import Foundation
import AppKit
import SwiftUI
import Combine
import CryptoKit
import UniformTypeIdentifiers
import Darwin

@MainActor
final class DeskflowEngine: ObservableObject {
    static let shared = DeskflowEngine()

    // MARK: - 1. Portal & File Transfer Settings (Scheme A & Scheme B: Black Hole / Mini Cube)

    @Published var transferSchemeMode: TransferSchemeMode = .autoSmart {
        didSet { savePrefs() }
    }
    @Published var portalEffectStyle: PortalEffectStyle = .blackHole {
        didSet {
            savePrefs()
            PortalOverlayController.shared.showOrUpdatePanel()
        }
    }
    @Published var portalEdgeSide: ScreenEdgeSide = .right {
        didSet {
            savePrefs()
            PortalOverlayController.shared.repositionPanel()
        }
    }
    /// Customizable position along the chosen screen edge (0.05 ... 0.95)
    @Published var portalEdgeOffset: Double = 0.55 {
        didSet {
            savePrefs()
            PortalOverlayController.shared.repositionPanel()
        }
    }
    @Published var portalMonitorIndex: Int = 0 {
        didSet {
            savePrefs()
            PortalOverlayController.shared.repositionPanel()
        }
    }
    @Published var portalOverlayEnabled: Bool = true {
        didSet {
            savePrefs()
            PortalOverlayController.shared.updateVisibility()
        }
    }

    @Published var portalPhase: PortalPhase = .idle
    @Published var lastTransferSummary: String = ""
    @Published var manualPeerIp: String = UserDefaults.standard.string(forKey: "mb_df_manual_peer") ?? "" {
        didSet { UserDefaults.standard.set(manualPeerIp, forKey: "mb_df_manual_peer") }
    }
    @Published var peerConnectedCount: Int = 0
    @Published var peerHostLabel: String = ""
    @Published var accessibilityGranted: Bool = MacKvmController.shared.hasAccessibilityPermission
    @Published var logs: [String] = []
    @Published var usbNcmLocalIp: String = "10.13.37.1"
    @Published var usbNcmPeerIp: String = "10.13.37.2"
    @Published var usbNcmDetected: Bool = false

