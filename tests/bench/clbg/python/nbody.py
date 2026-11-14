# Benchmarks Game n-body, single-threaded (see ../SPEC.md).
import sys
from math import sqrt

PI = 3.141592653589793
SOLAR_MASS = 4 * PI * PI
DAYS_PER_YEAR = 365.24

INITIAL = [
    (0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0),
    (4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01,
     1.66007664274403694e-03, 7.69901118419740425e-03, -6.90460016972063023e-05,
     9.54791938424326609e-04),
    (8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01,
     -2.76742510726862411e-03, 4.99852801234917238e-03, 2.30417297573763929e-05,
     2.85885980666130812e-04),
    (1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01,
     2.96460137564761618e-03, 2.37847173959480950e-03, -2.96589568540237556e-05,
     4.36624404335156298e-05),
    (1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01,
     2.68067772490389322e-03, 1.62824170038242295e-03, -9.51592254519715870e-05,
     5.15138902046611451e-05),
]


def make_bodies():
    # Each body is a list [x, y, z, vx, vy, vz, mass], updated in place.
    return [[x, y, z, vx * DAYS_PER_YEAR, vy * DAYS_PER_YEAR, vz * DAYS_PER_YEAR,
             m * SOLAR_MASS] for (x, y, z, vx, vy, vz, m) in INITIAL]


def offset_momentum(bodies):
    px = py = pz = 0.0
    for b in bodies:
        px += b[3] * b[6]
        py += b[4] * b[6]
        pz += b[5] * b[6]
    sun = bodies[0]
    sun[3] = -px / SOLAR_MASS
    sun[4] = -py / SOLAR_MASS
    sun[5] = -pz / SOLAR_MASS


def energy(bodies):
    e = 0.0
    nb = len(bodies)
    for i in range(nb):
        xi, yi, zi, vx, vy, vz, mi = bodies[i]
        e += 0.5 * mi * (vx * vx + vy * vy + vz * vz)
        for j in range(i + 1, nb):
            xj, yj, zj, _, _, _, mj = bodies[j]
            dx = xi - xj
            dy = yi - yj
            dz = zi - zj
            e -= mi * mj / sqrt(dx * dx + dy * dy + dz * dz)
    return e


def advance(bodies, pairs, n, dt):
    for _ in range(n):
        for bi, bj in pairs:
            dx = bi[0] - bj[0]
            dy = bi[1] - bj[1]
            dz = bi[2] - bj[2]
            d2 = dx * dx + dy * dy + dz * dz
            mag = dt / (d2 * sqrt(d2))
            mi = bi[6]
            mj = bj[6]
            bi[3] -= dx * mj * mag
            bi[4] -= dy * mj * mag
            bi[5] -= dz * mj * mag
            bj[3] += dx * mi * mag
            bj[4] += dy * mi * mag
            bj[5] += dz * mi * mag
        for b in bodies:
            b[0] += dt * b[3]
            b[1] += dt * b[4]
            b[2] += dt * b[5]


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 5000000
    bodies = make_bodies()
    pairs = [(bodies[i], bodies[j])
             for i in range(len(bodies)) for j in range(i + 1, len(bodies))]
    offset_momentum(bodies)
    out = ["%.9f" % energy(bodies)]
    advance(bodies, pairs, n, 0.01)
    out.append("%.9f" % energy(bodies))
    sys.stdout.write("\n".join(out) + "\n")


main()
