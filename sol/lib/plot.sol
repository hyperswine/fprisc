# plot.sol — a 2D plotting backend that is ONLY TEXT: charts and
# animations render to self-contained SVG, written like any other Sol
# string (one transactional writePath; any browser is the viewer; the
# repo can even diff them).  Animation-over-time is SMIL — <animate>
# elements interpolating point lists — so a physics run or a training
# loop becomes ONE file with zero runtime and zero dependencies.
#
#   pl = use "../lib/plot". P = pl.P.
#
#   s1 = P.line "loss" pts;                    # pts = [(x, y)]
#   s2 = P.series "spring" [("x", ptsX), ("v", ptsV)];
#   s3 = P.scatter "descent" pts;              # hover a marker: value tooltip
#   s4 = P.anim "wave" 4 frames;               # frames = [[(x,y)]], same
#                                              # length each: polyline morph
#   s5 = P.animDots "orbit" 6 tracks;          # tracks = [[(x,y) over time]]:
#                                              # one moving dot + faint trail
#   u = writePath @plots/wave.svg s4.
#
# Design (the dataviz method, committed to one light look because a
# standalone .svg has no theme context): validated categorical palette
# in FIXED slot order, recessive grid, thin 2px lines, >=8px markers,
# text in ink tokens (never series color), legend whenever there are
# >= 2 series.  Data is LISTS at this boundary — Vec/Matrix data
# arrives via Vec.toList / M.mapRows, the same convention as matmul's
# row algebra.

base = use "base".

# ---- geometry / palette ----------------------------------------------------

pW = 640.  pH = 400.
pL = 52.   pR = 624.  pT = 40.  pB = 360.

inkP = "#0b0b0b".
inkS = "#52514e".
gridC = "#e7e6e2".
surfC = "#fcfcfb".

colors = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300"].
colAt i = colors ! (((i - 1) % (List.len colors)) + 1).

# ---- small numeric helpers -------------------------------------------------

fmtN v = Num.round (v * 1000) / 1000.0.

bGo f xs a | xs == [] = a.
bGo f xs a = x :: r = xs; bGo f r (f a x).
bMin xs = x :: r = xs; bGo (fn a b -> Numeric.min a b) r x.
bMax xs = x :: r = xs; bGo (fn a b -> Numeric.max a b) r x.

# bounds of [(x, y)] -> (minx, maxx, miny, maxy), degenerate spans padded
ptsBounds pts =
  xs = map (fn p -> fst2 p) pts;
  ys = map (fn p -> snd2 p) pts;
  (lo1, hi1) = padB (bMin xs) (bMax xs);
  (lo2, hi2) = padB (bMin ys) (bMax ys);
  (lo1, hi1, lo2, hi2).
fst2 p = (a, b) = p; a.
snd2 p = (a, b) = p; b.
padB lo hi = case hi - lo == 0 of True -> (lo - 1, hi + 1) | False -> (lo, hi).

mergeB a b =
  (a1, a2, a3, a4) = a; (b1, b2, b3, b4) = b;
  (Numeric.min a1 b1, Numeric.max a2 b2, Numeric.min a3 b3, Numeric.max a4 b4).

allBounds ptss = bGo (fn a pts -> mergeB a (ptsBounds pts)) (lTailP ptss) (ptsBounds (ptss ! 1)).
lTailP xs = x :: r = xs; r.

# data -> pixel (y flips)
sx bx v = (x1, x2, y1, y2) = bx; pL + (v - x1) * (pR - pL) / (x2 - x1).
sy bx v = (x1, x2, y1, y2) = bx; pB - (v - y1) * (pB - pT) / (y2 - y1).

# "x,y x,y ..." pixel-mapped SMIL/polyline point list
ptsStr bx pts b | pts == [] = b.
ptsStr bx pts b =
  p :: r = pts; (x, y) = p;
  ptsStr bx r (BStr.append "{fmtN (sx bx x)},{fmtN (sy bx y)} " b).
