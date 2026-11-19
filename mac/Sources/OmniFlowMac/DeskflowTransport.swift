import Foundation
import Network
import Security
import CryptoKit
import Darwin
import AppKit

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
    private let sendQueue = DispatchQueue(label: "com.kslengyu.macbridge.link.send", qos: .userInteractive)
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
        while rxBuffer.count >= 5 {
            let b0 = UInt32(rxBuffer[rxBuffer.startIndex])
            let b1 = UInt32(rxBuffer[rxBuffer.startIndex + 1])
            let b2 = UInt32(rxBuffer[rxBuffer.startIndex + 2])
            let b3 = UInt32(rxBuffer[rxBuffer.startIndex + 3])
            let frameLen = Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
            if frameLen <= 0 || frameLen > 16 * 1024 * 1024 {
                rxBuffer.removeAll()
                break
            }
            if rxBuffer.count < 4 + frameLen {
                break
            }
            let typeByte = rxBuffer[rxBuffer.startIndex + 4]
            let payloadStart = rxBuffer.startIndex + 5
            let payloadEnd = rxBuffer.startIndex + 4 + frameLen
            let payload = Data(rxBuffer[payloadStart..<payloadEnd])
            rxBuffer.removeSubrange(rxBuffer.startIndex..<payloadEnd)
            if let msgType = DeskflowMsgType(rawValue: typeByte) {
                framesToDeliver.append((msgType, payload))
            }
        }
        rxLock.unlock()

        for (msgType, payload) in framesToDeliver {
            incrementRxFrames()
            onFrame?(self, msgType, payload)
        }
    }
}

/// Manages multi-NIC discovery, TLS/Raw listeners, control/data plane scheduling, and chunked file transfers.
final class DeskflowTransport: @unchecked Sendable {
    static let shared = DeskflowTransport()

    private let ioQueue = DispatchQueue(label: "com.kslengyu.macbridge.transport.io", qos: .userInteractive, attributes: .concurrent)
    private let stateLock = NSLock()
    private var lastControlLinkId: String?

    private var rawListener: NWListener?
    private var tlsListener: NWListener?
    private var udpFd: Int32 = -1
    private var running = false

    private var localIdentity: SecIdentity?
    private(set) var localFingerprint: String = "SHA256:LOCAL"
    private(set) var peerFingerprint: String = ""
    let trustStore = TrustedPeerStore()
    private var lastPairingNotifyAt: [String: Date] = [:]
    private var rejectedFingerprints: Set<String> = []
    private var discoveredHostByIp: [String: String] = [:]

    /// Active peer links keyed by link ID (`usb_<peerIp>` or `lan_<localIp>_<peerIp>`)
    private var links: [String: PeerLinkSession] = [:]
    private var manuallyDisconnectedIfaces: Set<String> = []
    private var manuallyPausedAll: Bool = false
    private var knownPeerIps: Set<String> = []
    private var peerHostName: String = ""
    private var peerMonitors: [WireMonitorDto] = []

    /// Active incoming file transfers keyed by transferId
    private struct IncomingFileState {
        let offer: WireFileOfferPayload
        let stagingDir: URL
        let tempURL: URL
        let finalParentDir: URL
        let handle: FileHandle
        var receivedChunks: Set<Int>
        var receivedBytes: UInt64
        var failedReason: String?
        let startTime: Date
        var lastUiNotify: Date
        var pendingComplete: WireFileCompletePayload?
        var pendingCompleteLink: PeerLinkSession?
    }
    /// Guards `incomingFiles` / `earlyFileChunks*` ONLY. Kept separate from `stateLock` because chunk
    /// disk writes (up to 8 MB) happen while holding it; the KVM event tap and `bestControlLink()` take
    /// `stateLock` on every mouse event and must never wait behind file I/O.
    private let fileLock = NSLock()
    private var incomingFiles: [String: IncomingFileState] = [:]
    private var earlyFileChunks: [String: [(idx: Int, data: Data, linkId: String, at: Date)]] = [:]
    private var earlyFileChunkTotalBytes: Int = 0
    private var pendingFileAcks: [String: (WireFileAckPayload) -> Void] = [:]
    private var pendingAckLinks: [String: String] = [:]
    private var activeBulkTransfers: Int = 0

    // Callbacks delivered to DeskflowEngine on MainActor
    var onLinksUpdated: (() -> Void)?
    var onPeerMonitorsUpdated: (([WireMonitorDto], String) -> Void)?
    var onTopologySync: ((WireTopologySyncPayload) -> Void)?
    var onConfigSync: ((WireConfigSyncPayload) -> Void)?
    var onRemoteClipboardText: ((String) -> Void)?
    var onRemoteClipboardImage: ((Data) -> Void)?
    var onRemotePortalSync: ((WirePortalSyncPayload) -> Void)?
    var onIncomingFileCompleted: ((WireFileOfferPayload, URL) -> Void)?
    var onTransferFailed: ((String, String) -> Void)?
    var onPendingPairingRequest: ((PendingPairingRequest) -> Void)?
    var onTrustStoreUpdated: (() -> Void)?
    var onKvmMouseMoveAbs: ((Int, Double, Double) -> Void)?
    var onKvmMouseButton: ((UInt8, Bool) -> Void)?
    var onKvmMouseScroll: ((Int32, Int32) -> Void)?
    var onKvmKeyEvent: ((UInt16, Bool, UInt32) -> Void)?
    var onKvmSemanticHotkey: ((String) -> Void)?
    var onKvmFocusSwitch: ((WireKvmFocusPayload) -> Void)?
    var onLog: ((String) -> Void)?

    private init() {}

    func start() {
        stateLock.lock()
        if running {
            stateLock.unlock()
            return
        }
        running = true
        stateLock.unlock()

        if let pair = TlsIdentityHelper.loadOrCreateIdentity() {
            localIdentity = pair.identity
            localFingerprint = pair.fingerprint
            onLog?("[TLS] 本机证书已就绪 (\(localFingerprint.prefix(28))...)")
        }

        startRawListener()
        startTlsListener()
        startUdpDiscovery()
        startHeartbeatLoop()
    }

    func stop() {
        stateLock.lock()
        running = false
        let allLinks = Array(links.values)
        links.removeAll()
        fileLock.lock()
        let leftoverIncoming = Array(incomingFiles.values)
        incomingFiles.removeAll()
        earlyFileChunks.removeAll()
        earlyFileChunkTotalBytes = 0
        fileLock.unlock()
        let leftoverAcks = pendingFileAcks
        pendingFileAcks.removeAll()
        pendingAckLinks.removeAll()
        stateLock.unlock()

        rawListener?.cancel()
        tlsListener?.cancel()
        if udpFd >= 0 {
            Darwin.close(udpFd)
            udpFd = -1
        }
        allLinks.forEach { $0.close() }
        for st in leftoverIncoming {
            try? st.handle.close()
            try? FileManager.default.removeItem(at: st.stagingDir)
        }
        for (tid, cb) in leftoverAcks {
            cb(WireFileAckPayload(transferId: tid, ok: false, savedPath: "", error: "传输服务已停止"))
        }
    }

    // MARK: - Mutual TLS Certificate Pinning & Interactive SAS Pairing

    func confirmPairing(fingerprint: String, hostName: String) {
        trustStore.addTrusted(fingerprint: fingerprint, hostName: hostName)
        let norm = SecurityValidation.normalizeFingerprint(fingerprint)
        stateLock.lock()
        rejectedFingerprints.remove(norm)
        lastPairingNotifyAt.removeValue(forKey: norm)
        let peers = Array(knownPeerIps)
        stateLock.unlock()
        onLog?("[SECURITY] 已信任并配对对端设备证书 (\(norm.prefix(28))...)")
        onTrustStoreUpdated?()
        for ip in peers {
            connectIfNeeded(peerIp: ip, localIpHint: nil, isUsb: MacBridgeSubnet.isUsbBridgeIp(ip))
        }
    }

    func rejectPairing(fingerprint: String) {
        let norm = SecurityValidation.normalizeFingerprint(fingerprint)
        stateLock.lock()
        rejectedFingerprints.insert(norm)
        stateLock.unlock()
        onLog?("[SECURITY] 用户拒绝了未配对设备的 TLS 连接请求 (\(norm.prefix(28))...)")
    }

    func clearAllTrustedPeers() {
        trustStore.removeAll()
        var toClose: [PeerLinkSession] = []
        stateLock.lock()
        rejectedFingerprints.removeAll()
        lastPairingNotifyAt.removeAll()
        for (k, link) in links where !link.isUsbBridge {
            toClose.append(link)
            links.removeValue(forKey: k)
        }
        peerFingerprint = ""
        stateLock.unlock()
        toClose.forEach { $0.close() }
        onLog?("[SECURITY] 已清除全部已配对证书信任记录，后续 TLS 连接需重新确认短码")
        onTrustStoreUpdated?()
        onLinksUpdated?()
    }

    func removeTrustedPeer(fingerprint: String) {
        let norm = SecurityValidation.normalizeFingerprint(fingerprint)
        guard !norm.isEmpty else { return }
        trustStore.removeTrusted(norm)
        var toClose: [PeerLinkSession] = []
        stateLock.lock()
        rejectedFingerprints.remove(norm)
        lastPairingNotifyAt.removeValue(forKey: norm)
        if trustStore.allTrusted().isEmpty {
            for (k, link) in links where !link.isUsbBridge {
                toClose.append(link)
                links.removeValue(forKey: k)
            }
            peerFingerprint = ""
        } else if peerFingerprint == norm {
            for (k, link) in links where !link.isUsbBridge {
                toClose.append(link)
                links.removeValue(forKey: k)
            }
            peerFingerprint = ""
        }
        stateLock.unlock()
        toClose.forEach { $0.close() }
        onLog?("[SECURITY] 已移除信任设备证书 (\(norm.prefix(28))...)，再次连接需重新核对短码")
        onTrustStoreUpdated?()
        onLinksUpdated?()
    }

