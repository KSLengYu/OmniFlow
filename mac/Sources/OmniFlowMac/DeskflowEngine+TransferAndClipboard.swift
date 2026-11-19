import Foundation
import AppKit
import SwiftUI
import Combine
import CryptoKit
import UniformTypeIdentifiers
import Darwin

@MainActor
extension DeskflowEngine {
    // MARK: - Real File Drop & Interactive Portal Effects (Edge Wall Pass-Through & Mini Cube)

    func estimatedThroughputBytesPerSec() -> Double {
        let links = DeskflowTransport.shared.activeLinksSnapshot()
        let enabledKeys = Set(nicChannels.filter(\.enabledForMultipath).map(\.channelKey))
        let filtered = links.filter { l in
            let key = NicChannelItem.canonicalChannelKey(ifaceName: l.ifaceName, localIp: l.localIp, isUsb: l.isUsbBridge, peerIp: l.peerIp)
            return enabledKeys.contains(key) || enabledKeys.contains(l.localIp)
        }
        let pool = filtered.isEmpty ? links : filtered
        guard !pool.isEmpty else { return 0 }

        func linkBytesPerSec(_ l: PeerLinkSession) -> Double {
            if let measured = l.measuredBytesPerSec, measured > 64 * 1024 { return measured }
            if l.isUsbBridge { return DragHandoffPolicy.fallbackUsbBytesPerSec }
            return l.ifaceName == "en0" ? DragHandoffPolicy.fallbackWifiBytesPerSec : DragHandoffPolicy.fallbackLanBytesPerSec
        }

        if multipathEnabled && pool.count > 1 {
            return pool.reduce(0.0) { $0 + linkBytesPerSec($1) }
        }
        return pool.map(linkBytesPerSec).max() ?? DragHandoffPolicy.fallbackLanBytesPerSec
    }

    func evaluateDragForEdgePrompt(for url: URL) {
        evaluateDragForEdgePrompt(urls: [url])
    }

    func evaluateDragForEdgePrompt(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let links = DeskflowTransport.shared.activeLinksSnapshot()
        let estBps = estimatedThroughputBytesPerSec()
        let targetName = peerHostLabel.isEmpty ? "Windows" : peerHostLabel
        let thresholdSec = DragHandoffPolicy.defaultContinuousMaxSeconds
        let en = isEnglish
        let title = urls.count > 1
            ? (en ? "\(urls[0].lastPathComponent) +\(urls.count - 1) more" : "\(urls[0].lastPathComponent) 等 \(urls.count) 项")
            : urls[0].lastPathComponent

        portalPhase = .hoverExpand(
            fileName: title,
            fileSize: tr(en, "正在计算大小...", "Calculating size..."),
            isLargeFile: true,
            estSec: 0,
            hint: tr(en, "停在传输架上松手开始传输 · 移开取消", "Release on shelf to send · Move away to cancel"),
            canSubmit: !links.isEmpty
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scan = DeskflowEngine.measureUrlsBytesStatic(urls)
            let sizeStr: String
            let estSec: Double
            let hintText: String
            let canSubmit: Bool

            if links.isEmpty || estBps <= 0 {
                sizeStr = scan.totalBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? tr(en, "大小未知", "Unknown size")
                estSec = 0
                hintText = tr(en, "未连上对端设备 · 无法发送（移开取消）", "Peer not connected · Move away to cancel")
                canSubmit = false
            } else if !scan.reliable || scan.totalBytes == nil {
                sizeStr = scan.totalBytes.map { tr(en, "至少 ", "At least ") + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? tr(en, "大小无法读取", "Size unavailable")
                estSec = 0
                hintText = tr(
                    en,
                    "大小无法可靠估算 · 发往 \(targetName) · 松手传到传输架 · 移开取消",
                    "Estimated size unavailable · To \(targetName) · Release to send"
                )
                canSubmit = true
            } else {
                let bytes = scan.totalBytes!
                sizeStr = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                estSec = Double(bytes) / estBps
                let speedMB = estBps / (1024.0 * 1024.0)
                let secLabel = estSec < 1.0
                    ? tr(en, "< 1 秒", "< 1s")
                    : tr(en, "约 \(Int(ceil(estSec))) 秒", "~\(Int(ceil(estSec)))s")
                hintText = en
                    ? String(format: "To %@ · Est. %@ (%.0f MB/s) · Release to send", targetName, secLabel, speedMB)
                    : String(format: "发往 %@ · 预计 %@ (%.0f MB/s) · 松手开始后台传输", targetName, secLabel, speedMB)
                canSubmit = true
                _ = estSec > thresholdSec || bytes > DragHandoffPolicy.maxContinuousSizeBytes
            }

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if case .hoverExpand = self.portalPhase {
                    self.portalPhase = .hoverExpand(
                        fileName: title,
                        fileSize: sizeStr,
                        isLargeFile: true,
                        estSec: estSec,
                        hint: hintText,
                        canSubmit: canSubmit
                    )
                }
            }
        }
    }

