// records: three-key sort and group-by (SPEC.md)
import java.util.Arrays;

public class Records {
    static final int N = 1_000_000;
    static final long M = 1_000_000_007L;

    record Rec(long id, long dept, long age, long salary) {}

    static long lcg(long x) { return (x * 1103515245L + 12345L) % 2147483648L; }

    public static void main(String[] args) {
        Rec[] rs = new Rec[N];
        long x = 42;
        for (int id = 0; id < N; id++) {
            x = lcg(x);
            rs[id] = new Rec(id, x % 100, 18 + (x / 100) % 63, 30000 + (x / 6300) % 90000);
        }
        Arrays.sort(rs, (a, b) -> {
            if (a.dept() != b.dept()) return Long.compare(a.dept(), b.dept());
            if (a.age() != b.age()) return Long.compare(b.age(), a.age());
            return Long.compare(a.id(), b.id());
        });
        long o = 0;
        for (Rec r : rs) o = (o * 31 + r.id()) % M;
        StringBuilder out = new StringBuilder();
        out.append("records ").append(N).append(" order ").append(o).append('\n');
        int i = 0;
        while (i < N) {
            long dept = rs[i].dept(), first = rs[i].id(), count = 0, sum = 0;
            while (i < N && rs[i].dept() == dept) { count++; sum += rs[i].salary(); i++; }
            out.append(dept).append(' ').append(count).append(' ').append(sum).append(' ').append(first).append('\n');
        }
        System.out.print(out);
    }
}
