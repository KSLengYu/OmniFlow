<div align="center">
  <img src="./assets/icon.png" width="112" alt="OmniFlow" />
  <h1>OmniFlow</h1>
  <p>macOS ↔ Windows 跨设备协同工具（低延迟键鼠共享、屏幕边缘拖曳传文件、剪贴板同步、多网卡并发与 USB-C 点对点直连）</p>
  <p>
    <a href="./README_EN.md">English</a> | <a href="./README.md">简体中文</a>
  </p>
</div>

---

**OmniFlow** 是一款原生跨平台协同应用（macOS SwiftUI + Windows WPF），无需外部中转服务器，即可在局域网（双向 TLS 1.3 + 6 位短码配对）或 USB-C 直连通道上实现多屏幕无缝跨屏键鼠控制、文件拖拽互传与剪贴板实时同步。

## 核心特性

1. **2D 屏幕拓扑排列 & 平滑跨屏切换 / 中英文即时切换**
   - 自由拖拽双端独立显示器（支持多屏不同分辨率与缩放倍率对齐）并实时同步拓扑到对端；
   - 基于硬件 Raw Input（`WM_INPUT`）与 `CGEvent` 低延迟注入实现边界连续越界穿屏，支持双向互控 / 单端主控模式及手动快捷键切换焦点；
   - 侧边栏与安装向导均支持 **中 | EN** 实时切换，底部集成 GitHub 作者名片。
2. **跨系统快捷键映射 & 可选防飘移三指拖移**
   - 按 `Mac → Win` / `Win → Mac` 分方向按需开启语义快捷键替换（截图、搜索、`Alt+Tab` / `Cmd+Tab`、`Ctrl/Cmd` 常用编辑热键等）；
   - 提供默认关闭的**触控板三指拖移**选项，内置离手防误触、单帧跳变过滤、静止死区、`70Hz` 速率限制与指数平滑；高延迟无线环境（`RTT >= 10 ms`）自动触发延迟告警。
3. **屏幕边缘悬浮传送带 & 跨端安全文件传输**
   - 桌面独立边缘悬浮传送带（Windows 内置 Medium-IL OLE 拖放代理，穿透 UIPI 限制）与主窗口传输架协同，支持文件拖出/接收防回吸隔离、多文件自动 ZIP 打包、盘符剩余空间预检、SHA-256 落盘校验及 Zip-Slip/Windows 保留名防护；
   - 跨端文本、图片与文件剪贴板无缝同步。
4. **USB-C 直连隧道与多网卡并行传输**
   - 自动发现与主动探测多块网卡，支持有线 LAN、Wi-Fi 与 USB-C NCM 点对点直连并行分块加速，断点通道自动切换与清理；
   - Windows 端内置 `usb_core` 用户态 WinUSB 隧道与原厂 Apple NCM 驱动一键还原逻辑，安全退出等待隧道与服务彻底停止后再关闭窗口。
5. **双向 TLS 1.3 加密与 6 位 SAS 短码配对**
   - 局域网/Wi-Fi 通道采用双向 TLS 1.3 + 6 位 SAS 短码确认及 SHA-256 证书指纹固定（Trusted Peer Store），支持随时查看与撤销已信任设备。

## 目录结构

```text
OmniFlow/
├── assets/
│   ├── icon.png                        # 应用图标
│   └── github_avatar.jpg               # 安装器 / 关于页头像资源
├── mac/                                # macOS 客户端 (Swift 5.9 / SwiftUI, macOS 14+)
│   ├── Package.swift / Info.plist / AppIcon.icns
│   └── Sources/OmniFlowMac/
│       ├── OmniFlowApp.swift           # 应用入口与自检 (--selftest)
│       ├── DeskflowEngine.swift        # 状态管理、剪贴板、文件流与偏好持久化
│       ├── DeskflowTransport.swift     # 多网卡发现、双向 TLS 1.3、分块文件传输
│       ├── DeskflowProtocol.swift      # 协议帧编解码、SAS 配对与 SafeZipExtractor
│       ├── MacKvmController.swift      # CGEventTap、多指触控板手势与光标恢复引擎
│       ├── PortalOverlayWindow.swift   # 桌面边缘拖放传送带悬浮窗
│       ├── OmniFlowViews.swift         # 主界面视图
│       └── AppLocalization.swift       # 中/英本地化与 GitHub 名片状态
├── win/                                # Windows 客户端 (C# / .NET 10 WPF, x64)
│   ├── OmniFlow.csproj / app.ico / app.manifest
│   ├── MainWindow.xaml(.cs) / PortalOverlayWindow.xaml(.cs)
│   ├── DeskflowService.cs / DeskflowTransport.cs / DeskflowWinKvm.cs
│   ├── DeskflowFileTransfer.cs / DeskflowDisplayLayout.cs / DeskflowUsbManager.cs
│   ├── ElevatedDropBridge.cs           # 穿透 UIPI 的 Medium-IL 文件拖放代理
│   ├── SecurityAndTrust.cs             # 证书指纹固定、SAS 与 SafeZip 解压校验
│   ├── UsbProbe.cs / DeskflowModels.cs / AppLocalization.cs
├── usb_core/                           # Windows 用户态 USB-C NCM / WinUSB 隧道核心 (C)
│   ├── omniflow_usb.c
│   └── restore_helper.h
└── installer/                          # 轻量化双端图形安装器与构建脚本
    ├── mac/
    │   ├── OmniFlowInstaller/          # SwiftUI 通用安装向导 (自动识别 arm64 / x86_64)
    │   └── build_mac_installer.sh      # 打包压缩版 OmniFlow-macOS-Installer.dmg
    └── win/
        ├── omniflow_setup.cpp          # 原生 Win32/GDI+ 深色圆角 GUI 安装与卸载器
        └── build_win_installer.ps1     # 打包 OmniFlow-Windows-Setup.exe
```

## 快速下载与安装

前往 [Releases](https://github.com/KSLengYu/OmniFlow/releases) 下载对应安装包：

- **macOS 安装器（推荐）**：下载打开 `OmniFlow-macOS-Installer.dmg`，运行 `OmniFlow Installer.app`。安装器为 Universal 通用二进制，会自动识别当前 Mac 为 **Apple Silicon (`arm64`)** 还是 **Intel (`x86_64`)**，写入对应原生版本、自动清理隔离属性，并支持覆盖更新与一键卸载。
- **Windows 安装器**：下载运行 `OmniFlow-Windows-Setup.exe`（需安装 `.NET 10 Desktop Runtime x64`），支持自定义目录、桌面/开始菜单快捷方式及“应用和功能”标准卸载。

## 从源码构建

### macOS（SwiftPM）

```bash
cd mac
swift build -c release
./.build/release/OmniFlowMac --selftest
```

### Windows（.NET 10 SDK）

```powershell
cd win
dotnet build -c Release
.\bin\x64\Release\net10.0-windows\OmniFlow.exe --selftest
```

## 构建轻量安装包（输出至 `dist/`）

### macOS 安装器（生成 `OmniFlow-macOS-Installer.dmg`，自动区分 Apple Silicon / Intel）

```bash
./installer/mac/build_mac_installer.sh
```

### Windows 安装器（需 .NET 10 SDK 与 MinGW-w64 `g++` / `windres`）

```powershell
.\installer\win\build_win_installer.ps1
```
