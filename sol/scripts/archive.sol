# Native gzip/tar writer; queued at commit, bounded and atomically published.
A = use "../lib/archive".
archive source target =
  u = A.create source target;
  print "archive: queued {source} -> {target}".
execute argv = case argv of
  source :: target :: [] -> archive source target
| _ -> error "usage: archive.sol SOURCE ARCHIVE.tar.gz".
> execute (args Unit).
