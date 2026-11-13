# Run in the FP-RISC checkout. Produces the Graviton POS1 executable.
B = use "../../sol/lib/build".
> out = "deploy/aws-pos1/out";
  _ = B.command ["mkdir","-p",out];
  _ = B.command ["./fpr","build","examples/pos1.fpr","--target=linux-aarch64","--cc",B.setting "CROSS_CC" "aarch64-linux-gnu-gcc","--harts",B.setting "HARTS" "2","-o","{out}/pos1"];
  B.command ["file","{out}/pos1"].
