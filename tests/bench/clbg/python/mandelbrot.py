# Benchmarks Game mandelbrot, single-threaded (see ../SPEC.md).
import sys


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 4000
    out = bytearray(b"P4\n%d %d\n" % (n, n))
    pad = (8 - n % 8) % 8
    crs = [2.0 * x / n - 1.5 for x in range(n)]
    for y in range(n):
        ci = 2.0 * y / n - 1.0
        bits = 0
        for x in range(n):
            cr = crs[x]
            zr = zi = tr = ti = 0.0
            for _ in range(50):
                zi = 2.0 * zr * zi + ci
                zr = tr - ti + cr
                tr = zr * zr
                ti = zi * zi
                if tr + ti > 4.0:
                    break
            bits = (bits << 1) | (tr + ti <= 4.0)
            if x & 7 == 7:
                out.append(bits)
                bits = 0
        if pad:
            out.append(bits << pad)
    sys.stdout.buffer.write(out)


main()
