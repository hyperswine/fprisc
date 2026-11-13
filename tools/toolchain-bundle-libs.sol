# Copy the transitive dylib dependencies before rewriting any load commands.
B = use "../sol/lib/build".
F = use "toolchain-files".
M = use "toolchain-macho".
J = use "../sol/lib/json".
Library = Type (Library String String String String String (List String)).
State = Type (State (List String) (List (String,String)) (List Library)).
libSource (Library _ real _ _ _ _) = real.
libName (Library _ _ name _ _ _) = name.
metadata (Library install real name pkg version notices) =
  J.JObj [("installName",J.JStr install),("file",J.JStr ("lib/" + name)),("source",J.JStr real),
          ("package",J.JStr pkg),("packageVersion",J.JStr version),("notices",J.JArr (List.map J.JStr notices))].
notices keg =
  ProcessResult status out err = unwrap (Proc.runNow (ProcessSpec ["find",".","-mindepth","1","-maxdepth","1","-print0"] keg [] "" 0));
  if status != 0 then error "listing license notices in {keg}: {err}" else
    names = List.map (fn p -> M.base p) (List.filter (fn p -> p != "") (Str.split 0 out));
    F.ordered (List.filter (fn n -> List.any (fn pre -> Str.startsWith pre (Str.upper n)) ["LICENSE","LICENCE","COPYING","NOTICE"]
                               and B.exists "-f" "{keg}/{n}") names).
collectDependency sdk image state dep = case state of State queue aliases libraries ->
  if M.systemLibrary dep or List.any (fn pair -> (path,_) = pair; path == dep) aliases then state else
    if not (Str.startsWith "/" dep) then error "{image} loads {dep}; build with absolute install names" else
      real = F.canonical dep;
      name = M.base dep;
      case List.filter (fn lib -> libSource lib == real) libraries of
        first :: _ -> State queue ((dep,libName first) :: aliases) libraries
      | [] -> if List.any (fn lib -> libName lib == name) libraries then error "two bundled libraries share the name {name}" else
          keg = M.parent (M.parent real);
          version = M.base keg;
          pkg = M.base (M.parent keg);
          sources = notices keg;
          if sources == [] then error "no license notice beside {real} (looked in {keg})" else
            dir = "lib/licenses/{pkg}-{version}";
            _ = B.command ["mkdir","-p","{sdk}/{dir}"];
            copy = "{sdk}/lib/{name}";
            _ = B.command ["cp","-p",real,copy];
            _ = B.command ["chmod","755",copy];
            _ = List.map (fn n -> _ = B.command ["cp","-pL","{keg}/{n}","{sdk}/{dir}/{n}"];
                                 B.command ["chmod","644","{sdk}/{dir}/{n}"]) sources;
            lib = Library dep real name pkg version (List.map (fn n -> "{dir}/{n}") sources);
            State (copy :: queue) ((dep,name) :: aliases) (lib :: libraries).
unique values = List.rev (List.fold (fn acc x -> if List.has x acc then acc else x :: acc) [] values).
allDeps image = unique (List.concat (List.map (fn arch -> M.dependencies arch image) (M.architectures image))).
closure : unsafe String -> State -> State .
closure sdk state = case state of State [] _ _ -> state | State (image :: rest) aliases libraries ->
  closure sdk (List.fold (collectDependency sdk image) (State rest aliases libraries) (allDeps image)).
rewrite exe aliases image =
  want = if image == exe then "@executable_path/lib" else "@loader_path";
  idArgs = if image == exe then [] else ["-id","@rpath/" + M.base image];
  change dep = case List.filter (fn pair -> (path,_) = pair; path == dep) aliases of
      [] -> [] | (_,name) :: _ -> ["-change",dep,"@rpath/{name}"];
  changes = List.concat (List.map change (allDeps image));
  perArch = List.map (fn arch -> List.has want (M.rpaths arch image)) (M.architectures image);
  pathArgs = if aliases == [] or List.all (fn p -> p) perArch then []
             else if List.any (fn p -> p) perArch then error "inconsistent {want} rpath across slices of {image}"
             else ["-add_rpath",want];
  options = List.concat [idArgs,changes,pathArgs];
  if options == [] then Unit else
    _ = B.command (List.append ("install_name_tool" :: options) [image]);
    B.command ["codesign","--force","--sign","-",image].
bundle : unsafe String -> String -> J.Json .
bundle sdk exe =
  State _ aliases reversed = closure sdk (State [exe] [] []);
  libraries = List.rev reversed;
  _ = List.map (rewrite exe aliases) (exe :: List.map (fn lib -> "{sdk}/lib/" + libName lib) libraries);
  J.JArr (List.map metadata libraries).
main : unsafe Unit -> Unit .
> case args Unit of [sdk,exe] -> print (J.render (bundle sdk exe)) | _ -> error "expected SDK_DIRECTORY EXECUTABLE".
