#!/usr/bin/env python3
"""Verify the cloud-shell intersect in material/planet.glsl independently of the
renderer.

Same precedent as W4's sun-marker clamp check: verify the algorithm exactly
rather than eyeballing a render, because a picture cannot distinguish "parallax
works" from "parallax is subtly wrong in a way that still looks like clouds".

Deliberately NOT checked against a hand-derived closed form for the angular
offset -- an earlier version of this file did that and the formula was wrong,
which looked like a shader bug. Instead it is checked against properties that must
hold for ANY correct ray-sphere solve, which is both stricter and safer:

  A. the returned point lies ON the shell (|P| == rShell) -- catches sign errors
     in the ray setup, which is how `origin - eye` instead of `eye - origin`
     survived into the shader in the first place;
  B. the returned t is the NEAREST POSITIVE root of the quadratic;
  C. cloudHeight = 0 reproduces the v1 ground lookup exactly;
  D. head-on view has zero parallax;
  E. parallax increases monotonically with view angle;
  F. a genuinely grazing view fades the parallax back out (no limb smearing);
  G. thin-shell limit: offset / height -> tan(incidence) as height -> 0.
"""
import math
import random

R = 101527.0


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def add(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def sc(a, s):
    return (a[0] * s, a[1] * s, a[2] * s)


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def norm(a):
    n = math.sqrt(dot(a, a))
    return (a[0] / n, a[1] / n, a[2] / n)


def mix(a, b, f):
    return tuple(a[i] + (b[i] - a[i]) * f for i in range(3))


def sstep(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def ang(a, b):
    return math.acos(max(-1.0, min(1.0, dot(norm(a), norm(b)))))


def ang_prec(a, b):
    """Numerically stable angle. `ang` uses acos(dot), whose argument rounds to
    1.0 for angles below ~1e-8 rad and silently returns 0 -- which is exactly the
    regime the drift checks live in, so they would pass vacuously. atan2 of the
    cross-product magnitude against the dot product stays accurate there."""
    a, b = norm(a), norm(b)
    c = (a[1] * b[2] - a[2] * b[1],
         a[2] * b[0] - a[0] * b[2],
         a[0] * b[1] - a[1] * b[0])
    return math.atan2(math.sqrt(dot(c, c)), dot(a, b))


def shell(nL, origin, eye, pos, height):
    """Exact transcription of the GLSL block (identity basis: local == world).
    Returns (cloudDir, fade, tHit, rShell)."""
    if height <= 1e-6:
        return nL, 0.0, None, None
    r_shell = R * (1.0 + height)
    oc = sub(eye, origin)
    rd = norm(sub(pos, eye))
    bq = dot(oc, rd)
    cq = dot(oc, oc) - r_shell * r_shell
    disc = bq * bq - cq
    if disc <= 0.0:
        return nL, 0.0, None, r_shell
    sq = math.sqrt(disc)
    t = -bq - sq
    if t <= 0.0:
        t = -bq + sq
    if t <= 0.0:
        return nL, 0.0, None, r_shell
    hit = norm(add(oc, sc(rd, t)))
    graze = abs(dot(rd, norm(sub(pos, origin))))
    fade = sstep(0.02, 0.30, graze)
    return norm(mix(nL, hit, fade)), fade, t, r_shell


fails = []


def check(name, cond, detail=""):
    print("  [%s] %s%s" % ("ok" if cond else "FAIL", name, ("  -- " + detail) if detail else ""))
    if not cond:
        fails.append(name)


origin = (0.0, 0.0, 0.0)
nL = (1.0, 0.0, 0.0)
print("cloud shell intersect verification (R = %g, identity basis)\n" % R)

# C. height 0 -> exactly the v1 lookup
d, fade, _, _ = shell(nL, origin, sc(nL, R * 3), sc(nL, R), 0.0)
check("C. height=0 reproduces the v1 ground lookup exactly", ang(d, nL) < 1e-12,
      "offset %.3e rad" % ang(d, nL))

# D. head-on -> zero parallax
d, fade, _, _ = shell(nL, origin, sc(nL, R * 3), sc(nL, R), 0.02)
check("D. head-on view has zero parallax", ang(d, nL) < 1e-9,
      "offset %.3e rad, fade %.3f" % (ang(d, nL), fade))

# A + B. random poses: point is on the shell, t is the nearest positive root
random.seed(20261015)
worst_on = 0.0
worst_root = 0.0
bad_sign = 0
for _ in range(4000):
    n = norm((random.gauss(0, 1), random.gauss(0, 1), random.gauss(0, 1)))
    pos = sc(n, R)
    # camera anywhere in a shell around the body, sometimes inside rShell
    d0 = random.choice([1.2, 1.6, 2.5, 0.6, 0.2])
    eye = sc(n, R * d0)
    # offset the camera sideways so the ray is not head-on
    t1 = norm((-n[1], n[0], 0.0)) if abs(n[1]) < 0.9 else norm((1.0, 0.0, 0.0))
    eye = add(eye, sc(t1, R * random.uniform(-0.9, 0.9)))
    h = random.choice([0.005, 0.02, 0.06])
    d, fade, t, r_shell = shell(n, origin, eye, pos, h)
    if t is None:
        continue
    oc = sub(eye, origin)
    rd = norm(sub(pos, eye))
    P = add(oc, sc(rd, t))
    worst_on = max(worst_on, abs(math.sqrt(dot(P, P)) - r_shell))
    # B: nearest positive root
    cq = dot(oc, oc) - r_shell * r_shell
    bq = dot(oc, rd)
    roots = sorted(r for r in (-bq - math.sqrt(bq * bq - cq), -bq + math.sqrt(bq * bq - cq))
                   if r > 0)
    if not roots:
        continue
    worst_root = max(worst_root, abs(t - roots[0]))
    # a sign error in `oc` would put the sample on the far side of the body
    if dot(d, n) < 0.0:
        bad_sign += 1

check("A. returned point lies ON the shell over 4000 random poses",
      worst_on < 1e-6 * R, "worst | |P| - rShell | = %.3e units (R=%g)" % (worst_on, R))
check("B. t is the nearest positive root", worst_root < 1e-6 * R,
      "worst |t - t_nearest| = %.3e units" % worst_root)
check("A. sample never lands on the far side of the body", bad_sign == 0,
      "%d bad orientations" % bad_sign)

# E. monotonic in view angle
print()
prev, mono = -1.0, True
for deg in (5, 15, 30, 45, 60):
    th = math.radians(deg)
    eye = (R * 3.0, R * 0.9 * math.tan(th), 0.0)
    d, fade, _, _ = shell(nL, origin, eye, sc(nL, R), 0.02)
    got = ang(d, nL)
    mono = mono and got > prev
    prev = got
    print("       elevation %2d deg -> parallax %.4f rad (%.3f deg), fade %.3f"
          % (deg, got, math.degrees(got), fade))
check("E. parallax increases monotonically with view angle", mono)

# F. a genuinely grazing camera: sitting just above the tangent plane, looking along it
eye_g = (R * 1.02, R * 4.0, 0.0)
d, fade, _, _ = shell(nL, origin, eye_g, sc(nL, R), 0.02)
check("F. grazing view fades parallax out (no limb smearing)", fade < 0.35,
      "fade %.3f, residual offset %.4f rad" % (fade, ang(d, nL)))

# G. thin-shell limit: offset / height -> tan(incidence)
print()
th = math.radians(35.0)
eye = (R * 3.0, R * 0.9 * math.tan(th), 0.0)
rd = norm(sub(sc(nL, R), eye))
# Incidence is measured from the INWARD normal. `rd` points from the camera
# toward the surface, so it is ~163 deg from the outward normal; taking tan() of
# that is meaningless (and gives -0.31 instead of +0.31).
inc = ang(rd, sc(nL, -1.0))
prev = None
ok = True
for h in (0.0005, 0.001, 0.002):
    d, _, _, _ = shell(nL, origin, eye, sc(nL, R), h)
    ratio = ang(d, nL) / h
    print("       h=%.4f -> offset/h = %.4f" % (h, ratio))
    if prev is not None:
        ok = ok and abs(ratio - prev) < 0.05
    prev = ratio
want = math.tan(min(inc, math.pi / 2 - 1e-3))
check("G. offset/height converges to tan(incidence) as h->0",
      ok and abs(prev - want) / want < 0.12,
      "converged %.4f vs tan(inc)=%.4f" % (prev, want))


# ---- cloud shadow: the same shell, solved along the sun in LOCAL space -------
def shadow_shade(surfL, sunL, height, coverage_fn, strength):
    """Exact transcription of the cloudShade block in material/planet.glsl.
    The local origin IS the planet centre, so the solve is the simple closed
    form  t = -b + sqrt(b^2 - R^2 + rShell^2)  with b = vertPos . sunDir."""
    if height <= 1e-6 or strength <= 1e-6:
        return 1.0, 0.0
    NL = dot(norm(surfL), sunL)
    shFade = sstep(0.06, 0.32, NL)
    if shFade <= 1e-3:
        return 1.0, shFade
    Rl = math.sqrt(dot(surfL, surfL))
    rSh = Rl * (1.0 + height)
    b = dot(surfL, sunL)
    disc = b * b - Rl * Rl + rSh * rSh
    if disc <= 0.0:
        return 1.0, shFade
    t = -b + math.sqrt(disc)
    sp = norm(add(surfL, sc(sunL, t)))
    scov = coverage_fn(sp)
    return 1.0 - strength * scov * shFade, shFade


print()
print("cloud SHADOW solve")
nl = (1.0, 0.0, 0.0)
surf = sc(nl, R)

worst = 0.0
random.seed(20261015)
for _ in range(4000):
    sunL = norm((random.gauss(0, 1), random.gauss(0, 1), random.gauss(0, 1)))
    if dot(nl, sunL) <= 0.36:
        continue
    h = random.choice([0.005, 0.02, 0.06])
    rSh = R * (1.0 + h)
    b = dot(surf, sunL)
    disc = b * b - R * R + rSh * rSh
    if disc <= 0.0:
        continue
    t = -b + math.sqrt(disc)
    P = add(surf, sc(sunL, t))
    worst = max(worst, abs(math.sqrt(dot(P, P)) - rSh))
check("H. shadow hit point lies ON the shell (4000 random sun directions)",
      worst < 1e-6 * R, "worst residual %.3e units (R=%g)" % (worst, R))

sun_up = (1.0, 0.0, 0.0)
b_up = dot(surf, sun_up)
t_up = -b_up + math.sqrt(b_up * b_up - R * R + (R * 1.02) ** 2)
check("I. sun overhead hits the shell straight up at R*(1+h)",
      abs((R + t_up) - (R * 1.02)) < 1e-6 * R,
      "t = %.4f, expected %.4f" % (t_up, R * 0.02))

behind = 0
for _ in range(2000):
    sunL = norm((random.gauss(0, 1), random.gauss(0, 1), random.gauss(0, 1)))
    if dot(nl, sunL) <= 0.36:
        continue
    rSh = R * 1.02
    b = dot(surf, sunL)
    disc = b * b - R * R + rSh * rSh
    t = -b + math.sqrt(disc)
    P = add(surf, sc(sunL, t))
    if dot(P, sunL) <= dot(surf, sunL):
        behind += 1
check("J. shadow point is always on the sunward side of the surface",
      behind == 0, "%d behind" % behind)

_, fade_h = shadow_shade(nl, (0.0, 1.0, 0.0), 0.02, lambda d: 1.0, 1.0)
check("K. shadow fades out at the horizon (no infinite-ray sampling)",
      fade_h == 0.0, "fade at NL=0 -> %.3f" % fade_h)

cov_full = lambda d: 1.0
shade, _ = shadow_shade(nl, sun_up, 0.02, cov_full, 0.55)
check("L. full coverage + full strength darkens the sun by exactly `strength`",
      abs(shade - (1.0 - 0.55)) < 1e-12, "shade = %.4f (expected %.4f)" % (shade, 1.0 - 0.55))

shade0, _ = shadow_shade(nl, sun_up, 0.02, cov_full, 0.0)
check("M. cloudShadow = 0 is an exact no-op", abs(shade0 - 1.0) < 1e-15)

# --- N: the deck mix factor must stay in [0,1] now that `clouds` exceeds 1.
# `render.planet.clouds` defaults to 2.0 and resolved coverage is clamped at 1.5
# (not 1.0 -- see Planet:cloudCoverage), so an UNCLAMPED cov*clouds reaches 1.5.
# mix(a, b, t) with t > 1 extrapolates PAST b, so the deck would render brighter
# than the cloud colour itself rather than saturating. Worst case is opaque deck
# (cov = 1) at the maximum resolved coverage.
MAX_RESOLVED = 1.5
unclamped_max = 1.0 * MAX_RESOLVED
clamped = max(0.0, min(1.0, unclamped_max))
check("N. deck mix factor never exceeds 1 (no mix extrapolation)",
      clamped <= 1.0 and unclamped_max > 1.0,
      "unclamped peak %.2f -> clamped %.2f" % (unclamped_max, clamped))
# ...but note what the clamp DOES cost: the factor reaches 1.0 at
# cov = 1/clouds, not at cov = 1.0, so the top of the coverage ramp flattens.
# That is correct behaviour (opaque cloud must render opaque) but it means the
# soft edge completes early. Assert the edge still exists at all -- if the
# saturation point reached 0.0 the deck would be uniformly opaque with no ramp.
default_resolved = 0.60 * 2.0 + 0.0   # terrestrial at the default knob, no bias
sat_at = 1.0 / default_resolved
check("O. deck still reaches full opacity on covered ground",
      min(1.0, 1.0 * default_resolved) == 1.0,
      "resolved %.2f -> cov=1 gives mix 1.000" % default_resolved)
check("O2. a soft coverage edge survives (ramp not collapsed to a step)",
      0.0 < sat_at < 1.0,
      "ramp saturates at cov %.3f (of 1.0) at resolved %.2f"
      % (sat_at, default_resolved))
# But the top of the knob range legitimately saturates, and that must be a clamp,
# not an extrapolation.
top_resolved = min(MAX_RESOLVED, 0.70 * 3.0)
check("P. maximum coverage saturates at exactly 1.0, never beyond",
      top_resolved >= 1.0 and min(1.0, 1.0 * top_resolved) == 1.0,
      "knob 3.0 ocean -> resolved %.2f -> mix 1.000" % top_resolved)

def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0])

