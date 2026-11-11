// sim: particle simulation (SPEC.md)
public class Sim {
    static final int NP = 20_000;
    static final int STEPS = 2_000;

    static final class Particle {
        long px, py, vx, vy;
    }

    static long lcg(long x) { return (x * 1103515245L + 12345L) % 2147483648L; }

    public static void main(String[] args) {
        Particle[] ps = new Particle[NP];
        long x = 1;
        for (int i = 0; i < NP; i++) {
            Particle p = new Particle();
            x = lcg(x); p.px = x % 1_000_000;
            x = lcg(x); p.py = x % 1_000_000;
            x = lcg(x); p.vx = x % 2001 - 1000;
            x = lcg(x); p.vy = x % 2001 - 1000;
            ps[i] = p;
        }
        for (int s = 0; s < STEPS; s++) {
            for (Particle p : ps) {
                p.vy -= 1;
                p.px += p.vx;
                if (p.px < 0) { p.px = -p.px; p.vx = -p.vx; }
                else if (p.px > 1_000_000) { p.px = 2_000_000 - p.px; p.vx = -p.vx; }
                p.py += p.vy;
                if (p.py < 0) { p.py = -p.py; p.vy = -p.vy; }
                else if (p.py > 1_000_000) { p.py = 2_000_000 - p.py; p.vy = -p.vy; }
            }
        }
        long sx = 0, sy = 0, e = 0;
        for (Particle p : ps) {
            sx += p.px; sy += p.py;
            e += p.vx * p.vx + p.vy * p.vy;
        }
        System.out.println("particles " + NP + " steps " + STEPS + " sx " + sx + " sy " + sy + " energy " + e);
    }
}
