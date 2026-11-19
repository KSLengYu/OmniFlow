using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace MacBridgeUI;

public sealed class TrustedPeerRecord
{
    public string Fingerprint { get; set; } = "";
    public string HostName { get; set; } = "";
    public string PairedAtIso { get; set; } = "";

    public string ShortFingerprint => Fingerprint.Length > 34 ? Fingerprint[..34] + "..." : Fingerprint;
    public string DisplayHostName => string.IsNullOrWhiteSpace(HostName) ? "未知设备" : HostName;
    public string PairedDateDisplay
    {
        get
        {
            if (DateTimeOffset.TryParse(PairedAtIso, out var dt))
                return dt.ToLocalTime().ToString("yyyy-MM-dd HH:mm");
            return PairedAtIso;
        }
    }
}

public sealed class PendingPairingRequest
{
    public string Fingerprint { get; init; } = "";
    public string RemoteIp { get; init; } = "";
    public string HostName { get; init; } = "";
    public string SasCode { get; init; } = "";
}

public sealed class TrustedPeerStore
{
    private readonly object _lock = new();
    private readonly Dictionary<string, TrustedPeerRecord> _trusted = new(StringComparer.OrdinalIgnoreCase);
    private readonly string _storePath;

    public TrustedPeerStore(string? customStorePath = null)
    {
        _storePath = customStorePath ?? OmniFlowPaths.TrustedPeersPath;
        Load();
    }

    public bool IsTrusted(string? fingerprint)
    {
        string norm = SecurityValidation.NormalizeFingerprint(fingerprint ?? "");
        if (string.IsNullOrEmpty(norm)) return false;
        lock (_lock)
            return _trusted.ContainsKey(norm);
    }

    public List<TrustedPeerRecord> AllTrusted()
    {
        lock (_lock)
            return _trusted.Values.OrderByDescending(r => r.PairedAtIso).ToList();
    }

    public void AddTrusted(string fingerprint, string hostName)
    {
        string norm = SecurityValidation.NormalizeFingerprint(fingerprint);
        if (string.IsNullOrEmpty(norm)) return;
        lock (_lock)
        {
            _trusted[norm] = new TrustedPeerRecord
            {
                Fingerprint = norm,
                HostName = string.IsNullOrWhiteSpace(hostName) ? "Mac Peer" : hostName,
                PairedAtIso = DateTimeOffset.UtcNow.ToString("O")
            };
            SaveLocked();
        }
    }

    public void RemoveAll()
    {
        lock (_lock)
        {
            _trusted.Clear();
            SaveLocked();
        }
    }

    public void RemoveTrusted(string? fingerprint)
    {
        string norm = SecurityValidation.NormalizeFingerprint(fingerprint ?? "");
        if (string.IsNullOrEmpty(norm)) return;
        lock (_lock)
        {
            if (_trusted.Remove(norm))
                SaveLocked();
        }
    }

    private void Load()
    {
        try
        {
            if (!File.Exists(_storePath)) return;
            string json = File.ReadAllText(_storePath);
            var list = JsonSerializer.Deserialize<List<TrustedPeerRecord>>(json);
            if (list == null) return;
            lock (_lock)
            {
                foreach (var rec in list)
                {
                    string norm = SecurityValidation.NormalizeFingerprint(rec.Fingerprint);
                    if (!string.IsNullOrEmpty(norm))
                    {
                        rec.Fingerprint = norm;
                        _trusted[norm] = rec;
                    }
                }
            }
        }
        catch (Exception ex)
        {
            OmniFlowPaths.AppendCrashLog("TrustedPeerStore.Load", ex);
        }
    }

    private void SaveLocked()
    {
        string? dir = Path.GetDirectoryName(_storePath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        string tmp = _storePath + ".tmp";
        string json = JsonSerializer.Serialize(_trusted.Values.ToList());
        File.WriteAllText(tmp, json, Encoding.UTF8);
        File.Move(tmp, _storePath, overwrite: true);
    }
}

public static class SecurityValidation
{
    public const int MaxChunkBytes = 8 * 1024 * 1024;
    public const ulong MaxTransferBytes = 20UL * 1024 * 1024 * 1024;
    public const int MaxTransferChunks = 200_000;
    public const int MaxZipEntries = 10_000;
    public const long MaxZipUncompressedBytes = 4L * 1024 * 1024 * 1024;
    public const int MaxZipPathDepth = 16;
    public const long MaxZipBombRatio = 100;

