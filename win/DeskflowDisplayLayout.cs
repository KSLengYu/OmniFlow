using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Threading;

namespace MacBridgeUI;

public sealed partial class DeskflowService
{
    public void IdentifyScreensBothSides()
    {
        IdentifyScreensRequested?.Invoke();
        Transport.SendControlJson(DeskflowMsgType.SemanticHotkey, new WireSemanticHotkeyPayload { Action = "IDENTIFY_SCREENS" });
        LogMessage?.Invoke("[Display] 已在 Windows 与 Mac 双端同步点亮屏幕编号");
    }

    public void ResetMonitorLayout(bool preservePositions = true)
    {
        var savedPos = new Dictionary<string, (double X, double Y)>(StringComparer.OrdinalIgnoreCase);
        if (preservePositions)
        {
            foreach (var m in Monitors)
            {
                if (!string.IsNullOrEmpty(m.Id))
                    savedPos.TryAdd(m.Id, (m.CanvasX, m.CanvasY));
            }
        }

        if (!preservePositions)
        {
            _syncedPositions.Clear();
            _savedMonitorPositions.Clear();
        }

        _localMonitors = DeskflowTransport.EnumerateRealWindowsMonitors();
        var list = new List<IndependentMonitorItem>();
        var usedIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        const double originX = 100.0;
        const double originY = 100.0;
        const double layoutScale = 0.068;

        if (_peerMonitors.Count > 0)
        {
            double minMacX = _peerMonitors.Min(m => (double)m.BoundsX);
            double minMacY = _peerMonitors.Min(m => (double)m.BoundsY);

            int pmIdx = 0;
            foreach (var pm in _peerMonitors)
            {
                string pmId = string.IsNullOrWhiteSpace(pm.Id) ? $"peer_disp_{Math.Max(1, pm.DisplayIndex)}_{pmIdx}" : pm.Id.Trim();
                if (!usedIds.Add(pmId))
                {
                    int suffix = 2;
                    string cand = $"peer_{pmId}";
                    while (!usedIds.Add(cand))
                        cand = $"peer_{pmId}_{suffix++}";
                    pmId = cand;
                }
                pmIdx++;
                var node = new IndependentMonitorItem
                {
                    Id = pmId,
                    DisplayIndex = pm.DisplayIndex,
                    Name = pm.Name,
                    OsKind = "macOS",
                    WidthPx = pm.WidthPx,
                    HeightPx = pm.HeightPx,
                    ScaleFactor = pm.ScaleFactor > 0 ? pm.ScaleFactor : 1.0,
                    BoundsX = pm.BoundsX,
                    BoundsY = pm.BoundsY,
                    IsPrimary = pm.IsPrimary,
                    CanvasX = originX + Math.Round((pm.BoundsX - minMacX) * layoutScale),
                    CanvasY = originY + Math.Round((pm.BoundsY - minMacY) * layoutScale)
                };

                if (_syncedPositions.TryGetValue(pmId, out var synced) || _syncedPositions.TryGetValue(pm.Id, out synced))
                {
                    node.CanvasX = synced.X;
                    node.CanvasY = synced.Y;
                }
                else if (savedPos.TryGetValue(pmId, out var pos) || savedPos.TryGetValue(pm.Id, out pos))
                {
                    node.CanvasX = pos.X;
                    node.CanvasY = pos.Y;
                }
                list.Add(node);
            }
        }

        double winBaseX = list.Count > 0 ? list.Max(m => m.CanvasX + m.AspectWidth) : originX;
        double winBaseY = list.FirstOrDefault(m => m.IsPrimary)?.CanvasY ?? list.FirstOrDefault()?.CanvasY ?? originY;

        if (_localMonitors.Count > 0)
        {
            double minWinX = _localMonitors.Min(m => (double)m.BoundsX);
            double minWinY = _localMonitors.Min(m => (double)m.BoundsY);

            int lmIdx = 0;
            foreach (var lm in _localMonitors)
            {
                string lmId = string.IsNullOrWhiteSpace(lm.Id) ? $"win_disp_{Math.Max(1, lm.DisplayIndex)}_{lmIdx}" : lm.Id.Trim();
                if (!usedIds.Add(lmId))
                {
                    int suffix = 2;
                    string cand = $"local_{lmId}";
                    while (!usedIds.Add(cand))
                        cand = $"local_{lmId}_{suffix++}";
                    lmId = cand;
                }
                lmIdx++;
                var node = new IndependentMonitorItem
                {
                    Id = lmId,
                    DisplayIndex = lm.DisplayIndex,
                    Name = lm.Name,
                    OsKind = "Windows",
                    WidthPx = lm.WidthPx,
                    HeightPx = lm.HeightPx,
                    ScaleFactor = lm.ScaleFactor > 0 ? lm.ScaleFactor : 1.0,
                    BoundsX = lm.BoundsX,
                    BoundsY = lm.BoundsY,
                    IsPrimary = lm.IsPrimary,
                    CanvasX = winBaseX + Math.Round((lm.BoundsX - minWinX) * layoutScale),
                    CanvasY = winBaseY + Math.Round((lm.BoundsY - minWinY) * layoutScale)
                };
                if (_syncedPositions.TryGetValue(lmId, out var synced) || _syncedPositions.TryGetValue(lm.Id, out synced))
                {
                    node.CanvasX = synced.X;
                    node.CanvasY = synced.Y;
                }
                else if (savedPos.TryGetValue(lmId, out var pos) || savedPos.TryGetValue(lm.Id, out pos))
                {
                    node.CanvasX = pos.X;
                    node.CanvasY = pos.Y;
                }
                list.Add(node);
            }
        }

        Monitors = list;
        bool allHaveSaved = Monitors.Count > 0 && Monitors.All(m => _savedMonitorPositions.ContainsKey(m.Id));
        if (!allHaveSaved)
        {
            ResolveDisplayOverlaps();
            CenterDisplayCluster(_lastCanvasW, _lastCanvasH, persistToSynced: _peerMonitors.Count > 0 || !preservePositions);
        }
        else if (_peerMonitors.Count == 0)
        {
            // Peer not connected yet -> center local monitor visually WITHOUT overwriting saved multi-monitor coords
            CenterDisplayCluster(_lastCanvasW, _lastCanvasH, persistToSynced: false);
        }

        if (string.IsNullOrEmpty(SelectedMonitorId) || !Monitors.Any(m => m.Id == SelectedMonitorId))
            SelectedMonitorId = Monitors.FirstOrDefault()?.Id;

        SyncPortalEdgeFromDisplayLayout();

        if (!preservePositions)
        {
            SaveMonitorLayout(silent: true);
            ScheduleTopologySync();
        }
    }

