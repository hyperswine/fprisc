# run.py --build passes selected workload names and its compiler environment.
B = use "../../../sol/lib/build".
variants name = if or (name == "wordfreq") (name == "treemap") then
  [("fpr",name),("fpr-mutmap","{name}_mutmap")] else [("fpr",name)].
compile compiler root name (label, source) =
  target = "{root}/bin-fpr/{name}.{label}";
  _ = B.command [compiler,"build","-o",target,"{root}/{source}.fpr"];
  print "built {name}.{label}".
> names = (case args Unit of [] -> ["csv","wordfreq","format","records","treemap","sim"] | selected -> selected);
  compiler = (case unwrap (Env.get "FPR") of EnvText path -> path | EnvMissing -> "fpr");
  root = B.query ["pwd","-P"];
  _ = B.command ["mkdir","-p","bin-fpr"];
  _ = List.map (fn n -> List.map (compile compiler root n) (variants n)) names; Unit.
