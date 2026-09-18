# archive.sol -- create a gzip tar archive without shell interpolation.
# tar is a mutating capability, so it is queued for the commit boundary.
# Deferred processes have at-least-once crash recovery; tar -czf is suitable
# because rerunning it replaces the requested output.
#
#   ./fpr sol sol/scripts/archive.sol SOURCE ARCHIVE.tar.gz

P = use "../lib/proc".

archive source target = case exists source of
  False -> error "archive: source does not exist: {source}"
| True ->
    u = Proc.afterCommit (P.spec ["tar", "-czf", target, "--", source]);
    print "archive: queued {source} -> {target}".

execute argv = case argv of
  source :: target :: [] -> archive source target
| _ -> error "usage: archive.sol SOURCE ARCHIVE.tar.gz".

> execute (args Unit).
