# The FP-RISC example suite, or one program, on a Simple-Risc board or in QEMU.
# A Sol port of the retired tools/run_tangnano20k_examples.py,
# tools/run_tangnano20k_base.py and tests/check_tangnano20k_dtree.py (legacy
# scripts release, 2026-11-13). From the repository root:
#
#   ./fpr sol machine/tangnano20k/examples.sol [--target qemu|board] [--preset NAME]
#       [--cases hello,numeric,...] [--timeout SECONDS] [--out DIR]
#       [--fpga-manifest PATH] [--port DEVICE] [--settle SECONDS] [--loader PATH]
#       [--skip-compiler-build]
#   ./fpr sol machine/tangnano20k/examples.sol --program FILE.fpr [--arg A]...
#       [--input LINE]... [--env NAME=VALUE]... [--root DIR] [...as above]
#
# Presets: fprisc-48 (default), fprisc-72, fprisc-81, fprisc-84 on the Tang Nano
# 20K (manifests from simple-risc boards/tangnano20k/sdram), and arty-s7-81, the
# fprisc-81 core on the Arty S7-50 with DDR3 (simple-risc boards/artys7/pipeline).
# The board target needs --fpga-manifest from the matching preset build; it checks
# the manifest and its artifact hashes, programs the bitstream into FPGA SRAM
# (never flash or the SD card) and checks the ROM identity against it. QEMU checks
# software only. The serial port, ROM upload and the guest's UART virtual device
# are machine/tangnano20k/board-host.sol, run with the same Sol.
# Writes OUT/results.json (default build/tangnano20k-examples/TARGET); a failed or
# interrupted run leaves passed=false there.
unsafe program.
B = use "../../sol/lib/build".
CLI = use "../../sol/lib/cli".
J = use "std/jsondoc".
D = use "../../sol/lib/digest".

suite = ["hello","numeric","collections","host","args","wc","classifier"].
source name = case name of
    "hello" -> "examples/tangnano20k_hello.fpr"
  | "numeric" -> "tests/tangnano20k_rv32_numeric.fpr"
  | "collections" -> "tests/base/vecshape.fpr"
  | "host" -> "tests/tangnano20k_rv32_host.fpr"
  | "args" -> "tests/tangnano20k_args.fpr"
  | "wc" -> "examples/wc.fpr"
  | _ -> error "no source for case {name}".
expectedLine name = case name of
    "hello" -> "SimpleRisc: factorial(6)=720"
  | "numeric" -> "RV32 BASE NUMERIC HOLDS"
  | "collections" -> "vecshape: two=1149000 four=2498000 in place=True"
  | "host" -> "RV32 BASE HOST HOLDS"
  | _ -> "".
programArguments = ["","two words","-n","雪","quote\"slash\\"].

# ---- presets: simple-risc's preset manifests, field for field ----------------
num n = J.JNum n.
yes b = J.JBool b.
tangShape mhz compressed ways lineBits placement = [("xlen",num 32),("compressed",yes compressed),("cpu_mhz",num mhz),
  ("memory_mhz",num 48),("ram_bytes",num 8388608),("cache_bytes",num 65536),("cache_ways",num ways),
  ("cache_line_bits",num lineBits),("phase_degrees",num 135),("placement",num placement),("write_update",yes True)].
floorplanned target = [("placer_target_mhz",num target),("map_option",num 3),("route_option",num 1),
  ("route_maxfan",num 8),("floorplan",J.JStr "fprisc-81.plan")].
config preset = case preset of
    "fprisc-48" -> J.JObj (tangShape 48 True 1 12 2)
  | "fprisc-72" -> J.JObj (List.append (tangShape 72 True 2 11 3) (floorplanned 79))
  | "fprisc-81" -> J.JObj (List.append (tangShape 81 False 2 11 3) (floorplanned 89))
  | "fprisc-84" -> J.JObj (List.append (tangShape 84 False 2 11 3) (floorplanned 92))
  | "arty-s7-81" -> J.JObj [("xlen",num 32),("compressed",yes False),("cpu_mhz",num 81),("memory_mhz",num 80),
      ("ram_bytes",num 8388608),("cache_bytes",num 65536),("cache_ways",num 2),("cache_line_bits",num 11),
      ("memory",J.JStr "ddr3-litedram"),("synthesis",J.JStr "yosys-nosrl")]
  | _ -> error "unknown preset {preset} (fprisc-48, fprisc-72, fprisc-81, fprisc-84, arty-s7-81)".
