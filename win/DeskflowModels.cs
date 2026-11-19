using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Media;

namespace MacBridgeUI;

// MARK: - Wire Protocol Constants & DTOs

public static class DeskflowPorts
{
    public const int RawUsbTcp = 24810;
    public const int LanTlsTcp = 24811;
    public const int UdpDiscovery = 24812;
}

public static class DeskflowUsbConstants
{
    public const string WinUsbIp = "10.13.37.2";
    public const string MacUsbIp = "10.13.37.1";
    public const int DefaultUsbSpeedMbps = 3200;
}

public enum DeskflowMsgType : byte
{
    Hello = 0x01,
    Ping = 0x02,
    Pong = 0x03,
    ClipboardText = 0x04,
    PortalSync = 0x05,
    FileOffer = 0x06,
    FileChunk = 0x07,
    FileComplete = 0x08,
    FileAck = 0x09,
    DataStreamBind = 0x0A,
    ClipboardImage = 0x0B,

    MouseMoveAbs = 0x10,
    MouseButton = 0x11,
    MouseScroll = 0x12,
    KeyEvent = 0x13,
    SemanticHotkey = 0x14,
    KvmFocusSwitch = 0x15,
    TopologyUpdate = 0x16,
    ConfigSync = 0x17
}

public sealed class WireMonitorDto
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("displayIndex")] public int DisplayIndex { get; set; }
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("osKind")] public string OsKind { get; set; } = "Windows";
    [JsonPropertyName("widthPx")] public int WidthPx { get; set; }
    [JsonPropertyName("heightPx")] public int HeightPx { get; set; }
    [JsonPropertyName("scaleFactor")] public double ScaleFactor { get; set; } = 1.0;
    [JsonPropertyName("isPrimary")] public bool IsPrimary { get; set; }
    [JsonPropertyName("boundsX")] public int BoundsX { get; set; }
    [JsonPropertyName("boundsY")] public int BoundsY { get; set; }
}

public sealed class WireHelloPayload
{
    [JsonPropertyName("os")] public string Os { get; set; } = "Windows";
    [JsonPropertyName("host")] public string Host { get; set; } = "";
    [JsonPropertyName("fingerprint")] public string Fingerprint { get; set; } = "";
    [JsonPropertyName("ips")] public List<string> Ips { get; set; } = new();
    [JsonPropertyName("usbIps")] public List<string> UsbIps { get; set; } = new();
    [JsonPropertyName("monitors")] public List<WireMonitorDto> Monitors { get; set; } = new();
}

public sealed class WireBeaconPayload
{
    [JsonPropertyName("type")] public string Type { get; set; } = "BEACON";
    [JsonPropertyName("os")] public string Os { get; set; } = "Windows";
    [JsonPropertyName("host")] public string Host { get; set; } = "";
    [JsonPropertyName("rawPort")] public int RawPort { get; set; } = DeskflowPorts.RawUsbTcp;
    [JsonPropertyName("tlsPort")] public int TlsPort { get; set; } = DeskflowPorts.LanTlsTcp;
    [JsonPropertyName("ips")] public List<string> Ips { get; set; } = new();
    [JsonPropertyName("usbIps")] public List<string> UsbIps { get; set; } = new();
    [JsonPropertyName("fingerprint")] public string Fingerprint { get; set; } = "";
}

public sealed class WirePortalSyncPayload
{
    [JsonPropertyName("transferId")] public string TransferId { get; set; } = "";
    [JsonPropertyName("style")] public string Style { get; set; } = "blackhole";
    [JsonPropertyName("edge")] public string Edge { get; set; } = "left";
    [JsonPropertyName("offset")] public double Offset { get; set; } = 0.55;
    [JsonPropertyName("phase")] public string Phase { get; set; } = "idle";
    [JsonPropertyName("progress")] public double Progress { get; set; }
    [JsonPropertyName("fileName")] public string FileName { get; set; } = "";
    [JsonPropertyName("fileSize")] public string FileSize { get; set; } = "";
    [JsonPropertyName("speedMbps")] public double SpeedMbps { get; set; }
    [JsonPropertyName("channelTag")] public string ChannelTag { get; set; } = "";
}

