# Structured argv, live output, explicit status handling. External I/O is not
# rolled back and may repeat if the surrounding script retries.
> result = Proc.streamNow
    (ProcessSpec ["/bin/cat"] "" [] "hello λ\n" 1000);
  case result of
    Ok 0 -> Unit
  | Ok code -> error "child exited {code}"
  | Err message -> error message.
