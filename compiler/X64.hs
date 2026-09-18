{-# LANGUAGE LambdaCase #-}

-- X64: rv64 emission -> x86-64 System V (ELF/gas AT&T syntax).
--
-- Same idea as A64.hs -- the rv64 emission is the shared low-level RISC
-- IR -- but x86-64 is the stress test of the claim, because nothing
-- lines up for free.  Four mismatches, four local rules:
--
-- 1. `call` PUSHES the return address; RISC-V's leaves sp alone and
--    fills ra.  Rule: inside every function, IR sp == %rsp + 8, so
--    N(sp) lowers to N+8(%rsp); the prologue's `sd ra, F-8(sp)` then
--    addresses exactly the slot the hardware call already filled and
--    lowers to NOTHING, as does the epilogue's `ld ra, -8(s0)`;
--    `mv sp, rX` (epilogue/tail restore) lowers to lea -8(rX), %rsp,
--    after which a hardware `ret` -- or a tail `jmp` into the next
--    function, which then believes ITS retaddr is at [rsp] -- is
--    correct with no fixup.  Frame layout is bit-identical to rv64.
--
-- 2. SysV wants %rsp == 0 mod 16 at `call` (entry == 8); the IR keeps
--    sp == 0 mod 16 always, so under rule 1 %rsp == 8 everywhere.
--    Rule: `call X` lowers to  sub $8,%rsp ; call X ; add $8,%rsp.
--    Generated frames stay untouched; C sees a conforming stack.
--
-- 3. RISC-V a0 is BOTH arg0 and the return register; SysV splits them
--    (%rdi vs %rax).  Rule: a0 maps to %rax (the value/return role,
--    which is what a0 is 95% of the time), and the arg0 role is two
--    boundary fixups: `mov %rdi,%rax` after every function label,
--    `mov %rax,%rdi` before every call/tail-jmp to a symbol.  a1..a5
--    map straight onto %rsi %rdx %rcx %r8 %r9 -- SysV args 2..6 --
--    so no other argument moves at all.  a6/a7 are SysV STACK args:
--    caller-side staging (`ld a6, slot`) parks the value in a TLS cell
--    (fpr_x64_a6/a7, runtime/posix/main.c) and the next `call` places
--    the parked cells at [rsp]/[rsp+8] under the pushed return address
--    -- exactly where SysV wants args 7 and 8.  Callee-side, a6/a7
--    reads lower to 0(%rbp)/8(%rbp): s0 == the IR entry sp == one word
--    above the return address, which IS the SysV stack-arg base.  Tail
--    calls to arity>6 functions are rejected (they would have to write
--    above a frame already released); codegen never emits them today.
--
-- 4. Three-operand arithmetic on a two-operand ISA, and setcc/shift/
--    idiv register quirks: each lowers through a scratch chosen
--    dynamically from {r10,r11,rsi,rcx} minus the operands (>= 4
--    candidates, <= 3 operands: one is always free), push/popped when
--    it might be live.  RISC-V has no flags, so nothing in the IR is
--    ever live across cmp/test.
--
-- Register map (SysV-compatible where the IR touches C):
--   a0 %rax  a1 %rsi  a2 %rdx  a3 %rcx  a4 %r8  a5 %r9
--   t0 %r10  t1 %r11  t2 %rdi (dead at call boundaries, where the
--                              translator claims %rdi for arg0)
--   s0 %rbp  s1 %rbx  s2 %r12  s3 %r13  s4 %r14  s5 %r15
--   s6..s11: unmapped -- SysV has only 6 callee-saved registers, which
--   is WHY x64 codegen runs with vec-loop specialization disabled
--   (emitProgram's spec flag); the generic C vec path needs none.
--   zero -> $0 / a fixup per use.  tp -> initial-exec TLS load of
--   fpr_posix_hart (multithreaded harts; matches A64.hs).
module X64 (lowerX64, deTlsQosApp, x64Rev) where


import Data.Char (isDigit, isSpace)
import Data.List (isPrefixOf, isSuffixOf, stripPrefix)

-- bump when the lowering changes: folded into the unit-cache tag, so a
-- lowering fix invalidates cached lowered units (learned the hard way:
-- the section-aware fixup fix left stale corrupt prelude units behind)
x64Rev :: Int
x64Rev = 4

-- deTlsQosApp: the QOS-x86_64 (--target=qx64) refinement.  A loaded
-- QOS Portable app image is a fixed-slot ELF with no dynamic loader
-- behind it -- nothing registers a TLS block for it, and its link-time
-- @tpoff constants would index the HOST's %fs TCB at meaningless
-- offsets.  v1 solved this by making the three thread-local cells
-- (fpr_posix_hart, fpr_x64_a6/a7) plain globals -- correct only while
-- one hart meant one writer.  v2 (multi-hart qosp) BORROWS THE HOST'S
-- TLS instead: qosp declares one __thread borrow block
-- {hart, a6, a7} per hart thread and publishes its offset from the
-- thread pointer in the boot record; entry.c stores it in the plain
-- global fpr_g_tlsoff.  The offset is the same in every thread (the
-- executable's static TLS block sits at a fixed displacement from %fs
-- in all of them), so every access rewrites to
--
--   load  SYM     ->  movq fpr_g_tlsoff(%rip), DST
--                     movq %fs:OFF(DST), DST
--   store SYM     ->  pushq SCR
--                     movq fpr_g_tlsoff(%rip), SCR
--                     movq SRC, %fs:OFF(SCR)
--                     popq SCR          (SCR = %r10, or %r11 if SRC is %r10;
--                                        push/pop is transparent to live regs
--                                        and balanced before any call)
--
-- with OFF = 0/8/16 for hart/a6/a7 (the borrow block's layout, pinned
-- by qos_abi.h).  Applied as a textual post-pass over the lowered
-- output; runtime/qosapp compiles the C side with FPR_QOSAPP so its
-- accessors go through the same fpr_g_tlsoff borrow (fpr.h).
deTlsQosApp :: String -> String
deTlsQosApp = unlines . concatMap detls . lines
  where
    detls l = case splitTls l of
      Nothing -> [l]
      Just (pre, sym, post)
        | ", " `isSuffixOf` pre ->
            -- store: "<ind>movq SRC, %fs:SYM@tpoff[ # comment]"
            let ind = takeWhile isSpace pre
                body = dropWhile isSpace pre -- "movq SRC, "
                src = takeWhile (/= ',') (drop 5 body)
                scr = if src == "%r10" then "%r11" else "%r10"
             in [ ind ++ "pushq " ++ scr,
                  ind ++ "movq fpr_g_tlsoff(%rip), " ++ scr,
                  ind ++ "movq " ++ src ++ ", %fs:" ++ tlsOff sym ++ "(" ++ scr ++ ")" ++ post,
                  ind ++ "popq " ++ scr ]
        | otherwise ->
            -- load: "<ind>movq %fs:SYM@tpoff, DST[ # comment]"
            let ind = takeWhile isSpace pre
                after = dropWhile (== ' ') (drop 1 post) -- past ", "
                dst = takeWhile (\c -> c /= ' ' && c /= '#') after
                rest = drop (length dst) after
                tail' = if null rest then "" else " " ++ dropWhile (== ' ') rest
             in [ ind ++ "movq fpr_g_tlsoff(%rip), " ++ dst,
                  ind ++ "movq %fs:" ++ tlsOff sym ++ "(" ++ dst ++ "), " ++ dst ++ tail' ]
    tlsOff "fpr_posix_hart" = "0"
    tlsOff "fpr_x64_a6" = "8"
    tlsOff "fpr_x64_a7" = "16"
    tlsOff s = error ("deTlsQosApp: unexpected TLS symbol " ++ s)
    -- find "%fs:SYM@tpoff" in a line
    splitTls s = case breakOn "%fs:" s of
      Nothing -> Nothing
      Just (pre, after) -> case breakOn "@tpoff" after of
        Nothing -> Nothing
        Just (sym, post) -> Just (pre, sym, post)
    breakOn pat s = go2 "" s
      where
        go2 _ [] = Nothing
        go2 acc t@(c : cs)
          | pat `isPrefixOf` t = Just (reverse acc, drop (length pat) t)
          | otherwise = go2 (c : acc) cs

lowerX64 :: String -> String
lowerX64 = unlines . go (True, (False, False)) . map banner . lines
  where
    banner "# target: rv64" = "# target: x64 (lowered from the rv64 emission -- the shared RISC IR)"
    banner l = l
    -- section-aware scan: the arg0 entry fixup is only injected after
    -- labels in .text -- injecting it after a DATA label splices
    -- instruction bytes into the object and shifts every field.
    -- `staged` tracks a6/a7 values parked in the TLS cells since the
    -- last call/label; the next `call` spills them as stack args.
    go _ [] = []
    go st@(inText, _) (l : ls) =
      let (out, st') = lowerLine st l in out ++ go (nextSect st' l) ls
      where _ = inText
    nextSect (cur, stg) l
      | ".text" `isPrefixOf` dropWhile isSpace l = (True, stg)
      | ".section" `isPrefixOf` dropWhile isSpace l = (False, stg)
      | ".rodata" `isPrefixOf` dropWhile isSpace l = (False, stg)
      | ".data" `isPrefixOf` dropWhile isSpace l = (False, stg)
      | otherwise = (cur, stg)

-- ---- registers -------------------------------------------------------

reg :: String -> String
reg = \case
  "a0" -> "%rax"; "a1" -> "%rsi"; "a2" -> "%rdx"; "a3" -> "%rcx"
  "a4" -> "%r8"; "a5" -> "%r9"
  "t0" -> "%r10"; "t1" -> "%r11"; "t2" -> "%rdi"
  "s0" -> "%rbp"; "s1" -> "%rbx"; "s2" -> "%r12"; "s3" -> "%r13"
  "s4" -> "%r14"; "s5" -> "%r15"
  "ra" -> error "X64: ra outside the prologue/epilogue patterns"
  "sp" -> "%rsp" -- only valid via the mem/mv special cases below
  r@('a' : _) -> error ("X64: " ++ r ++ " -- arity <= 6 on x64 (SysV stack args not lowered yet)")
  r@('s' : _) -> error ("X64: " ++ r ++ " -- spec loops need s6+; build with specs disabled")
  r -> error ("X64: unmapped register " ++ r)

r32 :: String -> String -- the 32-bit name of a mapped register
r32 r = case reg r of
  "%rax" -> "%eax"; "%rsi" -> "%esi"; "%rdx" -> "%edx"; "%rcx" -> "%ecx"
  "%rbx" -> "%ebx"; "%rbp" -> "%ebp"
  x -> x ++ "d" -- %r8..%r15 -> %r8d..
-- a scratch register none of the operands use; caller push/pops it
scratch :: [String] -> String
scratch avoid = head [c | c <- ["%r10", "%r11", "%rsi", "%rcx"], c `notElem` avoid]

-- ---- line dispatch ---------------------------------------------------

type St = (Bool, (Bool, Bool)) -- (in .text, (a6 staged, a7 staged))

lowerLine :: St -> String -> ([String], St)
lowerLine st@(inText, staged) l
  | null (dropWhile isSpace l) = ([l], st)
  | "#" `isPrefixOf` dropWhile isSpace l = ([l], st)
  | not inText = ([l], st) -- data lines pass through verbatim
  | Just body <- stripPrefix "    " l, not (isDirective body) =
      let (out, staged') = instr staged body in (map ind out, (inText, staged'))
  | Just lbl <- funcLabel l =
      ([l, ind ("movq %rdi, %rax # arg0 fixup (" ++ lbl ++ ")")], (inText, (False, False)))
  | otherwise = ([l], st)
  where
    ind s = "    " ++ s
    isDirective ('.' : _) = True
    isDirective _ = False
    -- a code label at column 0 that is not a local .L label: function
    -- entry, and (in .text) the place the SysV arg0 lands in %rdi
    funcLabel s = case break (== ':') s of
      (n@(c : _), ":") | c /= '.', c /= ' ' -> Just n
      _ -> Nothing

parts :: String -> (String, [String])
parts s = case words s of
  (op : rest) -> (op, map trim (splitOn ',' (unwords rest)))
  [] -> ("", [])
  where
    splitOn _ "" = []
    splitOn c t = case break (== c) t of
      (a, []) -> [a]
      (a, _ : b) -> a : splitOn c b
    trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

-- "N(base)" -> lowered AT&T operand under the sp bias rule
mem :: String -> String
mem s = case break (== '(') s of
  (o, '(' : r0) ->
    let b = takeWhile (/= ')') r0
        off = (if null o then 0 else readInt o) + (if b == "sp" then 8 else 0)
        base = if b == "sp" then "%rsp" else reg b
     in (if off == 0 then "" else show off) ++ "(" ++ base ++ ")"
  _ -> error ("X64: bad mem operand " ++ s)

readInt :: String -> Integer
readInt ('-' : d) = negate (read d)
readInt d = read d

imm :: String -> String
imm n = "$" ++ show (readInt n)

-- ---- instruction lowering -------------------------------------------

instr :: (Bool, Bool) -> String -> ([String], (Bool, Bool))
instr staged@(s6, s7) body = case parts body of
  -- ---- a6/a7: SysV stack args via the TLS staging cells ------------
  ("ld", ["a6", m]) -> stage "fpr_x64_a6" (["movq " ++ mem m ++ ", %r11"]) True
  ("ld", ["a7", m]) -> stage "fpr_x64_a7" (["movq " ++ mem m ++ ", %r11"]) False
  ("mv", ["a6", rs]) -> stage "fpr_x64_a6" (["movq " ++ reg rs ++ ", %r11"]) True
  ("mv", ["a7", rs]) -> stage "fpr_x64_a7" (["movq " ++ reg rs ++ ", %r11"]) False
  ("li", ["a6", n]) -> stage "fpr_x64_a6" (["movq " ++ imm n ++ ", %r11"]) True
  ("li", ["a7", n]) -> stage "fpr_x64_a7" (["movq " ++ imm n ++ ", %r11"]) False
  ("la", ["a6", sym]) -> stage "fpr_x64_a6" (["leaq " ++ sym ++ "(%rip), %r11"]) True
  ("la", ["a7", sym]) -> stage "fpr_x64_a7" (["leaq " ++ sym ++ "(%rip), %r11"]) False
  -- callee side: params 7/8 arrive in the same TLS cells the caller
  -- staged them into (calls AND tail jmps pass them through untouched
  -- -- TCO holds for every arity; the prologue reads the cells before
  -- any call this function makes, so nothing can clobber them first)
  ("sd", ["a6", m]) -> plain ["movq %fs:fpr_x64_a6@tpoff, %r11", "movq %r11, " ++ mem m]
  ("sd", ["a7", m]) -> plain ["movq %fs:fpr_x64_a7@tpoff, %r11", "movq %r11, " ++ mem m]
  _ -> (instr0 body, if isCall then (False, False) else staged)
  where
    stage cell load a6p =
      ( load ++ ["movq %r11, %fs:" ++ cell ++ "@tpoff # stage stack arg"],
        if a6p then (True, s7) else (s6, True) )
    plain out = (out, staged)
    isCall = case parts body of
      ("call", _) -> True
      ("j", [lb]) -> not (".L" `isPrefixOf` lb)
      _ -> False

instr0 :: String -> [String]
instr0 body = case parts body of
  -- ra never materializes (rule 1): the hardware call/ret carry it
  ("sd", ["ra", _]) -> ["# (ra store: hardware call already placed it)"]
  ("ld", ["ra", _]) -> ["# (ra load: hardware ret will consume it)"]
  ("sd", [rs, m]) -> ["movq " ++ reg rs ++ ", " ++ mem m]
  ("ld", [rd, m]) -> ["movq " ++ mem m ++ ", " ++ reg rd]
  ("sw", ["zero", m]) -> ["movl $0, " ++ mem m]
  ("sw", [rs, m]) -> ["movl " ++ r32 rs ++ ", " ++ mem m]
  ("lw", [rd, m]) -> ["movslq " ++ mem m ++ ", " ++ reg rd] -- rv lw sign-extends
  -- moves / constants / addresses
  ("mv", [rd, "tp"]) ->
    ["movq %fs:fpr_posix_hart@tpoff, " ++ reg rd] -- initial-exec TLS
  ("mv", [rd, "sp"]) -> ["leaq 8(%rsp), " ++ reg rd] -- rule 1 bias
  ("mv", ["sp", rs]) -> ["leaq -8(" ++ reg rs ++ "), %rsp"] -- epilogue restore
  ("mv", [rd, "zero"]) -> ["movq $0, " ++ reg rd]
  ("mv", [rd, rs]) -> ["movq " ++ reg rs ++ ", " ++ reg rd]
  ("li", [rd, n]) ->
    let v = readInt n
     in if v >= -2147483648 && v <= 2147483647
          then ["movq " ++ imm n ++ ", " ++ reg rd]
          else ["movabsq " ++ imm n ++ ", " ++ reg rd]
  ("la", [rd, sym]) -> ["leaq " ++ sym ++ "(%rip), " ++ reg rd]
  -- sp adjustment (frames/pushes; always 16-multiples)
  ("addi", ["sp", "sp", n]) ->
    let v = readInt n
     in if v < 0 then ["subq $" ++ show (-v) ++ ", %rsp"]
                 else ["addq $" ++ show v ++ ", %rsp"]
  ("addi", [rd, "sp", n]) -> ["leaq " ++ show (readInt n + 8) ++ "(%rsp), " ++ reg rd]
  ("addi", [rd, rs, n])
    | rd == rs -> ["addq " ++ imm n ++ ", " ++ reg rd]
    | otherwise -> ["leaq " ++ show (readInt n) ++ "(" ++ reg rs ++ "), " ++ reg rd]
  -- three-operand arithmetic (rule 4)
  ("add", [rd, r1, r2]) -> arith "addq" rd r1 r2 True
  ("sub", [rd, r1, r2])
    | rd == r2 && rd /= r1 -> ["negq " ++ reg rd, "addq " ++ reg r1 ++ ", " ++ reg rd]
    | otherwise -> arith "subq" rd r1 r2 False
  ("mul", [rd, r1, r2]) -> arith "imulq" rd r1 r2 True
  ("and", [rd, r1, r2]) -> arith "andq" rd r1 r2 True
  ("xor", [rd, r1, r2]) -> arith "xorq" rd r1 r2 True
  ("andi", [rd, rs, n]) -> two "andq" rd rs (imm n)
  ("ori", [rd, rs, n]) -> two "orq" rd rs (imm n)
  ("xori", [rd, rs, n]) -> two "xorq" rd rs (imm n)
  ("slli", [rd, rs, n]) -> two "shlq" rd rs (imm n)
  ("srai", [rd, rs, n]) -> two "sarq" rd rs (imm n)
  ("sll", [rd, r1, r2]) -> shiftReg rd r1 r2
  ("div", [rd, r1, r2]) -> idiv rd r1 r2
  -- comparisons to a register
  ("slt", [rd, r1, r2]) -> setcc rd [r1, r2] "l" ("cmpq " ++ reg r2 ++ ", " ++ reg r1)
  ("seqz", [rd, rs]) -> setcc rd [rs] "e" ("testq " ++ reg rs ++ ", " ++ reg rs)
  ("snez", [rd, rs]) -> setcc rd [rs] "ne" ("testq " ++ reg rs ++ ", " ++ reg rs)
  -- branches (nothing is live across flags in the IR)
  ("beqz", [r, l]) -> ["testq " ++ reg r ++ ", " ++ reg r, "je " ++ l]
  ("bnez", [r, l]) -> ["testq " ++ reg r ++ ", " ++ reg r, "jne " ++ l]
  ("bgtz", [r, l]) -> ["cmpq $0, " ++ reg r, "jg " ++ l]
  ("beq", [r1, r2, l]) -> cmpBr r1 r2 "je" l
  ("bne", [r1, r2, l]) -> cmpBr r1 r2 "jne" l
  ("bgeu", [r1, r2, l]) -> cmpBr r1 r2 "jae" l
  ("bltu", [r1, r2, l]) -> cmpBr r1 r2 "jb" l
  -- control transfer (rules 2 and 3)
  ("call", [sym]) ->
    [ "movq %rax, %rdi # arg0 fixup",
      "subq $8, %rsp # SysV call alignment",
      "call " ++ sym,
      "addq $8, %rsp" ]
  ("j", [l])
    | ".L" `isPrefixOf` l -> ["jmp " ++ l] -- local branch
    | otherwise -> ["movq %rax, %rdi # arg0 fixup (tail)", "jmp " ++ l] -- tail call
  ("ret", []) -> ["ret"]
  (op, _) -> error ("X64: cannot lower `" ++ body ++ "` (op " ++ op ++ ")")
  where
    cmpBr r1 r2 j l = ["cmpq " ++ reg r2 ++ ", " ++ reg r1, j ++ " " ++ l]
    two op rd rs src
      | rd == rs = [op ++ " " ++ src ++ ", " ++ reg rd]
      | otherwise = ["movq " ++ reg rs ++ ", " ++ reg rd, op ++ " " ++ src ++ ", " ++ reg rd]
    -- rd := r1 OP r2 on a two-operand ISA; commut says r1/r2 swappable
    arith op rd r1 r2 commut
      | rd == r1 = [op ++ " " ++ reg r2 ++ ", " ++ reg rd]
      | rd == r2 && commut = [op ++ " " ++ reg r1 ++ ", " ++ reg rd]
      | rd == r2 =
          let s = scratch (map reg [rd, r1, r2])
           in [ "pushq " ++ s, "movq " ++ reg r1 ++ ", " ++ s,
                op ++ " " ++ reg r2 ++ ", " ++ s,
                "movq " ++ s ++ ", " ++ reg rd, "popq " ++ s ]
      | otherwise = ["movq " ++ reg r1 ++ ", " ++ reg rd, op ++ " " ++ reg r2 ++ ", " ++ reg rd]
    -- rd := (cond of cmp) ? 1 : 0.  The scratch must avoid rd AND the
    -- compared registers (movq $0 runs before the cmp), and movq does
    -- not touch flags, so zeroing-before-setcc is safe.
    setcc rd ops cc cmp =
      let s = scratch (map reg (rd : ops))
       in [ "pushq " ++ s, "movq $0, " ++ s, cmp,
            "set" ++ cc ++ " " ++ b8 s,
            "movq " ++ s ++ ", " ++ reg rd, "popq " ++ s ]
    b8 "%r10" = "%r10b"
    b8 "%r11" = "%r11b"
    b8 "%rsi" = "%sil"
    b8 "%rcx" = "%cl"
    b8 x = error ("X64: no byte name for " ++ x)
    -- rd := r1 << r2 (count must live in %cl).  Capture-first: both
    -- operands are read before anything is clobbered, so any aliasing
    -- among rd/r1/r2/%rcx/%r11 is safe.  %r11 (t1) is written: the IR
    -- never keeps a t-reg live across a lowered op's expansion.
    shiftReg rd r1 r2 =
      [ "pushq %rcx",
        "pushq " ++ reg r1, -- r1's value (r1 == %rcx still original: pushed above)
        "movq " ++ reg r2 ++ ", %rcx", -- count (r2 == %rcx: self-move, still original)
        "movq (%rsp), %r11",
        "shlq %cl, %r11",
        "addq $8, %rsp",
        "popq %rcx",
        "movq %r11, " ++ reg rd ] -- after the pop: rd == %rcx lands correctly
    -- rd := r1 / r2 signed.  Same capture-first shape; idivq takes a
    -- memory divisor, which sidesteps every register-aliasing case.
    idiv rd r1 r2 =
      [ "pushq %rax", "pushq %rdx",
        "pushq " ++ reg r1, -- captured before rax/rdx are clobbered? both
        "pushq " ++ reg r2, -- still hold originals: only pushes so far
        "movq 8(%rsp), %rax",
        "cqto",
        "idivq (%rsp)",
        "movq %rax, %r11", -- quotient parked (t1: never live across div)
        "addq $16, %rsp",
        "popq %rdx", "popq %rax",
        "movq %r11, " ++ reg rd ] -- last: rd == rax/rdx overwrites the restore, correctly
