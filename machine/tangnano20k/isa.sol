B = use "../../sol/lib/build".
CLI = use "../../sol/lib/cli".
digits word = word != "" and List.all (fn c -> c >= 48 and c <= 57) (Str.codes word).
extension name token =
  if not (Str.startsWith name token) then False else
    version = Str.slice token (Str.len name) (Str.len token);
    case Str.split 112 version of [a,b] -> version == a + "p" + b and digits a and digits b | _ -> False.
value line = Str.trim (Str.slice line (Str.find 58 line + 1) (Str.len line)).
field label lines = case List.filter (Str.startsWith label) lines of
    line :: _ -> value line | [] -> error "missing {label} in ELF attributes".
verify report xlen compressed =
  _ = (if List.has xlen ["32","64"] then Unit else error "board XLEN must be 32 or 64");
  _ = (if Str.contains "ELF{xlen}" report and Str.contains "little endian" report then Unit else error "board requires a little-endian ELF{xlen} image");
  lines = List.map Str.trim (Str.lines report);
  flags = (Str.split 44 (field "Flags:" lines)) ! 0;
  bits = Str.slice flags 2 (Str.len flags);
  valid = Str.startsWith "0x" flags and bits != "" and List.all (fn c -> c == 48) (Str.codes (Str.slice bits 0 (Str.len bits - 1)));
  _ = (if valid and (Str.endsWith "0" bits or (compressed and Str.endsWith "1" bits)) then Unit
    else error "board requires a soft-float ABI and explicitly selected compressed instructions");
  arch = field "Tag_RISCV_arch:" lines;
  _ = (if Str.startsWith "\"" arch and Str.endsWith "\"" arch then Unit else error "invalid ELF architecture attribute");
  text = substr arch 1 (Str.len arch - 2);
  items = Str.split 95 text;
  allowed = List.append ["rv{xlen}i","m","zicsr","zifencei","zmmul"] (if compressed then ["c"] else []);
  _ = List.map (fn item -> if List.any (fn name -> extension name item) allowed then Unit else error "unsupported board ISA extension: {item}") items;
  if items != [] and Str.join "_" items == text and extension "rv{xlen}i" (items ! 0) and List.any (extension "m") items then Unit
  else error "board image must declare RV{xlen}IM".
check image xlen compressed = verify (B.query ["riscv64-unknown-elf-readelf","-Ah",image]) xlen compressed.
> parsed = unwrap (CLI.parse [CLI.Option "xlen" "" CLI.One,CLI.Option "compressed" "" CLI.Switch,CLI.Option "report" "" CLI.Switch] (args Unit));
  xlen = CLI.valueOr "64" "xlen" parsed;
  compressed = CLI.flag "compressed" parsed;
  case CLI.operands parsed of [path] ->
    _ = (if CLI.flag "report" parsed then verify (readPath path) xlen compressed else check path xlen compressed);
    print "PASS: linked ELF uses the selected RV{xlen}IM/IMC soft-float ABI; no A/F/D libraries"
  | _ -> error "expected IMAGE [--xlen 32|64] [--compressed]".
