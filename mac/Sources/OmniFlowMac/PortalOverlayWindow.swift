import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Screen-Edge Floating Overlay & Persistent Transfer Shelf Controller

@MainActor
final class PortalOverlayController: NSObject {
    static let shared = PortalOverlayController()

    private var panel: NSPanel?
    private weak var engine: DeskflowEngine?
    private var isDropHovered: Bool = false
    private var autoHideWorkItem: DispatchWorkItem?
    var currentPanelSize: NSSize { panel?.frame.size ?? NSSize(width: 136, height: 112) }

    func bind(engine: DeskflowEngine) {
        self.engine = engine
        updateVisibility()
    }

    func setDropHovered(_ hovered: Bool) {
        guard isDropHovered != hovered else { return }
        isDropHovered = hovered
        repositionPanel()
    }

    func updateVisibility() {
        guard let engine = engine else { return }
        if engine.portalOverlayEnabled || !engine.shelfItems.isEmpty {
            showOrUpdatePanel()
        } else {
            panel?.orderOut(nil)
        }
    }

    func closeForExit() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    func showOrUpdatePanel() {
        guard let engine = engine else { return }
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 16, height: 340),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.appearance = NSAppearance(named: .darkAqua)
            p.hasShadow = false
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.isMovableByWindowBackground = false
            p.contentViewController = NSHostingController(rootView: PortalOverlayRootView(engine: engine))
            self.panel = p
        }

        if case .completed = engine.portalPhase {
            scheduleTransientPhaseReset()
        } else {
            autoHideWorkItem?.cancel()
        }

        repositionPanel()
        panel?.orderFrontRegardless()
    }

    private func scheduleTransientPhaseReset() {
        autoHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self = self, let engine = self.engine else { return }
                if case .completed = engine.portalPhase {
                    engine.portalPhase = .idle
                    self.repositionPanel()
                }
            }
        }
        autoHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    func repositionPanel() {
        guard let engine = engine, let panel = panel else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let idx = min(max(0, engine.portalMonitorIndex), screens.count - 1)
        let screenFrame = screens[idx].visibleFrame

        let hasPersistentCards = !engine.shelfItems.isEmpty
        let isHoverOrTransferring: Bool
        if case .idle = engine.portalPhase {
            isHoverOrTransferring = isDropHovered
        } else {
            isHoverOrTransferring = true
        }
        let isExpanded = isHoverOrTransferring || hasPersistentCards

        let size: NSSize
        if engine.portalEffectStyle == .blackHole {
            if !isExpanded {
                switch engine.portalEdgeSide {
                case .left, .right:
                    size = NSSize(width: 16, height: min(560, screenFrame.height * 0.72))
                case .top, .bottom:
                    size = NSSize(width: min(680, screenFrame.width * 0.72), height: 16)
                }
            } else if hasPersistentCards {
                let cardRows = CGFloat(min(4, engine.shelfItems.count))
                let extraHover: CGFloat = isDropHovered ? 92 : 0
                let h = min(440, max(168, 48 + cardRows * 86 + extraHover))
                size = NSSize(width: 318, height: h)
            } else {
                switch engine.portalEdgeSide {
                case .left, .right:
                    size = NSSize(width: 316, height: 220)
                case .top, .bottom:
                    size = NSSize(width: 350, height: 210)
                }
            }
        } else {
            if hasPersistentCards {
                let cardRows = CGFloat(min(4, engine.shelfItems.count))
                size = NSSize(width: 280, height: min(400, max(190, 90 + cardRows * 78)))
            } else {
                size = isExpanded ? NSSize(width: 256, height: 192) : NSSize(width: 136, height: 112)
            }
        }

        let ratio = CGFloat(min(max(engine.portalEdgeOffset, 0.05), 0.95))
        var origin = NSPoint.zero

        switch engine.portalEdgeSide {
        case .right:
            origin.x = screenFrame.maxX - size.width
            origin.y = screenFrame.minY + (screenFrame.height - size.height) * ratio
        case .left:
            origin.x = screenFrame.minX
            origin.y = screenFrame.minY + (screenFrame.height - size.height) * ratio
        case .top:
            origin.x = screenFrame.minX + (screenFrame.width - size.width) * ratio
            origin.y = screenFrame.maxY - size.height
        case .bottom:
            origin.x = screenFrame.minX + (screenFrame.width - size.width) * ratio
            origin.y = screenFrame.minY
        }

        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }
}

