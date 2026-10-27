#!/usr/bin/env python3
"""Summarise ~/Library/Logs/Retrace/ui-trace.jsonl (written by UI/Diagnostics when RetraceUIDiagnostics is on).

    scripts/analyze_ui_trace.py [trace.jsonl] [--log retrace.log] [--top N] [--window SECONDS]

Prints: session/frame-rate overview, worst hitches with symbolicated stacks, aggregated hot frames,
@Published / body-evaluation storms, hot background threads, and the trace around every MARK
(⌃⌥⌘M) merged with WARN/ERROR/[PERF] lines from retrace.log. Read this summary, not the raw file.
"""
import argparse
import collections
import datetime as dt
import json
import os
import re
import subprocess
import sys

HOME = os.path.expanduser("~")
DEFAULT_TRACE = f"{HOME}/Library/Logs/Retrace/ui-trace.jsonl"
DEFAULT_LOG = f"{HOME}/Library/Logs/Retrace/retrace.log"
APP_IMAGE = "Retrace"

# Frames that are plumbing, not an answer to "what was main doing".
NOISE = re.compile(
    r"^(libsystem|libdispatch|CoreFoundation|libswiftCore|libswift_Concurrency|libobjc|dyld|SwiftUICore|"
    r"AttributeGraph|libswiftDispatch|Foundation)\b"
)


