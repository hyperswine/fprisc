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

upto : (a : Int | measure (b - a)) -> (b : Int) -> List Int .
upto a b | a > b = [].
upto a b = a :: upto (a + 1) b.
plus a b = a + b.

palette = ["@", "#", "*", "+", "=", "-", ":", ".", " "].
# The palette is indexed by the escape count divided by 10, with 0 mapping to "@"
charFor c = case c == 0 of
  True -> "@"
| False -> palette ! (case c / 10 + 1 > 9 of True -> 9 | False -> c / 10 + 1).

# exemplar, the compiler is able to prove that cs always decreases in length, so the fold is safe
# it calls charFor c, then calls itself recursively on the rest of the list, until cs is empty
rowStr : (cs : List Int | measure cs) -> String .
rowStr cs | cs == [] = "".
rowStr cs = case cs of c :: r -> "{charFor c}{rowStr r}".

# Review: dropN and takeN are just Vec.drop / Vec.take
# they are all tail recursive, which is good

dropN : (n : Int | measure n) -> List y29 -> List y29 .
dropN n xs | n <= 0 = xs.
dropN n xs | xs == [] = [].
dropN n xs = case xs of x :: r -> dropN (n - 1) r.

takeN : (n : Int | measure n) -> List z29 -> List z29 .
takeN n xs | n <= 0 = [].
takeN n xs | xs == [] = [].
takeN n xs = case xs of x :: r -> x :: takeN (n - 1) r.

printRows : unsafe List Int -> Int .
printRows cs | cs == [] = 0.
printRows cs = u = print (rowStr (takeN w cs)); printRows (dropN w cs).

# pix maps 1..(w*h) to the escape count for each pixel. The counts are collected
# into a Vec, folded to compute the checksum, and printed row by row.
> v = Vec.fromList (upto 1 (w * h));
  counts = Vec.map pix v;
  (checksum, c2) = Vec.fold plus 0 counts;
  cl = Vec.toList c2;
  u = printRows cl;
  print "checksum: {checksum} ({w}x{h}, {maxIter} iters)".
