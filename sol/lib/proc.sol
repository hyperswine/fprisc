# proc.sol -- pure builders and result helpers over the structured VM process
# primitive. ProcessSpec keeps argv structured all the way to exec(3).

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
