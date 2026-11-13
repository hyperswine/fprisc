# Physical image and exact linked stack gate, including every requested entry.
F = use "toolchain-files".
T = use "target-image-core".
RV = use "linked-rv64".
J = use "../sol/lib/json".
CLI = use "../sol/lib/cli".
M = use "../std/map".
entry spec = case List.rev (Str.split 58 spec) of
    size :: rest ->
      name = Str.join ":" (List.rev rest);
      _ = RV.require (name != "" and size != "" and List.all (fn c -> c >= 48 and c <= 57) (Str.codes size)) "entry must be symbol:positive-bytes";
      (name,Str.parse size)
  | _ -> error "entry must be symbol:positive-bytes".
main : unsafe Unit -> Unit .
> parsed = unwrap (CLI.parse (List.map (fn k -> CLI.Option k "" CLI.One) ["image","manifest","target","report","stack-entries"]) (args Unit));
  opt k = CLI.valueOr "" k parsed;
  bytes = F.readBytes (opt "image");
  physical = T.admit bytes (F.readBytes (opt "manifest")) (opt "target");
  img = RV.image bytes;
  entries = List.map entry (Str.words (Str.replace "," " " (opt "stack-entries")));
  names = List.map (fn p -> (name,_) = p; name) entries;
  _ = RV.require (entries != [] and List.len (List.fold (fn xs name -> if List.has name xs then xs else name::xs) [] names) == List.len names) "missing/duplicate stack entries";
  reports = List.map (fn pair -> (name,limit) = pair;
    _ = RV.require (M.member name img.symbols) "missing stack entry: {name}";
    RV.stackReport img physical name limit) entries;
  rows = List.concat (List.map (fn report -> unwrap (J.get "entries" report |>? J.items)) reports);
  functions = List.concat (List.map (fn report -> unwrap (J.get "functions" report |>? J.items)) reports);
  unique = List.fold (fn map row -> M.insert (unwrap (J.get "address" row |>? J.num)) row map) M.ints functions;
  proof = J.set "entries" (J.JArr rows) (J.set "functions" (J.JArr (List.map (fn pair -> (_,row) = pair; row) (M.entries unique))) (reports ! 0));
  result = J.set "schema" (J.JNum 3) (J.set "linked_stack" proof physical);
  if opt "report" == "" then print (J.render result) else writePath (opt "report") (J.pretty result+"\n").