public sealed class WireMonitorLayoutEntry
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("canvasX")] public double CanvasX { get; set; }
    [JsonPropertyName("canvasY")] public double CanvasY { get; set; }
    [JsonPropertyName("displayIndex")] public int? DisplayIndex { get; set; }
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("osKind")] public string? OsKind { get; set; }
    [JsonPropertyName("widthPx")] public int? WidthPx { get; set; }
    [JsonPropertyName("heightPx")] public int? HeightPx { get; set; }
    [JsonPropertyName("scaleFactor")] public double? ScaleFactor { get; set; }
    [JsonPropertyName("isPrimary")] public bool? IsPrimary { get; set; }
}

public sealed class WireTopologySyncPayload
{
    [JsonPropertyName("senderOs")] public string SenderOs { get; set; } = "Windows";
    [JsonPropertyName("timestamp")] public double Timestamp { get; set; }
    [JsonPropertyName("items")] public List<WireMonitorLayoutEntry> Items { get; set; } = new();
}

public sealed class WireConfigSyncPayload
{
    [JsonPropertyName("senderOs")] public string SenderOs { get; set; } = "Windows";
    [JsonPropertyName("timestamp")] public double Timestamp { get; set; }
    [JsonPropertyName("controlMode")] public string ControlMode { get; set; } = "dual";
    [JsonPropertyName("keymapProfile")] public string KeymapProfile { get; set; } = "hybrid";
    [JsonPropertyName("enabledRuleIds")] public List<string> EnabledRuleIds { get; set; } = new();
}

public sealed class WireFileOfferPayload
{
    [JsonPropertyName("transferId")] public string TransferId { get; set; } = "";
    [JsonPropertyName("fileName")] public string FileName { get; set; } = "";
    [JsonPropertyName("totalBytes")] public ulong TotalBytes { get; set; }
    [JsonPropertyName("chunkSize")] public int ChunkSize { get; set; } = 256 * 1024;
    [JsonPropertyName("totalChunks")] public int TotalChunks { get; set; } = 1;
    [JsonPropertyName("scheme")] public string Scheme { get; set; } = "a";
    [JsonPropertyName("style")] public string Style { get; set; } = "blackhole";
    [JsonPropertyName("edge")] public string Edge { get; set; } = "left";
    [JsonPropertyName("offset")] public double Offset { get; set; } = 0.55;
    [JsonPropertyName("isDirectoryZip")] public bool IsDirectoryZip { get; set; }
    [JsonPropertyName("isClipboardItem")] public bool IsClipboardItem { get; set; }
    [JsonPropertyName("isClipboardMulti")] public bool IsClipboardMulti { get; set; }
    [JsonPropertyName("requiredFreeBytes")] public ulong? RequiredFreeBytes { get; set; }
    [JsonPropertyName("batchItemCount")] public int? BatchItemCount { get; set; }
    [JsonPropertyName("isBatchBundle")] public bool IsBatchBundle { get; set; }
}

public sealed class WireFileCompletePayload
{
    [JsonPropertyName("transferId")] public string TransferId { get; set; } = "";
    [JsonPropertyName("sha256")] public string Sha256 { get; set; } = "";
}

public sealed class WireFileAckPayload
{
    [JsonPropertyName("transferId")] public string TransferId { get; set; } = "";
    [JsonPropertyName("ok")] public bool Ok { get; set; }
    [JsonPropertyName("savedPath")] public string SavedPath { get; set; } = "";
    [JsonPropertyName("error")] public string? Error { get; set; }
}

public sealed class WireSemanticHotkeyPayload
{
    [JsonPropertyName("action")] public string Action { get; set; } = "";
}

public sealed class WireKvmFocusPayload
{
    [JsonPropertyName("targetOs")] public string TargetOs { get; set; } = "";
    [JsonPropertyName("monitorIndex")] public int MonitorIndex { get; set; }
    [JsonPropertyName("normX")] public double NormX { get; set; }
    [JsonPropertyName("normY")] public double NormY { get; set; }
}

