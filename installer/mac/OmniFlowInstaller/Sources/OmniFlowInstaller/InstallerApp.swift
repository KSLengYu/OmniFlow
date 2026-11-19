import AppKit
import SwiftUI

@main
@MainActor
final class OmniFlowInstallerDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = OmniFlowInstallerDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appIcon = Bundle.main.image(forResource: "AppIcon") {
            NSApp.applicationIconImage = appIcon
        }

        let content = InstallerRootView(onClose: { [weak self] in
            self?.window?.close()
            NSApp.terminate(nil)
        })

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 506),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = InstallerL10n.shared.t("win_title")
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = NSColor(red: 0.043, green: 0.055, blue: 0.078, alpha: 1.0)
        win.contentViewController = NSHostingController(rootView: content)
        win.delegate = self
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private struct InstallerRootView: View {
    @StateObject private var vm = InstallerViewModel()
    @ObservedObject private var l10n = InstallerL10n.shared
    let onClose: () -> Void

    private let bgCanvas = Color(red: 0.043, green: 0.055, blue: 0.078)
    private let bgCard = Color(red: 0.071, green: 0.090, blue: 0.133)
    private let bgRecessed = Color(red: 0.031, green: 0.043, blue: 0.063)
    private let borderSubtle = Color(red: 0.122, green: 0.161, blue: 0.216)

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Group {
                switch vm.phase {
                case .setup:
                    setupView
                case .working:
                    workingView
                case .done:
                    doneView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 20)

            footerBar
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 660, height: 506)
        .background(bgCanvas)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Spacer().frame(width: 58)
            if let icon = loadBundleImage(named: "icon", ext: "png") {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .cornerRadius(5)
            }
            Text(l10n.t("win_title"))
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(.white)
            Text(l10n.t("badge_ver"))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(Color(red: 0.576, green: 0.773, blue: 0.992))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color(red: 0.082, green: 0.133, blue: 0.220))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(red: 0.145, green: 0.227, blue: 0.369), lineWidth: 1))
                .cornerRadius(4)

            Spacer()

            Button(action: { l10n.toggle() }) {
                Text(l10n.t("lang_btn"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(red: 0.576, green: 0.773, blue: 0.992))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Color(red: 0.082, green: 0.133, blue: 0.220))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(red: 0.145, green: 0.227, blue: 0.369), lineWidth: 1))
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)
        }
    }

    private var setupView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                if let icon = loadBundleImage(named: "icon", ext: "png") {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 50, height: 50)
                        .cornerRadius(11)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.t("hero_title"))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                    Text(l10n.t("hero_sub"))
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(red: 0.580, green: 0.639, blue: 0.722))
                }
                Spacer()
            }
            .padding(16)
            .background(bgCard)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderSubtle, lineWidth: 1))
            .cornerRadius(12)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(red: 0.063, green: 0.725, blue: 0.506))
                        .frame(width: 8, height: 8)
                    Text(l10n.t("arch_card_title"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(red: 0.886, green: 0.910, blue: 0.941))
                    Spacer()
                    Text(vm.detectedArch.label)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(red: 0.490, green: 0.827, blue: 0.988))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color(red: 0.055, green: 0.145, blue: 0.224))
                        .cornerRadius(5)
                }

                Text(vm.detectedArch == .arm64 ? l10n.t("arch_apple_silicon") : l10n.t("arch_intel"))
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 0.580, green: 0.639, blue: 0.722))

                HStack {
                    Text(l10n.t("arch_choice_lbl"))
                        .font(.system(size: 12))
                        .foregroundColor(Color(red: 0.796, green: 0.835, blue: 0.882))
                    Spacer()
                    Picker("", selection: $vm.archChoice) {
                        Text("\(l10n.t("arch_auto")) (\(vm.detectedArch.rawValue))").tag(ArchChoice.auto)
                        Text(l10n.t("arch_arm64")).tag(ArchChoice.arm64)
                        Text(l10n.t("arch_x86_64")).tag(ArchChoice.x86_64)
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }
            }
            .padding(15)
            .background(bgCard)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(borderSubtle, lineWidth: 1))
            .cornerRadius(10)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(l10n.t("dir_lbl"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(red: 0.796, green: 0.835, blue: 0.882))
                    Spacer()
                    Picker("", selection: $vm.destination) {
                        Text(l10n.t("dir_apps")).tag(InstallDestination.systemApplications)
                        Text(l10n.t("dir_user_apps")).tag(InstallDestination.userApplications)
                    }
                    .labelsHidden()
                    .frame(width: 290)
                    .onChange(of: vm.destination) { _, _ in
                        vm.refreshInstalledState()
                    }
                }

                Divider().background(borderSubtle)

                Toggle(l10n.t("chk_clear_quarantine"), isOn: $vm.clearQuarantine)
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 0.886, green: 0.910, blue: 0.941))
                Toggle(l10n.t("chk_launch"), isOn: $vm.launchAfter)
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 0.886, green: 0.910, blue: 0.941))
            }
            .padding(15)
            .background(bgCard)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(borderSubtle, lineWidth: 1))
            .cornerRadius(10)

            if let err = vm.errorMessage {
                Text(err)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(red: 0.988, green: 0.647, blue: 0.647))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var workingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(vm.lastActionWasUninstall ? l10n.t("prog_uninstalling") : l10n.t("prog_installing"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)

            ProgressView(value: vm.progress, total: 100)
                .progressViewStyle(.linear)
                .tint(Color(red: 0.231, green: 0.510, blue: 0.965))

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(vm.logs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(Color(red: 0.796, green: 0.835, blue: 0.882))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(bgRecessed)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderSubtle, lineWidth: 1))
            .cornerRadius(8)
        }
        .padding(18)
        .background(bgCard)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderSubtle, lineWidth: 1))
        .cornerRadius(12)
    }

    private var doneView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Color(red: 0.063, green: 0.725, blue: 0.506))
                Text(vm.lastActionWasUninstall ? l10n.t("done_uninstall_title") : l10n.t("done_install_title"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
            }

            Text(vm.lastActionWasUninstall ? l10n.t("done_uninstall_sub") : l10n.t("done_install_sub"))
                .font(.system(size: 13))
                .foregroundColor(Color(red: 0.796, green: 0.835, blue: 0.882))

            if !vm.lastActionWasUninstall {
                VStack(alignment: .leading, spacing: 5) {
                    Text(vm.destination.appPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(red: 0.576, green: 0.773, blue: 0.992))
                    Text("Architecture: \(vm.resolvedArch.label)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(Color(red: 0.580, green: 0.639, blue: 0.722))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(bgRecessed)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderSubtle, lineWidth: 1))
                .cornerRadius(8)
            }
            Spacer()
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(bgCard)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderSubtle, lineWidth: 1))
        .cornerRadius(12)
    }

    private var footerBar: some View {
        HStack {
            Button(action: { vm.openGitHub() }) {
                HStack(spacing: 9) {
                    if let avatar = loadBundleImage(named: "avatar", ext: "jpg") {
                        Image(nsImage: avatar)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 30, height: 30)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color(red: 0.231, green: 0.510, blue: 0.965), lineWidth: 1.2))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(vm.authorDisplayName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                            Text("· @KSLengYu")
                                .font(.system(size: 10.5))
                                .foregroundColor(Color(red: 0.580, green: 0.639, blue: 0.722))
                        }
                        Text("github.com/KSLengYu/OmniFlow")
                            .font(.system(size: 10.5))
                            .foregroundColor(Color(red: 0.376, green: 0.647, blue: 0.980))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(red: 0.063, green: 0.090, blue: 0.145))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 0.122, green: 0.169, blue: 0.251), lineWidth: 1))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)

            Spacer()

            if vm.phase == .setup {
                if vm.existingInstalled {
                    Button(l10n.t("btn_uninstall")) { vm.startUninstall() }
                        .buttonStyle(InstallerGhostBtn())
                }
                Button(l10n.t("btn_close")) { onClose() }
                    .buttonStyle(InstallerGhostBtn())
                Button(vm.existingInstalled ? l10n.t("btn_reinstall") : l10n.t("btn_install")) {
                    vm.startInstall()
                }
                .buttonStyle(InstallerPrimaryBtn())
            } else if vm.phase == .done {
                Button(l10n.t("btn_finish")) { onClose() }
                    .buttonStyle(InstallerPrimaryBtn())
            }
        }
    }

    private func loadBundleImage(named name: String, ext: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}

private struct InstallerPrimaryBtn: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(configuration.isPressed ? Color(red: 0.114, green: 0.306, blue: 0.847) : Color(red: 0.145, green: 0.388, blue: 0.922))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(red: 0.231, green: 0.510, blue: 0.965), lineWidth: 1))
            .cornerRadius(8)
    }
}

private struct InstallerGhostBtn: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundColor(Color(red: 0.796, green: 0.835, blue: 0.882))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(configuration.isPressed ? Color(red: 0.059, green: 0.090, blue: 0.165) : Color(red: 0.086, green: 0.114, blue: 0.169))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(red: 0.149, green: 0.196, blue: 0.282), lineWidth: 1))
            .cornerRadius(8)
    }
}
