<div align="center">
  <img src="./assets/icon.png" width="112" alt="OmniFlow" />
  <h1>OmniFlow</h1>
  <p>Cross-Device Synergy Suite for macOS ↔ Windows (Low-Latency KVM, Edge File Portal, Clipboard Sync, Multi-NIC Parallelism & USB-C Bridge)</p>
  <p>
    <a href="./README_EN.md">English</a> | <a href="./README.md">简体中文</a>
  </p>
</div>

---

**OmniFlow** is a native cross-platform synergy tool (macOS SwiftUI + Windows WPF) requiring no external relay servers. It enables seamless multi-monitor KVM sharing, edge drag-and-drop file transfers, and instant clipboard synchronization over LAN (mutual TLS 1.3 + 6-digit SAS pairing) or a direct USB-C link.

## Key Features

1. **2D Monitor Topology & Smooth Edge Crossing / Instant Bilingual Toggle**
   - Freely arrange independent displays across macOS and Windows (preserving resolution and DPI scaling) with real-time layout sync.
   - Smooth cross-screen cursor transition powered by Windows Raw Input (`WM_INPUT`) and macOS `CGEvent` injection; supports Bidirectional / Master-Only modes and manual hotkey focus switching.
   - Instant **中 | EN** switcher in both the main apps and installers, paired with a GitHub author badge.
2. **Cross-OS Hotkey Mapping & Opt-In Anti-Drift Three-Finger Drag**
   - Directional semantic hotkey translation (`Mac → Win` / `Win → Mac`) for screenshots, Spotlight/Search, `Cmd+Tab` / `Alt+Tab`, and common `Cmd`/`Ctrl` shortcuts.
   - Opt-in **Trackpad Three-Finger Drag** (off by default) with lift-off guard, single-frame spike filtering, stationary deadzone, `70Hz` rate cap, exponential smoothing, and automatic latency warning when `RTT >= 10 ms`.
3. **Desktop Edge File Portal & Verified Safe Transfers**
   - Floating edge-portal overlay on both platforms (with a Windows Medium-IL OLE drop proxy bridging UIPI elevation) synced with the main transfer shelf.
   - Includes anti-reentry drag isolation, automatic multi-file ZIP bundling, free disk space pre-checks, SHA-256 verification on commit, and Zip-Slip / Windows reserved device name protection.
   - Seamless text, image, and file clipboard sync across systems.
4. **USB-C Direct Tunnel & Multi-NIC Concurrent Chunking**
   - Automatic discovery and multi-NIC probing across Ethernet, Wi-Fi, and USB-C NCM with parallel chunk scheduling and automatic failover.
   - Integrated user-mode WinUSB tunnel core (`usb_core`) and clean Apple stock NCM driver restore on Windows, waiting gracefully for driver & service shutdown before exit.
5. **Mutual TLS 1.3 & 6-Digit SAS Verification**
   - LAN/Wi-Fi traffic is secured with mutual TLS 1.3, 6-digit SAS pairing verification, and SHA-256 certificate pinning (`TrustedPeerStore`), with full peer management in settings.

## Project Structure

```text
OmniFlow/
├── assets/
│   ├── icon.png                        # Application icon
│   └── github_avatar.jpg               # Author avatar for installers & about card
├── mac/                                # macOS App (Swift 5.9 / SwiftUI, macOS 14+)
│   ├── Package.swift / Info.plist / AppIcon.icns
│   └── Sources/OmniFlowMac/
│       ├── OmniFlowApp.swift           # App entry point & --selftest suite
│       ├── DeskflowEngine.swift        # App state, clipboard, transfers & persistence
│       ├── DeskflowTransport.swift     # Multi-NIC discovery, mutual TLS 1.3 & chunked I/O
│       ├── DeskflowProtocol.swift      # Wire codec, SAS validation & SafeZipExtractor
│       ├── MacKvmController.swift      # CGEventTap, multitouch gestures & cursor restore
│       ├── PortalOverlayWindow.swift   # Floating desktop edge drop portal
│       ├── OmniFlowViews.swift         # SwiftUI views
│       └── AppLocalization.swift       # Bilingual localization & GitHub badge sync
├── win/                                # Windows App (C# / .NET 10 WPF, x64)
│   ├── OmniFlow.csproj / app.ico / app.manifest
│   ├── MainWindow.xaml(.cs) / PortalOverlayWindow.xaml(.cs)
│   ├── DeskflowService.cs / DeskflowTransport.cs / DeskflowWinKvm.cs
│   ├── DeskflowFileTransfer.cs / DeskflowDisplayLayout.cs / DeskflowUsbManager.cs
│   ├── ElevatedDropBridge.cs           # Medium-IL COM IDropTarget proxy for UIPI bypass
│   ├── SecurityAndTrust.cs             # Cert pinning, SAS & SafeZip extraction checks
│   ├── UsbProbe.cs / DeskflowModels.cs / AppLocalization.cs
├── usb_core/                           # Windows user-mode USB-C NCM / WinUSB core (C)
│   ├── omniflow_usb.c
│   └── restore_helper.h
└── installer/                          # Lightweight bilingual installers & build scripts
    ├── mac/
    │   ├── OmniFlowInstaller/          # Universal SwiftUI installer (arm64 / x86_64)
    │   └── build_mac_installer.sh      # Builds compressed OmniFlow-macOS-Installer.dmg
    └── win/
        ├── omniflow_setup.cpp          # Native Win32/GDI+ dark rounded setup & uninstaller
        └── build_win_installer.ps1     # Builds OmniFlow-Windows-Setup.exe
```

## Quick Install

Download the installers from [Releases](https://github.com/KSLengYu/OmniFlow/releases):

- **macOS Installer (Recommended)**: Open `OmniFlow-macOS-Installer.dmg` and run `OmniFlow Installer.app`. The universal GUI detects **Apple Silicon (`arm64`)** vs **Intel (`x86_64`)** automatically, installs the native bundle, clears quarantine metadata, and supports reinstall or one-click uninstall.
- **Windows Installer**: Run `OmniFlow-Windows-Setup.exe` (requires `.NET 10 Desktop Runtime x64`) for custom install location, Desktop / Start Menu shortcuts, and Windows Apps & Features uninstaller registration.

## Building from Source

### macOS (SwiftPM)

```bash
cd mac
swift build -c release
./.build/release/OmniFlowMac --selftest
```

### Windows (.NET 10 SDK)

```powershell
cd win
dotnet build -c Release
.\bin\x64\Release\net10.0-windows\OmniFlow.exe --selftest
```

## Building Lightweight Installers (Outputs to `dist/`)

### macOS Installer (Generates `OmniFlow-macOS-Installer.dmg`)

```bash
./installer/mac/build_mac_installer.sh
```

### Windows Installer (Requires .NET 10 SDK & MinGW-w64 `g++` / `windres`)

```powershell
.\installer\win\build_win_installer.ps1
```
