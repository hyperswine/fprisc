import java.io.BufferedOutputStream;
import java.io.PrintStream;

public final class Fannkuchredux {
    public static void main(String[] args) {
        int n = args.length > 0 ? Integer.parseInt(args[0]) : 10;
        PrintStream out = new PrintStream(new BufferedOutputStream(System.out), false);
        int[] perm1 = new int[n], perm = new int[n], count = new int[n];
        for (int i = 0; i < n; i++) perm1[i] = i;
        int maxFlips = 0, checksum = 0, permIndex = 0, r = n;
        while (true) {
            while (r != 1) { count[r - 1] = r; r--; }
            System.arraycopy(perm1, 0, perm, 0, n);
            int flips = 0;
            for (int k = perm[0]; k != 0; k = perm[0]) {
                for (int i = 0, j = k; i < j; i++, j--) {
                    int t = perm[i]; perm[i] = perm[j]; perm[j] = t;
                }
                flips++;
            }
            if (flips > maxFlips) maxFlips = flips;
            checksum += (permIndex % 2 == 0) ? flips : -flips;
            while (true) {
                if (r == n) {
                    out.print(checksum + "\nPfannkuchen(" + n + ") = " + maxFlips + "\n");
                    out.flush();
                    return;
                }
                int p0 = perm1[0];
                for (int i = 0; i < r; i++) perm1[i] = perm1[i + 1];
                perm1[r] = p0;
                count[r]--;
                if (count[r] > 0) break;
                r++;
            }
            permIndex++;
        }
    }
}
