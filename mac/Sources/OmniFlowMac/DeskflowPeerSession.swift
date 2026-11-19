import Foundation
import Network

/// Trimmed lower-half sliding window + gentle RFC 6298 EWMA RTT estimator.
final class RttEstimator: @unchecked Sendable {
    private let windowSize = 6
    private let lock = NSLock()
    private var ring = [Double](repeating: 0, count: 6)
    private var scratch = [Double](repeating: 0, count: 6)
    private var count = 0
    private var head = 0
    private var smoothedMs: Double?

    var currentMs: Double? {
        lock.lock(); defer { lock.unlock() }
        return smoothedMs
    }

    func recordSample(_ rawRttMs: Double) -> Double {
        let sample = max(0.05, min(rawRttMs, 999.0))
        lock.lock()
        defer { lock.unlock() }

        ring[head] = sample
        head = (head + 1) % windowSize
        if count < windowSize { count += 1 }

        for i in 0..<count { scratch[i] = ring[i] }
        scratch[0..<count].sort()

        let keep = max(1, count / 2)
        var sum = 0.0
        for i in 0..<keep { sum += scratch[i] }
        let baseline = sum / Double(keep)

        if let prev = smoothedMs {
            if count <= 3 && baseline < prev * 0.5 {
                smoothedMs = baseline
            } else if baseline < prev * 0.6 {
                smoothedMs = prev * 0.5 + baseline * 0.5
            } else {
                smoothedMs = prev * 0.65 + baseline * 0.35
            }
        } else {
            smoothedMs = baseline
        }
        return smoothedMs!
    }
}

/// Represents one active or discovered transport link between a local NIC and a remote peer NIC.
final class PeerLinkSession: @unchecked Sendable {
    let id: String
    let peerIp: String
    let isUsbBridge: Bool
    let connection: NWConnection
    let createdAt: Date = Date()
    var isInbound: Bool { id.hasPrefix("in_") }

    private let sessionLock = NSLock()
    private let rttEstimator = RttEstimator()
    private var _localIp: String
    private var _ifaceName: String
    private var _isReady: Bool = false
    private var _rttMs: Double?
    private var _estBandwidthMbps: Double
    private var _measuredBytesPerSec: Double?
    private var _lastPingSentNs: UInt64 = 0
    private var _rxFrames: UInt64 = 0
    private var _txFrames: UInt64 = 0
    private var _lastActivityAt: Date = Date()

    var localIp: String {
        get { sessionLock.lock(); defer { sessionLock.unlock() }; return _localIp }
        set { sessionLock.lock(); defer { sessionLock.unlock() }; _localIp = newValue }
    }
    var ifaceName: String {
        get { sessionLock.lock(); defer { sessionLock.unlock() }; return _ifaceName }
        set { sessionLock.lock(); defer { sessionLock.unlock() }; _ifaceName = newValue }
    }
    var isReady: Bool {
        get { sessionLock.lock(); defer { sessionLock.unlock() }; return _isReady }
        set { sessionLock.lock(); defer { sessionLock.unlock() }; _isReady = newValue }
    }
    var rttMs: Double? {
        get { sessionLock.lock(); defer { sessionLock.unlock() }; return _rttMs }
        set { sessionLock.lock(); defer { sessionLock.unlock() }; _rttMs = newValue }
    }
    var estBandwidthMbps: Double {
        get { sessionLock.lock(); defer { sessionLock.unlock() }; return _estBandwidthMbps }
        set { sessionLock.lock(); defer { sessionLock.unlock() }; _estBandwidthMbps = newValue }
    }
    var measuredBytesPerSec: Double? {
        get { sessionLock.lock(); defer { sessionLock.unlock() }; return _measuredBytesPerSec }
        set { sessionLock.lock(); defer { sessionLock.unlock() }; _measuredBytesPerSec = newValue }
    }
    var lastPingSentNs: UInt64 {
        get { sessionLock.lock(); defer { sessionLock.unlock() }; return _lastPingSentNs }
        set { sessionLock.lock(); defer { sessionLock.unlock() }; _lastPingSentNs = newValue }
    }
    var rxFrames: UInt64 {
        get { sessionLock.lock(); defer { sessionLock.unlock() }; return _rxFrames }
    }
    var txFrames: UInt64 {
        get { sessionLock.lock(); defer { sessionLock.unlock() }; return _txFrames }
    }
    var lastActivityAt: Date {
        get { sessionLock.lock(); defer { sessionLock.unlock() }; return _lastActivityAt }
        set { sessionLock.lock(); defer { sessionLock.unlock() }; _lastActivityAt = newValue }
    }
    func incrementRxFrames() { sessionLock.lock(); _rxFrames &+= 1; _lastActivityAt = Date(); sessionLock.unlock() }
    func incrementTxFrames() { sessionLock.lock(); _txFrames &+= 1; sessionLock.unlock() }

    private var rxBuffer = Data()
    private let rxLock = NSLock()
    private let sendQueue = DispatchQueue(label: "com.omniflow.link.send", qos: .userInteractive)
    private let mouseLock = NSLock()
    private var pendingMouseFrame: Data?
    private var mouseInFlight: Bool = false

    var onReady: ((PeerLinkSession) -> Void)?
    var onFrame: ((PeerLinkSession, DeskflowMsgType, Data) -> Void)?
    var onClosed: ((PeerLinkSession) -> Void)?
    var onWaitingOrFailed: ((PeerLinkSession, String) -> Void)?

    init(
        id: String,
        localIp: String,
        peerIp: String,
        ifaceName: String,
        isUsbBridge: Bool,
        estBandwidthMbps: Double,
        connection: NWConnection
    ) {
        self.id = id
        self._localIp = localIp
        self.peerIp = peerIp
        self._ifaceName = ifaceName
        self.isUsbBridge = isUsbBridge
        self._estBandwidthMbps = estBandwidthMbps
        self.connection = connection
    }

