# pos2.sol — point of sale, second edition: modern login screen + a
# three-tab dashboard (Register / Receipts / Inventory). Auth is reused
# from lib/auth (pinned); the view composes node-local appearance values through the
# typed ui DSL. Written to 2026-09-01-STYLE.md throughout: head-clause tuple
# patterns for update, `|` guards over case-of-Bool, and |> pipelines.
#
# KV layout (store-wide, shared by every cashier, survives restarts):
#   revenue            running total (int string)
#   stock              space-joined counts aligned with `catalog`
#   receipts           newline-joined "n|cashier|total|item, item, ..."

base = use "../lib/base".
ui = use "../lib/ui".
auth = use "../lib/auth".

# ---- catalog ---------------------------------------------------------------

catalog = [("flat white", 5), ("long black", 4), ("cheese toastie", 9),
           ("brownie", 6), ("carrot cake", 7), ("sparkling water", 3)].

nameOf (n, _) = n.
priceOf (_, p) = p.
priceAt k = catalog ! k |> priceOf.   # k is the 0-based catalog index
nameAt k = catalog ! k |> nameOf.

cartTotal cart = cart |> List.map (fn k -> priceAt k) |> List.fold (fn a b -> a + b) 0.

# ---- stock: a list of ints aligned with the catalog ------------------------

initialStock = catalog |> List.map (fn t -> 12).

encStock : unsafe List f100 -> String .
encStock ns = ns |> List.map str |> joinWith " ".
decStock "" = initialStock.
decStock s = Str.split 32 s |> List.map base.pI.

joinWith : unsafe w99 -> List String -> String .
joinWith sep [] = "".
joinWith sep [x] = x.
joinWith sep (x :: r) = "{x}{sep}{joinWith sep r}".

stockAt k ns = ns ! k.
inStock k ns = stockAt k ns > 0.

# take one of each cart item out of stock; restock adds a crate of 10
adjust : unsafe (k100 -> k100) -> Int -> List k100 -> List k100 .
adjust f k ns = mapIdx (fn i n -> case i == k of True -> f n | False -> n) 0 ns.
mapIdx : unsafe (Int -> b100 -> c100) -> Int -> List b100 -> List c100 .
mapIdx f i [] = [].
mapIdx f i (x :: r) = f i x :: mapIdx f (i + 1) r.

sellCart : unsafe List Int -> List Int -> List Int .
sellCart cart ns = cart |> List.fold (fn acc k -> adjust (fn n -> n - 1) k acc) ns.
restock : unsafe Int -> List Int -> List Int .
restock k ns = adjust (fn n -> n + 10) k ns.

# ---- receipts: newline log, newest rendered first --------------------------

itemNames : unsafe List Int -> String .
itemNames cart = cart |> List.rev |> List.map (fn k -> nameAt k) |> joinWith ", ".   # ring-up order
receiptLine : unsafe r100 -> s100 -> List Int -> String .
receiptLine n who cart = "{n}|{who}|{cartTotal cart}|{itemNames cart}".
appendReceipt old line | old == "" = line.
appendReceipt old line = "{old}{base.nl}{line}".
receiptCount "" = 0.
receiptCount s = Str.split 10 s |> List.len.
parseReceipts "" = [].
parseReceipts s = Str.split 10 s |> List.rev |> List.map (fn ln -> Str.split 124 ln).

# ---- model -----------------------------------------------------------------

init tok = {user = Persistent "", pendu = "", pendp = "", note = "",
            tab = "register", cart = [], revenue = "0",
            stock = initialStock, receipts = ""}.

refreshCmds = Batch [Get "revenue" "gotrev", Get "stock" "gotstk", Get "receipts" "gotrcp"].

# ---- update: one head-clause per message ----------------------------------

update : unsafe (String, String) -> _ -> (_, Cmd) .
update ("login", v) m = auth.doLogin v m.
update ("auth", v) m = auth.doAuth v m.
update ("register", v) m = auth.doReg v m.
update ("regchk", v) m = auth.doRegchk v m.
update ("setuser", u) m = ({m | user = Persistent u, note = ""}, Msg "refresh" "").
update ("logout", _) m = ({m | user = Persistent "", cart = [], tab = "register"}, None).
update ("connected", _) m = (m, Msg "refresh" "").
update ("refresh", _) m | auth.unwrapU m == "" = (m, None).
update ("refresh", _) m = (m, refreshCmds).
update ("gotrev", v) m = ({m | revenue = str (base.pI v)}, None).
update ("gotstk", v) m = ({m | stock = decStock v}, None).
update ("gotrcp", v) m = ({m | receipts = v}, None).
update ("tab", v) m = ({m | tab = v}, None).
update ("buy", v) m | inStock (base.pI v) m.stock = ({m | cart = base.pI v :: m.cart}, None).
update ("buy", _) m = ({m | note = "out of stock"}, None).
update ("void", _) m = ({m | cart = []}, None).
update ("restock", v) m = restocked (restock (base.pI v) m.stock) m.
update ("checkout", _) m | m.cart == [] = (m, None).
update ("checkout", _) m = (m, Get "revenue" "dorev").
update ("dorev", v) m = settle (base.pI v + cartTotal m.cart) m.
update ("dorcp", v) m = record v m.
update _ m = (m, None).