// MARK: - Root Overlay SwiftUI View

struct PortalOverlayRootView: View {
    @ObservedObject var engine: DeskflowEngine
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            if !engine.shelfItems.isEmpty {
                VStack(spacing: 8) {
                    if isDropTargeted,
                       case .hoverExpand(let fn, let fsz, let isLarge, let estSec, let hint, let canSubmit) = engine.portalPhase {
                        HoverDropShelfBanner(fileName: fn, fileSize: fsz, isLargeFile: isLarge, estSec: estSec, hint: hint, canSubmit: canSubmit, edge: engine.portalEdgeSide, isEnglish: engine.isEnglish)
                            .modifier(EdgeExtrudeReveal(edge: engine.portalEdgeSide))
                    }
                    PersistentEdgeShelfView(engine: engine)
                        .modifier(EdgeExtrudeReveal(edge: engine.portalEdgeSide))
                }
                .padding(8)
            } else if engine.portalEffectStyle == .blackHole {
                GenieEdgePortalView(
                    phase: engine.portalPhase,
                    isDropTargeted: isDropTargeted,
                    edge: engine.portalEdgeSide,
                    isEnglish: engine.isEnglish,
                    onOpenReceived: { engine.openLastReceivedFile() },
                    onDismissCompleted: {
                        engine.resetPortalPhase()
                        PortalOverlayController.shared.repositionPanel()
                    }
                )
            } else {
                FloatingCubePortalView(
                    phase: engine.portalPhase,
                    isDropTargeted: isDropTargeted,
                    edge: engine.portalEdgeSide,
                    isEnglish: engine.isEnglish,
                    onDragBegin: { engine.beginCubeScreenDrag() },
                    onDragMoved: { _ in
                        engine.updateCubeScreenDrag()
                        PortalOverlayController.shared.repositionPanel()
                    },
                    onDragEnded: { engine.endCubeScreenDrag() },
                    onOpenReceived: { engine.openLastReceivedFile() },
                    onDismissCompleted: { engine.resetPortalPhase() }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.001))
        .preferredColorScheme(.dark)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            if engine.shouldIgnoreEdgeDrop() {
                PortalOverlayController.shared.setDropHovered(false)
                return false
            }
            PortalOverlayController.shared.setDropHovered(false)
            engine.handleDroppedProviders(providers)
            return true
        }
        .onChange(of: isDropTargeted) { _, newVal in
            if newVal && engine.shouldIgnoreEdgeDrop() {
                isDropTargeted = false
                PortalOverlayController.shared.setDropHovered(false)
                return
            }
            PortalOverlayController.shared.setDropHovered(newVal)
        }
        .onChange(of: engine.portalPhase) {
            PortalOverlayController.shared.showOrUpdatePanel()
        }
        .onChange(of: engine.shelfItems) {
            PortalOverlayController.shared.updateVisibility()
            PortalOverlayController.shared.repositionPanel()
        }
        .onChange(of: engine.portalEdgeSide) {
            PortalOverlayController.shared.repositionPanel()
        }
        .onChange(of: engine.portalEdgeOffset) {
            PortalOverlayController.shared.repositionPanel()
        }
        .onChange(of: engine.portalEffectStyle) {
            PortalOverlayController.shared.repositionPanel()
        }
        .onChange(of: engine.portalOverlayEnabled) {
            PortalOverlayController.shared.updateVisibility()
        }
        .onChange(of: engine.portalMonitorIndex) {
            PortalOverlayController.shared.repositionPanel()
        }
    }
}

// MARK: - Persistent Edge Shelf Cards (Supports Native Drag-Out, Open, Reveal, Retry, Remove)

struct HoverDropShelfBanner: View {
    let fileName: String?
    let fileSize: String?
    let isLargeFile: Bool
    let estSec: Double
    let hint: String?
    let canSubmit: Bool
    let edge: ScreenEdgeSide
    let isEnglish: Bool

