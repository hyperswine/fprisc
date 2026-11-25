# Stage a toolchain the same way a release does, pack it with the same tar
# invocation as tools/toolchain-release.sol, extract it to a path that contains
# a space, and smoke-test the archive with HOME empty and PATH limited to the
# archive's bin, /usr/bin and /bin.
#
# A native `fpr test` / `fpr build` in a new project is what catches a missing
# runtime header such as bigint.inc (the 0.15.0 packaging hole: the first
# candidate from 0c893a24 failed with "'bigint.inc' file not found").
#
# Official packaging (tools/package-toolchain.sol) is still macOS ARM64 only.
# This script reuses tools/stage-toolchain.sol and the release tar flags, so a
# Linux CI runner can still exercise the staged tree and archive layout.
B = use "../sol/lib/build".
CLI = use "../sol/lib/cli".
require ok why = if ok then Unit else error why.
absolute path = if Str.startsWith "/" path then path else unwrap (IO.cwd Unit) + "/" + path.
hostTriple system machine =
  os = if system == "Darwin" then "macos" else if system == "Linux" then "linux"
       else error "unrecognised host system: {system}";
  arch = if machine == "aarch64" then "arm64" else machine;
  "{os}-{arch}".
compilerVersion text =
  trimmed = Str.trim text;
  case Str.split 32 trimmed of
    "fpr" :: v :: _ -> v
  | _ -> error "unexpected fpr --version: {trimmed}".
# env -i is required: ProcessSpec env is merged with the inherited environment,
# so it cannot drop FPR_HOME or a developer PATH. HOME stays empty. Sol journals
# need an absolute state directory (SOL_STATE_DIR, else ~/.local/state/sol); with
# HOME empty that fallback is not absolute, so the documented override points
# under TMPDIR.
smokeArgv prefix tmp argv =
  List.append ["env","-i","HOME=","PATH={prefix}/bin:/usr/bin:/bin",
               "TMPDIR={tmp}","SOL_STATE_DIR={tmp}/sol-state",
               "LANG=C.UTF-8","LC_ALL=C.UTF-8"] argv.
run : String -> String -> String -> List String -> ProcessResult .
run prefix tmp cwd argv =
  unwrap (Proc.runNow (ProcessSpec (smokeArgv prefix tmp argv) cwd [] "" 0)).
failcmd argv status out err = error "command failed ({status}): {argv}\n{err}{out}".
mustRun : String -> String -> String -> List String -> ProcessResult .
mustRun prefix tmp cwd argv =
  ProcessResult status out err = run prefix tmp cwd argv;
  if status == 0 then ProcessResult status out err else failcmd argv status out err.
mustContain : String -> String -> String -> List String -> String -> String .
mustContain prefix tmp cwd argv needle =
  ProcessResult status out err = mustRun prefix tmp cwd argv;
  text = out + err;
  _ = require (Str.contains needle text) "expected {needle} in output of {argv}:\n{text}";
  text.
forbidden line = Str.contains "/opt/homebrew" line or Str.contains "/home/linuxbrew" line
  or Str.contains "/usr/local" line.
inspectImage : String -> Bool -> String -> Unit .
inspectImage system required path =
  argv = if system == "Darwin" then ["otool","-L",path] else ["ldd",path];
  ProcessResult status out err = unwrap (Proc.runNow (ProcessSpec argv "" [] "" 0));
  text = out + err;
  bad = List.filter forbidden (Str.lines text);
  if bad != [] then error "toolchain binary {path} names a Homebrew or /usr/local library: {bad}\n{text}"
  else if status != 0 then
    if required then error "could not inspect toolchain binary {path}:\n{text}" else Unit
  else Unit.
listFiles : String -> List String .
listFiles dir =
  ProcessResult status out err = unwrap (Proc.runNow (ProcessSpec ["find",dir,"-type","f","-print"] "" [] "" 0));
  if status != 0 then error "listing {dir} failed: {err}{out}"
  else List.filter (fn p -> p != "") (Str.lines out).
checkLinkage : String -> String -> Unit .
checkLinkage system prefix =
  sdk = "{prefix}/libexec/fprisc";
  lib = "{sdk}/lib";
  extra = if B.exists "-d" lib
          then List.filter (fn p -> not (Str.contains "/licenses/" p)) (listFiles lib)
          else [];
  _ = inspectImage system True "{sdk}/fpr";
  _ = List.map (inspectImage system False) extra;
  Unit.
incDirs = ["runtime","machine/posix","machine/unix","core","std","sol/lib",".fpr"].
listInc : String -> List String .
listInc root =
  dirs = List.filter (fn dir -> B.exists "-d" "{root}/{dir}") incDirs;
  case dirs of
    [] -> []
  | _ ->
      argv = List.concat [["find"],dirs,["-type","f","-name","*.inc","-print"]];
      ProcessResult status out err = unwrap (Proc.runNow (ProcessSpec argv root [] "" 0));
      if status != 0 then error "listing staged .inc files failed: {err}{out}"
      else List.filter (fn p -> p != "") (Str.lines out).
