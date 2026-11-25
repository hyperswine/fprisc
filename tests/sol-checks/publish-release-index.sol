# Build, order, sign and verify release-index entries with a throwaway key.
# The production fpr-release private key is not used here.
T = use "../../sol/lib/test".
C = use "../../tools/publish-release-index-core".
B = use "../../sol/lib/build".
J = use "../../sol/lib/json".

must r = case r of Ok x -> x | Err e -> error e.

cat path =
  ProcessResult code out err = unwrap (Proc.runNow (ProcessSpec ["cat", path] "" [] "" 0));
  if code == 0 then out else error "cannot read {path}: {err}".

same path expected = cat path == cat expected.

main : unsafe Unit -> Unit .
main u =
  root = Str.trim (B.query ["git", "rev-parse", "--show-toplevel"]);
  fixtures = "{root}/tests/fixtures/release-index";
  work = Str.trim (B.query ["mktemp", "-d"]);
  _ = B.command ["cp", "-a", "{fixtures}/tap", "{work}/tap"];
  _ = B.command ["mkdir", "-p", "{work}/entries"];
  _ = B.command [C.sshKeygen Unit, "-q", "-t", "ed25519", "-f", "{work}/key", "-N", "", "-C", "fpr-release"];
  _ = C.cli [
    "--tap", "{work}/tap",
    "--key", "{work}/key",
    "--pub", "{work}/key.pub",
    "--assets", "{fixtures}/assets",
    "--entries-dir", "{work}/entries",
    "--cache", "{work}/cache",
    "--allow-unsigned",
    "fprisc:0.2.0", "qos:0.2.0"];
  _ = C.cli [
    "--tap", "{work}/tap",
    "--key", "{work}/key",
    "--pub", "{work}/key.pub",
    "--assets", "{fixtures}/assets",
    "--entries-dir", "{work}/entries",
    "--cache", "{work}/cache",
    "--allow-unsigned",
    "fprisc:0.2.0", "qos:0.2.0"];
  qosMeta = must (C.readJson "{fixtures}/assets/qos-0.2.0/release.json");
  existing = must (J.items (must (J.get "entries" (must (C.readJson "{work}/tap/toolchains/fprisc.json")))));
  conflict = C.entryObject "fprisc" "0.2.0" "macos-arm64"
    "https://github.com/hyperswine/fprisc/releases/download/v0.2.0/fprisc-0.2.0-macos-arm64.tar.gz"
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" 26 "27.2" ["xcode-clt"] False;
  conflicted = case C.insertEntries existing [conflict] of Err _ -> True | Ok _ -> False;
  T.run [
    T.equal "0.9 before 0.10" (0 - 1) (must (C.compareVersions "0.9.0" "0.10.0")),
    T.equal "0.13.1 before 0.14.0" (0 - 1) (must (C.compareVersions "0.13.1" "0.14.0")),
    T.equal "equal versions" 0 (must (C.compareVersions "0.15.0" "0.15.0")),
    T.equal "parse qos" ("qos-portable", "0.6.0") (must (C.parseSpec "qos:0.6.0")),
    T.equal "parse bare version" ("fprisc", "0.15.0") (must (C.parseSpec "0.15.0")),
    T.equal "fprisc 0.2.0 entry" True (same "{work}/entries/fprisc-0.2.0-entry.json" "{fixtures}/expected/fprisc-0.2.0-entry.json"),
    T.equal "qos 0.2.0 entry" True (same "{work}/entries/qos-portable-0.2.0-entry.json" "{fixtures}/expected/qos-portable-0.2.0-entry.json"),
    T.equal "fprisc index order" True (same "{work}/tap/toolchains/fprisc.json" "{fixtures}/expected/fprisc.json"),
    T.equal "qos index order" True (same "{work}/tap/toolchains/qos-portable.json" "{fixtures}/expected/qos-portable.json"),
    T.equal "fprisc signature" True (case C.verifyIndex "{work}/key.pub" "{work}/tap/toolchains/fprisc.json" "{work}/tap/toolchains/fprisc.json.sig" of Ok _ -> True | Err _ -> False),
    T.equal "qos signature" True (case C.verifyIndex "{work}/key.pub" "{work}/tap/toolchains/qos-portable.json" "{work}/tap/toolchains/qos-portable.json.sig" of Ok _ -> True | Err _ -> False),
    T.equal "qos requires" ["xcode-clt", "homebrew:libgit2", "homebrew:libarchive", "homebrew:glfw"] (must (C.inferRequires qosMeta "macos-arm64")),
    T.that "refuses a different hash for the same version" conflicted].
> main Unit.
