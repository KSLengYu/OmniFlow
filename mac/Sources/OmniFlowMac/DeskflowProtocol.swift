import Foundation
import CryptoKit
import Compression
import Security
import Network

// MARK: - Wire Protocol Constants (Must match Windows DeskflowTransport.cs)

enum DeskflowPorts {
    static let rawUsbTcp: UInt16 = 24810
    static let lanTlsTcp: UInt16 = 24811
    static let udpDiscovery: UInt16 = 24812
}

enum DeskflowMsgType: UInt8 {
    case hello = 0x01
    case ping = 0x02
    case pong = 0x03
    case clipboardText = 0x04
    case portalSync = 0x05
    case fileOffer = 0x06
    case fileChunk = 0x07
    case fileComplete = 0x08
    case fileAck = 0x09
    case dataStreamBind = 0x0A
    case clipboardImage = 0x0B

    case mouseMoveAbs = 0x10
    case mouseButton = 0x11
    case mouseScroll = 0x12
    case keyEvent = 0x13
    case semanticHotkey = 0x14
    case kvmFocusSwitch = 0x15
    case topologyUpdate = 0x16
    case configSync = 0x17
}

// MARK: - Wire JSON Payloads

struct WireMonitorDto: Codable, Equatable {
    let id: String
    let displayIndex: Int
    let name: String
    let osKind: String
    let widthPx: Int
    let heightPx: Int
    let scaleFactor: Double
    let isPrimary: Bool
    let boundsX: Int
    let boundsY: Int
}

struct WireHelloPayload: Codable {
    let os: String
    let host: String
    let fingerprint: String
    let ips: [String]
    let usbIps: [String]
    let monitors: [WireMonitorDto]
}

struct WireBeaconPayload: Codable {
    let type: String
    let os: String
    let host: String
    let rawPort: UInt16
    let tlsPort: UInt16
    let ips: [String]
    let usbIps: [String]
    let fingerprint: String
}

struct WirePortalSyncPayload: Codable {
    let transferId: String
    let style: String       // "blackhole" | "cube"
    let edge: String        // "left" | "right" | "top" | "bottom"
    let offset: Double
    let phase: String       // "idle" | "hoverExpand" | "suckingIn" | "emergingOut" | "completed"
    let progress: Double
    let fileName: String
    let fileSize: String
    let speedMbps: Double
    let channelTag: String
}

struct WireFileOfferPayload: Codable {
    let transferId: String
    let fileName: String
    let totalBytes: UInt64
    let chunkSize: Int
    let totalChunks: Int
    let scheme: String      // "a" | "b"
    let style: String       // "blackhole" | "cube"
    let edge: String
    let offset: Double
    let isDirectoryZip: Bool
    var isClipboardItem: Bool? = nil
    var isClipboardMulti: Bool? = nil
    var requiredFreeBytes: UInt64? = nil
    var batchItemCount: Int? = nil
    var isBatchBundle: Bool? = nil
}

struct WireFileCompletePayload: Codable {
    let transferId: String
    let sha256: String
}

struct WireFileAckPayload: Codable {
    let transferId: String
    let ok: Bool
    let savedPath: String
    var error: String? = nil
}

struct WireSemanticHotkeyPayload: Codable {
    let action: String
}

struct WireKvmFocusPayload: Codable {
    let targetOs: String
    let monitorIndex: Int
    let normX: Double
    let normY: Double
}

struct WireDataBindPayload: Codable {
    let transferId: String
}

struct WireMonitorLayoutEntry: Codable, Equatable {
    let id: String
    let canvasX: Double
    let canvasY: Double
    var displayIndex: Int? = nil
    var name: String? = nil
    var osKind: String? = nil
    var widthPx: Int? = nil
    var heightPx: Int? = nil
    var scaleFactor: Double? = nil
    var isPrimary: Bool? = nil
}

struct WireTopologySyncPayload: Codable {
    let senderOs: String
    let timestamp: Double
    let items: [WireMonitorLayoutEntry]
}

struct WireConfigSyncPayload: Codable {
    let senderOs: String
    let timestamp: Double
    let controlMode: String       // "bidirectional" | "manualSwitch"
    let keymapProfile: String     // "hybrid" | "deskflowNative" | "omniflowMacHabit"
    let enabledRuleIds: [String]
}

// MARK: - Framing Codec

