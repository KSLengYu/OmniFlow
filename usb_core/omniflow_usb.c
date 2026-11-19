#define _CRT_SECURE_NO_WARNINGS
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <windows.h>
#include <setupapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <ctype.h>

#include "libwdi.h"
#include "restore_helper.h"

// ---- Dynamic WinUSB definitions ----
typedef PVOID WINUSB_INTERFACE_HANDLE, *PWINUSB_INTERFACE_HANDLE;

typedef struct _USB_INTERFACE_DESCRIPTOR {
    UCHAR bLength;
    UCHAR bDescriptorType;
    UCHAR bInterfaceNumber;
    UCHAR bAlternateSetting;
    UCHAR bNumEndpoints;
    UCHAR bInterfaceClass;
    UCHAR bInterfaceSubClass;
    UCHAR bInterfaceProtocol;
    UCHAR iInterface;
} USB_INTERFACE_DESCRIPTOR, *PUSB_INTERFACE_DESCRIPTOR;

typedef enum _USBD_PIPE_TYPE {
    UsbdPipeTypeControl,
    UsbdPipeTypeIsochronous,
    UsbdPipeTypeBulk,
    UsbdPipeTypeInterrupt
} USBD_PIPE_TYPE;

typedef struct _WINUSB_PIPE_INFORMATION {
    USBD_PIPE_TYPE PipeType;
    UCHAR PipeId;
    USHORT MaximumPacketSize;
    UCHAR Interval;
} WINUSB_PIPE_INFORMATION, *PWINUSB_PIPE_INFORMATION;

#pragma pack(push, 1)
typedef struct _WINUSB_SETUP_PACKET {
    UCHAR RequestType;
    UCHAR Request;
    USHORT Value;
    USHORT Index;
    USHORT Length;
} WINUSB_SETUP_PACKET, *PWINUSB_SETUP_PACKET;

typedef struct _NCM_NTB_PARAMS {
    uint16_t wLength;
    uint16_t bmNtbFormatsSupported;
    uint32_t dwNtbInMaxSize;
    uint16_t wNdpInDivisor;
    uint16_t wNdpInPayloadRemainder;
    uint16_t wNdpInAlignment;
    uint16_t wReserved;
    uint32_t dwNtbOutMaxSize;
    uint16_t wNdpOutDivisor;
    uint16_t wNdpOutPayloadRemainder;
    uint16_t wNdpOutAlignment;
    uint16_t wNtbOutMaxDatagrams;
} NCM_NTB_PARAMS;

typedef struct _NCM_NTH16 {
    uint32_t dwSignature;
    uint16_t wHeaderLength;
    uint16_t wSequence;
    uint16_t wBlockLength;
    uint16_t wNdpIndex;
} NCM_NTH16;
#pragma pack(pop)

typedef BOOL (WINAPI *PFN_WinUsb_Initialize)(HANDLE, PWINUSB_INTERFACE_HANDLE);
typedef BOOL (WINAPI *PFN_WinUsb_Free)(WINUSB_INTERFACE_HANDLE);
typedef BOOL (WINAPI *PFN_WinUsb_GetAssociatedInterface)(WINUSB_INTERFACE_HANDLE, UCHAR, PWINUSB_INTERFACE_HANDLE);
typedef BOOL (WINAPI *PFN_WinUsb_QueryInterfaceSettings)(WINUSB_INTERFACE_HANDLE, UCHAR, PUSB_INTERFACE_DESCRIPTOR);
typedef BOOL (WINAPI *PFN_WinUsb_SetCurrentAlternateInterface)(WINUSB_INTERFACE_HANDLE, UCHAR);
typedef BOOL (WINAPI *PFN_WinUsb_QueryPipe)(WINUSB_INTERFACE_HANDLE, UCHAR, UCHAR, PWINUSB_PIPE_INFORMATION);
typedef BOOL (WINAPI *PFN_WinUsb_ControlTransfer)(WINUSB_INTERFACE_HANDLE, WINUSB_SETUP_PACKET, PUCHAR, ULONG, PULONG, LPOVERLAPPED);
typedef BOOL (WINAPI *PFN_WinUsb_ReadPipe)(WINUSB_INTERFACE_HANDLE, UCHAR, PUCHAR, ULONG, PULONG, LPOVERLAPPED);
typedef BOOL (WINAPI *PFN_WinUsb_WritePipe)(WINUSB_INTERFACE_HANDLE, UCHAR, PUCHAR, ULONG, PULONG, LPOVERLAPPED);

static PFN_WinUsb_Initialize pWinUsb_Initialize;
static PFN_WinUsb_Free pWinUsb_Free;
static PFN_WinUsb_GetAssociatedInterface pWinUsb_GetAssociatedInterface;
static PFN_WinUsb_QueryInterfaceSettings pWinUsb_QueryInterfaceSettings;
static PFN_WinUsb_SetCurrentAlternateInterface pWinUsb_SetCurrentAlternateInterface;
static PFN_WinUsb_QueryPipe pWinUsb_QueryPipe;
static PFN_WinUsb_ControlTransfer pWinUsb_ControlTransfer;
static PFN_WinUsb_ReadPipe pWinUsb_ReadPipe;
static PFN_WinUsb_WritePipe pWinUsb_WritePipe;

// ---- Dynamic Wintun definitions ----
typedef void* WINTUN_ADAPTER_HANDLE;
typedef void* WINTUN_SESSION_HANDLE;
typedef WINTUN_ADAPTER_HANDLE (WINAPI *PFN_WintunCreateAdapter)(LPCWSTR, LPCWSTR, const GUID*);
typedef void (WINAPI *PFN_WintunCloseAdapter)(WINTUN_ADAPTER_HANDLE);
typedef WINTUN_SESSION_HANDLE (WINAPI *PFN_WintunStartSession)(WINTUN_ADAPTER_HANDLE, DWORD);
typedef void (WINAPI *PFN_WintunEndSession)(WINTUN_SESSION_HANDLE);
typedef HANDLE (WINAPI *PFN_WintunGetReadWaitEvent)(WINTUN_SESSION_HANDLE);
typedef BYTE* (WINAPI *PFN_WintunReceivePacket)(WINTUN_SESSION_HANDLE, DWORD*);
typedef void (WINAPI *PFN_WintunReleaseReceivePacket)(WINTUN_SESSION_HANDLE, const BYTE*);
typedef BYTE* (WINAPI *PFN_WintunAllocateSendPacket)(WINTUN_SESSION_HANDLE, DWORD);
typedef void (WINAPI *PFN_WintunSendPacket)(WINTUN_SESSION_HANDLE, const BYTE*);

static PFN_WintunCreateAdapter pWintunCreateAdapter;
static PFN_WintunCloseAdapter pWintunCloseAdapter;
static PFN_WintunStartSession pWintunStartSession;
static PFN_WintunEndSession pWintunEndSession;
static PFN_WintunGetReadWaitEvent pWintunGetReadWaitEvent;
static PFN_WintunReceivePacket pWintunReceivePacket;
static PFN_WintunReleaseReceivePacket pWintunReleaseReceivePacket;
static PFN_WintunAllocateSendPacket pWintunAllocateSendPacket;
static PFN_WintunSendPacket pWintunSendPacket;

