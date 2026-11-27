# board-host.sol: the host side of FP-RISC runs on Simple-Risc boards and in
# QEMU, in Sol (it replaced board-host.c on 27 November;
# docs/2026-11-27-SOL-STD-LIBRARIES.md).
#
#   fpr sol machine/tangnano20k/board-host.sol board IMAGE --port P --mhz M
#       [--settle S] [--isa rv32im|rv32imc] [--mem-mhz N] [--build-id HEX]
#       [--root DIR] [--timeout S] [--arg A]... [--input LINE]... [--env NAME=VALUE]...
#     Query the ROM identity ('I') and check it, upload with 'U' (CRC-32
#     header and payload), verify with 'C', start with 'G', then serve the
#     guest's @FPR1 requests until the ROM prints DONE. Guest output goes to
#     stdout. Exit 0 only for one "FPR EXIT 0" followed by DONE.
#   ... board-host.sol qemu ELF [--xlen 32|64] [--root DIR] [--timeout S] [...as above]
#     The same virtual device for qemu-system-riscvXLEN -machine virt, whose
#     serial console is a Child on pipes.
#   ... board-host.sol dtree TRAIN TEST BINS DEPTH MIN_LEAF [LOG REPEATS]
#     The classifier's independent reference as JSON; with LOG, also check
#     every run in the guest log against it and report elapsed times and heap
#     samples.
#
# The protocols are Simple-Risc's boards/tangnano20k/rom_protocol.py (SRID1,
# SRU1) and FP-RISC's UART virtual device (@FPR1 frames, one '+' ACK per reply
# byte, because the board's receiver holds one byte).
# Exit status: 0 pass, 1 guest or check failure, 2 usage, 3 timeout.

maxPayload = 1048576.

# ends the run: the exit status, after the message on stderr
die code message = _ = eprint "board-host: {message}"; _ = Script.exit code; error message.
eprint message =
  (r, w) = Stream.writeChunk (unwrap (Utf8.encode "{message}\n")) (unwrap (Stream.stderr 4096));
  _ = Stream.closeWrite w;
  Unit.
nowUs u = Sys.mtime Unit / 10.

# bytes as the string of those bytes, and back (strings are UTF-8 bytes)
textOf bytes = strJoin "" (List.map chr (Bytes.toList bytes)).
bytesOf text = unwrap (Utf8.encode text).
bytesFrom xs = unwrap (Bytes.fromList xs).
# 0, 1, ..., n - 1 (List.range includes its end)
upto n = if n <= 0 then [] else List.range 0 (n - 1).
repeat n x = List.map (fn i -> x) (upto n).
lastIndexOf c s = List.fold (fn acc i -> if charAt s i == c then i else acc) (0 - 1) (upto (Str.len s)).
pow16 k = List.fold (fn a i -> a * 16) 1 (upto k).
padHex w n = strJoin "" (List.map (fn i -> substr "0123456789abcdef" ((n / pow16 (w - 1 - i)) % 16) 1) (upto w)).
# a whole file's bytes, now
readFileBytes path = case Stream.openRead path 65536 of
    Err why -> Err why
  | Ok reader ->
      (result, next) = Stream.foldChunks (fn acc b -> b :: acc) [] reader;
      _ = Stream.closeRead next;
      (case result of Ok parts -> Ok (Bytes.concat (List.rev parts)) | Err why -> Err why).

# ---- options shared by board and qemu ------------------------------------------
Opts = { image : String, port : String, root : String, isa : String, buildId : String,
         mhz : Int, settle : Int, timeout : Int, memMhz : Int, xlen : Int,
         args : List String, inputs : List String, env : List String }.
defaults = { image = "", port = "", root = ".", isa = "", buildId = "", mhz = 0, settle = 0,
             timeout = 120, memMhz = 0, xlen = 32, args = [], inputs = [], env = [] }.

# a finite non-negative number; MHz and seconds may carry a fraction, kept
# here in thousandths
milli flag s =
  parts = Str.split 46 s;
  whole = parts ! 0;
  frac = (if List.len parts > 1 then parts ! 1 else "");
  digitsOnly t = List.all (fn c -> c >= 48 and c <= 57) (Str.codes t);
  if List.len parts > 2 or whole == "" or not (digitsOnly whole) or not (digitsOnly frac) then die 2 "{flag} needs a finite non-negative number, got '{s}'"
  else parseInt whole * 1000 + parseInt (Str.slice (frac + "000") 0 3).

