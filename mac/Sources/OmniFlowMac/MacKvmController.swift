import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Handles real macOS CGEventTap KVM capture & CGEventPost injection + 2D Spatial Monitor Crossing + File Drag Across Edge + Keymap Profiles.
@MainActor
final class MacKvmController {
    static let shared = MacKvmController()
    nonisolated static let injectedEventTag: Int64 = 0x4F4D4E49

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    var virtualNormX: Double = 0.5
    var virtualNormY: Double = 0.5
    var activeTargetWinMonitorIdx: Int = 0
    private var sourceMacMonitorIdx: Int = 0
    private var returnEdgeOnWin: ScreenEdgeSide = .left
    private var lastEdgeCrossTime: Date = .distantPast
    private var suppressDeltaUntil: Date = .distantPast
    private var parkedCursorPoint: CGPoint?
    private var bgCursorEnabled = false
    private var axPollTimer: Timer?
    private var cachedKvmEnabled: Bool = true
    private var cachedControlMode: KvmControlMode = .dualActive
    private var isRemoteFocusActive: Bool = false
    private var lastModifierFlags: CGEventFlags = []
    private var dragStartPasteboardCount: Int = -1
    private var isHoveringEdgeWithFile: Bool = false
    private var pendingEdgeDraggedURLs: [URL] = []
    private var consumedSemanticHotkeySinceMod: Bool = false
    private var remoteMouseButtonsDown: Set<UInt8> = []
    private var suppressEdgeCrossUntil: Date = .distantPast

    // Three-finger trackpad drag state (Mac -> Windows), accessed by MacMultitouchTrackpad extension
    var mtHandle: UnsafeMutableRawPointer?
    var mtDevices: [UnsafeMutableRawPointer] = []
    var activeTrackpadFingers: Int = 0
    var gestureStartCentroid: CGPoint?
    var gesturePrevCentroid: CGPoint?
    var gestureStartTime: Date = .distantPast
    var isThreeFingerDragging: Bool = false
    var lastThreeFingerMoveTime: Date = .distantPast
    var smooth3fDx: Double = 0.0
    var smooth3fDy: Double = 0.0
    private var scrollPointAccumX: Double = 0.0
    private var scrollPointAccumY: Double = 0.0

    var onRemoteFocusChanged: ((Bool) -> Void)?
    var onLog: ((String) -> Void)? {
        didSet {
            RemoteCursorInjector.shared.setTimingLogger { [weak self] msg in
                Task { @MainActor [weak self] in
                    self?.onLog?(msg)
                }
            }
        }
    }

