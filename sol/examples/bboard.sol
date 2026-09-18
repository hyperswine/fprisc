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
#
# Board model (identical to the Python):
#   30 rows x 2 sides x 5 cols; a strip = (row, side) is one node.
#   Components place vertically: pin_a at row R, pin_b at row R+2, same
#   side+col. GND net -> left neg rail, PWR nets -> left pos rail.
#   Strips are encoded as ints: key = row*2 + side (side: 0=left 1=right),
#   so "two rows down, same side" is just key+4.

# Ideally should use more |> and |>? and less explicit let-binding

base = use "../lib/base".

Opt = Type (Nope | Got x).

# ---------- generic helpers ----------
member : unsafe i93 -> List i93 -> Bool .
member _ [] = False.
member x (y :: _) | x == y = True.
member x (_ :: r) = member x r.

lookupA : unsafe k93 -> List (k93, j93) -> Opt .
lookupA _ [] = Nope.
lookupA k ((k2, v) :: _) | k2 == k = Got v.
lookupA k (_ :: r) = lookupA k r.

pad3 : unsafe String -> String .
pad3 s | Str.len s >= 3 = s.
pad3 s = pad3 " {s}".
pad4 : unsafe String -> String .
pad4 s | Str.len s >= 4 = s.
pad4 s = pad4 " {s}".

# ---------- tokenizing ----------
nonEmpty s = s != "".
words ln = Str.split 32 ln |> List.filter nonEmpty.
upC c | c >= 97, c <= 122 = c - 32.
upC c = c.

# ---------- parsing ----------
# component: {kind (char code), na, nb, nm, val}
parseLine : unsafe String -> List _ .
parseLine ln =
  ws = words ln;
  case ws == [] of True -> [] | False -> parseWs ws.

parseWs : unsafe List p101 -> List _ .
parseWs ws =
  nm = ws ! 1;
  k = upC (Str.at nm 1);
  case or (k == 42) (k == 46) of  # '*' comment, '.' directive
    True -> []
  | False -> parseKind k nm ws (List.len ws).

placeableKinds = [82, 67, 76, 68, 66].  # R C L D B

parseKind : unsafe Int -> t100 -> u100 -> Int -> List _ .
parseKind k nm ws n =
  case and (member k placeableKinds) (n >= 3) of
    True -> [{kind = k, na = ws ! 2, nb = ws ! 3, nm = nm,
              val = (case n >= 4 of True -> ws ! 4 | False -> "")}]
  | False -> (case and (member k [86, 73]) (n >= 3) of  # V I sources
      True -> [{kind = k, na = ws ! 2, nb = ws ! 3, nm = nm, val = "src"}]
    | False -> []).

parseNetlist : unsafe List String -> List _ .
parseNetlist ls | ls == [] = [].
parseNetlist ls = case ls of l :: r -> (parseLine l) + (parseNetlist r).

isSource c = or (c.kind == 86) (c.kind == 73).
notSource c = not (isSource c).

# ---------- net classification ----------
pwrNetsOf : unsafe List _ -> List b101 .
pwrNetsOf comps | comps == [] = [].
pwrNetsOf comps = case comps of c :: r -> pwStep2 c r.
pwStep2 : unsafe _ -> List _ -> List d101 .
pwStep2 c r = case and (isSource c) (c.nb == "0") of
  True -> c.na :: pwrNetsOf r
| False -> pwrNetsOf r.

netsOf : unsafe List _ -> List f101 .
netsOf comps | comps == [] = [].
netsOf comps = case comps of c :: r -> addNet c.na (addNet c.nb (netsOf r)).
addNet : unsafe m99 -> List m99 -> List m99 .
addNet n ns | member n ns = ns.
addNet n ns = n :: ns.

netTag : unsafe String -> List String -> String .
netTag net pwrs =
  case net == "0" of
    True -> " [GND]"
  | False -> (case member net pwrs of True -> " [PWR]" | False -> "").

# ---------- strip encoding ----------
sKey row side = row * 2 + side.
sRow k = k / 2.
sSide k = k - (k / 2) * 2.

holeLetter side col = Str.fromCode (97 + side * 5 + col - 1).
holeLabel k col = "{holeLetter (sSide k) col}{sRow k}".

# ---------- placement state ----------
# st = {holes  : [(stripKey, col)]        occupied holes
#       owners : [(stripKey, net)]        the one net a strip carries
#       netstr : [(net, [stripKey])]      strips per net, in placement order
#       places : [(nm, kind, sA, cA, cB)] placements (pinB strip = sA + 4)}
st0 = {holes = [], owners = [], netstr = [], places = []}.

