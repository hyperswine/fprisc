# ELF (Linux) counterparts of toolchain-macho / toolchain-bundle-libs /
# toolchain-linkage: find a binary's shared libraries, copy the ones that are
# not part of the system into the toolchain's lib/ with their licence notices,
# point every image's RUNPATH at $ORIGIN, and check that every image loads
# only system libraries or libraries inside the toolchain.
# docs/2026-11-27-LINUX-RELEASE-ARCHIVE.md.
B = use "../sol/lib/build".
J = use "../sol/lib/json".
F = use "toolchain-files".
M = use "toolchain-macho".
# The C library, its loader and the compiler runtime: present on every
# glibc system, and tied to it, so never bundled. Everything else is.
systemNames = ["libc.so.6","libm.so.6","libpthread.so.0","libdl.so.2","librt.so.1","libresolv.so.2",
  "libutil.so.1","libgcc_s.so.1","ld-linux-x86-64.so.2","ld-linux-aarch64.so.1","linux-vdso.so.1"].
systemLibrary name = List.has (M.base name) systemNames.
isElf path = B.exists "-f" path and Str.words (B.query ["od","-An","-tx1","-N4",path]) == ["7f","45","4c","46"].
# entries of `readelf -d` of one kind: NEEDED, RUNPATH or RPATH
dynamic kind image =
  marker = "({kind})";
  List.concat (List.map (fn line -> if Str.contains marker line then
      i = Str.indexOf "[" line; j = Str.indexOf "]" line;
      (if i >= 0 and j > i then [Str.slice line (i + 1) j] else [])
    else []) (Str.lines (B.query ["readelf","-d",image]))).
needed image = dynamic "NEEDED" image.
runpaths image = List.concat (List.map (fn p -> Str.split 58 p) (List.append (dynamic "RUNPATH" image) (dynamic "RPATH" image))).
# name -> resolved path for the whole closure, from the dynamic loader itself
resolvedClosure image = List.concat (List.map (fn line -> case Str.words (Str.trim line) of
    name :: "=>" :: path :: _ -> if Str.startsWith "/" path then [(name, path)] else []
  | _ -> []) (Str.lines (B.query ["ldd",image]))).
# the Debian package that owns a library, or "" for one built from source
# (by file name: with merged /usr, dpkg records /lib/... for what resolves to /usr/lib/...)
packageOf path = out = B.query ["sh","-c","b=$(basename \"$(readlink -f \"$1\")\"); dpkg -S \"$b\" 2>/dev/null | grep -m1 \"/$b\\$\" || true","sh",path];
  if out == "" then "" else (Str.split 58 out) ! 0.
# a library built from source into PREFIX/lib carries its notices in
# PREFIX/share/licenses, and PREFIX is NAME-VERSION (as a Homebrew keg)
prefixNotices sdk real =
  prefix = M.parent (M.parent real);
  src = "{prefix}/share/licenses";
  if not (B.exists "-d" src) then error "no licence notice for {real}: not a Debian package and no {src}" else
    dir = "lib/licenses/{M.base prefix}";
    _ = B.command ["mkdir","-p","{sdk}/{dir}"];
    _ = B.command ["cp","-pRL",src + "/.","{sdk}/{dir}"];
    List.map (fn n -> "{dir}/{n}") (Str.lines (B.query ["ls","{sdk}/{dir}"])).
noticesFor sdk pkg =
  base = Str.trim ((Str.split 58 pkg) ! 0);
  src = "/usr/share/doc/{base}/copyright";
  if not (B.exists "-f" src) then error "no licence notice for {pkg} ({src})" else
    dir = "lib/licenses/{base}";
    _ = B.command ["mkdir","-p","{sdk}/{dir}"];
    _ = B.command ["cp","-pL",src,"{sdk}/{dir}/copyright"];
    ["{dir}/copyright"].
bundle1 sdk entry = (name, path) = entry;
  real = F.canonical path;
  copy = "{sdk}/lib/{name}";
  _ = B.command ["cp","-pL",real,copy];
  _ = B.command ["chmod","755",copy];
  _ = B.command ["patchelf","--set-rpath","$ORIGIN",copy];
  pkg = packageOf real;
  prefix = M.base (M.parent (M.parent real));
  version = (if pkg == "" then prefix else B.query ["dpkg-query","-W","-f=$\{Version\}",Str.trim ((Str.split 58 pkg) ! 0)]);
  notes = (if pkg == "" then prefixNotices sdk real else noticesFor sdk pkg);
  J.JObj [("installName",J.JStr name),("file",J.JStr ("lib/" + name)),("source",J.JStr real),
          ("package",J.JStr (if pkg == "" then prefix else pkg)),("packageVersion",J.JStr version),("notices",J.JArr (List.map J.JStr notes))].
# copy every non-system library of `exe`'s closure into sdk/lib and point the
# executable at it
bundle sdk exe =
  _ = B.command ["mkdir","-p","{sdk}/lib"];
  libs = List.filter (fn e -> (n, p) = e; not (systemLibrary n)) (resolvedClosure exe);
  entries = List.map (bundle1 sdk) libs;
  _ = B.command ["patchelf","--set-rpath","$ORIGIN/lib",exe];
  J.JArr entries.
expand image entry = if Str.startsWith "$ORIGIN" entry then M.parent image + Str.slice entry 7 (Str.len entry) else entry.
inside root target = target == root or Str.startsWith "{root}/" target.
problems root relative =
  image = "{root}/{relative}";
  dirs = List.map (expand image) (runpaths image);
  bad = List.filter (fn d -> not (inside root (F.canonical d))) (List.filter (fn d -> B.exists "-d" d) dirs);
  missing = List.filter (fn n -> not (systemLibrary n) and not (List.any (fn d -> B.exists "-f" "{d}/{n}") dirs)) (needed image);
  List.append (List.map (fn d -> "{relative}: runpath {d} is outside the toolchain") bad)
              (List.map (fn n -> "{relative} loads {n}: not a system library and not inside the toolchain") missing).
# every ELF image in the prefix loads only system libraries or toolchain ones
verify prefix binary =
  root = F.canonical prefix;
  images = List.filter (fn name -> isElf "{root}/{name}") (F.files root);
  issues = List.concat (List.map (problems root) images);
  if issues == [] then Unit else error (Str.join "; " issues).
leadingDigits s = (n, stop) = List.fold (fn acc c -> (k, done) = acc; if done or c < 48 or c > 57 then (k, True) else (k + 1, False)) (0, False) (Str.codes s);
  Str.slice s 0 n.
# the newest glibc symbol version any image needs: the oldest system it runs on
glibcFloor prefix =
  root = F.canonical prefix;
  images = List.filter (fn name -> isElf "{root}/{name}") (F.files root);
  versions = List.concat (List.map (fn name -> List.concat (List.map (fn line ->
      i = Str.indexOf "GLIBC_2." line;
      (if i < 0 then [] else
        rest = Str.slice line (i + 8) (Str.len line);
        digits = leadingDigits rest;
        (if digits == "" then [] else [parseInt digits]))) (Str.lines (B.query ["objdump","-T","{root}/{name}"])))) images);
  "2." + str (List.fold (fn a v -> if v > a then v else a) 0 versions).
