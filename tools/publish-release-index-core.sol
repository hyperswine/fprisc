# Build, append and sign fprmeta/qosmeta release-index entries.
# The signing key is only ever passed as a path to ssh-keygen on this machine.
B = use "../sol/lib/build".
CLI = use "../sol/lib/cli".
D = use "../sol/lib/digest".
H = use "../sol/lib/http".
J = use "../sol/lib/json".

namespace = "fprmeta-index".
identity = "fpr-release".
defaultPlatform = "macos-arm64".
maxArchive = 268435456.
brewPackages = ["libgit2", "libarchive", "glfw"].
userAgent = "fprisc-publish-release-index".

optionsOf = [
  CLI.Option "tap" "" CLI.One,
  CLI.Option "key" "" CLI.One,
  CLI.Option "pub" "" CLI.One,
  CLI.Option "platform" "" CLI.One,
  CLI.Option "cache" "" CLI.One,
  CLI.Option "assets" "" CLI.One,
  CLI.Option "entries-dir" "" CLI.One,
  CLI.Option "entry-only" "" CLI.Switch,
  CLI.Option "skip-archive" "" CLI.Switch,
  CLI.Option "allow-unsigned" "" CLI.Switch,
  CLI.Option "dry-run" "" CLI.Switch].

usage = "usage: fpr sol tools/publish-release-index.sol [options] SPEC...\n\n" +
  "Add published GitHub releases to the signed fprmeta/qosmeta indexes.\n" +
  "SPECs are VERSION (fprisc), fprisc:VERSION, or qos:VERSION.\n\n" +
  "Options:\n" +
  "  --tap DIR           Homebrew tap checkout (default: ../homebrew-tap or $FPR_TAP)\n" +
  "  --key PATH          OpenSSH private key; comment must be fpr-release. Required to sign.\n" +
  "                      The key never leaves this machine; it is only passed to ssh-keygen.\n" +
  "  --pub PATH          Public key used to verify signatures (default: TAP/toolchains/release.pub)\n" +
  "  --platform NAME     Archive platform (default: macos-arm64)\n" +
  "  --cache DIR         Download cache (default: $TMPDIR/fpr-release-index)\n" +
  "  --assets DIR        Pre-fetched release.json, SHA256SUMS and optional archive\n" +
  "  --entries-dir DIR   Where to write *-entry.json (default: docs/release-indexes)\n" +
  "  --entry-only        Write entry files only; do not edit or sign the indexes\n" +
  "  --skip-archive      Do not download the tarball; use SHA256SUMS and the GitHub size\n" +
  "  --allow-unsigned    Allow appending to an index that does not yet have a valid signature\n" +
  "  --dry-run           Build and validate entries without writing indexes or signatures".

digits text = text != "" and List.all (fn c -> c >= 48 and c <= 57) (Str.codes text).

parseVersion : String -> Result (List Int) String.
parseVersion text =
  parts = Str.split 46 text;
  if parts == [] or List.any (fn p -> not (digits p)) parts then Err "invalid version {text}"
  else Ok (List.map parseInt parts).

partAt i xs = if i >= List.len xs then 0 else xs ! i.

compareFrom : unsafe Int -> List Int -> List Int -> Int .
compareFrom i as bs =
  if i >= List.len as and i >= List.len bs then 0 else
    a = partAt i as; b = partAt i bs;
    if a < b then 0 - 1 else if a > b then 1 else compareFrom (i + 1) as bs.

compareParts : unsafe List Int -> List Int -> Int .
compareParts as bs = compareFrom 0 as bs.

compareVersions : unsafe String -> String -> Result Int String.
compareVersions a b = parseVersion a |>? (fn as -> parseVersion b |>? (fn bs -> Ok (compareParts as bs))).

validSha h = Str.len h == 64 and List.all (fn c -> (c >= 48 and c <= 57) or (c >= 97 and c <= 102)) (Str.codes (Str.lower h)).

normalizeComponent name =
  if name == "fprisc" then Ok "fprisc"
  else if name == "qos" or name == "qos-portable" then Ok "qos-portable"
  else Err "unknown component {name}; use fprisc or qos".

