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

#ifndef CLEARTYPE_NATURAL_QUALITY
#define CLEARTYPE_NATURAL_QUALITY 6
#endif

static const int IDR_MANIFEST_ID = 1;
static const int IDI_APP_ICON    = 101;
static const int IDR_AVATAR_JPG  = 102;
static const int IDR_PAYLOAD_CAB = 103;

static const wchar_t* GITHUB_URL = L"https://github.com/KSLengYu/OmniFlow";
static const wchar_t* DOTNET10_DL_URL = L"https://dotnet.microsoft.com/en-us/download/dotnet/10.0";

enum CtrlId {
    IDC_PATH_EDIT = 1001,
    IDC_BROWSE_BTN = 1002,
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
    HWND installBtn = nullptr;
    HWND dotnetBtn = nullptr;

    HFONT fontEdit = nullptr;
    HBRUSH brBg = nullptr;
    HBRUSH brEdit = nullptr;

    Gdiplus::Image* avatarImg = nullptr;
    Gdiplus::Image* appIconImg = nullptr;

    bool isEnglish = false;
    bool dotnetReady = false;
    bool installing = false;
    bool installedOk = false;
    bool launchOnExit = true;
    bool createDesktopShortcut = true;
    int progressPct = 0;
    int dpi = 96;

    std::wstring authorName = L"\u695E\u5B87"; // "楞宇"
    std::wstring authorHandle = L"@KSLengYu";
    std::wstring statusText;
    std::wstring installDir;

    RECT rcLangZh{};
    RECT rcLangEn{};
    RECT rcAuthorCard{};
    RECT rcChkDesktop{};
    RECT rcChkLaunch{};
    bool hoverAuthor = false;
    int hoverBtnId = 0;
};

static AppState g;

static inline int S(int px) {
    return MulDiv(px, g.dpi, 96);
}

