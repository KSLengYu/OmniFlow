# OmniFlow

macOS 与 Windows 跨设备协同工具（统一 SwiftUI / WPF 界面）：支持低延迟键鼠共享（KVM）、跨系统快捷指令/剪贴板同步、屏幕边缘拖曳传文件、多网卡并发传输与 USB-C 点对点直连隧道。

## 目录结构

- `mac/` — macOS 原生客户端（Swift 5.9 / SwiftUI，最低系统要求 macOS 14+）
  - `Package.swift`、`Info.plist`、`AppIcon.icns`、`Sources/OmniFlowMac/`
- `win/` — Windows 客户端（.NET 10 WPF，x64）
  - `OmniFlow.csproj`、`MainWindow.xaml(.cs)`、`PortalOverlayWindow.xaml(.cs)`、`AppLocalization.cs`、`Deskflow*.cs`、`SecurityAndTrust.cs`、`UsbProbe.cs`
- `usb_core/` — Windows USB-C NCM / WinUSB 隧道与驱动恢复核心（C 源码）
  - `omniflow_usb.c`、`restore_helper.h`
- `installer/` — 轻量化双端安装器构建脚本与原生安装器源码
  - `mac/OmniFlowInstaller/` & `mac/build_mac_installer.sh`（通用 `.dmg` 安装向导 `OmniFlow Installer.app`，自动识别 Apple Silicon `arm64` / Intel `x86_64` 并支持覆盖/卸载）
  - `win/omniflow_setup.cpp`、`win/build_win_installer.ps1`（独立 Win32/GDI+ 深色圆角 GUI 安装器 + 卸载程序）

## 核心特性

1. **屏幕排列与跨屏切换 / 中英文即时切换**
   - 自由拖拽双端虚拟显示器位置，保存布局并实时同步到对端
   - 侧边栏顶部提供 `中 | EN` 语言切换开关，底部集成可点击的 GitHub 作者名片（启动时异步尝试同步 GitHub 名称，离线自动回退默认值）
   - 屏幕边缘越界平滑切屏，或通过手动快捷键快速切换焦点
2. **键鼠共享、快捷键映射与可选三指拖移**
   - 按 `Mac → Win` / `Win → Mac` 分方向按需配置快捷键替换与操控模式屏蔽
   - 默认关闭的**触控板三指拖移**开关（按需启用），内置离手防误触、单帧跳变过滤、静止死区、`70Hz` 速率限制与指数平滑；高延迟（如普通 Wi-Fi，`RTT >= 10 ms`）下会触发即时延迟告警（高延迟下仍建议切换有线 LAN 或 USB-C 直连）
3. **跨屏传文件悬浮传送带 & 剪贴板同步**
   - 桌面独立悬浮窗与主界面传输架双向协同，支持防回吸隔离、多文件自动打包及 SHA-256 落盘校验
   - 跨端文本/图片/文件剪贴板无缝同步
4. **USB-C 线直连与多网卡并发**
   - 局域网自动发现 + 手动指定 IP（可选）；支持有线网卡、Wi-Fi 与 USB-C NCM 直连自动切换与多网卡分块并发
   - Windows 端内置 WinUSB 点对点隧道与苹果原厂 NCM 驱动恢复流程（退出时等待驱动清理与全部服务停止完成后再关闭窗口）
5. **双向 TLS 1.3 与短码配对安全机制**
   - LAN/Wi-Fi 通道采用双向 TLS 1.3 + 6 位 SAS 短码确认、证书指纹固定（Trust Store），支持随时查看与清除已信任设备

## 从源码构建

### macOS（SwiftPM）

```bash
cd mac
swift build -c release
```

运行自检测试：

```bash
./.build/release/OmniFlowMac --selftest
```

### Windows（.NET 10 SDK）

```powershell
cd win
dotnet build -c Release
```

运行自检测试：

```powershell
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