def load(path):
    events = []
    with open(path, errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                pass  # truncated final line
    return events


def demangler(symbols):
    """Batch-demangle Swift symbols with swift-demangle; fall back to the raw names."""
    syms = sorted(symbols)
    if not syms:
        return {}
    try:
        out = subprocess.run(
            ["xcrun", "swift-demangle", "--simplified"],
            input="\n".join(syms), capture_output=True, text=True, timeout=60,
        ).stdout.split("\n")
        if len(out) >= len(syms):
            return dict(zip(syms, out))
    except Exception:
        pass
    return {s: s for s in syms}


FRAME_RE = re.compile(r"^(\S+) (.*?)(?:\+(\d+))?$")


def split_frame(frame):
    m = FRAME_RE.match(frame)
    if not m:
        return "?", frame
    image, sym = m.group(1), m.group(2)
    return image, sym


def pretty(frame, demangled):
    image, sym = split_frame(frame)
    name = demangled.get(sym, sym)
    name = re.sub(r"\s+", " ", name)
    if len(name) > 150:
        name = name[:147] + "..."
    return f"{image}: {name}"


def interesting_frames(frames, demangled, limit=6):
    """Innermost frames that say something: app frames first, otherwise first non-noise frames."""
    app = [f for f in frames if split_frame(f)[0] == APP_IMAGE]
    pool = app if app else [f for f in frames if not NOISE.match(f)]
    return [pretty(f, demangled) for f in pool[:limit]]


def fmt_t(ms):
    s = ms / 1000
    return f"{int(s // 60):02d}:{s % 60:05.2f}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace", nargs="?", default=DEFAULT_TRACE)
    ap.add_argument("--log", default=DEFAULT_LOG)
    ap.add_argument("--top", type=int, default=15)
    ap.add_argument("--window", type=float, default=2.0, help="seconds around each MARK")
    args = ap.parse_args()

    if not os.path.exists(args.trace):
        sys.exit(f"no trace at {args.trace} — enable with: scripts/retracectl.sh diag-on, then relaunch")
    ev = load(args.trace)
    sessions = [e for e in ev if e["k"] == "session"]
    if not sessions:
        sys.exit("trace has no session record")
    sess = sessions[-1]
    ev = [e for e in ev if e["t"] >= sess["t"]]
    by_kind = collections.defaultdict(list)
    for e in ev:
        by_kind[e["k"]].append(e)
    ticks, hitches, stacks = by_kind["tick"], by_kind["hitch"], by_kind["stack"]
    duration = max((e["t"] for e in ev), default=0)

    # Demangle every Swift symbol that appears in any stack, once.
    sym_re = re.compile(r"_?\$s[A-Za-z0-9_]+")
    all_syms = set()
    for e in stacks + by_kind["bgstack"] + by_kind["pubsrc"]:
        for f in e.get("frames", []):
            all_syms.update(sym_re.findall(f))
    dem = demangler(all_syms)

    print("=" * 78)
    print(f"UI TRACE  {args.trace}")
    print(f"app {sess.get('version')} ({sess.get('build')})  pid {sess.get('pid')}  {sess.get('os')}  "
          f"{sess.get('cores')} cores / {sess.get('ram_gb')} GB")
    print(f"duration {fmt_t(duration)}  events {len(ev)}  ticks {len(ticks)}  hitches {len(hitches)}  "
          f"stack samples {len(stacks)}  marks {len(by_kind['mark'])}")
    print("=" * 78)

    # ---- frame health ------------------------------------------------------------------
    if ticks:
        iters = sum(t.get("iters", 0) for t in ticks)
        over16 = sum(t.get("over16", 0) for t in ticks)
        hit_n = sum(t.get("hitches", 0) for t in ticks)
        busy = [t for t in ticks if t.get("iters", 0) > 0]
        print("\n## Frame health (main run-loop iterations)")
        print(f"iterations {iters}   >16.7ms: {over16} ({100 * over16 / max(iters, 1):.1f}%)   "
              f">=20ms hitches: {hit_n} ({100 * hit_n / max(iters, 1):.2f}%)")
        print(f"seconds with any hitch: {sum(1 for t in ticks if t.get('hitches'))}/{len(ticks)}   "
              f"worst iteration {max(t.get('iter_max', 0) for t in ticks):.0f}ms   "
              f"worst CA commit {max(t.get('commit_max', 0) for t in ticks):.0f}ms")
        print(f"process CPU: avg {sum(t['cpu'] for t in ticks) / len(ticks):.0f}%  peak {max(t['cpu'] for t in ticks):.0f}%   "
              f"main-thread CPU: avg {sum(t['main_cpu'] for t in ticks) / len(ticks):.0f}%  peak {max(t['main_cpu'] for t in ticks):.0f}%")
        print(f"memory footprint: start {ticks[0]['mb']}MB  peak {max(t['mb'] for t in ticks)}MB  end {ticks[-1]['mb']}MB   "
              f"threads: peak {max(t['threads'] for t in ticks)}")
        if busy:
            heavy = sorted(busy, key=lambda t: -t.get("iter_max", 0))[:3]
            print("worst seconds: " + "; ".join(f"{fmt_t(t['t'])} max {t['iter_max']:.0f}ms" for t in heavy))

    # ---- worst hitches -----------------------------------------------------------------
    stacks_by_iter = collections.defaultdict(list)
    for s in stacks:
        stacks_by_iter[s["iter"]].append(s)

    print(f"\n## Worst hitches (top {args.top} of {len(hitches)})")
    for h in sorted(hitches, key=lambda e: -e["ms"])[: args.top]:
        samples = stacks_by_iter.get(h["iter"], [])
        print(f"\n[{fmt_t(h['t'])}] {h['ms']:.0f}ms  src {h['src_ms']:.0f} / commit {h['commit_ms']:.0f} / post {h['post_ms']:.0f}"
              f"  mode={h.get('mode')} active={h.get('active')}")
        print(f"   trigger: {h.get('last_input', 'none within 2s')}   window: {h.get('key_window', '-')}")
        if not samples:
            print("   (no stack samples — iteration ended before the sampler fired)")
            continue
        # The sample that appears most often by its leading app frames is where main spent its time.
        sig_count = collections.Counter(tuple(interesting_frames(s["frames"], dem, 3)) for s in samples)
        for sig, n in sig_count.most_common(2):
            print(f"   {n}/{len(samples)} samples:")
            for line in sig:
                print(f"      {line}")

    # ---- aggregated hot frames ---------------------------------------------------------
    hitch_iters = {h["iter"]: h for h in hitches}
    hot_samples = [s for s in stacks if s["iter"] in hitch_iters]
    if hot_samples:
        incl = collections.Counter()
        leaf = collections.Counter()
        for s in hot_samples:
            seen = set()
            for f in s["frames"]:
                if split_frame(f)[0] == APP_IMAGE:
                    key = pretty(f, dem)
                    if key not in seen:
                        seen.add(key)
                        incl[key] += 1
            nonnoise = [f for f in s["frames"] if not NOISE.match(f)]
            if nonnoise:
                leaf[pretty(nonnoise[0], dem)] += 1
        total = len(hot_samples)
        print(f"\n## Where main spends hitch time ({total} samples, ~10ms apart)")
        print("-- inclusive: app frames present in the most samples")
        for k, n in incl.most_common(args.top):
            print(f"  {100 * n / total:5.1f}%  {k}")
        print("-- leaf: what main was literally executing")
        for k, n in leaf.most_common(10):
            print(f"  {100 * n / total:5.1f}%  {k}")

    # ---- hitch attribution ---------------------------------------------------------------
    if hitches:
        print("\n## Hitch attribution")
        phase = collections.Counter()
        for h in hitches:
            phase["commit (layout/SwiftUI body/draw)" if h["commit_ms"] > h["src_ms"] else "sources (handlers/timers/tasks)"] += h["ms"]
        tot = sum(phase.values())
        for k, v in phase.most_common():
            print(f"  {100 * v / tot:4.0f}% of hitch time in {k}")
        trig = collections.Counter()
        for h in hitches:
            li = h.get("last_input")
            trig[re.sub(r"\s*\(\d+ms ago\)", "", li) if li else "no recent input (background/timer/state-driven)"] += 1
        print("  by trigger:")
        for k, n in trig.most_common(8):
            print(f"    {n:4d}  {k}")

    # ---- storms ------------------------------------------------------------------------
    pub_peak, pub_total = collections.Counter(), collections.Counter()
    render_peak, render_total = collections.Counter(), collections.Counter()
    for t in ticks:
        for k, n in (t.get("pubs") or {}).items():
            pub_peak[k] = max(pub_peak[k], n)
            pub_total[k] += n
        for k, n in (t.get("renders") or {}).items():
            render_peak[k] = max(render_peak[k], n)
            render_total[k] += n
    if pub_total:
        print("\n## ObservableObject publishes (objectWillChange)")
        for k, n in pub_total.most_common():
            flag = "  <-- STORM" if pub_peak[k] >= 30 else ""
            print(f"  {k:24s} total {n:6d}  peak {pub_peak[k]:4d}/s{flag}")
        srcs = collections.defaultdict(collections.Counter)
        for e in by_kind["pubsrc"]:
            for f in e["frames"]:
                if "Retrace" in f and "Combine" not in f and "objectWillChange" not in f:
                    m = re.search(r"(\$s\S+)", f)
                    name = dem.get(m.group(1), m.group(1)) if m else f
                    srcs[e["vm"]][re.sub(r"\s+", " ", name)[:130]] += 1
                    break
        for vm, c in srcs.items():
            print(f"  top publishers for {vm}:")
            for name, n in c.most_common(6):
                print(f"     {n:4d}  {name}")
    if render_total:
        print("\n## SwiftUI body / updateNSView evaluations")
        for k, n in render_total.most_common():
            flag = "  <-- STORM" if render_peak[k] >= 30 else ""
            print(f"  {k:34s} total {n:6d}  peak {render_peak[k]:4d}/s{flag}")
    notif = collections.Counter()
    for t in ticks:
        for k, n in (t.get("notifs") or {}).items():
            notif[k] += n
    if notif:
        print("\n## Notification bursts (>=40/s seconds)")
        for k, n in notif.most_common(8):
            print(f"  {n:6d}  {k}")

    # ---- background CPU ------------------------------------------------------------------
    hot_threads = collections.Counter()
    for t in ticks:
        for th in t.get("hot_threads", []):
            hot_threads[th["name"]] += th["cpu"] / 100
    if hot_threads:
        print("\n## Busiest background threads (CPU-seconds in sampled seconds)")
        for k, v in hot_threads.most_common(6):
            print(f"  {v:6.1f}s  {k}")
    bg = collections.defaultdict(collections.Counter)
    for e in by_kind["bgstack"]:
        sig = " <- ".join(interesting_frames(e["frames"], dem, 3))
        bg[e["thread"]][sig] += 1
    for thread, c in list(bg.items())[:4]:
        print(f"  stacks for '{thread}':")
        for sig, n in c.most_common(3):
            print(f"     {n:3d}x {sig}")

    # ---- input latency ------------------------------------------------------------------
    inputs = by_kind["input"]
    lagged = [e for e in inputs if e.get("lag_ms", 0) >= 50]
    if inputs:
        print(f"\n## Input: {len(inputs)} events, {len(lagged)} delivered >=50ms late")
        for e in sorted(lagged, key=lambda e: -e["lag_ms"])[:6]:
            print(f"  [{fmt_t(e['t'])}] {e['type']} lag {e['lag_ms']:.0f}ms view={e.get('view', '-')} window={e.get('window', '-')}")

    # ---- marks --------------------------------------------------------------------------
    log_lines = read_log(args.log, sess["wall0"], sess["wall0"] + duration / 1000 + 5)
    marks = by_kind["mark"]
    if marks:
        print(f"\n## MARKS ({len(marks)}) — ±{args.window:.0f}s around each")
    for i, m in enumerate(marks, 1):
        lo, hi = m["t"] - args.window * 1000, m["t"] + args.window * 1000
        print(f"\n--- MARK {i} at {fmt_t(m['t'])}  note={m.get('note')!r}  last_input={m.get('last_input')}")
        for w in m.get("windows", []):
            if w["visible"]:
                print(f"    window: {w['class']} \"{w['title']}\" key={w['key']} occluded={w['occluded']} level={w['level']} {w['frame']}")
        for e in ev:
            if not (lo <= e["t"] <= hi) or e["k"] in ("stack", "pubsrc", "bgstack", "mark", "session"):
                continue
            rel = (e["t"] - m["t"]) / 1000
            k = e["k"]
            if k == "tick":
                if e.get("hitches") or e.get("pubs") or e.get("hot_threads"):
                    print(f"  {rel:+6.2f}s tick cpu={e['cpu']:.0f}% main={e['main_cpu']:.0f}% iter_max={e['iter_max']:.0f}ms "
                          f"hitches={e['hitches']} pubs={e.get('pubs', {})} renders={e.get('renders', {})}")
            elif k == "hitch":
                samples = stacks_by_iter.get(e["iter"], [])
                top = interesting_frames(samples[len(samples) // 2]["frames"], dem, 2) if samples else []
                print(f"  {rel:+6.2f}s HITCH {e['ms']:.0f}ms (src {e['src_ms']:.0f}/commit {e['commit_ms']:.0f})  {' <- '.join(top)}")
            elif k == "input":
                print(f"  {rel:+6.2f}s input {e['type']} view={e.get('view', '-')} lag={e.get('lag_ms', 0):.0f}ms")
            elif k == "note":
                print(f"  {rel:+6.2f}s note {e['name']} {e.get('window', e.get('app', ''))}")
            else:
                print(f"  {rel:+6.2f}s {k} {json.dumps({a: b for a, b in e.items() if a not in ('k', 't', 'w')})[:160]}")
        w_lo, w_hi = sess["wall0"] + lo / 1000, sess["wall0"] + hi / 1000
        for ts, line in log_lines:
            if w_lo <= ts <= w_hi:
                print(f"  {ts - (sess['wall0'] + m['t'] / 1000):+6.2f}s LOG {line[:200]}")

    # ---- app log problems over the whole session ----------------------------------------
    if log_lines:
        counts = collections.Counter()
        samples = {}
        for ts, line in log_lines:
            key = re.sub(r"\d+(\.\d+)?", "N", line.split(" - ", 1)[-1])[:110]
            counts[key] += 1
            samples.setdefault(key, line)
        print(f"\n## retrace.log WARN/ERROR/[PERF] during session ({len(log_lines)} lines, {len(counts)} distinct)")
        for key, n in counts.most_common(15):
            print(f"  {n:4d}x {samples[key][:190]}")
    print()


LOG_TS = re.compile(r"^\[(\d{4}-\d\d-\d\dT[\d:.]+Z)\] \[([^\]]+)\]")


def read_log(path, wall_lo, wall_hi):
    out = []
    if not os.path.exists(path):
        return out
    with open(path, errors="replace") as fh:
        for line in fh:
            m = LOG_TS.match(line)
            if not m:
                continue
            level = m.group(2)
            if not (any(k in level for k in ("WARN", "ERROR", "CRITICAL")) or "[PERF]" in line):
                continue
            try:
                ts = dt.datetime.fromisoformat(m.group(1).replace("Z", "+00:00")).timestamp()
            except ValueError:
                continue
            if wall_lo <= ts <= wall_hi:
                out.append((ts, line.rstrip()))
    return out


if __name__ == "__main__":
    main()