option o flag v =
  if flag == "--port" then { o | port = v }
  else if flag == "--mhz" then { o | mhz = milli flag v }
  else if flag == "--settle" then { o | settle = milli flag v }
  else if flag == "--timeout" then { o | timeout = milli flag v / 1000 }
  else if flag == "--root" then { o | root = v }
  else if flag == "--isa" then { o | isa = v }
  else if flag == "--build-id" then { o | buildId = v }
  else if flag == "--mem-mhz" then { o | memMhz = milli flag v / 1000 }
  else if flag == "--xlen" then { o | xlen = milli flag v / 1000 }
  else if flag == "--arg" then (if List.len o.args == 256 then die 2 "at most 256 program arguments" else { o | args = List.append o.args [v] })
  else if flag == "--input" then { o | inputs = List.append o.inputs [v] }
  else if flag == "--env" then (if Str.indexOf "=" v <= 0 then die 2 "--env requires a nonempty NAME=VALUE" else { o | env = List.append o.env [v] })
  else die 2 "unknown option {flag}".

parseOpts : unsafe Opts -> List String -> Opts .
parseOpts o argv = case argv of
    [] -> if o.image == "" then die 2 "an image is required"
          else if o.timeout <= 0 then die 2 "--timeout must be positive"
          else if o.xlen != 32 and o.xlen != 64 then die 2 "--xlen must be 32 or 64"
          else o
  | a :: rest ->
      if Str.startsWith "--" a then
        eq = Str.indexOf "=" a;
        (if eq > 0 then parseOpts (option o (Str.slice a 0 eq) (Str.slice a (eq + 1) (Str.len a))) rest
         else case rest of
             v :: more -> parseOpts (option o a v) more
           | [] -> die 2 "{a} needs a value")
      else if o.image != "" then die 2 "unexpected argument {a}"
      else parseOpts { o | image = a } rest.

# ---- the virtual device ----------------------------------------------------------
argBytes a = b = bytesOf a; Bytes.concat [Bytes.putU32le (Bytes.len b), b].
encodedArgs o =
  out = Bytes.concat (Bytes.putU32le (List.len o.args) :: List.map argBytes o.args);
  if Bytes.len out > 65536 then die 2 "program arguments exceed 65536 encoded bytes" else out.

realpath path =
  ProcessResult status out err = unwrap (Proc.runNow (ProcessSpec ["realpath",path] "" [] "" 0));
  if status == 0 then Ok (Str.trim out) else Err (Str.trim err).
parentOf path = i = lastIndexOf 47 path; if i <= 0 then "" else Str.slice path 0 i.
under root real = real == root or Str.startsWith "{root}/" real.
# the deepest existing ancestor of `probe` must resolve inside the root
staysInside : unsafe String -> String -> Bool .
staysInside root probe = if probe == "" or probe == root then True else
  case realpath probe of
    Ok real -> under root real
  | Err _ -> staysInside root (parentOf probe).

# A request path is relative, has no NUL, and stays inside the root both
# lexically and after following symlinks of whatever already exists.
devicePath : unsafe Opts -> String -> Result String String .
devicePath o rel = case realpath o.root of
    Err _ -> Err "virtual root is missing"
  | Ok root ->
      if rel == "" or Str.indexOf (chr 0) rel >= 0 or Str.startsWith "/" rel then Err "virtual path must be relative"
      else
        step acc part = case acc of
            Err e -> Err e
          | Ok parts -> if part == "" or part == "." then Ok parts
                        else if part == ".." then (case parts of [] -> Err "virtual path escapes root" | p :: ps -> Ok ps)
                        else Ok (part :: parts);
        case List.fold step (Ok []) (Str.split 47 rel) of
          Err e -> Err e
        | Ok parts ->
            path = root + strJoin "" (List.map (fn p -> "/" + p) (List.rev parts));
            if staysInside root path then Ok path else Err "virtual path escapes root".

# (status, reply): status 0 ok, 1 failure with the reason as the reply
dispatch : unsafe Opts -> Int -> Bytes -> (Int, Bytes) .
dispatch o op data = case op of
    1 -> (case devicePath o (textOf data) of
            Err why -> (1, bytesOf why)
          | Ok path -> (case readFileBytes path of
                Err why -> (1, bytesOf (str why))
              | Ok b -> if Bytes.len b > maxPayload then (1, bytesOf "virtual reply too large") else (0, b)))
  | 2 -> (case devicePath o (textOf data) of Err why -> (1, bytesOf why) | Ok path -> (0, bytesOf (if exists path then "1" else "0")))
  | 3 -> deviceWrite o True data
  | 4 -> deviceWrite o False data
  | 5 -> name = textOf data;
         (case List.filter (fn kv -> Str.startsWith "{name}=" kv) o.env of
             kv :: _ -> (0, bytesOf (Str.slice kv (Str.len name + 1) (Str.len kv)))
           | [] -> (1, bytesOf "unset"))
  | 6 -> if Bytes.len data != 0 then (1, bytesOf "clock payload must be empty") else (0, bytesOf "{nowUs Unit}")
  | 9 -> if Bytes.len data != 0 then (1, bytesOf "arguments payload must be empty") else (0, encodedArgs o)
  | _ -> (1, bytesOf "virtual operation unavailable").
