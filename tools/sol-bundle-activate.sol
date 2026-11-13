# The installer validates the existing launcher and installed bundle first.
# Stage the relative symlink beside the destination so mv can rename atomically.
B = use "../sol/lib/build".
activate bin id =
  renameFlag = if B.query ["uname","-s"] == "Linux" then "-T" else "-h";
  temp = B.query ["mktemp","-d","{bin}/.sol-activate.XXXXXX"];
  link = "{temp}/sol";
  install = Proc.streamNow (ProcessSpec ["ln","-s","../libexec/sol/{id}/launch-sol",link] "" [] "" 0);
  result = (case install of
      Ok 0 -> Proc.streamNow (ProcessSpec ["mv","-f",renameFlag,link,"{bin}/sol"] "" [] "" 0)
    | other -> other);
  _ = B.command ["rm","-f",link];
  _ = B.command ["rmdir",temp];
  case result of Ok 0 -> Unit | failed -> error "launcher activation failed: {failed}".
> case args Unit of [bin,id] -> activate bin id
  | _ -> error "usage: sol-bundle-activate.sol BIN_DIRECTORY BUNDLE_ID".
