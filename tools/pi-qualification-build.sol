J = use "sol/lib/json".
D = use "sol/lib/digest".
C = use "qualification-compile".
Hart = use "pi-hart-registers".
Scheduler = use "pi-scheduler-cases".
Cases = use "pi-qualification-cases".
field obj name = unwrap (J.get name obj).
pairs obj = case obj of J.JObj entries -> entries | _ -> error "expected manifest fields".
digest value = case value of
    J.JNull -> J.JNull
  | J.JStr path -> (case D.sha256File path of Ok hex -> J.JStr hex | Err why -> error "{path}: {why}")
  | _ -> error "expected file path".
hashEntry entry = (key,path) = entry; (key,digest path).
sourceHashes root names = J.JObj (List.map (fn name -> (name,digest (J.JStr "{root}/{name}"))) names).
runtimeHashes root =
  ProcessResult status files err = unwrap (Proc.runNow (ProcessSpec ["find","-L","runtime","-mindepth","1","-maxdepth","1","-type","f","-print0"] root [] "" 0));
  if status == 0 then sourceHashes root (List.filter (fn path -> path != "") (Str.split 0 files))
  else error "listing runtime sources: {err}".
builderSources = ["tools/pi-qualification-build.sol","tools/qualification-compile.sol","tools/qualification-symbols.sol",
  "tools/pi-hart-registers.sol","tools/pi-hart-registers.c","tools/pi-qualification-cases.sol",
  "tools/pi-scheduler-cases.sol","tools/pi-language-cases.sol"].
inventory obj = J.JObj (List.map hashEntry (pairs obj)).
# The compiler runs before the Sol transaction commits and needs the source immediately.
writeFixture path source =
  bytes = unwrap (Utf8.encode source);
  writer = unwrap (Stream.openWrite path (Bytes.len bytes + 1));
  (result,next) = Stream.writeChunk bytes writer;
  _ = unwrap (Stream.closeWrite next);
  unwrap result.
compileFixture root out cross driver fixture = case fixture of
  J.JArr [J.JStr name,J.JStr source,J.JObj switches,J.JStr probe,J.JStr hal,J.JArr checks] ->
    env = List.map (fn entry -> (k,v) = entry; (k,unwrap (J.text v))) switches;
    exe = "{out}/{name}";
    _ = writeFixture "{exe}.fpr" source;
    symbols = C.buildChecked env root "{exe}.fpr" exe cross driver probe hal True (List.map (fn v -> unwrap (J.text v)) checks);
    (name,symbols)
  | _ -> error "invalid compilation fixture".
buildBundle : unsafe String -> String -> Unit .
buildBundle input output =
  plan = unwrap (J.parse (readPath input));
  scheduler = (case field plan "scheduler" of J.JArr xs -> xs | _ -> error "expected scheduler fixtures");
  repetitions = field (field plan "metadata") "repetitions";
  variants = List.concat (List.map (Scheduler.fixturePair repetitions) scheduler);
  schedulerSpecs = List.map (fn pair -> (_,spec) = pair; spec) variants;
  schedulerJobs = List.map (fn pair -> (job,_) = pair; job) variants;
  specs = (case field plan "cases" of J.JArr xs -> xs | _ -> error "expected fixture list");
  rows = List.concat (List.map Cases.expand (schedulerSpecs + specs));
  compiler = unwrap (J.text (field plan "compiler"));
  ProcessResult status version err = unwrap (Proc.runNow (ProcessSpec [compiler,"--version"] "" [] "" 0));
  _ = (if status == 0 then Unit else error "{compiler} --version: {err}");
  first = (case Str.lines version of line :: _ -> line | [] -> error "missing compiler version: {err}");
  jobs = (case field plan "builds" of J.JArr xs -> xs | _ -> error "expected build list");
  root = unwrap (J.text (field plan "root")); out = unwrap (J.text (field plan "out"));
  cross = unwrap (J.text (field plan "mode"));
  runner = unwrap (J.text (field (field plan "files") "runner_source_sha256"));
  _ = Hart.checkRegisters compiler "{root}/tools/pi-hart-registers.c" out;
  _ = Hart.runTool [compiler,"-O2","-Wall","-Wextra",runner,"-o","{out}/runner"];
  built = List.map (compileFixture root out cross compiler) (schedulerJobs + jobs);
  names = List.map (fn item -> (name,_) = item; name) built;
  symbols = List.map (fn item -> (name,workers) = item; (name,J.JArr (List.map J.JStr workers)))
    (List.filter (fn item -> (_,workers) = item; workers != []) built);
  binaries = J.JObj (List.map (fn name -> (name,digest (J.JStr "{out}/{name}"))) (names + ["runner"]));
  sources = J.JObj (List.map (fn name -> ("{name}.fpr",digest (J.JStr "{out}/{name}.fpr"))) names);
  metadata = pairs (field plan "metadata") + [("storage_symbols",J.JObj symbols)];
  files = inventory (field plan "files");
  fixtures = (case field plan "fixtures" of J.JArr xs -> List.map (fn v -> unwrap (J.text v)) xs | _ -> error "expected fixture paths");
  inventories = [("binaries",binaries),("sources",sources),("fixtures",sourceHashes root fixtures),
    ("runtime_sha256",runtimeHashes root),("builder_sources_sha256",sourceHashes root builderSources)];
  header = [("schema",J.JStr "pi-runtime-qualification-bundle-v1"),("c_compiler",J.JStr first)];
  rowField = ("cases",J.JArr rows);
  entries = header + metadata + (pairs files) + inventories + [rowField];
  _ = writePath output (J.pretty (J.JObj entries) + "\n");
  numBins = List.len (pairs binaries); numCases = List.len rows;
  print "Built {numBins} binaries and {numCases} physical cases".
main : unsafe Unit -> Unit .
> case args Unit of [input,output] -> buildBundle input output
  | _ -> error "usage: pi-qualification-build PLAN OUTPUT".