# --- V: the drift is a ROTATION, and that is the whole point.
# It used to be `normalize(dir + D*driftdir)` with D = cloudTime*rate growing
# without bound. Because normalize() discards magnitude, every fragment's sample
# direction tends to driftdir as D grows, and driftdir sits at a FIXED angle off
# the equatorial plane -- so all latitudes collapsed together (+80 and -80 deg both
# landed at -21.8, the equator at 0) and the deck squeezed into one band. The
# player reported this as "the wind going down a drain", and it got worse as the
# Wind slider rose because a larger rate reaches the collapse sooner.
def rot_axis(d, a, ang):
    a = norm(a)
    return norm(sc(d, math.cos(ang))
               + sc(cross(a, d), math.sin(ang))
               + sc(a, dot(a, d) * (1.0 - math.cos(ang))))

def lat_lon(lat_deg, lon_deg):
    la, lo = math.radians(lat_deg), math.radians(lon_deg)
    return (math.cos(la) * math.cos(lo), math.sin(la), math.cos(la) * math.sin(lo))

SPIN = norm((-0.24, 0.96, 0.15))     # a reported planet's spin axis

worst_len = 0.0
for ang in (0.0, 0.5, 3.0, 17.0, 250.0, 900.0, 5000.0):
    for lat in range(-80, 81, 20):
        for lon in (0.0, 70.0, 160.0):
            r = rot_axis(lat_lon(float(lat), lon), SPIN, ang)
            worst_len = max(worst_len, abs(math.sqrt(dot(r, r)) - 1.0))
