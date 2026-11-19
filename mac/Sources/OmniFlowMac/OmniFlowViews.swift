import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum OmniNavPage: String, CaseIterable, Identifiable {
    case displays = "displays"
    case input = "input"
    case portal = "portal"
    case usbDirect = "usb"
    case network = "network"

    var id: String { rawValue }

    func title(_ en: Bool) -> String {
        switch self {
        case .displays:  return tr(en, "屏幕排列", "Displays")
        case .input:     return tr(en, "键鼠共享", "KVM & Keys")
        case .portal:    return tr(en, "跨屏传文件", "File Portal")
        case .usbDirect: return tr(en, "USB 直连", "USB Direct")
        case .network:   return tr(en, "网络与通道", "Network")
        }
    }

    func subtitle(_ en: Bool) -> String {
        switch self {
        case .displays:  return tr(en, "拖一拖摆好位置", "Arrange monitors")
        case .input:     return tr(en, "切换、剪贴板与快捷键", "Switch, clipboard & keys")
        case .portal:    return tr(en, "文件传输与历史", "Transfers & history")
        case .usbDirect: return tr(en, "USB-C 直连", "USB-C tunnel")
        case .network:   return tr(en, "连接与配对", "NICs & pairing")
        }
    }

    var iconName: String {
        switch self {
        case .displays:  return "display.2"
        case .input:     return "keyboard"
        case .portal:    return "rectangle.portrait.and.arrow.right"
        case .usbDirect: return "cable.connector"
        case .network:   return "network"
        }
    }
}

struct OmniFlowMainView: View {
    @ObservedObject var engine: DeskflowEngine
    @State private var currentPage: OmniNavPage = .displays
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            // Left System Settings Style Sidebar
            VStack(alignment: .leading, spacing: 6) {
                // App Title, Language Switch & Connection Status
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 6) {
                        Text("OmniFlow")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                        LanguagePillToggle(isEnglish: $engine.isEnglish)
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(engine.peerConnectedCount > 0
                                  ? Color(red: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0)
                                  : Color(white: 0.45))
                            .frame(width: 7, height: 7)
                        Text(engine.peerConnectedCount > 0
                             ? engine.t("已连接 · \(engine.peerConnectedCount) 条链路", "Connected · \(engine.peerConnectedCount) link(s)")
                             : engine.t("等待连接", "Waiting for peer"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(Color(white: 0.74))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 34)
                .padding(.bottom, 14)

                ForEach(OmniNavPage.allCases) { page in
                    OmniSidebarNavRow(
                        page: page,
                        isEnglish: engine.isEnglish,
                        selected: currentPage == page,
                        action: { currentPage = page }
                    )
                }

                Spacer()

                // Quick Focus & Route Status Indicator at bottom of sidebar
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(engine.t("控制端：", "Active Host: "))
                            .font(.system(size: 11.5))
                            .foregroundColor(Color(white: 0.62))
                        Text(engine.remoteFocusOnWindows ? "Windows" : engine.t("Mac 本机", "This Mac"))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(engine.remoteFocusOnWindows
                                             ? Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0)
                                             : Color(red: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0))
                    }
                    Text(engine.t("控制连接：\(engine.activeControlChannelName)", "Control: \(engine.activeControlChannelName)"))
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.70))
                        .lineLimit(1)
                    Text(engine.t("文件连接：\(engine.activeDataChannelSummary)", "Data: \(engine.activeDataChannelSummary)"))
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.58))
                        .lineLimit(1)
                    if !engine.accessibilityGranted {
                        Button(engine.t("授权辅助功能权限", "Grant Accessibility")) {
                            engine.requestAccessibility()
                        }
                        .buttonStyle(OmniSecondaryButtonStyle())
                    }
                }
                .padding(12)
                .background(Color(white: 0.14))
                .cornerRadius(8)
                .padding(.bottom, 6)

                GitHubAuthorBadgeButton()
                    .padding(.bottom, 12)
            }
            .padding(.horizontal, 12)
            .frame(width: 215)
            .frame(maxHeight: .infinity)
            .background(Color(red: 0x18 / 255.0, green: 0x18 / 255.0, blue: 0x1A / 255.0))

            Divider()
                .background(Color(white: 0.22))

            // Right Dedicated Page Area
            VStack(alignment: .leading, spacing: 0) {
                if let pair = engine.pendingPairing {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(engine.t("有设备请求配对 · 短码：\(pair.sasCode)", "Pairing Request · SAS: \(pair.sasCode)"))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text(engine.t("设备：\(pair.hostName)（\(pair.remoteIp)）· 指纹：\(pair.fingerprint.prefix(32))… · 请确认两端短码一致",
                                          "Peer: \(pair.hostName) (\(pair.remoteIp)) · FP: \(pair.fingerprint.prefix(32))… · Verify SAS matches"))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color(white: 0.85))
                        }
                        Spacer()
                        Button(engine.t("拒绝", "Reject")) {
                            engine.rejectPendingPairing()
                        }
                        .buttonStyle(OmniSecondaryButtonStyle())
                        Button(engine.t("确认并配对", "Trust & Pair")) {
                            engine.confirmPendingPairing()
                        }
                        .buttonStyle(OmniPrimaryButtonStyle())
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0).opacity(0.22))
                    .overlay(Rectangle().frame(height: 1).foregroundColor(Color(red: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0).opacity(0.45)), alignment: .bottom)
                }

                switch currentPage {
                case .displays:
                    ArrangeDisplaysPageView(engine: engine)
                case .input:
                    InputAndShortcutsPageView(engine: engine)
                case .portal:
                    PortalAndFilesPageView(engine: engine, isDropTargeted: $isDropTargeted)
                case .usbDirect:
                    UsbDirectPageView(engine: engine)
                case .network:
                    NetworkAndDriverPageView(engine: engine)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x20 / 255.0))
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Page 1: 2D Spatial Arrange Displays (macOS System Settings Arrange Displays Style)

