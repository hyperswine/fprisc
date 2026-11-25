# Generated CSS must stay byte-identical after set-based nub and atomClass intern.
# The program is tests/viewcss.fpr (locked strings taken from origin/main).
H = use "helpers".
> root = H.root Unit;
  env = [("FPR_HOME",root),("FPR_PATH",root)];
  ProcessResult code out err = H.call ["{root}/fpr","run","tests/viewcss.fpr"] env 180000;
  if and (code == 0) (Str.contains out "byte-identical CSS") then print "viewcss: {Str.trim out}"
  else error "viewcss: exit {code}, stdout={out}, stderr={err}".
