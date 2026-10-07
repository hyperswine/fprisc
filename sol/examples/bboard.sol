# bboard.sol — SPICE netlist -> 400-tie breadboard placement, in pure Sol.
#
# Port of the Python+clingo tool with declared simplifications:
#   * clingo's ASP search -> a transparent greedy scorer over the SAME
#     constraints (no shared holes, one net per strip, reward strip reuse,
#     prefer centre rows). At 56 candidate positions per component this is
#     near-optimal and fully deterministic.
#   * ASCII-only render (no ANSI/unicode), values kept verbatim,
#     2-pin components (R C L D B; V/I are sources, not placed).
#   * netlists are lists of line strings (no argv in Sol yet).
#   * a line the tool cannot place (too few nodes, an unsupported kind) is
#     reported under "-- skipped --" rather than dropped, and what it
#     places but does not wire (a second supply, a supply not referenced
#     to node 0, a current source) is reported under "-- notes --".
#
# Board model (identical to the Python):
#   30 rows x 2 sides x 5 cols; a strip = (row, side) is one node.
#   Components place vertically: pin_a at row R, pin_b at row R+2, same
#   side AND the same column (one free in both strips). GND net -> left
#   neg rail; THE supply -> left pos rail: the first voltage source whose
#   negative node is 0.  One positive rail is modelled, so one supply.
#   A strip takes at most 3 component pins: two of its five holes stay
#   free for the wires it may need (two jumper ends, or one and a rail
#   wire), so wiring can never find a strip full.
#
# Not modelled: every part is two pins, two rows apart, with no body.  A
# part with three or more pins, a DIP across the centre gap, a different
# pin pitch, or a body that covers the holes beside it is outside this
# tool; such a line is reported under "-- skipped --".
#
# NEXT VERSION FEATURE: footprints.  Intended, not written:
#   * a part carries a Footprint = {pins, body}: pins is a list of
#     (dRow, side, dCol) offsets from an anchor hole, one per netlist
#     node in order; body is the list of offsets of the holes the part
#     covers without connecting to (they take no other pin or wire end).
#   * the parts meant to be covered:
#       - DIP ICs (X lines, 8/14/16/... pins): two columns of pins, one
#         in column e and one in column f, straddling the centre gap,
#         one row per pin pair; the only legal anchor is the gap.
#       - three-pin parts (Q transistors, regulators, pots): three
#         consecutive rows in one column, or a triangle for a trimmer.
#       - two-pin parts of another pitch: a long resistor or axial diode
#         (4+ rows), a radial capacitor (1 row, so adjacent strips), a
#         push-button (four legs, two strips each side of the gap).
#       - oversized bodies: an electrolytic or a relay whose can covers
#         the neighbouring columns and rows, a module on a header strip.
#   * what changes here: parseKind gives each kind a footprint (with a
#     value or model field choosing among several); scoreCand asks that
#     EVERY pin's strip is legal (net, pinCap, a free hole at its
#     offset) and that every body hole is free; place records all pins
#     and marks the body holes used; pinNets and the checks read pins
#     from the footprint, and gain "no body over a used hole".
#   * a part that fits nowhere stays an honest "NOT placed" line.
#   * the board drawing marks a body hole (e.g. "#") so the cover shows.
#   Strips are encoded as ints: key = row*2 + side (side: 0=left 1=right),
#   so "two rows down, same side" is just key+4.
#
# Style (docs/2026-10-03-STYLE-DIRECTION.md): clauses select by shape, guards
# say when they apply, and every traversal is a List fold, map, filter or
# find. There is no explicit recursion, so nothing here is `unsafe` and every
# function is total.

base = use "../lib/base".

Opt = Type (Nope | Got x).

# a parsed netlist line; kind is the upper-cased first letter's char code
Comp = {kind : Int, na : String, nb : String, nm : String, val : String}.

# ---------- generic helpers ----------
lookupA k ps = ps |> List.filter (keyIs k) |> List.map valueOf |> firstGot.
keyIs k (k2, v) = k2 == k.
valueOf (k, v) = v.
firstGot [] = Nope.
firstGot (v :: _) = Got v.

padL : (w : Int | w >= 0) -> String -> String .
padL w s = "{Str.repeat (w - Str.len s) " "}{s}".

# ---------- parsing ----------
placeableKinds = [82, 67, 76, 68, 66].  # R C L D B
sourceKinds = [86, 73].                 # V I

upC c | c >= 97, c <= 122 = c - 32.
upC c = c.

