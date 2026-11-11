// wordfreq: word counts, top 10 (SPEC.md)
import java.io.BufferedReader;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class Wordfreq {
    public static void main(String[] args) throws IOException {
        String path = args.length > 0 ? args[0] : "data/corpus.txt";
        Map<String, Long> counts = new HashMap<>();
        long total = 0;
        try (BufferedReader in = Files.newBufferedReader(Paths.get(path), StandardCharsets.US_ASCII)) {
            String line;
            while ((line = in.readLine()) != null) {
                int n = line.length(), i = 0;
                while (i < n) {
                    while (i < n && Character.isWhitespace(line.charAt(i))) i++;
                    if (i >= n) break;
                    int start = i;
                    while (i < n && !Character.isWhitespace(line.charAt(i))) i++;
                    counts.merge(line.substring(start, i), 1L, Long::sum);
                    total++;
                }
            }
        }
        List<Map.Entry<String, Long>> es = new ArrayList<>(counts.entrySet());
        es.sort((a, b) -> {
            int c = Long.compare(b.getValue(), a.getValue());
            return c != 0 ? c : a.getKey().compareTo(b.getKey());
        });
        StringBuilder out = new StringBuilder();
        out.append("distinct ").append(es.size()).append(" total ").append(total).append('\n');
        for (int i = 0; i < es.size() && i < 10; i++)
            out.append(es.get(i).getKey()).append(' ').append(es.get(i).getValue()).append('\n');
        System.out.print(out);
    }
}
