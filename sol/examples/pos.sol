# pos.sol — point of sale with cashier sign-in. Catalog is static Sol data;
# the cart is runtime state; store-wide revenue accumulates in KV and is
# shared across every cashier and every restart.

base = use "../lib/base".
ui = use "../lib/ui".

unwrapU model = case model.user of Persistent u -> u.

doLogin v model = (u, p) = base.splitFirst v; ({model | pendu = u, pendp = p}, Get "user:{u}" "auth").
doAuth stored model | stored == "" = ({model | note = "no such user"}, None).
doAuth stored model | stored == model.pendp = (model, Msg "setuser" model.pendu).
doAuth stored model = ({model | note = "wrong password"}, None).
doReg v model = (u, p) = base.splitFirst v; ({model | pendu = u, pendp = p}, Get "user:{u}" "regchk").
doRegchk stored model | stored == "" = (model, Batch [Put "user:{model.pendu}" model.pendp, Msg "setuser" model.pendu]).
doRegchk stored model = ({model | note = "user already exists"}, None).

catalog = [("flat white", 5), ("long black", 4), ("cheese toastie", 9), ("brownie", 6)].

priceOf (n, p) = p.
nameOf (n, p) = n.
addPrice a t = a + priceOf t.
cartTotal cart = List.fold addPrice 0 cart.

init tok = {user = Persistent "", pendu = "", pendp = "", note = "", cart = [], revenue = ""}.

# one clause per message. Messages are (name, payload) strings from the
# browser; a sum type would be checked, but these are few and stable.
update ("login", v) model = doLogin v model.
update ("auth", v) model = doAuth v model.
update ("register", v) model = doReg v model.
update ("regchk", v) model = doRegchk v model.
update ("setuser", u) model = ({model | user = Persistent u, note = ""}, Msg "refresh" "").
update ("logout", v) model = ({model | user = Persistent "", cart = []}, None).
update ("connected", v) model = (model, Msg "refresh" "").
update ("refresh", v) model | unwrapU model == "" = (model, None).
update ("refresh", v) model = (model, Get "revenue" "gotrev").
update ("gotrev", v) model = ({model | revenue = str (base.pI v)}, None).
update ("buy", v) model = ({model | cart = (catalog ! Str.parse v) :: model.cart}, None).
update ("void", v) model = ({model | cart = []}, None).
update ("checkout", v) model | model.cart == [] = (model, None).
update ("checkout", v) model = (model, Get "revenue" "dorev").
update ("dorev", v) model = sale (base.pI v + cartTotal model.cart) model.
update msg model = (model, None).

# record a sale: the new store-wide revenue goes to KV and back to this view
sale total model =
  ({model | cart = []},
   Batch [Put "revenue" (str total),
          Msg "gotrev" (str total),
          Print "sale: {cartTotal model.cart} by {unwrapU model}"]).

# ui.el and ui.form are helpers for generating HTML elements and forms. ui.onClick is a helper for generating clickable elements that send messages to the update function.
# they could probably just be their own fuctions like div/2 or form/3, but this is a bit more convenient for now. The ui module could be expanded to include more helpers for generating HTML elements and forms.
# we are using ui.Style.* which is better than hardcoding style strings

# ui.onClick is its own element rather than some callback or something
# with it we can just directly generate the right html and js like a button with an onclick handler that sends a message to the update function

loginView model =
  ui.el "div" [ui.Style.card, ui.Style.flex, ui.Style.flexcol, ui.Style.gap3] [
    ui.el "h2" [ui.Style.textxl, ui.Style.fontbold] [ui.text "Cashier sign in"],
    ui.form "login" ["username", "password"] "Sign in",
    ui.el "h3" [ui.Style.fontbold] [ui.text "Register"],
    ui.form "register" ["username", "password"] "Create account",
    ui.el "span" [ui.Style.textmuted] [ui.text model.note]
  ].

productBtn (k, t) =
  ui.onClick "buy" (str k) (ui.el "div" [ui.Style.card, ui.Style.flex, ui.Style.flexcol, ui.Style.gap1] [
    ui.el "div" [ui.Style.fontbold] [ui.text (nameOf t)],
    ui.el "div" [ui.Style.textmuted] [ui.text "${priceOf t}"]
  ]).

# each item paired with its 0-based position
indexed xs = List.zip (List.range 0 (List.len xs - 1)) xs.

cartRow t = ui.el "div" [ui.Style.comment, ui.Style.flex, ui.Style.flexrow, ui.Style.gap2] [
  ui.el "span" [ui.Style.flex1] [ui.text (nameOf t)], ui.el "span" [] [ui.text "${priceOf t}"]].

posView model =
  ui.el "div" [ui.Style.flex, ui.Style.flexcol, ui.Style.gap3] [
    ui.el "div" [ui.Style.flex, ui.Style.flexrow, ui.Style.itemscenter, ui.Style.gap3] [
      ui.el "span" [ui.Style.badge] [ui.text "cashier: {unwrapU model}"],
      ui.el "span" [ui.Style.badge] [ui.text "revenue: ${model.revenue}"],
      ui.onClick "logout" "" (ui.el "span" [ui.Style.tab] [ui.text "sign out"])
    ],
    ui.el "div" [ui.Style.grid, ui.Style.gridcols2, ui.Style.gap3] (indexed catalog |> List.map productBtn),
    ui.el "div" [ui.Style.card, ui.Style.flex, ui.Style.flexcol, ui.Style.gap2] [
      ui.el "h3" [ui.Style.fontbold] [ui.text "cart - total ${cartTotal model.cart}"],
      ui.el "div" [ui.Style.flex, ui.Style.flexcol, ui.Style.gap1] (List.map cartRow model.cart),
      ui.el "div" [ui.Style.flex, ui.Style.flexrow, ui.Style.gap2] [
        ui.onClick "checkout" "" (ui.el "span" [ui.Style.btn] [ui.text "checkout"]),
        ui.onClick "void" "" (ui.el "span" [ui.Style.tab] [ui.text "void"])
      ]
    ]
  ].

view model =
  ui.el "div" [ui.Style.container, ui.Style.mxauto, ui.Style.flex, ui.Style.flexcol, ui.Style.gap4, ui.Style.p4] [
    ui.el "header" [ui.Style.flex, ui.Style.flexrow, ui.Style.itemscenter, ui.Style.gap3] [ui.el "h1" [ui.Style.text2xl, ui.Style.fontbold] [ui.text "Sol POS"]],
    ui.dyn "main" (case unwrapU model == "" of True -> loginView model | False -> posView model)
  ].

> View.serve 8083 init update view [].
