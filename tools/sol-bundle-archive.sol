# Publish only a completely written archive, including when replacing one.
B = use "../sol/lib/build".
pack parent name destination =
  dir = B.query ["dirname",destination];
  _ = B.command ["mkdir","-p",dir];
  _ = (if B.exists "-d" destination then error "archive destination is a directory: {destination}" else Unit);
  temporary = B.query ["mktemp","{dir}/.sol-bundle.XXXXXX"];
  spec = ProcessSpec ["tar","-czf",temporary,"-C",parent,"--",name] "" [("COPYFILE_DISABLE","1")] "" 0;
  result = (case Proc.streamNow spec of
      Ok 0 -> Proc.streamNow (ProcessSpec ["mv","-f",temporary,destination] "" [] "" 0)
    | other -> other);
  case result of Ok 0 -> Unit | failed -> _ = B.command ["rm","-f",temporary]; error "archive publication failed: {failed}".
> case args Unit of [parent,name,destination] -> pack parent name destination
  | _ -> error "usage: sol-bundle-archive.sol STAGING_DIRECTORY BUNDLE_NAME OUTPUT".
