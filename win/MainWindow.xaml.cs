using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;
using Microsoft.Win32;

namespace MacBridgeUI;

public partial class MainWindow : Window
{
    private readonly DeskflowService _service;
    private readonly PortalOverlayWindow _portalWindow;
    private readonly DispatcherTimer _usbProgTimer;
    private double _usbProgFloor;
    private double _usbProgCeil;
    private double _usbProgTarget;
    private double _usbProgCurrent;
    private double _usbSheenOffset = -80;
    private bool _usbProgHidden = true;
    private bool _usbProgCompleting;
    private string _lastHotkeySignature = "";
    private string _lastTrustedPeersSignature = "";
    private string _selectedDirectionTab = "mac_to_win";
    private string _lastReceivedSignature = "";
    private bool _lastLangEn;
    private bool _ready;
    private bool _explicitExit;
    private bool _isExiting;

    private readonly Dictionary<string, Border> _arrangeTileMap = new();
    private string? _draggingMonitorId;
    private Point _dragMouseOrigin;
    private double _dragTileOriginX;
    private double _dragTileOriginY;
    private Point _mainShelfDragOrigin;
    private ShelfTransferItem? _mainShelfDragCandidate;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool ChangeWindowMessageFilterEx(IntPtr hWnd, uint msg, uint action, IntPtr pChangeFilterStruct);

    [DllImport("shell32.dll")]
    private static extern void DragAcceptFiles(IntPtr hWnd, bool fAccept);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern uint DragQueryFileW(IntPtr hDrop, uint iFile, System.Text.StringBuilder? lpszFile, uint cch);

    [DllImport("shell32.dll")]
    private static extern void DragFinish(IntPtr hDrop);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    [StructLayout(LayoutKind.Sequential)]
    private struct Win32Point { public int X; public int Y; }

    [DllImport("user32.dll")]
    private static extern IntPtr WindowFromPoint(Win32Point Point);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    private ElevatedDropHost? _dropHost;
    private bool _externalDragSessionActive;
    private static readonly uint _selfPid = (uint)Environment.ProcessId;

    private const int DWMWA_USE_IMMUTABLE_DARK_MODE = 20;
    private const uint WM_DROPFILES = 0x0233;
    private const uint WM_COPYDATA = 0x004A;
    private const uint WM_COPYGLOBALDATA = 0x0049;
    private const uint WM_INPUT = 0x00FF;
    private const uint MSGFLT_ALLOW = 1;

    public MainWindow()
    {
        InitializeComponent();
        _service = new DeskflowService(Dispatcher);
        _portalWindow = new PortalOverlayWindow(_service);

        _service.StateUpdated += RefreshUiBindings;
        _service.MonitorsUpdated += RenderArrangeDisplaysCanvas;
        _service.IdentifyScreensRequested += ShowLocalIdentifyBadges;
        _service.LogMessage += AppendLog;

        RefreshDirectionTabAndLists(force: true);
        NicListControl.ItemsSource = _service.NicChannelsView;
        ShelfTasksList.ItemsSource = _service.ShelfItems;

        _usbProgTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(16) };
        _usbProgTimer.Tick += UsbProgTimer_Tick;

        _ready = true;
        _lastLangEn = AppLoc.Shared.IsEnglish;
        NavDisplaysBtn.Tag = "active";
        if (!string.IsNullOrWhiteSpace(_service.ManualPeerIp))
            PeerIpBox.Text = _service.ManualPeerIp;
        UpdateLanguagePillVisual();