    public static string NormalizeFingerprint(string fp) => fp.Trim().ToUpperInvariant();

    /// <summary>
    /// Deterministic 6-digit SAS verification code matching macOS Swift SecurityValidation.computePairingSasCode.
    /// </summary>
    public static string ComputePairingSasCode(string localFingerprint, string peerFingerprint)
    {
        string a = NormalizeFingerprint(localFingerprint);
        string b = NormalizeFingerprint(peerFingerprint);
        string combined = string.CompareOrdinal(a, b) <= 0 ? $"{a}|{b}" : $"{b}|{a}";
        byte[] digest = SHA256.HashData(Encoding.UTF8.GetBytes(combined));
        uint val = ((uint)digest[0] << 24) | ((uint)digest[1] << 16) | ((uint)digest[2] << 8) | digest[3];
        int code = (int)(val % 1_000_000);
        return $"{code / 1000:D3}-{code % 1000:D3}";
    }

    public static bool IsValidTransferId(string? tid)
    {
        if (string.IsNullOrEmpty(tid) || tid.Length > 64) return false;
        foreach (char c in tid)
        {
            bool ok = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '-' || c == '_';
            if (!ok) return false;
        }
        return true;
    }

    private static readonly HashSet<string> WindowsReservedDeviceNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
    };

    private static bool IsWindowsReservedOrInvalidSegment(string segment)
    {
        if (segment.EndsWith('.') || segment.EndsWith(' ')) return true;
        foreach (char c in segment)
        {
            if (c < 0x20 || c == 0x7F || c is '<' or '>' or '"' or '|' or '?' or '*' or '/' or '\\' or ':')
                return true;
        }
        int dot = segment.IndexOf('.');
        string stem = dot >= 0 ? segment[..dot] : segment;
        return WindowsReservedDeviceNames.Contains(stem);
    }

    public static bool IsValidSingleFileName(string? name)
    {
        if (string.IsNullOrEmpty(name)) return false;
        string trimmed = name.Trim();
        if (trimmed != name || name.Length > 255) return false;
        if (name == "." || name == "..") return false;
        return !IsWindowsReservedOrInvalidSegment(name);
    }

    public static string? ValidateFileOffer(WireFileOfferPayload offer)
    {
        if (!IsValidTransferId(offer.TransferId)) return "非法传输 ID";
        if (!IsValidSingleFileName(offer.FileName)) return "非法远端文件名（拒绝路径或特殊字符）";
        if (offer.ChunkSize <= 0 || offer.ChunkSize > MaxChunkBytes) return $"非法分块尺寸: {offer.ChunkSize}";
        if (offer.TotalBytes > MaxTransferBytes) return "文件体积超出上限";
        if (offer.TotalChunks <= 0 || offer.TotalChunks > MaxTransferChunks) return $"非法分块总数: {offer.TotalChunks}";

        if (offer.TotalBytes == 0)
        {
            if (offer.TotalChunks != 1) return "空文件分块数必须为 1";
        }
        else
        {
            ulong chunkU = (ulong)offer.ChunkSize;
            ulong chunksU = (ulong)offer.TotalChunks;
            if (chunksU - 1 > ulong.MaxValue / chunkU || (chunksU - 1) * chunkU >= offer.TotalBytes)
                return "分块数量与文件大小不匹配（过多）";
            if (chunksU <= ulong.MaxValue / chunkU && chunksU * chunkU < offer.TotalBytes)
                return "分块数量不足以覆盖总大小";
        }
        return null;
    }

    public static int? ExpectedChunkLength(WireFileOfferPayload offer, int index)
    {
        if (index < 0 || index >= offer.TotalChunks || offer.ChunkSize <= 0) return null;
        if (offer.TotalBytes == 0) return index == 0 ? 0 : null;
        ulong start = (ulong)index * (ulong)offer.ChunkSize;
        if (start >= offer.TotalBytes) return null;
        return (int)Math.Min((ulong)offer.ChunkSize, offer.TotalBytes - start);
    }

