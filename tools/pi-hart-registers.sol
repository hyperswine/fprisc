runTool argv = status = unwrap (Proc.streamNow (ProcessSpec argv "" [] "" 0));
  if status == 0 then Unit else error "command exited {status}: {argv}".
checkRegisters : unsafe String -> String -> String -> Unit .
checkRegisters driver fixture out =
  source = "{out}/hart-registers.c"; assembly = "{out}/hart-registers.s";
  _ = runTool ["cp",fixture,source];
  _ = runTool [driver,"-O2","-ffixed-x27","-ffixed-x28","-S",source,"-o",assembly];
  # Inspect instruction operands only. Ignore directives and trailing comments.
  lines = Str.lines (readPath assembly);
  if List.any reserved lines then error "reserved x27/x28 check failed: {assembly}" else Unit.
reserved : unsafe String -> Bool .
reserved line =
  if Str.startsWith "\t" line and Str.startsWith "." (Str.trim line) == False then
    comment = Str.indexOf "//" line;
    code = (if comment < 0 then line else Str.slice line 0 comment);
    List.any (hasRegister code) ["w27","w28","x27","x28"]
  else False.
wordChar c = (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95.
hasRegister : unsafe String -> String -> Bool .
hasRegister code reg = search code reg 0.
search : unsafe String -> String -> Int -> Bool .
search code reg start =
  offset = Str.indexOf reg (Str.slice code start (Str.len code));
  if offset < 0 then False else
    pos = start + offset; end = pos + Str.len reg;
    left = (if pos == 0 then True else wordChar (Str.at code (pos - 1)) == False);
    right = (if end == Str.len code then True else wordChar (Str.at code end) == False);
    if left and right then True else search code reg end.