enum WireFrameCodec {
    static func encode(type: DeskflowMsgType, payload: Data) -> Data {
        var frame = Data(capacity: 5 + payload.count)
        var len = UInt32(1 + payload.count).bigEndian
        withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        frame.append(type.rawValue)
        frame.append(payload)
        return frame
    }

    static func encodeJSON<T: Encodable>(type: DeskflowMsgType, value: T) -> Data? {
        guard let json = try? JSONEncoder().encode(value) else { return nil }
        return encode(type: type, payload: json)
    }
}

// MARK: - MacBridge USB Prefix Classifier

enum MacBridgeSubnet {
    static let usbPrefixes = [
        "10.13.37.", "10.13.38.", "10.13.39.",
        "10.13.137.", "10.13.138.",
        "10.13.237.", "10.13.238.", "10.13.239.",
        "100.113.37.", "172.31.237.", "192.168.237."
    ]

    static func isUsbBridgeIp(_ ip: String) -> Bool {
        usbPrefixes.contains(where: { ip.hasPrefix($0) })
    }
}

// MARK: - Self-Signed TLS 1.3 Identity & TOFU Fingerprint Helper

enum TlsIdentityHelper {
    private static let p12Password = "macbridge"

    static func loadOrCreateIdentity() -> (identity: SecIdentity, fingerprint: String)? {
        let fm = FileManager.default
        guard let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = appSup.appendingPathComponent("OmniFlow", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        let keyURL = dir.appendingPathComponent("omniflow_lan_key.pem")
        let certURL = dir.appendingPathComponent("omniflow_lan_cert.pem")
        let p12URL = dir.appendingPathComponent("omniflow_lan.p12")

        if !fm.fileExists(atPath: p12URL.path) {
            let proc1 = Process()
            proc1.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            proc1.arguments = [
                "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", keyURL.path,
                "-out", certURL.path,
                "-days", "3650",
                "-subj", "/CN=OmniFlow-Core"
            ]
            proc1.standardOutput = Pipe()
            proc1.standardError = Pipe()
            try? proc1.run()
            proc1.waitUntilExit()

            let proc2 = Process()
            proc2.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            proc2.arguments = [
                "pkcs12", "-export",
                "-out", p12URL.path,
                "-inkey", keyURL.path,
                "-in", certURL.path,
                "-passout", "pass:\(p12Password)"
            ]
            proc2.standardOutput = Pipe()
            proc2.standardError = Pipe()
            try? proc2.run()
            proc2.waitUntilExit()
        }
        // Remove plaintext PEM key/cert once packaged into .p12 so unencrypted private key does not linger on disk
        if fm.fileExists(atPath: p12URL.path) {
            try? fm.removeItem(at: keyURL)
            try? fm.removeItem(at: certURL)
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12URL.path)

        guard let p12Data = try? Data(contentsOf: p12URL) else { return nil }
        let options: [String: Any] = [kSecImportExportPassphrase as String: p12Password]
        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let identityAny = first[kSecImportItemIdentity as String] else {
            return nil
        }
        let identity = identityAny as! SecIdentity
        var certRef: SecCertificate?
        SecIdentityCopyCertificate(identity, &certRef)
        let fp = certRef.map { sha256Fingerprint($0) } ?? "SHA256:LOCAL"
        return (identity, fp)
    }

    static func sha256Fingerprint(_ cert: SecCertificate) -> String {
        let der = SecCertificateCopyData(cert) as Data
        let digest = SHA256.hash(data: der)
        return "SHA256:" + digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func makeTlsParameters(
        identity: SecIdentity?,
        verifyPeer: @escaping @Sendable (String) -> Bool
    ) -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        let secOpts = tlsOptions.securityProtocolOptions

        sec_protocol_options_set_min_tls_protocol_version(secOpts, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(secOpts, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(secOpts, true)

        if let identity = identity, let secId = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(secOpts, secId)
        }

        sec_protocol_options_set_verify_block(secOpts, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                  let leaf = chain.first else {
                complete(false)
                return
            }
            let fp = sha256Fingerprint(leaf)
            let trusted = verifyPeer(fp)
            complete(trusted)
        }, DispatchQueue.global(qos: .userInteractive))

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2
        tcpOptions.keepaliveInterval = 2
        tcpOptions.keepaliveCount = 2
        tcpOptions.connectionTimeout = 4
        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        params.serviceClass = .interactiveVoice
        return params
    }

    static func makeRawParameters(localIp: String? = nil) -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2
        tcpOptions.keepaliveInterval = 2
        tcpOptions.keepaliveCount = 2
        tcpOptions.connectionTimeout = 4
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.serviceClass = .interactiveVoice
        if let ip = localIp, !ip.isEmpty {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(ip), port: 0)
        }
        return params
    }
}

