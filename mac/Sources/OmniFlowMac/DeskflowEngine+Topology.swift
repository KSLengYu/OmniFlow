import Foundation
import AppKit
import SwiftUI
import Combine
import CryptoKit
import UniformTypeIdentifiers
import Darwin

@MainActor
extension DeskflowEngine {
    // MARK: - Direct Screen-Edge Cube Dragging (1:1 Screen-Locked, Zero Jump)

    func beginCubeScreenDrag() {
        cubeDragStartMouse = NSEvent.mouseLocation
        cubeDragStartOffset = portalEdgeOffset
    }

    func updateCubeScreenDrag() {
        if cubeDragStartMouse == nil {
            beginCubeScreenDrag()
            return
        }
        guard let start = cubeDragStartMouse else { return }
        let cur = NSEvent.mouseLocation
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let idx = min(max(0, portalMonitorIndex), screens.count - 1)
        let frame = screens[idx].visibleFrame
        let panelSz = PortalOverlayController.shared.currentPanelSize

        switch portalEdgeSide {
        case .left, .right:
            let travel = max(80.0, Double(frame.height - panelSz.height))
            let deltaRatio = Double(cur.y - start.y) / travel
            portalEdgeOffset = min(max(0.05, cubeDragStartOffset + deltaRatio), 0.95)
        case .top, .bottom:
            let travel = max(80.0, Double(frame.width - panelSz.width))
            let deltaRatio = Double(cur.x - start.x) / travel
            portalEdgeOffset = min(max(0.05, cubeDragStartOffset + deltaRatio), 0.95)
        }
    }

    func endCubeScreenDrag() {
        cubeDragStartMouse = nil
        savePrefs()
    }

    func adjustCubeOffsetByScreenDelta(_ translation: CGSize) {
        updateCubeScreenDrag()
    }


    // MARK: - Per-Monitor Independent 2D Spatial Topology Discovery & Cross-OS Sync


