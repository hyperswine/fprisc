# Build and order release-index entries. When ssh-keygen is present, also sign
# and verify with a throwaway key. The production fpr-release key is not used.
T = use "../../sol/lib/test".
C = use "../../tools/publish-release-index-core".
B = use "../../sol/lib/build".
J = use "../../sol/lib/json".

must r = case r of Ok x -> x | Err e -> error e.

cat path =
  ProcessResult code out err = unwrap (Proc.runNow (ProcessSpec ["cat", path] "" [] "" 0));
  if code == 0 then out else error "cannot read {path}: {err}".

same path expected = cat path == cat expected.

hasKeygen u = C.existsFile "/usr/bin/ssh-keygen" or C.existsFile "/usr/local/bin/ssh-keygen".

entriesOf path = must (J.items (must (J.get "entries" (must (C.readJson path))))).

signChecks : unsafe String -> String -> List (String, String) .
signChecks work fixtures =
  if hasKeygen Unit then
    _ = B.command ["cp", "-a", "{fixtures}/tap", "{work}/tap"];
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
    [
      T.equal "signed fprisc index" True (same "{work}/tap/toolchains/fprisc.json" "{fixtures}/expected/fprisc.json"),
      T.equal "signed qos index" True (same "{work}/tap/toolchains/qos-portable.json" "{fixtures}/expected/qos-portable.json"),
      T.equal "fprisc signature" True (case C.verifyIndex "{work}/key.pub" "{work}/tap/toolchains/fprisc.json" "{work}/tap/toolchains/fprisc.json.sig" of Ok _ -> True | Err _ -> False),
      T.equal "qos signature" True (case C.verifyIndex "{work}/key.pub" "{work}/tap/toolchains/qos-portable.json" "{work}/tap/toolchains/qos-portable.json.sig" of Ok _ -> True | Err _ -> False)]
  else
    _ = print "skipping signature checks: ssh-keygen is not installed";
    [].

main : unsafe Unit -> Unit .
main u =
  root = Str.trim (B.query ["git", "rev-parse", "--show-toplevel"]);
  fixtures = "{root}/tests/fixtures/release-index";
  work = Str.trim (B.query ["mktemp", "-d"]);
  _ = B.command ["mkdir", "-p", "{work}/entries"];
  _ = C.cli [
    "--entry-only",
    "--assets", "{fixtures}/assets",
    "--entries-dir", "{work}/entries",
    "--cache", "{work}/cache",
    "fprisc:0.2.0", "qos:0.2.0"];
  fprEntry = must (C.readJson "{work}/entries/fprisc-0.2.0-entry.json");
  qosEntry = must (C.readJson "{work}/entries/qos-portable-0.2.0-entry.json");
  (fprNext, _) = must (C.insertEntries (entriesOf "{fixtures}/tap/toolchains/fprisc.json") [fprEntry]);
  (qosNext, _) = must (C.insertEntries (entriesOf "{fixtures}/tap/toolchains/qos-portable.json") [qosEntry]);
  conflict = C.entryObject "fprisc" "0.2.0" "macos-arm64"
    "https://github.com/hyperswine/fprisc/releases/download/v0.2.0/fprisc-0.2.0-macos-arm64.tar.gz"
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" 26 "27.2" ["xcode-clt"] False;
  conflicted = case C.insertEntries fprNext [conflict] of Err _ -> True | Ok _ -> False;
  qosMeta = must (C.readJson "{fixtures}/assets/qos-0.2.0/release.json");
  T.run (List.append [
    T.equal "0.9 before 0.10" (0 - 1) (must (C.compareVersions "0.9.0" "0.10.0")),
    T.equal "0.13.1 before 0.14.0" (0 - 1) (must (C.compareVersions "0.13.1" "0.14.0")),
    T.equal "equal versions" 0 (must (C.compareVersions "0.15.0" "0.15.0")),
    T.equal "parse qos" ("qos-portable", "0.6.0") (must (C.parseSpec "qos:0.6.0")),
    T.equal "parse bare version" ("fprisc", "0.15.0") (must (C.parseSpec "0.15.0")),
    T.equal "fprisc 0.2.0 entry" True (same "{work}/entries/fprisc-0.2.0-entry.json" "{fixtures}/expected/fprisc-0.2.0-entry.json"),
    T.equal "qos 0.2.0 entry" True (same "{work}/entries/qos-portable-0.2.0-entry.json" "{fixtures}/expected/qos-portable-0.2.0-entry.json"),
    T.equal "fprisc index order" True (C.indexText "fprisc" fprNext == cat "{fixtures}/expected/fprisc.json"),
    T.equal "qos index order" True (C.indexText "qos-portable" qosNext == cat "{fixtures}/expected/qos-portable.json"),
    T.equal "qos requires" ["xcode-clt", "homebrew:libgit2", "homebrew:libarchive", "homebrew:glfw"] (must (C.inferRequires qosMeta "macos-arm64")),
    T.that "refuses a different hash for the same version" conflicted] (signChecks work fixtures)).
> main Unit.
