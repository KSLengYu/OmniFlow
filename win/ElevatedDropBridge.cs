using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32.SafeHandles;

namespace MacBridgeUI;

/// <summary>
/// Solves Windows UIPI blocking Explorer (Medium IL) -> OmniFlow (High IL Admin) OLE drag-and-drop
/// by spawning an invisible, click-non-blocking Medium-IL child proxy (`--drop-proxy`) during external drags.
/// </summary>
public static class ElevatedDropBridge
{
    internal static string EncodePaths(string[] paths) =>
        string.Join(";", paths.Select(p => Convert.ToBase64String(Encoding.UTF8.GetBytes(p))));

    internal static string[] DecodePaths(string payload)
    {
        if (string.IsNullOrWhiteSpace(payload)) return Array.Empty<string>();
        var list = new List<string>();
        foreach (var part in payload.Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                string p = Encoding.UTF8.GetString(Convert.FromBase64String(part));
                if (!string.IsNullOrWhiteSpace(p)) list.Add(p);
            }
            catch { }
        }
        return list.ToArray();
    }

    public static void RunProxy(int parentPid, string pipeName, string secret)
    {
        var dispatcher = Application.Current.Dispatcher;
        ProxySession? session = null;
        try
        {
            session = new ProxySession(dispatcher, parentPid, pipeName, secret);
            session.Start();
        }
        catch
        {
            try { session?.Dispose(); } catch { }
            try { Application.Current.Shutdown(1); } catch { Environment.Exit(1); }
        }
    }

    private sealed class ProxySession : IDisposable
    {
        private readonly Dispatcher _dispatcher;
        private readonly int _parentPid;
        private readonly string _pipeName;
        private readonly string _secret;
        private readonly CancellationTokenSource _cts = new();
        private NamedPipeClientStream? _pipe;
        private StreamWriter? _writer;
        private readonly object _writeLock = new();
        private ProxyDropWindow? _edgeWin;
        private ProxyDropWindow? _mainWin;
        private DispatcherTimer? _watchdogTimer;
        private DateTime _lbuttonUpSinceUtc = DateTime.MinValue;
        private bool _disposed;

        public ProxySession(Dispatcher dispatcher, int parentPid, string pipeName, string secret)
        {
            _dispatcher = dispatcher;
            _parentPid = parentPid;
            _pipeName = pipeName;
            _secret = secret;
        }

        public void Start()
        {
            _edgeWin = new ProxyDropWindow("edge", SendLine, HideBothWindows);
            _mainWin = new ProxyDropWindow("main", SendLine, HideBothWindows);
            _edgeWin.WarmUpHandle();
            _mainWin.WarmUpHandle();

            _watchdogTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
            _watchdogTimer.Tick += Watchdog_Tick;

            _ = Task.Run(() => MonitorParentExit(_parentPid, _cts.Token));
            _ = Task.Run(() => ConnectAndReadLoop(_cts.Token));
        }

        private void Watchdog_Tick(object? sender, EventArgs e)
        {
            bool anyVisible = (_edgeWin?.IsProxyVisible ?? false) || (_mainWin?.IsProxyVisible ?? false);
            if (!anyVisible)
            {
                _lbuttonUpSinceUtc = DateTime.MinValue;
                _watchdogTimer?.Stop();
                return;
            }
            if ((Win32DropNative.GetAsyncKeyState(Win32DropNative.VK_LBUTTON) & 0x8000) != 0)
            {
                _lbuttonUpSinceUtc = DateTime.MinValue;
                return;
            }
            if (_lbuttonUpSinceUtc == DateTime.MinValue)
            {
                _lbuttonUpSinceUtc = DateTime.UtcNow;
                return;
            }
            if ((DateTime.UtcNow - _lbuttonUpSinceUtc).TotalMilliseconds > 1500)
            {
                HideBothWindows();
            }
        }

        private async Task ConnectAndReadLoop(CancellationToken ct)
        {
            try
            {
                _pipe = new NamedPipeClientStream(".", _pipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
                await _pipe.ConnectAsync(5000, ct);
                _writer = new StreamWriter(_pipe, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
                SendLine($"AUTH|{_secret}");
                _ = _dispatcher.BeginInvoke(DispatcherPriority.Loaded, () =>
                {
                    bool eOle = _edgeWin?.HasOleDropTarget ?? false;
                    bool mOle = _mainWin?.HasOleDropTarget ?? false;
                    string eDiag = _edgeWin?.RegDiagnostic ?? "";
                    string mDiag = _mainWin?.RegDiagnostic ?? "";
                    SendLine($"READY|proxy|edge={eOle}({eDiag}),main={mOle}({mDiag})");
                });

                using var reader = new StreamReader(_pipe, Encoding.UTF8, leaveOpen: true);
                while (!ct.IsCancellationRequested)
                {
                    string? line = await reader.ReadLineAsync(ct);
                    if (line == null) break;
                    HandleHostCommand(line);
                }
            }
            catch { }
            finally
            {
                _ = _dispatcher.BeginInvoke(() =>
                {
                    Dispose();
                    try { Application.Current.Shutdown(0); } catch { Environment.Exit(0); }
                });
            }
        }

        private void HandleHostCommand(string line)
        {
            var parts = line.Split('|');
            if (parts.Length == 0) return;
            switch (parts[0])
            {
                case "QUIT":
                    _cts.Cancel();
                    break;
                case "HIDE":
                    _dispatcher.BeginInvoke(HideBothWindows);
                    break;
                case "SHOW":
                    // SHOW|edge|x|y|w|h|main|x|y|w|h
                    if (parts.Length >= 11 &&
                        int.TryParse(parts[2], out int ex) && int.TryParse(parts[3], out int ey) &&
                        int.TryParse(parts[4], out int ew) && int.TryParse(parts[5], out int eh) &&
                        int.TryParse(parts[7], out int mx) && int.TryParse(parts[8], out int my) &&
                        int.TryParse(parts[9], out int mw) && int.TryParse(parts[10], out int mh))
                    {
                        _dispatcher.BeginInvoke(() =>
                        {
                            if (_disposed) return;
                            if (ew > 0 && eh > 0) _edgeWin?.ShowAtPixels(ex, ey, ew, eh);
                            else _edgeWin?.HideProxy();

                            if (mw > 0 && mh > 0) _mainWin?.ShowAtPixels(mx, my, mw, mh);
                            else _mainWin?.HideProxy();

                            _lbuttonUpSinceUtc = DateTime.MinValue;
                            if ((ew > 0 && eh > 0) || (mw > 0 && mh > 0))
                                _watchdogTimer?.Start();
                        });
                    }
                    break;
                case "BOUNDS":
                    // BOUNDS|edge|x|y|w|h
                    if (parts.Length >= 6 && parts[1] == "edge" &&
                        int.TryParse(parts[2], out int bx) && int.TryParse(parts[3], out int by) &&
                        int.TryParse(parts[4], out int bw) && int.TryParse(parts[5], out int bh))
                    {
                        _dispatcher.BeginInvoke(() =>
                        {
                            if (_disposed || _edgeWin == null) return;
                            if (bw > 0 && bh > 0 && _edgeWin.IsProxyVisible)
                                _edgeWin.ShowAtPixels(bx, by, bw, bh);
                        });
                    }
                    break;
            }
        }

        private void HideBothWindows()
        {
            _edgeWin?.HideProxy();
            _mainWin?.HideProxy();
            _lbuttonUpSinceUtc = DateTime.MinValue;
            _watchdogTimer?.Stop();
        }

        private void SendLine(string line)
        {
            lock (_writeLock)
            {
                try { _writer?.WriteLine(line); } catch { }
            }
        }

        private void MonitorParentExit(int parentPid, CancellationToken ct)
        {
            IntPtr hParent = Win32DropNative.OpenProcess(Win32DropNative.SYNCHRONIZE, false, (uint)parentPid);
            if (hParent != IntPtr.Zero)
            {
                try
                {
                    while (!ct.IsCancellationRequested)
                    {
                        uint res = Win32DropNative.WaitForSingleObject(hParent, 500);
                        if (res == 0) break; // Parent signaled exit
                    }
                }
                finally { Win32DropNative.CloseHandle(hParent); }
            }
            else
            {
                while (!ct.IsCancellationRequested)
                {
                    try
                    {
                        using var p = Process.GetProcessById(parentPid);
                        if (p.HasExited) break;
                    }
                    catch { break; }
                    Thread.Sleep(500);
                }
            }
            _cts.Cancel();
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            try { _cts.Cancel(); } catch { }
            try { _watchdogTimer?.Stop(); } catch { }
            if (_dispatcher.CheckAccess())
            {
                try { _edgeWin?.Dispose(); } catch { }
                try { _mainWin?.Dispose(); } catch { }
            }
            try { _writer?.Dispose(); } catch { }
            try { _pipe?.Dispose(); } catch { }
        }
    }

    private sealed class ProxyDropWindow : Win32DropNative.IOleDropTarget, IDisposable
    {
        private readonly string _tag;
        private readonly Action<string> _sendLine;
        private readonly Action _hideAll;
        private IntPtr _hwnd;
        private int _lastX, _lastY, _lastW, _lastH;
        private int _oleInitHr = -1;
        private int _oleRegHr = -1;
        private bool _dragHasFiles;
        private bool _disposed;
        public bool IsProxyVisible { get; private set; }
        public bool HasOleDropTarget => _oleRegHr == 0 && _hwnd != IntPtr.Zero && Win32DropNative.GetPropW(_hwnd, "OleDropTargetInterface") != IntPtr.Zero;
        public string RegDiagnostic => $"init=0x{_oleInitHr:X8},reg=0x{_oleRegHr:X8}";

        private const string WindowClassName = "OmniFlowDropProxyWnd";
        private static readonly Win32DropNative.WndProcDelegate _wndProc = ProxyWndProc;
        private static bool _classRegistered;

        public ProxyDropWindow(string tag, Action<string> sendLine, Action hideAll)
        {
            _tag = tag;
            _sendLine = sendLine;
            _hideAll = hideAll;
        }

        private static void EnsureWindowClassRegistered()
        {
            if (_classRegistered) return;
            var wc = new Win32DropNative.WNDCLASSEXW
            {
                cbSize = (uint)Marshal.SizeOf<Win32DropNative.WNDCLASSEXW>(),
                lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wndProc),
                hInstance = Win32DropNative.GetModuleHandle(null),
                hbrBackground = IntPtr.Zero,
                lpszClassName = WindowClassName
            };
            ushort atom = Win32DropNative.RegisterClassExW(ref wc);
            if (atom != 0 || Marshal.GetLastWin32Error() == 1410) // ERROR_CLASS_ALREADY_EXISTS
                _classRegistered = true;
        }

        private static IntPtr ProxyWndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
        {
            switch (msg)
            {
                case Win32DropNative.WM_ERASEBKGND:
                    return new IntPtr(1);
                case Win32DropNative.WM_PAINT:
                    Win32DropNative.BeginPaint(hwnd, out var ps);
                    Win32DropNative.FillRect(ps.hdc, ref ps.rcPaint, Win32DropNative.GetStockObject(Win32DropNative.BLACK_BRUSH));
                    Win32DropNative.EndPaint(hwnd, ref ps);
                    return IntPtr.Zero;
                case Win32DropNative.WM_NCHITTEST:
                    return new IntPtr(Win32DropNative.HTCLIENT);
                case Win32DropNative.WM_MOUSEACTIVATE:
                    return new IntPtr(Win32DropNative.MA_NOACTIVATE);
                default:
                    return Win32DropNative.DefWindowProcW(hwnd, msg, wParam, lParam);
            }
        }

        public void WarmUpHandle()
        {
            if (_hwnd != IntPtr.Zero || _disposed) return;
            EnsureWindowClassRegistered();

            uint exStyle = Win32DropNative.WS_EX_LAYERED |
                           Win32DropNative.WS_EX_TOOLWINDOW |
                           Win32DropNative.WS_EX_NOACTIVATE |
                           Win32DropNative.WS_EX_TOPMOST;
            uint style = Win32DropNative.WS_POPUP;

            _hwnd = Win32DropNative.CreateWindowExW(
                exStyle,
                WindowClassName,
                $"OmniFlowDrop_{_tag}",
                style,
                -32000, -32000, 1, 1,
                IntPtr.Zero, IntPtr.Zero,
                Win32DropNative.GetModuleHandle(null),
                IntPtr.Zero);

            if (_hwnd != IntPtr.Zero)
            {
                // Pure Win32 layered HWND (zero WPF Direct3D swapchain): alpha=1 is visually transparent
                // while 100% solid for Win32 hit-testing & OLE RegisterDragDrop across all pixels.
                Win32DropNative.SetLayeredWindowAttributes(_hwnd, 0, 1, Win32DropNative.LWA_ALPHA);
                try
                {
                    _oleInitHr = Win32DropNative.OleInitialize(IntPtr.Zero);
                    _oleRegHr = Win32DropNative.RegisterDragDrop(_hwnd, this);
                }
                catch { _oleRegHr = -2; }
            }
            IsProxyVisible = false;
            _lastX = _lastY = _lastW = _lastH = 0;
        }

        public void ShowAtPixels(int x, int y, int w, int h)
        {
            if (w <= 0 || h <= 0)
            {
                HideProxy();
                return;
            }
            if (_hwnd == IntPtr.Zero) WarmUpHandle();
            if (_hwnd == IntPtr.Zero) return;
            if (IsProxyVisible && _lastX == x && _lastY == y && _lastW == w && _lastH == h)
                return;
            _lastX = x;
            _lastY = y;
            _lastW = w;
            _lastH = h;
            IsProxyVisible = true;
            Win32DropNative.SetWindowPos(
                _hwnd,
                Win32DropNative.HWND_TOPMOST,
                x, y, w, h,
                Win32DropNative.SWP_NOACTIVATE | Win32DropNative.SWP_SHOWWINDOW | Win32DropNative.SWP_NOOWNERZORDER);
        }

        public void HideProxy()
        {
            _dragHasFiles = false;
            if (!IsProxyVisible) return;
            IsProxyVisible = false;
            _lastX = _lastY = _lastW = _lastH = 0;
            if (_hwnd != IntPtr.Zero)
                Win32DropNative.ShowWindow(_hwnd, Win32DropNative.SW_HIDE);
        }

        int Win32DropNative.IOleDropTarget.DragEnter(
            System.Runtime.InteropServices.ComTypes.IDataObject pDataObj,
            uint grfKeyState,
            Win32DropNative.POINTL pt,
            ref uint pdwEffect)
        {
            var files = ExtractValidDropFiles(pDataObj);
            _dragHasFiles = files.Length > 0;
            if (_dragHasFiles && (pdwEffect & 1u) != 0)
            {
                pdwEffect = 1u; // DROPEFFECT_COPY
                _sendLine($"ENTER|{_tag}|{EncodePaths(files)}");
            }
            else
            {
                pdwEffect = 0u; // DROPEFFECT_NONE
            }
            return 0;
        }

        int Win32DropNative.IOleDropTarget.DragOver(
            uint grfKeyState,
            Win32DropNative.POINTL pt,
            ref uint pdwEffect)
        {
            pdwEffect = (_dragHasFiles && (pdwEffect & 1u) != 0) ? 1u : 0u;
            return 0;
        }

        int Win32DropNative.IOleDropTarget.DragLeave()
        {
            _dragHasFiles = false;
            _sendLine($"LEAVE|{_tag}");
            return 0;
        }

        int Win32DropNative.IOleDropTarget.Drop(
            System.Runtime.InteropServices.ComTypes.IDataObject pDataObj,
            uint grfKeyState,
            Win32DropNative.POINTL pt,
            ref uint pdwEffect)
        {
            _dragHasFiles = false;
            var files = ExtractValidDropFiles(pDataObj);
            if (files.Length > 0 && (pdwEffect & 1u) != 0)
            {
                pdwEffect = 1u;
                _sendLine($"DROP|{_tag}|{EncodePaths(files)}");
            }
            else
            {
                pdwEffect = 0u;
            }
            _hideAll();
            return 0;
        }

        private static string[] ExtractValidDropFiles(System.Runtime.InteropServices.ComTypes.IDataObject? dataObj)
        {
            if (dataObj == null) return Array.Empty<string>();
            try
            {
                var fmt = new System.Runtime.InteropServices.ComTypes.FORMATETC
                {
                    cfFormat = 15, // CF_HDROP
                    ptd = IntPtr.Zero,
                    dwAspect = System.Runtime.InteropServices.ComTypes.DVASPECT.DVASPECT_CONTENT,
                    lindex = -1,
                    tymed = System.Runtime.InteropServices.ComTypes.TYMED.TYMED_HGLOBAL
                };
                if (dataObj.QueryGetData(ref fmt) != 0) return Array.Empty<string>();
                dataObj.GetData(ref fmt, out var medium);
                try
                {
                    if (medium.tymed != System.Runtime.InteropServices.ComTypes.TYMED.TYMED_HGLOBAL ||
                        medium.unionmember == IntPtr.Zero)
                        return Array.Empty<string>();
                    // Note: For CF_HDROP, medium.unionmember IS the HDROP (HGLOBAL) passed directly to DragQueryFileW
                    uint count = Win32DropNative.DragQueryFileW(medium.unionmember, 0xFFFFFFFF, null, 0);
                    if (count == 0) return Array.Empty<string>();
                    var paths = new List<string>((int)Math.Min(count, 4096));
                    for (uint i = 0; i < count; i++)
                    {
                        uint len = Win32DropNative.DragQueryFileW(medium.unionmember, i, null, 0);
                        if (len == 0) continue;
                        var sb = new StringBuilder((int)len + 2);
                        if (Win32DropNative.DragQueryFileW(medium.unionmember, i, sb, (uint)sb.Capacity) > 0)
                        {
                            string p = sb.ToString();
                            if (!string.IsNullOrWhiteSpace(p) && (File.Exists(p) || Directory.Exists(p)))
                                paths.Add(p);
                        }
                    }
                    return paths.ToArray();
                }
                finally
                {
                    Win32DropNative.ReleaseStgMedium(ref medium);
                }
            }
            catch { return Array.Empty<string>(); }
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            if (_hwnd != IntPtr.Zero)
            {
                try { Win32DropNative.RevokeDragDrop(_hwnd); } catch { }
                try { Win32DropNative.DestroyWindow(_hwnd); } catch { }
                _hwnd = IntPtr.Zero;
            }
        }
    }
}

