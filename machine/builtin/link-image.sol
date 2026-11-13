# Stage outputs beside the final ELF so publication uses same-filesystem renames.
B = use "../../sol/lib/build".
commands : unsafe List (List String) -> Result Unit String .
commands steps = case steps of
    [] -> Ok Unit
  | argv :: rest -> (case Proc.streamNow (ProcessSpec argv "" [] "" 0) of
      Ok 0 -> commands rest
    | Ok code -> Err "exit {code}: {argv}"
    | Err why -> Err why).
link : unsafe String -> String -> String -> String -> String -> String -> String -> String -> String -> List String -> Unit .
link image binary directory board cross manifest target entries assembly flags =
  units = Str.lines (readPath "{assembly}.units");
  inputs = List.concat (List.map (fn arg -> if arg == "--fpr-units" then units else [arg]) flags);
  scratch = B.query ["mktemp","-d","{directory}.fpr-image.XXXXXX"];
  elf = "{scratch}/image.elf"; report = "{scratch}/image.json"; raw = "{scratch}/image.bin";
  reloc = (if board == "tangnano20k" then [["{cross}objcopy","-O","binary",elf,raw],["{cross}size",elf],["mv",raw,binary]] else []);
  check = (if entries == "" then [B.setting "SOL" "sol","tools/target-image.sol"] else
    ["python3","tools/check_target_image.py","--stack-entries",entries]);
  result = commands ([["{cross}gcc"] + inputs + ["-o",elf],
    check + ["--image",elf,"--manifest",manifest,"--target",target,"--report",report]]
    + reloc + [["mv",report,"{image}.admission.json"],["mv",elf,image]]);
  _ = B.command ["rm","-rf",scratch];
  case result of Ok u -> u | Err why -> error why.
main : unsafe Unit -> Unit .
> case args Unit of image :: binary :: directory :: board :: cross :: manifest :: target :: entries :: assembly :: flags ->
    link image binary directory board cross manifest target entries assembly flags
  | _ -> error "missing builtin image link arguments".
