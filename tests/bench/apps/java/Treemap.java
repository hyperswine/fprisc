// treemap: ordered map inserts and lookups (SPEC.md)
import java.util.TreeMap;

public class Treemap {
    static final long M = 1_000_000_007L;

    static long lcg(long x) { return (x * 1103515245L + 12345L) % 2147483648L; }

    public static void main(String[] args) {
        TreeMap<Long, Long> map = new TreeMap<>();
        long x = 7;
        for (long i = 0; i < 500_000; i++) {
            x = lcg(x);
            map.put(x % 1_000_000, i);
        }
        long hits = 0, sum = 0;
        for (int i = 0; i < 500_000; i++) {
            x = lcg(x);
            Long v = map.get(x % 1_000_000);
            if (v != null) { hits++; sum += v; }
        }
        long k = 0;
        for (long key : map.keySet()) k = (k * 31 + key) % M;
        System.out.println("size " + map.size() + " hits " + hits + " sum " + sum + " keyhash " + k);
    }
}
