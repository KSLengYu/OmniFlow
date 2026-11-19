import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

/// Lock-free / non-blocking per-stage KVM transition logger that writes directly to
/// `~/Library/Logs/OmniFlow/omniflow.log` via atomic O_APPEND writes with event sequence numbers
/// and monotonic offsets, bypassing `@MainActor` and optional `onLog` closures so no line is dropped.
final class KvmStageTracer: @unchecked Sendable {
    static let shared = KvmStageTracer()

    private let lock = NSLock()
    private let fileQueue = DispatchQueue(label: "com.lee.omniflow.kvm.stage.log", qos: .utility)
    private let defaultLogURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/OmniFlow/omniflow.log")
    private let wallFmt: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    private var seq: UInt64 = 0
    private var t0Ns: UInt64 = 0
    private var remainingNetMoveLogs: Int = 0
    private var remainingInjectMoveLogs: Int = 0

    func beginFocusSwitch(targetOs: String, recvNs: UInt64 = DispatchTime.now().uptimeNanoseconds) -> (seq: UInt64, recvNs: UInt64) {
        lock.lock()
        seq &+= 1
        let s = seq
        t0Ns = recvNs
        if targetOs == "macOS" {
            remainingNetMoveLogs = 3
            remainingInjectMoveLogs = 3
        } else {
            remainingNetMoveLogs = 0
            remainingInjectMoveLogs = 0
        }
        lock.unlock()
        return (s, recvNs)
    }

    func currentTrace() -> (seq: UInt64, t0Ns: UInt64) {
        lock.lock()
        let res = (seq, t0Ns)
        lock.unlock()
        return res
    }

    func takeNetMoveSlot(nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) -> (seq: UInt64, idx: Int, nowNs: UInt64, t0Ns: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        guard remainingNetMoveLogs > 0, nowNs >= t0Ns, (nowNs - t0Ns) <= 2_000_000_000 else { return nil }
        let idx = 4 - remainingNetMoveLogs
        remainingNetMoveLogs -= 1
        return (seq, idx, nowNs, t0Ns)
    }

    func takeInjectMoveSlot(nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) -> (seq: UInt64, idx: Int, nowNs: UInt64, t0Ns: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        guard remainingInjectMoveLogs > 0, nowNs >= t0Ns, (nowNs - t0Ns) <= 2_000_000_000 else { return nil }
        let idx = 4 - remainingInjectMoveLogs
        remainingInjectMoveLogs -= 1
        return (seq, idx, nowNs, t0Ns)
    }

