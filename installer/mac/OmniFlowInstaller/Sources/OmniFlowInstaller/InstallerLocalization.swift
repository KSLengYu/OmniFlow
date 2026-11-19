import Foundation
import Combine

enum InstallerLang: String {
    case zh
    case en
}

@MainActor
final class InstallerL10n: ObservableObject {
    static let shared = InstallerL10n()

    @Published var lang: InstallerLang

    private init() {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
        lang = preferred.hasPrefix("zh") ? .zh : .en
    }

    func toggle() {
        lang = (lang == .zh) ? .en : .zh
    }

    func t(_ key: String) -> String {
        (lang == .zh ? Self.zh : Self.en)[key] ?? key
    }

    private static let zh: [String: String] = [
        "win_title": "OmniFlow 安装向导",
        "badge_ver": "安装器 v1.0.0",
        "lang_btn": "中文 / EN",
        "hero_title": "OmniFlow",
        "hero_sub": "macOS ↔ Windows 跨系统键鼠共享、边缘传送带、剪贴板同步与 USB-C 直连",
        "arch_card_title": "芯片架构自动识别",
        "arch_apple_silicon": "已识别本机为 Apple Silicon (ARM64)，将自动安装原生 ARM64 版本",
        "arch_intel": "已识别本机为 Intel (x86_64)，将自动安装原生 x86_64 版本",
        "arch_choice_lbl": "安装架构版本",
        "arch_auto": "自动匹配本机架构",
        "arch_arm64": "Apple Silicon (arm64)",
        "arch_x86_64": "Intel (x86_64)",
        "dir_lbl": "安装位置",
        "dir_apps": "系统应用程序 (/Applications)",
        "dir_user_apps": "当前用户目录 (~/Applications)",
        "chk_launch": "安装完成后立即打开 OmniFlow",
        "chk_clear_quarantine": "自动清理系统隔离属性 (xattr)",
        "btn_install": "立即安装",
        "btn_reinstall": "覆盖安装",
        "btn_uninstall": "卸载已安装版本",
        "btn_finish": "完成",
        "btn_close": "关闭",
        "prog_installing": "正在安装 OmniFlow...",
        "prog_uninstalling": "正在卸载 OmniFlow...",
        "done_install_title": "OmniFlow 安装完成",
        "done_install_sub": "已安装适配本机芯片架构的原生版本，打开后授予辅助功能权限即可开启跨屏键鼠与文件传输。",
        "done_uninstall_title": "OmniFlow 已卸载",
        "done_uninstall_sub": "已关闭运行中的进程并移除应用包。",
        "step_stop": "正在检查并退出运行中的 OmniFlow...",
        "step_locate": "正在定位匹配的架构安装包: ",
        "step_copy": "正在写入目标目录: ",
        "step_xattr": "正在清理下载隔离属性...",
        "step_sign": "正在校验应用签名...",
        "step_remove": "正在移除应用文件...",
        "step_done": "操作完成。",
        "err_missing_payload": "安装器内部缺少对应架构安装包: "
    ]

    private static let en: [String: String] = [
        "win_title": "OmniFlow Installer",
        "badge_ver": "Installer v1.0.0",
        "lang_btn": "EN / 中文",
        "hero_title": "OmniFlow",
        "hero_sub": "Cross-OS KVM, Edge File Portal, Clipboard Sync & USB-C Bridge (macOS 14+)",
        "arch_card_title": "Architecture Auto-Detection",
        "arch_apple_silicon": "Detected Apple Silicon (ARM64) — native ARM64 build selected automatically",
        "arch_intel": "Detected Intel (x86_64) — native x86_64 build selected automatically",
        "arch_choice_lbl": "Target Build",
        "arch_auto": "Auto (Match This Mac)",
        "arch_arm64": "Apple Silicon (arm64)",
        "arch_x86_64": "Intel (x86_64)",
        "dir_lbl": "Install Location",
        "dir_apps": "Applications (/Applications)",
        "dir_user_apps": "User Applications (~/Applications)",
        "chk_launch": "Launch OmniFlow after installation",
        "chk_clear_quarantine": "Clear Gatekeeper quarantine attribute (xattr)",
        "btn_install": "Install",
        "btn_reinstall": "Reinstall",
        "btn_uninstall": "Uninstall",
        "btn_finish": "Finish",
        "btn_close": "Close",
        "prog_installing": "Installing OmniFlow...",
        "prog_uninstalling": "Uninstalling OmniFlow...",
        "done_install_title": "Installation Complete",
        "done_install_sub": "Native build installed cleanly. Grant Accessibility permission when launching OmniFlow to enable KVM.",
        "done_uninstall_title": "OmniFlow Uninstalled",
        "done_uninstall_sub": "Stopped running instances and removed the application bundle.",
        "step_stop": "Stopping any running OmniFlow instance...",
        "step_locate": "Selecting architecture payload: ",
        "step_copy": "Installing bundle to: ",
        "step_xattr": "Clearing quarantine metadata...",
        "step_sign": "Verifying bundle signature...",
        "step_remove": "Removing installed bundle...",
        "step_done": "All steps completed.",
        "err_missing_payload": "Missing bundled payload for architecture: "
    ]
}