    var body: some View {
        let accent: Color = !canSubmit
            ? Color(red: 1.0, green: 0.40, blue: 0.35)
            : (isLargeFile ? Color(red: 1.0, green: 0.62, blue: 0.04) : Color(red: 0.04, green: 0.52, blue: 1.0))

        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.20))
                    .frame(width: 32, height: 32)
                Image(systemName: !canSubmit ? "wifi.slash" : "tray.and.arrow.down.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName ?? tr(isEnglish, "松手放到传输架", "Drop onto Shelf"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if let fsz = fileSize, !fsz.isEmpty {
                    Text("\(fsz) · \(hint ?? tr(isEnglish, "松手开始传输 · 移开取消", "Release to send · Move away to cancel"))")
                        .font(.system(size: 10.5))
                        .foregroundColor(canSubmit ? Color(red: 1.0, green: 0.82, blue: 0.45) : Color(red: 1.0, green: 0.60, blue: 0.55))
                        .lineLimit(2)
                } else {
                    Text(hint ?? tr(isEnglish, "松手开始传输 · 移开取消", "Release to send · Move away to cancel"))
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(white: 0.78))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(red: 0.11, green: 0.12, blue: 0.15).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(accent.opacity(0.70), lineWidth: 1.2))
        .shadow(color: .black.opacity(0.38), radius: 12, y: 4)
    }
}

struct PersistentEdgeShelfView: View {
    @ObservedObject var engine: DeskflowEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(engine.t("跨屏传输架 (\(engine.shelfItems.count))", "Transfer Shelf (\(engine.shelfItems.count))"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Color(white: 0.85))
                Spacer()
                Text(engine.t("拖出到文件夹 · 或点击打开", "Drag to folder · or click Open"))
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.55))
            }
            .padding(.horizontal, 4)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 7) {
                    ForEach(engine.shelfItems) { item in
                        ShelfCardItemView(item: item, engine: engine)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(red: 0.11, green: 0.12, blue: 0.14).opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.42), radius: 14, y: 5)
    }
}

struct ShelfCardItemView: View {
    let item: ShelfTransferItem
    @ObservedObject var engine: DeskflowEngine

    var body: some View {
        let accent: Color = switch item.status {
        case .transferring: Color(red: 0.04, green: 0.52, blue: 1.0)
        case .ready: Color(red: 0.19, green: 0.82, blue: 0.35)
        case .failed: Color(red: 1.0, green: 0.35, blue: 0.32)
        }

        VStack(alignment: .leading, spacing: 6) {
            // Draggable top card region (supports native AppKit NSDraggingSession when ready)
            ZStack {
                HStack(spacing: 8) {
                    Image(systemName: item.status == .failed ? "exclamationmark.triangle.fill" : (item.status == .ready ? "doc.on.doc.fill" : "arrow.up.circle.fill"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(subtitleText)
                            .font(.system(size: 10.5))
                            .foregroundColor(item.status == .failed ? Color(red: 1.0, green: 0.65, blue: 0.60) : Color(white: 0.68))
                            .lineLimit(1)
                    }
                    Spacer()
                }
                if item.direction == .incoming && item.status == .ready && !item.localPaths.isEmpty {
                    ShelfNativeDragHandle(
                        paths: item.localPaths,
                        onDragBegin: { engine.beginShelfDragOut(paths: item.localPaths) },
                        onDragEnded: { engine.endShelfDragOut() },
                        onDelivered: { engine.markShelfItemDeliveredByDrag(item.id) }
                    )
                }
            }

            if item.status == .transferring {
                ProgressView(value: min(max(item.progress, 0.02), 1.0))
                    .progressViewStyle(.linear)
            } else {
                HStack(spacing: 6) {
                    if item.direction == .incoming && item.status == .ready {
                        Text(engine.t("按住上面卡片可直接拖走", "Hold card above to drag out"))
                            .font(.system(size: 10))
                            .foregroundColor(Color(red: 0.50, green: 0.84, blue: 1.0))
                        Spacer()
                        Button(engine.t("打开", "Open")) { engine.openShelfItem(item.id) }
                            .buttonStyle(PillButtonStyle())
                        Button(engine.t("定位", "Reveal")) { engine.revealShelfItem(item.id) }
                            .buttonStyle(PillButtonStyle())
                    } else if item.status == .failed && item.direction == .outgoing {
                        Spacer()
                        Button(engine.t("重试", "Retry")) { engine.retryShelfItem(item.id) }
                            .buttonStyle(PillButtonStyle())
                    } else {
                        Spacer()
                    }
                    Button(engine.t("移除", "Remove")) { engine.removeShelfItem(item.id) }
                        .buttonStyle(PillButtonStyle())
                }
            }
        }
        .padding(9)
        .background(Color(white: 0.16).opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(accent.opacity(0.45), lineWidth: 1))
    }

    private var subtitleText: String {
        switch item.status {
        case .transferring:
            let pct = Int(item.progress * 100)
            let mbs = item.speedMbps / 8.0
            return "\(item.sizeText) · \(pct)% · \(String(format: "%.0f MB/s", mbs))"
        case .ready:
            return engine.t("\(item.sizeText) · 已通过校验 · 就绪可拖出", "\(item.sizeText) · Verified · Ready to drag")
        case .failed:
            return item.errorText ?? engine.t("传输失败", "Transfer failed")
        }
    }
}

/// Transparent AppKit NSDraggingSource overlay enabling genuine macOS Finder / Desktop / App drag-out from a shelf card.
struct ShelfNativeDragHandle: NSViewRepresentable {
    let paths: [String]
    let onDragBegin: () -> Void
    let onDragEnded: () -> Void
    let onDelivered: () -> Void