parseSpec : String -> Result (String, String) String.
parseSpec token =
  if token == "" then Err "empty release spec" else
  if Str.contains ":" token then
    case Str.split 58 token of
      [name, version] -> normalizeComponent name |>? (fn component ->
        parseVersion version |>? (fn ignored -> Ok (component, version)))
    | _ -> Err "expected COMPONENT:VERSION, got {token}"
  else parseVersion token |>? (fn ignored -> Ok ("fprisc", token)).

repoOf component = if component == "fprisc" then "hyperswine/fprisc" else "hyperswine/qos".
tagOf component version = if component == "fprisc" then "v{version}" else "desktop-v{version}".
prefixOf component = if component == "fprisc" then "fprisc" else "qos-portable".
archiveOf component version platform = "{prefixOf component}-{version}-{platform}.tar.gz".
indexFileOf component = if component == "fprisc" then "fprisc.json" else "qos-portable.json".
entryFileOf component version = "{prefixOf component}-{version}-entry.json".
downloadRoot component version = "https://github.com/{repoOf component}/releases/download/{tagOf component version}".
archiveUrl component version platform = "{downloadRoot component version}/{archiveOf component version platform}".
assetUrl component version name = "{downloadRoot component version}/{name}".
apiUrl component version = "https://api.github.com/repos/{repoOf component}/releases/tags/{tagOf component version}".

# First 64 hex digits, then whitespace, then the filename. GNU coreutils uses two spaces.
parseSha256Sums : String -> String -> Result String String.
parseSha256Sums text name =
  rows = List.filter (fn line -> Str.trim line != "" and not (Str.startsWith "#" (Str.trim line))) (Str.lines text);
  match = List.fold (fn acc line ->
    if acc != "" then acc else
      hash = Str.lower (Str.trim (Str.sub line 0 64));
      rest = Str.trim (Str.sub line 64 (Str.len line - 64));
      if validSha hash and rest == name then hash else "") "" rows;
  if match == "" then Err "SHA256SUMS has no hash for {name}" else Ok match.

payloadRelease : J.Json -> Result String String .
payloadRelease meta =
  case J.get "release" meta of
    Ok value -> J.text value
  | Err _ -> J.get "version" meta |>? J.text |>? (fn reported ->
      case Str.split 32 reported of
        ["fpr", version] -> Ok version
      | [version] -> Ok version
      | _ -> Err "release.json version is not a release version: {reported}").

payloadMinimumOS : J.Json -> Result String String .
payloadMinimumOS meta = J.get "minimumMacOS" meta |>? J.text.

brewOf line = List.fold (fn acc pkg ->
  if acc != "" then acc else
    if Str.contains "/opt/homebrew/opt/{pkg}/" line then "homebrew:{pkg}" else "") "" brewPackages.

homebrewLine line = Str.contains "/opt/homebrew/" line or Str.contains "homebrew:" line.

collectRequires acc line =
  acc |>? (fn found ->
    pkg = brewOf line;
    if pkg != "" then
      if List.has pkg found then Ok found else Ok (List.append found [pkg])
    else if homebrewLine line then Err "unsupported Homebrew library in nativeLibraries: {Str.trim line}"
    else Ok found).

walkRequires : unsafe Result (List String) String -> J.Json -> Result (List String) String .
walkRequires acc json =
  case json of
    J.JStr line -> collectRequires acc line
  | J.JArr xs -> List.fold walkRequires acc xs
  | J.JObj kvs -> List.fold (fn a pair -> (k, v) = pair; walkRequires a v) acc kvs
  | _ -> acc.

inferRequires : unsafe J.Json -> String -> Result (List String) String .
inferRequires meta platform =
  if not (Str.startsWith "macos-" platform) then Ok [] else
    libs = case J.get "nativeLibraries" meta of Ok value -> value | Err _ -> J.JArr [];
    walkRequires (Ok []) libs |>? (fn brew -> Ok (List.append ["xcode-clt"] brew)).

allowedRequire r = r == "xcode-clt" or List.has r (List.map (fn p -> "homebrew:{p}") brewPackages).

