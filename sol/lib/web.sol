# web.sol — LEGACY: the untyped record view vocabulary. Superseded by
# lib/ui.sol (typed Html ADT + local Appearance values). Its record vocabulary
# remains available, but node/row/col now take typed style lists, not class strings.
# New code should use ui.sol; no old global-class registry is served.

S = use "webstyles".
node tag styles kids = {classes = S.classes ([S.reset] + styles), kids = kids, tag = tag}.
text s = {text = s}.
dynS name n = {dyn = name, node = n}.
clickable ev val n = {ev = ev, node = n, val = val}.
inputBox name ph btn = {btn = btn, inp = name, ph = ph}.
formBox ev fields btn = {btn = btn, fields = fields, form = ev}.

# conveniences
row styles kids = node "div" ([S.flex, S.flexrow, S.gap2] + styles) kids.
col styles kids = node "div" ([S.flex, S.flexcol, S.gap2] + styles) kids.
card kids = node "div" [S.card, S.flex, S.flexcol, S.gap2] kids.
badge s = node "span" [S.badge] [text s].
tabBtn ev val label = clickable ev val (node "span" [S.tab] [text label]).
btn ev val label = clickable ev val (node "span" [S.btn] [text label]).
title s = node "h1" [S.text2xl, S.fontbold] [text s].
subtitle s = node "h3" [S.fontbold] [text s].
muted s = node "span" [S.textmuted] [text s].
