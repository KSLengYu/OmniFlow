import Foundation

extension DeskflowTransport {
    // MARK: - Real Multi-NIC File Sender & Receiver

    static func sessionMatchesChannelFilter(_ session: PeerLinkSession, filterKeys: Set<String>) -> Bool {
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
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omniflow_send_\(UUID().uuidString).zip")
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
                let finishSync = WirePortalSyncPayload(
                    transferId: transferId,
                    style: style,
                    edge: edge,
                    offset: offset,
                    phase: "done",
                    progress: 1.0,
                    fileName: displayFileName,
                    fileSize: sizeStr,
                    speedMbps: 0,
                    channelTag: channelTag
                )
                if let sf = WireFrameCodec.encodeJSON(type: .portalSync, value: finishSync) {
                    workers[0].sendFrame(sf)
                }
            }
            onFinished(true, displayFileName)
        }
    }

    func handleIncomingFileOffer(_ offer: WireFileOfferPayload, via link: PeerLinkSession) {
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

    func handleIncomingFileChunk(_ payload: Data, via link: PeerLinkSession) {
        guard payload.count >= 40 else { return }
        let tid = String(data: payload.subdata(in: 0..<36), encoding: .utf8)?.trimmingCharacters(in: .whitespaces) ?? ""
        let idx = Int(UInt32(bigEndian: payload.subdata(in: 36..<40).withUnsafeBytes { $0.load(as: UInt32.self) }))
        let chunkData = payload.subdata(in: 40..<payload.count)

        fileLock.lock()
        guard var st = incomingFiles[tid] else {
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

    func handleIncomingFileComplete(_ comp: WireFileCompletePayload, via link: PeerLinkSession) {
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
