# Runtime == fast path for String, I32/Int and small tuples must stay
# semantically identical (including IEEE NaN). See tests/eq-cheap.fpr.
H = use "helpers".
> root = H.root Unit;
  env = [("FPR_HOME",root),("FPR_PATH",root)];
  ProcessResult code out err = H.call ["{root}/fpr","run","tests/eq-cheap.fpr"] env 180000;
  if and (code == 0) (Str.contains out "eq-cheap:") then print "eq-cheap: {Str.trim out}"
  else error "eq-cheap: exit {code}, stdout={out}, stderr={err}".