# Each line gives nothing (blank, '*' comment, '.' directive), a component
# (Ok), or the reason it cannot be used (Err). The netlist is input: a line
# the tool cannot place is reported, not silently dropped.
parseNetlist : List String -> List (Result Comp String) .
parseNetlist ls = ls |> List.map parseLine |> List.concat.

parseLine : String -> List (Result Comp String) .
parseLine ln = parseWords (Str.words ln).

parseWords : List String -> List (Result Comp String) .
parseWords [] = [].
parseWords ws = parseKind (upC (Str.at (ws ! 0) 0)) ws.

# NAME NODE_A NODE_B [VALUE]
parseKind : Int -> List String -> List (Result Comp String) .
parseKind k ws | k == 42 or k == 46 = [].
parseKind k ws | List.len ws < 3 = [Err "{ws ! 0}: needs two nodes"].
parseKind k ws | List.has k placeableKinds = [Ok (comp k ws (valueField ws))].
parseKind k ws | List.has k sourceKinds = [Ok (comp k ws "src")].
parseKind k ws = [Err "{ws ! 0}: unsupported (2-pin R C L D B, or a V/I source)"].

oks rs = rs |> List.map okPart |> List.concat.
okPart (Ok c) = [c].
okPart (Err e) = [].
errs rs = rs |> List.map errPart |> List.concat.
errPart (Ok c) = [].
errPart (Err e) = [e].

valueField ws | List.len ws >= 4 = ws ! 3.
valueField ws = "".

comp : Int -> List String -> String -> Comp .
comp k ws val = {kind = k, na = ws ! 1, nb = ws ! 2, nm = ws ! 0, val = val}.

isSource c = List.has c.kind sourceKinds.
isV c = c.kind == 86.

# ---------- net classification ----------
# the supply: the positive node of the first VOLTAGE source whose negative
# node is ground.  A list of none or one: the board has one positive rail,
# and two supplies on it would be a short.  A current source is not a rail.
pwrNetsOf comps = comps |> List.filter (fn c -> and (isV c) (c.nb == "0")) |> List.map (fn c -> c.na) |> firstOnly.
firstOnly [] = [].
firstOnly (x :: _) = [x].

# what is read but not wired, said rather than assumed
notesOf pwrs comps = comps |> List.map (noteOf pwrs) |> List.concat.
noteOf pwrs c | and (isV c) (and (c.nb == "0") (List.has c.na pwrs)) = [].
noteOf pwrs c | and (isV c) (c.nb == "0") = ["{c.nm}: a second supply ({c.na}); one positive rail is modelled, so it is not wired"].
noteOf pwrs c | isV c = ["{c.nm}: a supply not referenced to node 0 is not wired"].
noteOf pwrs c | isSource c = ["{c.nm}: a current source is not placed, and its nodes get no rail"].
noteOf pwrs c | c.na == c.nb = ["{c.nm}: both pins are on net {c.na}"].
noteOf pwrs c = [].

# every net once, walking the components from the last back, pin b before pin a
netsOf comps = List.rev comps |> List.fold (fn ns c -> ns |> addNet c.nb |> addNet c.na) [].
addNet n ns | List.has n ns = ns.
addNet n ns = ns + [n].

netTag net pwrs | net == "0" = " [GND]".
netTag net pwrs | List.has net pwrs = " [PWR]".
netTag net pwrs = "".

# ---------- strip encoding ----------
sKey : (row : Int | row >= 1 and row <= 30) -> (side : Int | side >= 0 and side <= 1) -> Int .
sKey row side = row * 2 + side.
sRow k = k / 2.
sSide k = k - (k / 2) * 2.

holeLetter : (side : Int | side >= 0 and side <= 1) -> (col : Int | col >= 1 and col <= 5) -> String .
holeLetter side col = Str.fromCode (97 + side * 5 + col - 1).
holeLabel k col = "{holeLetter (sSide k) col}{sRow k}".

# ---------- placement state ----------
# holes  : occupied (stripKey, col)
# owners : the one net each strip carries, (stripKey, net)
# netstr : strips per net in placement order, (net, [stripKey])
# places : placements (nm, kind, sA, cA, cB); pin b's strip is sA + 4
Board = {holes : List (Int, Int), owners : List (Int, String), netstr : List (String, List Int), places : List (String, Int, Int, Int, Int)}.
st0 = {holes = [], owners = [], netstr = [], places = []}.

usedCols k holes = holes |> List.filter (keyIs k) |> List.map valueOf.

# the first free column 1..5 of a strip, or 0 when it is full
freeCol k holes = used = usedCols k holes; List.range 1 5 |> List.filter (fn c -> not (List.has c used)) |> base.firstOr 0.

