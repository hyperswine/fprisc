// csv: parse and aggregate (SPEC.md)
import java.io.BufferedReader;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class Csv {
    static final class Agg {
        long count, sumA, maxB;
    }

    public static void main(String[] args) throws IOException {
        String path = args.length > 0 ? args[0] : "data/sales.csv";
        Map<String, Agg> map = new HashMap<>();
        long lines = 0;
        try (BufferedReader in = Files.newBufferedReader(Paths.get(path), StandardCharsets.US_ASCII)) {
            String line;
            while ((line = in.readLine()) != null) {
                if (line.isEmpty()) continue;
                String[] f = line.split(",");
                long a = Long.parseLong(f[1]);
                long b = Long.parseLong(f[2]);
                Agg e = map.computeIfAbsent(f[0], k -> new Agg());
                e.count++;
                e.sumA += a;
                if (b > e.maxB) e.maxB = b;
                lines++;
            }
        }
        List<Map.Entry<String, Agg>> es = new ArrayList<>(map.entrySet());
        es.sort((x, y) -> {
            int c = Long.compare(y.getValue().sumA, x.getValue().sumA);
            return c != 0 ? c : x.getKey().compareTo(y.getKey());
        });
        StringBuilder out = new StringBuilder();
        out.append("keys ").append(es.size()).append(" lines ").append(lines).append('\n');
        for (int i = 0; i < es.size() && i < 10; i++) {
            Agg a = es.get(i).getValue();
            out.append(es.get(i).getKey()).append(' ').append(a.count).append(' ')
               .append(a.sumA).append(' ').append(a.maxB).append('\n');
        }
        System.out.print(out);
    }
}
