import Foundation
import AppKit
import SwiftUI
import Combine
import CryptoKit
import UniformTypeIdentifiers
import Darwin

@MainActor
extension DeskflowEngine {
    // MARK: - Persistence

    func loadPrefs() {
        isLoadingPrefs = true
        defer { isLoadingPrefs = false }
        let d = UserDefaults.standard
        if let rawScheme = d.string(forKey: "mb_df_scheme"), let v = TransferSchemeMode(rawValue: rawScheme) {
            transferSchemeMode = v
        }
        if let rawStyle = d.string(forKey: "mb_df_style"), let v = PortalEffectStyle(rawValue: rawStyle) {
            portalEffectStyle = v
        }
        if let rawEdge = d.string(forKey: "mb_df_edge"), let v = ScreenEdgeSide(rawValue: rawEdge) {
            portalEdgeSide = v
        }
        if d.object(forKey: "mb_df_offset") != nil {
            portalEdgeOffset = min(max(d.double(forKey: "mb_df_offset"), 0.05), 0.95)
        }
        if d.object(forKey: "mb_df_overlay") != nil {
            portalOverlayEnabled = d.bool(forKey: "mb_df_overlay")
        }
        if d.object(forKey: "mb_df_multipath") != nil {
            multipathEnabled = d.bool(forKey: "mb_df_multipath")
        }
        if d.object(forKey: "mb_df_kvm_enabled") != nil {
            kvmEnabled = d.bool(forKey: "mb_df_kvm_enabled")
        }
        if d.object(forKey: "mb_df_edge_switch") != nil {
            edgeSwitchEnabled = d.bool(forKey: "mb_df_edge_switch")
        }
        if d.object(forKey: "mb_df_hotkey_switch") != nil {
            hotkeySwitchEnabled = d.bool(forKey: "mb_df_hotkey_switch")
        }
        if d.object(forKey: "mb_df_clip_sync") != nil {
            clipboardSyncEnabled = d.bool(forKey: "mb_df_clip_sync")
        }
        if let rawCtrl = d.string(forKey: "mb_df_ctrl_mode"), let v = KvmControlMode(rawValue: rawCtrl) {
            kvmControlMode = v
        }
        keymapProfile = .hybrid
        if let savedIds = d.array(forKey: "mb_df_enabled_rules") as? [String] {
            let set = Set(savedIds)
            for i in hotkeyRules.indices {
                hotkeyRules[i].enabled = set.contains(hotkeyRules[i].id)
            }
        }
        if !d.bool(forKey: "mb_df_tp_optin_v2") {
            for i in hotkeyRules.indices where hotkeyRules[i].isGesture {
                hotkeyRules[i].enabled = false
            }
            d.set(true, forKey: "mb_df_tp_optin_v2")
            d.set(hotkeyRules.filter(\.enabled).map(\.id), forKey: "mb_df_enabled_rules")
        }
        if let lang = d.string(forKey: "mb_df_app_language") {
            isEnglish = (lang == "en")
        }
        d.removeObject(forKey: "mb_df_pinned_data_nic")
        if let peer = d.string(forKey: "mb_df_manual_peer"), !peer.isEmpty {
            manualPeerIp = peer
        }
        if let savedPos = d.dictionary(forKey: "mb_df_saved_display_positions") as? [String: [Double]] {
            savedDisplayPositions = savedPos
            for (id, coords) in savedPos where coords.count == 2 {
                syncedRemotePositions[id] = CGPoint(x: coords[0], y: coords[1])
            }
        }
    }

    func savePrefs() {
        guard !isLoadingPrefs else { return }
        let d = UserDefaults.standard
        d.set(transferSchemeMode.rawValue, forKey: "mb_df_scheme")
        d.set(portalEffectStyle.rawValue, forKey: "mb_df_style")
        d.set(portalEdgeSide.rawValue, forKey: "mb_df_edge")
        d.set(portalEdgeOffset, forKey: "mb_df_offset")
        d.set(portalOverlayEnabled, forKey: "mb_df_overlay")
        d.set(multipathEnabled, forKey: "mb_df_multipath")
        d.set(kvmEnabled, forKey: "mb_df_kvm_enabled")
        d.set(edgeSwitchEnabled, forKey: "mb_df_edge_switch")
        d.set(hotkeySwitchEnabled, forKey: "mb_df_hotkey_switch")
        d.set(clipboardSyncEnabled, forKey: "mb_df_clip_sync")
        d.set(kvmControlMode.rawValue, forKey: "mb_df_ctrl_mode")
        d.set(keymapProfile.rawValue, forKey: "mb_df_keymap")
        d.set(hotkeyRules.filter(\.enabled).map(\.id), forKey: "mb_df_enabled_rules")
        d.set(manualPeerIp, forKey: "mb_df_manual_peer")
        d.set(isEnglish ? "en" : "zh", forKey: "mb_df_app_language")
        if !savedDisplayPositions.isEmpty {
            d.set(savedDisplayPositions, forKey: "mb_df_saved_display_positions")
        }
    }

