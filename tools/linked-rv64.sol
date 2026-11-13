remainder a b = a - (a / b) * b.
# Exact linked RV64 IMC abstract interpretation. Unknown values never supply
# stack or control - flow authority. Branches include both successors.
T = use "target-image-core".
R = use "riscv-compressed".
J = use "../sol/lib/json".
M = use "../std/map".
O = use "../std/option".
Order = use "../std/order".
require ok why = if ok then Unit else error why.
mask = 2 ^ 64 - 1.
u64 n = (n  `remainder`  (2 ^ 64) + 2 ^ 64)  `remainder`  (2 ^ 64).
signed n bits = n  `remainder`  (2 ^ bits) - (if n  `remainder`  (2 ^ bits) >= 2 ^ (bits - 1) then 2 ^ bits else 0).
bits n start width = remainder (n / (2 ^ start)) (2 ^ width).
Value = Type (Unknown | Constant Int | Stack Int | Incoming Int).
plus a b = case (a,b) of
    (Incoming r,Constant 0) -> Incoming r | (Constant 0,Incoming r) -> Incoming r
  | (Constant x,Constant y) -> Constant (u64 (x+y))
  | (Stack x,Constant y) -> Stack (x + signed y 64)
  | (Constant x,Stack y) -> Stack (y + signed x 64)
  | _ -> Unknown.
preserved = [0,2,3,4,8,9] + List.range 18 27.
section bytes h index =
  pos = h.shoff + index * h.shsize;
  n off count = T.number bytes (pos+off) count;
  {kind=n 4 4,flags=n 8 8,address=n 16 8,offset=n 24 8,size=n 32 8,link=n 40 4,stride=n 56 8}.
image bytes =
  h = T.header bytes 64;
  sections = List.map (section bytes h) (T.indices h.shcount);
  _ = List.fold (fn u i -> require (not (List.has (T.number bytes (h.phoff+i*h.phsize) 4) [2,3])) "dynamic/interpreted image") Unit (T.indices h.phcount);
  code = List.filter (fn s -> s.kind == 1 and bits s.flags 1 2 == 3 and s.size > 0) sections;
  symbols = List.fold (readSymbols bytes sections) M.strings (List.filter (fn s -> s.kind == 2) sections);
  {bytes=bytes,header=h,sections=sections,code=code,symbols=symbols,rvc=bits (T.number bytes 48 4) 0 1 == 1}.
readSymbols bytes sections symbols s =
  _ = require (s.stride == 24 and s.size  `remainder`  24 == 0 and s.offset+s.size <= Bytes.len bytes) "invalid symbol table";
  _ = require (s.link < List.len sections) "missing symbol strings";
  strings = sections ! s.link;
  _ = require (strings.kind == 3 and strings.offset+strings.size <= Bytes.len bytes) "invalid symbol strings";
  List.fold (fn acc i ->
    pos = s.offset + i*24;
    n off size = T.number bytes (pos+off) size;
    name = n 0 4; binding = n 4 1 / 16;
    if n 6 2 == 0 or name == 0 or not (List.has binding [1,2]) then acc else
      _ = require (name < strings.size) "invalid symbol name";
      text = symbolName bytes (strings.offset+name) (strings.offset+strings.size) [];
      _ = require (not (M.member text acc)) "duplicate public symbol: {text}";
      M.insert text (n 8 8,binding) acc) symbols (T.indices (s.size/24)).
symbolName bytes pos end acc =
  octets = Bytes.toList (unwrap (Bytes.slice pos (end - pos) bytes));
  (found,rev) = List.fold (fn state c -> (done,xs) = state; if done then state else if c == 0 then (True,xs) else (False,c::xs)) (False,acc) octets;
  _ = require found "unterminated symbol name";
  unwrap (Utf8.decode (unwrap (Bytes.fromList (List.rev rev)))).
need key map = case M.get key map of O.Some v -> v | O.None -> error "missing analysis entry".
symbol img name = case M.get name img.symbols of
    O.Some (address,1) -> address
  | _ -> error "missing/weak symbol: {name}".
hex n =
  (_,text) = List.fold (fn state i -> (started,text) = state; digit = bits n (i*4) 4;
    if not started and digit == 0 and i != 0 then state else (True,text+Str.fromCode (Str.at "0123456789abcdef" digit))) (False,"") (List.rev (List.range 0 15));
  "0x"+text.
label img address = case List.filter (fn pair -> (_,value) = pair; (a,_) = value; a == address) (M.entries img.symbols) of
    (name,_) :: _ -> name | [] -> hex address.
