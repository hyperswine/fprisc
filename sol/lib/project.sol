# sol/lib/project.sol -- Shared project build, test, and evidence-reporting harness.
#
#   C = use "sol/lib/project".
#
# Provides structured subprocess execution (`command`, `observe`, `live`),
# immediate file/JSON I/O (`readBytesNow`, `writeBytesNow`, `writeText`, `report`),
# assertion helpers (`need`, `check`, `passed`, `hasAny`), and standard project
# layout initialization (`setup`, `setupDirs`).

P = use "sol/lib/proc".
J = use "std/jsondoc".

need r = case r of Ok x -> x | Err why -> error "{why}".
check why yes = if yes then Unit else error why.
passed name = _ = print "PASS  {name}"; name.
hasAny words text = List.any (fn word -> Str.contains (Str.lower word) (Str.lower text)) words.

command argv = need (P.output (Proc.runNow (P.withTimeout 900000 (P.spec argv)))).
observe argv = need (Proc.runNow (P.withTimeout 900000 (P.spec argv))).
live argv =
  code = need (Proc.inheritNow (P.spec argv));
  _ = check "process exited {code}" (code == 0);
  code.

readBytesNow path =
  r = need (Stream.openRead path 65536);
  (result, r2) = Stream.foldChunks (fn acc b -> b :: acc) [] r;
  _ = need (Stream.closeRead r2);
  Bytes.concat (List.rev (need result)).

writeBytesNow path bytes =
  scratch = tempDir "project-write";
  w = need (Stream.openWrite "{scratch}/bytes" 16777216);
  (result, w2) = Stream.writeChunk bytes w;
  _ = need (Stream.closeWrite w2);
  _ = need result;
  _ = need (Fs.copyPublishNow "{scratch}/bytes" path 65536 True);
  Unit.

writeText path text = writeBytesNow path (need (Utf8.encode text)).
report path value = writeText path "{J.pretty value}\n".

setupDirs dirs =
  _ = command (["/bin/mkdir", "-p"] + dirs);
  root = need (IO.cwd Unit);
  _ = need (Env.set "XDG_CACHE_HOME" "{root}/.cache");
  Unit.

setup u = setupDirs ["build", ".cache", "data", "evidence"].