    public void ResolveDisplayOverlaps(string? anchoredId = null)
    {
        if (Monitors.Count <= 1) return;
        for (int pass = 0; pass < 6; pass++)
        {
            bool changed = false;
            for (int i = 0; i < Monitors.Count; i++)
            {
                for (int j = 0; j < Monitors.Count; j++)
                {
                    if (i == j) continue;
                    var a = Monitors[i];
                    var b = Monitors[j];
                    if (b.Id == anchoredId) continue;

                    double aL = a.CanvasX + 2, aR = a.CanvasX + a.AspectWidth - 2, aT = a.CanvasY + 2, aB = a.CanvasY + a.AspectHeight - 2;
                    double bL = b.CanvasX + 2, bR = b.CanvasX + b.AspectWidth - 2, bT = b.CanvasY + 2, bB = b.CanvasY + b.AspectHeight - 2;
                    if (aL < bR && aR > bL && aT < bB && aB > bT)
                    {
                        double pushRight = (a.CanvasX + a.AspectWidth) - b.CanvasX;
                        double pushLeft  = (b.CanvasX + b.AspectWidth) - a.CanvasX;
                        double pushDown  = (a.CanvasY + a.AspectHeight) - b.CanvasY;
                        double pushUp    = (b.CanvasY + b.AspectHeight) - a.CanvasY;
                        double minPush = Math.Min(Math.Min(pushRight, pushLeft), Math.Min(pushDown, pushUp));
                        if (minPush == pushRight) b.CanvasX = a.CanvasX + a.AspectWidth;
                        else if (minPush == pushLeft) b.CanvasX = a.CanvasX - b.AspectWidth;
                        else if (minPush == pushDown) b.CanvasY = a.CanvasY + a.AspectHeight;
                        else b.CanvasY = a.CanvasY - b.AspectHeight;
                        changed = true;
                    }
                }
            }
            if (!changed) break;
        }
    }

