# Physical admission for little-endian linked RV32/RV64 ELFs. Decode each
# multibyte field to an exact VM integer before checking address arithmetic.
J = use "../sol/lib/json".
F = use "toolchain-files".
CLI = use "../sol/lib/cli".
Map = use "../std/map".
require ok why = if ok then Unit else error ("target image refused: " + why).
number bytes pos count =
  octets = Bytes.toList (unwrap (Bytes.slice pos count bytes));
  List.fold (fn n b -> n * 256 + b) 0 (List.rev octets).
indices n = if n == 0 then [] else List.range 0 (n - 1).
digest bytes = Hex.encode (Sha256.bytes bytes).
# The generic JSON reader accepts fractional/exponent notation. A target
# manifest requires integer tokens, including for a value such as 32.0.
integerTokens text =
  (_,_,ok) = List.fold (fn state c ->
    (quoted,escaped,valid) = state;
    if escaped then (True,False,valid) else if quoted and c == 92 then (True,True,valid)
    else if c == 34 then (not quoted,False,valid) else (quoted,False,valid and (quoted or not (List.has c [46,69,101])))) (False,False,True) (Str.codes text);
  ok.
keysMatch : unsafe List String -> List String -> Bool .
keysMatch keys names = case keys of [] -> True | key :: rest -> List.has key names and keysMatch rest names.
target : unsafe Bytes -> String -> {id:String,width:Int,origin:Int,ram:Int,limit:Int,free:Int} .
target manifest selected =
  text = unwrap (Utf8.decode manifest);
  obj = unwrap (J.parse text);
  names = List.map (fn pair -> (name,_) = pair; name) (unwrap (J.fields obj));
  keys = ["schema","target","elf_class_bits","ram_origin","ram_bytes","max_image_bytes","min_free_bytes"];
  _ = require (List.len names == List.len keys and keysMatch keys names) "invalid target manifest fields";
  _ = require (integerTokens text) "target manifest values must be integers";
  intField k = unwrap (J.get k obj |>? J.num);
  _ = require (intField "schema" == 1) "unsupported target manifest schema";
  id = unwrap (J.get "target" obj |>? J.text);
  _ = require (id != "") "missing target identity";
  _ = require (selected == "" or id == selected) "manifest target differs from selected build target";
  width = intField "elf_class_bits";
  _ = require (width == 32 or width == 64) "unsupported target ELF width";
  origin = intField "ram_origin"; ram = intField "ram_bytes";
  limit = intField "max_image_bytes"; free = intField "min_free_bytes";
  _ = require (origin >= 0 and ram > 0 and origin + ram <= 2 ^ width) "invalid target RAM range";
  _ = require (limit > 0 and limit <= ram and free >= 0 and free < ram) "invalid target image/reserve limits";
  {id=id,width=width,origin=origin,ram=ram,limit=limit,free=free}.
header bytes width =
  n = number bytes;
  word = width / 8;
  _ = require (Bytes.len bytes >= 16 and Hex.encode (unwrap (Bytes.slice 0 4 bytes)) == "7f454c46") "not an ELF image";
  _ = require (n 4 1 == word / 4) "ELF width differs from selected target";
  _ = require (n 5 2 == 257) "expected little-endian ELF version 1";
  headerSize = 40 + 3 * word;
  _ = require (Bytes.len bytes >= headerSize) "truncated ELF header";
  _ = require (n 16 2 == 2 and n 18 2 == 243 and n 20 4 == 1) "expected a linked RISC-V executable";
  sizes = 28 + 3 * word;
  _ = require (n sizes 2 == headerSize) "invalid ELF header size";
  phoff = n (24 + word) word; shoff = n (24 + 2 * word) word;
  phsize = n (sizes + 2) 2; phcount = n (sizes + 4) 2;
  shsize = n (sizes + 6) 2; shcount = n (sizes + 8) 2;
  _ = require (phsize == 8 + 6 * word and phcount > 0) "missing/unsupported ELF load table";
  _ = require (phoff >= headerSize and phoff + phcount * phsize <= Bytes.len bytes) "truncated ELF load table";
  _ = require (shsize == 16 + 6 * word and shcount > 0) "missing/unsupported ELF section table";
  _ = require (shoff >= headerSize and shoff + shcount * shsize <= Bytes.len bytes) "truncated ELF section table";
  {word=word,entry=n 24 word,phoff=phoff,shoff=shoff,phsize=phsize,phcount=phcount,shsize=shsize,shcount=shcount}.
