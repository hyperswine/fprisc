# Immutable qualification fixtures live in pi-fixtures; building needs no test interpreter.
J = use "../sol/lib/json".
CLI = use "../sol/lib/cli".
F = use "toolchain-files".
B = use "../sol/lib/build".
Q = use "pi-qualification-build".
options = List.map (fn name -> CLI.Option name "" CLI.One) ["root","output","runner-source","rounds","repetitions","cross-cc","plan-output"] +
  List.map (fn name -> CLI.Option "{name}-only" "" CLI.Switch) ["imported-carrier","carrier","fields","storage","variant","transport"].
field value name = unwrap (J.get name value).
replace : unsafe String -> String -> J.Json -> J.Json .
replace root out value = case value of
    J.JStr s -> J.JStr (Str.replace "@OUT@" out (Str.replace "@ROOT@" root s))
  | J.JArr xs -> J.JArr (List.map (replace root out) xs)
  | J.JObj xs -> J.JObj (List.map (fn pair -> (k,v) = pair; (k,replace root out v)) xs)
  | _ -> value.
fixture root row = case row of
    J.JArr (name :: source :: rest) ->
      path = unwrap (J.get "fixture" source |>? J.text);
      J.JArr (name :: J.JStr (F.readText "{root}/tools/pi-fixtures/{path}") :: rest)
  | _ -> error "invalid fixture row".
main : unsafe Unit -> Unit .
main _ =
  parsed = unwrap (CLI.parse options (args Unit));
  _ = if CLI.operands parsed == [] then Unit else error "unexpected operand";
  get name = CLI.valueOr "" name parsed;
  root = F.canonical (get "root");
  requestedOut = get "output";
  _ = B.command ["mkdir","-p",B.query ["dirname",requestedOut]];
  out = F.canonical (B.query ["dirname",requestedOut]) + "/" + B.query ["basename",requestedOut];
  runner = F.canonical (get "runner-source");
  rounds = Str.parse (CLI.valueOr "256" "rounds" parsed);
  repetitions = Str.parse (CLI.valueOr "3" "repetitions" parsed);
  _ = if out != "" and rounds >= 64 and repetitions >= 1 then Unit else error "output required, rounds >= 64 and repetitions >= 1";
  selected = List.filter (fn name -> CLI.flag "{name}-only" parsed) ["imported-carrier","carrier","fields","storage","variant","transport"];
  focus = case selected of [] -> "full" | [name] -> name | _ -> error "choose only one qualification slice";
  plan = replace root out (unwrap (J.parse (F.readText "{root}/tools/pi-fixtures/{focus}.json")));
  files = J.set "plan_sha256" (J.JStr "{root}/tools/pi-fixtures/{focus}.json") (J.set "runner_source_sha256" (J.JStr runner) (J.set "cross_wrapper_sha256" (if get "cross-cc" == "" then J.JNull else J.JStr (F.canonical (get "cross-cc"))) (field plan "files")));
  meta = J.set "rounds" (J.JNum rounds) (J.set "repetitions" (J.JNum repetitions) (field plan "metadata"));
  jobs = unwrap (J.items (field plan "builds"));
  ready = List.fold (fn obj pair -> (k,v) = pair; J.set k v obj) plan
    [("files",files),("metadata",meta),("builds",J.JArr (List.map (fixture root) jobs)),
     ("compiler",J.JStr (if get "cross-cc" == "" then "cc" else get "cross-cc")),("mode",J.JStr (if get "cross-cc" == "" then "native" else "cross"))];
  scratch = tempDir "pi-build-plan";
  input = "{scratch}/plan.json";
  _ = Q.writeFixture input (J.pretty ready);
  if get "plan-output" != "" then Q.writeFixture (get "plan-output") (J.pretty ready) else
    _ = B.command ["mkdir",out];
    ProcessResult status environment err = unwrap (Proc.runNow (ProcessSpec ["env","-0"] "" [] "" 0));
    _ = if status == 0 then Unit else error "cannot read compiler environment: {err}";
    names = List.map (fn item -> case Str.split 61 item of name::_ -> name | _ -> "") (Str.split 0 environment);
    unset = List.concat (List.map (fn name -> ["-u",name]) (List.filter (Str.startsWith "FPR_") names));
    runner = B.setting "SOL" "sol";
    B.command (["env"] + unset + ["FPR_HOME={root}","FPR_PATH={root}","XDG_CACHE_HOME={out}/cache",runner,"{root}/tools/pi-qualification-build.sol",input,"{out}/manifest.json"]).
> main Unit.