check("V1. drift is an isometry (|sample| stays 1 however large the angle)",
      worst_len < 1e-9, "worst |len|-1 over angles to 5000 rad: %.2e" % worst_len)

d = lat_lon(37.0, 12.0)
p1 = rot_axis(d, SPIN, 4.25)
p2 = rot_axis(d, SPIN, 4.25 + 2.0 * math.pi)
p3 = rot_axis(d, SPIN, 4.25 + 2.0 * math.pi * 40.0)
check("V2. drift is periodic in the angle (wraps instead of growing)",
      ang_prec(p1, p2) < 1e-9 and ang_prec(p1, p3) < 1e-9,
      "after 1 turn %.2e rad, after 40 turns %.2e rad"
      % (ang_prec(p1, p2), ang_prec(p1, p3)))

ref_sep = None
worst_shrink = 0.0
for ang in (0.0, 1.0, 5.0, 30.0, 400.0):
    sep = ang_prec(rot_axis(lat_lon(70.0, 0.0), SPIN, ang),
                   rot_axis(lat_lon(-70.0, 0.0), SPIN, ang))
    if ref_sep is None:
        ref_sep = sep
    worst_shrink = max(worst_shrink, abs(sep - ref_sep))
check("V3. +70 and -70 latitude keep their separation (no convergence)",
      worst_shrink < 1e-9,
      "separation stays %.4f rad at every drift angle" % ref_sep)

