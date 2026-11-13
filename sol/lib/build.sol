# Build-time subprocesses use structured argv and propagate failures.
setting name fallback = case unwrap (Env.get name) of
  EnvText value -> if value == "" then fallback else value
| EnvMissing -> fallback.
inDirectory dir env argv = status = unwrap (Proc.streamNow (ProcessSpec argv dir env "" 0));
  if status == 0 then Unit else error "exit {status}: {argv}".
runWith env argv = inDirectory "" env argv.
command argv = runWith [] argv.
query argv = ProcessResult status out err = unwrap (Proc.runNow (ProcessSpec argv "" [] "" 0));
  if status == 0 then Str.trim out else error "{argv}: {err}".
exists flag path = ProcessResult code _ _ = unwrap (Proc.runNow (ProcessSpec ["test",flag,path] "" [] "" 0)); code == 0.