        RefreshUiBindings();
        RenderArrangeDisplaysCanvas();
        AppendLog("[OmniFlow] Windows 端已启动 (双向 TLS 证书固定、SHA-256 落盘校验与 macOS 统一界面已就绪)");
    }

    private void LangZh_Click(object sender, RoutedEventArgs e)
    {
        if (!_service.IsEnglish) return;
        _service.IsEnglish = false;
        UpdateLanguagePillVisual();
        RenderArrangeDisplaysCanvas();
        RefreshDirectionTabAndLists(force: true);
        RefreshUiBindings();
    }

    private void LangEn_Click(object sender, RoutedEventArgs e)
    {
        if (_service.IsEnglish) return;
        _service.IsEnglish = true;
        UpdateLanguagePillVisual();
        RenderArrangeDisplaysCanvas();
        RefreshDirectionTabAndLists(force: true);
        RefreshUiBindings();
    }

    private void UpdateLanguagePillVisual()
    {
        bool en = AppLoc.Shared.IsEnglish;
        var activeBg = new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF));
        var clearBg = Brushes.Transparent;
        var activeFg = Brushes.White;
        var dimFg = new SolidColorBrush(Color.FromRgb(0xA6, 0xA6, 0xAE));

        LangZhBtn.Background = en ? clearBg : activeBg;
        LangZhBtn.Foreground = en ? dimFg : activeFg;
        LangZhBtn.FontWeight = en ? FontWeights.Medium : FontWeights.Bold;

        LangEnBtn.Background = en ? activeBg : clearBg;
        LangEnBtn.Foreground = en ? activeFg : dimFg;
        LangEnBtn.FontWeight = en ? FontWeights.Bold : FontWeights.Medium;
    }

    private void OpenGitHubProfile_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Process.Start(new ProcessStartInfo(AppLoc.GitHubProfileUrl) { UseShellExecute = true });
        }
        catch { }
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd != IntPtr.Zero)
        {
            int useDark = 1;
            try { DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMUTABLE_DARK_MODE, ref useDark, sizeof(int)); } catch { }
            ChangeWindowMessageFilterEx(hwnd, WM_DROPFILES, MSGFLT_ALLOW, IntPtr.Zero);
            ChangeWindowMessageFilterEx(hwnd, WM_COPYDATA, MSGFLT_ALLOW, IntPtr.Zero);
            ChangeWindowMessageFilterEx(hwnd, WM_COPYGLOBALDATA, MSGFLT_ALLOW, IntPtr.Zero);
            DragAcceptFiles(hwnd, true);
            HwndSource.FromHwnd(hwnd)?.AddHook(WndProc);
            _service.EnsureTouchpadRawInputRegistered(hwnd);
            InitElevatedDropBridge();
        }
    }

    private void InitElevatedDropBridge()
    {
        if (_dropHost != null || !DeskflowService.IsRunningAsAdministrator()) return;
        _dropHost = new ElevatedDropHost(Dispatcher);
        _dropHost.LogMessage += AppendLog;
        _dropHost.EdgeDragEntered += files =>
        {
            if (!_service.ShouldIgnoreShelfDrop(files))
                _service.EvaluateShelfDrag(files);
        };
        _dropHost.EdgeDragLeft += () =>
        {
            if (_service.Phase == PortalTransferPhase.HoverExpand)
            {
                _service.Phase = PortalTransferPhase.Idle;
                _portalWindow.SyncVisualState();
            }
        };
        _dropHost.EdgeDropped += files =>
        {
            _externalDragSessionActive = false;
            if (!_service.ShouldIgnoreShelfDrop(files))
                _service.SendFilesFromWindows(files);
        };
        _dropHost.MainDragEntered += () =>
        {
            SetDropZoneHighlighted(true);
        };
        _dropHost.MainDragLeft += () =>
        {
            SetDropZoneHighlighted(false);
        };
        _dropHost.MainDropped += files =>
        {
            _externalDragSessionActive = false;
            SetDropZoneHighlighted(false);
            if (!_service.ShouldIgnoreShelfDrop(files))
                _service.SendFilesFromWindows(files);
        };
        _portalWindow.OverlayBoundsChanged += () =>
        {
            if (_dropHost is { IsActive: true } && _externalDragSessionActive && _service.Phase == PortalTransferPhase.HoverExpand)
            {
                _dropHost.UpdateEdgeBounds(ComputeEdgeDropRectPx());
            }
        };
        _service.ExternalDragMoved += OnExternalDragMoved;
        _service.ExternalDragEnded += OnExternalDragEnded;
        _dropHost.Start();
    }

    private void OnExternalDragMoved(int cursorX, int cursorY)
    {
        if (_dropHost == null || !_dropHost.IsActive || _externalDragSessionActive) return;
        _externalDragSessionActive = true;
        Int32Rect edgeRect = ComputeEdgeDropRectPx();
        Int32Rect mainRect = ComputeMainDropRectPx(_dropHost.ProxyProcessId);
        _dropHost.ShowTargets(edgeRect, mainRect);
    }

    private void OnExternalDragEnded()
    {
        _externalDragSessionActive = false;
        SetDropZoneHighlighted(false);
        _dropHost?.ScheduleHideAfterRelease();
    }

    private Int32Rect ComputeEdgeDropRectPx()
    {
        if (!_service.OverlayEnabled || !_portalWindow.IsVisible || _portalWindow.ActualWidth <= 0 || _portalWindow.ActualHeight <= 0)
            return Int32Rect.Empty;
        try
        {
            Point p0 = _portalWindow.PointToScreen(new Point(0, 0));
            Point p1 = _portalWindow.PointToScreen(new Point(_portalWindow.ActualWidth, _portalWindow.ActualHeight));
            int x = (int)Math.Round(Math.Min(p0.X, p1.X));
            int y = (int)Math.Round(Math.Min(p0.Y, p1.Y));
            int w = Math.Max(1, (int)Math.Round(Math.Abs(p1.X - p0.X)));
            int h = Math.Max(1, (int)Math.Round(Math.Abs(p1.Y - p0.Y)));
            const int minStripPx = 18;
            if (_service.EffectStyle == PortalEffectStyle.BlackHole && _service.Phase == PortalTransferPhase.Idle && _service.ShelfItems.Count == 0)
            {
                if ((_service.EdgeSide == ScreenEdgeSide.Left || _service.EdgeSide == ScreenEdgeSide.Right) && w < minStripPx)
                {
                    if (_service.EdgeSide == ScreenEdgeSide.Right) x -= (minStripPx - w);
                    w = minStripPx;
                }
                else if ((_service.EdgeSide == ScreenEdgeSide.Top || _service.EdgeSide == ScreenEdgeSide.Bottom) && h < minStripPx)
                {
                    if (_service.EdgeSide == ScreenEdgeSide.Bottom) y -= (minStripPx - h);
                    h = minStripPx;
                }
            }
            return new Int32Rect(x, y, w, h);
        }
        catch { return Int32Rect.Empty; }
    }

    private Int32Rect ComputeMainDropRectPx(uint proxyPid)
    {
        if (!IsVisible || WindowState == WindowState.Minimized || PagePortal.Visibility != Visibility.Visible ||
            !DropZoneBorder.IsVisible || DropZoneBorder.ActualWidth <= 10 || DropZoneBorder.ActualHeight <= 10)
            return Int32Rect.Empty;
        try
        {
            Point p0 = DropZoneBorder.PointToScreen(new Point(0, 0));
            Point p1 = DropZoneBorder.PointToScreen(new Point(DropZoneBorder.ActualWidth, DropZoneBorder.ActualHeight));
            int x = (int)Math.Round(Math.Min(p0.X, p1.X));
            int y = (int)Math.Round(Math.Min(p0.Y, p1.Y));
            int w = Math.Max(1, (int)Math.Round(Math.Abs(p1.X - p0.X)));
            int h = Math.Max(1, (int)Math.Round(Math.Abs(p1.Y - p0.Y)));

            int insetX = Math.Min(16, Math.Max(4, w / 6));
            int insetY = Math.Min(16, Math.Max(4, h / 6));
            bool anyVisible =
                IsScreenPointOwnedByUs(x + w / 2, y + h / 2, proxyPid) ||
                IsScreenPointOwnedByUs(x + insetX, y + insetY, proxyPid) ||
                IsScreenPointOwnedByUs(x + w - insetX, y + insetY, proxyPid) ||
                IsScreenPointOwnedByUs(x + insetX, y + h - insetY, proxyPid) ||
                IsScreenPointOwnedByUs(x + w - insetX, y + h - insetY, proxyPid);
            if (!anyVisible) return Int32Rect.Empty;
            return new Int32Rect(x, y, w, h);
        }
        catch { return Int32Rect.Empty; }
    }

    private static bool IsScreenPointOwnedByUs(int sx, int sy, uint proxyPid)
    {
        IntPtr hit = WindowFromPoint(new Win32Point { X = sx, Y = sy });
        if (hit == IntPtr.Zero) return false;
        GetWindowThreadProcessId(hit, out uint pid);
        return pid == _selfPid || (proxyPid != 0 && pid == proxyPid);
    }

    private void SetDropZoneHighlighted(bool active)
    {
        if (DropZoneBorder == null) return;
        DropZoneBorder.BorderBrush = active
            ? new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF))
            : new SolidColorBrush(Color.FromRgb(0x48, 0x48, 0x4D));
        DropZoneBorder.Background = active
            ? new SolidColorBrush(Color.FromRgb(0x1D, 0x2A, 0x3A))
            : new SolidColorBrush(Color.FromRgb(0x23, 0x24, 0x27));
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if ((uint)msg == WM_INPUT)
        {
            _service.HandleTouchpadRawInput(lParam);
            return IntPtr.Zero;
        }
        if ((uint)msg == WM_DROPFILES)
        {
            uint count = DragQueryFileW(wParam, 0xFFFFFFFF, null, 0);
            var files = new List<string>();
            for (uint i = 0; i < count; i++)
            {
                var sb = new System.Text.StringBuilder(1024);
                if (DragQueryFileW(wParam, i, sb, (uint)sb.Capacity) > 0)
                    files.Add(sb.ToString());
            }
            DragFinish(wParam);
            if (files.Count > 0)
            {
                handled = true;
                _service.SendFilesFromWindows(files.ToArray());
            }
        }
        return IntPtr.Zero;
    }

    private void RefreshUiBindings()
    {
        if (!_ready) return;

        int onlineCount = _service.NicChannels.Count(x => x.Online && !x.ManuallyDisconnected);
        if (_service.GlobalPaused)
        {
            ConnDot.Fill = new SolidColorBrush(Color.FromRgb(0xFF, 0x9F, 0x0A));
            ConnStatusText.Text = AppLoc.T("已手动全部断开", "All channels paused");
            ConnStatusText.Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0x9F, 0x0A));
        }
        else if (onlineCount > 0)
        {
            ConnDot.Fill = new SolidColorBrush(Color.FromRgb(0x30, 0xD1, 0x58));
            ConnStatusText.Text = AppLoc.T($"已连接（{onlineCount} 条通道）", $"Connected · {onlineCount} link(s)");
            ConnStatusText.Foreground = new SolidColorBrush(Color.FromRgb(0xB8, 0xB8, 0xBE));
        }
        else
        {
            ConnDot.Fill = new SolidColorBrush(Color.FromRgb(0x73, 0x73, 0x78));
            ConnStatusText.Text = AppLoc.T("等待连接", "Waiting for peer");
            ConnStatusText.Foreground = new SolidColorBrush(Color.FromRgb(0xB8, 0xB8, 0xBE));
        }

        SidebarFocusText.Text = _service.RemoteFocusActive ? "Mac" : AppLoc.T("Windows 本机", "This PC");
        SidebarFocusText.Foreground = _service.RemoteFocusActive
            ? new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF))
            : new SolidColorBrush(Color.FromRgb(0x30, 0xD1, 0x58));

        FocusToggleBtn.Content = _service.RemoteFocusActive
            ? AppLoc.T("切回 Windows", "Return to Windows")
            : AppLoc.T("切到 Mac 控制", "Switch to Mac");
        GlobalDisconnectBtn.Content = _service.GlobalPaused
            ? AppLoc.T("恢复连接", "Reconnect All")
            : AppLoc.T("全部断开", "Disconnect All");
        PeerConnectBtn.Visibility = (onlineCount > 0 && !_service.GlobalPaused) ? Visibility.Collapsed : Visibility.Visible;

        _ready = false;
        try
        {
            KvmToggle.IsChecked = _service.KvmEnabled;
            EdgeSwitchToggle.IsChecked = _service.EdgeSwitchEnabled;
            HotkeySwitchToggle.IsChecked = _service.HotkeySwitchEnabled;
            ClipToggle.IsChecked = _service.ClipboardSyncEnabled;
            MultipathToggle.IsChecked = _service.MultipathEnabled;
            OverlayToggle.IsChecked = _service.OverlayEnabled;

            CtrlDualRadio.IsChecked = (_service.ControlMode == KvmControlMode.DualActive);
            CtrlMacRadio.IsChecked = (_service.ControlMode == KvmControlMode.MacMasterOnly);
            CtrlWinRadio.IsChecked = (_service.ControlMode == KvmControlMode.WinMasterOnly);

            StyleBlackHoleRadio.IsChecked = (_service.EffectStyle == PortalEffectStyle.BlackHole);
            StyleCubeRadio.IsChecked = (_service.EffectStyle == PortalEffectStyle.FloatingCube);

            EdgeLeftRadio.IsChecked = (_service.EdgeSide == ScreenEdgeSide.Left);
            EdgeRightRadio.IsChecked = (_service.EdgeSide == ScreenEdgeSide.Right);
            EdgeTopRadio.IsChecked = (_service.EdgeSide == ScreenEdgeSide.Top);
            EdgeBottomRadio.IsChecked = (_service.EdgeSide == ScreenEdgeSide.Bottom);

            PortalEdgeSyncHint.Text = AppLoc.T($"屏幕边缘 · 屏幕 #{_service.PortalMonitorIndex}", $"Screen Edge · Display #{_service.PortalMonitorIndex}");
            PortalOffsetSlider.Value = _service.EdgeOffsetRatio;
            PortalOffsetText.Text = AppLoc.T($"边缘位置（{(int)Math.Round(_service.EdgeOffsetRatio * 100)}%）", $"Edge Offset ({(int)Math.Round(_service.EdgeOffsetRatio * 100)}%)");

            if (!string.IsNullOrEmpty(_service.LastTransferSummary))
            {
                LastTransferSummaryText.Text = _service.LastTransferSummary;
                LastTransferSummaryText.Visibility = Visibility.Visible;
            }
            else
            {
                LastTransferSummaryText.Visibility = Visibility.Collapsed;
            }

            // Sync MacBridge-style USB Direct Tunnel Page
            var liveUsbNic = _service.NicChannels.FirstOrDefault(x => x.IsUsbBridge && x.Online && !x.ManuallyDisconnected);
            bool usbRunning = liveUsbNic != null || _service.UsbProcessRunning || _service.UsbStateTone is "stopping" or "completing";
            UsbHeroDot.Fill = _service.UsbStateTone switch
            {
                "connected" => new SolidColorBrush(Color.FromRgb(0x30, 0xD1, 0x58)),
                "working" => new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF)),
                "stopping" or "completing" => new SolidColorBrush(Color.FromRgb(0xFF, 0x9F, 0x0A)),
                _ => new SolidColorBrush(Color.FromRgb(0x63, 0x63, 0x66))
            };
            UsbHeadlineText.Text = _service.UsbHeadline;
            UsbSublineText.Text = _service.UsbSubline;
            double nextPct = Math.Clamp(_service.UsbConnectProgress * 100.0, 0.0, 100.0);
            if (_service.UsbStateTone == "working" || _service.UsbStateTone == "stopping")
            {
                double minCeil = Math.Min(98.0, nextPct);
                double nextCeil = Math.Clamp(_service.UsbProgressCeil * 100.0, minCeil, 98.0);
                if (_usbProgHidden || Math.Abs(nextPct - _usbProgFloor) > 0.5)
                    SetUsbProgress(nextPct, nextCeil);
            }
            else if (_service.UsbStateTone == "connected" || _service.UsbStateTone == "completing")
            {
                if (_usbProgHidden && _service.UsbStateTone == "completing")
                    SetUsbProgress(65, 98);
                if (!_usbProgHidden && !_usbProgCompleting)
                    _ = CompleteUsbProgressAndHideAsync(finalizeServiceStop: _service.UsbStateTone == "completing");
                else if (_usbProgHidden && _service.UsbStateTone == "completing")
                    _service.FinishUsbCompletingTransition();
            }
            else
            {
                if (!_usbProgHidden && !_usbProgCompleting)
                    HideUsbProgressImmediate();
            }
            UsbProgressHintText.Text = _service.UsbActionHint;

            UsbConnectBtn.Visibility = usbRunning ? Visibility.Collapsed : Visibility.Visible;
            UsbDisconnectBtn.Visibility = usbRunning ? Visibility.Visible : Visibility.Collapsed;
            UsbConnectBtn.IsEnabled = !_service.UsbActionBusy;
            UsbDisconnectBtn.IsEnabled = !_service.UsbActionBusy;
            UsbRestoreBtn.IsEnabled = !_service.UsbActionBusy;

            UsbPortCardValue.Text = _service.UsbHardwareDetected ? _service.UsbHardwareSummary : AppLoc.T("没检测到苹果 USB 设备", "No Apple USB device detected");
            UsbPortCardSub.Text = _service.UsbHardwareDetected
                ? AppLoc.T($"驱动: {_service.UsbDriverService} · {_service.UsbSpeedLabel}", $"Driver: {_service.UsbDriverService} · {_service.UsbSpeedLabel}")
                : AppLoc.T("用 USB-C 线连上 Mac 就行", "Connect Mac via USB-C cable");
            UsbIpCardValue.Text = liveUsbNic != null
                ? $"{liveUsbNic.LocalIp} ↔ {liveUsbNic.PeerIp}"
                : $"{DeskflowUsbConstants.WinUsbIp} ↔ {DeskflowUsbConstants.MacUsbIp}";
            UsbIpCardSub.Text = liveUsbNic != null ? AppLoc.T("直连已通 (:24810)", "Direct Tunnel Ready (:24810)") : AppLoc.T("USB 直连", "USB Direct");
            UsbTrafficCardValue.Text = AppLoc.T($"收 {_service.UsbRxPackets} / 发 {_service.UsbTxPackets}", $"RX {_service.UsbRxPackets} / TX {_service.UsbTxPackets}");
            UsbTrafficCardSub.Text = liveUsbNic?.RttMs != null
                ? AppLoc.T($"当前延迟 {liveUsbNic.RttMs.Value:F2} ms", $"RTT {liveUsbNic.RttMs.Value:F2} ms")
                : AppLoc.T("暂未连接", "Not handshaked");
            UsbLogBox.Text = string.Join(Environment.NewLine, _service.UsbLogs.TakeLast(30));
            UsbLogBox.ScrollToEnd();
        }
        finally
        {
            _ready = true;
        }

        ControlRouteText.Text = AppLoc.T($"控制连接：{_service.ActiveControlSummary}", $"Control: {_service.ActiveControlSummary}");
        DataRouteText.Text = AppLoc.T($"文件连接：{_service.ActiveDataSummary}", $"Data: {_service.ActiveDataSummary}");
        ChannelModeSubtitle.Text = _service.MultipathEnabled
            ? AppLoc.T("多网卡传输", "Multipath Active")
            : AppLoc.T("自动选择线路", "Auto Route");

        bool langChanged = _lastLangEn != AppLoc.Shared.IsEnglish;
        _lastLangEn = AppLoc.Shared.IsEnglish;
        RefreshDirectionTabAndLists(force: langChanged);

        double? ctrlRtt = _service.CurrentControlRttMs;
        if (ctrlRtt.HasValue && ctrlRtt.Value >= 10.0)
        {
            HighLatencyDragBadge.Visibility = Visibility.Visible;
            HighLatencyDragBadgeText.Text = AppLoc.T($"当前延迟较高 ({(int)Math.Round(ctrlRtt.Value)} ms)，可能影响拖移体验", $"High latency ({(int)Math.Round(ctrlRtt.Value)} ms) — wired/USB recommended");
        }
        else
        {
            HighLatencyDragBadge.Visibility = Visibility.Collapsed;
        }

        if (_service.PendingPairing != null)
        {
            PairingBanner.Visibility = Visibility.Visible;
            PairingTitleText.Text = AppLoc.T($"有设备请求配对 · 短码：{_service.PendingPairing.SasCode}", $"Pairing Request · SAS: {_service.PendingPairing.SasCode}");
            string fp = _service.PendingPairing.Fingerprint;
            PairingDetailText.Text = AppLoc.T(
                $"设备：{_service.PendingPairing.HostName} ({_service.PendingPairing.RemoteIp}) · 指纹：{fp[..Math.Min(32, fp.Length)]}… · 请确认两端短码一致",
                $"Peer: {_service.PendingPairing.HostName} ({_service.PendingPairing.RemoteIp}) · FP: {fp[..Math.Min(32, fp.Length)]}… · Verify SAS matches");
        }
        else
        {
            PairingBanner.Visibility = Visibility.Collapsed;
        }

        TrustedPeersStatusText.Text = AppLoc.T($"已配对设备：{_service.TrustedPeerCount} 台", $"Trusted Peers: {_service.TrustedPeerCount}");
        string lfp = _service.Transport.LocalFingerprint;
        LocalTlsFingerprintText.Text = AppLoc.T($"本机识别码: {lfp[..Math.Min(36, lfp.Length)]}...", $"Local Fingerprint: {lfp[..Math.Min(36, lfp.Length)]}...");
        ClearTrustedPeersBtn.Visibility = _service.TrustedPeerCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        var peers = _service.TrustedPeersList;
        EmptyTrustedPeersText.Visibility = peers.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        string peersSig = string.Join("|", peers.Select(p => $"{p.Fingerprint}:{p.HostName}:{p.PairedAtIso}"));
        if (peersSig != _lastTrustedPeersSignature)
        {
            _lastTrustedPeersSignature = peersSig;
            TrustedPeersList.ItemsSource = null;
            TrustedPeersList.ItemsSource = peers;
        }

        ShelfTasksCard.Visibility = _service.ShelfItems.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        ShelfTasksHeaderText.Text = AppLoc.T($"当前传输架与待取文件 ({_service.ShelfItems.Count})", $"Active Transfers ({_service.ShelfItems.Count})");
        if (langChanged && _service.ShelfItems.Count > 0)
        {
            ShelfTasksList.ItemsSource = null;
            ShelfTasksList.ItemsSource = _service.ShelfItems;
        }

        DisplaySaveBadge.Visibility = string.IsNullOrEmpty(_service.DisplaySaveStatusText) ? Visibility.Collapsed : Visibility.Visible;
        DisplaySaveBadgeText.Text = _service.DisplaySaveStatusText;
        SettingsSaveBadge.Visibility = string.IsNullOrEmpty(_service.SettingsSaveStatusText) ? Visibility.Collapsed : Visibility.Visible;
        SettingsSaveBadgeText.Text = _service.SettingsSaveStatusText;

        EmptyReceivedHintText.Visibility = _service.ReceivedFiles.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        string recSig = string.Join("|", _service.ReceivedFiles.Select(f => f.Id));
        if (recSig != _lastReceivedSignature)
        {
            _lastReceivedSignature = recSig;
            ReceivedFilesList.ItemsSource = null;
            ReceivedFilesList.ItemsSource = _service.ReceivedFiles;
        }

        _portalWindow.SyncVisualState();
    }

    // MARK: - 2D Spatial Arrange Displays Canvas Rendering & Dragging

    private void ArrangeCanvas_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (ArrangeCanvas.ActualWidth > 100 && ArrangeCanvas.ActualHeight > 100)
        {
            _service.CenterDisplayCluster(ArrangeCanvas.ActualWidth, ArrangeCanvas.ActualHeight);
        }
        RenderArrangeDisplaysCanvas();
    }

    private void UpdateSelectedMonitorFooter(IndependentMonitorItem? sel)
    {
        if (sel == null) return;
        bool isMac = sel.OsKind.Equals("macOS", StringComparison.OrdinalIgnoreCase);
        SelectedMonitorBar.Background = isMac
            ? new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF))
            : new SolidColorBrush(Color.FromRgb(0x30, 0xD1, 0x58));
        SelectedMonitorTitle.Text = $"{sel.Name} ({sel.OsKind})";
        SelectedMonitorText.Text = AppLoc.T(
            $"{sel.WidthPx} × {sel.HeightPx} · 缩放 {(int)Math.Round(sel.ScaleFactor * 100)}% · 位置 ({(int)sel.CanvasX}, {(int)sel.CanvasY})",
            $"{sel.WidthPx} × {sel.HeightPx} · Scale {(int)Math.Round(sel.ScaleFactor * 100)}% · Pos ({(int)sel.CanvasX}, {(int)sel.CanvasY})");
    }

    private void RenderArrangeDisplaysCanvas()
    {
        if (ArrangeCanvas == null) return;
        ArrangeCanvas.Children.Clear();
        _arrangeTileMap.Clear();

        double cw = Math.Max(640, ArrangeCanvas.ActualWidth);
        double ch = Math.Max(340, ArrangeCanvas.ActualHeight);

        for (double y = 28; y < ch; y += 28)
        {
            for (double x = 28; x < cw; x += 28)
            {
                var dot = new Ellipse
                {
                    Width = 2,
                    Height = 2,
                    Fill = new SolidColorBrush(Color.FromArgb(20, 255, 255, 255)),
                    IsHitTestVisible = false
                };
                Canvas.SetLeft(dot, x);
                Canvas.SetTop(dot, y);
                ArrangeCanvas.Children.Add(dot);
            }
        }

        foreach (var mon in _service.Monitors)
        {
            bool isMac = mon.OsKind.Equals("macOS", StringComparison.OrdinalIgnoreCase);
            bool isSelected = mon.Id == _service.SelectedMonitorId;

            var tile = new Border
            {
                Width = mon.AspectWidth,
                Height = mon.AspectHeight,
                CornerRadius = new CornerRadius(7),
                BorderBrush = isSelected
                    ? new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF))
                    : new SolidColorBrush(Color.FromArgb(120, 255, 255, 255)),
                BorderThickness = new Thickness(isSelected ? 2.5 : 1.0),
                Cursor = Cursors.SizeAll,
                Tag = mon.Id,
                ClipToBounds = true,
                Background = new LinearGradientBrush(
                    isMac ? Color.FromRgb(0x2A, 0x6F, 0xB0) : Color.FromRgb(0x1E, 0x40, 0x78),
                    isMac ? Color.FromRgb(0x16, 0x4E, 0x63) : Color.FromRgb(0x12, 0x35, 0x48),
                    90.0)
            };

            var innerGrid = new Grid();

            if (mon.IsPrimary)
            {
                var menuStrip = new Border
                {
                    Height = 8,
                    VerticalAlignment = VerticalAlignment.Top,
                    Background = new SolidColorBrush(Color.FromArgb(210, 255, 255, 255))
                };
                innerGrid.Children.Add(menuStrip);
            }

            var infoStack = new StackPanel
            {
                VerticalAlignment = VerticalAlignment.Bottom,
                HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(6, 0, 6, 7)
            };

            var badgeRow = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, 0, 0, 2)
            };

            var osBadge = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(145, 0, 0, 0)),
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(5, 1, 5, 1),
                Margin = new Thickness(0, 0, 4, 0),
                Child = new TextBlock
                {
                    Text = isMac ? "macOS" : "Windows",
                    Foreground = Brushes.White,
                    FontSize = 9,
                    FontWeight = FontWeights.Bold
                }
            };
            badgeRow.Children.Add(osBadge);
            badgeRow.Children.Add(new TextBlock
            {
                Text = mon.OrderTag,
                Foreground = Brushes.White,
                FontSize = 9.5,
                FontWeight = FontWeights.Bold,
                VerticalAlignment = VerticalAlignment.Center
            });
            infoStack.Children.Add(badgeRow);

            infoStack.Children.Add(new TextBlock
            {
                Text = mon.Name,
                Foreground = Brushes.White,
                FontSize = 11,
                FontWeight = FontWeights.SemiBold,
                HorizontalAlignment = HorizontalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis
            });

            infoStack.Children.Add(new TextBlock
            {
                Text = mon.ResolutionTag,
                Foreground = new SolidColorBrush(Color.FromRgb(0xE0, 0xE0, 0xE6)),
                FontSize = 9.5,
                HorizontalAlignment = HorizontalAlignment.Center
            });

            innerGrid.Children.Add(infoStack);
            tile.Child = innerGrid;
            tile.MouseLeftButtonDown += MonitorTile_MouseLeftButtonDown;

            Canvas.SetLeft(tile, mon.CanvasX);
            Canvas.SetTop(tile, mon.CanvasY);
            _arrangeTileMap[mon.Id] = tile;
            ArrangeCanvas.Children.Add(tile);
        }

        UpdateSelectedMonitorFooter(_service.Monitors.FirstOrDefault(m => m.Id == _service.SelectedMonitorId) ?? _service.Monitors.FirstOrDefault());
    }

    private void MonitorTile_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (sender is Border tile && tile.Tag is string id)
        {
            var mon = _service.Monitors.FirstOrDefault(m => m.Id == id);
            if (mon == null) return;

            _service.SelectedMonitorId = id;
            _draggingMonitorId = id;
            _dragMouseOrigin = e.GetPosition(ArrangeCanvas);
            _dragTileOriginX = mon.CanvasX;
            _dragTileOriginY = mon.CanvasY;
            ArrangeCanvas.CaptureMouse();
            e.Handled = true;

            foreach (var kv in _arrangeTileMap)
            {
                bool selNow = kv.Key == id;
                kv.Value.BorderBrush = selNow
                    ? new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF))
                    : new SolidColorBrush(Color.FromArgb(120, 255, 255, 255));
                kv.Value.BorderThickness = new Thickness(selNow ? 2.5 : 1.0);
                Panel.SetZIndex(kv.Value, selNow ? 10 : 1);
            }
            UpdateSelectedMonitorFooter(mon);
        }
    }

    private void ArrangeCanvas_MouseMove(object sender, MouseEventArgs e)
    {
        if (_draggingMonitorId == null) return;
        var cur = e.GetPosition(ArrangeCanvas);
        double dx = cur.X - _dragMouseOrigin.X;
        double dy = cur.Y - _dragMouseOrigin.Y;

        double cw = Math.Max(640, ArrangeCanvas.ActualWidth);
        double ch = Math.Max(340, ArrangeCanvas.ActualHeight);

        _service.UpdateMonitorPosition2D(
            _draggingMonitorId,
            _dragTileOriginX + dx,
            _dragTileOriginY + dy,
            cw,
            ch);

        var mon = _service.Monitors.FirstOrDefault(m => m.Id == _draggingMonitorId);
        if (mon != null)
        {
            if (_arrangeTileMap.TryGetValue(_draggingMonitorId, out var tile))
            {
                Canvas.SetLeft(tile, mon.CanvasX);
                Canvas.SetTop(tile, mon.CanvasY);
            }
            UpdateSelectedMonitorFooter(mon);
        }
    }

    private void ArrangeCanvas_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (_draggingMonitorId != null)
        {
            string draggedId = _draggingMonitorId;
            _draggingMonitorId = null;
            ArrangeCanvas.ReleaseMouseCapture();
            double cw = Math.Max(640, ArrangeCanvas.ActualWidth);
            double ch = Math.Max(340, ArrangeCanvas.ActualHeight);
            _service.FinishMonitorDrag(draggedId, cw, ch);
            RenderArrangeDisplaysCanvas();
        }
    }

    // MARK: - Sidebar Page Navigation

    private void SetActiveNavPage(string page)
    {
        PageDisplays.Visibility = page == "displays" ? Visibility.Visible : Visibility.Collapsed;
        PageInput.Visibility = page == "input" ? Visibility.Visible : Visibility.Collapsed;
        PagePortal.Visibility = page == "portal" ? Visibility.Visible : Visibility.Collapsed;
        PageUsb.Visibility = page == "usb" ? Visibility.Visible : Visibility.Collapsed;
        PageNetwork.Visibility = page == "network" ? Visibility.Visible : Visibility.Collapsed;

        NavDisplaysBtn.Background = page == "displays" ? new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF)) : Brushes.Transparent;
        NavInputBtn.Background = page == "input" ? new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF)) : Brushes.Transparent;
        NavPortalBtn.Background = page == "portal" ? new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF)) : Brushes.Transparent;
        NavUsbBtn.Background = page == "usb" ? new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF)) : Brushes.Transparent;
        NavNetworkBtn.Background = page == "network" ? new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF)) : Brushes.Transparent;

        NavDisplaysBtn.Tag = page == "displays" ? "active" : null;
        NavInputBtn.Tag = page == "input" ? "active" : null;
        NavPortalBtn.Tag = page == "portal" ? "active" : null;
        NavUsbBtn.Tag = page == "usb" ? "active" : null;
        NavNetworkBtn.Tag = page == "network" ? "active" : null;
    }

    private void NavDisplays_Click(object sender, RoutedEventArgs e) => SetActiveNavPage("displays");
    private void NavInput_Click(object sender, RoutedEventArgs e) => SetActiveNavPage("input");
    private void NavPortal_Click(object sender, RoutedEventArgs e) => SetActiveNavPage("portal");
    private void NavUsb_Click(object sender, RoutedEventArgs e) => SetActiveNavPage("usb");
    private void NavNetwork_Click(object sender, RoutedEventArgs e) => SetActiveNavPage("network");

    private void Setting_Changed(object sender, RoutedEventArgs e)
    {
        if (!_ready) return;

        _service.KvmEnabled = KvmToggle.IsChecked == true;
        _service.EdgeSwitchEnabled = EdgeSwitchToggle.IsChecked == true;
        _service.HotkeySwitchEnabled = HotkeySwitchToggle.IsChecked == true;
        _service.ClipboardSyncEnabled = ClipToggle.IsChecked == true;
        bool prevMp = _service.MultipathEnabled;
        _service.MultipathEnabled = MultipathToggle.IsChecked == true;
        _service.OverlayEnabled = OverlayToggle.IsChecked == true;
        if (prevMp != _service.MultipathEnabled)
            _service.RefreshNicChannels(DeskflowUsbConstants.WinUsbIp, DeskflowUsbConstants.MacUsbIp, DeskflowUsbConstants.DefaultUsbSpeedMbps);

        var prevCtrl = _service.ControlMode;
        if (CtrlMacRadio.IsChecked == true) _service.ControlMode = KvmControlMode.MacMasterOnly;
        else if (CtrlWinRadio.IsChecked == true) _service.ControlMode = KvmControlMode.WinMasterOnly;
        else _service.ControlMode = KvmControlMode.DualActive;

        if (_service.ControlMode != prevCtrl)
            _service.BroadcastConfigSync();

        _service.EffectStyle = StyleCubeRadio.IsChecked == true ? PortalEffectStyle.FloatingCube : PortalEffectStyle.BlackHole;

        if (EdgeRightRadio.IsChecked == true) _service.EdgeSide = ScreenEdgeSide.Right;
        else if (EdgeTopRadio.IsChecked == true) _service.EdgeSide = ScreenEdgeSide.Top;
        else if (EdgeBottomRadio.IsChecked == true) _service.EdgeSide = ScreenEdgeSide.Bottom;
        else _service.EdgeSide = ScreenEdgeSide.Left;

        _service.SaveSettingsToDisk();
        _portalWindow.SyncVisualState();
        if (_service.ControlMode != prevCtrl || prevMp != _service.MultipathEnabled)
            RefreshUiBindings();
    }

    private void DirTabMacToWin_Click(object sender, RoutedEventArgs e)
    {
        if (_service.ControlMode == KvmControlMode.WinMasterOnly) return;
        _selectedDirectionTab = "mac_to_win";
        RefreshDirectionTabAndLists(force: true);
    }

    private void DirTabWinToMac_Click(object sender, RoutedEventArgs e)
    {
        if (_service.ControlMode == KvmControlMode.MacMasterOnly) return;
        _selectedDirectionTab = "win_to_mac";
        RefreshDirectionTabAndLists(force: true);
    }

    private void RefreshDirectionTabAndLists(bool force)
    {
        bool macToWinBlocked = _service.ControlMode == KvmControlMode.WinMasterOnly;
        bool winToMacBlocked = _service.ControlMode == KvmControlMode.MacMasterOnly;

        if (macToWinBlocked) _selectedDirectionTab = "win_to_mac";
        else if (winToMacBlocked) _selectedDirectionTab = "mac_to_win";

        string effectiveDir = _selectedDirectionTab;
        DirMacToWinBtn.IsEnabled = !macToWinBlocked;
        DirWinToMacBtn.IsEnabled = !winToMacBlocked;
        DirMacToWinBtn.Content = macToWinBlocked
            ? AppLoc.T("Mac 控制 Windows（已屏蔽）", "Mac → Windows (Blocked)")
            : AppLoc.T("Mac 控制 Windows（Mac → Win）", "Mac → Windows");
        DirWinToMacBtn.Content = winToMacBlocked
            ? AppLoc.T("Windows 控制 Mac（已屏蔽）", "Windows → Mac (Blocked)")
            : AppLoc.T("Windows 控制 Mac（Win → Mac）", "Windows → Mac");

        var activeBg = new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF));
        var inactiveBg = new SolidColorBrush(Color.FromRgb(0x1E, 0x1F, 0x22));
        var activeFg = Brushes.White;
        var inactiveFg = new SolidColorBrush(Color.FromRgb(0xC8, 0xC8, 0xCE));
        var blockedFg = new SolidColorBrush(Color.FromRgb(0x6B, 0x6B, 0x72));

        DirMacToWinBtn.Background = (effectiveDir == "mac_to_win" && !macToWinBlocked) ? activeBg : inactiveBg;
        DirMacToWinBtn.Foreground = macToWinBlocked ? blockedFg : (effectiveDir == "mac_to_win" ? activeFg : inactiveFg);
        DirMacToWinBtn.FontWeight = effectiveDir == "mac_to_win" ? FontWeights.SemiBold : FontWeights.Medium;

        DirWinToMacBtn.Background = (effectiveDir == "win_to_mac" && !winToMacBlocked) ? activeBg : inactiveBg;
        DirWinToMacBtn.Foreground = winToMacBlocked ? blockedFg : (effectiveDir == "win_to_mac" ? activeFg : inactiveFg);
        DirWinToMacBtn.FontWeight = effectiveDir == "win_to_mac" ? FontWeights.SemiBold : FontWeights.Medium;

        GestureSectionTitle.Text = effectiveDir == "mac_to_win"
            ? AppLoc.T("触控板三指拖移（MacBook 触控板 → Windows）", "Trackpad 3-Finger Drag (MacBook Trackpad → Windows)")
            : AppLoc.T("触控板三指拖移（Windows 精确触控板 → Mac）", "Trackpad 3-Finger Drag (Windows Touchpad → Mac)");

        string hkSig = $"{effectiveDir}|{string.Join("|", _service.HotkeyRules.Select(r => $"{r.Id}:{r.Enabled}"))}";
        if (force || hkSig != _lastHotkeySignature)
        {
            _lastHotkeySignature = hkSig;
            ShortcutRulesList.ItemsSource = null;
            ShortcutRulesList.ItemsSource = _service.HotkeyRules.Where(r => r.Direction == effectiveDir && !r.IsGesture).ToList();
            GestureRulesList.ItemsSource = null;
            GestureRulesList.ItemsSource = _service.HotkeyRules.Where(r => r.Direction == effectiveDir && r.IsGesture).ToList();
        }
    }

    private void PortalOffsetSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (!_ready) return;
        _service.EdgeOffsetRatio = Math.Clamp(e.NewValue, 0.05, 0.95);
        PortalOffsetText.Text = AppLoc.T($"边缘位置（{(int)Math.Round(_service.EdgeOffsetRatio * 100)}%）", $"Edge Offset ({(int)Math.Round(_service.EdgeOffsetRatio * 100)}%)");
        _service.SaveSettingsToDisk();
        _portalWindow.SyncVisualState();
    }

    private void ToggleManualFocus_Click(object sender, RoutedEventArgs e) => _service.ToggleManualFocusSwitch();

    private void HotkeyRuleToggle_Click(object sender, RoutedEventArgs e)
    {
        if (sender is CheckBox cb && cb.Tag is string id)
            _service.ToggleHotkeyRule(id, cb.IsChecked == true);
    }

    private void IdentifyScreens_Click(object sender, RoutedEventArgs e) => _service.IdentifyScreensBothSides();

    private void ShowLocalIdentifyBadges()
    {
        var mons = DeskflowTransport.EnumerateRealWindowsMonitors();
        foreach (var mon in mons)
        {
            var source = PresentationSource.FromVisual(this);
            double dpiX = source?.CompositionTarget?.TransformToDevice.M11 ?? 1.0;
            double dpiY = source?.CompositionTarget?.TransformToDevice.M22 ?? 1.0;

            double cx = (mon.BoundsX + mon.WidthPx * 0.5) / dpiX - 90;
            double cy = (mon.BoundsY + mon.HeightPx * 0.5) / dpiY - 90;

            var badge = new Window
            {
                Width = 180,
                Height = 180,
                Left = cx,
                Top = cy,
                WindowStyle = WindowStyle.None,
                AllowsTransparency = true,
                Background = Brushes.Transparent,
                Topmost = true,
                ShowInTaskbar = false,
                IsHitTestVisible = false,
                Content = new Border
                {
                    CornerRadius = new CornerRadius(20),
                    Background = new SolidColorBrush(Color.FromArgb(240, 0x1C, 0x1C, 0x1E)),
                    BorderBrush = new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF)),
                    BorderThickness = new Thickness(2),
                    Child = new StackPanel
                    {
                        VerticalAlignment = VerticalAlignment.Center,
                        HorizontalAlignment = HorizontalAlignment.Center,
                        Children =
                        {
                            new TextBlock
                            {
                                Text = $"{mon.DisplayIndex}",
                                Foreground = Brushes.White,
                                FontSize = 46,
                                FontWeight = FontWeights.Bold,
                                HorizontalAlignment = HorizontalAlignment.Center
                            },
                            new TextBlock
                            {
                                Text = mon.Name,
                                Foreground = new SolidColorBrush(Color.FromRgb(0xB0, 0xB0, 0xB8)),
                                FontSize = 12,
                                HorizontalAlignment = HorizontalAlignment.Center,
                                TextTrimming = TextTrimming.CharacterEllipsis,
                                MaxWidth = 156
                            }
                        }
                    }
                }
            };
            badge.Show();
            var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.6) };
            t.Tick += (_, _) => { t.Stop(); try { badge.Close(); } catch { } };
            t.Start();
        }
    }

    private void ToggleGlobalDisconnect_Click(object sender, RoutedEventArgs e) => _service.ToggleGlobalDisconnect();

    private void NicMultipathToggle_Click(object sender, RoutedEventArgs e)
    {
        if (sender is CheckBox cb && cb.Tag is NicChannelItem item)
            _service.ToggleNicMultipath(item, !item.EnabledForMultipath);
    }

    private void NicToggleConnection_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is NicChannelItem item)
        {
            if (item.ManuallyDisconnected || !item.Online)
                _service.ReconnectNic(item);
            else
                _service.DisconnectNic(item);
        }
    }

    private void ConfirmPairing_Click(object sender, RoutedEventArgs e) => _service.ConfirmPendingPairing();
    private void RejectPairing_Click(object sender, RoutedEventArgs e) => _service.RejectPendingPairing();
    private void ClearTrustedPeers_Click(object sender, RoutedEventArgs e) => _service.ClearTrustedPeers();

    private void RemoveTrustedPeer_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string fp && !string.IsNullOrWhiteSpace(fp))
            _service.RemoveTrustedPeer(fp);
    }

    // MARK: - Smooth Linear USB Progress Bar Controller (60fps linear glide + shimmer)

    private void UsbProgressTrack_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        ApplyUsbProgressVisual(_usbProgCurrent);
    }

    private void ApplyUsbProgressVisual(double pct)
    {
        double clamped = Math.Clamp(pct, 0.0, 100.0);
        double trackW = UsbProgressTrack.ActualWidth;
        if (trackW > 4)
        {
            double fillW = clamped > 0.1 ? Math.Max(10.0, trackW * (clamped / 100.0)) : 0.0;
            UsbProgressFill.Width = fillW;
            UsbProgressSheenTransform.X = _usbSheenOffset;
        }
        UsbProgressPctText.Text = $"{(int)Math.Round(clamped)}%";
    }

    private void UsbProgTimer_Tick(object? sender, EventArgs e)
    {
        if (_usbProgHidden) return;

        // Smooth continuous linear glide toward stage target, then linear creep toward ceiling
        if (_usbProgCurrent < _usbProgTarget)
        {
            _usbProgCurrent = Math.Min(_usbProgTarget, _usbProgCurrent + 0.85);
        }
        else if (!_usbProgCompleting && _usbProgCurrent < _usbProgCeil)
        {
            _usbProgCurrent = Math.Min(_usbProgCeil, _usbProgCurrent + 0.14);
        }

        double fillW = Math.Max(40.0, UsbProgressFill.Width);
        _usbSheenOffset += Math.Max(3.2, fillW * 0.025);
        if (_usbSheenOffset > fillW + 30.0) _usbSheenOffset = -72.0;

        ApplyUsbProgressVisual(_usbProgCurrent);
    }

    private void SetUsbProgress(double value, double? ceil = null)
    {
        bool wasHidden = _usbProgHidden;
        UsbActionProgressPanel.Visibility = Visibility.Visible;
        _usbProgHidden = false;
        _usbProgCompleting = false;
        double clamped = Math.Clamp(value, 0, 100);
        if (wasHidden && _usbProgCurrent < 1.0)
            _usbProgCurrent = Math.Max(4.0, Math.Round(clamped * 0.45));
        if (clamped > _usbProgFloor) _usbProgFloor = clamped;
        double minCeil = Math.Min(98.0, _usbProgFloor);
        _usbProgCeil = ceil.HasValue
            ? Math.Clamp(ceil.Value, minCeil, 98.0)
            : Math.Min(96.0, Math.Max(_usbProgFloor + 14.0, clamped));
        _usbProgTarget = Math.Max(_usbProgCurrent, clamped);
        if (!_usbProgTimer.IsEnabled) _usbProgTimer.Start();
        ApplyUsbProgressVisual(_usbProgCurrent);
    }

    private async System.Threading.Tasks.Task CompleteUsbProgressAndHideAsync(bool finalizeServiceStop = false)
    {
        if (_usbProgHidden || _usbProgCompleting) return;
        _usbProgCompleting = true;
        _usbProgTarget = 100.0;
        _usbProgCeil = 100.0;
        if (!_usbProgTimer.IsEnabled) _usbProgTimer.Start();

        var sw = Stopwatch.StartNew();
        while (_usbProgCurrent < 100.0 && sw.ElapsedMilliseconds < 1100)
        {
            _usbProgCurrent = Math.Min(100.0, _usbProgCurrent + 2.6);
            ApplyUsbProgressVisual(_usbProgCurrent);
            await System.Threading.Tasks.Task.Delay(16);
        }
        if (!_usbProgCompleting) return;
        _usbProgCurrent = 100.0;
        ApplyUsbProgressVisual(100.0);
        await System.Threading.Tasks.Task.Delay(300);
        if (!_usbProgCompleting) return;

        _usbProgTimer.Stop();
        UsbActionProgressPanel.Visibility = Visibility.Collapsed;
        _usbProgFloor = 0;
        _usbProgCeil = 0;
        _usbProgTarget = 0;
        _usbProgCurrent = 0;
        _usbSheenOffset = -80;
        _usbProgHidden = true;
        _usbProgCompleting = false;
        ApplyUsbProgressVisual(0);
        if (finalizeServiceStop)
            _service.FinishUsbCompletingTransition();
    }

    private void HideUsbProgressImmediate()
    {
        _usbProgTimer.Stop();
        _usbProgCompleting = false;
        _usbProgFloor = 0;
        _usbProgCeil = 0;
        _usbProgTarget = 0;
        _usbProgCurrent = 0;
        _usbSheenOffset = -80;
        _usbProgHidden = true;
        ApplyUsbProgressVisual(0);
        UsbActionProgressPanel.Visibility = Visibility.Collapsed;
    }

    private void SaveMonitors_Click(object sender, RoutedEventArgs e) => _service.SaveMonitorLayout(silent: false);
    private void SaveInputSettings_Click(object sender, RoutedEventArgs e) => _service.SaveInputSettingsManual();

    private void ConnectPeer_Click(object sender, RoutedEventArgs e)
    {
        _service.ManualPeerIp = PeerIpBox.Text.Trim();
        _service.ConnectManualPeer();
    }

    private void ResetMonitors_Click(object sender, RoutedEventArgs e)
    {
        _service.ResetMonitorLayout(preservePositions: false);
        RenderArrangeDisplaysCanvas();
        RefreshUiBindings();
    }

    private void RefreshMonitors_Click(object sender, RoutedEventArgs e)
    {
        _service.ResetMonitorLayout(preservePositions: true);
        RenderArrangeDisplaysCanvas();
        RefreshUiBindings();
    }

    private void TestWinScreenshot_Click(object sender, RoutedEventArgs e)
    {
        _service.TriggerWindowsNativeScreenshot();
        AppendLog("[Hotkey] 已触发 Windows 原生区域截图 (Win + Shift + S)");
    }

    private void PickFileToSend_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog { Title = AppLoc.T("选择要发到 Mac 的文件或压缩包", "Select file(s) to send to Mac"), Multiselect = true };
        if (dlg.ShowDialog() == true && dlg.FileNames.Length > 0)
            _service.SendFilesFromWindows(dlg.FileNames);
    }

    private void MainShelfCard_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement fe && fe.Tag is ShelfTransferItem item && item.CanDragOut)
        {
            _mainShelfDragOrigin = e.GetPosition(null);
            _mainShelfDragCandidate = item;
        }
    }

    private void MainShelfCard_MouseMove(object sender, MouseEventArgs e)
    {
        if (_mainShelfDragCandidate == null || e.LeftButton != MouseButtonState.Pressed) return;
        Point cur = e.GetPosition(null);
        if (Math.Abs(cur.X - _mainShelfDragOrigin.X) < SystemParameters.MinimumHorizontalDragDistance &&
            Math.Abs(cur.Y - _mainShelfDragOrigin.Y) < SystemParameters.MinimumVerticalDragDistance)
            return;

        var item = _mainShelfDragCandidate;
        _mainShelfDragCandidate = null;
        string[] validPaths = item.LocalPaths.Where(p => File.Exists(p) || Directory.Exists(p)).ToArray();
        if (validPaths.Length == 0) return;

        _service.BeginShelfDragOut(validPaths);
        try
        {
            var eff = DragDrop.DoDragDrop((DependencyObject)sender, new DataObject(DataFormats.FileDrop, validPaths), DragDropEffects.Copy);
            if (eff != DragDropEffects.None)
                _service.MarkShelfItemDeliveredByDrag(item.Id);
        }
        catch { }
        finally
        {
            _service.EndShelfDragOut();
        }
    }

    private void MainShelfOpen_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string id) _service.OpenShelfItem(id);
    }

    private void MainShelfReveal_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string id) _service.RevealShelfItem(id);
    }

    private void MainShelfRetry_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string id) _service.RetryShelfItem(id);
    }

    private void MainShelfRemove_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string id) _service.RemoveShelfItem(id);
    }

    private void PickFolderToSend_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFolderDialog { Title = AppLoc.T("选择要打包发送至 Mac 的文件夹", "Select folder to zip & send to Mac") };
        if (dlg.ShowDialog() == true)
            _service.SendFilesFromWindows(new[] { dlg.FolderName });
    }

    private void OpenDownloadsFolder_Click(object sender, RoutedEventArgs e)
    {
        string dl = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "OmniFlow");
        Directory.CreateDirectory(dl);
        try { Process.Start(new ProcessStartInfo("explorer.exe", $"\"{dl}\"") { UseShellExecute = true }); }
        catch (Exception ex) { AppendLog($"[Portal Warn] 打开目录失败: {ex.Message}"); }
    }

    private void RevealReceivedFile_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string path && !string.IsNullOrEmpty(path))
        {
            try
            {
                if (File.Exists(path) || Directory.Exists(path))
                    Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
                else
                    OpenDownloadsFolder_Click(sender, e);
            }
            catch (Exception ex) { AppendLog($"[Portal Warn] 定位文件失败: {ex.Message}"); }
        }
    }

    private void DropZone_DragOver(object sender, DragEventArgs e)
    {
        if (_service.ShouldIgnoreShelfDrop())
        {
            e.Effects = DragDropEffects.None;
            e.Handled = true;
            SetDropZoneHighlighted(false);
            return;
        }
        if (e.Data.GetDataPresent(DataFormats.FileDrop))
        {
            e.Effects = DragDropEffects.Copy;
            e.Handled = true;
            SetDropZoneHighlighted(true);
        }
    }

    private void DropZone_DragLeave(object sender, DragEventArgs e)
    {
        SetDropZoneHighlighted(false);
    }

    private void DropZone_Drop(object sender, DragEventArgs e)
    {
        SetDropZoneHighlighted(false);
        if (e.Data.GetDataPresent(DataFormats.FileDrop) &&
            e.Data.GetData(DataFormats.FileDrop) is string[] files &&
            files.Length > 0 &&
            !_service.ShouldIgnoreShelfDrop(files))
        {
            e.Handled = true;
            _service.SendFilesFromWindows(files);
        }
    }

    private void UsbConnect_Click(object sender, RoutedEventArgs e) => _service.StartUsbTunnel();
    private void UsbDisconnect_Click(object sender, RoutedEventArgs e) => _service.StopUsbTunnel(alsoRestoreAppleDriver: false);
    private void RestoreAppleDriver_Click(object sender, RoutedEventArgs e) => _service.StopUsbTunnel(alsoRestoreAppleDriver: true);

    private void AppendLog(string msg)
    {
        Dispatcher.BeginInvoke(() =>
        {
            string line = $"[{DateTime.Now:HH:mm:ss}] {msg}";
            if (LogBox.Text.Length > 24000)
            {
                LogBox.Text = LogBox.Text[^16000..];
            }
            LogBox.AppendText(line + Environment.NewLine);
            LogBox.ScrollToEnd();
            try
            {
                string logPath = OmniFlowPaths.RuntimeLogPath;
                if (File.Exists(logPath) && new FileInfo(logPath).Length > 2 * 1024 * 1024)
                {
                    File.WriteAllText(logPath, line + Environment.NewLine);
                }
                else
                {
                    File.AppendAllText(logPath, line + Environment.NewLine);
                }
            }
            catch { }
        });
    }

    // MARK: - Window Close Choice Modal (Minimize vs Exit + Auto-Cleanup Driver)

    private void Window_Closing(object sender, System.ComponentModel.CancelEventArgs e)
    {
        if (_explicitExit) return;
        e.Cancel = true;
        ClosePromptModal.Visibility = Visibility.Visible;
    }

    private void ModalCancel_Click(object sender, RoutedEventArgs e)
    {
        if (_isExiting) return;
        ClosePromptModal.Visibility = Visibility.Collapsed;
    }

    private void ModalMinimize_Click(object sender, RoutedEventArgs e)
    {
        if (_isExiting) return;
        ClosePromptModal.Visibility = Visibility.Collapsed;
        WindowState = WindowState.Minimized;
    }

    private async void ModalExit_Click(object sender, RoutedEventArgs e)
    {
        if (_isExiting) return;
        _isExiting = true;

        CloseCancelBtn.IsEnabled = false;
        CloseMinimizeBtn.IsEnabled = false;
        CloseExitBtn.IsEnabled = false;
        CloseModalTitle.Text = AppLoc.T("正在退出 OmniFlow...", "Exiting OmniFlow...");
        CloseModalStatusPanel.Visibility = Visibility.Visible;

        // Step 1: Stop hooks, clipboard/probe timers, save config, and close network transport BEFORE closing window
        CloseModalStatusText.Text = AppLoc.T("步骤 1/2 · 正在停止键鼠共享、剪贴板与网络通道服务...", "Step 1/2 · Stopping KVM, clipboard & network transport...");
        _service.PrepareShutdownServicesOnUi();
        await System.Threading.Tasks.Task.Run(() => _service.StopTransportSync());

        // Step 2: Gracefully tear down Wintun / omniflow-usb and finish restoring Apple USB driver BEFORE closing window
        CloseModalStatusText.Text = AppLoc.T("步骤 2/2 · 正在卸载 WinUSB 并恢复苹果原厂驱动，请稍候...", "Step 2/2 · Restoring Apple USB driver & tearing down Wintun...");
        await System.Threading.Tasks.Task.Run(() => _service.CleanupAndRestoreAppleUsbDriver());

        _service.MarkShutdownCompleted();
        CloseModalStatusText.Text = "所有服务与驱动已清理完成，正在关闭窗口...";
        await System.Threading.Tasks.Task.Delay(180);

        _explicitExit = true;
        ClosePromptModal.Visibility = Visibility.Collapsed;
        try { _dropHost?.Dispose(); } catch { }
        try { _portalWindow.ForceClose(); } catch { }
        try { Close(); } catch { }
        try { Application.Current.Shutdown(0); } catch { Environment.Exit(0); }
    }
}
