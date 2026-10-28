# Exact byte-line filter with a UTF-8 needle. PATH=- reads live stdin.
# Chunk and line limits bound memory; output preserves the original LF/EOF.
emit needle n line = case Bytes.contains needle line of
  True -> u = unwrap (IO.stdout line); n + 1
| False -> n.
scan needle path maxLine =
  r = unwrap (if path == "-" then Stream.stdin 65536 else Stream.openRead path 65536);
  (result, r2) = Stream.foldLines (emit (unwrap (Utf8.encode needle))) 0 maxLine r;
  u = unwrap (Stream.closeRead r2);
  unwrap result.
execute argv = case argv of
  [needle, path] -> scan needle path 1048576
| [needle, path, limit] -> scan needle path (parseInt limit)
| _ -> error "usage: filter-stream.sol NEEDLE PATH [MAX_LINE_BYTES]".
> execute (args Unit).
