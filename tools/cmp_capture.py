#!/usr/bin/env python3
"""Compare two PHX_DEBUG_DUMP captures, refusing the comparison if the frames
are not actually comparable.

The point is the gate, not the metrics. Captures taken without
`PHX_FIXED_DT` + `PHX_FIXED_VIEW` + `PHX_FIXED_SIZE` have, repeatedly, turned
out to be non-comparable for reasons that were invisible at the time:

  * the chase camera drifted between runs (docs/ltheory-planets.md 11.3, W5's dt trap),
  * the window was resized by the compositor, so the dumps came out at
    936x969 / 1691x1232 / 1891x969 while both runs logged
    `Resolution: 1280x720` (the boot-time print is a one-shot that goes stale),
  * a settings override silently did not apply, producing two byte-identical
    "disabled" variants.

So this reads the `[DUMP] frame=... render=WxH camera=(x,y,z) harness=... dt=...`
header each run prints, and refuses to compare unless size, camera pose, dt
pinning and harness state all agree. It also warns loudly when two supposedly
different variants come out identical, which is the signature of an override that
never landed.

Usage:
    cmp_capture.py <a.png> <b.png> [a.log] [b.log]

Logs default to run.<tag>.log next to the PNG. Exit status is 1 if the
comparison is invalid, 2 if the two frames are byte-identical (suspicious for an
A/B), 0 otherwise.
"""
import os
import re
import sys

HEADER = re.compile(
    r"\[DUMP\] frame=(\d+) render=(\d+)x(\d+) camera=\(([-\d.]+),([-\d.]+),([-\d.]+)\)"
    r" harness=(\w+) dt=(\S+)")


def header_from_log(path):
    """Last [DUMP] header in the log: the render size is only final then."""
    if not path or not os.path.exists(path):
        return None
    last = None
    with open(path, errors="replace") as fh:
        for line in fh:
            m = HEADER.search(line)
            if m:
                last = m
    return last


def field(m, i):
    return m.group(i)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    a_png, b_png = sys.argv[1], sys.argv[2]

    def log_for(png):
        if len(sys.argv) > 4:
            return None
        tag = os.path.splitext(os.path.basename(png))[0]
        for stem in (tag.replace("shot.", ""), tag):
            cand = "/tmp/opencode/run.%s.log" % stem
            if os.path.exists(cand):
                return cand
        return None

    a_log = sys.argv[3] if len(sys.argv) > 3 else log_for(a_png)
    b_log = sys.argv[4] if len(sys.argv) > 4 else log_for(b_png)

    ha, hb = header_from_log(a_log), header_from_log(b_log)

    print("A: %s" % a_png)
    print("   %s" % (a_log or "(no log)"))
    print("B: %s" % b_png)
    print("   %s" % (b_log or "(no log)"))
    print()

    if ha is None or hb is None:
        print("!! No [DUMP] header found -- cannot verify comparability.")
        print("   Re-run with PHX_REPORT_SIZE=1 (and the harness) so the")
        print("   captures are self-describing.")
        return 1

    problems = []

    if (field(ha, 2), field(ha, 3)) != (field(hb, 2), field(hb, 3)):
        problems.append("render size differs: %sx%s vs %sx%s -- the dumps are not "
                        "the same shape, so a pixel diff is meaningless"
                        % (field(ha, 2), field(ha, 3), field(hb, 2), field(hb, 3)))
    if field(ha, 7) != field(hb, 7):
        problems.append("harness state differs: %s vs %s" % (field(ha, 7), field(hb, 7)))
    if field(ha, 8) != field(hb, 8):
        problems.append("dt pinning differs: %s vs %s" % (field(ha, 8), field(hb, 8)))
    if field(ha, 1) != field(hb, 1):
        problems.append("dump frame differs: %s vs %s" % (field(ha, 1), field(hb, 1)))

    # Camera pose to 1 unit: the header prints it rounded, which is well inside
    # the drift that used to invalidate comparisons, and outside float noise.
    ca = tuple(float(field(ha, i)) for i in (4, 5, 6))
    cb = tuple(float(field(hb, i)) for i in (4, 5, 6))
    if any(abs(x - y) > 1.0 for x, y in zip(ca, cb)):
        problems.append("camera pose differs: %s vs %s -- the chase camera moved"
                        % (ca, cb))
    elif any(abs(x - y) > 0.0 for x, y in zip(ca, cb)):
        print("note: camera pose agrees to <1 unit but not exactly (%s vs %s)"
              % (ca, cb))

    unpinned = field(ha, 7) == "live"
    if unpinned:
        problems.append("harness=live -- the chase camera is not pinned, so this "
                        "comparison is only valid if the drift did not matter")

    if problems:
        print("!! COMPARISON INVALID")
        for p in problems:
            print("   - %s" % p)
        return 1

    print("comparability: OK (frame %s, %sx%s, harness=%s, dt=%s, camera pinned)"
          % (field(ha, 1), field(ha, 2), field(ha, 3), field(ha, 7), field(ha, 8)))
    print()

    try:
        sys.path.insert(0, "/tmp/opencode")
        from pngdiff import read_png
    except ImportError:
        print("(pngdiff unavailable; skipping pixel metrics)")
        return 0

    wa, ha_, fa = read_png(a_png)
    wb, hb_, fb = read_png(b_png)
    if (wa, ha_) != (wb, hb_):
        print("!! PNG dimensions differ (%dx%d vs %dx%d) despite matching headers"
              % (wa, ha_, wb, hb_))
        return 1

    tot = n = 0
    mx = 0
    sat = 0
    for y in range(0, ha_, 2):
        row = y * wa * 4
        for x in range(0, wa, 2):
            i = row + x * 4
            d = abs(fa[i] - fb[i]) + abs(fa[i + 1] - fb[i + 1]) + abs(fa[i + 2] - fb[i + 2])
            tot += d
            n += 1
            mx = max(mx, d)
            if d > 30:
                sat += 1

    if mx == 0:
        print("!! The two frames are IDENTICAL. For an A/B that is the signature of")
        print("   an override that never applied -- check PHX_SETTINGS=1 output.")
        return 2

    print("delta: mean %.2f/765, max %d/765, pixels differing >30: %.3f%%"
          % (tot / n, mx, 100.0 * sat / n))
    return 0


if __name__ == "__main__":
    sys.exit(main())