restocked : unsafe List a101 -> _ -> (_, Cmd) .
restocked ns m = ({m | stock = ns}, Batch [Put "stock" (encStock ns), Msg "gotstk" (encStock ns)]).

# checkout, step 1: revenue arrived — bank it, take stock, fetch the log
settle : unsafe c101 -> _ -> (_, Cmd) .
settle rev m =
  ns = sellCart m.cart m.stock;
  ({m | revenue = str rev, stock = ns},
   Batch [Put "revenue" (str rev), Put "stock" (encStock ns), Get "receipts" "dorcp"]).

# checkout, step 2: receipts log arrived — append this sale, clear the cart
record : unsafe String -> _ -> (_, Cmd) .
record old m =
  line = receiptLine (receiptCount old + 1) (auth.unwrapU m) m.cart;
  log = appendReceipt old line;
  ({m | cart = [], receipts = log},
   Batch [Put "receipts" log, Print "sale: {line}"]).

# ---- view: login hero ------------------------------------------------------

loginView m =
  ui.el "div" [ui.Style.hero] [
    ui.el "div" [ui.Style.herocard, ui.Style.flex, ui.Style.flexcol, ui.Style.gap3] [
      ui.el "div" [ui.Style.text3xl, ui.Style.fontbold, ui.Style.brandgrad] [ui.text "Sol POS"],
      ui.el "div" [ui.Style.textmuted, ui.Style.mb2] [ui.text "Sign in to open the register"],
      ui.form "login" ["username", "password"] "Sign in",
      ui.el "div" [ui.Style.divider, ui.Style.mt2, ui.Style.mb2] [],
      ui.el "div" [ui.Style.fontsemi, ui.Style.textsm] [ui.text "New here?"],
      ui.form "register" ["username", "password"] "Create account",
      noteLine m.note
    ]
  ].

noteLine "" = ui.text "".
noteLine s = ui.el "span" [ui.Style.badgered] [ui.text s].

# ---- view: chrome ----------------------------------------------------------

navTab cur id label | cur == id = ui.onClick "tab" id (ui.el "span" [ui.Style.navtab, ui.Style.navtabactive] [ui.text label]).
navTab cur id label = ui.onClick "tab" id (ui.el "span" [ui.Style.navtab] [ui.text label]).

nav m =
  ui.el "div" [ui.Style.nav] [
    ui.el "span" [ui.Style.fontbold, ui.Style.tracking] [ui.text "Sol POS"],
    navTab m.tab "register" "Register",
    navTab m.tab "receipts" "Receipts",
    navTab m.tab "inventory" "Inventory",
    ui.el "span" [ui.Style.flex1] [],
    ui.el "span" [ui.Style.badgegreen] [ui.text "revenue ${m.revenue}"],
    ui.el "span" [ui.Style.badge] [ui.text (auth.unwrapU m)],
    ui.onClick "logout" "" (ui.el "span" [ui.Style.navtab] [ui.text "sign out"])
  ].

# ---- view: register tab ----------------------------------------------------

stockBadge n | n == 0 = ui.el "span" [ui.Style.badgered] [ui.text "sold out"].
stockBadge n | n <= 3 = ui.el "span" [ui.Style.badgeamber] [ui.text "{n} left"].
stockBadge n = ui.el "span" [ui.Style.badgegreen] [ui.text "{n} in stock"].

productCard ns k t | inStock k ns = productBody ns k t [ui.Style.cardlg, ui.Style.hoverlift, ui.Style.flex, ui.Style.flexcol, ui.Style.gap1].
productCard ns k t = productBody ns k t [ui.Style.cardlg, ui.Style.stockout, ui.Style.flex, ui.Style.flexcol, ui.Style.gap1].
productBody ns k t cs =
  ui.onClick "buy" (str k) (ui.el "div" cs [
    ui.el "div" [ui.Style.fontsemi] [ui.text (nameOf t)],
    ui.el "div" [ui.Style.flex, ui.Style.flexrow, ui.Style.itemscenter, ui.Style.justifybetween] [
      ui.el "span" [ui.Style.price] [ui.text "${priceOf t}"],
      stockBadge (stockAt k ns)
    ]
  ]).

productGrid : unsafe _ -> ui.Html .
productGrid m = ui.el "div" [ui.Style.grid, ui.Style.gridcols3, ui.Style.gap3] (mapIdx (productCard m.stock) 0 catalog).

# cart lines grouped: (name, qty, subtotal), via the prelude's groupby
cartLines cart =
  cart |> List.groupby (fn k -> k)
       |> List.map (fn g -> lineOf g).
lineOf (k, ks) = (nameAt k, List.len ks, priceAt k * List.len ks).

cartRow (n, q, sub) =
  ui.el "div" [ui.Style.flex, ui.Style.flexrow, ui.Style.gap2, ui.Style.comment] [
    ui.el "span" [ui.Style.flex1] [ui.text n],
    ui.el "span" [ui.Style.textmuted] [ui.text "x{q}"],
    ui.el "span" [ui.Style.price] [ui.text "${sub}"]
  ].