fieldText : String -> J.Json -> Result String String .
fieldText key json = J.get key json |>? J.text.

optionalInt : String -> J.Json -> Result Int String .
optionalInt key json = case J.get key json of Err _ -> Ok 0 | Ok value -> J.num value.

optionalText : String -> J.Json -> Result String String .
optionalText key json = case J.get key json of Err _ -> Ok "" | Ok value -> J.text value.

requireList : J.Json -> Result (List String) String .
requireList json = case J.get "requires" json of
  Err _ -> Ok []
| Ok arr -> J.items arr |>? (fn xs ->
    List.fold (fn acc item -> acc |>? (fn rs -> J.text item |>? (fn r -> Ok (List.append rs [r])))) (Ok []) xs).

yankedOf : J.Json -> Result Bool String .
yankedOf json = case J.get "yanked" json of Err _ -> Ok False | Ok value -> J.bool value.

entryFields : J.Json -> Result (String, String, String, String, String, Int, String, List String, Bool) String .
entryFields json =
  fieldText "component" json |>? (fn component ->
  fieldText "version" json |>? (fn version ->
  fieldText "platform" json |>? (fn platform ->
  fieldText "url" json |>? (fn url ->
  fieldText "sha256" json |>? (fn sha ->
  optionalInt "size" json |>? (fn size ->
  optionalText "minimumOS" json |>? (fn minimum ->
  requireList json |>? (fn requires ->
  yankedOf json |>? (fn yanked ->
    Ok (component, version, platform, url, sha, size, minimum, requires, yanked)))))))))).

sameIdentity a b =
  (ac, av, ap, au, asha, az, amin, ar, ay) = a;
  (bc, bv, bp, bu, bsha, bz, bmin, br, by) = b;
  ac == bc and av == bv and ap == bp.

samePayload a b =
  (ac, av, ap, au, asha, az, amin, ar, ay) = a;
  (bc, bv, bp, bu, bsha, bz, bmin, br, by) = b;
  au == bu and Str.lower asha == Str.lower bsha and az == bz.

sameEntry a b =
  (ac, av, ap, au, asha, az, amin, ar, ay) = a;
  (bc, bv, bp, bu, bsha, bz, bmin, br, by) = b;
  samePayload a b and amin == bmin and ar == br and ay == by.

entryObject : String -> String -> String -> String -> String -> Int -> String -> List String -> Bool -> J.Json .
entryObject component version platform url sha size minimum requires yanked =
  sizeField = if size == 0 then [] else [("size", J.JNum size)];
  J.JObj (List.concat [
    [("component", J.JStr component),
     ("version", J.JStr version),
     ("platform", J.JStr platform),
     ("url", J.JStr url),
     ("sha256", J.JStr (Str.lower sha))],
    sizeField,
    [("minimumOS", J.JStr minimum),
     ("requires", J.JArr (List.map J.JStr requires)),
     ("yanked", J.JBool yanked)]]).

fromFields : (String, String, String, String, String, Int, String, List String, Bool) -> J.Json .
fromFields f = (component, version, platform, url, sha, size, minimum, requires, yanked) = f;
  entryObject component version platform url sha size minimum requires yanked.

entryText : (String, String, String, String, String, Int, String, List String, Bool) -> String .
entryText f = J.pretty (fromFields f) + "\n".

indexObject : String -> List J.Json -> J.Json .
indexObject component entries = J.JObj [
  ("format", J.JNum 1),
  ("component", J.JStr component),
  ("entries", J.JArr entries)].

indexText : String -> List J.Json -> String .
indexText component entries = J.pretty (indexObject component entries) + "\n".