// MARK: - Domain & UI Models

public enum TransferSchemeMode
{
    AutoSmart,
    SchemeASeamless,
    SchemeBPortal
}

public enum PortalEffectStyle
{
    BlackHole,
    FloatingCube
}

public enum ScreenEdgeSide
{
    Right,
    Left,
    Top,
    Bottom
}

public enum PortalTransferPhase
{
    Idle,
    HoverExpand,
    SuckingIn,
    EmergingOut,
    Completed
}

public enum KvmControlMode
{
    DualActive,
    MacMasterOnly,
    WinMasterOnly
}

public enum KeymapProfileMode
{
    Hybrid,
    DeskflowNative,
    OmniflowMacHabit
}

public sealed class NicChannelItem : INotifyPropertyChanged
{
    private static readonly SolidColorBrush DotGreen = FrozenBrush(0x30, 0xD1, 0x58);
    private static readonly SolidColorBrush DotOrange = FrozenBrush(0xFF, 0x9F, 0x0A);
    private static readonly SolidColorBrush DotGray = FrozenBrush(0x66, 0x66, 0x6C);
    private static readonly SolidColorBrush RttNormal = FrozenBrush(0xCC, 0xCC, 0xCC);
    private static readonly SolidColorBrush BtnPrimaryBg = FrozenBrush(0x0A, 0x84, 0xFF);
    private static readonly SolidColorBrush BtnPrimaryBd = FrozenBrush(0x1F, 0x8F, 0xFF);
    private static readonly SolidColorBrush BtnSecBg = FrozenBrush(0x32, 0x32, 0x36);
    private static readonly SolidColorBrush BtnSecBd = FrozenBrush(0x46, 0x46, 0x4C);

