import java.io.BufferedOutputStream;
import java.io.PrintStream;

public final class Binarytrees {
    static final class Node {
        final Node left, right;
        Node(Node left, Node right) { this.left = left; this.right = right; }
        int check() {
            return 1 + (left == null ? 0 : left.check()) + (right == null ? 0 : right.check());
        }
    }

    static Node make(int d) {
        return d == 0 ? new Node(null, null) : new Node(make(d - 1), make(d - 1));
    }

    public static void main(String[] args) {
        int n = args.length > 0 ? Integer.parseInt(args[0]) : 18;
        PrintStream out = new PrintStream(new BufferedOutputStream(System.out, 1 << 16), false);
        int minDepth = 4;
        int maxDepth = Math.max(minDepth + 2, n);
        int stretch = maxDepth + 1;
        out.print("stretch tree of depth " + stretch + "\t check: " + make(stretch).check() + "\n");
        Node longLived = make(maxDepth);
        for (int d = minDepth; d <= maxDepth; d += 2) {
            int iters = 1 << (maxDepth - d + minDepth);
            long sum = 0;
            for (int i = 0; i < iters; i++) sum += make(d).check();
            out.print(iters + "\t trees of depth " + d + "\t check: " + sum + "\n");
        }
        out.print("long lived tree of depth " + maxDepth + "\t check: " + longLived.check() + "\n");
        out.flush();
    }
}