    func makeNSView(context: Context) -> ShelfDragSourceNSView {
        let v = ShelfDragSourceNSView()
        v.paths = paths
        v.onDragBegin = onDragBegin
        v.onDragEnded = onDragEnded
        v.onDelivered = onDelivered
        return v
    }

    func updateNSView(_ nsView: ShelfDragSourceNSView, context: Context) {
        nsView.paths = paths
        nsView.onDragBegin = onDragBegin
        nsView.onDragEnded = onDragEnded
        nsView.onDelivered = onDelivered
    }
}

final class ShelfDragSourceNSView: NSView, NSDraggingSource {
    var paths: [String] = []
    var onDragBegin: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onDelivered: (() -> Void)?
    private var mouseDownPoint: NSPoint?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !paths.isEmpty else { return }
        let cur = convert(event.locationInWindow, from: nil)
        if hypot(cur.x - start.x, cur.y - start.y) < 4 { return }
        mouseDownPoint = nil

        let urls = paths.compactMap { p -> NSURL? in
            guard FileManager.default.fileExists(atPath: p) else { return nil }
            return URL(fileURLWithPath: p) as NSURL
        }
        guard !urls.isEmpty else { return }

        MainActor.assumeIsolated {
            onDragBegin?()
        }

        let items: [NSDraggingItem] = urls.enumerated().map { idx, nsUrl in
            let item = NSDraggingItem(pasteboardWriter: nsUrl)
            let icon = NSWorkspace.shared.icon(forFile: (nsUrl as URL).path)
            icon.size = NSSize(width: 36, height: 36)
            let frame = NSRect(x: cur.x - 18 + CGFloat(idx * 4), y: cur.y - 18 - CGFloat(idx * 4), width: 36, height: 36)
            item.setDraggingFrame(frame, contents: icon)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Task { @MainActor [onDragEnded, onDelivered] in
            onDragEnded?()
            if operation != [] {
                onDelivered?()
            }
        }
    }
}

// MARK: - 1. Invisible Screen-Edge Portal Hover & Transfer Indicator

struct EdgeExtrudeReveal: ViewModifier {
    let edge: ScreenEdgeSide
    @State private var appeared = false

    private var anchor: UnitPoint {
        switch edge {
        case .left: return .leading
        case .right: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        }
    }

    private var startOffsetX: CGFloat {
        switch edge {
        case .left: return -28
        case .right: return 28
        default: return 0
        }
    }

    private var startOffsetY: CGFloat {
        switch edge {
        case .top: return -24
        case .bottom: return 24
        default: return 0
        }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(
                x: appeared ? 1.0 : ((edge == .left || edge == .right) ? 0.72 : 1.0),
                y: appeared ? 1.0 : ((edge == .top || edge == .bottom) ? 0.72 : 1.0),
                anchor: anchor
            )
            .offset(x: appeared ? 0 : startOffsetX, y: appeared ? 0 : startOffsetY)
            .opacity(appeared ? 1.0 : 0.0)
            .onAppear {
                appeared = false
                withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                    appeared = true
                }
            }
    }
}