powerOfTwo : unsafe Int -> Bool .
powerOfTwo n = if n <= 1 then n == 1 else if n % 2 == 1 then False else powerOfTwo (n / 2).
load : unsafe Bytes -> {word:Int,phoff:Int,phsize:Int | h} -> {origin:Int,ram:Int | t} -> Int -> List {offset:Int,start:Int,files:Int,memory:Int,flags:Int} .
load bytes h contract index =
  pos = h.phoff + index * h.phsize;
  n off size = number bytes (pos + off) size;
  if n 0 4 != 1 then [] else
    w = h.word; offset = n w w; start = n (2 * w) w; physical = n (3 * w) w;
    files = n (4 * w) w; memory = n (5 * w) w;
    flags = n (if w == 4 then 24 else 4) 4; align = n (h.phsize - w) w;
    _ = require (start == physical) "target contract requires identical load/run addresses";
    _ = require (files <= memory and offset + files <= Bytes.len bytes) "invalid ELF load segment";
    _ = require (align <= 1 or (powerOfTwo align and start % align == offset % align)) "invalid ELF load segment alignment";
    _ = require (contract.origin <= start and start + memory <= contract.origin + contract.ram) "load segment {index} lies outside target RAM";
    [{offset=offset,start=start,files=files,memory=memory,flags=flags}].
section bytes h contract loads index =
  pos = h.shoff + index * h.shsize;
  n off width = number bytes (pos + off) width;
  w = h.word; flags = n 8 w; addr = n (8 + w) w;
  offset = n (8 + 2 * w) w; size = n (8 + 3 * w) w; end = addr + size;
  if size == 0 or flags / 2 % 2 == 0 then False else
    _ = require (addr >= contract.origin and end <= contract.origin + contract.ram) "allocated section {index} lies outside target RAM";
    covering = List.filter (fn seg -> seg.start <= addr and end <= seg.start + seg.memory) loads;
    _ = require (covering != []) "allocated section {index} has no load segment";
    if n 4 4 == 8 then False else
      _ = require (offset + size <= Bytes.len bytes) "truncated loadable section {index}";
      backed = List.filter (fn seg -> offset == seg.offset + addr - seg.start and end <= seg.start + seg.files) covering;
      _ = require (backed != []) "allocated section {index} disagrees with its load segment";
      flags / 4 % 2 == 1 and addr <= h.entry and h.entry < end and List.any (fn seg -> seg.flags % 2 == 1) backed.
admit : unsafe Bytes -> Bytes -> String -> J.Json .
admit bytes manifest selected =
  c = target manifest selected;
  h = header bytes c.width;
  loads = List.concat (List.map (load bytes h c) (indices h.phcount));
  # Sweep segments in address order. Empty segments do not reserve any bytes.
  occupied = List.filter (fn seg -> seg.memory > 0) loads;
  ranges = List.fold (fn m seg -> Map.insert seg.start (seg.start + seg.memory) m) Map.ints occupied;
  sorted = Map.entries ranges;
  (_,overlap) = List.fold (fn state span ->
    (previous,clash) = state; (start,end) = span; (end,clash or previous > start)) (c.origin,List.len sorted != List.len occupied) sorted;
  _ = require (not overlap) "overlapping ELF load segments";
  entries = List.map (section bytes h c loads) (indices h.shcount);
  _ = require (List.has True entries) "entry point is outside file-backed executable sections";
  image = List.fold (fn high s -> if s.files > 0 then Numeric.max high (s.start + s.files) else high) c.origin loads - c.origin;
  memory = List.fold (fn high s -> Numeric.max high (s.start + s.memory)) c.origin occupied - c.origin;
  _ = require (image <= c.limit) "image uses {image} bytes, target limit is {c.limit}";
  _ = require (memory + c.free <= c.ram) "static image uses {memory} RAM bytes plus {c.free} reserved, target has {c.ram}";
  J.JObj [("schema",J.JNum 2),("target",J.JStr c.id),("elf_class_bits",J.JNum c.width),
    ("image_sha256",J.JStr (digest bytes)),("manifest_sha256",J.JStr (digest manifest)),
    ("image_bytes",J.JNum image),("image_limit_bytes",J.JNum c.limit),("static_memory_bytes",J.JNum memory),
    ("remaining_ram_bytes",J.JNum (c.ram - memory)),("min_free_bytes",J.JNum c.free)].