// ---- Globals ----
static WINUSB_INTERFACE_HANDLE g_dataIf = NULL;
static UCHAR g_epIn = 0x81;
static UCHAR g_epOut = 0x01;
static WINTUN_SESSION_HANDLE g_session = NULL;
static volatile LONG g_running = 1;
static HANDLE g_stopEvent = NULL;
static NCM_NTB_PARAMS g_ntb = {0};
static CRITICAL_SECTION g_txLock;
static uint16_t g_txSeq = 0;

static const uint8_t WIN_MAC[6] = {0x02, 0x50, 0x43, 0x00, 0x00, 0x02};
static uint8_t WIN_IP[4]  = {10, 13, 37, 2};
static uint8_t MAC_IP[4]  = {10, 13, 37, 1};

typedef struct { uint8_t o1, o2, o3; } TUNNEL_PREFIX;
static const TUNNEL_PREFIX CANDIDATE_PREFIXES[] = {
    {10, 13, 37},
    {10, 13, 38},
    {10, 13, 39},
    {10, 13, 137},
    {10, 13, 138},
    {10, 13, 237},
    {10, 13, 238},
    {10, 13, 239},
    {100, 113, 37},
    {172, 31, 237},
    {192, 168, 237}
};
static uint8_t g_peerMac[6] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
static volatile LONG g_hasPeerMac = 0;
static volatile LONG64 g_rxFrames = 0, g_txFrames = 0;

static const char *DEFAULT_WINUSB_GUID = "{E72A46C5-37CC-459F-8DA4-31ED9FD127E8}";

static int is_prefix_in_use(uint8_t o1, uint8_t o2, uint8_t o3) {
    uint32_t candStart = ((uint32_t)o1 << 24) | ((uint32_t)o2 << 16) | ((uint32_t)o3 << 8);
    uint32_t candMask  = 0xFFFFFF00u;
    DWORD ownIfIndex = 0;
    int conflict = 0;

    ULONG abufSz = 16384;
    PIP_ADAPTER_ADDRESSES addrs = (PIP_ADAPTER_ADDRESSES)malloc(abufSz);
    if (addrs) {
        if (GetAdaptersAddresses(AF_INET, GAA_FLAG_INCLUDE_PREFIX, NULL, addrs, &abufSz) == ERROR_BUFFER_OVERFLOW) {
            free(addrs);
            addrs = (PIP_ADAPTER_ADDRESSES)malloc(abufSz);
        }
        if (addrs && GetAdaptersAddresses(AF_INET, GAA_FLAG_INCLUDE_PREFIX, NULL, addrs, &abufSz) == NO_ERROR) {
            for (PIP_ADAPTER_ADDRESSES aa = addrs; aa; aa = aa->Next) {
                if (aa->FriendlyName && _wcsicmp(aa->FriendlyName, L"MacBridge") == 0) {
                    ownIfIndex = aa->IfIndex;
                    break;
                }
            }
            for (PIP_ADAPTER_ADDRESSES aa = addrs; aa && !conflict; aa = aa->Next) {
                if (aa->IfIndex == ownIfIndex || aa->OperStatus != IfOperStatusUp) continue;
                for (PIP_ADAPTER_UNICAST_ADDRESS ua = aa->FirstUnicastAddress; ua; ua = ua->Next) {
                    if (!ua->Address.lpSockaddr || ua->Address.lpSockaddr->sa_family != AF_INET) continue;
                    const struct sockaddr_in *sin = (const struct sockaddr_in*)ua->Address.lpSockaddr;
                    uint32_t ip = ntohl(sin->sin_addr.s_addr);
                    UINT8 pfxLen = ua->OnLinkPrefixLength;
                    uint32_t mask = (pfxLen == 0) ? 0u : (pfxLen >= 32 ? 0xFFFFFFFFu : (~0u << (32 - pfxLen)));
                    if (mask != 0) {
                        uint32_t common = mask & candMask;
                        if ((ip & common) == (candStart & common)) {
                            conflict = 1;
                            break;
                        }
                    }
                }
            }
        }
        free(addrs);
    }
    if (conflict) return 1;

    ULONG rSz = 0;
    if (GetIpForwardTable(NULL, &rSz, FALSE) == ERROR_INSUFFICIENT_BUFFER && rSz > 0) {
        PMIB_IPFORWARDTABLE tbl = (PMIB_IPFORWARDTABLE)malloc(rSz);
        if (tbl) {
            if (GetIpForwardTable(tbl, &rSz, FALSE) == NO_ERROR) {
                for (DWORD i = 0; i < tbl->dwNumEntries; i++) {
                    const MIB_IPFORWARDROW *row = &tbl->table[i];
                    if (row->dwForwardIfIndex == ownIfIndex) continue;
                    uint32_t dest = ntohl(row->dwForwardDest);
                    uint32_t mask = ntohl(row->dwForwardMask);
                    if (mask == 0 || (dest & 0xF0000000u) == 0xE0000000u ||
                        dest == 0xFFFFFFFFu || (dest & 0xFF000000u) == 0x7F000000u) {
                        continue;
                    }
                    uint32_t common = mask & candMask;
                    if ((dest & common) == (candStart & common)) {
                        conflict = 1;
                        break;
                    }
                }
            }
            free(tbl);
        }
    }
    return conflict;
}

static void select_tunnel_subnet(int pairIdx) {
    int count = (int)(sizeof(CANDIDATE_PREFIXES) / sizeof(CANDIDATE_PREFIXES[0]));
    int start = (pairIdx >= 0) ? (pairIdx % count) : 0;
    int chosen = start;
    for (int i = 0; i < count; i++) {
        int idx = (start + i) % count;
        if (!is_prefix_in_use(CANDIDATE_PREFIXES[idx].o1, CANDIDATE_PREFIXES[idx].o2, CANDIDATE_PREFIXES[idx].o3)) {
            chosen = idx;
            break;
        }
    }
    const TUNNEL_PREFIX *p = &CANDIDATE_PREFIXES[chosen];
    WIN_IP[0] = p->o1; WIN_IP[1] = p->o2; WIN_IP[2] = p->o3; WIN_IP[3] = 2;
    MAC_IP[0] = p->o1; MAC_IP[1] = p->o2; MAC_IP[2] = p->o3; MAC_IP[3] = 1;
    if (chosen != start) {
        printf("[NET] Subnet %u.%u.%u.0/24 conflict detected, fallback -> %u.%u.%u.2/24\n",
               CANDIDATE_PREFIXES[start].o1, CANDIDATE_PREFIXES[start].o2, CANDIDATE_PREFIXES[start].o3,
               WIN_IP[0], WIN_IP[1], WIN_IP[2]);
    }
}

/** Resolve directory containing the current executable. */
static void get_exe_dir(char *outDir, DWORD cap) {
    GetModuleFileNameA(NULL, outDir, cap);
    char *slash = strrchr(outDir, '\\');
    if (slash) *slash = '\0';
    else strcpy(outDir, ".");
}