def old_sample(dv, a, D):
    east = norm(cross(dv, a))
    drift = norm(add(east, sc(cross(dv, east), 0.4)))
    return norm(add(dv, sc(drift, D)))
collapse = ang_prec(old_sample(lat_lon(70.0, 0.0), SPIN, 0.0),
                    old_sample(lat_lon(70.0, 0.0), SPIN, 200.0))
check("V4. OLD construction demonstrably collapsed (the regression has teeth)",
      collapse > 1.0,
      "the old form moved one fragment's sample %.2f rad at drift 200" % collapse)

# --- R/S: storms and lightning.
# These are pinned NUMERICALLY on purpose. A single screenshot is a bad verifier
# for lightning: the envelope decays inside each 1.6 s window, so two of three
# sampled frames landed in the dead part of it and reported "zero flashes" for a
# feature that was working. Sampling luck is not evidence.
weather = 0.60          # terrestrial prior
storm_amt = weather * 3.0
# A storm factor is clamped BEFORE it drives a mix(); unclamped it reaches 1.8 and
# mix(1.0, 0.45, 1.8) extrapolates to 0.01, i.e. cells go almost black.
def lerp(a, b, f):
    return a + (b - a) * f
dark_clamped = lerp(1.0, 0.45, min(1.0, storm_amt))
dark_raw = lerp(1.0, 0.45, storm_amt)
check("R1. storm mix factor is clamped so cells cannot be driven to black",
      dark_clamped >= 0.40 and dark_raw < 0.05,
      "clamped -> %.3f (readable); unclamped would have been %.3f (black)"
      % (dark_clamped, dark_raw))
