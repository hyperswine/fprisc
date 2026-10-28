# Bounded binary copy with complete-file publication. Existing output is
# refused unless --replace is supplied. This is an immediate external effect.
copy source target replace = case Fs.copyPublishNow source target 65536 replace of
  Ok n -> print "copied {n} bytes"
| Err why -> error (str why).
execute argv = case argv of
  [source, target] -> copy source target False
| ["--replace", source, target] -> copy source target True
| _ -> error "usage: copy-binary.sol [--replace] SOURCE TARGET".
> execute (args Unit).