/** Fast SetupAPI check whether the MacBook USB-C CDC-NCM gadget parent is still attached. */
static int is_apple_usb_present(void) {
    HDEVINFO hAll = SetupDiGetClassDevsA(NULL, "USB", NULL, DIGCF_ALLCLASSES | DIGCF_PRESENT);
    if (hAll == INVALID_HANDLE_VALUE) return 0;

    int found = 0;
    SP_DEVINFO_DATA did;
    did.cbSize = sizeof(did);
    for (DWORD i = 0; SetupDiEnumDeviceInfo(hAll, i, &did); i++) {
        char hwid[1024] = {0};
        if (SetupDiGetDeviceRegistryPropertyA(hAll, &did, SPDRP_HARDWAREID, NULL, (PBYTE)hwid, sizeof(hwid) - 1, NULL)) {
            if (mb_is_apple_ncm_parent_hwid(hwid)) {
                found = 1;
                break;
            }
        }
    }
    SetupDiDestroyDeviceInfoList(hAll);
    return found;
}

/** Detect Apple MacBook USB-C CDC-NCM gadget and bind WinUSB automatically via libwdi if needed. */
static int ensure_apple_winusb(int waitIfMissing) {
    wdi_set_log_level(WDI_LOG_LEVEL_WARNING);
    int waitedMsg = 0;

    while (g_running) {
        struct wdi_options_create_list ocl;
        ZeroMemory(&ocl, sizeof(ocl));
        ocl.list_all = TRUE;
        ocl.list_hubs = TRUE; /* Composite parent (usbccgp) requires list_hubs=TRUE */
        ocl.trim_whitespaces = TRUE;

        struct wdi_device_info *list = NULL, *target = NULL;
        int lr = wdi_create_list(&list, &ocl);
        if (lr == WDI_SUCCESS) {
            for (struct wdi_device_info *d = list; d != NULL; d = d->next) {
                if (d->vid == 0x05AC && (d->pid == 0x1902 || d->pid == 0x1905) &&
                    d->hardware_id && strstr(d->hardware_id, "&MI_") == NULL) {
                    target = d;
                    break;
                }
            }
        }

        if (!target) {
            if (list) wdi_destroy_list(list);
            if (!waitIfMissing) {
                printf("[ERR] No MacBook USB-C NCM device (VID_05AC PID_1902/1905) detected.\n");
                return -1;
            }
            if (!waitedMsg) {
                printf("[WAIT] Waiting for MacBook USB-C cable (VID_05AC PID_1902/1905)...\n");
                printf("       Plug in the Type-C cable between Windows and Mac.\n");
                waitedMsg = 1;
            }
            Sleep(1500);
            continue;
        }

        printf("[DETECT] Found Mac USB-C gadget: \"%s\"\n", target->desc ? target->desc : "MacBook");
        printf("         HardwareID=%s | CurrentDriver=%s\n",
               target->hardware_id, target->driver ? target->driver : "(none)");

        if (target->driver && _stricmp(target->driver, "WinUSB") == 0) {
            printf("[OK] WinUSB is already bound.\n");
            wdi_destroy_list(list);
            return 0;
        }

        char exeDir[MAX_PATH] = {0}, drvDir[512] = {0};
        get_exe_dir(exeDir, sizeof(exeDir));
        snprintf(drvDir, sizeof(drvDir), "%s\\drv_cache", exeDir);

        struct wdi_options_prepare_driver opd;
        ZeroMemory(&opd, sizeof(opd));
        opd.driver_type = WDI_WINUSB;
        opd.vendor_name = "Apple, Inc.";
        opd.device_guid = (char*)DEFAULT_WINUSB_GUID;

        printf("[DRIVER] Preparing WinUSB INF/CAT via built-in libwdi...\n");
        int r = wdi_prepare_driver(target, drvDir, "MacBridge_Apple_NCM.inf", &opd);
        if (r != WDI_SUCCESS) {
            printf("[ERR] wdi_prepare_driver failed: %s (%d)\n", wdi_strerror(r), r);
            wdi_destroy_list(list);
            return -2;
        }

        struct wdi_options_install_driver oid;
        ZeroMemory(&oid, sizeof(oid));
        oid.pending_install_timeout = 30000;

        printf("[DRIVER] Installing WinUSB onto %s (this may take 5-15s)...\n", target->hardware_id);
        r = wdi_install_driver(target, drvDir, "MacBridge_Apple_NCM.inf", &oid);
        wdi_destroy_list(list);
        if (r != WDI_SUCCESS) {
            printf("[ERR] wdi_install_driver failed: %s (%d)\n", wdi_strerror(r), r);
            return -3;
        }

        printf("[OK] WinUSB bound cleanly without testsigning! Waiting for re-enumeration...\n");
        Sleep(1500);
        return 0;
    }
    return -1;
}

static int parse_guid(const char *s, GUID *g) {
    unsigned int d1, d2, d3;
    unsigned int d4[8];
    if (sscanf(s, "{%8x-%4x-%4x-%2x%2x-%2x%2x%2x%2x%2x%2x}",
               &d1, &d2, &d3, &d4[0], &d4[1], &d4[2], &d4[3], &d4[4], &d4[5], &d4[6], &d4[7]) != 11) {
        return 0;
    }
    g->Data1 = d1;
    g->Data2 = (uint16_t)d2;
    g->Data3 = (uint16_t)d3;
    for (int i = 0; i < 8; i++) g->Data4[i] = (uint8_t)d4[i];
    return 1;
}

/** Check case-insensitively if path belongs to Apple 05AC:1902 or 05AC:1905 WinUSB device. */
static int path_matches_apple_ncm(const char *path) {
    char low[1024];
    size_t n = strlen(path);
    if (n >= sizeof(low)) n = sizeof(low) - 1;
    for (size_t i = 0; i < n; i++) low[i] = (char)tolower((unsigned char)path[i]);
    low[n] = '\0';
    return strstr(low, "vid_05ac&pid_1902") != NULL || strstr(low, "vid_05ac&pid_1905") != NULL;
}

