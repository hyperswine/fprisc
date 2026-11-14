import java.io.BufferedOutputStream;
import java.io.PrintStream;
import java.util.Locale;

public final class Spectralnorm {
    static double a(int i, int j) { return 1.0 / ((i + j) * (i + j + 1) / 2 + i + 1); }

    static void av(double[] v, double[] out) {
        for (int i = 0; i < out.length; i++) {
            double s = 0;
            for (int j = 0; j < v.length; j++) s += a(i, j) * v[j];
            out[i] = s;
        }
    }

    static void atv(double[] v, double[] out) {
        for (int i = 0; i < out.length; i++) {
            double s = 0;
            for (int j = 0; j < v.length; j++) s += a(j, i) * v[j];
            out[i] = s;
        }
    }

    static void atav(double[] v, double[] out, double[] tmp) { av(v, tmp); atv(tmp, out); }

    public static void main(String[] args) {
        int n = args.length > 0 ? Integer.parseInt(args[0]) : 2000;
        PrintStream out = new PrintStream(new BufferedOutputStream(System.out), false);
        double[] u = new double[n], v = new double[n], tmp = new double[n];
        java.util.Arrays.fill(u, 1.0);
        for (int i = 0; i < 10; i++) { atav(u, v, tmp); atav(v, u, tmp); }
        double vBv = 0, vv = 0;
        for (int i = 0; i < n; i++) { vBv += u[i] * v[i]; vv += v[i] * v[i]; }
        out.print(String.format(Locale.ROOT, "%.9f", Math.sqrt(vBv / vv)) + "\n");
        out.flush();
    }
}