field key j = unwrap (J.get key j).
presetMhz preset = unwrap (J.num (field "cpu_mhz" (config preset))).
presetMemMhz preset = unwrap (J.num (field "memory_mhz" (config preset))).
presetCompressed preset = unwrap (J.bool (field "compressed" (config preset))).
arty preset = Str.startsWith "arty-s7-" preset.
# (openFPGALoader board, bitstream, timing evidence, default port, settle seconds)
boardOf preset = if arty preset
  then ("arty_s7_50","top.bit","nextpnr.log","/dev/cu.usbserial-210352B840A31","1")
  else ("tangnano20k","impl/pnr/sdram_test.fs","impl/pnr/sdram_test.tr","/dev/cu.usbserial-20250303171","0").
loaderBoard (b,_,_,_,_) = b.
bitstreamName (_,b,_,_,_) = b.
timingName (_,_,t,_,_) = t.
defaultPort (_,_,_,p,_) = p.
defaultSettle (_,_,_,_,s) = s.

# ---- small helpers -----------------------------------------------------------
# The programmer behind a board's UART: both bridges are FTDI-style 0403:6010
# devices whose UART is /dev/cu.usbserial-<serial><interface>, so with two
# boards attached the loader is pointed at this board's serial, not the first.
ftdiSerial port =
  at = Str.indexOf "usbserial-" port;
  if at < 0 then [] else
    rest = Str.slice port (at + 10) (Str.len port);
    if Str.len rest < 2 then [] else ["--ftdi-serial",Str.slice rest 0 (Str.len rest - 1)].
# lands now and replaces what was there (the report is rewritten as cases finish)
writeStreamed path content = writeNow path content.
tailOf n s = Str.slice s (Numeric.max 0 (Str.len s - n)) (Str.len s).
decode bytes = case Utf8.decode bytes of Ok s -> s | Err _ -> "<output is not UTF-8>".
count line lines = List.len (List.filter (fn l -> l == line) lines).
insert : unsafe String -> List String -> List String.
insert x xs = case xs of [] -> [x] | y :: rest -> if Str.cmp x y <= 0 then x :: xs else y :: insert x rest.
sorted xs = List.fold (fn acc x -> insert x acc) [] xs.
# A configuration compared independently of key order.
canon j = case j of
    J.JObj kvs -> Str.join "," (sorted (List.map (fn kv -> (k,v) = kv; "{k}={J.render v}") kvs))
  | _ -> J.render j.
dirOf path = parts = Str.split 47 path; Str.join "/" (List.take (List.len parts - 1) parts).
hexDigit c = if c >= 48 and c <= 57 then c - 48 else if c >= 97 and c <= 102 then c - 87 else error "bad hex digit".
hex s = List.fold (fn acc c -> acc * 16 + hexDigit c) 0 (Str.codes s).
padLeft : unsafe Int -> String -> String.
padLeft w s = if Str.len s >= w then s else padLeft w " {s}".
seconds u = parseInt (B.query ["date","+%s"]).
solCommand u = case unwrap (Env.get "SOL") of
    EnvText path -> if path == "" then ["./fpr","sol"] else [path]
  | EnvMissing -> ["./fpr","sol"].

# ---- the report: written now, so a failure leaves passed=false behind -------
save out rep = writeStreamed "{out}/results.json" (J.pretty rep + "\n").
fail out rep message = _ = save out (J.set "error" (J.JStr message) rep); error message.
addCase rep c = J.set "cases" (J.JArr (List.append (unwrap (J.items (field "cases" rep))) [c])) rep.
setLastCase rep c = items = unwrap (J.items (field "cases" rep));
  J.set "cases" (J.JArr (List.append (List.take (List.len items - 1) items) [c])) rep.