static int find_winusb_apple_path(char *outPath, DWORD outCap, const char *overrideGuid) {
    GUID targetGuid;
    int haveGuid = 0;
    if (overrideGuid && parse_guid(overrideGuid, &targetGuid)) {
        haveGuid = 1;
    } else {
        HDEVINFO hAll = SetupDiGetClassDevsA(NULL, "USB", NULL, DIGCF_ALLCLASSES | DIGCF_PRESENT);
        if (hAll != INVALID_HANDLE_VALUE) {
            SP_DEVINFO_DATA did;
            did.cbSize = sizeof(did);
            for (DWORD i = 0; SetupDiEnumDeviceInfo(hAll, i, &did); i++) {
                char hwid[1024] = {0}, svc[256] = {0};
                SetupDiGetDeviceRegistryPropertyA(hAll, &did, SPDRP_HARDWAREID, NULL, (PBYTE)hwid, sizeof(hwid) - 1, NULL);
                SetupDiGetDeviceRegistryPropertyA(hAll, &did, SPDRP_SERVICE, NULL, (PBYTE)svc, sizeof(svc) - 1, NULL);
                if (mb_is_apple_ncm_parent_hwid(hwid) && _stricmp(svc, "WinUSB") == 0) {
                    HKEY hk = SetupDiOpenDevRegKey(hAll, &did, DICS_FLAG_GLOBAL, 0, DIREG_DEV, KEY_READ);
                    if (hk != INVALID_HANDLE_VALUE) {
                        char guidBuf[256] = {0};
                        DWORD sz = sizeof(guidBuf) - 1, type = 0;
                        if (RegQueryValueExA(hk, "DeviceInterfaceGUIDs", NULL, &type, (LPBYTE)guidBuf, &sz) == ERROR_SUCCESS ||
                            RegQueryValueExA(hk, "DeviceInterfaceGUID", NULL, &type, (LPBYTE)guidBuf, &sz) == ERROR_SUCCESS) {
                            if (parse_guid(guidBuf, &targetGuid)) {
                                printf("[USB] Found WinUSB device (%s), GUID=%s\n", hwid, guidBuf);
                                haveGuid = 1;
                            }
                        }
                        RegCloseKey(hk);
                    }
                    if (haveGuid) break;
                }
            }
            SetupDiDestroyDeviceInfoList(hAll);
        }
    }

    if (!haveGuid) return 0;

    HDEVINFO hIf = SetupDiGetClassDevsA(&targetGuid, NULL, NULL, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (hIf == INVALID_HANDLE_VALUE) return 0;

    SP_DEVICE_INTERFACE_DATA ifd;
    ifd.cbSize = sizeof(ifd);
    int found = 0;
    for (DWORD i = 0; SetupDiEnumDeviceInterfaces(hIf, NULL, &targetGuid, i, &ifd); i++) {
        DWORD req = 0;
        SetupDiGetDeviceInterfaceDetailA(hIf, &ifd, NULL, 0, &req, NULL);
        if (req == 0) continue;
        PSP_DEVICE_INTERFACE_DETAIL_DATA_A det = (PSP_DEVICE_INTERFACE_DETAIL_DATA_A)malloc(req);
        if (!det) continue;
        det->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_A);
        if (SetupDiGetDeviceInterfaceDetailA(hIf, &ifd, det, req, NULL, NULL)) {
            if (path_matches_apple_ncm(det->DevicePath)) {
                strncpy(outPath, det->DevicePath, outCap - 1);
                outPath[outCap - 1] = 0;
                found = 1;
                free(det);
                break;
            }
        }
        free(det);
    }
    SetupDiDestroyDeviceInfoList(hIf);
    return found;
}

static uint16_t align_up(uint16_t val, uint16_t align) {
    if (align <= 1) return val;
    return (uint16_t)(((val + align - 1) / align) * align);
}

static uint16_t align_up_rem(uint16_t val, uint16_t div, uint16_t rem) {
    if (div <= 1) return val;
    uint16_t r = rem % div;
    uint16_t cur = val % div;
    if (cur == r) return val;
    uint16_t diff = (cur < r) ? (r - cur) : (div - cur + r);
    return (uint16_t)(val + diff);
}

static void trigger_shutdown(void) {
    InterlockedExchange(&g_running, 0);
    if (g_stopEvent) SetEvent(g_stopEvent);
}

static int is_usb_disconnect_err(DWORD err) {
    return err == ERROR_BAD_COMMAND ||
           err == ERROR_GEN_FAILURE ||
           err == ERROR_DEVICE_NOT_CONNECTED ||
           err == ERROR_INVALID_HANDLE ||
           err == ERROR_FILE_NOT_FOUND ||
           err == 433; /* ERROR_NO_SUCH_DEVICE */
}

/** Pack up to 32 Ethernet frames into one CDC-NCM NTB16 block and send over Bulk OUT. */
static void send_ncm_eth_batch(const uint8_t * const *frames, const uint16_t *lens, int count) {
    if (count <= 0) return;
    uint16_t ndpAlign = g_ntb.wNdpOutAlignment ? g_ntb.wNdpOutAlignment : 4;
    uint16_t div = g_ntb.wNdpOutDivisor ? g_ntb.wNdpOutDivisor : 4;
    uint16_t rem = g_ntb.wNdpOutPayloadRemainder;
    uint32_t maxOut = (g_ntb.dwNtbOutMaxSize >= 2048 && g_ntb.dwNtbOutMaxSize <= 32764) ? g_ntb.dwNtbOutMaxSize : 16384;

    uint16_t ndpOff = align_up(sizeof(NCM_NTH16), ndpAlign);
    uint16_t ndpLen = (uint16_t)(8 + (count + 1) * 4);
    uint16_t cursor = (uint16_t)(ndpOff + ndpLen);

    static uint8_t buf[32768];
    uint16_t dOffs[32];
    if (count > 32) count = 32;

    for (int i = 0; i < count; i++) {
        uint16_t dgramOff = align_up_rem(cursor, div, rem);
        if ((uint32_t)dgramOff + lens[i] > maxOut) {
            count = i;
            break;
        }
        dOffs[i] = dgramOff;
        cursor = (uint16_t)(dgramOff + lens[i]);
    }
    if (count == 0) return;

    uint16_t totalLen = cursor;
    if ((totalLen % 512) == 0 && (uint32_t)totalLen + 4 <= maxOut) totalLen += 4;

    EnterCriticalSection(&g_txLock);
    memset(buf, 0, ndpOff + ndpLen);

    NCM_NTH16 *nth = (NCM_NTH16*)buf;
    nth->dwSignature = 0x484D434E; // NCMH
    nth->wHeaderLength = sizeof(NCM_NTH16);
    nth->wSequence = g_txSeq++;
    nth->wBlockLength = totalLen;
    nth->wNdpIndex = ndpOff;

    *(uint32_t*)(buf + ndpOff) = 0x304D434E; // NCM0
    *(uint16_t*)(buf + ndpOff + 4) = ndpLen;
    *(uint16_t*)(buf + ndpOff + 6) = 0;

    uint16_t prevEnd = (uint16_t)(ndpOff + ndpLen);
    for (int i = 0; i < count; i++) {
        if (dOffs[i] > prevEnd) memset(buf + prevEnd, 0, dOffs[i] - prevEnd);
        memcpy(buf + dOffs[i], frames[i], lens[i]);
        *(uint16_t*)(buf + ndpOff + 8 + i * 4) = dOffs[i];
        *(uint16_t*)(buf + ndpOff + 8 + i * 4 + 2) = lens[i];
        prevEnd = (uint16_t)(dOffs[i] + lens[i]);
    }
    *(uint16_t*)(buf + ndpOff + 8 + count * 4) = 0;
    *(uint16_t*)(buf + ndpOff + 8 + count * 4 + 2) = 0;
    if (totalLen > prevEnd) memset(buf + prevEnd, 0, totalLen - prevEnd);

    ULONG written = 0;
    BOOL ok = pWinUsb_WritePipe(g_dataIf, g_epOut, buf, totalLen, &written, NULL);
    DWORD err = ok ? 0 : GetLastError();
    LeaveCriticalSection(&g_txLock);

    static volatile LONG g_txErrs = 0;
    if (ok) {
        InterlockedExchange(&g_txErrs, 0);
        InterlockedExchangeAdd64(&g_txFrames, (LONG64)count);
    } else if (g_running) {
        LONG errs = InterlockedIncrement(&g_txErrs);
        printf("[TX] WritePipe err=%lu\n", err);
        if (is_usb_disconnect_err(err) || errs >= 3) {
            printf("[USB] Cable disconnected or USB endpoint lost (TX err=%lu), stopping tunnel...\n", err);
            trigger_shutdown();
        }
    }
}