# NAME \0 CONTENTS; replace or append
deviceWrite : unsafe Opts -> Bool -> Bytes -> (Int, Bytes) .
deviceWrite o replace data =
  text = textOf data;
  sep = Str.indexOf (chr 0) text;
  if sep < 0 then (1, bytesOf "write request has no path separator") else
    case devicePath o (Str.slice text 0 sep) of
      Err why -> (1, bytesOf why)
    | Ok path ->
        body = Str.slice text (sep + 1) (Str.len text);
        _ = (if replace then writeNow path body else appendNow path body);
        (0, Bytes.empty Unit).

# input lines are served in order: the next one is the count already served
nextInput o served = if served >= List.len o.inputs then (1, bytesOf "eof") else (0, bytesOf (o.inputs ! served)).

# ---- frames -------------------------------------------------------------------------
hex8 n = padHex 8 n.
hex2 n = padHex 2 n.
xorAll b = List.fold bxor 0 (Bytes.toList b).
hexValue t = if t == "" or not (List.all (fn c -> (c >= 48 and c <= 57) or (c >= 97 and c <= 102)) (Str.codes t)) then -1
  else List.fold (fn acc c -> acc * 16 + (if c <= 57 then c - 48 else c - 87)) 0 (Str.codes t).

# "@FPR1 SSSSSSSS OO NNNNNNNN HEX CC" without the newline: (seq, op, payload)
parseFrame line =
  n = Str.len line;
  ok = n >= 30 and Str.startsWith "@FPR1 " line and charAt line 14 == 32 and charAt line 17 == 32 and charAt line 26 == 32;
  if not ok then Err "malformed RPC header" else
    seq = hexValue (Str.slice line 6 14);
    op = hexValue (Str.slice line 15 17);
    len = hexValue (Str.slice line 18 26);
    if seq < 0 or op < 0 or len < 0 then Err "RPC hex"
    else if len > maxPayload or n != 27 + 2 * len + 3 or charAt line (27 + 2 * len) != 32 then Err "RPC length"
    else
      sum = hexValue (Str.slice line (28 + 2 * len) (30 + 2 * len));
      case Hex.decode (Str.slice line 27 (27 + 2 * len)) of
        Err _ -> Err "RPC hex"
      | Ok payload ->
          if sum < 0 then Err "RPC hex"
          else if xorAll payload != sum then Err "RPC checksum"
          else if seq == 0 then Err "RPC sequence"
          else Ok (seq, op, payload).

makeFrame seq code payload =
  bytesOf "@FPR1 {hex8 seq} {hex2 code} {hex8 (Bytes.len payload)} {Str.lower (Hex.encode payload)} {hex2 (xorAll payload)}\n".

# ---- the link: a board's UART or QEMU's console, the same operations -----------------
Link 1 = Type (OnBoard Serial | InQemu Child).
linkWrite b l = case l of
    OnBoard s -> (r, s2) = Serial.write b s; (r, OnBoard s2)
  | InQemu c -> (r, c2) = Child.write b c; (r, InQemu c2).
linkRead n ms l = case l of
    OnBoard s -> (r, s2) = Serial.read n ms s; (r, OnBoard s2)
  | InQemu c -> (r, c2) = Child.read n ms c; (r, InQemu c2).

# A failure ends the run, and the link goes with it: a board gets ^C first
# (it stops a running guest and returns the ROM to its prompt), QEMU is ended.
fail l code message = _ = closeLink True l; die code message.
closeLink abort l = case l of
    OnBoard s -> (if abort then (r, s2) = Serial.write (bytesOf (chr 3)) s; _ = Sys.sleepUs 200000; Serial.close s2 else Serial.close s)
  | InQemu c -> Child.kill c.

sendAll b l = (r, l2) = linkWrite b l; case r of Ok _ -> l2 | Err why -> fail l2 1 why.

# Stop-and-wait per byte protects the board's one-byte receiver while the
# guest allocates the reply or parses its header.
respond frame l = List.fold (fn link byte ->
    l2 = sendAll (bytesFrom [byte]) link;
    (r, l3) = linkRead 1 5000 l2;
    case r of
      Ok ack -> if Bytes.len ack == 1 and Bytes.u8 0 ack == Some 43 then l3
                else fail l3 1 "virtual device expected ACK, got {Bytes.toList ack}"
    | Err why -> fail l3 1 "virtual device ACK: {why}") l (Bytes.toList frame).

