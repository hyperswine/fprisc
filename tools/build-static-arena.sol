# Closed static activation/sequence driver. Publication follows every proof.
F = use "toolchain-files".
B = use "../sol/lib/build".
J = use "../sol/lib/json".
CLI = use "../sol/lib/cli".
D = use "../sol/lib/digest".
Contract = use "static-arena-contract-core".
Heap = use "static-arena-heap-proof".
Target = use "target-image-core".
RV = use "linked-rv64".
M = use "../std/map".
need result = case result of Ok value -> value | Err why -> error "{why}".
remainder a b = RV.remainder a b.

require ok why = if ok then Unit else error ("static arena refused: " + why).
get obj key = unwrap (J.get key obj).
text obj key = unwrap (J.text (get obj key)).
num obj key = unwrap (J.num (get obj key)).
hash path = unwrap (D.sha256File (F.canonical path)).
jsonIntegers source =
  (_,_,_,valid) = List.fold (fn state c ->
    (quoted,escaped,numeric,valid) = state;
    if escaped then (True,False,False,valid) else
    if quoted and c == 92 then (True,True,False,valid) else
    if c == 34 then (not quoted,False,False,valid) else
    if quoted then state else
      digit = c >= 48 and c <= 57;
      (False,False,digit or (numeric and List.has c [45,43]),valid and not (numeric and List.has c [46,69,101]))) (False,False,False,True) (Str.codes source);
  valid.