# component pins a strip may take: two holes stay for its wires
pinCap = 3.
pinRoom k holes = List.len (usedCols k holes) < pinCap.

# the first column 1..5 free in BOTH strips (a part sits in one column), or 0
sharedCol sA sB holes = uA = usedCols sA holes; uB = usedCols sB holes; List.range 1 5 |> List.filter (fn c -> and (not (List.has c uA)) (not (List.has c uB))) |> base.firstOr 0.

stripOK k net owners = case lookupA k owners of Nope -> True | Got n -> n == net.

netStrips net netstr = case lookupA net netstr of Nope -> [] | Got ss -> ss.

# ---------- candidate scoring ----------
# reward reusing a strip that already carries this net (direct connection);
# penalise a placement that IGNORES an existing strip of the net (jumper
# debt); small pull toward the middle (pin a at row 14, so the part sits
# across row 15).  Legal: each strip carries the pin's net or none, has
# pin room, and one column is free in both.
scoreCand na nb sA st =
  sB = sA + 4;
  ownA = lookupA sA st.owners;
  ownB = lookupA sB st.owners;
  okA = stripOK sA na st.owners;
  okB = stripOK sB nb st.owners;
  room = and (pinRoom sA st.holes) (pinRoom sB st.holes);
  col = sharedCol sA sB st.holes;
  case and (and okA okB) (and room (col > 0)) of
    False -> 0 - 1000000
  | True ->
      100 * base.boolInt (ownA == Got na)
      + 100 * base.boolInt (ownB == Got nb)
      - 40 * base.boolInt (and (netStrips na st.netstr != []) (not (ownA == Got na)))
      - 40 * base.boolInt (and (netStrips nb st.netstr != []) (not (ownB == Got nb)))
      - Numeric.abs (sRow sA - 14).

# pin a's candidate strips: rows 1..28 (pin b lands two rows down), both sides
allKeys = List.range 1 28 |> List.map (fn r -> [sKey r 0, sKey r 1]) |> List.concat.

# the first strictly best candidate, or 0 when none is legal
bestStrip na nb st = (k, s) = List.fold (better na nb st) (0, 0 - 999999) allKeys; k.
better na nb st best k =
  (bk, bs) = best;
  s = scoreCand na nb k st;
  case s > bs of True -> (k, s) | False -> best.

# ---------- committing a placement ----------
own k net owners | lookupA k owners == Nope = (k, net) :: owners.
own k net owners = owners.

track net k netstr | List.has k (netStrips net netstr) = netstr.
track net k netstr = (net, netStrips net netstr + [k]) :: List.filter (fn p -> not (keyIs net p)) netstr.

placeOne : Board -> Comp -> Board .
placeOne st c = place c (bestStrip c.na c.nb st) st.

place c sA st | sA == 0 = u = print "!! no legal position for {c.nm}"; st.
place c sA st =
  sB = sA + 4;
  cA = sharedCol sA sB st.holes;
  cB = cA;
  {st | holes = (sA, cA) :: (sB, cB) :: st.holes,
        owners = own sB c.nb (own sA c.na st.owners),
        netstr = track c.nb sB (track c.na sA st.netstr),
        places = st.places + [(c.nm, c.kind, sA, cA, cB)]}.

# ---------- wiring ----------
# labels : wire ends written into holes, ((strip, col), label)
# rails  : wire ends on a rail, ((railName, row), label)
# wires  : (net, from, to, kind);  k : wire counter
# links  : the jumpers that really landed in two holes, (net, strip, strip)
# railed : the nets whose rail wire really landed in a hole
Wiring = {holes : List (Int, Int), labels : List ((Int, Int), String), rails : List ((String, Int), String), wires : List (String, String, String, String), k : Int, links : List (String, Int, Int), railed : List String}.
mkWs holes = {holes = holes, labels = [], rails = [], wires = [], k = 0, links = [], railed = []}.

noHole = "(full)".

allocLbl k lbl ws =
  c = freeCol k ws.holes;
  case c == 0 of
    True -> (noHole, ws)
  | False -> (holeLabel k c, {ws | holes = (k, c) :: ws.holes, labels = ((k, c), lbl) :: ws.labels}).

# jumpers between consecutive strips of one net
jumpNet net ss ws = List.zip ss (List.drop 1 ss) |> List.fold (jumper net) ws.
jumper net ws (s1, s2) =
  wsA = {ws | k = ws.k + 1};
  (la, ws2) = allocLbl s1 "W{wsA.k}a" wsA;
  (lb, ws3) = allocLbl s2 "W{wsA.k}b" ws2;
  {ws3 | wires = ws3.wires + [(net, la, lb, "JUMPER")], links = linked net s1 s2 la lb ws3.links}.