usedCols : unsafe m94 -> List (m94, l94) -> List l94 .
usedCols _ [] = [].
usedCols k ((k2, c) :: r) | k2 == k = c :: usedCols k r.
usedCols k (_ :: r) = usedCols k r.

freeCol : unsafe t99 -> List (t99, Int) -> Int .
freeCol k holes = firstNot 1 (usedCols k holes).
firstNot : unsafe Int -> List Int -> Int .
firstNot c used | c > 5 = 0.
firstNot c used | member c used = firstNot (c + 1) used.
firstNot c used = c.

stripOK : unsafe u99 -> v99 -> List (u99, w99) -> Bool .
stripOK k net owners =
  case lookupA k owners of Nope -> True | Got n -> n == net.

netStrips : unsafe x99 -> List (x99, y99) -> List z99 .
netStrips net netstr = case lookupA net netstr of Nope -> [] | Got ss -> ss.

# ---------- candidate scoring ----------
# reward reusing a strip that already carries this net (direct connection);
# penalise a placement that IGNORES an existing strip of the net (jumper
# debt); small pull toward row 15.
scoreCand : unsafe v101 -> v101 -> Int -> _ -> Int .
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

allKeys : unsafe Int -> List Int .
allKeys r | r > 28 = [].
allKeys r = sKey r 0 :: sKey r 1 :: allKeys (r + 1).

bestCand : unsafe b102 -> b102 -> List Int -> Int -> Int -> _ -> Int .
bestCand na nb ks bk bs st | ks == [] = bk.
bestCand na nb ks bk bs st = case ks of
  k :: r -> bestStep na nb k r bk bs st.
bestStep : unsafe f102 -> f102 -> Int -> List Int -> Int -> Int -> _ -> Int .
bestStep na nb k r bk bs st =
  s = scoreCand na nb k st;
  case s > bs of
    True -> bestCand na nb r k s st
  | False -> bestCand na nb r bk bs st.

# ---------- committing a placement ----------
own : unsafe m100 -> n100 -> List (m100, n100) -> List (m100, n100) .
own k net owners = case lookupA k owners of
  Nope -> (k, net) :: owners
| Got n -> owners.

track : unsafe o100 -> p100 -> List (o100, List p100) -> List (o100, List p100) .
track net k netstr =
  ss = netStrips net netstr;
  case member k ss of
    True -> netstr
  | False -> (net, ss + [k]) :: dropKey net netstr.

dropKey : unsafe l95 -> List (l95, k95) -> List (l95, k95) .
dropKey _ [] = [].
dropKey k ((k2, _) :: r) | k2 == k = dropKey k r.
dropKey k (p :: r) = p :: dropKey k r.

placeOne : unsafe _ -> _ -> _ .
placeOne c st =
  sA = bestCand c.na c.nb (allKeys 1) 0 (0 - 999999) st;
  case sA == 0 of
    True -> placeFail c st
  | False -> commit c sA st.

placeFail c st =
  u = print "!! no legal position for {c.nm}";
  st.

commit : unsafe _ -> Int -> _ -> _ .
commit c sA st =
  sB = sA + 4;
  cA = freeCol sA st.holes;
  cB = freeCol sB st.holes;
  {st | holes = (sA, cA) :: (sB, cB) :: st.holes,
        owners = own sB c.nb (own sA c.na st.owners),
        netstr = track c.nb sB (track c.na sA st.netstr),
      places = (st.places + [(c.nm, c.kind, sA, cA, cB)])}.

placeAll : unsafe List _ -> _ -> _ .
placeAll cs st | cs == [] = st.
placeAll cs st = case cs of c :: r -> placeAll r (placeOne c st).

# ---------- wiring ----------
# ws = {holes, labels : [((strip,col), lbl)], rails : [(railName, (row, lbl))],
#       wires : [(net, from, to, kind)], k : counter}
mkWs holes = {holes = holes, labels = [], rails = [], wires = [], k = 0}.

allocLbl : unsafe Int -> j103 -> _ -> (String, _) .
allocLbl k lbl ws =
  c = freeCol k ws.holes;
  case c == 0 of
    True -> ("(full)", ws)
  | False -> (holeLabel k c,
      {ws | holes = (k, c) :: ws.holes, labels = ((k, c), lbl) :: ws.labels}).

