# dash.sol — a live dashboard with sign-in. Metrics tick server-side and
# push to the browser (no client events). Total sign-ins persist in KV;
# the live series is runtime state, abandoned on restart by design.

# Ideally unwrapU would be a standard Persistent projection.

base = use "../lib/base".
ui = use "../lib/ui".

# infers as Persistent String.
unwrapU model = case model.user of Persistent u -> u.

doLogin v model = (u, p) = base.splitFirst v; ({model | pendu = u, pendp = p}, Get "user:{u}" "auth").


# check if user exists and password matches; if so, set as current user
doAuth stored model | stored == "" = ({model | note = "no such user"}, None).
doAuth stored model | stored == model.pendp = (model, Msg "setuser" model.pendu).
doAuth stored model = ({model | note = "wrong password"}, None).

doReg v model = (u, p) = base.splitFirst v; ({model | pendu = u, pendp = p}, Get "user:{u}" "regchk").

# check if user exists; if not, create it and set as current user. If exists, return error note.
doRegchk stored model | stored == "" = (model, Batch [Put "user:{model.pendu}" model.pendp, Msg "setuser" model.pendu]).
doRegchk stored model = ({model | note = "user already exists"}, None).

init tok = {user = Persistent "", pendu = "", pendp = "", note = "", series = [], reqs = 0, logins = ""}.

# one clause per message
update : (String, String) -> _ -> (_, Cmd) .
update ("login", v) model = doLogin v model.
update ("auth", v) model = doAuth v model.
update ("register", v) model = doReg v model.
update ("regchk", v) model = doRegchk v model.
update ("setuser", u) model = ({model | user = Persistent u, note = ""}, Batch [Msg "refresh" "", Get "logins" "bump"]).
update ("bump", v) model = (model, Batch [Put "logins" (str (base.pI v + 1)), Msg "gotlogins" (str (base.pI v + 1))]).
update ("logout", v) model = ({model | user = Persistent ""}, None).
update ("connected", v) model = (model, Msg "refresh" "").
update ("refresh", v) model | unwrapU model == "" = (model, None).
update ("refresh", v) model = (model, Get "logins" "gotlogins").
update ("gotlogins", v) model = ({model | logins = v}, None).
update ("tick", v) model | unwrapU model == "" = (model, None).
update ("tick", v) model = (model, Rng 20 95 "sample").
update ("sample", v) model = ({model | reqs = Str.parse v, series = List.take 10 (Str.parse v :: model.series)}, None).
update msg model = (model, None).

bar n = Str.repeat n "#".

sampleRow : Int -> ui.Html .
sampleRow v = ui.el "div" [ui.Style.textsm] [ui.text "{bar (v / 8)} {v}"].

loginView model =
  ui.el "div" [ui.Style.card, ui.Style.flex, ui.Style.flexcol, ui.Style.gap3] [
    ui.el "h2" [ui.Style.textxl, ui.Style.fontbold] [ui.text "Ops sign in"],
    ui.form "login" ["username", "password"] "Sign in",
    ui.el "h3" [ui.Style.fontbold] [ui.text "Register"],
    ui.form "register" ["username", "password"] "Create account",
    ui.el "span" [ui.Style.textmuted] [ui.text model.note]
  ].

dashView model =
  ui.el "div" [ui.Style.flex, ui.Style.flexcol, ui.Style.gap3] [
    ui.el "div" [ui.Style.flex, ui.Style.flexrow, ui.Style.itemscenter, ui.Style.gap3] [
      ui.el "span" [ui.Style.badge] [ui.text (unwrapU model)],
      ui.onClick "logout" "" (ui.el "span" [ui.Style.tab] [ui.text "sign out"])
    ],
    ui.el "div" [ui.Style.grid, ui.Style.gridcols2, ui.Style.gap3] [
      ui.el "div" [ui.Style.card, ui.Style.flex, ui.Style.flexcol, ui.Style.gap1] [
        ui.el "h3" [ui.Style.fontbold] [ui.text "requests/sec"],
        ui.el "div" [ui.Style.text2xl, ui.Style.fontbold] [ui.text (str model.reqs)]
      ],
      ui.el "div" [ui.Style.card, ui.Style.flex, ui.Style.flexcol, ui.Style.gap1] [
        ui.el "h3" [ui.Style.fontbold] [ui.text "total sign-ins"],
        ui.el "div" [ui.Style.text2xl, ui.Style.fontbold] [ui.text model.logins]
      ],
      ui.el "div" [ui.Style.card, ui.Style.flex, ui.Style.flexcol, ui.Style.gap1] [
        ui.el "h3" [ui.Style.fontbold] [ui.text "history"],
        ui.el "div" [ui.Style.flex, ui.Style.flexcol, ui.Style.gap1] (List.map sampleRow model.series)
      ],
      ui.el "div" [ui.Style.card, ui.Style.flex, ui.Style.flexcol, ui.Style.gap1] [
        ui.el "h3" [ui.Style.fontbold] [ui.text "about"],
        ui.el "p" [ui.Style.textmuted, ui.Style.textsm] [ui.text "live series is runtime state - it resets on restart; sign-ins persist in KV"]
      ]
    ]
  ].

view model =
  ui.el "div" [ui.Style.container, ui.Style.mxauto, ui.Style.flex, ui.Style.flexcol, ui.Style.gap4, ui.Style.p4] [
    ui.el "header" [ui.Style.flex, ui.Style.flexrow, ui.Style.itemscenter, ui.Style.gap3] [ui.el "h1" [ui.Style.text2xl, ui.Style.fontbold] [ui.text "Sol Ops"]],
    ui.dyn "main" (case unwrapU model == "" of True -> loginView model | False -> dashView model)
  ].

> View.serve 8082 init update view [(500, "tick")].