# serve state: pending text, frames answered, inputs served, successful exits
Serve = { pending : String, sequence : Int, served : Int, exits : Int }.

# Serve the guest until the ROM's DONE (board) or end of stream (qemu): 0
# for a pass, 1 for a failure, 3 for a timeout.
serve : unsafe Opts -> Bool -> Int -> Serve -> Link -> (Int, Option Link) .
serve o board deadline st l =
  nl = Str.indexOf "\n" st.pending;
  if nl >= 0 then
    line = Str.slice st.pending 0 nl;
    rest = Str.slice st.pending (nl + 1) (Str.len st.pending);
    (if Str.startsWith "@FPR1 " line then
      (seq, op, payload) = (case parseFrame line of Ok f -> f | Err why -> (0, 0 - 1, bytesOf why));
      (status, reply) = (if op < 0 then (1, payload) else if op == 8 then (if Bytes.len payload != 0 then (1, bytesOf "input payload must be empty") else nextInput o st.served) else dispatch o op payload);
      served = (if op == 8 and status == 0 then st.served + 1 else st.served);
      l2 = (if op < 0 then fail l 1 (textOf payload)
            else if seq != st.sequence + 1 then fail l 1 "guest sequence out of order"
            else respond (makeFrame seq status reply) l);
      serve o board deadline { st | pending = rest, sequence = seq, served = served } l2
    else
      _ = print line;
      serve o board deadline { st | pending = rest, exits = st.exits + (if line == "FPR EXIT 0" then 1 else 0) } l)
  else if board and Str.endsWith "DONE" st.pending then
    _ = print st.pending;
    _ = closeLink (st.exits == 0) l;
    (if st.exits == 0 then _ = eprint "board-host: CPU halted without a successful runtime exit"; (1, None) else (0, None))
  else if Str.len st.pending > 2 * maxPayload + 128 then fail l 1 "oversized guest frame"
  else if nowUs Unit >= deadline then
    _ = eprint "board-host: timeout; no successful exit (pending {Str.slice st.pending 0 80})";
    _ = closeLink True l;
    (3, None)
  else
    (r, l2) = linkRead 4096 50 l;
    case r of
      Ok chunk -> serve o board deadline { st | pending = st.pending + textOf chunk } l2
    | Err why -> if board then fail l2 1 "serial port: {why}" else
        _ = (if st.pending != "" then print st.pending else Unit);
        # qemu: end of stream; the caller checks the exit
        (if st.exits == 0 then (1, Some l2) else (0, Some l2)).

# ---- boot ROM -----------------------------------------------------------------------
# what arrives within `ms`, until a full line: the last non-empty line, or ""
readLine : unsafe Int -> Link -> (String, Link) .
readLine ms l = readLineGo (nowUs Unit + ms * 1000) "" l.
readLineGo : unsafe Int -> String -> Link -> (String, Link) .
readLineGo deadline acc l =
  if Str.indexOf "\n" acc >= 0 or nowUs Unit >= deadline then
    lines = List.filter (fn t -> t != "") (List.concat (List.map (Str.split 13) (Str.split 10 acc)));
    (if lines == [] then "" else List.last lines, l)
  else
    (r, l2) = linkRead 256 50 l;
    case r of Ok b -> readLineGo deadline (acc + textOf b) l2 | Err why -> fail l2 1 "serial port: {why}".

drain : unsafe Int -> Link -> Link .
drain ms l = (r, l2) = linkRead 65536 ms l; case r of Ok b -> (if Bytes.len b == 0 then l2 else drain ms l2) | Err why -> fail l2 1 why.

Identity = { isa : String, cpu : Int, mem : Int, ram : Int, max : Int, cap : String, id : String, line : String }.
fieldOf words key = case List.filter (fn w -> Str.startsWith "{key}=" w) words of
    w :: _ -> Str.slice w (Str.len key + 1) (Str.len w)
  | [] -> "".
parseIdentity srid =
  words = Str.words srid;
  id = { isa = fieldOf words "isa", cpu = hexValue (fieldOf words "cpu"), mem = hexValue (fieldOf words "mem"),
         ram = hexValue (fieldOf words "ram"), max = hexValue (fieldOf words "max"), cap = fieldOf words "cap",
         id = fieldOf words "id", line = srid };
  if List.len words >= 8 and words ! 0 == "SRID1" and id.isa != "" and id.cpu >= 0 and id.mem >= 0 and id.ram >= 0 and id.max >= 0
     and id.cap != "" and Str.len id.id == 16 and hexValue id.id >= 0 then Ok id
  else if not (Str.startsWith "SRID1 " srid) then Err "unsupported ROM identity protocol: {srid}"
  else Err "malformed ROM identity reply: {srid}".