    func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                if let path = self.connection.currentPath {
                    if case let .hostPort(host, _) = path.localEndpoint {
                        let resolved = "\(host)".split(separator: "%").first.map(String.init) ?? ""
                        if !resolved.isEmpty && (self.localIp == "auto" || self.localIp.isEmpty) {
                            self.localIp = resolved
                        }
                    }
                    if (self.ifaceName == "LAN" || self.ifaceName == "USB-C"),
                       let ifName = path.availableInterfaces.first?.name, !ifName.isEmpty {
                        self.ifaceName = ifName
                    }
                }
                self.lastActivityAt = Date()
                self.isReady = true
                self.onReady?(self)
                self.receiveNext()
            case .waiting(let err):
                if !self.isReady {
                    self.onWaitingOrFailed?(self, "waiting: \(err)")
                    self.connection.cancel()
                }
            case .failed(let err):
                self.isReady = false
                self.onWaitingOrFailed?(self, "failed: \(err)")
                self.onClosed?(self)
            case .cancelled:
                self.isReady = false
                self.onClosed?(self)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func recordRttSample(_ rawRttMs: Double) -> Double {
        let smoothed = rttEstimator.recordSample(rawRttMs)
        rttMs = smoothed
        return smoothed
    }

    /// Stamps monotonic nanoseconds inside `sendQueue` immediately before `connection.send`
    /// so queue scheduling delay does not inflate wire RTT.
    func sendPingTimestamped() {
        sendQueue.async { [weak self] in
            guard let self = self, self.isReady else { return }
            self.incrementTxFrames()
            let nowNs = DispatchTime.now().uptimeNanoseconds
            self.lastPingSentNs = nowNs
            var bytes = [UInt8](repeating: 0, count: 8)
            for i in 0..<8 {
                bytes[7 - i] = UInt8((nowNs >> (i * 8)) & 0xFF)
            }
            let frame = WireFrameCodec.encode(type: .ping, payload: Data(bytes))
            self.connection.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    /// Sends `.pong` directly via thread-safe `NWConnection.send` without hopping back onto `sendQueue`.
    func sendPongDirect(_ payload: Data) {
        guard isReady else { return }
        incrementTxFrames()
        let frame = WireFrameCodec.encode(type: .pong, payload: payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    func sendFrame(_ frame: Data, completion: (@Sendable (Bool) -> Void)? = nil) {
        sendQueue.async { [weak self] in
            guard let self = self, self.isReady else {
                completion?(false)
                return
            }
            self.incrementTxFrames()
            self.connection.send(content: frame, completion: .contentProcessed { err in
                completion?(err == nil)
            })
        }
    }

    /// Overwrite-in-place coalesced mouse sender: guarantees fast 125-1000Hz swipes never build a stale queue backlog.
    func sendMouseMoveCoalesced(_ frame: Data) {
        guard isReady else { return }
        mouseLock.lock()
        pendingMouseFrame = frame
        let shouldStart = !mouseInFlight
        if shouldStart { mouseInFlight = true }
        mouseLock.unlock()

        if shouldStart {
            flushNextMouseFrame()
        }
    }

    private func flushNextMouseFrame() {
        mouseLock.lock()
        let next = pendingMouseFrame
        pendingMouseFrame = nil
        if next == nil || !isReady {
            mouseInFlight = false
            mouseLock.unlock()
            return
        }
        mouseLock.unlock()

        incrementTxFrames()
        connection.send(content: next, completion: .contentProcessed { [weak self] err in
            guard let self = self, err == nil, self.isReady else {
                self?.mouseLock.lock()
                self?.mouseInFlight = false
                self?.pendingMouseFrame = nil
                self?.mouseLock.unlock()
                return
            }
            self.flushNextMouseFrame()
        })
    }

    func close() {
        isReady = false
        connection.cancel()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.appendAndDispatch(data)
            }
            if isComplete || error != nil {
                self.isReady = false
                self.onClosed?(self)
                return
            }
            self.receiveNext()
        }
    }

    private func appendAndDispatch(_ data: Data) {
        var framesToDeliver: [(DeskflowMsgType, Data)] = []
        rxLock.lock()
        rxBuffer.append(data)
        var cursor = rxBuffer.startIndex
        let end = rxBuffer.endIndex
        while end - cursor >= 5 {
            let b0 = UInt32(rxBuffer[cursor])
            let b1 = UInt32(rxBuffer[cursor + 1])
            let b2 = UInt32(rxBuffer[cursor + 2])
            let b3 = UInt32(rxBuffer[cursor + 3])
            let frameLen = Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
            if frameLen <= 0 || frameLen > 16 * 1024 * 1024 {
                rxBuffer.removeAll(keepingCapacity: true)
                cursor = rxBuffer.endIndex
                break
            }
            if end - cursor < 4 + frameLen {
                break
            }
            let typeByte = rxBuffer[cursor + 4]
            let payloadStart = cursor + 5
            let payloadEnd = cursor + 4 + frameLen
            let payload = Data(rxBuffer[payloadStart..<payloadEnd])
            cursor = payloadEnd
            if let msgType = DeskflowMsgType(rawValue: typeByte) {
                framesToDeliver.append((msgType, payload))
            }
        }
        if cursor > rxBuffer.startIndex && cursor <= rxBuffer.endIndex {
            rxBuffer.removeSubrange(rxBuffer.startIndex..<cursor)
        }
        rxLock.unlock()

        for (msgType, payload) in framesToDeliver {
            incrementRxFrames()
            onFrame?(self, msgType, payload)
        }
    }
}
