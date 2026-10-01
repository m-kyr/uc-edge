#!/usr/bin/env python3
"""Ground truth for the s1/s2 trace replays (SPEC §10 item 4).

Writes Tests/UCEdgeCoreTests/Support/s2-crossings.json, which TraceReplayTests.swift loads.
Run from anywhere:  python3 Tests/UCEdgeCoreTests/Support/groundtruth.py

ALIGNMENT METHOD
----------------
Three clocks are involved: each recorder's own `t` (ms since that recorder started, header
`start` is only to the second), and each Mac's wall clock in its UC log.

1. Trace -> own UC log. On the receiving Mac, a UC landing is a position jump after a long
   freeze, observed by the 1 kHz poller within ~1 ms of UC's "Warp Location" log line (fact 3).
   Pairing every such jump with the nearest "Warp Location" of that Mac gives one estimate of
   `wall = t + a`; `a` is the median, and its spread is printed (about +-1.5 ms).
2. Trace -> other trace. Pairing each sender "Target Ready: edge=..." with the receiver's
   "Warp Location" shows the receiver's warp and the sender's Target Ready are simultaneous
   to ~0.3 ms of true time once the two wall clocks' offset (MacBook ~7.8 ms behind V-Mind,
   estimated from the symmetric V->M / M->V pairs) is removed. So, as SPEC §10 says, the
   sender's Target Ready (converted to sender trace time with `a`) is taken as the receiver's
   landing sample time. Every s2 top/bottom and side crossing gives one estimate of
   `k = t_macbook - t_vmind`; `k` is their median. The estimates agree within about +-4 ms,
   except one log pair (S1) whose receiver warped 15 ms after the sender's Target Ready.
3. Consistency checks (asserted below):
   * each upward crossing's V-Mind TAP event x satisfies offset = (x + 961) / 961 (SPEC §2);
   * each downward crossing into monitor 5 satisfies offset = (x + 2560) / 961 (UC zone
     [-2560,-1599]); into monitor 4 UC logs the raw MacBook x as the "offset" (measured here);
   * that TAP event lies a few ms *before* the receiver's landing after alignment, and the
     receiver really was frozen before it.

"Exit x" is the source-side x UC itself used (from the logged offset, which equals a TAP x to
0.01 pt). The source cursor keeps receiving "tail" events for up to ~70 ms after UC starts the
crossing, so the final frozen x can differ (up to 275 pt in U3); both are recorded.
"""
import json
import math
import os
import re
import statistics as st

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
TD = os.path.join(ROOT, "testdata")

VM_SPAN = (-1600.0, 1600.0)   # V-Mind top edge: monitors 5 + 4
MB_SPAN = (-2560.0, 0.0)      # MacBook bottom edge: display 3


def physical_map(x, src, dst):
    f = (x - src[0]) / (src[1] - src[0])
    return min(max(dst[0] + f * (dst[1] - dst[0]), dst[0]), dst[1])


def hms_ms(s):
    h, m, sec = s.split(":")
    return (int(h) * 3600 + int(m) * 60 + float(sec)) * 1000.0