static void send_ncm_eth_frame(const uint8_t *frame, uint16_t frameLen) {
    send_ncm_eth_batch(&frame, &frameLen, 1);
}

static uint16_t inet_csum(const uint8_t *data, int len, uint32_t init) {
    uint32_t sum = init;
    for (int i = 0; i + 1 < len; i += 2) {
        sum += ((uint32_t)data[i] << 8) | data[i + 1];
    }
    if (len & 1) sum += ((uint32_t)data[len - 1] << 8);
    while (sum >> 16) sum = (sum & 0xFFFFu) + (sum >> 16);
    return (uint16_t)(~sum & 0xFFFFu);
}

/** Minimal zero-config DHCPv4 responder assigning 10.13.37.1/24 to macOS peer. */
static int try_handle_dhcp_v4(const uint8_t *eth, uint16_t len) {
    if (len < 14 + 20 + 8 + 240) return 0;
    const uint8_t *ip = eth + 14;
    if ((ip[0] >> 4) != 4 || ip[9] != 17) return 0;
    int ihl = (ip[0] & 0x0F) * 4;
    if (ihl < 20 || 14 + ihl + 8 + 240 > len) return 0;
    const uint8_t *udp = ip + ihl;
    uint16_t sport = (uint16_t)((udp[0] << 8) | udp[1]);
    uint16_t dport = (uint16_t)((udp[2] << 8) | udp[3]);
    if (sport != 68 || dport != 67) return 0;

    const uint8_t *bootp = udp + 8;
    int bootpLen = (int)len - (int)(bootp - eth);
    if (bootp[0] != 1 || bootpLen < 240) return 0;
    if (bootp[236] != 0x63 || bootp[237] != 0x82 || bootp[238] != 0x53 || bootp[239] != 0x63) return 0;

    uint8_t msgType = 0;
    int optOff = 240;
    while (optOff < bootpLen) {
        uint8_t code = bootp[optOff++];
        if (code == 0) continue;
        if (code == 255 || optOff >= bootpLen) break;
        uint8_t olen = bootp[optOff++];
        if (optOff + olen > bootpLen) break;
        if (code == 53 && olen >= 1) msgType = bootp[optOff];
        optOff += olen;
    }
    if (msgType != 1 && msgType != 3) return 1;

    uint8_t replyType = (msgType == 1) ? 2 : 5;
    uint8_t pkt[512];
    memset(pkt, 0, sizeof(pkt));

    uint16_t bcastFlag = (uint16_t)((bootp[10] << 8) | bootp[11]);
    if (bcastFlag & 0x8000) memset(pkt + 0, 0xFF, 6);
    else memcpy(pkt + 0, eth + 6, 6);
    memcpy(pkt + 6, WIN_MAC, 6);
    pkt[12] = 0x08; pkt[13] = 0x00;

    uint8_t *rip = pkt + 14;
    uint8_t *rudp = rip + 20;
    uint8_t *rbootp = rudp + 8;

    rbootp[0] = 2; rbootp[1] = 1; rbootp[2] = 6;
    memcpy(rbootp + 4, bootp + 4, 4);
    memcpy(rbootp + 10, bootp + 10, 2);
    memcpy(rbootp + 16, MAC_IP, 4);
    memcpy(rbootp + 20, WIN_IP, 4);
    memcpy(rbootp + 28, bootp + 28, 16);

    int o = 236;
    rbootp[o++] = 0x63; rbootp[o++] = 0x82; rbootp[o++] = 0x53; rbootp[o++] = 0x63;
    rbootp[o++] = 53; rbootp[o++] = 1; rbootp[o++] = replyType;
    rbootp[o++] = 54; rbootp[o++] = 4; memcpy(rbootp + o, WIN_IP, 4); o += 4;
    rbootp[o++] = 51; rbootp[o++] = 4; rbootp[o++] = 0; rbootp[o++] = 1; rbootp[o++] = 0x51; rbootp[o++] = 0x80;
    rbootp[o++] = 1;  rbootp[o++] = 4; rbootp[o++] = 255; rbootp[o++] = 255; rbootp[o++] = 255; rbootp[o++] = 0;
    rbootp[o++] = 255;
    int rbootpLen = (o < 300) ? 300 : o;

    uint16_t udpLen = (uint16_t)(8 + rbootpLen);
    uint16_t ipLen  = (uint16_t)(20 + udpLen);
    rip[0] = 0x45; rip[1] = 0x00;
    rip[2] = (uint8_t)(ipLen >> 8); rip[3] = (uint8_t)(ipLen & 0xFF);
    rip[4] = 0x12; rip[5] = 0x34;
    rip[6] = 0x40; rip[7] = 0x00;
    rip[8] = 64;   rip[9] = 17;
    memcpy(rip + 12, WIN_IP, 4);
    if (bcastFlag & 0x8000) memset(rip + 16, 0xFF, 4);
    else memcpy(rip + 16, MAC_IP, 4);
    uint16_t ipCsum = inet_csum(rip, 20, 0);
    rip[10] = (uint8_t)(ipCsum >> 8); rip[11] = (uint8_t)(ipCsum & 0xFF);

    rudp[0] = 0; rudp[1] = 67;
    rudp[2] = 0; rudp[3] = 68;
    rudp[4] = (uint8_t)(udpLen >> 8); rudp[5] = (uint8_t)(udpLen & 0xFF);
    uint32_t pseudo = 17u + udpLen;
    for (int i = 12; i < 20; i += 2) pseudo += ((uint32_t)rip[i] << 8) | rip[i + 1];
    uint16_t uCsum = inet_csum(rudp, udpLen, pseudo);
    if (uCsum == 0) uCsum = 0xFFFF;
    rudp[6] = (uint8_t)(uCsum >> 8); rudp[7] = (uint8_t)(uCsum & 0xFF);

    printf("[DHCP] Sent %s -> %u.%u.%u.%u\n", (replyType == 2) ? "OFFER" : "ACK",
           MAC_IP[0], MAC_IP[1], MAC_IP[2], MAC_IP[3]);
    send_ncm_eth_frame(pkt, (uint16_t)(14 + ipLen));
    return 1;
}

