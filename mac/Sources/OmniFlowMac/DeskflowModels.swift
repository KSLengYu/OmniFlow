import Foundation
import AppKit

// MARK: - Control & Visual Effect Types

enum TransferSchemeMode: String, CaseIterable, Identifiable {
    case autoSmart = "auto"
    case schemeASeamless = "a"
    case schemeBPortal = "b"

    var id: String { rawValue }
}

enum KvmControlMode: String, CaseIterable, Identifiable {
    case dualActive = "dual"          // Both Mac & Windows can initiate control anytime
    case macMasterOnly = "mac_master" // Only Mac initiates control over Windows
    case winMasterOnly = "win_master" // Only Windows initiates control over Mac

    var id: String { rawValue }
}

enum KeymapProfileMode: String, CaseIterable, Identifiable {
    case hybrid = "hybrid"
    case deskflowNative = "deskflow_native"
    case omniflowMacHabit = "omniflow_mac"

    var id: String { rawValue }
}

enum PortalEffectStyle: String, CaseIterable, Identifiable {
    case blackHole = "blackhole"  // Screen-Edge Wall Distortion / Pass-Through (屏幕边缘引力墙 · 穿墙传输)
    case floatingCube = "cube"    // Customizable screen-edge mini cube dock (自定义边缘小方块)

    var id: String { rawValue }
}

enum ScreenEdgeSide: String, CaseIterable, Identifiable {
    case right = "right"
    case left = "left"
    case top = "top"
    case bottom = "bottom"

    var id: String { rawValue }
}

enum DragHandoffPolicy {
    static let defaultContinuousMaxSeconds: Double = 1.5
    static let maxContinuousSizeBytes: UInt64 = 64 * 1024 * 1024
    static let estimationScanBudgetCount: Int = 3000
    static let fallbackUsbBytesPerSec: Double = 60.0 * 1024.0 * 1024.0
    static let fallbackLanBytesPerSec: Double = 45.0 * 1024.0 * 1024.0
    static let fallbackWifiBytesPerSec: Double = 18.0 * 1024.0 * 1024.0
    static let hoverCancelDistancePx: CGFloat = 56.0
    static let requiredDiskMarginBytes: UInt64 = 32 * 1024 * 1024
}

enum DragEstimateConfidence: String, Equatable {
    case ready
    case partialOrUnreadable
    case noPeer
}

struct DragEstimationResult: Equatable {
    let urls: [URL]
    let displayTitle: String
    let totalBytes: UInt64?
    let sizeText: String
    let estimatedSeconds: Double?
    let confidence: DragEstimateConfidence
    let recommendShelf: Bool
    let statusHint: String
    let canSubmitOnShelf: Bool
}

enum ShelfDirection: String, Equatable {
    case outgoing
    case incoming
}

enum ShelfItemStatus: String, Equatable {
    case transferring
    case ready
    case failed
}

struct ShelfTransferItem: Identifiable, Equatable {
    let id: String
    let direction: ShelfDirection
    var status: ShelfItemStatus
    var title: String
    var sizeText: String
    var itemCount: Int
    var progress: Double
    var speedMbps: Double
    var channelTag: String
    var errorText: String?
    var sourcePaths: [String]
    var localPaths: [String]
    var timestamp: Date

    var primaryLocalURL: URL? {
        guard let p = localPaths.first, !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p)
    }
}

enum PortalPhase: Equatable {
    case idle
    case hoverExpand(
        fileName: String? = nil,
        fileSize: String? = nil,
        isLargeFile: Bool = false,
        estSec: Double = 0,
        hint: String? = nil,
        canSubmit: Bool = true
    )
    case suckingIn(progress: Double, fileName: String, fileSize: String, speedMbps: Double, channelTag: String)
    case emergingOut(progress: Double, fileName: String, fileSize: String, speedMbps: Double, channelTag: String)
    case completed(fileName: String, fileSize: String, savedURL: URL?)
}

struct ReceivedFileItem: Identifiable, Equatable {
    let id: String
    let fileName: String
    let fileSize: String
    let savedURL: URL
    let timestamp: Date
    let isArchiveOrFolder: Bool
}

