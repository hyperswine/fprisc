# Structured process query: raw argv, separate output streams, env overlay,
# stdin, and timeout all cross the VM/HAL boundary without shell quoting.
show r = case r of
  Ok (ProcessResult code out err) -> print "code={code} out=[{out}] err=[{err}]"
| Err msg -> print "err=[{msg}]".

> show (Proc.query (ProcessSpec ["/bin/sh", "-c", "printf '%s' \"$SOL_PROC_TEST\"; printf err >&2; cat"] "" [("SOL_PROC_TEST", "space arg:")] "stdin" 2000)).
> show (Proc.query (ProcessSpec ["/bin/sleep", "1"] "" [] "" 10)).