instruction img pc =
  _ = require (pc  `remainder`  (if img.rvc then 2 else 4) == 0) "unaligned instruction at {pc}";
  matches = List.filter (fn s -> s.address <= pc and pc+2 <= s.address+s.size) img.code;
  s = case matches of [one] -> one | _ -> error "control leaves executable bytes at {pc}";
  pos = s.offset+pc - s.address;
  half = T.number img.bytes pos 2;
  if half  `remainder`  4 != 3 then
    _ = require img.rvc "compressed instruction without RVC flag";
    (R.expand half,2)
  else
    _ = require (half  `remainder`  32 != 31 and pc+4 <= s.address+s.size) "unsupported/truncated instruction";
    (T.number img.bytes pos 4,4).
initial checked = List.map (fn i -> if i == 0 then Constant 0 else if i == 2 then Stack 0 else
  if checked and List.has i (1 :: preserved) then Incoming i else Unknown) (List.range 0 31).
sp regs = case regs ! 2 of Stack n -> n | _ -> error "unknown/dynamic stack pointer".
put index value regs = List.map (fn i -> if i == index and index != 0 then value else regs ! i) (List.range 0 31).
wordValue value = case value of Constant n -> Constant (u64 (signed n 32)) | _ -> Unknown.
# One instruction yields state, successors and an optional call edge.
step img returning checked pc regs frame =
  (w,length) = instruction img pc;
  op = bits w 0 7; rd = bits w 7 5; f3 = bits w 12 3;
  rs1 = bits w 15 5; rs2 = bits w 20 5; f7 = bits w 25 7;
  imm = signed (bits w 20 12) 12; offset = sp regs;
  a = regs ! rs1; b = regs ! rs2;
  base = {regs=regs,frame=frame,next=[pc+length],callee=0,retained=0,returns=False};
  decoded = case op of
      55 -> {base | regs=put rd (Constant (u64 (signed (w - w `remainder` 4096) 32))) regs}
    | 23 -> {base | regs=put rd (Constant (u64 (pc+signed (w - w `remainder` 4096) 32))) regs}
    | 19 -> {base | regs=put rd (immediate op f3 w a imm pc) regs}
    | 27 -> {base | regs=put rd (wordValue (immediate op f3 w a imm pc)) regs}
    | 51 -> {base | regs=put rd (integer op f3 f7 a b pc) regs}
    | 59 -> {base | regs=put rd (wordValue (integer op f3 f7 a b pc)) regs}
    | 3 ->
      _ = require (f3 < 7) "invalid load at {pc}";
      value = (case a of Stack n -> if checked and f3 == 3 then M.getOr Unknown (n+imm) frame else Unknown | _ -> Unknown);
      {base | regs=put rd value regs}
    | 35 ->
      _ = require (f3 < 4) "invalid store at {pc}";
      nextFrame = if checked then storeFrame a b frame offset (signed (f7*32+rd) 12) (2^f3) pc else frame;
      {base | frame=nextFrame}
    | 99 ->
      _ = require (List.has f3 [0,1,4,5,6,7]) "invalid branch at {pc}";
      displacement = signed (bits w 31 1*4096+bits w 7 1*2048+bits w 25 6*32+bits w 8 4*2) 13;
      {base | next=[pc+length,pc+displacement]}
    | 111 ->
      _ = require (rd == 0 or rd == 1) "unsupported link register at {pc}";
      displacement = signed (bits w 31 1*1048576+bits w 12 8*4096+bits w 20 1*2048+bits w 21 10*2) 21;
      transfer img returning base pc length offset (pc+displacement) (rd == 1)
    | 103 ->
      _ = require (f3 == 0 and (rd == 0 or rd == 1)) "unsupported indirect transfer at {pc}";
      if rd == 0 and rs1 == 1 and imm == 0 then
        _ = require (offset == 0) "return with unrestored stack at {pc}";
        _ = require (not checked or (regs ! 1 == Incoming 1 and List.all (fn i -> regs ! i == initial True ! i) preserved)) "unproved return/ABI register at {pc}";
        {base | next=[],returns=True}
      else
        target = (case a of Constant n -> u64 (n+imm) | _ -> error "unresolved indirect transfer at {pc}");
        transfer img returning base pc length offset (target - target `remainder` 2) (rd == 1)
    | 15 ->
      _ = require (List.has f3 [0,1] and rd == 0 and rs1 == 0) "unsupported fence at {pc}";
      base
    | _ -> error "unsupported opcode {op} at {pc}";
  current = sp decoded.regs;
  _ = require (current >= 0 - mask and current <= 0 and current  `remainder`  16 == 0) "invalid stack displacement at {pc}";
  {decoded | frame=if checked and current > offset then M.fromList Order.int (List.filter (fn pair -> (k,_) = pair; k >= current) (M.entries decoded.frame)) else decoded.frame}.