    private init() {}

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    func ensureTapWatcherStarted() {
        startTapIfPermitted()
        guard axPollTimer == nil else { return }
        axPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let trusted = AXIsProcessTrusted()
                if DeskflowEngine.shared.accessibilityGranted != trusted {
                    DeskflowEngine.shared.accessibilityGranted = trusted
                }
                if trusted && self.eventTap == nil && DeskflowEngine.shared.kvmEnabled {
                    self.startTapIfPermitted()
                }
            }
        }
    }

    func requestAccessibilityPermission() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func toggleRemoteFocusManual() {
        if !AXIsProcessTrusted() {
            onLog?("[KVM] 未检测到 macOS「辅助功能」权限，已打开系统设置窗口，请重新勾选 OmniFlow 后即可切换焦点。")
            requestAccessibilityPermission()
            return
        }
        startTapIfPermitted()
        let engine = DeskflowEngine.shared
        if engine.kvmControlMode == .winMasterOnly && !engine.remoteFocusOnWindows {
            onLog?("[KVM] 当前为「仅 Windows 主控」模式，请从 Windows 端发起切换或在设置改为「双端随时互控」。")
            return
        }
        let next = !engine.remoteFocusOnWindows
        setRemoteFocus(next, entryNormX: 0.5, entryNormY: 0.5)
    }

    func startTapIfPermitted() {
        guard eventTap == nil, AXIsProcessTrusted() else { return }

        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let callback: CGEventTapCallBack = { _, type, event, refcon -> Unmanaged<CGEvent>? in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let ctrl = Unmanaged<MacKvmController>.fromOpaque(refcon).takeUnretainedValue()
            return ctrl.handleTapEvent(type: type, event: event)
        }

        let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        ) ?? CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        )

        guard let validTap = tap else {
            onLog?("[KVM] CGEventTap 创建失败，请确认已在「隐私与安全性 -> 辅助功能」授权 OmniFlow")
            return
        }

        eventTap = validTap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, validTap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: validTap, enable: true)
        startMultitouchTrackpadMonitor()
        syncInjectorState(kvmEnabled: cachedKvmEnabled, controlMode: cachedControlMode)
        RemoteCursorInjector.shared.setTimingLogger { [weak self] msg in
            Task { @MainActor [weak self] in
                self?.onLog?(msg)
            }
        }
        onLog?("[KVM] macOS 全局键鼠捕获已就绪 (双端互控/主控可配 · 2D接缝穿屏 · 多指触控板手势)")
    }

    func stopTap() {
        if isRemoteFocusActive {
            setRemoteFocus(false)
        }
        stopMultitouchTrackpadMonitor()
        syncInjectorState(kvmEnabled: false, controlMode: cachedControlMode)
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    private func enableBackgroundCursorControl() {
        guard !bgCursorEnabled else { return }
        bgCursorEnabled = true
        RemoteCursorInjector.shared.ensureBackgroundCursorControl()
    }

    private func hideAndParkMacCursor() {
        enableBackgroundCursorControl()
        if parkedCursorPoint == nil {
            parkedCursorPoint = CGEvent(source: nil)?.location ?? CGPoint(x: 20, y: 20)
        }
        let parkPt = parkedCursorPoint ?? CGPoint(x: 20, y: 20)
        RemoteCursorInjector.shared.hideAndParkCursor(parkPoint: parkPt)
    }

    func syncInjectorState(kvmEnabled: Bool, controlMode: KvmControlMode) {
        cachedKvmEnabled = kvmEnabled
        cachedControlMode = controlMode
        let allowed = kvmEnabled && controlMode != .macMasterOnly
        var list: [CGRect] = []
        list.reserveCapacity(NSScreen.screens.count)
        for scr in NSScreen.screens {
            if let num = scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                list.append(CGDisplayBounds(CGDirectDisplayID(num.uint32Value)))
            } else {
                list.append(CGDisplayBounds(CGMainDisplayID()))
            }
        }
        RemoteCursorInjector.shared.update(bounds: list, allowed: allowed)
    }

    nonisolated static func prepareCursorForIncomingFocus(monitorIdx: Int, normX: Double, normY: Double, recvNs: UInt64, stageSeq: UInt64) -> UInt64 {
        RemoteCursorInjector.shared.prepareCursorForIncomingFocus(monitorIdx: monitorIdx, normX: normX, normY: normY, recvNs: recvNs, stageSeq: stageSeq)
    }

    nonisolated static func injectMouseMoveAbsFast(monitorIdx: Int, normX: Double, normY: Double) {
        RemoteCursorInjector.shared.injectMouseMoveAbs(monitorIdx: monitorIdx, normX: normX, normY: normY)
    }

    private func restoreMacCursor(warpTo targetPoint: CGPoint? = nil) {
        RemoteCursorInjector.shared.restoreCursorVisibilityIfNeeded(warpTo: targetPoint)
        parkedCursorPoint = nil
    }

    func setRemoteFocus(
        _ remote: Bool,
        entryNormX: Double = 0.05,
        entryNormY: Double = 0.5,
        notifyPeer: Bool = true,
        focusEpochAtSwitch: UInt64? = nil,
        returnWarpPoint: CGPoint? = nil
    ) {
        isRemoteFocusActive = remote
        let engine = DeskflowEngine.shared
        if remote {
            MultitouchBridge.shared.isRemoteFocus = true
            virtualNormX = min(max(entryNormX, 0.02), 0.98)
            virtualNormY = min(max(entryNormY, 0.02), 0.98)
            lastModifierFlags = []
            // Ignore transient delta spikes for 65ms right as Mac cursor detaches (prevents jumping to Win bottom-right!)
            suppressDeltaUntil = Date().addingTimeInterval(0.065)

            hideAndParkMacCursor()

            if !engine.remoteFocusOnWindows {
                engine.remoteFocusOnWindows = true
                onRemoteFocusChanged?(true)
                if notifyPeer,
                   let frame = WireFrameCodec.encodeJSON(
                    type: .kvmFocusSwitch,
                    value: WireKvmFocusPayload(
                        targetOs: "Windows",
                        monitorIndex: activeTargetWinMonitorIdx,
                        normX: virtualNormX,
                        normY: virtualNormY
                    )
                   ) {
                    DeskflowTransport.shared.sendControlFrame(frame)
                }
                sendMouseMoveAbs(monitorIdx: activeTargetWinMonitorIdx, normX: virtualNormX, normY: virtualNormY)
            }
        } else {
            // Deskflow PrimaryClient::enter / OSXComputer::enter order:
            // Warp & restore cursor visibility + zero suppression interval FIRST before network/UI work
            // so returning from Windows to Mac never hits macOS's default 250ms CGWarpMouseCursorPosition freeze.
            MultitouchBridge.shared.isRemoteFocus = false
            restoreMacCursor(warpTo: returnWarpPoint)
            if isThreeFingerDragging {
                isThreeFingerDragging = false
                DeskflowTransport.shared.sendControlFrame(WireFrameCodec.encode(type: .mouseButton, payload: Data([1, 0])))
            }
            if !remoteMouseButtonsDown.isEmpty {
                for btn in remoteMouseButtonsDown {
                    DeskflowTransport.shared.sendControlFrame(WireFrameCodec.encode(type: .mouseButton, payload: Data([btn, 0])))
                }
                remoteMouseButtonsDown.removeAll()
            }
            activeTrackpadFingers = 0
            gestureStartCentroid = nil
            gesturePrevCentroid = nil
            smooth3fDx = 0.0
            smooth3fDy = 0.0
            releaseAllRemoteModifiers()
            syncInjectorState(kvmEnabled: engine.kvmEnabled, controlMode: engine.kvmControlMode)

            if engine.remoteFocusOnWindows {
                engine.remoteFocusOnWindows = false
                onRemoteFocusChanged?(false)
                if notifyPeer,
                   let frame = WireFrameCodec.encodeJSON(
                    type: .kvmFocusSwitch,
                    value: WireKvmFocusPayload(
                        targetOs: "macOS",
                        monitorIndex: sourceMacMonitorIdx,
                        normX: virtualNormX,
                        normY: virtualNormY
                    )
                   ) {
                    DeskflowTransport.shared.sendControlFrame(frame)
                }
            }
            if let epoch = focusEpochAtSwitch {
                RemoteCursorInjector.shared.markMainActorDone(epoch: epoch)
            }
            let cur = KvmStageTracer.shared.currentTrace()
            let t0 = cur.t0Ns > 0 ? cur.t0Ns : DispatchTime.now().uptimeNanoseconds
            KvmStageTracer.shared.log(
                seq: cur.seq,
                t0Ns: t0,
                "setRemoteFocusFalse notifyPeer=\(notifyPeer) epoch=\(focusEpochAtSwitch.map(String.init) ?? "nil")"
            )
        }
    }

    private func releaseAllRemoteModifiers() {
        let modVks: [UInt16] = [0x5B, 0x10, 0x11, 0x12]
        for vk in modVks {
            sendRawKeyFrame(vk: vk, isDown: false, mods: 0)
        }
        lastModifierFlags = []
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Ignore synthetic events injected from Windows so Windows -> Mac control NEVER bounces back!
        if event.getIntegerValueField(.eventSourceUserData) == MacKvmController.injectedEventTag {
            return Unmanaged.passUnretained(event)
        }

        let engine = DeskflowEngine.shared
        guard engine.kvmEnabled else {
            if engine.remoteFocusOnWindows { setRemoteFocus(false) }
            return Unmanaged.passUnretained(event)
        }

        // Safety & Manual Toggle Hotkey
        if type == .keyDown {
            let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            let isCtrlOpt = flags.contains(.maskControl) && flags.contains(.maskAlternate)
            if isCtrlOpt && kc == 53 { // Esc always returns focus safely
                setRemoteFocus(false)
                return nil
            }
            if engine.hotkeySwitchEnabled && isCtrlOpt && kc == 1 { // Ctrl+Opt+S
                if engine.kvmControlMode != .winMasterOnly || engine.remoteFocusOnWindows {
                    let next = !engine.remoteFocusOnWindows
                    setRemoteFocus(next, entryNormX: 0.5, entryNormY: 0.5)
                    return nil
                }
            }
        }

        // Focus is currently on Mac
        if !engine.remoteFocusOnWindows {
            if type == .keyDown {
                let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                if kc == 53 && isHoveringEdgeWithFile {
                    isHoveringEdgeWithFile = false
                    pendingEdgeDraggedURLs.removeAll()
                    PortalOverlayController.shared.setDropHovered(false)
                    if case .hoverExpand = engine.portalPhase {
                        engine.portalPhase = .idle
                    }
                    return Unmanaged.passUnretained(event)
                }
            }

            if type == .leftMouseDown {
                dragStartPasteboardCount = NSPasteboard(name: .drag).changeCount
                isHoveringEdgeWithFile = false
                pendingEdgeDraggedURLs.removeAll()
                return Unmanaged.passUnretained(event)
            }

            // Holding mouse button to drag file in Finder toward the arranged edge shelf
            if type == .leftMouseDragged {
                handleLocalFileDragTowardsBoundary(cursorLocation: event.location, engine: engine)
                return Unmanaged.passUnretained(event)
            }
            if type == .leftMouseUp {
                dragStartPasteboardCount = -1
                suppressEdgeCrossUntil = Date().addingTimeInterval(0.45)
                let urls = pendingEdgeDraggedURLs
                let wasHover = isHoveringEdgeWithFile
                isHoveringEdgeWithFile = false
                pendingEdgeDraggedURLs.removeAll()
                PortalOverlayController.shared.setDropHovered(false)

                if wasHover && !urls.isEmpty && !engine.shouldIgnoreEdgeDrop(urls: urls) {
                    let hasPeer = !DeskflowTransport.shared.activeLinksSnapshot().isEmpty
                    if hasPeer {
                        cancelFinderLocalDragGhost()
                        engine.startFileTransferFlow(for: urls)
                    } else {
                        engine.portalPhase = .idle
                        let warn = "尚未连接 Windows 对端，已保持原文件在原地不动"
                        engine.lastTransferSummary = warn
                        engine.appendLog("[传文件警告] \(warn)")
                    }
                } else if wasHover {
                    if case .hoverExpand = engine.portalPhase {
                        engine.portalPhase = .idle
                    }
                }
                return Unmanaged.passUnretained(event)
            }

            // Mouse edge crossing into Windows (only when allowed by kvmControlMode and no button/drag active)
            if engine.edgeSwitchEnabled &&
               engine.kvmControlMode != .winMasterOnly &&
               type == .mouseMoved &&
               (NSEvent.pressedMouseButtons & 7) == 0 &&
               !isHoveringEdgeWithFile &&
               Date() >= suppressEdgeCrossUntil {
                let dx = event.getDoubleValueField(.mouseEventDeltaX)
                let dy = event.getDoubleValueField(.mouseEventDeltaY)
                if Date().timeIntervalSince(lastEdgeCrossTime) > 0.25,
                   !DeskflowTransport.shared.activeLinksSnapshot().isEmpty,
                   let cross = detect2DBoundaryCrossingToWindows(cursorLocation: event.location, dx: dx, dy: dy, engine: engine) {
                    lastEdgeCrossTime = Date()
                    sourceMacMonitorIdx = cross.macMonitorIdx
                    activeTargetWinMonitorIdx = cross.winMonitorIdx
                    returnEdgeOnWin = cross.returnEdge
                    setRemoteFocus(true, entryNormX: cross.entryX, entryNormY: cross.entryY)
                    return nil
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // Focus is currently on Windows -> keep Mac cursor locked & hidden across all Mac displays and forward deltas
        guard RemoteCursorInjector.shared.isRemoteFocusActive else {
            return Unmanaged.passUnretained(event)
        }
        if DeskflowTransport.shared.activeLinksSnapshot().isEmpty {
            setRemoteFocus(false, notifyPeer: false)
            return Unmanaged.passUnretained(event)
        }

        CGAssociateMouseAndMouseCursorPosition(boolean_t(0))

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            // Suppress 3-finger raw cursor jitter while three-finger drag is active
            if isThreeFingerDragging || (activeTrackpadFingers == 3 && engine.isRuleEnabled("mac_tp_3f_drag")) {
                if let p = parkedCursorPoint { CGWarpMouseCursorPosition(p) }
                return nil
            }
            if Date() < suppressDeltaUntil {
                if let p = parkedCursorPoint { CGWarpMouseCursorPosition(p) }
                return nil
            }
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            if let p = parkedCursorPoint,
               abs(event.location.x - p.x) > 48.0 || abs(event.location.y - p.y) > 48.0 {
                CGWarpMouseCursorPosition(p)
            }
            // Filter out bogus HID/warp delta spikes
            if abs(dx) > 450 || abs(dy) > 450 {
                return nil
            }
            let targetWin = engine.displayNodes.first(where: { $0.osKind == .windows && $0.displayIndex == activeTargetWinMonitorIdx })
                ?? engine.displayNodes.first(where: { $0.osKind == .windows })
            let refW = targetWin.map { max(1280.0, Double($0.widthPx) / max(1.0, $0.scaleFactor)) } ?? 1920.0
            let refH = targetWin.map { max(720.0, Double($0.heightPx) / max(1.0, $0.scaleFactor)) } ?? 1080.0
            virtualNormX += dx / refW
            virtualNormY += dy / refH

            // Strict 2D adjacency return check BEFORE clamping — never switch screens while dragging/buttons pressed
            if type == .mouseMoved &&
               (NSEvent.pressedMouseButtons & 7) == 0 &&
               !isThreeFingerDragging &&
               Date() >= suppressEdgeCrossUntil &&
               engine.edgeSwitchEnabled &&
               Date().timeIntervalSince(lastEdgeCrossTime) > 0.25 {
                if let back = detectReturnCrossingToMac(normX: virtualNormX, normY: virtualNormY, dx: dx, dy: dy, engine: engine) {
                    lastEdgeCrossTime = Date()
                    let returnPt = resolveReturnPointOnMac(macMonitorIdx: back.macMonitorIdx, returnEdge: back.returnEdge, normX: back.normX, normY: back.normY)
                    setRemoteFocus(false, returnWarpPoint: returnPt)
                    return nil
                }
            }

            virtualNormX = min(max(virtualNormX, 0.0), 1.0)
            virtualNormY = min(max(virtualNormY, 0.0), 1.0)
            sendMouseMoveAbs(monitorIdx: activeTargetWinMonitorIdx, normX: virtualNormX, normY: virtualNormY)
            return nil

        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            let btn: UInt8
            if type == .rightMouseDown || type == .rightMouseUp { btn = 2 }
            else if type == .otherMouseDown || type == .otherMouseUp { btn = 3 }
            else { btn = 1 }
            let isDown = (type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown)
            if isDown { remoteMouseButtonsDown.insert(btn) }
            else {
                remoteMouseButtonsDown.remove(btn)
                suppressEdgeCrossUntil = Date().addingTimeInterval(0.45)
            }
            let down: UInt8 = isDown ? 1 : 0
            let payload = Data([btn, down])
            DeskflowTransport.shared.sendControlFrame(WireFrameCodec.encode(type: .mouseButton, payload: payload))
            return nil

        case .scrollWheel:
            let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
            var dy = Int32(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            var dx = Int32(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            if isContinuous != 0 {
                scrollPointAccumY += event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
                scrollPointAccumX += event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
                let step: Double = 14.0
                if abs(scrollPointAccumY) >= step {
                    let units = Int32((scrollPointAccumY / step).rounded(.towardZero))
                    scrollPointAccumY -= Double(units) * step
                    if units != 0 { dy = units }
                }
                if abs(scrollPointAccumX) >= step {
                    let units = Int32((scrollPointAccumX / step).rounded(.towardZero))
                    scrollPointAccumX -= Double(units) * step
                    if units != 0 { dx = units }
                }
            }
            if dy == 0 && dx == 0 { return nil }
            // Wire convention: dx > 0 means scroll right (opposite of Mac Axis2 > 0)
            let wireDx = -dx
            var p = Data(capacity: 8)
            var beDy = dy.bigEndian
            var beDx = wireDx.bigEndian
            withUnsafeBytes(of: &beDy) { p.append(contentsOf: $0) }
            withUnsafeBytes(of: &beDx) { p.append(contentsOf: $0) }
            DeskflowTransport.shared.sendControlFrame(WireFrameCodec.encode(type: .mouseScroll, payload: p))
            return nil

        case .flagsChanged:
            let flags = event.flags
            let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

            if kc == 55 || kc == 54 { // Command -> Win Key (VK_LWIN)
                let down = flags.contains(.maskCommand)
                if !down && consumedSemanticHotkeySinceMod {
                    consumedSemanticHotkeySinceMod = false
                    sendRawKeyFrame(vk: 0x5B, isDown: false, mods: 0)
                } else {
                    if down { consumedSemanticHotkeySinceMod = false }
                    sendRawKeyFrame(vk: 0x5B, isDown: down, mods: currentModBits(flags))
                }
            } else if kc == 56 || kc == 60 { // Shift
                let down = flags.contains(.maskShift)
                sendRawKeyFrame(vk: 0x10, isDown: down, mods: currentModBits(flags))
            } else if kc == 59 || kc == 62 { // Control
                let down = flags.contains(.maskControl)
                if !down { consumedSemanticHotkeySinceMod = false }
                sendRawKeyFrame(vk: 0x11, isDown: down, mods: currentModBits(flags))
            } else if kc == 58 || kc == 61 { // Option -> Alt
                let down = flags.contains(.maskAlternate)
                if !down { consumedSemanticHotkeySinceMod = false }
                sendRawKeyFrame(vk: 0x12, isDown: down, mods: currentModBits(flags))
            }
            lastModifierFlags = flags
            return nil

        case .keyDown, .keyUp:
            let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let isDown = (type == .keyDown)
            let flags = event.flags

            // Profile-driven Semantic Hotkey Translations
            if let action = matchSemanticHotkey(keyCode: kc, flags: flags, engine: engine) {
                if isDown {
                    consumedSemanticHotkeySinceMod = true
                    releaseAllRemoteModifiers()
                    if let frame = WireFrameCodec.encodeJSON(type: .semanticHotkey, value: WireSemanticHotkeyPayload(action: action)) {
                        DeskflowTransport.shared.sendControlFrame(frame)
                    }
                    onLog?("[Hotkey] Mac 快捷键已实时穿透至 Windows: \(action)")
                }
                return nil
            }

            let vk = macKeyCodeToWindowsVK(kc)
            if vk != 0 {
                sendRawKeyFrame(vk: vk, isDown: isDown, mods: currentModBits(flags))
            }
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func currentModBits(_ flags: CGEventFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.maskShift) { mods |= 1 }
        if flags.contains(.maskControl) { mods |= 2 }
        if flags.contains(.maskAlternate) { mods |= 4 }
        if flags.contains(.maskCommand) { mods |= 8 }
        return mods
    }

    private func sendRawKeyFrame(vk: UInt16, isDown: Bool, mods: UInt32) {
        var p = Data(capacity: 7)
        var beVk = vk.bigEndian
        var beMods = mods.bigEndian
        withUnsafeBytes(of: &beVk) { p.append(contentsOf: $0) }
        p.append(isDown ? 1 : 0)
        withUnsafeBytes(of: &beMods) { p.append(contentsOf: $0) }
        DeskflowTransport.shared.sendControlFrame(WireFrameCodec.encode(type: .keyEvent, payload: p))
    }

    // MARK: - Size-Aware File Drag Across Edge

    private func cancelFinderLocalDragGhost() {
        // Send tagged Esc + leftMouseUp locally so Finder aborts its drag icon cleanly without moving the file on Mac
        if let escDown = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true) {
            escDown.setIntegerValueField(.eventSourceUserData, value: MacKvmController.injectedEventTag)
            escDown.post(tap: .cghidEventTap)
        }
        if let escUp = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) {
            escUp.setIntegerValueField(.eventSourceUserData, value: MacKvmController.injectedEventTag)
            escUp.post(tap: .cghidEventTap)
        }
    }

    private func handleLocalFileDragTowardsBoundary(cursorLocation: CGPoint, engine: DeskflowEngine) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        let idx = min(max(0, engine.portalMonitorIndex), screens.count - 1)
        var bounds = CGDisplayBounds(CGMainDisplayID())
        if let num = screens[idx].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            bounds = CGDisplayBounds(CGDirectDisplayID(num.uint32Value))
        }

        let distToPortalEdge: CGFloat
        switch engine.portalEdgeSide {
        case .right:  distToPortalEdge = abs(bounds.maxX - cursorLocation.x)
        case .left:   distToPortalEdge = abs(cursorLocation.x - bounds.minX)
        case .top:    distToPortalEdge = abs(cursorLocation.y - bounds.minY)
        case .bottom: distToPortalEdge = abs(bounds.maxY - cursorLocation.y)
        }

        let nearCross = detect2DBoundaryCrossingToWindows(cursorLocation: cursorLocation, dx: 0, dy: 0, engine: engine, edgeTolerance: 20.0)

        if distToPortalEdge <= 20.0 || nearCross != nil {
            let draggedURLs = extractDraggedFileURLsFromPasteboard()
            guard !draggedURLs.isEmpty, !engine.shouldIgnoreEdgeDrop(urls: draggedURLs) else { return }

            if pendingEdgeDraggedURLs != draggedURLs {
                pendingEdgeDraggedURLs = draggedURLs
                engine.evaluateDragForEdgePrompt(urls: draggedURLs)
            }
            if !isHoveringEdgeWithFile {
                isHoveringEdgeWithFile = true
                PortalOverlayController.shared.setDropHovered(true)
            }
        } else if isHoveringEdgeWithFile && distToPortalEdge > DragHandoffPolicy.hoverCancelDistancePx && nearCross == nil {
            isHoveringEdgeWithFile = false
            pendingEdgeDraggedURLs.removeAll()
            PortalOverlayController.shared.setDropHovered(false)
            if case .hoverExpand = engine.portalPhase {
                engine.portalPhase = .idle
            }
        }
    }

    private func extractDraggedFileURLsFromPasteboard() -> [URL] {
        let pb = NSPasteboard(name: .drag)
        // Strict guard: drag pasteboard changeCount must advance AFTER leftMouseDown so stale drags never trigger on normal window drags
        if dragStartPasteboardCount >= 0 && pb.changeCount == dragStartPasteboardCount {
            return []
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        if let names = pb.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String],
           !names.isEmpty {
            return names.compactMap { path -> URL? in
                guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
                return URL(fileURLWithPath: path)
            }
        }
        if let str = pb.string(forType: .fileURL), let u = URL(string: str), u.isFileURL,
           FileManager.default.fileExists(atPath: u.path) {
            return [u]
        }
        return []
    }

    // MARK: - Strict 2D Seam-Projected Boundary Crossing (Mac <-> Windows)

    private func overlapSpan(_ aMin: CGFloat, _ aMax: CGFloat, _ bMin: CGFloat, _ bMax: CGFloat) -> CGFloat {
        max(0, min(aMax, bMax) - max(aMin, bMin))
    }

    private func detectReturnCrossingToMac(
        normX: Double,
        normY: Double,
        dx: Double,
        dy: Double,
        engine: DeskflowEngine
    ) -> (macMonitorIdx: Int, returnEdge: ScreenEdgeSide, normX: Double, normY: Double)? {
        let macNodes = engine.displayNodes.filter { $0.osKind == .mac }
        let winNodes = engine.displayNodes.filter { $0.osKind == .windows }
        guard !macNodes.isEmpty else { return nil }

        let activeWin = winNodes.first(where: { $0.displayIndex == activeTargetWinMonitorIdx }) ?? winNodes.first
        guard let wRect = activeWin?.rect else { return nil }

        let canvasX = wRect.minX + CGFloat(min(max(normX, 0.0), 1.0)) * wRect.width
        let canvasY = wRect.minY + CGFloat(min(max(normY, 0.0), 1.0)) * wRect.height

        // Left seam of active Windows monitor -> Mac display strictly bordering its LEFT edge
        if normX <= 0.0 && dx < 0 {
            if let mac = macNodes
                .filter({ abs($0.rect.maxX - wRect.minX) <= 36 && overlapSpan(wRect.minY, wRect.maxY, $0.rect.minY, $0.rect.maxY) > 12 })
                .filter({ canvasY >= $0.rect.minY - 8 && canvasY <= $0.rect.maxY + 8 })
                .min(by: { abs($0.rect.maxX - wRect.minX) < abs($1.rect.maxX - wRect.minX) }) {
                let targetY = Double((canvasY - mac.rect.minY) / max(1, mac.rect.height))
                return (mac.displayIndex, .left, 0.97, min(max(targetY, 0.03), 0.97))
            }
        }
        // Right seam of active Windows monitor -> Mac display strictly bordering its RIGHT edge
        if normX >= 1.0 && dx > 0 {
            if let mac = macNodes
                .filter({ abs($0.rect.minX - wRect.maxX) <= 36 && overlapSpan(wRect.minY, wRect.maxY, $0.rect.minY, $0.rect.maxY) > 12 })
                .filter({ canvasY >= $0.rect.minY - 8 && canvasY <= $0.rect.maxY + 8 })
                .min(by: { abs($0.rect.minX - wRect.maxX) < abs($1.rect.minX - wRect.maxX) }) {
                let targetY = Double((canvasY - mac.rect.minY) / max(1, mac.rect.height))
                return (mac.displayIndex, .right, 0.03, min(max(targetY, 0.03), 0.97))
            }
        }
        // Top seam of active Windows monitor -> Mac display strictly bordering its TOP edge
        if normY <= 0.0 && dy < 0 {
            if let mac = macNodes
                .filter({ abs($0.rect.maxY - wRect.minY) <= 36 && overlapSpan(wRect.minX, wRect.maxX, $0.rect.minX, $0.rect.maxX) > 12 })
                .filter({ canvasX >= $0.rect.minX - 8 && canvasX <= $0.rect.maxX + 8 })
                .min(by: { abs($0.rect.maxY - wRect.minY) < abs($1.rect.maxY - wRect.minY) }) {
                let targetX = Double((canvasX - mac.rect.minX) / max(1, mac.rect.width))
                return (mac.displayIndex, .top, min(max(targetX, 0.03), 0.97), 0.97)
            }
        }
        // Bottom seam of active Windows monitor -> ONLY cross if a Mac monitor actually touches the BOTTOM edge!
        if normY >= 1.0 && dy > 0 {
            if let mac = macNodes
                .filter({ abs($0.rect.minY - wRect.maxY) <= 36 && overlapSpan(wRect.minX, wRect.maxX, $0.rect.minX, $0.rect.maxX) > 12 })
                .filter({ canvasX >= $0.rect.minX - 8 && canvasX <= $0.rect.maxX + 8 })
                .min(by: { abs($0.rect.minY - wRect.maxY) < abs($1.rect.minY - wRect.maxY) }) {
                let targetX = Double((canvasX - mac.rect.minX) / max(1, mac.rect.width))
                return (mac.displayIndex, .bottom, min(max(targetX, 0.03), 0.97), 0.03)
            }
        }
        return nil
    }

    private func detect2DBoundaryCrossingToWindows(
        cursorLocation: CGPoint,
        dx: Double,
        dy: Double,
        engine: DeskflowEngine,
        edgeTolerance: CGFloat = 5.0
    ) -> (macMonitorIdx: Int, winMonitorIdx: Int, entryX: Double, entryY: Double, returnEdge: ScreenEdgeSide)? {
        let winNodes = engine.displayNodes.filter { $0.osKind == .windows }
        guard !winNodes.isEmpty else { return nil }

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        var macIdx = 0
        var activeBounds = CGDisplayBounds(CGMainDisplayID())
        for (i, scr) in screens.enumerated() {
            if let num = scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let bounds = CGDisplayBounds(CGDirectDisplayID(num.uint32Value))
                if bounds.insetBy(dx: -6, dy: -6).contains(cursorLocation) {
                    macIdx = i
                    activeBounds = bounds
                    break
                }
            }
        }

        let normX = min(max(Double((cursorLocation.x - activeBounds.minX) / max(1, activeBounds.width)), 0.02), 0.98)
        let normY = min(max(Double((cursorLocation.y - activeBounds.minY) / max(1, activeBounds.height)), 0.02), 0.98)

        let atRight  = cursorLocation.x >= activeBounds.maxX - edgeTolerance && dx >= 0
        let atLeft   = cursorLocation.x <= activeBounds.minX + edgeTolerance && dx <= 0
        let atTop    = cursorLocation.y <= activeBounds.minY + edgeTolerance && dy <= 0
        let atBottom = cursorLocation.y >= activeBounds.maxY - edgeTolerance && dy >= 0

        guard atRight || atLeft || atTop || atBottom else { return nil }

        let macNode = engine.displayNodes.first(where: { $0.osKind == .mac && $0.displayIndex == macIdx })
            ?? engine.displayNodes.first(where: { $0.osKind == .mac })

        guard let mRect = macNode?.rect else { return nil }

        let canvasX = mRect.minX + CGFloat(normX) * mRect.width
        let canvasY = mRect.minY + CGFloat(normY) * mRect.height

        let otherMacRects = engine.displayNodes
            .filter { $0.osKind == .mac && $0.id != macNode?.id }
            .map(\.rect)

        if atRight {
            let macBlocking = otherMacRects.contains { abs($0.minX - mRect.maxX) < 32 && overlapSpan(mRect.minY, mRect.maxY, $0.minY, $0.maxY) > 16 }
            if !macBlocking,
               let target = winNodes
                .filter({ abs($0.rect.minX - mRect.maxX) <= 36 && overlapSpan(mRect.minY, mRect.maxY, $0.rect.minY, $0.rect.maxY) > 12 })
                .filter({ canvasY >= $0.rect.minY - 8 && canvasY <= $0.rect.maxY + 8 })
                .min(by: { abs($0.rect.minX - mRect.maxX) < abs($1.rect.minX - mRect.maxX) }) {
                let targetNormY = min(max(Double((canvasY - target.rect.minY) / max(1, target.rect.height)), 0.03), 0.97)
                return (macIdx, target.displayIndex, 0.03, targetNormY, .left)
            }
        }
        if atLeft {
            let macBlocking = otherMacRects.contains { abs(mRect.minX - $0.maxX) < 32 && overlapSpan(mRect.minY, mRect.maxY, $0.minY, $0.maxY) > 16 }
            if !macBlocking,
               let target = winNodes
                .filter({ abs(mRect.minX - $0.rect.maxX) <= 36 && overlapSpan(mRect.minY, mRect.maxY, $0.rect.minY, $0.rect.maxY) > 12 })
                .filter({ canvasY >= $0.rect.minY - 8 && canvasY <= $0.rect.maxY + 8 })
                .min(by: { abs(mRect.minX - $0.rect.maxX) < abs(mRect.minX - $1.rect.maxX) }) {
                let targetNormY = min(max(Double((canvasY - target.rect.minY) / max(1, target.rect.height)), 0.03), 0.97)
                return (macIdx, target.displayIndex, 0.97, targetNormY, .right)
            }
        }
        if atTop {
            let macBlocking = otherMacRects.contains { abs(mRect.minY - $0.maxY) < 32 && overlapSpan(mRect.minX, mRect.maxX, $0.minX, $0.maxX) > 16 }
            if !macBlocking,
               let target = winNodes
                .filter({ abs(mRect.minY - $0.rect.maxY) <= 36 && overlapSpan(mRect.minX, mRect.maxX, $0.rect.minX, $0.rect.maxX) > 12 })
                .filter({ canvasX >= $0.rect.minX - 8 && canvasX <= $0.rect.maxX + 8 })
                .min(by: { abs(mRect.minY - $0.rect.maxY) < abs(mRect.minY - $1.rect.maxY) }) {
                let targetNormX = min(max(Double((canvasX - target.rect.minX) / max(1, target.rect.width)), 0.03), 0.97)
                return (macIdx, target.displayIndex, targetNormX, 0.97, .bottom)
            }
        }
        if atBottom {
            let macBlocking = otherMacRects.contains { abs($0.minY - mRect.maxY) < 32 && overlapSpan(mRect.minX, mRect.maxX, $0.minX, $0.maxX) > 16 }
            if !macBlocking,
               let target = winNodes
                .filter({ abs($0.rect.minY - mRect.maxY) <= 36 && overlapSpan(mRect.minX, mRect.maxX, $0.rect.minX, $0.rect.maxX) > 12 })
                .filter({ canvasX >= $0.rect.minX - 8 && canvasX <= $0.rect.maxX + 8 })
                .min(by: { abs($0.rect.minY - mRect.maxY) < abs($1.rect.minY - mRect.maxY) }) {
                let targetNormX = min(max(Double((canvasX - target.rect.minX) / max(1, target.rect.width)), 0.03), 0.97)
                return (macIdx, target.displayIndex, targetNormX, 0.03, .top)
            }
        }

        return nil
    }

    private func resolveReturnPointOnMac(macMonitorIdx: Int, returnEdge: ScreenEdgeSide, normX: Double, normY: Double) -> CGPoint? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let idx = min(max(0, macMonitorIdx), screens.count - 1)
        var bounds = CGDisplayBounds(CGMainDisplayID())
        if let num = screens[idx].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            bounds = CGDisplayBounds(CGDirectDisplayID(num.uint32Value))
        }
        let clampedX = min(max(normX, 0.04), 0.96)
        let clampedY = min(max(normY, 0.04), 0.96)
        switch returnEdge {
        case .left:
            return CGPoint(x: bounds.maxX - 14, y: bounds.minY + bounds.height * clampedY)
        case .right:
            return CGPoint(x: bounds.minX + 14, y: bounds.minY + bounds.height * clampedY)
        case .top:
            return CGPoint(x: bounds.minX + bounds.width * clampedX, y: bounds.maxY - 14)
        case .bottom:
            return CGPoint(x: bounds.minX + bounds.width * clampedX, y: bounds.minY + 14)
        }
    }

    func sendMouseMoveAbs(monitorIdx: Int, normX: Double, normY: Double) {
        var p = Data(capacity: 10)
        var beIdx = UInt16(max(0, monitorIdx)).bigEndian
        var nx = Float(normX).bitPattern.bigEndian
        var ny = Float(normY).bitPattern.bigEndian
        withUnsafeBytes(of: &beIdx) { p.append(contentsOf: $0) }
        withUnsafeBytes(of: &nx) { p.append(contentsOf: $0) }
        withUnsafeBytes(of: &ny) { p.append(contentsOf: $0) }
        DeskflowTransport.shared.sendMouseMoveCoalesced(WireFrameCodec.encode(type: .mouseMoveAbs, payload: p))
    }

    private func matchSemanticHotkey(keyCode: UInt16, flags: CGEventFlags, engine: DeskflowEngine) -> String? {
        // Deskflow default passthrough (Command -> Win) unless the user specifically enabled an override rule below.
        let rules = engine.hotkeyRules
        let hasCmd = flags.contains(.maskCommand)
        let hasShift = flags.contains(.maskShift)
        let hasOpt = flags.contains(.maskAlternate)
        let hasCtrl = flags.contains(.maskControl)

        if hasCtrl && hasOpt && keyCode == 7,
           rules.contains(where: { $0.id == "win_quick_x" && $0.enabled }) {
            return "WIN_X_MENU"
        }
        if hasCmd && hasShift && keyCode == 21,
           rules.contains(where: { $0.id == "shot_region" && $0.enabled }) {
            return "WIN_SCREENSHOT_REGION"
        }
        if hasCmd && hasShift && keyCode == 23,
           rules.contains(where: { $0.id == "shot_panel" && $0.enabled }) {
            return "WIN_SCREENSHOT_BAR"
        }
        if hasCmd && hasOpt && keyCode == 0,
           rules.contains(where: { $0.id == "shot_snipaste" && $0.enabled }) {
            return "WIN_ALT_A"
        }
        if hasCmd && !hasShift && keyCode == 48,
           rules.contains(where: { $0.id == "app_switch" && $0.enabled }) {
            return "WIN_ALT_TAB"
        }
        if hasCmd && !hasShift && keyCode == 49,
           rules.contains(where: { $0.id == "search_launcher" && $0.enabled }) {
            return "WIN_SEARCH"
        }
        if hasCmd && !hasOpt && !hasCtrl && !hasShift {
            let map: [UInt16: String] = [8: "WIN_CTRL_C", 9: "WIN_CTRL_V", 7: "WIN_CTRL_X", 0: "WIN_CTRL_A", 6: "WIN_CTRL_Z", 1: "WIN_CTRL_S", 3: "WIN_CTRL_F"]
            if let act = map[keyCode],
               rules.contains(where: { $0.id == "clip_ops" && $0.enabled }) {
                return act
            }
        }
        // Any other Cmd+<Key> keeps standard Deskflow behavior (Command -> Win)
        return nil
    }

    // MARK: - Inject Incoming Windows -> Mac KVM Events (Tagged to avoid bounce-back)

    func injectMouseMoveAbs(monitorIdx: Int, normX: Double, normY: Double) {
        syncInjectorState(kvmEnabled: cachedKvmEnabled, controlMode: cachedControlMode)
        RemoteCursorInjector.shared.injectMouseMoveAbs(monitorIdx: monitorIdx, normX: normX, normY: normY)
    }

    func injectMouseButton(button: UInt8, isDown: Bool) {
        let loc = NSEvent.mouseLocation
        let mainH = NSScreen.screens.first?.frame.height ?? 1080
        let pt = CGPoint(x: loc.x, y: mainH - loc.y)
        let type: CGEventType = (button == 2)
            ? (isDown ? .rightMouseDown : .rightMouseUp)
            : (isDown ? .leftMouseDown : .leftMouseUp)
        let cgBtn: CGMouseButton = (button == 2) ? .right : .left
        if let ev = CGEvent(mouseEventSource: RemoteCursorInjector.shared.sharedEventSource(), mouseType: type, mouseCursorPosition: pt, mouseButton: cgBtn) {
            ev.setIntegerValueField(.eventSourceUserData, value: MacKvmController.injectedEventTag)
            ev.post(tap: .cghidEventTap)
        }
    }

    func injectMouseScroll(dy: Int32, dx: Int32) {
        if let ev = CGEvent(scrollWheelEvent2Source: RemoteCursorInjector.shared.sharedEventSource(), units: .line, wheelCount: 2, wheel1: dy, wheel2: -dx, wheel3: 0) {
            ev.setIntegerValueField(.eventSourceUserData, value: MacKvmController.injectedEventTag)
            ev.post(tap: .cghidEventTap)
        }
    }

    func injectKeyEvent(vkCode: UInt16, isDown: Bool, modifiers: UInt32) {
        let macKc = windowsVKToMacKeyCode(vkCode)
        guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: macKc, keyDown: isDown) else { return }
        var cgFlags: CGEventFlags = []
        if (modifiers & 1) != 0 { cgFlags.insert(.maskShift) }
        if (modifiers & 2) != 0 { cgFlags.insert(.maskControl) }
        if (modifiers & 4) != 0 { cgFlags.insert(.maskAlternate) }
        if (modifiers & 8) != 0 { cgFlags.insert(.maskCommand) }
        ev.flags = cgFlags
        ev.setIntegerValueField(.eventSourceUserData, value: MacKvmController.injectedEventTag)
        ev.post(tap: .cghidEventTap)
    }

    func injectSemanticHotkey(action: String) {
        func sendMacCombo(keyCode: CGKeyCode, flags: CGEventFlags) {
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
               let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
                down.flags = flags
                up.flags = flags
                down.setIntegerValueField(.eventSourceUserData, value: MacKvmController.injectedEventTag)
                up.setIntegerValueField(.eventSourceUserData, value: MacKvmController.injectedEventTag)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        }

        switch action {
        case "MAC_SCREENSHOT_REGION":
            sendMacCombo(keyCode: 21, flags: [.maskCommand, .maskShift]) // Cmd + Shift + 4
        case "MAC_CMD_C":
            sendMacCombo(keyCode: 8, flags: [.maskCommand])
        case "MAC_CMD_V":
            sendMacCombo(keyCode: 9, flags: [.maskCommand])
        case "MAC_CMD_X":
            sendMacCombo(keyCode: 7, flags: [.maskCommand])
        case "MAC_CMD_A":
            sendMacCombo(keyCode: 0, flags: [.maskCommand])
        case "MAC_CMD_Z":
            sendMacCombo(keyCode: 6, flags: [.maskCommand])
        case "MAC_CMD_S":
            sendMacCombo(keyCode: 1, flags: [.maskCommand])
        case "MAC_CMD_F":
            sendMacCombo(keyCode: 3, flags: [.maskCommand])
        case "MAC_CMD_TAB":
            sendMacCombo(keyCode: 48, flags: [.maskCommand])
        case "MAC_SPOTLIGHT":
            sendMacCombo(keyCode: 49, flags: [.maskCommand])
        default:
            break
        }
    }

    private static let macToWinKeyMap: [UInt16: UInt16] = [
        0: 0x41, 11: 0x42, 8: 0x43, 2: 0x44, 14: 0x45, 3: 0x46, 5: 0x47, 4: 0x48,
        34: 0x49, 38: 0x4A, 40: 0x4B, 37: 0x4C, 46: 0x4D, 45: 0x4E, 31: 0x4F, 35: 0x50,
        12: 0x51, 15: 0x52, 1: 0x53, 17: 0x54, 32: 0x55, 9: 0x56, 13: 0x57, 7: 0x58,
        16: 0x59, 6: 0x5A,
        29: 0x30, 18: 0x31, 19: 0x32, 20: 0x33, 21: 0x34, 23: 0x35, 22: 0x36, 26: 0x37, 28: 0x38, 25: 0x39,
        36: 0x0D, 48: 0x09, 49: 0x20, 51: 0x08, 53: 0x1B, 117: 0x2E,
        123: 0x25, 124: 0x27, 125: 0x28, 126: 0x26,
        115: 0x24, 119: 0x23, 116: 0x21, 121: 0x22,
        27: 0xBD, 24: 0xBB, 33: 0xDB, 30: 0xDD, 42: 0xDC, 41: 0xBA, 39: 0xDE, 43: 0xBC, 47: 0xBE, 44: 0xBF, 50: 0xC0,
        122: 0x70, 120: 0x71, 99: 0x72, 118: 0x73, 96: 0x74, 97: 0x75, 98: 0x76, 100: 0x77, 101: 0x78, 109: 0x79, 103: 0x7A, 111: 0x7B
    ]

    private static let winToMacKeyMap: [UInt16: CGKeyCode] = [
        0x41: 0, 0x42: 11, 0x43: 8, 0x44: 2, 0x45: 14, 0x46: 3, 0x47: 5, 0x48: 4,
        0x49: 34, 0x4A: 38, 0x4B: 40, 0x4C: 37, 0x4D: 46, 0x4E: 45, 0x4F: 31, 0x50: 35,
        0x51: 12, 0x52: 15, 0x53: 1, 0x54: 17, 0x55: 32, 0x56: 9, 0x57: 13, 0x58: 7,
        0x59: 16, 0x5A: 6,
        0x30: 29, 0x31: 18, 0x32: 19, 0x33: 20, 0x34: 21, 0x35: 23, 0x36: 22, 0x37: 26, 0x38: 28, 0x39: 25,
        0x0D: 36, 0x09: 48, 0x20: 49, 0x08: 51, 0x1B: 53, 0x2E: 117,
        0x25: 123, 0x27: 124, 0x28: 125, 0x26: 126,
        0x5B: 55
    ]

    private func macKeyCodeToWindowsVK(_ kc: UInt16) -> UInt16 {
        Self.macToWinKeyMap[kc] ?? 0
    }

    private func windowsVKToMacKeyCode(_ vk: UInt16) -> CGKeyCode {
        Self.winToMacKeyMap[vk] ?? 49
    }
}
