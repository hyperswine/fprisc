envOr name fallback = case unwrap (Env.get name) of EnvText value -> value | EnvMissing -> fallback.
call argv env millis = unwrap (Proc.runNow (ProcessSpec argv "" env "" millis)).
root u = ProcessResult code out err = call ["pwd","-P"] [] 5000;
  if code == 0 then Str.trim out else error err.
write path bytes = writer = unwrap (Stream.openWrite path (Bytes.len bytes));
  (result, next) = Stream.writeChunk bytes writer; _ = unwrap result; Stream.closeWrite next.
cpus u = ProcessResult code out _ = call ["nproc"] [] 5000; if code == 0 then parseInt (Str.trim out) else 2.
full u = envOr "FPR_CHECK_FULL" "0" == "1".
text b = case Utf8.decode b of Ok s -> s | Err _ -> "<non-UTF-8 output>".
# Parallel jobs: (label, argv, cwd, env, millis) -> (label, exit code, stdout, stderr), in input order.
# A job that cannot start or exceeds its deadline reports exit -1 and the reason on stderr.
launch (label, argv, cwd, env, millis) = stage = ProcessSpec argv cwd env "" 0;
  pipe = PipelineSpec [stage] (PipeBytes (Bytes.empty Unit)) (PipeCapture 16777216) (PipeCapture 16777216) millis PipeFail;
  case Proc.start pipe of Ok job -> (label, Ok job) | Err why -> (label, Err "{why}").
collect (label, started) = case started of
  Err why -> (label, -1, "", why)
| Ok job -> (case Proc.wait job of
    Ok (PipelineResult code _ out errs) -> (label, code, text out, Str.join "" (List.map text errs))
  | Err why -> (label, -1, "", "{why}")).
pool : unsafe Int -> List (String, List String, String, List (String, String), Int) -> List (String, Result ProcessJob String) -> List (String, Int, String, String) -> List (String, Int, String, String).
pool slots pending active done = case pending of
  job :: rest -> if slots > 0 then pool (slots - 1) rest (List.append active [launch job]) done
    else (case active of first :: others -> pool 1 pending others (collect first :: done) | [] -> error "empty pool")
| [] -> List.append (List.rev done) (List.map collect active).
parallel : unsafe Int -> List (String, List String, String, List (String, String), Int) -> List (String, Int, String, String).
parallel slots jobs = pool slots jobs [] [].
# Known failures inside one check: rows "<check>:<item>" in tests/sol-checks-known-failures.tsv.
knownItems check root = prefix = "{check}:"; List.concat (List.map (fn row -> case Str.split 9 row of
    key :: _ -> if Str.startsWith prefix key then [Str.slice key (Str.len prefix) (Str.len key)] else []
  | [] -> []) (Str.lines (readPath "{root}/tests/sol-checks-known-failures.tsv"))).
# Fails on an unexpected failed item, or on a known item that did not fail.
settle check root failed = known = knownItems check root;
  unexpected = List.filter (fn i -> not (List.has i known)) failed;
  fixed = List.filter (fn k -> not (List.has k failed)) known;
  _ = List.map (fn i -> print "KNOWN FAIL {check}:{i}") (List.filter (fn i -> List.has i known) failed);
  _ = List.map (fn i -> print "NOW PASSES {check}:{i}: remove it from tests/sol-checks-known-failures.tsv") fixed;
  if unexpected == [] and fixed == [] then Unit else error "{check}: unexpected failures {unexpected}, known failures now passing {fixed}".
isFile path = ProcessResult code _ _ = call ["test","-f",path] [] 5000; code == 0.
