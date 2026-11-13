Core = use "target-image-core".
F = use "toolchain-files".
J = use "../sol/lib/json".
CLI = use "../sol/lib/cli".
main : unsafe Unit -> Unit .
> parsed = unwrap (CLI.parse (List.map (fn k -> CLI.Option k "" CLI.One) ["image","manifest","target","report"]) (args Unit));
  get k = CLI.valueOr "" k parsed;
  if get "image" == "" or get "manifest" == "" or CLI.operands parsed != [] then error "expected --image ELF --manifest JSON [--target ID] [--report PATH]" else
    receipt = Core.admit (F.readBytes (F.canonical (get "image"))) (F.readBytes (F.canonical (get "manifest"))) (get "target");
    if get "report" == "" then print (J.render receipt) else
      _ = writePath (get "report") (J.pretty receipt + "\n");
      field k = unwrap (J.get k receipt |>? J.num);
      print ("target image admitted: " + unwrap (J.get "target" receipt |>? J.text) + ": {field "image_bytes"}/{field "image_limit_bytes"} load bytes; {field "remaining_ram_bytes"} RAM bytes after load segments").