# Runs argv with extra environment; the log gets stdout then stderr. Returns stdout.
runLogged env argv log limit =
  stage = ProcessSpec argv "" env "" 0;
  spec = PipelineSpec [stage] (PipeBytes (Bytes.empty Unit)) (PipeCapture 16777216) (PipeCapture 16777216) (limit * 1000) PipeFail;
  case Proc.pipeline spec of
    Ok (PipelineResult code _ out errs) ->
      stdout = decode out; stderr = decode (Bytes.concat errs);
      _ = writeStreamed log (stdout + stderr);
      if code == 0 then Ok stdout else Err "command failed (exit {code}); see {log}\n{tailOf 2000 (stdout + stderr)}"
  | Err why -> _ = writeStreamed log "{why}\n"; Err "{argv}: {why}; see {log}".
must out rep r = case r of Ok x -> x | Err e -> fail out rep e.

# ---- the FPGA manifest -------------------------------------------------------
# Manifests from before cache geometry was explicit describe the validated
# one-way, 4096-line fprisc-48 preset: only that complete legacy shape is filled in.
legacyGeometry preset c = case c of
    J.JObj kvs -> if preset == "fprisc-48" and not (List.any (fn kv -> (k,_) = kv; k == "cache_ways" or k == "cache_line_bits") kvs)
      then J.JObj (List.append kvs [("cache_ways",num 1),("cache_line_bits",num 12)]) else c
  | _ -> c.
safeName name = name != "" and not (Str.startsWith "/" name) and not (List.has ".." (Str.split 47 name)).
checkArtifact out rep dir pair = (name, digest) = pair;
  _ = (if safeName name then Unit else fail out rep "FPGA artifact escapes the build directory: {name}");
  want = unwrap (J.text digest);
  got = unwrap (D.sha256File "{dir}/{name}");
  if got == want then Unit else fail out rep "FPGA artifact hash mismatch: {name}".
fpgaImage out rep manifestPath preset =
  path = B.query ["realpath",manifestPath];
  dir = dirOf path;
  report = unwrap (J.parse (readPath path));
  presetName = case J.get "preset" report of Ok (J.JStr p) -> p | _ -> "";
  ready = case J.get "ready" report of Ok (J.JBool b) -> b | _ -> False;
  _ = (if presetName == preset and ready then Unit else fail out rep "FPGA manifest must be a completed {preset} build");
  got = legacyGeometry preset (case J.get "configuration" report of Ok c -> c | Err _ -> J.JNull);
  _ = (if canon got == canon (config preset) then Unit else fail out rep "FPGA preset configuration mismatch");
  artifacts = case J.get "artifacts" report of Ok (J.JObj kvs) -> kvs | _ -> [];
  board = boardOf preset;
  names = List.map (fn kv -> (k,_) = kv; k) artifacts;
  _ = (if List.has (bitstreamName board) names and List.has (timingName board) names then Unit
       else fail out rep "FPGA manifest lacks the bitstream or its checked timing report");
  _ = List.map (checkArtifact out rep dir) artifacts;
  buildId = case J.path ["rom_identity","build_id"] report of Ok (J.JStr id) -> id | _ -> "";
  ("{dir}/{bitstreamName board}", report, buildId).

# ---- one guest run -----------------------------------------------------------
guestOptions o files arguments inputs env =
  List.concat [["--root",files,"--timeout","{o.timeout}"],
    List.map (fn a -> "--arg={a}") arguments, List.map (fn l -> "--input={l}") inputs,
    List.map (fn kv -> (k,v) = kv; "--env={k}={v}") env].
