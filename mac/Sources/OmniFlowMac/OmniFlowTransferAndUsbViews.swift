import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

