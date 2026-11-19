using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Security;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace MacBridgeUI;

/// Trimmed lower-half sliding window + gentle RFC 6298 EWMA RTT estimator.
internal sealed class RttEstimator
{
    private const int WindowSize = 6;
    private readonly object _lock = new();
    private readonly double[] _ring = new double[WindowSize];
    private readonly double[] _scratch = new double[WindowSize];
    private int _count;
    private int _head;
    private double? _smoothedMs;

    public double? CurrentMs
    {
        get { lock (_lock) return _smoothedMs; }
    }

    public double RecordSample(double rawRttMs)
    {
        double sample = Math.Clamp(rawRttMs, 0.05, 999.0);
        lock (_lock)
        {
            _ring[_head] = sample;
            _head = (_head + 1) % WindowSize;
            if (_count < WindowSize) _count++;

            for (int i = 0; i < _count; i++) _scratch[i] = _ring[i];
            Array.Sort(_scratch, 0, _count);

            int keep = Math.Max(1, _count / 2);
            double sum = 0;
            for (int i = 0; i < keep; i++) sum += _scratch[i];
            double baseline = sum / keep;

            if (!_smoothedMs.HasValue)
            {
                _smoothedMs = baseline;
            }
            else if (_count <= 3 && baseline < _smoothedMs.Value * 0.5)
            {
                _smoothedMs = baseline;
            }
            else if (baseline < _smoothedMs.Value * 0.6)
            {
                _smoothedMs = _smoothedMs.Value * 0.5 + baseline * 0.5;
            }
            else
            {
                _smoothedMs = _smoothedMs.Value * 0.65 + baseline * 0.35;
            }
            return _smoothedMs.Value;
        }
    }
}

public sealed class PeerLinkSession : IDisposable
{
    public string Id { get; }
    public string LocalIp { get; }
    public string PeerIp { get; }
    public string IfaceName { get; }
    public bool IsUsbBridge { get; }
    public double EstBandwidthMbps { get; set; }
    public double? MeasuredBytesPerSec { get; set; }
    public double? RttMs { get; set; }
    internal readonly RttEstimator RttTracker = new();
    public volatile bool IsReady;
    private long _rxFrames;
    private long _txFrames;
    public long RxFrames => Interlocked.Read(ref _rxFrames);
    public long TxFrames => Interlocked.Read(ref _txFrames);
    public DateTime CreatedAtUtc { get; } = DateTime.UtcNow;
    private long _lastActivityUtcTicks = DateTime.UtcNow.Ticks;
    public DateTime LastActivityUtc => new DateTime(Interlocked.Read(ref _lastActivityUtcTicks), DateTimeKind.Utc);

    private readonly TcpClient _client;
    private readonly Stream _stream;
    private readonly SemaphoreSlim _sendLock = new(1, 1);
    private readonly CancellationTokenSource _cts = new();
    private readonly object _mouseLock = new();
    private byte[]? _pendingMouseFrame;
    private bool _mousePumpRunning;
    private int _readLoopStarted;

    public event Action<PeerLinkSession, DeskflowMsgType, byte[]>? FrameReceived;
    public event Action<PeerLinkSession>? Closed;

    public PeerLinkSession(string id, string localIp, string peerIp, string ifaceName, bool isUsbBridge, double estBandwidthMbps, TcpClient client, Stream stream)
    {
        Id = id;
        LocalIp = localIp;
        PeerIp = peerIp;
        IfaceName = ifaceName;
        IsUsbBridge = isUsbBridge;
        EstBandwidthMbps = estBandwidthMbps;
        _client = client;
        _stream = stream;
        IsReady = true;
    }

    public void StartReadLoop()
    {
        if (IsReady && Interlocked.Exchange(ref _readLoopStarted, 1) == 0)
        {
            _ = ReadLoopAsync(_cts.Token);
        }
    }

    public async Task<bool> SendFrameAsync(DeskflowMsgType type, ReadOnlyMemory<byte> payload)
    {
        if (!IsReady) return false;
        int frameLen = 1 + payload.Length;
        byte[]? combined = null;
        byte[] header;
        if (payload.Length <= 4096)
        {
            combined = new byte[5 + payload.Length];
            combined[0] = (byte)((frameLen >> 24) & 0xFF);
            combined[1] = (byte)((frameLen >> 16) & 0xFF);
            combined[2] = (byte)((frameLen >> 8) & 0xFF);
            combined[3] = (byte)(frameLen & 0xFF);
            combined[4] = (byte)type;
            if (!payload.IsEmpty) payload.Span.CopyTo(combined.AsSpan(5));
            header = combined;
        }
        else
        {
            header = new byte[5];
            header[0] = (byte)((frameLen >> 24) & 0xFF);
            header[1] = (byte)((frameLen >> 16) & 0xFF);
            header[2] = (byte)((frameLen >> 8) & 0xFF);
            header[3] = (byte)(frameLen & 0xFF);
            header[4] = (byte)type;
        }

        bool acquired = false;
        try
        {
            await _sendLock.WaitAsync(_cts.Token);
            acquired = true;
            if (!IsReady) return false;
            Interlocked.Increment(ref _txFrames);
            using var writeCts = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
            writeCts.CancelAfter(type == DeskflowMsgType.FileChunk ? 10000 : 2500);
            if (combined != null)
            {
                await _stream.WriteAsync(combined, writeCts.Token);
            }
            else
            {
                await _stream.WriteAsync(header, writeCts.Token);
                if (!payload.IsEmpty)
                    await _stream.WriteAsync(payload, writeCts.Token);
            }
            await _stream.FlushAsync(writeCts.Token);
            return true;
        }
        catch
        {
            Dispose();
            return false;
        }
        finally
        {
            if (acquired) _sendLock.Release();
        }
    }

    public async Task<bool> SendPingTimestampedAsync()
    {
        if (!IsReady) return false;
        byte[] frame = new byte[13];
        frame[0] = 0; frame[1] = 0; frame[2] = 0; frame[3] = 9;
        frame[4] = (byte)DeskflowMsgType.Ping;

        bool acquired = false;
        try
        {
            await _sendLock.WaitAsync(_cts.Token);
            acquired = true;
            if (!IsReady) return false;
            Interlocked.Increment(ref _txFrames);
            long nowTicks = Stopwatch.GetTimestamp();
            for (int i = 0; i < 8; i++)
                frame[5 + (7 - i)] = (byte)((nowTicks >> (i * 8)) & 0xFF);
            using var writeCts = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
            writeCts.CancelAfter(2500);
            await _stream.WriteAsync(frame, writeCts.Token);
            await _stream.FlushAsync(writeCts.Token);
            return true;
        }
        catch
        {
            Dispose();
            return false;
        }
        finally
        {
            if (acquired) _sendLock.Release();
        }
    }

    public async Task<bool> SendFramePairAsync(DeskflowMsgType t1, ReadOnlyMemory<byte> p1, DeskflowMsgType t2, ReadOnlyMemory<byte> p2)
    {
        if (!IsReady) return false;
        int f1Len = 1 + p1.Length;
        int f2Len = 1 + p2.Length;
        byte[] buf = new byte[5 + p1.Length + 5 + p2.Length];
        buf[0] = (byte)((f1Len >> 24) & 0xFF);
        buf[1] = (byte)((f1Len >> 16) & 0xFF);
        buf[2] = (byte)((f1Len >> 8) & 0xFF);
        buf[3] = (byte)(f1Len & 0xFF);
        buf[4] = (byte)t1;
        if (!p1.IsEmpty) p1.Span.CopyTo(buf.AsSpan(5));

        int off2 = 5 + p1.Length;
        buf[off2] = (byte)((f2Len >> 24) & 0xFF);
        buf[off2 + 1] = (byte)((f2Len >> 16) & 0xFF);
        buf[off2 + 2] = (byte)((f2Len >> 8) & 0xFF);
        buf[off2 + 3] = (byte)(f2Len & 0xFF);
        buf[off2 + 4] = (byte)t2;
        if (!p2.IsEmpty) p2.Span.CopyTo(buf.AsSpan(off2 + 5));

        bool acquired = false;
        try
        {
            await _sendLock.WaitAsync(_cts.Token);
            acquired = true;
            if (!IsReady) return false;
            Interlocked.Add(ref _txFrames, 2);
            using var writeCts = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
            writeCts.CancelAfter(2500);
            await _stream.WriteAsync(buf, writeCts.Token);
            await _stream.FlushAsync(writeCts.Token);
            return true;
        }
        catch
        {
            Dispose();
            return false;
        }
        finally
        {
            if (acquired) _sendLock.Release();
        }
    }