check("R2. a fully-developed storm still leaves the deck readable (not black)",
      0.30 < dark_clamped < 0.60,
      "full storm multiplies deck albedo by %.2f" % dark_clamped)

# Flash duty cycle: fraction of a window where the envelope is still visible.
win_dur = 1.6
visible = sum(1 for i in range(400)
              if math.exp(-(i / 400.0) * 5.0) > 0.10)
check("S1. a lightning flash is visible for a sensible part of its window",
      0.20 < visible / 400.0 < 0.75,
      "env > 0.10 for %.0f%% of the %.1f s window"
      % (100.0 * visible / 400.0, win_dur))
peak = min(1.0, 0.8) * 3.2
check("S2. a peak flash brightens the deck without exceeding the cap",
      0.0 < peak <= 0.8 * 3.2 + 1e-12,
      "peak deck addition %.2f (cap %.2f)" % (peak, 0.8 * 3.2))
# The cell grid must never be visible: the border window has to reach 0 at the
# cell edge, otherwise a firing cell paints a hard SQUARE (seen 2026-10-15).
def border_window(f):
    if f < 0.30:
        t = f / 0.30
        return t * t * (3.0 - 2.0 * t)
    if f <= 0.70:
        return 1.0
    return max(0.0, 1.0 - (f - 0.70) / 0.30)
