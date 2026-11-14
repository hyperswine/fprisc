import java.io.BufferedOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

public final class Fasta {
    static final String ALU = "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGACCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAATACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCAGCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGGAGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCCAGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA";
    static final int LINE = 60;
    static final int IM = 139968, IA = 3877, IC = 29573;
    static int seed = 42;

    static final byte[] IUB_C = "acgtBDHKMNRSVWY".getBytes(StandardCharsets.US_ASCII);
    static final double[] IUB_P = {0.27, 0.12, 0.12, 0.27, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02};
    static final byte[] HS_C = "acgt".getBytes(StandardCharsets.US_ASCII);
    static final double[] HS_P = {0.3029549426680, 0.1979883004921, 0.1975473066391, 0.3015094502008};

    static double random() {
        seed = (seed * IA + IC) % IM;
        return (double) seed / IM;
    }

    static void repeatFasta(OutputStream out, String header, int n) throws IOException {
        out.write(header.getBytes(StandardCharsets.US_ASCII));
        byte[] alu = ALU.getBytes(StandardCharsets.US_ASCII);
        byte[] line = new byte[LINE + 1];
        int k = 0;
        while (n > 0) {
            int m = Math.min(LINE, n);
            for (int i = 0; i < m; i++) {
                line[i] = alu[k];
                if (++k == alu.length) k = 0;
            }
            line[m] = '\n';
            out.write(line, 0, m + 1);
            n -= m;
        }
    }

    static void randomFasta(OutputStream out, String header, byte[] chars, double[] probs, int n) throws IOException {
        out.write(header.getBytes(StandardCharsets.US_ASCII));
        double[] cum = new double[probs.length];
        double sum = 0;
        for (int i = 0; i < probs.length; i++) { sum += probs[i]; cum[i] = sum; }
        int last = probs.length - 1;
        byte[] line = new byte[LINE + 1];
        while (n > 0) {
            int m = Math.min(LINE, n);
            for (int i = 0; i < m; i++) {
                double r = random();
                int j = 0;
                while (j < last && cum[j] <= r) j++;
                line[i] = chars[j];
            }
            line[m] = '\n';
            out.write(line, 0, m + 1);
            n -= m;
        }
    }

    public static void main(String[] args) throws IOException {
        int n = args.length > 0 ? Integer.parseInt(args[0]) : 2500000;
        BufferedOutputStream out = new BufferedOutputStream(System.out, 1 << 16);
        repeatFasta(out, ">ONE Homo sapiens alu\n", 2 * n);
        randomFasta(out, ">TWO IUB ambiguity codes\n", IUB_C, IUB_P, 3 * n);
        randomFasta(out, ">THREE Homo sapiens frequency\n", HS_C, HS_P, 5 * n);
        out.flush();
    }
}