    func beginShelfDragOut(paths: [String]) {
        isDraggingOutFromShelf = true
        recentDraggedOutPaths = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        if case .hoverExpand = portalPhase {
            portalPhase = .idle
        }
        PortalOverlayController.shared.setDropHovered(false)
    }

    func endShelfDragOut() {
        isDraggingOutFromShelf = false
        dragOutEndedAt = Date()
    }

    func shouldIgnoreEdgeDrop(urls: [URL]? = nil) -> Bool {
        if isDraggingOutFromShelf { return true }
        let elapsed = Date().timeIntervalSince(dragOutEndedAt)
        if elapsed < DeskflowEngine.dragOutReentryCooldownSeconds { return true }
        if elapsed < 4.0, let urls = urls, !urls.isEmpty, !recentDraggedOutPaths.isEmpty {
            if urls.allSatisfy({ recentDraggedOutPaths.contains($0.standardizedFileURL.path) }) {
                return true
            }
        }
        return false
    }

    func handleDroppedProviders(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty, !shouldIgnoreEdgeDrop() else { return }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                if let validURL = url, validURL.isFileURL {
                    lock.lock()
                    urls.append(validURL)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self, !urls.isEmpty else { return }
            self.startFileTransferFlow(for: urls)
        }
    }

    func startFileTransferFlow(for url: URL) {
        startFileTransferFlow(for: [url])
    }

