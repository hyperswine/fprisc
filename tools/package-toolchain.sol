B = use "../sol/lib/build".
CLI = use "../sol/lib/cli".
D = use "../sol/lib/digest".
J = use "../sol/lib/json".
M = use "toolchain-macho".
Link = use "toolchain-linkage".
I = use "toolchain-inventory".
F = use "toolchain-files".
Freeze = use "toolchain-freeze".
Notices = use "toolchain-notices".
Release = use "toolchain-release".
field obj key = unwrap (J.get key obj).
textField obj key = unwrap (J.text (field obj key)).
digits s = s != "" and List.all (fn c -> c >= 48 and c <= 57) (Str.codes s).
versionCore version =
  pieces = Str.split 45 version;
  core = case pieces of first :: _ -> first | [] -> "";
  components = Str.split 46 core;
  suffix = case pieces of [_] -> True | [_,rc] -> Str.startsWith "rc" rc and digits (Str.slice rc 2 (Str.len rc)) | _ -> False;
  if suffix and version == Str.join "-" pieces and core == Str.join "." components and List.len components == 3 and List.all digits components
  then core else error "expected MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-rcN".
require ok why = if ok then Unit else error why.
libraryNotices sdk lib =
  paths = unwrap (J.items (field lib "notices"));
  require (paths != [] and List.all (fn value -> B.exists "-f" (sdk + "/" + unwrap (J.text value))) paths)
    ("missing bundled library notices for " + textField lib "file").
releaseFiles sdk =
  ProcessResult status out err = unwrap (Proc.runNow (ProcessSpec ["find",".","(","-name",".git","-o","-name","dist-newstyle",
    "-o","-name","*.hs","-o","-name","*.o","-o","-name","*.hi",")","-print0"] sdk [] "" 0));
  if status != 0 then error "cannot inspect release files: {err}" else
    if out == "" then Unit else error ("unexpected release file: " + (Str.split 0 out ! 0)).
verify : unsafe String -> String -> String -> String -> J.Json -> String .
verify root prefix core notices meta =
  sdk = "{prefix}/libexec/fprisc";
  revision = B.query ["git","-C",root,"rev-parse","HEAD"];
  _ = require (B.query ["git","-C",root,"status","--porcelain"] == "") "commit FP-RISC changes before packaging a release";
  _ = require (field meta "sourceDirty" == J.JBool False and textField meta "sourceRevision" == revision) "stage the toolchain from this clean commit";
  _ = require (textField meta "version" == "fpr {core}") "staged compiler version differs from requested release";
  host = field meta "host";
  _ = require (textField host "system" == "Darwin" and textField host "machine" == "arm64") "release packaging is qualified only for macOS ARM64";
  recorded = field meta "files";
  actual = I.inventory prefix;
  entries = unwrap (J.fields actual);
  # JSON object membership is independent of insertion order.
  _ = require (List.len (unwrap (J.fields recorded)) == List.len entries and List.all (fn pair ->
    (name,value) = pair; J.get name recorded == Ok value) entries and unwrap (D.sha256File "{sdk}/fpr") == textField meta "compilerSha256")
    "staged toolchain inventory mismatch";
  _ = require ((Str.split 46 (textField meta "minimumMacOS") ! 0) == "27") "review the formula macOS requirement before packaging";
  _ = releaseFiles sdk;
  _ = require (B.exists "-f" "{sdk}/LICENSE") "the stage must include the FP-RISC license";
  _ = List.map (libraryNotices sdk) (unwrap (J.items (field meta "bundledLibraries")));
  plan = field meta "cabalPlan";
  _ = require (field plan "recorded" == J.JBool True) "the stage has no Cabal plan for its compiler";
  compiler = textField plan "compiler";
  _ = Freeze.verify "{sdk}/toolchain.json" "{root}/cabal.project.freeze";
  _ = Notices.verify notices compiler;
  compiler.
package : unsafe String -> String -> String -> String -> String -> Unit .
package root prefix version notices output =
  core = versionCore version;
  meta = unwrap (J.parse (F.readText "{prefix}/libexec/fprisc/toolchain.json"));
  compiler = verify root prefix core notices meta;
  _ = B.command ["mkdir","-p",M.parent output];
  _ = B.command ["mkdir",output];
  work = tempDir "fprisc-release";
  bundle = "{work}/fprisc-{version}-macos-arm64";
  _ = B.command ["cp","-RpP",prefix,bundle];
  _ = B.command ["find",bundle,"!","-type","l","-exec","chmod","u+w","\{}","+"];
  sdk = "{bundle}/libexec/fprisc";
  _ = Link.verify bundle "{sdk}/fpr";
  _ = B.command ["mkdir","{sdk}/licenses"];
  _ = B.command ["cp","-RpL",notices + "/.","{sdk}/licenses"];
  withCompiler = J.set "compilerNotices" (J.JStr compiler) (J.set "release" (J.JStr version) meta);
  qualified = J.set "qualification" (J.JStr "release candidate: installed runtime qualification required; archived Python harness retired") withCompiler;
  manifest = J.set "files" (I.inventory bundle) qualified;
  # tar reads the private copy immediately. The transaction's deferred writes
  # would become visible only after tar exits.
  scratch = "{sdk}/toolchain.json";
  proc = ProcessSpec ["cat"] "" [] "" 0;
  _ = (case Proc.pipeline (PipelineSpec [proc] (PipeBytes (unwrap (Utf8.encode (J.pretty manifest + "\n")))) (PipePublish scratch True) PipeOutputInherit 0 PipeFail) of
    Ok (PipelineResult 0 _ _ _) -> Unit | failed -> error "writing release manifest failed: {failed}");
  Release.release root work version output.
main : unsafe Unit -> Unit .
> parsed = unwrap (CLI.parse (List.map (fn n -> CLI.Option n "" CLI.One) ["root","sdk","version","notices","output"]) (args Unit));
  required n = CLI.valueOr "" n parsed;
  if CLI.operands parsed != [] or List.any (fn n -> required n == "") ["sdk","version","notices","output"]
  then error "expected --sdk PREFIX --version VERSION --notices DIRECTORY --output DIRECTORY [--root CHECKOUT]" else
    explicit = required "root";
    root = (if explicit == "" then B.query ["git","rev-parse","--show-toplevel"] else F.canonical explicit);
    out = required "output";
    package root (F.canonical (required "sdk")) (required "version") (F.canonical (required "notices"))
      (if Str.startsWith "/" out then out else unwrap (IO.cwd Unit) + "/" + out).
