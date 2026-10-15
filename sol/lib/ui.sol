# ui.sol — the typed view DSL: an Html ADT (Elm-style) + first-class
# node-local style values exported from typed std/view generation.
#
# Views built with these helpers TYPECHECK (no # sol:notypes needed):
# Html is nominal and recursive, which structural rows can't express —
# this is the Node-ADT decision from the README's gradual-boundary note.
# Web.hs serializes the constructors to the generated hosted client protocol.
# Appearance values compose by stage/property on each individual node.
#
#   view model = ui.div [ui.Style.card] [
#     ui.h2 [ui.Style.textxl] [ui.text "hello"],
#     ui.onClick "add" "1" (ui.text "+")
#   ].
#
# A typo'd style (ui.Style.crd) or element helper is a COMPILE error.

S = use "webstyles".

Html = Type (
    El String (List String) (List Html)
  | Txt String
  | EvN String String Html
  | DynN String Html
  | KeyN String Html
  | FormN String (List String) String
  | InpN String String String
).

# Named values carry local atoms, never browser class-registry keys.
Style = Struct {
  reset = S.reset,
  headcell = S.headcell,
  cell = S.cell,
  tablerow = S.tablerow,
  container = S.container,
  mxauto = S.mxauto,
  flex = S.flex,
  flexcol = S.flexcol,
  flexrow = S.flexrow,
  flexwrap = S.flexwrap,
  flex1 = S.flex1,
  itemscenter = S.itemscenter,
  grid = S.grid,
  gridcols2 = S.gridcols2,
  gridcols3 = S.gridcols3,
  gap1 = S.gap1,
  gap2 = S.gap2,
  gap3 = S.gap3,
  gap4 = S.gap4,
  p2 = S.p2,
  p4 = S.p4,
  px3 = S.px3,
  py1 = S.py1,
  rounded = S.rounded,
  border = S.border,
  shadow = S.shadow,
  card = S.card,
  textsm = S.textsm,
  textxl = S.textxl,
  text2xl = S.text2xl,
  text3xl = S.text3xl,
  textxs = S.textxs,
  fontbold = S.fontbold,
  fontsemi = S.fontsemi,
  tracking = S.tracking,
  textmuted = S.textmuted,
  badge = S.badge,
  tab = S.tab,
  tabactive = S.tabactive,
  clickable = S.clickable,
  comment = S.comment,
  input = S.input,
  btn = S.btn,
  appbg = S.appbg,
  hero = S.hero,
  herocard = S.herocard,
  brandgrad = S.brandgrad,
  nav = S.nav,
  navtab = S.navtab,
  navtabactive = S.navtabactive,
  wfull = S.wfull,
  justifybetween = S.justifybetween,
  textright = S.textright,
  textcenter = S.textcenter,
  mt2 = S.mt2,
  mb2 = S.mb2,
  cardlg = S.cardlg,
  hoverlift = S.hoverlift,
  badgegreen = S.badgegreen,
  badgered = S.badgered,
  badgeamber = S.badgeamber,
  btnghost = S.btnghost,
  btndanger = S.btndanger,
  price = S.price,
  divider = S.divider,
  tbl = S.tbl,
  stockout = S.stockout,
  empty = S.empty
}.

# ---- element helpers --------------------------------------------------------

tagStyles "th" = [S.headcell].
tagStyles "td" = [S.cell].
tagStyles "tr" = [S.tablerow].
tagStyles _ = [].

cls styles = S.classes styles.
el tag styles kids = El tag (S.classes ([S.reset] + tagStyles tag + styles)) kids.
key identity node = KeyN identity node.

div ss ks = el "div" ss ks.
span ss ks = el "span" ss ks.
h1 ss ks = el "h1" ss ks.
h2 ss ks = el "h2" ss ks.
h3 ss ks = el "h3" ss ks.
p ss ks = el "p" ss ks.
ul ss ks = el "ul" ss ks.
li ss ks = el "li" ss ks.

text s = Txt s.
tf s = Txt "{s}".

# clickable wrapper: sends (ev, val) on click
onClick ev val n = EvN ev val n.

# named dynamic slot: server patches this subtree by name
dyn name n = DynN name n.

# multi-field form: sends fields space-joined under the event name
form ev fields btnLabel = FormN ev fields btnLabel.

# single input + button row
inputRow ev placeholder btnLabel = InpN ev placeholder btnLabel.

# ---- conveniences (typed versions of the old web.sol layer) -----------------
# extra styles are LISTS and append with `+` — List.+ via the Arith row

row extra ks = div ([Style.flex, Style.flexrow, Style.gap2] + extra) ks.
col extra ks = div ([Style.flex, Style.flexcol, Style.gap2] + extra) ks.
card ks = div [Style.card, Style.flex, Style.flexcol, Style.gap2] ks.
badge s = span [Style.badge] [text s].
tabBtn ev val label = onClick ev val (span [Style.tab] [text label]).
btn ev val label = onClick ev val (span [Style.btn] [text label]).
title s = h1 [Style.text2xl, Style.fontbold] [text s].
subtitle s = h3 [Style.fontbold] [text s].
muted s = span [Style.textmuted] [text s].
