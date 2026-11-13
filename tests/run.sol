# From the repository root: sol tests/run.sol --jobs 4
# The manifest lists independent Python checks and their deadlines in seconds.
must r = case r of Ok x -> x | Err e -> error "{e}".
parse row = case Str.split 9 row of
  [path, seconds] -> (path, parseInt seconds)
| _ -> error "invalid case row: {row}".
start (path, seconds) =
  stage = ProcessSpec ["python3",path] "" [] "" 0;
  pipe = PipelineSpec [stage] (PipeBytes (Bytes.empty Unit)) (PipeCapture 1048576) (PipeCapture 1048576) (seconds * 1000) PipeFail;
  (path, must (Proc.start pipe)).
finish (path, job) = case Proc.wait job of
  Ok (PipelineResult 0 _ _ _) -> print "PASS {path}"
| Ok (PipelineResult code _ out errs) -> _ = IO.stdout out; _ = List.map IO.stderr errs; error "{path}: exit {code}"
| Err why -> error "{path}: {why}".
pool : unsafe Int -> List (String, Int) -> List (String, ProcessJob) -> List Unit.
pool slots pending active = case pending of
  item :: rest -> if slots > 0 then pool (slots - 1) rest (List.append active [start item])
    else (case active of first :: others -> _ = finish first; pool 1 pending others | [] -> error "empty pool")
| [] -> List.map finish active.
execute : unsafe Int -> List Unit.
execute count =
  _ = (if count < 1 then error "jobs must be positive" else Unit);
  checks = List.map parse (Str.lines (readPath "tests/sol-checks.tsv"));
  status = must (Proc.streamNow (ProcessSpec ["make","fpr"] "" [] "" 300000));
  _ = (if status == 0 then Unit else error "build exited {status}");
  pool count checks [].
> case args Unit of [] -> execute 1 | ["--jobs",n] -> execute (parseInt n) | _ -> error "usage: sol tests/run.sol [--jobs N]".