    private static func appendLinePOSIX(url: URL, line: String) {
        guard let data = line.data(using: .utf8), !data.isEmpty else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 {
            data.withUnsafeBytes { rawBuf in
                if let base = rawBuf.baseAddress {
                    _ = Darwin.write(fd, base, rawBuf.count)
                }
            }
            Darwin.close(fd)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    func log(
        seq: UInt64,
        t0Ns: UInt64,
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds,
        customURL: URL? = nil,
        sync: Bool = false,
        _ detail: String
    ) {
        let deltaMs = nowNs >= t0Ns ? Double(nowNs - t0Ns) / 1_000_000.0 : 0.0
        let msStr = String(format: "%.2f", deltaMs)
        lock.lock()
        let wall = wallFmt.string(from: Date())
        lock.unlock()
        let line = "[\(wall)] [KVM-Stage seq=#\(seq) +\(msStr)ms] \(detail)\n"
        let url = customURL ?? defaultLogURL
        if sync {
            fileQueue.sync {
                Self.appendLinePOSIX(url: url, line: line)
            }
        } else {
            fileQueue.async {
                Self.appendLinePOSIX(url: url, line: line)
            }
        }
    }
}

/// Thread-safe cached display bounds, cursor visibility state, and entry-timing trace
/// so Windows -> Mac focus switches ALWAYS restore cursor visibility BEFORE applying
/// coordinates directly on the transport receive queue without @MainActor hops or backward snap.
private final class RemoteCursorInjector: @unchecked Sendable {
    static let shared = RemoteCursorInjector()

    struct FocusTimingTrace {
        let epoch: UInt64
        let tRecvNs: UInt64
        let tRestoreStartNs: UInt64
        let tCursorShownNs: UInt64
        var tMainActorDoneNs: UInt64
        var tFirstMoveNs: UInt64
        let wasHidden: Bool
        let entryPt: CGPoint
        var firstMovePt: CGPoint?
        var emitted: Bool
    }

    private let lock = NSLock()
    private var bounds: [CGRect] = []
    private var injectAllowed: Bool = true
    private var remoteFocusActive: Bool = false
    private var cursorHidden: Bool = false
    private var hiddenDisplayIds: [CGDirectDisplayID] = []
    private var bgCursorConfigured: Bool = false
    private var moveSeq: UInt64 = 0
    private var focusEpoch: UInt64 = 0
    private var lastInjectedPoint: CGPoint?
    private var pendingTiming: FocusTimingTrace?
    private var timingLogger: (@Sendable (String) -> Void)?
    private let eventSource: CGEventSource? = {
        let src = CGEventSource(stateID: .privateState)
        src?.localEventsSuppressionInterval = 0.0
        return src
    }()

    var isRemoteFocusActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return remoteFocusActive
    }

    var isCursorHidden: Bool {
        lock.lock(); defer { lock.unlock() }
        return cursorHidden
    }

    func setTimingLogger(_ logger: (@Sendable (String) -> Void)?) {
        lock.lock()
        self.timingLogger = logger
        lock.unlock()
    }

    func setRemoteFocusActive(_ active: Bool) {
        lock.lock()
        self.remoteFocusActive = active
        lock.unlock()
    }

    func update(bounds: [CGRect], allowed: Bool) {
        lock.lock()
        self.bounds = bounds
        self.injectAllowed = allowed
        lock.unlock()
    }

    func sharedEventSource() -> CGEventSource? { eventSource }

    private static let cgHandle: UnsafeMutableRawPointer? = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
    private typealias FnMainConn = @convention(c) () -> UInt32
    private typealias FnSetProp = @convention(c) (UInt32, UInt32, CFString, CFTypeRef) -> Int32
    private typealias FnSetSuppression = @convention(c) (Double) -> Int32
    private typealias FnSetFilter = @convention(c) (UInt32, UInt32) -> Int32
    private static let fnMainConn: FnMainConn? = cgHandle.flatMap { dlsym($0, "CGSMainConnectionID") }.map { unsafeBitCast($0, to: FnMainConn.self) }
    private static let fnSetProp: FnSetProp? = cgHandle.flatMap { dlsym($0, "CGSSetConnectionProperty") }.map { unsafeBitCast($0, to: FnSetProp.self) }
    private static let fnSetSuppression: FnSetSuppression? = cgHandle.flatMap { dlsym($0, "CGSetLocalEventsSuppressionInterval") }.map { unsafeBitCast($0, to: FnSetSuppression.self) }
    private static let fnSetFilter: FnSetFilter? = cgHandle.flatMap { dlsym($0, "CGSetLocalEventsFilterDuringSupressionState") }.map { unsafeBitCast($0, to: FnSetFilter.self) }

    func ensureBackgroundCursorControl() {
        lock.lock()
        ensureBackgroundCursorControlLocked()
        lock.unlock()
    }

    private func ensureBackgroundCursorControlLocked() {
        guard !bgCursorConfigured else { return }
        bgCursorConfigured = true
        guard let mainConn = Self.fnMainConn, let setProp = Self.fnSetProp else { return }
        let cid = mainConn()
        _ = setProp(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    private func avoidSuppressionLocked() {
        _ = Self.fnSetSuppression?(0.0)
        // kCGEventFilterMaskPermitAllEvents = 0x7, kCGEventSupressionStateSupressionInterval = 0
        _ = Self.fnSetFilter?(0x00000007, 0)
        // kCGEventFilterMaskPermitLocalKeyboardEvents | kCGEventFilterMaskPermitSystemDefinedEvents = 0x6, RemoteMouseDrag = 1
        _ = Self.fnSetFilter?(0x00000006, 1)
    }

    func hideAndParkCursor(parkPoint: CGPoint) {
        lock.lock()
        ensureBackgroundCursorControlLocked()
        avoidSuppressionLocked()
        remoteFocusActive = true
        CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
        CGWarpMouseCursorPosition(parkPoint)
        if !cursorHidden {
            var ids = [CGDirectDisplayID](repeating: 0, count: 16)
            var count: UInt32 = 0
            if CGGetActiveDisplayList(16, &ids, &count) == .success && count > 0 {
                hiddenDisplayIds = Array(ids.prefix(Int(count)))
            } else {
                hiddenDisplayIds = [CGMainDisplayID()]
            }
            for did in hiddenDisplayIds {
                CGDisplayHideCursor(did)
            }
            cursorHidden = true
        }
        lock.unlock()
    }

    /// Restores cursor visibility & mouse association if currently hidden, optionally warping FIRST
    /// while still hidden/dissociated and clearing macOS's 250ms CGWarpMouseCursorPosition suppression interval.
    @discardableResult
    func restoreCursorVisibilityIfNeeded(warpTo targetPoint: CGPoint? = nil) -> Bool {
        lock.lock()
        ensureBackgroundCursorControlLocked()
        avoidSuppressionLocked()
        if let pt = targetPoint {
            CGWarpMouseCursorPosition(pt)
            lastInjectedPoint = pt
        }
        let (wasHidden, _, _) = restoreVisibilityLocked()
        remoteFocusActive = false
        avoidSuppressionLocked()
        lock.unlock()
        return wasHidden
    }

    private func restoreVisibilityLocked() -> (wasHidden: Bool, showErrs: [Int32], assocErr: Int32) {
        let wasHidden = cursorHidden
        var showErrs: [Int32] = []
        var assocErr: Int32 = 0
        if wasHidden {
            ensureBackgroundCursorControlLocked()
            let toShow = hiddenDisplayIds.isEmpty ? [CGMainDisplayID()] : hiddenDisplayIds
            for did in toShow {
                showErrs.append(CGDisplayShowCursor(did).rawValue)
            }
            hiddenDisplayIds.removeAll()
            cursorHidden = false
            assocErr = CGAssociateMouseAndMouseCursorPosition(boolean_t(1)).rawValue
        } else if remoteFocusActive {
            assocErr = CGAssociateMouseAndMouseCursorPosition(boolean_t(1)).rawValue
        }
        return (wasHidden, showErrs, assocErr)
    }

    private func resolvePointLocked(bList: [CGRect], monitorIdx: Int, normX: Double, normY: Double) -> CGPoint {
        let b: CGRect
        if !bList.isEmpty {
            b = bList[min(max(0, monitorIdx), bList.count - 1)]
        } else {
            b = CGDisplayBounds(CGMainDisplayID())
        }
        let maxX = b.minX + max(0.0, b.width - 1.0)
        let maxY = b.minY + max(0.0, b.height - 1.0)
        let rawX = b.minX + b.width * min(max(normX, 0.0), 1.0)
        let rawY = b.minY + b.height * min(max(normY, 0.0), 1.0)
        return CGPoint(
            x: min(max(rawX, b.minX), maxX),
            y: min(max(rawY, b.minY), maxY)
        )
    }

    private func postMouseMovedLocked(to pt: CGPoint, deltaX: Double, deltaY: Double) -> Bool {
        guard let ev = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left) else {
            return false
        }
        ev.setIntegerValueField(.mouseEventDeltaX, value: Int64(deltaX.rounded()))
        ev.setIntegerValueField(.mouseEventDeltaY, value: Int64(deltaY.rounded()))
        ev.setDoubleValueField(.mouseEventDeltaX, value: deltaX)
        ev.setDoubleValueField(.mouseEventDeltaY, value: deltaY)
        ev.setIntegerValueField(.eventSourceUserData, value: MacKvmController.injectedEventTag)
        ev.post(tap: .cghidEventTap)
        return true
    }

    /// Invoked immediately on transport receive queue when KvmFocusSwitch("macOS") arrives:
    /// Aligned with Deskflow Client::enter -> OSXComputer::fakeMouseMove + OSXComputer::enter (showCursor + avoidSupression):
    /// 1) Ensure background cursor control & pre-warp to entryPt if dissociated/parked (avoid parked-point flash),
    /// 2) Restore visibility & association + avoid suppression,
    /// 3) Post fakeMouseMove to entryPt and record stage timestamps.
    func prepareCursorForIncomingFocus(monitorIdx: Int, normX: Double, normY: Double, recvNs: UInt64, stageSeq: UInt64) -> UInt64 {
        lock.lock()
        focusEpoch &+= 1
        let epoch = focusEpoch
        let preHidden = cursorHidden
        let preHiddenIds = hiddenDisplayIds
        let preRemoteActive = remoteFocusActive
        let preInjectAllowed = injectAllowed
        let preBoundsCount = bounds.count

        let allowed = injectAllowed || cursorHidden
        let entryPt = resolvePointLocked(bList: bounds, monitorIdx: monitorIdx, normX: normX, normY: normY)

        ensureBackgroundCursorControlLocked()
        let tRestoreStart = DispatchTime.now().uptimeNanoseconds
        if allowed && (cursorHidden || remoteFocusActive) {
            // Warp while still hidden/dissociated so showing cursor never flashes at parkedCursorPoint.
            CGWarpMouseCursorPosition(entryPt)
        }
        remoteFocusActive = false
        let (wasHidden, showErrs, assocErr) = restoreVisibilityLocked()
        avoidSuppressionLocked()
        let tCursorShown = DispatchTime.now().uptimeNanoseconds

        var evCreated = false
        let srcOk = (eventSource != nil)
        var postLocStr = "n/a"
        if allowed {
            moveSeq &+= 1
            lastInjectedPoint = entryPt
            evCreated = postMouseMovedLocked(to: entryPt, deltaX: 0.0, deltaY: 0.0)
            if let curLoc = CGEvent(source: nil)?.location {
                postLocStr = String(format: "(%.1f,%.1f)", curLoc.x, curLoc.y)
            }
        }
        let tEntryPosted = DispatchTime.now().uptimeNanoseconds
        pendingTiming = FocusTimingTrace(
            epoch: epoch,
            tRecvNs: recvNs,
            tRestoreStartNs: tRestoreStart,
            tCursorShownNs: tCursorShown,
            tMainActorDoneNs: 0,
            tFirstMoveNs: 0,
            wasHidden: wasHidden,
            entryPt: entryPt,
            firstMovePt: nil,
            emitted: false
        )
        lock.unlock()

        KvmStageTracer.shared.log(
            seq: stageSeq,
            t0Ns: recvNs,
            nowNs: tRestoreStart,
            "prepareStart wasHidden=\(preHidden) hiddenIds=\(preHiddenIds) remoteActive=\(preRemoteActive) injectAllowed=\(preInjectAllowed) bounds=\(preBoundsCount)"
        )
        KvmStageTracer.shared.log(
            seq: stageSeq,
            t0Ns: recvNs,
            nowNs: tCursorShown,
            "cursorRestored wasHidden=\(wasHidden) showErrs=\(showErrs) assocErr=\(assocErr)"
        )
        let ptX = String(format: "%.1f", entryPt.x)
        let ptY = String(format: "%.1f", entryPt.y)
        KvmStageTracer.shared.log(
            seq: stageSeq,
            t0Ns: recvNs,
            nowNs: tEntryPosted,
            "entryEventPosted ok=\(evCreated) src=\(srcOk) allowed=\(allowed) target=(\(ptX),\(ptY)) actualLoc=\(postLocStr)"
        )

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.flushTimingIfPending(epoch: epoch)
        }
        return epoch
    }

    func injectMouseMoveAbs(monitorIdx: Int, normX: Double, normY: Double) {
        var readyTrace: FocusTimingTrace?
        var logger: (@Sendable (String) -> Void)?
        let slot = KvmStageTracer.shared.takeInjectMoveSlot()

        lock.lock()
        guard injectAllowed else {
            lock.unlock()
            if let slot {
                KvmStageTracer.shared.log(seq: slot.seq, t0Ns: slot.t0Ns, nowNs: slot.nowNs, "moveInjectBlocked #\(slot.idx) reason=injectAllowedFalse")
            }
            return
        }
        let pt = resolvePointLocked(bList: bounds, monitorIdx: monitorIdx, normX: normX, normY: normY)
        // Always ensure cursor is visible & associated BEFORE posting any coordinates
        if cursorHidden || remoteFocusActive {
            ensureBackgroundCursorControlLocked()
            CGWarpMouseCursorPosition(pt)
            _ = restoreVisibilityLocked()
            avoidSuppressionLocked()
            remoteFocusActive = false
        }
        let prevPt = lastInjectedPoint ?? pt
        let dx = pt.x - prevPt.x
        let dy = pt.y - prevPt.y
        moveSeq &+= 1
        lastInjectedPoint = pt

        let evOk = postMouseMovedLocked(to: pt, deltaX: dx, deltaY: dy)
        let tAfterPost = DispatchTime.now().uptimeNanoseconds

        if var trace = pendingTiming, trace.tFirstMoveNs == 0 {
            trace.tFirstMoveNs = tAfterPost
            trace.firstMovePt = pt
            if trace.tMainActorDoneNs != 0 && !trace.emitted {
                trace.emitted = true
                readyTrace = trace
                logger = timingLogger
            }
            pendingTiming = trace
        }
        lock.unlock()

        if let slot {
            let ptx = String(format: "%.1f", pt.x)
            let pty = String(format: "%.1f", pt.y)
            KvmStageTracer.shared.log(
                seq: slot.seq,
                t0Ns: slot.t0Ns,
                nowNs: tAfterPost,
                "moveInjected #\(slot.idx) ok=\(evOk) pt=(\(ptx),\(pty))"
            )
        }

        if let readyTrace {
            emitTiming(readyTrace, logger: logger)
        }
    }

    func markMainActorDone(epoch: UInt64) {
        var readyTrace: FocusTimingTrace?
        var logger: (@Sendable (String) -> Void)?

        lock.lock()
        if var trace = pendingTiming, trace.epoch == epoch {
            trace.tMainActorDoneNs = DispatchTime.now().uptimeNanoseconds
            if trace.tFirstMoveNs != 0 && !trace.emitted {
                trace.emitted = true
                readyTrace = trace
                logger = timingLogger
            }
            pendingTiming = trace
        }
        lock.unlock()

        if let readyTrace {
            emitTiming(readyTrace, logger: logger)
        }
    }

    private func flushTimingIfPending(epoch: UInt64) {
        var readyTrace: FocusTimingTrace?
        var logger: (@Sendable (String) -> Void)?

        lock.lock()
        if var trace = pendingTiming, trace.epoch == epoch, !trace.emitted {
            trace.emitted = true
            pendingTiming = trace
            readyTrace = trace
            logger = timingLogger
        }
        lock.unlock()

        if let readyTrace {
            emitTiming(readyTrace, logger: logger)
        }
    }

    private func emitTiming(_ trace: FocusTimingTrace, logger: (@Sendable (String) -> Void)?) {
        guard let logger else { return }
        func fmtMs(_ ns: UInt64) -> String {
            guard ns > 0 else { return "none" }
            let delta = ns >= trace.tRecvNs ? Double(ns - trace.tRecvNs) : 0.0
            return String(format: "+%.2fms", delta / 1_000_000.0)
        }
        let nextStr: String
        if let fpt = trace.firstMovePt {
            nextStr = String(format: "(%.1f,%.1f)->(%.1f,%.1f)", trace.entryPt.x, trace.entryPt.y, fpt.x, fpt.y)
        } else {
            nextStr = String(format: "(%.1f,%.1f)", trace.entryPt.x, trace.entryPt.y)
        }
        let msg = "[KVM-Timing] Win→Mac wasHidden=\(trace.wasHidden) restoreStart=\(fmtMs(trace.tRestoreStartNs)) cursorShown=\(fmtMs(trace.tCursorShownNs)) firstMove=\(fmtMs(trace.tFirstMoveNs)) mainActor=\(fmtMs(trace.tMainActorDoneNs)) pt=\(nextStr)"
        logger(msg)
    }
}

/// Handles real macOS CGEventTap KVM capture & CGEventPost injection + 2D Spatial Monitor Crossing + File Drag Across Edge + Keymap Profiles.
@MainActor
final class MacKvmController {
    static let shared = MacKvmController()
    nonisolated static let injectedEventTag: Int64 = 0x4F4D4E49

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var virtualNormX: Double = 0.5
    private var virtualNormY: Double = 0.5
    private var activeTargetWinMonitorIdx: Int = 0
    private var sourceMacMonitorIdx: Int = 0
    private var returnEdgeOnWin: ScreenEdgeSide = .left
    private var lastEdgeCrossTime: Date = .distantPast
    private var suppressDeltaUntil: Date = .distantPast
    private var parkedCursorPoint: CGPoint?
    private var bgCursorEnabled = false
    private var axPollTimer: Timer?
    private var lastModifierFlags: CGEventFlags = []
    private var dragStartPasteboardCount: Int = -1
    private var isHoveringEdgeWithFile: Bool = false
    private var pendingEdgeDraggedURLs: [URL] = []
    private var consumedSemanticHotkeySinceMod: Bool = false
    private var remoteMouseButtonsDown: Set<UInt8> = []
    private var suppressEdgeCrossUntil: Date = .distantPast

