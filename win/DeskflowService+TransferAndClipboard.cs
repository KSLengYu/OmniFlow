using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace MacBridgeUI;

public sealed partial class DeskflowService : IDisposable
{
    private static string ComputeBytesSha256Hex(byte[] data) =>
        Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

    private static string ComputeFilesSignature(IEnumerable<string> paths)
    {
        return string.Join(";", paths
            .Select(p =>
            {
                try
                {
                    if (File.Exists(p))
                    {
                        var fi = new FileInfo(p);
                        return $"{p}|{fi.Length}|{fi.LastWriteTimeUtc.Ticks}";
                    }
                    if (Directory.Exists(p))
                    {
                        var di = new DirectoryInfo(p);
                        return $"{p}|DIR|{di.LastWriteTimeUtc.Ticks}";
                    }
                }
                catch { }
                return p;
            })
            .OrderBy(s => s, StringComparer.OrdinalIgnoreCase));
    }

    private static byte[]? TryExtractClipboardPngBytes()
    {
        try
        {
            if (Clipboard.ContainsData("PNG"))
            {
                object? raw = Clipboard.GetData("PNG");
                if (raw is MemoryStream ms)
                {
                    byte[] arr = ms.ToArray();
                    if (arr.Length > 0) return arr;
                }
                else if (raw is byte[] bytes && bytes.Length > 0)
                {
                    return bytes;
                }
            }
            if (Clipboard.ContainsImage())
            {
                BitmapSource? src = Clipboard.GetImage();
                if (src != null)
                {
                    var encoder = new PngBitmapEncoder();
                    encoder.Frames.Add(BitmapFrame.Create(src));
                    using var outMs = new MemoryStream();
                    encoder.Save(outMs);
                    byte[] arr = outMs.ToArray();
                    if (arr.Length > 0) return arr;
                }
            }
        }
        catch { }
        return null;
    }