    public void SendMouseMoveCoalesced(ReadOnlySpan<byte> payload)
    {
        if (!IsReady || payload.Length < 10) return;
        int frameLen = 1 + payload.Length;
        byte[] frame = new byte[5 + payload.Length];
        frame[0] = (byte)((frameLen >> 24) & 0xFF);
        frame[1] = (byte)((frameLen >> 16) & 0xFF);
        frame[2] = (byte)((frameLen >> 8) & 0xFF);
        frame[3] = (byte)(frameLen & 0xFF);
        frame[4] = (byte)DeskflowMsgType.MouseMoveAbs;
        payload.CopyTo(frame.AsSpan(5));

        bool startPump = false;
        lock (_mouseLock)
        {
            _pendingMouseFrame = frame;
            if (!_mousePumpRunning)
            {
                _mousePumpRunning = true;
                startPump = true;
            }
        }
        if (startPump)
        {
            _ = FlushMouseMoveLoopAsync();
        }
    }

    private async Task FlushMouseMoveLoopAsync()
    {
        try
        {
            while (IsReady && !_cts.IsCancellationRequested)
            {
                byte[]? next;
                lock (_mouseLock)
                {
                    next = _pendingMouseFrame;
                    _pendingMouseFrame = null;
                    if (next == null)
                    {
                        _mousePumpRunning = false;
                        return;
                    }
                }

                await _sendLock.WaitAsync(_cts.Token);
                try
                {
                    if (!IsReady) break;
                    Interlocked.Increment(ref _txFrames);
                    using var mouseCts = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
                    mouseCts.CancelAfter(1500);
                    await _stream.WriteAsync(next, mouseCts.Token);
                    await _stream.FlushAsync(mouseCts.Token);
                }
                finally
                {
                    _sendLock.Release();
                }
            }
        }
        catch
        {
            Dispose();
        }
        finally
        {
            lock (_mouseLock)
            {
                _mousePumpRunning = false;
                _pendingMouseFrame = null;
            }
        }
    }

    public Task<bool> SendJsonAsync<T>(DeskflowMsgType type, T obj)
    {
        byte[] json = JsonSerializer.SerializeToUtf8Bytes(obj);
        return SendFrameAsync(type, json);
    }

    private async Task ReadLoopAsync(CancellationToken ct)
    {
        byte[] lenBuf = new byte[4];
        try
        {
            while (!ct.IsCancellationRequested && IsReady)
            {
                if (!await ReadExactAsync(_stream, lenBuf, 4, ct)) break;
                int frameLen = (lenBuf[0] << 24) | (lenBuf[1] << 16) | (lenBuf[2] << 8) | lenBuf[3];
                if (frameLen <= 0 || frameLen > 16 * 1024 * 1024) break;

                byte[] body = new byte[frameLen];
                if (!await ReadExactAsync(_stream, body, frameLen, ct)) break;

                var msgType = (DeskflowMsgType)body[0];
                byte[] payload = frameLen > 1 ? body.AsSpan(1).ToArray() : Array.Empty<byte>();
                Interlocked.Increment(ref _rxFrames);
                Interlocked.Exchange(ref _lastActivityUtcTicks, DateTime.UtcNow.Ticks);
                FrameReceived?.Invoke(this, msgType, payload);
            }
        }
        catch { }
        finally
        {
            Dispose();
        }
    }

    private static async Task<bool> ReadExactAsync(Stream s, byte[] buf, int count, CancellationToken ct)
    {
        int read = 0;
        while (read < count)
        {
            int n = await s.ReadAsync(buf.AsMemory(read, count - read), ct);
            if (n <= 0) return false;
            read += n;
        }
        return true;
    }

    public void Dispose()
    {
        if (!IsReady) return;
        IsReady = false;
        try { _cts.Cancel(); } catch { }
        try { _stream.Dispose(); } catch { }
        try { _client.Dispose(); } catch { }
        Closed?.Invoke(this);
    }
}

public sealed partial class DeskflowTransport : IDisposable
{
    private static readonly string[] UsbPrefixes =
    {
        "10.13.37.", "10.13.38.", "10.13.39.",
        "10.13.137.", "10.13.138.",
        "10.13.237.", "10.13.238.", "10.13.239.",
        "100.113.37.", "172.31.237.", "192.168.237."
    };

    private sealed class IncomingFileState
    {
        public object SyncLock { get; } = new();
        public WireFileOfferPayload Offer { get; init; } = new();
        public string StagingDir { get; init; } = "";
        public string TempPath { get; init; } = "";
        public string FinalParentDir { get; init; } = "";
        public FileStream Stream { get; init; } = null!;
        public HashSet<int> ReceivedChunks { get; } = new();
        public ulong ReceivedBytes { get; set; }
        public string? FailedReason { get; set; }
        public DateTime StartTime { get; } = DateTime.UtcNow;
        public long LastUiTickMs { get; set; }
        public WireFileCompletePayload? PendingComplete { get; set; }
        public PeerLinkSession? PendingCompleteLink { get; set; }
        public CancellationTokenSource? PendingGraceCts { get; set; }
    }

    public readonly TrustedPeerStore TrustStore = new();
    private readonly CancellationTokenSource _cts = new();
    private readonly ConcurrentDictionary<string, PeerLinkSession> _links = new();
    private readonly ConcurrentDictionary<string, byte> _connectingKeys = new();
    private readonly object _linkLock = new();
    private readonly ConcurrentDictionary<string, byte> _knownPeerIps = new();
    private readonly ConcurrentDictionary<string, IncomingFileState> _incomingFiles = new();
    private readonly ConcurrentDictionary<string, List<(int Idx, byte[] Data, string LinkId, long AddedTickMs)>> _earlyFileChunks = new();
    private long _earlyChunkTotalBytes = 0;
    private readonly ConcurrentDictionary<string, TaskCompletionSource<WireFileAckPayload>> _pendingFileAcks = new();
    private readonly ConcurrentDictionary<string, string> _pendingAckLinks = new();
    public sealed record KnownLanRoute(string IfaceName, string LocalIp, string PeerIp, double EstBandwidthMbps);
    private readonly ConcurrentDictionary<string, byte> _manuallyDisconnectedIfaces = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, KnownLanRoute> _knownLanRoutes = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, byte> _rejectedFingerprints = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, DateTime> _lastPairingNotify = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, string> _discoveredHostByIp = new();
    private volatile bool _manuallyPausedAll = false;
    private int _activeBulkTransfers = 0;
    private string? _lastControlLinkId;

    private TcpListener? _rawListener;
    private TcpListener? _tlsListener;
    private UdpClient? _udpClient;
    private X509Certificate2? _lanCert;

    public string LocalFingerprint { get; private set; } = "SHA256:LOCAL";
    public string PeerFingerprint { get; private set; } = "";
    public string PeerHostName { get; private set; } = "";
    public List<WireMonitorDto> PeerMonitors { get; private set; } = new();
    public bool IsGloballyPaused => _manuallyPausedAll;

    public event Action? LinksUpdated;
    public event Action<List<WireMonitorDto>, string>? PeerMonitorsUpdated;
    public event Action<string>? RemoteClipboardText;
    public event Action<byte[]>? RemoteClipboardImage;
    public event Action<WirePortalSyncPayload>? RemotePortalSync;
    public event Action<WireFileOfferPayload, string>? IncomingFileCompleted;
    public event Action<string, string>? TransferFailed;
    public event Action<PendingPairingRequest>? PendingPairingRequested;
    public event Action? TrustStoreUpdated;
    public event Action<int, double, double>? KvmMouseMoveAbs;
    public event Action<byte, bool>? KvmMouseButton;
    public event Action<int, int>? KvmMouseScroll;
    public event Action<ushort, bool, uint>? KvmKeyEvent;
    public event Action<string>? KvmSemanticHotkey;
    public event Action<WireKvmFocusPayload>? KvmFocusSwitch;
    public event Action<WireTopologySyncPayload>? TopologySync;
    public event Action<WireConfigSyncPayload>? ConfigSync;
    public event Action<string>? LogMessage;

    public static bool IsUsbBridgeIp(string ip) => UsbPrefixes.Any(p => ip.StartsWith(p, StringComparison.Ordinal));

