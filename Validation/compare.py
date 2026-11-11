#!/usr/bin/env python3
"""Cross-check Lutherie against ngspice.

  1. SPICE_DIR=out swift run -c release PedalCheck     (writes a deck and Lutherie's output per starter circuit)
  2. python3 Validation/compare.py out                 (runs ngspice on each deck and compares)

ngspice must be on the PATH, or name it with NGSPICE=/path/to/ngspice.
Both simulate the same circuit with the same device equations and a 220 Hz, 0.3 V sine. The figure
reported is the difference between the two outputs relative to the signal, over the last 100 ms.
"""
import math, os, subprocess, sys

def load(path):
    t, v = [], []
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) >= 2:
                try: t.append(float(p[0])); v.append(float(p[1]))
                except ValueError: pass
    return t, v

def resample(ts, vs, at):
    out, j = [], 0
    for x in at:
        while j + 1 < len(ts) - 1 and ts[j + 1] < x: j += 1
        t0, t1 = ts[j], ts[j + 1]
        w = 0 if t1 == t0 else min(max((x - t0) / (t1 - t0), 0), 1)
        out.append(vs[j] + w * (vs[j + 1] - vs[j]))
    return out

def main():
    d = sys.argv[1] if len(sys.argv) > 1 else "."
    ng = os.environ.get("NGSPICE", "ngspice")
    limit = float(os.environ.get("LIMIT_DB", "-40"))
    rows, failed = [], 0
    for line in open(os.path.join(d, "index.txt")):
        slug, name = line.rstrip("\n").split("\t")
        try:
            r = subprocess.run([ng, "-b", slug + ".cir"], cwd=d, capture_output=True, text=True, timeout=1800)
        except FileNotFoundError:
            sys.exit("ngspice not found: install it or set NGSPICE=/path/to/ngspice")
        ref = os.path.join(d, slug + ".ngspice.txt")
        if not os.path.exists(ref):
            rows.append((name, "ngspice produced no output: " + (r.stderr.strip().splitlines() or ["?"])[-1])); failed += 1; continue
        lt, lv = load(os.path.join(d, slug + ".lutherie.txt"))
        nt, nv = load(ref)
        start = lt[-1] - 0.1
        keep = [i for i, t in enumerate(lt) if t >= start]
        a = [lv[i] for i in keep]
        b = resample(nt, nv, [lt[i] for i in keep])
        mean = sum(b) / len(b)
        sig = math.sqrt(sum((x - mean) ** 2 for x in b) / len(b))
        err = math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)) / len(a))
        worst = max(abs(x - y) for x, y in zip(a, b))
        db = 20 * math.log10(max(err, 1e-15) / max(sig, 1e-15))
        ok = db <= limit
        failed += 0 if ok else 1
        rows.append((name, "%s  difference %6.1f dB  (signal %.4g V rms, worst %.3g V, DC %.4g V vs %.4g V)"
                     % ("ok  " if ok else "FAIL", db, sig, worst, sum(a) / len(a), mean)))
    for name, text in rows: print("%-28s %s" % (name, text))
    print("ALL WITHIN %g dB" % limit if failed == 0 else "%d OUTSIDE %g dB" % (failed, limit))
    sys.exit(1 if failed else 0)

if __name__ == "__main__":
    main()
