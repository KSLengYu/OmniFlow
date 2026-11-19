using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace MacBridgeUI;

public sealed partial class DeskflowService : IDisposable
{
    public readonly DeskflowTransport Transport = new();

    public TransferSchemeMode SchemeMode { get; set; } = TransferSchemeMode.AutoSmart;
    public PortalEffectStyle EffectStyle { get; set; } = PortalEffectStyle.BlackHole;
    public ScreenEdgeSide EdgeSide { get; set; } = ScreenEdgeSide.Left;
    public double EdgeOffsetRatio { get; set; } = 0.55;
    public bool OverlayEnabled { get; set; } = true;
    public bool MultipathEnabled { get; set; } = true;
    public bool KvmEnabled { get; set; } = true;
    public bool EdgeSwitchEnabled { get; set; } = true;
    public bool HotkeySwitchEnabled { get; set; } = true;
    public bool ClipboardSyncEnabled { get; set; } = true;
    public bool RemoteFocusActive { get; set; }
    public string ManualPeerIp { get; set; } = "";
    public string? SelectedMonitorId { get; set; }

    public PortalTransferPhase Phase { get; set; } = PortalTransferPhase.Idle;
    public double TransferProgress { get; set; }
    public string ActiveFileName { get; set; } = "";
    public string ActiveFileSize { get; set; } = "";
    public double ActiveSpeedMbps { get; set; }
    public string ActiveChannelTag { get; set; } = "";
    public string LastTransferSummary { get; set; } = "";
    public string? LastReceivedFilePath { get; private set; }

    public List<NicChannelItem> NicChannels { get; private set; } = new();
    public ObservableCollection<NicChannelItem> NicChannelsView { get; } = new();
    public List<IndependentMonitorItem> Monitors { get; private set; } = new();
    public ObservableCollection<ShelfTransferItem> ShelfItems { get; } = new();
    public List<ReceivedFileRecord> ReceivedFiles { get; } = new();
    public List<SemanticHotkeyItem> HotkeyRules { get; } = new()
    {
        new() { Id = "shot_region", TitleZh = "区域截图穿透", TitleEn = "Region Screenshot", MacTrigger = "Cmd + Shift + 4", WinAction = "Win + Shift + S", Direction = "mac_to_win", Enabled = false },
        new() { Id = "shot_panel", TitleZh = "截图录屏工具栏", TitleEn = "Screen Capture Bar", MacTrigger = "Cmd + Shift + 5", WinAction = "Win + Shift + S", Direction = "mac_to_win", Enabled = false },
        new() { Id = "shot_snipaste", TitleZh = "快捷贴图/微信截图映射", TitleEn = "WeChat / Snipaste Shot", MacTrigger = "Cmd + Opt + A", WinAction = "Alt + A", Direction = "mac_to_win", Enabled = false },
        new() { Id = "win_quick_x", TitleZh = "Windows 快捷系统菜单 (Win+X)", TitleEn = "Windows Quick Link Menu", MacTrigger = "Ctrl + Opt + X", WinAction = "Win + X", Direction = "mac_to_win", Enabled = false },
        new() { Id = "clip_ops", TitleZh = "剪贴板与编辑 (C/V/X/A/Z/S/F)", TitleEn = "Clipboard & Edit Keys", MacTrigger = "Cmd + C/V/X/A/Z/S/F", WinAction = "Ctrl + C/V/X/A/Z/S/F", Direction = "mac_to_win", Enabled = false },
        new() { Id = "app_switch", TitleZh = "跨系统窗口切换", TitleEn = "Window Switcher", MacTrigger = "Cmd + Tab", WinAction = "Alt + Tab", Direction = "mac_to_win", Enabled = false },
        new() { Id = "search_launcher", TitleZh = "全局搜索呼出", TitleEn = "Global Search", MacTrigger = "Cmd + Space", WinAction = "Win + S", Direction = "mac_to_win", Enabled = false },

        new() { Id = "mac_tp_3f_drag", TitleZh = "三指拖移（可选）", TitleEn = "3-Finger Drag -> Win Drag", MacTrigger = "Mac 三指拖动", WinAction = "Win 左键拖移", Direction = "mac_to_win", IsGesture = true, Enabled = false },

        new() { Id = "win_to_mac_prtsc", TitleZh = "PrintScreen 截 Mac 区域", TitleEn = "Win PrtScn -> Mac Screenshot", MacTrigger = "Win PrtScn", WinAction = "Mac Cmd + Shift + 4", Direction = "win_to_mac", Enabled = false },
        new() { Id = "win_to_mac_snip", TitleZh = "Win 截图键触发 Mac 截图", TitleEn = "Win+Shift+S -> Mac Screenshot", MacTrigger = "Win + Shift + S", WinAction = "Mac Cmd + Shift + 4", Direction = "win_to_mac", Enabled = false },
        new() { Id = "win_to_mac_clip", TitleZh = "Win 复制/编辑映射 (Ctrl→Cmd)", TitleEn = "Win Ctrl Edit -> Mac Cmd", MacTrigger = "Ctrl + C/V/X/A/Z/S/F", WinAction = "Mac Cmd + C/V/X/A/Z/S/F", Direction = "win_to_mac", Enabled = false },
        new() { Id = "win_to_mac_alttab", TitleZh = "Win Alt+Tab 切 Mac 应用", TitleEn = "Win Alt+Tab -> Mac Cmd+Tab", MacTrigger = "Alt + Tab", WinAction = "Mac Cmd + Tab", Direction = "win_to_mac", Enabled = false },
        new() { Id = "win_to_mac_search", TitleZh = "Win 搜索键呼出 Mac 聚焦", TitleEn = "Win+S -> Mac Spotlight", MacTrigger = "Win + S", WinAction = "Mac Cmd + Space", Direction = "win_to_mac", Enabled = false },

        new() { Id = "win_tp_3f_drag", TitleZh = "三指拖移（可选）", TitleEn = "Win 3-Finger Drag -> Mac Drag", MacTrigger = "Win 三指拖动", WinAction = "Mac 左键拖移", Direction = "win_to_mac", IsGesture = true, Enabled = false }
    };

    private readonly Dispatcher _dispatcher;
    private DispatcherTimer? _clipboardTimer;
    private DispatcherTimer? _topologySyncTimer;
    private DispatcherTimer? _usbProbeTimer;
    private System.Diagnostics.Process? _usbTunnelProcess;
    private uint _lastClipSeq;
    private string _lastRemoteClipboard = "";
    private string _lastRemoteClipboardImageSha = "";
    private string _lastRemoteClipboardFileSig = "";
    private DateTime _suppressClipboardUntilUtc = DateTime.MinValue;
    private List<WireMonitorDto> _peerMonitors = new();
    private List<WireMonitorDto> _localMonitors = new();
    private readonly Dictionary<string, (double X, double Y)> _syncedPositions = new();
    private readonly HashSet<string> _disabledMultipathIfaces = new(StringComparer.OrdinalIgnoreCase);
    private string? _lastRecommendedControlKey;
    private double _lastCanvasW = 680;
    private double _lastCanvasH = 360;
    private string _lastTriggeredHotkey = "";
    private DateTime _lastHotkeyTime = DateTime.MinValue;
    private DateTime _lastContinuousDragUtc = DateTime.MinValue;
    public const double DragOutReentryCooldownSeconds = 2.0;
    public bool IsDraggingOutFromShelf { get; private set; }
    private DateTime _dragOutEndedUtc = DateTime.MinValue;
    private HashSet<string> _recentDraggedOutPaths = new(StringComparer.OrdinalIgnoreCase);
    private string _lastDropSignature = "";
    private DateTime _lastDropSubmittedUtc = DateTime.MinValue;
    private readonly Dictionary<string, double[]> _savedMonitorPositions = new();
    private bool _applyingRemoteConfig;
    private double _lastAppliedConfigTs;