    public void CenterDisplayCluster(double canvasW = 680, double canvasH = 360, bool persistToSynced = true, bool ignoreSavedGuard = false)
    {
        if (canvasW > 100) _lastCanvasW = canvasW;
        if (canvasH > 100) _lastCanvasH = canvasH;
        if (Monitors.Count == 0) return;

        bool allSaved = Monitors.All(m => _savedMonitorPositions.ContainsKey(m.Id));
        if (!ignoreSavedGuard && persistToSynced && allSaved && _peerMonitors.Count > 0)
        {
            // Preserve exact saved arrangement once both peers are present unless user drags/resets
            return;
        }

        double cw = Math.Max(560, _lastCanvasW);
        double ch = Math.Max(320, _lastCanvasH);
        double minX = Monitors.Min(m => m.CanvasX);
        double maxX = Monitors.Max(m => m.CanvasX + m.AspectWidth);
        double minY = Monitors.Min(m => m.CanvasY);
        double maxY = Monitors.Max(m => m.CanvasY + m.AspectHeight);

        double dx = (cw * 0.5) - ((minX + maxX) * 0.5);
        double dy = (ch * 0.5) - ((minY + maxY) * 0.5);

        foreach (var m in Monitors)
        {
            m.CanvasX = Math.Round(m.CanvasX + dx);
            m.CanvasY = Math.Round(m.CanvasY + dy);
            if (persistToSynced)
                _syncedPositions[m.Id] = (m.CanvasX, m.CanvasY);
        }
    }

    public void FinishMonitorDrag(string id, double canvasW, double canvasH)
    {
        var item = Monitors.FirstOrDefault(m => m.Id == id);
        if (item != null)
        {
            double w = item.AspectWidth;
            double h = item.AspectHeight;
            double tx = item.CanvasX;
            double ty = item.CanvasY;
            const double snap = 7.0;
            foreach (var other in Monitors)
            {
                if (other.Id == id) continue;
                double ox = other.CanvasX, oy = other.CanvasY, ow = other.AspectWidth, oh = other.AspectHeight;
                if (Math.Abs((tx + w) - ox) < snap) tx = ox - w;
                else if (Math.Abs(tx - (ox + ow)) < snap) tx = ox + ow;
                else if (Math.Abs(tx - ox) < snap) tx = ox;
                else if (Math.Abs((tx + w) - (ox + ow)) < snap) tx = ox + ow - w;

                if (Math.Abs((ty + h) - oy) < snap) ty = oy - h;
                else if (Math.Abs(ty - (oy + oh)) < snap) ty = oy + oh;
                else if (Math.Abs(ty - oy) < snap) ty = oy;
                else if (Math.Abs((ty + h) - (oy + oh)) < snap) ty = oy + oh - h;
            }
            item.CanvasX = tx;
            item.CanvasY = ty;
            _syncedPositions[id] = (tx, ty);
        }
        ResolveDisplayOverlaps(anchoredId: id);
        CenterDisplayCluster(canvasW, canvasH, persistToSynced: true, ignoreSavedGuard: true);
        SyncPortalEdgeFromDisplayLayout();
        SaveMonitorLayout(silent: true);
        ScheduleTopologySync();
        MonitorsUpdated?.Invoke();
        StateUpdated?.Invoke();
    }