validateEntry : String -> (String, String, String, String, String, Int, String, List String, Bool) -> Result (String, String, String, String, String, Int, String, List String, Bool) String .
validateEntry platform f =
  (component, version, plat, url, sha, size, minimum, requires, yanked) = f;
  if plat != platform then Err "{version}: platform {plat} is not {platform}"
  else if not (validSha sha) then Err "{version}: invalid SHA-256"
  else if not (Str.startsWith "https://" url) then Err "{version}: URL must use HTTPS"
  else if size <= 0 or size > maxArchive then Err "{version}: invalid size {size}"
  else if minimum == "" then Err "{version}: missing minimumOS"
  else if List.any (fn r -> not (allowedRequire r)) requires then Err "{version}: unsupported requires {requires}"
  else if not (List.has "xcode-clt" requires) and Str.startsWith "macos-" platform then Err "{version}: macOS entries need xcode-clt"
  else Ok f.

insertOne : unsafe J.Json -> List J.Json -> Result (List J.Json, Bool) String .
insertOne entry entries =
  entryFields entry |>? (fn fields ->
    (component, version, platform, url, sha, size, minimum, requires, yanked) = fields;
    (List.fold (fn acc item ->
      acc |>? (fn state ->
        (placed, out, replaced) = state;
        if placed then Ok (True, List.append out [item], replaced) else
          entryFields item |>? (fn existing ->
            (ec, ev, ep, eu, esha, ez, emin, er, ey) = existing;
            if ep != platform then Ok (False, List.append out [item], replaced) else
              compareVersions version ev |>? (fn cmp ->
                if cmp < 0 then Ok (True, List.append out [entry, item], replaced)
                else if cmp > 0 then Ok (False, List.append out [item], replaced)
                else if not (sameIdentity fields existing) then Ok (False, List.append out [item], replaced)
                else if sameEntry fields existing then Ok (True, List.append out [item], True)
                else if samePayload fields existing then Ok (True, List.append out [entry], True)
                else Err "{component} {version} ({platform}) already has a different archive hash or URL"))))
      (Ok (False, [], False)) entries) |>? (fn state ->
        (placed, out, replaced) = state;
        if placed then Ok (out, replaced) else Ok (List.append out [entry], replaced))).

insertEntries : unsafe List J.Json -> List J.Json -> Result (List J.Json, Bool) String .
insertEntries start added =
  List.fold (fn acc entry ->
    acc |>? (fn state ->
      (entries, anyReplaced) = state;
      insertOne entry entries |>? (fn result ->
        (next, replaced) = result;
        Ok (next, anyReplaced or replaced)))) (Ok (start, False)) added.

httpOptions =
  H.withRedirects (RedirectHttps 20)
    (H.withBodyLimit maxArchive
      (H.withDeadline 300000 H.defaultOptions)).

httpGet url = HttpRequest "GET" url [("User-Agent", userAgent), ("Accept", "*/*")] (Bytes.empty Unit).

decodeBody : Bytes -> Result String String .
decodeBody bytes = Utf8.decode bytes.

showHttp err = "{err}".

downloadFile : String -> String -> Bool -> Result Int String .
downloadFile url path replace =
  case Http.download httpOptions (httpGet url) path replace of
    Ok (HttpInfo status headers count) ->
      if status >= 200 and status < 300 then Ok count
      else Err "GET {url}: HTTP {status}"
  | Err why -> Err "GET {url}: {showHttp why}".

fetchText : String -> Result String String .
fetchText url =
  case Http.request httpOptions (httpGet url) of
    Ok (HttpResponse status headers bytes) ->
      if status >= 200 and status < 300 then decodeBody bytes
      else Err "GET {url}: HTTP {status}"
    | Err why -> Err "GET {url}: {showHttp why}".

existsFile : String -> Bool .
existsFile path = B.exists "-f" path.
existsDir : String -> Bool .
existsDir path = B.exists "-d" path.

ensureDir : String -> Unit .
ensureDir path = B.command ["mkdir", "-p", path].

writeText : String -> String -> Unit .
writeText path text =
  _ = ensureDir (Str.trim (B.query ["dirname", path]));
  tmp = "{path}.tmp";
  _ = B.command ["rm", "-f", tmp];
  bytes = unwrap (Utf8.encode text);
  writer = unwrap (Stream.openWrite tmp (Bytes.len bytes));
  (result, next) = Stream.writeChunk bytes writer;
  _ = unwrap result;
  _ = unwrap (Stream.closeWrite next);
  B.command ["mv", "-f", tmp, path].

