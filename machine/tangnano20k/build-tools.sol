B = use "../../sol/lib/build".
abi width = case width of "32" -> "ilp32" | "64" -> "lp64" | _ -> error "FPR_XLEN must be 32 or 64".
libc u = path = B.query ["riscv64-unknown-elf-gcc","-print-file-name=picolibc.specs"];
  if and (Str.startsWith "/" path) (B.exists "-f" path) then ["--specs=picolibc.specs"] else [].
