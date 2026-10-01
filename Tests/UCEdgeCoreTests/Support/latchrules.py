#!/usr/bin/env python3
"""Which x should the sender latch as "the x UC crossed at"? Evaluates candidate rules on s2.

Run: python3 -B Tests/UCEdgeCoreTests/Support/latchrules.py   (after groundtruth.py)

UC's own behaviour, from the Hot Zone log lines aligned to the source traces (see timeline()):
  "Entering"   is logged 1-7 ms after the first event inside UC's 1 pt hot zone (d < 1).
  "Activating" is logged 1-5 ms after the next event whose delta points into the edge, and
               UC's exit x (its logged offset) is exactly that event's x. Events that move away
               in between do not reset it (U4), and it even fires far outside the zone (S3).

Rules (d = distance to the edge on the source, "push" = event delta points into the edge):
  a  latest x (SPEC v1)
  b  x of the first event with d <= 0.5 at or after episodeStart + 12 ms (episode: consecutive
     d <= 0.5 events, gaps <= 100 ms)
  c  x of the first pinned push (d <= 0.5, previous event d <= 0.5, push); before that latest x
  d  UC model: arm on an event with -1 <= s < 1 while not armed; latch x at the next push event.
     Reset (unarmed, unlatched) when s > 30, s < -1, more than 100 ms since the previous event,
     or 150 ms after the latch was set (tails end <= 100 ms after UC's exit event).
  d+ = d, and arming also needs x inside UC's zone (V-Mind [-961, 1600]).
  dA = d+, but the receiver also accepts at-edge packets that are not latched yet (live x).
For b/c/d/d+ the receiver only uses latched packets ("not latched" counts as not at edge).
s is the signed distance (positive inside the edge displays); packets need x in span +- 1.
"""
import json
import os
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import groundtruth as g  # noqa: E402

VM_ZONE = (-961.0, 1600.0)


def sdist(e, top):
    return e["y"] if top else -e["y"]


def dist(e, top):
    return max(0.0, sdist(e, top))


def push(e, top):
    return e["dy"] < 0 if top else e["dy"] > 0


def annotate(taps, top, rule, zone=None):
    """Returns [(event, crossX or None)] with the latch state after each event."""
    out, armed, latch, latch_t, prev = [], False, None, None, None
    ep_start, ep_prev_t = None, None
    for e in taps:
        d = dist(e, top)
        gap = prev is None or e["t"] - prev["t"] > 100
        if rule == "a":
            latch = e["x"]
        elif rule == "b":
            if d <= 0.5:
                if ep_start is None or gap or dist(prev, top) > 0.5:
                    ep_start, latch = e["t"], None
                if latch is None and e["t"] >= ep_start + 12:
                    latch = e["x"]
            else:
                ep_start, latch = None, None
        elif rule == "c":
            if d > 0.5 or gap:
                latch = None
            elif latch is None and prev is not None and not gap and dist(prev, top) <= 0.5 and push(e, top):
                latch = e["x"]
        else:  # d, d+
            s = sdist(e, top)
            if gap or s > 30 or s < -1 or (latch is not None and e["t"] - latch_t > 150):
                armed, latch = False, None
            if latch is None:
                in_zone = zone is None or zone[0] <= e["x"] <= zone[1]
                if armed and push(e, top):
                    latch, latch_t = e["x"], e["t"]
                elif not armed and -1 <= s < 1 and in_zone:
                    armed = True
        out.append((e, latch))
        prev = e
    return out


def packets(ann, top, span, shift, delay, rule):
    pk, last = [], -1e9
    for e, latch in ann:
        d = dist(e, top)
        if d > 150 or e["x"] < span[0] - 1 or e["x"] > span[1] + 1:
            continue
        if d > 1.5 and e["t"] - last < 4:
            continue
        at_edge = -1 <= sdist(e, top) <= 1.5 and (rule in ("a", "dA") or latch is not None)
        pk.append(dict(arrive=e["t"] + shift + delay, x=latch if latch is not None else e["x"], at_edge=at_edge))
        last = e["t"]
    return pk


def receiver_x(pk, landing_t):
    before = [p for p in pk if p["arrive"] <= landing_t]
    if before and landing_t - before[-1]["arrive"] <= 300 and before[-1]["at_edge"]:
        return before[-1]["x"], "i"
    late = [p for p in pk if landing_t < p["arrive"] <= landing_t + 150 and p["at_edge"]]
    return (late[0]["x"], "l") if late else (None, "-")