    public static string ComputeFileSha256Hex(string filePath)
    {
        using var fs = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024);
        using var sha = SHA256.Create();
        byte[] hash = sha.ComputeHash(fs);
        return Convert.ToHexStringLower(hash);
    }

    public static string[]? SanitizeZipRelativeSegments(string rawName, bool allowDirectory)
    {
        if (string.IsNullOrEmpty(rawName) || rawName.StartsWith('/') || rawName.StartsWith('\\')) return null;
        if (rawName.Contains(':')) return null;
        foreach (char c in rawName)
        {
            if (c < 0x20 || c == 0x7F) return null;
        }
        string normalized = rawName.Replace('\\', '/');
        if (allowDirectory && normalized.EndsWith('/'))
            normalized = normalized[..^1];
        if (string.IsNullOrEmpty(normalized)) return allowDirectory ? Array.Empty<string>() : null;

        string[] parts = normalized.Split('/');
        if (parts.Length > MaxZipPathDepth) return null;
        foreach (string p in parts)
        {
            if (string.IsNullOrEmpty(p) || p == "." || p == ".." || IsWindowsReservedOrInvalidSegment(p)) return null;
        }
        return parts;
    }

    public static string ExtractZipSafely(string zipPath, string destParentDir, string preferredFolderName)
    {
        string stagingDir = Path.Combine(destParentDir, $".unpack_{Guid.NewGuid():N}");
        Directory.CreateDirectory(stagingDir);
        try
        {
            string stagingFull = Path.GetFullPath(stagingDir);
            string stagingPrefix = stagingFull.EndsWith(Path.DirectorySeparatorChar)
                ? stagingFull
                : stagingFull + Path.DirectorySeparatorChar;

            using var archive = ZipFile.OpenRead(zipPath);
            if (archive.Entries.Count > MaxZipEntries)
                throw new InvalidDataException($"ZIP 条目数超限 ({archive.Entries.Count})");

            // Phase 1: Validate every entry BEFORE writing any output
            long declaredTotal = 0;
            foreach (var entry in archive.Entries)
            {
                int unixMode = (entry.ExternalAttributes >> 16) & 0xF000;
                if (unixMode == 0xA000)
                    throw new InvalidDataException($"ZIP 包含被禁止的符号链接: {entry.FullName}");

                bool isDir = entry.FullName.EndsWith('/') || entry.FullName.EndsWith('\\');
                string[]? segs = SanitizeZipRelativeSegments(entry.FullName, isDir);
                if (segs == null)
                    throw new InvalidDataException($"检测到越界或非法 ZIP 路径: {entry.FullName}");

                if (entry.Length > 10 * 1024 * 1024 && entry.CompressedLength > 0 &&
                    entry.Length / entry.CompressedLength > MaxZipBombRatio)
                {
                    throw new InvalidDataException($"疑似高压缩比炸弹: {entry.FullName}");
                }

                declaredTotal += Math.Max(0, entry.Length);
                if (declaredTotal > MaxZipUncompressedBytes)
                    throw new InvalidDataException("ZIP 解压总大小超出 4GB 上限");
            }

            // Phase 2: Bounded extraction inside stagingDir
            long actualWrittenTotal = 0;
            byte[] copyBuf = new byte[81920];
            foreach (var entry in archive.Entries)
            {
                bool isDir = entry.FullName.EndsWith('/') || entry.FullName.EndsWith('\\');
                string[] segs = SanitizeZipRelativeSegments(entry.FullName, isDir)!;
                if (segs.Length == 0) continue;

                string candidate = stagingFull;
                foreach (var s in segs) candidate = Path.Combine(candidate, s);
                string resolved = Path.GetFullPath(candidate);
                if (!resolved.StartsWith(stagingPrefix, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException($"ZIP 目标路径越界: {resolved}");

                if (isDir)
                {
                    Directory.CreateDirectory(resolved);
                    continue;
                }

                string? parent = Path.GetDirectoryName(resolved);
                if (!string.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);

                using var src = entry.Open();
                using var dst = new FileStream(resolved, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                int read;
                while ((read = src.Read(copyBuf, 0, copyBuf.Length)) > 0)
                {
                    actualWrittenTotal += read;
                    if (actualWrittenTotal > MaxZipUncompressedBytes)
                        throw new InvalidDataException("ZIP 实际写入超出 4GB 上限");
                    dst.Write(copyBuf, 0, read);
                }
            }

            string[] topEntries = Directory.GetFileSystemEntries(stagingFull);
            string safeFolder = IsValidSingleFileName(preferredFolderName) ? preferredFolderName : "ReceivedFolder";
            string finalFolder = Path.Combine(destParentDir, safeFolder);
            if (Directory.Exists(finalFolder) || File.Exists(finalFolder))
            {
                for (int i = 1; i < 999; i++)
                {
                    string alt = Path.Combine(destParentDir, $"{safeFolder} ({i})");
                    if (!Directory.Exists(alt) && !File.Exists(alt)) { finalFolder = alt; break; }
                }
            }

            if (topEntries.Length == 1 && Directory.Exists(topEntries[0]))
            {
                Directory.Move(topEntries[0], finalFolder);
            }
            else
            {
                Directory.CreateDirectory(finalFolder);
                foreach (var item in topEntries)
                {
                    string destItem = Path.Combine(finalFolder, Path.GetFileName(item));
                    if (Directory.Exists(item)) Directory.Move(item, destItem);
                    else File.Move(item, destItem);
                }
            }
            return finalFolder;
        }
        finally
        {
            try { if (Directory.Exists(stagingDir)) Directory.Delete(stagingDir, true); } catch { }
        }
    }
}

public static class OmniFlowSelfTests
{
    public static int RunAll()
    {
        // 1. Shared SAS derivation parity vector (must match macOS test!)
        string sas1 = SecurityValidation.ComputePairingSasCode("SHA256:AA:BB:CC:DD", "SHA256:11:22:33:44");
        string sas2 = SecurityValidation.ComputePairingSasCode("sha256:11:22:33:44 ", "SHA256:AA:BB:CC:DD");
        if (sas1 != sas2 || sas1.Length != 7 || !sas1.Contains('-'))
            throw new Exception("SAS parity failed");

        // 2. TrustStore pin check
        string tmpTrust = Path.Combine(Path.GetTempPath(), $"of_trust_{Guid.NewGuid():N}.json");
        try
        {
            var s1 = new TrustedPeerStore(tmpTrust);
            if (s1.IsTrusted("SHA256:AA:BB")) throw new Exception("Empty trust store must reject");
            s1.AddTrusted("sha256:aa:bb", "MacHost");
            var s2 = new TrustedPeerStore(tmpTrust);
            if (!s2.IsTrusted("SHA256:AA:BB")) throw new Exception("Pinned cert missing after reload");
            if (s2.IsTrusted("SHA256:AA:BC")) throw new Exception("Unpinned cert must be rejected");
            s2.AddTrusted("sha256:cc:dd", "MacTwo");
            s2.RemoveTrusted("SHA256:AA:BB");
            if (s2.IsTrusted("SHA256:AA:BB")) throw new Exception("Removed peer must not remain trusted");
            if (!s2.IsTrusted("SHA256:CC:DD")) throw new Exception("Other peer must stay trusted after single removal");
        }
        finally
        {
            try { if (File.Exists(tmpTrust)) File.Delete(tmpTrust); } catch { }
        }

        // 3. Single filename & offer validation
        if (!SecurityValidation.IsValidSingleFileName("report_2026.pdf"))
            throw new Exception("Valid filename rejected");
        foreach (string bad in new[] { "", ".", "..", "../evil.txt", "a/b.txt", "a\\b.txt", "C:foo", "bad\0name" })
        {
            if (SecurityValidation.IsValidSingleFileName(bad))
                throw new Exception($"Bad filename accepted: {bad}");
        }

        var validOffer = new WireFileOfferPayload
        {
            TransferId = "abc-123_XYZ",
            FileName = "demo.bin",
            TotalBytes = 300_000,
            ChunkSize = 262_144,
            TotalChunks = 2
        };
        if (SecurityValidation.ValidateFileOffer(validOffer) != null)
            throw new Exception("Valid offer rejected");
        if (SecurityValidation.ExpectedChunkLength(validOffer, 0) != 262_144 ||
            SecurityValidation.ExpectedChunkLength(validOffer, 1) != 37_856 ||
            SecurityValidation.ExpectedChunkLength(validOffer, 2) != null)
            throw new Exception("Chunk length calculation mismatch");

        var badOffer = new WireFileOfferPayload
        {
            TransferId = "../escape",
            FileName = "demo.bin",
            TotalBytes = 100,
            ChunkSize = 0,
            TotalChunks = 1
        };
        if (SecurityValidation.ValidateFileOffer(badOffer) == null)
            throw new Exception("Bad offer accepted");

        // 4. Zip-Slip attack rejection + valid extraction + SHA-256 verification
        string tmpWork = Path.Combine(Path.GetTempPath(), $"of_zip_{Guid.NewGuid():N}");
        Directory.CreateDirectory(tmpWork);
        try
        {
            string evilZip = Path.Combine(tmpWork, "evil.zip");
            using (var za = ZipFile.Open(evilZip, ZipArchiveMode.Create))
            {
                var e = za.CreateEntry("../pwned.txt");
                using var sw = new StreamWriter(e.Open());
                sw.Write("evil");
            }
            bool threw = false;
            try { SecurityValidation.ExtractZipSafely(evilZip, tmpWork, "Evil"); }
            catch { threw = true; }
            if (!threw) throw new Exception("Zip-Slip must throw");

            string goodZip = Path.Combine(tmpWork, "bundle.zip");
            using (var za = ZipFile.Open(goodZip, ZipArchiveMode.Create))
            {
                var e = za.CreateEntry("MyFolder/hello.txt");
                using var sw = new StreamWriter(e.Open());
                sw.Write("hello omniflow");
            }
            string sha = SecurityValidation.ComputeFileSha256Hex(goodZip);
            if (sha.Length != 64) throw new Exception("SHA-256 invalid");

            string outFolder = SecurityValidation.ExtractZipSafely(goodZip, tmpWork, "MyFolder");
            string content = File.ReadAllText(Path.Combine(outFolder, "hello.txt"));
            if (content != "hello omniflow") throw new Exception("Extracted content mismatch");
        }
        finally
        {
            try { if (Directory.Exists(tmpWork)) Directory.Delete(tmpWork, true); } catch { }
        }

        if (!DeskflowTransport.IsUsbBridgeIp("10.13.37.1") || !DeskflowTransport.IsUsbBridgeIp("10.13.37.2"))
            throw new Exception("USB subnet classifier rejected valid USB bridge IP");
        if (DeskflowTransport.IsUsbBridgeIp("192.0.2.10") || DeskflowTransport.IsUsbBridgeIp("10.0.0.5") || DeskflowTransport.IsUsbBridgeIp("127.0.0.1"))
            throw new Exception("USB subnet classifier accepted non-USB LAN IP");

        foreach (var winBad in new[] { "CON", "con.txt", "NUL", "COM1", "LPT9.log", "report.", "bad*name.txt", "a<b.txt" })
        {
            if (SecurityValidation.IsValidSingleFileName(winBad))
                throw new Exception($"Windows reserved/invalid filename was not rejected: {winBad}");
        }

        string[] samplePaths = { @"C:\Users\Alice\Desktop\测试|文件;名 (1).txt", @"D:\Work\folder with spaces" };
        string encoded = ElevatedDropBridge.EncodePaths(samplePaths);
        string[] decoded = ElevatedDropBridge.DecodePaths(encoded);
        if (decoded.Length != samplePaths.Length || decoded[0] != samplePaths[0] || decoded[1] != samplePaths[1])
            throw new Exception("ElevatedDropBridge pipe path codec roundtrip mismatch");

        // RttEstimator: reject periodic Wi-Fi/DTIM spikes while adapting to real path shifts
        var rtt = new RttEstimator();
        rtt.RecordSample(45.0);
        rtt.RecordSample(1.1);
        double afterWarmup = rtt.RecordSample(0.9);
        if (afterWarmup >= 1.5)
            throw new Exception($"RttEstimator failed to shed cold-start spike cleanly (got {afterWarmup:F2}ms)");
        double[] mixedSamples = { 85.0, 1.0, 62.0, 0.9, 50.0, 1.1 };
        double steady = afterWarmup;
        foreach (double s in mixedSamples) steady = rtt.RecordSample(s);
        if (steady >= 2.5)
            throw new Exception($"RttEstimator polluted by periodic power-save spikes (got {steady:F2}ms)");
        double shifted = steady;
        for (int i = 0; i < 8; i++) shifted = rtt.RecordSample(18.0);
        if (shifted <= 12.0)
            throw new Exception($"RttEstimator failed to adapt to sustained latency shift (got {shifted:F2}ms)");

        if (System.Runtime.InteropServices.Marshal.SizeOf<DeskflowService.RAWMOUSE>() != 24)
            throw new Exception("RAWMOUSE ABI size must be 24 bytes");
        string kA = NicChannelItem.CanonicalChannelKey("Ethernet", "192.0.2.10", false, "192.0.2.11");
        string kB = NicChannelItem.CanonicalChannelKey("Ethernet", "192.0.2.10", false, "192.0.2.12");
        if (kA == kB)
            throw new Exception("Multi-peer channels sharing a local NIC must preserve distinct canonical keys");

        // End-to-end validation for subtle edge anchor, crossing overshoot conservation,
        // SetCursorPos echo vs delayed/early WM_INPUT, and continuous unclamped Raw Input.
        long freq = System.Diagnostics.Stopwatch.Frequency;
        long t0 = System.Diagnostics.Stopwatch.GetTimestamp();
        var tracker = new DeskflowService.WinCursorTransitionTracker();

        // Case 1: Delayed WM_INPUT arrives AFTER SetCursorPos echo
        // Local cursor moved 15px left to bezel (crossHookDx=-15), physical mouse swiped -40px total.
        // SetCursorPos nudged only 6px inside bezel (curX=0 -> anchorX=6), NOT screen center.
        tracker.ProcessRawMouseInput(-10, 0, 900, t0 - freq / 20, IntPtr.Zero); // Establish active WM_INPUT before crossing
        tracker.EnterRemote(anchorX: 6, anchorY: 540, curX: 0, curY: 540,
            crossHookDx: -15, crossHookDy: 2, crossTimeMs: 1000, nowTicks: t0, stageSeq: 0,
            out int earlyOx1, out int earlyOy1);
        if (earlyOx1 != 0 || earlyOy1 != 0)
            throw new Exception($"Expected 0 preOvershoot when crossing WM_INPUT hasn't arrived yet (got {earlyOx1},{earlyOy1})");
        var echo = tracker.ProcessHookMouseMove(6, 540, 1000, t0 + freq / 2000, 0, 0, 2560, 1440);
        if (echo.needsRewarp || echo.dx != 0 || echo.dy != 0)
            throw new Exception($"Programmatic SetCursorPos echo must produce 0 delta (got {echo.dx},{echo.dy})");
        var delayedRaw = tracker.ProcessRawMouseInput(-40, 2, 1000, t0 + freq / 1000, new IntPtr(1));
        if (delayedRaw.dx != -25 || delayedRaw.dy != 0)
            throw new Exception($"Crossing overshoot must equal (-25, 0) without losing/doubling border pixels (got {delayedRaw.dx},{delayedRaw.dy})");

        // Subsequent hook move clamped at left bezel + unclamped WM_INPUT at +250ms (past old 80ms cap)
        var hookDuringRaw = tracker.ProcessHookMouseMove(0, 540, 1250, t0 + freq / 4, 0, 0, 2560, 1440);
        var continuousRaw = tracker.ProcessRawMouseInput(-18, -3, 1250, t0 + freq / 4, new IntPtr(1));
        if (hookDuringRaw.dx != 0 || hookDuringRaw.dy != 0 || continuousRaw.dx != -18 || continuousRaw.dy != -3)
            throw new Exception($"Continuous WM_INPUT must flow unclamped without hook duplication: hook=({hookDuringRaw.dx},{hookDuringRaw.dy}) raw=({continuousRaw.dx},{continuousRaw.dy})");
        tracker.ExitRemote();

        // Case 2: Early WM_INPUT (-40, +2) ran in WndProc right BEFORE WH_MOUSE_LL edge trigger
        long t1 = t0 + freq;
        tracker.ProcessRawMouseInput(-40, 2, 2000, t1 - freq / 1000, new IntPtr(1));
        tracker.EnterRemote(anchorX: 6, anchorY: 540, curX: 0, curY: 540,
            crossHookDx: -15, crossHookDy: 2, crossTimeMs: 2000, nowTicks: t1, stageSeq: 0,
            out int earlyOx2, out int earlyOy2);
        if (earlyOx2 != -25 || earlyOy2 != 0)
            throw new Exception($"Early crossing WM_INPUT must preserve (-25, 0) overshoot immediately (got {earlyOx2},{earlyOy2})");
        var nextRawAfterEarly = tracker.ProcessRawMouseInput(-12, 1, 2008, t1 + freq / 125, new IntPtr(1));
        if (nextRawAfterEarly.dx != -12 || nextRawAfterEarly.dy != 1)
            throw new Exception($"Post-crossing WM_INPUT must stay intact (got {nextRawAfterEarly.dx},{nextRawAfterEarly.dy})");
        tracker.ExitRemote();

        // Case 3: Pure fallback WH_MOUSE_LL tracker (no WM_INPUT ever seen) + rewarp + tracer write check
        var fallbackTracker = new DeskflowService.WinCursorTransitionTracker();
        fallbackTracker.EnterRemote(120, 540, 120, 540, 3000, t1);
        var fbMove = fallbackTracker.ProcessHookMouseMove(135, 542, 3004, t1 + freq / 250, 0, 0, 2560, 1440);
        if (fbMove.needsRewarp || fbMove.dx != 15 || fbMove.dy != 2)
            throw new Exception($"Fallback WH_MOUSE_LL move mismatch (got {fbMove.dx},{fbMove.dy})");
        var hugeJump = fallbackTracker.ProcessHookMouseMove(1800, 540, 3100, t1 + freq / 10, 0, 0, 2560, 1440);
        if (!hugeJump.needsRewarp)
            throw new Exception("Anomalous >900px fallback hook delta must trigger rewarp");

        // Case 4: CommitLocalMove prevents pre-cross WM_INPUT double-counting + center-warp rejects stale pre-warp edge event without fixed delay
        long t2 = t1 + freq;
        var centerTracker = new DeskflowService.WinCursorTransitionTracker();
        centerTracker.ProcessRawMouseInput(-15, 0, 4000, t2 - freq / 200, new IntPtr(1)); // pre-cross move already committed locally
        centerTracker.CommitLocalMove(t2 - freq / 400);
        centerTracker.ProcessRawMouseInput(-40, 2, 4004, t2 - freq / 1000, new IntPtr(1)); // crossing swipe right before WH_MOUSE_LL
        centerTracker.EnterRemote(anchorX: 1280, anchorY: 720, curX: 0, curY: 540,
            crossHookDx: -15, crossHookDy: 2, crossTimeMs: 4004, nowTicks: t2, stageSeq: 0,
            out int earlyOx4, out int earlyOy4);
        if (earlyOx4 != -25 || earlyOy4 != 0)
            throw new Exception($"CommitLocalMove must isolate crossing overshoot (-25,0) without doubling prior move (got {earlyOx4},{earlyOy4})");
        centerTracker.ExitRemote();

        var centerFallback = new DeskflowService.WinCursorTransitionTracker();
        centerFallback.EnterRemote(anchorX: 1280, anchorY: 720, curX: 0, curY: 540, crossTimeMs: 5000, nowTicks: t2);
        var staleEdge = centerFallback.ProcessHookMouseMove(2, 540, 5000, t2 + freq / 1000, 0, 0, 2560, 1440);
        if (staleEdge.needsRewarp || staleEdge.dx != 0 || staleEdge.dy != 0)
            throw new Exception($"Stale pre-warp edge event must be ignored while waiting center anchor (got {staleEdge.dx},{staleEdge.dy})");
        var centerEcho = centerFallback.ProcessHookMouseMove(1280, 720, 5001, t2 + freq / 500, 0, 0, 2560, 1440);
        if (centerEcho.needsRewarp || centerEcho.dx != 0 || centerEcho.dy != 0)
            throw new Exception($"Center warp echo must yield (0,0) (got {centerEcho.dx},{centerEcho.dy})");
        var postCenterMove = centerFallback.ProcessHookMouseMove(1295, 722, 5005, t2 + freq / 200, 0, 0, 2560, 1440);
        if (postCenterMove.needsRewarp || postCenterMove.dx != 15 || postCenterMove.dy != 2)
            throw new Exception($"Post-center fallback move must be (15,2) (got {postCenterMove.dx},{postCenterMove.dy})");

        string tmpWinStageLog = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"of_winstage_{Guid.NewGuid():N}.log");
        try
        {
            long sSeq = DeskflowService.WinKvmStageTracer.BeginCrossing(t1);
            DeskflowService.WinKvmStageTracer.Log(sSeq, t1, "selftestWinStage ok=true", t1 + freq / 1000, tmpWinStageLog, sync: true);
            string winStageText = System.IO.File.ReadAllText(tmpWinStageLog);
            if (!winStageText.Contains($"[KVM-Stage-Win seq=#{sSeq}") || !winStageText.Contains("selftestWinStage ok=true"))
                throw new Exception("WinKvmStageTracer failed to write log entry");
        }
        finally
        {
            try { System.IO.File.Delete(tmpWinStageLog); } catch { }
        }

        Console.WriteLine($"[PASS] Windows OmniFlowSelfTests SAS={sas1}");
        return 0;
    }
}