readText : String -> Result String String .
readText path =
  if not (existsFile path) then Err "missing file {path}" else
    ProcessResult code out err = unwrap (Proc.runNow (ProcessSpec ["cat", path] "" [] "" 0));
    if code == 0 then Ok out else Err "cannot read {path}: {err}".

readJson : String -> Result J.Json String .
readJson path = readText path |>? J.parse.

sha256Of : String -> Result String String .
sha256Of path = D.sha256File path.

statSize : String -> Int .
statSize path =
  ProcessResult code out err = unwrap (Proc.runNow (ProcessSpec ["stat", "-c", "%s", path] "" [] "" 0));
  if code == 0 then parseInt (Str.trim out) else
    ProcessResult c2 o2 e2 = unwrap (Proc.runNow (ProcessSpec ["stat", "-f", "%z", path] "" [] "" 0));
    if c2 == 0 then parseInt (Str.trim o2) else error "stat failed for {path}: {err}{e2}".

tmpdir u = case unwrap (Env.get "TMPDIR") of EnvText value -> if value == "" then "/tmp" else value | EnvMissing -> "/tmp".

defaultCache u = "{tmpdir Unit}/fpr-release-index".

sshKeygen : Unit -> String .
sshKeygen u = if existsFile "/usr/bin/ssh-keygen" then "/usr/bin/ssh-keygen" else "ssh-keygen".

publicKeyLine : String -> Result String String .
publicKeyLine path =
  readText path |>? (fn text ->
    line = Str.trim (List.fold (fn acc row -> if acc != "" then acc else if Str.startsWith "ssh-" (Str.trim row) then Str.trim row else acc) "" (Str.lines text));
    case Str.split 32 line of
      typ :: key :: _ -> if typ == "" or key == "" then Err "public key {path} is not an OpenSSH key line" else Ok "{typ} {key}"
    | _ -> Err "public key {path} is not an OpenSSH key line").

writeAllowed : String -> String -> Result String String .
writeAllowed path pub =
  publicKeyLine pub |>? (fn line ->
    _ = writeText path "{identity} namespaces=\"{namespace}\" {line}\n";
    Ok path).

runKeygen : String -> List String -> Result String String .
runKeygen stdin argv =
  ProcessResult code out err = unwrap (Proc.runNow (ProcessSpec argv "" [] stdin 30000));
  if code == 0 then Ok out else Err "ssh-keygen failed: {Str.trim err}".

signBytes : String -> String -> Result String String .
signBytes key text =
  runKeygen text [sshKeygen Unit, "-Y", "sign", "-f", key, "-n", namespace].

verifyBytes : String -> String -> String -> Result Unit String .
verifyBytes allowed signaturePath text =
  runKeygen text [sshKeygen Unit, "-Y", "verify", "-f", allowed, "-I", identity, "-n", namespace, "-s", signaturePath] |>? (fn ignored -> Ok Unit).

signIndex : String -> String -> String -> String -> Result String String .
signIndex key pub indexPath signaturePath =
  readText indexPath |>? (fn text ->
    work = Str.trim (B.query ["mktemp", "-d"]);
    allowed = "{work}/allowed_signers";
    writeAllowed allowed pub |>? (fn ignored ->
      signBytes key text |>? (fn sig ->
        if Str.trim sig == "" then Err "ssh-keygen produced an empty signature" else
          written = writeText signaturePath sig;
          verifyBytes allowed signaturePath text |>? (fn ignored ->
            _ = B.command ["rm", "-rf", work];
            Ok signaturePath)))).

verifyIndex : String -> String -> String -> Result Unit String .
verifyIndex pub indexPath signaturePath =
  if not (existsFile signaturePath) then Err "missing signature {signaturePath}" else
    readText indexPath |>? (fn text ->
      work = Str.trim (B.query ["mktemp", "-d"]);
      allowed = "{work}/allowed_signers";
      writeAllowed allowed pub |>? (fn ignored ->
        result = verifyBytes allowed signaturePath text;
        _ = B.command ["rm", "-rf", work];
        result)).