validName name =
  codes = Str.codes name;
  letter c = (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95;
  case codes of [] -> False | c::rest -> letter c and List.all (fn x -> letter x or (x >= 48 and x <= 57) or x == 46) rest.
kind k = case k of "KWord" -> "uintptr_t" | "KInt" -> "intptr_t" | "KBool" -> "int" | "KUnit" -> "uintptr_t" | _ -> error "static activation requires scalar Word/Int/Bool/Unit boundaries".
member k = case k of "KWord" -> "word" | "KInt" -> "integer" | "KBool" -> "boolean" | "KUnit" -> "unit" | _ -> error "invalid scalar kind".
literal k value =
  n = case value of J.JNum n -> n | _ -> error "activation arguments must be integers";
  (low,high) = (case k of "KWord" -> (0,2^64 - 1) | "KInt" -> (0 - 2^62,2^62 - 1) | "KBool" -> (0,1) | "KUnit" -> (0,0) | _ -> error "unsupported scalar kind");
  _ = require (n >= low and n <= high) "activation argument outside {k} domain";
  "({kind k})UINT64_C({RV.u64 n})".
signature assembly export =
  prefix = "# export {export} -> ";
  line = case List.filter (Str.startsWith prefix) (Str.lines assembly) of [line] -> line | _ -> error "missing/ambiguous checked callback signature";
  start = Str.find 40 line; finish = Str.find 41 line;
  _ = require (start >= 0 and finish == Str.len line - 1) "invalid callback signature";
  content = Str.words (substr line (start + 1) (finish - start - 1));
  (params,result) = (case List.rev content of result :: "->" :: rest -> (List.rev rest,result) | _ -> error "invalid callback signature");
  _ = require (List.len params <= 64) "static activation supports at most 64 parameters";
  _ = List.map kind (result::params);
  (params,result).
declaration export params result =
  resultC = if result == "KUnit" then "void" else kind result;
  "extern {resultC} {export}(" + (if params == [] then "void" else Str.join "," (List.map kind params)) + ");".
single assembly arguments heap =
  (params,result) = signature assembly "fpr_static_callback";
  _ = require (List.len params == List.len arguments) "argument count differs from the checked callback signature";
  values = List.map (fn i -> literal (params ! i) (arguments ! i)) (Target.indices (List.len params));
  invocation = "fpr_static_callback(" + Str.join "," values + ");";
  call = if result == "KUnit" then invocation+"fpr_static_result=0;" else "fpr_static_result=(uw)"+invocation;
  (declaration "fpr_static_callback" params result,call,J.JObj [("parameters",J.JArr (List.map J.JStr params)),("result",J.JStr result),("arguments",J.JArr arguments)]).
parseSequence doc =
  _ = require (Contract.fieldsEqual doc ["schema","steps"] and get doc "schema" == J.JStr "static-builtin-sequence-v1") "invalid static sequence schema";
  steps = unwrap (J.items (get doc "steps"));
  _ = require (steps != []) "a static sequence needs at least one step";
  _ = List.map (fn i -> step = steps ! i;
    _ = require (Contract.fieldsEqual step ["entry","arguments"] and validName (text step "entry")) "invalid static sequence step";
    arguments = unwrap (J.items (get step "arguments"));
    List.map (fn a -> case a of J.JNum _ -> Unit | _ ->
      require (i > 0 and Contract.fieldsEqual a ["previous"] and get a "previous" == J.JBool True) "invalid previous-result reference") arguments) (Target.indices (List.len steps));
  steps.
sequenceCaller assembly symbols steps setup checkpoint template =
  exports = List.map (fn pair -> (name,export) = pair; (params,result) = signature assembly export; (name,export,params,result)) symbols;
  (instructions,constants,previous) = List.fold (fn state step ->
    (ins,literals,prev) = state;
    name = text step "entry";
    index = case List.filter (fn i -> (n,_,_,_) = exports ! i; n == name) (Target.indices (List.len exports)) of [i] -> i | _ -> error "missing sequence entry";
    (_,_,params,result) = exports ! index;
    arguments = unwrap (J.items (get step "arguments"));
    _ = require (List.len params == List.len arguments) "argument count differs from the checked callback signature";
    (values,mask) = List.fold (fn valueState i ->
      (values,bits) = valueState; k = params ! i; a = arguments ! i;
      case a of J.JNum _ -> (values+[literal k a],bits) | _ ->
        _ = require (prev == k) "previous result kind differs from the checked parameter";
        (values+["0"],bits + 2^i)) ([],0) (Target.indices (List.len params));
    instruction = "\{{index}, {List.len literals}, UINT64_C({mask})\}";
    (ins+[instruction],literals + values,result)) ([],[],"") steps;
  declarations = List.map (fn row -> (_,export,params,result) = row; declaration export params result) exports;
  branches = List.map (fn i ->
    (_,export,params,result) = exports ! i;
    arguments = List.map (fn n -> k = params ! n;
      "((step->previous & (UINT64_C(1)<<{n})) ? state.{member k} : ({kind k})fpr_static_literals[step->offset+{n}])") (Target.indices (List.len params));
    call = export+"("+Str.join "," arguments+")";
    statement = if result == "KUnit" then call+"; state.unit=0;" else "state.{member result}={call};";
    "case {i}: {statement} break;") (Target.indices (List.len exports));
  decl = Str.join "\n" (declarations + ["static const uint64_t fpr_static_literals[]=\{"+(if constants == [] then "0" else Str.join "," constants)+"\};",
    "static const struct static_step \{uw entry,offset,previous;\} fpr_static_steps[]=\{"+Str.join "," instructions+"\};"]);
  resetBody = Str.replace "HEAP_SETUP" setup template;
  guardedBody = Str.replace "CHECKPOINT" checkpoint resetBody;
  dispatchBody = Str.replace "CASES" (Str.join "\n" branches) guardedBody;
  calls = Str.replace "PREVIOUS_MEMBER" (member previous) dispatchBody;
  sig = J.JObj (List.map (fn row -> (name,export,params,result) = row; (name,J.JObj [("parameters",J.JArr (List.map J.JStr params)),("result",J.JStr result),("export",J.JStr export)])) exports);
  (decl,calls,sig).
writeNow path content =
  bytes = unwrap (Utf8.encode content); h = unwrap (Stream.openWrite path (Bytes.len bytes + 1));
  (result,next) = Stream.writeChunk bytes h; _ = unwrap (Stream.closeWrite next); unwrap result.
queryTool root env argv =
  ProcessResult code out err = unwrap (Proc.runNow (ProcessSpec argv root env "" 250000));
  _ = require (code == 0) "controlled link/proof failed: {out}{err}";
  out.
placement img heap stack =
  region = fn name -> fn size ->
    start = RV.symbol img "fpr_static_{name}_start"; end = RV.symbol img "fpr_static_{name}_end"; guard = RV.symbol img "fpr_static_{name}_guard";
    _ = require (start `remainder` 16 == 0 and end - start == size and guard + 16 == start) "linked arena geometry differs from reserved {name}";
    covering = List.filter (fn s -> s.address == guard and s.address + s.size == end + 16) img.sections;
    _ = require (List.len covering == 1 and List.all (fn s -> s.kind == 8 and s.flags `remainder` 8 == 3) covering) "arena is not exact writable non-executable NOBITS";
    J.JObj [("start",J.JNum start),("end",J.JNum end),("bytes",J.JNum size),("lower_guard_start",J.JNum guard),("upper_guard_end",J.JNum (end + 16))];
  h = region "heap" heap; s = region "stack" stack;
  _ = require (num h "upper_guard_end" <= num s "lower_guard_start") "heap and stack arenas overlap";
  spans = M.entries (List.fold (fn m sec ->
    if sec.size == 0 or RV.bits sec.flags 1 1 == 0 then m else
      _ = require (not (M.member sec.address m)) "allocated sections overlap";
      M.insert sec.address (sec.address + sec.size) m) M.ints img.sections);
  _ = List.fold (fn end pair -> (start,next) = pair; _ = require (start >= end) "allocated sections overlap"; next) 0 spans;
  _ = require (RV.symbol img "fpr_static_bss_end" <= num h "lower_guard_start") "heap overlaps static state";
  _ = require (img.header.entry == RV.symbol img "_start") "ELF entry differs from controlled startup";
  J.JObj [("heap",h),("stack",s)].
options = List.map (fn name -> CLI.Option name "" CLI.One) ["root","entry","sequence","arguments","heap-bytes","stack-bytes","callback-instructions","image"] + [CLI.Option "execute" "" CLI.Switch].
build : unsafe Unit -> Unit .
build _ =
  parsed = unwrap (CLI.parse options (args Unit));
  getOpt name = CLI.valueOr "" name parsed;
  source = case CLI.operands parsed of [path] -> F.canonical path | _ -> error "expected SOURCE --entry NAME or --sequence JSON --heap-bytes N --stack-bytes N --image ELF";
  root = F.canonical (CLI.valueOr "." "root" parsed);
  imageName = getOpt "image";
  imagePath = if B.exists "-e" imageName then F.canonical imageName else F.canonical (B.query ["dirname",imageName]) + "/" + B.query ["basename",imageName];
  heapBytes = Str.parse (getOpt "heap-bytes"); stackBytes = Str.parse (getOpt "stack-bytes");
  _ = require (heapBytes == 0 or (heapBytes >= 112 and heapBytes < 2^64 and heapBytes `remainder` 16 == 0)) "heap bytes must be zero or a 16-byte multiple of at least 112";
  _ = require (stackBytes > 0 and stackBytes < 2^64 and stackBytes `remainder` 16 == 0) "stack bytes must be positive 16-byte multiple";
  isSequence = getOpt "sequence" != "";
  _ = require ((getOpt "entry" != "") != isSequence) "choose a sequence or a single entry";
  _ = require (not isSequence or getOpt "arguments" == "") "--arguments belongs to a single entry";
  sequenceText = if isSequence then F.readText (getOpt "sequence") else "null";
  _ = require (jsonIntegers sequenceText) "sequence arguments must be integers";
  sequence = unwrap (J.parse sequenceText);
  steps = if isSequence then parseSequence sequence else [];
  argumentText = CLI.valueOr "[]" "arguments" parsed;
  _ = require (jsonIntegers argumentText) "activation arguments must be integers";
  arguments = unwrap (J.parse argumentText |>? J.items);
  entry = getOpt "entry";
  _ = require (isSequence or validName entry) "invalid source entry name";
  names = if isSequence then List.fold (fn xs step -> name = text step "entry"; if List.has name xs then xs else xs+[name]) [] steps else [entry];
  symbols = List.map (fn i -> (names ! i,if isSequence then "fpr_static_callback_{i}" else "fpr_static_callback")) (Target.indices (List.len names));
  outputs = [imagePath,"{imagePath}.admission.json"];
  _ = require (not (List.has source outputs) and (not isSequence or not (List.has (F.canonical (getOpt "sequence")) outputs))) "output would replace source/sequence";
  _ = require (not (B.exists "-e" imagePath) or B.exists "-f" imagePath) "output image is not a file";
  contractPath = "{root}/machine/builtin/contracts/rv64-c-heap-v1.json";
  contract = Contract.verify root contractPath;
  sourceHash = hash source; compilerHash = hash "{root}/fpr";
  manifestPath = "{root}/machine/builtin/targets/virt.json";
  manifest = F.readBytes manifestPath;
  target = "builtin-rv64-virt-128m";
  selected = Target.target manifest target;
  _ = require (selected.width == 64 and selected.origin == 2147483648 and selected.ram == 134217728) "manifest geometry differs from controlled startup";
  out = tempDir "fpr-static";
  ProcessResult envStatus envText envError = unwrap (Proc.runNow (ProcessSpec ["/usr/bin/env","-0"] "" [] "" 0));
  _ = require (envStatus == 0) "cannot enumerate build environment: {envError}";
  prefixes = ["FPR_","CFLAGS","CPPFLAGS","LDFLAGS","GCC_EXEC_PREFIX","COMPILER_PATH","LIBRARY_PATH","CPATH","C_INCLUDE_PATH"];
  envNames = List.map (fn item -> case Str.split 61 item of name::_ -> name | _ -> "") (Str.split 0 envText);
  unset = List.concat (List.map (fn name -> ["-u",name]) (List.filter (fn name -> List.any (fn prefix -> Str.startsWith prefix name) prefixes) envNames));
  runner = B.setting "SOL" "sol";
  runTool = fn tool -> fn argv -> unwrap (J.parse (queryTool root [] (["/usr/bin/env"]+unset+["FPR_HOME={root}","XDG_CACHE_HOME={out}/cache",runner,"{root}/tools/{tool}",root,out]+argv)));
  compiled = runTool "static-arena-link.sol" (["compile",source,"{Numeric.max 1 heapBytes}"] + List.map (fn pair -> (name,export) = pair; "{name}:{export}") symbols);
  assembly = F.readText "{out}/callback.s";
  proofList = List.map (fn pair -> (name,export) = pair; (_,proof) = Heap.proof (Str.lines assembly) heapBytes export; (name,proof)) symbols;
  proofs = J.JObj proofList;
  setup = if heapBytes == 0 then "" else F.readText "{root}/tools/static-arena/heap.c.in";
  checkpoint = F.readText "{root}/tools/static-arena/checkpoint.c.in";
  (decl,calls,sig) = if isSequence then sequenceCaller assembly symbols steps setup checkpoint (F.readText "{root}/tools/static-arena/sequence.c.in") else single assembly arguments heapBytes;
  heap = if isSequence then
    J.JObj [("required_arena_bytes",J.JNum (List.fold (fn n pair -> (_,p) = pair; Numeric.max n (num p "required_arena_bytes")) 0 proofList)),
      ("reserved_bytes",J.JNum heapBytes),("requests",J.JNum (List.fold (fn n step -> n + num (get proofs (text step "entry")) "requests") 0 steps)),
      ("requested_bytes",J.JNum (List.fold (fn n step -> n + num (get proofs (text step "entry")) "requested_bytes") 0 steps)),("per_entry",proofs)]
    else J.set "reserved_bytes" (J.JNum heapBytes) (get proofs entry);
  body = Str.replace "HEAP_SETUP" setup (Str.replace "INVOCATION" calls (Str.replace "DECLARATION" decl (F.readText "{root}/tools/static-arena/caller.c.in")));
  _ = writeNow "{out}/caller.c" body;
  _ = writeNow "{out}/start.S" (F.readText "{root}/tools/static-arena/start.S.in");
  _ = writeNow "{out}/link.ld" (Str.replace "STACK_BYTES" "{stackBytes}" (Str.replace "HEAP_BYTES" "{heapBytes}" (F.readText "{root}/tools/static-arena/link.ld.in")));
  linked = runTool "static-arena-link.sol" [if isSequence then "sequence" else "single"];
  _ = require (Contract.verify root contractPath == contract) "runtime contract changed during admission";
  _ = require (hash source == sourceHash and hash "{root}/fpr" == compilerHash) "source/compiler changed during admission";
  bytes = F.readBytes "{out}/image.elf";
  physical = Target.admit bytes manifest target;
  img = RV.image bytes;
  regions = placement img heapBytes stackBytes;
  stack = RV.stackReport img physical "fpr_static_run" stackBytes;
  templates = ["start.S.in","caller.c.in","link.ld.in","heap.c.in","checkpoint.c.in","sequence.c.in"];
  templateHashes = J.JObj (List.map (fn name -> (name,J.JStr (hash "{root}/tools/static-arena/{name}"))) templates);
  receipt = J.JObj [("schema",J.JStr (if isSequence then "static-builtin-sequence-admission-v1" else "static-builtin-activation-v1")),
    ("image",physical),("signature",sig),("heap",heap),("regions",regions),("linked_stack",stack),("compiler_sha256",J.JStr compilerHash),
    ("runtime_contract",contract),("recipe_sha256",J.JStr (hash "{root}/tools/build-static-arena.sol")),("runtime_templates_sha256",templateHashes),
    ("root_source_sha256",J.JStr sourceHash),("assembly_sha256",J.JStr (hash "{out}/callback.s")),
    ("linked_inputs_sha256",get linked "inputs"),("flags",get linked "flags"),("build_commands",J.JArr (compiled :: unwrap (J.items (get linked "commands")))),
    ("toolchain",get linked "toolchain"),("link_recipe_sha256",J.JStr (hash "{root}/tools/static-arena-link.sol")),
    ("heap_proof_recipe_sha256",J.JStr (hash "{root}/tools/static-arena-heap-proof.sol")),
    ("linked_proof_sources_sha256",J.JObj (List.map (fn name -> (name,J.JStr (hash "{root}/tools/{name}"))) ["linked-rv64.sol","riscv-compressed.sol","target-image-core.sol","static-arena-contract-core.sol"])),
    ("scope",J.JStr (if isSequence then "Finite exclusive RV64 builtin activations from controlled startup, with typed scalar hand-offs and reclamation checks before every arena reset." else "One fresh, exclusive, non-reentrant RV64 builtin activation from the controlled boot path; no WCET claim.")),
    ("assumptions",J.JArr (List.map J.JStr ["Trusted compiler and C/assembler/linker toolchain; valid-memory program semantics.",
      "QEMU virt machine address map, machine-mode reset, hart 0; other harts park without memory accesses.",
      "No executable-code mutation or asynchronous NMI/debugger/DMA memory mutation; ordinary interrupts remain disabled.",
      "This receipt applies only to the exact image hash; it does not authenticate arbitrary replacement ELF files."]))];
  canonicalSequence = J.JObj [("schema",J.JStr "static-builtin-sequence-v1"),("steps",J.JArr (List.map (fn step -> J.JObj [("arguments",get step "arguments"),("entry",get step "entry")]) steps))];
  sequenceHash = Target.digest (unwrap (Utf8.encode (J.render canonicalSequence)));
  sequenced = if isSequence then J.set "sequence_sha256" (J.JStr sequenceHash) (J.set "sequence" sequence (J.set "dispatch" (J.JStr "fixed read-only schedule with direct entry calls") receipt)) else receipt;
  bounded = if getOpt "callback-instructions" == "" then sequenced else
    J.set "callback_work" (RV.callbackReport img symbols (if isSequence then List.map (fn step -> text step "entry") steps else [entry]) (Str.parse (getOpt "callback-instructions"))) sequenced;
  executed = if CLI.flag "execute" parsed then
    execution = runTool "static-arena-link.sol" ["execute"];
    output = text execution "output";
    values = List.filter (Str.startsWith "STATIC_ARENA_PASS result=") (Str.lines output);
    line = case values of [one] -> one | _ -> error "execution did not return guarded activation result";
    J.set "execution" (J.JObj [("status",J.JStr "RV64-QEMU-PASS"),("result_bits",J.JNum (Str.parse (substr line 25 (Str.len line - 25)))),("output",J.JStr output)]) bounded
    else bounded;
  _ = require (F.readBytes "{out}/image.elf" == bytes) "linked image changed during admission";
  _ = writeNow "{out}/receipt.json" (J.pretty executed+"\n");
  _ = need (Fs.copyPublishNow "{out}/receipt.json" "{imagePath}.admission.json" 65536 True);
  _ = need (Fs.copyPublishNow "{out}/image.elf" imagePath 65536 True);
  print "static arena admitted: {imagePath}".
> build Unit.