struct GenieEdgePortalView: View {
    let phase: PortalPhase
    let isDropTargeted: Bool
    let edge: ScreenEdgeSide
    let isEnglish: Bool
    let onOpenReceived: () -> Void
    let onDismissCompleted: () -> Void

    @State private var smoothProgress: Double = 0.0

    private var targetProgress: Double {
        switch phase {
        case .idle, .hoverExpand: return 0.0
        case .suckingIn(let p, _, _, _, _): return min(max(p, 0.02), 1.0)
        case .emergingOut(let p, _, _, _, _): return min(max(p, 0.02), 1.0)
        case .completed: return 1.0
        }
    }

    var body: some View {
        ZStack {
            switch phase {
            case .idle:
                if isDropTargeted {
                    HoverDropShelfBanner(fileName: nil, fileSize: nil, isLargeFile: true, estSec: 0, hint: tr(isEnglish, "松手放到传输架 · 移开取消", "Drop onto Shelf · Move away to cancel"), canSubmit: true, edge: edge, isEnglish: isEnglish)
                        .padding(8)
                        .modifier(EdgeExtrudeReveal(edge: edge))
                } else {
                    Color.clear
                }

            case .hoverExpand(let fn, let fsz, let isLarge, let estSec, let hint, let canSubmit):
                HoverDropShelfBanner(fileName: fn, fileSize: fsz, isLargeFile: isLarge, estSec: estSec, hint: hint, canSubmit: canSubmit, edge: edge, isEnglish: isEnglish)
                    .padding(8)
                    .modifier(EdgeExtrudeReveal(edge: edge))

            case .suckingIn(_, let fileName, let fileSize, let speedMbps, let channelTag):
                genieCanvasView(progress: smoothProgress, isSending: true, fileName: fileName, fileSize: fileSize, speedMbps: speedMbps, channelTag: channelTag)
                    .modifier(EdgeExtrudeReveal(edge: edge))

            case .emergingOut(_, let fileName, let fileSize, let speedMbps, let channelTag):
                genieCanvasView(progress: smoothProgress, isSending: false, fileName: fileName, fileSize: fileSize, speedMbps: speedMbps, channelTag: channelTag)
                    .modifier(EdgeExtrudeReveal(edge: edge))

            case .completed(let fileName, let fileSize, _):
                completedCard(fileName: fileName, fileSize: fileSize)
                    .modifier(EdgeExtrudeReveal(edge: edge))
            }
        }
        .task(id: targetProgress) {
            if case .idle = phase {
                smoothProgress = 0.0
                return
            }
            while abs(smoothProgress - targetProgress) > 0.003 {
                smoothProgress += (targetProgress - smoothProgress) * 0.28
                if abs(smoothProgress - targetProgress) <= 0.003 {
                    smoothProgress = targetProgress
                    break
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            smoothProgress = targetProgress
        }
        .animation(.easeOut(duration: 0.16), value: isDropTargeted)
    }

    private func genieCanvasView(progress: Double, isSending: Bool, fileName: String, fileSize: String, speedMbps: Double, channelTag: String) -> some View {
        let p = min(max(progress, 0.0), 1.0)
        let accent = isSending ? Color(red: 0.04, green: 0.52, blue: 1.0) : Color(red: 0.19, green: 0.82, blue: 0.35)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(accent).frame(width: 8, height: 8)
                Text(isSending ? tr(isEnglish, "正在传给对端 · \(fileName)", "Sending · \(fileName)") : tr(isEnglish, "正在接收 · \(fileName)", "Receiving · \(fileName)"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            ProgressView(value: p)
                .progressViewStyle(.linear)
            Text("\(Int(p * 100))% · \(fileSize) · \(String(format: "%.0f MB/s", speedMbps / 8.0)) · \(channelTag)")
                .font(.system(size: 10.5))
                .foregroundColor(Color(white: 0.78))
                .lineLimit(1)
        }
        .padding(12)
        .background(Color(red: 0.09, green: 0.11, blue: 0.14).opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(accent.opacity(0.65), lineWidth: 1.1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        .padding(8)
    }

    private func completedCard(fileName: String, fileSize: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color(red: 0.19, green: 0.85, blue: 0.39))

            VStack(alignment: .leading, spacing: 1) {
                Text(tr(isEnglish, "已验证送达 · \(fileName)", "Delivered · \(fileName)"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(tr(isEnglish, "\(fileSize) · SHA-256 校验通过", "\(fileSize) · SHA-256 Verified"))
                    .font(.system(size: 10))
                    .foregroundColor(Color(red: 0.72, green: 0.96, blue: 0.79))
                    .lineLimit(1)
            }

            Button("×") { onDismissCompleted() }
                .buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(Color(red: 0.08, green: 0.22, blue: 0.13).opacity(0.95))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color(red: 0.22, green: 0.84, blue: 0.42).opacity(0.70), lineWidth: 1.1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
        .padding(8)
    }
}

// MARK: - 2. Screen-Edge Mini Drop Cube (Draggable Along Screen Edge)

struct FloatingCubePortalView: View {
    let phase: PortalPhase
    let isDropTargeted: Bool
    let edge: ScreenEdgeSide
    let isEnglish: Bool
    let onDragBegin: () -> Void
    let onDragMoved: (CGSize) -> Void
    let onDragEnded: () -> Void
    let onOpenReceived: () -> Void
    let onDismissCompleted: () -> Void
    @State private var dragStarted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.12, green: 0.13, blue: 0.15).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            isDropTargeted
                                ? Color(red: 0.04, green: 0.52, blue: 1.0)
                                : Color.white.opacity(0.16),
                            lineWidth: isDropTargeted ? 2 : 1
                        )
                )
                .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 6)

            switch phase {
            case .idle:
                VStack(spacing: 6) {
                    Image(systemName: isDropTargeted ? "tray.and.arrow.down.fill" : "square.dashed.inset.filled")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
                    Text(isDropTargeted ? tr(isEnglish, "松手放到传输架", "Drop onto Shelf") : tr(isEnglish, "拖文件到此小框", "Drop Files Here"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.white)
                    Text(tr(isEnglish, "按住可沿屏幕边缘拖动", "Drag along screen edge"))
                        .font(.system(size: 9.5))
                        .foregroundColor(Color(white: 0.58))
                }
                .padding(8)

            case .hoverExpand(let name, let fsz, _, _, let hint, _):
                VStack(spacing: 5) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Color(red: 1.0, green: 0.62, blue: 0.04))
                    Text(name ?? tr(isEnglish, "松手开始发送", "Release to Send"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text("\(fsz ?? "") · \(hint ?? tr(isEnglish, "移开取消", "Move away to cancel"))")
                        .font(.system(size: 9.5))
                        .foregroundColor(Color(white: 0.72))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .padding(10)

            case .suckingIn(let p, let name, let size, let speedMbps, let chTag):
                cubeActive(icon: "arrow.up.right.circle.fill", title: tr(isEnglish, "发送 \(name)", "Sending \(name)"), subtitle: "\(size) · \(Int(p * 100))% · \(String(format: "%.0f MB/s", speedMbps / 8.0))", detail: chTag, progress: p)

            case .emergingOut(let p, let name, let size, let speedMbps, let chTag):
                cubeActive(icon: "arrow.down.left.circle.fill", title: tr(isEnglish, "接收 \(name)", "Receiving \(name)"), subtitle: "\(size) · \(Int(p * 100))% · \(String(format: "%.0f MB/s", speedMbps / 8.0))", detail: chTag, progress: p)

            case .completed(let name, _, _):
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Color(red: 0.19, green: 0.82, blue: 0.35))
                    Text(name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Button(action: onOpenReceived) {
                            Text(tr(isEnglish, "打开", "Open"))
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color(red: 0.04, green: 0.52, blue: 1.0)))
                        }
                        .buttonStyle(.plain)
                        Button(tr(isEnglish, "收起", "Hide")) { onDismissCompleted() }
                            .buttonStyle(PillButtonStyle())
                    }
                }
                .padding(10)
            }
        }
        .padding(8)
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if !dragStarted {
                        dragStarted = true
                        onDragBegin()
                    }
                    onDragMoved(value.translation)
                }
                .onEnded { _ in
                    dragStarted = false
                    onDragEnded()
                }
        )
    }

    private func cubeActive(icon: String, title: String, subtitle: String, detail: String, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            ProgressView(value: min(max(progress, 0.0), 1.0))
                .progressViewStyle(.linear)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.80))
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 9.5))
                .foregroundColor(Color(white: 0.56))
                .lineLimit(1)
        }
        .padding(12)
    }
}