struct ArrangeDisplaysPageView: View {
    @ObservedObject var engine: DeskflowEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Top Page Header
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.t("屏幕排列", "Arrange Displays"))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                    Text(engine.t("拖动屏幕，调整它们的位置。", "Drag displays to arrange their layout."))
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(white: 0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(0)
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    if !engine.displaySaveStatusText.isEmpty {
                        Text(engine.displaySaveStatusText)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(Color(red: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color(red: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0).opacity(0.16))
                            .cornerRadius(6)
                    }

                    Button(engine.t("保存位置", "Save Layout")) {
                        engine.saveDisplayArrangement()
                    }
                    .buttonStyle(OmniSecondaryButtonStyle())
                    .fixedSize(horizontal: true, vertical: false)

                    Button(engine.t("显示屏幕编号", "Identify")) {
                        engine.flashIdentifyScreens()
                    }
                    .buttonStyle(OmniSecondaryButtonStyle())
                    .fixedSize(horizontal: true, vertical: false)

                    Button(engine.t("恢复默认排列", "Reset")) {
                        engine.resetDisplayArrangement2D()
                    }
                    .buttonStyle(OmniSecondaryButtonStyle())
                    .fixedSize(horizontal: true, vertical: false)

                    Button(engine.t("重新识别", "Refresh")) {
                        engine.refreshIndependentDisplays()
                    }
                    .buttonStyle(OmniPrimaryButtonStyle())
                    .fixedSize(horizontal: true, vertical: false)
                }
                .layoutPriority(1)
            }

            // 2D Spatial Canvas Box (Styled after macOS Arrange Displays modal)
            GeometryReader { geo in
                let canvasSize = geo.size
                ZStack(alignment: .topLeading) {
                    // Subtle spatial workspace background
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(red: 0x25 / 255.0, green: 0x26 / 255.0, blue: 0x28 / 255.0))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(white: 0.24), lineWidth: 1)
                        )

                    // Subtle coordinate grid dots
                    Canvas { ctx, sz in
                        let step: CGFloat = 28
                        var y: CGFloat = step
                        while y < sz.height {
                            var x: CGFloat = step
                            while x < sz.width {
                                let dot = CGRect(x: x, y: y, width: 1.5, height: 1.5)
                                ctx.fill(Path(ellipseIn: dot), with: .color(Color.white.opacity(0.07)))
                                x += step
                            }
                            y += step
                        }
                    }

                    // Draggable 2D Monitor Rectangles
                    ForEach(engine.displayNodes) { node in
                        SpatialMonitorTileView(
                            node: node,
                            isSelected: engine.selectedDisplayId == node.id,
                            onSelect: {
                                engine.selectedDisplayId = node.id
                            },
                            onDragMove: { newX, newY in
                                engine.updateDisplayNodePosition(
                                    id: node.id,
                                    x: newX,
                                    y: newY,
                                    canvasSize: canvasSize
                                )
                            },
                            onDragEnd: {
                                engine.finishDisplayDrag(id: node.id, canvasSize: canvasSize)
                            }
                        )
                    }
                }
                .coordinateSpace(name: "arrangeCanvas")
                .onAppear {
                    engine.centerCurrentDisplaysNow(canvasSize: canvasSize)
                }
                .onChange(of: canvasSize) { _, newSize in
                    engine.centerCurrentDisplaysNow(canvasSize: newSize)
                }
            }
            .frame(minHeight: 370)

            // Selected Display Inspector Bar
            if let selId = engine.selectedDisplayId,
               let sel = engine.displayNodes.first(where: { $0.id == selId }) {
                HStack(spacing: 16) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(sel.osKind == .mac
                                  ? Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0)
                                  : Color(red: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0))
                            .frame(width: 8, height: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(sel.name) (\(sel.osKind.rawValue))")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                            Text(engine.t(
                                "\(sel.widthPx) × \(sel.heightPx) · 缩放 \(Int(sel.scaleFactor * 100))% · 位置 (\(Int(sel.canvasX)), \(Int(sel.canvasY)))",
                                "\(sel.widthPx) × \(sel.heightPx) · Scale \(Int(sel.scaleFactor * 100))% · Pos (\(Int(sel.canvasX)), \(Int(sel.canvasY)))"
                            ))
                                .font(.system(size: 11.5))
                                .foregroundColor(Color(white: 0.64))
                        }
                    }
                    Spacer()
                    Text(engine.t("拖动屏幕调整位置，靠近时会自动对齐。", "Drag displays to reposition; edges snap automatically."))
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(white: 0.58))
                }
                .padding(14)
                .background(Color(red: 0x26 / 255.0, green: 0x26 / 255.0, blue: 0x29 / 255.0))
                .cornerRadius(9)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(white: 0.22), lineWidth: 1))
            }
        }
        .padding(24)
    }
}

struct SpatialMonitorTileView: View {
    let node: IndependentDisplayNode
    let isSelected: Bool
    let onSelect: () -> Void
    let onDragMove: (CGFloat, CGFloat) -> Void
    let onDragEnd: () -> Void

    @State private var dragStartPos: CGPoint? = nil

