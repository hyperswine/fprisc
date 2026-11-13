# Package the already-qualified native manager from a clean checkout.
B = use "../sol/lib/build".
CLI = use "../sol/lib/cli".
D = use "../sol/lib/digest".
J = use "../sol/lib/json".
digits text = text != "" and List.all (fn c -> c >= 48 and c <= 57) (Str.codes text).
stable reported = case Str.split 32 reported of
    ["fprmeta",version] -> (case Str.split 46 version of
        [a,b,c] -> if List.all digits [a,b,c] then version else error "expected stable manager version"
      | _ -> error "expected stable manager version")
  | _ -> error "expected fprmeta version".
package : unsafe String -> String -> String -> Unit .
package root binary output =
  _ = (if B.query ["git","-C",root,"status","--porcelain"] != "" then error "commit source changes before packaging" else Unit);
  revision = B.query ["git","-C",root,"rev-parse","HEAD"];
  version = stable (B.query [binary,"--version"]);
  deps = List.map Str.trim (List.drop 1 (Str.lines (B.query ["/usr/bin/otool","-L",binary])));
  _ = (if List.all (fn line -> Str.startsWith "/usr/lib/" line or Str.startsWith "/System/" line) deps then Unit else error "manager links a non-system library");
  _ = B.command ["/usr/bin/codesign","--verify",binary];
  _ = B.command ["mkdir","-p",B.query ["dirname",output]];
  _ = B.command ["mkdir",output];
  name = "fprmeta-{version}-macos-arm64";
  prefix = "{output}/{name}";
  _ = B.command ["mkdir","-p","{prefix}/bin"];
  _ = B.command ["cp","-pL",binary,"{prefix}/bin/fprmeta"];
  _ = B.command ["cp","-pL","{root}/LICENSE","{root}/tools/fprmeta/release.pub",prefix];
  filename = "{name}.tar.gz";
  archive = "{output}/{filename}";
  _ = B.runWith [("COPYFILE_DISABLE","1")] ["tar","-czf",archive,"-C",output,name];
  hash = unwrap (D.sha256File archive);
  size = parseInt (B.query ["stat","-f","%z",archive]);
  manifest = J.JObj [("format",J.JNum 1),("version",J.JStr version),("component",J.JStr "fprmeta"),("platform",J.JStr "macos-arm64"),
    ("sourceRevision",J.JStr revision),("archive",J.JStr filename),("sha256",J.JStr hash),("size",J.JNum size),
    ("nativeLibraries",J.JArr (List.map J.JStr deps)),("publicKey",J.JStr (Str.trim (readPath "{prefix}/release.pub")))];
  text = J.pretty manifest;
  _ = writePath "{output}/SHA256SUMS" "{hash}  {filename}\n";
  _ = writePath "{output}/release.json" (text + "\n");
  print text.
main : unsafe Unit -> Unit .
> argsParsed = unwrap (CLI.parse [CLI.Option "binary" "" CLI.One,CLI.Option "output" "" CLI.One] (args Unit));
  root = B.query ["git","rev-parse","--show-toplevel"];
  binary = CLI.valueOr "{root}/build/fprmeta/fprmeta" "binary" argsParsed;
  output = CLI.valueOr "" "output" argsParsed;
  if output == "" or CLI.operands argsParsed != [] then error "expected --output DIRECTORY [--binary FPRMETA]" else
    package root (B.query ["realpath",binary]) output.
