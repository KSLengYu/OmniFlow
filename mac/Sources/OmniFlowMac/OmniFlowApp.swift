import SwiftUI
import AppKit

@main
enum OmniFlowEntry {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            let code = OmniFlowSelfTests.runAll()
            exit(code)
        }
        let app = NSApplication.shared
        let delegate = OmniFlowAppDelegate()
        app.delegate = delegate
        app.run()
    }
}

private enum OmniFlowSelfTests {
    static func makeMinimalZip(entries: [(name: String, content: Data)]) -> Data {
        var out = Data()
        var cd = Data()
        let crcTable: [UInt32] = (0..<256).map { i in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
            return c
        }
        func crc32(_ d: Data) -> UInt32 {
            var c: UInt32 = 0xFFFFFFFF
            for b in d { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
            return c ^ 0xFFFFFFFF
        }
        func u16(_ v: UInt16) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 2) }
        func u32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }

        for e in entries {
            let localOff = UInt32(out.count)
            let nameData = Data(e.name.utf8)
            let crc = crc32(e.content)
            let sz = UInt32(e.content.count)
            out.append(u32(0x04034B50))
            out.append(u16(20)); out.append(u16(0)); out.append(u16(0))
            out.append(u16(0)); out.append(u16(0))
            out.append(u32(crc)); out.append(u32(sz)); out.append(u32(sz))
            out.append(u16(UInt16(nameData.count))); out.append(u16(0))
            out.append(nameData)
            out.append(e.content)

            cd.append(u32(0x02014B50))
            cd.append(u16(0x031E))
            cd.append(u16(20)); cd.append(u16(0)); cd.append(u16(0))
            cd.append(u16(0)); cd.append(u16(0))
            cd.append(u32(crc)); cd.append(u32(sz)); cd.append(u32(sz))
            cd.append(u16(UInt16(nameData.count))); cd.append(u16(0)); cd.append(u16(0))
            cd.append(u16(0)); cd.append(u16(0)); cd.append(u32(0))
            cd.append(u32(localOff))
            cd.append(nameData)
        }
        let cdOff = UInt32(out.count)
        let cdSz = UInt32(cd.count)
        out.append(cd)
        out.append(u32(0x06054B50))
        out.append(u16(0)); out.append(u16(0))
        out.append(u16(UInt16(entries.count))); out.append(u16(UInt16(entries.count)))
        out.append(u32(cdSz)); out.append(u32(cdOff)); out.append(u16(0))
        return out
    }

    static func runAll() -> Int32 {
        // 1. Shared SAS derivation parity test vector
        let sas1 = SecurityValidation.computePairingSasCode(
            localFingerprint: "SHA256:AA:BB:CC:DD",
            peerFingerprint: "SHA256:11:22:33:44"
        )
        let sas2 = SecurityValidation.computePairingSasCode(
            localFingerprint: "sha256:11:22:33:44 ",
            peerFingerprint: "SHA256:AA:BB:CC:DD"
        )
        assert(sas1 == sas2 && sas1.count == 7 && sas1.contains("-"), "SAS parity failed")
        print("[PASS] SAS parity vector: \(sas1)")

        // 2. TrustStore pin & persist check
        let tmpTrust = FileManager.default.temporaryDirectory.appendingPathComponent("of_trust_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpTrust) }
        let store1 = TrustedPeerStore(customStoreURL: tmpTrust)
        assert(!store1.isTrusted("SHA256:AA:BB"), "Empty store must reject")
        store1.addTrusted(fingerprint: "sha256:aa:bb", hostName: "WinHost")
        let store2 = TrustedPeerStore(customStoreURL: tmpTrust)
        assert(store2.isTrusted("SHA256:AA:BB"), "Reloaded store must pin exact fingerprint")
        assert(!store2.isTrusted("SHA256:AA:BC"), "Different fingerprint must be rejected")
        print("[PASS] TrustStore certificate pinning")

        // 3. Single-filename & offer boundary validation
        assert(SecurityValidation.isValidSingleFileName("report_2026.pdf"))
        for bad in ["", ".", "..", "../evil.txt", "a/b.txt", "a\\b.txt", "C:foo", "bad\u{0000}name"] {
            assert(!SecurityValidation.isValidSingleFileName(bad), "Should reject bad filename: \(bad)")
        }
        let validOffer = WireFileOfferPayload(
            transferId: "abc-123_XYZ", fileName: "demo.bin", totalBytes: 300_000,
            chunkSize: 262_144, totalChunks: 2, scheme: "a", style: "blackhole", edge: "left", offset: 0.5, isDirectoryZip: false
        )
        assert(SecurityValidation.validateFileOffer(validOffer) == nil)
        assert(SecurityValidation.expectedChunkLength(offer: validOffer, index: 0) == 262_144)
        assert(SecurityValidation.expectedChunkLength(offer: validOffer, index: 1) == 37_856)
        assert(SecurityValidation.expectedChunkLength(offer: validOffer, index: 2) == nil)
        let badOffer = WireFileOfferPayload(
            transferId: "../escape", fileName: "demo.bin", totalBytes: 100,
            chunkSize: 0, totalChunks: 1, scheme: "a", style: "blackhole", edge: "left", offset: 0.5, isDirectoryZip: false
        )
        assert(SecurityValidation.validateFileOffer(badOffer) != nil)
        print("[PASS] Offer & chunk boundary validation")

        // 4. Zip-Slip attack rejection + safe folder extraction + SHA-256 verification
        let tmpWork = FileManager.default.temporaryDirectory.appendingPathComponent("of_zip_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpWork, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpWork) }

        let evilZipURL = tmpWork.appendingPathComponent("evil.zip")
        try? makeMinimalZip(entries: [("../pwned.txt", Data("evil".utf8))]).write(to: evilZipURL)
        var threwEvil = false
        do {
            _ = try SafeZipExtractor.extractSafely(zipURL: evilZipURL, destParentDir: tmpWork, preferredFolderName: "Evil")
        } catch { threwEvil = true }
        assert(threwEvil, "Zip-Slip must throw")
        assert(!FileManager.default.fileExists(atPath: tmpWork.deletingLastPathComponent().appendingPathComponent("pwned.txt").path))

        let goodZipURL = tmpWork.appendingPathComponent("bundle.zip")
        try? makeMinimalZip(entries: [("MyFolder/hello.txt", Data("hello omniflow".utf8))]).write(to: goodZipURL)
        do {
            let sha = try SecurityValidation.computeFileSha256Hex(url: goodZipURL)
            assert(sha.count == 64)
            let outFolder = try SafeZipExtractor.extractSafely(zipURL: goodZipURL, destParentDir: tmpWork, preferredFolderName: "MyFolder")
            let inner = outFolder.appendingPathComponent("hello.txt")
            let text = try String(contentsOf: inner, encoding: .utf8)
            assert(text == "hello omniflow")
        } catch {
            assertionFailure("Safe zip extraction failed: \(error)")
        }
        print("[PASS] SHA-256 & SafeZipExtractor Zip-Slip checks")

        // 5. Multitouch ABI & TrustedPeerStore per-device removal check
        precondition(MemoryLayout<MTContact>.stride == 96, "MTContact stride must be 96")
        precondition(MemoryLayout<MTContact>.offset(of: \.normalized) == 32, "MTContact normalized offset must be 32")
        let tmpTrust2 = FileManager.default.temporaryDirectory.appendingPathComponent("of_trust_rem_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpTrust2) }
        let ts = TrustedPeerStore(customStoreURL: tmpTrust2)
        ts.addTrusted(fingerprint: "SHA256:11:22", hostName: "WinA")
        ts.addTrusted(fingerprint: "SHA256:33:44", hostName: "WinB")
        precondition(ts.allTrusted().count == 2)
        ts.removeTrusted("SHA256:11:22")
        precondition(!ts.isTrusted("SHA256:11:22") && ts.isTrusted("SHA256:33:44"))
        precondition(MacBridgeSubnet.isUsbBridgeIp("10.13.37.1") && MacBridgeSubnet.isUsbBridgeIp("10.13.37.2"))
        precondition(!MacBridgeSubnet.isUsbBridgeIp("192.0.2.10") && !MacBridgeSubnet.isUsbBridgeIp("10.0.0.5") && !MacBridgeSubnet.isUsbBridgeIp("127.0.0.1"))
        print("[PASS] MTContact ABI (96B), USB subnet guard & TrustedPeerStore per-peer removal")

        // 6. RttEstimator spike filtering + sustained-shift adaptation
        let rtt = RttEstimator()
        _ = rtt.recordSample(45.0)
        _ = rtt.recordSample(1.1)
        let afterWarmup = rtt.recordSample(0.9)
        precondition(afterWarmup < 1.5, "RttEstimator failed to shed cold-start spike cleanly (got \(afterWarmup))")
        var steady = afterWarmup
        for s in [85.0, 1.0, 62.0, 0.9, 50.0, 1.1] {
            steady = rtt.recordSample(s)
        }
        precondition(steady < 2.5, "RttEstimator polluted by periodic spikes (got \(steady))")
        var shifted = steady
        for _ in 0..<8 {
            shifted = rtt.recordSample(18.0)
        }
        precondition(shifted > 12.0, "RttEstimator failed to adapt to sustained latency shift (got \(shifted))")
        let macKeyA = NicChannelItem.canonicalChannelKey(ifaceName: "en0", localIp: "192.0.2.11", isUsb: false, peerIp: "192.0.2.10")
        let macKeyB = NicChannelItem.canonicalChannelKey(ifaceName: "en0", localIp: "192.0.2.11", isUsb: false, peerIp: "192.0.2.12")
        precondition(macKeyA != macKeyB, "Multi-peer channels sharing one NIC must preserve distinct canonical keys")
        print("[PASS] RttEstimator trimmed lower-half baseline & adaptation")

        // 7. WireFrameCodec concatenated pair (FocusSwitch + MouseMoveAbs) & KvmStageTracer POSIX write
        let focusFrame = WireFrameCodec.encodeJSON(
            type: .kvmFocusSwitch,
            value: WireKvmFocusPayload(targetOs: "macOS", monitorIndex: 0, normX: 0.992, normY: 0.5)
        )!
        var movePayload = Data(count: 10)
        var nxBits = Float(0.992).bitPattern.bigEndian
        var nyBits = Float(0.5).bitPattern.bigEndian
        movePayload.replaceSubrange(2..<6, with: Data(bytes: &nxBits, count: 4))
        movePayload.replaceSubrange(6..<10, with: Data(bytes: &nyBits, count: 4))
        let pairBytes = focusFrame + WireFrameCodec.encode(type: .mouseMoveAbs, payload: movePayload)
        var cursor = pairBytes.startIndex
        var decodedTypes: [DeskflowMsgType] = []
        while pairBytes.count - (cursor - pairBytes.startIndex) >= 5 {
            let fLen = Int(UInt32(bigEndian: pairBytes.subdata(in: cursor..<(cursor + 4)).withUnsafeBytes { $0.load(as: UInt32.self) }))
            let msgType = DeskflowMsgType(rawValue: pairBytes[cursor + 4])!
            let pData = pairBytes.subdata(in: (cursor + 5)..<(cursor + 4 + fLen))
            decodedTypes.append(msgType)
            if msgType == .kvmFocusSwitch {
                let sw = try! JSONDecoder().decode(WireKvmFocusPayload.self, from: pData)
                precondition(sw.targetOs == "macOS" && abs(sw.normX - 0.992) < 0.001)
            } else if msgType == .mouseMoveAbs {
                precondition(pData.count == 10)
            }
            cursor += 4 + fLen
        }
        precondition(decodedTypes == [.kvmFocusSwitch, .mouseMoveAbs], "Concatenated SendFramePair must decode both frames cleanly")
        let tmpStageLog = FileManager.default.temporaryDirectory.appendingPathComponent("of_stage_\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: tmpStageLog) }
        let st = KvmStageTracer.shared.beginFocusSwitch(targetOs: "macOS")
        KvmStageTracer.shared.log(seq: st.seq, t0Ns: st.recvNs, customURL: tmpStageLog, sync: true, "selftestStageProbe ok=true")
        let stageContent = (try? String(contentsOf: tmpStageLog, encoding: .utf8)) ?? ""
        precondition(stageContent.contains("[KVM-Stage seq=#\(st.seq)") && stageContent.contains("selftestStageProbe ok=true"),
                     "KvmStageTracer failed to append POSIX log line")
        print("[PASS] Concatenated KvmFocusSwitch+MouseMoveAbs wire decode & KvmStageTracer POSIX write")
        return 0
    }
}

@MainActor
final class OmniFlowAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var openMenuItem: NSMenuItem?
    private var quitMenuItem: NSMenuItem?
    private var isCleanShutdownFinished = false
    private var isShuttingDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let myPid = ProcessInfo.processInfo.processIdentifier
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.lee.omniflow")
            .filter { $0.processIdentifier != myPid }
        if let first = existing.first {
            first.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSWindow.allowsAutomaticWindowTabbing = false
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        _ = DeskflowEngine.shared
        setupStatusItem()
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = item.button {
            btn.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "OmniFlow")
        }
        let menu = NSMenu()
        let en = DeskflowEngine.shared.isEnglish
        let openItem = NSMenuItem(title: en ? "Open OmniFlow Settings" : "打开 OmniFlow 设置", action: #selector(toggleWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        self.openMenuItem = openItem
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: en ? "Quit OmniFlow" : "彻底退出 OmniFlow", action: #selector(quitProgram), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        self.quitMenuItem = quitItem
        item.menu = menu
        statusItem = item

        NotificationCenter.default.addObserver(self, selector: #selector(refreshMenuLanguage), name: .omniFlowLanguageChanged, object: nil)
    }

    @objc private func refreshMenuLanguage() {
        let en = DeskflowEngine.shared.isEnglish
        openMenuItem?.title = en ? "Open OmniFlow Settings" : "打开 OmniFlow 设置"
        quitMenuItem?.title = en ? "Quit OmniFlow" : "彻底退出 OmniFlow"
    }

    @objc private func toggleWindow() {
        showMainWindow()
    }

    @objc private func quitProgram() {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isCleanShutdownFinished {
            return .terminateNow
        }
        if isShuttingDown {
            return .terminateLater
        }
        isShuttingDown = true

        // Keep window open showing cleanup progress until all services & helpers finish shutting down
        var sheetPanel: NSPanel?
        if let win = mainWindow, win.isVisible {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 84),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            panel.appearance = NSAppearance(named: .darkAqua)
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 84))
            let spin = NSProgressIndicator(frame: NSRect(x: 24, y: 32, width: 20, height: 20))
            spin.style = .spinning
            spin.controlSize = .small
            spin.startAnimation(nil)
            let en = DeskflowEngine.shared.isEnglish
            let label = NSTextField(labelWithString: en ? "Stopping services and cleaning up..." : "正在停止服务并清理后台组件...")
            label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            label.frame = NSRect(x: 56, y: 33, width: 240, height: 18)
            box.addSubview(spin)
            box.addSubview(label)
            panel.contentView = box
            sheetPanel = panel
            win.beginSheet(panel)
        }

        DeskflowEngine.shared.prepareForCleanExitAsync { [weak self] in
            guard let self = self else {
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            if let sp = sheetPanel, let win = self.mainWindow {
                win.endSheet(sp)
            }
            self.isCleanShutdownFinished = true
            self.mainWindow?.orderOut(nil)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isCleanShutdownFinished { return true }
        if isShuttingDown { return false }

        let en = DeskflowEngine.shared.isEnglish
        let alert = NSAlert()
        alert.messageText = en ? "Close OmniFlow Window" : "关闭 OmniFlow 窗口"
        alert.informativeText = en ? "Keep OmniFlow running in the background or quit completely." : "可以让 OmniFlow 留在后台运行，也可以退出。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: en ? "Keep in Background" : "最小化到后台")
        alert.addButton(withTitle: en ? "Quit Completely" : "彻底退出程序")
        alert.addButton(withTitle: en ? "Cancel" : "取消")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            sender.orderOut(nil)
            return false
        } else if response == .alertSecondButtonReturn {
            NSApp.terminate(nil)
            return false
        }
        return false
    }

    func showMainWindow() {
        if mainWindow == nil {
            let rootView = OmniFlowMainView(engine: DeskflowEngine.shared)
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.title = "OmniFlow"
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.appearance = NSAppearance(named: .darkAqua)
            win.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.13, alpha: 1.0)
            win.minSize = NSSize(width: 880, height: 580)
            win.center()
            win.isRestorable = false
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.contentView = NSHostingView(rootView: rootView)
            mainWindow = win
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
