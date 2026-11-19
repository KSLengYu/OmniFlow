using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace MacBridgeUI;

public sealed partial class DeskflowService
{
    public void ToggleManualFocusSwitch() => SetRemoteFocus(!RemoteFocusActive, broadcastToPeer: true);

    public void SetRemoteFocus(
        bool remoteOnMac,
        bool broadcastToPeer = true,
        double entryNormX = 0.5,
        double entryNormY = 0.5,
        uint crossTimeMs = 0,
        int crossHookDx = 0,
        int crossHookDy = 0,
        string crossEdgeLabel = "manual",
        int? crossCurX = null,
        int? crossCurY = null)
    {
        if (remoteOnMac && ControlMode == KvmControlMode.MacMasterOnly && broadcastToPeer)
        {
            LogMessage?.Invoke("[KVM] 当前为「仅 Mac 主控」模式，若需从 Windows 端发起控制请切换至「双端互控」。");
            return;
        }
        if (remoteOnMac && Transport.ActiveLinksSnapshot().Count == 0)
        {
            LogMessage?.Invoke("[KVM] 尚未连接 Mac 对端，无法切换远程焦点");
            RemoteFocusActive = false;
            StateUpdated?.Invoke();
            return;
        }

        long stageSeq = 0;
        long stageT0 = 0;
        int curX = 0;
        int curY = 0;
        int centerX = 0;
        int centerY = 0;
        bool rawInputActive = false;
        bool needRelocate = false;

        if (remoteOnMac)
        {
            _lastEdgeSwitchTime = DateTime.UtcNow;
            stageT0 = Stopwatch.GetTimestamp();
            stageSeq = broadcastToPeer ? WinKvmStageTracer.BeginCrossing(stageT0) : 0;
            if (_localMonitors.Count == 0) _localMonitors = DeskflowTransport.EnumerateRealWindowsMonitors();

            if (crossCurX.HasValue && crossCurY.HasValue)
            {
                curX = crossCurX.Value;
                curY = crossCurY.Value;
            }
            else if (GetCursorPos(out var curPt))
            {
                curX = curPt.x;
                curY = curPt.y;
            }
            else if (_hasPrevLocalPt)
            {
                curX = _prevLocalX;
                curY = _prevLocalY;
            }

            // Deskflow Server::switchComputer step 1: save entry coordinates on destination Mac screen
            uint tMs = crossTimeMs != 0 ? crossTimeMs : unchecked((uint)Environment.TickCount);
            rawInputActive = _cursorTracker.IsRawInputActive(stageT0);
            if (rawInputActive)
            {
                // Raw Input already supplies unbounded relative movement while the low-level hook
                // consumes local cursor motion. Keep the physical Windows cursor at the edge;
                // warping it here only blocks the hook callback and creates a visible jump.
                centerX = curX;
                centerY = curY;
            }
            else
            {
                // Keep the legacy absolute-hook fallback working when no hardware Raw Input stream
                // is available (for example, remote desktop or synthetic pointers).
                (centerX, centerY) = GetPrimaryCursorCenter();
                needRelocate = (centerX != curX || centerY != curY);
            }

            _cursorTracker.EnterRemote(
                centerX, centerY, curX, curY,
                crossHookDx, crossHookDy, tMs, stageT0, stageSeq,
                out int preOvershootX, out int preOvershootY);

            if (preOvershootX != 0 || preOvershootY != 0)
            {
                var (refW, refH) = GetActiveMacRefSize();
                entryNormX = Math.Clamp(entryNormX + preOvershootX / refW, 0.0, 1.0);
                entryNormY = Math.Clamp(entryNormY + preOvershootY / refH, 0.0, 1.0);
            }
            _remoteMacNormX = entryNormX;
            _remoteMacNormY = entryNormY;

            if (stageSeq > 0)
            {
                WinKvmStageTracer.Log(
                    stageSeq, stageT0,
                    $"edgeTrigger edge={crossEdgeLabel} cur=({curX},{curY}) prev=({(_hasPrevLocalPt ? _prevLocalX : curX)},{(_hasPrevLocalPt ? _prevLocalY : curY)}) hookDelta=({crossHookDx},{crossHookDy}) preOvershoot=({preOvershootX},{preOvershootY}) rawActive={rawInputActive} tMsg={tMs}",
                    stageT0);
            }
        }
        else
        {
            _hasPrevLocalPt = false;
            _cursorTracker.ExitRemote();
        }

        if (remoteOnMac)
        {
            // Rebase the Windows absolute cursor only for the fallback path. In Raw Input mode,
            // relative deltas continue even while the native pointer remains pinned at the edge.
            if (needRelocate)
            {
                SetCursorPos(centerX, centerY);
            }
            double ddx = centerX - curX;
            double ddy = centerY - curY;
            double relDist = Math.Sqrt(ddx * ddx + ddy * ddy);
            if (stageSeq > 0)
            {
                WinKvmStageTracer.Log(
                    stageSeq, stageT0,
                    $"cursorRelocate moved={needRelocate} rawActive={rawInputActive} from=({curX},{curY}) to=({centerX},{centerY}) dist={relDist:F1}px");
            }
        }

        bool wasRemote = RemoteFocusActive;
        RemoteFocusActive = remoteOnMac;
        if (remoteOnMac)
        {
            _leftButtonDown = false;
            _externalDragCandidate = false;
            if (_externalDragActive)
            {
                _externalDragActive = false;
                _dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, () => ExternalDragEnded?.Invoke());
            }
        }
        if (!remoteOnMac)
        {
            if (_tpThreeFingerDragging)
            {
                _tpThreeFingerDragging = false;
                Transport.SendControlFrame(DeskflowMsgType.MouseButton, new byte[] { 1, 0 });
            }
            if (_remoteLeftDown)
            {
                _remoteLeftDown = false;
                Transport.SendControlFrame(DeskflowMsgType.MouseButton, new byte[] { 1, 0 });
            }
            if (_remoteRightDown)
            {
                _remoteRightDown = false;
                Transport.SendControlFrame(DeskflowMsgType.MouseButton, new byte[] { 2, 0 });
            }
            if (wasRemote)
            {
                ReleaseRemoteModifiersOnMac();
            }
            _suppressedWinToMacVk = 0;
            _tpFingerCount = 0;
            _tpHasStart = false;
            _tpHasPrev = false;
        }
        if (broadcastToPeer)
        {
            // Deskflow ClientProxy1_0::enter step 3: send CINN (KvmFocusSwitch) with entry coordinate (no duplicate MouseMoveAbs)
            var focusPayload = new WireKvmFocusPayload
            {
                TargetOs = remoteOnMac ? "macOS" : "Windows",
                MonitorIndex = remoteOnMac ? _remoteMacMonIdx : 0,
                NormX = entryNormX,
                NormY = entryNormY
            };
            Transport.SendControlJson(DeskflowMsgType.KvmFocusSwitch, focusPayload);
            if (remoteOnMac)
            {
                var ctrlLink = Transport.ActiveLinksSnapshot().OrderBy(l => l.RttMs).FirstOrDefault();
                WinKvmStageTracer.Log(
                    stageSeq, stageT0,
                    $"focusSend mon={_remoteMacMonIdx} norm=({entryNormX:F4},{entryNormY:F4}) link={ctrlLink?.Id ?? "none"} rtt={ctrlLink?.RttMs:F2}ms");
            }
        }
        string focusLog = remoteOnMac ? "[KVM] 键鼠焦点已切换至 Mac" : "[KVM] 键鼠焦点已返回本机 Windows";
        _dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, () =>
        {
            LogMessage?.Invoke(focusLog);
            StateUpdated?.Invoke();
        });
    }

    private WireMonitorDto? FindMonitorForPoint(int px, int py)
    {
        if (_localMonitors.Count == 0) _localMonitors = DeskflowTransport.EnumerateRealWindowsMonitors();
        var lm = _localMonitors.FirstOrDefault(m =>
            px >= m.BoundsX - 6 && px <= m.BoundsX + m.WidthPx + 6 &&
            py >= m.BoundsY - 6 && py <= m.BoundsY + m.HeightPx + 6);
        return lm ?? (_localMonitors.Count > 0 ? _localMonitors[0] : null);
    }

    private (int centerX, int centerY) GetPrimaryCursorCenter()
    {
        if (_localMonitors.Count == 0) _localMonitors = DeskflowTransport.EnumerateRealWindowsMonitors();
        var primary = _localMonitors.FirstOrDefault(m => m.IsPrimary) ?? (_localMonitors.Count > 0 ? _localMonitors[0] : null);
        if (primary != null && primary.WidthPx > 0 && primary.HeightPx > 0)
        {
            return (primary.BoundsX + (primary.WidthPx >> 1), primary.BoundsY + (primary.HeightPx >> 1));
        }
        return (
            GetSystemMetrics(SM_XVIRTUALSCREEN) + (GetSystemMetrics(SM_CXVIRTUALSCREEN) >> 1),
            GetSystemMetrics(SM_YVIRTUALSCREEN) + (GetSystemMetrics(SM_CYVIRTUALSCREEN) >> 1));
    }

    private (double refW, double refH) GetActiveMacRefSize()
    {
        var activeMac = Monitors.FirstOrDefault(m => m.OsKind == "macOS" && Math.Max(0, m.DisplayIndex - 1) == _remoteMacMonIdx)
                        ?? Monitors.FirstOrDefault(m => m.OsKind == "macOS");
        double refW = activeMac != null ? Math.Max(1280.0, activeMac.WidthPx / Math.Max(1.0, activeMac.ScaleFactor)) : 1728.0;
        double refH = activeMac != null ? Math.Max(720.0, activeMac.HeightPx / Math.Max(1.0, activeMac.ScaleFactor)) : 1117.0;
        return (refW, refH);
    }

    public void InjectMouseMoveAbs(int monitorIndex, double normX, double normY)
    {
        if (_localMonitors.Count == 0) _localMonitors = DeskflowTransport.EnumerateRealWindowsMonitors();
        var mon = _localMonitors[Math.Clamp(monitorIndex, 0, _localMonitors.Count - 1)];

        double vLeft = GetSystemMetrics(SM_XVIRTUALSCREEN);
        double vTop = GetSystemMetrics(SM_YVIRTUALSCREEN);
        double vW = Math.Max(2, GetSystemMetrics(SM_CXVIRTUALSCREEN));
        double vH = Math.Max(2, GetSystemMetrics(SM_CYVIRTUALSCREEN));

        double px = mon.BoundsX + mon.WidthPx * Math.Clamp(normX, 0.0, 1.0);
        double py = mon.BoundsY + mon.HeightPx * Math.Clamp(normY, 0.0, 1.0);

        int absX = (int)Math.Round(((px - vLeft) * 65535.0) / Math.Max(1.0, vW - 1.0));
        int absY = (int)Math.Round(((py - vTop) * 65535.0) / Math.Max(1.0, vH - 1.0));

        var input = new INPUT
        {
            type = INPUT_MOUSE,
            U = new InputUnion
            {
                mi = new MOUSEINPUT
                {
                    dx = absX,
                    dy = absY,
                    dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
                    dwExtraInfo = OMNI_INJECTED_TAG
                }
            }
        };
        SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
    }

    public void InjectMouseButton(byte button, bool isDown)
    {
        uint flag = button == 2
            ? (isDown ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP)
            : (isDown ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP);
        var input = new INPUT { type = INPUT_MOUSE, U = new InputUnion { mi = new MOUSEINPUT { dwFlags = flag, dwExtraInfo = OMNI_INJECTED_TAG } } };
        SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
    }

    public void InjectMouseScroll(int dy, int dx)
    {
        if (dy != 0)
        {
            var input = new INPUT
            {
                type = INPUT_MOUSE,
                U = new InputUnion { mi = new MOUSEINPUT { dwFlags = MOUSEEVENTF_WHEEL, mouseData = unchecked((uint)(dy * 120)), dwExtraInfo = OMNI_INJECTED_TAG } }
            };
            SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
        }
        if (dx != 0)
        {
            var input = new INPUT
            {
                type = INPUT_MOUSE,
                U = new InputUnion { mi = new MOUSEINPUT { dwFlags = MOUSEEVENTF_HWHEEL, mouseData = unchecked((uint)(dx * 120)), dwExtraInfo = OMNI_INJECTED_TAG } }
            };
            SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
        }
    }

    public void InjectKeyEvent(ushort vk, bool isDown, uint mods)
    {
        if (vk == 0) return;
        if (isDown && (mods & 8) != 0 && vk != VK_LWIN && (GetAsyncKeyState(VK_LWIN) & 0x8000) == 0)
        {
            SendInput(1, new[] { KeyInput(VK_LWIN, false) }, Marshal.SizeOf<INPUT>());
        }
        var input = KeyInput(vk, !isDown);
        SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
    }

    public void ExecuteSemanticHotkey(string action)
    {
        bool isToggleableOverlay = action is "WIN_SCREENSHOT_REGION" or "WIN_SCREENSHOT_BAR" or "WIN_SEARCH" or "WIN_ALT_A";
        if (isToggleableOverlay && _lastTriggeredHotkey == action && (DateTime.UtcNow - _lastHotkeyTime).TotalSeconds < 6.0)
        {
            _lastTriggeredHotkey = "";
            var esc = new[] { KeyInput(0x1B, false), KeyInput(0x1B, true) };
            SendInput((uint)esc.Length, esc, Marshal.SizeOf<INPUT>());
            return;
        }

        if (isToggleableOverlay)
        {
            _lastTriggeredHotkey = action;
            _lastHotkeyTime = DateTime.UtcNow;
        }

        var clearMods = new[] { KeyInput(VK_CONTROL, true), KeyInput(VK_MENU, true), KeyInput(VK_SHIFT, true), KeyInput(VK_LWIN, true) };
        SendInput((uint)clearMods.Length, clearMods, Marshal.SizeOf<INPUT>());

        switch (action)
        {
            case "WIN_SCREENSHOT_REGION":
            case "WIN_SCREENSHOT_BAR":
                TriggerWindowsNativeScreenshot();
                break;
            case "WIN_X_MENU":
                SendCombo(VK_LWIN, 0x58);
                break;
            case "WIN_ALT_A":
                SendCombo(VK_MENU, 0x41);
                break;
            case "WIN_ALT_TAB":
                SendCombo(VK_MENU, 0x09);
                break;
            case "WIN_SEARCH":
                SendCombo(VK_LWIN, 0x53);
                break;
            case "WIN_CTRL_C": SendCombo(VK_CONTROL, 0x43); break;
            case "WIN_CTRL_V": SendCombo(VK_CONTROL, 0x56); break;
            case "WIN_CTRL_X": SendCombo(VK_CONTROL, 0x58); break;
            case "WIN_CTRL_A": SendCombo(VK_CONTROL, 0x41); break;
            case "WIN_CTRL_Z": SendCombo(VK_CONTROL, 0x5A); break;
            case "WIN_CTRL_S": SendCombo(VK_CONTROL, 0x53); break;
            case "WIN_CTRL_F": SendCombo(VK_CONTROL, 0x46); break;
        }
    }

    public void TriggerWindowsNativeScreenshot()
    {
        try
        {
            var inputs = new[]
            {
                KeyInput(VK_LWIN, false),
                KeyInput(VK_SHIFT, false),
                KeyInput(VK_S, false),
                KeyInput(VK_S, true),
                KeyInput(VK_SHIFT, true),
                KeyInput(VK_LWIN, true)
            };
            SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
        }
        catch { }
    }

    private static void SendCombo(ushort modVk, ushort keyVk)
    {
        var inputs = new[]
        {
            KeyInput(modVk, false),
            KeyInput(keyVk, false),
            KeyInput(keyVk, true),
            KeyInput(modVk, true)
        };
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    private static bool IsExtendedKey(ushort vk) =>
        vk is 0x5B or 0x5C or (>= 0x21 and <= 0x2E);

    private static INPUT KeyInput(ushort vk, bool keyUp)
    {
        uint flags = keyUp ? KEYEVENTF_KEYUP : 0u;
        if (IsExtendedKey(vk)) flags |= KEYEVENTF_EXTENDEDKEY;
        ushort scan = (ushort)MapVirtualKey(vk, 0);
        return new INPUT
        {
            type = INPUT_KEYBOARD,
            U = new InputUnion { ki = new KEYBDINPUT { wVk = vk, wScan = scan, dwFlags = flags, dwExtraInfo = OMNI_INJECTED_TAG } }
        };
    }

    private static readonly IntPtr OMNI_INJECTED_TAG = new(0x4F4D4E49);
    private const ushort VK_SHIFT = 0x10;
    private const ushort VK_CONTROL = 0x11;
    private const ushort VK_MENU = 0x12;
    private const ushort VK_LWIN = 0x5B;
    private const ushort VK_S = 0x53;

    private const uint INPUT_MOUSE = 0;
    private const uint INPUT_KEYBOARD = 1;
    private const uint MOUSEEVENTF_MOVE = 0x0001;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    private const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    private const uint MOUSEEVENTF_WHEEL = 0x0800;
    private const uint MOUSEEVENTF_HWHEEL = 0x01000;
    private const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;
    private const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
    private const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    private const uint KEYEVENTF_KEYUP = 0x0002;

    private const int SM_XVIRTUALSCREEN = 76;
    private const int SM_YVIRTUALSCREEN = 77;
    private const int SM_CXVIRTUALSCREEN = 78;
    private const int SM_CYVIRTUALSCREEN = 79;

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT { public uint type; public InputUnion U; }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HARDWAREINPUT
    {
        public uint uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }

    [DllImport("user32.dll")] private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT lpPoint);
    [DllImport("user32.dll")] private static extern int GetMessageTime();
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int nIndex);
    [DllImport("user32.dll")] private static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] private static extern uint MapVirtualKey(uint uCode, uint uMapType);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(POINT Point);
    [DllImport("user32.dll", SetLastError = true)] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("kernel32.dll", CharSet = CharSet.Auto)] private static extern IntPtr GetModuleHandle(string? lpModuleName);

    private delegate IntPtr LowLevelProc(int nCode, IntPtr wParam, IntPtr lParam);

    private const int WH_KEYBOARD_LL = 13;
    private const int WH_MOUSE_LL = 14;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;
    private const int WM_MOUSEMOVE = 0x0200;
    private const int WM_LBUTTONDOWN = 0x0201;
    private const int WM_LBUTTONUP = 0x0202;
    private const int WM_RBUTTONDOWN = 0x0204;
    private const int WM_RBUTTONUP = 0x0205;
    private const int WM_MOUSEWHEEL = 0x020A;
    private const int WM_MOUSEHWHEEL = 0x020E;
    private const uint LLKHF_INJECTED = 0x10;
    private const uint LLMHF_INJECTED = 0x01;

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int x; public int y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSLLHOOKSTRUCT
    {
        public POINT pt;
        public uint mouseData;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    private LowLevelProc? _mouseProc;
    private LowLevelProc? _kbdProc;
    private IntPtr _mouseHook = IntPtr.Zero;
    private IntPtr _kbdHook = IntPtr.Zero;
    private DateTime _lastEdgeSwitchTime = DateTime.MinValue;
    private DateTime _suppressEdgeCrossUntilUtc = DateTime.MinValue;
    private int _remoteMacMonIdx = 0;
    private double _remoteMacNormX = 0.5;
    private double _remoteMacNormY = 0.5;
    internal readonly WinCursorTransitionTracker _cursorTracker = new();
    private bool _hasPrevLocalPt = false;
    private int _prevLocalX = 0;
    private int _prevLocalY = 0;

    internal static class WinKvmStageTracer
    {
        private static readonly object _qLock = new();
        private static readonly Queue<string> _pending = new();
        private static bool _draining = false;
        private static long _seq = 0;

        public static long BeginCrossing(long nowTicks)
        {
            return Interlocked.Increment(ref _seq);
        }

        public static void Log(long seq, long t0Ticks, string detail, long? nowTicks = null, string? customLogPath = null, bool sync = false)
        {
            if (seq <= 0 || t0Ticks <= 0) return;
            long now = nowTicks ?? Stopwatch.GetTimestamp();
            double deltaMs = now >= t0Ticks ? (now - t0Ticks) * 1000.0 / Stopwatch.Frequency : 0.0;
            string line = $"[{DateTime.Now:HH:mm:ss.fff}] [KVM-Stage-Win seq=#{seq} +{deltaMs:F2}ms] {detail}{Environment.NewLine}";
            if (sync)
            {
                AppendLines(customLogPath ?? OmniFlowPaths.RuntimeLogPath, new[] { line });
                return;
            }
            bool kick = false;
            lock (_qLock)
            {
                _pending.Enqueue(line);
                if (!_draining)
                {
                    _draining = true;
                    kick = true;
                }
            }
            if (kick)
            {
                ThreadPool.QueueUserWorkItem(_ => Drain(customLogPath ?? OmniFlowPaths.RuntimeLogPath));
            }
        }

        private static void Drain(string path)
        {
            while (true)
            {
                List<string> batch;
                lock (_qLock)
                {
                    if (_pending.Count == 0)
                    {
                        _draining = false;
                        return;
                    }
                    batch = new List<string>(_pending.Count);
                    while (_pending.Count > 0) batch.Add(_pending.Dequeue());
                }
                AppendLines(path, batch);
            }
        }

        private static void AppendLines(string path, IEnumerable<string> lines)
        {
            try
            {
                string? dir = Path.GetDirectoryName(path);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                using var fs = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
                using var sw = new StreamWriter(fs, System.Text.Encoding.UTF8);
                foreach (var l in lines) sw.Write(l);
            }
            catch { }
        }
    }

    internal sealed class WinCursorTransitionTracker
    {
        private struct RawPacket
        {
            public int Dx;
            public int Dy;
            public uint MsgTimeMs;
            public long QpcTicks;
            public bool Consumed;
        }

        private readonly object _lock = new();
        private readonly RawPacket[] _localRing = new RawPacket[16];
        private int _ringWriteIdx;

        private bool _isRemote;
        private int _anchorX = -1;
        private int _anchorY = -1;
        private bool _waitingHookAnchor;
        private bool _awaitingPostCrossRaw;
        private uint _crossTimeMs;
        private long _stageSeq;
        private long _stageT0Ticks;
        private long _lastRawInputTicks;
        private long _lastCommittedLocalTicks;

        // Remaining physical movement spent reaching the Windows border during the crossing frame.
        // Deducted once from the delayed WM_INPUT crossing report so overshoot transfers without doubling.
        private int _crossCreditX;
        private int _crossCreditY;
        private long _crossCreditExpiryTicks;

        // Short-lived credit if WH_MOUSE_LL fallback ran before a sudden late WM_INPUT arrival.
        private int _fallbackHookCreditX;
        private int _fallbackHookCreditY;
        private long _fallbackHookCreditExpiryTicks;

        private int _loggedRawCount;
        private bool _loggedFirstHookPost;

        public int AnchorX { get { lock (_lock) return _anchorX; } }
        public int AnchorY { get { lock (_lock) return _anchorY; } }

        public bool IsRawInputActive(long nowTicks)
        {
            lock (_lock) return IsRawInputActiveLocked(nowTicks);
        }

        private bool IsRawInputActiveLocked(long nowTicks) =>
            _lastRawInputTicks != 0 && (nowTicks - _lastRawInputTicks) <= (long)(Stopwatch.Frequency * 300.0);

        public void CommitLocalMove(long nowTicks)
        {
            lock (_lock)
            {
                if (_isRemote) return;
                if (nowTicks > _lastCommittedLocalTicks)
                {
                    _lastCommittedLocalTicks = nowTicks;
                }
                for (int i = 0; i < _localRing.Length; i++)
                {
                    if (!_localRing[i].Consumed && _localRing[i].QpcTicks <= nowTicks)
                    {
                        _localRing[i].Consumed = true;
                    }
                }
            }
        }

        public void EnterRemote(
            int anchorX,
            int anchorY,
            int curX,
            int curY,
            int crossHookDx,
            int crossHookDy,
            uint crossTimeMs,
            long nowTicks,
            long stageSeq,
            out int preOvershootX,
            out int preOvershootY)
        {
            lock (_lock)
            {
                _isRemote = true;
                _anchorX = anchorX;
                _anchorY = anchorY;
                _waitingHookAnchor = (curX != anchorX || curY != anchorY);
                _awaitingPostCrossRaw = (crossTimeMs != 0);
                _crossTimeMs = crossTimeMs;
                _stageSeq = stageSeq;
                _stageT0Ticks = nowTicks;

                int creditX = Math.Clamp(crossHookDx, -450, 450);
                int creditY = Math.Clamp(crossHookDy, -450, 450);

                // Check whether WM_INPUT for this exact crossing swipe already ran in WndProc
                // after the last committed local WH_MOUSE_LL move and slightly ahead of crossing WH_MOUSE_LL;
                // if so, preserve its overshoot immediately and consume it.
                int matchedRawX = 0;
                int matchedRawY = 0;
                long freshCutoff = nowTicks - (long)(Stopwatch.Frequency * 0.016);
                if (_lastCommittedLocalTicks > freshCutoff)
                {
                    freshCutoff = _lastCommittedLocalTicks;
                }
                for (int i = 0; i < _localRing.Length; i++)
                {
                    if (!_localRing[i].Consumed &&
                        (_lastCommittedLocalTicks > 0 ? _localRing[i].QpcTicks > _lastCommittedLocalTicks : _localRing[i].QpcTicks >= freshCutoff) &&
                        unchecked((int)(_localRing[i].MsgTimeMs - crossTimeMs)) >= -16)
                    {
                        matchedRawX += _localRing[i].Dx;
                        matchedRawY += _localRing[i].Dy;
                        _localRing[i].Consumed = true;
                    }
                }

                if (matchedRawX != 0 || matchedRawY != 0)
                {
                    preOvershootX = ConsumeWithCredit(matchedRawX, ref creditX);
                    preOvershootY = ConsumeWithCredit(matchedRawY, ref creditY);
                    _awaitingPostCrossRaw = false;
                }
                else
                {
                    preOvershootX = 0;
                    preOvershootY = 0;
                }

                _crossCreditX = creditX;
                _crossCreditY = creditY;
                _crossCreditExpiryTicks = nowTicks + (long)(Stopwatch.Frequency * 0.045);

                _fallbackHookCreditX = 0;
                _fallbackHookCreditY = 0;
                _fallbackHookCreditExpiryTicks = 0;
                _loggedRawCount = 0;
                _loggedFirstHookPost = false;
            }
        }

        public void EnterRemote(int anchorX, int anchorY, int curX, int curY, uint crossTimeMs, long nowTicks)
        {
            EnterRemote(anchorX, anchorY, curX, curY, 0, 0, crossTimeMs, nowTicks, 0, out _, out _);
        }

        public void ExitRemote()
        {
            lock (_lock)
            {
                _isRemote = false;
                _waitingHookAnchor = false;
                _awaitingPostCrossRaw = false;
                _crossCreditX = 0;
                _crossCreditY = 0;
                _fallbackHookCreditX = 0;
                _fallbackHookCreditY = 0;
            }
        }

        public void StartRewarp(int anchorX, int anchorY, uint eventTimeMs, long nowTicks)
        {
            lock (_lock)
            {
                _anchorX = anchorX;
                _anchorY = anchorY;
                _waitingHookAnchor = true;
                _crossTimeMs = eventTimeMs;
            }
        }

        public (bool needsRewarp, int dx, int dy) ProcessHookMouseMove(
            int ptX,
            int ptY,
            uint eventTimeMs,
            long nowTicks,
            int monLeft = int.MinValue,
            int monTop = int.MinValue,
            int monRight = int.MaxValue,
            int monBottom = int.MaxValue)
        {
            long logSeq = 0;
            long logT0 = 0;
            string? logMsg = null;

            lock (_lock)
            {
                if (_anchorX < 0)
                {
                    _anchorX = ptX;
                    _anchorY = ptY;
                }

                if (_waitingHookAnchor)
                {
                    if (ptX == _anchorX && ptY == _anchorY)
                    {
                        _waitingHookAnchor = false;
                        if (!_loggedFirstHookPost && _stageSeq > 0)
                        {
                            _loggedFirstHookPost = true;
                            logSeq = _stageSeq;
                            logT0 = _stageT0Ticks;
                            logMsg = $"hookPostRelocate pt=({ptX},{ptY}) echo=true rawActive={IsRawInputActiveLocked(nowTicks)} tMsg={eventTimeMs}";
                        }
                        goto Done;
                    }

                    // Deskflow MSWindowsComputer::onMouseMove geometric bogus-jump guard:
                    // Ignore stale pre-warp events near the old crossing edge until cursor settles at center anchor.
                    int bogusHalfW = (monRight > monLeft && monRight < int.MaxValue && monLeft > int.MinValue)
                        ? Math.Max(120, ((monRight - monLeft) >> 1) - 10)
                        : 450;
                    int bogusHalfH = (monBottom > monTop && monBottom < int.MaxValue && monTop > int.MinValue)
                        ? Math.Max(120, ((monBottom - monTop) >> 1) - 10)
                        : 450;
                    bool isPreWarpJump = Math.Abs(ptX - _anchorX) >= bogusHalfW || Math.Abs(ptY - _anchorY) >= bogusHalfH;
                    if (isPreWarpJump)
                    {
                        if (!_loggedFirstHookPost && _stageSeq > 0)
                        {
                            _loggedFirstHookPost = true;
                            logSeq = _stageSeq;
                            logT0 = _stageT0Ticks;
                            logMsg = $"hookPostRelocate pt=({ptX},{ptY}) echo=false_preWarpBogus rawActive={IsRawInputActiveLocked(nowTicks)} tMsg={eventTimeMs}";
                        }
                        goto Done;
                    }

                    // Cursor is already near center anchor (OS coalesced warp echo with first small move).
                    _waitingHookAnchor = false;
                }

                if (!_loggedFirstHookPost && _stageSeq > 0)
                {
                    _loggedFirstHookPost = true;
                    logSeq = _stageSeq;
                    logT0 = _stageT0Ticks;
                    logMsg = $"hookPostRelocate pt=({ptX},{ptY}) echo=false rawActive={IsRawInputActiveLocked(nowTicks)} tMsg={eventTimeMs}";
                }

                // When hardware/PTP WM_INPUT RIM_TYPEMOUSE is active, let WM_INPUT deliver 100% of
                // unclamped relative deltas while WH_MOUSE_LL silently keeps the local cursor pinned at anchor.
                if (IsRawInputActiveLocked(nowTicks))
                {
                    return EmitLogAndReturn(logSeq, logT0, logMsg, nowTicks, (false, 0, 0));
                }

                // Fallback path ONLY when no WM_INPUT packets exist (e.g. RDP/synthetic pointer).
                int outDx = ptX - _anchorX;
                int outDy = ptY - _anchorY;
                if (Math.Abs(outDx) > 900 || Math.Abs(outDy) > 900)
                {
                    return EmitLogAndReturn(logSeq, logT0, logMsg, nowTicks, (true, 0, 0));
                }

                bool nearFallbackEdge = (monRight - monLeft > 260) &&
                    (ptX <= monLeft + 1 || ptX >= monRight - 2 || ptY <= monTop + 1 || ptY >= monBottom - 2);

                _fallbackHookCreditX += outDx;
                _fallbackHookCreditY += outDy;
                _fallbackHookCreditExpiryTicks = nowTicks + (long)(Stopwatch.Frequency * 0.004);
                return EmitLogAndReturn(logSeq, logT0, logMsg, nowTicks, (nearFallbackEdge, outDx, outDy));
            }

        Done:
            return EmitLogAndReturn(logSeq, logT0, logMsg, nowTicks, (false, 0, 0));
        }

        private static (bool needsRewarp, int dx, int dy) EmitLogAndReturn(
            long logSeq, long logT0, string? logMsg, long nowTicks, (bool needsRewarp, int dx, int dy) result)
        {
            if (logMsg != null) WinKvmStageTracer.Log(logSeq, logT0, logMsg, nowTicks);
            return result;
        }

        public (int dx, int dy) ProcessRawMouseInput(int lLastX, int lLastY, uint msgTimeMs, long nowTicks, IntPtr hDevice = default)
        {
            long logSeq = 0;
            long logT0 = 0;
            string? logMsg = null;
            int outDx = 0;
            int outDy = 0;

            lock (_lock)
            {
                _lastRawInputTicks = nowTicks;
                if (!_isRemote)
                {
                    _localRing[_ringWriteIdx] = new RawPacket
                    {
                        Dx = lLastX,
                        Dy = lLastY,
                        MsgTimeMs = msgTimeMs,
                        QpcTicks = nowTicks,
                        Consumed = false
                    };
                    _ringWriteIdx = (_ringWriteIdx + 1) % _localRing.Length;
                    return (0, 0);
                }

                if (nowTicks > _crossCreditExpiryTicks)
                {
                    _crossCreditX = 0;
                    _crossCreditY = 0;
                }
                if (nowTicks > _fallbackHookCreditExpiryTicks)
                {
                    _fallbackHookCreditX = 0;
                    _fallbackHookCreditY = 0;
                }

                // Ignore obviously stale packets emitted well before the edge crossing until post-cross stream starts.
                if (_awaitingPostCrossRaw && unchecked((int)(msgTimeMs - _crossTimeMs)) < -16)
                {
                    if (_stageSeq > 0 && _loggedRawCount < 3)
                    {
                        _loggedRawCount++;
                        logSeq = _stageSeq;
                        logT0 = _stageT0Ticks;
                        logMsg = $"rawInput #{_loggedRawCount} skipped=preCross raw=({lLastX},{lLastY}) tMsg={msgTimeMs} crossT={_crossTimeMs}";
                    }
                    goto Done;
                }
                _awaitingPostCrossRaw = false;

                int dx = lLastX;
                int dy = lLastY;
                if (_crossCreditX != 0 || _crossCreditY != 0)
                {
                    dx = ConsumeWithCredit(dx, ref _crossCreditX);
                    dy = ConsumeWithCredit(dy, ref _crossCreditY);
                }
                if (_fallbackHookCreditX != 0 || _fallbackHookCreditY != 0)
                {
                    dx = ConsumeWithCredit(dx, ref _fallbackHookCreditX);
                    dy = ConsumeWithCredit(dy, ref _fallbackHookCreditY);
                }

                outDx = dx;
                outDy = dy;

                if (_stageSeq > 0 && _loggedRawCount < 3)
                {
                    _loggedRawCount++;
                    logSeq = _stageSeq;
                    logT0 = _stageT0Ticks;
                    logMsg = $"rawInput #{_loggedRawCount} raw=({lLastX},{lLastY}) out=({outDx},{outDy}) remCross=({_crossCreditX},{_crossCreditY}) hDev=0x{hDevice.ToInt64():X} tMsg={msgTimeMs}";
                }
            }

        Done:
            if (logMsg != null) WinKvmStageTracer.Log(logSeq, logT0, logMsg, nowTicks);
            return (outDx, outDy);
        }

        private static int ConsumeWithCredit(int rawDelta, ref int credit)
        {
            if (rawDelta == 0) return 0;
            if (credit == 0) return rawDelta;
            if ((rawDelta > 0 && credit > 0) || (rawDelta < 0 && credit < 0))
            {
                if (Math.Abs(rawDelta) <= Math.Abs(credit))
                {
                    credit -= rawDelta;
                    return 0;
                }
                int remaining = rawDelta - credit;
                credit = 0;
                return remaining;
            }
            return rawDelta;
        }
    }
    private bool _leftButtonDown = false;
    private int _dragDownX, _dragDownY;
    private bool _externalDragCandidate = false;
    private bool _externalDragActive = false;
    private DateTime _lastDragProbeUtc = DateTime.MinValue;
    private static readonly uint _selfProcessId = (uint)Environment.ProcessId;
    public event Action<int, int>? ExternalDragMoved;
    public event Action? ExternalDragEnded;
    private bool _remoteLeftDown = false;
    private bool _remoteRightDown = false;
    private ushort _suppressedWinToMacVk = 0;

    private static bool IsPointOwnedBySelfProcess(POINT pt)
    {
        IntPtr hwnd = WindowFromPoint(pt);
        if (hwnd == IntPtr.Zero) return false;
        GetWindowThreadProcessId(hwnd, out uint pid);
        return pid == _selfProcessId;
    }

    private void InstallLowLevelHooks()
    {
        try
        {
            _mouseProc = MouseHookCallback;
            _kbdProc = KeyboardHookCallback;
            IntPtr hMod = GetModuleHandle(null);
            _mouseHook = SetWindowsHookEx(WH_MOUSE_LL, _mouseProc, hMod, 0);
            _kbdHook = SetWindowsHookEx(WH_KEYBOARD_LL, _kbdProc, hMod, 0);
            if (_mouseHook == IntPtr.Zero || _kbdHook == IntPtr.Zero)
            {
                LogMessage?.Invoke($"[KVM Warn] 底层键鼠钩子注册异常 (mouse={_mouseHook}, kbd={_kbdHook}, err={Marshal.GetLastWin32Error()})");
            }
        }
        catch (Exception ex)
        {
            LogMessage?.Invoke($"[KVM Warn] 底层键鼠钩子异常: {ex.Message}");
        }
    }

    private IntPtr MouseHookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && !_kvmShuttingDown)
        {
            var info = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam);
            int msg = wParam.ToInt32();
            bool isInjected = (info.flags & LLMHF_INJECTED) != 0;

            // Track external Explorer/Desktop file drags for BOTH hardware mouse AND Mac-injected mouse/trackpad.
            if (!RemoteFocusActive || !KvmEnabled)
            {
                if (msg == WM_LBUTTONDOWN)
                {
                    _leftButtonDown = true;
                    _dragDownX = info.pt.x;
                    _dragDownY = info.pt.y;
                    _externalDragCandidate = !IsDraggingOutFromShelf && !IsPointOwnedBySelfProcess(info.pt);
                    _externalDragActive = false;
                }
                else if (msg == WM_LBUTTONUP)
                {
                    if (_leftButtonDown || _externalDragActive)
                        _suppressEdgeCrossUntilUtc = DateTime.UtcNow.AddMilliseconds(500);
                    _leftButtonDown = false;
                    _externalDragCandidate = false;
                    if (_externalDragActive)
                    {
                        _externalDragActive = false;
                        _dispatcher.BeginInvoke(() => ExternalDragEnded?.Invoke());
                    }
                }
                else if (msg == WM_RBUTTONUP)
                {
                    _suppressEdgeCrossUntilUtc = DateTime.UtcNow.AddMilliseconds(350);
                }
                else if (msg == WM_MOUSEMOVE)
                {
                    if (_leftButtonDown && _externalDragCandidate)
                    {
                        if (!_externalDragActive &&
                            (Math.Abs(info.pt.x - _dragDownX) >= 5 || Math.Abs(info.pt.y - _dragDownY) >= 5))
                        {
                            _externalDragActive = true;
                            _lastDragProbeUtc = DateTime.UtcNow;
                            int px = info.pt.x, py = info.pt.y;
                            _dispatcher.BeginInvoke(() => ExternalDragMoved?.Invoke(px, py));
                        }
                        else if (_externalDragActive &&
                                 ((DateTime.UtcNow - _lastDragProbeUtc).TotalMilliseconds >= 12 || IsPointOwnedBySelfProcess(info.pt)))
                        {
                            _lastDragProbeUtc = DateTime.UtcNow;
                            int px = info.pt.x, py = info.pt.y;
                            _dispatcher.BeginInvoke(() => ExternalDragMoved?.Invoke(px, py));
                        }
                    }

                    // Strict safety rule: never switch focus on injected events, while dragging, or right after drop.
                    if (!isInjected &&
                        KvmEnabled &&
                        !_leftButtonDown &&
                        !_externalDragActive &&
                        (GetAsyncKeyState(0x01) & 0x8000) == 0 &&
                        (GetAsyncKeyState(0x02) & 0x8000) == 0 &&
                        DateTime.UtcNow >= _suppressEdgeCrossUntilUtc &&
                        EdgeSwitchEnabled &&
                        ControlMode != KvmControlMode.MacMasterOnly &&
                        Transport.ActiveLinksSnapshot().Count > 0 &&
                        (DateTime.UtcNow - _lastEdgeSwitchTime).TotalMilliseconds > 250)
                    {
                        var cross = Detect2DEdgeToMac(info.pt.x, info.pt.y, tolerance: 3);
                        if (cross.HasValue)
                        {
                            var crossMon = FindMonitorForPoint(info.pt.x, info.pt.y);
                            int edgeX = crossMon != null
                                ? Math.Clamp(info.pt.x, crossMon.BoundsX, crossMon.BoundsX + Math.Max(1, crossMon.WidthPx) - 1)
                                : info.pt.x;
                            int edgeY = crossMon != null
                                ? Math.Clamp(info.pt.y, crossMon.BoundsY, crossMon.BoundsY + Math.Max(1, crossMon.HeightPx) - 1)
                                : info.pt.y;
                            int hookDx = _hasPrevLocalPt ? (edgeX - _prevLocalX) : 0;
                            int hookDy = _hasPrevLocalPt ? (edgeY - _prevLocalY) : 0;
                            if (Math.Abs(hookDx) > 450 || Math.Abs(hookDy) > 450)
                            {
                                hookDx = 0;
                                hookDy = 0;
                            }
                            _hasPrevLocalPt = false;
                            _lastEdgeSwitchTime = DateTime.UtcNow;
                            _remoteMacMonIdx = cross.Value.macMonIdx;
                            _remoteMacNormX = cross.Value.normX;
                            _remoteMacNormY = cross.Value.normY;
                            SetRemoteFocus(
                                true,
                                broadcastToPeer: true,
                                _remoteMacNormX,
                                _remoteMacNormY,
                                crossTimeMs: info.time,
                                crossHookDx: hookDx,
                                crossHookDy: hookDy,
                                crossEdgeLabel: "edge2D",
                                crossCurX: edgeX,
                                crossCurY: edgeY);
                            return (IntPtr)1;
                        }
                    }

                    if (!isInjected)
                    {
                        _prevLocalX = info.pt.x;
                        _prevLocalY = info.pt.y;
                        _hasPrevLocalPt = true;
                        _cursorTracker.CommitLocalMove(Stopwatch.GetTimestamp());
                    }
                }
            }
            else if (!isInjected)
            {
                    if (Transport.ActiveLinksSnapshot().Count == 0)
                    {
                        _dispatcher.BeginInvoke(() => SetRemoteFocus(false, broadcastToPeer: false));
                    }
                    else
                    {
                        switch (msg)
                        {
                            case WM_MOUSEMOVE:
                                if (_tpThreeFingerDragging || (_tpFingerCount == 3 && IsHotkeyRuleEnabled("win_tp_3f_drag"))) return (IntPtr)1;
                                var lm = FindMonitorForPoint(_cursorTracker.AnchorX, _cursorTracker.AnchorY);
                                int mL = lm?.BoundsX ?? int.MinValue;
                                int mT = lm?.BoundsY ?? int.MinValue;
                                int mR = lm != null ? lm.BoundsX + lm.WidthPx : int.MaxValue;
                                int mB = lm != null ? lm.BoundsY + lm.HeightPx : int.MaxValue;
                                var step = _cursorTracker.ProcessHookMouseMove(info.pt.x, info.pt.y, info.time, Stopwatch.GetTimestamp(), mL, mT, mR, mB);
                                if (step.needsRewarp)
                                {
                                    var (centerAx, centerAy) = GetPrimaryCursorCenter();
                                    _cursorTracker.StartRewarp(centerAx, centerAy, info.time, Stopwatch.GetTimestamp());
                                    SetCursorPos(centerAx, centerAy);
                                    return (IntPtr)1;
                                }
                                if (step.dx != 0 || step.dy != 0)
                                {
                                    ApplyRemoteMouseDelta(step.dx, step.dy);
                                }
                                return (IntPtr)1;
                            case WM_LBUTTONDOWN:
                            case WM_LBUTTONUP:
                                _remoteLeftDown = (msg == WM_LBUTTONDOWN);
                                Transport.SendControlFrame(DeskflowMsgType.MouseButton, new byte[] { 1, (byte)(msg == WM_LBUTTONDOWN ? 1 : 0) });
                                return (IntPtr)1;
                            case WM_RBUTTONDOWN:
                            case WM_RBUTTONUP:
                                _remoteRightDown = (msg == WM_RBUTTONDOWN);
                                Transport.SendControlFrame(DeskflowMsgType.MouseButton, new byte[] { 2, (byte)(msg == WM_RBUTTONDOWN ? 1 : 0) });
                                return (IntPtr)1;
                            case WM_MOUSEWHEEL:
                                {
                                    int delta = (short)((info.mouseData >> 16) & 0xFFFF);
                                    byte[] sb = new byte[8];
                                    int dyW = delta / 12;
                                    sb[0] = (byte)((dyW >> 24) & 0xFF); sb[1] = (byte)((dyW >> 16) & 0xFF);
                                    sb[2] = (byte)((dyW >> 8) & 0xFF); sb[3] = (byte)(dyW & 0xFF);
                                    Transport.SendControlFrame(DeskflowMsgType.MouseScroll, sb);
                                    return (IntPtr)1;
                                }
                            case WM_MOUSEHWHEEL:
                                {
                                    int delta = (short)((info.mouseData >> 16) & 0xFFFF);
                                    byte[] sb = new byte[8];
                                    int dxW = delta / 12;
                                    sb[4] = (byte)((dxW >> 24) & 0xFF); sb[5] = (byte)((dxW >> 16) & 0xFF);
                                    sb[6] = (byte)((dxW >> 8) & 0xFF); sb[7] = (byte)(dxW & 0xFF);
                                    Transport.SendControlFrame(DeskflowMsgType.MouseScroll, sb);
                                    return (IntPtr)1;
                                }
                        }
                    }
                }
        }
        return CallNextHookEx(_mouseHook, nCode, wParam, lParam);
    }

    private static string[] TryGetExplorerSelectedFiles()
    {
        try
        {
            Type? shellType = Type.GetTypeFromProgID("Shell.Application");
            if (shellType == null) return Array.Empty<string>();
            dynamic? shell = Activator.CreateInstance(shellType);
            if (shell == null) return Array.Empty<string>();
            var list = new List<string>();
            foreach (dynamic win in shell.Windows())
            {
                try
                {
                    dynamic? doc = win.Document;
                    if (doc == null) continue;
                    dynamic? items = doc.SelectedItems();
                    if (items == null) continue;
                    foreach (dynamic item in items)
                    {
                        string? p = item.Path as string;
                        if (!string.IsNullOrEmpty(p) && (File.Exists(p) || Directory.Exists(p)))
                            list.Add(p);
                    }
                    if (list.Count > 0) break;
                }
                catch { }
            }
            return list.ToArray();
        }
        catch
        {
            return Array.Empty<string>();
        }
    }

    private IntPtr KeyboardHookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && KvmEnabled && !_kvmShuttingDown)
        {
            var info = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
            if ((info.flags & LLKHF_INJECTED) == 0)
            {
                int msg = wParam.ToInt32();
                bool isDown = (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN);
                bool ctrl = (GetAsyncKeyState(0x11) & 0x8000) != 0;
                bool alt = (GetAsyncKeyState(0x12) & 0x8000) != 0;

                if (isDown && HotkeySwitchEnabled && ctrl && alt)
                {
                    if (info.vkCode == 0x53)
                    {
                        _dispatcher.BeginInvoke(() => ToggleManualFocusSwitch());
                        return (IntPtr)1;
                    }
                    if (info.vkCode == 0x1B && RemoteFocusActive)
                    {
                        _dispatcher.BeginInvoke(() => SetRemoteFocus(false, broadcastToPeer: true));
                        return (IntPtr)1;
                    }
                }

                if (RemoteFocusActive && Transport.ActiveLinksSnapshot().Count > 0)
                {
                    ushort vk = (ushort)info.vkCode;
                    if (!isDown && _suppressedWinToMacVk != 0 && _suppressedWinToMacVk == vk)
                    {
                        _suppressedWinToMacVk = 0;
                        return (IntPtr)1;
                    }

                    bool shift = (GetAsyncKeyState(0x10) & 0x8000) != 0;
                    bool win = ((GetAsyncKeyState(0x5B) & 0x8000) != 0) || ((GetAsyncKeyState(0x5C) & 0x8000) != 0);
                    if (isDown && MatchWinToMacSemanticHotkey(vk, shift, ctrl, alt, win) is string action)
                    {
                        _suppressedWinToMacVk = vk;
                        ReleaseRemoteModifiersOnMac();
                        Transport.SendControlJson(DeskflowMsgType.SemanticHotkey, new WireSemanticHotkeyPayload { Action = action });
                        LogMessage?.Invoke($"[Hotkey] Windows 快捷键已触发 Mac: {action}");
                        return (IntPtr)1;
                    }

                    uint mods = (shift ? 1u : 0u) | (ctrl ? 2u : 0u) | (alt ? 4u : 0u) | (win ? 8u : 0u);
                    byte[] kb = new byte[7];
                    kb[0] = (byte)(vk >> 8); kb[1] = (byte)(vk & 0xFF);
                    kb[2] = (byte)(isDown ? 1 : 0);
                    kb[3] = (byte)((mods >> 24) & 0xFF); kb[4] = (byte)((mods >> 16) & 0xFF);
                    kb[5] = (byte)((mods >> 8) & 0xFF); kb[6] = (byte)(mods & 0xFF);
                    Transport.SendControlFrame(DeskflowMsgType.KeyEvent, kb);
                    return (IntPtr)1;
                }
            }
        }
        return CallNextHookEx(_kbdHook, nCode, wParam, lParam);
    }

    private void ReleaseRemoteModifiersOnMac()
    {
        foreach (ushort mvk in new ushort[] { 0x10, 0x11, 0x12, 0x5B })
        {
            byte[] kb = { (byte)(mvk >> 8), (byte)(mvk & 0xFF), 0, 0, 0, 0, 0 };
            Transport.SendControlFrame(DeskflowMsgType.KeyEvent, kb);
        }
    }

    private string? MatchWinToMacSemanticHotkey(ushort vk, bool shift, bool ctrl, bool alt, bool win)
    {
        bool IsEnabled(string id) => HotkeyRules.Any(r => r.Id == id && r.Enabled);

        if (vk == 0x2C && IsEnabled("win_to_mac_prtsc"))
            return "MAC_SCREENSHOT_REGION";
        if (vk == 0x53 && win && shift && !ctrl && !alt && IsEnabled("win_to_mac_snip"))
            return "MAC_SCREENSHOT_REGION";
        if (vk == 0x09 && alt && !ctrl && !win && IsEnabled("win_to_mac_alttab"))
            return "MAC_CMD_TAB";
        if (vk == 0x53 && win && !shift && !ctrl && !alt && IsEnabled("win_to_mac_search"))
            return "MAC_SPOTLIGHT";
        if (ctrl && !win && !alt && !shift && IsEnabled("win_to_mac_clip"))
        {
            return vk switch
            {
                0x43 => "MAC_CMD_C",
                0x56 => "MAC_CMD_V",
                0x58 => "MAC_CMD_X",
                0x41 => "MAC_CMD_A",
                0x5A => "MAC_CMD_Z",
                0x53 => "MAC_CMD_S",
                0x46 => "MAC_CMD_F",
                _ => null
            };
        }
        return null;
    }

    private void ApplyRemoteMouseDelta(double dx, double dy)
    {
        var (refW, refH) = GetActiveMacRefSize();
        _remoteMacNormX += dx / refW;
        _remoteMacNormY += dy / refH;

        if (EdgeSwitchEnabled &&
            !_remoteLeftDown &&
            !_remoteRightDown &&
            !_tpThreeFingerDragging &&
            (GetAsyncKeyState(0x01) & 0x8000) == 0 &&
            (GetAsyncKeyState(0x02) & 0x8000) == 0 &&
            DateTime.UtcNow >= _suppressEdgeCrossUntilUtc &&
            (DateTime.UtcNow - _lastEdgeSwitchTime).TotalMilliseconds > 280)
        {
            var back = DetectReturnCrossingToWindows(_remoteMacNormX, _remoteMacNormY, dx, dy);
            if (back.HasValue)
            {
                _lastEdgeSwitchTime = DateTime.UtcNow;
                var b = back.Value;
                SetRemoteFocus(false, broadcastToPeer: true, b.normX, b.normY);
                InjectMouseMoveAbs(b.winMonIdx, b.normX, b.normY);
                return;
            }
        }

        _remoteMacNormX = Math.Clamp(_remoteMacNormX, 0.0, 1.0);
        _remoteMacNormY = Math.Clamp(_remoteMacNormY, 0.0, 1.0);
        SendRemoteMouseMove(_remoteMacMonIdx, _remoteMacNormX, _remoteMacNormY);
    }

    private static byte[] BuildRemoteMouseMovePayload(int monIdx, double nx, double ny)
    {
        byte[] mb = new byte[10];
        mb[0] = (byte)((monIdx >> 8) & 0xFF); mb[1] = (byte)(monIdx & 0xFF);
        int bx = BitConverter.SingleToInt32Bits((float)nx);
        int by = BitConverter.SingleToInt32Bits((float)ny);
        mb[2] = (byte)((bx >> 24) & 0xFF); mb[3] = (byte)((bx >> 16) & 0xFF);
        mb[4] = (byte)((bx >> 8) & 0xFF); mb[5] = (byte)(bx & 0xFF);
        mb[6] = (byte)((by >> 24) & 0xFF); mb[7] = (byte)((by >> 16) & 0xFF);
        mb[8] = (byte)((by >> 8) & 0xFF); mb[9] = (byte)(by & 0xFF);
        return mb;
    }

    private void SendRemoteMouseMove(int monIdx, double nx, double ny) =>
        Transport.SendMouseMoveCoalesced(BuildRemoteMouseMovePayload(monIdx, nx, ny));

    private (int winMonIdx, double normX, double normY)? DetectReturnCrossingToWindows(double normX, double normY, double dx, double dy)
    {
        var macNodes = Monitors.Where(m => m.OsKind == "macOS").ToList();
        var winNodes = Monitors.Where(m => m.OsKind == "Windows").ToList();
        if (macNodes.Count == 0 || winNodes.Count == 0) return null;

        var activeMac = macNodes.FirstOrDefault(m => Math.Max(0, m.DisplayIndex - 1) == _remoteMacMonIdx) ?? macNodes[0];
        double cx = activeMac.CanvasX + Math.Clamp(normX, 0.0, 1.0) * activeMac.AspectWidth;
        double cy = activeMac.CanvasY + Math.Clamp(normY, 0.0, 1.0) * activeMac.AspectHeight;
        static double Overlap(double a1, double a2, double b1, double b2) => Math.Max(0, Math.Min(a2, b2) - Math.Max(a1, b1));

        if (normX <= 0.0 && dx < 0)
        {
            var t = winNodes.Where(w => Math.Abs((w.CanvasX + w.AspectWidth) - activeMac.CanvasX) <= 36 && Overlap(activeMac.CanvasY, activeMac.CanvasY + activeMac.AspectHeight, w.CanvasY, w.CanvasY + w.AspectHeight) > 12)
                            .Where(w => cy >= w.CanvasY - 8 && cy <= w.CanvasY + w.AspectHeight + 8)
                            .OrderBy(w => Math.Abs((w.CanvasX + w.AspectWidth) - activeMac.CanvasX)).FirstOrDefault();
            if (t != null) return (Math.Max(0, t.DisplayIndex - 1), 0.97, Math.Clamp((cy - t.CanvasY) / Math.Max(1, t.AspectHeight), 0.03, 0.97));
        }
        if (normX >= 1.0 && dx > 0)
        {
            var t = winNodes.Where(w => Math.Abs(w.CanvasX - (activeMac.CanvasX + activeMac.AspectWidth)) <= 36 && Overlap(activeMac.CanvasY, activeMac.CanvasY + activeMac.AspectHeight, w.CanvasY, w.CanvasY + w.AspectHeight) > 12)
                            .Where(w => cy >= w.CanvasY - 8 && cy <= w.CanvasY + w.AspectHeight + 8)
                            .OrderBy(w => Math.Abs(w.CanvasX - (activeMac.CanvasX + activeMac.AspectWidth))).FirstOrDefault();
            if (t != null) return (Math.Max(0, t.DisplayIndex - 1), 0.03, Math.Clamp((cy - t.CanvasY) / Math.Max(1, t.AspectHeight), 0.03, 0.97));
        }
        if (normY <= 0.0 && dy < 0)
        {
            var t = winNodes.Where(w => Math.Abs((w.CanvasY + w.AspectHeight) - activeMac.CanvasY) <= 36 && Overlap(activeMac.CanvasX, activeMac.CanvasX + activeMac.AspectWidth, w.CanvasX, w.CanvasX + w.AspectWidth) > 12)
                            .Where(w => cx >= w.CanvasX - 8 && cx <= w.CanvasX + w.AspectWidth + 8)
                            .OrderBy(w => Math.Abs((w.CanvasY + w.AspectHeight) - activeMac.CanvasY)).FirstOrDefault();
            if (t != null) return (Math.Max(0, t.DisplayIndex - 1), Math.Clamp((cx - t.CanvasX) / Math.Max(1, t.AspectWidth), 0.03, 0.97), 0.97);
        }
        if (normY >= 1.0 && dy > 0)
        {
            var t = winNodes.Where(w => Math.Abs(w.CanvasY - (activeMac.CanvasY + activeMac.AspectHeight)) <= 36 && Overlap(activeMac.CanvasX, activeMac.CanvasX + activeMac.AspectWidth, w.CanvasX, w.CanvasX + w.AspectWidth) > 12)
                            .Where(w => cx >= w.CanvasX - 8 && cx <= w.CanvasX + w.AspectWidth + 8)
                            .OrderBy(w => Math.Abs(w.CanvasY - (activeMac.CanvasY + activeMac.AspectHeight))).FirstOrDefault();
            if (t != null) return (Math.Max(0, t.DisplayIndex - 1), Math.Clamp((cx - t.CanvasX) / Math.Max(1, t.AspectWidth), 0.03, 0.97), 0.03);
        }
        return null;
    }

    private void EvaluateEdgeDragHoverPrompt()
    {
        var files = TryGetExplorerSelectedFiles();
        if (files.Length == 0)
        {
            HoverIsLargeFile = false;
            HoverPromptTitle = "松手穿屏发送至 Mac";
            HoverPromptDetail = "移开则取消，不会发起传输";
            Phase = PortalTransferPhase.HoverExpand;
            StateUpdated?.Invoke();
            return;
        }
        string path = files[0];
        bool isDir = Directory.Exists(path);
        string fname = isDir ? Path.GetFileName(path) + ".zip" : Path.GetFileName(path);
        HoverPromptTitle = fname;
        HoverPromptDetail = "检测文件体积中...";
        HoverIsLargeFile = false;
        Phase = PortalTransferPhase.HoverExpand;
        StateUpdated?.Invoke();

        _ = Task.Run(() =>
        {
            ulong bytes = 0;
            try
            {
                if (File.Exists(path)) bytes = (ulong)new FileInfo(path).Length;
                else if (isDir)
                {
                    int cap = 0;
                    foreach (var f in Directory.EnumerateFiles(path, "*", SearchOption.AllDirectories))
                    {
                        try { bytes += (ulong)new FileInfo(f).Length; } catch { }
                        if (++cap > 3000) break;
                    }
                    bytes = Math.Max(1024 * 1024, bytes);
                }
            }
            catch { bytes = 1024 * 1024; }

            double mb = bytes / (1024.0 * 1024.0);
            double estSec = mb / Math.Max(45.0, EffectiveTransferMbps / 8.0);
            bool isLarge = estSec > 1.0 || bytes > 90UL * 1024 * 1024;
            string sz = DeskflowTransport.FormatBytes(bytes);

            _dispatcher.BeginInvoke(() =>
            {
                if (Phase != PortalTransferPhase.HoverExpand) return;
                HoverIsLargeFile = isLarge;
                HoverPromptTitle = isLarge ? $"文件较大 ({sz} · 约 {Math.Ceiling(Math.Max(1, estSec))} 秒)" : $"准备发送（{sz}）";
                HoverPromptDetail = isLarge ? "松手发送到 Mac · 移开取消" : "松手发送到 Mac · 移开取消";
                StateUpdated?.Invoke();
            });
        });
    }

    private (int macMonIdx, double normX, double normY)? Detect2DEdgeToMac(int px, int py, int tolerance = 5)
    {
        if (_localMonitors.Count == 0) _localMonitors = DeskflowTransport.EnumerateRealWindowsMonitors();
        int wIdx = _localMonitors.FindIndex(m => px >= m.BoundsX - 6 && px <= m.BoundsX + m.WidthPx + 6 && py >= m.BoundsY - 6 && py <= m.BoundsY + m.HeightPx + 6);
        if (wIdx < 0) wIdx = 0;
        if (wIdx >= _localMonitors.Count) return null;

        var lm = _localMonitors[wIdx];
        bool atLeft = px <= lm.BoundsX + tolerance;
        bool atRight = px >= lm.BoundsX + lm.WidthPx - tolerance;
        bool atTop = py <= lm.BoundsY + tolerance;
        bool atBottom = py >= lm.BoundsY + lm.HeightPx - tolerance;
        if (!atLeft && !atRight && !atTop && !atBottom) return null;

        var winNode = Monitors.FirstOrDefault(m => m.OsKind == "Windows" && m.DisplayIndex == lm.DisplayIndex);
        if (winNode == null) return null;
        var macNodes = Monitors.Where(m => m.OsKind == "macOS").ToList();
        if (macNodes.Count == 0) return null;

        static double Overlap(double a1, double a2, double b1, double b2) => Math.Max(0, Math.Min(a2, b2) - Math.Max(a1, b1));
        double nx = Math.Clamp((double)(px - lm.BoundsX) / Math.Max(1, lm.WidthPx), 0.03, 0.97);
        double ny = Math.Clamp((double)(py - lm.BoundsY) / Math.Max(1, lm.HeightPx), 0.03, 0.97);
        double wl = winNode.CanvasX, wr = wl + winNode.AspectWidth, wt = winNode.CanvasY, wb = wt + winNode.AspectHeight;
        double canvasX = wl + nx * winNode.AspectWidth;
        double canvasY = wt + ny * winNode.AspectHeight;

        if (atLeft)
        {
            var t = macNodes.Where(m => Math.Abs((m.CanvasX + m.AspectWidth) - wl) <= 36 && Overlap(wt, wb, m.CanvasY, m.CanvasY + m.AspectHeight) > 12)
                            .Where(m => canvasY >= m.CanvasY - 8 && canvasY <= m.CanvasY + m.AspectHeight + 8)
                            .OrderBy(m => Math.Abs(wl - (m.CanvasX + m.AspectWidth))).FirstOrDefault();
            if (t != null) return (Math.Max(0, t.DisplayIndex - 1), 0.992, Math.Clamp((canvasY - t.CanvasY) / Math.Max(1, t.AspectHeight), 0.01, 0.99));
        }
        if (atRight)
        {
            var t = macNodes.Where(m => Math.Abs(m.CanvasX - wr) <= 36 && Overlap(wt, wb, m.CanvasY, m.CanvasY + m.AspectHeight) > 12)
                            .Where(m => canvasY >= m.CanvasY - 8 && canvasY <= m.CanvasY + m.AspectHeight + 8)
                            .OrderBy(m => Math.Abs(m.CanvasX - wr)).FirstOrDefault();
            if (t != null) return (Math.Max(0, t.DisplayIndex - 1), 0.008, Math.Clamp((canvasY - t.CanvasY) / Math.Max(1, t.AspectHeight), 0.01, 0.99));
        }
        if (atTop)
        {
            var t = macNodes.Where(m => Math.Abs((m.CanvasY + m.AspectHeight) - wt) <= 36 && Overlap(wl, wr, m.CanvasX, m.CanvasX + m.AspectWidth) > 12)
                            .Where(m => canvasX >= m.CanvasX - 8 && canvasX <= m.CanvasX + m.AspectWidth + 8)
                            .OrderBy(m => Math.Abs(wt - (m.CanvasY + m.AspectHeight))).FirstOrDefault();
            if (t != null) return (Math.Max(0, t.DisplayIndex - 1), Math.Clamp((canvasX - t.CanvasX) / Math.Max(1, t.AspectWidth), 0.01, 0.99), 0.992);
        }
        if (atBottom)
        {
            var t = macNodes.Where(m => Math.Abs(m.CanvasY - wb) <= 36 && Overlap(wl, wr, m.CanvasX, m.CanvasX + m.AspectWidth) > 12)
                            .Where(m => canvasX >= m.CanvasX - 8 && canvasX <= m.CanvasX + m.AspectWidth + 8)
                            .OrderBy(m => Math.Abs(m.CanvasY - wb)).FirstOrDefault();
            if (t != null) return (Math.Max(0, t.DisplayIndex - 1), Math.Clamp((canvasX - t.CanvasX) / Math.Max(1, t.AspectWidth), 0.01, 0.99), 0.008);
        }
        return null;
    }

    // MARK: - Windows Precision Touchpad HID Raw Input (Win -> Mac Gestures)

    private bool _ptpRawRegistered = false;
    private readonly Dictionary<IntPtr, PtpDeviceSchema> _ptpDeviceCache = new();
    private int _tpFingerCount = 0;
    private bool _tpThreeFingerDragging = false;
    private bool _tpHasStart = false;
    private bool _tpHasPrev = false;
    private bool _tpHasFilteredDelta = false;
    private double _tpStartX, _tpStartY;
    private double _tpPrevX, _tpPrevY;
    private double _tpFiltDx, _tpFiltDy;
    private double _tpPendingDx, _tpPendingDy;
    private long _tpThreeFingerEnterTicksMs = 0;
    private long _tpLastDragMoveTicksMs = 0;

    private bool IsHotkeyRuleEnabled(string id) => HotkeyRules.Any(r => r.Id == id && r.Enabled);

    public void EnsureTouchpadRawInputRegistered(IntPtr hwnd)
    {
        if (_ptpRawRegistered || hwnd == IntPtr.Zero) return;
        var rid = new[]
        {
            new RAWINPUTDEVICE
            {
                usUsagePage = 0x0D, // HID_USAGE_PAGE_DIGITIZER
                usUsage = 0x05,     // HID_USAGE_DIGITIZER_TOUCH_PAD
                dwFlags = 0x00000100, // RIDEV_INPUTSINK
                hwndTarget = hwnd
            },
            new RAWINPUTDEVICE
            {
                usUsagePage = 0x01, // HID_USAGE_PAGE_GENERIC
                usUsage = 0x02,     // HID_USAGE_GENERIC_MOUSE
                dwFlags = 0x00000100, // RIDEV_INPUTSINK
                hwndTarget = hwnd
            }
        };
        if (RegisterRawInputDevices(rid, (uint)rid.Length, (uint)Marshal.SizeOf<RAWINPUTDEVICE>()))
        {
            _ptpRawRegistered = true;
            LogMessage?.Invoke("[手势] Windows 精确触控板及鼠标 Raw Input HID 监听已就绪 (Win → Mac)");
        }
    }

    public void HandleTouchpadRawInput(IntPtr hRawInput)
    {
        if (!KvmEnabled || _kvmShuttingDown) return;

        uint size = 0;
        uint hdrSize = (uint)Marshal.SizeOf<RAWINPUTHEADER>();
        if (GetRawInputData(hRawInput, RID_INPUT, IntPtr.Zero, ref size, hdrSize) != 0 || size < hdrSize + 8)
            return;

        IntPtr buf = Marshal.AllocHGlobal((int)size);
        try
        {
            if (GetRawInputData(hRawInput, RID_INPUT, buf, ref size, hdrSize) != size) return;
            var hdr = Marshal.PtrToStructure<RAWINPUTHEADER>(buf);
            if (hdr.dwType == RIM_TYPEMOUSE)
            {
                if (size >= hdrSize + (uint)Marshal.SizeOf<RAWMOUSE>())
                {
                    var rm = Marshal.PtrToStructure<RAWMOUSE>(buf + (int)hdrSize);
                    if ((rm.usFlags & MOUSE_MOVE_ABSOLUTE) == 0 &&
                        rm.ulExtraInformation != (uint)OMNI_INJECTED_TAG.ToInt64() &&
                        (rm.lLastX != 0 || rm.lLastY != 0))
                    {
                        uint msgTime = unchecked((uint)GetMessageTime());
                        var rawStep = _cursorTracker.ProcessRawMouseInput(rm.lLastX, rm.lLastY, msgTime, Stopwatch.GetTimestamp(), hdr.hDevice);
                        if (RemoteFocusActive &&
                            Transport.ActiveLinksSnapshot().Count > 0 &&
                            (rawStep.dx != 0 || rawStep.dy != 0))
                        {
                            ApplyRemoteMouseDelta(rawStep.dx, rawStep.dy);
                        }
                    }
                }
                return;
            }

            if (!RemoteFocusActive || Transport.ActiveLinksSnapshot().Count == 0)
            {
                if (_tpThreeFingerDragging)
                {
                    _tpThreeFingerDragging = false;
                    Transport.SendControlFrame(DeskflowMsgType.MouseButton, new byte[] { 1, 0 });
                }
                _tpFingerCount = 0;
                _tpHasStart = false;
                _tpHasPrev = false;
                return;
            }

            if (hdr.dwType != RIM_TYPEHID) return;

            var schema = GetOrLoadPtpSchema(hdr.hDevice);
            if (schema == null || schema.Slots.Count == 0) return;

            int dwSizeHid = Marshal.ReadInt32(buf, (int)hdrSize);
            int dwCount = Marshal.ReadInt32(buf, (int)hdrSize + 4);
            if (dwSizeHid <= 0 || dwCount <= 0) return;

            byte[] report = new byte[dwSizeHid];
            for (int r = 0; r < dwCount; r++)
            {
                int offset = (int)hdrSize + 8 + r * dwSizeHid;
                if (offset + dwSizeHid > size) break;
                Marshal.Copy(buf + offset, report, 0, dwSizeHid);
                ParsePtpReportAndDispatch(schema, report);
            }
        }
        finally
        {
            Marshal.FreeHGlobal(buf);
        }
    }

    private PtpDeviceSchema? GetOrLoadPtpSchema(IntPtr hDevice)
    {
        if (hDevice == IntPtr.Zero) return null;
        if (_ptpDeviceCache.TryGetValue(hDevice, out var cached)) return cached;

        uint ppSize = 0;
        if (GetRawInputDeviceInfo(hDevice, RIDI_PREPARSEDDATA, IntPtr.Zero, ref ppSize) == unchecked((uint)-1) || ppSize == 0)
            return null;

        IntPtr preparsed = Marshal.AllocHGlobal((int)ppSize);
        try
        {
            if (GetRawInputDeviceInfo(hDevice, RIDI_PREPARSEDDATA, preparsed, ref ppSize) == unchecked((uint)-1))
            {
                Marshal.FreeHGlobal(preparsed);
                return null;
            }
            if (HidP_GetCaps(preparsed, out var caps) != HIDP_STATUS_SUCCESS)
            {
                Marshal.FreeHGlobal(preparsed);
                return null;
            }
            if (caps.UsagePage != 0x0D || caps.Usage != 0x05)
            {
                Marshal.FreeHGlobal(preparsed);
                return null;
            }

            ushort vCapCount = caps.NumberInputValueCaps;
            var vCaps = new HIDP_VALUE_CAPS[Math.Max(1, (int)vCapCount)];
            if (vCapCount > 0)
            {
                HidP_GetValueCaps(0, vCaps, ref vCapCount, preparsed);
            }

            uint lcCount = caps.NumberLinkCollectionNodes;
            var lcs = new HIDP_LINK_COLLECTION_NODE[Math.Max(1, (int)lcCount)];
            if (lcCount > 0)
            {
                HidP_GetLinkCollectionNodes(lcs, ref lcCount, preparsed);
            }

            var fingerColls = new List<ushort>();
            for (int i = 0; i < lcCount; i++)
            {
                if (lcs[i].LinkUsagePage == 0x0D && lcs[i].LinkUsage == 0x22)
                    fingerColls.Add((ushort)i);
            }

            var slots = new List<PtpFingerSlot>();
            foreach (ushort lc in fingerColls)
            {
                int minX = 0, maxX = 4096, minY = 0, maxY = 4096;
                foreach (var vc in vCaps.Take(vCapCount))
                {
                    if (vc.LinkCollection != lc || vc.UsagePage != 0x01) continue;
                    ushort uMin = vc.UsageMinOrUsage;
                    ushort uMax = vc.IsRange != 0 ? vc.UsageMax : uMin;
                    if (uMin <= 0x30 && 0x30 <= uMax)
                    {
                        minX = vc.LogicalMin;
                        maxX = vc.LogicalMax > vc.LogicalMin ? vc.LogicalMax : 4096;
                    }
                    if (uMin <= 0x31 && 0x31 <= uMax)
                    {
                        minY = vc.LogicalMin;
                        maxY = vc.LogicalMax > vc.LogicalMin ? vc.LogicalMax : 4096;
                    }
                }
                slots.Add(new PtpFingerSlot(lc, minX, maxX, minY, maxY));
            }

            var schema = new PtpDeviceSchema(preparsed, slots);
            _ptpDeviceCache[hDevice] = schema;
            return schema;
        }
        catch
        {
            Marshal.FreeHGlobal(preparsed);
            return null;
        }
    }

    private void ParsePtpReportAndDispatch(PtpDeviceSchema schema, byte[] report)
    {
        var points = new List<(double X, double Y)>(schema.Slots.Count);
        uint rLen = (uint)report.Length;
        uint reportedCount = 0;
        bool hasCount = HidP_GetUsageValue(0, 0x0D, 0, 0x54, out reportedCount, schema.PreparsedData, report, rLen) == HIDP_STATUS_SUCCESS;

        var usages = new ushort[8];
        foreach (var slot in schema.Slots)
        {
            uint uLen = (uint)usages.Length;
            int status = HidP_GetUsages(0, 0x0D, slot.LinkCollection, usages, ref uLen, schema.PreparsedData, report, rLen);
            bool tipDown = status == HIDP_STATUS_SUCCESS && usages.Take((int)uLen).Any(u => u == 0x42);
            if (!tipDown) continue;

            if (HidP_GetUsageValue(0, 0x01, slot.LinkCollection, 0x30, out uint rawX, schema.PreparsedData, report, rLen) != HIDP_STATUS_SUCCESS) continue;
            if (HidP_GetUsageValue(0, 0x01, slot.LinkCollection, 0x31, out uint rawY, schema.PreparsedData, report, rLen) != HIDP_STATUS_SUCCESS) continue;

            double nx = ((int)rawX - slot.MinX) / Math.Max(1.0, slot.MaxX - slot.MinX);
            double ny = ((int)rawY - slot.MinY) / Math.Max(1.0, slot.MaxY - slot.MinY);
            points.Add((Math.Clamp(nx, 0.0, 1.0), Math.Clamp(ny, 0.0, 1.0)));
        }

        if (hasCount && reportedCount > 0 && points.Count > (int)reportedCount)
            points = points.Take((int)reportedCount).ToList();

        ProcessTouchpadContacts(points);
    }

    private void ProcessTouchpadContacts(List<(double X, double Y)> points)
    {
        int count = points.Count;
        _tpFingerCount = count;

        if (count != 3)
        {
            // Release immediately on finger lift/change without applying centroid jump delta
            if (_tpThreeFingerDragging)
            {
                _tpThreeFingerDragging = false;
                Transport.SendControlFrame(DeskflowMsgType.MouseButton, new byte[] { 1, 0 });
            }
            _tpHasStart = false;
            _tpHasPrev = false;
            _tpHasFilteredDelta = false;
            _tpPendingDx = 0;
            _tpPendingDy = 0;
            _tpThreeFingerEnterTicksMs = 0;
            return;
        }

        bool allow3fDrag = IsHotkeyRuleEnabled("win_tp_3f_drag");
        if (!allow3fDrag)
        {
            if (_tpThreeFingerDragging)
            {
                _tpThreeFingerDragging = false;
                Transport.SendControlFrame(DeskflowMsgType.MouseButton, new byte[] { 1, 0 });
            }
            _tpHasStart = false;
            _tpHasPrev = false;
            _tpHasFilteredDelta = false;
            _tpPendingDx = 0;
            _tpPendingDy = 0;
            _tpThreeFingerEnterTicksMs = 0;
            return;
        }

        double avgX = points.Average(p => p.X);
        double avgY = points.Average(p => p.Y);
        long nowMs = Environment.TickCount64;

        if (!_tpHasStart)
        {
            _tpStartX = avgX;
            _tpStartY = avgY;
            _tpPrevX = avgX;
            _tpPrevY = avgY;
            _tpHasStart = true;
            _tpHasPrev = true;
            _tpHasFilteredDelta = false;
            _tpPendingDx = 0;
            _tpPendingDy = 0;
            _tpThreeFingerEnterTicksMs = nowMs;
            return;
        }

        double rawDx = avgX - (_tpHasPrev ? _tpPrevX : avgX);
        double rawDy = avgY - (_tpHasPrev ? _tpPrevY : avgY);
        _tpPrevX = avgX;
        _tpPrevY = avgY;
        _tpHasPrev = true;

        // Ignore abnormal single-frame centroid jumps caused by staggered finger touch/lift or palm rejection
        if (Math.Abs(rawDx) > 0.065 || Math.Abs(rawDy) > 0.065)
        {
            if (!_tpThreeFingerDragging)
            {
                _tpStartX = avgX;
                _tpStartY = avgY;
            }
            return;
        }

        if (!_tpThreeFingerDragging)
        {
            double sx = avgX - _tpStartX;
            double sy = avgY - _tpStartY;
            // Require >= 35ms finger settle + >= 0.012 normalized movement before initiating drag
            if (nowMs - _tpThreeFingerEnterTicksMs >= 35 && Math.Sqrt(sx * sx + sy * sy) >= 0.012)
            {
                _tpThreeFingerDragging = true;
                _tpHasFilteredDelta = false;
                _tpPendingDx = 0;
                _tpPendingDy = 0;
                _tpLastDragMoveTicksMs = 0;
                Transport.SendControlFrame(DeskflowMsgType.MouseButton, new byte[] { 1, 1 });
            }
            return;
        }

        _tpPendingDx += rawDx;
        _tpPendingDy += rawDy;

        // Throttle remote drag updates to ~70Hz so high-latency Wi-Fi links do not buffer long move queues
        if (nowMs - _tpLastDragMoveTicksMs < 14) return;

        // Deadzone filters micro-jitter while fingers rest stationary
        if (Math.Abs(_tpPendingDx) < 0.0010 && Math.Abs(_tpPendingDy) < 0.0010)
        {
            _tpPendingDx = 0;
            _tpPendingDy = 0;
            return;
        }

        double smoothDx = _tpHasFilteredDelta ? (_tpFiltDx * 0.25 + _tpPendingDx * 0.75) : _tpPendingDx;
        double smoothDy = _tpHasFilteredDelta ? (_tpFiltDy * 0.25 + _tpPendingDy * 0.75) : _tpPendingDy;
        _tpFiltDx = smoothDx;
        _tpFiltDy = smoothDy;
        _tpHasFilteredDelta = true;
        _tpPendingDx = 0;
        _tpPendingDy = 0;
        _tpLastDragMoveTicksMs = nowMs;

        _remoteMacNormX = Math.Clamp(_remoteMacNormX + smoothDx * 1.05, 0.0, 1.0);
        _remoteMacNormY = Math.Clamp(_remoteMacNormY + smoothDy * 1.05, 0.0, 1.0);
        SendRemoteMouseMove(_remoteMacMonIdx, _remoteMacNormX, _remoteMacNormY);
    }

    private sealed record PtpFingerSlot(ushort LinkCollection, int MinX, int MaxX, int MinY, int MaxY);
    private sealed class PtpDeviceSchema
    {
        public IntPtr PreparsedData { get; }
        public List<PtpFingerSlot> Slots { get; }
        public PtpDeviceSchema(IntPtr preparsed, List<PtpFingerSlot> slots)
        {
            PreparsedData = preparsed;
            Slots = slots;
        }
    }

    private const uint RID_INPUT = 0x10000003;
    private const uint RIM_TYPEMOUSE = 0;
    private const uint RIM_TYPEHID = 2;
    private const ushort MOUSE_MOVE_ABSOLUTE = 0x0001;
    private const uint RIDI_PREPARSEDDATA = 0x20000005;
    private const int HIDP_STATUS_SUCCESS = 0x00110000;

    [StructLayout(LayoutKind.Explicit, Size = 24)]
    internal struct RAWMOUSE
    {
        [FieldOffset(0)] public ushort usFlags;
        [FieldOffset(4)] public uint ulButtons;
        [FieldOffset(8)] public uint ulRawButtons;
        [FieldOffset(12)] public int lLastX;
        [FieldOffset(16)] public int lLastY;
        [FieldOffset(20)] public uint ulExtraInformation;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RAWINPUTDEVICE
    {
        public ushort usUsagePage;
        public ushort usUsage;
        public uint dwFlags;
        public IntPtr hwndTarget;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RAWINPUTHEADER
    {
        public uint dwType;
        public uint dwSize;
        public IntPtr hDevice;
        public IntPtr wParam;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HIDP_CAPS
    {
        public ushort Usage;
        public ushort UsagePage;
        public ushort InputReportByteLength;
        public ushort OutputReportByteLength;
        public ushort FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)]
        public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes;
        public ushort NumberInputButtonCaps;
        public ushort NumberInputValueCaps;
        public ushort NumberInputDataIndices;
        public ushort NumberOutputButtonCaps;
        public ushort NumberOutputValueCaps;
        public ushort NumberOutputDataIndices;
        public ushort NumberFeatureButtonCaps;
        public ushort NumberFeatureValueCaps;
        public ushort NumberFeatureDataIndices;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HIDP_LINK_COLLECTION_NODE
    {
        public ushort LinkUsage;
        public ushort LinkUsagePage;
        public ushort Parent;
        public ushort NumberOfChildren;
        public ushort NextSibling;
        public ushort FirstChild;
        public uint BitFields;
        public IntPtr UserContext;
    }

    [StructLayout(LayoutKind.Explicit, Size = 72)]
    private struct HIDP_VALUE_CAPS
    {
        [FieldOffset(0)] public ushort UsagePage;
        [FieldOffset(6)] public ushort LinkCollection;
        [FieldOffset(12)] public byte IsRange;
        [FieldOffset(40)] public int LogicalMin;
        [FieldOffset(44)] public int LogicalMax;
        [FieldOffset(56)] public ushort UsageMinOrUsage;
        [FieldOffset(58)] public ushort UsageMax;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] pRawInputDevices, uint uiNumDevices, uint cbSize);

    [DllImport("user32.dll")]
    private static extern uint GetRawInputData(IntPtr hRawInput, uint uiCommand, IntPtr pData, ref uint pcbSize, uint cbSizeHeader);

    [DllImport("user32.dll")]
    private static extern uint GetRawInputDeviceInfo(IntPtr hDevice, uint uiCommand, IntPtr pData, ref uint pcbSize);

    [DllImport("hid.dll")]
    private static extern int HidP_GetCaps(IntPtr PreparsedData, out HIDP_CAPS Capabilities);

    [DllImport("hid.dll")]
    private static extern int HidP_GetLinkCollectionNodes([Out] HIDP_LINK_COLLECTION_NODE[] LinkCollectionNodes, ref uint LinkCollectionNodesLength, IntPtr PreparsedData);

    [DllImport("hid.dll")]
    private static extern int HidP_GetValueCaps(int ReportType, [Out] HIDP_VALUE_CAPS[] ValueCaps, ref ushort ValueCapsLength, IntPtr PreparsedData);

    [DllImport("hid.dll")]
    private static extern int HidP_GetUsageValue(int ReportType, ushort UsagePage, ushort LinkCollection, ushort Usage, out uint UsageValue, IntPtr PreparsedData, byte[] Report, uint ReportLength);

    [DllImport("hid.dll")]
    private static extern int HidP_GetUsages(int ReportType, ushort UsagePage, ushort LinkCollection, [Out] ushort[] UsageList, ref uint UsageLength, IntPtr PreparsedData, byte[] Report, uint ReportLength);
}
