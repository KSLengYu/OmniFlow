import Foundation
import Network
import Security
import CryptoKit
import Darwin
import AppKit

/// Manages multi-NIC discovery, TLS/Raw listeners, control/data plane scheduling, and chunked file transfers.
final class DeskflowTransport: @unchecked Sendable {
    static let shared = DeskflowTransport()

    let ioQueue = DispatchQueue(label: "com.omniflow.transport.io", qos: .userInteractive, attributes: .concurrent)
    let stateLock = NSLock()
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
    private(set) var peerHostOs: String = ""
    private var peerMonitors: [WireMonitorDto] = []

    /// Active incoming file transfers keyed by transferId (implemented in DeskflowTransport+FileTransfer.swift)
    struct IncomingFileState {
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
    let fileLock = NSLock()
    var incomingFiles: [String: IncomingFileState] = [:]
    var earlyFileChunks: [String: [(idx: Int, data: Data, linkId: String, at: Date)]] = [:]
    var earlyFileChunkTotalBytes: Int = 0
    var pendingFileAcks: [String: (WireFileAckPayload) -> Void] = [:]
    var pendingAckLinks: [String: String] = [:]
    var activeBulkTransfers: Int = 0

    // Callbacks delivered to DeskflowEngine on MainActor
    var onLinksUpdated: (() -> Void)?
    var onPeerMonitorsUpdated: (([WireMonitorDto], String, String) -> Void)?
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
                hostName: hostHint.isEmpty ? "对端设备 (\(remoteIp))" : hostHint,
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
                peerHostOs = hello.os
                peerMonitors = hello.monitors
                stateLock.unlock()
                onPeerMonitorsUpdated?(hello.monitors, hello.host, hello.os)
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
                stateLock.lock()
                let isMacPeer = peerHostOs.lowercased().contains("mac")
                stateLock.unlock()
                let isIncoming = isMacPeer ? (sw.action != "leave") : (sw.targetOs == "macOS")
                let started = KvmStageTracer.shared.beginFocusSwitch(targetOs: isIncoming ? "macOS" : sw.targetOs)
                let sX = String(format: "%.4f", sw.normX)
                let sY = String(format: "%.4f", sw.normY)
                KvmStageTracer.shared.log(
                    seq: started.seq,
                    t0Ns: started.recvNs,
                    nowNs: started.recvNs,
                    "netRecvFocus target=\(sw.targetOs) action=\(sw.action ?? "nil") incoming=\(isIncoming) link=\(link.id) mon=\(sw.monitorIndex) norm=(\(sX),\(sY))"
                )
                if isIncoming, onKvmFocusSwitch == nil {
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

    func matchingLocalIps(for peerIp: String) -> [String] {
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
