# Stage a standalone SDK and record the exact compiler, input plan and staged files.
B = use "../sol/lib/build".
CLI = use "../sol/lib/cli".
D = use "../sol/lib/digest".
J = use "../sol/lib/json".
Lib = use "toolchain-bundle-libs".
Link = use "toolchain-linkage".
M = use "toolchain-macho".
F = use "toolchain-files".
P = use "toolchain-plan".
I = use "toolchain-inventory".
S = use "toolchain-sources".
absolute path = if Str.startsWith "/" path then path else unwrap (IO.cwd Unit) + "/" + path.
version binary =
  ProcessResult status env err = unwrap (Proc.runNow (ProcessSpec ["env","-0"] "" [] "" 0));
  if status != 0 then error "listing compiler environment failed: {err}" else
    owned = List.filter (fn entry -> Str.startsWith "FPR_" entry or Str.startsWith "SOL_" entry) (Str.split 0 env);
    remove = List.concat (List.map (fn entry -> ["-u",substr entry 0 (Str.find 61 entry)]) owned);
    B.query (List.concat [["env"],remove,[binary,"--version"]]).
darwinInfo : unsafe String -> String -> J.Json -> List (String,J.Json) .
darwinInfo prefix exe bundled =
  _ = Link.verify prefix exe;
  lines = Str.lines (B.query ["vtool","-show-build",exe]);
  values = List.concat (List.map (fn line -> case Str.words (Str.trim line) of
    ["minos",v] -> [v] | _ -> []) lines);
  minimum = case values of v :: _ -> v | [] -> error "missing macOS deployment target in {exe}";
  deps = List.drop 1 (Str.lines (B.query ["otool","-L",exe]));
  [("minimumMacOS",J.JStr minimum),("nativeLibraries",J.JArr (List.map J.JStr deps)),("bundledLibraries",bundled)].
stage : unsafe String -> String -> String -> String -> Unit .
stage root binary output plan =
  source = F.canonical binary;
  _ = B.command ["mkdir","-p",M.parent output];
  _ = B.command ["mkdir",output];
  sdk = "{output}/libexec/fprisc";
  exe = "{sdk}/fpr";
  _ = B.command ["mkdir","-p",sdk];
  _ = B.command ["cp","-p",source,exe];
  system = B.query ["uname","-s"];
  bundled = (if system == "Darwin" then Lib.bundle sdk exe else J.JArr []);
  _ = S.stage root output;
  digest = unwrap (D.sha256File exe);
  links = J.JObj (List.map (fn n -> (n,J.JStr (B.query ["readlink","{output}/bin/{n}"]))) ["fpr","sol"]);
  base = [("format",J.JNum 1),("qualification",J.JStr "private staging, not a public release"),
          ("version",J.JStr (version exe)),("sourceRevision",J.JStr (B.query ["git","-C",root,"rev-parse","HEAD"])),
          ("sourceDirty",J.JBool (B.query ["git","-C",root,"status","--porcelain"] != "")),("compilerSha256",J.JStr digest),
          ("host",J.JObj [("system",J.JStr system),("machine",J.JStr (B.query ["uname","-m"]))]),
          ("nativeBuildDependencies",J.JArr [J.JStr "C compiler, assembler/linker and platform SDK"]),("links",links)];
  native = (if system == "Darwin" then darwinInfo output exe bundled else []);
  inventory = I.inventory output;
  meta = J.JObj (List.concat [base,native,[("cabalPlan",P.plan plan source),("files",inventory)]]);
  _ = writePath "{sdk}/toolchain.json" (J.pretty meta + "\n");
  print (J.render (J.JObj [("prefix",J.JStr output),("compilerSha256",J.JStr digest),
                           ("files",J.JNum (List.len (unwrap (J.fields inventory))))])).
main : unsafe Unit -> Unit .
> parsed = unwrap (CLI.parse [CLI.Option "root" "" CLI.One,CLI.Option "output" "" CLI.One,
                              CLI.Option "binary" "" CLI.One,CLI.Option "plan" "" CLI.One] (args Unit));
  output = CLI.valueOr "" "output" parsed;
  explicit = CLI.valueOr "" "root" parsed;
  root = (if explicit == "" then B.query ["git","rev-parse","--show-toplevel"] else F.canonical explicit);
  if output == "" or CLI.operands parsed != [] then error "expected --output PREFIX [--binary FPR] [--plan PLAN] [--root CHECKOUT]" else
    stage root (CLI.valueOr "{root}/fpr" "binary" parsed) (absolute output) (CLI.valueOr "{root}/dist-newstyle/cache/plan.json" "plan" parsed).
