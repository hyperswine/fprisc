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
#     reported under "-- skipped --" rather than dropped.
#
# Board model (identical to the Python):
#   30 rows x 2 sides x 5 cols; a strip = (row, side) is one node.
#   Components place vertically: pin_a at row R, pin_b at row R+2, same
#   side+col. GND net -> left neg rail, PWR nets -> left pos rail.
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

# ---------- net classification ----------
# a source's positive node, when its negative node is ground
pwrNetsOf comps = comps |> List.filter (fn c -> and (isSource c) (c.nb == "0")) |> List.map (fn c -> c.na).

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

stripOK k net owners = case lookupA k owners of Nope -> True | Got n -> n == net.

netStrips net netstr = case lookupA net netstr of Nope -> [] | Got ss -> ss.

# ---------- candidate scoring ----------
# reward reusing a strip that already carries this net (direct connection);
# penalise a placement that IGNORES an existing strip of the net (jumper
# debt); small pull toward row 15.
scoreCand na nb sA st =
  sB = sA + 4;
  ownA = lookupA sA st.owners;
  ownB = lookupA sB st.owners;
  okA = stripOK sA na st.owners;
  okB = stripOK sB nb st.owners;
  fA = freeCol sA st.holes;
  fB = freeCol sB st.holes;
  case and (and okA okB) (and (fA > 0) (fB > 0)) of
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
  cA = freeCol sA st.holes;
  cB = freeCol sB st.holes;
  {st | holes = (sA, cA) :: (sB, cB) :: st.holes,
        owners = own sB c.nb (own sA c.na st.owners),
        netstr = track c.nb sB (track c.na sA st.netstr),
        places = st.places + [(c.nm, c.kind, sA, cA, cB)]}.

# ---------- wiring ----------
# labels : wire ends written into holes, ((strip, col), label)
# rails  : wire ends on a rail, (railName, (row, label))
# wires  : (net, from, to, kind);  k : wire counter
Wiring = {holes : List (Int, Int), labels : List ((Int, Int), String), rails : List (String, (Int, String)), wires : List (String, String, String, String), k : Int}.
mkWs holes = {holes = holes, labels = [], rails = [], wires = [], k = 0}.

allocLbl k lbl ws =
  c = freeCol k ws.holes;
  case c == 0 of
    True -> ("(full)", ws)
  | False -> (holeLabel k c,
      {ws | holes = (k, c) :: ws.holes, labels = ((k, c), lbl) :: ws.labels}).

# jumpers between consecutive strips of one net
jumpNet net ss ws = List.zip ss (List.drop 1 ss) |> List.fold (jumper net) ws.
jumper net ws (s1, s2) =
  wsA = {ws | k = ws.k + 1};
  (la, ws2) = allocLbl s1 "W{wsA.k}a" wsA;
  (lb, ws3) = allocLbl s2 "W{wsA.k}b" ws2;
  {ws3 | wires = ws3.wires + [(net, la, lb, "JUMPER")]}.

# rail wire: from the net's first strip to the given rail
railWire net rail [] ws = ws.
railWire net rail (s1 :: _) ws =
  wsA = {ws | k = ws.k + 1};
  (la, ws2) = allocLbl s1 "W{wsA.k}a" wsA;
  {ws2 | rails = (rail, (sRow s1, "W{wsA.k}b")) :: ws2.rails,
         wires = ws2.wires + [(net, la, rail, "RAIL")]}.

wireNet pwrs netstr ws n =
  ss = netStrips n netstr;
  jumpNet n ss ws |> railFor n pwrs ss.

railFor n pwrs ss ws | n == "0" = railWire n "L-" ss ws.
railFor n pwrs ss ws | List.has n pwrs = railWire n "L+" ss ws.
railFor n pwrs ss ws = ws.

# ---------- self-check ----------
# every strip carries exactly one net; every multi-strip net has strips-1
# jumpers (fully connected by construction) — verified, not assumed.
checkOwners owners =
  (seen, short) = List.fold noteStrip ([], Nope) owners;
  case short of Nope -> "no shorts: OK" | Got k -> "SHORT at strip {k}!".
noteStrip (seen, short) (k, n) | short != Nope = (seen, short).
noteStrip (seen, short) (k, n) | List.has k seen = (seen, Got k).
noteStrip (seen, short) (k, n) = (k :: seen, short).

isJumperOf net (n, f, t, kd) = and (n == net) (kd == "JUMPER").

jumperGap netstr wires n =
  need = List.len (netStrips n netstr) - 1;
  got = wires |> List.filter (isJumperOf n) |> List.len;
  case and (need > 0) (got != need) of
    True -> ["net {n}: {got}/{need} jumpers MISSING"]
  | False -> [].

checkNets nets netstr wires = nets |> List.map (jumperGap netstr wires) |> List.concat |> base.firstOr "connectivity: OK".

# ---------- rendering ----------
pinName 68 0 = "A".  # diode anode / cathode
pinName 68 _ = "K".
pinName _ 0 = "a".
pinName _ _ = "b".

cellMapOf places = places |> List.map pinCells |> List.concat.
pinCells (nm, kd, sA, cA, cB) = [((sA, cA), "{nm}{pinName kd 0}"), ((sA + 4, cB), "{nm}{pinName kd 1}")].

cellAt cm k c = case lookupA (k, c) cm of Nope -> "   ." | Got l -> padL 4 l.
cells cm k = List.range 1 5 |> List.map (cellAt cm k) |> Str.join "".

railCell rails name row = case lookupA name rails of Nope -> "  |" | Got rl -> railHit rl row.
railHit (r2, lbl) row | r2 == row = padL 3 lbl.
railHit rl row = "  |".

renderRow cm rails r =
  "{padL 3 (str r)} {railCell rails "L-" r} {railCell rails "L+" r}  {cells cm (sKey r 0)}  ||  {cells cm (sKey r 1)}".

header = "     L-  L+     a   b   c   d   e  ||     f   g   h   i   j".

boardLines cm rails = [header] + (List.range 1 30 |> List.map (renderRow cm rails)).

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

# ---------- driver ----------
runBoard title ls =
  parsed = parseNetlist ls;
  comps = oks parsed;
  u = base.say (["", "=== {title} ==="] + skippedLines (errs parsed));
  placeable = List.filter (fn c -> not (isSource c)) comps;
  pwrs = pwrNetsOf comps;
  nets = netsOf placeable;
  st = List.fold placeOne st0 placeable;
  ws = List.fold (wireNet pwrs st.netstr) (mkWs st.holes) nets;
  base.say (["-- components --"] + List.map compLine st.places
    + ["-- nets --"] + List.map (netLine pwrs st.netstr) nets
    + ["-- wires --"] + List.map wireLine ws.wires
    + ["-- checks --", "  {checkOwners st.owners}", "  {checkNets nets st.netstr ws.wires}", ""]
    + boardLines (cellMapOf st.places + ws.labels) ws.rails).

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
