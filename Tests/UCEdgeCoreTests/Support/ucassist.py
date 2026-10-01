#!/usr/bin/env python3
"""Independent check of SPEC §13 "UC log assist":
crossX = x of the latest at-edge local tap event (-1 <= s <= 1.5) at or before UC's
"Hot Zone: Activating" line, within 100 ms before it.

Run: python3 -B Tests/UCEdgeCoreTests/Support/ucassist.py

s3 (testdata/s3-*-uclog.txt): TAP evts= and rx= are uptime ns; UCLOG mach= is continuous-domain
ticks (timebase 125/3). V-Mind had not slept, so its continuous - uptime offset is ~0 (its CLOCK line
agrees to ~1 us). The MacBook's offset (~12 711 s) was not recorded: it is derived from UC's
"Warp Location" lines against the poller's landing samples (POS), which follow the warp by < 1 ms.

s2: no event timestamps; UC log lines are wall ms, mapped to trace time with groundtruth.py's
per-Mac alignment (residuals within 4 ms).

UC's x for a crossing comes from its "Target Ready" offset: top (V-Mind) x = 961*offset - 961;
MacBook bottom:<5> zone x = 961*offset - 2560; bottom:<4> zone offset = raw x.
"""
import os
import re
import statistics as st
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import groundtruth as g  # noqa: E402

TICK_NS = 125 / 3
WINDOW_NS = 100e6
VM_DISPLAYS = ("8D000000-0000-4000-8000-0000000000B2", "E5000000-0000-4000-8000-0000000000B1")
MB_DISPLAYS = ("8A000000-0000-4000-8000-0000000000A1",)


def parse_s3(name):
    taps, pos, logs, clock = [], [], [], None
    for line in open(os.path.join(g.TD, name)):
        if line.startswith("TAP "):
            m = re.match(r"TAP rx=(\d+) evts=(\d+) t(\d+) \((-?[\d.]+),(-?[\d.]+)\) dx=(-?\d+) dy=(-?\d+)", line)
            taps.append(dict(rx=int(m[1]), ns=int(m[2]), type=int(m[3]), x=float(m[4]), y=float(m[5]),
                             dx=int(m[6]), dy=int(m[7])))
        elif line.startswith("POS "):
            m = re.match(r"POS ns=(\d+) \((-?[\d.]+),(-?[\d.]+)\)", line)
            pos.append(dict(ns=int(m[1]), x=float(m[2]), y=float(m[3])))
        elif line.startswith("UCLOG "):
            m = re.match(r"UCLOG rx=(\d+) mach=(\d+) ts=\S+ (\S+)-\d{4} msg=(.*)$", line)
            logs.append(dict(rx=int(m[1]), mach_ns=int(m[2]) * TICK_NS, wall=m[3], msg=m[4].strip()))
        elif line.startswith("CLOCK "):
            m = re.match(r"CLOCK mach=(\d+) uptime_ns=(\d+)", line)
            clock = int(m[1]) * TICK_NS - int(m[2])
    return taps, pos, logs, clock


ACT = re.compile(r"Hot Zone: Activating: (\w+):([0-9A-F]+):([0-9A-F-]+)")


def sdist(y, top):
    return y if top else -y


def match(taps, t, top, window=WINDOW_NS):
    """Latest at-edge event with timestamp <= t (same unit as taps' 'ns'), within `window`."""
    cand = [e for e in taps if e["ns"] <= t and t - e["ns"] <= window and -1 <= sdist(e["y"], top) <= 1.5]
    return cand[-1] if cand else None


def uc_x(offset, top, zone5=False):
    if top:
        return 961 * offset - 961
    return 961 * offset - 2560 if zone5 else offset


def report(label, taps, t_log, top, ucx, unit_ms):
    e = match(taps, t_log, top)
    nxt = next((x for x in taps if x["ns"] > t_log), None)
    prev_edge = [x for x in taps if x["ns"] < (e["ns"] if e else t_log) and -1 <= sdist(x["y"], top) <= 1.5]
    if e is None:
        print(f"  {label:28} NO MATCH (UC x {ucx:9.2f})")
        return None
    lead = (t_log - e["ns"]) / unit_ms
    after = (nxt["ns"] - t_log) / unit_ms if nxt else float("nan")
    before = (e["ns"] - prev_edge[-1]["ns"]) / unit_ms if prev_edge else float("nan")
    ok = abs(e["x"] - ucx) < 0.011
    print(f"  {label:28} matched x {e['x']:9.2f}  UC x {ucx:9.2f}  {'OK ' if ok else 'BAD'}  "
          f"event {lead:5.2f} ms before the log line; next event {after:6.2f} ms after; "
          f"previous at-edge event {before:6.2f} ms earlier")
    return e["x"] - ucx