    // Three-finger trackpad drag state (Mac -> Windows)
    private var mtHandle: UnsafeMutableRawPointer?
    private var mtDevices: [UnsafeMutableRawPointer] = []
    private var activeTrackpadFingers: Int = 0
    private var gestureStartCentroid: CGPoint?
    private var gesturePrevCentroid: CGPoint?
    private var gestureStartTime: Date = .distantPast
    private var isThreeFingerDragging: Bool = false
    private var lastThreeFingerMoveTime: Date = .distantPast
    private var smooth3fDx: Double = 0.0
    private var smooth3fDy: Double = 0.0
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
        syncInjectorState(kvmEnabled: DeskflowEngine.shared.kvmEnabled, controlMode: DeskflowEngine.shared.kvmControlMode)
        RemoteCursorInjector.shared.setTimingLogger { [weak self] msg in
            Task { @MainActor [weak self] in
                self?.onLog?(msg)
            }
        }
        onLog?("[KVM] macOS 全局键鼠捕获已就绪 (双端互控/主控可配 · 2D接缝穿屏 · 多指触控板手势)")
    }

    func stopTap() {
        setRemoteFocus(false)
        stopMultitouchTrackpadMonitor()
        syncInjectorState(kvmEnabled: false, controlMode: DeskflowEngine.shared.kvmControlMode)
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

    private func sendMouseMoveAbs(monitorIdx: Int, normX: Double, normY: Double) {
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
        let engine = DeskflowEngine.shared
        syncInjectorState(kvmEnabled: engine.kvmEnabled, controlMode: engine.kvmControlMode)
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

    // MARK: - MacBook Built-in Multitouch Trackpad Monitor (Mac -> Windows 3-Finger Drag)

    func startMultitouchTrackpadMonitor() {
        guard mtHandle == nil else { return }
        let fwPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(fwPath, RTLD_LAZY),
              let symList = dlsym(handle, "MTDeviceCreateList"),
              let symReg = dlsym(handle, "MTRegisterContactFrameCallback"),
              let symStart = dlsym(handle, "MTDeviceStart") else {
            return
        }
        mtHandle = handle

        typealias FnList = @convention(c) () -> Unmanaged<CFArray>?
        typealias FnReg = @convention(c) (UnsafeMutableRawPointer, MTContactCallbackFn) -> Void
        typealias FnStart = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void

        let fnList = unsafeBitCast(symList, to: FnList.self)
        let fnReg = unsafeBitCast(symReg, to: FnReg.self)
        let fnStart = unsafeBitCast(symStart, to: FnStart.self)

        guard let cfArr = fnList()?.takeRetainedValue() else { return }
        let count = CFArrayGetCount(cfArr)
        for i in 0..<count {
            guard let devPtr = CFArrayGetValueAtIndex(cfArr, i) else { continue }
            let mutDev = UnsafeMutableRawPointer(mutating: devPtr)
            fnReg(mutDev, omniMTContactCallback)
            fnStart(mutDev, 0)
            mtDevices.append(mutDev)
        }
    }

    func stopMultitouchTrackpadMonitor() {
        guard let handle = mtHandle else { return }
        typealias FnUnreg = @convention(c) (UnsafeMutableRawPointer, MTContactCallbackFn) -> Void
        typealias FnStop = @convention(c) (UnsafeMutableRawPointer) -> Void

        let fnUnreg = dlsym(handle, "MTUnregisterContactFrameCallback").map { unsafeBitCast($0, to: FnUnreg.self) }
        let fnStop = dlsym(handle, "MTDeviceStop").map { unsafeBitCast($0, to: FnStop.self) }

        for dev in mtDevices {
            fnUnreg?(dev, omniMTContactCallback)
            fnStop?(dev)
        }
        mtDevices.removeAll()
        mtHandle = nil
    }

    func handleTrackpadContacts(_ touches: [MTSamplePoint]) {
        let engine = DeskflowEngine.shared
        guard engine.remoteFocusOnWindows, engine.kvmEnabled else {
            if isThreeFingerDragging {
                isThreeFingerDragging = false
                DeskflowTransport.shared.sendControlFrame(WireFrameCodec.encode(type: .mouseButton, payload: Data([1, 0])))
            }
            activeTrackpadFingers = 0
            gestureStartCentroid = nil
            gesturePrevCentroid = nil
            smooth3fDx = 0.0
            smooth3fDy = 0.0
            return
        }

        let count = touches.count
        activeTrackpadFingers = count

        // Require exactly 3 fingers; immediately release cleanly on lift-off without applying lift centroid shift
        if count != 3 || !engine.isRuleEnabled("mac_tp_3f_drag") {
            if isThreeFingerDragging {
                isThreeFingerDragging = false
                DeskflowTransport.shared.sendControlFrame(WireFrameCodec.encode(type: .mouseButton, payload: Data([1, 0])))
            }
            gestureStartCentroid = nil
            gesturePrevCentroid = nil
            smooth3fDx = 0.0
            smooth3fDy = 0.0
            return
        }

        let avgX = touches.reduce(0.0) { $0 + Double($1.x) } / 3.0
        let avgY = touches.reduce(0.0) { $0 + Double($1.y) } / 3.0
        let centroid = CGPoint(x: avgX, y: avgY)

        if gestureStartCentroid == nil {
            gestureStartCentroid = centroid
            gesturePrevCentroid = centroid
            gestureStartTime = Date()
            smooth3fDx = 0.0
            smooth3fDy = 0.0
            return
        }

        guard let start = gestureStartCentroid, let prev = gesturePrevCentroid else { return }
        let rawDx = centroid.x - prev.x
        // MultitouchSupport normalized.y runs 0 (bottom) -> 1 (top), opposite screen Y
        let rawDy = -(centroid.y - prev.y)
        gesturePrevCentroid = centroid

        // Reject single-frame centroid jump spikes (e.g., palm brush or non-simultaneous finger landing/lift)
        if hypot(rawDx, rawDy) > 0.065 {
            smooth3fDx = 0.0
            smooth3fDy = 0.0
            return
        }

        if !isThreeFingerDragging {
            let heldLongEnough = Date().timeIntervalSince(gestureStartTime) >= 0.035
            let distFromStart = hypot(centroid.x - start.x, centroid.y - start.y)
            if heldLongEnough && distFromStart >= 0.012 {
                isThreeFingerDragging = true
                DeskflowTransport.shared.sendControlFrame(WireFrameCodec.encode(type: .mouseButton, payload: Data([1, 1])))
            }
            return
        }

        // Ignore micro-tremble deadzone and lightly smooth + throttle to ~70Hz so high-latency Wi-Fi doesn't queue laggy drift
        if hypot(rawDx, rawDy) < 0.0010 { return }
        smooth3fDx = smooth3fDx * 0.25 + rawDx * 0.75
        smooth3fDy = smooth3fDy * 0.25 + rawDy * 0.75
        virtualNormX = min(max(virtualNormX + smooth3fDx * 1.05, 0.0), 1.0)
        virtualNormY = min(max(virtualNormY + smooth3fDy * 1.05, 0.0), 1.0)

        let now = Date()
        if now.timeIntervalSince(lastThreeFingerMoveTime) >= 0.014 {
            lastThreeFingerMoveTime = now
            sendMouseMoveAbs(monitorIdx: activeTargetWinMonitorIdx, normX: virtualNormX, normY: virtualNormY)
        }
    }

    private func macKeyCodeToWindowsVK(_ kc: UInt16) -> UInt16 {
        let table: [UInt16: UInt16] = [
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
        return table[kc] ?? 0
    }

    private func windowsVKToMacKeyCode(_ vk: UInt16) -> CGKeyCode {
        let table: [UInt16: CGKeyCode] = [
            0x41: 0, 0x42: 11, 0x43: 8, 0x44: 2, 0x45: 14, 0x46: 3, 0x47: 5, 0x48: 4,
            0x49: 34, 0x4A: 38, 0x4B: 40, 0x4C: 37, 0x4D: 46, 0x4E: 45, 0x4F: 31, 0x50: 35,
            0x51: 12, 0x52: 15, 0x53: 1, 0x54: 17, 0x55: 32, 0x56: 9, 0x57: 13, 0x58: 7,
            0x59: 16, 0x5A: 6,
            0x30: 29, 0x31: 18, 0x32: 19, 0x33: 20, 0x34: 21, 0x35: 23, 0x36: 22, 0x37: 26, 0x38: 28, 0x39: 25,
            0x0D: 36, 0x09: 48, 0x20: 49, 0x08: 51, 0x1B: 53, 0x2E: 117,
            0x25: 123, 0x27: 124, 0x28: 125, 0x26: 126,
            0x5B: 55
        ]
        return table[vk] ?? 49
    }
}

struct MTVector {
    var x: Float
    var y: Float
}

struct MTReadout {
    var position: MTVector
    var velocity: MTVector
}

struct MTContact {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var foo3: Int32
    var foo4: Int32
    var normalized: MTReadout
    var size: Float
    var unk2: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var mm: MTReadout
    var unk3_0: Int32
    var unk3_1: Int32
    var density: Float
}

struct MTSamplePoint: Sendable {
    let x: Float
    let y: Float
}

final class MultitouchBridge: @unchecked Sendable {
    static let shared = MultitouchBridge()
    private let lock = NSLock()
    private var _remoteFocus = false

    var isRemoteFocus: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _remoteFocus
        }
        set {
            lock.lock()
            _remoteFocus = newValue
            lock.unlock()
        }
    }
}

typealias MTContactCallbackFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

private let omniMTContactCallback: MTContactCallbackFn = { _, data, nFingers, _, _ in
    guard MultitouchBridge.shared.isRemoteFocus else { return 0 }
    var active: [MTSamplePoint] = []
    if let data = data, nFingers > 0 {
        let contacts = data.assumingMemoryBound(to: MTContact.self)
        active.reserveCapacity(Int(nFingers))
        for i in 0..<Int(nFingers) {
            let c = contacts[i]
            // States 3 (MakeTouch) and 4 (Touching) represent fingers physically touching the trackpad
            if c.state == 3 || c.state == 4 {
                active.append(MTSamplePoint(x: c.normalized.position.x, y: c.normalized.position.y))
            }
        }
    }
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            MacKvmController.shared.handleTrackpadContacts(active)
        }
    }
    return 0
}
