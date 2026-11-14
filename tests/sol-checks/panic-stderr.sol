# A hosted program's diagnostics go to stderr (port of the retired
# tests/reliability/panic_stderr.py). stdout carries what the program printed and
# nothing else; a panic's last words and [ERR] echo are on stderr.
# FPR_DIAG_STDOUT=1 is the rollback switch and restores one stream.
H = use "helpers".
diag = "[ERR] boom\n\n*** FPRISC PANIC [actor 0]: boom ***\n".
> root = H.root Unit; work = tempDir "fpr-panic-stderr"; src = "{work}/p.fpr"; exe = "{work}/p";
  env = [("FPR_HOME",root),("FPR_PATH",root),("XDG_CACHE_HOME","{work}/cache"),("FPR_DIAG_STDOUT","")];
  _ = H.write src (unwrap (Utf8.encode "unsafe base. main = _ = print \"data\"; error \"boom\".\n"));
  ProcessResult bc bo be = H.call ["{root}/fpr","build",src,"-o",exe] env 300000;
  _ = (if bc == 0 then Unit else error "build: {bo}{be}");
  ProcessResult c1 o1 e1 = H.call [exe] env 60000;
  _ = (if c1 == 1 and o1 == "data\n" and e1 == diag then Unit else error "default: exit {c1}, stdout={o1}, stderr={e1}");
  ProcessResult c2 o2 e2 = H.call [exe] [("FPR_HOME",root),("FPR_PATH",root),("FPR_DIAG_STDOUT","1")] 60000;
  _ = (if c2 == 1 and o2 == "data\n" + diag and e2 == "" then Unit else error "FPR_DIAG_STDOUT=1: exit {c2}, stdout={o2}, stderr={e2}");
  print "panic_stderr: panic on stderr, stdout clean, FPR_DIAG_STDOUT=1 rollback: PASS".