ptsS bx pts = BStr.toStr (ptsStr bx pts (BStr.new Unit)).

# ---- chart chrome ----------------------------------------------------------

svgOpen title b =
  b2 = BStr.append "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {pW} {pH}\" font-family=\"system-ui, sans-serif\">{base.nl}" b;
  b3 = BStr.append "<rect width=\"{pW}\" height=\"{pH}\" fill=\"{surfC}\"/>{base.nl}" b2;
  BStr.append "<text x=\"{pL}\" y=\"24\" fill=\"{inkP}\" font-size=\"15\" font-weight=\"600\">{title}</text>{base.nl}" b3.

# 5 ticks per axis: recessive grid lines + secondary-ink labels
tickVals lo hi = [lo, lo + (hi - lo) / 4, lo + (hi - lo) / 2, lo + 3 * (hi - lo) / 4, hi].

gridX bx vs b | vs == [] = b.
gridX bx vs b =
  v :: r = vs; px = fmtN (sx bx v);
  b2 = BStr.append "<line x1=\"{px}\" y1=\"{pT}\" x2=\"{px}\" y2=\"{pB}\" stroke=\"{gridC}\" stroke-width=\"1\"/>{base.nl}" b;
  gridX bx r (BStr.append "<text x=\"{px}\" y=\"{pB + 18}\" fill=\"{inkS}\" font-size=\"11\" text-anchor=\"middle\">{fmtN v}</text>{base.nl}" b2).

gridY bx vs b | vs == [] = b.
gridY bx vs b =
  v :: r = vs; py = fmtN (sy bx v);
  b2 = BStr.append "<line x1=\"{pL}\" y1=\"{py}\" x2=\"{pR}\" y2=\"{py}\" stroke=\"{gridC}\" stroke-width=\"1\"/>{base.nl}" b;
  gridY bx r (BStr.append "<text x=\"{pL - 6}\" y=\"{py + 4}\" fill=\"{inkS}\" font-size=\"11\" text-anchor=\"end\">{fmtN v}</text>{base.nl}" b2).

axes bx b =
  (x1, x2, y1, y2) = bx;
  b2 = gridX (x1, x2, y1, y2) (tickVals x1 x2) b;
  gridY (x1, x2, y1, y2) (tickVals y1 y2) b2.

legend named b = legGo named 1 b.
legGo named i b | named == [] = b.
legGo named i b =
  nm :: r = named;
  lx = pL + (i - 1) * 120;
  b2 = BStr.append "<rect x=\"{lx}\" y=\"{pB + 26}\" width=\"10\" height=\"10\" rx=\"2\" fill=\"{colAt i}\"/>{base.nl}" b;
  legGo r (i + 1) (BStr.append "<text x=\"{lx + 15}\" y=\"{pB + 35}\" fill=\"{inkS}\" font-size=\"12\">{nm}</text>{base.nl}" b2).

svgClose b = BStr.toStr (BStr.append "</svg>{base.nl}" b).

# ---- marks -----------------------------------------------------------------

polyline bx col pts b =
  BStr.append "<polyline points=\"{ptsS bx pts}\" fill=\"none\" stroke=\"{col}\" stroke-width=\"2\" stroke-linejoin=\"round\"/>{base.nl}" b.

markers bx col pts b | pts == [] = b.
markers bx col pts b =
  p :: r = pts; (x, y) = p;
  markers bx col r (BStr.append "<circle cx=\"{fmtN (sx bx x)}\" cy=\"{fmtN (sy bx y)}\" r=\"4\" fill=\"{col}\"><title>({fmtN x}, {fmtN y})</title></circle>{base.nl}" b).

# ---- the public charts -----------------------------------------------------

# one series, line: the title names it, no legend box
pLine title pts =
  bx = ptsBounds pts;
  b = axes bx (svgOpen title (BStr.new Unit));
  svgClose (polyline bx (colAt 1) pts b).

