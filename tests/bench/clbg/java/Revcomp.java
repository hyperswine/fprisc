import java.io.BufferedOutputStream;
import java.io.BufferedReader;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

public final class Revcomp {
    static final byte[] COMP = new byte[256];
    static {
        for (int i = 0; i < 256; i++) COMP[i] = (byte) i;
        String pairs = "ATCGGCTAUAMKRYWWSSYRKMVBHDDHBVNN";
        for (int i = 0; i < pairs.length(); i += 2) {
            char from = pairs.charAt(i);
            byte to = (byte) pairs.charAt(i + 1);
            COMP[from] = to;
            COMP[Character.toLowerCase(from)] = to;
        }
    }

    static byte[] buf = new byte[1 << 16];
    static int len = 0;

    static void append(String line) {
        int n = line.length();
        if (len + n > buf.length) buf = java.util.Arrays.copyOf(buf, Math.max(buf.length * 2, len + n));
        for (int i = 0; i < n; i++) buf[len + i] = (byte) line.charAt(i);
        len += n;
    }

    static void flush(OutputStream out, String header) throws IOException {
        out.write(header.getBytes(StandardCharsets.ISO_8859_1));
        out.write('\n');
        for (int i = 0, j = len - 1; i <= j; i++, j--) {
            byte a = buf[i];
            buf[i] = COMP[buf[j] & 0xff];
            buf[j] = COMP[a & 0xff];
        }
        for (int i = 0; i < len; i += 60) {
            out.write(buf, i, Math.min(60, len - i));
            out.write('\n');
        }
    }

    public static void main(String[] args) throws IOException {
        String path = args.length > 0 ? args[0] : "data/fasta-2500000.txt";
        BufferedOutputStream out = new BufferedOutputStream(System.out, 1 << 16);
        try (BufferedReader in = new BufferedReader(
                new InputStreamReader(new FileInputStream(path), StandardCharsets.ISO_8859_1), 1 << 16)) {
            String header = null, line;
            while ((line = in.readLine()) != null) {
                if (line.startsWith(">")) {
                    if (header != null) flush(out, header);
                    header = line;
                    len = 0;
                } else {
                    append(line);
                }
            }
            if (header != null) flush(out, header);
        }
        out.flush();
    }
}