queryIdentity : unsafe Int -> Link -> (Identity, Link) .
queryIdentity attempt l =
  if attempt == 3 then fail l 1 "no response from the boot ROM on the UART (check the bitstream, port and clock)" else
    l2 = sendAll (bytesOf "I") l;
    (line, l3) = readLine 1000 l2;
    if line == "" then
      l4 = sendAll (bytesOf (chr 3)) l3;
      _ = Sys.sleepUs 150000;
      queryIdentity (attempt + 1) (drain 10 l4)
    else
      at = Str.indexOf "SRID" line;
      if at < 0 then queryIdentity (attempt + 1) l3 else
        case parseIdentity (Str.slice line at (Str.len line)) of
          Ok id -> (id, l3)
        | Err why -> fail l3 1 why.

checkIdentity o id imageBytes =
  padded = (imageBytes + 3) / 4 * 4;
  if id.isa != "rv32im" and id.isa != "rv32imc" then "unsupported board ISA {id.isa}"
  else if o.isa != "" and id.isa != o.isa then "board ISA mismatch: board reports {id.isa}, expected {o.isa}"
  else if id.cpu != (o.mhz + 500) / 1000 then "CPU clock mismatch: board reports {id.cpu} MHz, expected {(o.mhz + 500) / 1000} MHz"
  else if o.memMhz != 0 and id.mem != o.memMhz then "memory clock mismatch: board reports {id.mem} MHz, expected {o.memMhz} MHz"
  else if o.buildId != "" and Str.lower id.id != Str.lower o.buildId then "bitstream build id mismatch: board reports {id.id}, expected {o.buildId}"
  else if not (List.all (fn c -> Str.contains c id.cap) ["U","I","C","G"]) then "board loader lacks a capability of UICG (cap={id.cap})"
  else if padded == 0 or padded > id.max then "program image is {padded} bytes; the loader takes 1..{id.max}"
  else "".

upload : unsafe Bytes -> Int -> Link -> Link .
upload image mhzMilli l =
  padded = (Bytes.len image + 3) / 4 * 4;
  words = Bytes.concat [image, bytesFrom (repeat (padded - Bytes.len image) 0)];
  head = Bytes.concat [bytesOf "SRU1", Bytes.putU32le (padded / 4)];
  pcrc = Bytes.crc32 words;
  l2 = sendAll (Bytes.concat [bytesOf "U", head, Bytes.putU32le (Bytes.crc32 head), words, Bytes.putU32le pcrc]) l;
  # 8680 µs per byte at 1 MHz: ten bits at clock/868
  ms = Numeric.max 15000 (padded * 8680 / mhzMilli + 5000);
  (line, l3) = readLine ms l2;
  l4 = (if line == "" then fail l3 1 "timed out waiting for the ROM upload acknowledgement"
        else if line != "OK {hex8 pcrc}" then fail l3 1 "upload rejected: got '{line}', expected 'OK {hex8 pcrc}'"
        else sendAll (bytesOf "C") l3);
  (back, l5) = readLine ms l4;
  if back != hex8 pcrc then fail l5 1 "readback 'C' CRC mismatch: got '{back}', expected '{hex8 pcrc}'" else l5.

cmdBoard : unsafe List String -> Int .
cmdBoard argv =
  o = parseOpts defaults argv;
  _ = (if o.port == "" or o.mhz <= 0 then die 2 "board needs --port and a positive --mhz" else Unit);
  _ = encodedArgs o; # refuse bad arguments before touching the board
  image = (case readFileBytes o.image of Ok b -> b | Err why -> die 2 "{o.image}: {why}");
  _ = (if Bytes.len image == 0 or Bytes.len image > 2097152 then die 2 "image must contain 1..2 MiB" else Unit);
  baud = (o.mhz * 1000 + 434) / 868;
  port = (case Serial.open o.port baud of Ok p -> p | Err why -> die 1 why);
  # Some USB bridges (the Arty S7's FTDI) drop what is written in roughly
  # the first second after the port opens.
  l0 = drain 10 (OnBoard port);
  l1 = (if o.settle > 0 then _ = Sys.sleepUs (o.settle * 1000); drain 10 l0 else l0);
  (id, l2) = queryIdentity 0 l1;
  _ = eprint "board-host: SRID1 isa={id.isa} cpu={id.cpu} mem={id.mem} ram={id.ram} max={id.max} cap={id.cap} id={id.id}";
  refused = checkIdentity o id (Bytes.len image);
  l3 = (if refused != "" then fail l2 1 refused else upload image (o.mhz) l2);
  l4 = sendAll (bytesOf "G") l3;
  # 'G' answers ERR NOIMG at once when no verified image is held
  (first, l5) = linkRead 256 20 l4;
  start = (case first of Ok b -> textOf b | Err why -> "");
  l6 = (if Str.startsWith "ERR NOIMG" start then fail l5 1 "ROM refused guarded execution ('G'): ERR NOIMG" else l5);
  (code, rest) = serve o True (nowUs Unit + o.timeout * 1000000) { pending = start, sequence = 0, served = 0, exits = 0 } l6;
  case rest of None -> code | Some l -> _ = closeLink False l; code.