transfer img returning base pc length offset target call =
  _ = instruction img target;
  if call then {base | callee=target,retained=0 - offset,
    regs=List.map (fn i -> if List.has i preserved then base.regs ! i else Unknown) (List.range 0 31),
    next=if List.has target returning then [pc+length] else []}
  else {base | next=[target]}.
storeFrame a b frame offset imm width pc =
  dest = case a of Stack n -> n+imm | _ -> error "callback store outside proved frame at {pc}";
  _ = require (offset <= dest and dest+width <= 0) "callback store outside proved frame at {pc}";
  clean = M.fromList Order.int (List.filter (fn pair -> (k,_) = pair; k+8 <= dest or dest+width <= k) (M.entries frame));
  if width == 8 and b != Unknown then M.insert dest b clean else clean.
immediate op f3 w a imm pc =
  if f3 == 0 then plus a (Constant (u64 imm)) else if f3 == 1 or f3 == 5 then
    width = if op == 27 then 5 else 6; upper = w / (2^(20+width)); shift = bits w 20 width;
    _ = require (upper == 0 or (f3 == 5 and upper == (if width == 5 then 32 else 16))) "invalid shift at {pc}";
    if shift == 0 then a else (case a of
      Constant n ->
        size = if op == 27 then 32 else 64;
        value = if f3 == 1 then n*2^shift else
          if upper == 0 then n `remainder` (2^size)/(2^shift) else floorShift (signed n size) shift;
        Constant (u64 value)
      | _ -> Unknown)
  else
    _ = require (op == 19 and List.has f3 [2,3,4,6,7]) "invalid immediate at {pc}";
    case a of Constant n ->
      value = (case f3 of 2 -> if signed n 64 < imm then 1 else 0 | 3 -> if n < u64 imm then 1 else 0
        | 4 -> n + (u64 imm) - 2 * (R.band n (u64 imm)) | 6 -> R.bor n (u64 imm) | _ -> R.band n (u64 imm));
      Constant value
    | _ -> Unknown.
floorShift n shift = d = 2^shift; (n - ((n `remainder` d+d) `remainder` d))/d.
integer op f3 f7 a b pc =
  _ = require (List.has f7 [0,1,32] and (f7 != 32 or List.has f3 [0,5])) "invalid integer operation at {pc}";
  _ = require (op == 51 or (f7 == 1 and List.has f3 [0,4,5,6,7]) or (f7 != 1 and List.has f3 [0,1,5])) "invalid word operation at {pc}";
  if f3 == 0 and f7 == 0 then plus a b else if f3 == 0 and f7 == 32 then
    (case b of Constant n -> plus a (Constant (u64 (0 - n))) | _ -> Unknown)
  else Unknown.
# Flow states join only when entry - SP offsets agree. Frame slots retain
# provenance only when all predecessors agree on an intact full - width save.
Facts = Type (Facts Int (List (Int,Int)) Int Bool (List (Int,Int,List Int)) Int).
Flow = Type (Flow (M.Map Int (List Value,M.Map Int Value)) (List Int) Int (List (Int,Int)) Bool (M.Map Int (Int,List Int)) Int).
joinState old incoming =
  (oldRegs,oldFrame) = old; (regs,frame) = incoming;
  _ = require (oldRegs ! 2 == regs ! 2) "incompatible stack join";
  merged = List.map (fn i -> if oldRegs ! i == regs ! i then regs ! i else Unknown) (List.range 0 31);
  slots = M.fromList Order.int (List.filter (fn pair -> (k,v) = pair; M.get k oldFrame == O.Some v) (M.entries frame));
  (merged,slots).
sameState a b = (ar,af) = a; (br,bf) = b; ar == br and M.entries af == M.entries bf.
enqueue state pc incoming =
  Flow states pending peak edges returns control compressed = state;
  next = (case M.get pc states of O.Some old -> joinState old incoming | O.None -> incoming);
  if M.member pc states and sameState (M.getOr incoming pc states) next then state else
    Flow (M.insert pc next states) (pending + [pc]) peak edges returns control compressed.