    private void StartClipboardWatcher()
    {
        _lastClipSeq = GetClipboardSequenceNumber();
        _clipboardTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(450) };
        _clipboardTimer.Tick += (_, _) =>
        {
            if (!ClipboardSyncEnabled) return;
            uint seq = GetClipboardSequenceNumber();
            if (seq == _lastClipSeq) return;
            _lastClipSeq = seq;
            if (DateTime.UtcNow < _suppressClipboardUntilUtc) return;
            if (Transport.ActiveLinksSnapshot().Count == 0) return;

            try
            {
                // 1. Files / Folders FIRST
                if (Clipboard.ContainsFileDropList())
                {
                    var drop = Clipboard.GetFileDropList();
                    var paths = drop.Cast<string>().Where(p => File.Exists(p) || Directory.Exists(p)).ToArray();
                    if (paths.Length > 0)
                    {
                        string sig = ComputeFilesSignature(paths);
                        if (sig != _lastRemoteClipboardFileSig)
                        {
                            _lastRemoteClipboardFileSig = sig;
                            BroadcastClipboardFilesToPeer(paths);
                        }
                        return;
                    }
                }

                // 2. Images / Screenshots
                byte[]? pngBytes = TryExtractClipboardPngBytes();
                if (pngBytes != null && pngBytes.Length > 0)
                {
                    string sha = ComputeBytesSha256Hex(pngBytes);
                    if (sha != _lastRemoteClipboardImageSha)
                    {
                        _lastRemoteClipboardImageSha = sha;
                        if (pngBytes.Length <= 14 * 1024 * 1024)
                        {
                            Transport.BroadcastControlFrame(DeskflowMsgType.ClipboardImage, pngBytes);
                            LogMessage?.Invoke($"[剪贴板] 已同步图片到 Mac ({pngBytes.Length / 1024.0:F0} KB)");
                        }
                        else
                        {
                            string tmp = Path.Combine(Path.GetTempPath(), $"ClipboardImage_{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}.png");
                            File.WriteAllBytes(tmp, pngBytes);
                            BroadcastClipboardFilesToPeer(new[] { tmp }, deleteAfterSend: tmp);
                        }
                    }
                    return;
                }

                // 3. Plain Text
                if (Clipboard.ContainsText())
                {
                    string txt = Clipboard.GetText();
                    if (!string.IsNullOrEmpty(txt) && txt != _lastRemoteClipboard)
                    {
                        _lastRemoteClipboard = txt;
                        byte[] bytes = Encoding.UTF8.GetBytes(txt);
                        Transport.BroadcastControlFrame(DeskflowMsgType.ClipboardText, bytes);
                        LogMessage?.Invoke($"[剪贴板] 已同步文字到 Mac ({txt.Length} 字符)");
                    }
                }
            }
            catch { }
        };
        _clipboardTimer.Start();
    }

    private void BroadcastClipboardFilesToPeer(string[] paths, string? deleteAfterSend = null)
    {
        var enabledIds = NicChannels.Where(x => x.Online && x.EnabledForMultipath).Select(x => x.Id).ToHashSet();
        bool useMultipath = MultipathEnabled;
        string countLabel = paths.Length == 1 ? Path.GetFileName(paths[0]) : $"{paths.Length} 项文件";

        _ = Task.Run(() =>
        {
            long totalBytes = MeasurePathsBytes(paths);
            if (totalBytes > 200L * 1024 * 1024)
            {
                _dispatcher.BeginInvoke(() =>
                    LogMessage?.Invoke("[剪贴板] 复制的文件超过 200 MB，改用直接拖入传送区会更快"));
                if (deleteAfterSend != null) try { File.Delete(deleteAfterSend); } catch { }
                return;
            }

            string sendPath = paths[0];
            bool isMulti = false;
            string? tempZip = null;

            if (paths.Length > 1)
            {
                tempZip = Path.Combine(Path.GetTempPath(), $"Clipboard_{paths.Length}items_{Guid.NewGuid():N}.zip");
                using (var archive = ZipFile.Open(tempZip, ZipArchiveMode.Create))
                {
                    foreach (var p in paths)
                    {
                        if (File.Exists(p))
                        {
                            archive.CreateEntryFromFile(p, Path.GetFileName(p), CompressionLevel.NoCompression);
                        }
                        else if (Directory.Exists(p))
                        {
                            string baseName = new DirectoryInfo(p).Name;
                            foreach (var file in Directory.GetFiles(p, "*", SearchOption.AllDirectories))
                            {
                                string rel = Path.GetRelativePath(p, file);
                                archive.CreateEntryFromFile(file, Path.Combine(baseName, rel), CompressionLevel.NoCompression);
                            }
                        }
                    }
                }
                sendPath = tempZip;
                isMulti = true;
            }

            _ = Transport.SendFileRealAsync(
                sendPath,
                "a",
                "blackhole",
                "left",
                0.5,
                useMultipath,
                enabledIds,
                (_, _, _, _, _) => { },
                (ok, msg) =>
                {
                    if (tempZip != null) try { File.Delete(tempZip); } catch { }
                    if (deleteAfterSend != null) try { File.Delete(deleteAfterSend); } catch { }
                    _dispatcher.BeginInvoke(() =>
                    {
                        if (ok) LogMessage?.Invoke($"[剪贴板] 已把复制的「{countLabel}」同步给 Mac");
                        else LogMessage?.Invoke($"[剪贴板] 同步文件失败: {msg}");
                    });
                },
                isClipboardItem: true,
                isClipboardMulti: isMulti);
        });
    }

    private static long MeasurePathsBytes(string[] paths)
    {
        long total = 0;
        foreach (var p in paths)
        {
            try
            {
                if (File.Exists(p))
                    total += new FileInfo(p).Length;
                else if (Directory.Exists(p))
                {
                    foreach (var f in Directory.GetFiles(p, "*", SearchOption.AllDirectories))
                    {
                        total += new FileInfo(f).Length;
                        if (total > 200L * 1024 * 1024) return total;
                    }
                }
            }
            catch { }
            if (total > 200L * 1024 * 1024) return total;
        }
        return total;
    }

    public double EstimatedThroughputBytesPerSec()
    {
        var links = Transport.ActiveLinksSnapshot();
        var enabledKeys = NicChannels.Where(c => c.EnabledForMultipath).Select(c => c.ChannelKey).ToHashSet();
        var filtered = links.Where(l => enabledKeys.Contains(NicChannelItem.CanonicalChannelKey(l.IfaceName, l.LocalIp, l.IsUsbBridge, l.PeerIp))).ToList();
        var pool = filtered.Count > 0 ? filtered : links;
        if (pool.Count == 0) return 0;

        static double LinkBps(PeerLinkSession l)
        {
            if (l.MeasuredBytesPerSec.HasValue && l.MeasuredBytesPerSec.Value > 64 * 1024)
                return l.MeasuredBytesPerSec.Value;
            if (l.IsUsbBridge) return DragHandoffPolicy.FallbackUsbBytesPerSec;
            bool isWifi = l.IfaceName.Contains("WLAN", StringComparison.OrdinalIgnoreCase) || l.IfaceName.Contains("Wi-Fi", StringComparison.OrdinalIgnoreCase);
            return isWifi ? DragHandoffPolicy.FallbackWifiBytesPerSec : DragHandoffPolicy.FallbackLanBytesPerSec;
        }

        if (MultipathEnabled && pool.Count > 1)
            return pool.Sum(LinkBps);
        return pool.Max(LinkBps);
    }

    public void EvaluateShelfDrag(string[] paths)
    {
        if (paths.Length == 0) return;
        string title = paths.Length > 1
            ? (AppLoc.Shared.IsEnglish ? $"{Path.GetFileName(paths[0])} +{paths.Length - 1} more" : $"{Path.GetFileName(paths[0])} 等 {paths.Length} 项")
            : Path.GetFileName(paths[0]);
        bool hasPeer = Transport.ActiveLinksSnapshot().Count > 0;
        double estBps = EstimatedThroughputBytesPerSec();
        string targetName = string.IsNullOrWhiteSpace(Transport.PeerHostName) ? "Mac" : Transport.PeerHostName;

        HoverPromptTitle = title;
        HoverIsLargeFile = true;
        HoverCanSubmit = hasPeer;
        HoverPromptDetail = hasPeer
            ? AppLoc.T("正在计算大小... 松手放上传输架 · 移开取消", "Calculating size... Release on shelf to send · Move away to cancel")
            : AppLoc.T("尚未连上对端设备 · 无法发送（移开取消）", "Peer not connected · Move away to cancel");
        Phase = PortalTransferPhase.HoverExpand;
        StateUpdated?.Invoke();

        _ = Task.Run(() =>
        {
            var scan = MeasurePathsReliable(paths);
            string sz = scan.TotalBytes.HasValue
                ? (scan.Reliable ? DeskflowTransport.FormatBytes(scan.TotalBytes.Value) : $"{AppLoc.T("至少", "At least")} {DeskflowTransport.FormatBytes(scan.TotalBytes.Value)}")
                : AppLoc.T("大小无法读取", "Size unavailable");
            string detail;
            bool canSubmit = hasPeer;
            if (!hasPeer || estBps <= 0)
            {
                detail = AppLoc.T("尚未连上对端设备 · 无法发送（移开取消）", "Peer not connected · Move away to cancel");
                canSubmit = false;
            }
            else if (!scan.Reliable || !scan.TotalBytes.HasValue)
            {
                detail = AppLoc.Shared.IsEnglish
                    ? $"{sz} · Size estimate unavailable · To {targetName} · Release to send"
                    : $"{sz} · 大小无法估算 · 发往 {targetName} · 松手仍可后台传";
            }
            else
            {
                double estSec = scan.TotalBytes.Value / estBps;
                double speedMB = estBps / (1024.0 * 1024.0);
                string secStr = estSec < 1.0
                    ? AppLoc.T("< 1 秒", "< 1s")
                    : (AppLoc.Shared.IsEnglish ? $"~{Math.Ceiling(estSec):F0}s" : $"约 {Math.Ceiling(estSec):F0} 秒");
                detail = AppLoc.Shared.IsEnglish
                    ? $"{sz} · To {targetName} · Est. {secStr} ({speedMB:F0} MB/s) · Release to send"
                    : $"{sz} · 发往 {targetName} · 预计 {secStr} ({speedMB:F0} MB/s) · 松手开始传";
            }

            _dispatcher.BeginInvoke(() =>
            {
                if (Phase != PortalTransferPhase.HoverExpand) return;
                HoverCanSubmit = canSubmit;
                HoverPromptTitle = title;
                HoverPromptDetail = detail;
                StateUpdated?.Invoke();
            });
        });
    }

    private static (ulong? TotalBytes, int Count, bool Reliable) MeasurePathsReliable(string[] paths)
    {
        ulong total = 0;
        int count = 0;
        bool reliable = true;

        foreach (var p in paths)
        {
            try
            {
                if (File.Exists(p))
                {
                    total += (ulong)new FileInfo(p).Length;
                    count++;
                }
                else if (Directory.Exists(p))
                {
                    count++;
                    foreach (var f in Directory.EnumerateFiles(p, "*", SearchOption.AllDirectories))
                    {
                        try { total += (ulong)new FileInfo(f).Length; }
                        catch { reliable = false; }
                        count++;
                        if (count > DragHandoffPolicy.EstimationScanBudgetCount)
                        {
                            reliable = false;
                            break;
                        }
                    }
                }
                else
                {
                    reliable = false;
                }
            }
            catch
            {
                reliable = false;
            }
        }
        if (!reliable && total == 0) return (null, Math.Max(1, count), false);
        return (total, Math.Max(1, count), reliable);
    }

    public void BeginShelfDragOut(string[] paths)
    {
        IsDraggingOutFromShelf = true;
        _recentDraggedOutPaths = new HashSet<string>(paths.Select(p => Path.GetFullPath(p)), StringComparer.OrdinalIgnoreCase);
        if (Phase == PortalTransferPhase.HoverExpand)
        {
            Phase = PortalTransferPhase.Idle;
            StateUpdated?.Invoke();
        }
    }

    public void EndShelfDragOut()
    {
        IsDraggingOutFromShelf = false;
        _dragOutEndedUtc = DateTime.UtcNow;
    }

    public bool ShouldIgnoreShelfDrop(string[]? paths = null)
    {
        if (IsDraggingOutFromShelf) return true;
        double elapsed = (DateTime.UtcNow - _dragOutEndedUtc).TotalSeconds;
        if (elapsed < DragOutReentryCooldownSeconds) return true;
        if (elapsed < 4.0 && paths != null && paths.Length > 0 && _recentDraggedOutPaths.Count > 0)
        {
            if (paths.All(p => { try { return _recentDraggedOutPaths.Contains(Path.GetFullPath(p)); } catch { return false; } }))
                return true;
        }
        return false;
    }

    public void SendFilesFromWindows(string[] paths, string? retryItemId = null)
    {
        if (paths.Length == 0) return;
        if (retryItemId == null)
        {
            if (ShouldIgnoreShelfDrop(paths)) return;
            string sig = string.Join("|", paths.Select(p => { try { return Path.GetFullPath(p); } catch { return p; } }).OrderBy(x => x, StringComparer.OrdinalIgnoreCase));
            var now = DateTime.UtcNow;
            if (sig == _lastDropSignature && (now - _lastDropSubmittedUtc).TotalSeconds < 1.5)
                return;
            _lastDropSignature = sig;
            _lastDropSubmittedUtc = now;
        }
        string taskId = retryItemId ?? Guid.NewGuid().ToString();
        string title = paths.Length > 1
            ? (AppLoc.Shared.IsEnglish ? $"{Path.GetFileName(paths[0])} +{paths.Length - 1} more" : $"{Path.GetFileName(paths[0])} 等 {paths.Length} 项")
            : Path.GetFileName(paths[0]);

        var enabledIds = NicChannels.Where(x => x.Online && x.EnabledForMultipath && !x.ManuallyDisconnected).Select(x => x.Id).ToHashSet();

        var existingCard = ShelfItems.FirstOrDefault(s => s.Id == taskId);
        if (existingCard != null) ShelfItems.Remove(existingCard);
        var card = new ShelfTransferItem
        {
            Id = taskId,
            Direction = ShelfDirection.Outgoing,
            Status = ShelfItemStatus.Transferring,
            Title = title,
            SizeText = AppLoc.T("准备中...", "Preparing..."),
            ItemCount = paths.Length,
            Progress = 0.03,
            SpeedMbps = EffectiveTransferMbps,
            ChannelTag = ActiveDataSummary,
            SourcePaths = paths.ToList()
        };
        ShelfItems.Insert(0, card);

        if (Transport.ActiveLinksSnapshot().Count == 0)
        {
            Phase = PortalTransferPhase.Idle;
            string warn = AppLoc.T($"尚未连接 Mac 对端，无法发送 {title}", $"Mac peer offline; cannot send {title}");
            card.SizeText = AppLoc.T("未连接", "Offline");
            card.ErrorText = warn;
            card.Status = ShelfItemStatus.Failed;
            LastTransferSummary = warn;
            LogMessage?.Invoke($"[传文件警告] {warn}");
            StateUpdated?.Invoke();
            return;
        }

        string style = EffectStyle == PortalEffectStyle.FloatingCube ? "cube" : "blackhole";
        string edge = EdgeSide.ToString().ToLowerInvariant();

        ActiveFileName = title;
        ActiveFileSize = AppLoc.T("准备中...", "Preparing...");
        ActiveSpeedMbps = EffectiveTransferMbps;
        ActiveChannelTag = ActiveDataSummary;
        TransferProgress = 0.03;
        Phase = PortalTransferPhase.SuckingIn;
        StateUpdated?.Invoke();

        _ = Task.Run(() =>
        {
            var scan = MeasurePathsReliable(paths);
            ulong estBytes = scan.TotalBytes ?? 1024 * 1024;
            string sizeStr = scan.Reliable ? DeskflowTransport.FormatBytes(estBytes) : "大小待确认";

            string sendPath = paths[0];
            bool isBatchBundle = false;
            string? tempBatchZip = null;
            if (paths.Length > 1)
            {
                string zipName = SecurityValidation.IsValidSingleFileName($"{Path.GetFileName(paths[0])}等{paths.Length}项.zip")
                    ? $"{Path.GetFileName(paths[0])}等{paths.Length}项.zip"
                    : $"OmniFlow_Batch_{paths.Length}items.zip";
                tempBatchZip = Path.Combine(Path.GetTempPath(), $"{Guid.NewGuid():N}_{zipName}");
                try
                {
                    using var archive = ZipFile.Open(tempBatchZip, ZipArchiveMode.Create);
                    foreach (var p in paths)
                    {
                        if (File.Exists(p))
                        {
                            archive.CreateEntryFromFile(p, Path.GetFileName(p), CompressionLevel.NoCompression);
                        }
                        else if (Directory.Exists(p))
                        {
                            string baseName = new DirectoryInfo(p).Name;
                            foreach (var file in Directory.GetFiles(p, "*", SearchOption.AllDirectories))
                            {
                                string rel = Path.GetRelativePath(p, file);
                                archive.CreateEntryFromFile(file, Path.Combine(baseName, rel), CompressionLevel.NoCompression);
                            }
                        }
                    }
                    sendPath = tempBatchZip;
                    isBatchBundle = true;
                }
                catch
                {
                    try { if (File.Exists(tempBatchZip)) File.Delete(tempBatchZip); } catch { }
                    tempBatchZip = null;
                }
            }

            ulong reqFree = isBatchBundle ? estBytes * 2 : estBytes;

            _dispatcher.BeginInvoke(() =>
            {
                card.SizeText = sizeStr;
                ActiveFileSize = sizeStr;
                StateUpdated?.Invoke();

                _ = Transport.SendFileRealAsync(
                    sendPath, "b", style, edge, EdgeOffsetRatio, MultipathEnabled, enabledIds,
                    (p, spd, fname, fsize, chTag) =>
                    {
                        _dispatcher.BeginInvoke(() =>
                        {
                            card.Progress = p;
                            card.SpeedMbps = spd;
                            card.ChannelTag = chTag;
                            card.SizeText = fsize;
                            ActiveFileName = title;
                            ActiveFileSize = fsize;
                            ActiveSpeedMbps = spd;
                            ActiveChannelTag = chTag;
                            TransferProgress = p;
                            Phase = PortalTransferPhase.SuckingIn;
                            StateUpdated?.Invoke();
                        });
                    },
                    (ok, msg) =>
                    {
                        if (tempBatchZip != null) try { File.Delete(tempBatchZip); } catch { }
                        _dispatcher.BeginInvoke(() =>
                        {
                            LogMessage?.Invoke(ok ? $"[传文件] {msg}" : $"[传文件失败] {msg}");
                            LastTransferSummary = msg;
                            if (ok)
                            {
                                ShelfItems.Remove(card);
                                TransferProgress = 1.0;
                                Phase = PortalTransferPhase.Completed;
                            }
                            else
                            {
                                card.ErrorText = msg;
                                card.Status = ShelfItemStatus.Failed;
                                Phase = PortalTransferPhase.Idle;
                            }
                            StateUpdated?.Invoke();
                        });
                    },
                    isClipboardItem: false,
                    isClipboardMulti: false,
                    batchItemCount: paths.Length,
                    isBatchBundle: isBatchBundle,
                    requiredFreeBytes: reqFree);
            });
        });
    }

    public void RetryShelfItem(string id)
    {
        var item = ShelfItems.FirstOrDefault(s => s.Id == id && s.Direction == ShelfDirection.Outgoing);
        if (item == null || item.SourcePaths.Count == 0) return;
        SendFilesFromWindows(item.SourcePaths.ToArray(), retryItemId: id);
    }

    public void RemoveShelfItem(string id)
    {
        var item = ShelfItems.FirstOrDefault(s => s.Id == id);
        if (item != null)
        {
            ShelfItems.Remove(item);
            StateUpdated?.Invoke();
        }
    }

    public void MarkShelfItemDeliveredByDrag(string id)
    {
        var item = ShelfItems.FirstOrDefault(s => s.Id == id);
        if (item != null)
        {
            ShelfItems.Remove(item);
            LogMessage?.Invoke($"[传输架] 目标应用已接收文件: {item.Title}");
            StateUpdated?.Invoke();
        }
    }

    public void OpenShelfItem(string id)
    {
        var item = ShelfItems.FirstOrDefault(s => s.Id == id);
        if (item == null || string.IsNullOrEmpty(item.PrimaryPath)) return;
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = item.PrimaryPath,
                UseShellExecute = true
            });
            ShelfItems.Remove(item);
            LogMessage?.Invoke($"[传输架] 已打开并从收件架移出: {item.Title}");
            StateUpdated?.Invoke();
        }
        catch (Exception ex)
        {
            LogMessage?.Invoke($"[传输架警告] 打开失败: {ex.Message}");
        }
    }

    public void RevealShelfItem(string id)
    {
        var item = ShelfItems.FirstOrDefault(s => s.Id == id);
        if (item == null || string.IsNullOrEmpty(item.PrimaryPath)) return;
        try
        {
            System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{item.PrimaryPath}\"");
        }
        catch { }
    }

}
