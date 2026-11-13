# Existing bundle IDs hash ASCII JSON with sorted keys and a space after
# commas and colons. Keep that wire representation stable across installers.
hex n = substr "0123456789abcdef" n 1.
escaped16 n = "\\u{hex (n / 4096)}{hex (n / 256 % 16)}{hex (n / 16 % 16)}{hex (n % 16)}".
escape c = case c of
    8 -> "\\b" | 9 -> "\\t" | 10 -> "\\n" | 12 -> "\\f" | 13 -> "\\r"
  | 34 -> "\\\"" | 92 -> "\\\\"
  | _ -> if and (c >= 32) (c < 127) then Str.fromCode c else
    if c <= 65535 then escaped16 c else
    n = c - 65536; escaped16 (55296 + n / 1024) + escaped16 (56320 + n % 1024).
quote text = "\"" + Str.join "" (List.map escape (Str.codes text)) + "\"".
identity runner pairs =
  encoded = "[" + quote runner + ", \{" + Str.join ", " pairs + "}]";
  Hex.encode (Sha256.bytes (unwrap (Utf8.encode encoded))).
# A source snapshot can declare its own file order. Keep that order in both
# manifests and sort only the separate inventory used for the identity.
block open close lines =
  if lines == [] then open + close else open + "\n    " + Str.join ",\n    " lines + "\n  " + close.
metadata bundle id version runner system machine named names =
  files = block "[" "]" (List.map quote names);
  hashes = block "\{" "}" named;
  source = "\{\n  \"files\": {files}\n}\n";
  manifest = Str.join "\n" ["\{","  \"format\": 1,","  \"version\": {quote version},",
    "  \"bundle_id\": {quote id},","  \"binary_sha256\": {quote runner},","  \"source_sha256\": {hashes},",
    "  \"host\": \{","    \"system\": {quote system},","    \"machine\": {quote machine}","  },",
    "  \"libraries\": [","    \"core\",","    \"std\",","    \"sol\"","  ],",
    "  \"dependencies\": \"See docs/2026-10-29-SOL-INSTALLATION.md\"","}",""];
  _ = writePath "{bundle}/source/bundle-source.json" source;
  writePath "{bundle}/manifest.json" manifest.
# Sort hex-encoded UTF-8 keys in the C locale. The space delimiter sorts
# before every hex digit, so a path prefix sorts before its extensions.
row pair = (name,digest) = pair; Hex.encode (unwrap (Utf8.encode name)) + " " + digest.
decode line = case Str.split 32 line of
    [key,digest] -> quote (unwrap (Utf8.decode (unwrap (Hex.decode key)))) + ": " + quote digest
  | _ -> error "invalid sorted bundle entry".
entries rows = List.map decode (List.filter (fn s -> s != "") (Str.split 10 rows)).
build bundle version system machine paths reference =
  names = List.filter (fn path -> path != "") (Str.split 0 (readPath paths));
  case Str.split 10 (Str.trim (readPath reference)) of
    runner :: digests ->
      if List.len names != List.len digests then error "bundle digest count mismatch" else
        pairs = List.zip names digests;
        rows = Str.join "\n" (List.map row pairs);
        # Repeated paths appear once in the hash object, in first-seen order.
        ProcessResult uniqueStatus unique uniqueErr = unwrap (Proc.runNow (ProcessSpec ["awk","!seen[$1]++"] "" [("LC_ALL","C")] rows 0));
        spec = ProcessSpec ["sort"] "" [("LC_ALL","C")] unique 0;
        ProcessResult status out err = unwrap (Proc.runNow spec);
        if uniqueStatus != 0 then error "deduplicating paths failed: {uniqueErr}" else if status != 0 then error "sort failed: {err}" else
          hash = identity runner (entries out);
          id = "sol-0.14.0-dev-api1-{Str.lower system}-{machine}-{substr hash 0 16}";
          _ = metadata bundle id version runner system machine (entries unique) names;
          _ = print id;
          print runner
  | _ -> error "missing runner hash".
> case args Unit of [bundle,version,system,machine,paths,reference] -> build bundle version system machine paths reference
  | _ -> error "expected BUNDLE VERSION SYSTEM MACHINE PATHS DIGESTS".