    func refreshIndependentDisplays() {
        let oldPositions = Dictionary(
            displayNodes.map { ($0.id, CGPoint(x: $0.canvasX, y: $0.canvasY)) },
            uniquingKeysWith: { first, _ in first }
        )
        var nodes: [IndependentDisplayNode] = []
        var usedIds = Set<String>()
        let screens = NSScreen.screens

        // Build Mac display tiles strictly matching macOS System Settings logical bounds & proportions
        var macEntries: [(idx: Int, name: String, w: Int, h: Int, scale: Double, bounds: CGRect)] = []
        for (idx, scr) in screens.enumerated() {
            let w = Int(scr.frame.width * scr.backingScaleFactor)
            let h = Int(scr.frame.height * scr.backingScaleFactor)
            let did = (scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
            let cgRect = CGDisplayBounds(did)
            macEntries.append((idx, scr.localizedName, max(640, w), max(480, h), Double(scr.backingScaleFactor), cgRect))
        }

        let minMacX = macEntries.map { Double($0.bounds.minX) }.min() ?? 0.0
        let minMacY = macEntries.map { Double($0.bounds.minY) }.min() ?? 0.0
        let originX: CGFloat = 100
        let originY: CGFloat = 100
        let layoutScale: Double = 0.068

        for entry in macEntries {
            let id = "mac_disp_\(entry.idx)"
            usedIds.insert(id)
            var node = IndependentDisplayNode(
                id: id,
                displayIndex: entry.idx,
                name: entry.name.isEmpty ? "Mac Display #\(entry.idx + 1)" : entry.name,
                osKind: .mac,
                widthPx: entry.w,
                heightPx: entry.h,
                scaleFactor: entry.scale,
                isPrimary: entry.idx == 0,
                boundsX: Int(entry.bounds.origin.x),
                boundsY: Int(entry.bounds.origin.y),
                canvasX: originX + CGFloat(((Double(entry.bounds.minX) - minMacX) * layoutScale).rounded()),
                canvasY: originY + CGFloat(((Double(entry.bounds.minY) - minMacY) * layoutScale).rounded())
            )

            if let synced = syncedRemotePositions[id] {
                node.canvasX = synced.x
                node.canvasY = synced.y
            } else if let saved = oldPositions[id] {
                node.canvasX = saved.x
                node.canvasY = saved.y
            }
            nodes.append(node)
        }
        MacKvmController.shared.syncInjectorState(kvmEnabled: kvmEnabled, controlMode: kvmControlMode)

        // Only render remote peer displays AFTER peer actually connects & sends real monitor list!
        if !remotePeerMonitors.isEmpty {
            let macMaxRight = nodes.map { $0.canvasX + $0.aspectWidth }.max() ?? (originX + 180)
            let primaryMacY = nodes.first(where: { $0.isPrimary })?.canvasY ?? nodes.first?.canvasY ?? originY
            let minWinX = remotePeerMonitors.map { Double($0.boundsX) }.min() ?? 0.0
            let minWinY = remotePeerMonitors.map { Double($0.boundsY) }.min() ?? 0.0

            for (rmIdx, rm) in remotePeerMonitors.enumerated() {
                var nodeId = rm.id.trimmingCharacters(in: .whitespacesAndNewlines)
                if nodeId.isEmpty {
                    nodeId = "peer_disp_\(max(1, rm.displayIndex))_\(rmIdx)"
                }
                if usedIds.contains(nodeId) {
                    var suffix = 1
                    var candidate = "peer_\(nodeId)"
                    while usedIds.contains(candidate) {
                        suffix += 1
                        candidate = "peer_\(nodeId)_\(suffix)"
                    }
                    nodeId = candidate
                }
                usedIds.insert(nodeId)

                let remoteIsMac = rm.osKind.lowercased().contains("mac") || peerIsMac
                var node = IndependentDisplayNode(
                    id: nodeId,
                    displayIndex: max(0, rm.displayIndex - 1),
                    name: rm.name,
                    osKind: remoteIsMac ? .mac : .windows,
                    isRemote: true,
                    widthPx: rm.widthPx,
                    heightPx: rm.heightPx,
                    scaleFactor: rm.scaleFactor,
                    isPrimary: rm.isPrimary,
                    boundsX: rm.boundsX,
                    boundsY: rm.boundsY,
                    canvasX: macMaxRight + CGFloat(((Double(rm.boundsX) - minWinX) * layoutScale).rounded()),
                    canvasY: primaryMacY + CGFloat(((Double(rm.boundsY) - minWinY) * layoutScale).rounded())
                )
                if let synced = syncedRemotePositions[nodeId] ?? syncedRemotePositions[rm.id] {
                    node.canvasX = synced.x
                    node.canvasY = synced.y
                } else if let saved = oldPositions[nodeId] ?? oldPositions[rm.id] {
                    node.canvasX = saved.x
                    node.canvasY = saved.y
                }
                nodes.append(node)
            }
        }

        let allHaveSavedPos = !nodes.isEmpty && nodes.allSatisfy { savedDisplayPositions[$0.id]?.count == 2 }
        if !allHaveSavedPos {
            resolveDisplayOverlaps(&nodes)
            centerDisplayCluster(&nodes, canvasSize: lastArrangeCanvasSize)
        } else if remotePeerMonitors.isEmpty {
            // Peer not connected yet: center local monitors visually WITHOUT mutating savedDisplayPositions/syncedRemotePositions
            centerDisplayCluster(&nodes, canvasSize: lastArrangeCanvasSize, persistToSynced: false)
        }
        displayNodes = nodes
        if selectedDisplayId == nil || !displayNodes.contains(where: { $0.id == selectedDisplayId }) {
            selectedDisplayId = displayNodes.first?.id
        }
        syncPortalEdgeFromDisplayLayout()
    }

    /// Guarantees no two display tiles overlap on the 2D canvas.
    func resolveDisplayOverlaps(_ nodes: inout [IndependentDisplayNode], anchoredId: String? = nil) {
        guard nodes.count > 1 else { return }
        for _ in 0..<6 {
            var changed = false
            for i in nodes.indices {
                for j in nodes.indices where i != j {
                    if nodes[j].id == anchoredId { continue }
                    let rA = nodes[i].rect.insetBy(dx: 2, dy: 2)
                    let rB = nodes[j].rect.insetBy(dx: 2, dy: 2)
                    if rA.intersects(rB) {
                        let a = nodes[i].rect
                        let b = nodes[j].rect
                        let pushRight = a.maxX - b.minX
                        let pushLeft  = b.maxX - a.minX
                        let pushDown  = a.maxY - b.minY
                        let pushUp    = b.maxY - a.minY
                        let minPush = min(min(pushRight, pushLeft), min(pushDown, pushUp))
                        if minPush == pushRight {
                            nodes[j].canvasX = a.maxX
                        } else if minPush == pushLeft {
                            nodes[j].canvasX = a.minX - b.width
                        } else if minPush == pushDown {
                            nodes[j].canvasY = a.maxY
                        } else {
                            nodes[j].canvasY = a.minY - b.height
                        }
                        changed = true
                    }
                }
            }
            if !changed { break }
        }
    }

    /// Centers the entire multi-monitor cluster inside the Arrange Displays canvas while preserving exact relative arrangement.
    func centerDisplayCluster(_ nodes: inout [IndependentDisplayNode], canvasSize: CGSize, persistToSynced: Bool = true) {
        guard !nodes.isEmpty else { return }
        let cw = max(560, canvasSize.width)
        let ch = max(320, canvasSize.height)
        let minX = nodes.map(\.canvasX).min() ?? 0
        let maxX = nodes.map { $0.canvasX + $0.aspectWidth }.max() ?? cw
        let minY = nodes.map(\.canvasY).min() ?? 0
        let maxY = nodes.map { $0.canvasY + $0.aspectHeight }.max() ?? ch

        let clusterMidX = (minX + maxX) * 0.5
        let clusterMidY = (minY + maxY) * 0.5
        let dx = (cw * 0.5) - clusterMidX
        let dy = (ch * 0.5) - clusterMidY

        for i in nodes.indices {
            nodes[i].canvasX = round(nodes[i].canvasX + dx)
            nodes[i].canvasY = round(nodes[i].canvasY + dy)
            if persistToSynced {
                syncedRemotePositions[nodes[i].id] = CGPoint(x: nodes[i].canvasX, y: nodes[i].canvasY)
            }
        }
    }

    func centerCurrentDisplaysNow(canvasSize: CGSize? = nil) {
        if let sz = canvasSize { lastArrangeCanvasSize = sz }
        var nodes = displayNodes
        let allHaveSavedPos = !nodes.isEmpty && nodes.allSatisfy { savedDisplayPositions[$0.id]?.count == 2 }
        if !allHaveSavedPos {
            resolveDisplayOverlaps(&nodes)
            centerDisplayCluster(&nodes, canvasSize: lastArrangeCanvasSize)
            displayNodes = nodes
        } else if remotePeerMonitors.isEmpty {
            // Peer not connected yet: center local monitors visually WITHOUT overwriting savedDisplayPositions
            centerDisplayCluster(&nodes, canvasSize: lastArrangeCanvasSize, persistToSynced: false)
            displayNodes = nodes
        }
        syncPortalEdgeFromDisplayLayout()
    }

    func finishDisplayDrag(id: String, canvasSize: CGSize) {
        lastArrangeCanvasSize = canvasSize
        var nodes = displayNodes
        // Apply fine magnetic alignment (<= 7px) ONLY when releasing the drag, so dragging itself is 1:1 silky smooth
        if let idx = nodes.firstIndex(where: { $0.id == id }) {
            let w = nodes[idx].aspectWidth
            let h = nodes[idx].aspectHeight
            var tx = nodes[idx].canvasX
            var ty = nodes[idx].canvasY
            let snapThreshold: CGFloat = 7.0
            for (otherIdx, other) in nodes.enumerated() where otherIdx != idx {
                let ox = other.canvasX
                let oy = other.canvasY
                let ow = other.aspectWidth
                let oh = other.aspectHeight
                if abs((tx + w) - ox) < snapThreshold { tx = ox - w }
                else if abs(tx - (ox + ow)) < snapThreshold { tx = ox + ow }
                else if abs(tx - ox) < snapThreshold { tx = ox }
                else if abs((tx + w) - (ox + ow)) < snapThreshold { tx = ox + ow - w }

                if abs((ty + h) - oy) < snapThreshold { ty = oy - h }
                else if abs(ty - (oy + oh)) < snapThreshold { ty = oy + oh }
                else if abs(ty - oy) < snapThreshold { ty = oy }
                else if abs((ty + h) - (oy + oh)) < snapThreshold { ty = oy + oh - h }
            }
            nodes[idx].canvasX = tx
            nodes[idx].canvasY = ty
            syncedRemotePositions[id] = CGPoint(x: tx, y: ty)
        }
        resolveDisplayOverlaps(&nodes, anchoredId: id)
        centerDisplayCluster(&nodes, canvasSize: canvasSize)
        displayNodes = nodes
        syncPortalEdgeFromDisplayLayout()
        saveDisplayArrangement(silent: true)
        scheduleTopologySyncBroadcast()
    }

    /// Automatically moves the file-transfer edge portal to the Mac monitor & edge facing the Windows display(s).
    func syncPortalEdgeFromDisplayLayout() {
        let macNodes = displayNodes.filter { !$0.isRemote }
        let winNodes = displayNodes.filter { $0.isRemote }
        guard !macNodes.isEmpty, !winNodes.isEmpty else { return }

        var bestMac = macNodes[0]
        var bestWin = winNodes[0]
        var bestDist = CGFloat.greatestFiniteMagnitude

        for m in macNodes {
            for w in winNodes {
                let d = hypot(w.rect.midX - m.rect.midX, w.rect.midY - m.rect.midY)
                if d < bestDist {
                    bestDist = d
                    bestMac = m
                    bestWin = w
                }
            }
        }

        let dx = bestWin.rect.midX - bestMac.rect.midX
        let dy = bestWin.rect.midY - bestMac.rect.midY
        let targetEdge: ScreenEdgeSide
        if abs(dx) >= abs(dy) {
            targetEdge = dx >= 0 ? .right : .left
        } else {
            targetEdge = dy >= 0 ? .bottom : .top
        }

        if portalMonitorIndex != bestMac.displayIndex {
            portalMonitorIndex = bestMac.displayIndex
        }
        if portalEdgeSide != targetEdge {
            portalEdgeSide = targetEdge
        }
        PortalOverlayController.shared.repositionPanel()
    }

    func resetDisplayArrangement2D() {
        syncedRemotePositions.removeAll()
        savedDisplayPositions.removeAll()
        displayNodes.removeAll()
        UserDefaults.standard.removeObject(forKey: "mb_df_saved_display_positions")
        refreshIndependentDisplays()
        saveDisplayArrangement(silent: true)
        scheduleTopologySyncBroadcast()
    }

    /// Updates a display's 2D spatial position continuously 1:1 during drag without steppy mid-drag snapping.
    func updateDisplayNodePosition(id: String, x: CGFloat, y: CGFloat, canvasSize: CGSize = CGSize(width: 680, height: 350)) {
        lastArrangeCanvasSize = canvasSize
        guard let idx = displayNodes.firstIndex(where: { $0.id == id }) else { return }
        let w = displayNodes[idx].aspectWidth
        let h = displayNodes[idx].aspectHeight

        let targetX = min(max(12, x), max(20, canvasSize.width - w - 12))
        let targetY = min(max(12, y), max(20, canvasSize.height - h - 12))

        displayNodes[idx].canvasX = targetX
        displayNodes[idx].canvasY = targetY
        syncedRemotePositions[id] = CGPoint(x: targetX, y: targetY)
    }

    func scheduleTopologySyncBroadcast() {
        topologySyncWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.sendTopologySyncNow()
            }
        }
        topologySyncWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    func sendTopologySyncNow() {
        let entries = displayNodes.map {
            WireMonitorLayoutEntry(
                id: $0.id,
                canvasX: Double($0.canvasX),
                canvasY: Double($0.canvasY),
                displayIndex: $0.displayIndex + 1,
                name: $0.name,
                osKind: $0.osKind.rawValue,
                widthPx: $0.widthPx,
                heightPx: $0.heightPx,
                scaleFactor: $0.scaleFactor,
                isPrimary: $0.isPrimary
            )
        }
        guard !entries.isEmpty,
              let frame = WireFrameCodec.encodeJSON(
                type: .topologyUpdate,
                value: WireTopologySyncPayload(
                    senderOs: "macOS",
                    timestamp: Date().timeIntervalSince1970,
                    items: entries
                )
              ) else { return }
        DeskflowTransport.shared.sendControlFrame(frame)
    }

