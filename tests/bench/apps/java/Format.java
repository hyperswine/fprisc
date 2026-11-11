// format: string building (SPEC.md)
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

public class Format {
    static final int N = 1_000_000;
    static final long M = 1_000_000_007L;

    public static void main(String[] args) {
        String[] status = {"open", "paid", "shipped"};
        List<String> lines = new ArrayList<>(N);
        for (long i = 0; i < N; i++) {
            long c = (i * 7919) % 10007;
            long q = i % 17 + 1;
            long cents = (i * 104729) % 1_000_000;
            lines.add(String.format(Locale.ROOT, "order %d cust c%d qty %d total %d.%02d status %s",
                    i, c, q, cents / 100, cents % 100, status[(int) (i % 3)]));
        }
        long bytes = 0, h = 0;
        for (String l : lines) {
            long len = l.length();   // ASCII: chars == bytes
            bytes += len;
            h = (h * 31 + len) % M;
        }
        StringBuilder out = new StringBuilder();
        out.append("lines ").append(N).append(" bytes ").append(bytes).append(" hash ").append(h).append('\n');
        out.append(lines.get(0)).append('\n');
        out.append(lines.get(499_999)).append('\n');
        out.append(lines.get(999_999)).append('\n');
        System.out.print(out);
    }
}