    private static SolidColorBrush FrozenBrush(byte r, byte g, byte b)
    {
        var br = new SolidColorBrush(Color.FromRgb(r, g, b));
        br.Freeze();
        return br;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private string _ifaceName = "";
    private string _displayName = "";
    private string _localIp = "";
    private string _peerIp = "";
    private bool _online;
    private double? _rttMs;
    private double _estBandwidthMbps;
    private bool _isRecommendedControl;
    private bool _isRecommendedData;
    private bool _enabledForMultipath = true;
    private bool _manuallyDisconnected;
    private bool _multipathEditable = true;

    public string Id { get; init; } = "";
    public bool IsUsbBridge { get; init; }

    public string IfaceName { get => _ifaceName; set => SetField(ref _ifaceName, value); }
    public string DisplayName { get => _displayName; set => SetField(ref _displayName, value); }
    public string LocalIp { get => _localIp; set { if (SetField(ref _localIp, value)) NotifyDerived(); } }
    public string PeerIp { get => _peerIp; set { if (SetField(ref _peerIp, value)) NotifyDerived(); } }
    public bool Online { get => _online; set { if (SetField(ref _online, value)) NotifyDerived(); } }
    public double? RttMs { get => _rttMs; set { if (SetField(ref _rttMs, value)) OnPropertyChanged(nameof(RttBadgeText)); } }
    public double EstBandwidthMbps { get => _estBandwidthMbps; set => SetField(ref _estBandwidthMbps, value); }
    public bool IsRecommendedControl { get => _isRecommendedControl; set { if (SetField(ref _isRecommendedControl, value)) OnPropertyChanged(nameof(RoleBadgeZh)); } }
    public bool IsRecommendedData { get => _isRecommendedData; set { if (SetField(ref _isRecommendedData, value)) OnPropertyChanged(nameof(RoleBadgeZh)); } }
    public bool EnabledForMultipath { get => _enabledForMultipath; set => SetField(ref _enabledForMultipath, value); }
    public bool ManuallyDisconnected { get => _manuallyDisconnected; set { if (SetField(ref _manuallyDisconnected, value)) NotifyDerived(); } }
    public bool IsMultipathEditable { get => _multipathEditable; set => SetField(ref _multipathEditable, value); }

    public string ChannelKey => IsUsbBridge ? "usb" : (!string.IsNullOrEmpty(PeerIp) ? $"{LocalIp}->{PeerIp}" : LocalIp);
    public string ConnectionActionText => ManuallyDisconnected ? AppLoc.T("重连", "Reconnect") : (Online ? AppLoc.T("断开", "Disconnect") : AppLoc.T("连接", "Connect"));

    public Brush StatusDotBrush => ManuallyDisconnected ? DotOrange : (Online ? DotGreen : DotGray);
    public Brush RttTextBrush => ManuallyDisconnected ? DotOrange : RttNormal;
    public Brush ConnBtnBackground => (ManuallyDisconnected || !Online) ? BtnPrimaryBg : BtnSecBg;
    public Brush ConnBtnBorder => (ManuallyDisconnected || !Online) ? BtnPrimaryBd : BtnSecBd;

    public string StatusSummary => ManuallyDisconnected
        ? $"{LocalIp} · {AppLoc.T("已手动断开", "Paused")}"
        : $"{LocalIp} ↔ {PeerIp} · {(IsUsbBridge ? AppLoc.T("USB 直连", "USB Direct") : AppLoc.T("已加密", "TLS Encrypted"))}";

    public string RttBadgeText => ManuallyDisconnected
        ? AppLoc.T("已断开", "Paused")
        : (Online && RttMs.HasValue ? $"{RttMs.Value:F1} ms" : AppLoc.T("待机", "Idle"));

    public string RoleBadgeZh =>
        (IsRecommendedControl ? AppLoc.T("[键鼠最快] ", "[Control] ") : "") +
        (IsRecommendedData ? AppLoc.T("[传文件最快]", "[Data]") : "");

    public static string CanonicalChannelKey(string ifaceName, string localIp, bool isUsb, string? peerIp = null)
    {
        if (isUsb || DeskflowTransport.IsUsbBridgeIp(localIp)
            || ifaceName is "USB-C NCM" or "USB-C" or "MacBridge" or "USB-NCM")
            return "usb";
        if (!string.IsNullOrEmpty(peerIp) && !string.IsNullOrEmpty(localIp) && localIp != "auto")
            return $"{localIp}->{peerIp}";
        return (!string.IsNullOrEmpty(localIp) && localIp != "auto") ? localIp : ifaceName;
    }

    public void CopyFrom(NicChannelItem src)
    {
        IfaceName = src.IfaceName;
        DisplayName = src.DisplayName;
        LocalIp = src.LocalIp;
        PeerIp = src.PeerIp;
        Online = src.Online;
        RttMs = src.RttMs;
        EstBandwidthMbps = src.EstBandwidthMbps;
        IsRecommendedControl = src.IsRecommendedControl;
        IsRecommendedData = src.IsRecommendedData;
        EnabledForMultipath = src.EnabledForMultipath;
        ManuallyDisconnected = src.ManuallyDisconnected;
        IsMultipathEditable = src.IsMultipathEditable;
    }

    private bool SetField<T>(ref T field, T value, [CallerMemberName] string? prop = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(prop);
        return true;
    }

    private void NotifyDerived()
    {
        OnPropertyChanged(nameof(ConnectionActionText));
        OnPropertyChanged(nameof(StatusDotBrush));
        OnPropertyChanged(nameof(RttTextBrush));
        OnPropertyChanged(nameof(ConnBtnBackground));
        OnPropertyChanged(nameof(ConnBtnBorder));
        OnPropertyChanged(nameof(StatusSummary));
        OnPropertyChanged(nameof(RttBadgeText));
        OnPropertyChanged(nameof(RoleBadgeZh));
    }

    private void OnPropertyChanged(string? name) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public static class DragHandoffPolicy
{
    public const double DefaultContinuousMaxSeconds = 1.5;
    public const ulong MaxContinuousSizeBytes = 64UL * 1024 * 1024;
    public const int EstimationScanBudgetCount = 3000;
    public const double FallbackUsbBytesPerSec = 60.0 * 1024.0 * 1024.0;
    public const double FallbackLanBytesPerSec = 45.0 * 1024.0 * 1024.0;
    public const double FallbackWifiBytesPerSec = 18.0 * 1024.0 * 1024.0;
    public const double HoverCancelDistancePx = 56.0;
    public const ulong RequiredDiskMarginBytes = 32UL * 1024 * 1024;
}

public enum ShelfDirection
{
    Outgoing,
    Incoming
}

public enum ShelfItemStatus
{
    Transferring,
    Ready,
    Failed
}

public sealed class ShelfTransferItem : INotifyPropertyChanged
{
    private static readonly SolidColorBrush AccentBlue = MakeBrush(0x0A, 0x84, 0xFF);
    private static readonly SolidColorBrush AccentGreen = MakeBrush(0x30, 0xD1, 0x58);
    private static readonly SolidColorBrush AccentRed = MakeBrush(0xFF, 0x5A, 0x52);
    private static readonly SolidColorBrush SubNormal = MakeBrush(0xB8, 0xB8, 0xBE);
    private static readonly SolidColorBrush SubError = MakeBrush(0xFF, 0x9C, 0x96);

    private static SolidColorBrush MakeBrush(byte r, byte g, byte b)
    {
        var br = new SolidColorBrush(Color.FromRgb(r, g, b));
        br.Freeze();
        return br;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private ShelfItemStatus _status;
    private string _title = "";
    private string _sizeText = "";
    private double _progress;
    private double _speedMbps;
    private string _channelTag = "";
    private string? _errorText;
    private List<string> _localPaths = new();

    public string Id { get; init; } = "";
    public ShelfDirection Direction { get; init; }
    public int ItemCount { get; set; } = 1;
    public List<string> SourcePaths { get; set; } = new();

    public ShelfItemStatus Status { get => _status; set { if (SetField(ref _status, value)) NotifyAllDerived(); } }
    public string Title { get => _title; set => SetField(ref _title, value); }
    public string SizeText { get => _sizeText; set { if (SetField(ref _sizeText, value)) OnPropertyChanged(nameof(SubtitleText)); } }
    public double Progress { get => _progress; set { if (SetField(ref _progress, value)) { OnPropertyChanged(nameof(ProgressPercent)); OnPropertyChanged(nameof(SubtitleText)); } } }
    public double SpeedMbps { get => _speedMbps; set { if (SetField(ref _speedMbps, value)) OnPropertyChanged(nameof(SubtitleText)); } }
    public string ChannelTag { get => _channelTag; set { if (SetField(ref _channelTag, value)) OnPropertyChanged(nameof(SubtitleText)); } }
    public string? ErrorText { get => _errorText; set { if (SetField(ref _errorText, value)) OnPropertyChanged(nameof(SubtitleText)); } }
    public List<string> LocalPaths { get => _localPaths; set { _localPaths = value; OnPropertyChanged(nameof(CanDragOut)); OnPropertyChanged(nameof(PrimaryPath)); } }
    public string? PrimaryPath => LocalPaths.FirstOrDefault();

    public double ProgressPercent => Math.Clamp(Progress * 100.0, 0.0, 100.0);
    public bool CanDragOut => Direction == ShelfDirection.Incoming && Status == ShelfItemStatus.Ready && LocalPaths.Count > 0;
    public Visibility ProgressVisibility => Status == ShelfItemStatus.Transferring ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ActionsVisibility => Status != ShelfItemStatus.Transferring ? Visibility.Visible : Visibility.Collapsed;
    public Visibility IncomingActionsVisibility => (Direction == ShelfDirection.Incoming && Status == ShelfItemStatus.Ready) ? Visibility.Visible : Visibility.Collapsed;
    public Visibility RetryVisibility => (Direction == ShelfDirection.Outgoing && Status == ShelfItemStatus.Failed) ? Visibility.Visible : Visibility.Collapsed;
    public Brush BorderAccentBrush => Status == ShelfItemStatus.Failed ? AccentRed : (Status == ShelfItemStatus.Ready ? AccentGreen : AccentBlue);
    public Brush SubtitleBrush => Status == ShelfItemStatus.Failed ? SubError : SubNormal;

    public string SubtitleText => Status switch
    {
        ShelfItemStatus.Transferring => $"{SizeText} · {(int)Math.Round(Progress * 100)}% · {SpeedMbps / 8.0:F0} MB/s",
        ShelfItemStatus.Ready => $"{SizeText} · {AppLoc.T("校验完成 · 按住卡片可拖出", "Verified · Hold card to drag")}",
        _ => ErrorText ?? AppLoc.T("传输失败", "Transfer failed")
    };

    private bool SetField<T>(ref T field, T value, [CallerMemberName] string? prop = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(prop);
        return true;
    }

    private void NotifyAllDerived()
    {
        OnPropertyChanged(nameof(CanDragOut));
        OnPropertyChanged(nameof(ProgressVisibility));
        OnPropertyChanged(nameof(ActionsVisibility));
        OnPropertyChanged(nameof(IncomingActionsVisibility));
        OnPropertyChanged(nameof(RetryVisibility));
        OnPropertyChanged(nameof(BorderAccentBrush));
        OnPropertyChanged(nameof(SubtitleBrush));
        OnPropertyChanged(nameof(SubtitleText));
    }

    private void OnPropertyChanged(string? name) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public sealed class ReceivedFileRecord
{
    public string Id { get; init; } = "";
    public string FileName { get; init; } = "";
    public string FileSize { get; init; } = "";
    public string SavedPath { get; init; } = "";
    public string TimeTag { get; init; } = "";
    public bool IsZipOrFolder => FileName.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) || Directory.Exists(SavedPath);
    public string TypeBadge => IsZipOrFolder ? "ZIP" : "FILE";
}

public sealed class IndependentMonitorItem
{
    public string Id { get; init; } = "";
    public int DisplayIndex { get; init; }
    public string Name { get; init; } = "";
    public string OsKind { get; init; } = "Windows";
    public int WidthPx { get; init; } = 1920;
    public int HeightPx { get; init; } = 1080;
    public double ScaleFactor { get; init; } = 1.0;
    public int BoundsX { get; init; }
    public int BoundsY { get; init; }
    public bool IsPrimary { get; init; }
    public double CanvasX { get; set; }
    public double CanvasY { get; set; }
    public double LogicalWidth => WidthPx / Math.Max(1.0, ScaleFactor);
    public double LogicalHeight => HeightPx / Math.Max(1.0, ScaleFactor);
    public double AspectWidth => Math.Round(Math.Clamp(LogicalWidth, 1024.0, 3840.0) * 0.068);
    public double AspectHeight => LogicalWidth > 0 ? Math.Clamp(Math.Round(AspectWidth * LogicalHeight / LogicalWidth), 66.0, 150.0) : 96.0;
    public string OrderTag => $"#{DisplayIndex}";
    public string ResolutionTag => $"{WidthPx}×{HeightPx}";
}

public sealed class SemanticHotkeyItem
{
    public string Id { get; init; } = "";
    public string TitleZh { get; init; } = "";
    public string TitleEn { get; init; } = "";
    public string MacTrigger { get; init; } = "";
    public string WinAction { get; init; } = "";
    public bool Enabled { get; set; } = true;
    public string Direction { get; init; } = "mac_to_win";
    public bool IsGesture { get; init; } = false;

    public string TitleDisplay => AppLoc.Shared.IsEnglish && !string.IsNullOrEmpty(TitleEn) ? TitleEn : TitleZh;

    public string TriggerDisplay
    {
        get
        {
            if (!AppLoc.Shared.IsEnglish) return MacTrigger;
            return MacTrigger switch
            {
                "Mac 三指拖动" => "Mac 3-Finger Drag",
                "Win 三指拖动" => "Win 3-Finger Drag",
                _ => MacTrigger
            };
        }
    }

    public string ActionDisplay
    {
        get
        {
            if (!AppLoc.Shared.IsEnglish) return WinAction;
            return WinAction switch
            {
                "Win 左键拖移" => "Win Left Drag",
                "Mac 左键拖移" => "Mac Left Drag",
                _ => WinAction
            };
        }
    }
}