static void handle_eth_frame(const uint8_t *eth, uint16_t len) {
    if (len < 14) return;
    if ((eth[6] & 1) == 0) {
        if (!g_hasPeerMac) {
            memcpy(g_peerMac, eth + 6, 6);
            InterlockedExchange(&g_hasPeerMac, 1);
            printf("[MAC] Learned peer MAC: %02x:%02x:%02x:%02x:%02x:%02x\n",
                   g_peerMac[0], g_peerMac[1], g_peerMac[2], g_peerMac[3], g_peerMac[4], g_peerMac[5]);
        } else {
            memcpy(g_peerMac, eth + 6, 6);
        }
    }

    uint16_t etype = (uint16_t)((eth[12] << 8) | eth[13]);
    if (etype == 0x0806 && len >= 42) {
        uint16_t oper = (uint16_t)((eth[20] << 8) | eth[21]);
        if (oper == 1) {
            const uint8_t *spa = eth + 28;
            const uint8_t *tpa = eth + 38;
            if (memcmp(tpa, WIN_IP, 4) == 0) {
                uint8_t reply[42];
                memcpy(reply + 0, eth + 6, 6);
                memcpy(reply + 6, WIN_MAC, 6);
                reply[12] = 0x08; reply[13] = 0x06;
                memcpy(reply + 14, eth + 14, 6);
                reply[20] = 0x00; reply[21] = 0x02;
                memcpy(reply + 22, WIN_MAC, 6);
                memcpy(reply + 28, WIN_IP, 4);
                memcpy(reply + 32, eth + 22, 6);
                memcpy(reply + 38, spa, 4);
                send_ncm_eth_frame(reply, 42);
            }
        }
        return;
    }

    if (etype == 0x0800 && try_handle_dhcp_v4(eth, len)) {
        return;
    }

    if ((etype == 0x0800 && len >= 34) || (etype == 0x86DD && len >= 54)) {
        DWORD ipLen = (DWORD)(len - 14);
        BYTE *pkt = pWintunAllocateSendPacket(g_session, ipLen);
        if (pkt) {
            memcpy(pkt, eth + 14, ipLen);
            pWintunSendPacket(g_session, pkt);
            InterlockedIncrement64(&g_rxFrames);
        }
    }
}

static DWORD WINAPI usb_rx_thread(LPVOID param) {
    (void)param;
    uint32_t bufCap = g_ntb.dwNtbInMaxSize ? g_ntb.dwNtbInMaxSize : 16384;
    if (bufCap < 16384) bufCap = 16384;
    if (bufCap > 65536) bufCap = 65536;
    uint8_t *buf = (uint8_t*)malloc(bufCap);
    if (!buf) return 1;

    int consecutiveErrs = 0;
    while (g_running) {
        ULONG nread = 0;
        if (!pWinUsb_ReadPipe(g_dataIf, g_epIn, buf, bufCap, &nread, NULL)) {
            DWORD err = GetLastError();
            if (!g_running) break;
            consecutiveErrs++;
            printf("[RX] ReadPipe err=%lu\n", err);
            if (is_usb_disconnect_err(err) || consecutiveErrs >= 3) {
                printf("[USB] Cable disconnected or device lost (RX err=%lu), stopping tunnel...\n", err);
                trigger_shutdown();
                break;
            }
            Sleep(100);
            continue;
        }
        consecutiveErrs = 0;
        if (nread < sizeof(NCM_NTH16)) continue;
        NCM_NTH16 *nth = (NCM_NTH16*)buf;
        if (nth->dwSignature != 0x484D434E) continue;
        uint16_t ndpOff = nth->wNdpIndex;
        while (ndpOff >= sizeof(NCM_NTH16) && (uint32_t)ndpOff + 8 <= nread) {
            uint32_t ndpSig = *(uint32_t*)(buf + ndpOff);
            if (ndpSig != 0x304D434E && ndpSig != 0x314D434E) break;
            uint16_t ndpLen = *(uint16_t*)(buf + ndpOff + 4);
            uint16_t nextNdp = *(uint16_t*)(buf + ndpOff + 6);
            if (ndpLen < 12 || (uint32_t)ndpOff + ndpLen > nread) break;
            int step = (ndpSig == 0x304D434E) ? 4 : 8;
            for (int off = ndpOff + 8; off + 4 <= ndpOff + ndpLen; off += step) {
                uint16_t dIdx = *(uint16_t*)(buf + off);
                uint16_t dLen = *(uint16_t*)(buf + off + 2);
                if (dIdx == 0 && dLen == 0) break;
                if ((uint32_t)dIdx + dLen <= nread && dLen >= 14) {
                    handle_eth_frame(buf + dIdx, dLen);
                }
            }
            ndpOff = nextNdp;
        }
    }
    free(buf);
    return 0;
}

static DWORD WINAPI tun_rx_thread(LPVOID param) {
    (void)param;
    HANDLE ev = pWintunGetReadWaitEvent(g_session);
    const int MAX_BATCH = 20;
    const int SLOT_SZ = 2048;
    uint8_t *pool = (uint8_t*)malloc((size_t)MAX_BATCH * SLOT_SZ);
    if (!pool) return 1;
    const uint8_t *ptrs[20];
    uint16_t lens[20];
    uint32_t maxOut = (g_ntb.dwNtbOutMaxSize >= 2048 && g_ntb.dwNtbOutMaxSize <= 32764) ? g_ntb.dwNtbOutMaxSize : 16384;

    while (g_running) {
        int count = 0;
        uint32_t estBytes = 128;
        while (count < MAX_BATCH) {
            DWORD sz = 0;
            BYTE *pkt = pWintunReceivePacket(g_session, &sz);
            if (!pkt) {
                if (GetLastError() == ERROR_NO_MORE_ITEMS) {
                    if (count == 0) WaitForSingleObject(ev, 200);
                    break;
                }
                free(pool);
                return 0;
            }
            if (sz >= 20 && (int)(sz + 14) <= SLOT_SZ) {
                uint8_t ver = pkt[0] >> 4;
                uint16_t etype = (ver == 4) ? 0x0800 : (ver == 6 ? 0x86DD : 0);
                if (etype) {
                    uint8_t *dst = pool + (size_t)count * SLOT_SZ;
                    memcpy(dst + 0, g_peerMac, 6);
                    memcpy(dst + 6, WIN_MAC, 6);
                    dst[12] = (uint8_t)(etype >> 8);
                    dst[13] = (uint8_t)(etype & 0xFF);
                    memcpy(dst + 14, pkt, sz);
                    ptrs[count] = dst;
                    lens[count] = (uint16_t)(sz + 14);
                    estBytes += (uint32_t)(sz + 14 + 8);
                    count++;
                }
            }
            pWintunReleaseReceivePacket(g_session, pkt);
            if (estBytes + 1600 > maxOut) break;
        }
        if (count > 0) {
            send_ncm_eth_batch(ptrs, lens, count);
        }
    }
    free(pool);
    return 0;
}

static BOOL WINAPI ctrl_handler(DWORD type) {
    (void)type;
    InterlockedExchange(&g_running, 0);
    if (g_stopEvent) SetEvent(g_stopEvent);
    return TRUE;
}

#define LOAD_PROC(dst, mod, sym, type) do { \
    dst = (type)(void*)GetProcAddress((mod), (sym)); \
    if (!(dst)) { printf("[ERR] Missing DLL proc: %s\n", (sym)); rc = 10; goto cleanup; } \
} while (0)

static HMODULE load_wintun_dll(void) {
    char exeDir[MAX_PATH] = {0}, dllPath[512] = {0};
    get_exe_dir(exeDir, sizeof(exeDir));
    snprintf(dllPath, sizeof(dllPath), "%s\\wintun.dll", exeDir);
    HMODULE h = LoadLibraryA(dllPath);
    if (!h) h = LoadLibraryA("C:\\MacBridge\\wintun.dll");
    return h;
}

