{-# LANGUAGE LambdaCase #-}
-- Direct x86-64 selection from typed scalar IR. No shared-RISC assembly is
-- generated or parsed here. Selection exposes two-address ties, fixed
-- division registers, argument cells and call clobbers to shared placement.
-- M3 allocates registers (Codegen.Allocate): rbx and r12..r15, the set the
-- context switch (ctx_x64.S) preserves, for values live across a call, the
-- SysV caller-saved registers for the rest, r10/r11 as the reload and
-- copy-cycle scratch; the budget registers a function uses are saved in
-- the prologue and restored before every return and tail transfer.
-- ABI: SysV first six arguments, private TLS cells seven/eight, result rax;
-- legacy frame pointer = entry rsp + 8, return address fp-8, saved rbp fp-16.
-- Parameters are parked before any entry check/tick, and rsp is restored
-- from rbp at exit so stack-segment growth remains compatible with legacy.
module Codegen.Target.X64
  ( X64Config (..), x64SelectionRev, emitFnX64, x64RegisterFile, placement, allocConfig ) where

import Codegen.Allocate
import Codegen.Bounds (Flow (..), Report (..), Tok (..), analyse, reportLine)
import Codegen.Frame
import Codegen.IR
import Codegen.Place
import Codegen.Policy
import Codegen.Selected
import Codegen.Target.Common
import Control.Monad (forM_, unless, when)
import Control.Monad.State.Strict
import Data.List (intercalate, stripPrefix)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

x64SelectionRev :: Int
x64SelectionRev = 15 -- typed column memory and kernel arithmetic; prior: 14: posix modules reach external symbols through the GOT; 13: units with no legacy code skip translation; 12: in-place constructor reuse; 11: inline F64 arithmetic and comparisons, kernel calls by symbol; prior 10: aggregate and string selection; prior: the merge (6, then 7: store.spill never overwrites its own value; 8: a tied destination never takes a fixed operand's register): M3's allocation (2) with coverage's widened selection (5); parameters 9.. arrive by load.spill

data X64Config = X64Config
  { cfgPolicy :: Policy, cfgExports :: S.Set String, cfgWeak :: Bool,
    cfgSelfLoops :: Bool, -- M3: self tail calls as loops (FPR_TYPED_IR_SELF_LOOPS, on unless 0)
    cfgForwardParams :: Bool,
    cfgTune :: Tune
  }

r :: String -> Phys
r = Phys

x64RegisterFile :: RegisterFile
x64RegisterFile = RegisterFile classOf (map r ["rsp", "rbp", "r10", "r11"])
  where
    classOf (Phys p)
      | p `elem` ["rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rsp", "rbp"]
          ++ ["r" ++ show n | n <- [8 :: Int .. 15]] = Just GPR
      | p `elem` ["xmm" ++ show n | n <- [0 :: Int .. 15]] = Just FPR
      | otherwise = Nothing

callerSaved, argRegs, scratchPool, calleeBudget, callerPool, allocScratch :: [Phys]
callerSaved = map r ["rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11"]
argRegs = map r ["rdi", "rsi", "rdx", "rcx", "r8", "r9"]
scratchPool = map r ["r8", "r9", "rsi", "rdi", "rcx", "rax", "rdx"]
-- M3: the budget (docs/2026-10-19-REGISTER-ALLOCATION.md 3.3: s1..s5, what
-- ctx_x64.S saves), the caller-saved pool, and the never-allocated scratch
-- (r10 and r11 are the expansions' own scratch inside the entry sequence
-- and the epilogue; between instructions they are free)
calleeBudget = map r ["rbx", "r12", "r13", "r14", "r15"]
callerPool = map r ["rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9"]
allocScratch = map r ["r10", "r11"]

-- ---- selection state ---------------------------------------------------

data Sel = Sel
  { selNext :: Int, -- next virtual register
    selLabel :: Int,
    selItems :: [Item], -- reversed
    selManaged :: S.Set VReg, -- virtual registers that hold tagged words
    selNullaries :: S.Set (Int, Int),
    selStrings :: S.Set String -- the string literals the function names
  }

type Se = StateT Sel (Either String)

refuse :: String -> Se a
refuse = lift . Left

emitI :: SInstr -> Se ()
emitI i = modify (\s -> s {selItems = I i : selItems s})

emitL :: Label -> Se ()
emitL l = modify (\s -> s {selItems = ILabel l : selItems s})

freshV :: Bool -> Se VReg
freshV managed = do
  n <- gets selNext
  modify (\s -> s {selNext = n + 1, selManaged = if managed then S.insert (VReg n) (selManaged s) else selManaged s})
  pure (VReg n)

freshL :: String -> Se Label
freshL base = do
  n <- gets selLabel
  modify (\s -> s {selLabel = n + 1})
  pure (Label (base ++ show n))

vreg :: VId -> VReg
vreg (VId n) = VReg n

blockLabel :: BId -> Label
blockLabel (BId n) = Label ("b" ++ show n)

-- ---- selected x86 forms ------------------------------------------------
any' :: VReg -> Operand
any' v = OV v (Any GPR)
fix :: VReg -> Phys -> Operand
fix v p = OV v (Fix p)
mov :: VReg -> VReg -> SInstr
mov d s = plain "movq" [any' d] [any' s]
li :: VReg -> Integer -> SInstr
li d n = plain "li" [any' d] [OI n]
la :: VReg -> String -> SInstr
la d s = plain "la" [any' d] [OS s]

-- A two-address result occupies the first source's register, after loading
-- that source from its home. Its home is unchanged (no destructive IR use).
rrr :: String -> VReg -> VReg -> VReg -> SInstr
rrr op d a b = (plain op [OV d (Tied 0)] [any' a, any' b]) {siFlags = FlagsDef}
rri :: String -> VReg -> VReg -> Integer -> SInstr
rri op d s n = (plain op [OV d (Tied 0)] [any' s, OI n]) {siFlags = FlagsDef}
ldrsw :: VReg -> VReg -> Integer -> SInstr
ldrsw d s off = plain "movslq" [any' d] [any' s, OI off]
cmp :: VReg -> VReg -> SInstr
cmp a b = (plain "cmpq" [] [any' a, any' b]) {siFlags = FlagsDef}
cmpi :: VReg -> Integer -> SInstr
cmpi a n = (plain "cmpi" [] [any' a, OI n]) {siFlags = FlagsDef}
cset :: String -> VReg -> SInstr
cset cond d = (plain ("set." ++ cond) [any' d] []) {siFlags = FlagsUse}
csel :: String -> VReg -> VReg -> VReg -> SInstr
csel cond d a b = (plain ("cmov." ++ cond) [OV d (Tied 0)] [any' b, any' a]) {siFlags = FlagsUse}
bcond :: String -> Label -> SInstr
bcond cond l = (plain ("j." ++ cond) [] [OL l]) {siFlags = FlagsUse, siControl = CondTo [l]}
cbz, cbnz :: VReg -> Label -> SInstr
cbz v l = (plain "jzero" [] [any' v, OL l]) {siFlags = FlagsDef, siControl = CondTo [l]}
cbnz v l = (plain "jnonzero" [] [any' v, OL l]) {siFlags = FlagsDef, siControl = CondTo [l]}
jump :: Label -> SInstr
jump l = (plain "jmp" [] [OL l]) {siControl = JumpTo l}

-- a variable shift: the count in %rcx (the instruction reads %cl), the
-- value tied to the destination
shiftv :: String -> VReg -> VReg -> VReg -> SInstr
shiftv op d a b = (plain op [OV d (Tied 0)] [any' a, fix b (r "rcx")]) {siFlags = FlagsDef}

-- cqto sign-extends the dividend into rdx before idivq. Placement excludes
-- both fixed rax and implicit rdx when choosing the divisor's register.
divide :: VReg -> VReg -> VReg -> SInstr
divide d a b = (plain "divide" [fix d (r "rax")] [fix a (r "rax"), any' b])
  {siImplicitDefs = [r "rdx"], siFlags = FlagsDef}

-- arguments 7 and 8 into the private TLS cells, 9.. into the per-hart
-- spill cells (cell j at 8*(1+j) in the hart block, read into %r10 for
-- each store); every argument is evaluated by now and no call separates
-- these stores from the transfer, so the callee's prologue copies them
stageArgs :: [VReg] -> Se ()
stageArgs args = do
  forM_ (zip [6 :: Int, 7] (take 2 (drop 6 args))) $ \(n,v) ->
    emitI (plain "store.cell" [] [any' v, OS ("fpr_x64_a" ++ show n)])
  forM_ (zip [0 :: Int ..] (drop 8 args)) $ \(j,v) ->
    emitI ((plain "store.spill" [] [any' v, OI (fromIntegral j)]) {siImplicitDefs = [r "r10", r "r11"]})

emitCall :: String -> Bool -> Bool -> [VReg] -> Maybe VReg -> Se ()
emitCall sym safepoint runtime args res = do
  stageArgs args
  emitI $ (plain "call" [fix v (r "rax") | Just v <- [res]]
    (OS sym : zipWith fix args argRegs))
    {siClobbers = filter (\p -> p `notElem` [r "rax" | Just _ <- [res]]) callerSaved,
     siImplicitDefs = [r "rsp"], siFlags = FlagsDef,
     siCalls = [Call sym safepoint runtime]}

ret :: VReg -> SInstr
ret v = (plain "ret" [] [fix v (r "rax")])
  {siImplicitDefs = map r ["r11", "rbp", "rsp"], siControl = Return}
emitTail :: String -> Bool -> Bool -> [VReg] -> Se ()
emitTail sym safepoint runtime args = do
  stageArgs args
  emitI $ (plain "tailjump" [] (OS sym : zipWith fix args argRegs))
    {siImplicitDefs = map r ["r11", "rbp", "rsp"], siClobbers = callerSaved,
     siControl = Return, siCalls = [Call sym safepoint runtime]}

entrySeq :: Bool -> Bool -> Label -> SInstr
entrySeq stack fuel (Label base) =
  (plain (case (stack, fuel) of (True, True) -> "entry.check.tick"; (True, False) -> "entry.check"; _ -> "entry.tick") [] [])
    {siImplicitDefs = map r ["r10", "r11", "rax", "rsp"], siClobbers = callerSaved,
     siFlags = FlagsDef,
     siCalls = [Call "fpr_stack_grow" False True | stack] ++ [Call "fpr_fuel_exhausted" True False | fuel],
     siNote = base}

-- ---- selection ---------------------------------------------------------

primSymbol :: ArithOp -> String
primSymbol o = "fpr_prim_fn_" ++ mangleName (arithSymbol o)

calleeSymbol :: Callee -> String
calleeSymbol c = case calleeKind c of
  Foreign sym -> sym
  Generated sym -> sym
  _ -> functionSymbol (calleeName c)

nullarySymbol :: Int -> Int -> Se String
nullarySymbol t v = case (t, v) of
  (0, 0) -> pure "fpr_unit"
  (1, 0) -> pure "fpr_false"
  (1, 1) -> pure "fpr_true"
  _ -> do
    modify (\s -> s {selNullaries = S.insert (t, v) (selNullaries s)})
    pure (".Lnul_" ++ show t ++ "_" ++ show v)

select :: X64Config -> Fn -> Either String (SFn, S.Set VReg, S.Set (Int, Int), S.Set String)
select cfg fn = do
  validatePolicy (cfgPolicy cfg)
  unless (policyWidth (cfgPolicy cfg) == W64) (Left "this native target requires the 64-bit word policy")
  let maxV = maximum (0 : [n | b <- fnBlocks fn, (VId n, _) <- blockDefs b]) + 1
      tyMap = M.fromList (concatMap blockDefs (fnBlocks fn))
      managed0 = S.fromList [vreg v | (v, TVal) <- M.toList tyMap]
      params = [vreg v | (v, _) <- bParams (entryBlock fn)]
      st0 = Sel maxV 0 [] managed0 S.empty S.empty
  when (length params > arityCeiling) (Left ("arity above " ++ show arityCeiling))
  (_, st) <- runStateT (mapM_ (selectBlock cfg fn tyMap) (fnBlocks fn)) st0
  pure (SFn (fnName fn) params (reverse (selItems st)), selManaged st, selNullaries st, selStrings st)

entryBlock :: Fn -> Block
entryBlock fn = head [b | b <- fnBlocks fn, bId b == fnEntry fn]

selectBlock :: X64Config -> Fn -> M.Map VId Ty -> Block -> Se ()
selectBlock cfg fn tyMap b = do
  emitL (blockLabel (bId b))
  let isEntry = bId b == fnEntry fn
      policy = cfgPolicy cfg
  -- the entry sequence: the stack check and the tick are the first
  -- instructions of the entry block, in that order, and nowhere else
  let (entryOps, rest) = span (\(Instr _ op) -> op `elem` [OStackCheck, OSafepoint]) (bInstrs b)
      stack = OStackCheck `elem` [op | Instr _ op <- entryOps]
      fuel = OSafepoint `elem` [op | Instr _ op <- entryOps]
  forM_ rest $ \(Instr _ op) -> when (op == OStackCheck) (refuse "a stack check that is not the first instruction of the entry block")
  if isEntry
    then do
      when (not stack && polStackCheck policy == StackCheckEveryEntry) (refuse "the entry block has no stack check under a policy that checks every entry")
      when (not fuel && polFuel policy) (refuse "the entry block has no fuel tick under a policy with fuel")
      unless (null entryOps) $ freshL "entry" >>= emitI . entrySeq stack fuel
    else do
      when stack (refuse "a stack check outside the entry block")
      -- an inlined callee's tick ($fuel) at the start of a non-entry block
      forM_ entryOps $ \_ -> freshL "tick" >>= emitI . entrySeq False True
  forM_ rest (selectInstr cfg tyMap)
  selectTerm cfg fn b

selectInstr :: X64Config -> M.Map VId Ty -> Instr -> Se ()
selectInstr _ _ (Instr d op) = case op of
  OStackCheck -> refuse "internal: a stack check reached selection"
  OSafepoint -> freshL "tick" >>= emitI . entrySeq False True -- an inlined callee's tick mid-block
  OSafepointN n -> freshL "tick" >>= \l -> emitI ((entrySeq False True l) {siOp = "tick.n", siUses = [OI (fromIntegral n)]})
  OSimdPair {} -> refuse "a NEON pair on x86-64"
  ORvvVlMax -> refuse "a RISC-V vector length on x86-64"
  ORvvLanes _ _ -> refuse "RISC-V vector lanes on x86-64"
  ORvvSumLoaded _ -> refuse "a RISC-V vector sum on x86-64"
  OAddress v -> def (\r -> emitI (mov r (vreg v)))
  OIndex a i -> def $ \r -> do
    offset <- freshV False
    emitI (rri "lsl" offset (vreg i) 3)
    emitI (rrr "add" r (vreg a) offset)
  OLoad _ a n -> def (\r -> emitI (plain "load.field" [any' r] [any' (vreg a), OI (fromIntegral n)]))
  OLoadByte a n -> def (\r -> emitI (plain "load.byte" [any' r] [any' (vreg a), OI (fromIntegral n)]))
  OStore _ a n v -> emitI (plain "store.field" [] [any' (vreg a), any' (vreg v), OI (fromIntegral n)])
  OConstInt n -> def (\r -> emitI (li r n))
  OBits n -> def (\r -> emitI (li r n))
  ONullary t v -> def (\r -> nullarySymbol t v >>= emitI . la r)
  OString text -> def $ \rd -> do
    modify (\st -> st {selStrings = S.insert text (selStrings st)})
    emitI (la rd (stringLabel text))
  OMake tid variant fields -> def $ \rd -> do
    size <- freshV False
    emitI (li size (8 + 8 * fromIntegral (length fields)))
    emitCall "fpr_alloc" False True [size] (Just rd)
    forM_ [(0, tid), (4, variant)] $ \(offset, value) -> do
      header <- freshV False
      emitI (li header (fromIntegral value))
      emitI (plain "store.header" [] [any' rd, any' header, OI offset])
    forM_ (zip [0..] fields) $ \(index, value) ->
      emitI (plain "store.field" [] [any' rd, any' (vreg value), OI (8 + 8 * index)])
  OReuse _ _ root fields -> def $ \rd -> do
    forM_ (zip [0..] fields) $ \(index, value) ->
      emitI (plain "store.field" [] [any' (vreg root), any' (vreg value), OI (8 + 8 * index)])
    emitI (mov rd (vreg root))
  OField index obj -> def $ \rd ->
    emitI (plain "load.field" [any' rd] [any' (vreg obj), OI (8 + 8 * fromIntegral index)])
  OStrLen str -> def $ \rd -> do
    tagged <- freshV True
    emitCall "fpr_g_strlen_call1" False True [vreg str] (Just tagged)
    emitI (rri "asr" rd tagged 1)
  OCharAt str index -> def $ \rd -> do
    shifted <- freshV False
    taggedIndex <- freshV True
    taggedResult <- freshV True
    emitI (rri "lsl" shifted (vreg index) 1)
    emitI (rri "orri" taggedIndex shifted 1)
    emitCall "fpr_g_charAt_call2" False True [vreg str, taggedIndex] (Just taggedResult)
    emitI (rri "asr" rd taggedResult 1)
  OSymbol sym -> def (\r -> emitI (la r sym)) -- the legacy `la a0, <symbol>`
  OFunValue n -> def (\r -> emitI (la r ("fpr_obj_" ++ mangleName n)))
  -- the generic application: the head then every argument pushed 16 bytes
  -- apart (the last at the stack pointer), fpr_applyN(head, n, &args) with
  -- the call-alignment adjustment, the pushes popped; slots are %rbp-relative
  OApply f as -> def $ \rd -> do
    forM_ (f : as) $ \v -> emitI ((plain "push" [] [any' (vreg v)]) {siImplicitDefs = [r "rsp"]})
    emitI ((plain "applyn" [fix rd (r "rax")] [OI (fromIntegral (length as))])
             { siImplicitDefs = map r ["rdi", "rsi", "rdx", "rsp"], siClobbers = filter (/= r "rax") callerSaved,
               siFlags = FlagsDef, siCalls = [Call "fpr_applyN" False True] })
  OTag v -> def $ \r -> do
    t <- freshV False
    emitI (rri "lsl" t (vreg v) 1)
    emitI (rri "orri" r t 1)
  OUntag v -> def (\r -> emitI (rri "asr" r (vreg v) 1))
  OBoolOf p -> def $ \r -> do
    f <- freshV True
    t <- freshV True
    emitI (la f "fpr_false")
    emitI (la t "fpr_true")
    emitI (cmpi (vreg p) 0)
    emitI (csel "ne" r t f)
  OTruth v -> def (\r -> emitI (ldrsw r (vreg v) 4))
  ONot p -> def (\r -> emitI (rri "eori" r (vreg p) 1))
  OIsInt v -> def (\r -> emitI (rri "andi" r (vreg v) 1))
  OTagTest t c v -> def $ \r -> do
    miss <- freshL "tagno"
    done <- freshL "tagdone"
    bit <- freshV False
    emitI (rri "andi" bit (vreg v) 1)
    emitI (cbnz bit miss)
    tid <- freshV False
    want <- freshV False
    emitI (ldrsw tid (vreg v) 0)
    emitI (li want (fromIntegral t))
    emitI (cmp tid want)
    emitI (bcond "ne" miss)
    var <- freshV False
    wantv <- freshV False
    emitI (ldrsw var (vreg v) 4)
    emitI (li wantv (fromIntegral c))
    emitI (cmp var wantv)
    emitI (cset "eq" r)
    emitI (jump done)
    emitL miss
    emitI (li r 0)
    emitL done
  OKernelArith o a b -> def (\r -> arith True o r (vreg a) (vreg b))
  OArith o a b -> def (\r -> arith False o r (vreg a) (vreg b))
  -- band/bor/bxor on the untagged values: one instruction, the result fits
  OBit o a b -> def (\r -> emitI (rrr (case o of BAnd -> "and"; BOr -> "or"; BXor -> "xor") r (vreg a) (vreg b)))
  -- F64 on the bits through xmm14/xmm15, inside the expansion only (SysV:
  -- caller-saved; no float register is allocated)
  OFloatBin o a b -> def (\r -> emitI (plain ("fbin." ++ (case o of FAdd -> "add"; FSub -> "sub"; FMul -> "mul"; FDiv -> "div")) [any' r] [any' (vreg a), any' (vreg b)]))
  OFloatCmp o a b -> def (\r -> emitI ((plain ("fcmp." ++ (case o of Lt -> "lt"; Gt -> "gt"; Le -> "le"; Ge -> "ge"; Eq -> "eq"; Ne -> "ne")) [any' r] [any' (vreg a), any' (vreg b)]) {siFlags = FlagsDef}))
  OFloat32Bin o a b -> def (\r -> emitI (plain ("fbin32." ++ (case o of FAdd -> "add"; FSub -> "sub"; FMul -> "mul"; FDiv -> "div")) [any' r] [any' (vreg a), any' (vreg b)]))
  OFloat32Cmp o a b -> def (\r -> emitI ((plain ("fcmp32." ++ (case o of Lt -> "lt"; Gt -> "gt"; Le -> "le"; Ge -> "ge"; Eq -> "eq"; Ne -> "ne")) [any' r] [any' (vreg a), any' (vreg b)]) {siFlags = FlagsDef}))
  OShift o a b -> def (\r -> shift o r (vreg a) (vreg b))
  OCmp o a b -> def $ \r -> do
    emitI (cmp (vreg a) (vreg b))
    emitI (cset (cond o) r)
  OEqVal eq a b -> def $ \r -> do
    slow <- freshL "eqslow"
    done <- freshL "eqdone"
    both <- freshV False
    bit <- freshV False
    emitI (rrr "and" both (vreg a) (vreg b))
    emitI (rri "andi" bit both 1)
    emitI (cbz bit slow)
    emitI (cmp (vreg a) (vreg b))
    emitI (cset (if eq then "eq" else "ne") r)
    emitI (jump done)
    emitL slow
    res <- freshV True
    emitCall ("fpr_prim_fn_" ++ mangleName (if eq then "==" else "!=")) False True [vreg a, vreg b] (Just res)
    emitI (ldrsw r res 4)
    emitL done
  OCall c as -> do
    when (length as > arityCeiling) (refuse ("a call with more than " ++ show arityCeiling ++ " arguments"))
    def (\r -> emitCall (calleeSymbol c) (not (isForeign c)) (isForeign c) (map vreg as) (Just r))
  where
    def k = case d of
      Just (v, _) -> k (vreg v)
      Nothing -> refuse ("internal: " ++ take 20 (show op) ++ " without a definition")
    cond = \case Lt -> "lt"; Gt -> "gt"; Le -> "le"; Ge -> "ge"; Eq -> "eq"; Ne -> "ne"
    -- checked Int arithmetic: the legacy worker sequences (Codegen.inlineTable,
    -- ScalarChecked): the fast path computes and checks the 63-bit fit, the
    -- slow path retags the ORIGINAL operands and re-enters the C primitive,
    -- whose panic text and failure order are the language's
    arith kernel o r a b = do
      slow <- freshL "slow"
      done <- freshL "done"
      t <- freshV False
      case o of
        Add -> emitI (rrr "add" t a b) >> fit t slow
        Sub -> emitI (rrr "sub" t a b) >> fit t slow
        Mul -> do
          emitI (rrr "mul" t a b)
          emitI (bcond "o" slow) -- full 64-bit overflow, then 63-bit language fit
          fit t slow
        Div -> do
          emitI (cbz b slow)
          emitI (divide t a b)
          fit t slow
      emitI (mov r t)
      emitI (jump done)
      emitL slow
      if kernel then do
        zero <- freshL "kernelzero"
        when (o == Div) (emitI (cbz b zero))
        emitCall "fpr_int_overflow_kernel" False True [] Nothing
        when (o == Div) $ do
          emitL zero
          emitCall "fpr_div_zero_kernel" False True [] Nothing
        -- Both entries are noreturn. Define the result on the impossible
        -- continuation as well so the allocation oracle needs no exception.
        emitI (li r 0)
      else do
        ta <- freshV False
        ta' <- freshV True
        tb <- freshV False
        tb' <- freshV True
        emitI (rri "lsl" ta a 1)
        emitI (rri "orri" ta' ta 1)
        emitI (rri "lsl" tb b 1)
        emitI (rri "orri" tb' tb 1)
        res <- freshV True
        emitCall (primSymbol o) False True [ta', tb'] (Just res)
        emitI (rri "asr" r res 1)
      emitL done
    -- the 63-bit fit check: sign-extend the low 63 bits and compare
    fit t slow = do
      n <- freshV False
      emitI (rri "sext63" n t 0)
      emitI (cmp n t)
      emitI (bcond "ne" slow)
    -- BITSHIFTL / BITSHIFTR (Codegen.inlineTable, shiftOk): a count outside
    -- 0..63 (negative counts included, compared unsigned) takes the slow
    -- path, the HAL entry fpr_g_<name>_call2 with the original operands
    -- retagged, which traps with the primitive's text; the fast path is
    -- the 64-bit shift (%cl) of the untagged value with the low 63 bits kept
    shift o r a b = do
      slow <- freshL "shslow"
      done <- freshL "shdone"
      t <- freshV False
      emitI (cmpi b 64)
      emitI (bcond "hs" slow)
      emitI (shiftv (case o of Shl -> "shlq"; Shr -> "shrq") t a b)
      emitI (rri "sext63" r t 0)
      emitI (jump done)
      emitL slow
      ta <- freshV False
      ta' <- freshV True
      tb <- freshV False
      tb' <- freshV True
      emitI (rri "lsl" ta a 1)
      emitI (rri "orri" ta' ta 1)
      emitI (rri "lsl" tb b 1)
      emitI (rri "orri" tb' tb 1)
      res <- freshV True
      emitCall ("fpr_g_" ++ mangleName (shiftName o) ++ "_call2") False True [ta', tb'] (Just res)
      emitI (rri "asr" r res 1)
      emitL done

-- block parameters are assigned in parallel: a cycle is broken with a
-- fresh temporary
parallelMoves :: [(VReg, VReg)] -> Se ()
parallelMoves = go . filter (uncurry (/=))
  where
    go [] = pure ()
    go ms = case [m | m@(d, _) <- ms, d `notElem` map snd ms] of
      ((d, s) : _) -> emitI (mov d s) >> go (filter (/= (d, s)) ms)
      [] -> do
        let (d, s) = head ms
        t <- freshV True -- a tagged word may travel through it
        emitI (mov t s)
        go ((d, t) : [(d', if s' == s then t else s') | (d', s') <- tail ms])

selectTerm :: X64Config -> Fn -> Block -> Se ()
selectTerm _ fn b = case bTerm b of
  TRet v -> emitI (ret (vreg v))
  TBr target as
    | target == fnEntry fn -> -- the self tail call: the legacy transfer re-enters the function through its symbol
        emitTail (functionSymbol (fnName fn)) True False (map vreg as)
    | otherwise -> do
        parallelMoves (zip (paramsOf target) (map vreg as))
        emitI (jump (blockLabel target))
  TCondBr p t as e bs
    | null as && null bs -> do
        emitI (cbnz (vreg p) (blockLabel t))
        emitI (jump (blockLabel e))
    | otherwise -> do
        edge <- freshL "edge"
        emitI (cbnz (vreg p) edge)
        parallelMoves (zip (paramsOf e) (map vreg bs))
        emitI (jump (blockLabel e))
        emitL edge
        parallelMoves (zip (paramsOf t) (map vreg as))
        emitI (jump (blockLabel t))
  TTailCall c as -> do
    when (length as > arityCeiling) (refuse ("a tail call with more than " ++ show arityCeiling ++ " arguments"))
    emitTail (calleeSymbol c) (not (isForeign c)) (isForeign c) (map vreg as)
  -- a dead arm: the legacy trap if ever reached (`la a0, <str>; call
  -- fpr_panic`, which does not return); the function's text ends here
  TUnreachable msg -> do
    modify (\s -> s {selStrings = S.insert msg (selStrings s)})
    emitI ((plain "panic" [] [OS (stringLabel msg)])
             {siImplicitDefs = map r ["rdi", "rsp"], siClobbers = callerSaved, siControl = Return, siCalls = [Call "fpr_panic" False True]})
  where
    paramsOf bid = [vreg v | blk <- fnBlocks fn, bId blk == bid, (v, _) <- bParams blk]

-- ---- placement, frame layout and rendering ------------------------------
placement :: S.Set VReg -> Placement
placement managed = Placement
  { plScratch = \case GPR -> scratchPool; FPR -> [],
    plLoad = \p ref -> plain "load" [OP p] [OF ref 0],
    plStore = \p ref -> plain "store" [] [OP p, OF ref 0],
    plSlot = \v@(VReg n) -> frameObj n 8 8 (SpillSlot n) (S.member v managed) }

-- the allocator's view of this target (M3): the first six parameters
-- arrive in the SysV registers, seven and eight are read from the private
-- cells before the entry sequence can destroy them
allocConfig :: Maybe String -> S.Set VReg -> AllocConfig
allocConfig self managed = AllocConfig
  { acCalleeSaved = calleeBudget,
    acCallerSaved = callerPool,
    acScratch = allocScratch,
    acPreserved = map r ["rbp", "rsp"],
    acArrival = \params ->
      plain "params" (zipWith fix (take 6 params) argRegs) []
        : [plain "load.cell" [OV p (Any GPR)] [OS ("fpr_x64_a" ++ show n)] | (n, p) <- take 2 (drop 6 (zip [0 :: Int ..] params))]
        -- the ninth and later from the hart spill cells (cell j at 8*(1+j)),
        -- the hart block read into the parameter's own register
        ++ [plain "load.spill" [OV p (Any GPR)] [OI (fromIntegral j)] | (j, p) <- zip [0 :: Int ..] (drop 8 params)],
    acLoad = \p ref -> plain "load" [OP p] [OF ref 0],
    acStore = \p ref -> plain "store" [] [OP p, OF ref 0],
    acMove = \d s' -> plain "movq" [OP d] [OP s'],
    acSlot = \n v -> frameObj n 8 8 (SpillSlot n) (S.member v managed),
    -- cqto writes rdx before idivq reads the divisor
    -- store.spill writes a scratch register before it reads the value
    acEarlyDef = \i -> siOp i `elem` ["divide", "store.spill"],
    acClassOf = rfClassOf x64RegisterFile,
    acSelfLoop = self }

savedObjs :: [Phys] -> [FrameObj]
savedObjs saved = [FrameObj (FrameRef (negate (k + 1))) 8 8 (SavedRegister p) False False | (k, Phys p) <- zip [0 ..] saved]

emitFnX64 :: X64Config -> Fn -> Either String NativeFn
emitFnX64 cfg fn = do
  (sel0, managed, nulls, strs) <- select cfg fn
  let (sel, entrySlots) = forwardEntry (cfgForwardParams cfg) (tuneEntryArgs (cfgTune cfg)) argRegs fn sel0
  either (Left . ("compiler error: " ++)) Right (checkFn x64RegisterFile sel)
  let ac = allocConfig (if cfgSelfLoops cfg then Just (functionSymbol (fnName fn)) else Nothing) managed
  alloc <- either (Left . ("compiler error: " ++)) Right (allocateFn ac sel)
  either (Left . ("compiler error: " ++)) Right (checkAllocation ac (fnName fn) (alBody alloc))
  let saves = savedObjs (alSaved alloc)
      objs = saves ++ alSlots alloc ++ entrySlots
      ly = layout 16 16 objs
      (shallow, allocatedBody) = shallowEntry (polStackCheck (cfgPolicy cfg)) (lyBytes ly) (alBody alloc)
  when (lyBytes ly > 32768) $ Left ("a frame of " ++ show (lyBytes ly) ++ " bytes exceeds the 32768-byte ceiling (half the runtime's stack headroom)")
  let name = fnName fn
      sym = functionSymbol name
      saveOff o = show (M.findWithDefault (error "X64: a saved register without an offset") (foRef o) (lyOffset ly)) ++ "(%rbp)"
      saveLines = ["movq %" ++ p ++ ", " ++ saveOff o | o <- saves, SavedRegister p <- [foKind o]]
      restores = ["movq " ++ saveOff o ++ ", %" ++ p | o <- saves, SavedRegister p <- [foKind o]]
      body = I ((plain "enter" [] []) {siImplicitDefs = map r ["rsp", "rbp"]})
        : [I (plain "save" [] []) | not (null saves)]
        ++ allocatedBody
      rendered = [(it, renderItem ly name saveLines restores it) | it <- body]
      report = analyse (concatMap (uncurry tokOf) rendered)
      visibility = if cfgWeak cfg && '@' `notElem` name then ".weak" else ".globl"
      header = ["# fn " ++ name ++ " (arity " ++ show (length (sfParams sel)) ++ ") typed-ir x64 frame=" ++ show (lyBytes ly)
                  ++ (if shallow then " shallow=yes" else " shallow=no") ++ (if null entrySlots then "" else " forward=yes") ++ " saved=" ++ (case alSaved alloc of [] -> "none"; ps -> intercalate "," [p | Phys p <- ps]) ++ " " ++ statsLine (alStats alloc)]
        ++ ["    " ++ visibility ++ " " ++ sym | S.member name (cfgExports cfg)] ++ [sym ++ ":"]
  pure (NativeFn name (header ++ concatMap snd rendered ++ [reportLine name report, ""]) report (S.toList nulls) (S.toList strs))
  where
    tokOf (ILabel (Label l)) _ = [TLabel l]
    tokOf (I i) ls = [TIns
      { tCost = length [() | l <- ls, isInstruction l],
        tFlow = case siControl i of
          Next -> FNext; CondTo labels -> FCond [l | Label l <- labels]; JumpTo (Label l) -> FJump l; Return -> FExit,
        tReset = any callSafepoint (siCalls i), tCCalls = length (filter callRuntime (siCalls i)) }]
    isInstruction l = case dropWhile (== ' ') l of
      "" -> False; '#':_ -> False; '.':_ -> False; t -> last t /= ':'

local :: String -> Label -> String
local fname (Label l) = ".Ltir_" ++ mangleName fname ++ "_" ++ l

renderItem :: Layout -> String -> [String] -> [String] -> Item -> [String]
renderItem _ fname _ _ (ILabel l) = [local fname l ++ ":"]
renderItem ly fname saveLines restores (I i) = map indent (go (siOp i) (siDefs i) (siUses i))
  where
    indent l = if last l == ':' then l else "    " ++ l
    lbl = local fname
    reg = \case OP (Phys p) -> '%' : p; o -> error ("X64 render: unplaced operand " ++ show o)
    byte o = case reg o of
      "%rax" -> "%al"; "%rcx" -> "%cl"; "%rdx" -> "%dl"; "%rsi" -> "%sil"; "%rdi" -> "%dil"; "%rbx" -> "%bl"
      p | p `elem` ["%r" ++ show n | n <- [8 :: Int .. 15]] -> p ++ "b"
      p -> error ("X64 render: no byte register for " ++ p)
    word32 o = case reg o of
      "%rax" -> "%eax"; "%rbx" -> "%ebx"; "%rcx" -> "%ecx"; "%rdx" -> "%edx"; "%rsi" -> "%esi"; "%rdi" -> "%edi"
      p -> p ++ "d"
    imm = \case OI n -> show n; o -> error ("X64 render: not an immediate " ++ show o)
    slot ref = show (M.findWithDefault (error "X64 render: missing frame object") ref (lyOffset ly)) ++ "(%rbp)"
    cc = \case "eq" -> "e"; "ne" -> "ne"; "lt" -> "l"; "gt" -> "g"; "le" -> "le"; "ge" -> "ge"; "o" -> "o"; "hs" -> "ae"; c -> error ("X64 condition " ++ c)
    call sym = ["subq $8, %rsp", "call " ++ sym, "addq $8, %rsp"]
    go op ds us = case (op,ds,us) of
      ("enter",[],[]) ->
        ["subq $" ++ show (lyBytes ly) ++ ", %rsp",
         "movq %rbp, " ++ show (lyBytes ly - 8) ++ "(%rsp)",
         "leaq " ++ show (lyBytes ly + 8) ++ "(%rsp), %rbp"]
      ("save",[],[]) -> saveLines
      ("params",_,[]) -> [] -- the parameters are where the ABI put them
      ("load.cell",[d],[OS cell]) -> ["movq %fs:" ++ cell ++ "@tpoff, " ++ reg d]
      ("load",[d],[OF ref 0]) -> ["movq " ++ slot ref ++ ", " ++ reg d]
      ("store",[],[s,OF ref 0]) -> ["movq " ++ reg s ++ ", " ++ slot ref]
      ("store.cell",[],[s,OS cell]) -> ["movq " ++ reg s ++ ", %fs:" ++ cell ++ "@tpoff"]
      -- the hart block in whichever scratch register the value is not in
      -- (a spilled value is reloaded into %r10, the allocator's first
      -- scratch: the merge, docs/2026-10-21-TYPED-IR-MERGE.md)
      ("store.spill",[],[s,OI j]) -> let h = if reg s == "%r10" then "%r11" else "%r10" in
        ["movq %fs:fpr_posix_hart@tpoff, " ++ h, "movq " ++ reg s ++ ", " ++ show (8 * (1 + j)) ++ "(" ++ h ++ ")"]
      ("load.spill",[d],[OI j]) -> ["movq %fs:fpr_posix_hart@tpoff, " ++ reg d, "movq " ++ show (8 * (1 + j)) ++ "(" ++ reg d ++ "), " ++ reg d]
      ("movq",[d],[s]) -> ["movq " ++ reg s ++ ", " ++ reg d]
      ("li",[d],[n]) -> ["movabsq $" ++ imm n ++ ", " ++ reg d]
      ("la",[d],[OS s]) -> ["leaq " ++ s ++ "(%rip), " ++ reg d]
      ("load.byte",[d],[base,n]) -> ["movzbq " ++ imm n ++ "(" ++ reg base ++ "), " ++ reg d]
      ("load.field",[d],[base,n]) -> ["movq " ++ imm n ++ "(" ++ reg base ++ "), " ++ reg d]
      ("store.field",[],[base,value,n]) -> ["movq " ++ reg value ++ ", " ++ imm n ++ "(" ++ reg base ++ ")"]
      ("store.header",[],[base,value,n]) -> ["movl " ++ word32 value ++ ", " ++ imm n ++ "(" ++ reg base ++ ")"]
      ("ldrsw",[d],[s,n]) -> ["movslq " ++ imm n ++ "(" ++ reg s ++ "), " ++ reg d]
      ("movslq",[d],[s,n]) -> ["movslq " ++ imm n ++ "(" ++ reg s ++ "), " ++ reg d]
      ("sext63",[d],[_,_]) -> ["shlq $1, " ++ reg d, "sarq $1, " ++ reg d]
      -- F32 on the low 32 bits: movd to a 32-bit register zero-extends
      (o,[d],[a,b]) | Just f <- stripPrefix "fbin32." o ->
        ["movd " ++ word32 a ++ ", %xmm14", "movd " ++ word32 b ++ ", %xmm15", f ++ "ss %xmm15, %xmm14", "movd %xmm14, " ++ word32 d]
      (o,[d],[a,b]) | Just c <- stripPrefix "fcmp32." o ->
        let (x, y, p) = case c of "lt" -> (a, b, "lt"); "le" -> (a, b, "le"); "gt" -> (b, a, "lt"); "ge" -> (b, a, "le"); "eq" -> (a, b, "eq"); _ -> (a, b, "neq")
         in ["movd " ++ word32 x ++ ", %xmm14", "movd " ++ word32 y ++ ", %xmm15", "cmp" ++ p ++ "ss %xmm15, %xmm14", "movd %xmm14, " ++ word32 d, "andq $1, " ++ reg d]
      (o,[d],[a,b]) | Just f <- stripPrefix "fbin." o ->
        ["movq " ++ reg a ++ ", %xmm14", "movq " ++ reg b ++ ", %xmm15", f ++ "sd %xmm15, %xmm14", "movq %xmm14, " ++ reg d]
      -- cmp<pred>sd leaves all-ones or zero: exact NaN behaviour (ordered
      -- predicates false, neq true); gt/ge compare the swapped operands
      (o,[d],[a,b]) | Just c <- stripPrefix "fcmp." o ->
        let (x, y, p) = case c of "lt" -> (a, b, "lt"); "le" -> (a, b, "le"); "gt" -> (b, a, "lt"); "ge" -> (b, a, "le"); "eq" -> (a, b, "eq"); _ -> (a, b, "neq")
         in ["movq " ++ reg x ++ ", %xmm14", "movq " ++ reg y ++ ", %xmm15", "cmp" ++ p ++ "sd %xmm15, %xmm14", "movq %xmm14, " ++ reg d, "andq $1, " ++ reg d]
      (o,[d],[_,n]) | Just mnemonic <- lookup o [("lsl","shlq"),("asr","sarq"),("orri","orq"),("andi","andq"),("eori","xorq")] ->
        [mnemonic ++ " $" ++ imm n ++ ", " ++ reg d]
      (o,[d],[_,b]) | Just mnemonic <- lookup o [("add","addq"),("sub","subq"),("mul","imulq"),("and","andq"),("or","orq"),("xor","xorq")] ->
        [mnemonic ++ " " ++ reg b ++ ", " ++ reg d]
      (o,[d],[_,c]) | o `elem` ["shlq","shrq"] -> [o ++ " " ++ byte c ++ ", " ++ reg d] -- the count register is %rcx by constraint
      ("divide",[_],[_,b]) -> ["cqto", "idivq " ++ reg b]
      ("cmpq",[],[a,b]) -> ["cmpq " ++ reg b ++ ", " ++ reg a]
      ("cmpi",[],[a,n]) -> ["cmpq $" ++ imm n ++ ", " ++ reg a]
      ('s':'e':'t':'.':c,[d],[]) -> ["set" ++ cc c ++ " " ++ byte d, "movzbq " ++ byte d ++ ", " ++ reg d]
      ('c':'m':'o':'v':'.':c,[d],[_,a]) -> ["cmov" ++ cc c ++ " " ++ reg a ++ ", " ++ reg d]
      ('j':'.':c,[],[OL l]) -> ["j" ++ cc c ++ " " ++ lbl l]
      (o,[],[v,OL l]) | o `elem` ["jzero","jnonzero"] -> ["testq " ++ reg v ++ ", " ++ reg v, (if o == "jzero" then "jz " else "jnz ") ++ lbl l]
      ("jmp",[],[OL l]) -> ["jmp " ++ lbl l]
      ("jump.loop",[],[OL l]) -> ["jmp " ++ lbl l]
      ("call",_,OS s:_) -> call s
      ("push",[],[v]) -> ["subq $16, %rsp", "movq " ++ reg v ++ ", (%rsp)"]
      ("applyn",[_],[OI n]) -> ["movq %rsp, %rdx", "movq $" ++ show n ++ ", %rsi", "movq " ++ show (16 * n) ++ "(%rsp), %rdi"]
        ++ call "fpr_applyN" ++ ["addq $" ++ show (16 * (n + 1)) ++ ", %rsp"]
      ("panic",[],[OS s]) -> ("leaq " ++ s ++ "(%rip), %rdi") : call "fpr_panic"
      ("ret",[],[_]) -> epilogue ++ ["ret"]
      ("tailjump",[],OS s:_) -> epilogue ++ ["jmp " ++ s]
      ("entry.check.tick",_,_) -> hartRead ++ stackCheck ++ tick
      ("entry.check",_,_) -> hartRead ++ stackCheck
      ("entry.tick",_,_) -> hartRead ++ tick
      ("tick.n",_,[OI n]) -> hartRead ++ tickN n
      _ -> error ("X64 render: no form for " ++ show (op,ds,us))
    -- the callee-saved registers come back first (rbp-relative, so after a
    -- stack-segment change they still read the frame they were saved in)
    epilogue = restores ++ ["movq %rbp, %r11", "movq -16(%rbp), %rbp", "leaq -8(%r11), %rsp"]
    hartRead = ["movq %fs:fpr_posix_hart@tpoff, %r10"]
    base = siNote i
    parkArgs save = ["movq " ++ (if save then reg o ++ ", " ++ slot ref else slot ref ++ ", " ++ reg o)
      | (n, o) <- zip [0..] (siDefs i), let ref = FrameRef (entrySlot n)]
    stackCheck =
      ["leaq 8(%rsp), %r11", "subq 456(%r10), %r11", "cmpq 464(%r10), %r11", "jb " ++ lbl (Label (base ++ "_stk"))]
      ++ parkArgs True ++ call "fpr_stack_grow"
      ++ ["testq %rax, %rax", "jz " ++ lbl (Label (base ++ "_same")), "leaq -8(%rax), %rsp", lbl (Label (base ++ "_same")) ++ ":"]
      ++ parkArgs False ++ hartRead ++ [lbl (Label (base ++ "_stk")) ++ ":"]
    tick = tickN 1
    tickN n = ["subq $" ++ show n ++ ", (%r10)", "cmpq $0, (%r10)", "jg " ++ lbl (Label (base ++ "_fuel"))]
      ++ parkArgs True ++ call "fpr_fuel_exhausted" ++ parkArgs False ++ [lbl (Label (base ++ "_fuel")) ++ ":"]