cmdQemu : unsafe List String -> Int .
cmdQemu argv =
  o = parseOpts defaults argv;
  _ = encodedArgs o;
  exe = "qemu-system-riscv{o.xlen}";
  child = (case Child.open [exe,"-machine","virt","-m","8M","-bios","none","-kernel",o.image,
                            "-display","none","-monitor","none","-serial","stdio"] of Ok c -> c | Err why -> die 1 why);
  (code, rest) = serve o False (nowUs Unit + o.timeout * 1000000) { pending = "", sequence = 0, served = 0, exits = 0 } (InQemu child);
  case rest of
    None -> code
  | Some (InQemu c) -> (case Child.wait 5000 c of
        Err why -> die 1 "QEMU did not exit: {why}"
      | Ok 0 -> (if code == 0 then 0 else _ = eprint "board-host: no successful runtime exit"; 1)
      | Ok status -> _ = eprint "board-host: QEMU exit status {status}"; 1)
  | Some l -> _ = closeLink True l; code.

# ---- classifier reference ------------------------------------------------------------
# The same data and tree as the guest's classifier fixture, with Sol's
# Num.log2 as the independent entropy (not the guest's 48-step log2).
lcg seed count = List.rev (List.fold (fn acc i -> (s, xs) = acc;
    s2 = (1103515245 * s + 12345) % 2147483648;
    (s2, (1.0 * s2) / 2147483648.0 :: xs)) (seed, []) (upto count) |> (fn p -> (s, xs) = p; xs)).
# n rows of (x, z, y): y is x and z of different signs, flipped by 5% noise
dataset seed n =
  v = lcg seed (3 * n);
  xs = List.map (fn a -> a * 2.0 - 1.0) (List.take n v);
  zs = List.map (fn a -> a * 2.0 - 1.0) (List.take n (List.drop n v));
  noise = List.drop (2 * n) v;
  List.map (fn t -> (x, rest) = t; (z, u) = rest; b = (if (x > 0.0) != (z > 0.0) then 1 else 0); (x, z, if u < 0.05 then 1 - b else b))
    (List.zip xs (List.zip zs noise)).

entropy c0 c1 =
  n = c0 + c1;
  term c = if c == 0 then 0.0 else ((1.0 * c) / (1.0 * n)) * Num.log2 ((1.0 * c) / (1.0 * n));
  if n == 0 then 0.0 else 0.0 - (term c0 + term c1).

# Sol numbers are one Numeric type: a threshold is an inexact Int
Tree = Type (Leaf Int | Split Int Int Tree Tree).

# a training row as the classifier sees it: (bin code of x, bin code of z, label)
codeOf r col = (c0, c1, y) = r; if col == 0 then c0 else c1.
labelOf r = (c0, c1, y) = r; y.

# the best split of one column: Some (gain, col, bin) or None, from `acc`
# (equal gains keep the earlier bin, then the earlier column)
bestIn bins minLeaf parent n c0 c1 rows col acc =
  List.fold (fn b t ->
      left = List.filter (fn r -> codeOf r col <= t) rows;
      n1 = List.sum (List.map labelOf left);
      nl = List.len left;
      n0 = nl - n1;
      if nl < minLeaf or n - nl < minLeaf then b else
        gain = parent - (((1.0 * nl) / (1.0 * n)) * entropy n0 n1 + ((1.0 * (n - nl)) / (1.0 * n)) * entropy (c0 - n0) (c1 - n1));
        case b of
          None -> Some (gain, col, t)
        | Some (g, bc, bt) -> if gain > g then Some (gain, col, t) else b)
    acc (upto (bins - 1)).