linked net s1 s2 la lb links | la == noHole or lb == noHole = links.
linked net s1 s2 la lb links = (net, s1, s2) :: links.

# rail wire: from the net's first strip to the given rail
railWire net rail [] ws = ws.
railWire net rail (s1 :: _) ws =
  wsA = {ws | k = ws.k + 1};
  (la, ws2) = allocLbl s1 "W{wsA.k}a" wsA;
  {ws2 | rails = ((rail, sRow s1), "W{wsA.k}b") :: ws2.rails,
         wires = ws2.wires + [(net, la, rail, "RAIL")],
         railed = railedIf net la ws2.railed}.
railedIf net la railed | la == noHole = railed.
railedIf net la railed = net :: railed.

wireNet pwrs netstr ws n =
  ss = netStrips n netstr;
  jumpNet n ss ws |> railFor n pwrs ss.

railFor n pwrs ss ws | n == "0" = railWire n "L-" ss ws.
railFor n pwrs ss ws | List.has n pwrs = railWire n "L+" ss ws.
railFor n pwrs ss ws = ws.

# ---------- self-check ----------
# Read back from what was BUILT -- the placements, the netlist, the holes
# and the wires that landed in holes -- never from the bookkeeping the
# placer steered by, so each line can fail:
#   every part is placed; no strip carries two nets; no hole is used twice;
#   the strips of a net are joined by its jumpers; ground and the supply
#   reach their rails.
placeName (nm, kd, sA, cA, cB) = nm.
keyOf (k, v) = k.

checkPlaced comps places =
  names = List.map placeName places;
  missing = comps |> List.filter (fn c -> not (List.has c.nm names)) |> List.map (fn c -> c.nm);
  case missing of [] -> "all parts placed: OK" | _ -> "{List.len missing} part(s) NOT placed: {Str.join ", " missing}".

# every pin as (strip, net)
pinNets comps places = byName = List.map (fn c -> (c.nm, c)) comps; places |> List.map (pinPair byName) |> List.concat.
pinPair byName (nm, kd, sA, cA, cB) = case lookupA nm byName of Nope -> [] | Got c -> [(sA, c.na), (sA + 4, c.nb)].

checkShorts pins =
  (seen, short) = List.fold noteShort ([], Nope) pins;
  case short of Nope -> "no shorts: OK" | Got k -> "SHORT at strip {stripName k}!".
noteShort (seen, short) (k, n) | short != Nope = (seen, short).
noteShort (seen, short) (k, n) = case lookupA k seen of
    Nope -> ((k, n) :: seen, short)
  | Got m -> (case m == n of True -> (seen, short) | False -> (seen, Got k)).

checkHoles cm =
  (seen, dup) = List.fold noteHole ([], Nope) (List.map keyOf cm);
  case dup of Nope -> "one end per hole: OK" | Got h -> "a hole is used TWICE: {holeAt h}".
holeAt (k, c) = holeLabel k c.
noteHole (seen, dup) h | dup != Nope = (seen, dup).
noteHole (seen, dup) h | List.has h seen = (seen, Got h).
noteHole (seen, dup) h = (h :: seen, dup).

# the strips a net's pins sit on, and those reached from the first of them
# over the net's landed jumpers: one growth pass per further strip is enough
stripsOfNet pins n = pins |> List.filter (fn p -> valueOf p == n) |> List.map keyOf |> List.fold (fn acc k -> addNet k acc) [].
linkNet (n, a, b) = n.
linkEnds (n, a, b) = (a, b).
reach ends [] = [].
reach ends (s :: rest) = List.fold (fn seen step -> List.fold growLink seen ends) [s] rest.
growLink seen (a, b) | and (List.has a seen) (not (List.has b seen)) = seen + [b].
growLink seen (a, b) | and (List.has b seen) (not (List.has a seen)) = seen + [a].
growLink seen (a, b) = seen.

netGap pins links n =
  ss = stripsOfNet pins n;
  ends = links |> List.filter (fn l -> linkNet l == n) |> List.map linkEnds;
  apart = List.len ss - List.len (reach ends ss);
  case apart > 0 of
    True -> ["net {n}: {apart} strip(s) NOT connected"]
  | False -> [].

checkNets nets pins links = nets |> List.map (netGap pins links) |> List.concat |> base.firstOr "connectivity: OK".