    var body: some View {
        let isMac = (node.osKind == .mac)
        ZStack(alignment: .top) {
            // Scenic Wallpaper Background (like macOS Arrange Displays)
            ZStack {
                LinearGradient(
                    colors: isMac
                        ? [Color(red: 0x2A / 255.0, green: 0x6F / 255.0, blue: 0xB0 / 255.0),
                           Color(red: 0x1A / 255.0, green: 0x8C / 255.0, blue: 0x9E / 255.0),
                           Color(red: 0x16 / 255.0, green: 0x4E / 255.0, blue: 0x63 / 255.0)]
                        : [Color(red: 0x1E / 255.0, green: 0x40 / 255.0, blue: 0x78 / 255.0),
                           Color(red: 0x1E / 255.0, green: 0x5E / 255.0, blue: 0x6F / 255.0),
                           Color(red: 0x12 / 255.0, green: 0x35 / 255.0, blue: 0x48 / 255.0)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Stylized horizon & lake shoreline silhouette
                Canvas { ctx, sz in
                    var mtn = Path()
                    mtn.move(to: CGPoint(x: 0, y: sz.height * 0.56))
                    mtn.addLine(to: CGPoint(x: sz.width * 0.28, y: sz.height * 0.45))
                    mtn.addLine(to: CGPoint(x: sz.width * 0.55, y: sz.height * 0.52))
                    mtn.addLine(to: CGPoint(x: sz.width * 0.82, y: sz.height * 0.42))
                    mtn.addLine(to: CGPoint(x: sz.width, y: sz.height * 0.50))
                    mtn.addLine(to: CGPoint(x: sz.width, y: sz.height))
                    mtn.addLine(to: CGPoint(x: 0, y: sz.height))
                    mtn.closeSubpath()
                    ctx.fill(mtn, with: .color(Color.black.opacity(0.22)))
                }
            }

            // White Menu Bar strip at top of primary display (just like macOS Arrange Displays)
            if node.isPrimary {
                Rectangle()
                    .fill(Color.white.opacity(0.82))
                    .frame(height: 8)
            }

            // Monitor Name & Resolution Overlay
            VStack(spacing: 3) {
                Spacer()
                HStack(spacing: 4) {
                    Text(isMac ? "macOS" : "Windows")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.black.opacity(0.55))
                        .foregroundColor(.white)
                        .cornerRadius(4)
                    Text("#\(node.displayIndex + 1)")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
                Text(node.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .shadow(color: .black.opacity(0.7), radius: 2, x: 0, y: 1)
                Text("\(node.widthPx)×\(node.heightPx)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(Color(white: 0.88))
                    .padding(.bottom, 7)
            }
        }
        .frame(width: node.aspectWidth, height: node.aspectHeight)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    isSelected
                        ? Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0)
                        : Color.white.opacity(0.45),
                    lineWidth: isSelected ? 2.5 : 1.0
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
        .position(
            x: node.canvasX + node.aspectWidth / 2,
            y: node.canvasY + node.aspectHeight / 2
        )
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("arrangeCanvas"))
                .onChanged { value in
                    var tx = Transaction(animation: nil)
                    tx.disablesAnimations = true
                    withTransaction(tx) {
                        if dragStartPos == nil {
                            dragStartPos = CGPoint(x: node.canvasX, y: node.canvasY)
                            onSelect()
                        }
                        if let start = dragStartPos {
                            onDragMove(
                                start.x + value.translation.width,
                                start.y + value.translation.height
                            )
                        }
                    }
                }
                .onEnded { _ in
                    dragStartPos = nil
                    onDragEnd()
                }
        )
    }
}

// MARK: - Page 2: Input, Focus Switching & Cross-OS Shortcuts

struct InputAndShortcutsPageView: View {
    @ObservedObject var engine: DeskflowEngine
    @State private var selectedDirectionTab: String = "mac_to_win"

    private var macToWinDisabled: Bool {
        engine.kvmControlMode == .winMasterOnly
    }

    private var winToMacDisabled: Bool {
        engine.kvmControlMode == .macMasterOnly
    }

