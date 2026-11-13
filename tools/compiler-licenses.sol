# Collect binary notices from the GHC docs or the installed Cabal source cache.
B = use "../sol/lib/build".
CLI = use "../sol/lib/cli".
J = use "../sol/lib/json".
M = use "toolchain-macho".
F = use "toolchain-files".
textField row k = unwrap (J.get k row |>? J.text).
children dir =
  if not (B.exists "-d" dir) then [] else
    ProcessResult status out err = unwrap (Proc.runNow (ProcessSpec ["find",".","-mindepth","1","-maxdepth","1","-print0"] dir [] "" 0));
    if status != 0 then error "listing {dir} failed: {err}" else F.ordered (List.map M.base (List.filter (fn s -> s != "") (Str.split 0 out))).
safeComponent s = s != "" and s != "." and s != ".." and not (Str.contains "/" s) and not (Str.contains (Str.fromCode 0) s).
docGroup docs label section =
  dir = "{docs}/{section}/{label}";
  List.map (fn name -> (name,F.readBytes (F.canonical "{dir}/{name}"))) (List.filter (fn n -> Str.startsWith "LICENSE" n) (children dir)).
documentNotices docs label = List.concat (List.map (docGroup docs label) (children docs)).
# bsdtar selects notice members and streams them into a newc archive. Reading
# its length-delimited records retains tar order and repeated basenames without
# extracting paths or interpreting file contents as text.
ascii bytes start count = unwrap (Utf8.decode (unwrap (Bytes.slice start count bytes))).
hexField data offset = List.fold (fn n byte -> n * 256 + byte) 0 (Bytes.toList (unwrap (Hex.decode (ascii data offset 8)))).
align4 n = (n + 3) / 4 * 4.
members : unsafe Bytes -> Int -> List (String,Bytes) .
members data pos =
  if ascii data pos 6 != "070701" then error "invalid newc archive header" else
    mode = hexField data (pos + 14);
    size = hexField data (pos + 54);
    namesize = hexField data (pos + 94);
    name = ascii data (pos + 110) (namesize - 1);
    if name == "TRAILER!!!" then [] else
      start = align4 (pos + 110 + namesize);
      rest = members data (align4 (start + size));
      if mode / 4096 == 8 then (M.base name,unwrap (Bytes.slice start size data)) :: rest else rest.
archiveNotices : unsafe String -> List (String,Bytes) .
archiveNotices source =
  if not (B.exists "-f" source) then [] else
    work = tempDir "fpr-licenses";
    filtered = "{work}/notices.cpio";
    patterns = ["[Ll][Ii][Cc][Ee][Nn][Ss][Ee]*","[Cc][Oo][Pp][Yy][Ii][Nn][Gg]*"];
    options = List.concat (List.map (fn p -> ["--include",p,"--include","*/" + p]) patterns);
    _ = B.command (List.concat [["bsdtar","-cf",filtered,"--format=newc"],options,["@" + source]]);
    members (F.readBytes filtered) 0.
writeNotice output label index pair =
  (filename,bytes) = pair;
  relative = "{label}/{index}-{filename}";
  writer = unwrap (Stream.openWrite "{output}/{relative}" 65536);
  (result,next) = Stream.writeChunk bytes writer;
  _ = unwrap (Stream.closeWrite next);
  _ = unwrap result;
  (relative,J.JStr (Hex.encode (Sha256.bytes bytes))).
collectPackage : unsafe String -> String -> String -> String -> String -> List (String,J.Json) .
collectPackage docs cache output ghc key =
  (name,version) = case Str.split 47 key of [n,v] -> (n,v) | _ -> error "invalid Cabal package {key}";
  label = "{name}-{version}";
  doc = documentNotices docs (if name == "rts" then "ghc-{ghc}" else label);
  texts = if doc == [] then archiveNotices "{cache}/packages/hackage.haskell.org/{name}/{version}/{label}.tar.gz" else doc;
  if texts == [] then error "no license notice for {label}; prepare the matching GHC docs/source cache" else
    _ = B.command ["mkdir","{output}/{label}"];
    (_,entries) = List.fold (fn state item -> (i,acc) = state; (i + 1,writeNotice output label i item :: acc)) (0,[]) texts;
    List.rev entries.
packageKey row =
  name = textField row "pkg-name";
  version = textField row "pkg-version";
  if safeComponent name and safeComponent version then "{name}/{version}" else error "invalid Cabal package name or version".
collectNotices : unsafe String -> String -> Unit .
collectNotices planPath output =
  plan = unwrap (J.parse (F.readText planPath));
  compiler = textField plan "compiler-id";
  ghc = if Str.startsWith "ghc-" compiler then Str.slice compiler 4 (Str.len compiler) else compiler;
  libdir = B.query ["ghc","--print-libdir"];
  if not (safeComponent ghc and Str.contains ghc libdir) then error "selected GHC differs from the compiler plan" else
    docs = M.parent (M.parent (M.parent libdir)) + "/share/doc";
    cache = B.query ["cabal","path","--cache-home"];
    _ = B.command ["mkdir","-p",M.parent output];
    _ = B.command ["mkdir",output];
    keys = List.map packageKey (unwrap (J.get "install-plan" plan |>? J.items));
    packages = F.ordered (List.fold (fn acc k -> if Str.startsWith "fp-risc/" k or List.has k acc then acc else k :: acc) [] keys);
    entries = List.concat (List.map (collectPackage docs cache output ghc) packages);
    _ = writePath "{output}/manifest.json" (J.pretty (J.JObj [("compiler",J.JStr compiler),("notices",J.JObj entries)]) + "\n");
    print "Collected notices for {List.len packages} packages in {output}".
main : unsafe Unit -> Unit .
> parsed = unwrap (CLI.parse [CLI.Option "plan" "" CLI.One,CLI.Option "output" "" CLI.One] (args Unit));
  plan = CLI.valueOr "" "plan" parsed;
  output = CLI.valueOr "" "output" parsed;
  if plan == "" or output == "" or CLI.operands parsed != [] then error "expected --plan CABAL_PLAN --output DIRECTORY" else
    collectNotices plan (if Str.startsWith "/" output then output else unwrap (IO.cwd Unit) + "/" + output).
