# Transactional JSON config update. Precedence: CLI > named env > JSON.
# fpr sol sol/scripts/config-update.sol CONFIG [--label TEXT] [--attempts N]
C = use "../lib/config".
J = use "../lib/json".
CLI = use "../lib/cli".
options = [CLI.Option "label" "l" CLI.One, CLI.Option "attempts" "n" CLI.One].
label parsed json = case CLI.values "label" parsed of
  [] -> C.string "label" "SOL_CONFIG_LABEL" json
| value :: rest -> Ok value.
attempts parsed json =
  chosen = case CLI.values "attempts" parsed of
    [] -> C.integer "attempts" "SOL_CONFIG_ATTEMPTS" json
  | value :: rest -> Try.parseInt value;
  chosen |>? (fn n -> if and (n >= 0) (n <= 10) then Ok n else Err "config 'attempts': expected 0..10").
update path parsed =
  json = unwrap (C.read path |>? C.schema ["label","attempts"]);
  text = unwrap (label parsed json);
  n = unwrap (attempts parsed json);
  next = json |> J.set "label" (J.JStr text) |> J.set "attempts" (J.JNum n);
  writePath path "{J.render next}\n".
main = parsed = unwrap (CLI.parse options (args Unit));
  case CLI.operands parsed of [path] -> update path parsed | _ -> error "usage: config-update.sol CONFIG [--label TEXT] [--attempts N]".