// MARK: - Pairing Trust Store & SAS Short Code Derivation

struct TrustedPeerRecord: Codable, Equatable {
    let fingerprint: String
    var hostName: String
    var pairedAtIso: String
}

struct PendingPairingRequest: Equatable {
    let fingerprint: String
    let remoteIp: String
    let hostName: String
    let sasCode: String
}

final class TrustedPeerStore: @unchecked Sendable {
    private let lock = NSLock()
    private var trusted: [String: TrustedPeerRecord] = [:]
    private let storeURL: URL?

    init(customStoreURL: URL? = nil) {
        if let u = customStoreURL {
            storeURL = u
        } else if let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = appSup.appendingPathComponent("OmniFlow", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            storeURL = dir.appendingPathComponent("trusted_peers.json")
        } else {
            storeURL = nil
        }
        load()
    }

    func isTrusted(_ fingerprint: String) -> Bool {
        let norm = SecurityValidation.normalizeFingerprint(fingerprint)
        guard !norm.isEmpty else { return false }
        lock.lock()
        let ok = trusted[norm] != nil
        lock.unlock()
        return ok
    }

    func allTrusted() -> [TrustedPeerRecord] {
        lock.lock()
        let list = Array(trusted.values).sorted { $0.pairedAtIso > $1.pairedAtIso }
        lock.unlock()
        return list
    }

    func addTrusted(fingerprint: String, hostName: String) {
        let norm = SecurityValidation.normalizeFingerprint(fingerprint)
        guard !norm.isEmpty else { return }
        let rec = TrustedPeerRecord(
            fingerprint: norm,
            hostName: hostName.isEmpty ? "Windows Peer" : hostName,
            pairedAtIso: ISO8601DateFormatter().string(from: Date())
        )
        lock.lock()
        trusted[norm] = rec
        saveLocked()
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        trusted.removeAll()
        saveLocked()
        lock.unlock()
    }

    func removeTrusted(_ fingerprint: String) {
        let norm = SecurityValidation.normalizeFingerprint(fingerprint)
        lock.lock()
        trusted.removeValue(forKey: norm)
        saveLocked()
        lock.unlock()
    }

    private func load() {
        guard let url = storeURL, let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([TrustedPeerRecord].self, from: data) else { return }
        lock.lock()
        for item in list {
            let norm = SecurityValidation.normalizeFingerprint(item.fingerprint)
            if !norm.isEmpty { trusted[norm] = item }
        }
        lock.unlock()
    }

