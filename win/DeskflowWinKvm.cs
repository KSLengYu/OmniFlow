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
        var localMons = _localMonitors;
        if (localMons.Count == 0)
        {
            localMons = DeskflowTransport.EnumerateRealWindowsMonitors();
            _localMonitors = localMons;
        }
        for (int i = 0; i < localMons.Count; i++)
        {
            var m = localMons[i];
            if (px >= m.BoundsX - 6 && px <= m.BoundsX + m.WidthPx + 6 &&
                py >= m.BoundsY - 6 && py <= m.BoundsY + m.HeightPx + 6)
            {
                return m;
            }
        }
        return localMons.Count > 0 ? localMons[0] : null;
    }

    private (int centerX, int centerY) GetPrimaryCursorCenter()
    {
        var localMons = _localMonitors;
        if (localMons.Count == 0)
        {
            localMons = DeskflowTransport.EnumerateRealWindowsMonitors();
            _localMonitors = localMons;
        }
        WireMonitorDto? primary = null;
        for (int i = 0; i < localMons.Count; i++)
        {
            if (localMons[i].IsPrimary)
            {
                primary = localMons[i];
                break;
            }
        }
        primary ??= localMons.Count > 0 ? localMons[0] : null;
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
        var mons = Monitors;
        IndependentMonitorItem? activeMac = null;
        for (int i = 0; i < mons.Count; i++)
        {
            var m = mons[i];
            if (m.OsKind != "macOS") continue;
            activeMac ??= m;
            if (Math.Max(0, m.DisplayIndex - 1) == _remoteMacMonIdx)
            {
                activeMac = m;
                break;
            }
        }
        double refW = activeMac != null ? Math.Max(1280.0, activeMac.WidthPx / Math.Max(1.0, activeMac.ScaleFactor)) : 1728.0;
        double refH = activeMac != null ? Math.Max(720.0, activeMac.HeightPx / Math.Max(1.0, activeMac.ScaleFactor)) : 1117.0;
        return (refW, refH);
    }

    public void InjectMouseMoveAbs(int monitorIndex, double normX, double normY)
    {
        var localMons = _localMonitors;
        if (localMons.Count == 0)
        {
            localMons = DeskflowTransport.EnumerateRealWindowsMonitors();
            _localMonitors = localMons;
        }
        if (localMons.Count == 0) return;
        var mon = localMons[Math.Clamp(monitorIndex, 0, localMons.Count - 1)];

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
    [DllImport("user32.dll")] private static extern sbyte GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);
    [DllImport("user32.dll")] private static extern bool PeekMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref MSG lpMsg);
    [DllImport("user32.dll")] private static extern IntPtr DispatchMessage(ref MSG lpMsg);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool PostThreadMessage(uint idThread, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
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
    private const uint WM_QUIT = 0x0012;
    private const uint PM_NOREMOVE = 0x0000;

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public POINT pt;
    }

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
    private volatile IntPtr _mouseHook = IntPtr.Zero;
    private volatile IntPtr _kbdHook = IntPtr.Zero;
    private uint _hookThreadId;
    private Thread? _hookThread;
    private DateTime _lastEdgeSwitchTime = DateTime.MinValue;
    private DateTime _suppressEdgeCrossUntilUtc = DateTime.MinValue;
    private int _remoteMacMonIdx = 0;
    private double _remoteMacNormX = 0.5;
    private double _remoteMacNormY = 0.5;
    internal readonly WinCursorTransitionTracker _cursorTracker = new();
    private bool _hasPrevLocalPt = false;
    private int _prevLocalX = 0;
    private int _prevLocalY = 0;

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
        if (_hookThread != null) return;
        _mouseProc = MouseHookCallback;
        _kbdProc = KeyboardHookCallback;
        using var ready = new ManualResetEventSlim(false);
        _hookThread = new Thread(() =>
        {
            try
            {
                // Ensure a Win32 message queue exists on this dedicated hook thread before publishing thread ID
                PeekMessage(out _, IntPtr.Zero, 0, 0, PM_NOREMOVE);
                Volatile.Write(ref _hookThreadId, GetCurrentThreadId());

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
            finally
            {
                ready.Set();
            }

            while (!_kvmShuttingDown && GetMessage(out MSG msg, IntPtr.Zero, 0, 0) > 0)
            {
                TranslateMessage(ref msg);
                DispatchMessage(ref msg);
            }

            IntPtr mh = Interlocked.Exchange(ref _mouseHook, IntPtr.Zero);
            if (mh != IntPtr.Zero) UnhookWindowsHookEx(mh);
            IntPtr kh = Interlocked.Exchange(ref _kbdHook, IntPtr.Zero);
            if (kh != IntPtr.Zero) UnhookWindowsHookEx(kh);
        })
        {
            IsBackground = true,
            Priority = ThreadPriority.Highest,
            Name = "OmniFlow-KvmHooks"
        };
        _hookThread.Start();
        ready.Wait(1000);
    }

    private void ShutdownLowLevelHooks()
    {
        IntPtr mh = Interlocked.Exchange(ref _mouseHook, IntPtr.Zero);
        if (mh != IntPtr.Zero) UnhookWindowsHookEx(mh);
        IntPtr kh = Interlocked.Exchange(ref _kbdHook, IntPtr.Zero);
        if (kh != IntPtr.Zero) UnhookWindowsHookEx(kh);
        uint tid = Volatile.Read(ref _hookThreadId);
        if (tid != 0)
        {
            PostThreadMessage(tid, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
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

    private static void WriteRemoteMouseMovePayload(Span<byte> mb, int monIdx, double nx, double ny)
    {
        mb[0] = (byte)((monIdx >> 8) & 0xFF);
        mb[1] = (byte)(monIdx & 0xFF);
        int bx = BitConverter.SingleToInt32Bits((float)nx);
        int by = BitConverter.SingleToInt32Bits((float)ny);
        mb[2] = (byte)((bx >> 24) & 0xFF); mb[3] = (byte)((bx >> 16) & 0xFF);
        mb[4] = (byte)((bx >> 8) & 0xFF); mb[5] = (byte)(bx & 0xFF);
        mb[6] = (byte)((by >> 24) & 0xFF); mb[7] = (byte)((by >> 16) & 0xFF);
        mb[8] = (byte)((by >> 8) & 0xFF); mb[9] = (byte)(by & 0xFF);
    }

    private void SendRemoteMouseMove(int monIdx, double nx, double ny)
    {
        Span<byte> mb = stackalloc byte[10];
        WriteRemoteMouseMovePayload(mb, monIdx, nx, ny);
        Transport.SendMouseMoveCoalesced(mb);
    }

    private static double EdgeOverlap(double a1, double a2, double b1, double b2) =>
        Math.Max(0.0, Math.Min(a2, b2) - Math.Max(a1, b1));

    private IndependentMonitorItem? FindNearestEdgeNeighbor(
        string targetOsKind,
        double edgeCoord,
        double spanStart,
        double spanEnd,
        double crossCoord,
        bool verticalEdge,
        bool neighborEndsAtEdge)
    {
        var mons = Monitors;
        IndependentMonitorItem? best = null;
        double bestGap = double.MaxValue;
        for (int i = 0; i < mons.Count; i++)
        {
            var c = mons[i];
            if (c.OsKind != targetOsKind) continue;
            double candEdge = verticalEdge
                ? (neighborEndsAtEdge ? c.CanvasX + c.AspectWidth : c.CanvasX)
                : (neighborEndsAtEdge ? c.CanvasY + c.AspectHeight : c.CanvasY);
            double gap = Math.Abs(candEdge - edgeCoord);
            if (gap > 36.0 || gap >= bestGap) continue;

            double cStart = verticalEdge ? c.CanvasY : c.CanvasX;
            double cEnd = verticalEdge ? c.CanvasY + c.AspectHeight : c.CanvasX + c.AspectWidth;
            if (EdgeOverlap(spanStart, spanEnd, cStart, cEnd) <= 12.0) continue;
            if (crossCoord < cStart - 8.0 || crossCoord > cEnd + 8.0) continue;

            bestGap = gap;
            best = c;
        }
        return best;
    }

    private (int winMonIdx, double normX, double normY)? DetectReturnCrossingToWindows(double normX, double normY, double dx, double dy)
    {
        var mons = Monitors;
        IndependentMonitorItem? activeMac = null;
        bool hasWin = false;
        for (int i = 0; i < mons.Count; i++)
        {
            var m = mons[i];
            if (m.OsKind == "Windows")
            {
                hasWin = true;
            }
            else if (m.OsKind == "macOS")
            {
                if (activeMac == null || Math.Max(0, m.DisplayIndex - 1) == _remoteMacMonIdx)
                {
                    activeMac = m;
                }
            }
        }
        if (activeMac == null || !hasWin) return null;

        double ml = activeMac.CanvasX, mr = ml + activeMac.AspectWidth;
        double mt = activeMac.CanvasY, mb = mt + activeMac.AspectHeight;
        double cx = ml + Math.Clamp(normX, 0.0, 1.0) * activeMac.AspectWidth;
        double cy = mt + Math.Clamp(normY, 0.0, 1.0) * activeMac.AspectHeight;

        if (normX <= 0.0 && dx < 0)
        {
            var t = FindNearestEdgeNeighbor("Windows", ml, mt, mb, cy, verticalEdge: true, neighborEndsAtEdge: true);
            if (t != null) return (Math.Max(0, t.DisplayIndex - 1), 0.97, Math.Clamp((cy - t.CanvasY) / Math.Max(1, t.AspectHeight), 0.03, 0.97));
        }
        if (normX >= 1.0 && dx > 0)
        {
            var t = FindNearestEdgeNeighbor("Windows", mr, mt, mb, cy, verticalEdge: true, neighborEndsAtEdge: false);
            if (t != null) return (Math.Max(0, t.DisplayIndex - 1), 0.03, Math.Clamp((cy - t.CanvasY) / Math.Max(1, t.AspectHeight), 0.03, 0.97));
        }
        if (normY <= 0.0 && dy < 0)
        {
            var t = FindNearestEdgeNeighbor("Windows", mt, ml, mr, cx, verticalEdge: false, neighborEndsAtEdge: true);
            if (t != null) return (Math.Max(0, t.DisplayIndex - 1), Math.Clamp((cx - t.CanvasX) / Math.Max(1, t.AspectWidth), 0.03, 0.97), 0.97);
        }
        if (normY >= 1.0 && dy > 0)
        {
            var t = FindNearestEdgeNeighbor("Windows", mb, ml, mr, cx, verticalEdge: false, neighborEndsAtEdge: false);
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
        var localMons = _localMonitors;
        if (localMons.Count == 0)
        {
            localMons = DeskflowTransport.EnumerateRealWindowsMonitors();
            _localMonitors = localMons;
        }
        int wIdx = localMons.FindIndex(m => px >= m.BoundsX - 6 && px <= m.BoundsX + m.WidthPx + 6 && py >= m.BoundsY - 6 && py <= m.BoundsY + m.HeightPx + 6);
        if (wIdx < 0) wIdx = 0;
        if (wIdx >= localMons.Count) return null;

        var lm = localMons[wIdx];
        bool atLeft = px <= lm.BoundsX + tolerance;
        bool atRight = px >= lm.BoundsX + lm.WidthPx - tolerance;
        bool atTop = py <= lm.BoundsY + tolerance;
        bool atBottom = py >= lm.BoundsY + lm.HeightPx - tolerance;
        if (!atLeft && !atRight && !atTop && !atBottom) return null;

        var mons = Monitors;
        IndependentMonitorItem? winNode = null;
        bool hasMac = false;
        for (int i = 0; i < mons.Count; i++)
        {
            var m = mons[i];
            if (m.OsKind == "Windows" && m.DisplayIndex == lm.DisplayIndex) winNode ??= m;
            else if (m.OsKind == "macOS") hasMac = true;
        }
        if (winNode == null || !hasMac) return null;

        double nx = Math.Clamp((double)(px - lm.BoundsX) / Math.Max(1, lm.WidthPx), 0.03, 0.97);
        double ny = Math.Clamp((double)(py - lm.BoundsY) / Math.Max(1, lm.HeightPx), 0.03, 0.97);
        double wl = winNode.CanvasX, wr = wl + winNode.AspectWidth, wt = winNode.CanvasY, wb = wt + winNode.AspectHeight;
        double canvasX = wl + nx * winNode.AspectWidth;
        double canvasY = wt + ny * winNode.AspectHeight;

        if (atLeft)
        {
            var t = FindNearestEdgeNeighbor("macOS", wl, wt, wb, canvasY, verticalEdge: true, neighborEndsAtEdge: true);
            if (t != null) return (Math.Max(0, t.DisplayIndex - 1), 0.992, Math.Clamp((canvasY - t.CanvasY) / Math.Max(1, t.AspectHeight), 0.01, 0.99));
        }
        if (atRight)
        {
            var t = FindNearestEdgeNeighbor("macOS", wr, wt, wb, canvasY, verticalEdge: true, neighborEndsAtEdge: false);
            if (t != null) return (Math.Max(0, t.DisplayIndex - 1), 0.008, Math.Clamp((canvasY - t.CanvasY) / Math.Max(1, t.AspectHeight), 0.01, 0.99));
        }
        if (atTop)
        {
            var t = FindNearestEdgeNeighbor("macOS", wt, wl, wr, canvasX, verticalEdge: false, neighborEndsAtEdge: true);
            if (t != null) return (Math.Max(0, t.DisplayIndex - 1), Math.Clamp((canvasX - t.CanvasX) / Math.Max(1, t.AspectWidth), 0.01, 0.99), 0.992);
        }
        if (atBottom)
        {
            var t = FindNearestEdgeNeighbor("macOS", wb, wl, wr, canvasX, verticalEdge: false, neighborEndsAtEdge: false);
            if (t != null) return (Math.Max(0, t.DisplayIndex - 1), Math.Clamp((canvasX - t.CanvasX) / Math.Max(1, t.AspectWidth), 0.01, 0.99), 0.008);
        }
        return null;
    }

    private bool IsHotkeyRuleEnabled(string id) => HotkeyRules.Any(r => r.Id == id && r.Enabled);
}