    public void Start()
    {
        EnsureLanCertificate();
        StartRawListener();
        StartTlsListener();
        StartUdpDiscovery();
        _ = HeartbeatLoopAsync(_cts.Token);
    }

    public void ConfirmPairing(string fingerprint, string hostName)
    {
        string norm = SecurityValidation.NormalizeFingerprint(fingerprint);
        TrustStore.AddTrusted(norm, hostName);
        _rejectedFingerprints.TryRemove(norm, out _);
        _lastPairingNotify.TryRemove(norm, out _);
        LogMessage?.Invoke($"[SECURITY] 已信任并配对对端设备证书 ({norm[..Math.Min(28, norm.Length)]}...)");
        TrustStoreUpdated?.Invoke();
        foreach (var mip in _knownPeerIps.Keys)
            _ = ConnectIfNeededAsync(mip, null, IsUsbBridgeIp(mip));
    }

    public void RejectPairing(string fingerprint)
    {
        string norm = SecurityValidation.NormalizeFingerprint(fingerprint);
        _rejectedFingerprints[norm] = 0;
        LogMessage?.Invoke($"[SECURITY] 已拒绝对端未配对设备的连接请求 ({norm[..Math.Min(28, norm.Length)]}...)");
    }

    public void ClearAllTrustedPeers()
    {
        TrustStore.RemoveAll();
        _rejectedFingerprints.Clear();
        _lastPairingNotify.Clear();
        PeerFingerprint = "";
        List<PeerLinkSession> toClose;
        lock (_linkLock)
        {
            toClose = _links.Values.Where(l => !l.IsUsbBridge).ToList();
            foreach (var l in toClose)
                _links.TryRemove(l.Id, out _);
        }
        foreach (var l in toClose) l.Dispose();
        LogMessage?.Invoke("[SECURITY] 已清除全部已配对证书信任记录，后续 TLS 连接需重新核对短码");
        TrustStoreUpdated?.Invoke();
        LinksUpdated?.Invoke();
    }

    public void RemoveTrustedPeer(string fingerprint)
    {
        string norm = SecurityValidation.NormalizeFingerprint(fingerprint);
        if (string.IsNullOrEmpty(norm)) return;
        TrustStore.RemoveTrusted(norm);
        _rejectedFingerprints.TryRemove(norm, out _);
        _lastPairingNotify.TryRemove(norm, out _);
        if (string.Equals(PeerFingerprint, norm, StringComparison.OrdinalIgnoreCase) || TrustStore.AllTrusted().Count == 0)
        {
            PeerFingerprint = "";
            List<PeerLinkSession> toClose;
            lock (_linkLock)
            {
                toClose = _links.Values.Where(l => !l.IsUsbBridge).ToList();
                foreach (var l in toClose)
                    _links.TryRemove(l.Id, out _);
            }
            foreach (var l in toClose) l.Dispose();
        }
        LogMessage?.Invoke($"[SECURITY] 已移除信任设备证书 ({norm[..Math.Min(28, norm.Length)]}...)，再次连接需重新核对短码");
        TrustStoreUpdated?.Invoke();
        LinksUpdated?.Invoke();
    }

    private bool VerifyTlsPeerCertificate(X509Certificate? cert, string remoteIp)
    {
        if (cert == null)
        {
            LogMessage?.Invoke($"[SECURITY] 拒绝无证书的 TLS 连接 ({remoteIp})");
            return false;
        }
        byte[] hash = SHA256.HashData(cert.GetRawCertData());
        string fp = SecurityValidation.NormalizeFingerprint("SHA256:" + string.Join(":", hash.Select(b => b.ToString("X2"))));

        if (TrustStore.IsTrusted(fp))
        {
            PeerFingerprint = fp;
            return true;
        }

        if (!_rejectedFingerprints.ContainsKey(fp))
        {
            DateTime now = DateTime.UtcNow;
            bool shouldNotify = false;
            if (!_lastPairingNotify.TryGetValue(fp, out var prev) || (now - prev).TotalSeconds >= 4.0)
            {
                _lastPairingNotify[fp] = now;
                shouldNotify = true;
            }
            if (shouldNotify)
            {
                string sas = SecurityValidation.ComputePairingSasCode(LocalFingerprint, fp);
                string host = _discoveredHostByIp.TryGetValue(remoteIp, out var h) && !string.IsNullOrWhiteSpace(h)
                    ? h
                    : (string.IsNullOrWhiteSpace(PeerHostName) ? $"Mac 设备 ({remoteIp})" : PeerHostName);
                LogMessage?.Invoke($"[SECURITY] 拦截未配对 TLS 连接 ip={remoteIp} sas={sas} fp={fp[..Math.Min(28, fp.Length)]}...");
                PendingPairingRequested?.Invoke(new PendingPairingRequest
                {
                    Fingerprint = fp,
                    RemoteIp = remoteIp,
                    HostName = host,
                    SasCode = sas
                });
            }
        }
        return false;
    }

    public void AddManualPeerIp(string ip)
    {
        string trimmed = ip.Trim();
        if (string.IsNullOrEmpty(trimmed)) return;
        _manuallyPausedAll = false;
        _knownPeerIps.TryAdd(trimmed, 0);
        LogMessage?.Invoke($"[NET] 正在主动探测 Mac 对端: {trimmed} ...");
        _ = ConnectIfNeededAsync(trimmed, null, IsUsbBridgeIp(trimmed), allowRoutedFallback: true);
    }

    private static bool IsUsbAlias(string key) =>
        key is "usb" or "USB-C NCM" or "USB-C" or "MacBridge" or "USB-NCM" || IsUsbBridgeIp(key);

    public bool IsIfaceDisconnected(string ifaceOrIp) =>
        _manuallyPausedAll
        || (!string.IsNullOrEmpty(ifaceOrIp) && _manuallyDisconnectedIfaces.ContainsKey(ifaceOrIp))
        || (!string.IsNullOrEmpty(ifaceOrIp) && IsUsbAlias(ifaceOrIp) && _manuallyDisconnectedIfaces.ContainsKey("usb"));

    public bool IsChannelDisconnected(string ifaceName, string localIp, string? peerIp, bool isUsb)
    {
        if (_manuallyPausedAll) return true;
        if (isUsb)
            return IsIfaceDisconnected("usb") || IsIfaceDisconnected(ifaceName) || IsIfaceDisconnected(localIp);
        if (!string.IsNullOrEmpty(peerIp) && !string.IsNullOrEmpty(localIp) && localIp != "auto")
        {
            if (_manuallyDisconnectedIfaces.ContainsKey($"{localIp}->{peerIp}"))
                return true;
        }
        return (!string.IsNullOrEmpty(ifaceName) && _manuallyDisconnectedIfaces.ContainsKey(ifaceName))
            || (!string.IsNullOrEmpty(localIp) && localIp != "auto" && _manuallyDisconnectedIfaces.ContainsKey(localIp));
    }

    public List<KnownLanRoute> KnownDisconnectedLanRoutesSnapshot() =>
        _knownLanRoutes.Values
            .Where(r => IsChannelDisconnected(r.IfaceName, r.LocalIp, r.PeerIp, isUsb: false))
            .ToList();

    public void DisconnectChannel(string ifaceName, string localIp, string? peerIp = null)
    {
        bool isUsb = IsUsbAlias(ifaceName) || IsUsbAlias(localIp) || (!string.IsNullOrEmpty(peerIp) && IsUsbBridgeIp(peerIp));
        if (isUsb)
        {
            if (!string.IsNullOrEmpty(ifaceName)) _manuallyDisconnectedIfaces.TryAdd(ifaceName, 0);
            if (!string.IsNullOrEmpty(localIp) && localIp != "auto") _manuallyDisconnectedIfaces.TryAdd(localIp, 0);
            _manuallyDisconnectedIfaces.TryAdd("usb", 0);
        }
        else if (!string.IsNullOrEmpty(peerIp) && !string.IsNullOrEmpty(localIp) && localIp != "auto")
        {
            _manuallyDisconnectedIfaces.TryAdd($"{localIp}->{peerIp}", 0);
        }
        else
        {
            if (!string.IsNullOrEmpty(ifaceName)) _manuallyDisconnectedIfaces.TryAdd(ifaceName, 0);
            if (!string.IsNullOrEmpty(localIp) && localIp != "auto") _manuallyDisconnectedIfaces.TryAdd(localIp, 0);
        }

        var toClose = _links.Values.Where(l =>
            isUsb
                ? l.IsUsbBridge
                : (!string.IsNullOrEmpty(peerIp)
                    ? (!l.IsUsbBridge && l.PeerIp.Equals(peerIp, StringComparison.OrdinalIgnoreCase) &&
                       (l.LocalIp.Equals(localIp, StringComparison.OrdinalIgnoreCase) || l.IfaceName.Equals(ifaceName, StringComparison.OrdinalIgnoreCase)))
                    : (l.IfaceName.Equals(ifaceName, StringComparison.OrdinalIgnoreCase) || l.LocalIp.Equals(localIp, StringComparison.OrdinalIgnoreCase)))
        ).ToList();
        foreach (var l in toClose)
        {
            _links.TryRemove(l.Id, out _);
        }
        if (toClose.Count > 0)
        {
            _ = Task.Run(() =>
            {
                foreach (var l in toClose)
                {
                    try { l.Dispose(); } catch { }
                }
            });
        }
        LogMessage?.Invoke($"[NET] 已手动断开网卡通道: {ifaceName} ({localIp}{(string.IsNullOrEmpty(peerIp) ? "" : " -> " + peerIp)})");
        if (isUsb) EnsureLanLinksConnected();
        LinksUpdated?.Invoke();
    }

