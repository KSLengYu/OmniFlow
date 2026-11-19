using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace MacBridgeUI;

public partial class PortalOverlayWindow : Window
{
    private readonly DeskflowService _service;
    private readonly DispatcherTimer _animTimer;
    private readonly DispatcherTimer _autoHideTimer;
    private double _timeSec;
    private double _smoothProgress;
    private bool _draggingCube;
    private Point _dragStartMouse;
    private double _cubeDragStartRatio;
    private Point _cardDragOrigin;
    private ShelfTransferItem? _cardDragCandidate;
    private bool _isClosed;
    private bool _allowClose;
    private PortalTransferPhase _lastAnimatedPillPhase = PortalTransferPhase.Idle;
    private bool _wasDockVisible;
    private bool _isCollapsingPill;
    private int _pillAnimSeq;
    public event Action? OverlayBoundsChanged;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool ChangeWindowMessageFilterEx(IntPtr hWnd, uint msg, uint action, IntPtr pChangeFilterStruct);

    [DllImport("shell32.dll")]
    private static extern void DragAcceptFiles(IntPtr hWnd, bool fAccept);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern uint DragQueryFileW(IntPtr hDrop, uint iFile, System.Text.StringBuilder? lpszFile, uint cch);

    [DllImport("shell32.dll")]
    private static extern void DragFinish(IntPtr hDrop);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X, Y; }

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT lpPoint);

    private const uint WM_DROPFILES = 0x0233;
    private const uint WM_COPYDATA = 0x004A;
    private const uint WM_COPYGLOBALDATA = 0x0049;
    private const uint MSGFLT_ALLOW = 1;

    public PortalOverlayWindow(DeskflowService service)
    {
        InitializeComponent();
        _service = service;
        _service.StateUpdated += SyncVisualState;
        EdgeShelfList.ItemsSource = _service.ShelfItems;
        _service.ShelfItems.CollectionChanged += OnShelfCollectionChanged;

        _animTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(16) };
        _animTimer.Tick += (_, _) =>
        {
            _timeSec += 0.016;
            if (_service.EffectStyle == PortalEffectStyle.BlackHole &&
                _service.Phase != PortalTransferPhase.Idle &&
                _service.ShelfItems.Count == 0)
            {
                double target = _service.Phase switch
                {
                    PortalTransferPhase.SuckingIn or PortalTransferPhase.EmergingOut => Math.Clamp(_service.TransferProgress, 0.02, 1.0),
                    PortalTransferPhase.Completed => 1.0,
                    _ => 0.35
                };
                _smoothProgress += (target - _smoothProgress) * 0.24;
                RenderGenieMesh();
            }
            else if (WallCanvas.Children.Count > 0)
            {
                WallCanvas.Children.Clear();
                _smoothProgress = 0.0;
            }
        };
        _animTimer.Start();

        _autoHideTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2.2) };
        _autoHideTimer.Tick += (_, _) =>
        {
            _autoHideTimer.Stop();
            if (_service.Phase == PortalTransferPhase.Completed)
            {
                _service.Phase = PortalTransferPhase.Idle;
                SyncVisualState();
            }
        };

        RepositionAlongScreenEdge();
        SyncVisualState();
    }

    private void OnShelfCollectionChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        SyncVisualState();
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd != IntPtr.Zero)
        {
            ChangeWindowMessageFilterEx(hwnd, WM_DROPFILES, MSGFLT_ALLOW, IntPtr.Zero);
            ChangeWindowMessageFilterEx(hwnd, WM_COPYDATA, MSGFLT_ALLOW, IntPtr.Zero);
            ChangeWindowMessageFilterEx(hwnd, WM_COPYGLOBALDATA, MSGFLT_ALLOW, IntPtr.Zero);
            DragAcceptFiles(hwnd, true);
            HwndSource.FromHwnd(hwnd)?.AddHook(WndProc);
        }
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
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
            if (files.Count > 0 && !_service.ShouldIgnoreShelfDrop(files.ToArray()))
            {
                handled = true;
                _service.SendFilesFromWindows(files.ToArray());
            }
        }
        return IntPtr.Zero;
    }

    public void RepositionAlongScreenEdge()
    {
        var wa = SystemParameters.WorkArea;
        bool isWall = _service.EffectStyle == PortalEffectStyle.BlackHole;
        bool hasCards = _service.ShelfItems.Count > 0;
        bool isActive = _service.Phase != PortalTransferPhase.Idle || hasCards;
        if (_isCollapsingPill && !isActive && isWall)
            return;

        double targetW, targetH;
        if (isWall)
        {
            if (!isActive)
            {
                if (_service.EdgeSide == ScreenEdgeSide.Left || _service.EdgeSide == ScreenEdgeSide.Right)
                {
                    targetW = 14;
                    targetH = Math.Min(156, wa.Height * 0.24);
                }
                else
                {
                    targetW = Math.Min(210, wa.Width * 0.24);
                    targetH = 14;
                }
            }
            else if (hasCards)
            {
                int rows = Math.Min(4, _service.ShelfItems.Count);
                double hoverExtra = _service.Phase == PortalTransferPhase.HoverExpand ? 86 : 0;
                targetW = 296;
                targetH = Math.Min(420, Math.Max(165, 58 + rows * 84 + hoverExtra));
            }
            else
            {
                targetW = _service.Phase == PortalTransferPhase.HoverExpand ? 236 : 252;
                targetH = _service.Phase == PortalTransferPhase.HoverExpand ? 156 : 168;
            }
        }
        else
        {
            targetW = hasCards ? 300 : (isActive ? 220 : 156);
            targetH = hasCards ? Math.Min(420, Math.Max(180, 64 + Math.Min(4, _service.ShelfItems.Count) * 84)) : (isActive ? 180 : 148);
        }

        if (Math.Abs(Width - targetW) > 0.5) Width = targetW;
        if (Math.Abs(Height - targetH) > 0.5) Height = targetH;

        double ratio = Math.Clamp(_service.EdgeOffsetRatio, 0.05, 0.95);
        switch (_service.EdgeSide)
        {
            case ScreenEdgeSide.Left:
                Left = wa.Left;
                Top = wa.Top + (wa.Height - Height) * ratio;
                break;
            case ScreenEdgeSide.Right:
                Left = wa.Right - Width;
                Top = wa.Top + (wa.Height - Height) * ratio;
                break;
            case ScreenEdgeSide.Top:
                Left = wa.Left + (wa.Width - Width) * ratio;
                Top = wa.Top;
                break;
            case ScreenEdgeSide.Bottom:
                Left = wa.Left + (wa.Width - Width) * ratio;
                Top = wa.Bottom - Height;
                break;
        }
        OverlayBoundsChanged?.Invoke();
    }

    public void ForceClose()
    {
        _allowClose = true;
        _isClosed = true;
        _service.StateUpdated -= SyncVisualState;
        _service.ShelfItems.CollectionChanged -= OnShelfCollectionChanged;
        _animTimer.Stop();
        _autoHideTimer.Stop();
        try { Close(); } catch { }
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        if (!_allowClose && !Dispatcher.HasShutdownStarted)
        {
            e.Cancel = true;
            Hide();
            return;
        }
        _isClosed = true;
        _service.StateUpdated -= SyncVisualState;
        _service.ShelfItems.CollectionChanged -= OnShelfCollectionChanged;
        _animTimer.Stop();
        _autoHideTimer.Stop();
        base.OnClosing(e);
    }

    protected override void OnClosed(EventArgs e)
    {
        _isClosed = true;
        _service.StateUpdated -= SyncVisualState;
        _service.ShelfItems.CollectionChanged -= OnShelfCollectionChanged;
        _animTimer.Stop();
        _autoHideTimer.Stop();
        base.OnClosed(e);
    }

    public void SyncVisualState()
    {
        if (_isClosed || Dispatcher.HasShutdownStarted || Dispatcher.HasShutdownFinished) return;
        bool hasCards = _service.ShelfItems.Count > 0;
        if (!_service.OverlayEnabled && !hasCards)
        {
            if (IsVisible) Hide();
            return;
        }
        try
        {
            if (!IsVisible) Show();
        }
        catch (InvalidOperationException)
        {
            _isClosed = true;
            return;
        }

        RepositionAlongScreenEdge();

        bool showShelfMode = _service.EffectStyle == PortalEffectStyle.BlackHole || hasCards;
        EdgeWallRoot.Visibility = showShelfMode ? Visibility.Visible : Visibility.Collapsed;
        MiniCubeRoot.Visibility = showShelfMode ? Visibility.Collapsed : Visibility.Visible;

        if (_service.Phase == PortalTransferPhase.Completed)
            _autoHideTimer.Start();
        else
            _autoHideTimer.Stop();

        if (showShelfMode)
            UpdateGenieOverlayUI();
        else
            UpdateMiniCubeUI();
    }

    private void UpdateGenieOverlayUI()
    {
        bool hasCards = _service.ShelfItems.Count > 0;
        bool dockWasVisible = _wasDockVisible;
        PersistentShelfDock.Visibility = hasCards ? Visibility.Visible : Visibility.Collapsed;
        _wasDockVisible = hasCards;
        if (hasCards && !dockWasVisible)
            AnimateOutwardFromEdge(PersistentShelfDock, PersistentShelfDockScale, PersistentShelfDockTranslate);
        ShelfDockHeaderText.Text = AppLoc.T($"跨屏传输架 ({_service.ShelfItems.Count})", $"Transfer Shelf ({_service.ShelfItems.Count})");

        WallActionButtons.Visibility = Visibility.Collapsed;
        if (_service.Phase == PortalTransferPhase.Idle || (hasCards && _service.Phase != PortalTransferPhase.HoverExpand))
        {
            if (WallStatusPill.Visibility == Visibility.Visible && !_isCollapsingPill && _service.Phase == PortalTransferPhase.Idle && !hasCards)
            {
                CollapsePillTowardEdge();
            }
            else if (!_isCollapsingPill)
            {
                ClearPillAnimations(WallStatusPill, WallStatusPillScale, WallStatusPillTranslate);
                WallStatusPill.Visibility = Visibility.Collapsed;
                _lastAnimatedPillPhase = PortalTransferPhase.Idle;
                WallCanvas.Children.Clear();
                _smoothProgress = 0;
            }
            return;
        }

        bool pillJustShown = WallStatusPill.Visibility != Visibility.Visible || _isCollapsingPill;
        _isCollapsingPill = false;
        _pillAnimSeq++;
        WallStatusPill.Visibility = Visibility.Visible;
        _lastAnimatedPillPhase = _service.Phase;
        if (pillJustShown)
            AnimateOutwardFromEdge(WallStatusPill, WallStatusPillScale, WallStatusPillTranslate);

        switch (_service.Phase)
        {
            case PortalTransferPhase.HoverExpand:
                WallTitleText.Text = _service.HoverPromptTitle;
                WallSubText.Text = _service.HoverPromptDetail;
                WallStatusPill.Background = new SolidColorBrush(Color.FromArgb(242, 0x16, 0x18, 0x20));
                WallStatusPill.BorderBrush = new SolidColorBrush(!_service.HoverCanSubmit
                    ? Color.FromRgb(0xFF, 0x5A, 0x52)
                    : Color.FromRgb(0xFF, 0x9F, 0x0A));
                break;

            case PortalTransferPhase.SuckingIn:
            case PortalTransferPhase.EmergingOut:
                bool sending = _service.Phase == PortalTransferPhase.SuckingIn;
                int pct = (int)Math.Round(Math.Clamp(_service.TransferProgress, 0.01, 1.0) * 100);
                double mbs = _service.ActiveSpeedMbps / 8.0;
                WallTitleText.Text = $"{(sending ? AppLoc.T("正在发给 Mac:", "Sending:") : AppLoc.T("正在接收:", "Receiving:"))} {_service.ActiveFileName}";
                WallSubText.Text = $"{pct}% · {mbs:F0} MB/s · {_service.ActiveFileSize}";
                WallStatusPill.Background = new SolidColorBrush(Color.FromArgb(242, 0x14, 0x18, 0x20));
                WallStatusPill.BorderBrush = new SolidColorBrush(sending
                    ? Color.FromRgb(0x0A, 0x84, 0xFF)
                    : Color.FromRgb(0x30, 0xD1, 0x58));
                break;

            case PortalTransferPhase.Completed:
                WallTitleText.Text = AppLoc.T($"已验证送达 · {_service.ActiveFileName}", $"Delivered · {_service.ActiveFileName}");
                WallSubText.Text = AppLoc.T($"{_service.ActiveFileSize} · SHA-256 校验通过", $"{_service.ActiveFileSize} · SHA-256 Verified");
                WallStatusPill.Background = new SolidColorBrush(Color.FromArgb(242, 0x14, 0x38, 0x21));
                WallStatusPill.BorderBrush = new SolidColorBrush(Color.FromRgb(0x30, 0xD1, 0x58));
                break;
        }
    }

    private void RenderGenieMesh()
    {
        WallCanvas.Children.Clear();
        if (_service.Phase != PortalTransferPhase.SuckingIn && _service.Phase != PortalTransferPhase.EmergingOut)
            return;

        double w = ActualWidth > 20 ? ActualWidth : Width;
        double h = ActualHeight > 20 ? ActualHeight : Height;
        if (w < 40 || h < 40) return;

        bool sending = _service.Phase != PortalTransferPhase.EmergingOut;
        byte r = sending ? (byte)0x0A : (byte)0x30;
        byte g = sending ? (byte)0x84 : (byte)0xD1;
        byte b = sending ? (byte)0xFF : (byte)0x58;

        double span = Math.Clamp(_smoothProgress, 0.08, 1.0);
        var slitLine = new Rectangle
        {
            Fill = new SolidColorBrush(Color.FromArgb(185, r, g, b)),
            RadiusX = 1.5,
            RadiusY = 1.5
        };
        if (_service.EdgeSide == ScreenEdgeSide.Left || _service.EdgeSide == ScreenEdgeSide.Right)
        {
            double barH = Math.Max(18, (h - 48) * span);
            slitLine.Width = 3;
            slitLine.Height = barH;
            Canvas.SetTop(slitLine, (h - barH) * 0.5);
            Canvas.SetLeft(slitLine, _service.EdgeSide == ScreenEdgeSide.Left ? 1 : w - 4);
        }
        else
        {
            double barW = Math.Max(28, (w - 48) * span);
            slitLine.Width = barW;
            slitLine.Height = 3;
            Canvas.SetLeft(slitLine, (w - barW) * 0.5);
            Canvas.SetTop(slitLine, _service.EdgeSide == ScreenEdgeSide.Top ? 1 : h - 4);
        }
        WallCanvas.Children.Add(slitLine);
    }

    private void UpdateMiniCubeUI()
    {
        CubeHandleText.Text = AppLoc.T($"按住拖动位置 ({(int)(_service.EdgeOffsetRatio * 100)}%)", $"Drag Position ({(int)(_service.EdgeOffsetRatio * 100)}%)");
        CubeActionButtons.Visibility = Visibility.Collapsed;

        switch (_service.Phase)
        {
            case PortalTransferPhase.Idle:
                CubeTitleText.Text = AppLoc.T("边缘小方块", "Drop Cube");
                CubeSubText.Text = AppLoc.T("拖入松手即传", "Drop files to send");
                CubeFillRect.Height = 0;
                break;

            case PortalTransferPhase.HoverExpand:
                CubeTitleText.Text = _service.HoverPromptTitle;
                CubeSubText.Text = AppLoc.T("松手开始发送 · 移开取消", "Release to send · Move away to cancel");
                CubeFillRect.Height = 20;
                break;

            case PortalTransferPhase.SuckingIn:
                CubeTitleText.Text = AppLoc.T($"发送 · {_service.ActiveFileName}", $"Sending · {_service.ActiveFileName}");
                CubeSubText.Text = $"{(int)(_service.TransferProgress * 100)}% · {_service.ActiveFileSize}";
                CubeFillRect.Height = Math.Clamp(_service.TransferProgress, 0.05, 1.0) * 110;
                break;

            case PortalTransferPhase.EmergingOut:
                CubeTitleText.Text = AppLoc.T($"接收 · {_service.ActiveFileName}", $"Receiving · {_service.ActiveFileName}");
                CubeSubText.Text = $"{(int)(_service.TransferProgress * 100)}% · {_service.ActiveFileSize}";
                CubeFillRect.Height = Math.Clamp(_service.TransferProgress, 0.05, 1.0) * 110;
                break;

            case PortalTransferPhase.Completed:
                CubeTitleText.Text = _service.ActiveFileName;
                CubeSubText.Text = AppLoc.T($"完成 ({_service.ActiveFileSize})", $"Done ({_service.ActiveFileSize})");
                CubeFillRect.Height = 110;
                CubeActionButtons.Visibility = Visibility.Visible;
                break;
        }
    }

    // MARK: - Explorer / Desktop Native File Drop (Hover -> Evaluate -> Drop to Send / Leave to Cancel)

    private void Window_DragEnter(object sender, DragEventArgs e)
    {
        if (e.Data.GetDataPresent(DataFormats.FileDrop) &&
            e.Data.GetData(DataFormats.FileDrop) is string[] files &&
            files.Length > 0 &&
            !_service.ShouldIgnoreShelfDrop(files))
        {
            e.Effects = DragDropEffects.Copy;
            e.Handled = true;
            _service.EvaluateShelfDrag(files);
        }
        else
        {
            e.Effects = DragDropEffects.None;
            e.Handled = true;
        }
    }

    private void Window_DragOver(object sender, DragEventArgs e)
    {
        if (_service.ShouldIgnoreShelfDrop())
        {
            e.Effects = DragDropEffects.None;
            e.Handled = true;
            return;
        }
        if (e.Data.GetDataPresent(DataFormats.FileDrop))
        {
            e.Effects = DragDropEffects.Copy;
            e.Handled = true;
        }
    }

    private void Window_DragLeave(object sender, DragEventArgs e)
    {
        if (_service.Phase != PortalTransferPhase.HoverExpand) return;
        // Ignore internal child-element DragLeave bounce while cursor physically remains inside overlay window
        if (GetCursorPos(out var pt))
        {
            var src = PresentationSource.FromVisual(this);
            double sx = src?.CompositionTarget?.TransformFromDevice.M11 ?? 1.0;
            double sy = src?.CompositionTarget?.TransformFromDevice.M22 ?? 1.0;
            double dipX = pt.X * sx;
            double dipY = pt.Y * sy;
            if (dipX >= Left - 4 && dipX <= Left + ActualWidth + 4 &&
                dipY >= Top - 4 && dipY <= Top + ActualHeight + 4)
            {
                return;
            }
        }
        _service.Phase = PortalTransferPhase.Idle;
        SyncVisualState();
    }

    private void Window_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetDataPresent(DataFormats.FileDrop) &&
            e.Data.GetData(DataFormats.FileDrop) is string[] files &&
            files.Length > 0 &&
            !_service.ShouldIgnoreShelfDrop(files))
        {
            e.Effects = DragDropEffects.Copy;
            e.Handled = true;
            _service.SendFilesFromWindows(files);
        }
        else
        {
            e.Effects = DragDropEffects.None;
            e.Handled = true;
            if (_service.Phase == PortalTransferPhase.HoverExpand)
            {
                _service.Phase = PortalTransferPhase.Idle;
                SyncVisualState();
            }
        }
    }

    // MARK: - Persistent Shelf Card Actions & Native Windows Drag-Out (DoDragDrop)

    private void ShelfCard_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement fe && fe.Tag is ShelfTransferItem item && item.CanDragOut)
        {
            _cardDragOrigin = e.GetPosition(null);
            _cardDragCandidate = item;
        }
    }

    private void ShelfCard_MouseMove(object sender, MouseEventArgs e)
    {
        if (_cardDragCandidate == null || e.LeftButton != MouseButtonState.Pressed) return;
        Point cur = e.GetPosition(null);
        if (Math.Abs(cur.X - _cardDragOrigin.X) < SystemParameters.MinimumHorizontalDragDistance &&
            Math.Abs(cur.Y - _cardDragOrigin.Y) < SystemParameters.MinimumVerticalDragDistance)
            return;

        var item = _cardDragCandidate;
        _cardDragCandidate = null;
        string[] validPaths = item.LocalPaths.Where(p => File.Exists(p) || Directory.Exists(p)).ToArray();
        if (validPaths.Length == 0) return;

        _service.BeginShelfDragOut(validPaths);
        AllowDrop = false;
        try
        {
            var data = new DataObject(DataFormats.FileDrop, validPaths);
            DragDropEffects eff = DragDrop.DoDragDrop((DependencyObject)sender, data, DragDropEffects.Copy);
            if (eff != DragDropEffects.None)
            {
                _service.MarkShelfItemDeliveredByDrag(item.Id);
            }
        }
        catch (Exception ex)
        {
            _service.AppendErrorLog($"[传输架警告] 拖出失败: {ex.Message}");
        }
        finally
        {
            AllowDrop = true;
            _service.EndShelfDragOut();
        }
    }

    private void ShelfOpen_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string id)
            _service.OpenShelfItem(id);
    }

    private void ShelfReveal_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string id)
            _service.RevealShelfItem(id);
    }

    private void ShelfRetry_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string id)
            _service.RetryShelfItem(id);
    }

    private void ShelfRemove_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string id)
            _service.RemoveShelfItem(id);
    }

    private static void ClearPillAnimations(Border target, ScaleTransform scale, TranslateTransform translate)
    {
        scale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
        scale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
        translate.BeginAnimation(TranslateTransform.XProperty, null);
        translate.BeginAnimation(TranslateTransform.YProperty, null);
        target.BeginAnimation(OpacityProperty, null);
        scale.ScaleX = 1.0;
        scale.ScaleY = 1.0;
        translate.X = 0.0;
        translate.Y = 0.0;
        target.Opacity = 1.0;
    }

    private void AnimateOutwardFromEdge(Border target, ScaleTransform scale, TranslateTransform translate)
    {
        ClearPillAnimations(target, scale, translate);
        double startX = 0, startY = 0, startSx = 1.0, startSy = 1.0;
        switch (_service.EdgeSide)
        {
            case ScreenEdgeSide.Left:
                target.RenderTransformOrigin = new Point(0.0, 0.5);
                startX = -18; startSx = 0.88; startSy = 0.94;
                break;
            case ScreenEdgeSide.Right:
                target.RenderTransformOrigin = new Point(1.0, 0.5);
                startX = 18; startSx = 0.88; startSy = 0.94;
                break;
            case ScreenEdgeSide.Top:
                target.RenderTransformOrigin = new Point(0.5, 0.0);
                startY = -16; startSx = 0.94; startSy = 0.88;
                break;
            case ScreenEdgeSide.Bottom:
                target.RenderTransformOrigin = new Point(0.5, 1.0);
                startY = 16; startSx = 0.94; startSy = 0.88;
                break;
        }

        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        var dur = TimeSpan.FromMilliseconds(180);

        scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(startSx, 1.0, dur) { EasingFunction = ease });
        scale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(startSy, 1.0, dur) { EasingFunction = ease });
        translate.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(startX, 0.0, dur) { EasingFunction = ease });
        translate.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(startY, 0.0, dur) { EasingFunction = ease });
        target.BeginAnimation(OpacityProperty, new DoubleAnimation(0.25, 1.0, TimeSpan.FromMilliseconds(150)) { EasingFunction = ease });
    }

    private void CollapsePillTowardEdge()
    {
        _isCollapsingPill = true;
        int seq = ++_pillAnimSeq;

        double endX = 0, endY = 0, endSx = 1.0, endSy = 1.0;
        switch (_service.EdgeSide)
        {
            case ScreenEdgeSide.Left:
                WallStatusPill.RenderTransformOrigin = new Point(0.0, 0.5);
                endX = -20; endSx = 0.86; endSy = 0.94;
                break;
            case ScreenEdgeSide.Right:
                WallStatusPill.RenderTransformOrigin = new Point(1.0, 0.5);
                endX = 20; endSx = 0.86; endSy = 0.94;
                break;
            case ScreenEdgeSide.Top:
                WallStatusPill.RenderTransformOrigin = new Point(0.5, 0.0);
                endY = -18; endSx = 0.94; endSy = 0.86;
                break;
            case ScreenEdgeSide.Bottom:
                WallStatusPill.RenderTransformOrigin = new Point(0.5, 1.0);
                endY = 18; endSx = 0.94; endSy = 0.86;
                break;
        }

        var ease = new CubicEase { EasingMode = EasingMode.EaseIn };
        var dur = TimeSpan.FromMilliseconds(150);

        WallStatusPillScale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(endSx, dur) { EasingFunction = ease });
        WallStatusPillScale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(endSy, dur) { EasingFunction = ease });
        WallStatusPillTranslate.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(endX, dur) { EasingFunction = ease });
        WallStatusPillTranslate.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(endY, dur) { EasingFunction = ease });

        var fade = new DoubleAnimation(0.0, dur) { EasingFunction = ease };
        fade.Completed += (_, _) =>
        {
            if (_pillAnimSeq != seq) return;
            _isCollapsingPill = false;
            ClearPillAnimations(WallStatusPill, WallStatusPillScale, WallStatusPillTranslate);
            WallStatusPill.Visibility = Visibility.Collapsed;
            _lastAnimatedPillPhase = PortalTransferPhase.Idle;
            WallCanvas.Children.Clear();
            _smoothProgress = 0;
            RepositionAlongScreenEdge();
        };
        WallStatusPill.BeginAnimation(OpacityProperty, fade);
    }

    // MARK: - Mini Cube Position Dragging Along Screen Edge (1:1 DIP-Locked, Zero Jump)

    private Point GetCursorDipPosition()
    {
        if (GetCursorPos(out var pt))
        {
            var src = PresentationSource.FromVisual(this);
            double sx = src?.CompositionTarget?.TransformFromDevice.M11 ?? 1.0;
            double sy = src?.CompositionTarget?.TransformFromDevice.M22 ?? 1.0;
            return new Point(pt.X * sx, pt.Y * sy);
        }
        return _dragStartMouse;
    }

    private void CubeHandle_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject d)
        {
            var cur = d;
            while (cur != null)
            {
                if (cur is System.Windows.Controls.Primitives.ButtonBase) return;
                cur = VisualTreeHelper.GetParent(cur);
            }
        }
        _draggingCube = true;
        _dragStartMouse = GetCursorDipPosition();
        _cubeDragStartRatio = _service.EdgeOffsetRatio;
        (sender as UIElement)?.CaptureMouse();
        e.Handled = true;
    }

    private void CubeHandle_MouseMove(object sender, MouseEventArgs e)
    {
        if (!_draggingCube) return;
        Point cur = GetCursorDipPosition();
        var wa = SystemParameters.WorkArea;
        if (_service.EdgeSide == ScreenEdgeSide.Left || _service.EdgeSide == ScreenEdgeSide.Right)
        {
            double travel = Math.Max(80.0, wa.Height - Math.Max(ActualHeight, Height));
            double delta = cur.Y - _dragStartMouse.Y;
            _service.EdgeOffsetRatio = Math.Clamp(_cubeDragStartRatio + (delta / travel), 0.05, 0.95);
        }
        else
        {
            double travel = Math.Max(80.0, wa.Width - Math.Max(ActualWidth, Width));
            double delta = cur.X - _dragStartMouse.X;
            _service.EdgeOffsetRatio = Math.Clamp(_cubeDragStartRatio + (delta / travel), 0.05, 0.95);
        }

        RepositionAlongScreenEdge();
        CubeHandleText.Text = $"按住拖动位置 ({(int)Math.Round(_service.EdgeOffsetRatio * 100)}%)";
    }

    private void CubeHandle_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (!_draggingCube) return;
        _draggingCube = false;
        (sender as UIElement)?.ReleaseMouseCapture();
        _service.SaveSettingsToDisk();
    }

    private void OpenReceived_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            string? target = _service.LastReceivedFilePath;
            if (!string.IsNullOrEmpty(target) && (File.Exists(target) || Directory.Exists(target)))
                Process.Start("explorer.exe", $"/select,\"{target}\"");
            else
            {
                string dl = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "OmniFlow");
                Directory.CreateDirectory(dl);
                Process.Start("explorer.exe", $"\"{dl}\"");
            }
        }
        catch (Exception ex)
        {
            _service.AppendErrorLog($"[Portal] 打开接收目录失败: {ex.Message}");
        }
    }

    private void Dismiss_Click(object sender, RoutedEventArgs e)
    {
        _service.Phase = PortalTransferPhase.Idle;
        SyncVisualState();
    }
}
