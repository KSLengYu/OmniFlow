using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;

namespace MacBridgeUI;

/// <summary>
/// Thread-safe bilingual string provider & GitHub profile sync for OmniFlow Windows UI.
/// Uses indexer binding ({Binding [Key], Source={x:Static local:AppLoc.Shared}}) so even
/// elements inside ControlTemplates and DataTemplates switch instantaneously.
/// </summary>
public sealed class AppLoc : INotifyPropertyChanged
{
    public static readonly AppLoc Shared = new();

    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action? LanguageChanged;

    private bool _isEnglish;
    private string _githubDisplayName = "楞宇";
    private string _githubHandle = "@KSLengYu";
    private bool _didFetchGitHub;

    public const string GitHubProfileUrl = "https://github.com/KSLengYu";

    public bool IsEnglish
    {
        get => _isEnglish;
        set
        {
            if (_isEnglish == value) return;
            _isEnglish = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsEnglish)));
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs("Item[]"));
            LanguageChanged?.Invoke();
        }
    }

    public string GitHubDisplayName
    {
        get => _githubDisplayName;
        private set
        {
            if (_githubDisplayName == value) return;
            _githubDisplayName = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(GitHubDisplayName)));
        }
    }

    public string GitHubHandle => _githubHandle;

    public static string T(string zh, string en) => Shared.IsEnglish ? en : zh;

    public string this[string key]
    {
        get
        {
            if (_dict.TryGetValue(key, out var pair))
                return _isEnglish ? pair.En : pair.Zh;
            return key;
        }
    }

    public void RefreshDynamicProperties()
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs("Item[]"));
    }

    public void SyncGitHubProfileAsync()
    {
        if (_didFetchGitHub) return;
        _didFetchGitHub = true;

        _ = Task.Run(async () =>
        {
            try
            {
                using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(4) };
                http.DefaultRequestHeaders.UserAgent.ParseAdd("OmniFlow/1.0");
                http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
                string json = await http.GetStringAsync("https://api.github.com/users/KSLengYu").ConfigureAwait(false);
                using var doc = JsonDocument.Parse(json);
                if (doc.RootElement.TryGetProperty("name", out var nameProp))
                {
                    string? synced = nameProp.GetString()?.Trim();
                    if (!string.IsNullOrEmpty(synced))
                    {
                        var disp = Application.Current?.Dispatcher;
                        if (disp != null)
                            _ = disp.BeginInvoke(() => GitHubDisplayName = synced);
                        else
                            GitHubDisplayName = synced;
                    }
                }
            }
            catch
            {
                // Silently keep fallback hardcoded GitHub display name when offline/rate-limited
            }
        });
    }

    private static readonly Dictionary<string, (string Zh, string En)> _dict = new()
    {
        // Sidebar Navigation
        ["NavDisplaysTitle"] = ("屏幕排列", "Displays"),
        ["NavDisplaysSub"] = ("拖一拖摆好位置", "Arrange monitors"),
        ["NavInputTitle"] = ("键鼠共享", "KVM & Keys"),
        ["NavInputSub"] = ("切换、剪贴板与快捷键", "Switch, clipboard & keys"),
        ["NavPortalTitle"] = ("跨屏传文件", "File Portal"),
        ["NavPortalSub"] = ("文件传输与历史", "Transfers & history"),
        ["NavUsbTitle"] = ("USB 直连", "USB Direct"),
        ["NavUsbSub"] = ("USB-C 直连", "USB-C tunnel"),
        ["NavNetworkTitle"] = ("网络与通道", "Network"),
        ["NavNetworkSub"] = ("连接与配对", "NICs & pairing"),
        ["SidebarHostPrefix"] = ("控制端：", "Active Host: "),

        // Pairing Banner
        ["RejectBtn"] = ("拒绝", "Reject"),
        ["ConfirmPairBtn"] = ("确认短码一致并配对", "Trust & Pair"),

        // Page 1: Displays
        ["Page1Title"] = ("屏幕排列", "Arrange Displays"),
        ["Page1Sub"] = ("拖动屏幕，调整它们的位置。", "Drag displays to arrange their layout."),
        ["SaveLayoutBtn"] = ("保存位置", "Save Layout"),
        ["IdentifyBtn"] = ("显示屏幕编号", "Identify"),
        ["ResetLayoutBtn"] = ("恢复默认排列", "Reset"),
        ["RefreshLayoutBtn"] = ("重新识别", "Refresh"),
        ["SnapHint"] = ("拖动屏幕调整位置，靠近时会自动对齐。", "Drag displays to reposition; edges snap automatically."),

        // Page 2: Input & Shortcuts
        ["Page2Title"] = ("键鼠共享", "KVM Input & Shortcuts"),
        ["Page2Sub"] = ("设置控制切换、剪贴板和快捷键。", "Configure focus switching, clipboard sync, and keybindings."),
        ["FocusSectionTitle"] = ("控制切换", "Focus Switching"),
        ["EnableKvmTitle"] = ("开启键鼠共享", "Enable Keyboard & Mouse Sharing"),
        ["EnableKvmSub"] = ("开启后可在两台电脑间切换控制。", "Allows switching input seamlessly between Windows and Mac."),
        ["EnableEdgeTitle"] = ("移到屏幕边缘时切换", "Switch on Screen Edge"),
        ["EnableEdgeSub"] = ("屏幕位置在「屏幕排列」中设置。", "Follows the geometry set in Arrange Displays."),
        ["EnableHotkeyTitle"] = ("快捷键切换控制权（Ctrl + Alt + S）", "Hotkey Focus Toggle (Ctrl + Alt + S)"),
        ["EnableHotkeySub"] = ("Ctrl + Alt + S 切换；Ctrl + Alt + Esc 返回 Windows。", "Ctrl + Alt + S toggles host; Ctrl + Alt + Esc returns to Windows."),
        ["EnableClipTitle"] = ("剪贴板同步（文字、图片和文件）", "Clipboard Sync (Text, Images & Files)"),
        ["EnableClipSub"] = ("复制后可在另一台电脑粘贴。", "Copy on one computer and paste directly on the other."),
        ["CtrlDirTitle"] = ("控制方向", "Control Direction"),
        ["CtrlDual"] = ("两边互控 (推荐)", "Bidirectional (Recommended)"),
        ["CtrlMacOnly"] = ("只用 Mac 控制 Windows", "Mac Controls Windows Only"),
        ["CtrlWinOnly"] = ("只用 Windows 控制 Mac", "Windows Controls Mac Only"),
        ["ModMapTitle"] = ("按键映射", "Modifier Mapping"),
        ["ModMapSub"] = ("Command 对应 Win，Option 对应 Alt。需要时可在下方设置快捷键。", "Command maps to Win; Option maps to Alt. Enable semantic rules below as needed."),
        ["ShortcutsCardTitle"] = ("快捷键与触控板手势", "Shortcuts & Trackpad"),
        ["ShortcutsCardSub"] = ("分别设置 Mac → Windows 和 Windows → Mac 的快捷键与手势。", "Configure Mac → Windows and Windows → Mac shortcuts and gestures separately."),
        ["TestShotBtn"] = ("试一下截图 (Win+Shift+S)", "Test Screenshot (Win+Shift+S)"),
        ["SaveSettingsBtn"] = ("保存设置", "Save Settings"),
        ["ShortcutListTitle"] = ("常用快捷键替换", "Semantic Shortcut Rules"),
        ["ThreeFingerWarn"] = ("提示：三指拖移对网络延迟较为敏感。高延迟或 Wi-Fi 波动较大时容易出现漂移或卡顿，建议在有线网线或 USB-C 直连环境下开启使用。",
                               "Note: Three-finger drag is sensitive to network latency. High RTT or unstable Wi-Fi may cause cursor drift or lag; wired Ethernet or USB-C Direct is recommended."),

        // Page 3: File Portal
        ["Page3Title"] = ("跨屏传文件", "File Portal & Transfers"),
        ["Page3Sub"] = ("把文件拖到下方区域或屏幕边缘，松手发送到 Mac。", "Drop files below or at the screen edge to send to Mac."),
        ["EnableOverlayTitle"] = ("启用边缘传输区", "Enable Screen-Edge Portal"),
        ["PortalStyleTitle"] = ("传输区样式", "Portal Style"),
        ["StyleHidden"] = ("隐藏边缘入口", "Hidden Edge Wall"),
        ["StyleCube"] = ("悬浮按钮", "Floating Drop Box"),
        ["EdgeRight"] = ("右边", "Right"),
        ["EdgeLeft"] = ("左边", "Left"),
        ["EdgeTop"] = ("顶边", "Top"),
        ["EdgeBottom"] = ("底边", "Bottom"),
        ["DropBoxTitle"] = ("把文件、文件夹或压缩包拖到这里", "Drop Files, Folders or Archives Here"),
        ["DropBoxSub"] = ("拖到边缘后，松手发送；拖回来取消。", "Drag to screen edge and release to send; pull back to cancel."),
        ["PickFileBtn"] = ("选文件发送...", "Choose File..."),
        ["PickFolderBtn"] = ("选文件夹发送...", "Choose Folder..."),
        ["ShelfDragHint"] = ("拖动卡片可取出文件", "Drag card to take files out"),
        ["ShelfOpenBtn"] = ("打开", "Open"),
        ["ShelfRevealBtn"] = ("定位", "Reveal"),
        ["ShelfRetryBtn"] = ("重试", "Retry"),
        ["ShelfRemoveBtn"] = ("移除", "Remove"),
        ["ReceivedTitle"] = ("收到的文件", "Received Files"),
        ["OpenFolderBtn"] = ("打开文件夹", "Open Folder"),
        ["EmptyReceivedHint"] = ("收到的文件会显示在这里。", "Received files will appear here."),
        ["ShowInFolderBtn"] = ("在文件夹中显示", "Show in Explorer"),

        // Page 4: USB Direct
        ["Page4Title"] = ("USB 直连", "USB Direct"),
        ["Page4Sub"] = ("连接 USB-C 后，点击“启动 USB 直连”。", "Plug in a USB-C cable and click \"Start USB Direct\"."),
        ["UsbConnectBtn"] = ("启动 USB 直连", "Start USB Direct"),
        ["UsbDisconnectBtn"] = ("断开", "Disconnect"),
        ["UsbRestoreBtn"] = ("恢复苹果原驱动", "Restore Apple Driver"),
        ["UsbProgressLabel"] = ("连接进度", "Progress"),
        ["UsbDevCardTitle"] = ("USB 设备", "USB Device"),
        ["UsbIpCardTitle"] = ("直连地址 (Win ↔ Mac)", "Tunnel IPs (Win ↔ Mac)"),
        ["UsbTrafficCardTitle"] = ("流量与延迟", "Packets & RTT"),
        ["UsbLogTitle"] = ("USB 日志", "USB Log"),

        // Page 5: Network
        ["Page5Title"] = ("网络与连接", "Network & Channels"),
        ["Page5Sub"] = ("查看网卡状态和延迟；大文件可使用多网卡传输。", "Monitor NIC latency and enable multi-NIC acceleration for large transfers."),
        ["PeerIpLabel"] = ("对端 IP：", "Peer IP:"),
        ["PeerIpTooltip"] = ("留空即可自动发现；有需要时也可填写对端 IP", "Leave blank for auto-discovery, or enter peer IP manually"),
        ["ConnectPeerBtn"] = ("连过去", "Connect"),
        ["MultipathChk"] = ("大文件使用多网卡传输", "Multi-NIC for large files"),
        ["NicListTitle"] = ("可用网卡和连接线路", "Available Network Interfaces"),
        ["JoinMultipath"] = ("参与并发", "Aggregate"),
        ["ClearTrustedBtn"] = ("清除全部配对记录", "Clear All Peers"),
        ["EmptyTrustedText"] = ("还没有配对设备。", "No paired devices yet."),
        ["RemoveBtn"] = ("移除", "Remove"),
        ["RuntimeLogTitle"] = ("运行日志", "Runtime Log"),

        // Close Modal
        ["CloseModalTitle"] = ("关闭 OmniFlow", "Close OmniFlow"),
        ["CloseModalBody"] = ("可以让 OmniFlow 留在后台运行，也可以退出。", "Keep OmniFlow running in the background or quit completely."),
        ["CloseModalHint"] = ("退出时会先清理并恢复 Apple 原厂驱动、停止所有服务后再关闭窗口。", "Quitting restores Apple USB drivers and stops all services before closing."),
        ["CloseModalStatus"] = ("正在准备停止服务...", "Preparing shutdown..."),
        ["CloseCancelBtn"] = ("取消", "Cancel"),
        ["CloseMinimizeBtn"] = ("最小化到后台", "Minimize"),
        ["CloseExitBtn"] = ("彻底退出并还原驱动", "Quit & Restore Drivers"),

        // Portal Overlay
        ["OverlayDockHint"] = ("拖动卡片取出，或点击打开", "Drag out or click Open"),
        ["OverlayOpenDir"] = ("打开目录", "Open Folder")
    };
}