def fmt_ms(ms):
    h = int(ms // 3600000)
    m = int(ms % 3600000 // 60000)
    s = ms % 60000 / 1000.0
    return f"{h:02d}:{m:02d}:{s:06.3f}"


POLL = re.compile(r"^([\d.]+) (-?[\d.]+) (-?[\d.]+) b(\d) still=(\d+)")
TAP = re.compile(r"^([\d.]+) TAP t(\d+) \((-?[\d.]+),(-?[\d.]+)\) dx=(-?\d+) dy=(-?\d+)")


def parse_trace(name):
    polls, taps, warps, start = [], [], [], None
    for line in open(os.path.join(TD, name)):
        if m := POLL.match(line):
            polls.append(dict(t=float(m[1]), x=float(m[2]), y=float(m[3]), b=int(m[4]), still=float(m[5])))
        elif m := TAP.match(line):
            taps.append(dict(t=float(m[1]), type=int(m[2]), x=float(m[3]), y=float(m[4]), dx=int(m[5]), dy=int(m[6])))
        elif " WARP " in line:
            warps.append(float(line.split()[0]))
        elif line.startswith("start "):
            start = hms_ms(line.split()[2])
    return dict(polls=polls, taps=taps, warps=warps, start=start)


LOGLINE = re.compile(r"^\S+ (\d+:\d+:\d+\.\d+) .*?\] (.*)$")


def parse_uclog(name):
    ready, warp, last_activating = [], [], None
    for line in open(os.path.join(TD, name)):
        m = LOGLINE.match(line)
        t, msg = hms_ms(m[1]), m[2]
        if "Hot Zone: Activating:" in msg:
            last_activating = t
        elif r := re.search(r"Target Ready: edge=(\w+), offset=(-?[\d.]+)", msg):
            ready.append(dict(wall=t, edge=r[1], offset=float(r[2]), activating=last_activating))
        elif "Warp Location" in msg:
            warp.append(t)
    return ready, warp


def jumps(trace, min_still, min_jump):
    """Poll samples that move after a freeze. With TAP data, a UC landing is a jump *without*
    a matching TAP event (fact 3); ordinary first moves after a pause always have one."""
    taps = trace["taps"]
    out, prev = [], None
    for p in trace["polls"]:
        if prev is not None and p["t"] - prev["t"] >= min_still:
            if math.hypot(p["x"] - prev["x"], p["y"] - prev["y"]) >= min_jump:
                has_tap = any(abs(e["t"] - p["t"]) <= 25 and abs(e["x"] - p["x"]) < 0.01 and abs(e["y"] - p["y"]) < 0.01
                              for e in taps)
                if not has_tap:
                    out.append(dict(t=p["t"], x=p["x"], y=p["y"], fromX=prev["x"], fromY=prev["y"],
                                    stillMs=p["t"] - prev["t"]))
        prev = p
    return out


def align_own(trace, warp_walls, label):
    """wall = t + a, from UC landings matched to this Mac's own 'Warp Location' lines.
    Pass 1 uses unmistakable landings (>= 200 pt after >= 1 s frozen); pass 2 matches every
    Warp Location to the first freeze-then-move sample within 30 ms and refines `a`."""
    big = jumps(trace, 1000.0, 200.0)
    ests = []
    for L in big:
        w = min(warp_walls, key=lambda w: abs(w - (L["t"] + trace["start"] + 500)))
        if abs(w - (L["t"] + trace["start"] + 500)) < 700:
            ests.append(w - L["t"])
    a = st.median(ests)
    cands = jumps(trace, 90.0, 3.0)
    lands, ests = [], []
    lo, hi = a, a + trace["polls"][-1]["t"]
    for w in warp_walls:
        if not (lo <= w <= hi):
            continue
        near = [L for L in cands if -3 <= L["t"] + a - w <= 30]
        assert near, f"{label}: no landing sample for Warp Location {fmt_ms(w)}"
        L = min(near, key=lambda L: abs(L["t"] + a - w))
        lands.append(dict(L, warpWall=w))
        ests.append(w - L["t"])
    a = st.median(ests)
    print(f"{label}: trace start {fmt_ms(a)} (header {fmt_ms(trace['start'])}); "
          f"{len(ests)} landings, residuals {min(ests) - a:+.1f}..{max(ests) - a:+.1f} ms")
    return a, lands


def near_tap(taps, x, lo, hi, tol=0.02):
    c = [e for e in taps if lo <= e["t"] <= hi and abs(e["x"] - x) <= tol]
    return c[-1] if c else None


def main():
    vm, mb, s1 = parse_trace("s2-vmind.txt"), parse_trace("s2-macbook.txt"), parse_trace("s1-macbook-landtest.txt")
    v_ready, v_warp = parse_uclog("uc-log-vmind.txt")
    m_ready, m_warp = parse_uclog("uc-log-macbook.txt")

    # Inter-Mac wall clock offset (informational): symmetric-latency model over all log pairs.
    d1 = [min(m_warp, key=lambda w: abs(w - r["wall"])) - r["wall"] for r in v_ready]
    d2 = [min(v_warp, key=lambda w: abs(w - r["wall"])) - r["wall"] for r in m_ready]
    clock_mb_minus_vm = (st.median(d1) - st.median(d2)) / 2
    print(f"UC log pairs: V->M warp-minus-ready median {st.median(d1):+.1f} ms, M->V {st.median(d2):+.1f} ms "
          f"=> MacBook clock {clock_mb_minus_vm:+.2f} ms vs V-Mind, one-way ~{-(st.median(d1) + st.median(d2)) / 2:.2f} ms")

    a_v, v_lands = align_own(vm, v_warp, "s2 V-Mind ")
    a_m, m_lands = align_own(mb, m_warp, "s2 MacBook")
    a_1, s1_lands = align_own(s1, m_warp, "s1 MacBook")

    s2_lo, s2_hi = a_m, a_m + mb["polls"][-1]["t"]
    crossings, k_est = [], []

    def dest_landing(lands, a_dest, wall):
        L = min(lands, key=lambda L: abs(L["t"] + a_dest - wall))
        assert abs(L["t"] + a_dest - wall) < 40, (fmt_ms(wall), L)
        return L

    for r in v_ready + m_ready:
        if not (s2_lo <= r["wall"] <= s2_hi):
            continue
        up = r in v_ready
        src, a_src, dst_lands, a_dst = (vm, a_v, m_lands, a_m) if up else (mb, a_m, v_lands, a_v)
        ready_t_src = r["wall"] - a_src
        L = dest_landing(dst_lands, a_dst, r["wall"] + (clock_mb_minus_vm if up else -clock_mb_minus_vm))
        k_est.append(L["t"] - ready_t_src if up else ready_t_src - L["t"])
        e = dict(wall=fmt_ms(r["wall"]), edge=r["edge"], ucOffset=r["offset"], readySourceT=round(ready_t_src, 1),
                 activatingSourceT=round(r["activating"] - a_src, 1),
                 landingT=L["t"], landingX=L["x"], landingY=L["y"])
        if r["edge"] in ("top", "bottom"):
            if up:
                x = r["offset"] * 961 - 961                       # SPEC §2
            elif r["offset"] > 0 and r["offset"] < 1.5:
                x = r["offset"] * 961 - 2560                      # zone bottom:<5>:[-2560 -1 -1599 0]
            else:
                x = r["offset"]                                   # zone bottom:<4>: UC logs raw x
            tap = near_tap(src["taps"], x, ready_t_src - 120, ready_t_src + 5, tol=0.02)
            assert tap is not None, f"no source TAP at exit x {x:.2f} for {e['wall']}"
            assert tap["y"] == 0.0 if up else tap["y"] >= -0.03, tap
            before = [p for p in src["polls"] if p["t"] <= ready_t_src + 200]
            frozen = before[-1]
            e.update(direction="up" if up else "down", exitX=round(tap["x"], 2), exitT=tap["t"],
                     exitXFrozen=frozen["x"],
                     expectedTargetX=round(physical_map(tap["x"], VM_SPAN, MB_SPAN) if up
                                           else physical_map(tap["x"], MB_SPAN, VM_SPAN), 2))
        else:
            e.update(direction="side-up" if up else "side-down")
        crossings.append(e)

    k = st.median(k_est)
    print(f"k = t_macbook - t_vmind = {k:.1f} ms from {len(k_est)} crossings, spread "
          f"{min(k_est) - k:+.1f}..{max(k_est) - k:+.1f} ms  (header-only estimate {mb['start'] - vm['start']:+.0f})")

    # Name crossings and report the exit-event lead (how long before the landing UC's exit event came).
    n = dict(up=0, down=0, side=0)
    for c in sorted(crossings, key=lambda c: c["wall"]):
        kind = "side" if c["direction"].startswith("side") else c["direction"]
        n[kind] += 1
        c["id"] = {"up": "U", "down": "D", "side": "S"}[kind] + str(n[kind])
    crossings.sort(key=lambda c: c["wall"])
    print("\nid  dir        wall          exitX     frozenX   landing(dest)         landingT   expTarget  lead")
    for c in crossings:
        if "exitX" in c:
            lead = (c["landingT"] - (c["exitT"] + k)) if c["direction"] == "up" else ((c["landingT"] + k) - c["exitT"])
            c["exitLeadMs"] = round(lead, 1)
            assert 0 < lead < 40, f"{c['id']}: exit event should come just before the landing, lead {lead:.1f} ms"
            print(f"{c['id']:3} {c['direction']:9} {c['wall']}  {c['exitX']:8.2f}  {c['exitXFrozen']:8.2f}  "
                  f"({c['landingX']:8.2f},{c['landingY']:6.2f})  {c['landingT']:9.1f}  {c['expectedTargetX']:8.2f}  {lead:5.1f}")
        else:
            print(f"{c['id']:3} {c['direction']:9} {c['wall']}  {'':8}  {'':8}  ({c['landingX']:8.2f},{c['landingY']:6.2f})  {c['landingT']:9.1f}")

    # Every event-less jump in either s2 trace must be a logged crossing, and vice versa.
    for trace, dest in ((mb, "macbook"), (vm, "vmind")):
        for L in jumps(trace, 90.0, 3.0):
            ok = any(abs(c["landingT"] - L["t"]) < 0.05 for c in crossings)
            assert ok, f"unexplained {dest} jump {L}"
    assert len(crossings) == len(m_lands) + len(v_lands)

    # Dead-strip push: V-Mind TAP events pinned at y=0 in the dead part, dy into the edge.
    push = [e for e in vm["taps"] if e["y"] == 0.0 and e["x"] < -961 and 139000 <= e["t"] <= 146000]
    pinned_push = [e for i, e in enumerate(push) if e["dy"] < 0]
    dead = dict(startT=push[0]["t"], endT=push[-1]["t"], events=len(push), sumDy=sum(e["dy"] for e in push),
                minX=min(e["x"] for e in push), maxX=max(e["x"] for e in push),
                expectedRedirectX=-961 + 2, pushEventsDyNegative=len(pinned_push))
    # When does a 400 ms window of pinned pushes (prev event also pinned) first reach 24 pt?
    taps = vm["taps"]
    acc = []
    fire = None
    for i, e in enumerate(taps):
        prev_pinned = i > 0 and taps[i - 1]["y"] <= 0.5
        if e["y"] <= 0.5 and prev_pinned and e["dy"] < 0 and e["x"] < -961:
            acc.append((e["t"], -e["dy"]))
        acc = [(t, v) for t, v in acc if e["t"] - t <= 400]
        if fire is None and sum(v for _, v in acc) >= 24:
            fire = e["t"]
    dead["expectedFireT"] = fire
    print(f"\ndead-strip push: {dead}")

    # s1: MacBook-only; V-Mind exits from SPEC §2 at the V-Mind Target Ready times.
    spec_x = [-930.9, 1564.9, -33.5, 20.4, 785.2, 1553.1]
    s1_ups = [r for r in v_ready if r["edge"] == "top" and a_1 <= r["wall"] <= a_1 + s1["polls"][-1]["t"]]
    assert len(s1_ups) == 6
    s1_cross = []
    for r, sx in zip(s1_ups, spec_x):
        L = dest_landing(s1_lands, a_1, r["wall"] + clock_mb_minus_vm)
        ucx = r["offset"] * 961 - 961
        s1_cross.append(dict(wall=fmt_ms(r["wall"]), ucOffset=r["offset"], specExitX=sx, ucExitX=round(ucx, 2),
                             landingT=L["t"], landingX=L["x"], landingY=L["y"],
                             expectedTargetX=round(physical_map(sx, VM_SPAN, MB_SPAN), 2)))
        print(f"s1 up {fmt_ms(r['wall'])} spec x {sx:8.1f} uc x {ucx:8.2f} (diff {sx - ucx:+5.1f}) "
              f"-> landing t={L['t']:.1f} ({L['x']:.2f},{L['y']:.2f})")
    s1_other = [dict(t=L["t"], x=L["x"], y=L["y"]) for L in s1_lands
                if not any(abs(c["landingT"] - L["t"]) < 0.05 for c in s1_cross)]
    print(f"s1 other landings (side-link, V-Mind -> display 1): {s1_other}")
    print(f"s1 WARP lines at {s1['warps']}")

    out = dict(
        comment="Generated by groundtruth.py; see its docstring for the alignment method. Times are trace ms.",
        alignment=dict(vmindTraceStartWall=fmt_ms(a_v), macbookTraceStartWall=fmt_ms(a_m),
                       vmindToMacbookMs=round(k, 1), estimatedErrorMs=round(max(abs(x - k) for x in k_est), 1),
                       macbookClockMinusVMindMs=round(clock_mb_minus_vm, 2), s1MacbookTraceStartWall=fmt_ms(a_1)),
        crossings=crossings,
        deadStrip=dead,
        s1=dict(crossings=s1_cross, warpT=s1["warps"], otherJumps=s1_other),
    )
    with open(os.path.join(HERE, "s2-crossings.json"), "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")
    print("\nwrote s2-crossings.json")


if __name__ == "__main__":
    main()
