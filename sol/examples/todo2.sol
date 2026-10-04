# todo2.sol — the todo app rebuilt on `use`d libraries: base (helpers),
# web (view vocabulary), auth (sign-in pattern). Compare with todo.sol:
# the app is now ONLY its own logic.

base = use "../lib/base#f9616700c2a16d11".
ui = use "../lib/ui#24f48582c24bf402".
auth = use "../lib/auth#668a459dce40f198".

# ---- todos: one per line as "<done> <text>" in KV --------------------------
parseItem line = (d, x) = base.splitFirst line; (base.pI d, x).
parseTodos s = Str.split 10 s |> List.map parseItem.

serItem (d, x) = "{d} {x}".
serTodos ts = ts |> List.map serItem |> Str.join base.nl.

flipItem (d, x) = (1 - d, x).
toggleAt i ts = base.indexed ts |> List.map (flipIfAt i).
flipIfAt i (k, t) | k == i = flipItem t.
flipIfAt i (k, t) = t.

isOpen (d, x) = d == 0.
openCount ts = ts |> List.filter isOpen |> List.len.

save ts model = ({model | todos = ts}, Put "todos:{auth.unwrapU model}" (serTodos ts)).

# ---- MVU --------------------------------------------------------------------
init tok = {user = Persistent "", pendu = "", pendp = "", note = "", todos = []}.

# one clause per message
update : (String, String) -> _ -> (_, Cmd) .
update ("login", v) model = auth.doLogin v model.
update ("auth", v) model = auth.doAuth v model.
update ("register", v) model = auth.doReg v model.
update ("regchk", v) model = auth.doRegchk v model.
update ("setuser", u) model = ({model | user = Persistent u, note = ""}, Msg "refresh" "").
update ("logout", v) model = ({model | user = Persistent "", todos = []}, None).
update ("connected", v) model = (model, Msg "refresh" "").
update ("refresh", v) model | auth.unwrapU model == "" = (model, None).
update ("refresh", v) model = (model, Get "todos:{auth.unwrapU model}" "gottodos").
update ("gottodos", v) model = ({model | todos = parseTodos v}, None).
update ("add", v) model = save ((0, v) :: model.todos) model.
update ("toggle", v) model = toggle (Try.parseInt v) model.
update ("clear", v) model = save (List.filter isOpen model.todos) model.
update msg model = (model, None).

# the browser names a row; a non-number is a forged or stale request, logged
# and ignored (an out-of-range row already toggles nothing)
toggle (Ok i) model = save (toggleAt i model.todos) model.
toggle (Err e) model = (model, Print "ignored toggle: {e}").

# ---- view --------------------------------------------------------------------
todoItem (k, (d, x)) =
  ui.onClick "toggle" (str k)
    (ui.div (case d == 1 of True -> [ui.Style.comment, ui.Style.textmuted] | False -> [ui.Style.comment]) [
      ui.text (case d == 1 of True -> "[x] {x}" | False -> "[ ] {x}")
    ]).

todoView model =
  ui.col [] [
    ui.row [ui.Style.itemscenter] [
      ui.badge "{auth.unwrapU model} - {openCount model.todos} open",
      ui.tabBtn "clear" "" "clear done",
      ui.tabBtn "logout" "" "sign out"
    ],
    ui.card [
      ui.inputRow "add" "what needs doing?" "Add",
      ui.col [ui.Style.gap1] (base.indexed model.todos |> List.map todoItem)
    ]
  ].

view model =
  ui.div [ui.Style.container, ui.Style.mxauto, ui.Style.flex, ui.Style.flexcol, ui.Style.gap4, ui.Style.p4] [
    ui.el "header" [ui.Style.flex, ui.Style.flexrow, ui.Style.itemscenter, ui.Style.gap3] [ui.title "Sol Todos"],
    ui.dyn "main" (case auth.unwrapU model == "" of
      True -> auth.loginView "Sign in" model
    | False -> todoView model)
  ].

> View.serve 8081 init update view [].
