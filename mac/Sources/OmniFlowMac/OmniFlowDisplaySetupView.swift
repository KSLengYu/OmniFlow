import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
                            isEnglish: engine.isEnglish,
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
    let isEnglish: Bool
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
                    Text(isMac ? tr(isEnglish, node.isRemote ? "对方 Mac" : "本机 Mac", node.isRemote ? "Peer Mac" : "This Mac") : "Windows")
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
                        Button(engine.remoteFocusOnWindows
                               ? engine.t("切回本机 Mac", "Return to This Mac")
                               : engine.t("切到 \(engine.peerIsMac ? "对端 Mac" : "Windows") 控制", "Switch to \(engine.peerShortDisplayOs)")) {
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

