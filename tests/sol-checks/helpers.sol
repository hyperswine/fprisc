envOr name fallback = case unwrap (Env.get name) of EnvText value -> value | EnvMissing -> fallback.
call argv env millis = unwrap (Proc.runNow (ProcessSpec argv "" env "" millis)).
root u = ProcessResult code out err = call ["pwd","-P"] [] 5000;
  if code == 0 then Str.trim out else error err.
write path bytes = writer = unwrap (Stream.openWrite path (Bytes.len bytes));
  (result, next) = Stream.writeChunk bytes writer; _ = unwrap result; Stream.closeWrite next.
