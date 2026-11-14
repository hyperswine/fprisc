import java.io.BufferedOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

public final class Mandelbrot {
    public static void main(String[] args) throws IOException {
        int n = args.length > 0 ? Integer.parseInt(args[0]) : 4000;
        BufferedOutputStream out = new BufferedOutputStream(System.out, 1 << 16);
        out.write(("P4\n" + n + " " + n + "\n").getBytes(StandardCharsets.US_ASCII));
        double fn = n;
        for (int y = 0; y < n; y++) {
            double ci = 2.0 * y / fn - 1.0;
            int bits = 0, bitNum = 0;
            for (int x = 0; x < n; x++) {
                double cr = 2.0 * x / fn - 1.5;
                double zr = 0, zi = 0, tr = 0, ti = 0;
                for (int i = 0; i < 50 && tr + ti <= 4.0; i++) {
                    zi = 2.0 * zr * zi + ci;
                    zr = tr - ti + cr;
                    tr = zr * zr;
                    ti = zi * zi;
                }
                bits <<= 1;
                if (tr + ti <= 4.0) bits |= 1;
                if (++bitNum == 8) { out.write(bits); bits = 0; bitNum = 0; }
            }
            if (bitNum > 0) out.write(bits << (8 - bitNum));
        }
        out.flush();
    }
}