walk : unsafe {bytes:Bytes,rvc:Bool,code:List {address:Int,size:Int,offset:Int | s} | i} -> List Int -> Bool -> Flow -> Facts .
walk img returning checked flow = case flow of Flow states pending peak edges returns control compressed ->
  case pending of
    [] -> Facts peak edges (List.len (M.entries states)) returns (List.map (fn pair -> (pc,value) = pair; (callee,next) = value; (pc,callee,next)) (M.entries control))
      (List.len (List.filter (fn pair -> (pc,_) = pair; (_,length) = instruction img pc; length == 2) (M.entries states)))
  | pc :: rest ->
    (regs,frame) = M.getOr ([],M.ints) pc states;
    decoded = step img returning checked pc regs frame;
    nextPeak = Numeric.max peak (Numeric.max (0 - sp regs) (0 - sp decoded.regs));
    edge = (decoded.callee,decoded.retained);
    nextEdges = if decoded.callee != 0 and not (List.has edge edges) then edge::edges else edges;
    base = Flow states rest nextPeak nextEdges (returns or decoded.returns) (M.insert pc (decoded.callee,decoded.next) control) compressed;
    next = List.fold (fn state target -> enqueue state target (decoded.regs,decoded.frame)) base decoded.next;
    walk img returning checked next.
function : unsafe {bytes:Bytes,rvc:Bool,code:List {address:Int,size:Int,offset:Int | s} | i} -> Int -> List Int -> Bool -> Facts .
function img entry returning checked = walk img returning checked (Flow (M.insert entry (initial checked,M.ints) M.ints) [entry] 0 [] False M.ints 0).
reachable : unsafe {bytes:Bytes,rvc:Bool,code:List {address:Int,size:Int,offset:Int | s} | i} -> List Int -> Bool -> M.Map Int Facts .
reachable img roots checked = discover img roots checked M.ints [] M.ints.
discover : unsafe {bytes:Bytes,rvc:Bool,code:List {address:Int,size:Int,offset:Int | s} | i} -> List Int -> Bool -> M.Map Int Facts -> List Int -> M.Map Int (List Int) -> M.Map Int Facts .
discover img pending checked functions returning dependents = case pending of
    [] -> functions
  | address :: rest ->
    facts = function img address returning checked;
    Facts _ edges _ returns _ _ = facts;
    nextFunctions = M.insert address facts functions;
    (queue,deps) = List.fold (fn state edge ->
      (todo,users) = state; (callee,_) = edge;
      nextUsers = M.insert callee (address :: M.getOr [] callee users) users;
      (if M.member callee nextFunctions or List.has callee todo then todo else callee::todo,nextUsers)) (rest,dependents) edges;
    newlyReturns = returns and not (List.has address returning);
    again = if newlyReturns then List.filter (fn a -> not (List.has a queue)) (M.getOr [] address deps) else [];
    discover img (again+queue) checked nextFunctions (if newlyReturns then address::returning else returning) deps.
relax functions bounds = M.fromList Order.int (List.map (fn pair ->
  (address,facts) = pair; Facts local edges _ _ _ _ = facts;
  (address,List.fold (fn best edge -> (callee,retained) = edge; Numeric.max best (retained + M.getOr 0 callee bounds)) local edges)) (M.entries functions)).
boundsLoop : unsafe Int -> M.Map Int Facts -> M.Map Int Int -> M.Map Int Int .
boundsLoop count functions bounds =
  next = relax functions bounds;
  if M.entries next == M.entries bounds then bounds else
    if count == 0 then error "retaining call cycle has no finite stack bound" else boundsLoop (count - 1) functions next.
stackBounds : unsafe M.Map Int Facts -> M.Map Int Int .
stackBounds functions = boundsLoop (List.len (M.entries functions)) functions
  (M.fromList Order.int (List.map (fn pair -> (address,Facts local _ _ _ _ _) = pair; (address,local)) (M.entries functions))).
# Work is a separate graph keyed by (activation,PC); a shared callee cannot
# accidentally obtain another caller's continuation. A cycle always refuses.
workCount : unsafe M.Map Int Facts -> (Int,Int) -> List (Int,Int) -> M.Map String Int -> (Int,M.Map String Int) .
workCount functions node active memo =
  (entry,pc) = node; key = "{entry}:{pc}";
  case M.get key memo of O.Some n -> (n,memo) | O.None ->
    _ = require (not (List.has node active)) "callback instruction bound unproved: reachable cycle";
    Facts _ _ _ _ control _ = need entry functions;
    (_,callee,next) = (case List.filter (fn row -> (address,_,_) = row; address == pc) control of [row] -> row | _ -> error "missing callback PC");
    (continuation,withNext) = List.fold (fn state target ->
      (best,cache) = state; (cost,updated) = workCount functions (entry,target) (node::active) cache;
      (Numeric.max best cost,updated)) (0,memo) next;
    (callCost,withCall) = if callee == 0 then (0,withNext) else workCount functions (callee,callee) (node::active) withNext;
    bound = 1+continuation+callCost;
    _ = require (bound <= mask) "callback work exceeds RV64 domain";
    (bound,M.insert key bound withCall).
