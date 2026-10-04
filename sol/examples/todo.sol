# todo.sol — todos with sign-in. Accounts + todo lists live in the shared
# KV store (todo.solkv), so your list follows your login across browsers.
# The view uses the TYPED DSL (lib/ui.sol): Html ADT + Style symbols —
# this file typechecks, no # sol:notypes pragma needed.
# The signed-in user is `Persistent` (event-sourced, survives restarts);
# the in-model todo list is runtime state, refreshed from KV on connect.

base = use "../lib/base".
ui = use "../lib/ui".

# ---- auth (the shared pattern: KV accounts + replay-safe Msg setuser) ----
unwrapU model = case model.user of Persistent u -> u.

doLogin v model =
  (u, p) = base.splitFirst v;
  ({model | pendu = u, pendp = p}, Get "user:{u}" "auth").

doAuth stored model | stored == "" = ({model | note = "no such user"}, None).
doAuth stored model | stored == model.pendp = (model, Msg "setuser" model.pendu).
doAuth stored model = ({model | note = "wrong password"}, None).

doReg v model =
  (u, p) = base.splitFirst v;
  ({model | pendu = u, pendp = p}, Get "user:{u}" "regchk").

doRegchk stored model | stored == "" = (model, Batch [Put "user:{model.pendu}" model.pendp, Msg "setuser" model.pendu]).
doRegchk stored model = ({model | note = "user already exists"}, None).

# ---- todos: serialized one per line as "<done> <text>" in KV -------------
parseItem line = (d, x) = base.splitFirst line; (base.pI d, x).
parseTodos s = Str.lines s |> List.map parseItem.

serItem (d, x) = "{d} {x}".
serTodos ts = ts |> List.map serItem |> Str.join base.nl.

flipItem (d, x) = (1 - d, x).
toggleAt i ts = base.indexed ts |> List.map (flipIfAt i).
flipIfAt i (k, t) | k == i = flipItem t.
flipIfAt i (k, t) = t.

isOpen (d, x) = d == 0.
openCount ts = ts |> List.filter isOpen |> List.len.

save ts model = ({model | todos = ts}, Put "todos:{unwrapU model}" (serTodos ts)).

# ---- MVU ------------------------------------------------------------------
init tok = {user = Persistent "", pendu = "", pendp = "", note = "", todos = []}.

# one clause per message
update : (String, String) -> _ -> (_, Cmd) .
update ("login", v) model = doLogin v model.
update ("auth", v) model = doAuth v model.
update ("register", v) model = doReg v model.
update ("regchk", v) model = doRegchk v model.
update ("setuser", u) model = ({model | user = Persistent u, note = ""}, Msg "refresh" "").
update ("logout", v) model = ({model | user = Persistent "", todos = []}, None).
update ("connected", v) model = (model, Msg "refresh" "").
update ("refresh", v) model | unwrapU model == "" = (model, None).
update ("refresh", v) model = (model, Get "todos:{unwrapU model}" "gottodos").
update ("gottodos", v) model = ({model | todos = parseTodos v}, None).
update ("add", v) model = save ((0, v) :: model.todos) model.
update ("toggle", v) model = toggle (Try.parseInt v) model.
update ("clear", v) model = save (List.filter isOpen model.todos) model.
update msg model = (model, None).

# the browser names a row; a non-number is a forged or stale request, logged
# and ignored (an out-of-range row already toggles nothing)
toggle (Ok i) model = save (toggleAt i model.todos) model.
toggle (Err e) model = (model, Print "ignored toggle: {e}").

# ---- view (typed DSL: ui.Html + ui.Style symbols) ---------------------------

loginView model =
  ui.div [ui.Style.card, ui.Style.flex, ui.Style.flexcol, ui.Style.gap3] [
    ui.h2 [ui.Style.textxl, ui.Style.fontbold] [ui.text "Sign in"],
    ui.form "login" ["username", "password"] "Sign in",
    ui.h3 [ui.Style.fontbold] [ui.text "New here? Register"],
    ui.form "register" ["username", "password"] "Create account",
    ui.span [ui.Style.textmuted] [ui.text model.note]
  ].

todoItem (k, (d, x)) =
  ui.onClick "toggle" (str k)
    (ui.div (case d == 1 of True -> [ui.Style.comment, ui.Style.textmuted] | False -> [ui.Style.comment]) [
      ui.text (case d == 1 of True -> "[x] {x}" | False -> "[ ] {x}")
    ]).

todoView model =
  ui.div [ui.Style.flex, ui.Style.flexcol, ui.Style.gap3] [
    ui.div [ui.Style.flex, ui.Style.flexrow, ui.Style.itemscenter, ui.Style.gap3] [
      ui.span [ui.Style.badge] [ui.text "{unwrapU model} - {openCount model.todos} open"],
      ui.onClick "clear" "" (ui.span [ui.Style.tab] [ui.text "clear done"]),
      ui.onClick "logout" "" (ui.span [ui.Style.tab] [ui.text "sign out"])
    ],
    ui.div [ui.Style.card, ui.Style.flex, ui.Style.flexcol, ui.Style.gap2] [
      ui.inputRow "add" "what needs doing?" "Add",
      ui.div [ui.Style.flex, ui.Style.flexcol, ui.Style.gap1] (base.indexed model.todos |> List.map todoItem)
    ]
  ].

view model =
  ui.div [ui.Style.container, ui.Style.mxauto, ui.Style.flex, ui.Style.flexcol, ui.Style.gap4, ui.Style.p4] [
    ui.el "header" [ui.Style.flex, ui.Style.flexrow, ui.Style.itemscenter, ui.Style.gap3] [
      ui.h1 [ui.Style.text2xl, ui.Style.fontbold] [ui.text "Sol Todos"]
    ],
    ui.dyn "main" (case unwrapU model == "" of True -> loginView model | False -> todoView model)
  ].

> View.serve 8081 init update view [].