    private func verifyTlsPeerCertificate(_ fp: String, remoteIp: String) -> Bool {
        let norm = SecurityValidation.normalizeFingerprint(fp)
        if trustStore.isTrusted(norm) {
            stateLock.lock()
            peerFingerprint = norm
            stateLock.unlock()
            return true
        }

        var shouldNotify = false
        var hostHint = ""
        stateLock.lock()
        let isRejected = rejectedFingerprints.contains(norm)
        let lastAt = lastPairingNotifyAt[norm] ?? .distantPast
        if !isRejected && Date().timeIntervalSince(lastAt) >= 4.0 {
            lastPairingNotifyAt[norm] = Date()
            hostHint = discoveredHostByIp[remoteIp] ?? peerHostName
            shouldNotify = true
        }
        stateLock.unlock()

        if shouldNotify {
            let sas = SecurityValidation.computePairingSasCode(localFingerprint: localFingerprint, peerFingerprint: norm)
            onLog?("[SECURITY] 拦截未配对 TLS 连接 ip=\(remoteIp) sas=\(sas) fp=\(norm.prefix(28))...")
            let req = PendingPairingRequest(
                fingerprint: norm,
                remoteIp: remoteIp,
                hostName: hostHint.isEmpty ? "Windows 设备 (\(remoteIp))" : hostHint,
                sasCode: sas
            )
            onPendingPairingRequest?(req)
        }
        return false
    }

    func addManualPeerIp(_ ip: String) {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stateLock.lock()
        manuallyPausedAll = false
        knownPeerIps.insert(trimmed)
        stateLock.unlock()
        onLog?("[NET] 正在主动探测对端地址: \(trimmed) ...")
        connectIfNeeded(peerIp: trimmed, localIpHint: nil, isUsb: MacBridgeSubnet.isUsbBridgeIp(trimmed), allowRoutedFallback: true)
    }

    private static func isUsbAlias(_ key: String) -> Bool {
        key == "usb" || key == "USB-C NCM" || key == "USB-C" || key == "MacBridge" || key == "USB-NCM" || MacBridgeSubnet.isUsbBridgeIp(key)
    }

    func isIfaceDisconnected(_ ifaceOrIp: String) -> Bool {
        stateLock.lock()
        let res = manuallyPausedAll
            || manuallyDisconnectedIfaces.contains(ifaceOrIp)
            || (Self.isUsbAlias(ifaceOrIp) && manuallyDisconnectedIfaces.contains("usb"))
        stateLock.unlock()
        return res
    }

    var isGloballyPaused: Bool {
        stateLock.lock()
        let v = manuallyPausedAll
        stateLock.unlock()
        return v
    }

    func disconnectChannel(ifaceName: String, localIp: String) {
        var toClose: [PeerLinkSession] = []
        let isUsb = Self.isUsbAlias(ifaceName) || Self.isUsbAlias(localIp)
        stateLock.lock()
        if !ifaceName.isEmpty { manuallyDisconnectedIfaces.insert(ifaceName) }
        if !localIp.isEmpty && localIp != "auto" { manuallyDisconnectedIfaces.insert(localIp) }
        if isUsb { manuallyDisconnectedIfaces.insert("usb") }
        for (k, link) in links {
            if link.ifaceName == ifaceName || link.localIp == localIp || (isUsb && link.isUsbBridge) {
                toClose.append(link)
                links.removeValue(forKey: k)
            }
        }
        stateLock.unlock()
        toClose.forEach { $0.close() }
        onLog?("[NET] 已手动断开网卡通道: \(ifaceName) (\(localIp))")
        if isUsb {
            ensureLanLinksConnected()
        }
        onLinksUpdated?()
    }

    func ensureLanLinksConnected() {
        stateLock.lock()
        let peers = Array(knownPeerIps).filter { !MacBridgeSubnet.isUsbBridgeIp($0) }
        stateLock.unlock()
        for ip in peers {
            connectIfNeeded(peerIp: ip, localIpHint: nil, isUsb: false)
        }
    }

    func reconnectChannel(ifaceName: String, localIp: String, peerIp: String) {
        let isUsb = Self.isUsbAlias(ifaceName) || Self.isUsbAlias(localIp) || MacBridgeSubnet.isUsbBridgeIp(peerIp)
        stateLock.lock()
        manuallyPausedAll = false
        manuallyDisconnectedIfaces.remove(ifaceName)
        manuallyDisconnectedIfaces.remove(localIp)
        if isUsb { manuallyDisconnectedIfaces.remove("usb") }
        stateLock.unlock()
        onLog?("[NET] 正在重新连接网卡通道: \(ifaceName) (\(localIp) -> \(peerIp))")
        if !peerIp.isEmpty {
            connectIfNeeded(peerIp: peerIp, localIpHint: localIp == "auto" ? nil : localIp, isUsb: isUsb)
        }
        onLinksUpdated?()
    }

    func disconnectAllLinks() {
        var toClose: [PeerLinkSession] = []
        stateLock.lock()
        manuallyPausedAll = true
        toClose = Array(links.values)
        links.removeAll()
        stateLock.unlock()
        toClose.forEach { $0.close() }
        onLog?("[NET] 已手动断开全部对端连接")
        onLinksUpdated?()
    }

    func reconnectAllLinks() {
        stateLock.lock()
        manuallyPausedAll = false
        manuallyDisconnectedIfaces.removeAll()
        let peers = Array(knownPeerIps)
        stateLock.unlock()
        onLog?("[NET] 已恢复多网卡自动重连")
        for ip in peers {
            connectIfNeeded(peerIp: ip, localIpHint: nil, isUsb: MacBridgeSubnet.isUsbBridgeIp(ip))
        }
        onLinksUpdated?()
    }

    func activeLinksSnapshot() -> [PeerLinkSession] {
        stateLock.lock()
        let arr = Array(links.values).filter { $0.isReady }
        stateLock.unlock()
        return arr
    }

    func bestControlLink() -> PeerLinkSession? {
        let active = activeLinksSnapshot()
        guard !active.isEmpty else { return nil }
        // Lowest RTT wins; tie-breaker favors USB-C raw P2P, then wired LAN over Wi-Fi (en0)
        let best = active.min { a, b in
            let ra = a.rttMs ?? (a.isUsbBridge ? 0.5 : 5.0)
            let rb = b.rttMs ?? (b.isUsbBridge ? 0.5 : 5.0)
            if abs(ra - rb) < 0.30 {
                if a.isUsbBridge != b.isUsbBridge { return a.isUsbBridge }
                let aWifi = (a.ifaceName == "en0")
                let bWifi = (b.ifaceName == "en0")
                if aWifi != bWifi { return !aWifi }
            }
            return ra < rb
        }
        guard let candidate = best else { return nil }

        stateLock.lock()
        let prevId = lastControlLinkId
        if let pid = prevId, let prev = active.first(where: { $0.id == pid }), prev.id != candidate.id {
            let prevRtt = prev.rttMs ?? (prev.isUsbBridge ? 0.5 : 5.0)
            let candRtt = candidate.rttMs ?? (candidate.isUsbBridge ? 0.5 : 5.0)
            if (prevRtt - candRtt) < 0.5 && !(candidate.isUsbBridge && !prev.isUsbBridge) {
                stateLock.unlock()
                return prev
            }
        }
        lastControlLinkId = candidate.id
        stateLock.unlock()
        return candidate
    }

    func sendControlFrame(_ frame: Data) {
        guard let ctrl = bestControlLink() else { return }
        ctrl.sendFrame(frame)
    }

    func sendMouseMoveCoalesced(_ frame: Data) {
        guard let ctrl = bestControlLink() else { return }
        ctrl.sendMouseMoveCoalesced(frame)
    }

    func broadcastControlFrame(_ frame: Data) {
        let active = activeLinksSnapshot()
        for link in active {
            link.sendFrame(frame)
        }
    }

    // MARK: - Listeners (24800 Raw USB & 24801 LAN TLS 1.3)

    private func startRawListener() {
        do {
            let listener = try NWListener(using: TlsIdentityHelper.makeRawParameters(), on: NWEndpoint.Port(rawValue: DeskflowPorts.rawUsbTcp)!)
            listener.newConnectionHandler = { [weak self] conn in
                self?.acceptIncomingConnection(conn, isTls: false)
            }
            listener.start(queue: ioQueue)
            rawListener = listener
            onLog?("[NET] USB-C 极速直连免加密端口已监听 :\(DeskflowPorts.rawUsbTcp)")
        } catch {
            onLog?("[ERR] Raw listener failed: \(error.localizedDescription)")
        }
    }

