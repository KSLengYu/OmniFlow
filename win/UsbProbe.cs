using System;
using System.Runtime.InteropServices;
using System.Text;

namespace MacBridgeUI;

public sealed record UsbAppleStatus(
    bool Detected,
    string HardwareId,
    string Service,
    string FriendlyName,
    string UsbSpeedLabel,
    int UsbSpeedMbps);

/// <summary>
/// Queries Windows PnP USB devices and physical USB hub connection speed without spawning external processes.
/// </summary>
public static class UsbProbe
{
    private const uint DIGCF_PRESENT = 0x00000002;
    private const uint DIGCF_ALLCLASSES = 0x00000004;
    private const uint DIGCF_DEVICEINTERFACE = 0x00000010;
    private const uint SPDRP_DEVICEDESC = 0x00000000;
    private const uint SPDRP_HARDWAREID = 0x00000001;
    private const uint SPDRP_SERVICE = 0x00000004;
    private const uint SPDRP_FRIENDLYNAME = 0x0000000C;
    private const uint SPDRP_ADDRESS = 0x0000001C;

    private const uint GENERIC_WRITE = 0x40000000;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint OPEN_EXISTING = 3;
    private const uint IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX = 0x00220448;
    private const uint IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX_V2 = 0x0022045C;

    private static readonly Guid GUID_DEVINTERFACE_USB_HUB = new("f18a0e88-c30c-11d0-8815-00a0c906bed8");

    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVINFO_DATA
    {
        public uint cbSize;
        public Guid ClassGuid;
        public uint DevInst;
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVICE_INTERFACE_DATA
    {
        public uint cbSize;
        public Guid InterfaceClassGuid;
        public uint Flags;
        public IntPtr Reserved;
    }

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SetupDiGetClassDevs(ref Guid ClassGuid, string? Enumerator, IntPtr hwndParent, uint Flags);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SetupDiGetClassDevs(IntPtr ClassGuid, string? Enumerator, IntPtr hwndParent, uint Flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiEnumDeviceInfo(IntPtr DeviceInfoSet, uint MemberIndex, ref SP_DEVINFO_DATA DeviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiEnumDeviceInterfaces(
        IntPtr DeviceInfoSet,
        IntPtr DeviceInfoData,
        ref Guid InterfaceClassGuid,
        uint MemberIndex,
        ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetupDiGetDeviceInterfaceDetail(
        IntPtr DeviceInfoSet,
        ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData,
        IntPtr DeviceInterfaceDetailData,
        uint DeviceInterfaceDetailDataSize,
        out uint RequiredSize,
        ref SP_DEVINFO_DATA DeviceInfoData);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetupDiGetDeviceRegistryProperty(
        IntPtr DeviceInfoSet,
        ref SP_DEVINFO_DATA DeviceInfoData,
        uint Property,
        out uint PropertyRegDataType,
        byte[] PropertyBuffer,
        uint PropertyBufferSize,
        out uint RequiredSize);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

    [DllImport("cfgmgr32.dll")]
    private static extern uint CM_Get_Parent(out uint pdnDevInst, uint dnDevInst, uint ulFlags);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(
        string lpFileName,
        uint dwDesiredAccess,
        uint dwShareMode,
        IntPtr lpSecurityAttributes,
        uint dwCreationDisposition,
        uint dwFlagsAndAttributes,
        IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(
        IntPtr hDevice,
        uint dwIoControlCode,
        byte[] lpInBuffer,
        uint nInBufferSize,
        byte[] lpOutBuffer,
        uint nOutBufferSize,
        out uint lpBytesReturned,
        IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    private static string ReadPropString(IntPtr hDevInfo, ref SP_DEVINFO_DATA devInfo, uint prop)
    {
        var buf = new byte[2048];
        if (!SetupDiGetDeviceRegistryProperty(hDevInfo, ref devInfo, prop, out _, buf, (uint)buf.Length, out uint req))
            return string.Empty;
        int len = Math.Min(buf.Length, (int)req);
        string raw = Encoding.Unicode.GetString(buf, 0, len);
        int nul = raw.IndexOf('\0');
        return nul >= 0 ? raw[..nul] : raw;
    }

    private static uint ReadPropUInt(IntPtr hDevInfo, ref SP_DEVINFO_DATA devInfo, uint prop)
    {
        var buf = new byte[8];
        if (!SetupDiGetDeviceRegistryProperty(hDevInfo, ref devInfo, prop, out _, buf, (uint)buf.Length, out uint req) || req < 4)
            return 0;
        return BitConverter.ToUInt32(buf, 0);
    }

    private static string? FindHubInterfacePath(uint hubDevInst)
    {
        Guid hubGuid = GUID_DEVINTERFACE_USB_HUB;
        IntPtr hHubs = SetupDiGetClassDevs(ref hubGuid, null, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (hHubs == new IntPtr(-1)) return null;

        try
        {
            var ifData = new SP_DEVICE_INTERFACE_DATA { cbSize = (uint)Marshal.SizeOf<SP_DEVICE_INTERFACE_DATA>() };
            for (uint i = 0; SetupDiEnumDeviceInterfaces(hHubs, IntPtr.Zero, ref hubGuid, i, ref ifData); i++)
            {
                var devInfo = new SP_DEVINFO_DATA { cbSize = (uint)Marshal.SizeOf<SP_DEVINFO_DATA>() };
                SetupDiGetDeviceInterfaceDetail(hHubs, ref ifData, IntPtr.Zero, 0, out uint reqSize, ref devInfo);
                if (reqSize < 8) continue;

                IntPtr detailBuf = Marshal.AllocHGlobal((int)reqSize);
                try
                {
                    Marshal.WriteInt32(detailBuf, IntPtr.Size == 8 ? 8 : 6);
                    var infoOut = new SP_DEVINFO_DATA { cbSize = (uint)Marshal.SizeOf<SP_DEVINFO_DATA>() };
                    if (SetupDiGetDeviceInterfaceDetail(hHubs, ref ifData, detailBuf, reqSize, out _, ref infoOut))
                    {
                        if (infoOut.DevInst == hubDevInst)
                        {
                            return Marshal.PtrToStringUni(detailBuf + 4);
                        }
                    }
                }
                finally
                {
                    Marshal.FreeHGlobal(detailBuf);
                }
            }
        }
        finally
        {
            SetupDiDestroyDeviceInfoList(hHubs);
        }
        return null;
    }

    private static (string Label, int Mbps) QueryHubPortSpeed(uint childDevInst, uint portIndex)
    {
        if (portIndex == 0 || CM_Get_Parent(out uint parentDevInst, childDevInst, 0) != 0)
            return ("--", 0);

        string? hubPath = FindHubInterfacePath(parentDevInst);
        if (string.IsNullOrEmpty(hubPath))
            return ("--", 0);

        IntPtr hHub = CreateFile(hubPath, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (hHub == new IntPtr(-1))
            hHub = CreateFile(hubPath, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (hHub == new IntPtr(-1))
            return ("--", 0);

        try
        {
            var exBuf = new byte[1024];
            BitConverter.GetBytes(portIndex).CopyTo(exBuf, 0);
            if (!DeviceIoControl(hHub, IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX, exBuf, (uint)exBuf.Length, exBuf, (uint)exBuf.Length, out uint bytesRet, IntPtr.Zero) || bytesRet < 35)
                return ("--", 0);

            byte speedCode = exBuf[23];
            if (speedCode == 3)
            {
                // Query V2 to distinguish USB 3.0 (5 Gbps) vs USB 3.1/3.2 (10+ Gbps)
                var v2 = new byte[16];
                BitConverter.GetBytes(portIndex).CopyTo(v2, 0);
                BitConverter.GetBytes(16u).CopyTo(v2, 4);
                BitConverter.GetBytes(0x07u).CopyTo(v2, 8);
                if (DeviceIoControl(hHub, IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX_V2, v2, 16, v2, 16, out uint v2Ret, IntPtr.Zero) && v2Ret >= 16)
                {
                    uint flags = BitConverter.ToUInt32(v2, 12);
                    if ((flags & 0x04) != 0)
                        return ("USB 3.2 · 10 Gbps+", 10000);
                }
                return ("USB 3.0 · 5 Gbps", 5000);
            }

            return speedCode switch
            {
                2 => ("USB 2.0 · 480 Mbps", 480),
                1 => ("USB 1.1 · 12 Mbps", 12),
                0 => ("USB 1.0 · 1.5 Mbps", 2),
                _ => ("--", 0)
            };
        }
        finally
        {
            CloseHandle(hHub);
        }
    }

    public static UsbAppleStatus DetectAppleNcm()
    {
        IntPtr h = SetupDiGetClassDevs(IntPtr.Zero, "USB", IntPtr.Zero, DIGCF_ALLCLASSES | DIGCF_PRESENT);
        if (h == new IntPtr(-1))
            return new UsbAppleStatus(false, string.Empty, string.Empty, string.Empty, "--", 0);

        try
        {
            var did = new SP_DEVINFO_DATA { cbSize = (uint)Marshal.SizeOf<SP_DEVINFO_DATA>() };
            for (uint i = 0; SetupDiEnumDeviceInfo(h, i, ref did); i++)
            {
                string hwid = ReadPropString(h, ref did, SPDRP_HARDWAREID);
                if (string.IsNullOrEmpty(hwid)) continue;

                bool isAppleNcm = hwid.Contains("VID_05AC&PID_1902", StringComparison.OrdinalIgnoreCase) ||
                                  hwid.Contains("VID_05AC&PID_1905", StringComparison.OrdinalIgnoreCase);
                bool isChildMi = hwid.Contains("&MI_", StringComparison.OrdinalIgnoreCase);
                if (!isAppleNcm || isChildMi) continue;

                string svc = ReadPropString(h, ref did, SPDRP_SERVICE);
                string name = ReadPropString(h, ref did, SPDRP_FRIENDLYNAME);
                if (string.IsNullOrWhiteSpace(name))
                    name = ReadPropString(h, ref did, SPDRP_DEVICEDESC);

                uint portAddr = ReadPropUInt(h, ref did, SPDRP_ADDRESS);
                var (speedLabel, speedMbps) = QueryHubPortSpeed(did.DevInst, portAddr);

                return new UsbAppleStatus(true, hwid, svc, name, speedLabel, speedMbps);
            }
        }
        finally
        {
            SetupDiDestroyDeviceInfoList(h);
        }

        return new UsbAppleStatus(false, string.Empty, string.Empty, string.Empty, "--", 0);
    }
}