aliasDirs component version =
  if component == "qos-portable" then ["qos-{version}", "qos/{version}"] else [].

assetCandidates root component version =
  List.append
    ["{root}/{component}-{version}", "{root}/{component}/{version}", "{root}/{prefixOf component}-{version}"]
    (List.append (List.map (fn name -> "{root}/{name}") (aliasDirs component version)) [root]).

hasReleaseFiles : String -> Bool .
hasReleaseFiles dir = B.exists "-f" "{dir}/SHA256SUMS" and B.exists "-f" "{dir}/release.json".

findAssetDir : String -> String -> String -> String .
findAssetDir root component version =
  List.fold (fn acc dir -> if acc != "" then acc else if hasReleaseFiles dir then dir else "") "" (assetCandidates root component version).

githubSize : String -> String -> Result Int String .
githubSize text name =
  J.parse text |>? (fn json ->
    J.get "assets" json |>? J.items |>? (fn assets ->
      (List.fold (fn acc asset ->
        acc |>? (fn found ->
          if found > 0 then Ok found else
            case J.get "name" asset |>? J.text of
              Err _ -> Ok 0
            | Ok n -> if n != name then Ok 0 else J.get "size" asset |>? J.num))
        (Ok 0) assets) |>? (fn size ->
        if size <= 0 then Err "GitHub release lists no size for {name}" else Ok size))).

loadMeta : unsafe String -> String -> String -> String -> Result (String, String, List String, J.Json, String) String .
loadMeta dir component version platform =
  archive = archiveOf component version platform;
  readText "{dir}/SHA256SUMS" |>? (fn sums ->
  parseSha256Sums sums archive |>? (fn sha ->
  readJson "{dir}/release.json" |>? (fn meta ->
  payloadRelease meta |>? (fn release ->
  if release != version then Err "{dir}/release.json is for {release}, not {version}" else
    payloadMinimumOS meta |>? (fn minimum ->
    inferRequires meta platform |>? (fn requires ->
      Ok (sha, minimum, requires, meta, archive))))))).

finishEntry : String -> String -> String -> String -> String -> List String -> String -> Int -> Result (String, String, String, String, String, Int, String, List String, Bool) String .
finishEntry component version platform sha minimum requires archivePath givenSize =
  size = if givenSize > 0 then givenSize else statSize archivePath;
  checked = if givenSize > 0 then Ok sha else
    sha256Of archivePath |>? (fn got ->
      if Str.lower got != Str.lower sha then Err "{archivePath} SHA-256 {got} does not match SHA256SUMS {sha}" else Ok sha);
  checked |>? (fn okSha ->
    fields = (component, version, platform, archiveUrl component version platform, okSha, size, minimum, requires, False);
    validateEntry platform fields).

ensureMeta : String -> String -> String -> Bool -> String -> Unit .
ensureMeta work component version fetchMissing assets =
  if hasReleaseFiles work then Unit
  else if not fetchMissing then error "no release.json/SHA256SUMS for {component} {version} under {assets}"
  else
    _ = ensureDir work;
    _ = unwrap (downloadFile (assetUrl component version "SHA256SUMS") "{work}/SHA256SUMS" True);
    _ = unwrap (downloadFile (assetUrl component version "release.json") "{work}/release.json" True);
    Unit.

ensureArchive : String -> String -> String -> Bool -> Unit .
ensureArchive path url sha fetchMissing =
  present = existsFile path;
  current = if present then Str.lower (unwrap (sha256Of path)) else "";
  if present and current == Str.lower sha then Unit
  else if not fetchMissing then
    if not present then error "missing archive {path}"
    else error "{path} SHA-256 {current} does not match SHA256SUMS {sha}"
  else
    _ = unwrap (downloadFile url path True);
    again = Str.lower (unwrap (sha256Of path));
    if again == Str.lower sha then Unit else error "{path} SHA-256 {again} does not match SHA256SUMS {sha}".