# jumpers between consecutive strips of one net
jumpNet : unsafe l103 -> List Int -> _ -> _ .
jumpNet net ss ws | ss == [] = ws.
jumpNet net ss ws = case ss of
  s1 :: rest -> (case rest == [] of True -> ws | False -> jumpStep net s1 rest ws).
jumpStep : unsafe n103 -> Int -> List Int -> _ -> _ .
jumpStep net s1 rest ws = case rest of
  s2 :: more -> jumpDo net s1 s2 more ws.
jumpDo : unsafe p103 -> Int -> Int -> List Int -> _ -> _ .
jumpDo net s1 s2 more ws =
  wsA = {ws | k = ws.k + 1};
  (la, ws2) = allocLbl s1 "W{wsA.k}a" wsA;
  (lb, ws3) = allocLbl s2 "W{wsA.k}b" ws2;
  jumpNet net (s2 :: more) {ws3 | wires = (ws3.wires + [(net, la, lb, "JUMPER")])}.

# rail wire: from the net's first strip to the given rail
railWire : unsafe f103 -> g103 -> List Int -> _ -> _ .
railWire net rail ss ws =
  case ss of s1 :: rest -> railDo net rail s1 ws.
railDo : unsafe u103 -> v103 -> Int -> _ -> _ .
railDo net rail s1 ws =
  wsA = {ws | k = ws.k + 1};
  (la, ws2) = allocLbl s1 "W{wsA.k}a" wsA;
  {ws2 | rails = (rail, (sRow s1, "W{wsA.k}b")) :: ws2.rails,
      wires = (ws2.wires + [(net, la, rail, "RAIL")])}.

wireNets : unsafe List String -> List String -> List (String, x103) -> _ -> _ .
wireNets nets pwrs netstr ws | nets == [] = ws.
wireNets nets pwrs netstr ws = case nets of
  n :: r -> wireNets r pwrs netstr (wireOne n pwrs netstr ws).

wireOne : unsafe String -> List String -> List (String, z103) -> _ -> _ .
wireOne n pwrs netstr ws =
  ss = netStrips n netstr;
  ws2 = jumpNet n ss ws;
  case n == "0" of
    True -> railWire n "L-" ss ws2
  | False -> (case member n pwrs of
      True -> railWire n "L+" ss ws2
    | False -> ws2).

# ---------- self-check ----------
# every strip carries exactly one net; every multi-strip net has strips-1
# jumpers (fully connected by construction) — verified, not assumed.
checkOwners : unsafe List (a97, b97) -> List a97 -> String .
checkOwners owners seen | owners == [] = "no shorts: OK".
checkOwners owners seen = case owners of o :: r -> ownStep o r seen.
ownStep : unsafe (c97, d97) -> List (c97, d97) -> List c97 -> String .
ownStep o r seen =
  (k, n) = o;
  case member k seen of
    True -> "SHORT at strip {k}!"
  | False -> checkOwners r (k :: seen).

countWires : unsafe g97 -> List (g97, e97, f97, String) -> Int .
countWires net wires | wires == [] = 0.
countWires net wires = case wires of w :: r -> cwStep net w r.
cwStep : unsafe j97 -> (j97, h97, i97, String) -> List (j97, h97, i97, String) -> Int .
cwStep net w r =
  (n2, f, t, kd) = w;
  countWires net r + base.boolInt (and (n2 == net) (kd == "JUMPER")).

checkNets : unsafe List n97 -> List (n97, k97) -> List (n97, l97, m97, String) -> String .
checkNets nets netstr wires | nets == [] = "connectivity: OK".
checkNets nets netstr wires = case nets of n :: r -> cnStep n r netstr wires.
cnStep : unsafe r97 -> List r97 -> List (r97, o97) -> List (r97, p97, q97, String) -> String .
cnStep n r netstr wires =
  ss = netStrips n netstr;
  need = List.len ss - 1;
  got = countWires n wires;
  case and (need > 0) (not (got == need)) of
    True -> "net {n}: {got}/{need} jumpers MISSING"
  | False -> checkNets r netstr wires.

# ---------- rendering ----------
pinName kind idx =
  case kind == 68 of
    True -> (case idx == 0 of True -> "A" | False -> "K")   # diode A/K
  | False -> (case idx == 0 of True -> "a" | False -> "b").