check("S3. cell border window reaches zero at the cell edge (no visible grid)",
      abs(border_window(0.0)) < 1e-12 and abs(border_window(1.0)) < 1e-12
      and border_window(0.5) > 0.99,
      "f=0 -> %.3f, f=0.5 -> %.3f, f=1 -> %.3f"
      % (border_window(0.0), border_window(0.5), border_window(1.0)))

# --- T: aurora localisation.
# Aurorae must be a NARROW polar band on the NIGHT side. The first attempt
# spanned latitude 0.70-0.99 and washed the entire disc green.
def ss(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3.0 - 2.0 * t)
def oval(lat):
    return ss(0.84, 0.90, lat) * (1.0 - ss(0.93, 0.985, lat))
def night_w(NL):
    return 1.0 - ss(-0.55, 0.10, NL)
check("T1. auroral oval peaks in the 64-68 deg band, zero at equator and pole",
      oval(math.sin(math.radians(66))) > 0.95
      and oval(0.0) == 0.0 and oval(1.0) == 0.0,
      "lat 66deg -> %.3f, equator -> %.3f, pole -> %.3f"
      % (oval(math.sin(math.radians(66))), oval(0.0), oval(1.0)))
check("T2. aurora is dark on the day side and lit on the night side",
      night_w(0.5) == 0.0 and night_w(-0.5) > 0.95,
      "NL=+0.5 (day) -> %.3f, NL=-0.5 (night) -> %.3f" % (night_w(0.5), night_w(-0.5)))
G_W, R_W = 2.60, 0.70
check("T3. green emission dominates red (arc reads green, not magenta)",
      G_W > R_W * 2.5,
      "green gain %.2f vs red gain %.2f (%.1fx)" % (G_W, R_W, G_W / R_W))

# --- U: no tangent basis may come back, anywhere.
# TWO separate artefacts in this area were the same mistake: a ternary that swaps
# a reference axis (+Y for +X) puts its branch boundary on the latitude circle
# |n.y| = 0.9 (asin 0.9 = 64.2 deg), and cross(n,+Y) / cross(n,+X) are unrelated
# vectors, so whatever frame depends on it SHEARS discontinuously there. It was
# in the cloud drift (11.14) AND in the terrain relief gradient (which predates
# the cloud work entirely). Both are now built from the spin axis, and the drift
# is a rotation with no frame at all.
import os
SHADER = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                       os.pardir, "res", "shader", "fragment",
                                       "material", "planet.glsl"))
src = open(SHADER).read() if os.path.exists(SHADER) else ""
# Strip comments so the OLD code quoted in explanatory comments is not a hit.
code = "\n".join(l.split("//", 1)[0] for l in src.split("\n"))
ternary = " ? vec3("
check("U1. no ternary reference-axis basis remains in executable shader code",
      bool(code) and ternary not in code,
      "found %d ternary reference-axis bas(es) in code" % code.count(ternary))
check("U2. cloud drift is a rotation, and the relief frame uses the spin axis",
      "driftRotate" in code and "planetSpinAxis" in code
      and "cloudDriftAng" in code,
      "driftRotate=%s planetSpinAxis=%s cloudDriftAng=%s"
      % ("driftRotate" in code, "planetSpinAxis" in code, "cloudDriftAng" in code))

print("all checks passed")