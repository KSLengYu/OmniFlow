using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace MacBridgeUI;

public sealed partial class DeskflowTransport
{
    private static bool SessionMatchesChannelFilter(PeerLinkSession session, HashSet<string> filterKeys)
    {
        if (filterKeys.Contains(session.Id) || filterKeys.Contains(session.IfaceName) || filterKeys.Contains(session.LocalIp))
            return true;
        string canon = NicChannelItem.CanonicalChannelKey(session.IfaceName, session.LocalIp, session.IsUsbBridge, session.PeerIp);
        if (filterKeys.Contains(canon))
            return true;
        string baseCanon = NicChannelItem.CanonicalChannelKey(session.IfaceName, session.LocalIp, session.IsUsbBridge);
        return filterKeys.Contains(baseCanon);
    }

    public Task SendFileRealAsync(
        string sourcePath,
        string scheme,
        string style,
        string edge,
        double offset,
        bool multipath,
        HashSet<string> enabledLinkIds,
        Action<double, double, string, string, string> onProgress,
        Action<bool, string> onFinished,
        bool isClipboardItem = false,
        bool isClipboardMulti = false,
        int? batchItemCount = null,
        bool isBatchBundle = false,
        ulong? requiredFreeBytes = null)
    {
        return Task.Run(async () =>
        {
            var allActive = ActiveLinksSnapshot();
            var active = allActive.Where(l => enabledLinkIds.Count == 0 || SessionMatchesChannelFilter(l, enabledLinkIds)).ToList();
            if (active.Count == 0)
            {
                onFinished(false, "未连接 Mac 对端，无法发送文件");
                return;
            }

            string sendPath = sourcePath;
            string displayName = Path.GetFileName(sourcePath);
            bool isZip = isClipboardMulti || isBatchBundle;
            string? tempZip = null;

            if (Directory.Exists(sourcePath))
            {
                displayName += ".zip";
                isZip = true;
                onProgress(0.03, active.Max(a => a.EstBandwidthMbps), displayName, "打包目录中...", active[0].IfaceName);
                tempZip = Path.Combine(Path.GetTempPath(), $"mb_send_{Guid.NewGuid():N}.zip");
                ZipFile.CreateFromDirectory(sourcePath, tempZip, CompressionLevel.NoCompression, includeBaseDirectory: true);
                sendPath = tempZip;
            }

            Interlocked.Increment(ref _activeBulkTransfers);
            string transferId = "";
            try
            {
                var fi = new FileInfo(sendPath);
                if (!fi.Exists)
                {
                    onFinished(false, "文件不存在");
                    return;
                }

                ulong totalBytes = (ulong)fi.Length;
                const int chunkSize = 256 * 1024;
                int totalChunks = Math.Max(1, (int)((totalBytes + (ulong)chunkSize - 1) / (ulong)chunkSize));
                transferId = Guid.NewGuid().ToString();
                string sizeStr = FormatBytes(totalBytes);

                var workers = (multipath && active.Count > 1 && totalChunks >= 8)
                    ? active.OrderByDescending(l => l.EstBandwidthMbps).ToList()
                    : new List<PeerLinkSession> { active.OrderByDescending(l => l.EstBandwidthMbps).First() };

                string channelTag = workers.Count > 1
                    ? $"{workers.Count}路并发(" + string.Join("+", workers.Select(w => w.IfaceName)) + ")"
                    : workers[0].IfaceName;

                ulong reqFree = requiredFreeBytes ?? (isZip ? totalBytes * 2 : totalBytes);
                await workers[0].SendJsonAsync(DeskflowMsgType.FileOffer, new WireFileOfferPayload
                {
                    TransferId = transferId,
                    FileName = displayName,
                    TotalBytes = totalBytes,
                    ChunkSize = chunkSize,
                    TotalChunks = totalChunks,
                    Scheme = scheme,
                    Style = style,
                    Edge = edge,
                    Offset = offset,
                    IsDirectoryZip = isZip,
                    IsClipboardItem = isClipboardItem,
                    IsClipboardMulti = isClipboardMulti,
                    RequiredFreeBytes = reqFree,
                    BatchItemCount = batchItemCount,
                    IsBatchBundle = isBatchBundle
                });

                var start = DateTime.UtcNow;
                int nextChunk = -1;
                long sentBytes = 0;
                long lastUiTickMs = 0;
                string? sendFailureReason = null;
                byte[] idBytes = Encoding.ASCII.GetBytes(transferId.PadRight(36)[..36]);

                onProgress(0.05, workers.Sum(w => w.EstBandwidthMbps), displayName, sizeStr, channelTag);

                using var fs = new FileStream(sendPath, FileMode.Open, FileAccess.Read, FileShare.Read);
                var readLock = new object();

                var tasks = workers.Select(async worker =>
                {
                    while (true)
                    {
                        if (Volatile.Read(ref sendFailureReason) != null) break;
                        int idx = Interlocked.Increment(ref nextChunk);
                        if (idx >= totalChunks) break;

                        long byteOffset = (long)idx * chunkSize;
                        int readLen = (int)Math.Min(chunkSize, (long)totalBytes - byteOffset);
                        byte[] payload = new byte[36 + 4 + readLen];
                        Buffer.BlockCopy(idBytes, 0, payload, 0, 36);
                        payload[36] = (byte)((idx >> 24) & 0xFF);
                        payload[37] = (byte)((idx >> 16) & 0xFF);
                        payload[38] = (byte)((idx >> 8) & 0xFF);
                        payload[39] = (byte)(idx & 0xFF);

                        int r = 0;
                        lock (readLock)
                        {
                            fs.Position = byteOffset;
                            while (r < readLen)
                            {
                                int n = fs.Read(payload, 40 + r, readLen - r);
                                if (n <= 0) break;
                                r += n;
                            }
                        }
                        if (r != readLen)
                        {
                            Interlocked.CompareExchange(ref sendFailureReason, $"读取第 {idx} 块长度不完整 ({r} != {readLen})", null);
                            break;
                        }

                        bool chunkSent = await worker.SendFrameAsync(DeskflowMsgType.FileChunk, payload);
                        if (!chunkSent)
                        {
                            Interlocked.CompareExchange(ref sendFailureReason, $"通道 {worker.IfaceName} 发送第 {idx} 块失败或断线", null);
                            break;
                        }
                        if (totalChunks <= 6)
                        {
                            await Task.Delay(75);
                        }
                        long cur = Interlocked.Add(ref sentBytes, readLen);
                        long nowTick = Environment.TickCount64;
                        long prevTick = Volatile.Read(ref lastUiTickMs);
                        if (cur >= (long)totalBytes || nowTick - prevTick >= 55)
                        {
                            if (Interlocked.CompareExchange(ref lastUiTickMs, nowTick, prevTick) == prevTick || cur >= (long)totalBytes)
                            {
                                double elapsed = Math.Max(0.01, (DateTime.UtcNow - start).TotalSeconds);
                                double speedMbps = (cur * 8.0) / (elapsed * 1_000_000.0);
                                foreach (var w in workers)
                                    w.EstBandwidthMbps = Math.Clamp(speedMbps / workers.Count, 40.0, 5000.0);
                                double p = totalBytes == 0 ? 1.0 : Math.Min(1.0, (double)cur / totalBytes);
                                onProgress(p, speedMbps, displayName, sizeStr, channelTag);

                                if (!isClipboardItem)
                                {
                                    _ = workers[0].SendJsonAsync(DeskflowMsgType.PortalSync, new WirePortalSyncPayload
                                    {
                                        TransferId = transferId,
                                        Style = style,
                                        Edge = edge,
                                        Offset = offset,
                                        Phase = "emergingOut",
                                        Progress = p,
                                        FileName = displayName,
                                        FileSize = sizeStr,
                                        SpeedMbps = speedMbps,
                                        ChannelTag = channelTag
                                    });
                                }
                            }
                        }
                    }
                });

                await Task.WhenAll(tasks);

                if (sendFailureReason != null)
                {
                    LogMessage?.Invoke($"[Transfer Error] [Tid={transferId}] stage=send_chunks error={sendFailureReason}");
                    if (!isClipboardItem)
                    {
                        _ = workers[0].SendJsonAsync(DeskflowMsgType.PortalSync, new WirePortalSyncPayload
                        {
                            TransferId = transferId, Style = style, Edge = edge, Offset = offset,
                            Phase = "idle", Progress = 0, FileName = displayName, FileSize = sizeStr, SpeedMbps = 0, ChannelTag = channelTag
                        });
                    }
                    onFinished(false, $"发送失败: {sendFailureReason}");
                    return;
                }

                string shaHex = SecurityValidation.ComputeFileSha256Hex(sendPath);
                var ackTcs = new TaskCompletionSource<WireFileAckPayload>(TaskCreationOptions.RunContinuationsAsynchronously);
                _pendingAckLinks[transferId] = workers[0].Id;
                _pendingFileAcks[transferId] = ackTcs;

                bool compSent = await workers[0].SendJsonAsync(DeskflowMsgType.FileComplete, new WireFileCompletePayload
                {
                    TransferId = transferId,
                    Sha256 = shaHex
                });
                if (!compSent)
                {
                    _pendingAckLinks.TryRemove(transferId, out _);
                    _pendingFileAcks.TryRemove(transferId, out _);
                    LogMessage?.Invoke($"[Transfer Error] [Tid={transferId}] stage=send_complete error=写入完成帧失败");
                    onFinished(false, "发送完成确认包失败");
                    return;
                }

                using var ackTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(isZip ? 35 : 20));
                WireFileAckPayload? ack = null;
                try
                {
                    ack = await ackTcs.Task.WaitAsync(ackTimeout.Token);
                }
                catch (TimeoutException)
                {
                    _pendingAckLinks.TryRemove(transferId, out _);
                    _pendingFileAcks.TryRemove(transferId, out _);
                    LogMessage?.Invoke($"[Transfer Error] [Tid={transferId}] stage=wait_ack error=对端校验确认超时");
                    onFinished(false, "对端校验确认超时（可能未成功落盘）");
                    return;
                }

                if (ack == null || !ack.Ok)
                {
                    string errDetail = ack?.Error ?? "对端完整性校验未通过";
                    LogMessage?.Invoke($"[Transfer Error] [Tid={transferId}] stage=peer_nack error={errDetail}");
                    if (!isClipboardItem)
                    {
                        _ = workers[0].SendJsonAsync(DeskflowMsgType.PortalSync, new WirePortalSyncPayload
                        {
                            TransferId = transferId, Style = style, Edge = edge, Offset = offset,
                            Phase = "idle", Progress = 0, FileName = displayName, FileSize = sizeStr, SpeedMbps = 0, ChannelTag = channelTag
                        });
                    }
                    onFinished(false, $"传输失败: {errDetail}");
                    return;
                }

                if (!isClipboardItem)
                {
                    await workers[0].SendJsonAsync(DeskflowMsgType.PortalSync, new WirePortalSyncPayload
                    {
                        TransferId = transferId,
                        Style = style,
                        Edge = edge,
                        Offset = offset,
                        Phase = "completed",
                        Progress = 1.0,
                        FileName = displayName,
                        FileSize = sizeStr,
                        SpeedMbps = 0,
                        ChannelTag = channelTag
                    });
                }

                if (totalBytes >= 128 * 1024)
                {
                    double totalSec = Math.Max(0.01, (DateTime.UtcNow - start).TotalSeconds);
                    double perWorker = Math.Max(256.0 * 1024.0, (totalBytes / totalSec) / Math.Max(1, workers.Count));
                    foreach (var w in workers)
                        w.MeasuredBytesPerSec = w.MeasuredBytesPerSec.HasValue ? w.MeasuredBytesPerSec.Value * 0.4 + perWorker * 0.6 : perWorker;
                }

                onFinished(true, $"已验证 SHA-256 并送达 {displayName} ({sizeStr}) 经由 {channelTag}");
            }
            catch (Exception ex)
            {
                _pendingAckLinks.TryRemove(transferId, out _);
                _pendingFileAcks.TryRemove(transferId, out _);
                LogMessage?.Invoke($"[Transfer Error] [Tid={transferId}] stage=send_exception error={ex.Message}");
                onFinished(false, ex.Message);
            }
            finally
            {
                Interlocked.Decrement(ref _activeBulkTransfers);
                if (tempZip != null)
                {
                    try { File.Delete(tempZip); }
                    catch (Exception ex) { LogMessage?.Invoke($"[Cleanup Warn] {ex.Message}"); }
                }
            }
        });
    }

    private void HandleIncomingFileOffer(WireFileOfferPayload offer, PeerLinkSession link)
    {
        string? validationErr = SecurityValidation.ValidateFileOffer(offer);
        if (validationErr != null)
        {
            LogMessage?.Invoke($"[Transfer Error] [Link={link.Id}] [Tid={offer.TransferId}] stage=offer_validate error={validationErr}");
            _ = link.SendJsonAsync(DeskflowMsgType.FileAck, new WireFileAckPayload
            {
                TransferId = offer.TransferId,
                Ok = false,
                SavedPath = "",
                Error = validationErr
            });
            return;
        }

        string dl;
        if (offer.IsClipboardItem)
        {
            string clipRoot = Path.Combine(OmniFlowPaths.AppDataDirectory, "ClipboardCache");
            Directory.CreateDirectory(clipRoot);
            PruneOldClipboardBatches(clipRoot, keepCount: 6);
            string sub = offer.TransferId.Length >= 8 ? offer.TransferId[..8] : offer.TransferId;
            dl = Path.Combine(clipRoot, sub);
        }
        else
        {
            dl = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "OmniFlow");
        }
        Directory.CreateDirectory(dl);

        try
        {
            string? root = Path.GetPathRoot(Path.GetFullPath(dl));
            if (!string.IsNullOrEmpty(root))
            {
                var di = new DriveInfo(root);
                ulong required = Math.Max(offer.RequiredFreeBytes ?? offer.TotalBytes, offer.TotalBytes) + DragHandoffPolicy.RequiredDiskMarginBytes;
                if (di.IsReady && (ulong)di.AvailableFreeSpace < required)
                {
                    string err = $"目标磁盘可用空间不足（需要 {FormatBytes(required)}）";
                    LogMessage?.Invoke($"[Transfer Error] [Link={link.Id}] [Tid={offer.TransferId}] stage=disk_space error={err}");
                    _ = link.SendJsonAsync(DeskflowMsgType.FileAck, new WireFileAckPayload { TransferId = offer.TransferId, Ok = false, SavedPath = "", Error = err });
                    TransferFailed?.Invoke(offer.FileName, err);
                    return;
                }
            }
        }
        catch { }

        string stagingDir = Path.Combine(dl, $".stage_{offer.TransferId}");
        try
        {
            if (Directory.Exists(stagingDir)) Directory.Delete(stagingDir, true);
            Directory.CreateDirectory(stagingDir);
        }
        catch (Exception ex)
        {
            string reason = $"无法创建暂存目录: {ex.Message}";
            LogMessage?.Invoke($"[Transfer Error] [Tid={offer.TransferId}] stage=create_stage error={reason}");
            _ = link.SendJsonAsync(DeskflowMsgType.FileAck, new WireFileAckPayload { TransferId = offer.TransferId, Ok = false, SavedPath = "", Error = reason });
            TransferFailed?.Invoke(offer.FileName, reason);
            return;
        }

        string tmp = Path.Combine(stagingDir, "payload.part");
        FileStream fs;
        try
        {
            fs = new FileStream(tmp, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        }
        catch (Exception ex)
        {
            try { Directory.Delete(stagingDir, true); } catch { }
            string reason = $"无法创建暂存文件: {ex.Message}";
            LogMessage?.Invoke($"[Transfer Error] [Tid={offer.TransferId}] stage=open_temp error={reason}");
            _ = link.SendJsonAsync(DeskflowMsgType.FileAck, new WireFileAckPayload { TransferId = offer.TransferId, Ok = false, SavedPath = "", Error = reason });
            TransferFailed?.Invoke(offer.FileName, reason);
            return;
        }

        var st = new IncomingFileState
        {
            Offer = offer,
            StagingDir = stagingDir,
            TempPath = tmp,
            FinalParentDir = dl,
            Stream = fs
        };

        if (_incomingFiles.TryRemove(offer.TransferId, out var prev))
        {
            lock (prev.SyncLock)
            {
                try { prev.PendingGraceCts?.Cancel(); prev.PendingGraceCts?.Dispose(); } catch { }
                try { prev.Stream.Dispose(); } catch { }
                try { if (Directory.Exists(prev.StagingDir)) Directory.Delete(prev.StagingDir, true); } catch { }
            }
        }
        if (_earlyFileChunks.TryRemove(offer.TransferId, out var earlyChunks))
        {
            lock (st.SyncLock)
            {
                foreach (var c in earlyChunks)
                {
                    Interlocked.Add(ref _earlyChunkTotalBytes, -c.Data.Length);
                    ApplyIncomingChunkLocked(st, offer.TransferId, c.Idx, c.Data, c.LinkId);
                }
            }
        }
        _incomingFiles[offer.TransferId] = st;

        if (!offer.IsClipboardItem)
        {
            RemotePortalSync?.Invoke(new WirePortalSyncPayload
            {
                TransferId = offer.TransferId,
                Style = offer.Style,
                Edge = offer.Edge,
                Offset = offer.Offset,
                Phase = "emergingOut",
                Progress = 0.08,
                FileName = offer.FileName,
                FileSize = FormatBytes(offer.TotalBytes),
                SpeedMbps = 0,
                ChannelTag = "Peer"
            });
        }
    }

    private static void PruneOldClipboardBatches(string root, int keepCount)
    {
        try
        {
            var dirs = new DirectoryInfo(root).GetDirectories().OrderByDescending(d => d.CreationTimeUtc).Skip(keepCount);
            foreach (var d in dirs)
            {
                try { d.Delete(recursive: true); } catch { }
            }
        }
        catch { }
    }

    private void ApplyIncomingChunkLocked(IncomingFileState st, string tid, int idx, ReadOnlySpan<byte> chunkSpan, string linkId)
    {
        if (st.FailedReason != null) return;
        int? expectedLen = SecurityValidation.ExpectedChunkLength(st.Offer, idx);
        if (!expectedLen.HasValue)
        {
            st.FailedReason = $"分块序号越界 idx={idx}/{st.Offer.TotalChunks}";
            LogMessage?.Invoke($"[Transfer Error] [Link={linkId}] [Tid={tid}] stage=chunk_bounds error={st.FailedReason}");
            return;
        }
        int dataLen = chunkSpan.Length;
        if (dataLen != expectedLen.Value)
        {
            st.FailedReason = $"分块 #{idx} 长度异常 ({dataLen} != {expectedLen.Value})";
            LogMessage?.Invoke($"[Transfer Error] [Link={linkId}] [Tid={tid}] stage=chunk_len error={st.FailedReason}");
            return;
        }
        if (st.ReceivedChunks.Contains(idx)) return;

        try
        {
            st.Stream.Position = (long)idx * st.Offer.ChunkSize;
            st.Stream.Write(chunkSpan);
        }
        catch (Exception ex)
        {
            st.FailedReason = $"写入暂存分块失败: {ex.Message}";
            LogMessage?.Invoke($"[Transfer Error] [Link={linkId}] [Tid={tid}] stage=chunk_write error={st.FailedReason}");
            return;
        }

        st.ReceivedChunks.Add(idx);
        st.ReceivedBytes += (ulong)dataLen;
    }

    private void HandleIncomingFileChunk(byte[] payload, PeerLinkSession link)
    {
        if (payload.Length < 40) return;
        string tid = Encoding.ASCII.GetString(payload, 0, 36).Trim();
        int idx = (payload[36] << 24) | (payload[37] << 16) | (payload[38] << 8) | payload[39];
        if (!_incomingFiles.TryGetValue(tid, out var st))
        {
            long nowMs = Environment.TickCount64;
            foreach (var kv in _earlyFileChunks)
            {
                lock (kv.Value)
                {
                    for (int i = kv.Value.Count - 1; i >= 0; i--)
                    {
                        if (nowMs - kv.Value[i].AddedTickMs > 15000)
                        {
                            Interlocked.Add(ref _earlyChunkTotalBytes, -kv.Value[i].Data.Length);
                            kv.Value.RemoveAt(i);
                        }
                    }
                    if (kv.Value.Count == 0)
                        _earlyFileChunks.TryRemove(kv.Key, out _);
                }
            }
            int dataLenEarly = payload.Length - 40;
            if (Interlocked.Read(ref _earlyChunkTotalBytes) + dataLenEarly <= 16 * 1024 * 1024)
            {
                var list = _earlyFileChunks.GetOrAdd(tid, _ => new List<(int, byte[], string, long)>());
                lock (list)
                {
                    if (list.Count < 64 && !list.Any(x => x.Idx == idx))
                    {
                        byte[] copy = new byte[dataLenEarly];
                        Buffer.BlockCopy(payload, 40, copy, 0, dataLenEarly);
                        list.Add((idx, copy, link.Id, nowMs));
                        Interlocked.Add(ref _earlyChunkTotalBytes, dataLenEarly);
                    }
                }
            }
            return;
        }

        double p = 0;
        double speedMbps = 0;
        bool shouldEmit = false;
        WireFileCompletePayload? pendingComp = null;
        PeerLinkSession? pendingLink = null;

        lock (st.SyncLock)
        {
            ApplyIncomingChunkLocked(st, tid, idx, payload.AsSpan(40, payload.Length - 40), link.Id);

            if (st.PendingComplete != null &&
                st.ReceivedChunks.Count == st.Offer.TotalChunks &&
                st.ReceivedBytes == st.Offer.TotalBytes)
            {
                pendingComp = st.PendingComplete;
                pendingLink = st.PendingCompleteLink;
                st.PendingComplete = null;
                try { st.PendingGraceCts?.Cancel(); st.PendingGraceCts?.Dispose(); } catch { }
                st.PendingGraceCts = null;
            }
            else
            {
                ulong total = Math.Max(1, st.Offer.TotalBytes);
                p = Math.Min(1.0, (double)st.ReceivedBytes / total);
                double elapsed = Math.Max(0.01, (DateTime.UtcNow - st.StartTime).TotalSeconds);
                speedMbps = (st.ReceivedBytes * 8.0) / (elapsed * 1_000_000.0);

                long nowTick = Environment.TickCount64;
                if (st.ReceivedBytes >= total || nowTick - st.LastUiTickMs >= 65)
                {
                    st.LastUiTickMs = nowTick;
                    shouldEmit = true;
                }
            }
        }

        if (pendingComp != null)
        {
            if (_incomingFiles.TryRemove(tid, out var readySt))
            {
                FinalizeIncomingFile(readySt, pendingComp, pendingLink ?? link);
            }
            return;
        }

        if (shouldEmit && !st.Offer.IsClipboardItem)
        {
            RemotePortalSync?.Invoke(new WirePortalSyncPayload
            {
                TransferId = tid,
                Style = st.Offer.Style,
                Edge = st.Offer.Edge,
                Offset = st.Offer.Offset,
                Phase = "emergingOut",
                Progress = Math.Max(0.08, p),
                FileName = st.Offer.FileName,
                FileSize = FormatBytes(st.Offer.TotalBytes),
                SpeedMbps = speedMbps,
                ChannelTag = "Incoming"
            });
        }
    }

    private void HandleIncomingFileComplete(WireFileCompletePayload comp, PeerLinkSession link)
    {
        if (!_incomingFiles.TryGetValue(comp.TransferId, out var st)) return;

        bool waitForLateChunks = false;
        CancellationTokenSource? graceCts = null;
        lock (st.SyncLock)
        {
            if (st.FailedReason == null &&
                (st.ReceivedChunks.Count != st.Offer.TotalChunks || st.ReceivedBytes != st.Offer.TotalBytes))
            {
                st.PendingComplete = comp;
                st.PendingCompleteLink = link;
                graceCts = new CancellationTokenSource();
                st.PendingGraceCts = graceCts;
                waitForLateChunks = true;
            }
        }

        if (waitForLateChunks && graceCts != null)
        {
            string tid = comp.TransferId;
            _ = Task.Run(async () =>
            {
                try
                {
                    await Task.Delay(3000, graceCts.Token);
                    if (_incomingFiles.TryRemove(tid, out var expired))
                    {
                        FinalizeIncomingFile(expired, comp, link);
                    }
                }
                catch { }
            });
            return;
        }

        if (_incomingFiles.TryRemove(comp.TransferId, out var readySt))
        {
            FinalizeIncomingFile(readySt, comp, link);
        }
    }

    private void FinalizeIncomingFile(IncomingFileState st, WireFileCompletePayload comp, PeerLinkSession link)
    {
        try { st.PendingGraceCts?.Cancel(); st.PendingGraceCts?.Dispose(); } catch { }
        st.PendingGraceCts = null;

        void Fail(string reason)
        {
            lock (st.SyncLock)
            {
                try { st.Stream.Dispose(); } catch { }
                try { if (Directory.Exists(st.StagingDir)) Directory.Delete(st.StagingDir, true); } catch { }
            }
            LogMessage?.Invoke($"[Transfer Error] [Link={link.Id}] [Tid={comp.TransferId}] stage=commit error={reason}");
            _ = link.SendJsonAsync(DeskflowMsgType.FileAck, new WireFileAckPayload
            {
                TransferId = comp.TransferId,
                Ok = false,
                SavedPath = "",
                Error = reason
            });
            TransferFailed?.Invoke(st.Offer.FileName, reason);
        }

        try
        {
            lock (st.SyncLock)
            {
                if (st.FailedReason != null)
                {
                    Fail(st.FailedReason);
                    return;
                }
                if (st.ReceivedChunks.Count != st.Offer.TotalChunks || st.ReceivedBytes != st.Offer.TotalBytes)
                {
                    Fail($"分块未收齐 ({st.ReceivedChunks.Count}/{st.Offer.TotalChunks} 块, {st.ReceivedBytes}/{st.Offer.TotalBytes} 字节)");
                    return;
                }
                st.Stream.Flush();
                st.Stream.Dispose();
            }

            var partInfo = new FileInfo(st.TempPath);
            if (!partInfo.Exists || (ulong)partInfo.Length != st.Offer.TotalBytes)
            {
                Fail($"磁盘体积校验失败 ({partInfo.Length} != {st.Offer.TotalBytes})");
                return;
            }

            string expectedSha = comp.Sha256.Trim().ToLowerInvariant();
            if (expectedSha.Length != 64)
            {
                Fail("缺少有效的 SHA-256 摘要");
                return;
            }
            string actualSha = SecurityValidation.ComputeFileSha256Hex(st.TempPath);
            if (!string.Equals(actualSha, expectedSha, StringComparison.OrdinalIgnoreCase))
            {
                Fail("SHA-256 完整性校验不匹配");
                return;
            }

            string finalPath;
            if (st.Offer.IsDirectoryZip)
            {
                string rawStem = Path.GetFileNameWithoutExtension(st.Offer.FileName);
                string safeStem = SecurityValidation.IsValidSingleFileName(rawStem) ? rawStem : "ReceivedFolder";
                finalPath = SecurityValidation.ExtractZipSafely(st.TempPath, st.FinalParentDir, safeStem);
                try { Directory.Delete(st.StagingDir, true); } catch { }
            }
            else
            {
                string destPath = GetUniquePath(st.FinalParentDir, st.Offer.FileName);
                string parentFull = Path.GetFullPath(st.FinalParentDir);
                string parentPrefix = parentFull.EndsWith(Path.DirectorySeparatorChar) ? parentFull : parentFull + Path.DirectorySeparatorChar;
                if (!Path.GetFullPath(destPath).StartsWith(parentPrefix, StringComparison.OrdinalIgnoreCase))
                {
                    Fail("目标保存路径越界被拦截");
                    return;
                }
                File.Move(st.TempPath, destPath, overwrite: true);
                try { Directory.Delete(st.StagingDir, true); } catch { }
                finalPath = destPath;
            }

            _ = link.SendJsonAsync(DeskflowMsgType.FileAck, new WireFileAckPayload
            {
                TransferId = comp.TransferId,
                Ok = true,
                SavedPath = finalPath
            });
            IncomingFileCompleted?.Invoke(st.Offer, finalPath);
        }
        catch (Exception ex)
        {
            Fail($"安全落盘/解压异常: {ex.Message}");
        }
    }

    private static string GetUniquePath(string dir, string fileName)
    {
        string path = Path.Combine(dir, fileName);
        if (!File.Exists(path)) return path;
        string stem = Path.GetFileNameWithoutExtension(fileName);
        string ext = Path.GetExtension(fileName);
        for (int i = 1; i < 999; i++)
        {
            string cand = Path.Combine(dir, $"{stem} ({i}){ext}");
            if (!File.Exists(cand)) return cand;
        }
        return Path.Combine(dir, $"{stem}_{Guid.NewGuid().ToString("N")[..8]}{ext}");
    }

    public static string FormatBytes(ulong bytes)
    {
        if (bytes < 1024) return $"{bytes} B";
        if (bytes < 1024 * 1024) return $"{bytes / 1024.0:F1} KB";
        if (bytes < 1024UL * 1024 * 1024) return $"{bytes / (1024.0 * 1024):F1} MB";
        return $"{bytes / (1024.0 * 1024 * 1024):F2} GB";
    }
}
