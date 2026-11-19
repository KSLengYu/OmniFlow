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
