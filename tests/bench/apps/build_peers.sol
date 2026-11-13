# Run from tests/bench/apps with sol build_peers.sol.
B = use "../../../sol/lib/build".
workloads = [("csv","Csv"),("wordfreq","Wordfreq"),("format","Format"),
             ("records","Records"),("treemap","Treemap"),("sim","Sim")].
javaLauncher path class =
  source = "#!/bin/sh\nexec java -cp \"$(dirname \"$0\")/java-classes\" {class} \"$@\"\n";
  bytes = unwrap (Utf8.encode source);
  _ = B.command ["rm","-f",path];
  writer = unwrap (Stream.openWrite path (Bytes.len bytes));
  (result,next) = Stream.writeChunk bytes writer; _ = unwrap result; _ = Stream.closeWrite next;
  B.command ["chmod","+x",path].
build bin opt (name,class) =
  _ = print "== {name}";
  _ = B.command ["cc","-O2","-o","{bin}/{name}.c","c/{name}.c"];
  _ = B.command ["rustc","-C","opt-level=3","-o","{bin}/{name}.rust","rust/{name}.rs"];
  _ = B.inDirectory "" [("GO111MODULE","off")] ["go","build","-o","{bin}/{name}.go","go/{name}.go"];
  _ = B.command ["cp","ocaml/{name}.ml","{bin}/ocaml-build/{name}.ml"];
  _ = B.inDirectory "{bin}/ocaml-build" [] (List.concat [["ocamlfind","ocamlopt"],opt,["-package","unix","-o","{bin}/{name}.ocaml","{name}.ml"]]);
  _ = B.command ["javac","-d","{bin}/java-classes","java/{class}.java"];
  javaLauncher "{bin}/{name}.java" class.
> bin = "{B.query ["pwd","-P"]}/bin";
  _ = B.command ["mkdir","-p","{bin}/ocaml-build","{bin}/java-classes"];
  config = B.query ["ocamlopt","-config"];
  opt = (if List.any (fn line -> line == "flambda: true") (Str.lines config) then ["-O3"] else []);
  _ = List.map (build bin opt) workloads;
  print "built into {bin}".