    private var effectiveDirection: String {
        if macToWinDisabled { return "win_to_mac" }
        if winToMacDisabled { return "mac_to_win" }
        return selectedDirectionTab
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.t("键鼠共享与切换", "KVM Input & Shortcuts"))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                    Text(engine.t("设置控制切换、剪贴板和快捷键。", "Configure focus switching, clipboard sync, and keybindings."))
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(white: 0.65))
                }

                // Accessibility permission alert banner (re-auth needed after app update)
                if !engine.accessibilityGranted {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.2))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.t("需要辅助功能权限才能使用跨屏控制。", "Accessibility permission is required for cross-screen KVM."))
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(.white)
                            Text(engine.t("请在系统设置 → 隐私与安全性 → 辅助功能中允许 OmniFlow。", "Enable OmniFlow in System Settings → Privacy & Security → Accessibility."))
                                .font(.system(size: 11))
                                .foregroundColor(Color(white: 0.72))
                        }
                        Spacer()
                        Button(engine.t("前往授权", "Authorize")) {
                            engine.requestAccessibility()
                        }
                        .buttonStyle(OmniPrimaryButtonStyle())
                    }
                    .padding(14)
                    .background(Color(red: 0.32, green: 0.22, blue: 0.08).opacity(0.65))
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 1.0, green: 0.72, blue: 0.2).opacity(0.45), lineWidth: 1))
                }

                // Section 1: Focus Switching Settings
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(engine.t("控制切换", "Focus Switching"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer()
                        Button(engine.remoteFocusOnWindows ? engine.t("切回 Mac", "Return to Mac") : engine.t("切到 Windows 控制", "Switch to Windows")) {
                            engine.toggleManualFocusSwitch()
                        }
                        .buttonStyle(OmniPrimaryButtonStyle())
                    }

                    Divider().background(Color(white: 0.24))

                    Toggle(isOn: $engine.kvmEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.t("开启键鼠共享", "Enable Keyboard & Mouse Sharing"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text(engine.t("开启后可在两台电脑间切换控制。", "Allows switching input seamlessly between Mac and Windows."))
                                .font(.system(size: 11.5))
                                .foregroundColor(Color(white: 0.62))
                        }
                    }
                    .toggleStyle(.switch)

                    Toggle(isOn: $engine.edgeSwitchEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.t("移到屏幕边缘时切换", "Switch on Screen Edge"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text(engine.t("屏幕位置在「屏幕排列」中设置。", "Follows the geometry set in Arrange Displays."))
                                .font(.system(size: 11.5))
                                .foregroundColor(Color(white: 0.62))
                        }
                    }
                    .toggleStyle(.switch)

                    Toggle(isOn: $engine.hotkeySwitchEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.t("快捷键切换控制权（Ctrl + Opt + S）", "Hotkey Focus Toggle (Ctrl + Opt + S)"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text(engine.t("Ctrl + Opt + S 切换；Ctrl + Opt + Esc 返回 Mac。", "Ctrl + Opt + S toggles host; Ctrl + Opt + Esc returns to Mac."))
                                .font(.system(size: 11.5))
                                .foregroundColor(Color(white: 0.62))
                        }
                    }
                    .toggleStyle(.switch)

                    Toggle(isOn: $engine.clipboardSyncEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.t("剪贴板同步（文字、图片和文件）", "Clipboard Sync (Text, Images & Files)"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text(engine.t("复制后可在另一台电脑粘贴。", "Copy on one computer and paste directly on the other."))
                                .font(.system(size: 11.5))
                                .foregroundColor(Color(white: 0.62))
                        }
                    }
                    .toggleStyle(.switch)

                    Divider().background(Color(white: 0.24))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(engine.t("控制方向", "Control Direction"))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.white)
                        OmniSegmentedPicker(
                            selection: $engine.kvmControlMode,
                            options: [
                                .init(value: .dualActive, title: engine.t("两边互控 (推荐)", "Bidirectional (Recommended)")),
                                .init(value: .macMasterOnly, title: engine.t("只用 Mac 控制 Windows", "Mac Controls Windows Only")),
                                .init(value: .winMasterOnly, title: engine.t("只用 Windows 控制 Mac", "Windows Controls Mac Only"))
                            ]
                        )
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(engine.t("按键映射", "Modifier Mapping"))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.white)
                        Text(engine.t("Command 对应 Win，Option 对应 Alt。需要时可在下方设置快捷键。", "Command maps to Win; Option maps to Alt. Enable semantic rules below as needed."))
                            .font(.system(size: 11.5))
                            .foregroundColor(Color(white: 0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .background(Color(red: 0x26 / 255.0, green: 0x26 / 255.0, blue: 0x29 / 255.0))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.22), lineWidth: 1))

                // Section 2: Cross-OS Semantic Shortcut Rules & Trackpad Gestures (Dual Merged Direction Tabs)
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.t("快捷键与触控板手势", "Shortcuts & Trackpad"))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                            Text(engine.t("分别设置 Mac → Windows 和 Windows → Mac 的快捷键与手势。", "Configure Mac → Windows and Windows → Mac shortcuts and gestures separately."))
                                .font(.system(size: 11.5))
                                .foregroundColor(Color(white: 0.62))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .layoutPriority(0)
                        Spacer(minLength: 8)
                        HStack(spacing: 8) {
                            if !engine.settingsSaveStatusText.isEmpty {
                                Text(engine.settingsSaveStatusText)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundColor(Color(red: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(Color(red: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0).opacity(0.16))
                                    .cornerRadius(6)
                            }
                            Button(engine.t("试一下远程截图", "Test Remote Screenshot")) {
                                engine.triggerRemoteWindowsScreenshot(isRegion: true)
                            }
                            .buttonStyle(OmniSecondaryButtonStyle())
                            .fixedSize(horizontal: true, vertical: false)
                            Button(engine.t("保存设置", "Save Settings")) {
                                engine.saveAllSettingsManual()
                            }
                            .buttonStyle(OmniPrimaryButtonStyle())
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        .layoutPriority(1)
                    }

                    // Merged 2-button direction segmented switch (Windows vs Mac)
                    HStack(spacing: 0) {
                        Button(action: {
                            if !macToWinDisabled { selectedDirectionTab = "mac_to_win" }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "laptopcomputer.and.arrow.right")
                                    .font(.system(size: 11.5))
                                Text(macToWinDisabled
                                     ? engine.t("Mac 控制 Windows（已屏蔽）", "Mac → Windows (Blocked)")
                                     : engine.t("Mac 控制 Windows（Mac → Win）", "Mac → Windows"))
                                    .font(.system(size: 12.5, weight: effectiveDirection == "mac_to_win" ? .semibold : .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                effectiveDirection == "mac_to_win"
                                ? Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0)
                                : Color(red: 0x1E / 255.0, green: 0x1F / 255.0, blue: 0x22 / 255.0)
                            )
                            .foregroundColor(
                                macToWinDisabled
                                ? Color(white: 0.42)
                                : (effectiveDirection == "mac_to_win" ? .white : Color(white: 0.78))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(macToWinDisabled)

                        Rectangle()
                            .fill(Color(white: 0.28))
                            .frame(width: 1)

                        Button(action: {
                            if !winToMacDisabled { selectedDirectionTab = "win_to_mac" }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "display.and.arrow.down")
                                    .font(.system(size: 11.5))
                                Text(winToMacDisabled
                                     ? engine.t("Windows 控制 Mac（已屏蔽）", "Windows → Mac (Blocked)")
                                     : engine.t("Windows 控制 Mac（Win → Mac）", "Windows → Mac"))
                                    .font(.system(size: 12.5, weight: effectiveDirection == "win_to_mac" ? .semibold : .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                effectiveDirection == "win_to_mac"
                                ? Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0)
                                : Color(red: 0x1E / 255.0, green: 0x1F / 255.0, blue: 0x22 / 255.0)
                            )
                            .foregroundColor(
                                winToMacDisabled
                                ? Color(white: 0.42)
                                : (effectiveDirection == "win_to_mac" ? .white : Color(white: 0.78))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(winToMacDisabled)
                    }
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(white: 0.28), lineWidth: 1)
                    )
                    .onChange(of: engine.kvmControlMode) { _, newMode in
                        if newMode == .macMasterOnly { selectedDirectionTab = "mac_to_win" }
                        else if newMode == .winMasterOnly { selectedDirectionTab = "win_to_mac" }
                    }

                    let dir = effectiveDirection
                    let shortcutIndices = engine.hotkeyRules.indices.filter {
                        engine.hotkeyRules[$0].direction == dir && !engine.hotkeyRules[$0].isGesture
                    }
                    let gestureIndices = engine.hotkeyRules.indices.filter {
                        engine.hotkeyRules[$0].direction == dir && engine.hotkeyRules[$0].isGesture
                    }

                    Text(engine.t("常用快捷键替换", "Semantic Shortcut Rules"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(white: 0.70))

                    ForEach(shortcutIndices, id: \.self) { idx in
                        let rule = engine.hotkeyRules[idx]
                        HStack(spacing: 12) {
                            Toggle("", isOn: $engine.hotkeyRules[idx].enabled)
                                .labelsHidden()
                            Text(rule.title(isEnglish: engine.isEnglish))
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 210, alignment: .leading)
                            Text(rule.triggerText(isEnglish: engine.isEnglish))
                                .font(.system(size: 11.5, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color(white: 0.16))
                                .foregroundColor(Color(white: 0.88))
                                .cornerRadius(5)
                            Text("→")
                                .foregroundColor(Color(white: 0.50))
                            Text(rule.actionText(isEnglish: engine.isEnglish))
                                .font(.system(size: 11.5, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color(white: 0.16))
                                .foregroundColor(Color(red: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0))
                                .cornerRadius(5)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }

                    Divider().background(Color(white: 0.24))

                    HStack(spacing: 8) {
                        Text(dir == "mac_to_win"
                             ? engine.t("触控板三指拖移（MacBook 触控板 → Windows）", "Trackpad 3-Finger Drag (MacBook Trackpad → Windows)")
                             : engine.t("触控板三指拖移（Windows 精确触控板 → Mac）", "Trackpad 3-Finger Drag (Windows Touchpad → Mac)"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(white: 0.70))
                        if let rtt = engine.currentControlLinkRttMs, rtt >= 10.0 {
                            Text(engine.t("当前延迟较高 (\(Int(rtt.rounded())) ms)，可能影响拖移体验", "High latency (\(Int(rtt.rounded())) ms) — wired/USB recommended"))
                                .font(.system(size: 10.5, weight: .semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color(red: 1.0, green: 0.62, blue: 0.04).opacity(0.20))
                                .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.20))
                                .cornerRadius(4)
                        }
                    }

                    ForEach(gestureIndices, id: \.self) { idx in
                        let rule = engine.hotkeyRules[idx]
                        HStack(spacing: 12) {
                            Toggle("", isOn: $engine.hotkeyRules[idx].enabled)
                                .labelsHidden()
                            Text(rule.title(isEnglish: engine.isEnglish))
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 210, alignment: .leading)
                            Text(rule.triggerText(isEnglish: engine.isEnglish))
                                .font(.system(size: 11.5, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color(white: 0.16))
                                .foregroundColor(Color(white: 0.88))
                                .cornerRadius(5)
                            Text("→")
                                .foregroundColor(Color(white: 0.50))
                            Text(rule.actionText(isEnglish: engine.isEnglish))
                                .font(.system(size: 11.5, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color(white: 0.16))
                                .foregroundColor(Color(red: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0))
                                .cornerRadius(5)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 12.5))
                            .foregroundColor(Color(red: 1.0, green: 0.68, blue: 0.15))
                            .padding(.top, 1)
                        Text(engine.t(
                            "提示：三指拖移对网络延迟较为敏感。高延迟或 Wi-Fi 波动较大时容易出现漂移或卡顿，建议在有线网线或 USB-C 直连环境下开启使用。",
                            "Note: Three-finger drag is sensitive to network latency. High RTT or unstable Wi-Fi may cause cursor drift or lag; wired Ethernet or USB-C Direct is recommended."
                        ))
                            .font(.system(size: 11.5))
                            .foregroundColor(Color(white: 0.70))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(Color(red: 1.0, green: 0.62, blue: 0.04).opacity(0.09))
                    .cornerRadius(7)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(red: 1.0, green: 0.62, blue: 0.04).opacity(0.28), lineWidth: 1))
                }
                .padding(16)
                .background(Color(red: 0x26 / 255.0, green: 0x26 / 255.0, blue: 0x29 / 255.0))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.22), lineWidth: 1))
            }
            .padding(24)
        }
    }
}