    public string DisplaySaveStatusText { get; private set; } = "";
    public string SettingsSaveStatusText { get; private set; } = "";

    public double UsbConnectProgress { get; private set; }
    public string UsbStatusText { get; private set; } = "待插线 · 可点击「启动 USB 直连」启动通道";
    public string UsbHeadline { get; private set; } = "等待连接";
    public string UsbSubline { get; private set; } = "请用 USB-C 数据线连接 Mac 与 Windows，然后点击右侧「启动 USB 直连」";
    public string UsbActionHint { get; private set; } = "就绪 · 使用 WinUSB 驱动接管苹果 USB-C NCM 并建立点对点隧道";
    public string UsbStateTone { get; private set; } = "waiting";
    public double UsbProgressCeil { get; private set; } = 0.0;
    public bool UsbHardwareDetected { get; private set; }
    public string UsbHardwareSummary { get; private set; } = "未检测到 Apple USB-C NCM 设备";
    public string UsbDriverService { get; private set; } = "未绑定";
    public string UsbSpeedLabel { get; private set; } = "待握手";
    public int UsbSpeedMbps { get; private set; }
    public long UsbRxPackets { get; private set; }
    public long UsbTxPackets { get; private set; }
    public bool UsbProcessRunning { get; set; }
    public bool UsbActionBusy { get; private set; }
    public List<string> UsbLogs { get; } = new();
    public string HoverPromptTitle { get; private set; } = "松手放到传输架 · 移开取消";
    public string HoverPromptDetail { get; private set; } = "移开则取消，不会发起传输";
    public bool HoverIsLargeFile { get; private set; }
    public bool HoverCanSubmit { get; private set; } = true;
    public KvmControlMode ControlMode { get; set; } = KvmControlMode.DualActive;
    public KeymapProfileMode KeymapProfile { get; set; } = KeymapProfileMode.Hybrid;
    public PendingPairingRequest? PendingPairing { get; private set; }
    public int TrustedPeerCount => Transport.TrustStore.AllTrusted().Count;
    public IReadOnlyList<TrustedPeerRecord> TrustedPeersList => Transport.TrustStore.AllTrusted();
    private bool _threeFingerOptInV2 = true;

    public int PortalMonitorIndex { get; set; } = 1;
    public bool GlobalPaused => Transport.IsGloballyPaused;

    public bool IsEnglish
    {
        get => AppLoc.Shared.IsEnglish;
        set
        {
            if (AppLoc.Shared.IsEnglish == value && UsbHardwareSummary != null) return;
            AppLoc.Shared.IsEnglish = value;
            SaveSettingsToDisk();
            RefreshNicChannels(DeskflowUsbConstants.WinUsbIp, DeskflowUsbConstants.MacUsbIp, UsbSpeedMbps > 0 ? UsbSpeedMbps : DeskflowUsbConstants.DefaultUsbSpeedMbps);
            StateUpdated?.Invoke();
        }
    }

    public event Action? StateUpdated;
    public event Action? MonitorsUpdated;
    public event Action? IdentifyScreensRequested;
    public event Action<string>? LogMessage;

    public DeskflowService(Dispatcher dispatcher)
    {
        _dispatcher = dispatcher;
        LoadSettingsFromDisk();
        AppLoc.Shared.SyncGitHubProfileAsync();
        WireTransport();
        Transport.Start();
        if (!string.IsNullOrWhiteSpace(ManualPeerIp))
            Transport.AddManualPeerIp(ManualPeerIp);
        RefreshNicChannels(DeskflowUsbConstants.WinUsbIp, DeskflowUsbConstants.MacUsbIp, DeskflowUsbConstants.DefaultUsbSpeedMbps);
        ResetMonitorLayout();
        StartClipboardWatcher();
        StartUsbHardwareProbeLoop();
        InstallLowLevelHooks();
        bool isAdmin = IsRunningAsAdministrator();
        LogMessage?.Invoke(isAdmin
            ? "[KVM] 当前已以管理员权限运行（支持控制管理员 CMD/任务管理器等提权窗口）"
            : "[KVM Warn] 当前非管理员运行，受 Windows UIPI 限制将无法控制管理员窗口");
    }