int main(int argc, char **argv) {
    SetConsoleOutputCP(65001);
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    int pairIdx = 0;
    int waitCable = 1;
    int installOnly = 0;
    int doRestore = 0;
    const char *guidArg = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--pair") == 0 && i + 1 < argc) pairIdx = atoi(argv[++i]);
        else if (strcmp(argv[i], "--guid") == 0 && i + 1 < argc) guidArg = argv[++i];
        else if (strcmp(argv[i], "--no-wait") == 0) waitCable = 0;
        else if (strcmp(argv[i], "--install-only") == 0) installOnly = 1;
        else if (strcmp(argv[i], "--restore") == 0) doRestore = 1;
    }

    int elev = mb_ensure_admin(argc, argv);
    if (elev > 0) return 0;
    if (elev < 0) return 1;

    if (doRestore) {
        return mb_restore_apple_driver();
    }

    printf("============================================================\n");
    printf(" MacBridge One-Click (Auto-Detect + Built-in WinUSB + Wintun)\n");
    printf("============================================================\n");

    int rc = 0;
    HMODULE hWinUsbDll = NULL, hWintunDll = NULL;
    HANDLE hFile = INVALID_HANDLE_VALUE;
    WINUSB_INTERFACE_HANDLE hIfs[8] = {0};
    int totalIfs = 0;
    WINTUN_ADAPTER_HANDLE adap = NULL;
    HANDLE tRx = NULL, tTx = NULL;
    BOOL txLockInit = FALSE;

    g_stopEvent = CreateEventA(NULL, TRUE, FALSE, NULL);
    SetConsoleCtrlHandler(ctrl_handler, TRUE);

    if (!guidArg) {
        if (ensure_apple_winusb(waitCable) != 0) {
            rc = 2;
            goto cleanup;
        }
    }
    if (installOnly) {
        printf("[DONE] Driver setup finished (--install-only).\n");
        rc = 0;
        goto cleanup;
    }

    hWinUsbDll = LoadLibraryA("winusb.dll");
    hWintunDll = load_wintun_dll();
    if (!hWinUsbDll || !hWintunDll) {
        printf("[ERR] Failed to load DLLs: winusb=%p wintun=%p err=%lu\n", (void*)hWinUsbDll, (void*)hWintunDll, GetLastError());
        rc = 1;
        goto cleanup;
    }

    LOAD_PROC(pWinUsb_Initialize, hWinUsbDll, "WinUsb_Initialize", PFN_WinUsb_Initialize);
    LOAD_PROC(pWinUsb_Free, hWinUsbDll, "WinUsb_Free", PFN_WinUsb_Free);
    LOAD_PROC(pWinUsb_GetAssociatedInterface, hWinUsbDll, "WinUsb_GetAssociatedInterface", PFN_WinUsb_GetAssociatedInterface);
    LOAD_PROC(pWinUsb_QueryInterfaceSettings, hWinUsbDll, "WinUsb_QueryInterfaceSettings", PFN_WinUsb_QueryInterfaceSettings);
    LOAD_PROC(pWinUsb_SetCurrentAlternateInterface, hWinUsbDll, "WinUsb_SetCurrentAlternateSetting", PFN_WinUsb_SetCurrentAlternateInterface);
    LOAD_PROC(pWinUsb_QueryPipe, hWinUsbDll, "WinUsb_QueryPipe", PFN_WinUsb_QueryPipe);
    LOAD_PROC(pWinUsb_ControlTransfer, hWinUsbDll, "WinUsb_ControlTransfer", PFN_WinUsb_ControlTransfer);
    LOAD_PROC(pWinUsb_ReadPipe, hWinUsbDll, "WinUsb_ReadPipe", PFN_WinUsb_ReadPipe);
    LOAD_PROC(pWinUsb_WritePipe, hWinUsbDll, "WinUsb_WritePipe", PFN_WinUsb_WritePipe);

    LOAD_PROC(pWintunCreateAdapter, hWintunDll, "WintunCreateAdapter", PFN_WintunCreateAdapter);
    LOAD_PROC(pWintunCloseAdapter, hWintunDll, "WintunCloseAdapter", PFN_WintunCloseAdapter);
    LOAD_PROC(pWintunStartSession, hWintunDll, "WintunStartSession", PFN_WintunStartSession);
    LOAD_PROC(pWintunEndSession, hWintunDll, "WintunEndSession", PFN_WintunEndSession);
    LOAD_PROC(pWintunGetReadWaitEvent, hWintunDll, "WintunGetReadWaitEvent", PFN_WintunGetReadWaitEvent);
    LOAD_PROC(pWintunReceivePacket, hWintunDll, "WintunReceivePacket", PFN_WintunReceivePacket);
    LOAD_PROC(pWintunReleaseReceivePacket, hWintunDll, "WintunReleaseReceivePacket", PFN_WintunReleaseReceivePacket);
    LOAD_PROC(pWintunAllocateSendPacket, hWintunDll, "WintunAllocateSendPacket", PFN_WintunAllocateSendPacket);
    LOAD_PROC(pWintunSendPacket, hWintunDll, "WintunSendPacket", PFN_WintunSendPacket);

    char devPath[1024] = {0};
    for (int retry = 0; retry < 10 && g_running; retry++) {
        if (find_winusb_apple_path(devPath, sizeof(devPath), guidArg)) break;
        if (retry >= 2 && !is_apple_usb_present()) {
            printf("[USB] Cable disconnected before tunnel opened, stopping...\n");
            rc = 2;
            goto cleanup;
        }
        if (g_stopEvent) WaitForSingleObject(g_stopEvent, 500);
        else Sleep(500);
    }
    if (!devPath[0]) {
        printf("[ERR] WinUSB interface path did not appear. Try replugging the USB-C cable.\n");
        rc = 2;
        goto cleanup;
    }
    printf("[USB] Opening: %s\n", devPath);

    hFile = CreateFileA(devPath, GENERIC_WRITE | GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                        NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED, NULL);
    if (hFile == INVALID_HANDLE_VALUE) {
        DWORD err = GetLastError();
        if (is_usb_disconnect_err(err)) {
            printf("[USB] Cable disconnected during tunnel setup (err=%lu), stopping...\n", err);
        } else {
            printf("[ERR] CreateFile failed: %lu (if 5, close any existing MacBridge instance)\n", err);
        }
        rc = 3;
        goto cleanup;
    }

    if (!pWinUsb_Initialize(hFile, &hIfs[0])) {
        DWORD err = GetLastError();
        if (is_usb_disconnect_err(err)) {
            printf("[USB] Cable disconnected during tunnel setup (err=%lu), stopping...\n", err);
        } else {
            printf("[ERR] WinUsb_Initialize failed: %lu\n", err);
        }
        rc = 4;
        goto cleanup;
    }

    totalIfs = 1;
    for (UCHAR a = 0; a < 7; a++) {
        if (pWinUsb_GetAssociatedInterface(hIfs[0], a, &hIfs[a + 1])) totalIfs++;
        else break;
    }

    int ctrlIdx = pairIdx * 2;
    int dataIdx = pairIdx * 2 + 1;
    if (dataIdx >= totalIfs) {
        printf("[ERR] pair %d out of range (totalIfs=%d)\n", pairIdx, totalIfs);
        rc = 5;
        goto cleanup;
    }

    WINUSB_INTERFACE_HANDLE hCtrl = hIfs[ctrlIdx];
    g_dataIf = hIfs[dataIdx];

    WINUSB_SETUP_PACKET sp = {0xA1, 0x80, 0, (USHORT)ctrlIdx, sizeof(g_ntb)};
    ULONG xfer = 0;
    if (pWinUsb_ControlTransfer(hCtrl, sp, (PUCHAR)&g_ntb, sizeof(g_ntb), &xfer, NULL)) {
        printf("[NCM] NTB params: inMax=%u outMax=%u outAlign=%u outDiv=%u maxDgram=%u\n",
               g_ntb.dwNtbInMaxSize, g_ntb.dwNtbOutMaxSize, g_ntb.wNdpOutAlignment,
               g_ntb.wNdpOutDivisor, g_ntb.wNtbOutMaxDatagrams);
    } else {
        g_ntb.dwNtbInMaxSize = 16384;
        g_ntb.dwNtbOutMaxSize = 16384;
        g_ntb.wNdpOutAlignment = 4;
        g_ntb.wNdpOutDivisor = 4;
    }

    uint32_t inMax = (g_ntb.dwNtbInMaxSize > 0 && g_ntb.dwNtbInMaxSize <= 32768) ? g_ntb.dwNtbInMaxSize : 16384;
    WINUSB_SETUP_PACKET spSize = {0x21, 0x86, 0, (USHORT)ctrlIdx, 4};
    pWinUsb_ControlTransfer(hCtrl, spSize, (PUCHAR)&inMax, 4, &xfer, NULL);

    WINUSB_SETUP_PACKET spFilt = {0x21, 0x43, 0x000E, (USHORT)ctrlIdx, 0};
    pWinUsb_ControlTransfer(hCtrl, spFilt, NULL, 0, &xfer, NULL);

    pWinUsb_SetCurrentAlternateInterface(g_dataIf, 0);
    Sleep(200);
    if (!pWinUsb_SetCurrentAlternateInterface(g_dataIf, 1)) {
        DWORD err = GetLastError();
        if (is_usb_disconnect_err(err)) {
            printf("[USB] Cable disconnected during tunnel setup (err=%lu), stopping...\n", err);
        } else {
            printf("[ERR] SetCurrentAlternateSetting(1) failed: %lu\n", err);
        }
        rc = 6;
        goto cleanup;
    }

    USB_INTERFACE_DESCRIPTOR altDesc = {0};
    if (pWinUsb_QueryInterfaceSettings(g_dataIf, 1, &altDesc)) {
        for (UCHAR p = 0; p < altDesc.bNumEndpoints; p++) {
            WINUSB_PIPE_INFORMATION pi = {0};
            if (pWinUsb_QueryPipe(g_dataIf, 1, p, &pi)) {
                if (pi.PipeId & 0x80) g_epIn = pi.PipeId; else g_epOut = pi.PipeId;
            }
        }
    }

    GUID adapGuid = {0x6b3a1201, 0x9c4e, 0x4b12, {0x9a, 0x11, 0x05, 0xac, 0x19, 0x02, 0x00, 0x01}};
    adap = pWintunCreateAdapter(L"MacBridge", L"MacBridge", &adapGuid);
    if (!adap) {
        printf("[ERR] WintunCreateAdapter failed: %lu\n", GetLastError());
        rc = 7;
        goto cleanup;
    }
    g_session = pWintunStartSession(adap, 0x400000);
    if (!g_session) {
        printf("[ERR] WintunStartSession failed: %lu\n", GetLastError());
        rc = 8;
        goto cleanup;
    }

    select_tunnel_subnet(pairIdx);

    char netshCmd[256];
    snprintf(netshCmd, sizeof(netshCmd),
             "netsh interface ip set address name=\"MacBridge\" static %u.%u.%u.%u 255.255.255.0 >nul 2>&1",
             WIN_IP[0], WIN_IP[1], WIN_IP[2], WIN_IP[3]);
    system(netshCmd);
    system("powershell -NoProfile -Command \"Set-NetConnectionProfile -InterfaceAlias 'MacBridge' -NetworkCategory Private -ErrorAction SilentlyContinue\" >nul 2>&1");

    if (!g_running || !is_apple_usb_present()) {
        printf("[USB] Cable disconnected during tunnel setup, stopping...\n");
        rc = 2;
        goto cleanup;
    }

    printf("------------------------------------------------------------\n");
    printf("[READY] Windows IP : %u.%u.%u.%u / 24 (Private profile)\n", WIN_IP[0], WIN_IP[1], WIN_IP[2], WIN_IP[3]);
    printf("[READY] Mac IP     : %u.%u.%u.%u / 24 (Auto via DHCP)\n", MAC_IP[0], MAC_IP[1], MAC_IP[2], MAC_IP[3]);
    printf("[TIP]   Mac Finder Cmd+K -> smb://%u.%u.%u.%u\n", WIN_IP[0], WIN_IP[1], WIN_IP[2], WIN_IP[3]);
    printf("[TIP]   Press Ctrl+C to stop (run MacBridge-Restore.exe to revert driver)\n");
    printf("------------------------------------------------------------\n");
    printf("[OK] Tunnel UP (%u.%u.%u.%u <-> %u.%u.%u.%u)\n",
           WIN_IP[0], WIN_IP[1], WIN_IP[2], WIN_IP[3],
           MAC_IP[0], MAC_IP[1], MAC_IP[2], MAC_IP[3]);

    InitializeCriticalSection(&g_txLock);
    txLockInit = TRUE;
    tRx = CreateThread(NULL, 0, usb_rx_thread, NULL, 0, NULL);
    tTx = CreateThread(NULL, 0, tun_rx_thread, NULL, 0, NULL);

    while (g_running) {
        if (g_stopEvent) WaitForSingleObject(g_stopEvent, 2000);
        else Sleep(2000);
        if (!g_running) break;
        printf("[STAT] RX_frames=%llu TX_frames=%llu peerMAC=%s\n",
               (unsigned long long)InterlockedExchangeAdd64(&g_rxFrames, 0),
               (unsigned long long)InterlockedExchangeAdd64(&g_txFrames, 0),
               g_hasPeerMac ? "learned" : "unknown");
    }

