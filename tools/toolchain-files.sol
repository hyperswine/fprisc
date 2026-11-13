# Use NUL delimiters for filenames, and order by path component for manifest parity.
canonical path =
  ProcessResult status out err = unwrap (Proc.runNow (ProcessSpec ["realpath",path] "" [] "" 0));
  if status == 0 and Str.endsWith "\n" out then substr out 0 (Str.len out - 1) else error "cannot resolve {path}: {err}".
# SDKs, GHC documentation and package caches can all be read-only. Streams
# leave no transaction lock alongside an input.
readBytes path =
  reader = unwrap (Stream.openRead path 65536);
  (result,next) = Stream.foldChunks (fn acc b -> b :: acc) [] reader;
  _ = unwrap (Stream.closeRead next);
  Bytes.concat (List.rev (unwrap result)).
readText path = unwrap (Utf8.decode (readBytes (canonical path))).
key path = Hex.encode (unwrap (Utf8.encode (Str.replace "/" (Str.fromCode 0) path))).
fromKey text = Str.replace (Str.fromCode 0) "/" (unwrap (Utf8.decode (unwrap (Hex.decode text)))).
ordered names =
  ProcessResult status sorted why = unwrap (Proc.runNow (ProcessSpec ["sort"] "" [("LC_ALL","C")] (Str.join "\n" (List.map key names)) 0));
  if status != 0 then error "sorting toolchain paths failed: {why}" else
    List.map fromKey (List.filter (fn s -> s != "") (Str.split 10 sorted)).
files prefix =
  ProcessResult code paths err = unwrap (Proc.runNow (ProcessSpec ["find",".","-type","f","-print0"] prefix [] "" 0));
  if code != 0 then error "listing {prefix} failed: {err}" else
    ordered (List.map (fn p -> substr p 2 (Str.len p - 2)) (List.filter (fn p -> p != "") (Str.split 0 paths))).
