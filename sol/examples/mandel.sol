# mandel.sol — Mandelbrot on the Numeric datatype. Coordinates are inexact
# Numerics born from Numeric.div; the escape iteration uses plain *, +, >
# throughout — promotion carries inexactness, escape counts stay Ints.
# (The former Q16.16 version is gone: no fix library, no manual scaling.)
#
# JIT note: the typed tier compiles the per-pixel map natively — the
# complex-square recursion specializes per callsite (int seed iteration
# widening into f64 state), with the inexact plane constants folded in as
# f64 CAFs — and the all-int escape counts take the i64 fold unchanged.

# z(n+1) = (zr(n)^2 - zi(n)^2 + cr, 2*zr(n)*zi(n) + ci)
# c is the complex plane point (cr, ci) corresponding to the pixel; z(0) = 0.

w = 96.
h = 36.
maxIter = 80.

xmin = 0 - Numeric.div 2213 1000.  # -2.213 .. 0.787
xspan = 3.
ymin = 0 - Numeric.div 12 10.      # -1.2 .. 1.2
yspan = Numeric.div 24 10.

dx = Numeric.div xspan w.
dy = Numeric.div yspan h.

mand : Int -> Int -> Int -> Int -> (k : Int | measure k) -> Int .
mand cr ci zr zi k | k <= 0 = 0.
mand cr ci zr zi k =
  r2 = zr * zr;
  i2 = zi * zi;
  case r2 + i2 > 4 of
    True -> k
  | False -> mand cr ci (r2 - i2 + cr) (2 * zr * zi + ci) (k - 1).

pix : Int -> Int .
pix i =
  col = (i - 1) % w;
  row = (i - 1) / w;
  mand (xmin + col * dx) (ymin + row * dy) 0 0 maxIter.

plus a b = a + b.

palette = ["@", "#", "*", "+", "=", "-", ":", ".", " "].
# The palette is indexed by the escape count divided by 10, with 0 mapping to "@"
charFor c = case c == 0 of
  True -> "@"
| False -> palette ! (case c / 10 > 8 of True -> 8 | False -> c / 10).

rowStr cs = cs |> List.map charFor |> Str.join "".

# row r (0-based) of the row-major counts
rowOf cs r = cs |> List.drop (r * w) |> List.take w |> rowStr.

# print each line, in order
say lines = List.fold (fn n l -> u = print l; n + 1) 0 lines.

# pix maps 1..(w*h) to the escape count for each pixel. The counts are collected
# into a Vec, folded to compute the checksum, and printed row by row.
> v = Vec.fromList (List.range 1 (w * h));
  counts = Vec.map pix v;
  (checksum, c2) = Vec.fold plus 0 counts;
  cl = Vec.toList c2;
  u = say (List.range 0 (h - 1) |> List.map (rowOf cl));
  print "checksum: {checksum} ({w}x{h}, {maxIter} iters)".