public sealed class ElevatedDropHost : IDisposable
{
    private readonly Dispatcher _dispatcher;
    private readonly CancellationTokenSource _cts = new();
    private readonly object _writeLock = new();
    private NamedPipeServerStream? _pipe;
    private StreamWriter? _writer;
    private Process? _proxyProc;
    private int _restartCount;
    private bool _disposed;
    private bool _isReady;
    private bool _loggedDragSession;
    private DispatcherTimer? _releaseHideTimer;

    public event Action<string[]>? EdgeDragEntered;
    public event Action? EdgeDragLeft;
    public event Action<string[]>? EdgeDropped;
    public event Action? MainDragEntered;
    public event Action? MainDragLeft;
    public event Action<string[]>? MainDropped;
    public event Action<string>? LogMessage;

    public bool IsActive => _isReady && !_disposed;
    public uint ProxyProcessId { get { try { return _proxyProc != null && !_proxyProc.HasExited ? (uint)_proxyProc.Id : 0; } catch { return 0; } } }

    public ElevatedDropHost(Dispatcher dispatcher)
    {
        _dispatcher = dispatcher;
    }

    public void Start()
    {
        if (!DeskflowService.IsRunningAsAdministrator()) return;
        _releaseHideTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(140) };
        _releaseHideTimer.Tick += (_, _) =>
        {
            _releaseHideTimer.Stop();
            HideTargets();
        };
        _ = Task.Run(RunHostLoop);
    }

    public void ShowTargets(Int32Rect edgePx, Int32Rect mainPx)
    {
        if (!_isReady || _disposed) return;
        _releaseHideTimer?.Stop();
        if (!_loggedDragSession)
        {
            _loggedDragSession = true;
            LogMessage?.Invoke($"[DropBridge] 外部拖拽开始 edge=({edgePx.X},{edgePx.Y},{edgePx.Width}x{edgePx.Height}) main=({mainPx.X},{mainPx.Y},{mainPx.Width}x{mainPx.Height})");
        }
        SendLine($"SHOW|edge|{edgePx.X}|{edgePx.Y}|{edgePx.Width}|{edgePx.Height}|main|{mainPx.X}|{mainPx.Y}|{mainPx.Width}|{mainPx.Height}");
    }

    public void UpdateEdgeBounds(Int32Rect edgePx)
    {
        if (!_isReady || _disposed) return;
        SendLine($"BOUNDS|edge|{edgePx.X}|{edgePx.Y}|{edgePx.Width}|{edgePx.Height}");
    }

    public void ScheduleHideAfterRelease()
    {
        _loggedDragSession = false;
        if (!_isReady || _disposed) return;
        _releaseHideTimer?.Stop();
        _releaseHideTimer?.Start();
    }

    public void HideTargets()
    {
        _loggedDragSession = false;
        _releaseHideTimer?.Stop();
        if (!_isReady || _disposed) return;
        SendLine("HIDE");
    }

    private async Task RunHostLoop()
    {
        while (!_cts.IsCancellationRequested && _restartCount <= 3)
        {
            try
            {
                uint? explorerIl = Win32DropNative.GetExplorerIntegrityRid();
                if (explorerIl.HasValue && explorerIl.Value >= Win32DropNative.SECURITY_MANDATORY_HIGH_RID)
                {
                    LogMessage?.Invoke("[DropBridge] Shell 为高权限，原生拖放可直接工作");
                    return;
                }

                string? dotnetExe = Win32DropNative.FindDotNetHostExe();
                string dllPath = Path.Combine(AppContext.BaseDirectory, "OmniFlow.dll");
                if (string.IsNullOrWhiteSpace(dotnetExe) || !File.Exists(dllPath))
                {
                    LogMessage?.Invoke("[DropBridge Warn] 未找到 dotnet.exe 或 OmniFlow.dll，跳过 Medium-IL 拖放代理");
                    return;
                }

                string pipeName = $"OmniFlow_Drop_{Environment.ProcessId}_{Guid.NewGuid():N}";
                string secret = Convert.ToHexString(RandomNumberGenerator.GetBytes(16));

                var pipeSecurity = new PipeSecurity();
                var currentUser = WindowsIdentity.GetCurrent().User;
                if (currentUser != null)
                {
                    pipeSecurity.AddAccessRule(new PipeAccessRule(currentUser, PipeAccessRights.FullControl, AccessControlType.Allow));
                }

                using var pipe = NamedPipeServerStreamAcl.Create(
                    pipeName,
                    PipeDirection.InOut,
                    1,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous,
                    0,
                    0,
                    pipeSecurity);
                _pipe = pipe;

                string args = $"exec \"{dllPath}\" --drop-proxy {Environment.ProcessId} {pipeName} {secret}";
                _proxyProc = Win32DropNative.LaunchViaExplorerToken(dotnetExe, args, out string launchErr);
                if (_proxyProc == null)
                {
                    LogMessage?.Invoke($"[DropBridge Warn] 启动 Medium-IL 拖放代理失败: {launchErr}");
                    return;
                }

                using var connectCts = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
                connectCts.CancelAfter(6000);
                await pipe.WaitForConnectionAsync(connectCts.Token);

                if (!Win32DropNative.GetNamedPipeClientProcessId(pipe.SafePipeHandle, out uint clientPid) ||
                    clientPid != (uint)_proxyProc.Id)
                {
                    LogMessage?.Invoke($"[DropBridge Security] 拒绝非代理进程连接 (pid={clientPid})");
                    CleanupCurrentProxy();
                    return;
                }

                using var reader = new StreamReader(pipe, Encoding.UTF8, leaveOpen: true);
                using var writer = new StreamWriter(pipe, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
                _writer = writer;

                using var authCts = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
                authCts.CancelAfter(4000);
                string? authLine = await reader.ReadLineAsync(authCts.Token);
                if (authLine != $"AUTH|{secret}")
                {
                    LogMessage?.Invoke("[DropBridge Security] 代理管道握手校验失败");
                    CleanupCurrentProxy();
                    return;
                }

                _isReady = true;
                LogMessage?.Invoke($"[DropBridge] Medium-IL 文件拖放代理已就绪 (pid={_proxyProc.Id})");

                while (!_cts.IsCancellationRequested)
                {
                    string? line = await reader.ReadLineAsync(_cts.Token);
                    if (line == null) break;
                    DispatchProxyEvent(line);
                }
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                LogMessage?.Invoke($"[DropBridge Warn] 代理通道异常: {ex.Message}");
            }
            finally
            {
                _isReady = false;
                _writer = null;
                _pipe = null;
                CleanupCurrentProxy();
            }

            if (_cts.IsCancellationRequested || _disposed) break;
            _restartCount++;
            try { await Task.Delay(1200, _cts.Token); } catch { break; }
        }
    }

    private void DispatchProxyEvent(string line)
    {
        var parts = line.Split('|', 3);
        if (parts.Length < 2) return;
        string kind = parts[0];
        string target = parts[1];
        string payload = parts.Length >= 3 ? parts[2] : "";

        _dispatcher.BeginInvoke(() =>
        {
            if (_disposed) return;
            switch ((kind, target))
            {
                case ("READY", "proxy"):
                    LogMessage?.Invoke($"[DropBridge] 代理 OLE DropTarget 注册状态: {payload}");
                    break;
                case ("ENTER", "edge"):
                    var enterFiles = ElevatedDropBridge.DecodePaths(payload);
                    if (enterFiles.Length > 0)
                    {
                        LogMessage?.Invoke($"[DropBridge] 边缘区响应拖入 ({enterFiles.Length} 项)");
                        EdgeDragEntered?.Invoke(enterFiles);
                    }
                    break;
                case ("LEAVE", "edge"):
                    EdgeDragLeft?.Invoke();
                    break;
                case ("DROP", "edge"):
                    _releaseHideTimer?.Stop();
                    _loggedDragSession = false;
                    var edgeFiles = ElevatedDropBridge.DecodePaths(payload);
                    if (edgeFiles.Length > 0)
                    {
                        LogMessage?.Invoke($"[DropBridge] 边缘区松手触发发送 ({edgeFiles.Length} 项)");
                        EdgeDropped?.Invoke(edgeFiles);
                    }
                    break;
                case ("ENTER", "main"):
                    LogMessage?.Invoke("[DropBridge] 应用拖放框响应拖入");
                    MainDragEntered?.Invoke();
                    break;
                case ("LEAVE", "main"):
                    MainDragLeft?.Invoke();
                    break;
                case ("DROP", "main"):
                    _releaseHideTimer?.Stop();
                    _loggedDragSession = false;
                    var mainFiles = ElevatedDropBridge.DecodePaths(payload);
                    if (mainFiles.Length > 0)
                    {
                        LogMessage?.Invoke($"[DropBridge] 应用拖放框松手触发发送 ({mainFiles.Length} 项)");
                        MainDropped?.Invoke(mainFiles);
                    }
                    break;
            }
        });
    }

    private void SendLine(string line)
    {
        lock (_writeLock)
        {
            try { _writer?.WriteLine(line); } catch { }
        }
    }

    private void CleanupCurrentProxy()
    {
        try
        {
            if (_proxyProc != null && !_proxyProc.HasExited)
            {
                _proxyProc.WaitForExit(300);
                if (!_proxyProc.HasExited) _proxyProc.Kill(entireProcessTree: true);
            }
        }
        catch { }
        try { _proxyProc?.Dispose(); } catch { }
        _proxyProc = null;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _isReady = false;
        try { _releaseHideTimer?.Stop(); } catch { }
        SendLine("QUIT");
        try { _cts.Cancel(); } catch { }
        try { _pipe?.Dispose(); } catch { }
        CleanupCurrentProxy();
    }
}

