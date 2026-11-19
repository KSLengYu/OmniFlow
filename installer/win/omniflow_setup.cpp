#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <shellapi.h>
#include <setupapi.h>
#include <winhttp.h>
#include <gdiplus.h>
#include <objbase.h>

#include <string>
#include <vector>
#include <atomic>
#include <cstdio>

#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "uuid.lib")

#ifndef DWMWA_USE_IMMUTABLE_DARK_MODE
#define DWMWA_USE_IMMUTABLE_DARK_MODE 20
#endif

static const int IDR_MANIFEST_ID = 1;
static const int IDI_APP_ICON    = 101;
static const int IDR_AVATAR_JPG  = 102;
static const int IDR_PAYLOAD_CAB = 103;

static const wchar_t* GITHUB_URL = L"https://github.com/KSLengYu";
static const wchar_t* DOTNET10_DL_URL = L"https://dotnet.microsoft.com/en-us/download/dotnet/10.0";

enum CtrlId {
    IDC_PATH_EDIT = 1001,
    IDC_BROWSE_BTN = 1002,
    IDC_CHK_DESKTOP = 1003,
    IDC_CHK_LAUNCH = 1004,
    IDC_PROGRESS = 1005,
    IDC_INSTALL_BTN = 1006,
    IDC_DOTNET_BTN = 1007
};

static const UINT WM_GITHUB_SYNCED = WM_APP + 1;
static const UINT WM_INSTALL_PROGRESS = WM_APP + 2;
static const UINT WM_INSTALL_DONE = WM_APP + 3;

struct AppState {
    HWND hwnd = nullptr;
    HWND pathEdit = nullptr;
    HWND browseBtn = nullptr;
    HWND chkDesktop = nullptr;
    HWND chkLaunch = nullptr;
    HWND progressBar = nullptr;
    HWND installBtn = nullptr;
    HWND dotnetBtn = nullptr;

    HFONT fontTitle = nullptr;
    HFONT fontSub = nullptr;
    HFONT fontBold = nullptr;
    HFONT fontNormal = nullptr;
    HFONT fontMono = nullptr;

    HBRUSH brBg = nullptr;
    HBRUSH brCard = nullptr;
    HBRUSH brEdit = nullptr;

    Gdiplus::Image* avatarImg = nullptr;
    Gdiplus::Image* appIconImg = nullptr;

    bool isEnglish = false;
    bool dotnetReady = false;
    bool installing = false;
    bool installedOk = false;
    bool launchOnExit = true;
    bool createDesktopShortcut = true;
    int dpi = 96;

    std::wstring authorName = L"\u695E\u5B87"; // "楞宇"
    std::wstring authorHandle = L"@KSLengYu";
    std::wstring statusText;
    std::wstring installDir;

    RECT rcLangZh{};
    RECT rcLangEn{};
    RECT rcAuthorCard{};
    bool hoverAuthor = false;
};

static AppState g;

static inline int S(int px) {
    return MulDiv(px, g.dpi, 96);
}

static void ClearThemeForDarkText(HWND ctrl) {
    HMODULE hUx = LoadLibraryW(L"uxtheme.dll");
    if (!hUx) return;
    typedef HRESULT(WINAPI* PFN_SetWindowTheme)(HWND, LPCWSTR, LPCWSTR);
    if (auto fn = (PFN_SetWindowTheme)GetProcAddress(hUx, "SetWindowTheme")) {
        fn(ctrl, L"", L"");
    }
    FreeLibrary(hUx);
}

static inline std::wstring T(const wchar_t* zh, const wchar_t* en) {
    return g.isEnglish ? std::wstring(en) : std::wstring(zh);
}

static void EnableDarkTitleBar(HWND hwnd) {
    HMODULE hDwm = LoadLibraryW(L"dwmapi.dll");
    if (!hDwm) return;
    typedef HRESULT(WINAPI* PFN_DwmSetWindowAttribute)(HWND, DWORD, LPCVOID, DWORD);
    auto fn = (PFN_DwmSetWindowAttribute)GetProcAddress(hDwm, "DwmSetWindowAttribute");
    if (fn) {
        BOOL val = TRUE;
        fn(hwnd, DWMWA_USE_IMMUTABLE_DARK_MODE, &val, sizeof(val));
    }
    FreeLibrary(hDwm);
}

static Gdiplus::Image* LoadImageFromResource(int resId, const wchar_t* resType) {
    HRSRC hr = FindResourceW(nullptr, MAKEINTRESOURCEW(resId), resType);
    if (!hr) return nullptr;
    DWORD sz = SizeofResource(nullptr, hr);
    HGLOBAL hg = LoadResource(nullptr, hr);
    if (!hg || sz == 0) return nullptr;
    void* ptr = LockResource(hg);
    if (!ptr) return nullptr;

    HGLOBAL copyMem = GlobalAlloc(GMEM_MOVEABLE, sz);
    if (!copyMem) return nullptr;
    void* dst = GlobalLock(copyMem);
    if (dst) {
        memcpy(dst, ptr, sz);
        GlobalUnlock(copyMem);
    }
    IStream* stream = nullptr;
    if (CreateStreamOnHGlobal(copyMem, TRUE, &stream) != S_OK || !stream) {
        GlobalFree(copyMem);
        return nullptr;
    }
    Gdiplus::Image* img = Gdiplus::Image::FromStream(stream);
    stream->Release();
    return img;
}

static bool CheckDotNet10DesktopRuntime() {
    wchar_t progFiles[MAX_PATH]{};
    if (SHGetFolderPathW(nullptr, CSIDL_PROGRAM_FILES, nullptr, 0, progFiles) != S_OK)
        wcscpy_s(progFiles, L"C:\\Program Files");

    std::wstring searchDir = std::wstring(progFiles) + L"\\dotnet\\shared\\Microsoft.WindowsDesktop.App\\10.*";
    WIN32_FIND_DATAW fd{};
    HANDLE h = FindFirstFileW(searchDir.c_str(), &fd);
    if (h != INVALID_HANDLE_VALUE) {
        FindClose(h);
        return true;
    }

    // Also check dotnet --list-runtimes fallback via registry or environment
    wchar_t dotnetRoot[MAX_PATH]{};
    DWORD n = GetEnvironmentVariableW(L"DOTNET_ROOT", dotnetRoot, MAX_PATH);
    if (n > 0 && n < MAX_PATH) {
        std::wstring customDir = std::wstring(dotnetRoot) + L"\\shared\\Microsoft.WindowsDesktop.App\\10.*";
        h = FindFirstFileW(customDir.c_str(), &fd);
        if (h != INVALID_HANDLE_VALUE) {
            FindClose(h);
            return true;
        }
    }
    return false;
}