railGap pwrs railed n | List.has n railed = [].
railGap pwrs railed n | n == "0" or List.has n pwrs = ["net {n}: NO rail wire"].
railGap pwrs railed n = [].
checkRails nets pwrs railed = nets |> List.map (railGap pwrs railed) |> List.concat |> base.firstOr "rails: OK".

# ---------- rendering ----------
pinName 68 0 = "A".  # diode anode / cathode
pinName 68 _ = "K".
pinName _ 0 = "a".
pinName _ _ = "b".

cellMapOf places = places |> List.map pinCells |> List.concat.
pinCells (nm, kd, sA, cA, cB) = [((sA, cA), "{nm}{pinName kd 0}"), ((sA + 4, cB), "{nm}{pinName kd 1}")].

# a cell is one wider than the longest label (4 for the usual "R1a")
cellW cm = 1 + List.fold (fn w p -> Numeric.max w (Str.len (valueOf p))) 3 cm.

cellAt w cm k c = case lookupA (k, c) cm of Nope -> padL w "." | Got l -> padL w l.
cells w cm k = List.range 1 5 |> List.map (cellAt w cm k) |> Str.join "".

railCell rails name row = case lookupA (name, row) rails of Nope -> "  |" | Got lbl -> padL 3 lbl.

renderRow w cm rails r = "{padL 3 (str r)} {railCell rails "L-" r} {railCell rails "L+" r}  {cells w cm (sKey r 0)}  ||  {cells w cm (sKey r 1)}".

letters w side = List.range 1 5 |> List.map (fn c -> padL w (holeLetter side c)) |> Str.join "".
header w = "     L-  L+  {letters w 0}  ||  {letters w 1}".

boardLines cm rails = w = cellW cm; [header w] + (List.range 1 30 |> List.map (renderRow w cm rails)).

# ---------- summaries ----------
compLine (nm, kd, sA, cA, cB) = "  {nm}  {holeLabel sA cA} -> {holeLabel (sA + 4) cB}".

sideName k | sSide k == 0 = "L".
sideName k = "R".
stripName s = "row {sRow s} {sideName s}".
stripsStr ss = ss |> List.map stripName |> Str.join ", ".
netLine pwrs netstr n = "  {n}{netTag n pwrs}: {stripsStr (netStrips n netstr)}".

wireLine (n, f, t, kd) = "  [{kd}] net {n}: {f} -> {t}".

skippedLines [] = [].
skippedLines es = "-- skipped --" :: List.map (fn e -> "  {e}") es.
noteLines [] = [].
noteLines ns = "-- notes --" :: List.map (fn n -> "  {n}") ns.

# ---------- driver ----------
runBoard title ls =
  parsed = parseNetlist ls;
  comps = oks parsed;
  placeable = List.filter (fn c -> not (isSource c)) comps;
  pwrs = pwrNetsOf comps;

  u = base.say (["", "=== {title} ==="] + skippedLines (errs parsed) + noteLines (notesOf pwrs comps));

  nets = netsOf placeable;
  st = List.fold placeOne st0 placeable;
  ws = List.fold (wireNet pwrs st.netstr) (mkWs st.holes) nets;
  pins = pinNets placeable st.places;
  cm = cellMapOf st.places + ws.labels;

  base.say
     (["-- components --"] + List.map compLine st.places
    + ["-- nets --"] + List.map (netLine pwrs st.netstr) nets
    + ["-- wires --"] + List.map wireLine ws.wires
    + ["-- checks --", "  {checkPlaced placeable st.places}", "  {checkShorts pins}", "  {checkHoles cm}", "  {checkNets nets pins ws.links}", "  {checkRails nets pwrs ws.railed}", ""]
    + boardLines cm ws.rails).

ex1 = [
  "* RC low-pass filter",
  "V1 vcc 0 DC 5",
  "R1 vcc mid 1k",
  "C1 mid 0 100n",
  ".end"
].

ex2 = [
  "* Voltage divider + filter",
  "V1 vcc 0 DC 9",
  "R1 vcc mid1 10k",
  "R2 mid1 0 10k",
  "C1 mid1 mid2 100n",
  "R3 mid2 0 4k7",
  ".end"
].

ex3 = [
  "* Debounced push-button LED",
  "V1 vcc 0 DC 5",
  "B1 vcc sw_out",
  "R1 sw_out 0 10k",
  "C1 sw_out 0 100n",
  "R2 sw_out led_a 330",
  "D1 led_a 0",
  ".end"
].

> runBoard "RC low-pass filter" ex1.
> runBoard "Voltage divider + filter" ex2.
> runBoard "Debounced push-button LED" ex3.