// MARK: - Page 3: Screen-Edge Portal & File Transfer

struct PortalAndFilesPageView: View {
    @ObservedObject var engine: DeskflowEngine
    @Binding var isDropTargeted: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.t("跨屏传文件", "File Portal & Transfers"))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                    Text(engine.t("把文件拖到下方区域或屏幕边缘，松手发送到 Windows。", "Drop files below or at the screen edge to send to Windows."))
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(white: 0.65))
                }

                // Section 1: Edge Portal Configuration
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Toggle(engine.t("启用边缘传输区", "Enable Screen-Edge Portal"), isOn: $engine.portalOverlayEnabled)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .toggleStyle(.switch)
                        Spacer()
                    }

                    Divider().background(Color(white: 0.24))

                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(engine.t("传输区样式", "Portal Style"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color(white: 0.72))
                            OmniSegmentedPicker(
                                selection: $engine.portalEffectStyle,
                                options: [
                                    .init(value: .blackHole, title: engine.t("隐藏边缘入口", "Hidden Edge Wall")),
                                    .init(value: .floatingCube, title: engine.t("悬浮按钮", "Floating Drop Box"))
                                ]
                            )
                            .frame(width: 260)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text(engine.t("屏幕边缘 · 屏幕 #\(engine.portalMonitorIndex + 1)", "Screen Edge · Display #\(engine.portalMonitorIndex + 1)"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color(white: 0.72))
                            OmniSegmentedPicker(
                                selection: $engine.portalEdgeSide,
                                options: [
                                    .init(value: .right, title: engine.t("右边", "Right")),
                                    .init(value: .left, title: engine.t("左边", "Left")),
                                    .init(value: .top, title: engine.t("顶边", "Top")),
                                    .init(value: .bottom, title: engine.t("底边", "Bottom"))
                                ]
                            )
                            .frame(width: 248)
                        }
                    }

                    HStack(spacing: 14) {
                        Text(engine.t("边缘位置（\(Int(engine.portalEdgeOffset * 100))%）", "Edge Offset (\(Int(engine.portalEdgeOffset * 100))%)"))
                            .font(.system(size: 12))
                            .foregroundColor(Color(white: 0.72))
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $engine.portalEdgeOffset, in: 0.05...0.95)
                    }
                }
                .padding(16)
                .background(Color(red: 0x26 / 255.0, green: 0x26 / 255.0, blue: 0x29 / 255.0))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.22), lineWidth: 1))

                // Section 2: Direct Drag-and-Drop Box
                VStack(spacing: 10) {
                    Text(isDropTargeted
                         ? engine.t("松手就开始发往 Windows", "Release to Send to Windows")
                         : engine.t("把文件、文件夹或压缩包拖到这里", "Drop Files, Folders or Archives Here"))
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(.white)
                    Text(engine.t("拖到边缘后，松手发送；拖回来取消。", "Drag to screen edge and release to send; pull back to cancel."))
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(white: 0.62))

                    HStack(spacing: 10) {
                        Button(engine.t("选文件发送...", "Choose File...")) {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let u = panel.url {
                                engine.startFileTransferFlow(for: u)
                            }
                        }
                        .buttonStyle(OmniPrimaryButtonStyle())

                        Button(engine.t("选文件夹发送...", "Choose Folder...")) {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let u = panel.url {
                                engine.startFileTransferFlow(for: u)
                            }
                        }
                        .buttonStyle(OmniSecondaryButtonStyle())
                    }

                    if !engine.lastTransferSummary.isEmpty {
                        Text(engine.lastTransferSummary)
                            .font(.system(size: 11.5))
                            .foregroundColor(Color(red: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0))
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(red: 0x23 / 255.0, green: 0x24 / 255.0, blue: 0x27 / 255.0))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(
                                    isDropTargeted
                                        ? Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0)
                                        : Color(white: 0.28),
                                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                                )
                        )
                )
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    engine.handleDroppedProviders(providers)
                    return true
                }

                // Section 2.5: Persistent Transfer Shelf Tasks (Synced with Edge Shelf)
                if !engine.shelfItems.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(engine.t("传输任务（\(engine.shelfItems.count)）", "Active Transfers (\(engine.shelfItems.count))"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)

                        Divider().background(Color(white: 0.24))

                        ForEach(engine.shelfItems) { item in
                            ShelfCardItemView(item: item, engine: engine)
                        }
                    }
                    .padding(16)
                    .background(Color(red: 0x26 / 255.0, green: 0x26 / 255.0, blue: 0x29 / 255.0))
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.22), lineWidth: 1))
                }

                // Section 3: Received Files & ZIP History
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(engine.t("收到的文件", "Received Files"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer()
                        Button(engine.t("打开文件夹", "Open Folder")) {
                            engine.openLastReceivedFile()
                        }
                        .buttonStyle(OmniSecondaryButtonStyle())
                    }

                    Divider().background(Color(white: 0.24))

                    if engine.receivedFiles.isEmpty {
                        Text(engine.t("收到的文件会显示在这里。", "Received files will appear here."))
                            .font(.system(size: 12))
                            .foregroundColor(Color(white: 0.56))
                            .padding(.vertical, 8)
                    } else {
                        ForEach(engine.receivedFiles) { item in
                            HStack(spacing: 10) {
                                Text(item.isArchiveOrFolder ? "ZIP" : "FILE")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(white: 0.18))
                                    .foregroundColor(Color(red: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0))
                                    .cornerRadius(4)
                                Text(item.fileName)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                Spacer()
                                Text(item.fileSize)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundColor(Color(white: 0.65))
                                Button(engine.t("在 Finder 中显示", "Show in Finder")) {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.savedURL])
                                }
                                .buttonStyle(OmniSecondaryButtonStyle())
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .padding(16)
                .background(Color(red: 0x26 / 255.0, green: 0x26 / 255.0, blue: 0x29 / 255.0))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.22), lineWidth: 1))
            }
            .padding(24)
        }
    }
}