build : unsafe { bins : Int, maxDepth : Int, minLeaf : Int, lo : List Int, width : List Int } -> List (Int, Int, Int) -> Int -> Tree .
build c rows depth =
  n = List.len rows;
  c1 = List.sum (List.map labelOf rows);
  c0 = n - c1;
  leaf = Leaf (if c1 > c0 then 1 else 0);
  parent = entropy c0 c1;
  if depth >= c.maxDepth or n < 2 * c.minLeaf or parent == 0.0 then leaf else
    best = bestIn c.bins c.minLeaf parent n c0 c1 rows 1 (bestIn c.bins c.minLeaf parent n c0 c1 rows 0 None);
    case best of
      None -> leaf
    | Some (gain, col, thr) -> if gain < 0.001 then leaf else
        a = List.filter (fn r -> codeOf r col <= thr) rows;
        b = List.filter (fn r -> codeOf r col > thr) rows;
        Split col ((c.lo ! col) + (1.0 * (thr + 1)) * (c.width ! col)) (build c a (depth + 1)) (build c b (depth + 1)).

predict : unsafe Tree -> Int -> Int -> Int .
predict t x z = case t of Leaf v -> v | Split col thr lo hi -> predict (if (if col == 1 then z else x) < thr then lo else hi) x z.
shape : unsafe Tree -> (Int, Int) .
shape t = case t of Leaf _ -> (1, 0) | Split _ _ lo hi -> (an, ad) = shape lo; (bn, bd) = shape hi; (1 + an + bn, 1 + Numeric.max ad bd).

score : unsafe Tree -> List (Int, Int, Int) -> (Int, Int, String) .
score t d =
  ps = List.map (fn r -> (x, z, y) = r; predict t x z) d;
  hits = List.sum (List.map (fn p -> (pv, r) = p; (x, z, y) = r; if pv == y then 1 else 0) (List.zip ps d));
  digest = List.fold (fn acc p -> (acc * 257 + p + 1) % 1000003) 0 ps;
  (hits, digest, Str.lower (Hex.encode (Sha256.bytes (bytesFrom ps)))).

# Every "DTREE BEGIN" run in the log must carry the reference lines exactly
# once, the root split, and an elapsed time.
checkRuns logText repeats want tree =
  lines = Str.split 10 logText;
  # each run is its BEGIN line and the lines up to the next BEGIN (one pass)
  grouped = List.fold (fn acc l -> (done, cur) = acc;
      if Str.startsWith "DTREE BEGIN " l then (case cur of None -> (done, Some [l]) | Some ls -> (List.rev ls :: done, Some [l]))
      else (case cur of None -> (done, None) | Some ls -> (done, Some (l :: ls)))) ([], None) lines;
  runs = (case grouped of (done, None) -> List.rev done | (done, Some ls) -> List.rev (List.rev ls :: done));
  _ = (if List.len runs > repeats then die 1 "classifier: more than {repeats} runs in the log" else Unit);
  elapsed = List.map (fn k -> run = runs ! k;
      _ = List.map (fn w -> if List.len (List.filter (fn l -> l == w) run) != 1 then die 1 "classifier run {k + 1}: expected exactly one '{w}'" else Unit) want;
      _ = (case tree of
          Leaf _ -> if List.has "root: leaf" run then Unit else die 1 "classifier run {k + 1}: expected a leaf root"
        | Split col thr _ _ -> (case List.filter (Str.startsWith "root split: col ") run of
              l :: _ -> ws = Str.words l;
                (if List.len ws >= 6 and parseInt (ws ! 3) == col and closeTo (unwrap (Try.parseNum (ws ! 5))) thr then Unit
                 else die 1 "classifier run {k + 1}: root split differs from the reference")
            | [] -> die 1 "classifier run {k + 1}: root split differs from the reference"));
      (case List.filter (Str.startsWith "DTREE elapsed_us=") run of
          l :: _ -> parseInt (Str.slice l 17 (Str.len l))
        | [] -> die 1 "classifier run {k + 1}: no elapsed time")) (upto (List.len runs));
  _ = (if List.len runs != repeats then die 1 "classifier: {List.len runs} runs in the log, expected {repeats}" else Unit);
  heap = List.map heapSample (List.filter (fn l -> Str.startsWith "HEAP " l or Str.startsWith "GC HEAP " l) lines);
  (elapsed, heap).
closeTo a b = d = (if a > b then a - b else b - a); m = (if a > b then a else b); d <= (if 0.000000000001 * m > 0.000000000001 then 0.000000000001 * m else 0.000000000001).
leadingDigits cs = List.rev ((List.fold (fn acc c -> (ds, stopped) = acc;
    if stopped or c < 48 or c > 57 then (ds, True) else (c :: ds, False)) ([], False) cs) |> (fn p -> (ds, s) = p; ds)).
