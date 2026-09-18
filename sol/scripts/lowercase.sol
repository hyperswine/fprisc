# lowercase.sol -- transactionally lowercase one UTF-8 text file.
# The source is snapshotted and the destination is replaced at commit; a
# conflict retries the whole transform without duplicate appends.
#
#   ./fpr sol sol/scripts/lowercase.sol INPUT OUTPUT

lowerFile source target = case Try.readPath source of
  Ok text -> u = writePath target (Str.lower text); print "lowercase: {source} -> {target}"
| Err message -> error "lowercase: {message}".

execute argv = case argv of
  source :: target :: [] -> lowerFile source target
| _ -> error "usage: lowercase.sol INPUT OUTPUT".

> execute (args Unit).
