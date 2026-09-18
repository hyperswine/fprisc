{-# LANGUAGE LambdaCase #-}

-- A64: rv64 emission -> AArch64 (ELF/gas syntax).
--
-- The PoC of the "shared low-level RISC IR" idea: Codegen.hs's rv64
-- output IS the IR.  It only ever uses a ~20-mnemonic, 8-register,
-- flags-free, direct-control-flow subset of RISC-V (no jalr, no CSRs
-- outside --rvv, frames always 16-aligned), and that subset maps 1:1
-- onto AArch64 under a register assignment that happens to agree with
-- AAPCS64 exactly where the RISC-V ABI agrees with it:
--
--   a0..a7 -> x0..x7      (args/results: identical in both ABIs)
--   t0 t1 t2 t6 -> x9 x10 x11 x12   (caller-saved temps)
--   s0 -> x29 (fp)        s1..s9 -> x19..x27 (callee-saved)
--   ra -> x30  sp -> sp  zero -> xzr
--   tp -> (no free per-thread register on hosted AArch64: tpidr_el0
--          belongs to libc TLS)  `mv RD, tp` therefore lowers to a
--          local-exec TLS load of fpr_posix_hart (__thread: one per
--          hart pthread), which runtime/posix maintains where bare
--          metal maintains tp.  This is the one
--          place the translation knows it is targeting the posix HAL.
--
-- Because both ABIs agree on x0..x7/caller-saved/callee-saved for the
-- registers we use, translated FPRISC code calls the C runtime (and is
-- called back through fpr_apply's casts) with no shims at all.
--
-- Flags: RISC-V has none, so nothing in the IR is live across a `cmp`;
-- lowering branches/slt/seqz/snez through NZCV is always safe.
-- x16/x17 (IP0/IP1) are scratch strictly within one lowered
-- instruction, which is exactly their AAPCS role.
--
-- macOS/Mach-O IS the promised syntax layer over this same pass
-- (lowerA64 True): same instructions, four differences --
--
--   * adrp/:lo12: becomes adrp _sym@PAGE / add _sym@PAGEOFF, and every
--     C-visible symbol (definitions, .globl, call/la/.quad references)
--     grows the leading underscore; .L local labels become L (the
--     Mach-O assembler-private prefix)
--   * .section .rodata becomes __DATA,__const -- NOT __TEXT,__const: the
--     rodata section holds .quad relocations to code symbols (e.g. the
--     per-shape dispatch tables), and a PIE binary's dyld fixes those
--     up at load time. ld64 refuses to emit such a fixup into __TEXT
--     ("illegal text-relocation"; W^X/hardened-runtime pages can't be
--     patched post-link), so the data has to live in __DATA instead.
--   * big immediates are movz/movk chains on BOTH syntaxes now (the
--     ldr =imm literal pool + .ltorg pseudo was ELF-gas-only; the chain
--     is portable and the ELF suite regression-tests the encoding)
--   * `mv rd, tp` cannot be a local-exec :tprel: load -- Darwin TLS is
--     TLV descriptors.  The lowering emits the standard Darwin
--     sequence (adrp/ldr the descriptor, blr through its thunk), which
--     the dyld contract makes safe mid-function: _tlv_get_addr
--     preserves every register except x0, x16, x17.  x0 (arg0, live at
--     the function-entry fuel tick) and x30 (ra, live everywhere) are
--     saved around it; x17 stashes the loaded hart pointer across the
--     restore.  The C side's __thread cell uses the same TLV machinery,
--     so both sides agree by construction.
module A64 (lowerA64, deTlsQosAppA64, a64Rev) where


import Data.Bits (shiftR, (.&.))
import Data.Char (isDigit, isSpace)
import Data.List (isPrefixOf, stripPrefix)
import Data.Word (Word64)

-- bump when the lowering changes (unit-cache tag component; see X64.hs)
a64Rev :: Int
a64Rev = 10 -- scalar F32/F64 lowering for qa64

lowerA64 :: Bool -> String -> String
lowerA64 mach =
  post . unlines . concatMap (lowerLine mach) . map banner . lines
  where
    banner "# target: rv64"
      | mach = "# target: a64mac (lowered from the rv64 emission; Mach-O syntax)"
      | otherwise = "# target: a64 (lowered from the rv64 emission -- the shared RISC IR)"
    banner l = l
    -- .L -> L: Mach-O's assembler-private label prefix.  Safe as a text
    -- pass: the emission holds no quoted strings (string data is .byte
    -- lists), so ".L" occurs only as a label prefix (and in comments,
    -- where the rename is harmless).
    post = if mach then replaceAll ".L" "L" else id

replaceAll :: String -> String -> String -> String
replaceAll from to = go
  where
    go s = case breakOn s of
      Nothing -> s
      Just (pre, rest) -> pre ++ to ++ go rest
    breakOn s = bo "" s
    bo _ [] = Nothing
    bo acc r@(c : cs)
      | from `isPrefixOf` r = Just (reverse acc, drop (length from) r)
      | otherwise = bo (c : acc) cs

-- ---- registers -------------------------------------------------------

xreg :: String -> String
xreg = \case
  "zero" -> "xzr"
  "ra" -> "x30"
  "sp" -> "sp"
  "s0" -> "x29"
  "t0" -> "x9"; "t1" -> "x10"; "t2" -> "x11"; "t6" -> "x12"
  'a' : d | [c] <- d, isDigit c -> 'x' : d
  's' : d | Just n <- num d, n >= 1, n <= 9 -> "x" ++ show (18 + n)
  r -> error ("A64: unmapped register " ++ r)
  where num d = if all isDigit d && not (null d) then Just (read d :: Int) else Nothing

wreg :: String -> String
wreg r = case xreg r of
  "xzr" -> "wzr"
  'x' : n -> 'w' : n
  other -> error ("A64: no w-form for " ++ other)

-- ---- line dispatch ---------------------------------------------------

lowerLine :: Bool -> String -> [String]
lowerLine mach l
  | null (dropWhile isSpace l) = [l]
  | "#" `isPrefixOf` dropWhile isSpace l = [l] -- comments pass through
  | Just body <- stripPrefix "    " l, not (isDirective body) = map ind (instr mach body)
  | mach = [macLine l] -- labels, directives, .quad data: Mach-O spellings
  | otherwise = [l] -- labels, directives, .byte data: identical on a64
  where
    ind s = "    " ++ s
    isDirective ('.' : _) = True
    isDirective _ = False

-- the underscore a C-visible symbol grows on Mach-O (.L locals exempt;
-- the post pass renames those to the L private prefix)
gsym :: Bool -> String -> String
gsym mach s
  | mach, not (".L" `isPrefixOf` s) = '_' : s
  | otherwise = s

-- non-instruction lines under Mach-O: label definitions and the three
-- symbol-bearing directives; everything else passes through
macLine :: String -> String
macLine l
  | Just rest <- stripPrefix "    .globl " l =
      "    .globl " ++ mapSyms rest
  | Just rest <- stripPrefix "    .quad " l,
    (c : _) <- dropWhile isSpace rest,
    not (isDigit c),
    c /= '-' =
      "    .quad " ++ gsym True (trim rest)
  | "    .section .rodata" `isPrefixOf` l = "    .section __DATA,__const"
  | (name, ':' : rest) <- break (== ':') l,
    not (null name),
    all (not . isSpace) name,
    not ("." `isPrefixOf` name) || ".L" `isPrefixOf` name =
      gsym True name ++ ":" ++ rest
  | otherwise = l
  where
    trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse
    mapSyms = intercalate1 ", " . map (gsym True . trim) . splitC
    splitC t = case break (== ',') t of
      (x, []) -> [x]
      (x, _ : r) -> x : splitC r
    intercalate1 sep = foldr1 (\x acc -> x ++ sep ++ acc)

-- split "op a, b, c" -> (op, [a,b,c]); memory operands "N(reg)" kept whole
parts :: String -> (String, [String])
parts s = case words s of
  (op : rest) -> (op, splitOps (unwords rest))
  [] -> ("", [])
  where
    splitOps "" = []
    splitOps t = map trim (splitOn ',' t)
    splitOn c t = case break (== c) t of
      (a, []) -> [a]
      (a, _ : b) -> a : splitOn c b
    trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

mem :: String -> (Integer, String) -- "N(reg)" -> (offset, base)
mem s = case break (== '(') s of
  (o, '(' : r) -> (readInt (if null o then "0" else o), xreg (takeWhile (/= ')') r))
  _ -> error ("A64: bad mem operand " ++ s)

readInt :: String -> Integer
readInt ('-' : d) = negate (read d)
readInt d = read d

-- ---- loads/stores ----------------------------------------------------
-- 64-bit: ldr/str (scaled, off in [0,32760] step 8) or ldur/stur
-- ([-256,255]); otherwise materialize base+off in x16.
-- 32-bit: lw sign-extends on RISC-V, so ldrsw; sw -> str wN.

ldst64 :: String -> String -> String -> String -> [String]
ldst64 opU opS rm rd = withOff rm 8 opS opU rd

ld32 :: String -> String -> [String] -- lw rd, off(rb): sign-extending
ld32 rd rm =
  let (off, rb) = mem rm; xd = xreg rd
   in if off >= -256 && off <= 255
        then ["ldursw " ++ xd ++ ", [" ++ rb ++ ", #" ++ show off ++ "]"]
        else if off >= 0 && off `mod` 4 == 0 && off <= 16380
          then ["ldrsw " ++ xd ++ ", [" ++ rb ++ ", #" ++ show off ++ "]"]
          else farBase rb off ++ ["ldrsw " ++ xd ++ ", [x16]"]

st32 :: String -> String -> [String]
st32 rs rm =
  let (off, rb) = mem rm; ws = wreg rs
   in if off >= -256 && off <= 255
        then ["stur " ++ ws ++ ", [" ++ rb ++ ", #" ++ show off ++ "]"]
        else if off >= 0 && off `mod` 4 == 0 && off <= 16380
          then ["str " ++ ws ++ ", [" ++ rb ++ ", #" ++ show off ++ "]"]
          else farBase rb off ++ ["str " ++ ws ++ ", [x16]"]

withOff :: String -> Integer -> String -> String -> (String -> [String])
withOff rm step opScaled opUnscaled = \rd ->
  let (off, rb) = mem rm; xd = xreg rd
   in if off >= -256 && off <= 255
        then [opUnscaled ++ " " ++ xd ++ ", [" ++ rb ++ ", #" ++ show off ++ "]"]
        else if off >= 0 && off `mod` step == 0 && off <= 4095 * step
          then [opScaled ++ " " ++ xd ++ ", [" ++ rb ++ ", #" ++ show off ++ "]"]
          else farBase rb off ++ [opScaled ++ " " ++ xd ++ ", [x16]"]

farBase :: String -> Integer -> [String]
farBase rb off = movImm "x16" off ++ ["add x16, " ++ rb ++ ", x16"]

-- ---- immediates ------------------------------------------------------

movImm :: String -> Integer -> [String]
movImm xd n
  | n >= -65535 && n <= 65535 = ["mov " ++ xd ++ ", #" ++ show n] -- movz/movn territory
  | otherwise = -- movz/movk chain: portable across gas-ELF and Mach-O
      let w = fromIntegral n :: Word64
          hws = [(w `shiftR` s) .&. 0xffff | s <- [0, 16, 32, 48]]
       in ("movz " ++ xd ++ ", #" ++ show (head hws))
            : [ "movk " ++ xd ++ ", #" ++ show h ++ ", lsl #" ++ show s
                | (h, s) <- zip (tail hws) [16 :: Int, 32, 48],
                  h /= 0
              ]

addImm :: String -> String -> Integer -> [String]
addImm xd xs n
  | n >= 0 && n < 4096 = ["add " ++ xd ++ ", " ++ xs ++ ", #" ++ show n]
  | n < 0 && (-n) < 4096 = ["sub " ++ xd ++ ", " ++ xs ++ ", #" ++ show (-n)]
  | otherwise = movImm "x16" n ++ ["add " ++ xd ++ ", " ++ xs ++ ", x16"]

-- ---- instruction lowering -------------------------------------------

instr :: Bool -> String -> [String]
instr mach body = case parts body of
  -- loads/stores (rv64 words)
  ("ld", [rd, rm]) -> ldst64 "ldur" "ldr" rm rd
  ("sd", [rs, rm]) -> ldst64 "stur" "str" rm rs
  ("lw", [rd, rm]) -> ld32 rd rm
  ("sw", [rs, rm]) -> st32 rs rm
  -- moves / constants / addresses
  ("mv", [rd, "tp"])
    | mach ->
        let xd = xreg rd
         in [ -- Darwin TLV: dyld's _tlv_get_addr preserves all registers
              -- except x0/x16/x17 (the contract that lets compilers drop
              -- this sequence mid-function).  x0 = arg0 and x30 = ra are
              -- live at the entry fuel tick, so both are saved; x17
              -- carries the loaded hart pointer across the restore.
              "sub sp, sp, #16",
              "stp x0, x30, [sp]",
              "adrp x0, _fpr_posix_hart@TLVPPAGE",
              "ldr x0, [x0, _fpr_posix_hart@TLVPPAGEOFF]",
              "ldr x16, [x0]",
              "blr x16",
              "ldr x17, [x0]",
              "ldp x0, x30, [sp]",
              "add sp, sp, #16",
              "mov " ++ xd ++ ", x17" ]
    | otherwise ->
        let xd = xreg rd
         in [ -- local-exec TLS: fpr_posix_hart is __thread (one per hart
              -- pthread), matching X64.hs's %fs load; static-link only,
              -- which is the whole posix philosophy anyway
              "mrs " ++ xd ++ ", tpidr_el0",
              "add " ++ xd ++ ", " ++ xd ++ ", :tprel_hi12:fpr_posix_hart",
              "add " ++ xd ++ ", " ++ xd ++ ", :tprel_lo12_nc:fpr_posix_hart",
              "ldr " ++ xd ++ ", [" ++ xd ++ "]" ]
  ("mv", [rd, rs]) -> ["mov " ++ xreg rd ++ ", " ++ xreg rs]
  ("li", [rd, n]) -> movImm (xreg rd) (readInt n)
  ("la", [rd, sym])
    | mach ->
        let xd = xreg rd
            s = gsym True sym
         in ["adrp " ++ xd ++ ", " ++ s ++ "@PAGE", "add " ++ xd ++ ", " ++ xd ++ ", " ++ s ++ "@PAGEOFF"]
    | otherwise ->
        let xd = xreg rd
         in ["adrp " ++ xd ++ ", " ++ sym, "add " ++ xd ++ ", " ++ xd ++ ", :lo12:" ++ sym]
  -- arithmetic / logic
  ("addi", [rd, rs, n]) -> addImm (xreg rd) (xreg rs) (readInt n)
  ("add", [rd, r1, r2]) -> [rrr "add" rd r1 r2]
  ("sub", [rd, r1, r2]) -> [rrr "sub" rd r1 r2]
  ("mul", [rd, r1, r2]) -> [rrr "mul" rd r1 r2]
  ("div", [rd, r1, r2]) -> [rrr "sdiv" rd r1 r2]
  ("and", [rd, r1, r2]) -> [rrr "and" rd r1 r2]
  ("xor", [rd, r1, r2]) -> [rrr "eor" rd r1 r2]
  ("andi", [rd, rs, n]) -> logImm "and" rd rs n
  ("ori", [rd, rs, n]) -> logImm "orr" rd rs n
  ("xori", [rd, rs, n]) -> logImm "eor" rd rs n
  ("slli", [rd, rs, n]) -> ["lsl " ++ xreg rd ++ ", " ++ xreg rs ++ ", #" ++ n]
  ("srai", [rd, rs, n]) -> ["asr " ++ xreg rd ++ ", " ++ xreg rs ++ ", #" ++ n]
  ("sll", [rd, r1, r2]) -> [rrr "lsl" rd r1 r2]
  -- scalar floats travel through the integer ABI as raw bits
  ("fmv.d.x", [fd, rs]) -> ["fmov " ++ freg "d" fd ++ ", " ++ xreg rs]
  ("fmv.x.d", [rd, fs]) -> ["fmov " ++ xreg rd ++ ", " ++ freg "d" fs]
  ("fmv.w.x", [fd, rs]) -> ["fmov " ++ freg "s" fd ++ ", " ++ wreg rs]
  ("fmv.x.w", [rd, fs]) -> ["fmov " ++ wreg rd ++ ", " ++ freg "s" fs]
  (op, [fd, f1, f2])
    | Just (aop, width) <- floatBin op ->
        [aop ++ " " ++ freg width fd ++ ", " ++ freg width f1 ++ ", " ++ freg width f2]
  (op, [rd, f1, f2])
    | Just (cond, width) <- floatCmp op ->
        ["fcmp " ++ freg width f1 ++ ", " ++ freg width f2, "cset " ++ xreg rd ++ ", " ++ cond]
  -- comparisons materialized to a register (flags dead outside each)
  ("slt", [rd, r1, r2]) -> cmpSet rd r1 r2 "lt"
  ("seqz", [rd, rs]) -> ["cmp " ++ xreg rs ++ ", #0", "cset " ++ xreg rd ++ ", eq"]
  ("snez", [rd, rs]) -> ["cmp " ++ xreg rs ++ ", #0", "cset " ++ xreg rd ++ ", ne"]
  -- branches
  ("beqz", [r, l]) -> ["cbz " ++ xreg r ++ ", " ++ l]
  ("bnez", [r, l]) -> ["cbnz " ++ xreg r ++ ", " ++ l]
  ("bgtz", [r, l]) -> ["cmp " ++ xreg r ++ ", #0", "b.gt " ++ l]
  ("beq", [r1, r2, l]) -> cmpBr r1 r2 "b.eq" l
  ("bne", [r1, r2, l]) -> cmpBr r1 r2 "b.ne" l
  ("bgeu", [r1, r2, l]) -> cmpBr r1 r2 "b.hs" l
  ("bltu", [r1, r2, l]) -> cmpBr r1 r2 "b.lo" l
  -- control transfer
  ("call", [sym]) -> ["bl " ++ gsym mach sym]
  -- `j` is used both for intra-function local branches (.L-prefixed
  -- labels) and for tail calls to global function symbols (see
  -- Codegen.hs's knownCall): gsym only adds the underscore in the
  -- latter case, so this must go through it exactly like `call` does.
  ("j", [l]) -> ["b " ++ gsym mach l]
  ("ret", []) -> ["ret"] -- no literal pools since the movz/movk change
  (op, _) -> error ("A64: cannot lower `" ++ body ++ "` (op " ++ op ++ ")")
  where
    rrr op rd r1 r2 = op ++ " " ++ xreg rd ++ ", " ++ xreg r1 ++ ", " ++ xreg r2
    cmpBr r1 r2 b l = ["cmp " ++ xreg r1 ++ ", " ++ xreg r2, b ++ " " ++ l]
    cmpSet rd r1 r2 cond =
      ["cmp " ++ xreg r1 ++ ", " ++ xreg r2, "cset " ++ xreg rd ++ ", " ++ cond]
    freg width = \case
      'f' : 't' : n | all isDigit n -> width ++ n
      r -> error ("A64: unmapped float register " ++ r)
    floatBin op = case break (== '.') op of
      ("fadd", ".d") -> Just ("fadd", "d")
      ("fsub", ".d") -> Just ("fsub", "d")
      ("fmul", ".d") -> Just ("fmul", "d")
      ("fdiv", ".d") -> Just ("fdiv", "d")
      ("fadd", ".s") -> Just ("fadd", "s")
      ("fsub", ".s") -> Just ("fsub", "s")
      ("fmul", ".s") -> Just ("fmul", "s")
      ("fdiv", ".s") -> Just ("fdiv", "s")
      _ -> Nothing
    floatCmp op = case break (== '.') op of
      ("flt", ".d") -> Just ("mi", "d")
      ("fle", ".d") -> Just ("ls", "d")
      ("feq", ".d") -> Just ("eq", "d")
      ("flt", ".s") -> Just ("mi", "s")
      ("fle", ".s") -> Just ("ls", "s")
      ("feq", ".s") -> Just ("eq", "s")
      _ -> Nothing
    -- a64 logical immediates are bitmask-encoded; sidestep the encoder
    -- entirely by materializing (the IR only uses small masks anyway)
    logImm op rd rs n =
      movImm "x16" (readInt n) ++ [op ++ " " ++ xreg rd ++ ", " ++ xreg rs ++ ", x16"]

-- deTlsQosAppA64: the QOS-aarch64 (--target=qa64 / qa64mac) refinement.
-- Same problem as X64.hs deTlsQosApp (see the v2 essay there): a
-- loaded QOS Portable app is fixed-slot with no TLS block registered
-- by a dynamic loader, so its :tprel_* constants are meaningless.
-- v2 borrowed the HOST's static TLS (a thread-pointer displacement in
-- the boot record) -- which is a LINUX assumption: Darwin's TLV model
-- has no stable displacement from the thread pointer.
-- v3 removes TLS from the picture entirely: x28 IS the hosted world's
-- tp.  The IR register map uses x19..x27 (s1..s9) + x29 only, so x28
-- is free; ctx_a64.S no longer saves or restores it, making it
-- per-HART-invariant across actor switches and cross-hart migration
-- (exactly bare metal's tp discipline: set once per hart, never a
-- per-context value); app-side C is compiled -ffixed-x28 and reads it
-- as a global register variable (fpr.h).  The 4-instruction TLS
-- sequence (10 lines on Mach-O) becomes ONE mov -- cheaper than what
-- it replaces, zero symbols, zero platform assumptions.
deTlsQosAppA64 :: Bool -> Bool -> String -> String
deTlsQosAppA64 mach single = unlines . go . lines
  where
    go [] = []
    go (l:ls)
      | Just (pre, xd, consumed) <- matchTls (l:ls) =
          -- v3: x28 is the hart register (set by fpr_set_tp on each
          -- hart's thread, untouched by ctx switches).
          let rest = drop (consumed - 1) ls
              global = [pre ++ "adrp " ++ xd ++ ", fpr_posix_hart",
                        pre ++ "ldr  " ++ xd ++ ", [" ++ xd ++ ", #:lo12:fpr_posix_hart]"]
          in (if single then global else [pre ++ "mov  " ++ xd ++ ", x28"]) ++ go rest
      | otherwise = fixBanner l : go ls

    matchTls xs
      | mach = do
          (pre, xd) <- matchTlsMach10 xs
          pure (pre, xd, 10)
      | otherwise = do
          (pre, xd) <- matchTls4 xs
          pure (pre, xd, 4)

    -- Detect the exact 4-line tpidr sequence emitted by lowerA64 (non-mach)
    -- for "mv rd, tp".  Returns (indent, reg) if matched.
    matchTls4 (l1:l2:l3:l4:_)
      | Just (pre, xd) <- isMrsTpidr l1,
        isAddTprel xd l2 "hi12",
        isAddTprel xd l3 "lo12_nc",
        isLdrSelf xd l4 =
          Just (pre, xd)
    matchTls4 _ = Nothing

    matchTlsMach10 (l1:l2:l3:l4:l5:l6:l7:l8:l9:l10:_)
      | trim l1 == "sub sp, sp, #16",
        trim l2 == "stp x0, x30, [sp]",
        trim l3 == "adrp x0, _fpr_posix_hart@TLVPPAGE",
        trim l4 == "ldr x0, [x0, _fpr_posix_hart@TLVPPAGEOFF]",
        trim l5 == "ldr x16, [x0]",
        trim l6 == "blr x16",
        trim l7 == "ldr x17, [x0]",
        trim l8 == "ldp x0, x30, [sp]",
        trim l9 == "add sp, sp, #16",
        ["mov", xd, "x17"] <- words (trim l10) =
          Just (takeWhile isSpace l1, stripComma xd)
    matchTlsMach10 _ = Nothing

    -- token helpers: the emitted asm has "xN," (with comma attached to reg)
    stripComma t = takeWhile (/= ',') t
    trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse
    isMrsTpidr s =
      let (pre, r) = break (not . isSpace) s
          ws = words r
      in case ws of
           ["mrs", xd, "tpidr_el0"] -> Just (pre, stripComma xd)
           _ -> Nothing
    isAddTprel xd s kind =
      let ws = words (dropWhile isSpace s)
      in case ws of
           ["add", d, base, off] | stripComma d == xd && stripComma base == xd && (":tprel_" ++ kind ++ ":fpr_posix_hart") `isSuffixOf` off -> True
           _ -> False
    isLdrSelf xd s =
      let ws = words (dropWhile isSpace s)
      in case ws of
           ["ldr", d, mem] | stripComma d == xd && mem == "[" ++ xd ++ "]" -> True
           _ -> False

    isSuffixOf suf s = reverse suf `isPrefixOf` reverse s

    fixBanner "# target: rv64" = "# target: qa64 (lowered from the rv64 emission; QOS Portable single-hart globals)"
    fixBanner "# target: a64 (lowered from the rv64 emission -- the shared RISC IR)" =
      "# target: qa64 (lowered from the rv64 emission; QOS Portable single-hart globals)"
    fixBanner l = l