    private func startTlsListener() {
        let params = TlsIdentityHelper.makeTlsParameters(identity: localIdentity) { [weak self] fp in
            guard let self = self else { return false }
            let norm = SecurityValidation.normalizeFingerprint(fp)
            if self.trustStore.isTrusted(norm) {
                self.stateLock.lock()
                self.peerFingerprint = norm
                self.stateLock.unlock()
                return true
            }
            return self.verifyTlsPeerCertificate(norm, remoteIp: "入站请求")
        }
        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: DeskflowPorts.lanTlsTcp)!)
            listener.newConnectionHandler = { [weak self] conn in
                self?.acceptIncomingConnection(conn, isTls: true)
            }
            listener.start(queue: ioQueue)
            tlsListener = listener
            onLog?("[TLS] 局域网 TLS 1.3 加密端口已监听 :\(DeskflowPorts.lanTlsTcp)")
        } catch {
            onLog?("[ERR] TLS listener failed: \(error.localizedDescription)")
        }
    }

    private func acceptIncomingConnection(_ conn: NWConnection, isTls: Bool) {
        var remoteIp = "unknown"
        if case let .hostPort(host, _) = conn.endpoint {
            remoteIp = "\(host)".split(separator: "%").first.map(String.init) ?? "unknown"
        }
        var localIp = "auto"
        var ifaceName: String? = nil
        if case let .hostPort(lHost, _)? = conn.currentPath?.localEndpoint {
            let parsed = "\(lHost)".split(separator: "%").first.map(String.init) ?? ""
            if !parsed.isEmpty { localIp = parsed }
        }
        if let localIface = conn.currentPath?.availableInterfaces.first(where: { !$0.name.isEmpty })?.name {
            ifaceName = localIface
        }
        if isGloballyPaused {
            conn.cancel()
            return
        }
        if !isTls {
            let validUsbPeer = MacBridgeSubnet.isUsbBridgeIp(remoteIp)
            let validUsbLocal: Bool
            if localIp == "auto" || localIp.isEmpty {
                validUsbLocal = enumerateLocalIPv4().contains(where: { MacBridgeSubnet.isUsbBridgeIp($0.ip) })
            } else {
                validUsbLocal = MacBridgeSubnet.isUsbBridgeIp(localIp)
            }
            if !validUsbPeer || !validUsbLocal {
                onLog?("[SECURITY] 拒绝非 USB 直连网段访问免加密端口 \(DeskflowPorts.rawUsbTcp): remote=\(remoteIp) local=\(localIp)")
                conn.cancel()
                return
            }
        }
        let isUsb = !isTls || MacBridgeSubnet.isUsbBridgeIp(remoteIp) || MacBridgeSubnet.isUsbBridgeIp(localIp)
        let id = "in_\(isUsb ? "usb" : "lan")_\(remoteIp)_\(UUID().uuidString.prefix(6))"
        let session = PeerLinkSession(
            id: id,
            localIp: localIp,
            peerIp: remoteIp,
            ifaceName: isUsb ? (ifaceName ?? "USB-C") : (ifaceName ?? "LAN"),
            isUsbBridge: isUsb,
            estBandwidthMbps: isUsb ? 3200 : 1200,
            connection: conn
        )
        wireSessionCallbacks(session, sendHelloOnReady: true)
        stateLock.lock()
        links[id] = session
        stateLock.unlock()
        session.start(on: ioQueue)
    }

    // MARK: - Outbound Multi-NIC Channel Connectors

    func connectIfNeeded(peerIp: String, localIpHint: String?, isUsb: Bool, allowRoutedFallback: Bool = false) {
        if isGloballyPaused { return }
        if isUsb && !MacBridgeSubnet.isUsbBridgeIp(peerIp) { return }
        let rawLocalIps = localIpHint.map { [$0] } ?? matchingLocalIps(for: peerIp)
        let localIps = isUsb ? rawLocalIps.filter { MacBridgeSubnet.isUsbBridgeIp($0) } : rawLocalIps
        if localIps.isEmpty {
            if isUsb || !allowRoutedFallback || !activeLinksSnapshot().isEmpty {
                return
            }
        }
        let targets = localIps.isEmpty ? [""] : localIps

        for loc in targets {
            let iface = interfaceName(for: loc) ?? (isUsb ? "USB-NCM" : "LAN")
            if isIfaceDisconnected(iface) || (!loc.isEmpty && isIfaceDisconnected(loc)) {
                continue
            }
            let id = "\(isUsb ? "usb" : "lan")_\(loc.isEmpty ? "auto" : loc)_\(peerIp)"
            var stalePending: PeerLinkSession?
            stateLock.lock()
            if let existing = links[id], !existing.isReady, Date().timeIntervalSince(existing.createdAt) > 6.0 {
                links.removeValue(forKey: id)
                stalePending = existing
            }
            let exists = links[id] != nil || links.values.contains(where: {
                $0.peerIp == peerIp && $0.isUsbBridge == isUsb && ($0.localIp == loc || loc.isEmpty) &&
                ($0.isReady || Date().timeIntervalSince($0.createdAt) <= 6.0)
            })
            if exists {
                stateLock.unlock()
                stalePending?.close()
                continue
            }

            let port = NWEndpoint.Port(rawValue: isUsb ? DeskflowPorts.rawUsbTcp : DeskflowPorts.lanTlsTcp)!
            let params: NWParameters
            if isUsb {
                params = TlsIdentityHelper.makeRawParameters(localIp: loc.isEmpty ? nil : loc)
            } else {
                params = TlsIdentityHelper.makeTlsParameters(identity: localIdentity) { [weak self] fp in
                    guard let self = self else { return false }
                    return self.verifyTlsPeerCertificate(fp, remoteIp: peerIp)
                }
                if !loc.isEmpty {
                    params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(loc), port: 0)
                }
            }

            let conn = NWConnection(host: NWEndpoint.Host(peerIp), port: port, using: params)
            let estBw: Double = isUsb ? 2400.0 : (iface == "en0" ? 1200.0 : 2500.0)
            let session = PeerLinkSession(
                id: id,
                localIp: loc.isEmpty ? "auto" : loc,
                peerIp: peerIp,
                ifaceName: iface,
                isUsbBridge: isUsb,
                estBandwidthMbps: estBw,
                connection: conn
            )
            wireSessionCallbacks(session, sendHelloOnReady: true)
            links[id] = session
            stateLock.unlock()
            stalePending?.close()
            session.start(on: ioQueue)
        }
    }

    private func ipv4Value(_ ip: String) -> UInt32 {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return 0 }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }

    /// Ensures only one ready link remains per (localIp, peerIp, isUsb) tuple across simultaneous initiations.
    private func deduplicateOnReady(_ session: PeerLinkSession) -> Bool {
        var toClose: PeerLinkSession?
        var keepCurrent = true

        stateLock.lock()
        if let iface = interfaceName(for: session.localIp), !iface.isEmpty {
            session.ifaceName = iface
            session.estBandwidthMbps = session.isUsbBridge ? 2400.0 : (iface == "en0" ? 1200.0 : 2500.0)
        }
        let blocked = manuallyPausedAll
            || manuallyDisconnectedIfaces.contains(session.ifaceName)
            || manuallyDisconnectedIfaces.contains(session.localIp)
            || (session.isUsbBridge && manuallyDisconnectedIfaces.contains("usb"))
        if blocked {
            links.removeValue(forKey: session.id)
            toClose = session
            keepCurrent = false
        } else if let existing = links.values.first(where: {
            $0.id != session.id && $0.isReady && $0.peerIp == session.peerIp &&
            $0.isUsbBridge == session.isUsbBridge && $0.localIp == session.localIp
        }) {
            if session.isInbound && existing.isInbound {
                links.removeValue(forKey: existing.id)
                toClose = existing
            } else {
                let localSmaller = ipv4Value(session.localIp) < ipv4Value(session.peerIp)
                let sessionPreferred = localSmaller ? !session.isInbound : session.isInbound
                if sessionPreferred {
                    links.removeValue(forKey: existing.id)
                    toClose = existing
                } else {
                    links.removeValue(forKey: session.id)
                    toClose = session
                    keepCurrent = false
                }
            }
        }
        stateLock.unlock()

        toClose?.close()
        return keepCurrent
    }

    private func wireSessionCallbacks(_ session: PeerLinkSession, sendHelloOnReady: Bool) {
        session.onReady = { [weak self] s in
            guard let self = self else { return }
            guard self.deduplicateOnReady(s) else { return }
            self.onLog?("[LINK] 已连上对端 \(s.peerIp) (本机 \(s.ifaceName) \(s.localIp) · \(s.isUsbBridge ? "USB 点对点免加密" : "TLS 1.3 加密"))")
            if sendHelloOnReady {
                if let helloFrame = WireFrameCodec.encodeJSON(type: .hello, value: self.buildHelloPayload()) {
                    s.sendFrame(helloFrame)
                }
            }
            self.sendPing(on: s)
            self.scheduleWarmupPingBurst(on: s)
            self.onLinksUpdated?()
        }

        session.onWaitingOrFailed = { [weak self] s, reason in
            guard let self = self else { return }
            self.stateLock.lock()
            self.links.removeValue(forKey: s.id)
            let isKnown = self.knownPeerIps.contains(s.peerIp)
            self.stateLock.unlock()
            if isKnown {
                self.onLog?("[NET] 链路状态 \(s.localIp)->\(s.peerIp): \(reason)")
            }
            self.onLinksUpdated?()
        }

        session.onClosed = { [weak self] s in
            guard let self = self else { return }
            self.stateLock.lock()
            self.links.removeValue(forKey: s.id)
            let noLinksLeft = self.links.values.allSatisfy { !$0.isReady }
            var droppedAcks: [String: (WireFileAckPayload) -> Void] = [:]
            if noLinksLeft {
                droppedAcks = self.pendingFileAcks
                self.pendingFileAcks.removeAll()
                self.pendingAckLinks.removeAll()
            } else {
                let matchingTids = self.pendingAckLinks.filter { $0.value == s.id }.map(\.key)
                for tid in matchingTids {
                    self.pendingAckLinks.removeValue(forKey: tid)
                    if let cb = self.pendingFileAcks.removeValue(forKey: tid) {
                        droppedAcks[tid] = cb
                    }
                }
            }
            self.stateLock.unlock()

            var orphanedIncoming: [IncomingFileState] = []
            if noLinksLeft {
                self.fileLock.lock()
                orphanedIncoming = Array(self.incomingFiles.values)
                self.incomingFiles.removeAll()
                self.earlyFileChunks.removeAll()
                self.earlyFileChunkTotalBytes = 0
                self.fileLock.unlock()
            }

            self.onLog?("[NET] 链路关闭 Link=\(s.id) Peer=\(s.peerIp)")
            for st in orphanedIncoming {
                try? st.handle.close()
                try? FileManager.default.removeItem(at: st.stagingDir)
                self.onTransferFailed?(st.offer.fileName, "对端连接已断开，接收已中止")
            }
            for (tid, cb) in droppedAcks {
                cb(WireFileAckPayload(transferId: tid, ok: false, savedPath: "", error: "对端连接已断开"))
            }
            if s.isUsbBridge {
                self.ensureLanLinksConnected()
            }
            self.onLinksUpdated?()
        }

        session.onFrame = { [weak self] s, type, payload in
            self?.handleIncomingFrame(from: s, type: type, payload: payload)
        }
    }

    // MARK: - UDP Broadcast Discovery (24802)

    private func startUdpDiscovery() {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = DeskflowPorts.udpDiscovery.bigEndian
        sa.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        let bound = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bound else {
            Darwin.close(fd)
            return
        }
        udpFd = fd

        // UDP receive loop
        ioQueue.async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 8192)
            while let self = self, self.isRunning() {
                var senderSa = sockaddr_in()
                var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &senderSa) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(fd, &buf, buf.count, 0, $0, &senderLen)
                    }
                }
                if n <= 0 {
                    if !self.isRunning() { break }
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &senderSa.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
                let senderIp = String(cString: ipBuf)
                let data = Data(bytes: buf, count: n)
                if let beacon = try? JSONDecoder().decode(WireBeaconPayload.self, from: data),
                   beacon.os != "macOS" {
                    self.handlePeerBeacon(beacon, senderIp: senderIp)
                }
            }
        }

        // UDP broadcast loop + USB direct probe
        ioQueue.async { [weak self] in
            while let self = self, self.isRunning() {
                self.broadcastBeacon(fd: fd)
                // Also probe MacBridge USB default peer if local USB interface is active
                let usbLocal = self.enumerateLocalIPv4().filter { MacBridgeSubnet.isUsbBridgeIp($0.ip) }
                for item in usbLocal {
                    let parts = item.ip.split(separator: ".")
                    if parts.count == 4 {
                        let peerUsb = "\(parts[0]).\(parts[1]).\(parts[2]).2"
                        self.connectIfNeeded(peerIp: peerUsb, localIpHint: item.ip, isUsb: true)
                    }
                }
                // Re-probe any manually added peer IPs
                self.stateLock.lock()
                let manuals = Array(self.knownPeerIps)
                self.stateLock.unlock()
                for ip in manuals {
                    self.connectIfNeeded(peerIp: ip, localIpHint: nil, isUsb: MacBridgeSubnet.isUsbBridgeIp(ip))
                }
                Thread.sleep(forTimeInterval: 2.0)
            }
        }
    }

    private func broadcastBeacon(fd: Int32) {
        let localNics = enumerateLocalIPv4()
        let usbIps = localNics.map(\.ip).filter { MacBridgeSubnet.isUsbBridgeIp($0) }
        let lanIps = localNics.map(\.ip).filter { !MacBridgeSubnet.isUsbBridgeIp($0) }
        let beacon = WireBeaconPayload(
            type: "BEACON",
            os: "macOS",
            host: Host.current().localizedName ?? "Mac",
            rawPort: DeskflowPorts.rawUsbTcp,
            tlsPort: DeskflowPorts.lanTlsTcp,
            ips: lanIps,
            usbIps: usbIps,
            fingerprint: localFingerprint
        )
        guard let payload = try? JSONEncoder().encode(beacon) else { return }

        var targets: [String] = ["255.255.255.255"]
        for nic in localNics {
            if let bcast = nic.broadcast, !targets.contains(bcast) {
                targets.append(bcast)
            }
        }
        stateLock.lock()
        for ip in knownPeerIps where !targets.contains(ip) {
            targets.append(ip)
        }
        stateLock.unlock()

        for target in targets {
            var dst = sockaddr_in()
            dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            dst.sin_family = sa_family_t(AF_INET)
            dst.sin_port = DeskflowPorts.udpDiscovery.bigEndian
            inet_pton(AF_INET, target, &dst.sin_addr)
            payload.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                withUnsafePointer(to: &dst) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = Darwin.sendto(fd, base, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    private func handlePeerBeacon(_ beacon: WireBeaconPayload, senderIp: String) {
        // NOTE: Beacon is LAN discovery hint ONLY; NEVER treat beacon.fingerprint as TLS-trusted!
        let validUsbIps = beacon.usbIps.filter { MacBridgeSubnet.isUsbBridgeIp($0) }
        let validLanIps = beacon.ips.filter { !MacBridgeSubnet.isUsbBridgeIp($0) }
        stateLock.lock()
        if !beacon.host.isEmpty {
            peerHostName = beacon.host
            if !senderIp.isEmpty { discoveredHostByIp[senderIp] = beacon.host }
            for ip in validLanIps { discoveredHostByIp[ip] = beacon.host }
            for ip in validUsbIps { discoveredHostByIp[ip] = beacon.host }
        }
        knownPeerIps.formUnion(validLanIps)
        knownPeerIps.formUnion(validUsbIps)
        if !senderIp.isEmpty && senderIp != "0.0.0.0" { knownPeerIps.insert(senderIp) }
        stateLock.unlock()

        for ip in validUsbIps {
            connectIfNeeded(peerIp: ip, localIpHint: nil, isUsb: true)
        }
        for ip in validLanIps {
            connectIfNeeded(peerIp: ip, localIpHint: nil, isUsb: false)
        }
        if !senderIp.isEmpty && senderIp != "0.0.0.0" {
            connectIfNeeded(peerIp: senderIp, localIpHint: nil, isUsb: MacBridgeSubnet.isUsbBridgeIp(senderIp))
        }
    }

    // MARK: - Heartbeat & Real RTT Measurement

    private func scheduleWarmupPingBurst(on link: PeerLinkSession) {
        ioQueue.asyncAfter(deadline: .now() + 0.055) { [weak self, weak link] in
            guard let self = self, let link = link, self.isRunning(), link.isReady else { return }
            self.sendPing(on: link)
        }
        ioQueue.asyncAfter(deadline: .now() + 0.110) { [weak self, weak link] in
            guard let self = self, let link = link, self.isRunning(), link.isReady else { return }
            self.sendPing(on: link)
        }
    }

    private func startHeartbeatLoop() {
        ioQueue.async { [weak self] in
            while let self = self, self.isRunning() {
                let now = Date()
                var staleLinks: [PeerLinkSession] = []
                var pinged: [PeerLinkSession] = []
                for link in self.activeLinksSnapshot() {
                    if now.timeIntervalSince(link.createdAt) > 8.0 && now.timeIntervalSince(link.lastActivityAt) > 7.5 {
                        staleLinks.append(link)
                    } else {
                        self.sendPing(on: link)
                        pinged.append(link)
                    }
                }
                if !staleLinks.isEmpty {
                    var anyUsbClosed = false
                    for s in staleLinks {
                        if s.isUsbBridge { anyUsbClosed = true }
                        self.stateLock.lock()
                        self.links.removeValue(forKey: s.id)
                        self.stateLock.unlock()
                        self.onLog?("[NET] 链路心跳超时，已自动清理并切换通道: \(s.ifaceName) (\(s.peerIp))")
                        s.close()
                    }
                    if anyUsbClosed {
                        self.ensureLanLinksConnected()
                    }
                    self.onLinksUpdated?()
                }
                self.stateLock.lock()
                let sendingBulk = self.activeBulkTransfers > 0
                self.stateLock.unlock()
                self.fileLock.lock()
                let inBulk = sendingBulk || !self.incomingFiles.isEmpty
                self.fileLock.unlock()
                if !pinged.isEmpty && !inBulk {
                    Thread.sleep(forTimeInterval: 0.035)
                    for link in pinged where link.isReady {
                        self.sendPing(on: link)
                    }
                    Thread.sleep(forTimeInterval: 1.465)
                } else {
                    Thread.sleep(forTimeInterval: 1.5)
                }
            }
        }
    }

    private func sendPing(on link: PeerLinkSession) {
        link.sendPingTimestamped()
    }

    // MARK: - Incoming Frame Dispatcher

    private func handleIncomingFrame(from link: PeerLinkSession, type: DeskflowMsgType, payload: Data) {
        switch type {
        case .ping:
            link.sendPongDirect(payload)

        case .pong:
            if payload.count >= 8 && link.isReady {
                var sentNs: UInt64 = 0
                let base = payload.startIndex
                for i in 0..<8 {
                    sentNs = (sentNs << 8) | UInt64(payload[base + i])
                }
                let nowNs = DispatchTime.now().uptimeNanoseconds
                if nowNs >= sentNs {
                    let rawRtt = Double(nowNs - sentNs) / 1_000_000.0
                    stateLock.lock()
                    let sendingBulk = activeBulkTransfers > 0
                    stateLock.unlock()
                    fileLock.lock()
                    let inBulk = sendingBulk || !incomingFiles.isEmpty
                    fileLock.unlock()
                    if rawRtt > 5000.0 || (inBulk && rawRtt > 200.0) {
                        return
                    }
                    let prevRtt = link.rttMs
                    let nextRtt = link.recordRttSample(rawRtt)
                    if prevRtt == nil || abs(nextRtt - (prevRtt ?? 0)) >= 0.15 {
                        onLinksUpdated?()
                    }
                }
            }

        case .hello:
            do {
                let hello = try JSONDecoder().decode(WireHelloPayload.self, from: payload)
                stateLock.lock()
                peerHostName = hello.host
                peerMonitors = hello.monitors
                stateLock.unlock()
                onPeerMonitorsUpdated?(hello.monitors, hello.host)
                for ip in hello.usbIps where MacBridgeSubnet.isUsbBridgeIp(ip) {
                    connectIfNeeded(peerIp: ip, localIpHint: nil, isUsb: true)
                }
                for ip in hello.ips where !MacBridgeSubnet.isUsbBridgeIp(ip) {
                    connectIfNeeded(peerIp: ip, localIpHint: nil, isUsb: false)
                }
            } catch {
                onLog?("[ERR] [Link=\(link.id)] stage=decode_hello error=\(error.localizedDescription)")
            }

        case .clipboardText:
            if let txt = String(data: payload, encoding: .utf8) {
                onRemoteClipboardText?(txt)
            }

        case .clipboardImage:
            onRemoteClipboardImage?(payload)

        case .portalSync:
            do {
                let sync = try JSONDecoder().decode(WirePortalSyncPayload.self, from: payload)
                onRemotePortalSync?(sync)
            } catch {
                onLog?("[ERR] [Link=\(link.id)] stage=decode_portal_sync error=\(error.localizedDescription)")
            }

        case .fileOffer:
            do {
                let offer = try JSONDecoder().decode(WireFileOfferPayload.self, from: payload)
                handleIncomingFileOffer(offer, via: link)
            } catch {
                onLog?("[ERR] [Link=\(link.id)] stage=decode_file_offer error=\(error.localizedDescription)")
            }

        case .fileChunk:
            handleIncomingFileChunk(payload, via: link)

        case .fileComplete:
            do {
                let comp = try JSONDecoder().decode(WireFileCompletePayload.self, from: payload)
                handleIncomingFileComplete(comp, via: link)
            } catch {
                onLog?("[ERR] [Link=\(link.id)] stage=decode_file_complete error=\(error.localizedDescription)")
            }

        case .mouseMoveAbs:
            if payload.count >= 10 {
                let monIdx = Int(UInt16(bigEndian: payload.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self) }))
                let nxBits = UInt32(bigEndian: payload.subdata(in: 2..<6).withUnsafeBytes { $0.load(as: UInt32.self) })
                let nyBits = UInt32(bigEndian: payload.subdata(in: 6..<10).withUnsafeBytes { $0.load(as: UInt32.self) })
                let nx = Double(Float(bitPattern: nxBits))
                let ny = Double(Float(bitPattern: nyBits))
                if let slot = KvmStageTracer.shared.takeNetMoveSlot() {
                    let sX = String(format: "%.4f", nx)
                    let sY = String(format: "%.4f", ny)
                    KvmStageTracer.shared.log(
                        seq: slot.seq,
                        t0Ns: slot.t0Ns,
                        nowNs: slot.nowNs,
                        "netRecvMove #\(slot.idx) link=\(link.id) mon=\(monIdx) norm=(\(sX),\(sY))"
                    )
                }
                onKvmMouseMoveAbs?(monIdx, nx, ny)
            }

        case .mouseButton:
            if payload.count >= 2 {
                onKvmMouseButton?(payload[0], payload[1] != 0)
            }

        case .mouseScroll:
            if payload.count >= 8 {
                let dy = Int32(bigEndian: payload.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: Int32.self) })
                let dx = Int32(bigEndian: payload.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: Int32.self) })
                onKvmMouseScroll?(dy, dx)
            }

        case .keyEvent:
            if payload.count >= 7 {
                let kc = UInt16(bigEndian: payload.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self) })
                let isDown = payload[2] != 0
                let mods = UInt32(bigEndian: payload.subdata(in: 3..<7).withUnsafeBytes { $0.load(as: UInt32.self) })
                onKvmKeyEvent?(kc, isDown, mods)
            }

        case .semanticHotkey:
            if let hk = try? JSONDecoder().decode(WireSemanticHotkeyPayload.self, from: payload) {
                onKvmSemanticHotkey?(hk.action)
            }

        case .kvmFocusSwitch:
            if let sw = try? JSONDecoder().decode(WireKvmFocusPayload.self, from: payload) {
                let started = KvmStageTracer.shared.beginFocusSwitch(targetOs: sw.targetOs)
                let sX = String(format: "%.4f", sw.normX)
                let sY = String(format: "%.4f", sw.normY)
                KvmStageTracer.shared.log(
                    seq: started.seq,
                    t0Ns: started.recvNs,
                    nowNs: started.recvNs,
                    "netRecvFocus target=\(sw.targetOs) link=\(link.id) mon=\(sw.monitorIndex) norm=(\(sX),\(sY))"
                )
                if sw.targetOs == "macOS", onKvmFocusSwitch == nil {
                    KvmStageTracer.shared.log(seq: started.seq, t0Ns: started.recvNs, "error_onKvmFocusSwitchNil")
                }
                onKvmFocusSwitch?(sw)
            } else {
                let cur = KvmStageTracer.shared.currentTrace()
                KvmStageTracer.shared.log(seq: cur.seq, t0Ns: DispatchTime.now().uptimeNanoseconds, "netRecvFocus_decodeFailed bytes=\(payload.count)")
            }

        case .topologyUpdate:
            if let topo = try? JSONDecoder().decode(WireTopologySyncPayload.self, from: payload) {
                onTopologySync?(topo)
            }

        case .configSync:
            if let cfg = try? JSONDecoder().decode(WireConfigSyncPayload.self, from: payload) {
                onConfigSync?(cfg)
            }

        case .fileAck:
            do {
                let ack = try JSONDecoder().decode(WireFileAckPayload.self, from: payload)
                stateLock.lock()
                let cb = pendingFileAcks.removeValue(forKey: ack.transferId)
                pendingAckLinks.removeValue(forKey: ack.transferId)
                stateLock.unlock()
                cb?(ack)
            } catch {
                onLog?("[ERR] [Link=\(link.id)] stage=decode_file_ack error=\(error.localizedDescription)")
            }

        case .dataStreamBind:
            break
        }
    }

    // MARK: - Real Multi-NIC File Sender & Receiver

    private static func sessionMatchesChannelFilter(_ session: PeerLinkSession, filterKeys: Set<String>) -> Bool {
        if filterKeys.contains(session.id) || filterKeys.contains(session.ifaceName) || filterKeys.contains(session.localIp) {
            return true
        }
        let canon = NicChannelItem.canonicalChannelKey(ifaceName: session.ifaceName, localIp: session.localIp, isUsb: session.isUsbBridge, peerIp: session.peerIp)
        if filterKeys.contains(canon) {
            return true
        }
        let baseCanon = NicChannelItem.canonicalChannelKey(ifaceName: session.ifaceName, localIp: session.localIp, isUsb: session.isUsbBridge)
        if filterKeys.contains(baseCanon) {
            return true
        }
        // Inbound LAN session before localEndpoint IP is populated: treat as eligible for non-USB enabled LAN keys
        if !session.isUsbBridge && (session.localIp.isEmpty || session.localIp == "auto") {
            return filterKeys.contains(where: { $0 != "usb" && !MacBridgeSubnet.isUsbBridgeIp($0) })
        }
        return false
    }

    func sendFileReal(
        sourceURL: URL,
        scheme: String,
        style: String,
        edge: String,
        offset: Double,
        multipath: Bool,
        enabledLinkIds: Set<String>,
        isClipboardItem: Bool = false,
        isClipboardMulti: Bool = false,
        batchItemCount: Int? = nil,
        isBatchBundle: Bool = false,
        requiredFreeBytes: UInt64? = nil,
        onProgress: @escaping @Sendable (Double, Double, String, String, String) -> Void,
        onFinished: @escaping @Sendable (Bool, String) -> Void
    ) {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let allActive = self.activeLinksSnapshot()
            let active = allActive.filter { enabledLinkIds.isEmpty || Self.sessionMatchesChannelFilter($0, filterKeys: enabledLinkIds) }
            guard !active.isEmpty else {
                onFinished(false, "未连接 Windows 对端，无法发送文件")
                return
            }

            // Prepare file (if folder, fast-zip on background thread with immediate UI feedback)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDir)
            var sendURL = sourceURL
            var displayFileName = sourceURL.lastPathComponent
            var isZip = isClipboardMulti || isBatchBundle
            var tempZipURL: URL?

            if isDir.boolValue {
                displayFileName = sourceURL.lastPathComponent + ".zip"
                onProgress(0.03, 0, displayFileName, "打包目录中...", active[0].ifaceName)
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mb_send_\(UUID().uuidString).zip")
                let proc = Process()
                proc.currentDirectoryURL = sourceURL.deletingLastPathComponent()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                proc.arguments = ["-r", "-q", "-0", tmp.path, sourceURL.lastPathComponent]
                proc.standardOutput = Pipe()
                proc.standardError = Pipe()
                try? proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: tmp.path) {
                    sendURL = tmp
                    tempZipURL = tmp
                    isZip = true
                }
            }

            defer {
                if let tmp = tempZipURL { try? FileManager.default.removeItem(at: tmp) }
            }

            guard let attrs = try? FileManager.default.attributesOfItem(atPath: sendURL.path),
                  let totalBytes = attrs[.size] as? UInt64,
                  let fh = try? FileHandle(forReadingFrom: sendURL) else {
                onFinished(false, "无法读取文件: \(sourceURL.lastPathComponent)")
                return
            }
            defer { try? fh.close() }

            stateLock.lock()
            activeBulkTransfers += 1
            stateLock.unlock()
            defer {
                stateLock.lock()
                activeBulkTransfers = max(0, activeBulkTransfers - 1)
                stateLock.unlock()
            }

            let transferId = UUID().uuidString
            let chunkSize = 256 * 1024
            let totalChunks = max(1, Int((totalBytes + UInt64(chunkSize) - 1) / UInt64(chunkSize)))
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)

            // Select workers: across active multi-NIC links when >= 8 chunks and multipath enabled
            let workers: [PeerLinkSession]
            if multipath && active.count > 1 && totalChunks >= 8 {
                workers = active.sorted { $0.estBandwidthMbps > $1.estBandwidthMbps }
            } else if let fastest = active.max(by: { $0.estBandwidthMbps < $1.estBandwidthMbps }) {
                workers = [fastest]
            } else {
                workers = [active[0]]
            }

            let channelTag = workers.count > 1
                ? "\(workers.count)路并发(" + workers.map(\.ifaceName).joined(separator: "+") + ")"
                : workers[0].ifaceName

            let (doubled, overflow) = totalBytes.multipliedReportingOverflow(by: 2)
            let computedReqFree = requiredFreeBytes ?? (isZip ? (overflow ? UInt64.max : doubled) : totalBytes)
            let offer = WireFileOfferPayload(
                transferId: transferId,
                fileName: displayFileName,
                totalBytes: totalBytes,
                chunkSize: chunkSize,
                totalChunks: totalChunks,
                scheme: scheme,
                style: style,
                edge: edge,
                offset: offset,
                isDirectoryZip: isZip,
                isClipboardItem: isClipboardItem ? true : nil,
                isClipboardMulti: isClipboardMulti ? true : nil,
                requiredFreeBytes: computedReqFree,
                batchItemCount: batchItemCount,
                isBatchBundle: isBatchBundle ? true : nil
            )
            if let offerFrame = WireFrameCodec.encodeJSON(type: .fileOffer, value: offer) {
                let offerSem = DispatchSemaphore(value: 0)
                let offerBox = LockedValueBox(false)
                workers[0].sendFrame(offerFrame) { ok in
                    offerBox.set(ok)
                    offerSem.signal()
                }
                offerSem.wait()
                if !offerBox.get() {
                    onFinished(false, "发送文件头失败或连接已断开")
                    return
                }
            }

            let startTime = Date()
            let nextChunkLock = NSLock()
            let sendState = TransferChunkSendState()
            var lastUiReportTime = Date.distantPast
            let group = DispatchGroup()
            let idBytes = Array(transferId.utf8)

            // Work-stealing concurrent chunk sender across selected NIC links
            for worker in workers {
                group.enter()
                self.ioQueue.async {
                    while true {
                        nextChunkLock.lock()
                        if sendState.failureReason != nil {
                            nextChunkLock.unlock()
                            break
                        }
                        let idx = sendState.nextChunkIdx
                        if idx >= totalChunks {
                            nextChunkLock.unlock()
                            break
                        }
                        sendState.nextChunkIdx += 1
                        let byteOffset = UInt64(idx) * UInt64(chunkSize)
                        let readLen = Int(min(UInt64(chunkSize), totalBytes - byteOffset))
                        var chunkData = Data()
                        do {
                            try fh.seek(toOffset: byteOffset)
                            chunkData = try fh.read(upToCount: readLen) ?? Data()
                        } catch {
                            sendState.failureReason = "读取第 \(idx) 块失败: \(error.localizedDescription)"
                            nextChunkLock.unlock()
                            break
                        }
                        guard chunkData.count == readLen else {
                            sendState.failureReason = "读取第 \(idx) 块长度不完整 (\(chunkData.count) != \(readLen))"
                            nextChunkLock.unlock()
                            break
                        }
                        nextChunkLock.unlock()

                        var payload = Data(capacity: 36 + 4 + chunkData.count)
                        payload.append(contentsOf: idBytes.prefix(36))
                        if idBytes.count < 36 {
                            payload.append(Data(repeating: 0x20, count: 36 - idBytes.count))
                        }
                        var beIdx = UInt32(idx).bigEndian
                        withUnsafeBytes(of: &beIdx) { payload.append(contentsOf: $0) }
                        payload.append(chunkData)

                        let sem = DispatchSemaphore(value: 0)
                        worker.sendFrame(WireFrameCodec.encode(type: .fileChunk, payload: payload)) { ok in
                            if !ok {
                                nextChunkLock.lock()
                                if sendState.failureReason == nil {
                                    sendState.failureReason = "通道 \(worker.ifaceName) 发送第 \(idx) 块失败或断线"
                                }
                                nextChunkLock.unlock()
                            }
                            sem.signal()
                        }
                        sem.wait()
                        nextChunkLock.lock()
                        let chunkFailed = (sendState.failureReason != nil)
                        nextChunkLock.unlock()
                        if chunkFailed {
                            break
                        }

                        if totalChunks <= 4 {
                            Thread.sleep(forTimeInterval: 0.06)
                        }

                        var shouldReport = false
                        var currentSent: UInt64 = 0
                        nextChunkLock.lock()
                        sendState.sentBytes += UInt64(chunkData.count)
                        currentSent = sendState.sentBytes
                        let now = Date()
                        if now.timeIntervalSince(lastUiReportTime) >= 0.055 || currentSent >= totalBytes {
                            lastUiReportTime = now
                            shouldReport = true
                        }
                        nextChunkLock.unlock()

                        if shouldReport {
                            let elapsed = max(0.01, now.timeIntervalSince(startTime))
                            let speedMbps = (Double(currentSent) * 8.0) / (elapsed * 1_000_000.0)
                            worker.estBandwidthMbps = min(max(speedMbps, 40.0), 5000.0)
                            let p = totalBytes == 0 ? 1.0 : min(1.0, Double(currentSent) / Double(totalBytes))
                            onProgress(p, speedMbps, displayFileName, sizeStr, channelTag)

                            if !isClipboardItem {
                                let sync = WirePortalSyncPayload(
                                    transferId: transferId,
                                    style: style,
                                    edge: edge,
                                    offset: offset,
                                    phase: "emergingOut",
                                    progress: p,
                                    fileName: displayFileName,
                                    fileSize: sizeStr,
                                    speedMbps: speedMbps,
                                    channelTag: channelTag
                                )
                                if let syncFrame = WireFrameCodec.encodeJSON(type: .portalSync, value: sync) {
                                    workers[0].sendFrame(syncFrame)
                                }
                            }
                        }
                    }
                    group.leave()
                }
            }

            group.wait()

            if let errMsg = sendState.failureReason {
                self.onLog?("[Transfer Error] [Tid=\(transferId)] stage=send_chunks error=\(errMsg)")
                let abortSync = WirePortalSyncPayload(
                    transferId: transferId, style: style, edge: edge, offset: offset,
                    phase: "idle", progress: 0, fileName: displayFileName, fileSize: sizeStr, speedMbps: 0, channelTag: channelTag
                )
                if let sf = WireFrameCodec.encodeJSON(type: .portalSync, value: abortSync) { workers[0].sendFrame(sf) }
                onFinished(false, "发送失败: \(errMsg)")
                return
            }

            let shaHex: String
            do {
                shaHex = try SecurityValidation.computeFileSha256Hex(url: sendURL)
            } catch {
                self.onLog?("[Transfer Error] [Tid=\(transferId)] stage=sha256 error=\(error.localizedDescription)")
                onFinished(false, "计算 SHA-256 失败: \(error.localizedDescription)")
                return
            }

            let ackSem = DispatchSemaphore(value: 0)
            let ackBox = LockedValueBox<WireFileAckPayload?>(nil)
            self.stateLock.lock()
            self.pendingAckLinks[transferId] = workers[0].id
            self.pendingFileAcks[transferId] = { ack in
                ackBox.set(ack)
                ackSem.signal()
            }
            self.stateLock.unlock()

            let comp = WireFileCompletePayload(transferId: transferId, sha256: shaHex)
            let compErrBox = LockedValueBox<String?>("写入完成帧失败")
            if let compFrame = WireFrameCodec.encodeJSON(type: .fileComplete, value: comp) {
                let compSem = DispatchSemaphore(value: 0)
                workers[0].sendFrame(compFrame) { ok in
                    if ok { compErrBox.set(nil) }
                    compSem.signal()
                }
                compSem.wait()
            }

            if compErrBox.get() != nil {
                self.stateLock.lock()
                self.pendingFileAcks.removeValue(forKey: transferId)
                self.stateLock.unlock()
                self.onLog?("[Transfer Error] [Tid=\(transferId)] stage=send_complete error=写入完成帧失败")
                onFinished(false, "发送完成确认包失败")
                return
            }

            let ackWaitRes = ackSem.wait(timeout: .now() + (isZip ? 35.0 : 20.0))
            if ackWaitRes == .timedOut {
                self.stateLock.lock()
                self.pendingFileAcks.removeValue(forKey: transferId)
                self.stateLock.unlock()
                self.onLog?("[Transfer Error] [Tid=\(transferId)] stage=wait_ack error=对端校验确认超时")
                onFinished(false, "对端校验确认超时（可能未成功落盘）")
                return
            }

            let receivedAck = ackBox.get()
            guard let ack = receivedAck, ack.ok else {
                let errDetail = receivedAck?.error ?? "对端完整性校验未通过"
                self.onLog?("[Transfer Error] [Tid=\(transferId)] stage=peer_nack error=\(errDetail)")
                if !isClipboardItem {
                    let abortSync = WirePortalSyncPayload(
                        transferId: transferId, style: style, edge: edge, offset: offset,
                        phase: "idle", progress: 0, fileName: displayFileName, fileSize: sizeStr, speedMbps: 0, channelTag: channelTag
                    )
                    if let sf = WireFrameCodec.encodeJSON(type: .portalSync, value: abortSync) { workers[0].sendFrame(sf) }
                }
                onFinished(false, "传输失败: \(errDetail)")
                return
            }

            if !isClipboardItem {
                let doneSync = WirePortalSyncPayload(
                    transferId: transferId,
                    style: style,
                    edge: edge,
                    offset: offset,
                    phase: "completed",
                    progress: 1.0,
                    fileName: displayFileName,
                    fileSize: sizeStr,
                    speedMbps: 0,
                    channelTag: channelTag
                )
                if let syncFrame = WireFrameCodec.encodeJSON(type: .portalSync, value: doneSync) {
                    workers[0].sendFrame(syncFrame)
                }
            }
            if totalBytes >= 128 * 1024 {
                let totalSec = max(0.01, Date().timeIntervalSince(startTime))
                let overallBps = Double(totalBytes) / totalSec
                let perWorker = max(256.0 * 1024.0, overallBps / Double(max(1, workers.count)))
                for w in workers {
                    w.measuredBytesPerSec = w.measuredBytesPerSec.map { $0 * 0.4 + perWorker * 0.6 } ?? perWorker
                }
            }
            onFinished(true, "已验证 SHA-256 并送达 \(displayFileName) (\(sizeStr)) 经由 \(channelTag)")
        }
    }

    private func handleIncomingFileOffer(_ offer: WireFileOfferPayload, via link: PeerLinkSession) {
        if let err = SecurityValidation.validateFileOffer(offer) {
            onLog?("[Transfer Error] [Link=\(link.id)] [Tid=\(offer.transferId)] stage=offer_validate error=\(err)")
            if let ack = WireFrameCodec.encodeJSON(type: .fileAck, value: WireFileAckPayload(transferId: offer.transferId, ok: false, savedPath: "", error: err)) {
                link.sendFrame(ack)
            }
            return
        }

        let targetParentDir: URL
        if offer.isClipboardItem == true {
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
            let clipRoot = cachesDir.appendingPathComponent("OmniFlow/Clipboard", isDirectory: true)
            Self.pruneOldClipboardBatches(in: clipRoot, keepCount: 6)
            targetParentDir = clipRoot.appendingPathComponent(String(offer.transferId.prefix(8)), isDirectory: true)
        } else {
            let dlDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            targetParentDir = dlDir.appendingPathComponent("OmniFlow", isDirectory: true)
        }
        let macBridgeDir = targetParentDir
        do {
            try FileManager.default.createDirectory(at: macBridgeDir, withIntermediateDirectories: true)
        } catch {
            let reason = "无法创建接收目录: \(error.localizedDescription)"
            onLog?("[Transfer Error] [Tid=\(offer.transferId)] stage=create_dir error=\(reason)")
            if let ack = WireFrameCodec.encodeJSON(type: .fileAck, value: WireFileAckPayload(transferId: offer.transferId, ok: false, savedPath: "", error: reason)) {
                link.sendFrame(ack)
            }
            onTransferFailed?(offer.fileName, reason)
            return
        }

        // Verify target volume has enough free space before allocating chunks
        let requiredFree = max(offer.requiredFreeBytes ?? offer.totalBytes, offer.totalBytes) + DragHandoffPolicy.requiredDiskMarginBytes
        if let vals = try? macBridgeDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let avail = vals.volumeAvailableCapacityForImportantUsage,
           avail > 0, UInt64(avail) < requiredFree {
            let reason = "目标磁盘可用空间不足（需要 \(ByteCountFormatter.string(fromByteCount: Int64(requiredFree), countStyle: .file))）"
            onLog?("[Transfer Error] [Link=\(link.id)] [Tid=\(offer.transferId)] stage=disk_space error=\(reason)")
            if let ack = WireFrameCodec.encodeJSON(type: .fileAck, value: WireFileAckPayload(transferId: offer.transferId, ok: false, savedPath: "", error: reason)) {
                link.sendFrame(ack)
            }
            onTransferFailed?(offer.fileName, reason)
            return
        }

        let stagingDir = macBridgeDir.appendingPathComponent(".stage_\(offer.transferId)", isDirectory: true)
        try? FileManager.default.removeItem(at: stagingDir)
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            let reason = "无法创建暂存目录: \(error.localizedDescription)"
            onLog?("[Transfer Error] [Tid=\(offer.transferId)] stage=create_stage error=\(reason)")
            if let ack = WireFrameCodec.encodeJSON(type: .fileAck, value: WireFileAckPayload(transferId: offer.transferId, ok: false, savedPath: "", error: reason)) {
                link.sendFrame(ack)
            }
            onTransferFailed?(offer.fileName, reason)
            return
        }

        let tmpURL = stagingDir.appendingPathComponent("payload.part")
        FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: tmpURL) else {
            try? FileManager.default.removeItem(at: stagingDir)
            let reason = "无法创建暂存文件"
            onLog?("[Transfer Error] [Tid=\(offer.transferId)] stage=open_temp error=\(reason)")
            if let ack = WireFrameCodec.encodeJSON(type: .fileAck, value: WireFileAckPayload(transferId: offer.transferId, ok: false, savedPath: "", error: reason)) {
                link.sendFrame(ack)
            }
            onTransferFailed?(offer.fileName, reason)
            return
        }

        var replacedPrev: IncomingFileState?
        var st = IncomingFileState(
            offer: offer,
            stagingDir: stagingDir,
            tempURL: tmpURL,
            finalParentDir: macBridgeDir,
            handle: fh,
            receivedChunks: [],
            receivedBytes: 0,
            failedReason: nil,
            startTime: Date(),
            lastUiNotify: .distantPast,
            pendingComplete: nil,
            pendingCompleteLink: nil
        )
        fileLock.lock()
        replacedPrev = incomingFiles.removeValue(forKey: offer.transferId)
        if let early = earlyFileChunks.removeValue(forKey: offer.transferId) {
            for c in early {
                earlyFileChunkTotalBytes = max(0, earlyFileChunkTotalBytes - c.data.count)
                applyIncomingChunkLocked(&st, tid: offer.transferId, idx: c.idx, chunkData: c.data, linkId: c.linkId)
            }
        }
        incomingFiles[offer.transferId] = st
        fileLock.unlock()

        if let prev = replacedPrev {
            try? prev.handle.close()
            try? FileManager.default.removeItem(at: prev.stagingDir)
        }

        if offer.isClipboardItem != true {
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(offer.totalBytes), countStyle: .file)
            onRemotePortalSync?(WirePortalSyncPayload(
                transferId: offer.transferId,
                style: offer.style,
                edge: offer.edge,
                offset: offer.offset,
                phase: "emergingOut",
                progress: 0.08,
                fileName: offer.fileName,
                fileSize: sizeStr,
                speedMbps: 0,
                channelTag: "Peer"
            ))
        }
    }

    private static func pruneOldClipboardBatches(in root: URL, keepCount: Int) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else { return }
        if items.count <= keepCount { return }
        let sorted = items.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return da > db
        }
        for old in sorted.dropFirst(keepCount) {
            try? fm.removeItem(at: old)
        }
    }

    private func applyIncomingChunkLocked(_ st: inout IncomingFileState, tid: String, idx: Int, chunkData: Data, linkId: String) {
        if st.failedReason != nil { return }
        guard let expectedLen = SecurityValidation.expectedChunkLength(offer: st.offer, index: idx) else {
            let reason = "分块序号越界 idx=\(idx)/\(st.offer.totalChunks)"
            st.failedReason = reason
            onLog?("[Transfer Error] [Link=\(linkId)] [Tid=\(tid)] stage=chunk_bounds error=\(reason)")
            return
        }
        guard chunkData.count == expectedLen else {
            let reason = "分块 #\(idx) 长度异常 (\(chunkData.count) != \(expectedLen))"
            st.failedReason = reason
            onLog?("[Transfer Error] [Link=\(linkId)] [Tid=\(tid)] stage=chunk_len error=\(reason)")
            return
        }
        if st.receivedChunks.contains(idx) { return }

        let byteOffset = UInt64(idx) * UInt64(st.offer.chunkSize)
        do {
            try st.handle.seek(toOffset: byteOffset)
            try st.handle.write(contentsOf: chunkData)
        } catch {
            let reason = "写入暂存分块失败: \(error.localizedDescription)"
            st.failedReason = reason
            onLog?("[Transfer Error] [Link=\(linkId)] [Tid=\(tid)] stage=chunk_write error=\(reason)")
            return
        }

        st.receivedChunks.insert(idx)
        st.receivedBytes += UInt64(chunkData.count)
    }

    private func handleIncomingFileChunk(_ payload: Data, via link: PeerLinkSession) {
        guard payload.count >= 40 else { return }
        let tid = String(data: payload.subdata(in: 0..<36), encoding: .utf8)?.trimmingCharacters(in: .whitespaces) ?? ""
        let idx = Int(UInt32(bigEndian: payload.subdata(in: 36..<40).withUnsafeBytes { $0.load(as: UInt32.self) }))
        let chunkData = payload.subdata(in: 40..<payload.count)

        fileLock.lock()
        guard var st = incomingFiles[tid] else {
            // Buffer early chunks briefly if a parallel NIC delivered chunks before FileOffer arrived on primary NIC
            let now = Date()
            for (k, list) in earlyFileChunks {
                let fresh = list.filter { now.timeIntervalSince($0.at) <= 15.0 }
                if fresh.count != list.count {
                    let removedBytes = list.reduce(0) { $0 + $1.data.count } - fresh.reduce(0) { $0 + $1.data.count }
                    earlyFileChunkTotalBytes = max(0, earlyFileChunkTotalBytes - removedBytes)
                    if fresh.isEmpty { earlyFileChunks.removeValue(forKey: k) }
                    else { earlyFileChunks[k] = fresh }
                }
            }
            if earlyFileChunkTotalBytes + chunkData.count <= 16 * 1024 * 1024 {
                var arr = earlyFileChunks[tid] ?? []
                if arr.count < 64 && !arr.contains(where: { $0.idx == idx }) {
                    arr.append((idx, chunkData, link.id, now))
                    earlyFileChunks[tid] = arr
                    earlyFileChunkTotalBytes += chunkData.count
                }
            }
            fileLock.unlock()
            return
        }
        applyIncomingChunkLocked(&st, tid: tid, idx: idx, chunkData: chunkData, linkId: link.id)

        let now = Date()
        let isCompleteNow = st.receivedChunks.count == st.offer.totalChunks && st.receivedBytes == st.offer.totalBytes
        let pendingComp = st.pendingComplete
        let pendingLink = st.pendingCompleteLink

        if isCompleteNow && pendingComp != nil {
            incomingFiles.removeValue(forKey: tid)
            fileLock.unlock()
            finalizeIncomingFile(st, comp: pendingComp!, via: pendingLink ?? link)
            return
        }

        let shouldNotify = now.timeIntervalSince(st.lastUiNotify) >= 0.065 || st.receivedBytes >= st.offer.totalBytes
        if shouldNotify { st.lastUiNotify = now }
        incomingFiles[tid] = st
        let total = max(1, st.offer.totalBytes)
        let p = min(1.0, Double(st.receivedBytes) / Double(total))
        let elapsed = max(0.01, now.timeIntervalSince(st.startTime))
        let speedMbps = (Double(st.receivedBytes) * 8.0) / (elapsed * 1_000_000.0)
        let offer = st.offer
        fileLock.unlock()

        if shouldNotify && offer.isClipboardItem != true {
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(offer.totalBytes), countStyle: .file)
            onRemotePortalSync?(WirePortalSyncPayload(
                transferId: tid,
                style: offer.style,
                edge: offer.edge,
                offset: offer.offset,
                phase: "emergingOut",
                progress: max(0.08, p),
                fileName: offer.fileName,
                fileSize: sizeStr,
                speedMbps: speedMbps,
                channelTag: "Incoming"
            ))
        }
    }

    private func handleIncomingFileComplete(_ comp: WireFileCompletePayload, via link: PeerLinkSession) {
        fileLock.lock()
        guard var st = incomingFiles.removeValue(forKey: comp.transferId) else {
            fileLock.unlock()
            return
        }
        if st.failedReason == nil &&
           (st.receivedChunks.count != st.offer.totalChunks || st.receivedBytes != st.offer.totalBytes) {
            // Wait up to 3.0s for delayed chunks still in flight on parallel multi-NIC worker sockets
            st.pendingComplete = comp
            st.pendingCompleteLink = link
            incomingFiles[comp.transferId] = st
            fileLock.unlock()

            let tid = comp.transferId
            ioQueue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self else { return }
                self.fileLock.lock()
                guard let stillSt = self.incomingFiles.removeValue(forKey: tid) else {
                    self.fileLock.unlock()
                    return
                }
                self.fileLock.unlock()
                let pComp = stillSt.pendingComplete ?? comp
                let pLink = stillSt.pendingCompleteLink ?? link
                self.finalizeIncomingFile(stillSt, comp: pComp, via: pLink)
            }
            return
        }
        fileLock.unlock()
        finalizeIncomingFile(st, comp: comp, via: link)
    }

    private func finalizeIncomingFile(_ st: IncomingFileState, comp: WireFileCompletePayload, via link: PeerLinkSession) {
        func failTransfer(_ reason: String) {
            try? st.handle.close()
            try? FileManager.default.removeItem(at: st.stagingDir)
            onLog?("[Transfer Error] [Link=\(link.id)] [Tid=\(comp.transferId)] stage=commit error=\(reason)")
            if let ackFrame = WireFrameCodec.encodeJSON(
                type: .fileAck,
                value: WireFileAckPayload(transferId: comp.transferId, ok: false, savedPath: "", error: reason)
            ) {
                link.sendFrame(ackFrame)
            }
            onTransferFailed?(st.offer.fileName, reason)
        }

        if let prevErr = st.failedReason {
            failTransfer(prevErr)
            return
        }
        guard st.receivedChunks.count == st.offer.totalChunks,
              st.receivedBytes == st.offer.totalBytes else {
            failTransfer("分块未收齐 (已收 \(st.receivedChunks.count)/\(st.offer.totalChunks) 块, \(st.receivedBytes)/\(st.offer.totalBytes) 字节)")
            return
        }

        do {
            try st.handle.synchronize()
            try st.handle.close()
        } catch {
            failTransfer("落盘刷新失败: \(error.localizedDescription)")
            return
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: st.tempURL.path)
        let actualSize = (attrs?[.size] as? UInt64) ?? 0
        guard actualSize == st.offer.totalBytes else {
            failTransfer("磁盘体积校验失败 (\(actualSize) != \(st.offer.totalBytes))")
            return
        }

        let expectedSha = comp.sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard expectedSha.count == 64 else {
            failTransfer("缺少有效的 SHA-256 摘要")
            return
        }
        let actualSha: String
        do {
            actualSha = try SecurityValidation.computeFileSha256Hex(url: st.tempURL)
        } catch {
            failTransfer("接收端计算 SHA-256 失败: \(error.localizedDescription)")
            return
        }
        guard actualSha == expectedSha else {
            failTransfer("SHA-256 完整性校验不匹配")
            return
        }

        var finalURL: URL
        do {
            if st.offer.isDirectoryZip {
                let rawFolderStem = URL(fileURLWithPath: st.offer.fileName).deletingPathExtension().lastPathComponent
                let safeStem = SecurityValidation.isValidSingleFileName(rawFolderStem) ? rawFolderStem : "ReceivedFolder"
                finalURL = try SafeZipExtractor.extractSafely(
                    zipURL: st.tempURL,
                    destParentDir: st.finalParentDir,
                    preferredFolderName: safeStem
                )
                try? FileManager.default.removeItem(at: st.stagingDir)
            } else {
                let targetDest = uniqueDestinationURL(dir: st.finalParentDir, fileName: st.offer.fileName)
                let parentStd = st.finalParentDir.standardizedFileURL.path
                let parentPrefix = parentStd.hasSuffix("/") ? parentStd : parentStd + "/"
                guard targetDest.standardizedFileURL.path.hasPrefix(parentPrefix) else {
                    failTransfer("目标保存路径越界被拦截")
                    return
                }
                try FileManager.default.moveItem(at: st.tempURL, to: targetDest)
                try? FileManager.default.removeItem(at: st.stagingDir)
                finalURL = targetDest
            }
        } catch {
            failTransfer("安全提交/解压失败: \(error.localizedDescription)")
            return
        }

        let ack = WireFileAckPayload(transferId: comp.transferId, ok: true, savedPath: finalURL.path, error: nil)
        if let ackFrame = WireFrameCodec.encodeJSON(type: .fileAck, value: ack) {
            link.sendFrame(ackFrame)
        }
        onIncomingFileCompleted?(st.offer, finalURL)
    }

    private func uniqueDestinationURL(dir: URL, fileName: String) -> URL {
        let base = dir.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: base.path) { return base }
        let stem = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension
        for i in 1...999 {
            let candidateName = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            let candidate = dir.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        let suffix = UUID().uuidString.prefix(8)
        let fallbackName = ext.isEmpty ? "\(stem)_\(suffix)" : "\(stem)_\(suffix).\(ext)"
        return dir.appendingPathComponent(fallbackName)
    }

    // MARK: - Helpers

    private func isRunning() -> Bool {
        stateLock.lock()
        let r = running
        stateLock.unlock()
        return r
    }

    func buildHelloPayload() -> WireHelloPayload {
        let localNics = enumerateLocalIPv4()
        let usbIps = localNics.map(\.ip).filter { MacBridgeSubnet.isUsbBridgeIp($0) }
        let lanIps = localNics.map(\.ip).filter { !MacBridgeSubnet.isUsbBridgeIp($0) }
        let monitors: [WireMonitorDto] = NSScreen.screens.enumerated().map { idx, scr in
            var bx = Int(scr.frame.origin.x)
            var by = Int(-scr.frame.origin.y)
            if let num = scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let bounds = CGDisplayBounds(CGDirectDisplayID(num.uint32Value))
                bx = Int(bounds.origin.x)
                by = Int(bounds.origin.y)
            }
            let w = Int(scr.frame.width * scr.backingScaleFactor)
            let h = Int(scr.frame.height * scr.backingScaleFactor)
            return WireMonitorDto(
                id: "mac_disp_\(idx)",
                displayIndex: idx + 1,
                name: scr.localizedName.isEmpty ? "Mac #\(idx + 1)" : scr.localizedName,
                osKind: "macOS",
                widthPx: max(640, w),
                heightPx: max(480, h),
                scaleFactor: Double(scr.backingScaleFactor),
                isPrimary: idx == 0,
                boundsX: bx,
                boundsY: by
            )
        }
        return WireHelloPayload(
            os: "macOS",
            host: Host.current().localizedName ?? "Mac",
            fingerprint: localFingerprint,
            ips: lanIps,
            usbIps: usbIps,
            monitors: monitors
        )
    }

    struct LocalNicInfo {
        let iface: String
        let ip: String
        let mask: String?
        let broadcast: String?
    }

    func enumerateLocalIPv4() -> [LocalNicInfo] {
        var result: [LocalNicInfo] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return result }
        defer { freeifaddrs(first) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            defer { cur = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: p.pointee.ifa_name)
            var ipBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &ipBuf, socklen_t(ipBuf.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: ipBuf)
            if ip.hasPrefix("169.254.") { continue }

            var maskStr: String?
            if let nm = p.pointee.ifa_netmask, nm.pointee.sa_family == UInt8(AF_INET) {
                var mb = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(nm, socklen_t(nm.pointee.sa_len), &mb, socklen_t(mb.count), nil, 0, NI_NUMERICHOST) == 0 {
                    maskStr = String(cString: mb)
                }
            }
            var bcastStr: String?
            if (flags & IFF_BROADCAST) != 0, let bc = p.pointee.ifa_dstaddr, bc.pointee.sa_family == UInt8(AF_INET) {
                var bb = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(bc, socklen_t(bc.pointee.sa_len), &bb, socklen_t(bb.count), nil, 0, NI_NUMERICHOST) == 0 {
                    bcastStr = String(cString: bb)
                }
            }
            result.append(LocalNicInfo(iface: name, ip: ip, mask: maskStr, broadcast: bcastStr))
        }
        return result
    }

    private func matchingLocalIps(for peerIp: String) -> [String] {
        let nics = enumerateLocalIPv4()
        let peerParts = peerIp.split(separator: ".")
        guard peerParts.count == 4 else { return [] }
        let prefix3 = "\(peerParts[0]).\(peerParts[1]).\(peerParts[2])."
        return nics.filter { $0.ip.hasPrefix(prefix3) }.map(\.ip)
    }

    private func interfaceName(for ip: String) -> String? {
        enumerateLocalIPv4().first(where: { $0.ip == ip })?.iface
    }
}

private final class LockedValueBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: T) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

private final class TransferChunkSendState: @unchecked Sendable {
    var nextChunkIdx: Int = 0
    var sentBytes: UInt64 = 0
    var failureReason: String? = nil
}
