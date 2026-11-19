using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace MacBridgeUI;

public sealed partial class DeskflowService
{
    internal static class WinKvmStageTracer
    {
        private static readonly object _qLock = new();
        private static readonly Queue<string> _pending = new();
        private static bool _draining = false;
        private static long _seq = 0;

        public static long BeginCrossing(long nowTicks)
        {
            return Interlocked.Increment(ref _seq);
        }

        public static void Log(long seq, long t0Ticks, string detail, long? nowTicks = null, string? customLogPath = null, bool sync = false)
        {
            if (seq <= 0 || t0Ticks <= 0) return;
            long now = nowTicks ?? Stopwatch.GetTimestamp();
            double deltaMs = now >= t0Ticks ? (now - t0Ticks) * 1000.0 / Stopwatch.Frequency : 0.0;
            string line = $"[{DateTime.Now:HH:mm:ss.fff}] [KVM-Stage-Win seq=#{seq} +{deltaMs:F2}ms] {detail}{Environment.NewLine}";
            if (sync)
            {
                AppendLines(customLogPath ?? OmniFlowPaths.RuntimeLogPath, new[] { line });
                return;
            }
            bool kick = false;
            lock (_qLock)
            {
                _pending.Enqueue(line);
                if (!_draining)
                {
                    _draining = true;
                    kick = true;
                }
            }
            if (kick)
            {
                ThreadPool.QueueUserWorkItem(_ => Drain(customLogPath ?? OmniFlowPaths.RuntimeLogPath));
            }
        }

        private static void Drain(string path)
        {
            while (true)
            {
                List<string> batch;
                lock (_qLock)
                {
                    if (_pending.Count == 0)
                    {
                        _draining = false;
                        return;
                    }
                    batch = new List<string>(_pending.Count);
                    while (_pending.Count > 0) batch.Add(_pending.Dequeue());
                }
                AppendLines(path, batch);
            }
        }

        private static void AppendLines(string path, IEnumerable<string> lines)
        {
            try
            {
                string? dir = Path.GetDirectoryName(path);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                using var fs = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
                using var sw = new StreamWriter(fs, System.Text.Encoding.UTF8);
                foreach (var l in lines) sw.Write(l);
            }
            catch { }
        }
    }

    internal sealed class WinCursorTransitionTracker
    {
        private struct RawPacket
        {
            public int Dx;
            public int Dy;
            public uint MsgTimeMs;
            public long QpcTicks;
            public bool Consumed;
        }

        private readonly object _lock = new();
        private readonly RawPacket[] _localRing = new RawPacket[16];
        private int _ringWriteIdx;

        private bool _isRemote;
        private int _anchorX = -1;
        private int _anchorY = -1;
        private bool _waitingHookAnchor;
        private bool _awaitingPostCrossRaw;
        private uint _crossTimeMs;
        private long _stageSeq;
        private long _stageT0Ticks;
        private long _lastRawInputTicks;
        private long _lastCommittedLocalTicks;

        // Remaining physical movement spent reaching the Windows border during the crossing frame.
        // Deducted once from the delayed WM_INPUT crossing report so overshoot transfers without doubling.
        private int _crossCreditX;
        private int _crossCreditY;
        private long _crossCreditExpiryTicks;

        // Short-lived credit if WH_MOUSE_LL fallback ran before a sudden late WM_INPUT arrival.
        private int _fallbackHookCreditX;
        private int _fallbackHookCreditY;
        private long _fallbackHookCreditExpiryTicks;

        private int _loggedRawCount;
        private bool _loggedFirstHookPost;

        public int AnchorX { get { lock (_lock) return _anchorX; } }
        public int AnchorY { get { lock (_lock) return _anchorY; } }

        public bool IsRawInputActive(long nowTicks)
        {
            lock (_lock) return IsRawInputActiveLocked(nowTicks);
        }

        private bool IsRawInputActiveLocked(long nowTicks) =>
            _lastRawInputTicks != 0 && (nowTicks - _lastRawInputTicks) <= (long)(Stopwatch.Frequency * 300.0);

