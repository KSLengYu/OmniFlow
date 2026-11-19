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