requireIncludes : String -> String -> Unit .
requireIncludes root sdk =
  incs = listInc root;
  _ = require (incs != []) "expected at least one .inc under the staged source directories";
  _ = require (B.exists "-f" "{sdk}/LICENSE") "staged toolchain is missing LICENSE";
  _ = require (B.exists "-f" "{sdk}/runtime/bigint.inc")
        "staged toolchain is missing runtime/bigint.inc (the 0.15.0 packaging hole)";
  _ = List.map (fn rel -> require (B.exists "-f" "{sdk}/{rel}") "staged toolchain is missing {rel}") incs;
  Unit.
# writePath is deferred until commit; the next Proc.runNow must see the file.
writeFile : String -> String -> Unit .
writeFile path body =
  proc = ProcessSpec ["cat"] "" [] "" 0;
  case Proc.pipeline (PipelineSpec [proc] (PipeBytes (unwrap (Utf8.encode (body + "\n")))) (PipePublish path True) PipeOutputInherit 0 PipeFail) of
    Ok (PipelineResult 0 _ _ _) -> Unit
  | failed -> error "writing {path} failed: {failed}".
smoke : String -> String -> String -> String -> Unit .
smoke root binary work version =
  system = B.query ["uname","-s"];
  triple = hostTriple system (B.query ["uname","-m"]);
  name = "fprisc-{version}-{triple}";
  bundleParent = "{work}/bundle";
  staged = "{bundleParent}/{name}";
  archive = "{work}/{name}.tar.gz";
  extractParent = "{work}/extract prefix";
  prefix = "{extractParent}/{name}";
  tmp = "{work}/tmp";
  project = "{work}/project";
  _ = print "archive-smoke: staging {name}";
  _ = B.command ["mkdir","-p",bundleParent,tmp,project];
  _ = B.command [binary,"sol","{root}/tools/stage-toolchain.sol","--root",root,
                 "--binary",binary,"--output",staged];
  sdk = "{prefix}/libexec/fprisc";
  _ = print "archive-smoke: packing {archive}";
  _ = B.runWith [("COPYFILE_DISABLE","1")] ["tar","-czf",archive,"-C",bundleParent,name];
  _ = require (B.exists "-f" archive) "archive was not created: {archive}";
  _ = print "archive-smoke: extracting to {extractParent}";
  _ = B.command ["mkdir","-p",extractParent];
  _ = B.runWith [("COPYFILE_DISABLE","1")] ["tar","-xzf",archive,"-C",extractParent];
  _ = require (B.exists "-x" "{prefix}/bin/fpr") "extracted archive is missing bin/fpr";
  _ = require (B.exists "-x" "{prefix}/bin/sol") "extracted archive is missing bin/sol";
  _ = requireIncludes root sdk;
  _ = print "archive-smoke: fpr --version / sol --version";
  _ = mustContain prefix tmp project ["fpr","--version"] "fpr ";
  _ = mustContain prefix tmp project ["sol","--version"] "Sol ";
  _ = print "archive-smoke: fpr new hello";
  _ = mustRun prefix tmp project ["fpr","new","hello"];
  hello = "{project}/hello";
  _ = print "archive-smoke: fpr check";
  _ = mustRun prefix tmp hello ["fpr","check"];
  _ = print "archive-smoke: fpr test (native)";
  _ = mustRun prefix tmp hello ["fpr","test"];
  _ = print "archive-smoke: fpr run -- Ada";
  _ = mustContain prefix tmp hello ["fpr","run","--","Ada"] "hello, Ada";
  _ = print "archive-smoke: fpr build (native)";
  _ = mustRun prefix tmp hello ["fpr","build"];
  _ = print "archive-smoke: Sol script using std/order";
  _ = writeFile "{project}/order.sol"
        ("Order = use \"std/order\".\n" +
         "> print (if Order.isLess (Order.int 2 3) then \"order: less\" else \"order: other\").");
  _ = mustContain prefix tmp project ["sol","order.sol"] "order: less";
  _ = print "archive-smoke: linkage (no Homebrew or /usr/local)";
  _ = checkLinkage system prefix;
  print "archive-smoke: passed ({archive})".
main : unsafe Unit -> Unit .
main Unit =
  parsed = unwrap (CLI.parse [CLI.Option "root" "" CLI.One,CLI.Option "binary" "" CLI.One,
                              CLI.Option "work" "" CLI.One] (args Unit));
  if CLI.operands parsed != [] then error "expected [--root CHECKOUT] [--binary FPR] [--work DIRECTORY]" else
    explicitRoot = CLI.valueOr "" "root" parsed;
    root = (if explicitRoot == "" then B.query ["git","rev-parse","--show-toplevel"] else absolute explicitRoot);
    binary = CLI.valueOr "{root}/fpr" "binary" parsed;
    explicitWork = CLI.valueOr "" "work" parsed;
    work = if explicitWork == "" then tempDir "fprisc-archive-smoke" else absolute explicitWork;
    _ = require (B.exists "-x" binary) "compiler is not executable: {binary}";
    _ = B.command ["mkdir","-p",work];
    version = compilerVersion (B.query [binary,"--version"]);
    smoke root (absolute binary) work version.
> main Unit.