        public void CommitLocalMove(long nowTicks)
        {
            lock (_lock)
            {
                if (_isRemote) return;
                if (nowTicks > _lastCommittedLocalTicks)
                {
                    _lastCommittedLocalTicks = nowTicks;
                }
                for (int i = 0; i < _localRing.Length; i++)
                {
                    if (!_localRing[i].Consumed && _localRing[i].QpcTicks <= nowTicks)
                    {
                        _localRing[i].Consumed = true;
                    }
                }
            }
        }

        public void EnterRemote(
            int anchorX,
            int anchorY,
            int curX,
            int curY,
            int crossHookDx,
            int crossHookDy,
            uint crossTimeMs,
            long nowTicks,
            long stageSeq,
            out int preOvershootX,
            out int preOvershootY)
        {
            lock (_lock)
            {
                _isRemote = true;
                _anchorX = anchorX;
                _anchorY = anchorY;
                _waitingHookAnchor = (curX != anchorX || curY != anchorY);
                _awaitingPostCrossRaw = (crossTimeMs != 0);
                _crossTimeMs = crossTimeMs;
                _stageSeq = stageSeq;
                _stageT0Ticks = nowTicks;

                int creditX = Math.Clamp(crossHookDx, -450, 450);
                int creditY = Math.Clamp(crossHookDy, -450, 450);

                // Check whether WM_INPUT for this exact crossing swipe already ran in WndProc
                // after the last committed local WH_MOUSE_LL move and slightly ahead of crossing WH_MOUSE_LL;
                // if so, preserve its overshoot immediately and consume it.
                int matchedRawX = 0;
                int matchedRawY = 0;
                long freshCutoff = nowTicks - (long)(Stopwatch.Frequency * 0.016);
                if (_lastCommittedLocalTicks > freshCutoff)
                {
                    freshCutoff = _lastCommittedLocalTicks;
                }
                for (int i = 0; i < _localRing.Length; i++)
                {
                    if (!_localRing[i].Consumed &&
                        (_lastCommittedLocalTicks > 0 ? _localRing[i].QpcTicks > _lastCommittedLocalTicks : _localRing[i].QpcTicks >= freshCutoff) &&
                        unchecked((int)(_localRing[i].MsgTimeMs - crossTimeMs)) >= -16)
                    {
                        matchedRawX += _localRing[i].Dx;
                        matchedRawY += _localRing[i].Dy;
                        _localRing[i].Consumed = true;
                    }
                }

                if (matchedRawX != 0 || matchedRawY != 0)
                {
                    preOvershootX = ConsumeWithCredit(matchedRawX, ref creditX);
                    preOvershootY = ConsumeWithCredit(matchedRawY, ref creditY);
                    _awaitingPostCrossRaw = false;
                }
                else
                {
                    preOvershootX = 0;
                    preOvershootY = 0;
                }

                _crossCreditX = creditX;
                _crossCreditY = creditY;
                _crossCreditExpiryTicks = nowTicks + (long)(Stopwatch.Frequency * 0.045);

                _fallbackHookCreditX = 0;
                _fallbackHookCreditY = 0;
                _fallbackHookCreditExpiryTicks = 0;
                _loggedRawCount = 0;
                _loggedFirstHookPost = false;
            }
        }

        public void EnterRemote(int anchorX, int anchorY, int curX, int curY, uint crossTimeMs, long nowTicks)
        {
            EnterRemote(anchorX, anchorY, curX, curY, 0, 0, crossTimeMs, nowTicks, 0, out _, out _);
        }

        public void ExitRemote()
        {
            lock (_lock)
            {
                _isRemote = false;
                _waitingHookAnchor = false;
                _awaitingPostCrossRaw = false;
                _crossCreditX = 0;
                _crossCreditY = 0;
                _fallbackHookCreditX = 0;
                _fallbackHookCreditY = 0;
            }
        }

        public void StartRewarp(int anchorX, int anchorY, uint eventTimeMs, long nowTicks)
        {
            lock (_lock)
            {
                _anchorX = anchorX;
                _anchorY = anchorY;
                _waitingHookAnchor = true;
                _crossTimeMs = eventTimeMs;
            }
        }

