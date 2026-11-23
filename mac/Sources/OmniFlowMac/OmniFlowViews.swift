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
                        Text(engine.remoteFocusOnWindows
                             ? (engine.peerIsMac ? engine.t("对端 Mac", "Remote Mac") : "Windows")
                             : engine.t("Mac 本机", "This Mac"))
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