# n series: fixed-order slot colors + a legend
pSeries title named =
  bx = allBounds (map (fn s -> snd2 s) named);
  b = axes bx (svgOpen title (BStr.new Unit));
  b2 = serGo bx named 1 b;
  svgClose (legend (map (fn s -> fst2 s) named) b2).
serGo bx named i b | named == [] = b.
serGo bx named i b =
  s :: r = named; (nm, pts) = s;
  serGo bx r (i + 1) (polyline bx (colAt i) pts b).

pScatter title pts =
  bx = ptsBounds pts;
  b = axes bx (svgOpen title (BStr.new Unit));
  svgClose (markers bx (colAt 1) pts b).

# frames = [[(x, y)]], all the SAME length: one polyline whose points
# MORPH through the frames (SMIL interpolates), looping every dur s.
# Axes are fixed to the union of every frame's bounds.
pAnim title dur frames =
  bx = allBounds frames;
  b = axes bx (svgOpen title (BStr.new Unit));
  vals = BStr.toStr (valsGo bx frames (BStr.new Unit));
  first = ptsS bx (frames ! 1);
  b2 = BStr.append "<polyline points=\"{first}\" fill=\"none\" stroke=\"{colAt 1}\" stroke-width=\"2\" stroke-linejoin=\"round\"><animate attributeName=\"points\" dur=\"{dur}s\" repeatCount=\"indefinite\" values=\"{vals}\"/></polyline>{base.nl}" b;
  svgClose b2.
valsGo bx frames b | frames == [] = b.
valsGo bx frames b =
  f :: r = frames;
  sep = case r == [] of True -> "" | False -> ";";
  valsGo bx r (BStr.append "{ptsS bx f}{sep}" b).

# tracks = [[(x, y) over time]]: one dot per track animated along its
# samples (cx/cy value lists) + the full path as a faint static trail
pAnimDots title dur tracks =
  bx = allBounds tracks;
  b = axes bx (svgOpen title (BStr.new Unit));
  b2 = trailGo bx tracks 1 b;
  svgClose (dotGo bx tracks 1 dur b2).
trailGo bx tracks i b | tracks == [] = b.
trailGo bx tracks i b =
  t :: r = tracks;
  b2 = BStr.append "<polyline points=\"{ptsS bx t}\" fill=\"none\" stroke=\"{colAt i}\" stroke-width=\"1\" opacity=\"0.25\"/>{base.nl}" b;
  trailGo bx r (i + 1) b2.
dotGo bx tracks i dur b | tracks == [] = b.
dotGo bx tracks i dur b =
  t :: r = tracks; (x0, y0) = t ! 1;
  cxs = joinSemi (map (fn p -> fmtN (sx bx (fst2 p))) t);
  cys = joinSemi (map (fn p -> fmtN (sy bx (snd2 p))) t);
  b2 = BStr.append "<circle cx=\"{fmtN (sx bx x0)}\" cy=\"{fmtN (sy bx y0)}\" r=\"6\" fill=\"{colAt i}\"><animate attributeName=\"cx\" dur=\"{dur}s\" repeatCount=\"indefinite\" values=\"{cxs}\"/><animate attributeName=\"cy\" dur=\"{dur}s\" repeatCount=\"indefinite\" values=\"{cys}\"/></circle>{base.nl}" b;
  dotGo bx r (i + 1) dur b2.
joinSemi xs | xs == [] = "".
joinSemi xs | (x :: r) <- xs, r == [] = "{x}".
joinSemi xs = x :: r = xs; "{x};{joinSemi r}".

# ---- the public surface ----------------------------------------------------

P = Struct {
  line     = fn title pts -> pLine title pts,
  series   = fn title named -> pSeries title named,
  scatter  = fn title pts -> pScatter title pts,
  anim     = fn title dur frames -> pAnim title dur frames,
  animDots = fn title dur tracks -> pAnimDots title dur tracks
}.