keyChar c = c == 95 or (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57).
# key=value integers of one heap line, in order
heapSample line = "\{" + strJoin "," (List.concat (List.map (fn w ->
    eq = Str.indexOf "=" w;
    key = (if eq > 0 then Str.slice w 0 eq else "");
    value = (if eq > 0 then leadingDigits (Str.codes (Str.slice w (eq + 1) (Str.len w))) else []);
    if key != "" and List.all keyChar (Str.codes key) and value != [] then ["\"{key}\":{strJoin "" (List.map chr value)}"] else []) (Str.words line))) + "\}".

# a column's low end, bin width and bin codes
colStats bins vs =
  lo = List.fold (fn a v -> if v < a then v else a) (vs ! 0) vs;
  hi = List.fold (fn a v -> if v > a then v else a) (vs ! 0) vs;
  w0 = (hi - lo) / (1.0 * bins);
  width = (if w0 == 0.0 then 1.0 else w0);
  codes = List.map (fn v -> k = Num.floor ((v - lo) / width); if k < bins - 1 then k else bins - 1) vs;
  (lo, width, codes).

cmdDtree : unsafe List String -> Int .
cmdDtree argv =
  _ = (if List.len argv != 5 and List.len argv != 7 then die 2 "dtree TRAIN TEST BINS DEPTH MIN_LEAF [LOG REPEATS]" else Unit);
  train = parseInt (argv ! 0); test = parseInt (argv ! 1);
  bins = parseInt (argv ! 2); maxDepth = parseInt (argv ! 3); minLeaf = parseInt (argv ! 4);
  _ = (if train < 1 or test < 1 or minLeaf < 1 or bins < 2 or maxDepth < 1 or maxDepth > 12 then die 2 "positive sizes, bins >= 2 and depth 1..12 required" else Unit);
  tr = dataset 42 train;
  te = dataset 7 test;
  (lo0, w0, codes0) = colStats bins (List.map (fn r -> (x, z, y) = r; x) tr);
  (lo1, w1, codes1) = colStats bins (List.map (fn r -> (x, z, y) = r; z) tr);
  rows = List.map (fn t -> (k0, rest) = t; (k1, r) = rest; (x, z, y) = r; (k0, k1, y)) (List.zip codes0 (List.zip codes1 tr));
  c = { bins = bins, maxDepth = maxDepth, minLeaf = minLeaf, lo = [lo0, lo1], width = [w0, w1] };
  tree = build c rows 0;
  (nodes, depth) = shape tree;
  (trHits, trDigest, trSha) = score tree tr;
  (teHits, teDigest, teSha) = score tree te;
  want = ["DTREE BEGIN train={train} test={test} bins={bins} depth={maxDepth} minLeaf={minLeaf}", "DTREE DATA READY",
          "DTREE nodes={nodes} depth={depth}", "DTREE train hits={trHits}/{train} digest={trDigest}",
          "DTREE test hits={teHits}/{test} digest={teDigest}"];
  root = (case tree of Leaf v -> "\"root\":\{\"leaf\":{v}\}," | Split col thr _ _ -> "\"root\":\{\"column\":{col},\"threshold\":{thr}\},");
  reference = "\{\"reference\":\{\"train_rows\":{train},\"test_rows\":{test},\"bins\":{bins},\"max_depth\":{maxDepth},\"min_leaf\":{minLeaf},"
    + "\"nodes\":{nodes},\"depth\":{depth},"
    + "\"train\":\{\"hits\":{trHits},\"rows\":{train},\"digest\":{trDigest},\"predictions_sha256\":\"{trSha}\"\},"
    + "\"test\":\{\"hits\":{teHits},\"rows\":{test},\"digest\":{teDigest},\"predictions_sha256\":\"{teSha}\"\},"
    + root + "\"entropy\":\"Sol Num.log2; the classifier uses its own 48-step log2\"\}";
  checked = (if List.len argv == 7 then
      repeats = parseInt (argv ! 6);
      _ = (if repeats < 1 or repeats > 100 then die 2 "REPEATS must be 1..100" else Unit);
      (elapsed, heap) = checkRuns (case readFileBytes (argv ! 5) of Ok b -> textOf b | Err why -> die 2 "{argv ! 5}: {why}") repeats want tree;
      ",\"elapsed_us_runs\":[{strJoin "," (List.map str elapsed)}],\"heap_samples\":[{strJoin "," heap}]"
    else "");
  _ = print (reference + checked + "\}");
  0.

main : unsafe Unit -> Int .
main u = case args Unit of
    "board" :: rest -> cmdBoard rest
  | "qemu" :: rest -> cmdQemu rest
  | "dtree" :: rest -> cmdDtree rest
  | _ -> _ = eprint "usage: board-host board IMAGE --port P --mhz M [...] | qemu ELF [...] | dtree ..."; 2.

>! Script.exit (main Unit).