    public static bool IsRunningAsAdministrator()
    {
        try
        {
            using var id = WindowsIdentity.GetCurrent();
            return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch
        {
            return false;
        }
    }

    public void AppendErrorLog(string msg) => LogMessage?.Invoke(msg);

    public void ConfirmPendingPairing()
    {
        var req = PendingPairing;
        if (req == null) return;
        PendingPairing = null;
        Transport.ConfirmPairing(req.Fingerprint, req.HostName);
        StateUpdated?.Invoke();
    }

    public void RejectPendingPairing()
    {
        var req = PendingPairing;
        if (req == null) return;
        PendingPairing = null;
        Transport.RejectPairing(req.Fingerprint);
        StateUpdated?.Invoke();
    }

    public void ClearTrustedPeers()
    {
        PendingPairing = null;
        Transport.ClearAllTrustedPeers();
        StateUpdated?.Invoke();
    }

    public void RemoveTrustedPeer(string fingerprint)
    {
        if (string.IsNullOrWhiteSpace(fingerprint)) return;
        PendingPairing = null;
        Transport.RemoveTrustedPeer(fingerprint);
        StateUpdated?.Invoke();
    }

    private void WireTransport()
    {
        Transport.LogMessage += msg => LogMessage?.Invoke(msg);

        Transport.LinksUpdated += () =>
        {
            _dispatcher.BeginInvoke(() =>
            {
                var linksNow = Transport.ActiveLinksSnapshot();
                if (linksNow.Count == 0)
                {
                    if (RemoteFocusActive)
                    {
                        SetRemoteFocus(false, broadcastToPeer: false);
                    }
                    if (_peerMonitors.Count > 0)
                    {
                        _peerMonitors.Clear();
                        ResetMonitorLayout();
                        MonitorsUpdated?.Invoke();
                    }
                }
                // Do not hold failed connection on disconnected USB interface if LAN links exist
                RefreshNicChannels(DeskflowUsbConstants.WinUsbIp, DeskflowUsbConstants.MacUsbIp, DeskflowUsbConstants.DefaultUsbSpeedMbps);
                StateUpdated?.Invoke();
            });
        };

        Transport.PeerMonitorsUpdated += (mons, host) =>
        {
            _dispatcher.BeginInvoke(() =>
            {
                _peerMonitors = mons;
                foreach (var kv in _savedMonitorPositions)
                {
                    if (kv.Value.Length == 2)
                        _syncedPositions[kv.Key] = (kv.Value[0], kv.Value[1]);
                }
                ResetMonitorLayout();
                LogMessage?.Invoke($"[Display] 已同步 Mac ({host}) 的 {mons.Count} 块独立显示器");
                MonitorsUpdated?.Invoke();
                StateUpdated?.Invoke();
            });
        };

        Transport.TopologySync += topo =>
        {
            _dispatcher.BeginInvoke(() =>
            {
                bool addedPeer = false;
                foreach (var item in topo.Items)
                {
                    _syncedPositions[item.Id] = (item.CanvasX, item.CanvasY);
                    var m = Monitors.FirstOrDefault(x => x.Id == item.Id);
                    if (m != null)
                    {
                        m.CanvasX = item.CanvasX;
                        m.CanvasY = item.CanvasY;
                    }
                    else if (item.OsKind == "macOS" && !string.IsNullOrEmpty(item.Name))
                    {
                        if (!_peerMonitors.Any(p => p.Id == item.Id))
                        {
                            _peerMonitors.Add(new WireMonitorDto
                            {
                                Id = item.Id,
                                DisplayIndex = item.DisplayIndex ?? (_peerMonitors.Count + 1),
                                Name = item.Name ?? "Mac Display",
                                OsKind = "macOS",
                                WidthPx = item.WidthPx ?? 2560,
                                HeightPx = item.HeightPx ?? 1600,
                                ScaleFactor = item.ScaleFactor ?? 2.0,
                                IsPrimary = item.IsPrimary ?? false
                            });
                            addedPeer = true;
                        }
                    }
                }
                if (addedPeer)
                {
                    ResetMonitorLayout();
                }
                else
                {
                    bool allSaved = Monitors.Count > 0 && Monitors.All(m => _savedMonitorPositions.ContainsKey(m.Id));
                    if (!allSaved)
                    {
                        ResolveDisplayOverlaps();
                        CenterDisplayCluster(_lastCanvasW, _lastCanvasH, persistToSynced: _peerMonitors.Count > 0);
                    }
                    SyncPortalEdgeFromDisplayLayout();
                }
                if (Monitors.Count > 1 && topo.Items.Count >= Monitors.Count)
                    SaveMonitorLayout(silent: true);
                LogMessage?.Invoke($"[Topology] 已同步来自 {topo.SenderOs} 的显示器空间布局 ({topo.Items.Count} 块)");
                MonitorsUpdated?.Invoke();
                StateUpdated?.Invoke();
            });
        };

        Transport.KvmFocusSwitch += sw =>
        {
            _dispatcher.BeginInvoke(() =>
            {
                if (sw.TargetOs == "Windows")
                {
                    if (!RemoteFocusActive && ControlMode == KvmControlMode.WinMasterOnly) return;
                    SetRemoteFocus(false, broadcastToPeer: false);
                    if (KvmEnabled && ControlMode != KvmControlMode.WinMasterOnly)
                        InjectMouseMoveAbs(sw.MonitorIndex, sw.NormX, sw.NormY);
                }
                else if (sw.TargetOs == "macOS")
                {
                    SetRemoteFocus(true, broadcastToPeer: false);
                }
            });
        };

        Transport.RemoteClipboardText += txt =>
        {
            if (!ClipboardSyncEnabled || string.IsNullOrEmpty(txt)) return;
            _dispatcher.BeginInvoke(() =>
            {
                try
                {
                    string current = Clipboard.ContainsText() ? Clipboard.GetText() : "";
                    if (current == txt && _lastRemoteClipboard == txt)
                    {
                        _lastClipSeq = GetClipboardSequenceNumber();
                        return;
                    }
                    _suppressClipboardUntilUtc = DateTime.UtcNow.AddMilliseconds(900);
                    _lastRemoteClipboard = txt;
                    Clipboard.SetText(txt);
                    _lastClipSeq = GetClipboardSequenceNumber();
                    LogMessage?.Invoke($"[剪贴板] 收到 Mac 复制的文字 ({txt.Length} 字符)");
                }
                catch (Exception ex)
                {
                    LogMessage?.Invoke($"[剪贴板警告] 写入文字失败: {ex.Message}");
                }
            });
        };

        Transport.RemoteClipboardImage += pngBytes =>
        {
            if (!ClipboardSyncEnabled || pngBytes.Length == 0) return;
            string sha = ComputeBytesSha256Hex(pngBytes);
            _dispatcher.BeginInvoke(() =>
            {
                try
                {
                    if (sha == _lastRemoteClipboardImageSha)
                    {
                        _lastClipSeq = GetClipboardSequenceNumber();
                        return;
                    }
                    using var ms = new MemoryStream(pngBytes, writable: false);
                    var bmp = new BitmapImage();
                    bmp.BeginInit();
                    bmp.CreateOptions = BitmapCreateOptions.PreservePixelFormat;
                    bmp.CacheOption = BitmapCacheOption.OnLoad;
                    bmp.StreamSource = ms;
                    bmp.EndInit();
                    bmp.Freeze();

                    var dataObj = new DataObject();
                    dataObj.SetData(DataFormats.Bitmap, bmp);
                    dataObj.SetData("PNG", new MemoryStream(pngBytes, writable: false));

                    _suppressClipboardUntilUtc = DateTime.UtcNow.AddMilliseconds(900);
                    _lastRemoteClipboardImageSha = sha;
                    Clipboard.SetDataObject(dataObj, copy: true);
                    _lastClipSeq = GetClipboardSequenceNumber();
                    LogMessage?.Invoke($"[剪贴板] 收到 Mac 复制的图片 ({pngBytes.Length / 1024.0:F0} KB)，可直接 Ctrl+V 粘贴");
                }
                catch (Exception ex)
                {
                    LogMessage?.Invoke($"[剪贴板警告] 写入图片失败: {ex.Message}");
                }
            });
        };

        Transport.RemotePortalSync += sync =>
        {
            _dispatcher.BeginInvoke(() =>
            {
                if (!OverlayEnabled) OverlayEnabled = true;
                EffectStyle = sync.Style == "cube" ? PortalEffectStyle.FloatingCube : PortalEffectStyle.BlackHole;
                ActiveFileName = sync.FileName;
                ActiveFileSize = sync.FileSize;
                ActiveSpeedMbps = sync.SpeedMbps;
                ActiveChannelTag = sync.ChannelTag;
                TransferProgress = sync.Progress;
                Phase = sync.Phase switch
                {
                    "suckingIn" => PortalTransferPhase.SuckingIn,
                    "emergingOut" => PortalTransferPhase.EmergingOut,
                    "completed" => PortalTransferPhase.Completed,
                    _ => PortalTransferPhase.Idle
                };
                StateUpdated?.Invoke();
            });
        };

        Transport.IncomingFileCompleted += (offer, savedPath) =>
        {
            _dispatcher.BeginInvoke(() =>
            {
                string sizeStr = DeskflowTransport.FormatBytes(offer.TotalBytes);

                if (offer.IsClipboardItem)
                {
                    if (!ClipboardSyncEnabled) return;
                    try
                    {
                        var dropList = new StringCollection();
                        if (offer.IsClipboardMulti && Directory.Exists(savedPath))
                        {
                            foreach (var entry in Directory.GetFileSystemEntries(savedPath))
                                dropList.Add(entry);
                        }
                        if (dropList.Count == 0) dropList.Add(savedPath);

                        var paths = dropList.Cast<string>().ToArray();
                        _suppressClipboardUntilUtc = DateTime.UtcNow.AddMilliseconds(1000);
                        _lastRemoteClipboardFileSig = ComputeFilesSignature(paths);
                        Clipboard.SetFileDropList(dropList);
                        _lastClipSeq = GetClipboardSequenceNumber();
                        LogMessage?.Invoke($"[剪贴板] 收到 Mac 复制的文件，可直接按 Ctrl+V 粘贴 ({dropList.Count} 项 · {sizeStr})");
                    }
                    catch (Exception ex)
                    {
                        LogMessage?.Invoke($"[剪贴板警告] 更新接收文件剪贴板失败: {ex.Message}");
                    }
                    return;
                }

                var deliveredPaths = new List<string>();
                if (offer.IsBatchBundle && Directory.Exists(savedPath))
                {
                    try
                    {
                        foreach (var child in Directory.GetFileSystemEntries(savedPath))
                            deliveredPaths.Add(child);
                    }
                    catch { }
                }
                if (deliveredPaths.Count == 0) deliveredPaths.Add(savedPath);

                int itemCount = offer.BatchItemCount ?? deliveredPaths.Count;
                string cardTitle = itemCount > 1
                    ? $"{Path.GetFileName(deliveredPaths[0])} 等 {itemCount} 项"
                    : Path.GetFileName(deliveredPaths[0]);

                var existingShelf = ShelfItems.FirstOrDefault(s => s.Id == offer.TransferId);
                if (existingShelf != null) ShelfItems.Remove(existingShelf);
                ShelfItems.Insert(0, new ShelfTransferItem
                {
                    Id = offer.TransferId,
                    Direction = ShelfDirection.Incoming,
                    Status = ShelfItemStatus.Ready,
                    Title = cardTitle,
                    SizeText = sizeStr,
                    ItemCount = itemCount,
                    Progress = 1.0,
                    SpeedMbps = 0,
                    ChannelTag = "已校验",
                    LocalPaths = deliveredPaths
                });
                while (ShelfItems.Count > 12) ShelfItems.RemoveAt(ShelfItems.Count - 1);

                LastReceivedFilePath = savedPath;
                ActiveFileName = cardTitle;
                ActiveFileSize = sizeStr;
                TransferProgress = 1.0;
                Phase = PortalTransferPhase.Completed;
                LastTransferSummary = $"收到 Mac 发来的文件: {cardTitle} ({ActiveFileSize})";
                ReceivedFiles.Insert(0, new ReceivedFileRecord
                {
                    Id = offer.TransferId,
                    FileName = cardTitle,
                    FileSize = ActiveFileSize,
                    SavedPath = savedPath,
                    TimeTag = DateTime.Now.ToString("HH:mm:ss")
                });
                if (ReceivedFiles.Count > 50) ReceivedFiles.RemoveAt(ReceivedFiles.Count - 1);
                try
                {
                    var dropList = new StringCollection();
                    foreach (var p in deliveredPaths) dropList.Add(p);
                    _suppressClipboardUntilUtc = DateTime.UtcNow.AddMilliseconds(900);
                    _lastRemoteClipboardFileSig = ComputeFilesSignature(deliveredPaths);
                    Clipboard.SetFileDropList(dropList);
                    _lastClipSeq = GetClipboardSequenceNumber();
                }
                catch (Exception ex)
                {
                    LogMessage?.Invoke($"[剪贴板警告] 更新接收剪贴板失败: {ex.Message}");
                }
                LogMessage?.Invoke($"[传文件] 接收并校验完成: {cardTitle} -> {savedPath}");
                StateUpdated?.Invoke();
            });
        };

        Transport.TransferFailed += (fileName, reason) =>
        {
            _dispatcher.BeginInvoke(() =>
            {
                Phase = PortalTransferPhase.Idle;
                LastTransferSummary = $"传输校验失败 ({fileName}): {reason}";
                LogMessage?.Invoke($"[File Error] 接收失败 ({fileName}): {reason}");
                StateUpdated?.Invoke();
            });
        };

        Transport.PendingPairingRequested += req =>
        {
            _dispatcher.BeginInvoke(() =>
            {
                if (PendingPairing?.Fingerprint != req.Fingerprint)
                {
                    PendingPairing = req;
                    StateUpdated?.Invoke();
                }
            });
        };

        Transport.TrustStoreUpdated += () =>
        {
            _dispatcher.BeginInvoke(() => StateUpdated?.Invoke());
        };

        Transport.KvmMouseMoveAbs += (monIdx, nx, ny) =>
        {
            if (!KvmEnabled || _kvmShuttingDown || ControlMode == KvmControlMode.WinMasterOnly) return;
            InjectMouseMoveAbs(monIdx, nx, ny);
        };

        Transport.KvmMouseButton += (btn, isDown) =>
        {
            if (!KvmEnabled || _kvmShuttingDown || ControlMode == KvmControlMode.WinMasterOnly) return;
            InjectMouseButton(btn, isDown);
        };

        Transport.KvmMouseScroll += (dy, dx) =>
        {
            if (!KvmEnabled || _kvmShuttingDown || ControlMode == KvmControlMode.WinMasterOnly) return;
            InjectMouseScroll(dy, dx);
        };

        Transport.KvmKeyEvent += (vk, isDown, mods) =>
        {
            if (!KvmEnabled || _kvmShuttingDown || ControlMode == KvmControlMode.WinMasterOnly) return;
            InjectKeyEvent(vk, isDown, mods);
        };

        Transport.KvmSemanticHotkey += action =>
        {
            if (action == "IDENTIFY_SCREENS")
            {
                _dispatcher.BeginInvoke(() =>
                {
                    IdentifyScreensRequested?.Invoke();
                    LogMessage?.Invoke("[Display] 收到 Mac 请求：已在 Windows 全屏幕点亮编号");
                });
                return;
            }
            if (!KvmEnabled || _kvmShuttingDown || ControlMode == KvmControlMode.WinMasterOnly) return;
            _dispatcher.BeginInvoke(() =>
            {
                ExecuteSemanticHotkey(action);
                LogMessage?.Invoke($"[Hotkey] 收到 Mac 跨系统快捷键指令 -> 执行 {action}");
            });
        };

        Transport.ConfigSync += cfg =>
        {
            _dispatcher.BeginInvoke(() => ApplyRemoteConfigSync(cfg));
        };
    }

    public void ToggleNicMultipath(NicChannelItem item, bool enabled)
    {
        string key = item.ChannelKey;
        if (enabled)
        {
            _disabledMultipathIfaces.Remove(key);
            LogMessage?.Invoke($"[Route] 已启用网卡「{item.IfaceName} ({item.LocalIp})」参与多网卡并发");
        }
        else
        {
            _disabledMultipathIfaces.Add(key);
            LogMessage?.Invoke($"[Route] 已将网卡「{item.IfaceName} ({item.LocalIp})」移出并发池");
        }
        RefreshNicChannels(DeskflowUsbConstants.WinUsbIp, DeskflowUsbConstants.MacUsbIp, DeskflowUsbConstants.DefaultUsbSpeedMbps);
        StateUpdated?.Invoke();
    }

    public void RefreshNicChannels(string winUsbIp, string macUsbIp, int usbMbps)
    {
        var list = new List<NicChannelItem>();
        bool mpEditableGlobal = MultipathEnabled;

        foreach (var l in Transport.ActiveLinksSnapshot())
        {
            string resolvedLocal = string.IsNullOrEmpty(l.LocalIp) || l.LocalIp == "auto" ? winUsbIp : l.LocalIp;
            string canonKey = NicChannelItem.CanonicalChannelKey(l.IfaceName, resolvedLocal, l.IsUsbBridge, l.PeerIp);
            if (list.Any(x => x.Id == canonKey))
                continue;

            bool isDisc = Transport.IsChannelDisconnected(l.IfaceName, resolvedLocal, l.PeerIp, l.IsUsbBridge);
            bool mpEnabled = !_disabledMultipathIfaces.Contains(canonKey);
            list.Add(new NicChannelItem
            {
                Id = canonKey,
                IfaceName = l.IfaceName,
                DisplayName = l.IsUsbBridge
                    ? AppLoc.T("USB-C 直连（未加密）", "USB-C Direct (Raw P2P)")
                    : AppLoc.T($"局域网通道 ({l.IfaceName} · TLS 1.3 已连接)", $"LAN ({l.IfaceName} · TLS 1.3)"),
                LocalIp = resolvedLocal,
                PeerIp = l.PeerIp,
                IsUsbBridge = l.IsUsbBridge,
                Online = !isDisc,
                ManuallyDisconnected = isDisc,
                EnabledForMultipath = mpEnabled,
                IsMultipathEditable = mpEditableGlobal && !isDisc,
                RttMs = l.RttMs ?? (l.IsUsbBridge ? 0.36 : 1.50),
                EstBandwidthMbps = l.EstBandwidthMbps
            });
        }

        foreach (var route in Transport.KnownDisconnectedLanRoutesSnapshot())
        {
            string canonKey = NicChannelItem.CanonicalChannelKey(route.IfaceName, route.LocalIp, isUsb: false, route.PeerIp);
            if (list.Any(x => x.Id == canonKey)) continue;
            bool mpEnabled = !_disabledMultipathIfaces.Contains(canonKey);
            list.Add(new NicChannelItem
            {
                Id = canonKey,
                IfaceName = route.IfaceName,
                DisplayName = AppLoc.T($"{route.IfaceName} (已手动断开 · 点击重连恢复)", $"{route.IfaceName} (Disconnected · Click Reconnect)"),
                LocalIp = route.LocalIp,
                PeerIp = route.PeerIp,
                IsUsbBridge = false,
                Online = false,
                ManuallyDisconnected = true,
                EnabledForMultipath = mpEnabled,
                IsMultipathEditable = false,
                RttMs = null,
                EstBandwidthMbps = route.EstBandwidthMbps
            });
        }

        foreach (var nic in DeskflowTransport.GetCachedLocalIPv4())
        {
            bool isUsb = DeskflowTransport.IsUsbBridgeIp(nic.Ip);
            string canonKey = NicChannelItem.CanonicalChannelKey(nic.IfaceName, nic.Ip, isUsb);
            if (list.Any(x => x.IsUsbBridge == isUsb && (isUsb || string.Equals(x.LocalIp, nic.Ip, StringComparison.OrdinalIgnoreCase))))
                continue;
            bool isDisc = Transport.IsChannelDisconnected(nic.IfaceName, nic.Ip, null, isUsb);
            bool mpEnabled = !_disabledMultipathIfaces.Contains(canonKey);
            list.Add(new NicChannelItem
            {
                Id = canonKey,
                IfaceName = nic.IfaceName,
                DisplayName = isDisc
                    ? AppLoc.T($"{nic.IfaceName} (已手动断开 · 点击重连恢复)", $"{nic.IfaceName} (Disconnected · Click Reconnect)")
                    : (isUsb ? AppLoc.T("USB-C 直连（就绪）", "USB-C Direct (Ready)") : AppLoc.T($"本地网卡 ({nic.IfaceName} · 在线)", $"Local NIC ({nic.IfaceName} · Online)")),
                LocalIp = nic.Ip,
                PeerIp = isUsb ? macUsbIp : ManualPeerIp,
                IsUsbBridge = isUsb,
                Online = false,
                ManuallyDisconnected = isDisc,
                EnabledForMultipath = mpEnabled,
                IsMultipathEditable = mpEditableGlobal && !isDisc,
                RttMs = null,
                EstBandwidthMbps = isUsb ? (usbMbps > 0 ? usbMbps : DeskflowUsbConstants.DefaultUsbSpeedMbps) : nic.EstMbps
            });
        }

        if (!list.Any(x => x.Id == "usb"))
        {
            bool isUsbDisc = Transport.IsIfaceDisconnected("USB-C NCM")
                || Transport.IsIfaceDisconnected(winUsbIp)
                || Transport.IsIfaceDisconnected("usb");
            bool mpEnabled = !_disabledMultipathIfaces.Contains("usb");
            list.Add(new NicChannelItem
            {
                Id = "usb",
                IfaceName = "USB-C NCM",
                DisplayName = isUsbDisc
                    ? AppLoc.T("USB-C 直连引擎 (已手动断开)", "USB-C Direct Engine (Paused)")
                    : AppLoc.T("USB-C 直连（未连接）", "USB-C Direct (Standby)"),
                LocalIp = winUsbIp,
                PeerIp = macUsbIp,
                IsUsbBridge = true,
                Online = false,
                ManuallyDisconnected = isUsbDisc,
                EnabledForMultipath = mpEnabled,
                IsMultipathEditable = mpEditableGlobal && !isUsbDisc,
                RttMs = null,
                EstBandwidthMbps = usbMbps > 0 ? usbMbps : 2400
            });
        }

        // Fixed deterministic row order (USB first, wired LAN next, Wi-Fi next, sorted by IP/PeerIP) so rows never swap on RTT jitter
        list.Sort((a, b) =>
        {
            if (a.IsUsbBridge != b.IsUsbBridge) return a.IsUsbBridge ? -1 : 1;
            bool aWifi = a.IfaceName.Contains("WLAN", StringComparison.OrdinalIgnoreCase) || a.IfaceName.Contains("Wi-Fi", StringComparison.OrdinalIgnoreCase);
            bool bWifi = b.IfaceName.Contains("WLAN", StringComparison.OrdinalIgnoreCase) || b.IfaceName.Contains("Wi-Fi", StringComparison.OrdinalIgnoreCase);
            if (aWifi != bWifi) return aWifi ? 1 : -1;
            int cmp = string.CompareOrdinal(a.LocalIp, b.LocalIp);
            return cmp != 0 ? cmp : string.CompareOrdinal(a.PeerIp, b.PeerIp);
        });

        var liveUsb = list.FirstOrDefault(x => x.IsUsbBridge && x.Online && !x.ManuallyDisconnected);
        var liveUsbSession = Transport.ActiveLinksSnapshot().FirstOrDefault(x => x.IsUsbBridge);
        if (liveUsbSession != null)
        {
            UsbRxPackets = Math.Max(UsbRxPackets, liveUsbSession.RxFrames);
            UsbTxPackets = Math.Max(UsbTxPackets, liveUsbSession.TxFrames);
        }

        bool usbBlockedOrStopping = UsbActionBusy
            || UsbStateTone is "stopping" or "completing"
            || Transport.IsIfaceDisconnected("usb");

        if (liveUsb != null && UsbStateTone is not ("stopping" or "completing"))
        {
            UsbConnectProgress = 1.0;
            UsbProgressCeil = 1.0;
            UsbStateTone = "connected";
            UsbHeadline = AppLoc.T("USB-C 点对点直连已就绪", "USB-C Direct Tunnel Active");
            UsbSubline = AppLoc.T($"USB 直连：{liveUsb.LocalIp} ↔ {liveUsb.PeerIp} · 未加密", $"USB P2P: {liveUsb.LocalIp} ↔ {liveUsb.PeerIp} · Raw P2P");
            UsbStatusText = AppLoc.T($"USB-C 点对点直连已就绪 ({liveUsb.LocalIp} ↔ {liveUsb.PeerIp} · RTT {(liveUsb.RttMs ?? 0.35):F2} ms)", $"USB-C Direct ready ({liveUsb.LocalIp} ↔ {liveUsb.PeerIp} · RTT {(liveUsb.RttMs ?? 0.35):F2} ms)");
            UsbActionHint = AppLoc.T($"隧道激活 · 延迟 {(liveUsb.RttMs ?? 0.35):F2} ms · 收包 {UsbRxPackets} / 发包 {UsbTxPackets}", $"Tunnel active · RTT {(liveUsb.RttMs ?? 0.35):F2} ms · RX {UsbRxPackets} / TX {UsbTxPackets}");
        }
        else if (!usbBlockedOrStopping && UsbProcessRunning && DeskflowTransport.GetCachedLocalIPv4().Any(x => DeskflowTransport.IsUsbBridgeIp(x.Ip)))
        {
            UsbConnectProgress = Math.Max(UsbConnectProgress, 0.88);
            UsbProgressCeil = Math.Max(UsbProgressCeil, 0.97);
            UsbStateTone = "working";
            UsbHeadline = AppLoc.T("USB 虚拟网卡已就绪，正在握手...", "USB adapter ready, handshaking...");
            UsbSubline = AppLoc.T("已分配 10.13.37.2 隧道接口，正在等待 Mac 端 (10.13.37.1) 响应端口 24810", "Assigned 10.13.37.2 interface; waiting for Mac (10.13.37.1) on port 24810");
            UsbStatusText = AppLoc.T("USB 虚拟网卡已就绪，正在与 Mac 对端握手建连 (10.13.37.x)...", "USB adapter ready, handshaking with Mac (10.13.37.x)...");
            UsbActionHint = AppLoc.T("步骤 3/3 · 正在完成端口 24810 点对点链路握手...", "Step 3/3 · Completing port 24810 P2P handshake...");
        }
        else if (UsbProcessRunning && UsbStateTone is not ("stopping" or "completing"))
        {
            if (UsbConnectProgress < 0.25) UsbConnectProgress = 0.25;
            if (UsbProgressCeil < 0.45) UsbProgressCeil = 0.45;
            UsbStateTone = "working";
            UsbStatusText = UsbActionHint;
        }
        else if (!UsbActionBusy && UsbStateTone is not ("stopping" or "completing"))
        {
            UsbConnectProgress = 0.0;
            UsbProgressCeil = 0.0;
            UsbStateTone = "waiting";
            UsbStatusText = UsbHardwareDetected
                ? AppLoc.T("已识别 Apple USB-C NCM 设备，点击「启动 USB 直连」开始绑定与建连", "Apple USB-C NCM detected — click Start USB Direct to connect")
                : AppLoc.T("未连接。接好 USB-C 线后，点击“启动 USB 直连”。", "Standby. Connect USB-C cable and click \"Start USB Direct\".");
            if (!UsbHardwareDetected && string.IsNullOrWhiteSpace(UsbActionHint))
                UsbHeadline = AppLoc.T("等待连接", "Waiting for USB-C Direct");
        }

        var pool = Transport.IsGloballyPaused
            ? new List<NicChannelItem>()
            : list.Where(x => x.Online && !x.ManuallyDisconnected).ToList();
        string? chosenCtrlId = null;
        string? chosenDataId = null;
        if (pool.Count > 0)
        {
            var minRtt = pool.OrderBy(x => x.RttMs ?? 999).First();
            chosenCtrlId = minRtt.Id;
            if (!string.IsNullOrEmpty(_lastRecommendedControlKey))
            {
                var prevCtrl = pool.FirstOrDefault(x => x.Id == _lastRecommendedControlKey);
                if (prevCtrl != null && prevCtrl.Id != minRtt.Id)
                {
                    double prevRtt = prevCtrl.RttMs ?? 999;
                    double candRtt = minRtt.RttMs ?? 999;
                    if ((prevRtt - candRtt) < 0.5 && !(minRtt.IsUsbBridge && !prevCtrl.IsUsbBridge))
                        chosenCtrlId = prevCtrl.Id;
                }
            }
            _lastRecommendedControlKey = chosenCtrlId;
            chosenDataId = pool.OrderByDescending(x => x.EstBandwidthMbps).First().Id;
        }
        else
        {
            _lastRecommendedControlKey = null;
        }

        foreach (var item in list)
        {
            item.IsRecommendedControl = (chosenCtrlId != null && item.Id == chosenCtrlId);
            item.IsRecommendedData = (chosenDataId != null && item.Id == chosenDataId);
        }

        NicChannels = list;
        SyncNicChannelsView(list);
    }

    private void SyncNicChannelsView(List<NicChannelItem> list)
    {
        if (!_dispatcher.CheckAccess())
        {
            _dispatcher.BeginInvoke(() => SyncNicChannelsView(list));
            return;
        }
        var targetIds = list.Select(x => x.Id).ToList();
        var currentIds = NicChannelsView.Select(x => x.Id).ToList();
        if (!targetIds.SequenceEqual(currentIds))
        {
            NicChannelsView.Clear();
            foreach (var item in list) NicChannelsView.Add(item);
            return;
        }
        for (int i = 0; i < list.Count; i++)
        {
            NicChannelsView[i].CopyFrom(list[i]);
        }
    }

    public void BroadcastConfigSync()
    {
        if (_applyingRemoteConfig) return;
        string modeStr = ControlMode switch
        {
            KvmControlMode.MacMasterOnly => "mac_master",
            KvmControlMode.WinMasterOnly => "win_master",
            _ => "dual"
        };
        string keymapStr = KeymapProfile switch
        {
            KeymapProfileMode.DeskflowNative => "deskflowNative",
            KeymapProfileMode.OmniflowMacHabit => "omniflowMacHabit",
            _ => "hybrid"
        };
        var payload = new WireConfigSyncPayload
        {
            SenderOs = "Windows",
            Timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0,
            ControlMode = modeStr,
            KeymapProfile = keymapStr,
            EnabledRuleIds = HotkeyRules.Where(r => r.Enabled).Select(r => r.Id).ToList()
        };
        Transport.BroadcastControlJson(DeskflowMsgType.ConfigSync, payload);
    }

    public void ApplyRemoteConfigSync(WireConfigSyncPayload cfg)
    {
        if (cfg.SenderOs == "Windows" || cfg.Timestamp < _lastAppliedConfigTs - 0.1) return;
        _lastAppliedConfigTs = cfg.Timestamp;
        _applyingRemoteConfig = true;
        try
        {
            ControlMode = cfg.ControlMode switch
            {
                "mac_master" => KvmControlMode.MacMasterOnly,
                "win_master" => KvmControlMode.WinMasterOnly,
                _ => KvmControlMode.DualActive
            };
            KeymapProfile = cfg.KeymapProfile switch
            {
                "deskflowNative" => KeymapProfileMode.DeskflowNative,
                "omniflowMacHabit" => KeymapProfileMode.OmniflowMacHabit,
                _ => KeymapProfileMode.Hybrid
            };
            var set = cfg.EnabledRuleIds.ToHashSet(StringComparer.OrdinalIgnoreCase);
            foreach (var r in HotkeyRules)
                r.Enabled = set.Contains(r.Id);
            SaveSettingsToDisk();
            LogMessage?.Invoke($"[Config] 已同步 Mac 键位映射与控制策略: {cfg.KeymapProfile} / {cfg.ControlMode} ({set.Count}条规则)");
            StateUpdated?.Invoke();
        }
        finally
        {
            _applyingRemoteConfig = false;
        }
    }

    public void ToggleHotkeyRule(string id, bool enabled)
    {
        var r = HotkeyRules.FirstOrDefault(x => x.Id == id);
        if (r != null)
        {
            r.Enabled = enabled;
            BroadcastConfigSync();
            SaveSettingsToDisk();
            LogMessage?.Invoke($"[Config] 快捷键规则「{r.TitleZh}」已{(enabled ? "启用" : "停用")}并同步至 Mac");
        }
    }

    private sealed class OmniFlowSettingsDto
    {
        public Dictionary<string, double[]>? SavedMonitorPositions { get; set; }
        public List<string>? EnabledRuleIds { get; set; }
        public bool? KvmEnabled { get; set; }
        public bool? EdgeSwitchEnabled { get; set; }
        public bool? HotkeySwitchEnabled { get; set; }
        public bool? ClipboardSyncEnabled { get; set; }
        public bool? MultipathEnabled { get; set; }
        public bool? OverlayEnabled { get; set; }
        public string? ControlMode { get; set; }
        public string? EdgeSide { get; set; }
        public double? EdgeOffsetRatio { get; set; }
        public string? EffectStyle { get; set; }
        public string? ManualPeerIp { get; set; }
        public bool? ThreeFingerOptInV2 { get; set; }
        public string? AppLanguage { get; set; }
    }

    private static string SettingsFilePath => Path.Combine(OmniFlowPaths.AppDataDirectory, "settings.json");

    public void LoadSettingsFromDisk()
    {
        try
        {
            if (!File.Exists(SettingsFilePath)) return;
            var dto = JsonSerializer.Deserialize<OmniFlowSettingsDto>(File.ReadAllText(SettingsFilePath));
            if (dto == null) return;

            if (dto.KvmEnabled.HasValue) KvmEnabled = dto.KvmEnabled.Value;
            if (dto.EdgeSwitchEnabled.HasValue) EdgeSwitchEnabled = dto.EdgeSwitchEnabled.Value;
            if (dto.HotkeySwitchEnabled.HasValue) HotkeySwitchEnabled = dto.HotkeySwitchEnabled.Value;
            if (dto.ClipboardSyncEnabled.HasValue) ClipboardSyncEnabled = dto.ClipboardSyncEnabled.Value;
            if (dto.MultipathEnabled.HasValue) MultipathEnabled = dto.MultipathEnabled.Value;
            if (dto.OverlayEnabled.HasValue) OverlayEnabled = dto.OverlayEnabled.Value;
            if (Enum.TryParse<KvmControlMode>(dto.ControlMode, out var cm)) ControlMode = cm;
            if (Enum.TryParse<ScreenEdgeSide>(dto.EdgeSide, out var es)) EdgeSide = es;
            if (dto.EdgeOffsetRatio.HasValue) EdgeOffsetRatio = Math.Clamp(dto.EdgeOffsetRatio.Value, 0.05, 0.95);
            if (Enum.TryParse<PortalEffectStyle>(dto.EffectStyle, out var ps)) EffectStyle = ps;
            if (!string.IsNullOrWhiteSpace(dto.ManualPeerIp)) ManualPeerIp = dto.ManualPeerIp;
            if (!string.IsNullOrWhiteSpace(dto.AppLanguage))
                AppLoc.Shared.IsEnglish = string.Equals(dto.AppLanguage, "en", StringComparison.OrdinalIgnoreCase);

            if (dto.EnabledRuleIds != null)
            {
                var set = dto.EnabledRuleIds.ToHashSet(StringComparer.OrdinalIgnoreCase);
                foreach (var r in HotkeyRules) r.Enabled = set.Contains(r.Id);
            }
            if (dto.ThreeFingerOptInV2 != true)
            {
                foreach (var r in HotkeyRules.Where(x => x.IsGesture))
                    r.Enabled = false;
                _threeFingerOptInV2 = true;
                SaveSettingsToDisk();
            }

            if (dto.SavedMonitorPositions != null)
            {
                _savedMonitorPositions.Clear();
                foreach (var kv in dto.SavedMonitorPositions)
                {
                    if (kv.Value != null && kv.Value.Length == 2)
                    {
                        _savedMonitorPositions[kv.Key] = new[] { kv.Value[0], kv.Value[1] };
                        _syncedPositions[kv.Key] = (kv.Value[0], kv.Value[1]);
                    }
                }
            }
        }
        catch (Exception ex)
        {
            LogMessage?.Invoke($"[Config Warn] 读取设置文件失败: {ex.Message}");
        }
    }

    public void SaveSettingsToDisk()
    {
        try
        {
            Directory.CreateDirectory(OmniFlowPaths.AppDataDirectory);
            var dto = new OmniFlowSettingsDto
            {
                SavedMonitorPositions = _savedMonitorPositions.ToDictionary(kv => kv.Key, kv => new[] { kv.Value[0], kv.Value[1] }),
                EnabledRuleIds = HotkeyRules.Where(r => r.Enabled).Select(r => r.Id).ToList(),
                KvmEnabled = KvmEnabled,
                EdgeSwitchEnabled = EdgeSwitchEnabled,
                HotkeySwitchEnabled = HotkeySwitchEnabled,
                ClipboardSyncEnabled = ClipboardSyncEnabled,
                MultipathEnabled = MultipathEnabled,
                OverlayEnabled = OverlayEnabled,
                ControlMode = ControlMode.ToString(),
                EdgeSide = EdgeSide.ToString(),
                EdgeOffsetRatio = EdgeOffsetRatio,
                EffectStyle = EffectStyle.ToString(),
                ManualPeerIp = ManualPeerIp,
                ThreeFingerOptInV2 = _threeFingerOptInV2,
                AppLanguage = AppLoc.Shared.IsEnglish ? "en" : "zh"
            };
            File.WriteAllText(SettingsFilePath, JsonSerializer.Serialize(dto, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception ex)
        {
            LogMessage?.Invoke($"[Config Warn] 保存设置失败: {ex.Message}");
        }
    }

    public void SaveMonitorLayout(bool silent = false)
    {
        foreach (var m in Monitors)
        {
            _syncedPositions[m.Id] = (m.CanvasX, m.CanvasY);
            _savedMonitorPositions[m.Id] = new[] { m.CanvasX, m.CanvasY };
        }
        SaveSettingsToDisk();
        if (!silent)
        {
            ScheduleTopologySync();
            LogMessage?.Invoke($"[Display] 已保存当前显示器排列位置 ({Monitors.Count} 块)");
            string badge = AppLoc.T("已保存位置", "Layout Saved");
            DisplaySaveStatusText = badge;
            StateUpdated?.Invoke();
            _ = Task.Run(async () =>
            {
                await Task.Delay(2500);
                _ = _dispatcher.BeginInvoke(() =>
                {
                    if (DisplaySaveStatusText == badge)
                    {
                        DisplaySaveStatusText = "";
                        StateUpdated?.Invoke();
                    }
                });
            });
        }
    }

    public void SaveInputSettingsManual()
    {
        SaveSettingsToDisk();
        BroadcastConfigSync();
        LogMessage?.Invoke("[Config] 已保存快捷键替换与共享设置");
        string badge = AppLoc.T("已保存设置", "Settings Saved");
        SettingsSaveStatusText = badge;
        StateUpdated?.Invoke();
        _ = Task.Run(async () =>
        {
            await Task.Delay(2500);
            _ = _dispatcher.BeginInvoke(() =>
            {
                if (SettingsSaveStatusText == badge)
                {
                    SettingsSaveStatusText = "";
                    StateUpdated?.Invoke();
                }
            });
        });
    }

    public void DisconnectNic(NicChannelItem item)
    {
        if (item.IsUsbBridge)
        {
            StopUsbTunnel(alsoRestoreAppleDriver: false);
            return;
        }
        Transport.DisconnectChannel(item.IfaceName, item.LocalIp, item.PeerIp);
        RefreshNicChannels(DeskflowUsbConstants.WinUsbIp, DeskflowUsbConstants.MacUsbIp, DeskflowUsbConstants.DefaultUsbSpeedMbps);
        StateUpdated?.Invoke();
    }

    public void ReconnectNic(NicChannelItem item)
    {
        Transport.ReconnectChannel(item.IfaceName, item.LocalIp, string.IsNullOrWhiteSpace(item.PeerIp) ? ManualPeerIp : item.PeerIp);
        RefreshNicChannels(DeskflowUsbConstants.WinUsbIp, DeskflowUsbConstants.MacUsbIp, DeskflowUsbConstants.DefaultUsbSpeedMbps);
        StateUpdated?.Invoke();
    }

    public void ToggleGlobalDisconnect()
    {
        if (Transport.IsGloballyPaused)
        {
            Transport.ReconnectAllLinks();
        }
        else
        {
            if (RemoteFocusActive)
            {
                SetRemoteFocus(false, broadcastToPeer: false);
            }
            Transport.DisconnectAllLinks();
        }
        RefreshNicChannels(DeskflowUsbConstants.WinUsbIp, DeskflowUsbConstants.MacUsbIp, DeskflowUsbConstants.DefaultUsbSpeedMbps);
        StateUpdated?.Invoke();
    }

    public double EffectiveTransferMbps
    {
        get
        {
            var active = NicChannels.Where(x => x.Online && x.EnabledForMultipath).ToList();
            if (MultipathEnabled && active.Count > 1)
                return Math.Max(400, active.Sum(x => x.EstBandwidthMbps));
            if (active.Count > 0)
                return Math.Max(400, active.Max(x => x.EstBandwidthMbps));
            return Math.Max(400, NicChannels.Max(x => x.EstBandwidthMbps));
        }
    }

    public double? CurrentControlRttMs
    {
        get
        {
            if (Transport.IsGloballyPaused) return null;
            var ctrl = NicChannels.FirstOrDefault(x => x.Online && !x.ManuallyDisconnected && x.IsRecommendedControl);
            return ctrl?.RttMs;
        }
    }

    public string ActiveControlSummary
    {
        get
        {
            if (Transport.IsGloballyPaused) return AppLoc.T("已断开", "Paused");
            var ctrl = NicChannels.FirstOrDefault(x => x.Online && !x.ManuallyDisconnected && x.IsRecommendedControl)
                       ?? NicChannels.FirstOrDefault(x => x.Online && !x.ManuallyDisconnected);
            if (ctrl == null) return AppLoc.T("未连接", "Disconnected");
            return ctrl.RttMs.HasValue
                ? $"{ctrl.IfaceName} ({ctrl.RttMs.Value:F2}ms)"
                : $"{ctrl.IfaceName} ({AppLoc.T("已连接", "Online")})";
        }
    }

    public string ActiveDataSummary
    {
        get
        {
            if (Transport.IsGloballyPaused) return AppLoc.T("已断开", "Paused");
            var active = NicChannels.Where(x => x.Online && !x.ManuallyDisconnected && x.EnabledForMultipath).ToList();
            if (MultipathEnabled && active.Count > 1)
                return AppLoc.Shared.IsEnglish
                    ? $"{active.Count}-NIC ({active.Sum(x => x.EstBandwidthMbps):F0} Mbps)"
                    : $"{active.Count}路并发 ({active.Sum(x => x.EstBandwidthMbps):F0} Mbps)";
            var best = active.OrderByDescending(x => x.EstBandwidthMbps).FirstOrDefault()
                       ?? NicChannels.Where(x => x.Online && !x.ManuallyDisconnected)
                           .OrderByDescending(x => x.EstBandwidthMbps).FirstOrDefault();
            return best != null ? $"{best.IfaceName} ({best.EstBandwidthMbps:F0} Mbps)" : AppLoc.T("未连接", "Disconnected");
        }
    }

    public void ConnectManualPeer()
    {
        if (!string.IsNullOrWhiteSpace(ManualPeerIp))
            Transport.AddManualPeerIp(ManualPeerIp);
        RefreshNicChannels(DeskflowUsbConstants.WinUsbIp, DeskflowUsbConstants.MacUsbIp, DeskflowUsbConstants.DefaultUsbSpeedMbps);
        StateUpdated?.Invoke();
    }

    private int _shutdownExecuted;
    private volatile bool _kvmShuttingDown;

    public void PrepareShutdownServicesOnUi()
    {
        _kvmShuttingDown = true;
        try
        {
            // Keep persisted KvmEnabled untouched so SaveSettingsToDisk never turns KVM off for next launch
            if (RemoteFocusActive)
                SetRemoteFocus(false, broadcastToPeer: false);
        }
        catch { }
        if (_mouseHook != IntPtr.Zero) { UnhookWindowsHookEx(_mouseHook); _mouseHook = IntPtr.Zero; }
        if (_kbdHook != IntPtr.Zero) { UnhookWindowsHookEx(_kbdHook); _kbdHook = IntPtr.Zero; }
        _clipboardTimer?.Stop();
        _topologySyncTimer?.Stop();
        _usbProbeTimer?.Stop();
        SaveSettingsToDisk();
    }

    public void StopTransportSync()
    {
        try { Transport.Dispose(); } catch { }
    }

    public void MarkShutdownCompleted()
    {
        System.Threading.Interlocked.Exchange(ref _shutdownExecuted, 1);
    }

    public void Dispose()
    {
        if (System.Threading.Interlocked.Exchange(ref _shutdownExecuted, 1) != 0)
            return;
        PrepareShutdownServicesOnUi();
        CleanupAndRestoreAppleUsbDriver();
        StopTransportSync();
    }
}