executeGuest o out rep dir files arguments inputs env =
  log = "{dir}/run.log";
  if o.target == "qemu" then
    must out rep (runLogged [] (List.concat [o.helper,["qemu","{dir}/base.elf","--xlen","32"],guestOptions o files arguments inputs env]) log (o.timeout + 30))
  else
    bin = "{dir}/base.bin";
    size = parseInt (B.query ["stat","-f","%z",bin]);
    upload = size * 8680 / (o.mhz * 1000000) + 1;
    board = List.append o.helper ["board",bin,"--port",o.port,"--mhz","{o.mhz}","--settle",o.settle,
      "--isa",(if o.compressed then "rv32imc" else "rv32im"),"--mem-mhz","{o.memMhz}"];
    identity = if o.buildId == "" then [] else ["--build-id",o.buildId];
    output = must out rep (runLogged [] (List.concat [board,identity,guestOptions o files arguments inputs env]) log (o.timeout + 60 + upload));
    if Str.endsWith "DONE" (Str.trim output) then output else fail out rep "board did not return to the loader".

checkCase out rep name output files =
  lines = Str.lines output;
  _ = (if count "FPR EXIT 0" lines == 1 and count "FPR EXIT 1" lines == 0 then Unit
       else fail out rep "{name}: expected exactly one successful runtime exit");
  want = expectedLine name;
  _ = (if want == "" or count want lines == 1 then Unit else fail out rep "{name}: missing or duplicated expected output");
  _ = (if name != "host" or readPath "{files}/output.txt" == "RV32 UART + append" then Unit
       else fail out rep "host file content mismatch");
  argLines = List.filter (Str.startsWith "ARG ") lines;
  wantArgs = List.map (fn a -> "ARG {Bytes.len (unwrap (Utf8.encode a))}:{a}") programArguments;
  _ = (if name != "args" or (argLines == wantArgs and count "ARGS count=5" lines == 1) then Unit
       else fail out rep "argument content, order or count mismatch");
  wc = List.filter (fn l -> Str.endsWith " words.txt" l or Str.endsWith " two words.txt" l) lines;
  wantWc = ["{padLeft 8 "2"}{padLeft 8 "3"}{padLeft 9 "17"} words.txt","{padLeft 8 "1"}{padLeft 8 "2"}{padLeft 9 "11"} two words.txt"];
  if name != "wc" or wc == wantWc then Unit else fail out rep "wc result mismatch: {wc}".

buildImage o out rep prog dir =
  _ = B.command ["mkdir","-p",dir];
  _ = must out rep (runLogged o.env (List.append o.sol ["machine/tangnano20k/build.sol",prog,dir]) "{dir}/build.log" 900);
  unwrap (J.parse (readPath "{dir}/build-manifest.json")).

runCase o out rep name =
  dir = "{out}/{name}";
  started = seconds Unit;
  rep1 = addCase rep (J.JObj [("name",J.JStr name),("passed",J.JBool False)]);
  _ = save out rep1;
  _ = print "{name}: building/running ({o.target}, {o.preset})";
  detail = if name == "classifier" then classifier o out rep1 dir else
    build = buildImage o out rep1 (source name) dir;
    files = "{dir}/files";
    _ = B.command ["mkdir","-p",files];
    _ = (if name == "host" then B.command ["rm","-f","{files}/output.txt"] else Unit);
    _ = (if name == "wc" then _ = writeStreamed "{files}/words.txt" "alpha beta\ngamma\n"; writeStreamed "{files}/two words.txt" "delta zeta\n" else Unit);
    arguments = if name == "args" then programArguments else if name == "wc" then ["words.txt","two words.txt"] else [];
    output = executeGuest o out rep1 dir files arguments ["hello RV32"] [("TEST_UART","connected")];
    _ = checkCase out rep1 name output files;
    [("build",build)];
  rep2 = setLastCase rep1 (J.JObj (List.concat [[("name",J.JStr name),("passed",J.JBool True)],detail,
    [("wall_seconds",num (seconds Unit - started))]]));
  _ = save out rep2;
  _ = print "{name}: PASS";
  rep2.

# ---- the decision-tree classifier ---------------------------------------------
symbolAt lines name = case List.filter (fn l -> Str.endsWith " {name}" l) lines of
    l :: _ -> hex (Str.slice l 0 (Str.find 32 l))
  | [] -> error "symbol {name} missing from the classifier image".
