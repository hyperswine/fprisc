# Validate each image slice against its own search paths and the main executable's
# paths for that architecture. @loader_path is relative to the image declaring it.
M = use "toolchain-macho".
F = use "toolchain-files".
B = use "../sol/lib/build".
marker prefix entry = entry == prefix or Str.startsWith (prefix + "/") entry.
localPath entry = marker "@loader_path" entry or marker "@executable_path" entry.
expand image exe entry =
  if marker "@loader_path" entry then M.parent image + Str.slice entry 12 (Str.len entry)
  else if marker "@executable_path" entry then M.parent exe + Str.slice entry 16 (Str.len entry)
  else entry.
inside root target = target == root or Str.startsWith (if root == "/" then "/" else "{root}/") target.
fileInside root path = B.exists "-f" path and inside root (F.canonical path).
# A search directory may be absent. Check its canonical location, including
# symlinks in the existing prefix, before admitting the directory.
resolved : unsafe String -> Int -> String .
resolved path links =
  if B.exists "-e" path then F.canonical path else
    if B.exists "-L" path then
      if links == 0 then error "symlink loop resolving {path}" else
        ProcessResult status out err = unwrap (Proc.runNow (ProcessSpec ["readlink",path] "" [] "" 0));
        if status != 0 then error "cannot read {path}: {err}" else
          link = M.trimNewline out;
          resolved (if Str.startsWith "/" link then link else M.parent path + "/" + link) (links - 1)
    else
      dir = resolved (M.parent path) links;
      name = M.base path;
      if name == "" or name == "." then dir else if name == ".." then M.parent dir
      else (if dir == "/" then "/" else dir + "/") + name.
report image entry why = "{image} loads {entry} ({why})".
problems : unsafe String -> String -> List (String,List String) -> String -> String -> List String .
problems root exe mainPaths relative arch =
  image = "{root}/{relative}";
  own = M.rpaths arch image;
  directories = List.map (expand image exe) own;
  invalid = List.filter (fn r -> not (localPath r) or not (inside root (resolved (expand image exe r) 40))) own;
  search = List.append directories (List.concat (List.map (fn pair -> (a,dirs) = pair; if a == arch then dirs else []) mainPaths));
  dependency entry =
    if M.systemLibrary entry then [] else
      if Str.startsWith "@rpath/" entry then
        if List.any (fn dir -> fileInside root (dir + "/" + Str.slice entry 7 (Str.len entry))) search then []
        else [report relative entry "no file inside the toolchain"]
      else if localPath entry then
        if fileInside root (expand image exe entry) then [] else [report relative entry "no file inside the toolchain"]
      else [report relative entry "library outside /usr/lib, /System and the toolchain"];
  List.append (List.map (fn r -> report relative r "rpath outside the toolchain") invalid)
              (List.concat (List.map dependency (M.dependencies arch image))).
verify : unsafe String -> String -> Unit .
verify prefix binary =
  root = F.canonical prefix;
  exe = F.canonical binary;
  mainPaths = List.map (fn arch -> (arch,List.map (expand exe exe) (M.rpaths arch exe))) (M.architectures exe);
  images = List.filter (fn name -> M.isImage "{root}/{name}") (F.files root);
  issues = List.concat (List.map (fn name ->
    List.concat (List.map (problems root exe mainPaths name) (M.architectures "{root}/{name}"))) images);
  if issues == [] then Unit else error (Str.join "; " issues).
main : unsafe Unit -> Unit .
> case args Unit of [root,exe] -> verify root exe | _ -> error "expected TOOLCHAIN_PREFIX EXECUTABLE".