    func applyRemoteTopologySync(_ payload: WireTopologySyncPayload) {
        var addedRemote = false
        for entry in payload.items {
            // When two Macs sync topology, map sender's local `mac_disp_*` to our remote `peer_mac_disp_*`
            let resolvedId: String
            if payload.senderOs == "macOS" {
                if entry.id.hasPrefix("peer_") {
                    let stripped = String(entry.id.dropFirst(5))
                    resolvedId = displayNodes.contains(where: { $0.id == stripped && !$0.isRemote }) ? stripped : entry.id
                } else {
                    resolvedId = displayNodes.contains(where: { $0.id == "peer_\(entry.id)" }) ? "peer_\(entry.id)" : entry.id
                }
            } else {
                resolvedId = entry.id
            }

            let pt = CGPoint(x: entry.canvasX, y: entry.canvasY)
            syncedRemotePositions[resolvedId] = pt
            if let idx = displayNodes.firstIndex(where: { $0.id == resolvedId }) {
                displayNodes[idx].canvasX = pt.x
                displayNodes[idx].canvasY = pt.y
            } else if entry.osKind == "Windows" || (payload.senderOs == "macOS" && entry.osKind == "macOS"),
                      let name = entry.name,
                      let w = entry.widthPx,
                      let h = entry.heightPx {
                let dIdx = max(1, entry.displayIndex ?? 1)
                if !remotePeerMonitors.contains(where: { $0.id == entry.id || $0.id == resolvedId }) {
                    remotePeerMonitors.append(
                        WireMonitorDto(
                            id: entry.id,
                            displayIndex: dIdx,
                            name: name,
                            osKind: entry.osKind ?? payload.senderOs,
                            widthPx: w,
                            heightPx: h,
                            scaleFactor: entry.scaleFactor ?? 1.0,
                            isPrimary: entry.isPrimary ?? (dIdx == 1),
                            boundsX: 0,
                            boundsY: 0
                        )
                    )
                    addedRemote = true
                }
            }
        }
        if addedRemote {
            refreshIndependentDisplays()
        } else {
            var nodes = displayNodes
            resolveDisplayOverlaps(&nodes)
            displayNodes = nodes
            syncPortalEdgeFromDisplayLayout()
        }
        if payload.items.count > 1 && payload.items.count >= displayNodes.count {
            saveDisplayArrangement(silent: true)
        }
        appendLog("[Topology] 已实时同步来自 \(payload.senderOs) 的屏幕空间布局 (\(payload.items.count) 块)")
    }

    func moveDisplay(from src: Int, to dst: Int) {
        guard displayNodes.indices.contains(src), displayNodes.indices.contains(dst), src != dst else { return }
        let item = displayNodes.remove(at: src)
        displayNodes.insert(item, at: dst)
    }

}