    func saveDisplayArrangement(silent: Bool = false) {
        for n in displayNodes {
            syncedRemotePositions[n.id] = CGPoint(x: n.canvasX, y: n.canvasY)
            savedDisplayPositions[n.id] = [Double(n.canvasX), Double(n.canvasY)]
        }
        savePrefs()
        UserDefaults.standard.synchronize()
        if !silent {
            scheduleTopologySyncBroadcast()
            appendLog("[Display] 已保存当前屏幕排列位置 (\(displayNodes.count) 块)")
            let badge = t("已保存位置", "Layout Saved")
            displaySaveStatusText = badge
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                if self?.displaySaveStatusText == badge {
                    self?.displaySaveStatusText = ""
                }
            }
        }
    }

    func saveAllSettingsManual() {
        savePrefs()
        broadcastConfigSync()
        UserDefaults.standard.synchronize()
        appendLog("[Config] 已保存快捷键映射与控制设置")
        let badge = t("已保存设置", "Settings Saved")
        settingsSaveStatusText = badge
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.settingsSaveStatusText == badge {
                self?.settingsSaveStatusText = ""
            }
        }
    }


    // MARK: - Multi-NIC Discovery & Smart Control/Data Plane Scoring


    func toggleNicMultipath(_ item: NicChannelItem) {
        let key = item.channelKey
        let isCurrentlyDisabled = disabledMultipathNics.contains(key)
        if isCurrentlyDisabled {
            disabledMultipathNics.remove(key)
            appendLog("[Route] 已启用网卡「\(item.ifaceName) (\(item.localIp))」参与多网卡并发")
        } else {
            disabledMultipathNics.insert(key)
            appendLog("[Route] 已将网卡「\(item.ifaceName) (\(item.localIp))」移出并发池")
        }
        refreshAllNicChannels()
    }

    func refreshAllNicChannels() {
        accessibilityGranted = MacKvmController.shared.hasAccessibilityPermission
        let liveLinks = DeskflowTransport.shared.activeLinksSnapshot()
        peerConnectedCount = liveLinks.count

        var discovered: [NicChannelItem] = []

        // 1. Add all real live PeerLinkSessions first (keyed per local<->peer channel so multi-peer links on one NIC all display)
        for link in liveLinks {
            let resolvedLocal = link.isUsbBridge
                ? ((link.localIp == "auto" || link.localIp.isEmpty) ? usbNcmLocalIp : link.localIp)
                : link.localIp
            let canonKey = NicChannelItem.canonicalChannelKey(ifaceName: link.ifaceName, localIp: resolvedLocal, isUsb: link.isUsbBridge, peerIp: link.peerIp)
            if discovered.contains(where: { $0.id == canonKey }) {
                continue
            }
            let isDisc = DeskflowTransport.shared.isIfaceDisconnected(link.ifaceName)
                || DeskflowTransport.shared.isIfaceDisconnected(resolvedLocal)
                || DeskflowTransport.shared.isIfaceDisconnected(canonKey)
                || (link.isUsbBridge && DeskflowTransport.shared.isIfaceDisconnected("usb"))
            let mpEnabled = !disabledMultipathNics.contains(canonKey)
            let label = link.isUsbBridge
                ? t("USB-C 直连（未加密）", "USB-C Direct (Raw P2P)")
                : t("局域网通道 (\(link.ifaceName) · TLS 1.3 已连接)", "LAN (\(link.ifaceName) · TLS 1.3)")
            discovered.append(
                NicChannelItem(
                    id: canonKey,
                    ifaceName: link.ifaceName,
                    displayName: label,
                    localIp: resolvedLocal,
                    peerIp: link.peerIp,
                    isUsbBridge: link.isUsbBridge,
                    online: !isDisc,
                    manuallyDisconnected: isDisc,
                    rttMs: link.rttMs ?? (link.isUsbBridge ? 0.35 : 1.50),
                    estBandwidthMbps: link.estBandwidthMbps,
                    securityMode: link.isUsbBridge ? .trustedUsbP2P : .lanTls13,
                    isRecommendedControl: false,
                    isRecommendedData: false,
                    enabledForMultipath: mpEnabled
                )
            )
        }

        // 2. Also list local standby NICs not yet paired with an active link
        let localNics = DeskflowTransport.shared.enumerateLocalIPv4()
        usbNcmDetected = localNics.contains(where: { MacBridgeSubnet.isUsbBridgeIp($0.ip) })
        for nic in localNics {
            let isUsb = MacBridgeSubnet.isUsbBridgeIp(nic.ip)
            let canonKey = NicChannelItem.canonicalChannelKey(ifaceName: nic.iface, localIp: nic.ip, isUsb: isUsb)
            if discovered.contains(where: { $0.isUsbBridge == isUsb && (isUsb || $0.localIp == nic.ip || $0.id == canonKey) }) { continue }

            let isDisc = DeskflowTransport.shared.isIfaceDisconnected(nic.iface)
                || DeskflowTransport.shared.isIfaceDisconnected(nic.ip)
                || (isUsb && DeskflowTransport.shared.isIfaceDisconnected("usb"))
            let mpEnabled = !disabledMultipathNics.contains(canonKey)
            let isWifi = (nic.iface == "en0")
            discovered.append(
                NicChannelItem(
                    id: canonKey,
                    ifaceName: nic.iface,
                    displayName: isDisc
                        ? t("\(nic.iface) (已手动断开 · 点击重连恢复)", "\(nic.iface) (Disconnected · Click Reconnect)")
                        : (isUsb ? t("USB-C 直连（\(nic.iface)）", "USB-C Direct (\(nic.iface))")
                           : (isWifi ? t("Wi-Fi 无线网卡 (\(nic.iface) · 在线)", "Wi-Fi (\(nic.iface) · Online)")
                              : t("有线/扩展网卡 (\(nic.iface) · 在线)", "Wired Ethernet (\(nic.iface) · Online)"))),
                    localIp: nic.ip,
                    peerIp: isUsb ? usbNcmPeerIp : manualPeerIp,
                    isUsbBridge: isUsb,
                    online: false,
                    manuallyDisconnected: isDisc,
                    rttMs: nil,
                    estBandwidthMbps: isUsb ? 2400.0 : (isWifi ? 1200.0 : 2500.0),
                    securityMode: isUsb ? .trustedUsbP2P : .lanTls13,
                    isRecommendedControl: false,
                    isRecommendedData: false,
                    enabledForMultipath: mpEnabled
                )
            )
        }

        if !discovered.contains(where: { $0.id == "usb" }) {
            let isUsbDisc = DeskflowTransport.shared.isIfaceDisconnected("USB-C NCM")
                || DeskflowTransport.shared.isIfaceDisconnected(usbNcmLocalIp)
                || DeskflowTransport.shared.isIfaceDisconnected("usb")
            let mpEnabled = !disabledMultipathNics.contains("usb")
            discovered.append(
                NicChannelItem(
                    id: "usb",
                    ifaceName: "USB-C NCM",
                    displayName: isUsbDisc
                        ? t("USB-C 直连引擎 (已手动断开)", "USB-C Direct Engine (Paused)")
                        : t("USB-C 直连（未连接）", "USB-C Direct (Standby)"),
                    localIp: usbNcmLocalIp,
                    peerIp: usbNcmPeerIp,
                    isUsbBridge: true,
                    online: false,
                    manuallyDisconnected: isUsbDisc,
                    rttMs: nil,
                    estBandwidthMbps: 2400.0,
                    securityMode: .trustedUsbP2P,
                    isRecommendedControl: false,
                    isRecommendedData: false,
                    enabledForMultipath: mpEnabled
                )
            )
        }

        // Fixed deterministic row ordering so rows never jump around on RTT jitter
        discovered.sort { a, b in
            if a.isUsbBridge != b.isUsbBridge { return a.isUsbBridge }
            let aWifi = a.ifaceName == "en0"
            let bWifi = b.ifaceName == "en0"
            if aWifi != bWifi { return !aWifi }
            return a.localIp < b.localIp
        }

        // Update USB-C Connection Progress Bar & MacBridge-style Telemetry
        let liveUsbLink = liveLinks.first(where: { $0.isUsbBridge })
        usbRxFrames = liveUsbLink?.rxFrames ?? 0
        usbTxFrames = liveUsbLink?.txFrames ?? 0
        let usbIfaces = localNics.filter { MacBridgeSubnet.isUsbBridgeIp($0.ip) }
        let usbIfaceName = liveUsbLink?.ifaceName ?? usbIfaces.first?.iface ?? t("未接入", "Unplugged")

        if let liveUsb = discovered.first(where: { $0.isUsbBridge && $0.online && !$0.manuallyDisconnected }) {
            usbConnectProgress = 1.0
            let rttStr = liveUsb.rttMs.map { String(format: "%.2f ms", $0) } ?? "0.35 ms"
            usbHeadline = t("USB-C 直连隧道已运行", "USB-C Direct Tunnel Active")
            usbSubline = t("双向控制与文件直传已就绪（点对点免加密 · \(liveUsb.localIp) ↔ \(liveUsb.peerIp)）", "Bidirectional KVM & file transfer ready (P2P Raw · \(liveUsb.localIp) ↔ \(liveUsb.peerIp))")
            usbDriverStatusText = t("Apple NCM (\(usbIfaceName)) · 已握手", "Apple NCM (\(usbIfaceName)) · Connected")
            usbStatusText = t("USB-C 点对点直连已就绪 (\(liveUsb.localIp) ↔ \(liveUsb.peerIp) · 延迟 \(rttStr))", "USB-C Direct ready (\(liveUsb.localIp) ↔ \(liveUsb.peerIp) · RTT \(rttStr))")
            usbActionHint = t("隧道已激活 · RX \(usbRxFrames) 帧 / TX \(usbTxFrames) 帧 · RTT \(rttStr)", "Tunnel active · RX \(usbRxFrames) / TX \(usbTxFrames) · RTT \(rttStr)")
        } else if let pausedUsb = discovered.first(where: { $0.isUsbBridge && $0.manuallyDisconnected }) {
            usbConnectProgress = 0.0
            usbHeadline = t("USB-C 通道已手动断开", "USB-C Channel Disconnected")
            usbSubline = t("点击右侧「立即连接 USB」可随时恢复点对点直连", "Click Reconnect on the right to restore USB-C P2P anytime")
            usbDriverStatusText = usbNcmDetected
                ? t("Apple NCM (\(usbIfaceName)) · 已暂停", "Apple NCM (\(usbIfaceName)) · Paused")
                : t("待插线 / 已暂停", "Unplugged / Paused")
            usbStatusText = t("已暂停：\(pausedUsb.localIp) ↔ \(pausedUsb.peerIp)", "Paused: \(pausedUsb.localIp) ↔ \(pausedUsb.peerIp)")
            usbActionHint = t("通道处于断开状态，不影响 LAN/Wi-Fi 并发通道", "USB paused; LAN/Wi-Fi channels keep running")
        } else if usbNcmDetected {
            usbConnectProgress = min(0.92, max(0.32, usbConnectProgress + 0.08))
            usbHeadline = t("正在建立 USB-C 直连...", "Establishing USB-C Direct Link...")
            usbSubline = t("本机 \(usbIfaceName) 已获取 10.13.37.x，正在等待 Windows 端 NCM 驱动与端口就绪", "Local \(usbIfaceName) assigned 10.13.37.x; waiting for Windows NCM driver & port")
            usbDriverStatusText = t("Apple NCM (\(usbIfaceName)) · 就绪", "Apple NCM (\(usbIfaceName)) · Ready")
            usbStatusText = t("已识别 USB-C NCM 虚拟网卡，正在与 Windows 端握手建连 (10.13.37.x)...", "USB-C NCM detected, handshaking with Windows (10.13.37.x)...")
            usbActionHint = t("若 Windows 端刚启动，请点击 Windows 端「一键连接 USB」完成驱动绑定", "Click Start USB Direct on Windows to finish WinUSB driver binding")
        } else {
            if !usbActionInProgress { usbConnectProgress = 0.0 }
            usbHeadline = t("等待 USB-C 直连", "Waiting for USB-C Direct Link")
            usbSubline = t("插入 USB-C 数据线，并在 Windows 端启动 USB 直连，Mac 端无需额外驱动即可自动协商", "Plug in a USB-C cable and start USB Direct on Windows. macOS works driver-free.")
            usbDriverStatusText = t("未检测到 USB-C NCM 网口", "No USB-C NCM interface detected")
            usbStatusText = t("待插线：插入 USB-C 数据线并开启 Windows 端 USB 引擎后将自动连接", "Standby: connect USB-C cable and start Windows USB tunnel")
            if !usbActionInProgress {
                usbActionHint = t("Mac 端原生支持 USB-C NCM 免驱直连，无需清理或安装驱动", "macOS natively supports driver-free USB-C NCM")
            }
        }

        // Score online channels with 0.5ms hysteresis to avoid recommendation pill flapping
        let pool = globalPaused ? [] : discovered.filter { $0.online && !$0.manuallyDisconnected }
        let bestCand = pool.min(by: { ($0.rttMs ?? 999) < ($1.rttMs ?? 999) })
        var minRttId = bestCand?.id
        if let prevId = lastRecommendedControlKey,
           let prevItem = pool.first(where: { $0.id == prevId }),
           let cand = bestCand,
           cand.id != prevId {
            let prevRtt = prevItem.rttMs ?? 999
            let candRtt = cand.rttMs ?? 999
            if (prevRtt - candRtt) < 0.5 && !(cand.isUsbBridge && !prevItem.isUsbBridge) {
                minRttId = prevId
            }
        }
        lastRecommendedControlKey = minRttId
        let maxBwId = pool.max(by: { $0.estBandwidthMbps < $1.estBandwidthMbps })?.id

        for i in discovered.indices {
            discovered[i].isRecommendedControl = (minRttId != nil && discovered[i].id == minRttId)
            discovered[i].isRecommendedData = (maxBwId != nil && discovered[i].id == maxBwId)
        }

        if nicChannels != discovered {
            nicChannels = discovered
        }
    }

    var activeControlChannelName: String {
        if globalPaused {
            return t("已断开", "Paused")
        }
        if let ctrl = nicChannels.first(where: { $0.online && !$0.manuallyDisconnected && $0.isRecommendedControl })
            ?? nicChannels.first(where: { $0.online && !$0.manuallyDisconnected }) {
            let ms = ctrl.rttMs.map { String(format: "%.2fms", $0) } ?? t("已连接", "Online")
            return "\(ctrl.ifaceName) (\(ms))"
        }
        return t("未连接", "Disconnected")
    }

    var currentControlLinkRttMs: Double? {
        guard !globalPaused else { return nil }
        return nicChannels.first(where: { $0.online && $0.isRecommendedControl && !$0.manuallyDisconnected })?.rttMs
            ?? nicChannels.filter { $0.online && !$0.manuallyDisconnected }.compactMap(\.rttMs).min()
    }

    var activeDataChannelSummary: String {
        if globalPaused {
            return t("已断开", "Paused")
        }
        let active = nicChannels.filter { $0.online && !$0.manuallyDisconnected && $0.enabledForMultipath }
        if multipathEnabled && active.count > 1 {
            let sumMbps = active.reduce(0.0) { $0 + $1.estBandwidthMbps }
            return isEnglish
                ? String(format: "%d-NIC Multipath (%.0f Mbps)", active.count, sumMbps)
                : String(format: "%d通道并发 (%.0f Mbps)", active.count, sumMbps)
        }
        if let best = active.max(by: { $0.estBandwidthMbps < $1.estBandwidthMbps })
            ?? nicChannels.filter({ $0.online && !$0.manuallyDisconnected }).max(by: { $0.estBandwidthMbps < $1.estBandwidthMbps }) {
            return "\(best.ifaceName) (\(Int(best.estBandwidthMbps)) Mbps)"
        }
        return t("未连接", "Disconnected")
    }

    var effectiveTransferMbps: Double {
        let enabled = nicChannels.filter { $0.online && $0.enabledForMultipath }
        if multipathEnabled && enabled.count > 1 {
            return max(400, enabled.reduce(0.0) { $0 + $1.estBandwidthMbps })
        }
        return max(400, enabled.map(\.estBandwidthMbps).max() ?? nicChannels.map(\.estBandwidthMbps).max() ?? 2400)
    }

}
