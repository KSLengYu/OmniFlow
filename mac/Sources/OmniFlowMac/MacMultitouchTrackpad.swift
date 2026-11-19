import Foundation
import AppKit
import CoreGraphics
import Darwin

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

extension MacKvmController {
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
}