    public void EnsureLanLinksConnected()
    {
        foreach (var ip in _knownPeerIps.Keys)
        {
            if (!IsUsbBridgeIp(ip))
                _ = ConnectIfNeededAsync(ip, null, isUsb: false);
        }
    }

    public void ReconnectChannel(string ifaceName, string localIp, string peerIp)
    {
        bool isUsb = IsUsbAlias(ifaceName) || IsUsbAlias(localIp) || IsUsbBridgeIp(peerIp);
        _manuallyPausedAll = false;
        if (!string.IsNullOrEmpty(ifaceName)) _manuallyDisconnectedIfaces.TryRemove(ifaceName, out _);
        if (!string.IsNullOrEmpty(localIp)) _manuallyDisconnectedIfaces.TryRemove(localIp, out _);
        if (!string.IsNullOrEmpty(peerIp) && !string.IsNullOrEmpty(localIp))
            _manuallyDisconnectedIfaces.TryRemove($"{localIp}->{peerIp}", out _);
        if (isUsb) _manuallyDisconnectedIfaces.TryRemove("usb", out _);
        LogMessage?.Invoke($"[NET] 正在重新连接网卡通道: {ifaceName} ({localIp}{(string.IsNullOrEmpty(peerIp) ? "" : " -> " + peerIp)})");
        if (!string.IsNullOrEmpty(peerIp))
            _ = ConnectIfNeededAsync(peerIp, localIp == "auto" || string.IsNullOrEmpty(localIp) ? null : localIp, isUsb);
        LinksUpdated?.Invoke();
    }

    public void DisconnectAllLinks()
    {
        _manuallyPausedAll = true;
        var toClose = _links.Values.ToList();
        _links.Clear();
        foreach (var l in toClose) l.Dispose();
        LogMessage?.Invoke("[NET] 已手动断开所有对端网络连接");
        LinksUpdated?.Invoke();
    }

    public void ReconnectAllLinks()
    {
        _manuallyPausedAll = false;
        _manuallyDisconnectedIfaces.Clear();
        LogMessage?.Invoke("[NET] 已恢复全部网卡自动重连");
        foreach (var ip in _knownPeerIps.Keys)
            _ = ConnectIfNeededAsync(ip, null, IsUsbBridgeIp(ip));
        LinksUpdated?.Invoke();
    }

    public List<PeerLinkSession> ActiveLinksSnapshot() =>
        _links.Values.Where(l => l.IsReady).ToList();

    public PeerLinkSession? BestControlLink()
    {
        var active = ActiveLinksSnapshot();
        if (active.Count == 0) return null;
        var candidate = active
            .OrderBy(l => l.RttMs ?? (l.IsUsbBridge ? 0.5 : 5.0))
            .ThenByDescending(l => l.IsUsbBridge)
            .First();

        string? prevId = Volatile.Read(ref _lastControlLinkId);
        if (!string.IsNullOrEmpty(prevId) && prevId != candidate.Id)
        {
            var prev = active.FirstOrDefault(l => l.Id == prevId);
            if (prev != null)
            {
                double prevRtt = prev.RttMs ?? (prev.IsUsbBridge ? 0.5 : 5.0);
                double candRtt = candidate.RttMs ?? (candidate.IsUsbBridge ? 0.5 : 5.0);
                if ((prevRtt - candRtt) < 0.5 && !(candidate.IsUsbBridge && !prev.IsUsbBridge))
                    return prev;
            }
        }
        Volatile.Write(ref _lastControlLinkId, candidate.Id);
        return candidate;
    }

    public void SendControlFrame(DeskflowMsgType type, byte[] payload)
    {
        var ctrl = BestControlLink();
        if (ctrl != null)
            _ = ctrl.SendFrameAsync(type, payload);
    }

    public void SendMouseMoveCoalesced(byte[] payload)
    {
        var ctrl = BestControlLink();
        ctrl?.SendMouseMoveCoalesced(payload);
    }

    public void SendControlJson<T>(DeskflowMsgType type, T obj)
    {
        var ctrl = BestControlLink();
        if (ctrl != null)
            _ = ctrl.SendJsonAsync(type, obj);
    }

    public void SendKvmFocusWithCursor(WireKvmFocusPayload focusPayload, byte[] mousePayload)
    {
        var ctrl = BestControlLink();
        if (ctrl == null) return;
        byte[] json = JsonSerializer.SerializeToUtf8Bytes(focusPayload);
        _ = ctrl.SendFramePairAsync(DeskflowMsgType.KvmFocusSwitch, json, DeskflowMsgType.MouseMoveAbs, mousePayload);
    }

    public void BroadcastControlFrame(DeskflowMsgType type, byte[] payload)
    {
        foreach (var l in ActiveLinksSnapshot())
            _ = l.SendFrameAsync(type, payload);
    }

    public void BroadcastControlJson<T>(DeskflowMsgType type, T obj)
    {
        foreach (var l in ActiveLinksSnapshot())
            _ = l.SendJsonAsync(type, obj);
    }

    private void EnsureLanCertificate()
    {
        try
        {
            string dir = OmniFlowPaths.AppDataDirectory;
            string pfxPath = Path.Combine(dir, "omniflow_lan.pfx");

            if (!File.Exists(pfxPath))
            {
                using RSA rsa = RSA.Create(2048);
                var req = new CertificateRequest("CN=OmniFlow-Core", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                using X509Certificate2 cert = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(10));
                File.WriteAllBytes(pfxPath, cert.Export(X509ContentType.Pfx, "omniflow"));
            }

            _lanCert = X509CertificateLoader.LoadPkcs12FromFile(pfxPath, "omniflow", X509KeyStorageFlags.Exportable);
            byte[] hash = SHA256.HashData(_lanCert.RawData);
            LocalFingerprint = "SHA256:" + string.Join(":", hash.Select(b => b.ToString("X2")));
            LogMessage?.Invoke($"[TLS] 本机证书已就绪 ({LocalFingerprint[..Math.Min(32, LocalFingerprint.Length)]}...)");
        }
        catch (Exception ex)
        {
            LogMessage?.Invoke($"[TLS Warn] 证书初始化异常: {ex.Message}");
        }
    }

    private void StartRawListener()
    {
        try
        {
            _rawListener = new TcpListener(IPAddress.Any, DeskflowPorts.RawUsbTcp);
            _rawListener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            _rawListener.Start();
            LogMessage?.Invoke($"[NET] USB-C 极速直连免加密端口已监听 :{DeskflowPorts.RawUsbTcp}");
            _ = AcceptLoopAsync(_rawListener, isTls: false, _cts.Token);
        }
        catch (Exception ex)
        {
            LogMessage?.Invoke($"[ERR] Raw listener failed: {ex.Message}");
        }
    }

    private void StartTlsListener()
    {
        try
        {
            _tlsListener = new TcpListener(IPAddress.Any, DeskflowPorts.LanTlsTcp);
            _tlsListener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            _tlsListener.Start();
            LogMessage?.Invoke($"[TLS] 局域网 TLS 1.3 加密端口已监听 :{DeskflowPorts.LanTlsTcp}");
            _ = AcceptLoopAsync(_tlsListener, isTls: true, _cts.Token);
        }
        catch (Exception ex)
        {
            LogMessage?.Invoke($"[ERR] TLS listener failed: {ex.Message}");
        }
    }

