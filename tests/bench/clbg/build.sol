# Run from tests/bench/clbg: sol build.sol [program ...]
# Builds every peer into bin/ and the FP-RISC programs into bin-fpr/ (FPR selects the compiler),
# then writes the fasta inputs into data/ when they are missing.
B = use "../../../sol/lib/build".
all = ["binarytrees","fannkuchredux","nbody","spectralnorm","mandelbrot","fasta","knucleotide","revcomp"].
className name = "{Str.upper (Str.sub name 0 1)}{Str.slice name 1 (Str.len name)}".
build compiler bin opt name =
  _ = print "== {name}";
  _ = B.command ["cc","-O2","-o","{bin}/{name}.c","c/{name}.c","-lm"];
  _ = B.command ["rustc","-C","opt-level=3","-o","{bin}/{name}.rust","rust/{name}.rs"];
  _ = B.runWith [("GO111MODULE","off")] ["go","build","-o","{bin}/{name}.go","go/{name}.go"];
  _ = B.command ["cp","ocaml/{name}.ml","{bin}/ocaml-build/{name}.ml"];
  _ = B.inDirectory "{bin}/ocaml-build" [] (List.append ["ocamlfind","ocamlopt"] (List.append opt ["-package","unix","-o","{bin}/{name}.ocaml","{name}.ml"]));
  _ = B.command ["ghc","-O2","-v0","-outputdir","{bin}/hs-build/{name}","-o","{bin}/{name}.haskell","haskell/{name}.hs"];
  _ = B.command ["javac","-d","{bin}/java-classes","java/{className name}.java"];
  B.command [compiler,"build","-o","bin-fpr/{name}","{name}.fpr"].
fastaInput bin n =
  path = "data/fasta-{n}.txt";
  if B.exists "-s" path then Unit else
    B.command ["sh","-c","\"$0\" \"$1\" > \"$2\".tmp && mv \"$2\".tmp \"$2\"","{bin}/fasta.c","{n}",path].
inputs bin = _ = fastaInput bin 1000000; fastaInput bin 2500000.
>! names = (case args Unit of [] -> all | selected -> selected);
  compiler = B.setting "FPR" "fpr";
  bin = "{B.query ["pwd","-P"]}/bin";
  _ = B.command ["mkdir","-p","{bin}/ocaml-build","{bin}/hs-build","{bin}/java-classes","bin-fpr","data"];
  opt = (if List.any (fn line -> line == "flambda: true") (Str.lines (B.query ["ocamlopt","-config"])) then ["-O3"] else []);
  _ = List.map (build compiler bin opt) names;
  _ = (if List.has "fasta" names then inputs bin else Unit);
  print "built into {bin} and bin-fpr".