internal static class Win32DropNative
{
    public const int GWL_EXSTYLE = -20;
    public const uint WS_POPUP = 0x80000000;
    public const uint WS_EX_TOOLWINDOW = 0x00000080;
    public const uint WS_EX_TOPMOST = 0x00000008;
    public const uint WS_EX_LAYERED = 0x00080000;
    public const uint WS_EX_NOACTIVATE = 0x08000000;
    public const uint LWA_ALPHA = 0x00000002;
    public const int SW_HIDE = 0;
    public const int VK_LBUTTON = 0x01;
    public const uint WM_PAINT = 0x000F;
    public const uint WM_ERASEBKGND = 0x0014;
    public const uint WM_MOUSEACTIVATE = 0x0021;
    public const uint WM_NCHITTEST = 0x0084;
    public const int HTCLIENT = 1;
    public const int MA_NOACTIVATE = 3;
    public const int BLACK_BRUSH = 4;
    public const uint SYNCHRONIZE = 0x00100000;
    public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    public const uint TOKEN_QUERY = 0x0008;
    public const uint TOKEN_DUPLICATE = 0x0002;
    public const uint TOKEN_ASSIGN_PRIMARY = 0x0001;
    public const uint TOKEN_ADJUST_DEFAULT = 0x0080;
    public const uint TOKEN_ADJUST_SESSIONID = 0x0100;
    public const uint MAXIMUM_ALLOWED = 0x02000000;
    public const uint SECURITY_MANDATORY_HIGH_RID = 0x00003000;
    public const uint CREATE_NO_WINDOW = 0x08000000;
    public const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_SHOWWINDOW = 0x0040;
    public const uint SWP_NOOWNERZORDER = 0x0200;
    public static readonly IntPtr HWND_TOPMOST = new(-1);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    public static extern IntPtr GetShellWindow();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr GetPropW(IntPtr hWnd, string lpString);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetLayeredWindowAttributes(IntPtr hwnd, uint crKey, byte bAlpha, uint dwFlags);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr GetModuleHandle(string? lpModuleName);