    public void SyncPortalEdgeFromDisplayLayout()
    {
        var winNodes = Monitors.Where(m => m.OsKind == "Windows").ToList();
        var macNodes = Monitors.Where(m => m.OsKind == "macOS").ToList();
        if (winNodes.Count == 0 || macNodes.Count == 0) return;

        var bestWin = winNodes[0];
        var bestMac = macNodes[0];
        double bestDist = double.MaxValue;

        foreach (var w in winNodes)
        {
            double wx = w.CanvasX + w.AspectWidth * 0.5;
            double wy = w.CanvasY + w.AspectHeight * 0.5;
            foreach (var m in macNodes)
            {
                double mx = m.CanvasX + m.AspectWidth * 0.5;
                double my = m.CanvasY + m.AspectHeight * 0.5;
                double d = Math.Sqrt((mx - wx) * (mx - wx) + (my - wy) * (my - wy));
                if (d < bestDist)
                {
                    bestDist = d;
                    bestWin = w;
                    bestMac = m;
                }
            }
        }

        double dx = (bestMac.CanvasX + bestMac.AspectWidth * 0.5) - (bestWin.CanvasX + bestWin.AspectWidth * 0.5);
        double dy = (bestMac.CanvasY + bestMac.AspectHeight * 0.5) - (bestWin.CanvasY + bestWin.AspectHeight * 0.5);

        EdgeSide = Math.Abs(dx) >= Math.Abs(dy)
            ? (dx >= 0 ? ScreenEdgeSide.Right : ScreenEdgeSide.Left)
            : (dy >= 0 ? ScreenEdgeSide.Bottom : ScreenEdgeSide.Top);
        PortalMonitorIndex = bestWin.DisplayIndex;
    }

    public void ScheduleTopologySync()
    {
        if (_topologySyncTimer == null)
        {
            _topologySyncTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(140) };
            _topologySyncTimer.Tick += (_, _) =>
            {
                _topologySyncTimer?.Stop();
                SendTopologySyncNow();
            };
        }
        _topologySyncTimer.Stop();
        _topologySyncTimer.Start();
    }

    public void SendTopologySyncNow()
    {
        if (Monitors.Count == 0) return;
        var payload = new WireTopologySyncPayload
        {
            SenderOs = "Windows",
            Timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0,
            Items = Monitors.Select(m => new WireMonitorLayoutEntry
            {
                Id = m.Id,
                CanvasX = m.CanvasX,
                CanvasY = m.CanvasY,
                DisplayIndex = m.DisplayIndex,
                Name = m.Name,
                OsKind = m.OsKind,
                WidthPx = m.WidthPx,
                HeightPx = m.HeightPx,
                ScaleFactor = 1.0,
                IsPrimary = m.IsPrimary
            }).ToList()
        };
        Transport.SendControlJson(DeskflowMsgType.TopologyUpdate, payload);
    }

    public void UpdateMonitorPosition2D(string id, double x, double y, double canvasW = 680, double canvasH = 360)
    {
        if (canvasW > 100) _lastCanvasW = canvasW;
        if (canvasH > 100) _lastCanvasH = canvasH;
        var item = Monitors.FirstOrDefault(m => m.Id == id);
        if (item == null) return;

        double w = item.AspectWidth;
        double h = item.AspectHeight;
        double targetX = Math.Clamp(x, 12, Math.Max(20, canvasW - w - 12));
        double targetY = Math.Clamp(y, 12, Math.Max(20, canvasH - h - 12));

        item.CanvasX = targetX;
        item.CanvasY = targetY;
        _syncedPositions[id] = (targetX, targetY);
    }
}
