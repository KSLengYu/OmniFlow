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
final class RemoteCursorInjector: @unchecked Sendable {
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
    private var injectedButtonsMask: UInt8 = 0
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

    func updateInjectedMouseButton(button: UInt8, isDown: Bool) -> CGPoint? {
        lock.lock()
        let bit: UInt8 = (button == 2) ? 2 : (button == 3 ? 4 : 1)
        if isDown {
            injectedButtonsMask |= bit
        } else {
            injectedButtonsMask &= ~bit
        }
        let pt = lastInjectedPoint
        lock.unlock()
        return pt
    }

    private func postMouseMovedLocked(to pt: CGPoint, deltaX: Double, deltaY: Double) -> Bool {
        let mouseType: CGEventType
        let cgBtn: CGMouseButton
        if (injectedButtonsMask & 1) != 0 {
            mouseType = .leftMouseDragged
            cgBtn = .left
        } else if (injectedButtonsMask & 2) != 0 {
            mouseType = .rightMouseDragged
            cgBtn = .right
        } else if (injectedButtonsMask & 4) != 0 {
            mouseType = .otherMouseDragged
            cgBtn = .center
        } else {
            mouseType = .mouseMoved
            cgBtn = .left
        }
        guard let ev = CGEvent(mouseEventSource: eventSource, mouseType: mouseType, mouseCursorPosition: pt, mouseButton: cgBtn) else {
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