    [DllImport("gdi32.dll")]
    public static extern IntPtr GetStockObject(int fnObject);

    public delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WNDCLASSEXW
    {
        public uint cbSize;
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        public string? lpszMenuName;
        public string lpszClassName;
        public IntPtr hIconSm;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int left, top, right, bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PAINTSTRUCT
    {
        public IntPtr hdc;
        public bool fErase;
        public RECT rcPaint;
        public bool fRestore;
        public bool fIncUpdate;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
        public byte[] rgbReserved;
    }

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern ushort RegisterClassExW([In] ref WNDCLASSEXW lpwcx);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateWindowExW(
        uint dwExStyle,
        string lpClassName,
        string lpWindowName,
        uint dwStyle,
        int X, int Y, int nWidth, int nHeight,
        IntPtr hWndParent, IntPtr hMenu, IntPtr hInstance, IntPtr lpParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyWindow(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr DefWindowProcW(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern IntPtr BeginPaint(IntPtr hwnd, out PAINTSTRUCT lpPaint);

    [DllImport("user32.dll")]
    public static extern bool EndPaint(IntPtr hWnd, ref PAINTSTRUCT lpPaint);

    [DllImport("user32.dll")]
    public static extern int FillRect(IntPtr hDC, ref RECT lprc, IntPtr hbr);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINTL
    {
        public int x;
        public int y;
    }

    [ComImport]
    [Guid("00000122-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IOleDropTarget
    {
        [PreserveSig]
        int DragEnter(
            [In] System.Runtime.InteropServices.ComTypes.IDataObject pDataObj,
            [In] uint grfKeyState,
            [In] POINTL pt,
            [In, Out] ref uint pdwEffect);

        [PreserveSig]
        int DragOver(
            [In] uint grfKeyState,
            [In] POINTL pt,
            [In, Out] ref uint pdwEffect);

        [PreserveSig]
        int DragLeave();

        [PreserveSig]
        int Drop(
            [In] System.Runtime.InteropServices.ComTypes.IDataObject pDataObj,
            [In] uint grfKeyState,
            [In] POINTL pt,
            [In, Out] ref uint pdwEffect);
    }

    [DllImport("ole32.dll")]
    public static extern int OleInitialize(IntPtr pvReserved);

    [DllImport("ole32.dll")]
    public static extern int RegisterDragDrop(IntPtr hwnd, IOleDropTarget pDropTarget);

    [DllImport("ole32.dll")]
    public static extern int RevokeDragDrop(IntPtr hwnd);

    [DllImport("ole32.dll")]
    public static extern void ReleaseStgMedium(ref System.Runtime.InteropServices.ComTypes.STGMEDIUM pmedium);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern uint DragQueryFileW(IntPtr hDrop, uint iFile, StringBuilder? lpszFile, uint cch);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetNamedPipeClientProcessId(SafePipeHandle Pipe, out uint ClientProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ProcessIdToSessionId(uint dwProcessId, out uint pSessionId);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool DuplicateTokenEx(
        IntPtr hExistingToken,
        uint dwDesiredAccess,
        IntPtr lpTokenAttributes,
        int ImpersonationLevel,
        int TokenType,
        out IntPtr phNewToken);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessWithTokenW(
        IntPtr hToken,
        uint dwLogonFlags,
        string? lpApplicationName,
        string lpCommandLine,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string? lpCurrentDirectory,
        ref STARTUPINFOW lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(
        IntPtr TokenHandle,
        int TokenInformationClass,
        IntPtr TokenInformation,
        int TokenInformationLength,
        out int ReturnLength);

    [DllImport("advapi32.dll")]
    private static extern IntPtr GetSidSubAuthorityCount(IntPtr pSid);

    [DllImport("advapi32.dll")]
    private static extern IntPtr GetSidSubAuthority(IntPtr pSid, uint nSubAuthority);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFOW
    {
        public int cb;
        public string? lpReserved;
        public string? lpDesktop;
        public string? lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    private static uint FindExplorerPid()
    {
        IntPtr shellHwnd = GetShellWindow();
        if (shellHwnd != IntPtr.Zero)
        {
            GetWindowThreadProcessId(shellHwnd, out uint shellPid);
            if (shellPid != 0) return shellPid;
        }
        uint mySession = (uint)Process.GetCurrentProcess().SessionId;
        foreach (var p in Process.GetProcessesByName("explorer"))
        {
            try
            {
                if (ProcessIdToSessionId((uint)p.Id, out uint sess) && sess == mySession)
                    return (uint)p.Id;
            }
            catch { }
            finally { p.Dispose(); }
        }
        return 0;
    }

    public static uint? GetExplorerIntegrityRid()
    {
        uint pid = FindExplorerPid();
        if (pid == 0) return null;
        IntPtr hProc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (hProc == IntPtr.Zero) return null;
        IntPtr hTok = IntPtr.Zero;
        try
        {
            if (!OpenProcessToken(hProc, TOKEN_QUERY, out hTok)) return null;
            return GetTokenIntegrityRid(hTok);
        }
        finally
        {
            if (hTok != IntPtr.Zero) CloseHandle(hTok);
            CloseHandle(hProc);
        }
    }

    private static uint? GetTokenIntegrityRid(IntPtr hToken)
    {
        const int TokenIntegrityLevel = 25;
        GetTokenInformation(hToken, TokenIntegrityLevel, IntPtr.Zero, 0, out int len);
        if (len <= 0) return null;
        IntPtr buf = Marshal.AllocHGlobal(len);
        try
        {
            if (!GetTokenInformation(hToken, TokenIntegrityLevel, buf, len, out _)) return null;
            IntPtr pSid = Marshal.ReadIntPtr(buf);
            if (pSid == IntPtr.Zero) return null;
            byte subCount = Marshal.ReadByte(GetSidSubAuthorityCount(pSid));
            if (subCount == 0) return null;
            return unchecked((uint)Marshal.ReadInt32(GetSidSubAuthority(pSid, (uint)(subCount - 1))));
        }
        finally { Marshal.FreeHGlobal(buf); }
    }

    public static string? FindDotNetHostExe()
    {
        var candidates = new List<string>();
        string? root = Environment.GetEnvironmentVariable("DOTNET_ROOT");
        if (!string.IsNullOrWhiteSpace(root))
            candidates.Add(Path.Combine(root, "dotnet.exe"));
        string pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        if (!string.IsNullOrWhiteSpace(pf))
            candidates.Add(Path.Combine(pf, "dotnet", "dotnet.exe"));
        string? envPath = Environment.GetEnvironmentVariable("PATH");
        if (!string.IsNullOrWhiteSpace(envPath))
        {
            foreach (var dir in envPath.Split(';', StringSplitOptions.RemoveEmptyEntries))
                candidates.Add(Path.Combine(dir.Trim(), "dotnet.exe"));
        }
        return candidates.FirstOrDefault(File.Exists);
    }

    public static Process? LaunchViaExplorerToken(string exePath, string arguments, out string error)
    {
        error = "";
        uint explorerPid = FindExplorerPid();
        if (explorerPid == 0)
        {
            error = "未找到桌面 Explorer 进程";
            return null;
        }

        IntPtr hProc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, explorerPid);
        if (hProc == IntPtr.Zero)
        {
            error = new Win32Exception(Marshal.GetLastWin32Error()).Message;
            return null;
        }

        IntPtr hTok = IntPtr.Zero;
        IntPtr hDupTok = IntPtr.Zero;
        try
        {
            if (!OpenProcessToken(hProc, TOKEN_DUPLICATE | TOKEN_QUERY, out hTok))
            {
                error = $"OpenProcessToken: {new Win32Exception(Marshal.GetLastWin32Error()).Message}";
                return null;
            }
            if (!DuplicateTokenEx(
                    hTok,
                    TOKEN_ASSIGN_PRIMARY | TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_ADJUST_DEFAULT | TOKEN_ADJUST_SESSIONID,
                    IntPtr.Zero,
                    2, // SecurityImpersonation
                    1, // TokenPrimary
                    out hDupTok))
            {
                error = $"DuplicateTokenEx: {new Win32Exception(Marshal.GetLastWin32Error()).Message}";
                return null;
            }

            var si = new STARTUPINFOW
            {
                cb = Marshal.SizeOf<STARTUPINFOW>(),
                lpDesktop = @"winsta0\default"
            };
            string cmdLine = $"\"{exePath}\" {arguments}";
            if (!CreateProcessWithTokenW(
                    hDupTok,
                    0,
                    exePath,
                    cmdLine,
                    CREATE_NO_WINDOW,
                    IntPtr.Zero,
                    Path.GetDirectoryName(exePath),
                    ref si,
                    out var pi))
            {
                error = $"CreateProcessWithTokenW: {new Win32Exception(Marshal.GetLastWin32Error()).Message}";
                return null;
            }

            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
            return Process.GetProcessById(pi.dwProcessId);
        }
        catch (Exception ex)
        {
            error = ex.Message;
            return null;
        }
        finally
        {
            if (hDupTok != IntPtr.Zero) CloseHandle(hDupTok);
            if (hTok != IntPtr.Zero) CloseHandle(hTok);
            CloseHandle(hProc);
        }
    }
}