buildEntry : unsafe String -> String -> String -> String -> String -> Bool -> Bool -> Result (String, String, String, String, String, Int, String, List String, Bool) String .
buildEntry component version platform assets cache skip fetchMissing =
  dir0 = if assets != "" then findAssetDir assets component version else "";
  dir1 = if dir0 != "" then dir0 else if cache != "" then findAssetDir cache component version else "";
  work = if dir1 != "" then dir1 else "{cache}/{component}-{version}";
  _ = ensureMeta work component version fetchMissing assets;
  loadMeta work component version platform |>? (fn loaded ->
    (sha, minimum, requires, meta, archive) = loaded;
    path = "{work}/{archive}";
    if skip then
      fetchText (apiUrl component version) |>? (fn body ->
        githubSize body archive |>? (fn size ->
          finishEntry component version platform sha minimum requires path size))
    else
      url = archiveUrl component version platform;
      _ = ensureArchive path url sha fetchMissing;
      finishEntry component version platform sha minimum requires path 0).

defaultTap : Unit -> String .
defaultTap u =
  case unwrap (Env.get "FPR_TAP") of
    EnvText value -> value
  | EnvMissing ->
      root = Str.trim (B.query ["git", "rev-parse", "--show-toplevel"]);
      sibling = "{root}/../homebrew-tap";
      if existsDir "{sibling}/toolchains" then sibling
      else if existsDir "toolchains" and existsFile "toolchains/fprisc.json" then "."
      else "".

defaultEntries : Unit -> String .
defaultEntries u =
  root = Str.trim (B.query ["git", "rev-parse", "--show-toplevel"]);
  if existsDir "{root}/docs/release-indexes" then "{root}/docs/release-indexes" else "docs/release-indexes".

groupByComponent specs =
  List.fold (fn acc spec ->
    (component, fields) = spec;
    (found, out) = List.fold (fn state pair ->
      (seen, rows) = state;
      (c, items) = pair;
      if c == component then (True, List.append rows [(c, List.append items [fields])])
      else (seen, List.append rows [pair])) (False, []) acc;
    if found then out else List.append acc [(component, [fields])]) [] specs.

gitCommands tap files versions =
  quoted = Str.join " " files;
  message = "Offer {versions} in the signed indexes";
  "To publish, in the tap checkout ({tap}):\n\n" +
    "  git add {quoted}\n" +
    "  git commit -m \"{message}\"\n" +
    "  git push\n".

announce : (String, String, String, String, String, Int, String, List String, Bool) -> String -> Bool -> Unit .
announce fields dest dryRun =
  (component, version, platform, url, sha, size, minimum, requires, yanked) = fields;
  prefix = if dryRun then "would write" else "wrote";
  print "{prefix} {dest}: {component} {version} {Str.lower sha} ({size} bytes)".

versionOf fields = (component, version, platform, url, sha, size, minimum, requires, yanked) = fields; version.

checkIndexHeader : String -> String -> J.Json -> Unit .
checkIndexHeader path component current =
  _ = case J.get "format" current |>? J.num of
    Ok 1 -> Unit
  | Ok n -> error "{path} has unsupported format {n}"
  | Err why -> error "{path}: {why}";
  case J.get "component" current |>? J.text of
    Ok c -> if c == component then Unit else error "{path} is for {c}, not {component}"
  | Err why -> error "{path}: {why}".

requireExistingSig : String -> Bool -> String -> String -> Unit .
requireExistingSig pub allowUnsigned indexPath sigPath =
  if allowUnsigned then Unit
  else if existsFile sigPath then unwrap (verifyIndex pub indexPath sigPath)
  else error "{indexPath} has no signature; pass --allow-unsigned for a new or unsigned index".

writeSignedIndex : String -> String -> String -> String -> String -> Unit .
writeSignedIndex key pub indexPath sigPath body =
  _ = if key == "" then error "need --key PATH to sign" else Unit;
  _ = writeText indexPath body;
  _ = unwrap (signIndex key pub indexPath sigPath);
  _ = unwrap (verifyIndex pub indexPath sigPath);
  print "signed {indexPath}".

