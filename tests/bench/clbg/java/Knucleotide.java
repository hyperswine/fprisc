import java.io.BufferedOutputStream;
import java.io.BufferedReader;
import java.io.FileReader;
import java.io.IOException;
import java.io.PrintStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

public final class Knucleotide {
    static HashMap<String, Integer> count(String seq, int k) {
        HashMap<String, Integer> m = new HashMap<>();
        for (int i = 0; i + k <= seq.length(); i++) {
            m.merge(seq.substring(i, i + k), 1, Integer::sum);
        }
        return m;
    }

    public static void main(String[] args) throws IOException {
        String path = args.length > 0 ? args[0] : "data/fasta-1000000.txt";
        StringBuilder sb = new StringBuilder();
        try (BufferedReader in = new BufferedReader(new FileReader(path), 1 << 16)) {
            String line;
            boolean inside = false;
            while ((line = in.readLine()) != null) {
                if (line.startsWith(">")) {
                    if (inside) break;
                    inside = line.startsWith(">THREE");
                    continue;
                }
                if (inside) sb.append(line);
            }
        }
        String seq = sb.toString().toUpperCase(Locale.ROOT);
        PrintStream out = new PrintStream(new BufferedOutputStream(System.out), false);
        for (int k = 1; k <= 2; k++) {
            HashMap<String, Integer> m = count(seq, k);
            List<Map.Entry<String, Integer>> es = new ArrayList<>(m.entrySet());
            es.sort((a, b) -> {
                int c = Integer.compare(b.getValue(), a.getValue());
                return c != 0 ? c : a.getKey().compareTo(b.getKey());
            });
            double total = seq.length() - k + 1;
            for (Map.Entry<String, Integer> e : es) {
                out.print(e.getKey() + " " + String.format(Locale.ROOT, "%.3f", 100.0 * e.getValue() / total) + "\n");
            }
            out.print("\n");
        }
        for (String q : new String[] {"GGT", "GGTA", "GGTATT", "GGTATTTTAATT", "GGTATTTTAATTTATAGT"}) {
            HashMap<String, Integer> m = count(seq, q.length());
            out.print(m.getOrDefault(q, 0) + "\t" + q + "\n");
        }
        out.flush();
    }
}