heapBudget dir =
  lines = Str.lines (B.query ["riscv64-unknown-elf-nm","{dir}/base.elf"]);
  low = (symbolAt lines "_heap_start" + 15) / 16 * 16;
  high = symbolAt lines "_heap_end" / 16 * 16;
  bitmap = (((high - low) / 16 + 7) / 8 + 15) / 16 * 16;
  [("image_bytes",num (parseInt (B.query ["stat","-f","%z","{dir}/base.bin"]))),("heap_arena_bytes",num (high - low)),
   ("heap_bitmap_bytes",num bitmap),("usable_heap_block_bytes",num (high - low - bitmap)),
   ("stack_bytes",num (symbolAt lines "_stack_top" - symbolAt lines "_heap_end"))].
classifierCall = "run 512 128 16 6 5".
fixture root = text = readPath "tests/tangnano20k_dtree.fpr";
  _ = (if Str.contains "D = use \"dtree\"." text and Str.contains "main = {classifierCall}." text then Unit
       else error "tests/tangnano20k_dtree.fpr no longer has the expected `D = use` and `main = {classifierCall}.` lines");
  repeated = "main = repeatRuns 10.\nrepeatRuns : unsafe Int -> Unit .\nrepeatRuns 0 = Unit.\nrepeatRuns n = _ = {classifierCall}; repeatRuns (n - 1).";
  Str.replace "main = {classifierCall}." repeated (Str.replace "D = use \"dtree\"." "D = use \"{root}/tests/dtree\"." text).
sampleOk limit s = List.all (fn k -> case J.get k s of Ok (J.JNum n) -> n >= 0 | _ -> False) ["live","peak","regions","reclaimed"]
  and (case (J.get "live" s, J.get "peak" s) of (Ok (J.JNum live), Ok (J.JNum peak)) -> live <= peak and peak <= limit | _ -> False).
classifier o out rep dir =
  _ = B.command ["mkdir","-p",dir];
  _ = writeStreamed "{dir}/program.fpr" (fixture o.root);
  build = buildImage o out rep "{dir}/program.fpr" dir;
  budget = heapBudget dir;
  limit = unwrap (J.num (field "usable_heap_block_bytes" (J.JObj budget)));
  output = executeGuest {o | timeout = 600} out rep dir dir [] [] [];
  result = unwrap (J.parse (must out rep (runLogged [] (List.append o.helper ["dtree","512","128","16","6","5","{dir}/run.log","10"]) "{dir}/check.log" 60)));
  runs = unwrap (J.items (field "elapsed_us_runs" result));
  samples = unwrap (J.items (field "heap_samples" result));
  _ = (if List.len runs == 10 then Unit else fail out rep "classifier did not complete ten exact iterations");
  _ = (if limit > 0 and samples != [] then Unit else fail out rep "classifier is missing its heap budget or region summary");
  _ = (if List.all (sampleOk limit) samples then Unit else fail out rep "classifier region summary is invalid or exceeded its usable heap budget");
  last = List.last samples;
  lastNum k = case J.get k last of Ok (J.JNum n) -> n | _ -> 0;
  _ = (if lastNum "peak" > 0 then Unit else fail out rep "classifier is missing allocation peak instrumentation");
  _ = (if lastNum "regions" >= 10 and lastNum "reclaimed" > 10 * limit then Unit else fail out rep "classifier region reclamation gate failed");
  execution = J.JObj (List.concat [budget,[("frequency_mhz",num o.mhz),("isa",J.JStr (if o.compressed then "RV32IMC" else "RV32IM")),
    ("elapsed_us",List.last runs),("elapsed_us_runs",J.JArr runs),("heap_samples",J.JArr samples),("passed",J.JBool True)]]);
  _ = writeStreamed "{dir}/results.json" (J.pretty (J.JObj [("reference",field "reference" result),("repeats",num 10),
    ("executions",J.JObj [(o.target,execution)])]) + "\n");
  [("build",build),("classifier_report",J.JStr "{dir}/results.json"),("elapsed_us_runs",J.JArr runs)].