// MARK: - Multi-NIC Smart Channel Model

enum NicSecurityMode: String {
    case trustedUsbP2P = "RAW_P2P"   // MacBridge USB point-to-point: 0 encryption overhead
    case lanTls13 = "TLS_1_3"        // LAN Wi-Fi / Ethernet: Deskflow-grade TLS 1.3 encryption
}

struct NicChannelItem: Identifiable, Equatable {
    let id: String
    let ifaceName: String
    let displayName: String
    let localIp: String
    let peerIp: String
    let isUsbBridge: Bool
    var online: Bool
    var manuallyDisconnected: Bool
    var rttMs: Double?
    var estBandwidthMbps: Double
    var securityMode: NicSecurityMode
    var isRecommendedControl: Bool
    var isRecommendedData: Bool
    var enabledForMultipath: Bool

    var channelKey: String {
        if isUsbBridge { return "usb" }
        return !peerIp.isEmpty ? "\(localIp)->\(peerIp)" : localIp
    }

    static func canonicalChannelKey(ifaceName: String, localIp: String, isUsb: Bool, peerIp: String? = nil) -> String {
        if isUsb || MacBridgeSubnet.isUsbBridgeIp(localIp)
            || ifaceName == "USB-C NCM" || ifaceName == "USB-C" || ifaceName == "MacBridge" || ifaceName == "USB-NCM" {
            return "usb"
        }
        if let peer = peerIp, !peer.isEmpty, !localIp.isEmpty, localIp != "auto" {
            return "\(localIp)->\(peer)"
        }
        return (!localIp.isEmpty && localIp != "auto") ? localIp : ifaceName
    }
}

// MARK: - Per-Monitor Independent 2D Spatial Topology Model

enum PeerOSKind: String, Codable {
    case mac = "macOS"
    case windows = "Windows"
}

struct IndependentDisplayNode: Identifiable, Codable, Equatable {
    var id: String
    var displayIndex: Int
    var name: String
    var osKind: PeerOSKind
    var isRemote: Bool = false
    var widthPx: Int
    var heightPx: Int
    var scaleFactor: Double
    var isPrimary: Bool
    var boundsX: Int = 0
    var boundsY: Int = 0
    /// Top-left position (in points) on the 2D Arrange Displays workspace canvas
    var canvasX: CGFloat
    var canvasY: CGFloat

    var logicalWidth: Double {
        Double(max(640, widthPx)) / max(1.0, scaleFactor)
    }

    var logicalHeight: Double {
        Double(max(480, heightPx)) / max(1.0, scaleFactor)
    }

    var aspectWidth: CGFloat {
        let clamped = min(3840.0, max(1024.0, logicalWidth))
        return CGFloat((clamped * 0.068).rounded())
    }

    var aspectHeight: CGFloat {
        guard logicalWidth > 0 else { return 96 }
        let rawH = Double(aspectWidth) * (logicalHeight / logicalWidth)
        return CGFloat(min(150.0, max(66.0, rawH.rounded())))
    }

    var rect: CGRect {
        CGRect(x: canvasX, y: canvasY, width: aspectWidth, height: aspectHeight)
    }
}

// MARK: - Cross-OS Semantic Hotkey Translation Rule

struct SemanticHotkeyRule: Identifiable, Codable, Equatable {
    var id: String
    var titleZh: String
    var titleEn: String
    var macTrigger: String
    var winAction: String
    var actionCode: String
    var enabled: Bool
    var direction: String = "mac_to_win"
    var isGesture: Bool = false

    func title(isEnglish: Bool) -> String { isEnglish ? titleEn : titleZh }

    func triggerText(isEnglish: Bool) -> String {
        guard isEnglish else { return macTrigger }
        switch macTrigger {
        case "3指按住移动": return "3-Finger Drag"
        case "Win 3指按住移动": return "Win 3-Finger Drag"
        default: return macTrigger
        }
    }

    func actionText(isEnglish: Bool) -> String {
        guard isEnglish else { return winAction }
        switch winAction {
        case "Windows 左键拖移": return "Windows Left Drag"
        case "Mac 左键按住拖移": return "Mac Left Drag"
        default: return winAction
        }
    }
}
