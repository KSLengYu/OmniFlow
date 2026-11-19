using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Threading;

namespace MacBridgeUI;

public sealed partial class DeskflowService
{
    private void AppendUsbLog(string msg)
    {
        string line = $"[{DateTime.Now:HH:mm:ss}] {msg}";
        UsbLogs.Add(line);
        if (UsbLogs.Count > 150) UsbLogs.RemoveAt(0);
        LogMessage?.Invoke($"[USB] {msg}");
    }

    private int _usbOpSeq = 0;
    private bool _pendingRestoreComplete = false;
    private DateTime _suppressUsbIdleProbeHeadlineUntilUtc = DateTime.MinValue;

    private void StartUsbHardwareProbeLoop()
    {
        _usbProbeTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1300) };
        _usbProbeTimer.Tick += async (_, _) =>
        {
            var probe = await Task.Run(() =>
            {
                DeskflowTransport.RefreshLocalNicCacheSync();
                return UsbProbe.DetectAppleNcm();
            });
            UsbHardwareDetected = probe.Detected;
            if (probe.Detected)
            {
                UsbHardwareSummary = string.IsNullOrWhiteSpace(probe.FriendlyName) ? "Apple USB-C NCM Device" : probe.FriendlyName;
                UsbDriverService = string.IsNullOrWhiteSpace(probe.Service) ? "usbncm" : probe.Service;
                UsbSpeedLabel = probe.UsbSpeedLabel;
                UsbSpeedMbps = probe.UsbSpeedMbps;
                if (!UsbProcessRunning && !UsbActionBusy && UsbStateTone == "waiting" && DateTime.UtcNow > _suppressUsbIdleProbeHeadlineUntilUtc)
                {
                    UsbHeadline = AppLoc.T("检测到 Mac USB-C NCM 设备，待连接", "Mac USB-C NCM detected — ready to connect");
                    UsbSubline = AppLoc.T($"物理端口已连接 ({probe.UsbSpeedLabel} · 驱动 {UsbDriverService})，点击「启动 USB 直连」即可建立 10.13.37.x 直连", $"Link attached ({probe.UsbSpeedLabel} · Driver {UsbDriverService}). Click Start USB Direct to connect 10.13.37.x.");
                }
            }
            else
            {
                UsbHardwareSummary = AppLoc.T("未检测到 Apple USB-C NCM 设备", "No Apple USB-C NCM device");
                UsbDriverService = AppLoc.T("未连接", "Disconnected");
                UsbSpeedLabel = AppLoc.T("待插线", "Unplugged");
                UsbSpeedMbps = 0;
            }
            StateUpdated?.Invoke();
        };
        _usbProbeTimer.Start();
    }

    public void StartUsbTunnel()
    {
        if (UsbProcessRunning && _usbTunnelProcess != null && !_usbTunnelProcess.HasExited) return;
        int opSeq = ++_usbOpSeq;
        _suppressUsbIdleProbeHeadlineUntilUtc = DateTime.MinValue;
        UsbActionBusy = true;
        UsbStateTone = "working";
        UsbConnectProgress = 0.18;
        UsbProgressCeil = 0.36;
        UsbHeadline = AppLoc.T("正在初始化 USB 隧道引擎...", "Initializing USB Tunnel Engine...");
        UsbSubline = AppLoc.T("正在准备 WinUSB 绑定与 10.13.37.2 Wintun 虚拟网卡", "Preparing WinUSB binding and 10.13.37.2 Wintun virtual adapter");
        UsbActionHint = AppLoc.T("步骤 1/3 · 正在启动底层 USB 直连服务 (--pair 0 --no-wait)...", "Step 1/3 · Launching USB tunnel backend...");
        AppendUsbLog("正在启动 USB-C 直连隧道...");

        string exePath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "omniflow-usb.exe");
        if (!File.Exists(exePath)) exePath = @"C:\OmniFlow\omniflow-usb.exe";
        if (!File.Exists(exePath)) exePath = @"C:\MacBridge\MacBridge.exe";

        if (!File.Exists(exePath))
        {
            UsbActionBusy = false;
            UsbConnectProgress = 0.0;
            UsbProgressCeil = 0.0;
            UsbStateTone = "waiting";
            UsbHeadline = AppLoc.T("未找到 USB 隧道组件 (omniflow-usb.exe)", "Missing USB backend (omniflow-usb.exe)");
            UsbSubline = AppLoc.T("当前自动使用 LAN/Wi-Fi TLS 1.3 加密多通道传输", "Falling back to TLS 1.3 LAN/Wi-Fi encrypted multipath links");
            UsbActionHint = AppLoc.T("缺少 omniflow-usb.exe，如需 USB 直连请确认安装目录完整", "Ensure omniflow-usb.exe exists in the installation folder");
            AppendUsbLog("未找到 omniflow-usb.exe，跳过 USB 绑定");
            StateUpdated?.Invoke();
            return;
        }

        try
        {
            var psi = new System.Diagnostics.ProcessStartInfo
            {
                FileName = exePath,
                Arguments = "--pair 0 --no-wait",
                WorkingDirectory = Path.GetDirectoryName(exePath) ?? @"C:\OmniFlow",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8
            };
            var proc = new System.Diagnostics.Process { StartInfo = psi, EnableRaisingEvents = true };
            proc.OutputDataReceived += (_, ev) =>
            {
                if (!string.IsNullOrWhiteSpace(ev.Data))
                    _dispatcher.BeginInvoke(() => HandleUsbEngineOutputLine(ev.Data));
            };
            proc.ErrorDataReceived += (_, ev) =>
            {
                if (!string.IsNullOrWhiteSpace(ev.Data))
                    _dispatcher.BeginInvoke(() => HandleUsbEngineOutputLine(ev.Data));
            };
            proc.Exited += (_, _) =>
            {
                int exitCode = -1;
                try { exitCode = proc.ExitCode; } catch { }
                _dispatcher.BeginInvoke(() =>
                {
                    if (opSeq != _usbOpSeq || UsbStateTone is "stopping" or "completing") return;
                    bool expectedStop = !UsbProcessRunning;
                    UsbProcessRunning = false;
                    UsbActionBusy = false;
                    if (!expectedStop && UsbStateTone != "connected")
                    {
                        UsbConnectProgress = 0.0;
                        UsbProgressCeil = 0.0;
                        UsbStateTone = "waiting";
                        UsbHeadline = AppLoc.T("USB 直连进程已退出", "USB Direct process exited");
                        UsbSubline = AppLoc.T($"退出码 {exitCode} · 请检查 USB-C 数据线或点击「启动 USB 直连」重试", $"Exit code {exitCode} · Check USB-C cable or click Start USB Direct");
                        UsbActionHint = AppLoc.T($"进程已停止 (exit={exitCode})", $"Process exited ({exitCode})");
                        AppendUsbLog($"USB 隧道进程已退出 (exit={exitCode})");
                    }
                    RefreshNicChannels(DeskflowUsbConstants.WinUsbIp, DeskflowUsbConstants.MacUsbIp, UsbSpeedMbps > 0 ? UsbSpeedMbps : DeskflowUsbConstants.DefaultUsbSpeedMbps);
                    StateUpdated?.Invoke();
                });
            };
            proc.Start();
            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();
            _usbTunnelProcess = proc;
            UsbProcessRunning = true;
            UsbConnectProgress = Math.Max(UsbConnectProgress, 0.28);
            UsbProgressCeil = Math.Max(UsbProgressCeil, 0.48);
            UsbActionHint = AppLoc.T("步骤 1/3 · 已静默拉起 USB 隧道，正在检测 Apple NCM 接口...", "Step 1/3 · USB backend started, probing Apple NCM interface...");
            Transport.ReconnectChannel("USB-C NCM", DeskflowUsbConstants.WinUsbIp, DeskflowUsbConstants.MacUsbIp);
            Transport.AddManualPeerIp(DeskflowUsbConstants.MacUsbIp);
            StateUpdated?.Invoke();
        }
        catch (Exception ex)
        {
            UsbActionBusy = false;
            UsbProcessRunning = false;
            UsbConnectProgress = 0.0;
            UsbProgressCeil = 0.0;
            UsbStateTone = "waiting";
            UsbHeadline = AppLoc.T("启动 USB 直连失败", "Failed to start USB Direct");
            UsbSubline = ex.Message;
            UsbActionHint = ex.Message;
            AppendUsbLog($"启动失败: {ex.Message}");
            StateUpdated?.Invoke();
        }
    }

    private void HandleUsbEngineOutputLine(string line)
    {
        AppendUsbLog(line);
        if (!UsbProcessRunning || UsbStateTone is "stopping" or "completing")
        {
            StateUpdated?.Invoke();
            return;
        }
        if (line.Contains("[DRIVER]", StringComparison.OrdinalIgnoreCase))
        {
            UsbStateTone = "working";
            UsbConnectProgress = Math.Max(UsbConnectProgress, 0.42);
            UsbProgressCeil = Math.Max(UsbProgressCeil, 0.68);
            UsbHeadline = AppLoc.T("正在安装并绑定 WinUSB 驱动...", "Installing & binding WinUSB driver...");
            UsbSubline = AppLoc.T("正在为苹果 USB-C NCM 接口自动签发 WinUSB 控制权", "Attaching WinUSB driver to Apple USB-C NCM interface");
            UsbActionHint = line;
        }
        else if (line.Contains("[OK] WinUSB", StringComparison.OrdinalIgnoreCase) || line.Contains("WinUSB already bound", StringComparison.OrdinalIgnoreCase))
        {
            UsbStateTone = "working";
            UsbConnectProgress = Math.Max(UsbConnectProgress, 0.72);
            UsbProgressCeil = Math.Max(UsbProgressCeil, 0.86);
            UsbHeadline = AppLoc.T("WinUSB 绑定完成，正在激活 10.13.37.2 网卡...", "WinUSB ready, activating 10.13.37.2 virtual NIC...");
            UsbActionHint = line;
        }
        else if (line.Contains("Tunnel UP", StringComparison.OrdinalIgnoreCase) || line.Contains("10.13.37.2", StringComparison.OrdinalIgnoreCase))
        {
            UsbActionBusy = false;
            UsbStateTone = "working";
            UsbConnectProgress = Math.Max(UsbConnectProgress, 0.88);
            UsbProgressCeil = Math.Max(UsbProgressCeil, 0.97);
            UsbHeadline = AppLoc.T("Wintun 隧道已启动，正在与 Mac 建连...", "Wintun tunnel UP, handshaking with Mac...");
            UsbSubline = AppLoc.T("本机 10.13.37.2 已就绪，正在握手 Mac 端 (10.13.37.1:24810)", "10.13.37.2 active, connecting to Mac (10.13.37.1:24810)");
            UsbActionHint = AppLoc.T("步骤 3/3 · Wintun 隧道已运行，正在自动建立高速传输通道...", "Step 3/3 · Wintun tunnel running, establishing data channel...");
            Transport.AddManualPeerIp(DeskflowUsbConstants.MacUsbIp);
            RefreshNicChannels(DeskflowUsbConstants.WinUsbIp, DeskflowUsbConstants.MacUsbIp, UsbSpeedMbps > 0 ? UsbSpeedMbps : DeskflowUsbConstants.DefaultUsbSpeedMbps);
        }
        else if (line.StartsWith("[STAT]", StringComparison.OrdinalIgnoreCase))
        {
            var mRx = System.Text.RegularExpressions.Regex.Match(line, @"rx=(\d+)");
            var mTx = System.Text.RegularExpressions.Regex.Match(line, @"tx=(\d+)");
            if (mRx.Success && long.TryParse(mRx.Groups[1].Value, out long rx)) UsbRxPackets = rx;
            if (mTx.Success && long.TryParse(mTx.Groups[1].Value, out long tx)) UsbTxPackets = tx;
        }
        else if (line.Contains("[FATAL]", StringComparison.OrdinalIgnoreCase) || line.Contains("[ERR]", StringComparison.OrdinalIgnoreCase))
        {
            UsbActionBusy = false;
            UsbStateTone = "stopping";
            UsbHeadline = AppLoc.T("USB 隧道遇到异常", "USB tunnel encountered an error");
            UsbSubline = line;
            UsbActionHint = line;
        }
        StateUpdated?.Invoke();
    }

    public void StopUsbTunnel(bool alsoRestoreAppleDriver = false)
    {
        int opSeq = ++_usbOpSeq;
        _pendingRestoreComplete = alsoRestoreAppleDriver;

        // Immediately drop USB transport links & failover to Ethernet/LAN BEFORE tearing down Wintun/WinUSB so KVM/transfers never stall!
        Transport.DisconnectChannel("USB-C NCM", DeskflowUsbConstants.WinUsbIp);
        Transport.EnsureLanLinksConnected();

        UsbProcessRunning = false;
        UsbActionBusy = true;
        UsbStateTone = "stopping";
        UsbConnectProgress = 0.22;
        UsbProgressCeil = alsoRestoreAppleDriver ? 0.52 : 0.88;
        UsbHeadline = alsoRestoreAppleDriver
            ? AppLoc.T("正在停止隧道并恢复苹果原厂驱动...", "Stopping tunnel & restoring Apple driver...")
            : AppLoc.T("正在停止 USB 直连通道...", "Stopping USB Direct link...");
        UsbSubline = alsoRestoreAppleDriver
            ? AppLoc.T("步骤 1/2 · 正在安全关闭 USB 隧道与 Wintun 虚拟网卡...", "Step 1/2 · Safely closing USB tunnel & Wintun NIC...")
            : AppLoc.T("已切回以太网/LAN，后台正在关闭 USB 隧道...", "Switched back to Ethernet/LAN, closing USB tunnel...");
        UsbActionHint = AppLoc.T("控制与数据链路已切回以太网 · 后台正在执行清理...", "Traffic failed over to LAN · Cleaning up in background...");
        AppendUsbLog(alsoRestoreAppleDriver ? "断开通道并恢复苹果原厂 USB 驱动..." : "正在手动停止 USB 直连隧道（已即时切回以太网）...");
        RefreshNicChannels(DeskflowUsbConstants.WinUsbIp, DeskflowUsbConstants.MacUsbIp, DeskflowUsbConstants.DefaultUsbSpeedMbps);
        StateUpdated?.Invoke();

        _ = Task.Run(async () =>
        {
            await Task.Delay(70);
            try
            {
                if (_usbTunnelProcess != null)
                    StopUsbProcessGracefully(_usbTunnelProcess);
                _usbTunnelProcess = null;
                foreach (var p in System.Diagnostics.Process.GetProcessesByName("omniflow-usb"))
                    StopUsbProcessGracefully(p);
            }
            catch { }

            if (alsoRestoreAppleDriver)
            {
                _ = _dispatcher.BeginInvoke(() =>
                {
                    if (opSeq != _usbOpSeq) return;
                    UsbStateTone = "stopping";
                    UsbConnectProgress = 0.58;
                    UsbProgressCeil = 0.92;
                    UsbHeadline = AppLoc.T("正在恢复苹果原厂 USB 驱动...", "Restoring Apple USB NCM driver...");
                    UsbSubline = AppLoc.T("步骤 2/2 · 正在卸载 WinUSB 并重新绑定 Apple USB-C NCM...", "Step 2/2 · Removing WinUSB and rebinding Apple USB-C NCM...");
                    UsbActionHint = AppLoc.T("正在还原驱动签名，请稍候...", "Restoring driver binding, please wait...");
                    StateUpdated?.Invoke();
                });
                CleanupAndRestoreAppleUsbDriver();
            }

            DeskflowTransport.RefreshLocalNicCacheSync();

            _ = _dispatcher.BeginInvoke(() =>
            {
                if (opSeq != _usbOpSeq) return;
                UsbStateTone = "completing";
                UsbConnectProgress = 1.0;
                UsbProgressCeil = 1.0;
                UsbHeadline = alsoRestoreAppleDriver
                    ? AppLoc.T("正在完成驱动恢复...", "Completing driver restore...")
                    : AppLoc.T("正在完成断开清理...", "Finalizing USB teardown...");
                UsbSubline = alsoRestoreAppleDriver
                    ? AppLoc.T("苹果原厂 USB 驱动已还原，正在刷新设备状态...", "Apple USB driver restored, refreshing status...")
                    : AppLoc.T("USB 直连已停用，当前通过以太网/Wi-Fi 保持连接", "USB stopped; active connection continues over Ethernet/Wi-Fi");
                UsbActionHint = "即将完成 (100%)...";
                StateUpdated?.Invoke();
            });

            // Fallback in case main window is closed/hidden and UI completion callback doesn't fire
            await Task.Delay(1600);
            _ = _dispatcher.BeginInvoke(() =>
            {
                if (opSeq == _usbOpSeq && UsbStateTone == "completing")
                    FinishUsbCompletingTransition();
            });
        });
    }

    public void FinishUsbCompletingTransition()
    {
        if (UsbStateTone != "completing") return;
        bool restored = _pendingRestoreComplete;
        _suppressUsbIdleProbeHeadlineUntilUtc = DateTime.UtcNow.AddSeconds(5);
        UsbActionBusy = false;
        UsbConnectProgress = 0.0;
        UsbProgressCeil = 0.0;
        UsbStateTone = "waiting";
        UsbHeadline = restored ? "已恢复苹果原厂 USB 驱动" : "USB 直连已手动断开";
        UsbSubline = restored
            ? "已卸载 WinUSB，其他苹果设备现在可正常使用；点击「启动 USB 直连」可随时重新连接"
            : "已安全停用 USB，LAN/Wi-Fi 通道正常工作；点击「启动 USB 直连」可随时重连";
        UsbActionHint = restored ? "已卸载 WinUSB，苹果原厂驱动已就绪" : "已安全停用 USB，LAN/Wi-Fi 通道正常工作";
        Transport.EnsureLanLinksConnected();
        RefreshNicChannels(DeskflowUsbConstants.WinUsbIp, DeskflowUsbConstants.MacUsbIp, DeskflowUsbConstants.DefaultUsbSpeedMbps);
        StateUpdated?.Invoke();
    }

    private static void StopUsbProcessGracefully(System.Diagnostics.Process p)
    {
        try
        {
            if (p.HasExited) return;
            try
            {
                if (System.Threading.EventWaitHandle.TryOpenExisting($"Local\\MacBridgeStop_{p.Id}", out var stopEv))
                {
                    using (stopEv) { stopEv.Set(); }
                    if (p.WaitForExit(2500)) return;
                }
            }
            catch { }
            if (!p.HasExited)
            {
                p.Kill(entireProcessTree: true);
                p.WaitForExit(2000);
            }
        }
        catch { }
    }

    public void CleanupAndRestoreAppleUsbDriver()
    {
        try
        {
            if (_usbTunnelProcess != null)
            {
                StopUsbProcessGracefully(_usbTunnelProcess);
                _usbTunnelProcess = null;
            }
            foreach (var p in System.Diagnostics.Process.GetProcessesByName("omniflow-usb"))
            {
                StopUsbProcessGracefully(p);
            }
            string restoreExe = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "omniflow-restore.exe");
            if (!File.Exists(restoreExe))
                restoreExe = @"C:\OmniFlow\omniflow-restore.exe";
            if (!File.Exists(restoreExe))
                restoreExe = @"C:\MacBridge\MacBridge-Restore.exe";

            if (File.Exists(restoreExe))
            {
                var psi = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = restoreExe,
                    Arguments = "--no-pause",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = System.Diagnostics.ProcessWindowStyle.Hidden,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };
                using var proc = System.Diagnostics.Process.Start(psi);
                proc?.WaitForExit(8000);
            }
        }
        catch { }
    }
}