# ---- options -------------------------------------------------------------------
specs = [CLI.Option "target" "" CLI.One, CLI.Option "preset" "" CLI.One, CLI.Option "cases" "" CLI.One,
  CLI.Option "program" "" CLI.One, CLI.Option "arg" "" CLI.Many, CLI.Option "input" "" CLI.Many,
  CLI.Option "env" "" CLI.Many, CLI.Option "root" "" CLI.One, CLI.Option "timeout" "" CLI.One,
  CLI.Option "out" "" CLI.One, CLI.Option "fpga-manifest" "" CLI.One, CLI.Option "loader" "" CLI.One,
  CLI.Option "port" "" CLI.One, CLI.Option "settle" "" CLI.One, CLI.Option "skip-compiler-build" "" CLI.Switch].
splitEnv entry = k = Str.find 61 entry;
  if k <= 0 then error "--env requires a nonempty NAME=VALUE" else (Str.slice entry 0 k, Str.slice entry (k + 1) (Str.len entry)).

main : unsafe Unit -> Unit .
main u =
  parsed = unwrap (CLI.parse specs (args Unit));
  _ = (if CLI.operands parsed == [] then Unit else error "unexpected arguments: {CLI.operands parsed}");
  root = B.query ["pwd","-P"];
  _ = (if B.exists "-f" "machine/tangnano20k/examples.sol" then Unit else error "run from the FP-RISC repository root");
  target = CLI.valueOr "qemu" "target" parsed;
  _ = (if List.has target ["qemu","board"] then Unit else error "--target must be qemu or board");
  preset = CLI.valueOr "fprisc-48" "preset" parsed;
  shape = config preset;
  board = boardOf preset;
  manifestArg = CLI.valueOr "" "fpga-manifest" parsed;
  _ = (if target == "board" and manifestArg == "" then error "--target board requires --fpga-manifest from the matching preset build" else Unit);
  _ = (if target == "qemu" and manifestArg != "" then error "--fpga-manifest is only used with --target board" else Unit);
  programPath = CLI.valueOr "" "program" parsed;
  chosenArg = CLI.valueOr "" "cases" parsed;
  _ = (if programPath != "" and chosenArg != "" then error "--cases and --program exclude each other" else Unit);
  chosen = if chosenArg == "" then suite else Str.split 44 chosenArg;
  _ = (if List.all (fn c -> List.has c suite) chosen then Unit else error "unknown case in --cases (choose from {suite})");
  _ = (if List.len (sorted chosen) == List.len chosen and List.all (fn c -> count c chosen == 1) chosen then Unit else error "duplicate cases");
  timeout = parseInt (CLI.valueOr "120" "timeout" parsed);
  _ = (if timeout > 0 then Unit else error "--timeout must be a positive number of seconds");
  guestArgs = CLI.values "arg" parsed; guestInputs = CLI.values "input" parsed;
  guestEnv = List.map splitEnv (CLI.values "env" parsed); rootArg = CLI.valueOr "" "root" parsed;
  _ = (if programPath == "" and (guestArgs != [] or guestInputs != [] or guestEnv != [] or rootArg != "")
       then error "--arg, --input, --env and --root require --program" else Unit);
  mode = if programPath == "" then "suite" else "program";
  outArg = CLI.valueOr "" "out" parsed;
  out = if outArg != "" then outArg else "{root}/build/tangnano20k-examples/{if programPath == "" then target else "program-{target}"}";
  _ = B.command ["mkdir","-p",out];
  out2 = B.query ["realpath",out];
  rep0 = J.JObj [("preset",J.JStr preset),("target",J.JStr target),("mode",J.JStr mode),("passed",J.JBool False),
    ("suite_complete",J.JBool False),("repository",J.JNull),("cases",J.JArr [])];
  _ = save out2 rep0;
  sol = solCommand Unit;
  repository = case runLogged [] (List.append sol ["machine/tangnano20k/artifact.sol","repository",root]) "{out2}/repository.log" 120 of
      Ok text -> (case J.parse (Str.trim text) of Ok j -> j | Err e -> J.JObj [("error",J.JStr e)])
    | Err e -> J.JObj [("revision",J.JNull),("diff_sha256",J.JNull),("error",J.JStr (tailOf 400 e))];
  rep1 = J.set "repository" repository rep0;
  _ = save out2 rep1;
  mhz = presetMhz preset;
  compressed = presetCompressed preset;
  env = [("FPR_PRESET",preset),("FPR_QEMU",if target == "qemu" then "1" else "0"),("FPR_HEAP_REPORT","1"),
    ("FPR_XLEN","32"),("FPR_RVC",if compressed then "1" else "0"),("FPR_CPU_MHZ","{mhz}")];
  # the preset refuses conflicting inherited settings before any build or hardware change
  _ = must out2 rep1 (runLogged env (List.append sol ["machine/tangnano20k/preset.sol"]) "{out2}/preset.log" 60);
  (bitstream, fpga, buildId) = if target == "board" then fpgaImage out2 rep1 manifestArg preset else ("",J.JNull,"");
  rep2 = if target == "board" then J.set "fpga" fpga rep1 else rep1;
  skipCompiler = CLI.flag "skip-compiler-build" parsed;
  _ = (if skipCompiler then Unit else _ = print "building the compiler (make fpr)"; _ = must out2 rep2 (runLogged env ["make","fpr"] "{out2}/compiler-build.log" 1800); Unit);
  soft = B.setting "FPR_SOFTFLOAT_ROOT" "{root}/build/tangnano20k-softfloat";
  _ = (if B.exists "-f" "{soft}/build/Linux-RISCV32-GCC/softfloat.a" then Unit
       else _ = must out2 rep2 (runLogged env (List.append sol ["machine/tangnano20k/build-softfloat.sol"]) "{out2}/softfloat-build.log" 600); Unit);
  helper = List.append sol ["{root}/machine/tangnano20k/board-host.sol"];
  o = {target = target, preset = preset, mhz = mhz, memMhz = presetMemMhz preset, compressed = compressed,
       timeout = timeout, port = CLI.valueOr (defaultPort board) "port" parsed,
       settle = CLI.valueOr (defaultSettle board) "settle" parsed, buildId = buildId,
       helper = helper, sol = sol, env = env, root = root};
  loader = CLI.valueOr "{B.setting "HOME" "~"}/Documents/Libs/oss-cad-suite/bin/openFPGALoader" "loader" parsed;
  rep3 = if bitstream == "" then rep2 else
    _ = print "programming FPGA SRAM: {bitstream}";
    _ = must out2 rep2 (runLogged [] (List.concat [[loader,"-b",loaderBoard board],ftdiSerial o.port,[bitstream]]) "{out2}/program-fpga.log" 120);
    J.set "fpga_programmed_sram" (J.JBool True) rep2;
  _ = save out2 rep3;
  if programPath != "" then
    files = if rootArg != "" then B.query ["realpath",rootArg] else "{out2}/files";
    _ = B.command ["mkdir","-p",files];
    rep4 = J.set "invocation" (J.JObj [("source",J.JStr programPath),("root",J.JStr files),("arguments",J.strs guestArgs),
      ("input_lines",J.strs guestInputs),("environment",J.JObj (List.map (fn kv -> (k,v) = kv; (k,J.JStr v)) guestEnv)),
      ("timeout",num timeout)]) rep3;
    dir = "{out2}/program";
    started = seconds Unit;
    rep5 = addCase rep4 (J.JObj [("name",J.JStr "program"),("passed",J.JBool False)]);
    build = buildImage o out2 rep5 programPath dir;
    output = executeGuest o out2 rep5 dir files guestArgs guestInputs guestEnv;
    _ = checkCase out2 rep5 "program" output files;
    _ = print output;
    rep6 = J.set "passed" (J.JBool True) (setLastCase rep5 (J.JObj [("name",J.JStr "program"),("passed",J.JBool True),
      ("build",build),("wall_seconds",num (seconds Unit - started))]));
    _ = save out2 rep6;
    print "PASS: program; {out2}/results.json"
  else
    rep4 = List.fold (fn r name -> runCase o out2 r name) rep3 chosen;
    complete = List.len chosen == List.len suite;
    _ = save out2 (J.set "suite_complete" (J.JBool complete) (J.set "passed" (J.JBool True) rep4));
    print "PASS: {List.len chosen} cases; {out2}/results.json".

>! main Unit.
