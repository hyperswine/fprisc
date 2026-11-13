# Package the qualified private copy and derive every release file from the archive.
B = use "../sol/lib/build".
D = use "../sol/lib/digest".
J = use "../sol/lib/json".
F = use "toolchain-files".
substitute : unsafe String -> List (String,String) -> String .
substitute text replacements = case replacements of
    [] -> text
  | (key,value) :: rest -> substitute (Str.replace key value text) rest.
release : unsafe String -> String -> String -> String -> Unit .
release root parent version output =
  name = "fprisc-{version}-macos-arm64";
  file = "{name}.tar.gz";
  archive = "{output}/{file}";
  meta = unwrap (J.parse (F.readText "{parent}/{name}/libexec/fprisc/toolchain.json"));
  _ = B.runWith [("COPYFILE_DISABLE","1")] ["tar","-czf",archive,"-C",parent,name];
  digest = unwrap (D.sha256File archive);
  sums = "{digest}  {file}\n";
  record = J.set "sha256" (J.JStr digest) (J.set "archive" (J.JStr file) meta);
  template = F.readText "{root}/packaging/homebrew/fprisc.rb.in";
  compiler = (Str.split 45 version) ! 0;
  formula = substitute template [("__COMPILER_VERSION__",compiler),("__VERSION__",version),
                                 ("__ARCHIVE__",file),("__SHA256__",digest)];
  _ = writePath "{output}/SHA256SUMS" sums;
  _ = writePath "{output}/release.json" (J.pretty record + "\n");
  _ = writePath "{output}/fprisc.rb" formula;
  _ = print archive;
  print "SHA256 {digest}".
main : unsafe Unit -> Unit .
> case args Unit of [root,parent,version,output] -> release root parent version output
  | _ -> error "expected SOURCE_ROOT BUNDLE_PARENT VERSION OUTPUT".
