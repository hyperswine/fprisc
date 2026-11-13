H = use "helpers".
verify exe fixture env expected harts =
  ProcessResult code out err = H.call [exe,fixture] (("FPR_HARTS",harts) :: env) 90000;
  if and (code == 0) (and (out == expected) (err == "")) then Unit
  else error "digest on {harts} harts: exit {code}, stdout={out}, stderr={err}".
> work = tempDir "fpr-digest"; root = H.root Unit; exe = "{work}/check"; fixture = "{work}/bytes.bin";
  bytes = unwrap (Bytes.fromList (List.map (fn i -> (i * 37 + 11) % 256) (List.range 0 65536)));
  _ = H.write fixture bytes;
  env = [("FPR_HOME",root),("FPR_PATH",root)];
  ProcessResult code out err = H.call ["{root}/fpr","build","tests/sol-checks/digest.fpr","--harts","4","-o",exe] env 180000;
  _ = (if code == 0 then Unit else error "digest build: {out}{err}");
  expected = readPath "tests/sol-checks/digest.expected";
  _ = List.map (verify exe fixture env expected) ["1","4"];
  print "digest: SHA-256/SHA-1 binary padding/block boundaries, incremental and 64KiB streaming against hashlib on 1/4 harts PASS".
