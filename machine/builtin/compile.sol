# Shared compiler invocation for builtin images and exported libraries.
B = use "../../sol/lib/build".
compile compiler source target flags =
  parts = Str.split 47 target;
  dir = Str.join "/" (List.take (List.len parts - 1) parts);
  parent = (if dir == "" then (if Str.startsWith "/" target then "/" else ".") else dir);
  _ = B.command ["mkdir","-p",parent];
  B.command ([compiler,"--system=bare-metal","--profile=builtin"] + flags + [source,target]).
> case args Unit of
    "image" :: compiler :: source :: target :: flags -> compile compiler source target flags
  | "library" :: compiler :: source :: target :: exports :: flags ->
      compile compiler source target (["--arc"] + flags + ["--lib","--export={exports}"])
  | _ -> error "usage: compile.sol image|library COMPILER SOURCE OUTPUT [EXPORTS for library] [FLAGS...]".