stackReport : unsafe {bytes:Bytes,rvc:Bool,code:List {address:Int,size:Int,offset:Int | s},symbols:M.Map String (Int,Int) | i} -> J.Json -> String -> Int -> J.Json .
stackReport img physical entry limit =
  address = symbol img entry;
  _ = require (limit > 0 and limit <= mask) "invalid stack budget";
  functions = reachable img [address] False;
  bounds = stackBounds functions;
  need = M.getOr 0 address bounds;
  _ = require (need <= limit) "{entry}: needs {need} stack bytes, limit {limit}";
  rows = List.map (fn pair ->
    (a,Facts local edges count returns _ compressed) = pair;
    J.JObj [("symbol",J.JStr (label img a)),("address",J.JNum a),("local_bytes",J.JNum local),
      ("peak_bytes",J.JNum (M.getOr 0 a bounds)),("instructions",J.JNum count),("compressed_instructions",J.JNum compressed),("may_return",J.JBool returns),
      ("calls",J.JArr (List.map (fn edge -> (c,r) = edge; J.JObj [("address",J.JNum c),("symbol",J.JStr (label img c)),("retained_bytes",J.JNum r)]) edges))]) (M.entries functions);
  J.JObj [("schema",J.JStr "linked-rv64-stack-v2"),("image",physical),
    ("entries",J.JArr [J.JObj [("symbol",J.JStr entry),("address",J.JNum address),("peak_bytes",J.JNum need),("limit_bytes",J.JNum limit)]]),
    ("functions",J.JArr rows),("scope",J.JStr "ordinary ABI entry SP; synchronous RV64 IMC integer code; no asynchronous traps, startup or stack switching"),
    ("assumptions",J.JArr (List.map J.JStr ["Valid memory accesses and RV64 integer callee-saved register/return ABI, shared by the FPR native frame convention.","No asynchronous interrupt, fault-handler stack, stack switching or concurrent mutation of executable bytes."]))].
callbackReport : unsafe {bytes:Bytes,rvc:Bool,code:List {address:Int,size:Int,offset:Int | s},symbols:M.Map String (Int,Int) | i} -> List (String,String) -> List String -> Int -> J.Json .
callbackReport img symbols steps limit =
  _ = require (limit > 0 and limit <= mask and steps != []) "invalid callback instruction budget/schedule";
  entries = List.map (fn pair -> (name,export) = pair; (name,symbol img export)) symbols;
  functions = reachable img (List.map (fn p -> (_,a) = p; a) entries) True;
  (perEntry,memo) = List.fold (fn state pair -> (values,cache) = state; (name,entry) = pair;
    (count,next) = workCount functions (entry,entry) [] cache;
    (M.insert name count values,next)) (M.strings,M.strings) entries;
  total = List.fold (fn sum name -> sum + need name perEntry) 0 steps;
  _ = require (total <= limit) "callback work needs {total} instructions, limit {limit}";
  J.JObj [("schema",J.JStr "linked-rv64-callback-instructions-v1"),("per_entry",J.JObj (List.map (fn p -> (k,n) = p; (k,J.JNum n)) (M.entries perEntry))),
    ("symbols",J.JObj (List.map (fn p -> (k,s) = p; (k,J.JStr s)) symbols)),("callbacks",J.JNum (List.len steps)),("required",J.JNum total),("limit",J.JNum limit),
    ("linked_functions",J.JArr (List.map (fn pair -> (entry,_) = pair; (count,_) = workCount functions (entry,entry) [] memo;
      J.JObj [("symbol",J.JStr (label img entry)),("address",J.JNum entry),("instructions",J.JNum count)]) (M.entries functions))),
    ("scope",J.JStr "C ABI callback entry through return, including generated adapters and all synchronous callees. Counts RV64 IMC instructions. Startup, dispatcher, resets, interrupts and elapsed time are outside this budget."),
    ("return_policy",J.JStr "Checks preserved registers, stack balance, intact saved return links and frame-confined writes at each activation."),
    ("assumptions",J.JArr [J.JStr "Valid memory reads and instruction fetches, immutable code and no asynchronous handlers or external mutation of active frames."])].
