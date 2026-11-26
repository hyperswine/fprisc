# Build a Linux toolchain archive in a container and qualify it
# (docs/2026-11-27-LINUX-RELEASE-ARCHIVE.md):
#   1. the image packaging/linux/Dockerfile: Debian bookworm (glibc 2.36),
#      GHC 9.8.2, libcurl from bookworm-backports, libgit2 1.9.1 from source;
#   2. in it: check out --rev, `make fpr`, then tools/archive-smoke.sol, which
#      stages with bundled libraries (tools/toolchain-elf.sol), packs with the
#      release tar flags and smoke-tests the extracted archive;
#   3. the archive alone in a fresh debian:bookworm-slim with only gcc: fpr and
#      sol run, a new project checks, tests and runs, and a Sol script runs.
#   ./fpr sol tools/linux-archive.sol --platform linux/amd64 --rev HEAD --out DIR [--cache DIR]
# The build tree and cabal store persist under --cache (default
# ~/.cache/fprisc-linux/<arch>), which must be a directory the container
# runtime shares (colima shares $HOME). Uses whatever `docker` context is set.
B = use "../sol/lib/build".
CLI = use "../sol/lib/cli".
buildSteps = Str.join " && " [
  "git config --global --add safe.directory /src", "git config --global --add safe.directory /src/.git",
  "if [ -d /build/fprisc/.git ]; then cd /build/fprisc && git fetch -q /src && git checkout -q -f \"$REV\"; else git clone -q /src /build/fprisc && cd /build/fprisc && git checkout -q \"$REV\"; fi",
  "([ -f /root/.cabal/packages/hackage.haskell.org/01-index.tar ] || cabal update >/dev/null)",
  "make fpr", "./fpr --version", "rm -rf /tmp/work",
  "./fpr sol tools/archive-smoke.sol --work /tmp/work", "cp /tmp/work/fprisc-*.tar.gz /out/"].
smokeSteps = Str.join " && " [
  "apt-get update >/dev/null", "apt-get install -y --no-install-recommends gcc libc6-dev >/dev/null",
  "mkdir -p '/x/with space'", "tar -xzf /out/fprisc-*.tar.gz -C '/x/with space'",
  "P=$(ls -d '/x/with space'/fprisc-*)",
  "export HOME= PATH=\"$P/bin:/usr/bin:/bin\" TMPDIR=/tmp SOL_STATE_DIR=/tmp/sol-state LANG=C.UTF-8",
  "fpr --version", "sol --version", "cd /tmp", "fpr new hello", "cd hello", "fpr check", "fpr test",
  "fpr run -- Ada",
  "printf 'Order = use \"std/order\".\\n> print (if Order.isLess (Order.int 2 3) then \"order: less\" else \"order: other\").\\n' > /tmp/o.sol",
  "sol /tmp/o.sol", "echo CLEAN-SMOKE-PASSED"].
>! parsed = unwrap (CLI.parse (List.map (fn n -> CLI.Option n "" CLI.One) ["platform","rev","out","cache"]) (args Unit));
  platform = CLI.valueOr "linux/amd64" "platform" parsed;
  arch = List.last (Str.split 47 platform);
  root = B.query ["git","rev-parse","--show-toplevel"];
  rev = B.query ["git","rev-parse","--short",CLI.valueOr "HEAD" "rev" parsed];
  out = CLI.valueOr "" "out" parsed;
  home = (case unwrap (Env.get "HOME") of EnvText h -> h | EnvMissing -> error "HOME is not set");
  cache = CLI.valueOr "{home}/.cache/fprisc-linux/{arch}" "cache" parsed;
  _ = (if out == "" then error "expected --out DIRECTORY [--platform linux/amd64|linux/arm64] [--rev REV] [--cache DIR]" else Unit);
  common = B.query ["git","-C",root,"rev-parse","--path-format=absolute","--git-common-dir"];
  source = Str.slice common 0 (Str.len common - 5);
  _ = B.command ["mkdir","-p",out,"{cache}/build","{cache}/cabal"];
  _ = print "linux-archive: image for {platform}";
  _ = B.command ["docker","build","-q","--platform",platform,"-t","fprisc-linux-build","{root}/packaging/linux"];
  _ = print "linux-archive: building {rev}";
  _ = B.command ["docker","run","--rm","--platform",platform,"-e","REV={rev}","-v","{source}:/src:ro","-v","{out}:/out",
                 "-v","{cache}/build:/build","-v","{cache}/cabal:/root/.cabal","fprisc-linux-build","sh","-c",buildSteps];
  _ = print "linux-archive: clean smoke test";
  _ = B.command ["docker","run","--rm","--platform",platform,"-v","{out}:/out:ro","debian:bookworm-slim","sh","-c",smokeSteps];
  print "linux-archive: passed ({out})".
