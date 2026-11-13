B = use "../sol/lib/build".
systemLibrary path = Str.startsWith "/usr/lib/" path or Str.startsWith "/System/" path.
base path = List.last (Str.split 47 path).
parent path = parts = Str.split 47 path; dir = Str.join "/" (List.take (List.len parts - 1) parts); if dir == "" then "/" else dir.
trimNewline out = if Str.endsWith "\n" out then substr out 0 (Str.len out - 1) else out.
isImage path =
  reader = unwrap (Stream.openRead path 4);
  (read,next) = Stream.readChunk reader;
  _ = unwrap (Stream.closeRead next);
  case unwrap read of EndBytes -> False | ChunkBytes bytes ->
    List.has (Hex.encode bytes) ["cffaedfe","cefaedfe","feedfacf","feedface","cafebabe","bebafeca","cafebabf","bfbafeca"].
architectures path = Str.words (B.query ["lipo","-archs",path]).
otool arch flag path = List.drop 1 (Str.lines (B.query ["otool","-arch",arch,flag,path])).
dependencies arch path =
  ids = List.map Str.trim (otool arch "-D" path);
  rows = List.map (fn line -> entry = Str.trim line; n = Str.indexOf " (compatibility" entry;
    if n < 0 then entry else substr entry 0 n) (otool arch "-L" path);
  List.filter (fn dep -> dep != "" and not (List.has dep ids)) rows.
rpaths arch path =
  (_,paths) = List.fold (fn state raw ->
    (pending,found) = state;
    line = Str.trim raw;
    if Str.startsWith "cmd " line then (line == "cmd LC_RPATH",found)
    else if pending and Str.startsWith "path " line then
      end = Str.indexOf " (offset " line;
      if end < 5 then error "invalid LC_RPATH in {path}: {line}" else (False,substr line 5 (end - 5) :: found)
    else (pending,found)) (False,[]) (otool arch "-l" path);
  List.rev paths.