def s3():
    print("s3 (event timestamps, ns)")
    taps, pos, logs, clock = parse_s3("s3-vmind-uclog.txt")
    print(f"  V-Mind CLOCK: continuous - uptime = {clock / 1e3:.1f} us (taken as 0)")
    lags = [(l["rx"] - l["mach_ns"]) / 1e6 for l in logs]
    print(f"  V-Mind log receive lag (rx - line time): {min(lags):.2f}..{max(lags):.2f} ms, median {st.median(lags):.2f}")
    ready = [l for l in logs if "Target Ready: edge=top" in l["msg"]]
    for a in [l for l in logs if l["msg"].startswith("Hot Zone: Activating: top:")]:
        assert ACT.match(a["msg"])[3] in MB_DISPLAYS
        r = next(x for x in ready if x["mach_ns"] > a["mach_ns"])
        off = float(re.search(r"offset=(-?[\d.]+)", r["msg"])[1])
        report(f"V-Mind up {a['wall']}", taps, a["mach_ns"], True, uc_x(off, True), 1e6)

    taps, pos, logs, _ = parse_s3("s3-macbook-uclog.txt")
    offs = []
    for w in [l for l in logs if l["msg"].startswith("Warp Location")]:
        # The landing: the poller's first jump (> 20 pt) near the moment the log line was received.
        near = [i for i, p in enumerate(pos) if abs(p["ns"] - w["rx"]) <= 10e6 and i > 0 and
                abs(p["x"] - pos[i - 1]["x"]) + abs(p["y"] - pos[i - 1]["y"]) > 20]
        offs.append(w["mach_ns"] - pos[near[0]]["ns"])
    off = st.median(offs)
    print(f"  MacBook continuous - uptime from {len(offs)} landings: {off / 1e9:.6f} s "
          f"(spread {min(offs) / 1e6 - off / 1e6:+.2f}..{max(offs) / 1e6 - off / 1e6:+.2f} ms; poll lag <= 1 ms)")
    lags = [(l["rx"] - (l["mach_ns"] - off)) / 1e6 for l in logs]
    print(f"  MacBook log receive lag with that offset: {min(lags):.2f}..{max(lags):.2f} ms")
    # A negative lag is impossible: the line can't be received before it is logged. The bound
    # offset >= max(line time - rx) + 0.24 ms (V-Mind's smallest lag) moves line times earlier.
    bound = max(l["mach_ns"] - l["rx"] for l in logs) + 0.24e6
    print(f"  lag-consistent offset: {bound / 1e9:.6f} s ({(bound - off) / 1e6:+.2f} ms); matching is checked with both")
    ready = [l for l in logs if "Target Ready: edge=bottom" in l["msg"]]
    for a in [l for l in logs if l["msg"].startswith("Hot Zone: Activating: bottom:")]:
        disp = ACT.match(a["msg"])[3]
        assert disp in VM_DISPLAYS
        r = next(x for x in ready if x["mach_ns"] > a["mach_ns"])
        o = float(re.search(r"offset=(-?[\d.]+)", r["msg"])[1])
        for name, o_ns in (("landings", off), ("lag bound", bound)):
            report(f"MacBook down {a['wall'][:12]} ({name})", taps, a["mach_ns"] - o_ns, False,
                   uc_x(o, False, disp == VM_DISPLAYS[0]), 1e6)
    for a in [l for l in logs if l["msg"].startswith("Hot Zone: Activating:") and ACT.match(l["msg"])[1] != "bottom"]:
        print(f"  (ignored, side link) {a['wall']} {a['msg'][:40]}")


def s2():
    print("\ns2 (UC log wall ms mapped to trace ms; alignment residuals <= 4 ms)")
    vm, mb = g.parse_trace("s2-vmind.txt"), g.parse_trace("s2-macbook.txt")
    vr, vw = g.parse_uclog("uc-log-vmind.txt")
    mr, mw = g.parse_uclog("uc-log-macbook.txt")
    a_v, _ = g.align_own(vm, vw, "  V-Mind ")
    a_m, _ = g.align_own(mb, mw, "  MacBook")
    for trace, a, logname, edge, top in ((vm, a_v, "uc-log-vmind.txt", "top", True),
                                         (mb, a_m, "uc-log-macbook.txt", "bottom", False)):
        lines = [(g.hms_ms(m[1]), re.sub(r"^\[[^\]]*\] ", "", m[2]))
                 for m in (g.LOGLINE.match(l) for l in open(os.path.join(g.TD, logname)))]
        taps = [dict(ns=e["t"], x=e["x"], y=e["y"]) for e in trace["taps"]]
        end = a + trace["polls"][-1]["t"]
        for i, (w, msg) in enumerate(lines):
            if not (a <= w <= end) or not msg.startswith(f"Hot Zone: Activating: {edge}:"):
                continue
            ready = next(m for _, m in lines[i:] if f"Target Ready: edge={edge}" in m)
            off = float(re.search(r"offset=(-?[\d.]+)", ready)[1])
            zone5 = "8D000000" in msg
            report(f"{'V-Mind up' if top else 'MacBook down'} {g.fmt_ms(w)}", taps, w - a, top, uc_x(off, top, zone5), 1.0)


def live_misses():
    print("\nlive-test misses (no tap data): UC's x from the offsets")
    for when, x in (("16:53:05.8", -1191.7), ("16:53:14.0", -1230.3)):
        print(f"  {when}: UC x {x} is left of UC's own zone (-961): sticky Entering, then Activating on a slide "
              f"617-784 ms later. The log assist takes the latest at-edge event before Activating, so it gets "
              f"this x if the slide stayed within 1.5 pt of the edge; the model latch cannot.")


if __name__ == "__main__":
    s3()
    s2()
    live_misses()
