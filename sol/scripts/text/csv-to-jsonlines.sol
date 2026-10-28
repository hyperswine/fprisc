# Stream CSV records to JSON arrays, publishing only after complete validation.
# fpr sol sol/scripts/text/csv-to-jsonlines.sol SOURCE DESTINATION [--replace]
J = use "../../lib/json".
emit writer row =
  bytes = unwrap (Utf8.encode "{J.render (J.strs row)}\n");
  (written,writer2) = Stream.writeChunk bytes writer;
  u = unwrap written;
  writer2.
convert source target replace =
  scratch = tempDir "csv-json";
  stage = "{scratch}/result";
  reader = unwrap (Stream.openRead source 65536);
  writer = unwrap (Stream.openWrite stage 1048576);
  (result,reader2) = Stream.foldCsv emit writer 1024 65536 65536 reader;
  u = unwrap (Stream.closeRead reader2);
  writer2 = unwrap result;
  closed = unwrap (Stream.closeWrite writer2);
  case Fs.copyPublishNow stage target 65536 replace of Ok n -> Unit | Err e -> error (str e).
main = case args Unit of
  [source,target] -> convert source target False
| [source,target,"--replace"] -> convert source target True
| _ -> error "usage: csv-to-jsonlines.sol SOURCE DESTINATION [--replace]".