cartBody [] = [ui.el "div" [ui.Style.empty] [ui.text "Cart is empty — tap a product"]].
cartBody cart = cartLines cart |> List.map cartRow.

cartCard m =
  ui.el "div" [ui.Style.cardlg, ui.Style.flex, ui.Style.flexcol, ui.Style.gap2] [
    ui.el "div" [ui.Style.flex, ui.Style.flexrow, ui.Style.itemscenter, ui.Style.justifybetween] [
      ui.el "h3" [ui.Style.fontbold] [ui.text "Current sale"],
      ui.el "span" [ui.Style.price, ui.Style.textxl] [ui.text "${cartTotal m.cart}"]
    ],
    ui.el "div" [ui.Style.flex, ui.Style.flexcol, ui.Style.gap1] (cartBody m.cart),
    ui.el "div" [ui.Style.flex, ui.Style.flexrow, ui.Style.gap2, ui.Style.mt2] [
      ui.onClick "checkout" "" (ui.el "span" [ui.Style.btn] [ui.text "Charge ${cartTotal m.cart}"]),
      ui.onClick "void" "" (ui.el "span" [ui.Style.btnghost] [ui.text "Void"])
    ]
  ].

registerTab : unsafe _ -> ui.Html .
registerTab m = ui.el "div" [ui.Style.flex, ui.Style.flexcol, ui.Style.gap3] [productGrid m, cartCard m].

# ---- view: receipts tab ----------------------------------------------------

rcpCell cs s = ui.el "td" cs [ui.text s].
rcpRow [n, who, total, items] =
  ui.el "tr" [] [rcpCell [ui.Style.fontsemi] "#{n}", rcpCell [] who,
                 rcpCell [] items, rcpCell [ui.Style.price, ui.Style.textright] "${total}"].
rcpRow _ = ui.el "tr" [] [].

receiptsTable m =
  ui.el "table" [ui.Style.tbl] (
    ui.el "tr" [] [ui.el "th" [] [ui.text "receipt"], ui.el "th" [] [ui.text "cashier"],
                   ui.el "th" [] [ui.text "items"], ui.el "th" [ui.Style.textright] [ui.text "total"]]
    :: (parseReceipts m.receipts |> List.map rcpRow)).

receiptsBody m | m.receipts == "" = ui.el "div" [ui.Style.empty] [ui.text "No sales yet"].
receiptsBody m = receiptsTable m.

receiptsTab m =
  ui.el "div" [ui.Style.cardlg, ui.Style.flex, ui.Style.flexcol, ui.Style.gap2] [
    ui.el "h3" [ui.Style.fontbold] [ui.text "Receipts"],
    ui.el "div" [ui.Style.textmuted, ui.Style.textsm] [ui.text "{receiptCount m.receipts} sales, ${m.revenue} all-time"],
    receiptsBody m
  ].

# ---- view: inventory tab ---------------------------------------------------

invRow ns k t =
  ui.el "tr" [] [
    ui.el "td" [ui.Style.fontsemi] [ui.text (nameOf t)],
    ui.el "td" [ui.Style.price] [ui.text "${priceOf t}"],
    ui.el "td" [] [stockBadge (stockAt k ns)],
    ui.el "td" [ui.Style.textright] [ui.onClick "restock" (str k) (ui.el "span" [ui.Style.btnghost] [ui.text "+10"])]
  ].

inventoryTab : unsafe _ -> ui.Html .
inventoryTab m =
  ui.el "div" [ui.Style.cardlg, ui.Style.flex, ui.Style.flexcol, ui.Style.gap2] [
    ui.el "h3" [ui.Style.fontbold] [ui.text "Inventory"],
    ui.el "table" [ui.Style.tbl] (
      ui.el "tr" [] [ui.el "th" [] [ui.text "product"], ui.el "th" [] [ui.text "price"],
                     ui.el "th" [] [ui.text "stock"], ui.el "th" [ui.Style.textright] [ui.text "restock"]]
      :: mapIdx (invRow m.stock) 0 catalog)
  ].

# ---- view: shell -----------------------------------------------------------

tabView : unsafe _ -> ui.Html .
tabView m | m.tab == "receipts" = receiptsTab m.
tabView m | m.tab == "inventory" = inventoryTab m.
tabView m = registerTab m.

dashboard : unsafe _ -> ui.Html .
dashboard m =
  ui.el "div" [] [
    nav m,
    ui.el "div" [ui.Style.container, ui.Style.mxauto, ui.Style.p4, ui.Style.flex, ui.Style.flexcol, ui.Style.gap4] [tabView m]
  ].

body : unsafe _ -> ui.Html .
body m | auth.unwrapU m == "" = loginView m.
body m = dashboard m.

view : unsafe _ -> ui.Html .
view m = ui.el "div" [ui.Style.appbg] [ui.dyn "main" (body m)].

> View.serve 8084 init update view [].