static inline float SF(float px) {
    return px * (float)g.dpi / 96.0f;
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

    EnsureDirectoryRecursive(destDir);
    if (GetFileAttributesW(destDir.c_str()) == INVALID_FILE_ATTRIBUTES) {
        reportFail(T(L"\u65E0\u6CD5\u521B\u5EFA\u5B89\u88C5\u76EE\u5F55", L"Failed to create target directory."));
        CoUninitialize();
        return 0;
    }

    PostMessageW(g.hwnd, WM_INSTALL_PROGRESS, 22, 0);
    if (!ExtractCabToDir(destDir, true)) {
        reportFail(T(L"\u89E3\u538B\u5B89\u88C5\u6587\u4EF6\u5931\u8D25\uFF0C\u8BF7\u68C0\u67E5\u76EE\u5F55\u6743\u9650", L"Failed to extract files. Check directory permissions."));
        CoUninitialize();
        return 0;
    }

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

// --- Modern GDI+ Rounded Helpers & Typography ---

static void AddRoundRectPath(Gdiplus::GraphicsPath& path, Gdiplus::RectF r, float radius) {
    float d = radius * 2.0f;
    if (d > r.Width) d = r.Width;
    if (d > r.Height) d = r.Height;
    path.AddArc(r.X, r.Y, d, d, 180.0f, 90.0f);
    path.AddArc(r.X + r.Width - d, r.Y, d, d, 270.0f, 90.0f);
    path.AddArc(r.X + r.Width - d, r.Y + r.Height - d, d, d, 0.0f, 90.0f);
    path.AddArc(r.X, r.Y + r.Height - d, d, d, 90.0f, 90.0f);
    path.CloseFigure();
}

static void FillRoundRect(Gdiplus::Graphics& gfx, Gdiplus::RectF r, float radius, Gdiplus::Color fill) {
    Gdiplus::GraphicsPath p;
    AddRoundRectPath(p, r, radius);
    Gdiplus::SolidBrush br(fill);
    gfx.FillPath(&br, &p);
}

static void DrawRoundCard(Gdiplus::Graphics& gfx, Gdiplus::RectF r, float radius, Gdiplus::Color fill, Gdiplus::Color border, float strokeW = 1.0f) {
    Gdiplus::GraphicsPath p;
    AddRoundRectPath(p, r, radius);
    Gdiplus::SolidBrush br(fill);
    Gdiplus::Pen pen(border, strokeW);
    gfx.FillPath(&br, &p);
    gfx.DrawPath(&pen, &p);
}

static Gdiplus::FontFamily* MakeUiFontFamily() {
    auto* f = new Gdiplus::FontFamily(L"Microsoft YaHei UI");
    if (f->IsAvailable()) return f;
    delete f;
    f = new Gdiplus::FontFamily(L"Segoe UI");
    if (f->IsAvailable()) return f;
    delete f;
    return Gdiplus::FontFamily::GenericSansSerif()->Clone();
}

static void DrawTextGdip(
    Gdiplus::Graphics& gfx,
    const Gdiplus::FontFamily* ff,
    const std::wstring& text,
    float pxSize,
    INT style,
    Gdiplus::RectF rect,
    Gdiplus::Color col,
    Gdiplus::StringAlignment hAlign = Gdiplus::StringAlignmentNear,
    Gdiplus::StringAlignment vAlign = Gdiplus::StringAlignmentCenter)
{
    Gdiplus::Font font(ff, pxSize, style, Gdiplus::UnitPixel);
    Gdiplus::SolidBrush br(col);
    Gdiplus::StringFormat fmt(Gdiplus::StringFormatFlagsNoWrap);
    fmt.SetAlignment(hAlign);
    fmt.SetLineAlignment(vAlign);
    fmt.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
    gfx.DrawString(text.c_str(), (INT)text.size(), &font, rect, &fmt, &br);
}

static void DrawGitHubOctocat(Gdiplus::Graphics& gfx, float x, float y, float sz, Gdiplus::Color col, Gdiplus::Color cutout) {
    Gdiplus::SolidBrush br(col);
    Gdiplus::GraphicsPath circlePath;
    circlePath.AddEllipse(x, y, sz, sz);
    gfx.FillPath(&br, &circlePath);

    Gdiplus::SolidBrush inner(cutout);
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

static void DrawOwnerButton(const DRAWITEMSTRUCT* dis) {
    if (!dis) return;
    RECT rc = dis->rcItem;
    int w = rc.right - rc.left;
    int h = rc.bottom - rc.top;
    if (w <= 0 || h <= 0) return;

    HDC memDc = CreateCompatibleDC(dis->hDC);
    HBITMAP memBmp = CreateCompatibleBitmap(dis->hDC, w, h);
    HGDIOBJ oldBmp = SelectObject(memDc, memBmp);

    Gdiplus::Graphics gfx(memDc);
    gfx.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    gfx.SetTextRenderingHint(Gdiplus::TextRenderingHintClearTypeGridFit);

    bool disabled = (dis->itemState & ODS_DISABLED) != 0;
    bool pressed = (dis->itemState & ODS_SELECTED) != 0;
    bool isPrimary = (dis->CtlID == IDC_INSTALL_BTN);
    bool hovered = (g.hoverBtnId == (int)dis->CtlID) && !disabled;

    // Paint card/window backdrop behind button corners
    Gdiplus::Color backdrop = (dis->CtlID == IDC_BROWSE_BTN)
        ? Gdiplus::Color(255, 0x12, 0x17, 0x22)
        : Gdiplus::Color(255, 0x0B, 0x0E, 0x14);
    Gdiplus::SolidBrush brBack(backdrop);
    gfx.FillRectangle(&brBack, 0, 0, w, h);

    Gdiplus::Color fill, border, textCol;
    if (isPrimary) {
        if (disabled) {
            fill = Gdiplus::Color(255, 0x1D, 0x35, 0x62);
            border = Gdiplus::Color(255, 0x28, 0x45, 0x7A);
            textCol = Gdiplus::Color(255, 0x94, 0xA3, 0xB8);
        } else if (pressed) {
            fill = Gdiplus::Color(255, 0x1D, 0x4E, 0xD8);
            border = Gdiplus::Color(255, 0x3B, 0x82, 0xF6);
            textCol = Gdiplus::Color(255, 255, 255, 255);
        } else if (hovered) {
            fill = Gdiplus::Color(255, 0x3B, 0x82, 0xF6);
            border = Gdiplus::Color(255, 0x60, 0xA5, 0xFA);
            textCol = Gdiplus::Color(255, 255, 255, 255);
        } else {
            fill = Gdiplus::Color(255, 0x25, 0x63, 0xEB);
            border = Gdiplus::Color(255, 0x3B, 0x82, 0xF6);
            textCol = Gdiplus::Color(255, 255, 255, 255);
        }
    } else {
        if (disabled) {
            fill = Gdiplus::Color(255, 0x13, 0x18, 0x24);
            border = Gdiplus::Color(255, 0x1E, 0x29, 0x3B);
            textCol = Gdiplus::Color(255, 0x64, 0x74, 0x8B);
        } else if (pressed) {
            fill = Gdiplus::Color(255, 0x12, 0x1B, 0x2E);
            border = Gdiplus::Color(255, 0x3B, 0x82, 0xF6);
            textCol = Gdiplus::Color(255, 0xF8, 0xFA, 0xFC);
        } else if (hovered) {
            fill = Gdiplus::Color(255, 0x1E, 0x29, 0x3B);
            border = Gdiplus::Color(255, 0x47, 0x55, 0x69);
            textCol = Gdiplus::Color(255, 0xF8, 0xFA, 0xFC);
        } else {
            fill = Gdiplus::Color(255, 0x16, 0x1E, 0x2E);
            border = Gdiplus::Color(255, 0x26, 0x32, 0x48);
            textCol = Gdiplus::Color(255, 0xCB, 0xD5, 0xE1);
        }
    }

    DrawRoundCard(gfx, Gdiplus::RectF(0.5f, 0.5f, (float)w - 1.5f, (float)h - 1.5f), SF(8.0f), fill, border, 1.0f);

    wchar_t buf[128]{};
    GetWindowTextW(dis->hwndItem, buf, 128);
    Gdiplus::FontFamily* ff = MakeUiFontFamily();
    DrawTextGdip(
        gfx, ff, buf,
        SF(isPrimary ? 13.5f : 12.5f),
        isPrimary ? Gdiplus::FontStyleBold : Gdiplus::FontStyleRegular,
        Gdiplus::RectF(4.0f, 0.0f, (float)w - 8.0f, (float)h),
        textCol,
        Gdiplus::StringAlignmentCenter,
        Gdiplus::StringAlignmentCenter);
    delete ff;

    BitBlt(dis->hDC, 0, 0, w, h, memDc, 0, 0, SRCCOPY);
    SelectObject(memDc, oldBmp);
    DeleteObject(memBmp);
    DeleteDC(memDc);
}

static void RefreshUiLanguageStrings() {
    if (!g.hwnd) return;
    SetWindowTextW(g.hwnd, T(L"OmniFlow \u5B89\u88C5\u5411\u5BFC", L"OmniFlow Installer").c_str());
    SetWindowTextW(g.browseBtn, T(L"\u6D4F\u89C8...", L"Browse...").c_str());

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
    InvalidateRect(g.hwnd, nullptr, FALSE);
    InvalidateRect(g.browseBtn, nullptr, FALSE);
    InvalidateRect(g.installBtn, nullptr, FALSE);
    if (g.dotnetBtn) InvalidateRect(g.dotnetBtn, nullptr, FALSE);
}

static void DrawCheckboxRow(
    Gdiplus::Graphics& gfx,
    const Gdiplus::FontFamily* ff,
    const RECT& rcRow,
    bool checked,
    const std::wstring& label)
{
    float boxSz = SF(16.0f);
    float bx = (float)rcRow.left;
    float by = (float)rcRow.top + ((rcRow.bottom - rcRow.top) - boxSz) * 0.5f;
    Gdiplus::RectF boxR(bx, by, boxSz, boxSz);

    if (checked) {
        DrawRoundCard(gfx, boxR, SF(4.5f),
            Gdiplus::Color(255, 0x25, 0x63, 0xEB),
            Gdiplus::Color(255, 0x3B, 0x82, 0xF6), 1.0f);
        Gdiplus::Pen ck(Gdiplus::Color(255, 255, 255, 255), SF(1.8f));
        ck.SetStartCap(Gdiplus::LineCapRound);
        ck.SetEndCap(Gdiplus::LineCapRound);
        ck.SetLineJoin(Gdiplus::LineJoinRound);
        Gdiplus::PointF pts[3] = {
            {bx + boxSz * 0.24f, by + boxSz * 0.52f},
            {bx + boxSz * 0.44f, by + boxSz * 0.72f},
            {bx + boxSz * 0.77f, by + boxSz * 0.30f}
        };
        gfx.DrawLines(&ck, pts, 3);
    } else {
        DrawRoundCard(gfx, boxR, SF(4.5f),
            Gdiplus::Color(255, 0x08, 0x0B, 0x10),
            Gdiplus::Color(255, 0x33, 0x41, 0x55), 1.2f);
    }

    Gdiplus::RectF lblR(bx + boxSz + SF(10.0f), (float)rcRow.top, (float)(rcRow.right - rcRow.left) - boxSz - SF(10.0f), (float)(rcRow.bottom - rcRow.top));
    DrawTextGdip(gfx, ff, label, SF(13.0f), Gdiplus::FontStyleRegular, lblR, Gdiplus::Color(255, 0xE2, 0xE8, 0xF0));
}

static void PaintWindow(HWND hwnd) {
    PAINTSTRUCT ps{};
    HDC hdc = BeginPaint(hwnd, &ps);
    RECT rc{};
    GetClientRect(hwnd, &rc);

    HDC memDc = CreateCompatibleDC(hdc);
    HBITMAP memBmp = CreateCompatibleBitmap(hdc, rc.right, rc.bottom);
    HGDIOBJ oldBmp = SelectObject(memDc, memBmp);

    Gdiplus::Graphics gfx(memDc);
    gfx.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    gfx.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
    gfx.SetTextRenderingHint(Gdiplus::TextRenderingHintClearTypeGridFit);

    Gdiplus::FontFamily* ff = MakeUiFontFamily();

    // Canvas Background (#0B0E14)
    Gdiplus::SolidBrush brCanvas(Gdiplus::Color(255, 0x0B, 0x0E, 0x14));
    gfx.FillRectangle(&brCanvas, 0, 0, rc.right, rc.bottom);

    // Header (Hero)
    if (g.appIconImg) {
        gfx.DrawImage(g.appIconImg, S(24), S(18), S(42), S(42));
    }
    DrawTextGdip(gfx, ff, L"OmniFlow", SF(20.0f), Gdiplus::FontStyleBold,
        Gdiplus::RectF((float)S(78), (float)S(15), (float)S(115), (float)S(26)),
        Gdiplus::Color(255, 0xF8, 0xFA, 0xFC));

    // Version Badge next to Title
    DrawRoundCard(gfx, Gdiplus::RectF((float)S(178), (float)S(19), (float)S(56), (float)S(20)), SF(5.0f),
        Gdiplus::Color(255, 0x15, 0x22, 0x38), Gdiplus::Color(255, 0x25, 0x3A, 0x5E), 1.0f);
    DrawTextGdip(gfx, ff, L"v1.0.0", SF(11.0f), Gdiplus::FontStyleBold,
        Gdiplus::RectF((float)S(178), (float)S(19), (float)S(56), (float)S(20)),
        Gdiplus::Color(255, 0x93, 0xC5, 0xFD), Gdiplus::StringAlignmentCenter, Gdiplus::StringAlignmentCenter);

    std::wstring sub = T(L"\u8DE8\u8BBE\u5907\u952E\u9F20\u5171\u4EAB\u3001\u8FB9\u7F18\u4F20\u9001\u5E26\u4E0E USB-C \u76F4\u8FDE (Windows x64)",
                         L"Cross-Device KVM, File Portal & USB-C Bridge (Windows x64)");
    DrawTextGdip(gfx, ff, sub, SF(12.5f), Gdiplus::FontStyleRegular,
        Gdiplus::RectF((float)S(78), (float)S(42), (float)(rc.right - S(188)), (float)S(20)),
        Gdiplus::Color(255, 0x94, 0xA3, 0xB8));

    // Language Pill (中 | EN) top-right
    g.rcLangZh = { rc.right - S(98), S(22), rc.right - S(61), S(48) };
    g.rcLangEn = { rc.right - S(61), S(22), rc.right - S(24), S(48) };
    DrawRoundCard(gfx, Gdiplus::RectF((float)(rc.right - S(100)), (float)S(20), (float)S(78), (float)S(30)), SF(8.0f),
        Gdiplus::Color(255, 0x12, 0x17, 0x22), Gdiplus::Color(255, 0x1F, 0x29, 0x37), 1.0f);
    RECT activeR = g.isEnglish ? g.rcLangEn : g.rcLangZh;
    FillRoundRect(gfx,
        Gdiplus::RectF((float)activeR.left, (float)activeR.top, (float)(activeR.right - activeR.left), (float)(activeR.bottom - activeR.top)),
        SF(6.0f), Gdiplus::Color(255, 0x25, 0x63, 0xEB));
    DrawTextGdip(gfx, ff, L"\u4E2D", SF(12.0f), Gdiplus::FontStyleBold,
        Gdiplus::RectF((float)g.rcLangZh.left, (float)g.rcLangZh.top, (float)(g.rcLangZh.right - g.rcLangZh.left), (float)(g.rcLangZh.bottom - g.rcLangZh.top)),
        g.isEnglish ? Gdiplus::Color(255, 0x94, 0xA3, 0xB8) : Gdiplus::Color(255, 255, 255, 255),
        Gdiplus::StringAlignmentCenter, Gdiplus::StringAlignmentCenter);
    DrawTextGdip(gfx, ff, L"EN", SF(12.0f), Gdiplus::FontStyleBold,
        Gdiplus::RectF((float)g.rcLangEn.left, (float)g.rcLangEn.top, (float)(g.rcLangEn.right - g.rcLangEn.left), (float)(g.rcLangEn.bottom - g.rcLangEn.top)),
        g.isEnglish ? Gdiplus::Color(255, 255, 255, 255) : Gdiplus::Color(255, 0x94, 0xA3, 0xB8),
        Gdiplus::StringAlignmentCenter, Gdiplus::StringAlignmentCenter);

    // Card 1: Author GitHub Card
    g.rcAuthorCard = { S(24), S(74), rc.right - S(24), S(140) };
    {
        Gdiplus::Color cardBg = g.hoverAuthor ? Gdiplus::Color(255, 0x17, 0x20, 0x33) : Gdiplus::Color(255, 0x12, 0x17, 0x22);
        Gdiplus::Color cardBd = g.hoverAuthor ? Gdiplus::Color(255, 0x3B, 0x82, 0xF6) : Gdiplus::Color(255, 0x1F, 0x29, 0x37);
        DrawRoundCard(gfx,
            Gdiplus::RectF((float)g.rcAuthorCard.left, (float)g.rcAuthorCard.top,
                (float)(g.rcAuthorCard.right - g.rcAuthorCard.left), (float)(g.rcAuthorCard.bottom - g.rcAuthorCard.top)),
            SF(12.0f), cardBg, cardBd, 1.0f);

        Gdiplus::Rect avRect(S(38), S(85), S(44), S(44));
        if (g.avatarImg) {
            Gdiplus::GraphicsState st = gfx.Save();
            Gdiplus::GraphicsPath clip;
            clip.AddEllipse(avRect);
            gfx.SetClip(&clip);
            gfx.DrawImage(g.avatarImg, avRect);
            gfx.Restore(st);
        }
        Gdiplus::Pen avRing(Gdiplus::Color(230, 0x3B, 0x82, 0xF6), 1.6f);
        gfx.DrawEllipse(&avRing, avRect);

        DrawGitHubOctocat(gfx, (float)S(96), (float)S(88), (float)S(16),
            Gdiplus::Color(255, 0xF8, 0xFA, 0xFC), cardBg);

        DrawTextGdip(gfx, ff, g.authorName, SF(14.0f), Gdiplus::FontStyleBold,
            Gdiplus::RectF((float)S(118), (float)S(85), (float)(rc.right - S(250)), (float)S(22)),
            Gdiplus::Color(255, 0xF8, 0xFA, 0xFC));

        std::wstring line2 = g.authorHandle + L"  ·  github.com/KSLengYu/OmniFlow";
        DrawTextGdip(gfx, ff, line2, SF(12.0f), Gdiplus::FontStyleRegular,
            Gdiplus::RectF((float)S(96), (float)S(110), (float)(rc.right - S(200)), (float)S(20)),
            Gdiplus::Color(255, 0x60, 0xA5, 0xFA));

        DrawTextGdip(gfx, ff, T(L"GitHub \u4E3B\u9875 \u2197", L"GitHub \u2197"), SF(12.0f), Gdiplus::FontStyleRegular,
            Gdiplus::RectF((float)(rc.right - S(130)), (float)S(85), (float)S(90), (float)S(44)),
            g.hoverAuthor ? Gdiplus::Color(255, 0x93, 0xC5, 0xFD) : Gdiplus::Color(255, 0x94, 0xA3, 0xB8),
            Gdiplus::StringAlignmentFar, Gdiplus::StringAlignmentCenter);
    }

    // Card 2: Install Location Card
    DrawRoundCard(gfx, Gdiplus::RectF((float)S(24), (float)S(154), (float)(rc.right - S(48)), (float)S(92)),
        SF(12.0f), Gdiplus::Color(255, 0x12, 0x17, 0x22), Gdiplus::Color(255, 0x1F, 0x29, 0x37), 1.0f);

    DrawTextGdip(gfx, ff, T(L"\u5B89\u88C5\u76EE\u5F55", L"Install Location"), SF(13.0f), Gdiplus::FontStyleBold,
        Gdiplus::RectF((float)S(40), (float)S(165), (float)S(200), (float)S(22)),
        Gdiplus::Color(255, 0xE2, 0xE8, 0xF0));

    std::wstring dnText = g.dotnetReady
        ? T(L"\u2713 .NET 10 \u684C\u9762\u8FD0\u884C\u65F6\u5DF2\u5C31\u7EEA", L"\u2713 .NET 10 Desktop Runtime Ready")
        : T(L"\u26A0 \u9700 .NET 10 \u8FD0\u884C\u65F6", L"\u26A0 Needs .NET 10 Runtime");
    Gdiplus::Color dnCol = g.dotnetReady
        ? Gdiplus::Color(255, 0x34, 0xD3, 0x99)
        : Gdiplus::Color(255, 0xFB, 0xBF, 0x24);
    float dnRight = (float)(g.dotnetReady ? (rc.right - S(40)) : (rc.right - S(138)));
    DrawTextGdip(gfx, ff, dnText, SF(12.0f), Gdiplus::FontStyleRegular,
        Gdiplus::RectF((float)S(220), (float)S(165), dnRight - (float)S(220), (float)S(22)),
        dnCol, Gdiplus::StringAlignmentFar, Gdiplus::StringAlignmentCenter);

    // Recessed rounded input container behind borderless EDIT
    DrawRoundCard(gfx, Gdiplus::RectF((float)S(40), (float)S(196), (float)(rc.right - S(170)), (float)S(34)),
        SF(8.0f), Gdiplus::Color(255, 0x08, 0x0B, 0x10), Gdiplus::Color(255, 0x26, 0x32, 0x48), 1.0f);

    // Card 3: Install Options Card
    DrawRoundCard(gfx, Gdiplus::RectF((float)S(24), (float)S(260), (float)(rc.right - S(48)), (float)S(96)),
        SF(12.0f), Gdiplus::Color(255, 0x12, 0x17, 0x22), Gdiplus::Color(255, 0x1F, 0x29, 0x37), 1.0f);

    DrawTextGdip(gfx, ff, T(L"\u5B89\u88C5\u9009\u9879", L"Install Options"), SF(13.0f), Gdiplus::FontStyleBold,
        Gdiplus::RectF((float)S(40), (float)S(271), (float)S(200), (float)S(20)),
        Gdiplus::Color(255, 0x94, 0xA3, 0xB8));

    g.rcChkDesktop = { S(40), S(296), rc.right - S(40), S(322) };
    g.rcChkLaunch  = { S(40), S(324), rc.right - S(40), S(350) };
    DrawCheckboxRow(gfx, ff, g.rcChkDesktop, g.createDesktopShortcut,
        T(L"\u521B\u5EFA\u684C\u9762\u5FEB\u6377\u65B9\u5F0F (OmniFlow)", L"Create Desktop shortcut (OmniFlow)"));
    DrawCheckboxRow(gfx, ff, g.rcChkLaunch, g.launchOnExit,
        T(L"\u5B89\u88C5\u5B8C\u6210\u540E\u7ACB\u5373\u542F\u52A8 OmniFlow", L"Launch OmniFlow after installation"));

    // Status Text
    if (!g.statusText.empty()) {
        Gdiplus::Color stCol = g.installedOk
            ? Gdiplus::Color(255, 0x34, 0xD3, 0x99)
            : Gdiplus::Color(255, 0xCB, 0xD5, 0xE1);
        DrawTextGdip(gfx, ff, g.statusText, SF(12.5f), Gdiplus::FontStyleRegular,
            Gdiplus::RectF((float)S(24), (float)S(370), (float)(rc.right - S(48)), (float)S(20)),
            stCol);
    }

    // Custom Rounded Progress Bar
    Gdiplus::RectF trackR((float)S(24), (float)S(396), (float)(rc.right - S(48)), (float)S(8));
    FillRoundRect(gfx, trackR, SF(4.0f), Gdiplus::Color(255, 0x16, 0x20, 0x32));
    if (g.progressPct > 0) {
        int clamped = g.progressPct > 100 ? 100 : g.progressPct;
        float fillW = trackR.Width * (float)clamped / 100.0f;
        if (fillW < SF(8.0f)) fillW = SF(8.0f);
        FillRoundRect(gfx, Gdiplus::RectF(trackR.X, trackR.Y, fillW, trackR.Height), SF(4.0f),
            g.installedOk ? Gdiplus::Color(255, 0x10, 0xB9, 0x81) : Gdiplus::Color(255, 0x3B, 0x82, 0xF6));
    }

    delete ff;

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

        g.fontEdit = CreateFontW(-S(14), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
            DEFAULT_CHARSET, 0, 0, CLEARTYPE_NATURAL_QUALITY, 0, L"Microsoft YaHei UI");

        g.brBg = CreateSolidBrush(RGB(0x0B, 0x0E, 0x14));
        g.brEdit = CreateSolidBrush(RGB(0x08, 0x0B, 0x10));

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

        wchar_t localApp[MAX_PATH]{};
        if (GetFileAttributesW(L"C:\\OmniFlow\\OmniFlow.exe") != INVALID_FILE_ATTRIBUTES) {
            g.installDir = L"C:\\OmniFlow";
        } else if (SHGetFolderPathW(nullptr, CSIDL_LOCAL_APPDATA, nullptr, 0, localApp) == S_OK) {
            g.installDir = std::wstring(localApp) + L"\\Programs\\OmniFlow";
        } else {
            g.installDir = L"C:\\OmniFlow";
        }

        RECT crc{};
        GetClientRect(hwnd, &crc);
        int cw = crc.right;

        // Borderless modern EDIT centered vertically inside rounded #080B10 container (top 196, h 34)
        g.pathEdit = CreateWindowExW(0, L"EDIT", g.installDir.c_str(),
                                     WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL,
                                     S(50), S(204), cw - S(190), S(20), hwnd, (HMENU)IDC_PATH_EDIT, nullptr, nullptr);
        SendMessageW(g.pathEdit, WM_SETFONT, (WPARAM)g.fontEdit, TRUE);

        g.browseBtn = CreateWindowW(L"BUTTON", L"...", WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
                                    cw - S(120), S(196), S(80), S(34), hwnd, (HMENU)IDC_BROWSE_BTN, nullptr, nullptr);

        if (!g.dotnetReady) {
            g.dotnetBtn = CreateWindowW(L"BUTTON", L"Get .NET 10", WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
                                        cw - S(130), S(162), S(90), S(26), hwnd, (HMENU)IDC_DOTNET_BTN, nullptr, nullptr);
        }

        g.installBtn = CreateWindowW(L"BUTTON", L"Install", WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
                                     cw - S(184), S(416), S(160), S(38), hwnd, (HMENU)IDC_INSTALL_BTN, nullptr, nullptr);

        g.statusText = T(L"\u51C6\u5907\u5C31\u7EEA\uFF0C\u70B9\u51FB\u53F3\u4E0B\u89D2\u5F00\u59CB\u5B89\u88C5", L"Ready. Click Install to continue.");
        RefreshUiLanguageStrings();
        CreateThread(nullptr, 0, GitHubSyncThread, nullptr, 0, nullptr);
        return 0;
    }

    case WM_DRAWITEM: {
        DrawOwnerButton((const DRAWITEMSTRUCT*)lParam);
        return TRUE;
    }

    case WM_CTLCOLOREDIT: {
        HDC hdc = (HDC)wParam;
        SetTextColor(hdc, RGB(0xF8, 0xFA, 0xFC));
        SetBkColor(hdc, RGB(0x08, 0x0B, 0x10));
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
        HWND target = (HWND)wParam;
        int prevHover = g.hoverBtnId;
        if (target == g.installBtn) g.hoverBtnId = IDC_INSTALL_BTN;
        else if (target == g.browseBtn) g.hoverBtnId = IDC_BROWSE_BTN;
        else if (target == g.dotnetBtn && g.dotnetBtn != nullptr) g.hoverBtnId = IDC_DOTNET_BTN;
        else g.hoverBtnId = 0;

        if (prevHover != g.hoverBtnId) {
            if (prevHover == IDC_INSTALL_BTN) InvalidateRect(g.installBtn, nullptr, FALSE);
            else if (prevHover == IDC_BROWSE_BTN) InvalidateRect(g.browseBtn, nullptr, FALSE);
            else if (prevHover == IDC_DOTNET_BTN && g.dotnetBtn) InvalidateRect(g.dotnetBtn, nullptr, FALSE);
            if (g.hoverBtnId == IDC_INSTALL_BTN) InvalidateRect(g.installBtn, nullptr, FALSE);
            else if (g.hoverBtnId == IDC_BROWSE_BTN) InvalidateRect(g.browseBtn, nullptr, FALSE);
            else if (g.hoverBtnId == IDC_DOTNET_BTN && g.dotnetBtn) InvalidateRect(g.dotnetBtn, nullptr, FALSE);
        }

        if (target == hwnd && LOWORD(lParam) == HTCLIENT) {
            POINT pt{};
            GetCursorPos(&pt);
            ScreenToClient(hwnd, &pt);
            if (PtInRect(&g.rcAuthorCard, pt) || PtInRect(&g.rcLangZh, pt) || PtInRect(&g.rcLangEn, pt) ||
                PtInRect(&g.rcChkDesktop, pt) || PtInRect(&g.rcChkLaunch, pt)) {
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
        if (!g.installing && !g.installedOk && PtInRect(&g.rcChkDesktop, pt)) {
            g.createDesktopShortcut = !g.createDesktopShortcut;
            InvalidateRect(hwnd, &g.rcChkDesktop, FALSE);
            return 0;
        }
        if (!g.installedOk && PtInRect(&g.rcChkLaunch, pt)) {
            g.launchOnExit = !g.launchOnExit;
            InvalidateRect(hwnd, &g.rcChkLaunch, FALSE);
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
                if (g.launchOnExit) {
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
                g.installing = true;
                g.progressPct = 5;
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
        g.progressPct = (int)wParam;
        RECT rcProg{ S(24), S(394), 2000, S(408) };
        InvalidateRect(hwnd, &rcProg, FALSE);
        return 0;
    }

    case WM_INSTALL_DONE: {
        g.installing = false;
        if (wParam == 1) {
            g.installedOk = true;
            g.progressPct = 100;
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
        DeleteObject(g.fontEdit);
        DeleteObject(g.brBg);
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

    INITCOMMONCONTROLSEX icc{ sizeof(icc), ICC_STANDARD_CLASSES };
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

    int w = S(564), h = S(506);
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