def main():
    gt = json.load(open(os.path.join(HERE, "s2-crossings.json")))
    k = gt["alignment"]["vmindToMacbookMs"]
    vm, mb = g.parse_trace("s2-vmind.txt"), g.parse_trace("s2-macbook.txt")
    VS, MS = (-1600.0, 1600.0), (-2560.0, 0.0)
    rules = ["a", "b", "c", "d", "d+", "dA"]
    delays = [0, 2, 5, 10, 20, 30, 40]
    cross = [c for c in gt["crossings"] if c["direction"] in ("up", "down")]

    print("Receiver target error (destination pt) vs physicalMap(UC exit x); i=immediate l=late")
    print("id   " + "  ".join(f"{r:>3}: " + " ".join(f"{d:>2}" for d in delays) for r in rules))
    worst = {r: 0.0 for r in rules}
    for c in cross:
        up = c["direction"] == "up"
        taps, span = (vm["taps"], VS) if up else (mb["taps"], MS)
        cells = []
        for r in rules:
            ann = annotate(taps, up, r[0], VM_ZONE if (r in ("d+", "dA") and up) else None)
            row = []
            for delay in delays:
                pk = packets(ann, up, span, k if up else -k, delay, r)
                x, kind = receiver_x(pk, c["landingT"])
                if x is None:
                    row.append("  miss")
                    worst[r] = float("inf")
                    continue
                err = (g.physical_map(x, VS, MS) if up else g.physical_map(x, MS, VS)) - c["expectedTargetX"]
                worst[r] = max(worst[r], abs(err))
                row.append(f"{kind}{err:+5.0f}")
            cells.append(f"{r:>3}:" + "".join(f"{s:>6}" for s in row))
        print(f"{c['id']:4} " + " | ".join(cells))
    print("worst |error|: " + ", ".join(f"{r}={worst[r]:.0f}" for r in rules))

    print("\nLatched x per crossing: at UC's exit event, and over the tail (150 ms)")
    for c in cross:
        up = c["direction"] == "up"
        taps = vm["taps"] if up else mb["taps"]
        for r in ["b", "c", "d", "d+"]:
            ann = annotate(taps, up, r[0], VM_ZONE if (r == "d+" and up) else None)
            at_exit = next(l for e, l in ann if abs(e["t"] - c["exitT"]) < 0.05)
            tail = [l for e, l in ann if c["exitT"] < e["t"] <= c["exitT"] + 150 and dist(e, up) <= 1.5]
            tail_end = max([e["t"] for e, l in ann if c["exitT"] <= e["t"] <= c["exitT"] + 400 and dist(e, up) <= 1.5])
            stable = all(l is not None and abs(l - at_exit) < 0.01 for l in tail) if at_exit is not None else False
            vals = sorted({round(l, 2) for l in tail if l is not None})
            print(f"  {c['id']} {r:>2}: at exit {at_exit!s:>9} (UC {c['exitX']:8.2f})  tail(+{tail_end - c['exitT']:.0f} ms) {vals}  "
                  f"{'stable' if stable else 'UNSTABLE/WRONG' if at_exit != c['exitX'] or not stable else ''}")

    print("\nAt-edge episodes (d <= 1.5) that did not cross, and what each rule latches there")
    for name, taps, top in (("V-Mind", vm["taps"], True), ("MacBook", mb["taps"], False)):
        exits = [c["exitT"] for c in cross if (c["direction"] == "up") == top]
        eps, cur = [], []
        for e in taps:
            span = (-1600.0, 1600.0) if top else (-2560.0, 0.0)
            edge = -1 <= sdist(e, top) <= 1.5 and span[0] - 1 <= e["x"] <= span[1] + 1
            if edge and (not cur or e["t"] - cur[-1]["t"] <= 100):
                cur.append(e)
            else:
                if cur:
                    eps.append(cur)
                cur = [e] if edge else []
        if cur:
            eps.append(cur)
        for ep in eps:
            if any(ep[0]["t"] - 120 <= x <= ep[-1]["t"] + 5 for x in exits):
                continue
            lat = {}
            for r in ["b", "c", "d", "d+"]:
                ann = dict((id(e), l) for e, l in annotate(taps, top, r[0], VM_ZONE if (r == "d+" and top) else None))
                ls = [ann[id(e)] for e in ep if ann[id(e)] is not None]
                lat[r] = f"{ls[0]:.1f}" if ls else "-"
            xs = [e["x"] for e in ep]
            print(f"  {name:7} t {ep[0]['t']:9.1f}..{ep[-1]['t']:9.1f} n={len(ep):3} x {min(xs):8.1f}..{max(xs):8.1f}  "
                  + "  ".join(f"{r}:{v}" for r, v in lat.items()))


if __name__ == "__main__":
    main()