    private static let logFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    func appendLog(_ msg: String) {
        let line = "[\(Self.logFormatter.string(from: Date()))] \(msg)"
        logs.append(line)
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
        if msg.contains("[USB") || msg.contains("USB") || msg.contains("10.13.37.") || msg.contains("WinUSB") {
            usbLogs.append(line)
            if usbLogs.count > 120 { usbLogs.removeFirst(usbLogs.count - 120) }
        }
        if let d = (line + "\n").data(using: .utf8) {
            let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OmniFlow", isDirectory: true)
            try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            let logURL = logDir.appendingPathComponent("omniflow.log")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
               let sz = attrs[.size] as? UInt64, sz > 2 * 1024 * 1024 {
                try? d.write(to: logURL)
            } else if let fh = try? FileHandle(forWritingTo: logURL) {
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: d)
                try? fh.close()
            } else {
                try? d.write(to: logURL)
            }
        }
    }

    func appendUsbLog(_ msg: String) {
        let line = "[\(Self.logFormatter.string(from: Date()))] \(msg)"
        usbLogs.append(line)
        if usbLogs.count > 120 { usbLogs.removeFirst(usbLogs.count - 120) }
        appendLog("[USB] \(msg)")
    }

    private var lastReceivedURL: URL?
    private var remotePeerMonitors: [WireMonitorDto] = []

    // MARK: - 2. Multi-NIC Online, Latency/Bandwidth Split & Concurrency

    @Published var nicChannels: [NicChannelItem] = []
    @Published var isEnglish: Bool = false {
        didSet {
            guard !isLoadingPrefs else { return }
            savePrefs()
            refreshAllNicChannels()
            NotificationCenter.default.post(name: .omniFlowLanguageChanged, object: nil)
        }
    }

    @inline(__always)
    func t(_ zh: String, _ en: String) -> String {
        isEnglish ? en : zh
    }

    @Published var multipathEnabled: Bool = true {
        didSet { savePrefs() }
    }
    @Published var tlsFingerprint: String = "SHA256: 初始化中..."
    @Published var pendingPairing: PendingPairingRequest? = nil
    @Published var trustedPeers: [TrustedPeerRecord] = []

    // MARK: - 3. Per-Monitor Independent 2D Spatial Arrangement

    @Published var displayNodes: [IndependentDisplayNode] = []
    @Published var selectedDisplayId: String? = nil
    @Published var receivedFiles: [ReceivedFileItem] = []
    @Published var shelfItems: [ShelfTransferItem] = []

    // MARK: - 4. KVM Input, Focus Switch Mode, Clipboard & Semantic Hotkey Translation

    @Published var kvmEnabled: Bool = true {
        didSet {
            savePrefs()
            MacKvmController.shared.syncInjectorState(kvmEnabled: kvmEnabled, controlMode: kvmControlMode)
            if !isLoadingPrefs {
                if kvmEnabled { MacKvmController.shared.startTapIfPermitted() }
                else { MacKvmController.shared.stopTap() }
            }
        }
    }
    @Published var kvmControlMode: KvmControlMode = .dualActive {
        didSet {
            savePrefs()
            MacKvmController.shared.syncInjectorState(kvmEnabled: kvmEnabled, controlMode: kvmControlMode)
            if !applyingRemoteConfig && !isLoadingPrefs { broadcastConfigSync() }
        }
    }
    @Published var keymapProfile: KeymapProfileMode = .hybrid {
        didSet {
            savePrefs()
            if !applyingRemoteConfig && !isLoadingPrefs { broadcastConfigSync() }
        }
    }
    @Published var usbConnectProgress: Double = 0.0
    @Published var usbStatusText: String = "待插线 · USB-C 直连待机"
    @Published var usbHeadline: String = "等待 USB-C 直连"
    @Published var usbSubline: String = "连接 USB-C 线并启动 Windows 端 USB 直连。"
    @Published var usbDriverStatusText: String = "未检测到 USB-C NCM 虚拟网卡"
    @Published var usbActionInProgress: Bool = false
    @Published var usbActionHint: String = ""
    @Published var usbRxFrames: UInt64 = 0
    @Published var usbTxFrames: UInt64 = 0
    @Published var usbLogs: [String] = []
    private var applyingRemoteConfig: Bool = false
    private var isLoadingPrefs: Bool = false
    private var lastAppliedConfigTs: Double = 0
    @Published var edgeSwitchEnabled: Bool = true {
        didSet { savePrefs() }
    }
    @Published var hotkeySwitchEnabled: Bool = true {
        didSet { savePrefs() }
    }
    @Published var clipboardSyncEnabled: Bool = true {
        didSet { savePrefs() }
    }
    @Published var remoteFocusOnWindows: Bool = false
    @Published var hotkeyRules: [SemanticHotkeyRule] = [
        SemanticHotkeyRule(
            id: "shot_region",
            titleZh: "区域截图穿透",
            titleEn: "Region Screenshot",
            macTrigger: "Cmd + Shift + 4",
            winAction: "Win + Shift + S",
            actionCode: "WIN_SCREENSHOT_REGION",
            enabled: false
        ),
        SemanticHotkeyRule(
            id: "shot_panel",
            titleZh: "截图录屏工具栏",
            titleEn: "Screen Capture Bar",
            macTrigger: "Cmd + Shift + 5",
            winAction: "Win + Shift + S (Snipping)",
            actionCode: "WIN_SCREENSHOT_BAR",
            enabled: false
        ),
        SemanticHotkeyRule(
            id: "shot_snipaste",
            titleZh: "快捷贴图/微信截图映射",
            titleEn: "Quick Snip / WeChat Shot",
            macTrigger: "Cmd + Opt + A",
            winAction: "Alt + A",
            actionCode: "WIN_ALT_A",
            enabled: false
        ),
        SemanticHotkeyRule(
            id: "win_quick_x",
            titleZh: "Windows 快捷系统菜单 (Win+X)",
            titleEn: "Windows Quick Link Menu",
            macTrigger: "Ctrl + Opt + X",
            winAction: "Win + X",
            actionCode: "WIN_X_MENU",
            enabled: false
        ),
        SemanticHotkeyRule(
            id: "clip_ops",
            titleZh: "剪贴板与编辑 (C/V/X/A/Z/S/F)",
            titleEn: "Clipboard & Edit Keys",
            macTrigger: "Cmd + C/V/X/A/Z/S/F",
            winAction: "Ctrl + C/V/X/A/Z/S/F",
            actionCode: "WIN_CTRL_STD",
            enabled: false
        ),
        SemanticHotkeyRule(
            id: "app_switch",
            titleZh: "跨系统窗口切换",
            titleEn: "Window Switcher",
            macTrigger: "Cmd + Tab",
            winAction: "Alt + Tab",
            actionCode: "WIN_ALT_TAB",
            enabled: false
        ),
        SemanticHotkeyRule(
            id: "search_launcher",
            titleZh: "全局搜索呼出",
            titleEn: "Global Search",
            macTrigger: "Cmd + Space",
            winAction: "Win + S",
            actionCode: "WIN_SEARCH",
            enabled: false,
            direction: "mac_to_win"
        ),
        // Mac Trackpad -> Windows Three-Finger Drag (opt-in; sensitive to network latency)
        SemanticHotkeyRule(
            id: "mac_tp_3f_drag",
            titleZh: "触控板三指拖移",
            titleEn: "3-Finger Drag",
            macTrigger: "3指按住移动",
            winAction: "Windows 左键拖移",
            actionCode: "TP_3F_DRAG",
            enabled: false,
            direction: "mac_to_win",
            isGesture: true
        ),
        // Windows -> Mac Keyboard Shortcuts
        SemanticHotkeyRule(
            id: "win_to_mac_prtsc",
            titleZh: "PrintScreen 截 Mac 区域",
            titleEn: "Win PrtScn -> Mac Screenshot",
            macTrigger: "Win PrtScn",
            winAction: "Mac Cmd + Shift + 4",
            actionCode: "MAC_SCREENSHOT_REGION",
            enabled: false,
            direction: "win_to_mac"
        ),
        SemanticHotkeyRule(
            id: "win_to_mac_snip",
            titleZh: "Win 截图键触发 Mac 截图",
            titleEn: "Win+Shift+S -> Mac Screenshot",
            macTrigger: "Win + Shift + S",
            winAction: "Mac Cmd + Shift + 4",
            actionCode: "MAC_SCREENSHOT_REGION",
            enabled: false,
            direction: "win_to_mac"
        ),
        SemanticHotkeyRule(
            id: "win_to_mac_clip",
            titleZh: "Win 复制/编辑映射 (Ctrl→Cmd)",
            titleEn: "Win Ctrl Edit -> Mac Cmd",
            macTrigger: "Ctrl + C/V/X/A/Z/S/F",
            winAction: "Mac Cmd + C/V/X/A/Z/S/F",
            actionCode: "MAC_CMD_STD",
            enabled: false,
            direction: "win_to_mac"
        ),
        SemanticHotkeyRule(
            id: "win_to_mac_alttab",
            titleZh: "Win Alt+Tab 切 Mac 应用",
            titleEn: "Win Alt+Tab -> Mac Cmd+Tab",
            macTrigger: "Alt + Tab",
            winAction: "Mac Cmd + Tab",
            actionCode: "MAC_CMD_TAB",
            enabled: false,
            direction: "win_to_mac"
        ),
        SemanticHotkeyRule(
            id: "win_to_mac_search",
            titleZh: "Win 搜索键呼出 Mac 聚焦",
            titleEn: "Win+S -> Mac Spotlight",
            macTrigger: "Win + S",
            winAction: "Mac Cmd + Space",
            actionCode: "MAC_SPOTLIGHT",
            enabled: false,
            direction: "win_to_mac"
        ),
        // Windows Touchpad -> Mac Three-Finger Drag (opt-in; sensitive to network latency)
        SemanticHotkeyRule(
            id: "win_tp_3f_drag",
            titleZh: "触控板三指拖移",
            titleEn: "Win 3-Finger Drag",
            macTrigger: "Win 3指按住移动",
            winAction: "Mac 左键按住拖移",
            actionCode: "TP_3F_DRAG",
            enabled: false,
            direction: "win_to_mac",
            isGesture: true
        )
    ] {
        didSet {
            savePrefs()
            if !applyingRemoteConfig && !isLoadingPrefs { broadcastConfigSync() }
        }
    }

    @Published var globalPaused: Bool = false
    private var lastPasteboardCount: Int = NSPasteboard.general.changeCount
    private var lastRemoteClipboardText: String = ""
    private var lastRemoteClipboardImageSha: String = ""
    private var lastRemoteClipboardFileSig: String = ""
    private var suppressPasteboardUntil: Date = .distantPast
    private var clipboardTimer: Timer?
    private var fallbackKeyMonitor: Any?
    static let dragOutReentryCooldownSeconds: TimeInterval = 2.0
    var isDraggingOutFromShelf: Bool = false
    private var dragOutEndedAt: Date = .distantPast
    private var recentDraggedOutPaths: Set<String> = []
    private var lastDropSignature: String = ""
    private var lastDropSubmittedAt: Date = .distantPast
    @Published var displaySaveStatusText: String = ""
    @Published var settingsSaveStatusText: String = ""
    private var savedDisplayPositions: [String: [Double]] = [:]
    private var cubeDragStartMouse: NSPoint?
    private var cubeDragStartOffset: Double = 0.55

    private init() {
        loadPrefs()
        wireTransportAndKvm()
        DeskflowTransport.shared.start()
        trustedPeers = DeskflowTransport.shared.trustStore.allTrusted()
        if !manualPeerIp.isEmpty {
            DeskflowTransport.shared.addManualPeerIp(manualPeerIp)
        }
        tlsFingerprint = DeskflowTransport.shared.localFingerprint
        refreshAllNicChannels()
        refreshIndependentDisplays()
        startClipboardAndHotkeyWatchers()

        MacKvmController.shared.ensureTapWatcherStarted()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            PortalOverlayController.shared.bind(engine: self)
        }
    }

    // MARK: - Transport & KVM Wiring

    private func wireTransportAndKvm() {
        let tx = DeskflowTransport.shared

        tx.onLog = { [weak self] msg in
            Task { @MainActor in
                self?.appendLog(msg)
            }
        }

        tx.onLinksUpdated = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                let linksNow = tx.activeLinksSnapshot()
                if linksNow.isEmpty {
                    if self.remoteFocusOnWindows {
                        MacKvmController.shared.setRemoteFocus(false, notifyPeer: false)
                    }
                    if !self.remotePeerMonitors.isEmpty {
                        self.remotePeerMonitors.removeAll()
                        self.refreshIndependentDisplays()
                    }
                }
                self.refreshAllNicChannels()
                if !tx.peerFingerprint.isEmpty {
                    self.tlsFingerprint = tx.peerFingerprint
                } else {
                    self.tlsFingerprint = tx.localFingerprint
                }
            }
        }

        tx.onPeerMonitorsUpdated = { [weak self] monitors, host in
            Task { @MainActor in
                guard let self = self else { return }
                self.remotePeerMonitors = monitors
                self.peerHostLabel = host
                self.syncedRemotePositions.removeValue(forKey: "win_disp_wait")
                // Restore authoritative user-saved display coordinates before laying out combined Mac+Win screens
                for (id, coords) in self.savedDisplayPositions where coords.count == 2 {
                    self.syncedRemotePositions[id] = CGPoint(x: coords[0], y: coords[1])
                }
                self.refreshIndependentDisplays()
                self.appendLog("[Display] 已同步对端 Windows (\(host)) 的 \(monitors.count) 块独立显示器")
            }
        }

        tx.onRemoteClipboardText = { [weak self] txt in
            Task { @MainActor in
                guard let self = self, self.clipboardSyncEnabled, !txt.isEmpty else { return }
                let pb = NSPasteboard.general
                if pb.string(forType: .string) == txt && self.lastRemoteClipboardText == txt {
                    return
                }
                self.suppressPasteboardUntil = Date().addingTimeInterval(0.9)
                self.lastRemoteClipboardText = txt
                pb.clearContents()
                pb.setString(txt, forType: .string)
                self.lastPasteboardCount = pb.changeCount
                self.appendLog("[剪贴板] 收到 Windows 复制的文字 (\(txt.count) 字符)")
            }
        }

        tx.onRemoteClipboardImage = { [weak self] pngData in
            Task { @MainActor in
                guard let self = self, self.clipboardSyncEnabled, !pngData.isEmpty else { return }
                let sha = Self.sha256Hex(pngData)
                if sha == self.lastRemoteClipboardImageSha { return }
                guard let img = NSImage(data: pngData) else { return }

                self.suppressPasteboardUntil = Date().addingTimeInterval(0.9)
                self.lastRemoteClipboardImageSha = sha
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([img])
                pb.setData(pngData, forType: .png)
                self.lastPasteboardCount = pb.changeCount
                let kb = String(format: "%.0f KB", Double(pngData.count) / 1024.0)
                self.appendLog("[剪贴板] 收到 Windows 复制的图片 (\(kb))，可直接粘贴")
            }
        }

        tx.onRemotePortalSync = { [weak self] sync in
            Task { @MainActor in
                guard let self = self else { return }
                if !self.portalOverlayEnabled {
                    self.portalOverlayEnabled = true
                }
                if let style = PortalEffectStyle(rawValue: sync.style), self.portalEffectStyle != style {
                    self.portalEffectStyle = style
                }
                PortalOverlayController.shared.showOrUpdatePanel()
                switch sync.phase {
                case "emergingOut":
                    self.portalPhase = .emergingOut(
                        progress: sync.progress,
                        fileName: sync.fileName,
                        fileSize: sync.fileSize,
                        speedMbps: sync.speedMbps,
                        channelTag: sync.channelTag
                    )
                case "suckingIn":
                    self.portalPhase = .suckingIn(
                        progress: sync.progress,
                        fileName: sync.fileName,
                        fileSize: sync.fileSize,
                        speedMbps: sync.speedMbps,
                        channelTag: sync.channelTag
                    )
                case "completed":
                    self.portalPhase = .completed(fileName: sync.fileName, fileSize: sync.fileSize, savedURL: self.lastReceivedURL)
                default:
                    self.portalPhase = .idle
                }
            }
        }

        tx.onIncomingFileCompleted = { [weak self] offer, savedURL in
            Task { @MainActor in
                guard let self = self else { return }
                let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(offer.totalBytes), countStyle: .file)

                if offer.isClipboardItem == true {
                    guard self.clipboardSyncEnabled else { return }
                    var clipURLs: [URL] = [savedURL]
                    if offer.isClipboardMulti == true {
                        let children = (try? FileManager.default.contentsOfDirectory(
                            at: savedURL,
                            includingPropertiesForKeys: nil,
                            options: [.skipsHiddenFiles]
                        )) ?? []
                        if !children.isEmpty { clipURLs = children }
                    }
                    let pb = NSPasteboard.general
                    self.suppressPasteboardUntil = Date().addingTimeInterval(1.0)
                    self.lastRemoteClipboardFileSig = Self.clipboardFilesSignature(clipURLs)
                    pb.clearContents()
                    pb.writeObjects(clipURLs as [NSURL])
                    self.lastPasteboardCount = pb.changeCount
                    self.appendLog("[剪贴板] 收到 Windows 复制的文件，可直接按 ⌘V 粘贴 (\(clipURLs.count) 项 · \(sizeStr))")
                    return
                }

                self.lastReceivedURL = savedURL
                // Place received file on clipboard so Ctrl/Cmd+V lands immediately
                let pb = NSPasteboard.general
                self.suppressPasteboardUntil = Date().addingTimeInterval(0.9)
                self.lastRemoteClipboardFileSig = Self.clipboardFilesSignature([savedURL])
                pb.clearContents()
                pb.writeObjects([savedURL as NSURL])
                self.lastPasteboardCount = pb.changeCount

                var deliveredURLs: [URL] = [savedURL]
                if offer.isBatchBundle == true {
                    let children = (try? FileManager.default.contentsOfDirectory(
                        at: savedURL,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )) ?? []
                    if !children.isEmpty { deliveredURLs = children }
                }

                let itemCount = offer.batchItemCount ?? deliveredURLs.count
                let cardTitle = itemCount > 1
                    ? (self.isEnglish
                       ? "\(deliveredURLs.first?.lastPathComponent ?? offer.fileName) +\(itemCount - 1) more"
                       : "\(deliveredURLs.first?.lastPathComponent ?? offer.fileName) 等 \(itemCount) 项")
                    : (deliveredURLs.first?.lastPathComponent ?? offer.fileName)
                let shelfCard = ShelfTransferItem(
                    id: offer.transferId,
                    direction: .incoming,
                    status: .ready,
                    title: cardTitle,
                    sizeText: sizeStr,
                    itemCount: itemCount,
                    progress: 1.0,
                    speedMbps: 0,
                    channelTag: self.t("已校验", "Verified"),
                    errorText: nil,
                    sourcePaths: [],
                    localPaths: deliveredURLs.map(\.path),
                    timestamp: Date()
                )
                self.shelfItems.removeAll(where: { $0.id == offer.transferId })
                self.shelfItems.insert(shelfCard, at: 0)
                if self.shelfItems.count > 12 { self.shelfItems.removeLast() }

                self.portalPhase = .completed(fileName: cardTitle, fileSize: sizeStr, savedURL: savedURL)
                let item = ReceivedFileItem(
                    id: offer.transferId,
                    fileName: cardTitle,
                    fileSize: sizeStr,
                    savedURL: savedURL,
                    timestamp: Date(),
                    isArchiveOrFolder: offer.isDirectoryZip || offer.fileName.lowercased().hasSuffix(".zip")
                )
                self.receivedFiles.insert(item, at: 0)
                if self.receivedFiles.count > 50 { self.receivedFiles.removeLast() }
                self.lastTransferSummary = self.t(
                    "收到 Windows 发来的文件: \(cardTitle) (\(sizeStr))",
                    "Received from Windows: \(cardTitle) (\(sizeStr))"
                )
                self.appendLog("[传文件] 接收并校验完成: \(cardTitle) -> \(savedURL.path) (\(sizeStr))")
            }
        }

        tx.onTransferFailed = { [weak self] fileName, reason in
            Task { @MainActor in
                guard let self = self else { return }
                self.portalPhase = .idle
                self.lastTransferSummary = self.t(
                    "传输校验失败 (\(fileName)): \(reason)",
                    "Transfer verification failed (\(fileName)): \(reason)"
                )
                self.appendLog("[File Error] 接收失败 (\(fileName)): \(reason)")
            }
        }

        tx.onPendingPairingRequest = { [weak self] req in
            Task { @MainActor in
                guard let self = self else { return }
                if self.pendingPairing?.fingerprint != req.fingerprint {
                    self.pendingPairing = req
                }
            }
        }

        tx.onTrustStoreUpdated = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                self.trustedPeers = tx.trustStore.allTrusted()
            }
        }

        MacKvmController.shared.syncInjectorState(kvmEnabled: kvmEnabled, controlMode: kvmControlMode)
        tx.onKvmMouseMoveAbs = { monIdx, nx, ny in
            MacKvmController.injectMouseMoveAbsFast(monitorIdx: monIdx, normX: nx, normY: ny)
        }
        tx.onKvmMouseButton = { [weak self] btn, down in
            Task { @MainActor in
                guard let self = self, self.kvmEnabled, self.kvmControlMode != .macMasterOnly else { return }
                MacKvmController.shared.injectMouseButton(button: btn, isDown: down)
            }
        }
        tx.onKvmMouseScroll = { [weak self] dy, dx in
            Task { @MainActor in
                guard let self = self, self.kvmEnabled, self.kvmControlMode != .macMasterOnly else { return }
                MacKvmController.shared.injectMouseScroll(dy: dy, dx: dx)
            }
        }
        tx.onKvmKeyEvent = { [weak self] vk, down, mods in
            Task { @MainActor in
                guard let self = self, self.kvmEnabled, self.kvmControlMode != .macMasterOnly else { return }
                MacKvmController.shared.injectKeyEvent(vkCode: vk, isDown: down, modifiers: mods)
            }
        }
        tx.onKvmSemanticHotkey = { [weak self] action in
            Task { @MainActor in
                guard let self = self else { return }
                if action == "IDENTIFY_SCREENS" {
                    self.flashLocalScreenNumbersOnly()
                    self.appendLog("[Display] 收到对端请求：已亮起本机屏幕编号")
                } else {
                    guard self.kvmEnabled, self.kvmControlMode != .macMasterOnly else { return }
                    MacKvmController.shared.injectSemanticHotkey(action: action)
                    self.appendLog("[Hotkey] 收到 Windows 跨系统快捷键触发: \(action)")
                }
            }
        }
        tx.onKvmFocusSwitch = { [weak self] sw in
            let trace = KvmStageTracer.shared.currentTrace()
            let recvNs = trace.t0Ns > 0 ? trace.t0Ns : DispatchTime.now().uptimeNanoseconds
            let stageSeq = trace.seq
            let epochAtSwitch: UInt64
            if sw.targetOs == "macOS" {
                KvmStageTracer.shared.log(
                    seq: stageSeq,
                    t0Ns: recvNs,
                    "engineFocusCallback target=macOS"
                )
                epochAtSwitch = MacKvmController.prepareCursorForIncomingFocus(
                    monitorIdx: sw.monitorIndex,
                    normX: sw.normX,
                    normY: sw.normY,
                    recvNs: recvNs,
                    stageSeq: stageSeq
                )
            } else {
                epochAtSwitch = 0
            }
            Task { @MainActor in
                guard let self = self else {
                    if sw.targetOs == "macOS" {
                        KvmStageTracer.shared.log(seq: stageSeq, t0Ns: recvNs, "mainActorSkipped_selfNil")
                    }
                    return
                }
                if sw.targetOs == "macOS" {
                    KvmStageTracer.shared.log(
                        seq: stageSeq,
                        t0Ns: recvNs,
                        "mainActorEnter mode=\(self.kvmControlMode.rawValue) remoteFocusOnWin=\(self.remoteFocusOnWindows) kvmEnabled=\(self.kvmEnabled)"
                    )
                    // Incoming remote control from Windows -> allow only when dualActive or winMasterOnly
                    if self.kvmControlMode == .macMasterOnly && !self.remoteFocusOnWindows {
                        KvmStageTracer.shared.log(seq: stageSeq, t0Ns: recvNs, "mainActorGuardReturnedEarly mode=macMasterOnly")
                        return
                    }
                    MacKvmController.shared.setRemoteFocus(
                        false,
                        entryNormX: sw.normX,
                        entryNormY: sw.normY,
                        notifyPeer: false,
                        focusEpochAtSwitch: epochAtSwitch
                    )
                    KvmStageTracer.shared.log(
                        seq: stageSeq,
                        t0Ns: recvNs,
                        "mainActorDone remoteFocusOnWin=\(self.remoteFocusOnWindows)"
                    )
                } else if sw.targetOs == "Windows" {
                    MacKvmController.shared.setRemoteFocus(true, entryNormX: sw.normX, entryNormY: sw.normY, notifyPeer: false)
                }
            }
        }
        tx.onTopologySync = { [weak self] payload in
            Task { @MainActor in
                self?.applyRemoteTopologySync(payload)
            }
        }
        tx.onConfigSync = { [weak self] cfg in
            Task { @MainActor in
                self?.applyRemoteConfigSync(cfg)
            }
        }

        MacKvmController.shared.onLog = { [weak self] msg in
            Task { @MainActor in
                self?.appendLog(msg)
            }
        }
        MacKvmController.shared.onRemoteFocusChanged = { [weak self] remote in
            Task { @MainActor in
                self?.remoteFocusOnWindows = remote
                self?.appendLog(remote ? "[KVM] 鼠标键盘焦点已切换至 Windows" : "[KVM] 鼠标键盘焦点已返回 Mac")
            }
        }
    }

    func connectManualPeer() {
        DeskflowTransport.shared.addManualPeerIp(manualPeerIp)
        refreshAllNicChannels()
    }

    func toggleManualFocusSwitch() {
        MacKvmController.shared.toggleRemoteFocusManual()
    }

    func isRuleEnabled(_ id: String) -> Bool {
        hotkeyRules.first(where: { $0.id == id })?.enabled ?? false
    }

    func disconnectNic(_ item: NicChannelItem) {
        DeskflowTransport.shared.disconnectChannel(ifaceName: item.ifaceName, localIp: item.localIp)
        if item.isUsbBridge {
            DeskflowTransport.shared.ensureLanLinksConnected()
        }
        refreshAllNicChannels()
    }

    func reconnectNic(_ item: NicChannelItem) {
        DeskflowTransport.shared.reconnectChannel(
            ifaceName: item.ifaceName,
            localIp: item.localIp,
            peerIp: item.peerIp.isEmpty ? manualPeerIp : item.peerIp
        )
        refreshAllNicChannels()
    }

    func toggleGlobalDisconnect() {
        if globalPaused {
            globalPaused = false
            DeskflowTransport.shared.reconnectAllLinks()
        } else {
            globalPaused = true
            if remoteFocusOnWindows {
                MacKvmController.shared.setRemoteFocus(false, notifyPeer: false)
            }
            DeskflowTransport.shared.disconnectAllLinks()
        }
        refreshAllNicChannels()
    }

    func connectUsbDirectBridge() {
        usbActionInProgress = true
        usbConnectProgress = 0.15
        usbHeadline = t("正在启动 USB-C 直连引擎...", "Starting USB-C Direct Engine...")
        usbSubline = t("正在检测本地 USB-C NCM 网口并与 Windows (10.13.37.2) 建立点对点直连", "Detecting local USB-C NCM interface and linking with Windows (10.13.37.2)")
        usbActionHint = t("步骤 1/3 · 正在扫描 USB-C NCM 网口...", "Step 1/3 · Scanning USB-C NCM interfaces...")
        appendUsbLog("手动触发 USB-C 直连建立：10.13.37.1 <-> 10.13.37.2")
        DeskflowTransport.shared.reconnectChannel(ifaceName: "USB-C NCM", localIp: usbNcmLocalIp, peerIp: usbNcmPeerIp)
        DeskflowTransport.shared.addManualPeerIp(usbNcmPeerIp)
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            for (stepPct, stepZh, stepEn) in [
                (0.38, "步骤 1/3 · 正在检测 USB-C NCM 虚拟网卡...", "Step 1/3 · Checking USB-C NCM adapter..."),
                (0.62, "步骤 2/3 · 正在等待 Windows 端 NCM 驱动与端口 24810 握手...", "Step 2/3 · Handshaking with Windows port 24810..."),
                (0.84, "步骤 3/3 · 正在完成隧道连通性确认...", "Step 3/3 · Verifying tunnel connectivity...")
            ] {
                try? await Task.sleep(nanoseconds: 380_000_000)
                if !self.usbActionInProgress || self.usbConnectProgress >= 1.0 { return }
                self.refreshAllNicChannels()
                if self.usbConnectProgress < 1.0 {
                    self.usbConnectProgress = max(self.usbConnectProgress, stepPct)
                    self.usbActionHint = self.t(stepZh, stepEn)
                }
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
            self.usbActionInProgress = false
            self.refreshAllNicChannels()
        }
    }

    func disconnectUsbDirectBridge() {
        usbActionInProgress = true
        usbConnectProgress = 0.20
        usbHeadline = t("正在断开 USB-C 直连通道...", "Disconnecting USB-C Direct Link...")
        usbActionHint = t("正在关闭点对点直连隧道并自动切换以太网", "Closing USB tunnel and failing over to Ethernet/LAN")
        appendUsbLog("正在断开 USB-C 直连隧道并切换回 LAN/以太网")
        DeskflowTransport.shared.disconnectChannel(ifaceName: "USB-C NCM", localIp: usbNcmLocalIp)
        if let liveUsb = DeskflowTransport.shared.activeLinksSnapshot().first(where: { $0.isUsbBridge }) {
            DeskflowTransport.shared.disconnectChannel(ifaceName: liveUsb.ifaceName, localIp: liveUsb.localIp)
        }
        DeskflowTransport.shared.ensureLanLinksConnected()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self else { return }
            self.usbActionInProgress = false
            self.usbConnectProgress = 0.0
            self.refreshAllNicChannels()
        }
    }

    func broadcastConfigSync() {
        let modeStr: String
        switch kvmControlMode {
        case .dualActive: modeStr = "dual"
        case .macMasterOnly: modeStr = "mac_master"
        case .winMasterOnly: modeStr = "win_master"
        }
        let keymapStr: String
        switch keymapProfile {
        case .hybrid: keymapStr = "hybrid"
        case .deskflowNative: keymapStr = "deskflowNative"
        case .omniflowMacHabit: keymapStr = "omniflowMacHabit"
        }
        let enabledIds = hotkeyRules.filter(\.enabled).map(\.id)
        let payload = WireConfigSyncPayload(
            senderOs: "macOS",
            timestamp: Date().timeIntervalSince1970,
            controlMode: modeStr,
            keymapProfile: keymapStr,
            enabledRuleIds: enabledIds
        )
        if let frame = WireFrameCodec.encodeJSON(type: .configSync, value: payload) {
            DeskflowTransport.shared.broadcastControlFrame(frame)
        }
    }

    func applyRemoteConfigSync(_ cfg: WireConfigSyncPayload) {
        guard cfg.senderOs != "macOS", cfg.timestamp >= lastAppliedConfigTs - 0.1 else { return }
        lastAppliedConfigTs = cfg.timestamp
        applyingRemoteConfig = true
        defer { applyingRemoteConfig = false }

        switch cfg.controlMode {
        case "dual": kvmControlMode = .dualActive
        case "mac_master": kvmControlMode = .macMasterOnly
        case "win_master": kvmControlMode = .winMasterOnly
        default: break
        }
        switch cfg.keymapProfile {
        case "hybrid": keymapProfile = .hybrid
        case "deskflowNative": keymapProfile = .deskflowNative
        case "omniflowMacHabit": keymapProfile = .omniflowMacHabit
        default: break
        }
        let idSet = Set(cfg.enabledRuleIds)
        for i in hotkeyRules.indices {
            hotkeyRules[i].enabled = idSet.contains(hotkeyRules[i].id)
        }
        appendLog("[Config] 已同步 Windows 按键映射与控制策略: \(cfg.keymapProfile) / \(cfg.controlMode) (\(idSet.count)条规则)")
    }

    func confirmPendingPairing() {
        guard let req = pendingPairing else { return }
        pendingPairing = nil
        DeskflowTransport.shared.confirmPairing(fingerprint: req.fingerprint, hostName: req.hostName)
        trustedPeers = DeskflowTransport.shared.trustStore.allTrusted()
    }

    func rejectPendingPairing() {
        guard let req = pendingPairing else { return }
        pendingPairing = nil
        DeskflowTransport.shared.rejectPairing(fingerprint: req.fingerprint)
    }

    func clearTrustedPeers() {
        pendingPairing = nil
        DeskflowTransport.shared.clearAllTrustedPeers()
        trustedPeers = DeskflowTransport.shared.trustStore.allTrusted()
    }

    func removeTrustedPeer(fingerprint: String) {
        pendingPairing = nil
        DeskflowTransport.shared.removeTrustedPeer(fingerprint: fingerprint)
        trustedPeers = DeskflowTransport.shared.trustStore.allTrusted()
    }

    func requestAccessibility() {
        MacKvmController.shared.requestAccessibilityPermission()
        MacKvmController.shared.ensureTapWatcherStarted()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.accessibilityGranted = MacKvmController.shared.hasAccessibilityPermission
            if self?.accessibilityGranted == true {
                MacKvmController.shared.startTapIfPermitted()
            }
        }
    }

    // MARK: - Persistence

    private func loadPrefs() {
        isLoadingPrefs = true
        defer { isLoadingPrefs = false }
        let d = UserDefaults.standard
        if let rawScheme = d.string(forKey: "mb_df_scheme"), let v = TransferSchemeMode(rawValue: rawScheme) {
            transferSchemeMode = v
        }
        if let rawStyle = d.string(forKey: "mb_df_style"), let v = PortalEffectStyle(rawValue: rawStyle) {
            portalEffectStyle = v
        }
        if let rawEdge = d.string(forKey: "mb_df_edge"), let v = ScreenEdgeSide(rawValue: rawEdge) {
            portalEdgeSide = v
        }
        if d.object(forKey: "mb_df_offset") != nil {
            portalEdgeOffset = min(max(d.double(forKey: "mb_df_offset"), 0.05), 0.95)
        }
        if d.object(forKey: "mb_df_overlay") != nil {
            portalOverlayEnabled = d.bool(forKey: "mb_df_overlay")
        }
        if d.object(forKey: "mb_df_multipath") != nil {
            multipathEnabled = d.bool(forKey: "mb_df_multipath")
        }
        if d.object(forKey: "mb_df_kvm_enabled") != nil {
            kvmEnabled = d.bool(forKey: "mb_df_kvm_enabled")
        }
        if d.object(forKey: "mb_df_edge_switch") != nil {
            edgeSwitchEnabled = d.bool(forKey: "mb_df_edge_switch")
        }
        if d.object(forKey: "mb_df_hotkey_switch") != nil {
            hotkeySwitchEnabled = d.bool(forKey: "mb_df_hotkey_switch")
        }
        if d.object(forKey: "mb_df_clip_sync") != nil {
            clipboardSyncEnabled = d.bool(forKey: "mb_df_clip_sync")
        }
        if let rawCtrl = d.string(forKey: "mb_df_ctrl_mode"), let v = KvmControlMode(rawValue: rawCtrl) {
            kvmControlMode = v
        }
        keymapProfile = .hybrid
        if let savedIds = d.array(forKey: "mb_df_enabled_rules") as? [String] {
            let set = Set(savedIds)
            for i in hotkeyRules.indices {
                hotkeyRules[i].enabled = set.contains(hotkeyRules[i].id)
            }
        }
        if !d.bool(forKey: "mb_df_tp_optin_v2") {
            for i in hotkeyRules.indices where hotkeyRules[i].isGesture {
                hotkeyRules[i].enabled = false
            }
            d.set(true, forKey: "mb_df_tp_optin_v2")
            d.set(hotkeyRules.filter(\.enabled).map(\.id), forKey: "mb_df_enabled_rules")
        }
        if let lang = d.string(forKey: "mb_df_app_language") {
            isEnglish = (lang == "en")
        }
        d.removeObject(forKey: "mb_df_pinned_data_nic")
        if let peer = d.string(forKey: "mb_df_manual_peer"), !peer.isEmpty {
            manualPeerIp = peer
        }
        if let savedPos = d.dictionary(forKey: "mb_df_saved_display_positions") as? [String: [Double]] {
            savedDisplayPositions = savedPos
            for (id, coords) in savedPos where coords.count == 2 {
                syncedRemotePositions[id] = CGPoint(x: coords[0], y: coords[1])
            }
        }
    }

    private func savePrefs() {
        guard !isLoadingPrefs else { return }
        let d = UserDefaults.standard
        d.set(transferSchemeMode.rawValue, forKey: "mb_df_scheme")
        d.set(portalEffectStyle.rawValue, forKey: "mb_df_style")
        d.set(portalEdgeSide.rawValue, forKey: "mb_df_edge")
        d.set(portalEdgeOffset, forKey: "mb_df_offset")
        d.set(portalOverlayEnabled, forKey: "mb_df_overlay")
        d.set(multipathEnabled, forKey: "mb_df_multipath")
        d.set(kvmEnabled, forKey: "mb_df_kvm_enabled")
        d.set(edgeSwitchEnabled, forKey: "mb_df_edge_switch")
        d.set(hotkeySwitchEnabled, forKey: "mb_df_hotkey_switch")
        d.set(clipboardSyncEnabled, forKey: "mb_df_clip_sync")
        d.set(kvmControlMode.rawValue, forKey: "mb_df_ctrl_mode")
        d.set(keymapProfile.rawValue, forKey: "mb_df_keymap")
        d.set(hotkeyRules.filter(\.enabled).map(\.id), forKey: "mb_df_enabled_rules")
        d.set(manualPeerIp, forKey: "mb_df_manual_peer")
        d.set(isEnglish ? "en" : "zh", forKey: "mb_df_app_language")
        if !savedDisplayPositions.isEmpty {
            d.set(savedDisplayPositions, forKey: "mb_df_saved_display_positions")
        }
    }

    func saveDisplayArrangement(silent: Bool = false) {
        for n in displayNodes {
            syncedRemotePositions[n.id] = CGPoint(x: n.canvasX, y: n.canvasY)
            savedDisplayPositions[n.id] = [Double(n.canvasX), Double(n.canvasY)]
        }
        savePrefs()
        UserDefaults.standard.synchronize()
        if !silent {
            scheduleTopologySyncBroadcast()
            appendLog("[Display] 已保存当前屏幕排列位置 (\(displayNodes.count) 块)")
            let badge = t("已保存位置", "Layout Saved")
            displaySaveStatusText = badge
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                if self?.displaySaveStatusText == badge {
                    self?.displaySaveStatusText = ""
                }
            }
        }
    }

    func saveAllSettingsManual() {
        savePrefs()
        broadcastConfigSync()
        UserDefaults.standard.synchronize()
        appendLog("[Config] 已保存快捷键映射与控制设置")
        let badge = t("已保存设置", "Settings Saved")
        settingsSaveStatusText = badge
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.settingsSaveStatusText == badge {
                self?.settingsSaveStatusText = ""
            }
        }
    }

    // MARK: - Direct Screen-Edge Cube Dragging (1:1 Screen-Locked, Zero Jump)

    func beginCubeScreenDrag() {
        cubeDragStartMouse = NSEvent.mouseLocation
        cubeDragStartOffset = portalEdgeOffset
    }

    func updateCubeScreenDrag() {
        if cubeDragStartMouse == nil {
            beginCubeScreenDrag()
            return
        }
        guard let start = cubeDragStartMouse else { return }
        let cur = NSEvent.mouseLocation
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let idx = min(max(0, portalMonitorIndex), screens.count - 1)
        let frame = screens[idx].visibleFrame
        let panelSz = PortalOverlayController.shared.currentPanelSize

        switch portalEdgeSide {
        case .left, .right:
            let travel = max(80.0, Double(frame.height - panelSz.height))
            let deltaRatio = Double(cur.y - start.y) / travel
            portalEdgeOffset = min(max(0.05, cubeDragStartOffset + deltaRatio), 0.95)
        case .top, .bottom:
            let travel = max(80.0, Double(frame.width - panelSz.width))
            let deltaRatio = Double(cur.x - start.x) / travel
            portalEdgeOffset = min(max(0.05, cubeDragStartOffset + deltaRatio), 0.95)
        }
    }

    func endCubeScreenDrag() {
        cubeDragStartMouse = nil
        savePrefs()
    }

    func adjustCubeOffsetByScreenDelta(_ translation: CGSize) {
        updateCubeScreenDrag()
    }

    // MARK: - Multi-NIC Discovery & Smart Control/Data Plane Scoring

    private var disabledMultipathNics: Set<String> = []
    private var lastRecommendedControlKey: String?
    private var lastArrangeCanvasSize: CGSize = CGSize(width: 680, height: 360)

    func toggleNicMultipath(_ item: NicChannelItem) {
        let key = item.channelKey
        let isCurrentlyDisabled = disabledMultipathNics.contains(key)
        if isCurrentlyDisabled {
            disabledMultipathNics.remove(key)
            appendLog("[Route] 已启用网卡「\(item.ifaceName) (\(item.localIp))」参与多网卡并发")
        } else {
            disabledMultipathNics.insert(key)
            appendLog("[Route] 已将网卡「\(item.ifaceName) (\(item.localIp))」移出并发池")
        }
        refreshAllNicChannels()
    }

    func refreshAllNicChannels() {
        accessibilityGranted = MacKvmController.shared.hasAccessibilityPermission
        let liveLinks = DeskflowTransport.shared.activeLinksSnapshot()
        peerConnectedCount = liveLinks.count

        var discovered: [NicChannelItem] = []

        // 1. Add all real live PeerLinkSessions first (keyed per local<->peer channel so multi-peer links on one NIC all display)
        for link in liveLinks {
            let resolvedLocal = link.isUsbBridge
                ? ((link.localIp == "auto" || link.localIp.isEmpty) ? usbNcmLocalIp : link.localIp)
                : link.localIp
            let canonKey = NicChannelItem.canonicalChannelKey(ifaceName: link.ifaceName, localIp: resolvedLocal, isUsb: link.isUsbBridge, peerIp: link.peerIp)
            if discovered.contains(where: { $0.id == canonKey }) {
                continue
            }
            let isDisc = DeskflowTransport.shared.isIfaceDisconnected(link.ifaceName)
                || DeskflowTransport.shared.isIfaceDisconnected(resolvedLocal)
                || DeskflowTransport.shared.isIfaceDisconnected(canonKey)
                || (link.isUsbBridge && DeskflowTransport.shared.isIfaceDisconnected("usb"))
            let mpEnabled = !disabledMultipathNics.contains(canonKey)
            let label = link.isUsbBridge
                ? t("USB-C 直连（未加密）", "USB-C Direct (Raw P2P)")
                : t("局域网通道 (\(link.ifaceName) · TLS 1.3 已连接)", "LAN (\(link.ifaceName) · TLS 1.3)")
            discovered.append(
                NicChannelItem(
                    id: canonKey,
                    ifaceName: link.ifaceName,
                    displayName: label,
                    localIp: resolvedLocal,
                    peerIp: link.peerIp,
                    isUsbBridge: link.isUsbBridge,
                    online: !isDisc,
                    manuallyDisconnected: isDisc,
                    rttMs: link.rttMs ?? (link.isUsbBridge ? 0.35 : 1.50),
                    estBandwidthMbps: link.estBandwidthMbps,
                    securityMode: link.isUsbBridge ? .trustedUsbP2P : .lanTls13,
                    isRecommendedControl: false,
                    isRecommendedData: false,
                    enabledForMultipath: mpEnabled
                )
            )
        }

        // 2. Also list local standby NICs not yet paired with an active link
        let localNics = DeskflowTransport.shared.enumerateLocalIPv4()
        usbNcmDetected = localNics.contains(where: { MacBridgeSubnet.isUsbBridgeIp($0.ip) })
        for nic in localNics {
            let isUsb = MacBridgeSubnet.isUsbBridgeIp(nic.ip)
            let canonKey = NicChannelItem.canonicalChannelKey(ifaceName: nic.iface, localIp: nic.ip, isUsb: isUsb)
            if discovered.contains(where: { $0.isUsbBridge == isUsb && (isUsb || $0.localIp == nic.ip || $0.id == canonKey) }) { continue }

            let isDisc = DeskflowTransport.shared.isIfaceDisconnected(nic.iface)
                || DeskflowTransport.shared.isIfaceDisconnected(nic.ip)
                || (isUsb && DeskflowTransport.shared.isIfaceDisconnected("usb"))
            let mpEnabled = !disabledMultipathNics.contains(canonKey)
            let isWifi = (nic.iface == "en0")
            discovered.append(
                NicChannelItem(
                    id: canonKey,
                    ifaceName: nic.iface,
                    displayName: isDisc
                        ? t("\(nic.iface) (已手动断开 · 点击重连恢复)", "\(nic.iface) (Disconnected · Click Reconnect)")
                        : (isUsb ? t("USB-C 直连（\(nic.iface)）", "USB-C Direct (\(nic.iface))")
                           : (isWifi ? t("Wi-Fi 无线网卡 (\(nic.iface) · 在线)", "Wi-Fi (\(nic.iface) · Online)")
                              : t("有线/扩展网卡 (\(nic.iface) · 在线)", "Wired Ethernet (\(nic.iface) · Online)"))),
                    localIp: nic.ip,
                    peerIp: isUsb ? usbNcmPeerIp : manualPeerIp,
                    isUsbBridge: isUsb,
                    online: false,
                    manuallyDisconnected: isDisc,
                    rttMs: nil,
                    estBandwidthMbps: isUsb ? 2400.0 : (isWifi ? 1200.0 : 2500.0),
                    securityMode: isUsb ? .trustedUsbP2P : .lanTls13,
                    isRecommendedControl: false,
                    isRecommendedData: false,
                    enabledForMultipath: mpEnabled
                )
            )
        }

        if !discovered.contains(where: { $0.id == "usb" }) {
            let isUsbDisc = DeskflowTransport.shared.isIfaceDisconnected("USB-C NCM")
                || DeskflowTransport.shared.isIfaceDisconnected(usbNcmLocalIp)
                || DeskflowTransport.shared.isIfaceDisconnected("usb")
            let mpEnabled = !disabledMultipathNics.contains("usb")
            discovered.append(
                NicChannelItem(
                    id: "usb",
                    ifaceName: "USB-C NCM",
                    displayName: isUsbDisc
                        ? t("USB-C 直连引擎 (已手动断开)", "USB-C Direct Engine (Paused)")
                        : t("USB-C 直连（未连接）", "USB-C Direct (Standby)"),
                    localIp: usbNcmLocalIp,
                    peerIp: usbNcmPeerIp,
                    isUsbBridge: true,
                    online: false,
                    manuallyDisconnected: isUsbDisc,
                    rttMs: nil,
                    estBandwidthMbps: 2400.0,
                    securityMode: .trustedUsbP2P,
                    isRecommendedControl: false,
                    isRecommendedData: false,
                    enabledForMultipath: mpEnabled
                )
            )
        }

        // Fixed deterministic row ordering so rows never jump around on RTT jitter
        discovered.sort { a, b in
            if a.isUsbBridge != b.isUsbBridge { return a.isUsbBridge }
            let aWifi = a.ifaceName == "en0"
            let bWifi = b.ifaceName == "en0"
            if aWifi != bWifi { return !aWifi }
            return a.localIp < b.localIp
        }

        // Update USB-C Connection Progress Bar & MacBridge-style Telemetry
        let liveUsbLink = liveLinks.first(where: { $0.isUsbBridge })
        usbRxFrames = liveUsbLink?.rxFrames ?? 0
        usbTxFrames = liveUsbLink?.txFrames ?? 0
        let usbIfaces = localNics.filter { MacBridgeSubnet.isUsbBridgeIp($0.ip) }
        let usbIfaceName = liveUsbLink?.ifaceName ?? usbIfaces.first?.iface ?? t("未接入", "Unplugged")

        if let liveUsb = discovered.first(where: { $0.isUsbBridge && $0.online && !$0.manuallyDisconnected }) {
            usbConnectProgress = 1.0
            let rttStr = liveUsb.rttMs.map { String(format: "%.2f ms", $0) } ?? "0.35 ms"
            usbHeadline = t("USB-C 直连隧道已运行", "USB-C Direct Tunnel Active")
            usbSubline = t("双向控制与文件直传已就绪（点对点免加密 · \(liveUsb.localIp) ↔ \(liveUsb.peerIp)）", "Bidirectional KVM & file transfer ready (P2P Raw · \(liveUsb.localIp) ↔ \(liveUsb.peerIp))")
            usbDriverStatusText = t("Apple NCM (\(usbIfaceName)) · 已握手", "Apple NCM (\(usbIfaceName)) · Connected")
            usbStatusText = t("USB-C 点对点直连已就绪 (\(liveUsb.localIp) ↔ \(liveUsb.peerIp) · 延迟 \(rttStr))", "USB-C Direct ready (\(liveUsb.localIp) ↔ \(liveUsb.peerIp) · RTT \(rttStr))")
            usbActionHint = t("隧道已激活 · RX \(usbRxFrames) 帧 / TX \(usbTxFrames) 帧 · RTT \(rttStr)", "Tunnel active · RX \(usbRxFrames) / TX \(usbTxFrames) · RTT \(rttStr)")
        } else if let pausedUsb = discovered.first(where: { $0.isUsbBridge && $0.manuallyDisconnected }) {
            usbConnectProgress = 0.0
            usbHeadline = t("USB-C 通道已手动断开", "USB-C Channel Disconnected")
            usbSubline = t("点击右侧「立即连接 USB」可随时恢复点对点直连", "Click Reconnect on the right to restore USB-C P2P anytime")
            usbDriverStatusText = usbNcmDetected
                ? t("Apple NCM (\(usbIfaceName)) · 已暂停", "Apple NCM (\(usbIfaceName)) · Paused")
                : t("待插线 / 已暂停", "Unplugged / Paused")
            usbStatusText = t("已暂停：\(pausedUsb.localIp) ↔ \(pausedUsb.peerIp)", "Paused: \(pausedUsb.localIp) ↔ \(pausedUsb.peerIp)")
            usbActionHint = t("通道处于断开状态，不影响 LAN/Wi-Fi 并发通道", "USB paused; LAN/Wi-Fi channels keep running")
        } else if usbNcmDetected {
            usbConnectProgress = min(0.92, max(0.32, usbConnectProgress + 0.08))
            usbHeadline = t("正在建立 USB-C 直连...", "Establishing USB-C Direct Link...")
            usbSubline = t("本机 \(usbIfaceName) 已获取 10.13.37.x，正在等待 Windows 端 NCM 驱动与端口就绪", "Local \(usbIfaceName) assigned 10.13.37.x; waiting for Windows NCM driver & port")
            usbDriverStatusText = t("Apple NCM (\(usbIfaceName)) · 就绪", "Apple NCM (\(usbIfaceName)) · Ready")
            usbStatusText = t("已识别 USB-C NCM 虚拟网卡，正在与 Windows 端握手建连 (10.13.37.x)...", "USB-C NCM detected, handshaking with Windows (10.13.37.x)...")
            usbActionHint = t("若 Windows 端刚启动，请点击 Windows 端「一键连接 USB」完成驱动绑定", "Click Start USB Direct on Windows to finish WinUSB driver binding")
        } else {
            if !usbActionInProgress { usbConnectProgress = 0.0 }
            usbHeadline = t("等待 USB-C 直连", "Waiting for USB-C Direct Link")
            usbSubline = t("插入 USB-C 数据线，并在 Windows 端启动 USB 直连，Mac 端无需额外驱动即可自动协商", "Plug in a USB-C cable and start USB Direct on Windows. macOS works driver-free.")
            usbDriverStatusText = t("未检测到 USB-C NCM 网口", "No USB-C NCM interface detected")
            usbStatusText = t("待插线：插入 USB-C 数据线并开启 Windows 端 USB 引擎后将自动连接", "Standby: connect USB-C cable and start Windows USB tunnel")
            if !usbActionInProgress {
                usbActionHint = t("Mac 端原生支持 USB-C NCM 免驱直连，无需清理或安装驱动", "macOS natively supports driver-free USB-C NCM")
            }
        }

        // Score online channels with 0.5ms hysteresis to avoid recommendation pill flapping
        let pool = globalPaused ? [] : discovered.filter { $0.online && !$0.manuallyDisconnected }
        let bestCand = pool.min(by: { ($0.rttMs ?? 999) < ($1.rttMs ?? 999) })
        var minRttId = bestCand?.id
        if let prevId = lastRecommendedControlKey,
           let prevItem = pool.first(where: { $0.id == prevId }),
           let cand = bestCand,
           cand.id != prevId {
            let prevRtt = prevItem.rttMs ?? 999
            let candRtt = cand.rttMs ?? 999
            if (prevRtt - candRtt) < 0.5 && !(cand.isUsbBridge && !prevItem.isUsbBridge) {
                minRttId = prevId
            }
        }
        lastRecommendedControlKey = minRttId
        let maxBwId = pool.max(by: { $0.estBandwidthMbps < $1.estBandwidthMbps })?.id

        for i in discovered.indices {
            discovered[i].isRecommendedControl = (minRttId != nil && discovered[i].id == minRttId)
            discovered[i].isRecommendedData = (maxBwId != nil && discovered[i].id == maxBwId)
        }

        if nicChannels != discovered {
            nicChannels = discovered
        }
    }

    var activeControlChannelName: String {
        if globalPaused {
            return t("已断开", "Paused")
        }
        if let ctrl = nicChannels.first(where: { $0.online && !$0.manuallyDisconnected && $0.isRecommendedControl })
            ?? nicChannels.first(where: { $0.online && !$0.manuallyDisconnected }) {
            let ms = ctrl.rttMs.map { String(format: "%.2fms", $0) } ?? t("已连接", "Online")
            return "\(ctrl.ifaceName) (\(ms))"
        }
        return t("未连接", "Disconnected")
    }

    var currentControlLinkRttMs: Double? {
        guard !globalPaused else { return nil }
        return nicChannels.first(where: { $0.online && $0.isRecommendedControl && !$0.manuallyDisconnected })?.rttMs
            ?? nicChannels.filter { $0.online && !$0.manuallyDisconnected }.compactMap(\.rttMs).min()
    }

    var activeDataChannelSummary: String {
        if globalPaused {
            return t("已断开", "Paused")
        }
        let active = nicChannels.filter { $0.online && !$0.manuallyDisconnected && $0.enabledForMultipath }
        if multipathEnabled && active.count > 1 {
            let sumMbps = active.reduce(0.0) { $0 + $1.estBandwidthMbps }
            return isEnglish
                ? String(format: "%d-NIC Multipath (%.0f Mbps)", active.count, sumMbps)
                : String(format: "%d通道并发 (%.0f Mbps)", active.count, sumMbps)
        }
        if let best = active.max(by: { $0.estBandwidthMbps < $1.estBandwidthMbps })
            ?? nicChannels.filter({ $0.online && !$0.manuallyDisconnected }).max(by: { $0.estBandwidthMbps < $1.estBandwidthMbps }) {
            return "\(best.ifaceName) (\(Int(best.estBandwidthMbps)) Mbps)"
        }
        return t("未连接", "Disconnected")
    }

    var effectiveTransferMbps: Double {
        let enabled = nicChannels.filter { $0.online && $0.enabledForMultipath }
        if multipathEnabled && enabled.count > 1 {
            return max(400, enabled.reduce(0.0) { $0 + $1.estBandwidthMbps })
        }
        return max(400, enabled.map(\.estBandwidthMbps).max() ?? nicChannels.map(\.estBandwidthMbps).max() ?? 2400)
    }

    // MARK: - Per-Monitor Independent 2D Spatial Topology Discovery & Cross-OS Sync

    private var topologySyncWorkItem: DispatchWorkItem?
    private var syncedRemotePositions: [String: CGPoint] = [:]

    func refreshIndependentDisplays() {
        let oldPositions = Dictionary(uniqueKeysWithValues: displayNodes.map { ($0.id, CGPoint(x: $0.canvasX, y: $0.canvasY)) })
        var nodes: [IndependentDisplayNode] = []
        let screens = NSScreen.screens

        // Build Mac display tiles strictly matching macOS System Settings logical bounds & proportions
        var macEntries: [(idx: Int, name: String, w: Int, h: Int, scale: Double, bounds: CGRect)] = []
        for (idx, scr) in screens.enumerated() {
            let w = Int(scr.frame.width * scr.backingScaleFactor)
            let h = Int(scr.frame.height * scr.backingScaleFactor)
            let did = (scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
            let cgRect = CGDisplayBounds(did)
            macEntries.append((idx, scr.localizedName, max(640, w), max(480, h), Double(scr.backingScaleFactor), cgRect))
        }

        let minMacX = macEntries.map { Double($0.bounds.minX) }.min() ?? 0.0
        let minMacY = macEntries.map { Double($0.bounds.minY) }.min() ?? 0.0
        let originX: CGFloat = 100
        let originY: CGFloat = 100
        let layoutScale: Double = 0.068

        for entry in macEntries {
            let id = "mac_disp_\(entry.idx)"
            var node = IndependentDisplayNode(
                id: id,
                displayIndex: entry.idx,
                name: entry.name.isEmpty ? "Mac Display #\(entry.idx + 1)" : entry.name,
                osKind: .mac,
                widthPx: entry.w,
                heightPx: entry.h,
                scaleFactor: entry.scale,
                isPrimary: entry.idx == 0,
                boundsX: Int(entry.bounds.origin.x),
                boundsY: Int(entry.bounds.origin.y),
                canvasX: originX + CGFloat(((Double(entry.bounds.minX) - minMacX) * layoutScale).rounded()),
                canvasY: originY + CGFloat(((Double(entry.bounds.minY) - minMacY) * layoutScale).rounded())
            )

            if let synced = syncedRemotePositions[id] {
                node.canvasX = synced.x
                node.canvasY = synced.y
            } else if let saved = oldPositions[id] {
                node.canvasX = saved.x
                node.canvasY = saved.y
            }
            nodes.append(node)
        }
        MacKvmController.shared.syncInjectorState(kvmEnabled: kvmEnabled, controlMode: kvmControlMode)

        // Only render remote Windows displays AFTER peer actually connects & sends real monitor list!
        if !remotePeerMonitors.isEmpty {
            let macMaxRight = nodes.map { $0.canvasX + $0.aspectWidth }.max() ?? (originX + 180)
            let primaryMacY = nodes.first(where: { $0.isPrimary })?.canvasY ?? nodes.first?.canvasY ?? originY
            let minWinX = remotePeerMonitors.map { Double($0.boundsX) }.min() ?? 0.0
            let minWinY = remotePeerMonitors.map { Double($0.boundsY) }.min() ?? 0.0

            for rm in remotePeerMonitors {
                var node = IndependentDisplayNode(
                    id: rm.id,
                    displayIndex: max(0, rm.displayIndex - 1),
                    name: rm.name,
                    osKind: .windows,
                    widthPx: rm.widthPx,
                    heightPx: rm.heightPx,
                    scaleFactor: rm.scaleFactor,
                    isPrimary: rm.isPrimary,
                    boundsX: rm.boundsX,
                    boundsY: rm.boundsY,
                    canvasX: macMaxRight + CGFloat(((Double(rm.boundsX) - minWinX) * layoutScale).rounded()),
                    canvasY: primaryMacY + CGFloat(((Double(rm.boundsY) - minWinY) * layoutScale).rounded())
                )
                if let synced = syncedRemotePositions[rm.id] {
                    node.canvasX = synced.x
                    node.canvasY = synced.y
                } else if let saved = oldPositions[rm.id] {
                    node.canvasX = saved.x
                    node.canvasY = saved.y
                }
                nodes.append(node)
            }
        }

        let allHaveSavedPos = !nodes.isEmpty && nodes.allSatisfy { savedDisplayPositions[$0.id]?.count == 2 }
        if !allHaveSavedPos {
            resolveDisplayOverlaps(&nodes)
            centerDisplayCluster(&nodes, canvasSize: lastArrangeCanvasSize)
        } else if remotePeerMonitors.isEmpty {
            // Peer not connected yet: center local monitors visually WITHOUT mutating savedDisplayPositions/syncedRemotePositions
            centerDisplayCluster(&nodes, canvasSize: lastArrangeCanvasSize, persistToSynced: false)
        }
        displayNodes = nodes
        if selectedDisplayId == nil || !displayNodes.contains(where: { $0.id == selectedDisplayId }) {
            selectedDisplayId = displayNodes.first?.id
        }
        syncPortalEdgeFromDisplayLayout()
    }

    /// Guarantees no two display tiles overlap on the 2D canvas.
    private func resolveDisplayOverlaps(_ nodes: inout [IndependentDisplayNode], anchoredId: String? = nil) {
        guard nodes.count > 1 else { return }
        for _ in 0..<6 {
            var changed = false
            for i in nodes.indices {
                for j in nodes.indices where i != j {
                    if nodes[j].id == anchoredId { continue }
                    let rA = nodes[i].rect.insetBy(dx: 2, dy: 2)
                    let rB = nodes[j].rect.insetBy(dx: 2, dy: 2)
                    if rA.intersects(rB) {
                        let a = nodes[i].rect
                        let b = nodes[j].rect
                        let pushRight = a.maxX - b.minX
                        let pushLeft  = b.maxX - a.minX
                        let pushDown  = a.maxY - b.minY
                        let pushUp    = b.maxY - a.minY
                        let minPush = min(min(pushRight, pushLeft), min(pushDown, pushUp))
                        if minPush == pushRight {
                            nodes[j].canvasX = a.maxX
                        } else if minPush == pushLeft {
                            nodes[j].canvasX = a.minX - b.width
                        } else if minPush == pushDown {
                            nodes[j].canvasY = a.maxY
                        } else {
                            nodes[j].canvasY = a.minY - b.height
                        }
                        changed = true
                    }
                }
            }
            if !changed { break }
        }
    }

    /// Centers the entire multi-monitor cluster inside the Arrange Displays canvas while preserving exact relative arrangement.
    func centerDisplayCluster(_ nodes: inout [IndependentDisplayNode], canvasSize: CGSize, persistToSynced: Bool = true) {
        guard !nodes.isEmpty else { return }
        let cw = max(560, canvasSize.width)
        let ch = max(320, canvasSize.height)
        let minX = nodes.map(\.canvasX).min() ?? 0
        let maxX = nodes.map { $0.canvasX + $0.aspectWidth }.max() ?? cw
        let minY = nodes.map(\.canvasY).min() ?? 0
        let maxY = nodes.map { $0.canvasY + $0.aspectHeight }.max() ?? ch

        let clusterMidX = (minX + maxX) * 0.5
        let clusterMidY = (minY + maxY) * 0.5
        let dx = (cw * 0.5) - clusterMidX
        let dy = (ch * 0.5) - clusterMidY

        for i in nodes.indices {
            nodes[i].canvasX = round(nodes[i].canvasX + dx)
            nodes[i].canvasY = round(nodes[i].canvasY + dy)
            if persistToSynced {
                syncedRemotePositions[nodes[i].id] = CGPoint(x: nodes[i].canvasX, y: nodes[i].canvasY)
            }
        }
    }

    func centerCurrentDisplaysNow(canvasSize: CGSize? = nil) {
        if let sz = canvasSize { lastArrangeCanvasSize = sz }
        var nodes = displayNodes
        let allHaveSavedPos = !nodes.isEmpty && nodes.allSatisfy { savedDisplayPositions[$0.id]?.count == 2 }
        if !allHaveSavedPos {
            resolveDisplayOverlaps(&nodes)
            centerDisplayCluster(&nodes, canvasSize: lastArrangeCanvasSize)
            displayNodes = nodes
        } else if remotePeerMonitors.isEmpty {
            // Peer not connected yet: center local monitors visually WITHOUT overwriting savedDisplayPositions
            centerDisplayCluster(&nodes, canvasSize: lastArrangeCanvasSize, persistToSynced: false)
            displayNodes = nodes
        }
        syncPortalEdgeFromDisplayLayout()
    }

    func finishDisplayDrag(id: String, canvasSize: CGSize) {
        lastArrangeCanvasSize = canvasSize
        var nodes = displayNodes
        // Apply fine magnetic alignment (<= 7px) ONLY when releasing the drag, so dragging itself is 1:1 silky smooth
        if let idx = nodes.firstIndex(where: { $0.id == id }) {
            let w = nodes[idx].aspectWidth
            let h = nodes[idx].aspectHeight
            var tx = nodes[idx].canvasX
            var ty = nodes[idx].canvasY
            let snapThreshold: CGFloat = 7.0
            for (otherIdx, other) in nodes.enumerated() where otherIdx != idx {
                let ox = other.canvasX
                let oy = other.canvasY
                let ow = other.aspectWidth
                let oh = other.aspectHeight
                if abs((tx + w) - ox) < snapThreshold { tx = ox - w }
                else if abs(tx - (ox + ow)) < snapThreshold { tx = ox + ow }
                else if abs(tx - ox) < snapThreshold { tx = ox }
                else if abs((tx + w) - (ox + ow)) < snapThreshold { tx = ox + ow - w }

                if abs((ty + h) - oy) < snapThreshold { ty = oy - h }
                else if abs(ty - (oy + oh)) < snapThreshold { ty = oy + oh }
                else if abs(ty - oy) < snapThreshold { ty = oy }
                else if abs((ty + h) - (oy + oh)) < snapThreshold { ty = oy + oh - h }
            }
            nodes[idx].canvasX = tx
            nodes[idx].canvasY = ty
            syncedRemotePositions[id] = CGPoint(x: tx, y: ty)
        }
        resolveDisplayOverlaps(&nodes, anchoredId: id)
        centerDisplayCluster(&nodes, canvasSize: canvasSize)
        displayNodes = nodes
        syncPortalEdgeFromDisplayLayout()
        saveDisplayArrangement(silent: true)
        scheduleTopologySyncBroadcast()
    }

    /// Automatically moves the file-transfer edge portal to the Mac monitor & edge facing the Windows display(s).
    func syncPortalEdgeFromDisplayLayout() {
        let macNodes = displayNodes.filter { $0.osKind == .mac }
        let winNodes = displayNodes.filter { $0.osKind == .windows }
        guard !macNodes.isEmpty, !winNodes.isEmpty else { return }

        var bestMac = macNodes[0]
        var bestWin = winNodes[0]
        var bestDist = CGFloat.greatestFiniteMagnitude

        for m in macNodes {
            for w in winNodes {
                let d = hypot(w.rect.midX - m.rect.midX, w.rect.midY - m.rect.midY)
                if d < bestDist {
                    bestDist = d
                    bestMac = m
                    bestWin = w
                }
            }
        }

        let dx = bestWin.rect.midX - bestMac.rect.midX
        let dy = bestWin.rect.midY - bestMac.rect.midY
        let targetEdge: ScreenEdgeSide
        if abs(dx) >= abs(dy) {
            targetEdge = dx >= 0 ? .right : .left
        } else {
            targetEdge = dy >= 0 ? .bottom : .top
        }

        if portalMonitorIndex != bestMac.displayIndex {
            portalMonitorIndex = bestMac.displayIndex
        }
        if portalEdgeSide != targetEdge {
            portalEdgeSide = targetEdge
        }
        PortalOverlayController.shared.repositionPanel()
    }

    func resetDisplayArrangement2D() {
        syncedRemotePositions.removeAll()
        savedDisplayPositions.removeAll()
        displayNodes.removeAll()
        UserDefaults.standard.removeObject(forKey: "mb_df_saved_display_positions")
        refreshIndependentDisplays()
        saveDisplayArrangement(silent: true)
        scheduleTopologySyncBroadcast()
    }

    /// Updates a display's 2D spatial position continuously 1:1 during drag without steppy mid-drag snapping.
    func updateDisplayNodePosition(id: String, x: CGFloat, y: CGFloat, canvasSize: CGSize = CGSize(width: 680, height: 350)) {
        lastArrangeCanvasSize = canvasSize
        guard let idx = displayNodes.firstIndex(where: { $0.id == id }) else { return }
        let w = displayNodes[idx].aspectWidth
        let h = displayNodes[idx].aspectHeight

        let targetX = min(max(12, x), max(20, canvasSize.width - w - 12))
        let targetY = min(max(12, y), max(20, canvasSize.height - h - 12))

        displayNodes[idx].canvasX = targetX
        displayNodes[idx].canvasY = targetY
        syncedRemotePositions[id] = CGPoint(x: targetX, y: targetY)
    }

    private func scheduleTopologySyncBroadcast() {
        topologySyncWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.sendTopologySyncNow()
            }
        }
        topologySyncWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    func sendTopologySyncNow() {
        let entries = displayNodes.map {
            WireMonitorLayoutEntry(
                id: $0.id,
                canvasX: Double($0.canvasX),
                canvasY: Double($0.canvasY),
                displayIndex: $0.displayIndex + 1,
                name: $0.name,
                osKind: $0.osKind.rawValue,
                widthPx: $0.widthPx,
                heightPx: $0.heightPx,
                scaleFactor: $0.scaleFactor,
                isPrimary: $0.isPrimary
            )
        }
        guard !entries.isEmpty,
              let frame = WireFrameCodec.encodeJSON(
                type: .topologyUpdate,
                value: WireTopologySyncPayload(
                    senderOs: "macOS",
                    timestamp: Date().timeIntervalSince1970,
                    items: entries
                )
              ) else { return }
        DeskflowTransport.shared.sendControlFrame(frame)
    }

    private func applyRemoteTopologySync(_ payload: WireTopologySyncPayload) {
        var addedRemote = false
        for entry in payload.items {
            let pt = CGPoint(x: entry.canvasX, y: entry.canvasY)
            syncedRemotePositions[entry.id] = pt
            if let idx = displayNodes.firstIndex(where: { $0.id == entry.id }) {
                displayNodes[idx].canvasX = pt.x
                displayNodes[idx].canvasY = pt.y
            } else if entry.osKind == "Windows",
                      let name = entry.name,
                      let w = entry.widthPx,
                      let h = entry.heightPx {
                let dIdx = max(1, entry.displayIndex ?? 1)
                if !remotePeerMonitors.contains(where: { $0.id == entry.id }) {
                    remotePeerMonitors.append(
                        WireMonitorDto(
                            id: entry.id,
                            displayIndex: dIdx,
                            name: name,
                            osKind: "Windows",
                            widthPx: w,
                            heightPx: h,
                            scaleFactor: entry.scaleFactor ?? 1.0,
                            isPrimary: entry.isPrimary ?? (dIdx == 1),
                            boundsX: 0,
                            boundsY: 0
                        )
                    )
                    addedRemote = true
                }
            }
        }
        if addedRemote {
            refreshIndependentDisplays()
        } else {
            var nodes = displayNodes
            resolveDisplayOverlaps(&nodes)
            displayNodes = nodes
            syncPortalEdgeFromDisplayLayout()
        }
        if payload.items.count > 1 && payload.items.count >= displayNodes.count {
            saveDisplayArrangement(silent: true)
        }
        appendLog("[Topology] 已实时同步来自 \(payload.senderOs) 的屏幕空间布局 (\(payload.items.count) 块)")
    }

    func moveDisplay(from src: Int, to dst: Int) {
        guard displayNodes.indices.contains(src), displayNodes.indices.contains(dst), src != dst else { return }
        let item = displayNodes.remove(at: src)
        displayNodes.insert(item, at: dst)
    }

    func cleanExitMac() {
        prepareForCleanExitAsync {
            NSApp.terminate(nil)
        }
    }

    func prepareForCleanExitAsync(onComplete: @escaping @MainActor () -> Void) {
        if MacKvmController.shared.hasAccessibilityPermission {
            MacKvmController.shared.setRemoteFocus(false, notifyPeer: false)
        }
        MacKvmController.shared.stopTap()
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        if let mon = fallbackKeyMonitor {
            NSEvent.removeMonitor(mon)
            fallbackKeyMonitor = nil
        }
        savePrefs()
        UserDefaults.standard.synchronize()
        PortalOverlayController.shared.closeForExit()
        DeskflowTransport.shared.stop()

        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = ["-TERM", "omniflow-usb"]
            try? p.run()
            p.waitUntilExit()
            Task { @MainActor in
                onComplete()
            }
        }
    }

    /// Flashes large screen numbers on BOTH Mac & Windows monitors simultaneously so multi-monitor users can identify each screen
    func flashIdentifyScreens() {
        flashLocalScreenNumbersOnly()
        if let frame = WireFrameCodec.encodeJSON(
            type: .semanticHotkey,
            value: WireSemanticHotkeyPayload(action: "IDENTIFY_SCREENS")
        ) {
            DeskflowTransport.shared.sendControlFrame(frame)
        }
        appendLog("[Display] 已在 Mac 与 Windows 双端同步点亮屏幕编号")
    }

    func flashLocalScreenNumbersOnly() {
        for (idx, screen) in NSScreen.screens.enumerated() {
            let w = NSPanel(
                contentRect: NSRect(
                    x: screen.frame.midX - 90,
                    y: screen.frame.midY - 90,
                    width: 180,
                    height: 180
                ),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = .screenSaver
            w.contentView = NSHostingView(
                rootView: ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(red: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x1E / 255.0).opacity(0.95))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0), lineWidth: 2))
                    VStack(spacing: 4) {
                        Text("\(idx + 1)")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundColor(.white)
                        Text(screen.localizedName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(white: 0.72))
                    }
                }
            )
            w.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                w.orderOut(nil)
            }
        }
    }

    // MARK: - Real File Drop & Interactive Portal Effects (Edge Wall Pass-Through & Mini Cube)

    func estimatedThroughputBytesPerSec() -> Double {
        let links = DeskflowTransport.shared.activeLinksSnapshot()
        let enabledKeys = Set(nicChannels.filter(\.enabledForMultipath).map(\.channelKey))
        let filtered = links.filter { l in
            let key = NicChannelItem.canonicalChannelKey(ifaceName: l.ifaceName, localIp: l.localIp, isUsb: l.isUsbBridge, peerIp: l.peerIp)
            return enabledKeys.contains(key) || enabledKeys.contains(l.localIp)
        }
        let pool = filtered.isEmpty ? links : filtered
        guard !pool.isEmpty else { return 0 }

        func linkBytesPerSec(_ l: PeerLinkSession) -> Double {
            if let measured = l.measuredBytesPerSec, measured > 64 * 1024 { return measured }
            if l.isUsbBridge { return DragHandoffPolicy.fallbackUsbBytesPerSec }
            return l.ifaceName == "en0" ? DragHandoffPolicy.fallbackWifiBytesPerSec : DragHandoffPolicy.fallbackLanBytesPerSec
        }

        if multipathEnabled && pool.count > 1 {
            return pool.reduce(0.0) { $0 + linkBytesPerSec($1) }
        }
        return pool.map(linkBytesPerSec).max() ?? DragHandoffPolicy.fallbackLanBytesPerSec
    }

    func evaluateDragForEdgePrompt(for url: URL) {
        evaluateDragForEdgePrompt(urls: [url])
    }

    func evaluateDragForEdgePrompt(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let links = DeskflowTransport.shared.activeLinksSnapshot()
        let estBps = estimatedThroughputBytesPerSec()
        let targetName = peerHostLabel.isEmpty ? "Windows" : peerHostLabel
        let thresholdSec = DragHandoffPolicy.defaultContinuousMaxSeconds
        let en = isEnglish
        let title = urls.count > 1
            ? (en ? "\(urls[0].lastPathComponent) +\(urls.count - 1) more" : "\(urls[0].lastPathComponent) 等 \(urls.count) 项")
            : urls[0].lastPathComponent

        portalPhase = .hoverExpand(
            fileName: title,
            fileSize: tr(en, "正在计算大小...", "Calculating size..."),
            isLargeFile: true,
            estSec: 0,
            hint: tr(en, "停在传输架上松手开始传输 · 移开取消", "Release on shelf to send · Move away to cancel"),
            canSubmit: !links.isEmpty
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scan = DeskflowEngine.measureUrlsBytesStatic(urls)
            let sizeStr: String
            let estSec: Double
            let hintText: String
            let canSubmit: Bool

            if links.isEmpty || estBps <= 0 {
                sizeStr = scan.totalBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? tr(en, "大小未知", "Unknown size")
                estSec = 0
                hintText = tr(en, "未连上对端设备 · 无法发送（移开取消）", "Peer not connected · Move away to cancel")
                canSubmit = false
            } else if !scan.reliable || scan.totalBytes == nil {
                sizeStr = scan.totalBytes.map { tr(en, "至少 ", "At least ") + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? tr(en, "大小无法读取", "Size unavailable")
                estSec = 0
                hintText = tr(
                    en,
                    "大小无法可靠估算 · 发往 \(targetName) · 松手传到传输架 · 移开取消",
                    "Estimated size unavailable · To \(targetName) · Release to send"
                )
                canSubmit = true
            } else {
                let bytes = scan.totalBytes!
                sizeStr = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                estSec = Double(bytes) / estBps
                let speedMB = estBps / (1024.0 * 1024.0)
                let secLabel = estSec < 1.0
                    ? tr(en, "< 1 秒", "< 1s")
                    : tr(en, "约 \(Int(ceil(estSec))) 秒", "~\(Int(ceil(estSec)))s")
                hintText = en
                    ? String(format: "To %@ · Est. %@ (%.0f MB/s) · Release to send", targetName, secLabel, speedMB)
                    : String(format: "发往 %@ · 预计 %@ (%.0f MB/s) · 松手开始后台传输", targetName, secLabel, speedMB)
                canSubmit = true
                _ = estSec > thresholdSec || bytes > DragHandoffPolicy.maxContinuousSizeBytes
            }

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if case .hoverExpand = self.portalPhase {
                    self.portalPhase = .hoverExpand(
                        fileName: title,
                        fileSize: sizeStr,
                        isLargeFile: true,
                        estSec: estSec,
                        hint: hintText,
                        canSubmit: canSubmit
                    )
                }
            }
        }
    }

    func beginShelfDragOut(paths: [String]) {
        isDraggingOutFromShelf = true
        recentDraggedOutPaths = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        if case .hoverExpand = portalPhase {
            portalPhase = .idle
        }
        PortalOverlayController.shared.setDropHovered(false)
    }

    func endShelfDragOut() {
        isDraggingOutFromShelf = false
        dragOutEndedAt = Date()
    }

    func shouldIgnoreEdgeDrop(urls: [URL]? = nil) -> Bool {
        if isDraggingOutFromShelf { return true }
        let elapsed = Date().timeIntervalSince(dragOutEndedAt)
        if elapsed < DeskflowEngine.dragOutReentryCooldownSeconds { return true }
        if elapsed < 4.0, let urls = urls, !urls.isEmpty, !recentDraggedOutPaths.isEmpty {
            if urls.allSatisfy({ recentDraggedOutPaths.contains($0.standardizedFileURL.path) }) {
                return true
            }
        }
        return false
    }

    func handleDroppedProviders(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty, !shouldIgnoreEdgeDrop() else { return }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                if let validURL = url, validURL.isFileURL {
                    lock.lock()
                    urls.append(validURL)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self, !urls.isEmpty else { return }
            self.startFileTransferFlow(for: urls)
        }
    }

    func startFileTransferFlow(for url: URL) {
        startFileTransferFlow(for: [url])
    }

    func startFileTransferFlow(for urls: [URL], retryItemId: String? = nil) {
        guard !urls.isEmpty else { return }
        if retryItemId == nil {
            if shouldIgnoreEdgeDrop(urls: urls) { return }
            let sig = urls.map { $0.standardizedFileURL.path }.sorted().joined(separator: "|")
            let now = Date()
            if sig == lastDropSignature && now.timeIntervalSince(lastDropSubmittedAt) < 1.5 {
                return
            }
            lastDropSignature = sig
            lastDropSubmittedAt = now
        }
        if !portalOverlayEnabled {
            portalOverlayEnabled = true
        }
        PortalOverlayController.shared.showOrUpdatePanel()

        let taskId = retryItemId ?? UUID().uuidString
        let hasRealPeer = !DeskflowTransport.shared.activeLinksSnapshot().isEmpty
        let enabledIds = Set(nicChannels.filter { $0.online && $0.enabledForMultipath && !$0.manuallyDisconnected }.map(\.id))
        let styleTag = portalEffectStyle.rawValue
        let edgeTag = portalEdgeSide.rawValue
        let offsetVal = portalEdgeOffset
        let isMultiNic = multipathEnabled
        let estMbps = effectiveTransferMbps
        let chanSummary = activeDataChannelSummary
        let en = isEnglish
        let title = urls.count > 1
            ? (en ? "\(urls[0].lastPathComponent) +\(urls.count - 1) more" : "\(urls[0].lastPathComponent) 等 \(urls.count) 项")
            : urls[0].lastPathComponent

        let initialCard = ShelfTransferItem(
            id: taskId,
            direction: .outgoing,
            status: .transferring,
            title: title,
            sizeText: tr(en, "正在统计...", "Calculating..."),
            itemCount: urls.count,
            progress: 0.02,
            speedMbps: estMbps,
            channelTag: chanSummary,
            errorText: nil,
            sourcePaths: urls.map(\.path),
            localPaths: [],
            timestamp: Date()
        )
        shelfItems.removeAll(where: { $0.id == taskId })
        shelfItems.insert(initialCard, at: 0)

        guard hasRealPeer else {
            let warn = tr(en, "尚未连接 Windows 对端，无法发送 \(title)", "Windows peer disconnected; cannot send \(title)")
            updateShelfItem(id: taskId) { item in
                item.status = .failed
                item.errorText = warn
                item.sizeText = tr(en, "未连接", "Offline")
            }
            portalPhase = .idle
            lastTransferSummary = warn
            appendLog("[传文件警告] \(warn)")
            return
        }

        portalPhase = .suckingIn(
            progress: 0.02,
            fileName: title,
            fileSize: tr(en, "准备中...", "Preparing..."),
            speedMbps: estMbps,
            channelTag: chanSummary
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scan = DeskflowEngine.measureUrlsBytesStatic(urls)
            let estBytes = scan.totalBytes ?? 1024 * 1024
            let sizeStr = scan.reliable
                ? ByteCountFormatter.string(fromByteCount: Int64(estBytes), countStyle: .file)
                : tr(en, "计算受限", "Limited")

            var sendURL = urls[0]
            var isBatchBundle = false
            var cleanupDir: URL?
            var cleanupZip: URL?

            if urls.count > 1 {
                let fm = FileManager.default
                let stage = fm.temporaryDirectory.appendingPathComponent("of_batch_\(UUID().uuidString)", isDirectory: true)
                let zipName = SecurityValidation.isValidSingleFileName("\(urls[0].lastPathComponent)等\(urls.count)项.zip")
                    ? "\(urls[0].lastPathComponent)等\(urls.count)项.zip"
                    : "OmniFlow_Batch_\(urls.count)items.zip"
                let zipURL = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString.prefix(6))_\(zipName)")
                do {
                    try fm.createDirectory(at: stage, withIntermediateDirectories: true)
                    for src in urls {
                        let dst = stage.appendingPathComponent(src.lastPathComponent)
                        try? fm.copyItem(at: src, to: dst)
                    }
                    let proc = Process()
                    proc.currentDirectoryURL = stage
                    proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                    proc.arguments = ["-r", "-q", "-0", zipURL.path, "."]
                    proc.standardOutput = Pipe()
                    proc.standardError = Pipe()
                    try proc.run()
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0 && fm.fileExists(atPath: zipURL.path) {
                        sendURL = zipURL
                        isBatchBundle = true
                        cleanupDir = stage
                        cleanupZip = zipURL
                    } else {
                        try? fm.removeItem(at: stage)
                    }
                } catch {
                    try? fm.removeItem(at: stage)
                }
            }

            let finalCleanupDir = cleanupDir
            let finalCleanupZip = cleanupZip
            let (doubled, overflow) = estBytes.multipliedReportingOverflow(by: 2)
            let reqFree = isBatchBundle ? (overflow ? UInt64.max : doubled) : estBytes

            Task { @MainActor [weak self] in
                guard let self = self else {
                    if let d = finalCleanupDir { try? FileManager.default.removeItem(at: d) }
                    if let z = finalCleanupZip { try? FileManager.default.removeItem(at: z) }
                    return
                }
                self.updateShelfItem(id: taskId) { item in
                    item.sizeText = sizeStr
                }
                self.portalPhase = .suckingIn(
                    progress: 0.04,
                    fileName: title,
                    fileSize: sizeStr,
                    speedMbps: estMbps,
                    channelTag: chanSummary
                )

                DeskflowTransport.shared.sendFileReal(
                    sourceURL: sendURL,
                    scheme: "b",
                    style: styleTag,
                    edge: edgeTag,
                    offset: offsetVal,
                    multipath: isMultiNic,
                    enabledLinkIds: enabledIds,
                    batchItemCount: urls.count,
                    isBatchBundle: isBatchBundle,
                    requiredFreeBytes: reqFree,
                    onProgress: { [weak self] p, speedMbps, fname, fsize, chTag in
                        Task { @MainActor [weak self] in
                            self?.updateShelfItem(id: taskId) { item in
                                item.progress = p
                                item.speedMbps = speedMbps
                                item.channelTag = chTag
                                item.sizeText = fsize
                            }
                            self?.portalPhase = .suckingIn(
                                progress: p,
                                fileName: title,
                                fileSize: fsize,
                                speedMbps: speedMbps,
                                channelTag: chTag
                            )
                        }
                    },
                    onFinished: { [weak self] ok, msg in
                        if let d = finalCleanupDir { try? FileManager.default.removeItem(at: d) }
                        if let z = finalCleanupZip { try? FileManager.default.removeItem(at: z) }
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            self.appendLog(ok ? "[传文件] \(msg)" : "[传文件失败] \(msg)")
                            self.lastTransferSummary = msg
                            if ok {
                                self.shelfItems.removeAll(where: { $0.id == taskId })
                                self.portalPhase = .completed(fileName: title, fileSize: sizeStr, savedURL: nil)
                            } else {
                                self.updateShelfItem(id: taskId) { item in
                                    item.status = .failed
                                    item.errorText = msg
                                }
                                self.portalPhase = .idle
                            }
                        }
                    }
                )
            }
        }
    }

    private func updateShelfItem(id: String, _ mutate: (inout ShelfTransferItem) -> Void) {
        guard let idx = shelfItems.firstIndex(where: { $0.id == id }) else { return }
        mutate(&shelfItems[idx])
    }

    func retryShelfItem(_ id: String) {
        guard let item = shelfItems.first(where: { $0.id == id && $0.direction == .outgoing }) else { return }
        let urls = item.sourcePaths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        startFileTransferFlow(for: urls, retryItemId: id)
    }

    func removeShelfItem(_ id: String) {
        shelfItems.removeAll(where: { $0.id == id })
    }

    func markShelfItemDeliveredByDrag(_ id: String, operationDesc: String = "拖放投递") {
        guard let item = shelfItems.first(where: { $0.id == id }) else { return }
        shelfItems.removeAll(where: { $0.id == id })
        appendLog("[传输架] 已完成\(operationDesc): \(item.title)")
    }

    func openShelfItem(_ id: String) {
        guard let item = shelfItems.first(where: { $0.id == id }), let u = item.primaryLocalURL else { return }
        NSWorkspace.shared.open(u)
        shelfItems.removeAll(where: { $0.id == id })
        appendLog("[传输架] 已打开文件并从收件架移出: \(item.title)")
    }

    func revealShelfItem(_ id: String) {
        guard let item = shelfItems.first(where: { $0.id == id }) else { return }
        let urls = item.localPaths.map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func resetPortalPhase() {
        portalPhase = .idle
    }

    func openLastReceivedFile() {
        if let firstReady = shelfItems.first(where: { $0.direction == .incoming && $0.status == .ready }),
           let u = firstReady.primaryLocalURL {
            NSWorkspace.shared.activateFileViewerSelecting([u])
        } else if let u = lastReceivedURL {
            NSWorkspace.shared.activateFileViewerSelecting([u])
        } else if let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            NSWorkspace.shared.open(dl)
        }
    }

    nonisolated private static func measureUrlsBytesStatic(_ urls: [URL]) -> (totalBytes: UInt64?, count: Int, reliable: Bool) {
        let fm = FileManager.default
        var total: UInt64 = 0
        var count = 0
        var reliable = true

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                reliable = false
                continue
            }
            if !isDir.boolValue {
                if let attrs = try? fm.attributesOfItem(atPath: url.path), let sz = attrs[.size] as? UInt64 {
                    total += sz
                    count += 1
                } else {
                    reliable = false
                }
                continue
            }
            // Directory recursive count
            count += 1
            if let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in
                    reliable = false
                    return true
                }
            ) {
                for case let fileURL as URL in enumerator {
                    if let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]) {
                        if vals.isRegularFile == true {
                            total += UInt64(max(0, vals.fileSize ?? 0))
                        }
                    } else {
                        reliable = false
                    }
                    count += 1
                    if count > DragHandoffPolicy.estimationScanBudgetCount {
                        reliable = false
                        break
                    }
                }
            } else {
                reliable = false
            }
        }
        if !reliable && total == 0 {
            return (nil, max(1, count), false)
        }
        return (total, max(1, count), reliable)
    }

    // MARK: - Clipboard & Cross-OS Semantic Hotkey Translation

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func clipboardFilesSignature(_ urls: [URL]) -> String {
        let fm = FileManager.default
        return urls.map { u in
            let attrs = try? fm.attributesOfItem(atPath: u.path)
            let sz = (attrs?[.size] as? UInt64) ?? 0
            let mod = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(u.path)|\(sz)|\(Int64(mod))"
        }.sorted().joined(separator: ";")
    }

    private static func extractPngFromPasteboard(_ pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png), !png.isEmpty {
            return png
        }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        if pb.canReadObject(forClasses: [NSImage.self], options: nil),
           let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let first = imgs.first,
           let tiff = first.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
    }

    private func startClipboardAndHotkeyWatchers() {
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.clipboardSyncEnabled else { return }
                let pb = NSPasteboard.general
                guard pb.changeCount != self.lastPasteboardCount else { return }
                self.lastPasteboardCount = pb.changeCount
                if Date() < self.suppressPasteboardUntil { return }
                if DeskflowTransport.shared.activeLinksSnapshot().isEmpty { return }

                // 1. Check copied files / folders FIRST (Finder also attaches file icon + filename string)
                if let fileURLs = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                   !fileURLs.isEmpty {
                    let existing = fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
                    if !existing.isEmpty {
                        let sig = Self.clipboardFilesSignature(existing)
                        if sig != self.lastRemoteClipboardFileSig {
                            self.lastRemoteClipboardFileSig = sig
                            self.broadcastClipboardFilesToPeer(existing)
                        }
                        return
                    }
                }

                // 2. Check copied images / screenshots
                if let pngData = Self.extractPngFromPasteboard(pb), !pngData.isEmpty {
                    let sha = Self.sha256Hex(pngData)
                    if sha == self.lastRemoteClipboardImageSha { return }
                    self.lastRemoteClipboardImageSha = sha
                    if pngData.count <= 14 * 1024 * 1024 {
                        DeskflowTransport.shared.broadcastControlFrame(WireFrameCodec.encode(type: .clipboardImage, payload: pngData))
                        let kb = String(format: "%.0f KB", Double(pngData.count) / 1024.0)
                        self.appendLog("[剪贴板] 已同步图片到 Windows (\(kb))")
                    } else {
                        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardImage_\(Int(Date().timeIntervalSince1970)).png")
                        if (try? pngData.write(to: tmp)) != nil {
                            self.broadcastClipboardFilesToPeer([tmp], cleanupAfterSend: tmp)
                        }
                    }
                    return
                }

                // 3. Fallback to plain text
                let copied = pb.string(forType: .string)
                    ?? pb.string(forType: NSPasteboard.PasteboardType("public.utf8-plain-text"))
                if let copied = copied, !copied.isEmpty, copied != self.lastRemoteClipboardText {
                    self.lastRemoteClipboardText = copied
                    if let data = copied.data(using: .utf8) {
                        DeskflowTransport.shared.broadcastControlFrame(WireFrameCodec.encode(type: .clipboardText, payload: data))
                    }
                    self.appendLog("[剪贴板] 已同步文字到 Windows (\(copied.count) 字符)")
                }
            }
        }

        // Fallback global monitor when Accessibility isn't granted
        fallbackKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                guard let self = self, self.kvmEnabled, self.remoteFocusOnWindows, !MacKvmController.shared.hasAccessibilityPermission else { return }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags.contains([.command, .shift]) && (event.keyCode == 21 || event.keyCode == 23) {
                    self.triggerRemoteWindowsScreenshot(isRegion: event.keyCode == 21)
                }
            }
        }
    }

    private func broadcastClipboardFilesToPeer(_ urls: [URL], cleanupAfterSend: URL? = nil) {
        let enabledIds = Set(nicChannels.filter { $0.online && $0.enabledForMultipath }.map(\.id))
        let useMultipath = multipathEnabled
        let countLabel = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) 项文件"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var totalBytes: UInt64 = 0
            for u in urls {
                totalBytes += Self.measurePathBytes(u)
                if totalBytes > 200 * 1024 * 1024 { break }
            }
            if totalBytes > 200 * 1024 * 1024 {
                Task { @MainActor in
                    self?.appendLog("[剪贴板] 复制的文件超过 200 MB，改用直接拖拽传输会更快")
                }
                if let c = cleanupAfterSend { try? FileManager.default.removeItem(at: c) }
                return
            }

            var sendURL = urls[0]
            var isMulti = false
            var tempBundleDir: URL?
            var tempZip: URL?

            if urls.count > 1 {
                let fm = FileManager.default
                let stage = fm.temporaryDirectory.appendingPathComponent("of_clip_\(UUID().uuidString)", isDirectory: true)
                let zipURL = fm.temporaryDirectory.appendingPathComponent("Clipboard_\(urls.count)items.zip")
                do {
                    try fm.createDirectory(at: stage, withIntermediateDirectories: true)
                    for src in urls {
                        let dst = stage.appendingPathComponent(src.lastPathComponent)
                        try? fm.copyItem(at: src, to: dst)
                    }
                    let proc = Process()
                    proc.currentDirectoryURL = stage
                    proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                    proc.arguments = ["-r", "-q", "-0", zipURL.path, "."]
                    proc.standardOutput = Pipe()
                    proc.standardError = Pipe()
                    try proc.run()
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0 && fm.fileExists(atPath: zipURL.path) {
                        sendURL = zipURL
                        isMulti = true
                        tempBundleDir = stage
                        tempZip = zipURL
                    } else {
                        try? fm.removeItem(at: stage)
                    }
                } catch {
                    try? fm.removeItem(at: stage)
                }
            }

            let cleanupBundleDir = tempBundleDir
            let cleanupZip = tempZip

            DeskflowTransport.shared.sendFileReal(
                sourceURL: sendURL,
                scheme: "a",
                style: "blackhole",
                edge: "right",
                offset: 0.5,
                multipath: useMultipath,
                enabledLinkIds: enabledIds,
                isClipboardItem: true,
                isClipboardMulti: isMulti,
                onProgress: { _, _, _, _, _ in },
                onFinished: { [weak self] ok, msg in
                    if let d = cleanupBundleDir { try? FileManager.default.removeItem(at: d) }
                    if let z = cleanupZip { try? FileManager.default.removeItem(at: z) }
                    if let c = cleanupAfterSend { try? FileManager.default.removeItem(at: c) }
                    Task { @MainActor in
                        if ok {
                            self?.appendLog("[剪贴板] 已把复制的「\(countLabel)」同步给 Windows")
                        } else {
                            self?.appendLog("[剪贴板] 同步文件失败: \(msg)")
                        }
                    }
                }
            )
        }
    }

    nonisolated private static func measurePathBytes(_ url: URL) -> UInt64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let a = try? fm.attributesOfItem(atPath: url.path)
            return (a?[.size] as? UInt64) ?? 0
        }
        var sum: UInt64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let child as URL in e {
                let vals = try? child.resourceValues(forKeys: [.fileSizeKey])
                sum += UInt64(vals?.fileSize ?? 0)
                if sum > 200 * 1024 * 1024 { return sum }
            }
        }
        return sum
    }

    func triggerRemoteWindowsScreenshot(isRegion: Bool) {
        let ruleId = isRegion ? "shot_region" : "shot_panel"
        guard let rule = hotkeyRules.first(where: { $0.id == ruleId }), rule.enabled else { return }
        if let frame = WireFrameCodec.encodeJSON(type: .semanticHotkey, value: WireSemanticHotkeyPayload(action: rule.actionCode)) {
            DeskflowTransport.shared.sendControlFrame(frame)
        }
        appendLog(
            "[Hotkey] Mac 焦点在 Windows · 捕获 \(rule.macTrigger) -> 已通过低延迟控制通道 (\(activeControlChannelName)) 发送至 Windows 触发「\(rule.winAction)」！"
        )
        lastTransferSummary = "已发送跨系统截图指令：Mac [\(rule.macTrigger)] -> Windows [\(rule.winAction)]"
    }
}