// MARK: - Page 4: Dedicated MacBridge-Style USB Direct Tunnel Page

struct UsbDirectPageView: View {
    @ObservedObject var engine: DeskflowEngine

    private var usbChannel: NicChannelItem? {
        engine.nicChannels.first(where: { $0.isUsbBridge })
    }

    private var dotColor: Color {
        if let ch = usbChannel, ch.online && !ch.manuallyDisconnected {
            return Color(red: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0)
        }
        if engine.usbActionInProgress || engine.usbNcmDetected {
            return Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0)
        }
        if let ch = usbChannel, ch.manuallyDisconnected {
            return Color(red: 1.0, green: 0.62, blue: 0.04)
        }
        return Color(white: 0.45)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.t("USB 直连", "USB Direct"))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                    Text(engine.t("连接 USB-C 后自动建立直连。", "Connect USB-C cable to establish a P2P direct link automatically."))
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(white: 0.65))
                }

                // Hero Status Card + Smooth Animated Action Progress Bar
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(dotColor.opacity(0.20))
                                .frame(width: 28, height: 28)
                            Circle()
                                .fill(dotColor)
                                .frame(width: 12, height: 12)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(engine.usbHeadline)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                            Text(engine.usbSubline)
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.65))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        // Mac side connects automatically via Apple NCM; only show Pause/Resume if needed
                        if let ch = usbChannel {
                            if ch.online && !ch.manuallyDisconnected {
                                Button(engine.t("断开 USB", "Disconnect")) {
                                    engine.disconnectUsbDirectBridge()
                                }
                                .buttonStyle(OmniSecondaryButtonStyle())
                            } else if ch.manuallyDisconnected {
                                Button(engine.t("恢复自动直连", "Reconnect")) {
                                    engine.connectUsbDirectBridge()
                                }
                                .buttonStyle(OmniPrimaryButtonStyle())
                            }
                        }
                    }

                    if engine.usbActionInProgress || (engine.usbConnectProgress > 0.0 && engine.usbConnectProgress < 1.0) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(engine.t("连接进度", "Progress"))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundColor(Color(white: 0.72))
                                Spacer()
                                Text("\(Int(engine.usbConnectProgress * 100))%")
                                    .font(.system(size: 11.5, weight: .bold).monospacedDigit())
                                    .foregroundColor(Color(red: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0))
                            }

                            OmniSmoothLinearProgressBar(
                                progress: engine.usbConnectProgress,
                                isComplete: false
                            )

                            Text(engine.usbActionHint.isEmpty ? engine.usbStatusText : engine.usbActionHint)
                                .font(.system(size: 11))
                                .foregroundColor(Color(white: 0.62))
                        }
                    }
                }
                .padding(16)
                .background(Color(red: 0x26 / 255.0, green: 0x26 / 255.0, blue: 0x29 / 255.0))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.24), lineWidth: 1))

                // 3 Telemetry Cards matching original MacBridge
                HStack(spacing: 12) {
                    usbMetricCard(
                        title: engine.t("USB 网卡", "USB Adapter"),
                        value: engine.usbDriverStatusText,
                        caption: engine.t("插线后自动识别", "Driver-free Apple NCM")
                    )
                    usbMetricCard(
                        title: engine.t("直连地址 (Mac ↔ Win)", "Tunnel IPs (Mac ↔ Win)"),
                        value: "\(usbChannel?.localIp ?? engine.usbNcmLocalIp) ↔ \(usbChannel?.peerIp ?? engine.usbNcmPeerIp)",
                        caption: engine.t("USB 直连", "USB Direct")
                    )
                    usbMetricCard(
                        title: engine.t("流量与延迟", "Packets & RTT"),
                        value: engine.t("收 \(engine.usbRxFrames) / 发 \(engine.usbTxFrames)", "RX \(engine.usbRxFrames) / TX \(engine.usbTxFrames)"),
                        caption: usbChannel?.rttMs.map { engine.t(String(format: "当前延迟 %.2f ms", $0), String(format: "RTT %.2f ms", $0)) } ?? engine.t("还没握手", "Not handshaked")
                    )
                }

                // Dedicated USB Console Log
                VStack(alignment: .leading, spacing: 8) {
                    Text(engine.t("USB 连接日志", "USB Console Log"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            let items = engine.usbLogs.isEmpty ? Array(engine.logs.suffix(12)) : Array(engine.usbLogs.suffix(30))
                            ForEach(items, id: \.self) { line in
                                Text(line)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(Color(white: 0.72))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(height: 150)
                }
                .padding(14)
                .background(Color(red: 0x18 / 255.0, green: 0x18 / 255.0, blue: 0x1A / 255.0))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.20), lineWidth: 1))
            }
            .padding(24)
        }
    }

    private func usbMetricCard(title: String, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(white: 0.56))
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundColor(.white)
                .lineLimit(2)
            Text(caption)
                .font(.system(size: 10.5))
                .foregroundColor(Color(white: 0.60))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color(red: 0x26 / 255.0, green: 0x26 / 255.0, blue: 0x29 / 255.0))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.22), lineWidth: 1))
    }
}

