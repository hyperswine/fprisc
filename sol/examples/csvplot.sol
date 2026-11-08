# csvplot.sol — the science vertical in one script, the Python-notebook
# shape: generate a sensor CSV, read it back into the linear Matrix, fit a
# line by least squares, reject 3-sigma outliers, refit, and chart the data
# with both fits and the rejected points in ONE mixed-series SVG. The whole
# workflow is ONE transaction: the CSV and the chart land complete or not
# at all.
#
#   sol examples/csvplot.sol
#   -> /tmp/sol-csvplot/readings.csv, /tmp/sol-csvplot/sensor.svg
#
# The generated CSV is exact ints (like csvmatrix); decimals appear only
# where the fits' Numeric.div introduces them. The LCG is seeded, so the
# printed numbers are reproducible run to run.

mx  = use "../lib/matrix".  M = mx.M.
rnd = use "../lib/rand".    Rand = rnd.Rand.
pl  = use "../lib/plot".    P = pl.P.

dir   = "/tmp/sol-csvplot".
weeks = 40.

# ---- 1. generate: y = 12 + 3x + noise in [-5, 5]; every 13th week +150 -----

mkRow st = (s, x) = st;
  s1 = Rand.next s;
  k = Rand.uniform s1 11;
  y = 12 + 3 * x + k - 5 + (case x % 13 == 12 of True -> 150 | False -> 0);
  ((s1, x + 1), [x, y]).

genRows s n = case List.genS (s, 0) n mkRow of (_, rows) -> rows.

# ---- 2. least squares over exact int sums: one fold, one division ----------

step st p = (n, sx, sy, sxx, sxy) = st; (x, y) = p;
  (n + 1, sx + x, sy + y, sxx + x * x, sxy + x * y).

# a precondition, not a guard: distinct x values are the caller's promise
# (two equal x values make the normal-equation denominator 0)
fitOf pts | List.len pts < 2 = error "fit needs at least 2 points".
fitOf pts =
  (n, sx, sy, sxx, sxy) = List.fold step (0, 0, 0, 0, 0) pts;
  xm = Numeric.div sx n;
  ym = Numeric.div sy n;
  b = Numeric.div (n * sxy - sx * sy) (n * sxx - sx * sx);
  (n, xm, ym, ym - b * xm, b).

resid a b p = (x, y) = p; y - (a + b * x).
sqResid a b p = r = resid a b p; r * r.
sigmaOf a b pts = Numeric.sqrt (Numeric.div (List.fold (fn s p -> s + sqResid a b p) 0 pts) (List.len pts)).

# ---- 3. the 3-sigma rule, ITERATED to a stable clean set --------------------
# The plain rule has a contamination budget: with fraction f of the points
# shifted by D, the fit absorbs the shift and sigma inflates to about
# 3·sqrt(f)·0.875·D, so 3-sigma rejects only while 3·sqrt(f) < 1 — under
# ~11% of the data. At 3 of 40 weeks (7.5%) it fires; pass one rejects all
# three on the all-data sigma, pass two refits the survivors and changes
# nothing (the stable set). Past ~11% the scale itself must be robust
# (median absolute deviation), which is a different example.

mark a b sig p = (p, resid a b p, Numeric.abs (resid a b p) > 3 * sig).
fstT t = (p, r, isBad) = t; p.
thdT t = (p, r, isBad) = t; isBad.
fstP p = (x, y) = p; x.

refine pts =
  (_, _, _, a, b) = fitOf pts;
  sig = sigmaOf a b pts;
  map fstT (List.filter (fn t -> not (thdT t)) (map (mark a b sig) pts)).

robust pts = List.fold (fn ps ignored -> refine ps) pts (List.range 1 3).
memberP ps p = not (List.find (fn q -> q == p) ps == []).

# ---- 4. chart points: exact ints enter the plot boundary converted ---------

numP p = (x, y) = p; (Numeric.inexact x, Numeric.inexact y).
num pts = map numP pts.
linePts a b x0 x1 = [(x0, a + b * x0), (x1, a + b * x1)].

# ---- 5. the vertical: CSV out, CSV in, fit, reject, refit, chart ------------

> u0 = mkdirp "{dir}";
  (csv, m0) = M.toCsvHeader ["week", "reading"] (M.fromRows (genRows 20261108 weeks));
  u1 = writePath "{dir}/readings.csv" csv;
  u2 = M.free m0;
  (header, m1) = M.fromCsvHeader (readPath "{dir}/readings.csv");
  (pts, m2) = M.mapRows (fn r -> (r ! 0, r ! 1)) m1;
  u3 = M.free m2;
  (n, xm, ym, aAll, bAll) = fitOf pts;
  sigAll = sigmaOf aAll bAll pts;
  p0 = print "readings: header {header}, n = {n}, mean(x) = {xm}, mean(y) = {ym}";
  clean = robust pts;
  bad = List.filter (fn p -> not (memberP clean p)) pts;
  badWeeks = map fstP bad;
  (nC, xmC, ymC, aFit, bFit) = fitOf clean;
  sigFit = sigmaOf aFit bFit clean;
  p1 = print "all-data fit: y = {aAll} + {bAll} x (sigma {sigAll})";
  la = linePts aAll bAll 0 (weeks - 1);
  lc = linePts aFit bFit 0 (weeks - 1);
  svg = P.chart "weekly sensor: 3-sigma robust refit" [
      ("readings", False, num clean),
      ("fit (all data)", True, num la),
      ("rejected", False, num bad),
      ("fit (clean)", True, num lc)];
  u4 = writePath "{dir}/sensor.svg" svg;
  p2 = print "clean fit: y = {aFit} + {bFit} x (sigma {sigFit})";
  p3 = print "rejected {List.len bad} outlier(s) at weeks {badWeeks}";
  print "wrote {dir}/sensor.svg".