    private func saveLocked() {
        guard let url = storeURL else { return }
        let list = Array(trusted.values)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

// MARK: - File Integrity, Boundary Validation & Zip-Slip Safe Extractor

enum SecurityValidation {
    static let maxChunkBytes = 8 * 1024 * 1024
    static let maxTransferBytes: UInt64 = 20 * 1024 * 1024 * 1024
    static let maxTransferChunks = 200_000
    static let maxZipEntries = 10_000
    static let maxZipUncompressedBytes: UInt64 = 4 * 1024 * 1024 * 1024
    static let maxZipPathDepth = 16
    static let maxZipBombRatio: UInt64 = 100

    static func normalizeFingerprint(_ fp: String) -> String {
        fp.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Deterministic 6-digit SAS verification code identical across macOS & Windows.
    static func computePairingSasCode(localFingerprint: String, peerFingerprint: String) -> String {
        let a = normalizeFingerprint(localFingerprint)
        let b = normalizeFingerprint(peerFingerprint)
        let combined = (a <= b) ? "\(a)|\(b)" : "\(b)|\(a)"
        let digest = Array(SHA256.hash(data: Data(combined.utf8)))
        let val = (UInt32(digest[0]) << 24) | (UInt32(digest[1]) << 16) | (UInt32(digest[2]) << 8) | UInt32(digest[3])
        let code = Int(val % 1_000_000)
        return String(format: "%03d-%03d", code / 1000, code % 1000)
    }

    static func isValidTransferId(_ tid: String) -> Bool {
        guard !tid.isEmpty, tid.count <= 64 else { return false }
        return tid.unicodeScalars.allSatisfy { sc in
            (sc.value >= 0x30 && sc.value <= 0x39) ||
            (sc.value >= 0x41 && sc.value <= 0x5A) ||
            (sc.value >= 0x61 && sc.value <= 0x7A) ||
            sc == "-" || sc == "_"
        }
    }

    /// Strictly validates remote filename as a single leaf name (blocks path traversal, separators, drive letters, controls).
    static func isValidSingleFileName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == name, name.count <= 255 else { return false }
        if name == "." || name == ".." { return false }
        if name.contains("/") || name.contains("\\") || name.contains(":") { return false }
        for scalar in name.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F {
            return false
        }
        return true
    }

    static func validateFileOffer(_ offer: WireFileOfferPayload) -> String? {
        guard isValidTransferId(offer.transferId) else { return "非法传输 ID" }
        guard isValidSingleFileName(offer.fileName) else { return "非法远端文件名（拒绝路径或特殊字符）" }
        guard offer.chunkSize > 0, offer.chunkSize <= maxChunkBytes else { return "非法分块尺寸: \(offer.chunkSize)" }
        guard offer.totalBytes <= maxTransferBytes else { return "文件体积超出上限" }
        guard offer.totalChunks > 0, offer.totalChunks <= maxTransferChunks else { return "非法分块总数: \(offer.totalChunks)" }

        if offer.totalBytes == 0 {
            if offer.totalChunks != 1 { return "空文件分块数必须为 1" }
        } else {
            let chunkU = UInt64(offer.chunkSize)
            let chunksU = UInt64(offer.totalChunks)
            let (minPrev, ov1) = (chunksU - 1).multipliedReportingOverflow(by: chunkU)
            let (maxCov, ov2) = chunksU.multipliedReportingOverflow(by: chunkU)
            if ov1 || minPrev >= offer.totalBytes { return "分块数量与文件大小不匹配（过多）" }
            if !ov2 && maxCov < offer.totalBytes { return "分块数量不足以覆盖总大小" }
        }
        return nil
    }

    static func expectedChunkLength(offer: WireFileOfferPayload, index: Int) -> Int? {
        guard index >= 0, index < offer.totalChunks, offer.chunkSize > 0 else { return nil }
        if offer.totalBytes == 0 { return index == 0 ? 0 : nil }
        let start = UInt64(index) * UInt64(offer.chunkSize)
        guard start < offer.totalBytes else { return nil }
        return Int(min(UInt64(offer.chunkSize), offer.totalBytes - start))
    }

    static func computeFileSha256Hex(url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            let data = try fh.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Validates a ZIP relative entry path and returns sanitized POSIX segments, rejecting traversal & deep nesting.
    static func sanitizeZipRelativeSegments(_ rawName: String, allowDirectory: Bool) -> [String]? {
        if rawName.isEmpty || rawName.hasPrefix("/") || rawName.hasPrefix("\\") { return nil }
        if rawName.contains(":") { return nil }
        for sc in rawName.unicodeScalars where sc.value < 0x20 || sc.value == 0x7F {
            return nil
        }
        let normalized = rawName.replacingOccurrences(of: "\\", with: "/")
        let stripped = allowDirectory && normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
        if stripped.isEmpty { return allowDirectory ? [] : nil }
        let parts = stripped.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count > maxZipPathDepth { return nil }
        for p in parts {
            if p.isEmpty || p == "." || p == ".." { return nil }
        }
        return parts
    }
}

enum SafeZipExtractor {
    enum ZipError: LocalizedError {
        case invalidArchive(String)
        case securityViolation(String)

        var errorDescription: String? {
            switch self {
            case .invalidArchive(let m): return "ZIP 格式错误: \(m)"
            case .securityViolation(let m): return "ZIP 安全校验拒绝: \(m)"
            }
        }
    }

    private struct CentralEntry {
        let segments: [String]
        let isDir: Bool
        let method: UInt16
        let expectedCrc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
    }

    private static let crc32Table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private static func computeCrc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in data {
            crc = crc32Table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    private static func readU16(_ d: Data, _ off: Int) -> UInt16 {
        UInt16(d[off]) | (UInt16(d[off + 1]) << 8)
    }

    private static func readU32(_ d: Data, _ off: Int) -> UInt32 {
        UInt32(d[off]) | (UInt32(d[off + 1]) << 8) | (UInt32(d[off + 2]) << 16) | (UInt32(d[off + 3]) << 24)
    }

    static func extractSafely(zipURL: URL, destParentDir: URL, preferredFolderName: String) throws -> URL {
        let data = try Data(contentsOf: zipURL, options: .mappedIfSafe)
        guard data.count >= 22 else { throw ZipError.invalidArchive("文件过小") }

        // Locate EOCD (0x06054B50) scanning backwards max 64KB + 22
        let minScan = max(0, data.count - 65_557)
        var eocdOffset: Int? = nil
        var pos = data.count - 22
        while pos >= minScan {
            if readU32(data, pos) == 0x06054B50 {
                eocdOffset = pos
                break
            }
            pos -= 1
        }
        guard let eocd = eocdOffset else { throw ZipError.invalidArchive("缺少 EOCD 记录") }

        let totalEntries = Int(readU16(data, eocd + 10))
        let cdSize = Int(readU32(data, eocd + 12))
        let cdOffset = Int(readU32(data, eocd + 16))
        if totalEntries > SecurityValidation.maxZipEntries {
            throw ZipError.securityViolation("条目数超限 (\(totalEntries))")
        }
        guard cdOffset >= 0, cdSize >= 0, cdOffset + cdSize <= eocd else {
            throw ZipError.invalidArchive("中央目录越界")
        }

        // Phase 1: Validate every entry BEFORE writing any file to disk
        var parsed: [CentralEntry] = []
        parsed.reserveCapacity(totalEntries)
        var cursor = cdOffset
        var totalUncompressed: UInt64 = 0

        for _ in 0..<totalEntries {
            guard cursor + 46 <= cdOffset + cdSize, readU32(data, cursor) == 0x02014B50 else {
                throw ZipError.invalidArchive("中央目录头损坏")
            }
            let verMadeBy = readU16(data, cursor + 4)
            let method = readU16(data, cursor + 10)
            let crc = readU32(data, cursor + 16)
            let compSz = UInt64(readU32(data, cursor + 20))
            let uncompSz = UInt64(readU32(data, cursor + 24))
            let nameLen = Int(readU16(data, cursor + 28))
            let extraLen = Int(readU16(data, cursor + 30))
            let commentLen = Int(readU16(data, cursor + 32))
            let extAttr = readU32(data, cursor + 38)
            let localOff = UInt64(readU32(data, cursor + 42))

            let headerEnd = cursor + 46 + nameLen + extraLen + commentLen
            guard headerEnd <= cdOffset + cdSize else { throw ZipError.invalidArchive("条目越界") }
            guard let name = String(data: data[(cursor + 46)..<(cursor + 46 + nameLen)], encoding: .utf8) else {
                throw ZipError.securityViolation("非法 UTF-8 文件名")
            }

            // Block Unix symlinks (mode bits 0o120000) & unsupported methods
            if (verMadeBy >> 8) == 3 {
                let unixMode = (extAttr >> 16) & 0xF000
                if unixMode == 0xA000 {
                    throw ZipError.securityViolation("拒绝包含符号链接的压缩包: \(name)")
                }
            }
            if method != 0 && method != 8 {
                throw ZipError.securityViolation("不支持的 ZIP 压缩方式 \(method): \(name)")
            }

            let isDir = name.hasSuffix("/") || name.hasSuffix("\\")
            guard let segments = SecurityValidation.sanitizeZipRelativeSegments(name, allowDirectory: isDir) else {
                throw ZipError.securityViolation("检测到越界或非法路径: \(name)")
            }

            if uncompSz > 10 * 1024 * 1024, compSz > 0, (uncompSz / compSz) > SecurityValidation.maxZipBombRatio {
                throw ZipError.securityViolation("疑似高压缩比炸弹: \(name)")
            }
            totalUncompressed += uncompSz
            if totalUncompressed > SecurityValidation.maxZipUncompressedBytes {
                throw ZipError.securityViolation("解压总体积超出 4GB 上限")
            }

            if !segments.isEmpty {
                parsed.append(CentralEntry(
                    segments: segments,
                    isDir: isDir,
                    method: method,
                    expectedCrc32: crc,
                    compressedSize: compSz,
                    uncompressedSize: uncompSz,
                    localHeaderOffset: localOff
                ))
            }
            cursor = headerEnd
        }

        // Phase 2: Extract into clean quarantine folder inside destParentDir
        let fm = FileManager.default
        let stagingDir = destParentDir.appendingPathComponent(".unpack_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        let stagingStd = stagingDir.standardizedFileURL.path
        let stagingPrefix = stagingStd.hasSuffix("/") ? stagingStd : stagingStd + "/"
        var actualWrittenTotal: UInt64 = 0

        for entry in parsed {
            var targetURL = stagingDir
            for seg in entry.segments { targetURL.appendPathComponent(seg, isDirectory: false) }
            let resolvedPath = targetURL.standardizedFileURL.path
            guard resolvedPath.hasPrefix(stagingPrefix) else {
                throw ZipError.securityViolation("目标路径越界: \(resolvedPath)")
            }

            if entry.isDir {
                try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
                continue
            }

            try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let lh = Int(entry.localHeaderOffset)
            guard lh + 30 <= data.count, readU32(data, lh) == 0x04034B50 else {
                throw ZipError.invalidArchive("本地文件头损坏")
            }
            let lNameLen = Int(readU16(data, lh + 26))
            let lExtraLen = Int(readU16(data, lh + 28))
            let payloadStart = lh + 30 + lNameLen + lExtraLen
            let payloadEnd = payloadStart + Int(entry.compressedSize)
            guard payloadStart >= 0, payloadEnd <= data.count else {
                throw ZipError.invalidArchive("压缩数据越界")
            }

            let outData: Data
            if entry.method == 0 {
                guard entry.compressedSize == entry.uncompressedSize else {
                    throw ZipError.invalidArchive("STORE 长度不一致")
                }
                outData = data[payloadStart..<payloadEnd]
            } else {
                if entry.uncompressedSize == 0 {
                    outData = Data()
                } else {
                    let cap = Int(entry.uncompressedSize)
                    var decoded = Data(count: cap)
                    let writtenCount = data[payloadStart..<payloadEnd].withUnsafeBytes { srcRaw -> Int in
                        guard let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                        return decoded.withUnsafeMutableBytes { dstRaw -> Int in
                            guard let dstPtr = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                            return compression_decode_buffer(dstPtr, cap, srcPtr, srcRaw.count, nil, COMPRESSION_ZLIB)
                        }
                    }
                    guard writtenCount == cap else {
                        throw ZipError.invalidArchive("DEFLATE 解压长度不匹配 (\(writtenCount) != \(cap))")
                    }
                    outData = decoded
                }
            }

            actualWrittenTotal += UInt64(outData.count)
            if actualWrittenTotal > SecurityValidation.maxZipUncompressedBytes {
                throw ZipError.securityViolation("实际解压体积超限")
            }
            let crcActual = computeCrc32(outData)
            guard crcActual == entry.expectedCrc32 else {
                throw ZipError.invalidArchive("CRC32 校验失败")
            }
            try outData.write(to: targetURL, options: .atomic)
        }

        // Determine final folder inside destParentDir (unique name if collision)
        let candidateTopDirs = try fm.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: nil)
        let singleRoot = candidateTopDirs.count == 1 ? candidateTopDirs[0] : stagingDir
        let safeFolderName = SecurityValidation.isValidSingleFileName(preferredFolderName) ? preferredFolderName : "UnpackedFolder"
        var finalURL = destParentDir.appendingPathComponent(safeFolderName, isDirectory: true)
        if fm.fileExists(atPath: finalURL.path) {
            for i in 1...999 {
                let alt = destParentDir.appendingPathComponent("\(safeFolderName) (\(i))", isDirectory: true)
                if !fm.fileExists(atPath: alt.path) {
                    finalURL = alt
                    break
                }
            }
        }
        if singleRoot == stagingDir {
            try fm.createDirectory(at: finalURL, withIntermediateDirectories: true)
            for item in candidateTopDirs {
                try fm.moveItem(at: item, to: finalURL.appendingPathComponent(item.lastPathComponent))
            }
        } else {
            try fm.moveItem(at: singleRoot, to: finalURL)
        }
        return finalURL
    }
}