cleanup:
    InterlockedExchange(&g_running, 0);
    if (hFile != INVALID_HANDLE_VALUE) CancelIoEx(hFile, NULL);
    if (g_session && pWintunGetReadWaitEvent) {
        HANDLE tunEv = pWintunGetReadWaitEvent(g_session);
        if (tunEv) SetEvent(tunEv);
    }
    if (tRx) { WaitForSingleObject(tRx, 3000); CloseHandle(tRx); }
    if (tTx) { WaitForSingleObject(tTx, 3000); CloseHandle(tTx); }
    if (g_session && pWintunEndSession) { pWintunEndSession(g_session); g_session = NULL; }
    if (adap && pWintunCloseAdapter) { pWintunCloseAdapter(adap); adap = NULL; }
    if (txLockInit) DeleteCriticalSection(&g_txLock);
    if (pWinUsb_Free) {
        for (int i = totalIfs - 1; i >= 0; i--) {
            if (hIfs[i]) pWinUsb_Free(hIfs[i]);
        }
    }
    if (hFile != INVALID_HANDLE_VALUE) CloseHandle(hFile);
    if (g_stopEvent) { CloseHandle(g_stopEvent); g_stopEvent = NULL; }
    if (hWintunDll) FreeLibrary(hWintunDll);
    if (hWinUsbDll) FreeLibrary(hWinUsbDll);
    return rc;
}
