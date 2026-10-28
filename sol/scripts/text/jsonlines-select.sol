# Select JSON objects by a string field; malformed/schema errors abort publication.
# fpr sol sol/scripts/text/jsonlines-select.sol FIELD VALUE SOURCE DESTINATION [--replace]
J = use "../../lib/json".
limits = J.Limits 65536 64 1024 65536.
emit key wanted writer line =
  value = unwrap (J.parseLineWith limits line);
  text = unwrap (J.get key value |>? J.text);
  case text == wanted of
    False -> writer
  | True -> bytes = unwrap (Utf8.encode "{J.render value}\n");
            (written,writer2) = Stream.writeChunk bytes writer;
            u = unwrap written; writer2.
select key wanted source target replace =
  scratch = tempDir "jsonlines";
  stage = "{scratch}/result";
  reader = unwrap (Stream.openRead source 65536);
  writer = unwrap (Stream.openWrite stage 1048576);
  (result,reader2) = Stream.foldLines (emit key wanted) writer 65536 reader;
  u = unwrap (Stream.closeRead reader2);
  writer2 = unwrap result;
  closed = unwrap (Stream.closeWrite writer2);
  case Fs.copyPublishNow stage target 65536 replace of Ok n -> Unit | Err e -> error (str e).
main = case args Unit of
  [key,wanted,source,target] -> select key wanted source target False
| [key,wanted,source,target,"--replace"] -> select key wanted source target True
| _ -> error "usage: jsonlines-select.sol FIELD VALUE SOURCE DESTINATION [--replace]".
