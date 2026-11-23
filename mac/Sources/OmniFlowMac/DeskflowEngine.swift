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

    var lastReceivedURL: URL?
    var remotePeerMonitors: [WireMonitorDto] = []
    @Published var peerHostOs: String = "Windows"

    var peerIsMac: Bool {
        peerHostOs.lowercased().contains("mac")
    }

    var peerShortDisplayOs: String {
        peerIsMac ? "macOS" : "Windows"
    }

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
    var applyingRemoteConfig: Bool = false
    var isLoadingPrefs: Bool = false
    var lastAppliedConfigTs: Double = 0
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
    var lastPasteboardCount: Int = NSPasteboard.general.changeCount
    var lastRemoteClipboardText: String = ""
    var lastRemoteClipboardImageSha: String = ""
    var lastRemoteClipboardFileSig: String = ""
    var suppressPasteboardUntil: Date = .distantPast
    var clipboardTimer: Timer?
    var fallbackKeyMonitor: Any?
    static let dragOutReentryCooldownSeconds: TimeInterval = 2.0
    var isDraggingOutFromShelf: Bool = false
    var dragOutEndedAt: Date = .distantPast
    var recentDraggedOutPaths: Set<String> = []
    var lastDropSignature: String = ""
    var lastDropSubmittedAt: Date = .distantPast
    @Published var displaySaveStatusText: String = ""
    @Published var settingsSaveStatusText: String = ""
    var savedDisplayPositions: [String: [Double]] = [:]
    var cubeDragStartMouse: NSPoint?
    var cubeDragStartOffset: Double = 0.55
    var disabledMultipathNics: Set<String> = []
    var lastRecommendedControlKey: String?
    var lastArrangeCanvasSize: CGSize = CGSize(width: 680, height: 360)
    var topologySyncWorkItem: DispatchWorkItem?
    var syncedRemotePositions: [String: CGPoint] = [:]

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

        MacKvmController.shared.syncInjectorState(kvmEnabled: kvmEnabled, controlMode: kvmControlMode)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            MacKvmController.shared.ensureTapWatcherStarted()
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
                        self.peerHostOs = "Windows"
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

        tx.onPeerMonitorsUpdated = { [weak self] monitors, host, os in
            Task { @MainActor in
                guard let self = self else { return }
                self.remotePeerMonitors = monitors
                self.peerHostLabel = host
                self.peerHostOs = os.isEmpty ? "Windows" : os
                self.syncedRemotePositions.removeValue(forKey: "win_disp_wait")
                // Restore authoritative user-saved display coordinates before laying out combined screen arrangement
                for (id, coords) in self.savedDisplayPositions where coords.count == 2 {
                    self.syncedRemotePositions[id] = CGPoint(x: coords[0], y: coords[1])
                }
                self.refreshIndependentDisplays()
                self.appendLog("[Display] 已同步对端 \(self.peerShortDisplayOs) (\(host)) 的 \(monitors.count) 块独立显示器")
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
            let isMacPeerNow = DeskflowTransport.shared.peerHostOs.lowercased().contains("mac")
            let incomingToLocalPre = isMacPeerNow ? (sw.action != "leave") : (sw.targetOs == "macOS")
            let epochAtSwitch: UInt64
            if incomingToLocalPre {
                KvmStageTracer.shared.log(
                    seq: stageSeq,
                    t0Ns: recvNs,
                    "engineFocusCallback target=\(sw.targetOs) action=\(sw.action ?? "nil")"
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
                    if incomingToLocalPre {
                        KvmStageTracer.shared.log(seq: stageSeq, t0Ns: recvNs, "mainActorSkipped_selfNil")
                    }
                    return
                }
                let incomingToLocal = self.peerIsMac ? (sw.action != "leave") : (sw.targetOs == "macOS")
                if incomingToLocal {
                    KvmStageTracer.shared.log(
                        seq: stageSeq,
                        t0Ns: recvNs,
                        "mainActorEnter mode=\(self.kvmControlMode.rawValue) remoteFocusOnWin=\(self.remoteFocusOnWindows) kvmEnabled=\(self.kvmEnabled) peerIsMac=\(self.peerIsMac)"
                    )
                    // Incoming remote control -> allow only when dualActive or winMasterOnly
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
                } else if self.peerIsMac && sw.action == "leave" {
                    // Controlling peer Mac pulled focus back to itself (e.g. Esc / Ctrl+Opt+S)
                    if self.remoteFocusOnWindows {
                        MacKvmController.shared.setRemoteFocus(false, notifyPeer: false)
                    } else {
                        MacKvmController.shared.syncInjectorState(kvmEnabled: self.kvmEnabled, controlMode: self.kvmControlMode)
                    }
                } else if !self.peerIsMac && sw.targetOs == "Windows" {
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
}
