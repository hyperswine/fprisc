# proc.sol -- pure builders and result helpers over the structured VM process
# primitive. ProcessSpec a keeps argv structured all the way to exec(3).
# Direct/afterCommit APIs use String arguments; Proc.later uses Arg values:
# Lit "literal" or From (Deferred.out earlier |> Deferred.trim).
# Deferred projections are data evaluated at commit; they do not run here.
# Proc.streamNow sends spec stdin and forwards live stdout/stderr directly.
# Proc.inheritNow inherits all three descriptors; spec stdin must be empty.
# Both return Result Int String and refuse pending transaction effects.
# Guarded retry stops after immediate external work; explicit legacy mode or
# Script.replayable accepts repetition. Proc.queryReplayable is the query
# convenience, not a read-only validator. Text captures are capped at 1 MiB
# per channel. Use Proc.pipeline for byte input/sinks, explicit capture budgets,
# stage statuses and owned jobs (Proc.start/wait/poll/cancel).
# See docs/2026-10-29-SOL-PROCESS-PHASE3.md for publication and recovery rules.

spec argv = ProcessSpec argv "" [] "" 0.

inDir dir (ProcessSpec argv _ env stdin timeoutMs) =
  ProcessSpec argv dir env stdin timeoutMs.

withEnv key value (ProcessSpec argv dir env stdin timeoutMs) =
  ProcessSpec argv dir ((key, value) :: env) stdin timeoutMs.

withStdin input (ProcessSpec argv dir env _ timeoutMs) =
  ProcessSpec argv dir env input timeoutMs.

withTimeout timeoutMs (ProcessSpec argv dir env stdin _) =
  ProcessSpec argv dir env stdin timeoutMs.

output result = case result of
  Ok (ProcessResult 0 stdout stderr) -> Ok stdout
| Ok (ProcessResult code stdout stderr) -> Err "process exited {code}: {stderr}{stdout}"
| Err msg -> Err msg.

succeeded result = case result of
  Ok (ProcessResult 0 _ _) -> True
| _ -> False.