// MARK: - Page 5: Network Channels Management

struct NetworkAndDriverPageView: View {
    @ObservedObject var engine: DeskflowEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.t("网络与连接", "Network & Channels"))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                    Text(engine.t("查看网卡状态和延迟；大文件可使用多网卡传输。", "Monitor NIC latency and enable multi-NIC acceleration for large transfers."))
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(white: 0.65))
                }

                // Peer Connection Bar (hide Connect button once connected — show only Disconnect!)
                HStack(spacing: 12) {
                    Text(engine.t("对端 IP：", "Peer IP:"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(.white)
                    TextField(engine.t("输入对端 IP（可选，支持自动发现）", "Peer IP (optional, auto-discovers)"), text: $engine.manualPeerIp)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundColor(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(red: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x1E / 255.0))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(white: 0.30), lineWidth: 1)
                        )
                        .frame(width: 210)

                    if engine.peerConnectedCount == 0 || engine.globalPaused {
                        Button(engine.t("连过去", "Connect")) {
                            engine.connectManualPeer()
                        }
                        .buttonStyle(OmniPrimaryButtonStyle())
                    }

                    if engine.peerConnectedCount > 0 && !engine.globalPaused {
                        Button(engine.t("全部断开", "Disconnect All")) {
                            engine.toggleGlobalDisconnect()
                        }
                        .buttonStyle(OmniSecondaryButtonStyle())
                    } else if engine.globalPaused {
                        Button(engine.t("恢复连接", "Reconnect All")) {
                            engine.toggleGlobalDisconnect()
                        }
                        .buttonStyle(OmniSecondaryButtonStyle())
                    }

                    Spacer()

                    Toggle(engine.t("大文件使用多网卡传输", "Multi-NIC for large files"), isOn: $engine.multipathEnabled)
                        .font(.system(size: 12.5))
                        .foregroundColor(.white)
                        .toggleStyle(.switch)
                }
                .padding(14)
                .background(Color(red: 0x26 / 255.0, green: 0x26 / 255.0, blue: 0x29 / 255.0))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.22), lineWidth: 1))

                // NIC List
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(engine.t("可用网卡和连接线路", "Available Network Interfaces"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer()
                        Text(engine.multipathEnabled
                             ? engine.t("多网卡传输", "Multipath Active")
                             : engine.t("自动选择线路", "Auto Route"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(Color(white: 0.62))
                    }

                    Divider().background(Color(white: 0.24))

                    ForEach(engine.nicChannels) { ch in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(ch.manuallyDisconnected
                                      ? Color(red: 1.0, green: 0.62, blue: 0.04)
                                      : (ch.online
                                         ? Color(red: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0)
                                         : Color(white: 0.40)))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ch.displayName)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(.white)
                                Text("\(ch.localIp) ↔ \(ch.peerIp) · \(ch.securityMode == .trustedUsbP2P ? engine.t("USB 直连", "USB Direct") : engine.t("已加密", "TLS Encrypted"))")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(Color(white: 0.62))
                            }
                            Spacer()
                            if ch.isRecommendedControl && !ch.manuallyDisconnected {
                                Text(engine.t("控制线路", "Control"))
                                    .font(.system(size: 10.5, weight: .medium))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0).opacity(0.22))
                                    .foregroundColor(Color(red: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0))
                                    .cornerRadius(4)
                            }
                            if ch.isRecommendedData && !ch.manuallyDisconnected {
                                Text(engine.t("文件线路", "Data"))
                                    .font(.system(size: 10.5, weight: .medium))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color(red: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0).opacity(0.22))
                                    .foregroundColor(Color(red: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0))
                                    .cornerRadius(4)
                            }
                            Text(ch.manuallyDisconnected
                                 ? engine.t("已断开", "Paused")
                                 : (ch.rttMs.map { String(format: "%.1f ms", $0) } ?? engine.t("待机", "Idle")))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(ch.manuallyDisconnected ? Color(red: 1.0, green: 0.62, blue: 0.04) : Color(white: 0.80))
                                .frame(width: 58, alignment: .trailing)

                            OmniAnimatedSwitch(
                                label: engine.t("参与并发", "Aggregate"),
                                isOn: Binding(
                                    get: { ch.enabledForMultipath },
                                    set: { newVal in
                                        if newVal != ch.enabledForMultipath {
                                            engine.toggleNicMultipath(ch)
                                        }
                                    }
                                )
                            )
                            .disabled(ch.manuallyDisconnected || !engine.multipathEnabled)
                            .opacity((!ch.manuallyDisconnected && engine.multipathEnabled) ? 1.0 : 0.45)

                            if ch.manuallyDisconnected {
                                Button(engine.t("重连", "Reconnect")) {
                                    engine.reconnectNic(ch)
                                }
                                .buttonStyle(OmniPrimaryButtonStyle())
                                .frame(minWidth: 54)
                            } else if ch.online {
                                Button(engine.t("断开", "Disconnect")) {
                                    engine.disconnectNic(ch)
                                }
                                .buttonStyle(OmniSecondaryButtonStyle())
                                .frame(minWidth: 54)
                            } else {
                                Button(engine.t("连接", "Connect")) {
                                    engine.reconnectNic(ch)
                                }
                                .buttonStyle(OmniPrimaryButtonStyle())
                                .frame(minWidth: 54)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                .padding(16)
                .background(Color(red: 0x26 / 255.0, green: 0x26 / 255.0, blue: 0x29 / 255.0))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.22), lineWidth: 1))

                // Mutual TLS Certificate Trust & Pairing Store Card
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(engine.t("已配对设备：\(engine.trustedPeers.count) 台", "Trusted Peers: \(engine.trustedPeers.count)"))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                            Text(engine.t("本机指纹：\(engine.tlsFingerprint.prefix(36))…", "Local Fingerprint: \(engine.tlsFingerprint.prefix(36))…"))
                                .font(.system(size: 11.5))
                                .foregroundColor(Color(white: 0.64))
                        }
                        Spacer()
                        if !engine.trustedPeers.isEmpty {
                            Button(engine.t("清除全部配对记录", "Clear All Peers")) {
                                engine.clearTrustedPeers()
                            }
                            .buttonStyle(OmniSecondaryButtonStyle())
                        }
                    }

                    if engine.trustedPeers.isEmpty {
                        Text(engine.t("还没有配对设备。", "No paired devices yet."))
                            .font(.system(size: 11.5))
                            .foregroundColor(Color(white: 0.50))
                    } else {
                        Divider().background(Color(white: 0.24))
                        ForEach(engine.trustedPeers, id: \.fingerprint) { peer in
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.shield.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(Color(red: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.hostName.isEmpty ? engine.t("已配对设备", "Trusted Device") : peer.hostName)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundColor(.white)
                                    Text("\(peer.fingerprint.prefix(28))... · \(peer.pairedAtIso.prefix(10))")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(Color(white: 0.56))
                                }
                                Spacer()
                                Button(engine.t("移除", "Remove")) {
                                    engine.removeTrustedPeer(fingerprint: peer.fingerprint)
                                }
                                .buttonStyle(OmniSecondaryButtonStyle())
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .padding(14)
                .background(Color(red: 0x26 / 255.0, green: 0x26 / 255.0, blue: 0x29 / 255.0))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.22), lineWidth: 1))

                // Logs
                VStack(alignment: .leading, spacing: 8) {
                    Text(engine.t("运行日志", "Runtime Log"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(engine.logs.suffix(25), id: \.self) { line in
                                Text(line)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(Color(white: 0.68))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(height: 110)
                }
                .padding(14)
                .background(Color(red: 0x18 / 255.0, green: 0x18 / 255.0, blue: 0x1A / 255.0))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.20), lineWidth: 1))
            }
            .padding(24)
        }
    }
}