    func startFileTransferFlow(for urls: [URL], retryItemId: String? = nil) {
        guard !urls.isEmpty else { return }
        if retryItemId == nil {
            if shouldIgnoreEdgeDrop(urls: urls) { return }
            let sig = urls.map { $0.standardizedFileURL.path }.sorted().joined(separator: "|")
            let now = Date()
            if sig == lastDropSignature && now.timeIntervalSince(lastDropSubmittedAt) < 1.5 {
                return
            }
            lastDropSignature = sig
            lastDropSubmittedAt = now
        }
        if !portalOverlayEnabled {
            portalOverlayEnabled = true
        }
        PortalOverlayController.shared.showOrUpdatePanel()

        let taskId = retryItemId ?? UUID().uuidString
        let hasRealPeer = !DeskflowTransport.shared.activeLinksSnapshot().isEmpty
        let enabledIds = Set(nicChannels.filter { $0.online && $0.enabledForMultipath && !$0.manuallyDisconnected }.map(\.id))
        let styleTag = portalEffectStyle.rawValue
        let edgeTag = portalEdgeSide.rawValue
        let offsetVal = portalEdgeOffset
        let isMultiNic = multipathEnabled
        let estMbps = effectiveTransferMbps
        let chanSummary = activeDataChannelSummary
        let en = isEnglish
        let title = urls.count > 1
            ? (en ? "\(urls[0].lastPathComponent) +\(urls.count - 1) more" : "\(urls[0].lastPathComponent) 等 \(urls.count) 项")
            : urls[0].lastPathComponent

        let initialCard = ShelfTransferItem(
            id: taskId,
            direction: .outgoing,
            status: .transferring,
            title: title,
            sizeText: tr(en, "正在统计...", "Calculating..."),
            itemCount: urls.count,
            progress: 0.02,
            speedMbps: estMbps,
            channelTag: chanSummary,
            errorText: nil,
            sourcePaths: urls.map(\.path),
            localPaths: [],
            timestamp: Date()
        )
        shelfItems.removeAll(where: { $0.id == taskId })
        shelfItems.insert(initialCard, at: 0)

        guard hasRealPeer else {
            let warn = tr(en, "尚未连接 Windows 对端，无法发送 \(title)", "Windows peer disconnected; cannot send \(title)")
            updateShelfItem(id: taskId) { item in
                item.status = .failed
                item.errorText = warn
                item.sizeText = tr(en, "未连接", "Offline")
            }
            portalPhase = .idle
            lastTransferSummary = warn
            appendLog("[传文件警告] \(warn)")
            return
        }

        portalPhase = .suckingIn(
            progress: 0.02,
            fileName: title,
            fileSize: tr(en, "准备中...", "Preparing..."),
            speedMbps: estMbps,
            channelTag: chanSummary
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scan = DeskflowEngine.measureUrlsBytesStatic(urls)
            let estBytes = scan.totalBytes ?? 1024 * 1024
            let sizeStr = scan.reliable
                ? ByteCountFormatter.string(fromByteCount: Int64(estBytes), countStyle: .file)
                : tr(en, "计算受限", "Limited")

            var sendURL = urls[0]
            var isBatchBundle = false
            var cleanupDir: URL?
            var cleanupZip: URL?

            if urls.count > 1 {
                let fm = FileManager.default
                let stage = fm.temporaryDirectory.appendingPathComponent("of_batch_\(UUID().uuidString)", isDirectory: true)
                let zipName = SecurityValidation.isValidSingleFileName("\(urls[0].lastPathComponent)等\(urls.count)项.zip")
                    ? "\(urls[0].lastPathComponent)等\(urls.count)项.zip"
                    : "OmniFlow_Batch_\(urls.count)items.zip"
                let zipURL = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString.prefix(6))_\(zipName)")
                do {
                    try fm.createDirectory(at: stage, withIntermediateDirectories: true)
                    for src in urls {
                        let dst = stage.appendingPathComponent(src.lastPathComponent)
                        try? fm.copyItem(at: src, to: dst)
                    }
                    let proc = Process()
                    proc.currentDirectoryURL = stage
                    proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                    proc.arguments = ["-r", "-q", "-0", zipURL.path, "."]
                    proc.standardOutput = Pipe()
                    proc.standardError = Pipe()
                    try proc.run()
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0 && fm.fileExists(atPath: zipURL.path) {
                        sendURL = zipURL
                        isBatchBundle = true
                        cleanupDir = stage
                        cleanupZip = zipURL
                    } else {
                        try? fm.removeItem(at: stage)
                    }
                } catch {
                    try? fm.removeItem(at: stage)
                }
            }

            let finalCleanupDir = cleanupDir
            let finalCleanupZip = cleanupZip
            let (doubled, overflow) = estBytes.multipliedReportingOverflow(by: 2)
            let reqFree = isBatchBundle ? (overflow ? UInt64.max : doubled) : estBytes

            Task { @MainActor [weak self] in
                guard let self = self else {
                    if let d = finalCleanupDir { try? FileManager.default.removeItem(at: d) }
                    if let z = finalCleanupZip { try? FileManager.default.removeItem(at: z) }
                    return
                }
                self.updateShelfItem(id: taskId) { item in
                    item.sizeText = sizeStr
                }
                self.portalPhase = .suckingIn(
                    progress: 0.04,
                    fileName: title,
                    fileSize: sizeStr,
                    speedMbps: estMbps,
                    channelTag: chanSummary
                )

                DeskflowTransport.shared.sendFileReal(
                    sourceURL: sendURL,
                    scheme: "b",
                    style: styleTag,
                    edge: edgeTag,
                    offset: offsetVal,
                    multipath: isMultiNic,
                    enabledLinkIds: enabledIds,
                    batchItemCount: urls.count,
                    isBatchBundle: isBatchBundle,
                    requiredFreeBytes: reqFree,
                    onProgress: { [weak self] p, speedMbps, fname, fsize, chTag in
                        Task { @MainActor [weak self] in
                            self?.updateShelfItem(id: taskId) { item in
                                item.progress = p
                                item.speedMbps = speedMbps
                                item.channelTag = chTag
                                item.sizeText = fsize
                            }
                            self?.portalPhase = .suckingIn(
                                progress: p,
                                fileName: title,
                                fileSize: fsize,
                                speedMbps: speedMbps,
                                channelTag: chTag
                            )
                        }
                    },
                    onFinished: { [weak self] ok, msg in
                        if let d = finalCleanupDir { try? FileManager.default.removeItem(at: d) }
                        if let z = finalCleanupZip { try? FileManager.default.removeItem(at: z) }
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            self.appendLog(ok ? "[传文件] \(msg)" : "[传文件失败] \(msg)")
                            self.lastTransferSummary = msg
                            if ok {
                                self.shelfItems.removeAll(where: { $0.id == taskId })
                                self.portalPhase = .completed(fileName: title, fileSize: sizeStr, savedURL: nil)
                            } else {
                                self.updateShelfItem(id: taskId) { item in
                                    item.status = .failed
                                    item.errorText = msg
                                }
                                self.portalPhase = .idle
                            }
                        }
                    }
                )
            }
        }
    }

    func updateShelfItem(id: String, _ mutate: (inout ShelfTransferItem) -> Void) {
        guard let idx = shelfItems.firstIndex(where: { $0.id == id }) else { return }
        mutate(&shelfItems[idx])
    }

    func retryShelfItem(_ id: String) {
        guard let item = shelfItems.first(where: { $0.id == id && $0.direction == .outgoing }) else { return }
        let urls = item.sourcePaths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        startFileTransferFlow(for: urls, retryItemId: id)
    }

    func removeShelfItem(_ id: String) {
        shelfItems.removeAll(where: { $0.id == id })
    }

    func markShelfItemDeliveredByDrag(_ id: String, operationDesc: String = "拖放投递") {
        guard let item = shelfItems.first(where: { $0.id == id }) else { return }
        shelfItems.removeAll(where: { $0.id == id })
        appendLog("[传输架] 已完成\(operationDesc): \(item.title)")
    }

    func openShelfItem(_ id: String) {
        guard let item = shelfItems.first(where: { $0.id == id }), let u = item.primaryLocalURL else { return }
        NSWorkspace.shared.open(u)
        shelfItems.removeAll(where: { $0.id == id })
        appendLog("[传输架] 已打开文件并从收件架移出: \(item.title)")
    }

    func revealShelfItem(_ id: String) {
        guard let item = shelfItems.first(where: { $0.id == id }) else { return }
        let urls = item.localPaths.map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func resetPortalPhase() {
        portalPhase = .idle
    }

    func openLastReceivedFile() {
        if let firstReady = shelfItems.first(where: { $0.direction == .incoming && $0.status == .ready }),
           let u = firstReady.primaryLocalURL {
            NSWorkspace.shared.activateFileViewerSelecting([u])
        } else if let u = lastReceivedURL {
            NSWorkspace.shared.activateFileViewerSelecting([u])
        } else if let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            NSWorkspace.shared.open(dl)
        }
    }

    nonisolated static func measureUrlsBytesStatic(_ urls: [URL]) -> (totalBytes: UInt64?, count: Int, reliable: Bool) {
        let fm = FileManager.default
        var total: UInt64 = 0
        var count = 0
        var reliable = true

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                reliable = false
                continue
            }
            if !isDir.boolValue {
                if let attrs = try? fm.attributesOfItem(atPath: url.path), let sz = attrs[.size] as? UInt64 {
                    total += sz
                    count += 1
                } else {
                    reliable = false
                }
                continue
            }
            // Directory recursive count
            count += 1
            if let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in
                    reliable = false
                    return true
                }
            ) {
                for case let fileURL as URL in enumerator {
                    if let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]) {
                        if vals.isRegularFile == true {
                            total += UInt64(max(0, vals.fileSize ?? 0))
                        }
                    } else {
                        reliable = false
                    }
                    count += 1
                    if count > DragHandoffPolicy.estimationScanBudgetCount {
                        reliable = false
                        break
                    }
                }
            } else {
                reliable = false
            }
        }
        if !reliable && total == 0 {
            return (nil, max(1, count), false)
        }
        return (total, max(1, count), reliable)
    }

    // MARK: - Clipboard & Cross-OS Semantic Hotkey Translation

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func clipboardFilesSignature(_ urls: [URL]) -> String {
        let fm = FileManager.default
        return urls.map { u in
            let attrs = try? fm.attributesOfItem(atPath: u.path)
            let sz = (attrs?[.size] as? UInt64) ?? 0
            let mod = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(u.path)|\(sz)|\(Int64(mod))"
        }.sorted().joined(separator: ";")
    }

    static func extractPngFromPasteboard(_ pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png), !png.isEmpty {
            return png
        }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        if pb.canReadObject(forClasses: [NSImage.self], options: nil),
           let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let first = imgs.first,
           let tiff = first.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
    }

    func startClipboardAndHotkeyWatchers() {
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.clipboardSyncEnabled else { return }
                let pb = NSPasteboard.general
                guard pb.changeCount != self.lastPasteboardCount else { return }
                self.lastPasteboardCount = pb.changeCount
                if Date() < self.suppressPasteboardUntil { return }
                if DeskflowTransport.shared.activeLinksSnapshot().isEmpty { return }

                // 1. Check copied files / folders FIRST (Finder also attaches file icon + filename string)
                if let fileURLs = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                   !fileURLs.isEmpty {
                    let existing = fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
                    if !existing.isEmpty {
                        let sig = Self.clipboardFilesSignature(existing)
                        if sig != self.lastRemoteClipboardFileSig {
                            self.lastRemoteClipboardFileSig = sig
                            self.broadcastClipboardFilesToPeer(existing)
                        }
                        return
                    }
                }

                // 2. Check copied images / screenshots
                if let pngData = Self.extractPngFromPasteboard(pb), !pngData.isEmpty {
                    let sha = Self.sha256Hex(pngData)
                    if sha == self.lastRemoteClipboardImageSha { return }
                    self.lastRemoteClipboardImageSha = sha
                    if pngData.count <= 14 * 1024 * 1024 {
                        DeskflowTransport.shared.broadcastControlFrame(WireFrameCodec.encode(type: .clipboardImage, payload: pngData))
                        let kb = String(format: "%.0f KB", Double(pngData.count) / 1024.0)
                        self.appendLog("[剪贴板] 已同步图片到 Windows (\(kb))")
                    } else {
                        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardImage_\(Int(Date().timeIntervalSince1970)).png")
                        if (try? pngData.write(to: tmp)) != nil {
                            self.broadcastClipboardFilesToPeer([tmp], cleanupAfterSend: tmp)
                        }
                    }
                    return
                }

                // 3. Fallback to plain text
                let copied = pb.string(forType: .string)
                    ?? pb.string(forType: NSPasteboard.PasteboardType("public.utf8-plain-text"))
                if let copied = copied, !copied.isEmpty, copied != self.lastRemoteClipboardText {
                    self.lastRemoteClipboardText = copied
                    if let data = copied.data(using: .utf8) {
                        DeskflowTransport.shared.broadcastControlFrame(WireFrameCodec.encode(type: .clipboardText, payload: data))
                    }
                    self.appendLog("[剪贴板] 已同步文字到 Windows (\(copied.count) 字符)")
                }
            }
        }

        // Fallback global monitor when Accessibility isn't granted
        fallbackKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                guard let self = self, self.kvmEnabled, self.remoteFocusOnWindows, !MacKvmController.shared.hasAccessibilityPermission else { return }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags.contains([.command, .shift]) && (event.keyCode == 21 || event.keyCode == 23) {
                    self.triggerRemoteWindowsScreenshot(isRegion: event.keyCode == 21)
                }
            }
        }
    }

    func broadcastClipboardFilesToPeer(_ urls: [URL], cleanupAfterSend: URL? = nil) {
        let enabledIds = Set(nicChannels.filter { $0.online && $0.enabledForMultipath }.map(\.id))
        let useMultipath = multipathEnabled
        let countLabel = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) 项文件"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var totalBytes: UInt64 = 0
            for u in urls {
                totalBytes += Self.measurePathBytes(u)
                if totalBytes > 200 * 1024 * 1024 { break }
            }
            if totalBytes > 200 * 1024 * 1024 {
                Task { @MainActor in
                    self?.appendLog("[剪贴板] 复制的文件超过 200 MB，改用直接拖拽传输会更快")
                }
                if let c = cleanupAfterSend { try? FileManager.default.removeItem(at: c) }
                return
            }

            var sendURL = urls[0]
            var isMulti = false
            var tempBundleDir: URL?
            var tempZip: URL?

            if urls.count > 1 {
                let fm = FileManager.default
                let stage = fm.temporaryDirectory.appendingPathComponent("of_clip_\(UUID().uuidString)", isDirectory: true)
                let zipURL = fm.temporaryDirectory.appendingPathComponent("Clipboard_\(urls.count)items.zip")
                do {
                    try fm.createDirectory(at: stage, withIntermediateDirectories: true)
                    for src in urls {
                        let dst = stage.appendingPathComponent(src.lastPathComponent)
                        try? fm.copyItem(at: src, to: dst)
                    }
                    let proc = Process()
                    proc.currentDirectoryURL = stage
                    proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                    proc.arguments = ["-r", "-q", "-0", zipURL.path, "."]
                    proc.standardOutput = Pipe()
                    proc.standardError = Pipe()
                    try proc.run()
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0 && fm.fileExists(atPath: zipURL.path) {
                        sendURL = zipURL
                        isMulti = true
                        tempBundleDir = stage
                        tempZip = zipURL
                    } else {
                        try? fm.removeItem(at: stage)
                    }
                } catch {
                    try? fm.removeItem(at: stage)
                }
            }

            let cleanupBundleDir = tempBundleDir
            let cleanupZip = tempZip

            DeskflowTransport.shared.sendFileReal(
                sourceURL: sendURL,
                scheme: "a",
                style: "blackhole",
                edge: "right",
                offset: 0.5,
                multipath: useMultipath,
                enabledLinkIds: enabledIds,
                isClipboardItem: true,
                isClipboardMulti: isMulti,
                onProgress: { _, _, _, _, _ in },
                onFinished: { [weak self] ok, msg in
                    if let d = cleanupBundleDir { try? FileManager.default.removeItem(at: d) }
                    if let z = cleanupZip { try? FileManager.default.removeItem(at: z) }
                    if let c = cleanupAfterSend { try? FileManager.default.removeItem(at: c) }
                    Task { @MainActor in
                        if ok {
                            self?.appendLog("[剪贴板] 已把复制的「\(countLabel)」同步给 Windows")
                        } else {
                            self?.appendLog("[剪贴板] 同步文件失败: \(msg)")
                        }
                    }
                }
            )
        }
    }

    nonisolated static func measurePathBytes(_ url: URL) -> UInt64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let a = try? fm.attributesOfItem(atPath: url.path)
            return (a?[.size] as? UInt64) ?? 0
        }
        var sum: UInt64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let child as URL in e {
                let vals = try? child.resourceValues(forKeys: [.fileSizeKey])
                sum += UInt64(vals?.fileSize ?? 0)
                if sum > 200 * 1024 * 1024 { return sum }
            }
        }
        return sum
    }

    func triggerRemoteWindowsScreenshot(isRegion: Bool) {
        let ruleId = isRegion ? "shot_region" : "shot_panel"
        guard let rule = hotkeyRules.first(where: { $0.id == ruleId }), rule.enabled else { return }
        if let frame = WireFrameCodec.encodeJSON(type: .semanticHotkey, value: WireSemanticHotkeyPayload(action: rule.actionCode)) {
            DeskflowTransport.shared.sendControlFrame(frame)
        }
        appendLog(
            "[Hotkey] Mac 焦点在 Windows · 捕获 \(rule.macTrigger) -> 已通过低延迟控制通道 (\(activeControlChannelName)) 发送至 Windows 触发「\(rule.winAction)」！"
        )
        lastTransferSummary = "已发送跨系统截图指令：Mac [\(rule.macTrigger)] -> Windows [\(rule.winAction)]"
    }
}
