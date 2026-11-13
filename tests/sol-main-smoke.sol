T = use "../sol/lib/test".
J = use "../sol/lib/json".
R = use "../tools/riscv-compressed".
> obj = unwrap (J.parse "\{\"answer\":42\}");
  T.run [T.equal "JSON roundtrip" obj (unwrap (J.parse (J.render obj))),
    T.equal "compressed NOP expands to ADDI zero,zero,0" 19 (R.expand 1),
    T.equal "integer arithmetic" 42 (6 * 7)].