    private async Task AcceptLoopAsync(TcpListener listener, bool isTls, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                TcpClient client = await listener.AcceptTcpClientAsync(ct);
                _ = HandleIncomingClientAsync(client, isTls, ct);
            }
            catch (OperationCanceledException) { break; }
            catch { await Task.Delay(200, ct); }
        }
    }

    private async Task HandleIncomingClientAsync(TcpClient client, bool isTls, CancellationToken ct)
    {
        string remoteIp = (client.Client.RemoteEndPoint as IPEndPoint)?.Address.ToString() ?? "unknown";
        try
        {
            client.NoDelay = true;
            client.SendBufferSize = 512 * 1024;
            client.ReceiveBufferSize = 512 * 1024;
            string localIp = (client.Client.LocalEndPoint as IPEndPoint)?.Address.ToString() ?? "auto";
            if (!isTls)
            {
                bool validUsbPeer = IsUsbBridgeIp(remoteIp);
                bool validUsbLocal = localIp == "auto" || string.IsNullOrEmpty(localIp) || IsUsbBridgeIp(localIp);
                if (!validUsbPeer || !validUsbLocal)
                {
                    LogMessage?.Invoke($"[SECURITY] 拒绝非 USB 直连网段访问免加密端口 {DeskflowPorts.RawUsbTcp}: remote={remoteIp} local={localIp}");
                    try { client.Dispose(); } catch { }
                    return;
                }
            }
            bool isUsb = !isTls || IsUsbBridgeIp(remoteIp);

            Stream stream = client.GetStream();
            if (isTls)
            {
                if (_lanCert == null)
                {
                    LogMessage?.Invoke($"[SECURITY] 本机 TLS 证书未就绪，拒绝入站 LAN 连接 ({remoteIp})，严禁降级为明文");
                    try { client.Dispose(); } catch { }
                    return;
                }
                var ssl = new SslStream(stream, leaveInnerStreamOpen: false, (_, cert, _, _) =>
                    VerifyTlsPeerCertificate(cert, remoteIp));
                await ssl.AuthenticateAsServerAsync(
                    new SslServerAuthenticationOptions
                    {
                        ServerCertificate = _lanCert,
                        ClientCertificateRequired = true,
                        EnabledSslProtocols = SslProtocols.Tls13 | SslProtocols.Tls12,
                        CertificateRevocationCheckMode = X509RevocationMode.NoCheck
                    }, ct);
                stream = ssl;
            }

            var localNic = EnumerateLocalIPv4().FirstOrDefault(n => n.Ip == localIp);
            string ifaceName = localNic?.IfaceName ?? (isUsb ? "USB-C" : "LAN");
            if (_manuallyPausedAll || IsChannelDisconnected(ifaceName, localIp, remoteIp, isUsb))
            {
                try { client.Dispose(); } catch { }
                return;
            }
            double estMbps = localNic?.EstMbps ?? (isUsb ? 3200 : 1200);
            string id = $"in_{(isUsb ? "usb" : "lan")}_{localIp}_{remoteIp}_{Guid.NewGuid().ToString("N")[..6]}";
            var session = new PeerLinkSession(id, localIp, remoteIp, ifaceName, isUsb, estMbps, client, stream);
            if (!DeduplicateAndRegisterSession(session))
            {
                session.Dispose();
                return;
            }
            LogMessage?.Invoke($"[LINK] 接受 Mac 入站 {remoteIp} (本机 {ifaceName} {localIp} · {(isUsb ? "USB 点对点免加密" : "TLS 1.3 加密")})");
            await session.SendJsonAsync(DeskflowMsgType.Hello, BuildHelloPayload());
            await SendPingAsync(session);
            ScheduleWarmupPingBurst(session);
        }
        catch (Exception ex)
        {
            LogMessage?.Invoke($"[ERR] 入站 TLS 握手失败 ({remoteIp}): {ex.Message}");
            try { client.Dispose(); } catch { }
        }
    }

    private async Task ConnectIfNeededAsync(string peerIp, string? localIpHint, bool isUsb, bool allowRoutedFallback = false)
    {
        if (_manuallyPausedAll) return;
        if (isUsb && !IsUsbBridgeIp(peerIp)) return;
        var localNics = EnumerateLocalIPv4();
        string[] peerParts = peerIp.Split('.');
        List<LocalNicInfo> matching = new();
        if (localIpHint != null)
        {
            var found = localNics.FirstOrDefault(n => n.Ip == localIpHint && (!isUsb || IsUsbBridgeIp(n.Ip)));
            if (found != null) matching.Add(found);
        }
        else if (peerParts.Length == 4)
        {
            string p3 = $"{peerParts[0]}.{peerParts[1]}.{peerParts[2]}.";
            matching = localNics.Where(n => n.Ip.StartsWith(p3, StringComparison.Ordinal) && (!isUsb || IsUsbBridgeIp(n.Ip))).ToList();
        }
        if (matching.Count == 0)
        {
            if (isUsb || !allowRoutedFallback || ActiveLinksSnapshot().Count > 0)
                return;
            matching.Add(new LocalNicInfo("auto", "", null, null, 1200));
        }

        foreach (var loc in matching)
        {
            if (IsChannelDisconnected(loc.IfaceName, loc.Ip, peerIp, isUsb))
                continue;
            string id = $"{(isUsb ? "usb" : "lan")}_{(string.IsNullOrEmpty(loc.Ip) ? "auto" : loc.Ip)}_{peerIp}";
            if (_links.ContainsKey(id) || _links.Values.Any(l => l.IsReady && l.PeerIp == peerIp && l.IsUsbBridge == isUsb && (l.LocalIp == loc.Ip || string.IsNullOrEmpty(loc.Ip))))
                continue;
            if (!_connectingKeys.TryAdd(id, 0))
                continue;

            TcpClient? client = null;
            try
            {
                client = string.IsNullOrEmpty(loc.Ip)
                    ? new TcpClient()
                    : new TcpClient(new IPEndPoint(IPAddress.Parse(loc.Ip), 0));
                client.NoDelay = true;
                client.SendBufferSize = 512 * 1024;
                client.ReceiveBufferSize = 512 * 1024;

                using var connectCts = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
                connectCts.CancelAfter(TimeSpan.FromMilliseconds(4500));
                int port = isUsb ? DeskflowPorts.RawUsbTcp : DeskflowPorts.LanTlsTcp;
                await client.ConnectAsync(IPAddress.Parse(peerIp), port, connectCts.Token);

                Stream stream = client.GetStream();
                if (!isUsb)
                {
                    if (_lanCert == null)
                    {
                        LogMessage?.Invoke($"[SECURITY] 本机 TLS 证书未就绪，中止出站 LAN 连接 ({peerIp})，严禁降级为明文");
                        try { client.Dispose(); } catch { }
                        continue;
                    }
                    var ssl = new SslStream(stream, leaveInnerStreamOpen: false, (_, cert, _, _) =>
                        VerifyTlsPeerCertificate(cert, peerIp));
                    await ssl.AuthenticateAsClientAsync(
                        new SslClientAuthenticationOptions
                        {
                            TargetHost = "MacBridge-Deskflow",
                            ClientCertificates = new X509CertificateCollection { _lanCert },
                            EnabledSslProtocols = SslProtocols.Tls13 | SslProtocols.Tls12,
                            CertificateRevocationCheckMode = X509RevocationMode.NoCheck
                        }, connectCts.Token);
                    stream = ssl;
                }

                string actualLocal = (client.Client.LocalEndPoint as IPEndPoint)?.Address.ToString() ?? loc.Ip;
                var session = new PeerLinkSession(id, actualLocal, peerIp, loc.IfaceName, isUsb, loc.EstMbps, client, stream);
                if (!DeduplicateAndRegisterSession(session))
                {
                    session.Dispose();
                    continue;
                }
                LogMessage?.Invoke($"[LINK] 已连接 Mac 对端 {peerIp} (本机 {loc.IfaceName} {actualLocal} · {(isUsb ? "USB 点对点免加密" : "TLS 1.3 加密")})");
                await session.SendJsonAsync(DeskflowMsgType.Hello, BuildHelloPayload());
                await SendPingAsync(session);
                ScheduleWarmupPingBurst(session);
            }
            catch (Exception ex)
            {
                try { client?.Dispose(); } catch { }
                if (!isUsb && _knownPeerIps.ContainsKey(peerIp))
                    LogMessage?.Invoke($"[ERR] 出站连接 {peerIp} ({loc.IfaceName} {loc.Ip}) 失败: {ex.Message}");
            }
            finally
            {
                _connectingKeys.TryRemove(id, out _);
            }
        }
    }

    private static uint Ipv4Value(string ip)
    {
        if (IPAddress.TryParse(ip, out var addr))
        {
            var b = addr.GetAddressBytes();
            if (b.Length == 4)
                return ((uint)b[0] << 24) | ((uint)b[1] << 16) | ((uint)b[2] << 8) | b[3];
        }
        return 0;
    }

    private bool DeduplicateAndRegisterSession(PeerLinkSession session)
    {
        PeerLinkSession? toClose = null;
        bool keepCurrent = true;
        lock (_linkLock)
        {
            var existing = _links.Values.FirstOrDefault(l =>
                l.Id != session.Id && l.IsReady &&
                l.PeerIp == session.PeerIp && l.IsUsbBridge == session.IsUsbBridge && l.LocalIp == session.LocalIp);
            if (existing != null)
            {
                bool sInbound = session.Id.StartsWith("in_", StringComparison.Ordinal);
                bool eInbound = existing.Id.StartsWith("in_", StringComparison.Ordinal);
                if (sInbound && eInbound)
                {
                    _links.TryRemove(existing.Id, out _);
                    toClose = existing;
                }
                else
                {
                    bool localSmaller = Ipv4Value(session.LocalIp) < Ipv4Value(session.PeerIp);
                    bool sessionPreferred = localSmaller ? !sInbound : sInbound;
                    if (sessionPreferred)
                    {
                        _links.TryRemove(existing.Id, out _);
                        toClose = existing;
                    }
                    else
                    {
                        keepCurrent = false;
                    }
                }
            }
            if (keepCurrent)
            {
                RegisterSession(session);
            }
        }
        toClose?.Dispose();
        return keepCurrent;
    }

    private void RegisterSession(PeerLinkSession session)
    {
        session.FrameReceived += OnFrameReceived;
        session.Closed += s =>
        {
            _links.TryRemove(s.Id, out _);
            if (_links.Values.All(l => !l.IsReady))
            {
                foreach (var kv in _pendingFileAcks)
                {
                    _pendingAckLinks.TryRemove(kv.Key, out _);
                    if (_pendingFileAcks.TryRemove(kv.Key, out var tcs))
                        tcs.TrySetResult(new WireFileAckPayload { TransferId = kv.Key, Ok = false, Error = "对端连接已断开" });
                }
                foreach (var tid in _incomingFiles.Keys.ToArray())
                {
                    if (_incomingFiles.TryRemove(tid, out var st))
                    {
                        lock (st.SyncLock)
                        {
                            try { st.PendingGraceCts?.Cancel(); st.PendingGraceCts?.Dispose(); } catch { }
                            try { st.Stream.Dispose(); } catch { }
                            try { if (Directory.Exists(st.StagingDir)) Directory.Delete(st.StagingDir, true); } catch { }
                        }
                        TransferFailed?.Invoke(st.Offer.FileName, "对端连接已断开，接收已中止");
                    }
                }
                _earlyFileChunks.Clear();
                Interlocked.Exchange(ref _earlyChunkTotalBytes, 0);
            }
            else
            {
                foreach (var kv in _pendingAckLinks.ToArray())
                {
                    if (kv.Value == s.Id && _pendingAckLinks.TryRemove(kv.Key, out _))
                    {
                        if (_pendingFileAcks.TryRemove(kv.Key, out var tcs))
                            tcs.TrySetResult(new WireFileAckPayload { TransferId = kv.Key, Ok = false, Error = "对端连接已断开" });
                    }
                }
            }
            if (s.IsUsbBridge) EnsureLanLinksConnected();
            LinksUpdated?.Invoke();
        };
        if (!session.IsUsbBridge && !string.IsNullOrEmpty(session.LocalIp) && session.LocalIp != "auto" && !string.IsNullOrEmpty(session.PeerIp))
        {
            _knownLanRoutes[$"{session.LocalIp}->{session.PeerIp}"] = new KnownLanRoute(
                session.IfaceName, session.LocalIp, session.PeerIp, session.EstBandwidthMbps);
        }
        _links[session.Id] = session;
        session.StartReadLoop();
        LinksUpdated?.Invoke();
    }

    private void StartUdpDiscovery()
    {
        try
        {
            _udpClient = new UdpClient();
            _udpClient.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            _udpClient.Client.Bind(new IPEndPoint(IPAddress.Any, DeskflowPorts.UdpDiscovery));
            _udpClient.EnableBroadcast = true;

            _ = Task.Run(async () =>
            {
                while (!_cts.IsCancellationRequested)
                {
                    try
                    {
                        var res = await _udpClient.ReceiveAsync(_cts.Token);
                        var beacon = JsonSerializer.Deserialize<WireBeaconPayload>(res.Buffer);
                        if (beacon != null && beacon.Os != "Windows")
                        {
                            string senderIp = res.RemoteEndPoint.Address.ToString();
                            var validUsbIps = beacon.UsbIps.Where(IsUsbBridgeIp).ToList();
                            var validLanIps = beacon.Ips.Where(ip => !IsUsbBridgeIp(ip)).ToList();
                            if (!string.IsNullOrEmpty(beacon.Host))
                            {
                                PeerHostName = beacon.Host;
                                _discoveredHostByIp[senderIp] = beacon.Host;
                                foreach (var uip in validUsbIps) _discoveredHostByIp[uip] = beacon.Host;
                                foreach (var lip in validLanIps) _discoveredHostByIp[lip] = beacon.Host;
                            }
                            foreach (var uip in validUsbIps) _knownPeerIps[uip] = 0;
                            foreach (var lip in validLanIps) _knownPeerIps[lip] = 0;
                            _knownPeerIps[senderIp] = 0;

                            foreach (var uip in validUsbIps) _ = ConnectIfNeededAsync(uip, null, isUsb: true);
                            foreach (var lip in validLanIps) _ = ConnectIfNeededAsync(lip, null, isUsb: false);
                            _ = ConnectIfNeededAsync(senderIp, null, IsUsbBridgeIp(senderIp));
                        }
                    }
                    catch (OperationCanceledException) { break; }
                    catch (Exception ex)
                    {
                        LogMessage?.Invoke($"[UDP Warn] stage=recv error={ex.Message}");
                        await Task.Delay(250);
                    }
                }
            }, _cts.Token);

            _ = Task.Run(async () =>
            {
                while (!_cts.IsCancellationRequested)
                {
                    try
                    {
                        BroadcastBeacon();
                        var nics = EnumerateLocalIPv4();
                        foreach (var u in nics.Where(x => IsUsbBridgeIp(x.Ip)))
                        {
                            var parts = u.Ip.Split('.');
                            if (parts.Length == 4)
                            {
                                string peerUsb = $"{parts[0]}.{parts[1]}.{parts[2]}.1";
                                _ = ConnectIfNeededAsync(peerUsb, u.Ip, isUsb: true);
                            }
                        }
                        foreach (var mip in _knownPeerIps.Keys)
                            _ = ConnectIfNeededAsync(mip, null, IsUsbBridgeIp(mip));
                    }
                    catch { }
                    await Task.Delay(2000, _cts.Token);
                }
            }, _cts.Token);
        }
        catch (Exception ex)
        {
            LogMessage?.Invoke($"[UDP Warn] {ex.Message}");
        }
    }

    private void BroadcastBeacon()
    {
        if (_udpClient == null) return;
        var nics = EnumerateLocalIPv4();
        var beacon = new WireBeaconPayload
        {
            Type = "BEACON",
            Os = "Windows",
            Host = Environment.MachineName,
            RawPort = DeskflowPorts.RawUsbTcp,
            TlsPort = DeskflowPorts.LanTlsTcp,
            Ips = nics.Where(x => !IsUsbBridgeIp(x.Ip)).Select(x => x.Ip).ToList(),
            UsbIps = nics.Where(x => IsUsbBridgeIp(x.Ip)).Select(x => x.Ip).ToList(),
            Fingerprint = LocalFingerprint
        };
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(beacon);

        var targets = new HashSet<string> { "255.255.255.255" };
        foreach (var n in nics)
        {
            if (!string.IsNullOrEmpty(n.Broadcast)) targets.Add(n.Broadcast);
        }
        foreach (var mip in _knownPeerIps.Keys) targets.Add(mip);

        foreach (var t in targets)
        {
            try { _udpClient.Send(bytes, bytes.Length, new IPEndPoint(IPAddress.Parse(t), DeskflowPorts.UdpDiscovery)); }
            catch { }
        }
    }

    private void ScheduleWarmupPingBurst(PeerLinkSession link)
    {
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(55, _cts.Token);
                if (link.IsReady && !_cts.IsCancellationRequested)
                    await link.SendPingTimestampedAsync();
                await Task.Delay(55, _cts.Token);
                if (link.IsReady && !_cts.IsCancellationRequested)
                    await link.SendPingTimestampedAsync();
            }
            catch { }
        }, _cts.Token);
    }

    private async Task HeartbeatLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            DateTime now = DateTime.UtcNow;
            bool reapedUsb = false;
            var pinged = new List<PeerLinkSession>();
            foreach (var link in ActiveLinksSnapshot())
            {
                if ((now - link.CreatedAtUtc).TotalSeconds > 8.0 && (now - link.LastActivityUtc).TotalSeconds > 7.5)
                {
                    _links.TryRemove(link.Id, out _);
                    if (link.IsUsbBridge) reapedUsb = true;
                    LogMessage?.Invoke($"[NET] 链路心跳超时，已自动清理并切换通道: {link.IfaceName} ({link.PeerIp})");
                    link.Dispose();
                }
                else
                {
                    await SendPingAsync(link);
                    pinged.Add(link);
                }
            }
            if (reapedUsb) EnsureLanLinksConnected();
            if (pinged.Count > 0 && Volatile.Read(ref _activeBulkTransfers) == 0 && _incomingFiles.IsEmpty)
            {
                await Task.Delay(35, ct);
                foreach (var link in pinged)
                {
                    if (link.IsReady && !ct.IsCancellationRequested)
                        await SendPingAsync(link);
                }
                await Task.Delay(1465, ct);
            }
            else
            {
                await Task.Delay(1500, ct);
            }
        }
    }

    private static Task SendPingAsync(PeerLinkSession link) => link.SendPingTimestampedAsync();

    private void OnFrameReceived(PeerLinkSession link, DeskflowMsgType type, byte[] payload)
    {
        switch (type)
        {
            case DeskflowMsgType.Ping:
                _ = link.SendFrameAsync(DeskflowMsgType.Pong, payload);
                break;

            case DeskflowMsgType.Pong:
                if (payload.Length >= 8 && link.IsReady)
                {
                    ulong sent = 0;
                    for (int i = 0; i < 8; i++) sent = (sent << 8) | payload[i];
                    ulong now = (ulong)Stopwatch.GetTimestamp();
                    if (now >= sent)
                    {
                        double rawRtt = (now - sent) * 1000.0 / Stopwatch.Frequency;
                        bool inBulk = Volatile.Read(ref _activeBulkTransfers) > 0 || !_incomingFiles.IsEmpty;
                        if (rawRtt > 5000.0 || (inBulk && rawRtt > 200.0))
                            break;
                        double? prevRtt = link.RttMs;
                        double nextRtt = link.RttTracker.RecordSample(rawRtt);
                        link.RttMs = nextRtt;
                        if (!prevRtt.HasValue || Math.Abs(nextRtt - prevRtt.Value) >= 0.15)
                            LinksUpdated?.Invoke();
                    }
                }
                break;

            case DeskflowMsgType.Hello:
                try
                {
                    var hello = JsonSerializer.Deserialize<WireHelloPayload>(payload);
                    if (hello != null)
                    {
                        PeerHostName = hello.Host;
                        PeerMonitors = hello.Monitors;
                        PeerMonitorsUpdated?.Invoke(hello.Monitors, hello.Host);
                        foreach (var uip in hello.UsbIps.Where(IsUsbBridgeIp)) _ = ConnectIfNeededAsync(uip, null, isUsb: true);
                        foreach (var lip in hello.Ips.Where(ip => !IsUsbBridgeIp(ip))) _ = ConnectIfNeededAsync(lip, null, isUsb: false);
                    }
                }
                catch (Exception ex)
                {
                    LogMessage?.Invoke($"[ERR] [Link={link.Id}] stage=decode_hello error={ex.Message}");
                }
                break;

            case DeskflowMsgType.ClipboardText:
                RemoteClipboardText?.Invoke(Encoding.UTF8.GetString(payload));
                break;

            case DeskflowMsgType.ClipboardImage:
                RemoteClipboardImage?.Invoke(payload);
                break;

            case DeskflowMsgType.PortalSync:
                try
                {
                    var sync = JsonSerializer.Deserialize<WirePortalSyncPayload>(payload);
                    if (sync != null) RemotePortalSync?.Invoke(sync);
                }
                catch (Exception ex)
                {
                    LogMessage?.Invoke($"[ERR] [Link={link.Id}] stage=decode_portal_sync error={ex.Message}");
                }
                break;

            case DeskflowMsgType.FileOffer:
                try
                {
                    var offer = JsonSerializer.Deserialize<WireFileOfferPayload>(payload);
                    if (offer != null) HandleIncomingFileOffer(offer, link);
                }
                catch (Exception ex)
                {
                    LogMessage?.Invoke($"[ERR] [Link={link.Id}] stage=decode_file_offer error={ex.Message}");
                }
                break;

            case DeskflowMsgType.FileChunk:
                HandleIncomingFileChunk(payload, link);
                break;

            case DeskflowMsgType.FileComplete:
                try
                {
                    var comp = JsonSerializer.Deserialize<WireFileCompletePayload>(payload);
                    if (comp != null) HandleIncomingFileComplete(comp, link);
                }
                catch (Exception ex)
                {
                    LogMessage?.Invoke($"[ERR] [Link={link.Id}] stage=decode_file_complete error={ex.Message}");
                }
                break;

            case DeskflowMsgType.FileAck:
                try
                {
                    var ack = JsonSerializer.Deserialize<WireFileAckPayload>(payload);
                    if (ack != null)
                    {
                        _pendingAckLinks.TryRemove(ack.TransferId, out _);
                        if (_pendingFileAcks.TryRemove(ack.TransferId, out var tcs))
                            tcs.TrySetResult(ack);
                    }
                }
                catch (Exception ex)
                {
                    LogMessage?.Invoke($"[ERR] [Link={link.Id}] stage=decode_file_ack error={ex.Message}");
                }
                break;

            case DeskflowMsgType.MouseMoveAbs:
                if (payload.Length >= 10)
                {
                    int monIdx = (payload[0] << 8) | payload[1];
                    float nx = BitConverter.Int32BitsToSingle((payload[2] << 24) | (payload[3] << 16) | (payload[4] << 8) | payload[5]);
                    float ny = BitConverter.Int32BitsToSingle((payload[6] << 24) | (payload[7] << 16) | (payload[8] << 8) | payload[9]);
                    KvmMouseMoveAbs?.Invoke(monIdx, nx, ny);
                }
                break;

            case DeskflowMsgType.MouseButton:
                if (payload.Length >= 2)
                    KvmMouseButton?.Invoke(payload[0], payload[1] != 0);
                break;

            case DeskflowMsgType.MouseScroll:
                if (payload.Length >= 8)
                {
                    int dy = (payload[0] << 24) | (payload[1] << 16) | (payload[2] << 8) | payload[3];
                    int dx = (payload[4] << 24) | (payload[5] << 16) | (payload[6] << 8) | payload[7];
                    KvmMouseScroll?.Invoke(dy, dx);
                }
                break;

            case DeskflowMsgType.KeyEvent:
                if (payload.Length >= 7)
                {
                    ushort vk = (ushort)((payload[0] << 8) | payload[1]);
                    bool isDown = payload[2] != 0;
                    uint mods = (uint)((payload[3] << 24) | (payload[4] << 16) | (payload[5] << 8) | payload[6]);
                    KvmKeyEvent?.Invoke(vk, isDown, mods);
                }
                break;

            case DeskflowMsgType.SemanticHotkey:
                try
                {
                    var hk = JsonSerializer.Deserialize<WireSemanticHotkeyPayload>(payload);
                    if (hk != null) KvmSemanticHotkey?.Invoke(hk.Action);
                }
                catch (Exception ex)
                {
                    LogMessage?.Invoke($"[ERR] [Link={link.Id}] stage=decode_hotkey error={ex.Message}");
                }
                break;

            case DeskflowMsgType.KvmFocusSwitch:
                try
                {
                    var sw = JsonSerializer.Deserialize<WireKvmFocusPayload>(payload);
                    if (sw != null) KvmFocusSwitch?.Invoke(sw);
                }
                catch (Exception ex)
                {
                    LogMessage?.Invoke($"[ERR] [Link={link.Id}] stage=decode_focus error={ex.Message}");
                }
                break;

            case DeskflowMsgType.TopologyUpdate:
                try
                {
                    var topo = JsonSerializer.Deserialize<WireTopologySyncPayload>(payload);
                    if (topo != null) TopologySync?.Invoke(topo);
                }
                catch (Exception ex)
                {
                    LogMessage?.Invoke($"[ERR] [Link={link.Id}] stage=decode_topology error={ex.Message}");
                }
                break;

            case DeskflowMsgType.ConfigSync:
                try
                {
                    var cfg = JsonSerializer.Deserialize<WireConfigSyncPayload>(payload);
                    if (cfg != null) ConfigSync?.Invoke(cfg);
                }
                catch (Exception ex)
                {
                    LogMessage?.Invoke($"[ERR] [Link={link.Id}] stage=decode_config error={ex.Message}");
                }
                break;
        }
    }

    public sealed record LocalNicInfo(string IfaceName, string Ip, string? Broadcast, string? Mask, double EstMbps);

    private static readonly object _nicCacheLock = new();
    private static List<LocalNicInfo> _cachedLocalNics = new();
    private static DateTime _lastNicCacheUtc = DateTime.MinValue;
    private static int _nicCacheRefreshing = 0;

    public static List<LocalNicInfo> GetCachedLocalIPv4()
    {
        List<LocalNicInfo> snap;
        bool needAsyncRefresh;
        lock (_nicCacheLock)
        {
            snap = _cachedLocalNics;
            needAsyncRefresh = (DateTime.UtcNow - _lastNicCacheUtc).TotalMilliseconds > 1200;
        }
        if (snap.Count == 0)
        {
            // Seed initial snapshot once; subsequent refreshes always run off the UI thread
            snap = RefreshLocalNicCacheSync();
        }
        else if (needAsyncRefresh)
        {
            RefreshLocalNicCacheAsync();
        }
        return snap;
    }

    public static void RefreshLocalNicCacheAsync()
    {
        if (Interlocked.CompareExchange(ref _nicCacheRefreshing, 1, 0) != 0) return;
        _ = Task.Run(() =>
        {
            try { RefreshLocalNicCacheSync(); }
            finally { Interlocked.Exchange(ref _nicCacheRefreshing, 0); }
        });
    }

    public static List<LocalNicInfo> RefreshLocalNicCacheSync()
    {
        var fresh = EnumerateLocalIPv4();
        lock (_nicCacheLock)
        {
            _cachedLocalNics = fresh;
            _lastNicCacheUtc = DateTime.UtcNow;
        }
        return fresh;
    }

    public static List<LocalNicInfo> EnumerateLocalIPv4()
    {
        var result = new List<LocalNicInfo>();
        try
        {
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != OperationalStatus.Up ||
                    ni.NetworkInterfaceType == NetworkInterfaceType.Loopback)
                    continue;
                double rawMbps = ni.Speed > 0 ? (ni.Speed / 1_000_000.0) : (ni.NetworkInterfaceType == NetworkInterfaceType.Wireless80211 ? 1200 : 1000);
                double mbps = ni.NetworkInterfaceType == NetworkInterfaceType.Wireless80211
                    ? Math.Min(2400.0, rawMbps)
                    : Math.Min(2500.0, rawMbps);
                foreach (var ua in ni.GetIPProperties().UnicastAddresses)
                {
                    if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    string ip = ua.Address.ToString();
                    if (ip.StartsWith("169.254.")) continue;

                    double ifaceEst = IsUsbBridgeIp(ip) ? 2400.0 : mbps;
                    string? bcast = null;
                    if (ua.IPv4Mask != null)
                    {
                        byte[] ipB = ua.Address.GetAddressBytes();
                        byte[] mkB = ua.IPv4Mask.GetAddressBytes();
                        byte[] bcB = new byte[4];
                        for (int i = 0; i < 4; i++) bcB[i] = (byte)(ipB[i] | ~mkB[i]);
                        bcast = new IPAddress(bcB).ToString();
                    }
                    result.Add(new LocalNicInfo(ni.Name, ip, bcast, ua.IPv4Mask?.ToString(), Math.Max(300, ifaceEst)));
                }
            }
        }
        catch { }
        return result;
    }

    private WireHelloPayload BuildHelloPayload()
    {
        var nics = EnumerateLocalIPv4();
        return new WireHelloPayload
        {
            Os = "Windows",
            Host = Environment.MachineName,
            Fingerprint = LocalFingerprint,
            Ips = nics.Where(x => !IsUsbBridgeIp(x.Ip)).Select(x => x.Ip).ToList(),
            UsbIps = nics.Where(x => IsUsbBridgeIp(x.Ip)).Select(x => x.Ip).ToList(),
            Monitors = EnumerateRealWindowsMonitors()
        };
    }

    public static List<WireMonitorDto> EnumerateRealWindowsMonitors()
    {
        var list = new List<WireMonitorDto>();
        try
        {
            int idx = 1;
            MonitorEnumProc cb = (IntPtr hMon, IntPtr hdc, ref RECT lprc, IntPtr dwData) =>
            {
                var mi = new MONITORINFOEX { cbSize = Marshal.SizeOf<MONITORINFOEX>() };
                if (GetMonitorInfoW(hMon, ref mi))
                {
                    int w = mi.rcMonitor.Right - mi.rcMonitor.Left;
                    int h = mi.rcMonitor.Bottom - mi.rcMonitor.Top;
                    bool primary = (mi.dwFlags & 1) != 0;
                    string dev = mi.szDevice?.TrimEnd('\0') ?? $"DISPLAY{idx}";
                    list.Add(new WireMonitorDto
                    {
                        Id = $"win_disp_{idx}",
                        DisplayIndex = idx,
                        Name = $"Win {dev.Replace("\\\\.\\", "")} #{idx}",
                        OsKind = "Windows",
                        WidthPx = Math.Max(640, w),
                        HeightPx = Math.Max(480, h),
                        ScaleFactor = 1.0,
                        IsPrimary = primary,
                        BoundsX = mi.rcMonitor.Left,
                        BoundsY = mi.rcMonitor.Top
                    });
                    idx++;
                }
                return true;
            };
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, cb, IntPtr.Zero);
        }
        catch { }

        if (list.Count == 0)
        {
            list.Add(new WireMonitorDto
            {
                Id = "win_disp_1",
                DisplayIndex = 1,
                Name = "Win 主屏 #1",
                OsKind = "Windows",
                WidthPx = (int)System.Windows.SystemParameters.PrimaryScreenWidth,
                HeightPx = (int)System.Windows.SystemParameters.PrimaryScreenHeight,
                ScaleFactor = 1.0,
                IsPrimary = true
            });
        }
        return list;
    }

    private delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFOEX
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szDevice;
    }

    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfoW(IntPtr hMonitor, ref MONITORINFOEX lpmi);

    public void Dispose()
    {
        try { _cts.Cancel(); } catch { }
        try { _rawListener?.Stop(); } catch { }
        try { _tlsListener?.Stop(); } catch { }
        try { _udpClient?.Dispose(); } catch { }
        foreach (var l in _links.Values) l.Dispose();
        _links.Clear();
        foreach (var st in _incomingFiles.Values)
        {
            lock (st.SyncLock)
            {
                try { st.PendingGraceCts?.Cancel(); st.PendingGraceCts?.Dispose(); } catch { }
                try { st.Stream.Dispose(); } catch { }
                try { if (Directory.Exists(st.StagingDir)) Directory.Delete(st.StagingDir, true); } catch { }
            }
        }
        _incomingFiles.Clear();
        _earlyFileChunks.Clear();
        Interlocked.Exchange(ref _earlyChunkTotalBytes, 0);
        foreach (var kv in _pendingFileAcks)
        {
            kv.Value.TrySetResult(new WireFileAckPayload { TransferId = kv.Key, Ok = false, Error = "传输服务已关闭" });
        }
        _pendingFileAcks.Clear();
        _pendingAckLinks.Clear();
    }
}