        public (bool needsRewarp, int dx, int dy) ProcessHookMouseMove(
            int ptX,
            int ptY,
            uint eventTimeMs,
            long nowTicks,
            int monLeft = int.MinValue,
            int monTop = int.MinValue,
            int monRight = int.MaxValue,
            int monBottom = int.MaxValue)
        {
            long logSeq = 0;
            long logT0 = 0;
            string? logMsg = null;

            lock (_lock)
            {
                if (_anchorX < 0)
                {
                    _anchorX = ptX;
                    _anchorY = ptY;
                }

                if (_waitingHookAnchor)
                {
                    if (ptX == _anchorX && ptY == _anchorY)
                    {
                        _waitingHookAnchor = false;
                        if (!_loggedFirstHookPost && _stageSeq > 0)
                        {
                            _loggedFirstHookPost = true;
                            logSeq = _stageSeq;
                            logT0 = _stageT0Ticks;
                            logMsg = $"hookPostRelocate pt=({ptX},{ptY}) echo=true rawActive={IsRawInputActiveLocked(nowTicks)} tMsg={eventTimeMs}";
                        }
                        goto Done;
                    }

                    // Deskflow MSWindowsComputer::onMouseMove geometric bogus-jump guard:
                    // Ignore stale pre-warp events near the old crossing edge until cursor settles at center anchor.
                    int bogusHalfW = (monRight > monLeft && monRight < int.MaxValue && monLeft > int.MinValue)
                        ? Math.Max(120, ((monRight - monLeft) >> 1) - 10)
                        : 450;
                    int bogusHalfH = (monBottom > monTop && monBottom < int.MaxValue && monTop > int.MinValue)
                        ? Math.Max(120, ((monBottom - monTop) >> 1) - 10)
                        : 450;
                    bool isPreWarpJump = Math.Abs(ptX - _anchorX) >= bogusHalfW || Math.Abs(ptY - _anchorY) >= bogusHalfH;
                    if (isPreWarpJump)
                    {
                        if (!_loggedFirstHookPost && _stageSeq > 0)
                        {
                            _loggedFirstHookPost = true;
                            logSeq = _stageSeq;
                            logT0 = _stageT0Ticks;
                            logMsg = $"hookPostRelocate pt=({ptX},{ptY}) echo=false_preWarpBogus rawActive={IsRawInputActiveLocked(nowTicks)} tMsg={eventTimeMs}";
                        }
                        goto Done;
                    }

                    // Cursor is already near center anchor (OS coalesced warp echo with first small move).
                    _waitingHookAnchor = false;
                }

                if (!_loggedFirstHookPost && _stageSeq > 0)
                {
                    _loggedFirstHookPost = true;
                    logSeq = _stageSeq;
                    logT0 = _stageT0Ticks;
                    logMsg = $"hookPostRelocate pt=({ptX},{ptY}) echo=false rawActive={IsRawInputActiveLocked(nowTicks)} tMsg={eventTimeMs}";
                }

                // When hardware/PTP WM_INPUT RIM_TYPEMOUSE is active, let WM_INPUT deliver 100% of
                // unclamped relative deltas while WH_MOUSE_LL silently keeps the local cursor pinned at anchor.
                if (IsRawInputActiveLocked(nowTicks))
                {
                    return EmitLogAndReturn(logSeq, logT0, logMsg, nowTicks, (false, 0, 0));
                }

                // Fallback path ONLY when no WM_INPUT packets exist (e.g. RDP/synthetic pointer).
                int outDx = ptX - _anchorX;
                int outDy = ptY - _anchorY;
                if (Math.Abs(outDx) > 900 || Math.Abs(outDy) > 900)
                {
                    return EmitLogAndReturn(logSeq, logT0, logMsg, nowTicks, (true, 0, 0));
                }

                bool nearFallbackEdge = (monRight - monLeft > 260) &&
                    (ptX <= monLeft + 1 || ptX >= monRight - 2 || ptY <= monTop + 1 || ptY >= monBottom - 2);

                _fallbackHookCreditX += outDx;
                _fallbackHookCreditY += outDy;
                _fallbackHookCreditExpiryTicks = nowTicks + (long)(Stopwatch.Frequency * 0.004);
                return EmitLogAndReturn(logSeq, logT0, logMsg, nowTicks, (nearFallbackEdge, outDx, outDy));
            }

        Done:
            return EmitLogAndReturn(logSeq, logT0, logMsg, nowTicks, (false, 0, 0));
        }