cellMapOf : unsafe List (s97, Int, Int, t97, t97) -> List ((Int, t97), String) .
cellMapOf places | places == [] = [].
cellMapOf places = case places of p :: r -> cmStep p r.
cmStep : unsafe (u97, Int, Int, v97, v97) -> List (u97, Int, Int, v97, v97) -> List ((Int, v97), String) .
cmStep p r =
  (nm, kd, sA, cA, cB) = p;
  ((sA, cA), "{nm}{pinName kd 0}") :: ((sA + 4, cB), "{nm}{pinName kd 1}") :: cellMapOf r.

cellAt : unsafe List ((c103, d103), e103) -> c103 -> d103 -> String .
cellAt cm k c = case lookupA (k, c) cm of Nope -> "   ." | Got l -> pad4 l.

cells : unsafe List ((z97, Int), a98) -> z97 -> Int -> String .
cells cm k c | c > 5 = "".
cells cm k c = "{cellAt cm k c}{cells cm k (c + 1)}".

railCell : unsafe List (h103, j103) -> h103 -> i103 -> String .
railCell rails name row =
  case lookupA name rails of
    Nope -> "  |"
  | Got rl -> railHit rl row.
railHit : unsafe (k103, String) -> k103 -> String .
railHit rl row = (r2, lbl) = rl; case r2 == row of True -> pad3 lbl | False -> "  |".

renderRow : unsafe List ((Int, Int), m103) -> List (String, l103) -> Int -> String .
renderRow cm rails r =
  "{pad3 (str r)} {railCell rails "L-" r} {railCell rails "L+" r}  {cells cm (sKey r 0) 1}  ||  {cells cm (sKey r 1) 1}".

renderRows : unsafe List ((Int, Int), i98) -> List (String, h98) -> Int -> Int .
renderRows cm rails r | r > 30 = 0.
renderRows cm rails r =
  u = print (renderRow cm rails r);
  renderRows cm rails (r + 1).

header = "     L-  L+     a   b   c   d   e  ||     f   g   h   i   j".

# ---------- summaries ----------
printComps : unsafe List (j98, k98, Int, Int, Int) -> Int .
printComps ps | ps == [] = 0.
printComps ps = case ps of p :: r -> pcStep p r.
pcStep : unsafe (l98, m98, Int, Int, Int) -> List (l98, m98, Int, Int, Int) -> Int .
pcStep p r =
  (nm, kd, sA, cA, cB) = p;
  u = print "  {nm}  {holeLabel sA cA} -> {holeLabel (sA + 4) cB}";
  printComps r.

stripsStr : unsafe List Int -> String .
stripsStr ss | ss == [] = "".
stripsStr ss = case ss of
  s :: r -> (case r == [] of
    True -> "row {sRow s} {sideName s}"
  | False -> "row {sRow s} {sideName s}, {stripsStr r}").
sideName k | sSide k == 0 = "L".
sideName _ = "R".

printNets : unsafe List String -> List String -> List (String, n98) -> Int .
printNets nets pwrs netstr | nets == [] = 0.
printNets nets pwrs netstr = case nets of n :: r -> pnStep n r pwrs netstr.
pnStep : unsafe String -> List String -> List String -> List (String, o98) -> Int .
pnStep n r pwrs netstr =
  u = print "  {n}{netTag n pwrs}: {stripsStr (netStrips n netstr)}";
  printNets r pwrs netstr.

printWires : unsafe List (p98, q98, r98, s98) -> Int .
printWires wl | wl == [] = 0.
printWires wl = case wl of w :: r -> pwStep w r.
pwStep : unsafe (t98, u98, v98, w98) -> List (t98, u98, v98, w98) -> Int .
pwStep w r =
  (n, f, t, kd) = w;
  u = print "  [{kd}] net {n}: {f} -> {t}";
  printWires r.

# ---------- driver ----------
runBoard : unsafe d104 -> List String -> Int .
runBoard title ls =
  u0 = print "";
  u1 = print "=== {title} ===";
  comps = parseNetlist ls;
  placeable = List.filter notSource comps;
  pwrs = pwrNetsOf comps;
  nets = List.rev (netsOf placeable);
  st = placeAll placeable st0;
  ws = wireNets nets pwrs st.netstr (mkWs st.holes);
  u2 = print "-- components --";
  u3 = printComps st.places;
  u4 = print "-- nets --";
  u5 = printNets nets pwrs st.netstr;
  u6 = print "-- wires --";
  u7 = printWires ws.wires;
  u8 = print "-- checks --";
  u9 = print "  {checkOwners st.owners []}";
  ua = print "  {checkNets nets st.netstr ws.wires}";
  ub = print "";
  uc = print header;
  cm = (cellMapOf st.places) + ws.labels;
  renderRows cm ws.rails 1.

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