static DWORD WINAPI GitHubSyncThread(LPVOID) {
    HINTERNET hSession = WinHttpOpen(L"OmniFlow-Setup/1.0", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!hSession) return 0;
    WinHttpSetTimeouts(hSession, 2500, 2500, 2500, 2500);

    HINTERNET hConn = WinHttpConnect(hSession, L"api.github.com", INTERNET_DEFAULT_HTTPS_PORT, 0);
    if (hConn) {
        HINTERNET hReq = WinHttpOpenRequest(hConn, L"GET", L"/users/KSLengYu", nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
        if (hReq) {
            LPCWSTR hdrs = L"Accept: application/vnd.github+json\r\n";
            if (WinHttpSendRequest(hReq, hdrs, (DWORD)-1L, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) &&
                WinHttpReceiveResponse(hReq, nullptr)) {
                DWORD status = 0, ssz = sizeof(status);
                WinHttpQueryHeaders(hReq, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, nullptr, &status, &ssz, nullptr);
                if (status >= 200 && status < 300) {
                    std::string body;
                    char buf[2048];
                    DWORD avail = 0, readBytes = 0;
                    while (WinHttpQueryDataAvailable(hReq, &avail) && avail > 0) {
                        DWORD chunk = avail < sizeof(buf) ? avail : (DWORD)sizeof(buf);
                        if (!WinHttpReadData(hReq, buf, chunk, &readBytes) || readBytes == 0) break;
                        body.append(buf, readBytes);
                    }
                    // Extract "name":"..." field simply & safely
                    size_t pos = body.find("\"name\"");
                    if (pos != std::string::npos) {
                        size_t colon = body.find(':', pos + 6);
                        if (colon != std::string::npos) {
                            size_t q1 = body.find('"', colon);
                            size_t nullPos = body.find("null", colon);
                            if (q1 != std::string::npos && (nullPos == std::string::npos || q1 < nullPos)) {
                                std::string raw;
                                for (size_t i = q1 + 1; i < body.size(); ++i) {
                                    if (body[i] == '"' && body[i - 1] != '\\') break;
                                    if (body[i] == '\\' && i + 5 < body.size() && body[i + 1] == 'u') {
                                        unsigned int cp = 0;
                                        if (sscanf(body.c_str() + i + 2, "%4x", &cp) == 1) {
                                            wchar_t wc = (wchar_t)cp;
                                            char utf8[4]{};
                                            int ulen = WideCharToMultiByte(CP_UTF8, 0, &wc, 1, utf8, sizeof(utf8), nullptr, nullptr);
                                            raw.append(utf8, ulen);
                                            i += 5;
                                            continue;
                                        }
                                    }
                                    raw.push_back(body[i]);
                                }
                                if (!raw.empty()) {
                                    int wlen = MultiByteToWideChar(CP_UTF8, 0, raw.c_str(), (int)raw.size(), nullptr, 0);
                                    if (wlen > 0) {
                                        std::wstring* synced = new std::wstring(wlen, L'\0');
                                        MultiByteToWideChar(CP_UTF8, 0, raw.c_str(), (int)raw.size(), &(*synced)[0], wlen);
                                        PostMessageW(g.hwnd, WM_GITHUB_SYNCED, 0, (LPARAM)synced);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            WinHttpCloseHandle(hReq);
        }
        WinHttpCloseHandle(hConn);
    }
    WinHttpCloseHandle(hSession);
    return 0;
}

static bool CreateShortcutLnk(const std::wstring& lnkPath, const std::wstring& targetExe, const std::wstring& args, const std::wstring& workDir, const std::wstring& desc) {
    IShellLinkW* psl = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_IShellLinkW, (void**)&psl);
    if (FAILED(hr) || !psl) return false;

    psl->SetPath(targetExe.c_str());
    if (!args.empty()) psl->SetArguments(args.c_str());
    psl->SetWorkingDirectory(workDir.c_str());
    psl->SetDescription(desc.c_str());
    psl->SetIconLocation(targetExe.c_str(), 0);

    IPersistFile* ppf = nullptr;
    bool ok = false;
    if (SUCCEEDED(psl->QueryInterface(IID_IPersistFile, (void**)&ppf)) && ppf) {
        ok = SUCCEEDED(ppf->Save(lnkPath.c_str(), TRUE));
        ppf->Release();
    }
    psl->Release();
    return ok;
}

static void EnsureDirectoryRecursive(const std::wstring& dir) {
    SHCreateDirectoryExW(nullptr, dir.c_str(), nullptr);
}

struct CabCtx {
    std::wstring destDir;
    int count = 0;
};

static UINT CALLBACK CabNotifyCallback(PVOID context, UINT notification, UINT_PTR param1, UINT_PTR param2) {
    CabCtx* ctx = (CabCtx*)context;
    if (notification == SPFILENOTIFY_FILEINCABINET) {
        auto* info = (FILE_IN_CABINET_INFO_W*)param1;
        std::wstring target = ctx->destDir + L"\\" + info->NameInCabinet;
        wcscpy_s(info->FullTargetName, MAX_PATH, target.c_str());
        ctx->count++;
        int pct = 30 + (ctx->count * 7);
        if (pct > 82) pct = 82;
        PostMessageW(g.hwnd, WM_INSTALL_PROGRESS, (WPARAM)pct, 0);
        return FILEOP_DOIT;
    }
    return NO_ERROR;
}

static bool ExtractCabToDir(const std::wstring& destDir, bool postProgress) {
    HRSRC hr = FindResourceW(nullptr, MAKEINTRESOURCEW(IDR_PAYLOAD_CAB), RT_RCDATA);
    if (!hr) return false;
    DWORD cabSz = SizeofResource(nullptr, hr);
    HGLOBAL hg = LoadResource(nullptr, hr);
    void* cabPtr = hg ? LockResource(hg) : nullptr;
    if (!cabPtr || cabSz == 0) return false;

    wchar_t tempDir[MAX_PATH]{};
    GetTempPathW(MAX_PATH, tempDir);
    wchar_t tempCab[MAX_PATH]{};
    swprintf_s(tempCab, L"%somniflow_setup_%lu.cab", tempDir, GetCurrentProcessId());

    HANDLE hFile = CreateFileW(tempCab, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (hFile == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    WriteFile(hFile, cabPtr, cabSz, &written, nullptr);
    CloseHandle(hFile);

    CabCtx ctx{ destDir, 0 };
    BOOL cabOk = SetupIterateCabinetW(tempCab, 0, postProgress ? CabNotifyCallback : [](PVOID c, UINT n, UINT_PTR p1, UINT_PTR) -> UINT {
        if (n == SPFILENOTIFY_FILEINCABINET) {
            auto* ctx2 = (CabCtx*)c;
            auto* info = (FILE_IN_CABINET_INFO_W*)p1;
            wcscpy_s(info->FullTargetName, MAX_PATH, (ctx2->destDir + L"\\" + info->NameInCabinet).c_str());
            ctx2->count++;
            return FILEOP_DOIT;
        }
        return NO_ERROR;
    }, &ctx);
    DeleteFileW(tempCab);
    return cabOk && ctx.count > 0;
}

static DWORD WINAPI InstallWorkerThread(LPVOID param) {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    std::wstring* pDir = (std::wstring*)param;
    std::wstring destDir = *pDir;
    delete pDir;

    auto reportFail = [](const std::wstring& msg) {
        PostMessageW(g.hwnd, WM_INSTALL_DONE, 0, (LPARAM)(new std::wstring(msg)));
    };

    // 1. Stop any running OmniFlow instances cleanly
    PostMessageW(g.hwnd, WM_INSTALL_PROGRESS, 12, 0);
    {
        STARTUPINFOW si{};
        PROCESS_INFORMATION pi{};
        si.cb = sizeof(si);
        si.dwFlags = STARTF_USESHOWWINDOW;
        si.wShowWindow = SW_HIDE;
        wchar_t cmd[] = L"taskkill.exe /IM OmniFlow.exe /F";
        if (CreateProcessW(nullptr, cmd, nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
            WaitForSingleObject(pi.hProcess, 2500);
            CloseHandle(pi.hProcess);
            CloseHandle(pi.hThread);
        }
        wchar_t cmd2[] = L"taskkill.exe /IM omniflow-usb.exe /F";
        if (CreateProcessW(nullptr, cmd2, nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
            WaitForSingleObject(pi.hProcess, 2000);
            CloseHandle(pi.hProcess);
            CloseHandle(pi.hThread);
        }
        Sleep(250);
    }

    // 2. Ensure directory
    EnsureDirectoryRecursive(destDir);
    if (GetFileAttributesW(destDir.c_str()) == INVALID_FILE_ATTRIBUTES) {
        reportFail(T(L"\u65E0\u6CD5\u521B\u5EFA\u5B89\u88C5\u76EE\u5F55", L"Failed to create target directory."));
        CoUninitialize();
        return 0;
    }

    // 3. Extract embedded LZX CAB payload using Windows SetupAPI
    PostMessageW(g.hwnd, WM_INSTALL_PROGRESS, 22, 0);
    if (!ExtractCabToDir(destDir, true)) {
        reportFail(T(L"\u89E3\u538B\u5B89\u88C5\u6587\u4EF6\u5931\u8D25\uFF0C\u8BF7\u68C0\u67E5\u76EE\u5F55\u6743\u9650", L"Failed to extract files. Check directory permissions."));
        CoUninitialize();
        return 0;
    }

    // 4. Copy self as Uninstall binary & register Apps & Features entry
    PostMessageW(g.hwnd, WM_INSTALL_PROGRESS, 88, 0);
    wchar_t selfExe[MAX_PATH]{};
    GetModuleFileNameW(nullptr, selfExe, MAX_PATH);
    std::wstring uninstExe = destDir + L"\\OmniFlow-Uninstall.exe";
    CopyFileW(selfExe, uninstExe.c_str(), FALSE);

    std::wstring appExe = destDir + L"\\OmniFlow.exe";
    std::wstring uninstCmd = L"\"" + uninstExe + L"\" --uninstall \"" + destDir + L"\"";

    HKEY hKey = nullptr;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\OmniFlow",
                        0, nullptr, 0, KEY_WRITE, nullptr, &hKey, nullptr) == ERROR_SUCCESS) {
        auto setReg = [&](const wchar_t* name, const std::wstring& val) {
            RegSetValueExW(hKey, name, 0, REG_SZ, (const BYTE*)val.c_str(), (DWORD)((val.size() + 1) * sizeof(wchar_t)));
        };
        setReg(L"DisplayName", L"OmniFlow");
        setReg(L"DisplayVersion", L"1.0.0");
        setReg(L"Publisher", g.authorName + L" (@KSLengYu)");
        setReg(L"URLInfoAbout", GITHUB_URL);
        setReg(L"DisplayIcon", appExe);
        setReg(L"InstallLocation", destDir);
        setReg(L"UninstallString", uninstCmd);
        DWORD noModify = 1;
        RegSetValueExW(hKey, L"NoModify", 0, REG_DWORD, (const BYTE*)&noModify, sizeof(noModify));
        RegSetValueExW(hKey, L"NoRepair", 0, REG_DWORD, (const BYTE*)&noModify, sizeof(noModify));
        RegCloseKey(hKey);
    }

    // 5. Create Start Menu & optional Desktop shortcuts
    PostMessageW(g.hwnd, WM_INSTALL_PROGRESS, 94, 0);
    wchar_t programsPath[MAX_PATH]{};
    if (SHGetFolderPathW(nullptr, CSIDL_PROGRAMS, nullptr, 0, programsPath) == S_OK) {
        std::wstring smDir = std::wstring(programsPath) + L"\\OmniFlow";
        EnsureDirectoryRecursive(smDir);
        CreateShortcutLnk(smDir + L"\\OmniFlow.lnk", appExe, L"", destDir, L"OmniFlow Cross-OS Flow");
        CreateShortcutLnk(smDir + L"\\Uninstall OmniFlow.lnk", uninstExe, L"--uninstall \"" + destDir + L"\"", destDir, L"Uninstall OmniFlow");
    }

    if (g.createDesktopShortcut) {
        wchar_t deskPath[MAX_PATH]{};
        if (SHGetFolderPathW(nullptr, CSIDL_DESKTOPDIRECTORY, nullptr, 0, deskPath) == S_OK) {
            CreateShortcutLnk(std::wstring(deskPath) + L"\\OmniFlow.lnk", appExe, L"", destDir, L"OmniFlow Cross-OS Flow");
        }
    }

    PostMessageW(g.hwnd, WM_INSTALL_PROGRESS, 100, 0);
    PostMessageW(g.hwnd, WM_INSTALL_DONE, 1, 0);
    CoUninitialize();
    return 0;
}

static void RefreshUiLanguageStrings() {
    if (!g.hwnd) return;
    SetWindowTextW(g.hwnd, T(L"OmniFlow \u5B89\u88C5\u7A0B\u5E8F", L"OmniFlow Setup").c_str());
    SetWindowTextW(g.browseBtn, T(L"\u6D4F\u89C8...", L"Browse...").c_str());
    SetWindowTextW(g.chkDesktop, T(L"\u521B\u5EFA\u684C\u9762\u5FEB\u6377\u65B9\u5F0F", L"Create Desktop shortcut").c_str());
    SetWindowTextW(g.chkLaunch, T(L"\u5B89\u88C5\u540E\u7ACB\u5373\u542F\u52A8 OmniFlow", L"Launch OmniFlow after installation").c_str());

    if (g.installedOk) {
        SetWindowTextW(g.installBtn, T(L"\u5B8C\u6210", L"Finish").c_str());
    } else if (g.installing) {
        SetWindowTextW(g.installBtn, T(L"\u6B63\u5728\u5B89\u88C5...", L"Installing...").c_str());
    } else {
        SetWindowTextW(g.installBtn, T(L"\u7ACB\u5373\u5B89\u88C5", L"Install OmniFlow").c_str());
    }

    if (!g.dotnetReady && g.dotnetBtn) {
        SetWindowTextW(g.dotnetBtn, T(L"\u4E0B\u8F7D .NET 10", L"Get .NET 10").c_str());
    }
    InvalidateRect(g.hwnd, nullptr, TRUE);
}

static void DrawGitHubOctocat(Gdiplus::Graphics& gfx, float x, float y, float sz, Gdiplus::Color col) {
    // Simple stylized Octocat head+ears silhouette on 24x24 normalized grid + smile accent
    Gdiplus::SolidBrush br(col);
    Gdiplus::GraphicsPath circlePath;
    circlePath.AddEllipse(x, y, sz, sz);
    gfx.FillPath(&br, &circlePath);

    Gdiplus::SolidBrush inner(Gdiplus::Color(255, 0x22, 0x23, 0x28));
    Gdiplus::PointF head[8] = {
        {x + sz * 0.25f, y + sz * 0.30f},
        {x + sz * 0.36f, y + sz * 0.20f},
        {x + sz * 0.44f, y + sz * 0.30f},
        {x + sz * 0.56f, y + sz * 0.30f},
        {x + sz * 0.64f, y + sz * 0.20f},
        {x + sz * 0.75f, y + sz * 0.30f},
        {x + sz * 0.78f, y + sz * 0.65f},
        {x + sz * 0.22f, y + sz * 0.65f}
    };
    gfx.FillPolygon(&inner, head, 8);
    gfx.FillEllipse(&inner, x + sz * 0.22f, y + sz * 0.34f, sz * 0.56f, sz * 0.38f);
    gfx.FillRectangle(&inner, x + sz * 0.40f, y + sz * 0.66f, sz * 0.20f, sz * 0.30f);
}

static void PaintWindow(HWND hwnd) {
    PAINTSTRUCT ps{};
    HDC hdc = BeginPaint(hwnd, &ps);
    RECT rc{};
    GetClientRect(hwnd, &rc);

    HDC memDc = CreateCompatibleDC(hdc);
    HBITMAP memBmp = CreateCompatibleBitmap(hdc, rc.right, rc.bottom);
    HGDIOBJ oldBmp = SelectObject(memDc, memBmp);

    FillRect(memDc, &rc, g.brBg);

    Gdiplus::Graphics gfx(memDc);
    gfx.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    gfx.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
    SetBkMode(memDc, TRANSPARENT);

    // Top Header
    if (g.appIconImg) {
        gfx.DrawImage(g.appIconImg, S(24), S(20), S(40), S(40));
    }

    SelectObject(memDc, g.fontTitle);
    SetTextColor(memDc, RGB(255, 255, 255));
    RECT rcTitle{ S(76), S(18), S(390), S(44) };
    DrawTextW(memDc, L"OmniFlow Installer", -1, &rcTitle, DT_LEFT | DT_VCENTER | DT_SINGLELINE);

    SelectObject(memDc, g.fontSub);
    SetTextColor(memDc, RGB(166, 166, 174));
    RECT rcSub{ S(76), S(42), S(400), S(62) };
    std::wstring sub = T(L"\u8DE8\u8BBE\u5907\u952E\u9F20\u4E0E\u6587\u4EF6\u65E0\u7F1D\u534F\u540C (Windows x64)", L"Cross-Device KVM & File Portal (Windows x64)");
    DrawTextW(memDc, sub.c_str(), -1, &rcSub, DT_LEFT | DT_VCENTER | DT_SINGLELINE);

    // Language Pill (中 | EN) top-right
    g.rcLangZh = { rc.right - S(92), S(24), rc.right - S(58), S(48) };
    g.rcLangEn = { rc.right - S(56), S(24), rc.right - S(24), S(48) };
    {
        Gdiplus::SolidBrush brPillBg(Gdiplus::Color(255, 0x25, 0x25, 0x2A));
        Gdiplus::Pen penPill(Gdiplus::Color(255, 0x3C, 0x3C, 0x42), 1.0f);
        gfx.FillRectangle(&brPillBg, (INT)(rc.right - S(94)), S(22), S(72), S(28));
        gfx.DrawRectangle(&penPill, (INT)(rc.right - S(94)), S(22), S(72), S(28));

        Gdiplus::SolidBrush brActive(Gdiplus::Color(255, 0x0A, 0x84, 0xFF));
        RECT activeR = g.isEnglish ? g.rcLangEn : g.rcLangZh;
        gfx.FillRectangle(&brActive, (INT)activeR.left, (INT)activeR.top, (INT)(activeR.right - activeR.left), (INT)(activeR.bottom - activeR.top));

        SelectObject(memDc, g.fontBold);
        SetTextColor(memDc, g.isEnglish ? RGB(170, 170, 176) : RGB(255, 255, 255));
        DrawTextW(memDc, L"\u4E2D", -1, &g.rcLangZh, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        SetTextColor(memDc, g.isEnglish ? RGB(255, 255, 255) : RGB(170, 170, 176));
        DrawTextW(memDc, L"EN", -1, &g.rcLangEn, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    }

    // Author GitHub Card (Circular Avatar + Octocat Icon + Synced Display Name + Clickable Link)
    g.rcAuthorCard = { S(24), S(74), rc.right - S(24), S(140) };
    {
        Gdiplus::Color cardBg = g.hoverAuthor ? Gdiplus::Color(255, 0x28, 0x2B, 0x34) : Gdiplus::Color(255, 0x22, 0x23, 0x28);
        Gdiplus::Color cardBd = g.hoverAuthor ? Gdiplus::Color(255, 0x64, 0xD2, 0xFF) : Gdiplus::Color(255, 0x34, 0x35, 0x3D);
        Gdiplus::SolidBrush brCard(cardBg);
        Gdiplus::Pen penCard(cardBd, 1.0f);
        gfx.FillRectangle(&brCard, (INT)g.rcAuthorCard.left, (INT)g.rcAuthorCard.top,
                           (INT)(g.rcAuthorCard.right - g.rcAuthorCard.left), (INT)(g.rcAuthorCard.bottom - g.rcAuthorCard.top));
        gfx.DrawRectangle(&penCard, (INT)g.rcAuthorCard.left, (INT)g.rcAuthorCard.top,
                          (INT)(g.rcAuthorCard.right - g.rcAuthorCard.left), (INT)(g.rcAuthorCard.bottom - g.rcAuthorCard.top));

        // Circular Avatar
        Gdiplus::Rect avRect(S(38), S(85), S(44), S(44));
        if (g.avatarImg) {
            Gdiplus::GraphicsState st = gfx.Save();
            Gdiplus::GraphicsPath clip;
            clip.AddEllipse(avRect);
            gfx.SetClip(&clip);
            gfx.DrawImage(g.avatarImg, avRect);
            gfx.Restore(st);
        }
        Gdiplus::Pen avRing(Gdiplus::Color(220, 0x64, 0xD2, 0xFF), 1.6f);
        gfx.DrawEllipse(&avRing, avRect);

        // Tiny Octocat mark next to Name
        DrawGitHubOctocat(gfx, (float)S(94), (float)S(89), (float)S(15), Gdiplus::Color(255, 255, 255, 255));

        SelectObject(memDc, g.fontBold);
        SetTextColor(memDc, RGB(255, 255, 255));
        RECT rcName{ S(115), S(86), rc.right - S(130), S(108) };
        DrawTextW(memDc, g.authorName.c_str(), -1, &rcName, DT_LEFT | DT_VCENTER | DT_SINGLELINE);

        SelectObject(memDc, g.fontMono);
        SetTextColor(memDc, RGB(100, 210, 255));
        RECT rcHandle{ S(94), S(108), rc.right - S(90), S(128) };
        std::wstring line2 = g.authorHandle + L"  ·  https://github.com/KSLengYu";
        DrawTextW(memDc, line2.c_str(), -1, &rcHandle, DT_LEFT | DT_VCENTER | DT_SINGLELINE);

        SelectObject(memDc, g.fontNormal);
        SetTextColor(memDc, RGB(165, 165, 175));
        RECT rcArrow{ rc.right - S(96), S(86), rc.right - S(36), S(128) };
        DrawTextW(memDc, T(L"\u4E3B\u9875 \u2197", L"GitHub \u2197").c_str(), -1, &rcArrow, DT_RIGHT | DT_VCENTER | DT_SINGLELINE);
    }

    // Install Folder Label + Runtime Check Badge
    SelectObject(memDc, g.fontBold);
    SetTextColor(memDc, RGB(230, 230, 235));
    RECT rcDirLbl{ S(24), S(156), S(280), S(176) };
    DrawTextW(memDc, T(L"\u5B89\u88C5\u76EE\u5F55", L"Install Location").c_str(), -1, &rcDirLbl, DT_LEFT | DT_VCENTER | DT_SINGLELINE);

    // .NET 10 Status Text
    SelectObject(memDc, g.fontNormal);
    SetTextColor(memDc, g.dotnetReady ? RGB(48, 209, 88) : RGB(255, 159, 10));
    RECT rcDotNet{ S(260), S(156), g.dotnetReady ? (rc.right - S(24)) : (rc.right - S(118)), S(176) };
    std::wstring dnText = g.dotnetReady
        ? T(L"\u2713 .NET 10 \u684C\u9762\u8FD0\u884C\u65F6\u5DF2\u5C31\u7EEA", L"\u2713 .NET 10 Desktop Runtime Ready")
        : T(L"\u26A0 \u9700 .NET 10 \u8FD0\u884C\u65F6", L"\u26A0 Needs .NET 10 Runtime");
    DrawTextW(memDc, dnText.c_str(), -1, &rcDotNet, DT_RIGHT | DT_VCENTER | DT_SINGLELINE);

    // Status message above bottom buttons
    if (!g.statusText.empty()) {
        SelectObject(memDc, g.fontNormal);
        SetTextColor(memDc, g.installedOk ? RGB(48, 209, 88) : RGB(195, 195, 205));
        RECT rcStat{ S(24), S(294), rc.right - S(24), S(316) };
        DrawTextW(memDc, g.statusText.c_str(), -1, &rcStat, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
    }

    BitBlt(hdc, 0, 0, rc.right, rc.bottom, memDc, 0, 0, SRCCOPY);
    SelectObject(memDc, oldBmp);
    DeleteObject(memBmp);
    DeleteDC(memDc);
    EndPaint(hwnd, &ps);
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_CREATE: {
        EnableDarkTitleBar(hwnd);
        g.hwnd = hwnd;

        g.fontTitle = CreateFontW(-S(19), 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
        g.fontSub = CreateFontW(-S(12), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Microsoft YaHei UI");
        g.fontBold = CreateFontW(-S(12), 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Microsoft YaHei UI");
        g.fontNormal = CreateFontW(-S(12), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Microsoft YaHei UI");
        g.fontMono = CreateFontW(-S(11), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Consolas");

        g.brBg = CreateSolidBrush(RGB(0x18, 0x18, 0x1B));
        g.brCard = CreateSolidBrush(RGB(0x22, 0x23, 0x28));
        g.brEdit = CreateSolidBrush(RGB(0x24, 0x24, 0x2A));

        g.avatarImg = LoadImageFromResource(IDR_AVATAR_JPG, RT_RCDATA);
        HICON hIco = (HICON)LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON, S(48), S(48), 0);
        if (hIco) {
            g.appIconImg = Gdiplus::Bitmap::FromHICON(hIco);
            SendMessageW(hwnd, WM_SETICON, ICON_BIG, (LPARAM)hIco);
            SendMessageW(hwnd, WM_SETICON, ICON_SMALL, (LPARAM)hIco);
        }

        LANGID lang = GetUserDefaultUILanguage();
        g.isEnglish = ((lang & 0x3FF) != LANG_CHINESE);
        g.dotnetReady = CheckDotNet10DesktopRuntime();

        // Default install dir: C:\OmniFlow if writable/present else %LocalAppData%\Programs\OmniFlow
        wchar_t localApp[MAX_PATH]{};
        if (GetFileAttributesW(L"C:\\OmniFlow\\OmniFlow.exe") != INVALID_FILE_ATTRIBUTES) {
            g.installDir = L"C:\\OmniFlow";
        } else if (SHGetFolderPathW(nullptr, CSIDL_LOCAL_APPDATA, nullptr, 0, localApp) == S_OK) {
            g.installDir = std::wstring(localApp) + L"\\Programs\\OmniFlow";
        } else {
            g.installDir = L"C:\\OmniFlow";
        }

        g.pathEdit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", g.installDir.c_str(),
                                     WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL,
                                     S(24), S(182), S(390), S(28), hwnd, (HMENU)IDC_PATH_EDIT, nullptr, nullptr);
        SendMessageW(g.pathEdit, WM_SETFONT, (WPARAM)g.fontNormal, TRUE);

        g.browseBtn = CreateWindowW(L"BUTTON", L"...", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                                    S(422), S(182), S(74), S(28), hwnd, (HMENU)IDC_BROWSE_BTN, nullptr, nullptr);
        SendMessageW(g.browseBtn, WM_SETFONT, (WPARAM)g.fontNormal, TRUE);

        g.chkDesktop = CreateWindowW(L"BUTTON", L"", WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX,
                                     S(24), S(224), S(300), S(24), hwnd, (HMENU)IDC_CHK_DESKTOP, nullptr, nullptr);
        ClearThemeForDarkText(g.chkDesktop);
        SendMessageW(g.chkDesktop, WM_SETFONT, (WPARAM)g.fontNormal, TRUE);
        SendMessageW(g.chkDesktop, BM_SETCHECK, BST_CHECKED, 0);

        g.chkLaunch = CreateWindowW(L"BUTTON", L"", WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX,
                                    S(24), S(252), S(320), S(24), hwnd, (HMENU)IDC_CHK_LAUNCH, nullptr, nullptr);
        ClearThemeForDarkText(g.chkLaunch);
        SendMessageW(g.chkLaunch, WM_SETFONT, (WPARAM)g.fontNormal, TRUE);
        SendMessageW(g.chkLaunch, BM_SETCHECK, BST_CHECKED, 0);

        if (!g.dotnetReady) {
            g.dotnetBtn = CreateWindowW(L"BUTTON", L"Get .NET 10", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                                        S(406), S(152), S(90), S(24), hwnd, (HMENU)IDC_DOTNET_BTN, nullptr, nullptr);
            SendMessageW(g.dotnetBtn, WM_SETFONT, (WPARAM)g.fontNormal, TRUE);
        }

        g.progressBar = CreateWindowW(PROGRESS_CLASSW, nullptr, WS_CHILD | WS_VISIBLE | PBS_SMOOTH,
                                      S(24), S(322), S(472), S(14), hwnd, (HMENU)IDC_PROGRESS, nullptr, nullptr);
        SendMessageW(g.progressBar, PBM_SETRANGE, 0, MAKELPARAM(0, 100));

        g.installBtn = CreateWindowW(L"BUTTON", L"Install", WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON,
                                     S(346), S(350), S(150), S(34), hwnd, (HMENU)IDC_INSTALL_BTN, nullptr, nullptr);
        SendMessageW(g.installBtn, WM_SETFONT, (WPARAM)g.fontBold, TRUE);

        g.statusText = T(L"\u51C6\u5907\u5C31\u7EEA\uFF0C\u70B9\u51FB\u53F3\u4E0B\u89D2\u5F00\u59CB\u5B89\u88C5", L"Ready. Click Install to continue.");
        RefreshUiLanguageStrings();
        CreateThread(nullptr, 0, GitHubSyncThread, nullptr, 0, nullptr);
        return 0;
    }

    case WM_CTLCOLORSTATIC: {
        HDC hdc = (HDC)wParam;
        SetTextColor(hdc, RGB(230, 230, 235));
        SetBkColor(hdc, RGB(0x18, 0x18, 0x1B));
        return (LRESULT)g.brBg;
    }

    case WM_CTLCOLOREDIT: {
        HDC hdc = (HDC)wParam;
        SetTextColor(hdc, RGB(255, 255, 255));
        SetBkColor(hdc, RGB(0x24, 0x24, 0x2A));
        return (LRESULT)g.brEdit;
    }

    case WM_MOUSEMOVE: {
        POINT pt{ (short)LOWORD(lParam), (short)HIWORD(lParam) };
        bool nowHover = PtInRect(&g.rcAuthorCard, pt) != FALSE;
        if (nowHover != g.hoverAuthor) {
            g.hoverAuthor = nowHover;
            InvalidateRect(hwnd, &g.rcAuthorCard, FALSE);
        }
        return 0;
    }

    case WM_SETCURSOR: {
        if ((HWND)wParam == hwnd && LOWORD(lParam) == HTCLIENT) {
            POINT pt{};
            GetCursorPos(&pt);
            ScreenToClient(hwnd, &pt);
            if (PtInRect(&g.rcAuthorCard, pt) || PtInRect(&g.rcLangZh, pt) || PtInRect(&g.rcLangEn, pt)) {
                SetCursor(LoadCursorW(nullptr, IDC_HAND));
                return TRUE;
            }
        }
        break;
    }

    case WM_LBUTTONDOWN: {
        POINT pt{ (short)LOWORD(lParam), (short)HIWORD(lParam) };
        if (PtInRect(&g.rcLangZh, pt)) {
            g.isEnglish = false;
            if (!g.installing && !g.installedOk)
                g.statusText = T(L"\u51C6\u5907\u5C31\u7EEA\uFF0C\u70B9\u51FB\u53F3\u4E0B\u89D2\u5F00\u59CB\u5B89\u88C5", L"Ready.");
            RefreshUiLanguageStrings();
            return 0;
        }
        if (PtInRect(&g.rcLangEn, pt)) {
            g.isEnglish = true;
            if (!g.installing && !g.installedOk)
                g.statusText = T(L"\u51C6\u5907\u5C31\u7EEA", L"Ready. Click Install to continue.");
            RefreshUiLanguageStrings();
            return 0;
        }
        if (PtInRect(&g.rcAuthorCard, pt)) {
            ShellExecuteW(hwnd, L"open", GITHUB_URL, nullptr, nullptr, SW_SHOWNORMAL);
            return 0;
        }
        break;
    }

    case WM_COMMAND: {
        int id = LOWORD(wParam);
        if (id == IDC_BROWSE_BTN && !g.installing) {
            BROWSEINFOW bi{};
            bi.hwndOwner = hwnd;
            std::wstring prompt = T(L"\u9009\u62E9 OmniFlow \u5B89\u88C5\u76EE\u5F55", L"Select OmniFlow Install Folder");
            bi.lpszTitle = prompt.c_str();
            bi.ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE;
            LPITEMIDLIST pidl = SHBrowseForFolderW(&bi);
            if (pidl) {
                wchar_t chosen[MAX_PATH]{};
                if (SHGetPathFromIDListW(pidl, chosen)) {
                    std::wstring p = chosen;
                    if (p.size() > 3 && p.rfind(L"OmniFlow") == std::wstring::npos) {
                        p += L"\\OmniFlow";
                    }
                    SetWindowTextW(g.pathEdit, p.c_str());
                }
                CoTaskMemFree(pidl);
            }
        } else if (id == IDC_DOTNET_BTN) {
            ShellExecuteW(hwnd, L"open", DOTNET10_DL_URL, nullptr, nullptr, SW_SHOWNORMAL);
        } else if (id == IDC_INSTALL_BTN) {
            if (g.installedOk) {
                if (SendMessageW(g.chkLaunch, BM_GETCHECK, 0, 0) == BST_CHECKED) {
                    std::wstring exe = g.installDir + L"\\OmniFlow.exe";
                    ShellExecuteW(nullptr, L"open", exe.c_str(), nullptr, g.installDir.c_str(), SW_SHOWNORMAL);
                }
                DestroyWindow(hwnd);
                return 0;
            }
            if (!g.installing) {
                wchar_t buf[MAX_PATH]{};
                GetWindowTextW(g.pathEdit, buf, MAX_PATH);
                if (wcslen(buf) < 3) return 0;
                g.installDir = buf;
                g.createDesktopShortcut = (SendMessageW(g.chkDesktop, BM_GETCHECK, 0, 0) == BST_CHECKED);
                g.launchOnExit = (SendMessageW(g.chkLaunch, BM_GETCHECK, 0, 0) == BST_CHECKED);
                g.installing = true;
                EnableWindow(g.pathEdit, FALSE);
                EnableWindow(g.browseBtn, FALSE);
                EnableWindow(g.installBtn, FALSE);
                g.statusText = T(L"\u6B63\u5728\u89E3\u538B\u5E76\u5199\u5165\u6587\u4EF6...", L"Extracting and installing files...");
                RefreshUiLanguageStrings();
                CreateThread(nullptr, 0, InstallWorkerThread, new std::wstring(g.installDir), 0, nullptr);
            }
        }
        return 0;
    }

    case WM_GITHUB_SYNCED: {
        auto* p = (std::wstring*)lParam;
        if (p && !p->empty()) g.authorName = *p;
        delete p;
        InvalidateRect(hwnd, &g.rcAuthorCard, FALSE);
        return 0;
    }

    case WM_INSTALL_PROGRESS: {
        int pct = (int)wParam;
        SendMessageW(g.progressBar, PBM_SETPOS, (WPARAM)pct, 0);
        return 0;
    }

    case WM_INSTALL_DONE: {
        g.installing = false;
        if (wParam == 1) {
            g.installedOk = true;
            g.statusText = T(L"\u5B89\u88C5\u5B8C\u6210\uFF01\u70B9\u51FB\u300C\u5B8C\u6210\u300D\u5373\u53EF\u542F\u52A8 OmniFlow\u3002", L"Installation complete! Click Finish to launch OmniFlow.");
            EnableWindow(g.installBtn, TRUE);
        } else {
            auto* err = (std::wstring*)lParam;
            g.statusText = err ? *err : L"Install failed";
            delete err;
            EnableWindow(g.pathEdit, TRUE);
            EnableWindow(g.browseBtn, TRUE);
            EnableWindow(g.installBtn, TRUE);
        }
        RefreshUiLanguageStrings();
        return 0;
    }

    case WM_PAINT:
        PaintWindow(hwnd);
        return 0;

    case WM_DESTROY:
        if (g.avatarImg) delete g.avatarImg;
        if (g.appIconImg) delete g.appIconImg;
        DeleteObject(g.fontTitle);
        DeleteObject(g.fontSub);
        DeleteObject(g.fontBold);
        DeleteObject(g.fontNormal);
        DeleteObject(g.fontMono);
        DeleteObject(g.brBg);
        DeleteObject(g.brCard);
        DeleteObject(g.brEdit);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

static int PerformUninstall(const std::wstring& targetDir) {
    STARTUPINFOW si{};
    PROCESS_INFORMATION pi{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    wchar_t tk[] = L"taskkill.exe /IM OmniFlow.exe /F";
    if (CreateProcessW(nullptr, tk, nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
        WaitForSingleObject(pi.hProcess, 2000);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    }

    wchar_t desk[MAX_PATH]{}, sm[MAX_PATH]{};
    if (SHGetFolderPathW(nullptr, CSIDL_DESKTOPDIRECTORY, nullptr, 0, desk) == S_OK)
        DeleteFileW((std::wstring(desk) + L"\\OmniFlow.lnk").c_str());
    if (SHGetFolderPathW(nullptr, CSIDL_PROGRAMS, nullptr, 0, sm) == S_OK) {
        std::wstring smDir = std::wstring(sm) + L"\\OmniFlow";
        DeleteFileW((smDir + L"\\OmniFlow.lnk").c_str());
        DeleteFileW((smDir + L"\\Uninstall OmniFlow.lnk").c_str());
        RemoveDirectoryW(smDir.c_str());
    }

    RegDeleteKeyW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\OmniFlow");

    const wchar_t* files[] = {
        L"OmniFlow.exe", L"OmniFlow.dll", L"OmniFlow.deps.json",
        L"OmniFlow.runtimeconfig.json", L"omniflow-usb.exe",
        L"omniflow-restore.exe", L"wintun.dll"
    };
    for (const auto* f : files)
        DeleteFileW((targetDir + L"\\" + f).c_str());

    // Self-delete uninstaller & folder cleanly
    wchar_t selfPath[MAX_PATH]{};
    GetModuleFileNameW(nullptr, selfPath, MAX_PATH);
    std::wstring cmdLine = L"cmd.exe /c ping -n 2 127.0.0.1 >nul & del /f /q \"" + std::wstring(selfPath) + L"\" & rmdir /q \"" + targetDir + L"\"";
    std::vector<wchar_t> cmdBuf(cmdLine.begin(), cmdLine.end());
    cmdBuf.push_back(L'\0');
    if (CreateProcessW(nullptr, cmdBuf.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    }

    MessageBoxW(nullptr, L"OmniFlow has been uninstalled.", L"OmniFlow Uninstall", MB_OK | MB_ICONINFORMATION);
    return 0;
}

int WINAPI wWinMain(HINSTANCE hInst, HINSTANCE, PWSTR lpCmdLine, int) {
    // Enable Per-Monitor V2 DPI awareness dynamically without conflicting with MinGW default manifest
    if (HMODULE hUser = GetModuleHandleW(L"user32.dll")) {
        typedef BOOL(WINAPI* PFN_DpiCtx)(HANDLE);
        if (auto fn = (PFN_DpiCtx)GetProcAddress(hUser, "SetProcessDpiAwarenessContext")) {
            fn((HANDLE)(INT_PTR)-4); // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
        }
    }

    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (argv) {
        if (argc >= 3 && wcscmp(argv[1], L"--uninstall") == 0) {
            std::wstring dir = argv[2];
            LocalFree(argv);
            return PerformUninstall(dir);
        }
        if (argc >= 3 && wcscmp(argv[1], L"--extract") == 0) {
            std::wstring dir = argv[2];
            LocalFree(argv);
            EnsureDirectoryRecursive(dir);
            return ExtractCabToDir(dir, false) ? 0 : 2;
        }
        LocalFree(argv);
    }

    HDC screenDc = GetDC(nullptr);
    if (screenDc) {
        g.dpi = GetDeviceCaps(screenDc, LOGPIXELSX);
        if (g.dpi < 96) g.dpi = 96;
        ReleaseDC(nullptr, screenDc);
    }

    INITCOMMONCONTROLSEX icc{ sizeof(icc), ICC_PROGRESS_CLASS | ICC_STANDARD_CLASSES };
    InitCommonControlsEx(&icc);
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    Gdiplus::GdiplusStartupInput gdiIn;
    ULONG_PTR gdiTok = 0;
    Gdiplus::GdiplusStartup(&gdiTok, &gdiIn, nullptr);

    WNDCLASSEXW wc{ sizeof(wc) };
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInst;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = L"OmniFlowSetupWndClass";
    wc.hIcon = LoadIconW(hInst, MAKEINTRESOURCEW(IDI_APP_ICON));
    RegisterClassExW(&wc);

    int w = S(528), h = S(432);
    int sw = GetSystemMetrics(SM_CXSCREEN), sh = GetSystemMetrics(SM_CYSCREEN);
    HWND hwnd = CreateWindowExW(
        0, wc.lpszClassName, L"OmniFlow Installer",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
        (sw - w) / 2, (sh - h) / 2, w, h,
        nullptr, nullptr, hInst, nullptr);

    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);

    MSG m{};
    while (GetMessageW(&m, nullptr, 0, 0)) {
        TranslateMessage(&m);
        DispatchMessageW(&m);
    }

    Gdiplus::GdiplusShutdown(gdiTok);
    CoUninitialize();
    return 0;
}