        private static (bool needsRewarp, int dx, int dy) EmitLogAndReturn(
            long logSeq, long logT0, string? logMsg, long nowTicks, (bool needsRewarp, int dx, int dy) result)
        {
            if (logMsg != null) WinKvmStageTracer.Log(logSeq, logT0, logMsg, nowTicks);
            return result;
        }

        public (int dx, int dy) ProcessRawMouseInput(int lLastX, int lLastY, uint msgTimeMs, long nowTicks, IntPtr hDevice = default)
        {
            long logSeq = 0;
            long logT0 = 0;
            string? logMsg = null;
            int outDx = 0;
            int outDy = 0;

            lock (_lock)
            {
                _lastRawInputTicks = nowTicks;
                if (!_isRemote)
                {
                    _localRing[_ringWriteIdx] = new RawPacket
                    {
                        Dx = lLastX,
                        Dy = lLastY,
                        MsgTimeMs = msgTimeMs,
                        QpcTicks = nowTicks,
                        Consumed = false
                    };
                    _ringWriteIdx = (_ringWriteIdx + 1) % _localRing.Length;
                    return (0, 0);
                }

                if (nowTicks > _crossCreditExpiryTicks)
                {
                    _crossCreditX = 0;
                    _crossCreditY = 0;
                }
                if (nowTicks > _fallbackHookCreditExpiryTicks)
                {
                    _fallbackHookCreditX = 0;
                    _fallbackHookCreditY = 0;
                }

                // Ignore obviously stale packets emitted well before the edge crossing until post-cross stream starts.
                if (_awaitingPostCrossRaw && unchecked((int)(msgTimeMs - _crossTimeMs)) < -16)
                {
                    if (_stageSeq > 0 && _loggedRawCount < 3)
                    {
                        _loggedRawCount++;
                        logSeq = _stageSeq;
                        logT0 = _stageT0Ticks;
                        logMsg = $"rawInput #{_loggedRawCount} skipped=preCross raw=({lLastX},{lLastY}) tMsg={msgTimeMs} crossT={_crossTimeMs}";
                    }
                    goto Done;
                }
                _awaitingPostCrossRaw = false;

                int dx = lLastX;
                int dy = lLastY;
                if (_crossCreditX != 0 || _crossCreditY != 0)
                {
                    dx = ConsumeWithCredit(dx, ref _crossCreditX);
                    dy = ConsumeWithCredit(dy, ref _crossCreditY);
                }
                if (_fallbackHookCreditX != 0 || _fallbackHookCreditY != 0)
                {
                    dx = ConsumeWithCredit(dx, ref _fallbackHookCreditX);
                    dy = ConsumeWithCredit(dy, ref _fallbackHookCreditY);
                }

                outDx = dx;
                outDy = dy;

                if (_stageSeq > 0 && _loggedRawCount < 3)
                {
                    _loggedRawCount++;
                    logSeq = _stageSeq;
                    logT0 = _stageT0Ticks;
                    logMsg = $"rawInput #{_loggedRawCount} raw=({lLastX},{lLastY}) out=({outDx},{outDy}) remCross=({_crossCreditX},{_crossCreditY}) hDev=0x{hDevice.ToInt64():X} tMsg={msgTimeMs}";
                }
            }

        Done:
            if (logMsg != null) WinKvmStageTracer.Log(logSeq, logT0, logMsg, nowTicks);
            return (outDx, outDy);
        }

        private static int ConsumeWithCredit(int rawDelta, ref int credit)
        {
            if (rawDelta == 0) return 0;
            if (credit == 0) return rawDelta;
            if ((rawDelta > 0 && credit > 0) || (rawDelta < 0 && credit < 0))
            {
                if (Math.Abs(rawDelta) <= Math.Abs(credit))
                {
                    credit -= rawDelta;
                    return 0;
                }
                int remaining = rawDelta - credit;
                credit = 0;
                return remaining;
            }
            return rawDelta;
        }
    }
}