updateIndex : unsafe String -> String -> String -> Bool -> Bool -> String -> List (String, String, String, String, String, Int, String, List String, Bool) -> List String .
updateIndex tap pub key allowUnsigned dryRun component items =
  name = indexFileOf component;
  indexPath = "{tap}/toolchains/{name}";
  sigPath = "{indexPath}.sig";
  _ = if not (existsFile indexPath) then error "missing index {indexPath}" else Unit;
  _ = if pub == "" then error "need --pub PATH (or a tap with toolchains/release.pub)" else Unit;
  _ = requireExistingSig pub allowUnsigned indexPath sigPath;
  current = unwrap (readJson indexPath);
  _ = checkIndexHeader indexPath component current;
  existing = unwrap (J.items (unwrap (J.get "entries" current)));
  added = List.map fromFields items;
  (next, replaced) = unwrap (insertEntries existing added);
  versions = Str.join ", " (List.map versionOf items);
  body = indexText component next;
  if dryRun then
    _ = print "would update {indexPath} ({versions})";
    []
  else
    _ = writeSignedIndex key pub indexPath sigPath body;
    [name, "{name}.sig"].

writeEntry : String -> (String, String, String, String, String, Int, String, List String, Bool) -> Bool -> Unit .
writeEntry dest fields dryRun =
  text = entryText fields;
  _ = if dryRun then print "would write {dest}" else writeText dest text;
  announce fields dest dryRun.

run : unsafe CLI.Parsed -> Unit .
run parsed =
  case parsed of CLI.Parsed unusedOperands unusedEntries ->
    specs = CLI.operands parsed;
    if specs == [] then error usage else
      platform = CLI.valueOr defaultPlatform "platform" parsed;
      entryOnly = CLI.flag "entry-only" parsed;
      skipArchive = CLI.flag "skip-archive" parsed;
      allowUnsigned = CLI.flag "allow-unsigned" parsed;
      dryRun = CLI.flag "dry-run" parsed;
      tap = CLI.valueOr (if entryOnly then "" else defaultTap Unit) "tap" parsed;
      key = CLI.valueOr "" "key" parsed;
      assets = CLI.valueOr "" "assets" parsed;
      cache = CLI.valueOr (defaultCache Unit) "cache" parsed;
      entriesDir = CLI.valueOr (defaultEntries Unit) "entries-dir" parsed;
      fetchMissing = assets == "";
      _ = if (not entryOnly) and tap == "" then error "need --tap DIR (or $FPR_TAP, or a sibling homebrew-tap checkout)" else Unit;
      _ = if (not entryOnly) and (not dryRun) and key == "" then error "need --key PATH to sign (the fpr-release private key stays on this machine)" else Unit;
      _ = if key != "" and not (existsFile key) then error "private key not found: {key}" else Unit;
      pub = CLI.valueOr (if tap == "" then "" else "{tap}/toolchains/release.pub") "pub" parsed;
      parsedSpecs = List.map (fn token -> unwrap (parseSpec token)) specs;
      _ = ensureDir cache;
      _ = ensureDir entriesDir;
      built = List.map (fn spec ->
        (component, version) = spec;
        fields = unwrap (buildEntry component version platform assets cache skipArchive fetchMissing);
        dest = "{entriesDir}/{entryFileOf component version}";
        _ = writeEntry dest fields dryRun;
        (component, fields)) parsedSpecs;
      if entryOnly then
        print "Wrote {List.len built} entry file(s) under {entriesDir}."
      else
        groups = groupByComponent built;
        files = List.concat (List.map (fn group ->
          (component, items) = group;
          updateIndex tap pub key allowUnsigned dryRun component items) groups);
        offered = Str.join ", " (List.map (fn spec ->
          (component, version) = spec;
          "{component} {version}") parsedSpecs);
        if dryRun then print "Dry run; no signatures written."
        else print "Signed and verified with namespace {namespace} and identity {identity}.\nThe private key was only passed to {sshKeygen Unit} on this machine.\n\n{gitCommands tap files offered}".

cli : unsafe List String -> Unit .
cli argv =
  case CLI.parse optionsOf argv of
    Err why -> error "{why}\n{usage}"
  | Ok parsed ->
      if CLI.operands parsed == [] then error usage else run parsed.