// MARK: - Sidebar Row, Animated Progress & Hover-Highlighted Button Styles

struct OmniSidebarNavRow: View {
    let page: OmniNavPage
    let isEnglish: Bool
    let selected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.iconName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(selected ? .white : (isHovered ? Color(white: 0.90) : Color(white: 0.70)))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(page.title(isEnglish))
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundColor(.white)
                    Text(page.subtitle(isEnglish))
                        .font(.system(size: 10))
                        .foregroundColor(selected ? Color(white: 0.85) : Color(white: 0.52))
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected
                          ? Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0)
                          : (isHovered ? Color.white.opacity(0.09) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovered)
    }
}

struct OmniSmoothLinearProgressBar: View {
    let progress: Double
    let isComplete: Bool

    @State private var displayedProgress: Double = 0.0
    @State private var shimmerPhase: CGFloat = -0.35

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let clamped = min(max(displayedProgress, 0.0), 1.0)
            let fillW = max(clamped > 0 ? 10 : 0, w * clamped)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(white: 0.14))
                Capsule()
                    .fill(
                        isComplete
                            ? LinearGradient(colors: [Color(red: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0), Color(red: 0x34 / 255.0, green: 0xC7 / 255.0, blue: 0x59 / 255.0)], startPoint: .leading, endPoint: .trailing)
                            : LinearGradient(colors: [Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0), Color(red: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0)], startPoint: .leading, endPoint: .trailing)
                    )
                    .overlay(
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.45), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: max(28, fillW * 0.42))
                        .offset(x: shimmerPhase * fillW)
                    )
                    .clipShape(Capsule())
                    .frame(width: fillW)
            }
        }
        .frame(height: 8)
        .onAppear {
            displayedProgress = min(max(progress, 0.0), 1.0)
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                shimmerPhase = 1.15
            }
        }
        .task(id: progress) {
            let target = min(max(progress, 0.0), 1.0)
            let delta = target - displayedProgress
            let steps = 18
            let stepDur: UInt64 = 16_000_000
            if abs(delta) < 0.002 {
                displayedProgress = target
                return
            }
            let inc = delta / Double(steps)
            for _ in 0..<steps {
                if Task.isCancelled { break }
                displayedProgress = min(max(displayedProgress + inc, 0.0), 1.0)
                try? await Task.sleep(nanoseconds: stepDur)
            }
            if !Task.isCancelled {
                displayedProgress = target
            }
        }
    }
}

struct OmniAnimatedSwitch: View {
    let label: String
    @Binding var isOn: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 7) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0) : Color(white: isHovered ? 0.30 : 0.23))
                    .overlay(Capsule().stroke(Color(white: isOn ? 0.0 : 0.36).opacity(isOn ? 0.0 : 1.0), lineWidth: 1))
                Circle()
                    .fill(Color.white)
                    .frame(width: 13, height: 13)
                    .padding(2)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, x: 0, y: 1)
            }
            .frame(width: 32, height: 17)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(white: isHovered ? 0.94 : 0.78))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
                isOn.toggle()
            }
        }
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.18), value: isOn)
    }
}

struct OmniPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0)
                            .opacity(configuration.isPressed ? 0.75 : (isHovered ? 0.92 : 1.0)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(red: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0).opacity(isHovered ? 0.85 : 0.0), lineWidth: 1.2)
                )
                .brightness(isHovered && !configuration.isPressed ? 0.08 : 0.0)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
    }
}

struct OmniSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(white: configuration.isPressed ? 0.22 : (isHovered ? 0.36 : 0.27)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(white: isHovered ? 0.56 : 0.36), lineWidth: isHovered ? 1.1 : 0.8)
                )
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(white: configuration.isPressed ? 0.24 : (isHovered ? 0.42 : 0.32)))
                )
                .onHover { isHovered = $0 }
        }
    }
}

/// Custom dark-themed segmented control so labels never fall back to light-mode black text.
struct OmniSegmentedPicker<SelectionValue: Hashable>: View {
    struct Option: Identifiable {
        let value: SelectionValue
        let title: String
        var id: SelectionValue { value }
    }

    @Binding var selection: SelectionValue
    let options: [Option]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { opt in
                SegmentedChip(
                    title: opt.title,
                    selected: selection == opt.value,
                    action: { selection = opt.value }
                )
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0x1A / 255.0, green: 0x1A / 255.0, blue: 0x1D / 255.0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(white: 0.26), lineWidth: 1)
        )
    }

    private struct SegmentedChip: View {
        let title: String
        let selected: Bool
        let action: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                    .foregroundColor(selected ? .white : (isHovered ? .white : Color(white: 0.82)))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected
                                  ? Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0)
                                  : (isHovered ? Color(white: 0.24) : Color.clear))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
        }
    }
}
