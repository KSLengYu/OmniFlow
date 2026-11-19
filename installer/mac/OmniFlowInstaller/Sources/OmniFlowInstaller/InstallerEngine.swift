import AppKit
import Darwin
import Foundation

enum MacArch: String, CaseIterable, Identifiable {
    case arm64
    case x86_64

    var id: String { rawValue }

    var bundleFolderName: String {
        switch self {
        case .arm64: return "OmniFlow-arm64.app"
        case .x86_64: return "OmniFlow-x86_64.app"
        }
    }

    var label: String {
        switch self {
        case .arm64: return "Apple Silicon (arm64)"
        case .x86_64: return "Intel (x86_64)"
        }
    }
}

enum ArchChoice: String, CaseIterable, Identifiable {
    case auto
    case arm64
    case x86_64

    var id: String { rawValue }
}

enum InstallDestination: String, CaseIterable, Identifiable {
    case systemApplications
    case userApplications

    var id: String { rawValue }

    var directoryPath: String {
        switch self {
        case .systemApplications:
            return "/Applications"
        case .userApplications:
            return NSHomeDirectory() + "/Applications"
        }
    }

    var appPath: String {
        directoryPath + "/OmniFlow.app"
    }
}

enum InstallerPhase {
    case setup
    case working
    case done
}

@MainActor
final class InstallerViewModel: ObservableObject {
    @Published var detectedArch: MacArch
    @Published var archChoice: ArchChoice = .auto
    @Published var destination: InstallDestination = .systemApplications
    @Published var launchAfter = true
    @Published var clearQuarantine = true
    @Published var phase: InstallerPhase = .setup
    @Published var progress: Double = 0
    @Published var logs: [String] = []
    @Published var errorMessage: String?
    @Published var lastActionWasUninstall = false
    @Published var existingInstalled = false
    @Published var authorDisplayName: String = "楞宇"

    let l10n = InstallerL10n.shared

    init() {
        detectedArch = Self.detectHostArchitecture()
        if !FileManager.default.isWritableFile(atPath: "/Applications") {
            destination = .userApplications
        }
        refreshInstalledState()
        syncGitHubAuthorName()
    }

    var resolvedArch: MacArch {
        switch archChoice {
        case .auto: return detectedArch
        case .arm64: return .arm64
        case .x86_64: return .x86_64
        }
    }

    func refreshInstalledState() {
        existingInstalled = FileManager.default.fileExists(atPath: destination.appPath)
    }

    static func detectHostArchitecture() -> MacArch {
        var isTranslated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &isTranslated, &size, nil, 0) == 0 && isTranslated == 1 {
            return .arm64
        }

        var sysInfo = utsname()
        uname(&sysInfo)
        let machine = withUnsafePointer(to: &sysInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
        return machine.lowercased().contains("arm64") ? .arm64 : .x86_64
    }

    private func syncGitHubAuthorName() {
        Task {
            guard let url = URL(string: "https://api.github.com/users/KSLengYu") else { return }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3.0)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let name = obj["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.authorDisplayName = name
                }
            } catch {
                // Keep offline fallback name
            }
        }
    }

    private func appendLog(_ text: String, _ progress: Double) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        logs.append("[\(df.string(from: Date()))] \(text)")
        self.progress = progress
    }

    func startInstall() {
        guard phase == .setup else { return }
        errorMessage = nil
        lastActionWasUninstall = false
        logs.removeAll()
        phase = .working

        let targetArch = resolvedArch
        let destDir = destination.directoryPath
        let destApp = destination.appPath
        let shouldClearXattr = clearQuarantine
        let shouldLaunch = launchAfter

        Task {
            do {
                appendLog(l10n.t("step_stop"), 15)
                await Self.stopRunningOmniFlow()

                appendLog(l10n.t("step_locate") + targetArch.label, 35)
                guard let payloadUrl = Self.locatePayloadBundle(for: targetArch) else {
                    throw NSError(domain: "OmniFlowInstaller", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: l10n.t("err_missing_payload") + targetArch.bundleFolderName
                    ])
                }

                appendLog(l10n.t("step_copy") + destApp, 60)
                try await Self.installBundle(from: payloadUrl, toDir: destDir, destApp: destApp)

                if shouldClearXattr {
                    appendLog(l10n.t("step_xattr"), 82)
                    _ = await Self.runTool("/usr/bin/xattr", args: ["-cr", destApp])
                }

                appendLog(l10n.t("step_sign"), 94)
                _ = await Self.runTool("/usr/bin/codesign", args: ["--force", "--deep", "--sign", "-", destApp])

                appendLog(l10n.t("step_done"), 100)
                refreshInstalledState()
                phase = .done

                if shouldLaunch {
                    NSWorkspace.shared.openApplication(
                        at: URL(fileURLWithPath: destApp),
                        configuration: NSWorkspace.OpenConfiguration()
                    ) { _, _ in }
                }
            } catch {
                errorMessage = error.localizedDescription
                phase = .setup
            }
        }
    }

    func startUninstall() {
        guard phase == .setup else { return }
        errorMessage = nil
        lastActionWasUninstall = true
        logs.removeAll()
        phase = .working

        let destApp = destination.appPath
        Task {
            do {
                appendLog(l10n.t("step_stop"), 25)
                await Self.stopRunningOmniFlow()

                appendLog(l10n.t("step_remove") + " " + destApp, 75)
                let fm = FileManager.default
                if fm.fileExists(atPath: destApp) {
                    try fm.removeItem(atPath: destApp)
                }

                appendLog(l10n.t("step_done"), 100)
                refreshInstalledState()
                phase = .done
            } catch {
                errorMessage = error.localizedDescription
                phase = .setup
            }
        }
    }

    func openGitHub() {
        if let url = URL(string: "https://github.com/KSLengYu/OmniFlow") {
            NSWorkspace.shared.open(url)
        }
    }

    private nonisolated static func locatePayloadBundle(for arch: MacArch) -> URL? {
        if let resUrl = Bundle.main.resourceURL {
            let candidate = resUrl.appendingPathComponent("Payload").appendingPathComponent(arch.bundleFolderName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let direct = resUrl.appendingPathComponent(arch.bundleFolderName)
            if FileManager.default.fileExists(atPath: direct.path) {
                return direct
            }
        }
        return nil
    }

    private nonisolated static func stopRunningOmniFlow() async {
        await runTool("/usr/bin/pkill", args: ["-x", "OmniFlowMac"])
        try? await Task.sleep(nanoseconds: 350_000_000)
    }

    private nonisolated static func installBundle(from src: URL, toDir: String, destApp: String) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: toDir) {
            try fm.createDirectory(atPath: toDir, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: destApp) {
            try fm.removeItem(atPath: destApp)
        }
        let ok = await runTool("/usr/bin/ditto", args: [src.path, destApp])
        if !ok {
            throw NSError(domain: "OmniFlowInstaller", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to copy application bundle to \(destApp)"
            ])
        }
    }

    @discardableResult
    private nonisolated static func runTool(_ path: String, args: [String]) async -> Bool {
        await Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = args
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
                return proc.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }
}
