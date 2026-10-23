{-# LANGUAGE LambdaCase #-}
-- Codegen.Target.A64: direct AArch64 selection from the typed IR, for the
-- M1 scalar subset under the hosted Base profile
-- (docs/2026-10-20-TYPED-NATIVE-IR-PLAN.md M2; the ABI facts are the M0
-- register's, docs/2026-10-21-NATIVE-IR-CONTRACTS.md; the sequences are the
-- legacy generator's as docs/2026-10-19-REGISTER-ALLOCATION.md 1.2/3.2
-- and Codegen.compileFnBody state them).
--
-- The pipeline for one function:
--
--   select   IR operations -> selected instructions over virtual registers
--            (Codegen.Selected), every temporary, fixed register, flag use
--            and call clobber explicit; the entry sequence, calls, tail
--            transfers and the arithmetic slow paths are the legacy
--            generated-code ABI exactly, so legacy and new functions call
--            each other and the runtime without adapters
--   check    Codegen.Selected.checkFn: an invalid selection is a compiler error
--   allocate Codegen.Allocate.allocateFn (M3): live ranges over the stream
--            (Codegen.Liveness), a linear scan over x19..x27 for values that
--            cross a call and x9..x12, x8..x0 for the rest, fixed operands
--            met by parallel copies, spills to shared slots; then
--            Codegen.Allocate.checkAllocation, the oracle that recomputes
--            liveness over the physical stream and refuses a clobbered
--            live register or a value across a call outside x19..x27
--            (M2's Codegen.Place.placeInSlots remains for its tests)
--   layout   Codegen.Frame.layout: the legacy frame shape (ra at fp-8, the
--            caller's fp at fp-16, the saved callee-saved registers, then
--            the spill slots, 16-aligned)
--   render   the Mach-O or ELF text, pseudos expanded
--   bound    Codegen.Bounds over the rendered stream: native-insns-v1
--
-- What the generated code relies on (the register's "Calls and target
-- constraints" and "Scheduler, hart and stack boundary"):
--   * arguments 1..8 in x0..x7, 9..64 in the per-hart spill cells (stored
--     by the caller after every argument is evaluated, copied into the
--     callee's frame before its entry sequence), the result in x0;
--   * x29 is the frame pointer and the frame is addressed through it; the
--     epilogue restores sp from x29, so after fpr_stack_grow moved sp to a
--     new segment the function still returns into the old one;
--   * x28 is the hart register on hosted AArch64 (fpr build), never saved;
--     a64mac without --base reads the Darwin TLV cell, a64 ELF the
--     local-exec TLS cell; every read happens where it is needed, after
--     any call that may have moved the actor to another hart;
--   * the runtime's C entries clobber x0..x17 and x30 and preserve
--     x19..x28; a value that is live across any call (the runtime's, a
--     generated function's, the tick, the stack check) is in x19..x27 or in
--     a slot, which is exactly the set the context switch (ctx_a64.S)
--     saves, so a descheduled actor resumes with its values; the registers
--     of that set the function uses are saved in the prologue as pairs
--     (stp/ldp at signed scaled offsets) and restored before every return
--     and tail transfer; x27 is never paired with x28;
--   * the entry parks the parameters in their slots before the stack
--     check and the fuel tick, both real C calls;
--   * the overflow and zero-divisor slow paths re-enter the C primitive
--     with the original operands retagged, so the trap text and failure
--     order are the primitive's.
module Codegen.Target.A64
  ( A64Config (..), ObjectFormat (..), HartAccess (..), NativeFn (..),
    a64InterfaceRev, a64HostedInterfaceRev, a64SelectionRev, emitFnA64, a64RegisterFile, mangleName, functionSymbol,
    placement, allocConfig,
  ) where

import Codegen.Allocate
import Codegen.Bounds (Flow (..), Report (..), Tok (..), analyse, reportLine)
import Codegen.Frame
import Codegen.IR
import Codegen.Place
import Codegen.Policy
import Codegen.Selected
import Control.Monad (forM_, unless, when)
import Control.Monad.State.Strict
import Data.Bits (shiftR, (.&.))
import Data.List (intercalate, stripPrefix)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Word (Word64)
import Codegen.Target.Common

-- Preserve existing module contract identities across translator retirement.
-- This ABI tag was formerly owned by the translator; cache/selection policy
-- changes have their own version and must not invalidate compatible modules.
a64InterfaceRev :: Int
a64InterfaceRev = 15

-- Hosted context now preserves d8..d15; old hosts must refuse new modules.
a64HostedInterfaceRev :: Int
a64HostedInterfaceRev = 16

-- bump when the selection, placement, layout or rendering changes what is
-- emitted (a unit-cache and run-cache identity component)
a64SelectionRev :: Int
a64SelectionRev = 23 -- sized frames; prior: captured NEON, FP pool, comparison/F32 trees

-- how generated code reaches the hart block
data HartAccess
  = HartX28 -- hosted AArch64 under fpr build: `mov x9, x28`
  | HartTlvMachO -- Darwin TLV descriptor call: _tlv_get_addr preserves all but x0, x16, x17
  | HartTlsElf -- local-exec TLS: mrs tpidr_el0 and the :tprel: adds
  | HartGlobal -- a loaded QOS app on a host without a hart register (qa64single): the global hart cell, as deTlsQosAppA64's single form loads it
  deriving (Eq, Ord, Show)

data A64Config = A64Config
  { cfgFormat :: ObjectFormat,
    cfgHart :: HartAccess,
    cfgPolicy :: Policy,
    cfgExports :: S.Set String, -- functions that get a visibility directive
    cfgWeak :: Bool, -- a library unit: unqualified globals are .weak
    cfgSelfLoops :: Bool, -- M3: self tail calls as loops (FPR_TYPED_IR_SELF_LOOPS, on unless 0)
    cfgForwardParams :: Bool,
    cfgTune :: Tune
  }

-- ---- registers ---------------------------------------------------------

x :: Int -> Phys
x n = Phys ("x" ++ show n)

a64RegisterFile :: RegisterFile
a64RegisterFile = RegisterFile classOf reserved
  where
    classOf (Phys r) = case r of
      'x' : d | all (`elem` "0123456789") d, not (null d), read d < (31 :: Int) -> Just GPR
      'd' : d | all (`elem` "0123456789") d, not (null d), read d < (32 :: Int) -> Just FPR
      "sp" -> Just GPR
      _ -> Nothing
    reserved = [Phys "sp", x 16, x 17, x 18, x 28, x 29, x 30]

-- what a C call destroys (AAPCS64 caller-saved integer registers and the
-- link register); x18 is the platform register and never holds a value
callerSaved :: [Phys]
callerSaved = map x ([0 .. 17] ++ [30]) ++ map (Phys . ("d" ++) . show) ([0..7] ++ [16..31 :: Int])

-- the placement's scratch: caller-saved registers the runtime ABI leaves
-- free and the expansions do not use (x16/x17 are the expansions')
scratchPool :: [Phys]
scratchPool = map x [9 .. 15]

-- M3 allocation (Codegen.Allocate): the budget is x19..x27, the registers
-- the context switch preserves (docs/2026-10-19-REGISTER-ALLOCATION.md 3.3:
-- s1..s9; x28 is the hart register); the caller-saved pool is what no
-- expansion reserves for itself across an instruction (x9..x11 are the
-- entry sequence's scratch, so a value that spans it cannot take them, and
-- that exclusion comes from the sequence's declared implicit definitions);
-- x13..x15 are never allocated: they reload spilled operands and break copy
-- cycles.
calleeBudget, callerPool, allocScratch :: [Phys]
calleeBudget = map x [19 .. 27]
callerPool = map x ([9 .. 12] ++ [8, 7 .. 0])
allocScratch = map x [13, 14, 15]

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

-- ---- instruction builders (A64 forms the renderer prints) ---------------

any' :: VReg -> Operand
any' v = OV v (Any GPR)

fix :: VReg -> Phys -> Operand
fix v p = OV v (Fix p)

-- rd <- rs
mov :: VReg -> VReg -> SInstr
mov d s = plain "mov" [any' d] [any' s]

-- rd <- immediate (movz/movk chain)
li :: VReg -> Integer -> SInstr
li d n = plain "li" [any' d] [OI n]

-- rd <- &symbol
la :: VReg -> String -> SInstr
la d s = plain "la" [any' d] [OS s]

rrr :: String -> VReg -> VReg -> VReg -> SInstr
rrr op d a b = plain op [any' d] [any' a, any' b]

-- rd <- rs op #imm (lsl, asr, orri, andi, eori, sbfx)
rri :: String -> VReg -> VReg -> Integer -> SInstr
rri op d s n = plain op [any' d] [any' s, OI n]

-- rd <- sign-extended word at [rs, #off]
ldrsw :: VReg -> VReg -> Integer -> SInstr
ldrsw d s off = plain "ldrsw" [any' d] [any' s, OI off]

cmp :: VReg -> VReg -> SInstr
cmp a b = (plain "cmp" [] [any' a, any' b]) {siFlags = FlagsDef}

cmpi :: VReg -> Integer -> SInstr
cmpi a n = (plain "cmpi" [] [any' a, OI n]) {siFlags = FlagsDef}

cset :: String -> VReg -> SInstr
cset cond d = (plain ("cset." ++ cond) [any' d] []) {siFlags = FlagsUse}

csel :: String -> VReg -> VReg -> VReg -> SInstr
csel cond d a b = (plain ("csel." ++ cond) [any' d] [any' a, any' b]) {siFlags = FlagsUse}

bcond :: String -> Label -> SInstr
bcond cond l = (plain ("b." ++ cond) [] [OL l]) {siFlags = FlagsUse, siControl = CondTo [l]}

cbz, cbnz :: VReg -> Label -> SInstr
cbz r l = (plain "cbz" [] [any' r, OL l]) {siControl = CondTo [l]}
cbnz r l = (plain "cbnz" [] [any' r, OL l]) {siControl = CondTo [l]}

jump :: Label -> SInstr
jump l = (plain "b" [] [OL l]) {siControl = JumpTo l}

-- a direct call: arguments 1..8 fixed to x0..x7, the result to x0; the
-- callee destroys the caller-saved set; `safepoint` says its entry ticks.
-- Arguments beyond the eighth are in the hart spill cells by now
-- (`stageCells` precedes the call, as the legacy generator's stores do)
call :: String -> Bool -> Bool -> [VReg] -> Maybe VReg -> SInstr
call sym safepoint runtime args res =
  SInstr
    { siOp = "bl",
      siDefs = [fix r (x 0) | Just r <- [res]],
      siUses = [OS sym] ++ zipWith fix (take 8 args) (map x [0 ..]),
      siImplicitDefs = [],
      siImplicitUses = [],
      siClobbers = filter (\p -> p `notElem` [x 0 | Just _ <- [res]]) callerSaved,
      siFlags = FlagsDef, -- nothing survives a call: the flags are destroyed too
      siControl = Next,
      siCalls = [Call sym safepoint runtime],
      siNote = ""
    }

-- the return: x0 <- the value, then the epilogue
ret :: VReg -> SInstr
ret v = (plain "ret" [] [fix v (x 0)]) {siImplicitDefs = [x 9, x 29, x 30, Phys "sp"], siControl = Return}

-- a tail transfer: arguments 1..8 staged in x0..x7 (the rest in the
-- cells, stored before the teardown), the frame torn down, a jump
tailJump :: String -> Bool -> Bool -> [VReg] -> SInstr
tailJump sym safepoint runtime args =
  (plain "tailjump" [] (OS sym : zipWith fix (take 8 args) (map x [0 ..])))
    { siImplicitDefs = [x 9, x 29, x 30, Phys "sp"],
      siClobbers = callerSaved,
      siControl = Return,
      siCalls = [Call sym safepoint runtime]
    }

-- arguments 9.. of a call or transfer into the per-hart spill cells
-- (docs/2026-10-21-NATIVE-IR-CONTRACTS.md "Arguments 9-64": cell j at
-- W*(1+j) in the hart block, fuel at 0): the hart block is read into x9
-- for each store, after every argument is evaluated and with no call
-- between the stores and the transfer, so nothing can touch the cells
-- before the callee's prologue copies them
stageCells :: [VReg] -> Se ()
stageCells args = forM_ (zip [0 :: Int ..] (drop 8 args)) $ \(j, v) ->
  emitI ((plain "store.spill" [] [any' v, OI (fromIntegral j)]) {siImplicitDefs = [x 9, x 16, x 17]})

-- the arrival of parameter 9+j: cell j into the parameter's register,
-- read before the entry sequence's calls can deschedule the actor (the
-- cells are the hart's, dead once copied); the hart block is read into x9
-- for each load, as stageCells does for each store
loadSpill :: VReg -> Int -> SInstr
loadSpill v j = (plain "load.spill" [OV v (Any GPR)] [OI (fromIntegral j)]) {siImplicitDefs = [x 9, x 16, x 17]}

-- the entry sequence: the stack check (a call to fpr_stack_grow that may
-- move sp to a new segment) and the fuel tick (a call to
-- fpr_fuel_exhausted that may deschedule the actor and resume it on
-- another hart); x9..x11 are its scratch, as the legacy sequence's t0..t2
entrySeq :: Bool -> Bool -> Label -> SInstr
entrySeq stack fuel (Label base) =
  (plain (case (stack, fuel) of (True, True) -> "entry.check.tick"; (True, False) -> "entry.check"; _ -> "entry.tick") [] [])
    { siImplicitDefs = [x 9, x 10, x 11, Phys "sp"],
      siImplicitUses = [x 28],
      siClobbers = callerSaved,
      siFlags = FlagsDef,
      siCalls = [Call "fpr_stack_grow" False True | stack] ++ [Call "fpr_fuel_exhausted" True False | fuel],
      siNote = base
    }

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

select :: A64Config -> Fn -> Either String (SFn, S.Set VReg, S.Set (Int, Int), S.Set String)
select cfg fn = do
  validatePolicy (cfgPolicy cfg)
  when (polProfile (cfgPolicy cfg) `elem` [Builtin,Builtin32,BuiltinArc]) (Left "builtin native lowering requires RISC-V")
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

selectBlock :: A64Config -> Fn -> M.Map VId Ty -> Block -> Se ()
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

selectInstr :: A64Config -> M.Map VId Ty -> Instr -> Se ()
selectInstr _ _ (Instr d op) = case op of
  OStackCheck -> refuse "internal: a stack check reached selection"
  OSafepoint -> freshL "tick" >>= emitI . entrySeq False True -- an inlined callee's tick mid-block
  OSafepointN n -> freshL "tick" >>= \l -> emitI ((entrySeq False True l) {siOp = "tick.n", siUses = [OI (fromIntegral n)]})
  OSimdPair int e caps a -> simdPair int e (map vreg caps) (vreg a)
  ORvvVlMax -> refuse "a RISC-V vector length on A64"
  ORvvLanes _ _ -> refuse "RISC-V vector lanes on A64"
  ORvvSumLoaded _ -> refuse "a RISC-V vector sum on A64"
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
    emitI (call "fpr_alloc" False True [size] (Just rd))
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
    emitI (call "fpr_g_strlen_call1" False True [vreg str] (Just tagged))
    emitI (rri "asr" rd tagged 1)
  OCharAt str index -> def $ \rd -> do
    shifted <- freshV False
    taggedIndex <- freshV True
    taggedResult <- freshV True
    emitI (rri "lsl" shifted (vreg index) 1)
    emitI (rri "orri" taggedIndex shifted 1)
    emitI (call "fpr_g_charAt_call2" False True [vreg str, taggedIndex] (Just taggedResult))
    emitI (rri "asr" rd taggedResult 1)
  OSymbol sym -> def (\r -> emitI (la r sym)) -- the legacy `la a0, <symbol>`
  OFunValue n -> def (\r -> emitI (la r ("fpr_obj_" ++ mangleName n)))
  -- the generic application (Codegen.genT's CApp case): the head, then every
  -- argument, pushed 16 bytes apart (the last argument at the stack
  -- pointer), then fpr_applyN(head, n, &args) and the pushes popped; the
  -- pushes move sp below the frame the entry check sized, as the legacy
  -- pushes do, and every slot is addressed through x29
  OApply f as -> def $ \r -> do
    forM_ (f : as) $ \v -> emitI ((plain "push" [] [any' (vreg v)]) {siImplicitDefs = [Phys "sp"]})
    emitI ((plain "applyn" [fix r (x 0)] [OI (fromIntegral (length as))])
             { siImplicitDefs = [x 1, x 2, Phys "sp"], siClobbers = filter (/= x 0) callerSaved,
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
  OBit o a b -> def (\r -> emitI (rrr (case o of BAnd -> "and"; BOr -> "orr"; BXor -> "eor") r (vreg a) (vreg b)))
  -- F64 on the bits: d16/d17 live only inside the expansion (no float
  -- register is allocated; AAPCS lets a call clobber them anyway)
  OFloatBin o a b -> def (\r -> emitI (rrr ("fbin." ++ (case o of FAdd -> "add"; FSub -> "sub"; FMul -> "mul"; FDiv -> "div")) r (vreg a) (vreg b)))
  OFloatCmp o a b -> def (\r -> emitI ((rrr ("fcmp." ++ (case o of Lt -> "lt"; Gt -> "gt"; Le -> "le"; Ge -> "ge"; Eq -> "eq"; Ne -> "ne")) r (vreg a) (vreg b)) {siFlags = FlagsDef}))
  OFloat32Bin o a b -> def (\r -> emitI (rrr ("fbin32." ++ (case o of FAdd -> "add"; FSub -> "sub"; FMul -> "mul"; FDiv -> "div")) r (vreg a) (vreg b)))
  OFloatCmpTree o x y -> def (\r -> do
    forM_ (ftreeScheduleAt 0 x ++ ftreeScheduleAt 1 y) $ \case
      FSLeaf v n -> emitI (plain "ftree.leaf" [] [any' (vreg v), OI (fromIntegral n)])
      FSNode f n -> emitI (plain ("ftree." ++ (case f of FAdd -> "add"; FSub -> "sub"; FMul -> "mul"; FDiv -> "div")) [] [OI (fromIntegral n)])
    emitI ((plain ("ftree.cmp." ++ (case o of Lt -> "lt"; Gt -> "gt"; Le -> "le"; Ge -> "ge"; Eq -> "eq"; Ne -> "ne")) [any' r] []) {siFlags = FlagsDef}))
  OFloat32CmpTree o x y -> def (\r -> do
    forM_ (ftreeScheduleAt 0 x ++ ftreeScheduleAt 1 y) $ \case
      FSLeaf v n -> emitI (plain "ftree32.leaf" [] [any' (vreg v), OI (fromIntegral n)])
      FSNode f n -> emitI (plain ("ftree32." ++ (case f of FAdd -> "add"; FSub -> "sub"; FMul -> "mul"; FDiv -> "div")) [] [OI (fromIntegral n)])
    emitI ((plain ("ftree32.cmp." ++ (case o of Lt -> "lt"; Gt -> "gt"; Le -> "le"; Ge -> "ge"; Eq -> "eq"; Ne -> "ne")) [any' r] []) {siFlags = FlagsDef}))
  OFloatTree t -> def (\r -> do
    let (steps, root) = ftreeSchedule t
    forM_ steps $ \case
      FSLeaf v n -> emitI (plain "ftree.leaf" [] [any' (vreg v), OI (fromIntegral n)])
      FSNode o n -> emitI (plain ("ftree." ++ (case o of FAdd -> "add"; FSub -> "sub"; FMul -> "mul"; FDiv -> "div")) [] [OI (fromIntegral n)])
    emitI (plain "ftree.out" [any' r] [OI (fromIntegral root)]))
  OFloat32Tree t -> def (\r -> do
    let (steps, root) = ftreeSchedule t
    forM_ steps $ \case
      FSLeaf v n -> emitI (plain "ftree32.leaf" [] [any' (vreg v), OI (fromIntegral n)])
      FSNode o n -> emitI (plain ("ftree32." ++ (case o of FAdd -> "add"; FSub -> "sub"; FMul -> "mul"; FDiv -> "div")) [] [OI (fromIntegral n)])
    emitI (plain "ftree32.out" [any' r] [OI (fromIntegral root)]))
  OFloat32Cmp o a b -> def (\r -> emitI ((rrr ("fcmp32." ++ (case o of Lt -> "lt"; Gt -> "gt"; Le -> "le"; Ge -> "ge"; Eq -> "eq"; Ne -> "ne")) r (vreg a) (vreg b)) {siFlags = FlagsDef}))
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
    emitI (call ("fpr_prim_fn_" ++ mangleName (if eq then "==" else "!=")) False True [vreg a, vreg b] (Just res))
    emitI (ldrsw r res 4)
    emitL done
  OCall c as -> do
    when (length as > arityCeiling) (refuse ("a call with more than " ++ show arityCeiling ++ " arguments"))
    stageCells (map vreg as)
    def (\r -> emitI (call (calleeSymbol c) (not (isForeign c)) (isForeign c) (map vreg as) (Just r)))
  where
    def k = case d of
      Just (v, _) -> k (vreg v)
      Nothing -> refuse ("internal: " ++ take 20 (show op) ++ " without a definition")
    cond = \case Lt -> "lt"; Gt -> "gt"; Le -> "le"; Ge -> "ge"; Eq -> "eq"; Ne -> "ne"
    -- the NEON pair: q16 holds the lanes, the expression's temporaries take
    -- v17.. in evaluation order (the legacy neonExpr's allocation), the result
    -- is stored back, and Int lanes are checked for the 63-bit fit (the whole
    -- overflow test for one + or - on fitting operands)
    simdPair int e caps base = do
      trap <- freshL "lanes"
      done <- freshL "lanesok"
      emitI (plain "simd.ld" [] [any' base, OI 16])
      (res, _) <- simdGo caps e (17 :: Int)
      emitI (plain "simd.st" [] [any' base, OI (fromIntegral res)])
      when int $ forM_ [0, 8] $ \off -> do
        t <- freshV False
        emitI (plain "load.field" [any' t] [any' base, OI off])
        n <- freshV False
        emitI (rri "sbfx63" n t 0)
        emitI (cmp n t)
        emitI (bcond "ne" trap)
      emitI (jump done)
      emitL trap
      emitI (call "fpr_int_overflow_kernel" False True [] Nothing)
      emitL done
    simdGo caps e next = case e of
      SLane -> pure (16, next)
      SCapture n -> do
        emitI (plain "simd.dup" [] [any' (caps !! n), OI (fromIntegral next)])
        pure (next, next + 1)
      SConst n -> do
        t <- freshV False
        emitI (li t n)
        emitI (plain "simd.dup" [] [any' t, OI (fromIntegral next)])
        pure (next, next + 1)
      SInt o x y -> simdBinary caps (case o of Add -> "simd.add"; Sub -> "simd.sub"; Mul -> "simd.mul"; Div -> "simd.div") x y next
      SFloat o x y -> simdBinary caps (case o of FAdd -> "simd.fadd"; FSub -> "simd.fsub"; FMul -> "simd.fmul"; FDiv -> "simd.fdiv") x y next
    simdBinary caps name x y next = do
      (rx, n1) <- simdGo caps x next
      (ry, n2) <- simdGo caps y n1
      emitI (plain name [] [OI (fromIntegral n2), OI (fromIntegral rx), OI (fromIntegral ry)])
      pure (n2, n2 + 1)
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
          wide <- freshL "wide"
          fitL <- freshL "fit"
          emitI (rrr "mul" t a b)
          -- both operands within 31 bits: the product fits; else the
          -- division check (a zero divisor cannot overflow)
          forM_ [a, b] $ \opnd -> do
            n <- freshV False
            emitI (rri "sbfx31" n opnd 0)
            emitI (cmp n opnd)
            emitI (bcond "ne" wide)
          emitI (jump fitL)
          emitL wide
          emitI (cbz b fitL)
          q <- freshV False
          emitI (rrr "sdiv" q t b)
          emitI (cmp q a)
          emitI (bcond "ne" slow)
          emitL fitL
          fit t slow
        Div -> do
          emitI (cbz b slow)
          emitI (rrr "sdiv" t a b)
          fit t slow
      emitI (mov r t)
      emitI (jump done)
      emitL slow
      if kernel then do
        zero <- freshL "kernelzero"
        when (o == Div) (emitI (cbz b zero))
        emitI (call "fpr_int_overflow_kernel" False True [] Nothing)
        when (o == Div) $ do
          emitL zero
          emitI (call "fpr_div_zero_kernel" False True [] Nothing)
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
        emitI (call (primSymbol o) False True [ta', tb'] (Just res))
        emitI (rri "asr" r res 1)
      emitL done
    -- the 63-bit fit check: sign-extend the low 63 bits and compare
    fit t slow = do
      n <- freshV False
      emitI (rri "sbfx63" n t 0)
      emitI (cmp n t)
      emitI (bcond "ne" slow)
    -- BITSHIFTL / BITSHIFTR (Codegen.inlineTable, shiftOk): a count outside
    -- 0..63 (negative counts included, compared unsigned) takes the slow
    -- path, the HAL entry fpr_g_<name>_call2 with the original operands
    -- retagged, which traps with the primitive's text; the fast path is
    -- the 64-bit shift of the untagged value with the low 63 bits kept
    -- (the legacy `slli 1; ori 1` then `srai 1`)
    shift o r a b = do
      slow <- freshL "shslow"
      done <- freshL "shdone"
      t <- freshV False
      emitI (cmpi b 64)
      emitI (bcond "hs" slow)
      emitI (rrr (case o of Shl -> "lslr"; Shr -> "lsrr") t a b)
      emitI (rri "sbfx63" r t 0)
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
      emitI (call ("fpr_g_" ++ mangleName (shiftName o) ++ "_call2") False True [ta', tb'] (Just res))
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

selectTerm :: A64Config -> Fn -> Block -> Se ()
selectTerm _ fn b = case bTerm b of
  TRet v -> emitI (ret (vreg v))
  TBr target as
    | target == fnEntry fn -> do -- the self tail call: the legacy transfer re-enters the function through its symbol
        stageCells (map vreg as)
        emitI (tailJump (functionSymbol (fnName fn)) True False (map vreg as))
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
    stageCells (map vreg as)
    emitI (tailJump (calleeSymbol c) (not (isForeign c)) (isForeign c) (map vreg as))
  -- a dead arm: the legacy trap if ever reached (`la a0, <str>; call
  -- fpr_panic`, which does not return); the function's text ends here
  TUnreachable msg -> do
    modify (\s -> s {selStrings = S.insert msg (selStrings s)})
    emitI ((plain "panic" [] [OS (stringLabel msg)])
             {siImplicitDefs = [x 0], siClobbers = callerSaved, siControl = Return, siCalls = [Call "fpr_panic" False True]})
  where
    paramsOf bid = [vreg v | blk <- fnBlocks fn, bId blk == bid, (v, _) <- bParams blk]

-- ---- placement, layout, rendering --------------------------------------

-- the frame the runtime's headroom can absorb before the entry check runs:
-- the check comes after the frame decrement, and the hosted runtime keeps
-- FPR_STACK_HEADROOM (64 KiB, runtime/actors.c) below stk_lo for C; half
-- of it is this backend's ceiling, refused by name beyond
frameCeiling :: Int
frameCeiling = 32768

placement :: S.Set VReg -> Placement
placement managed =
  Placement
    { plScratch = \case GPR -> scratchPool; FPR -> [],
      plLoad = \p ref -> plain "ldr" [OP p] [OF ref 0],
      plStore = \p ref -> plain "str" [] [OP p, OF ref 0],
      plSlot = \v@(VReg n) -> frameObj n 8 8 (SpillSlot n) (S.member v managed)
    }

-- the allocator's view of this target (M3)
allocConfig :: Maybe String -> S.Set VReg -> AllocConfig
allocConfig self managed =
  AllocConfig
    { acCalleeSaved = calleeBudget ++ map (Phys . ("d" ++) . show) [8..15 :: Int],
      acCallerSaved = callerPool ++ map (Phys . ("d" ++) . show) [2..7 :: Int],
      acScratch = allocScratch ++ [Phys "d0", Phys "d1"],
      acPreserved = [x 29, Phys "sp", x 28],
      -- x0..x7, then the ninth and later from the hart spill cells
      acArrival = \params -> plain "params" (zipWith fix (take 8 params) (map x [0 ..])) [] : zipWith loadSpill (drop 8 params) [0 ..],
      acLoad = \p ref -> plain "ldr" [OP p] [OF ref 0],
      acStore = \p ref -> plain "str" [] [OP p, OF ref 0],
      acMove = \d s' -> plain (if rfClassOf a64RegisterFile d == Just FPR || rfClassOf a64RegisterFile s' == Just FPR then "fmov" else "mov") [OP d] [OP s'],
      acSlot = \n v -> frameObj n 8 8 (SpillSlot n) (S.member v managed),
      -- every A64 form with a definition and register uses is one
      -- instruction, or writes only its own definition (la: adrp then add);
      -- store.spill reads the hart into x9 before it reads the value it
      -- stores, so that value must not be in x9 (the merge,
      -- docs/2026-10-21-TYPED-IR-MERGE.md)
      acEarlyDef = \i -> siOp i == "store.spill",
      acClassOf = rfClassOf a64RegisterFile,
      acSelfLoop = self
    }

-- Floating results have their own virtual register class. Function/block
-- parameters keep the word ABI; non-float uses receive a bit-preserving move.
-- Tree scratch d16..d23 and SIMD scratch are disjoint from the pool d2..d15.
floatPool :: SFn -> SFn
floatPool fn = fn {sfBody = evalState (concat <$> mapM item (sfBody fn)) start}
  where
    floats = S.fromList [v | I i <- sfBody fn, floatingDef (siOp i), OV v _ <- siDefs i]
    floatingDef op = any (\p -> take (length p) op == p) ["fbin.","fbin32."] || op `elem` ["ftree.out","ftree32.out"]
    start = 1 + maximum (0 : [n | I i <- sfBody fn, OV (VReg n) _ <- siDefs i ++ siUses i])
    fresh :: RegClass -> State Int Operand
    fresh cls = do n <- get; put (n+1); pure (OV (VReg n) (Any cls))
    fp v = OV v (Any FPR)
    asFloat o@(OV v _) | S.member v floats = pure ([], fp v)
                      | otherwise = do t <- fresh FPR; pure ([I (plain "fmov" [t] [o])], t)
    asFloat _ = error "A64 float pool: non-register float operand"
    asWord o@(OV v constraint) | S.member v floats = do
      t <- fresh GPR
      let use = case t of OV w _ -> OV w constraint; _ -> error "A64 pool: invalid fresh operand"
      pure ([I (plain "fmov" [t] [fp v])], use)
                     | otherwise = pure ([],o)
    asWord o = pure ([],o)
    item (ILabel l) = pure [ILabel l]
    item (I i)
      | Just op <- lookupPrefix (siOp i) [("fbin.","pool.bin64."),("fbin32.","pool.bin32."),("fcmp.","pool.cmp64."),("fcmp32.","pool.cmp32.")] = do
          args <- mapM asFloat (siUses i)
          pure (concatMap fst args ++ [I i {siOp=op,siDefs=map def (siDefs i),siUses=map snd args}])
      | siOp i `elem` ["ftree.out","ftree32.out"] = pure [I i {siOp="pool." ++ siOp i,siDefs=map def (siDefs i)}]
      | siOp i `elem` ["ftree.leaf","ftree32.leaf"], OV v _ : rest <- siUses i, S.member v floats =
          pure [I i {siOp="pool." ++ siOp i,siUses=fp v:rest}]
      | otherwise = do
          args <- mapM asWord (siUses i)
          pure (concatMap fst args ++ [I i {siUses=map snd args}])
    def (OV v _) | S.member v floats = fp v
    def o = o
    lookupPrefix _ [] = Nothing
    lookupPrefix op ((old,new):rest) = case stripPrefix old op of Just tail' -> Just (new++tail'); Nothing -> lookupPrefix op rest

-- the saved callee-saved registers as frame objects, one word each,
-- adjacent in creation order so the renderer can pair them
savedObjs :: [Phys] -> [FrameObj]
savedObjs saved = [FrameObj (FrameRef (negate (k + 1))) 8 8 (SavedRegister p) False False | (k, Phys p) <- zip [0 ..] saved]

emitFnA64 :: A64Config -> Fn -> Either String NativeFn
emitFnA64 cfg fn = do
  (sel0, managed, nulls, strs) <- select cfg fn
  let pooled = if polProfile (cfgPolicy cfg) == QosApp || not (tuneFpPool (cfgTune cfg)) then sel0 else floatPool sel0
      fpValues = S.fromList [v | I i <- sfBody pooled, OV v (Any FPR) <- siDefs i ++ siUses i]
      poolManaged = S.difference managed fpValues
      (sel, entrySlots) = forwardEntry (cfgForwardParams cfg && cfgHart cfg /= HartTlvMachO) (tuneEntryArgs (cfgTune cfg)) (map x [0..7]) fn pooled
  either (\e -> Left ("compiler error: " ++ e)) Right (checkFn a64RegisterFile sel)
  let ac = allocConfig (if cfgSelfLoops cfg then Just (functionSymbol (fnName fn)) else Nothing) poolManaged
  alloc <- either (\e -> Left ("compiler error: " ++ e)) Right (allocateFn ac sel)
  either (\e -> Left ("compiler error: " ++ e)) Right (checkAllocation ac (fnName fn) (alBody alloc))
  let saves = savedObjs (alSaved alloc)
      objs = saves ++ alSlots alloc ++ entrySlots
      ordinary = layout 16 16 objs
      large = polStackCheck (cfgPolicy cfg) /= StackStatic && lyBytes ordinary > frameCeiling
      ly = if large then layout 24 16 objs else ordinary
      (shallow, allocatedBody) = shallowEntry (polStackCheck (cfgPolicy cfg)) (lyBytes ly) (alBody alloc)
  when (not large && lyBytes ly > frameCeiling) $
    Left ("a frame of " ++ show (lyBytes ly) ++ " bytes exceeds the " ++ show frameCeiling ++ "-byte ceiling (half the runtime's stack headroom)")
  let name = fnName fn
      sym = functionSymbol name
      -- the prologue: the frame, the callee-saved registers this function
      -- uses, then the arrival copies and the entry sequence (the
      -- parameters are parked before the entry sequence's calls: the
      -- legacy order)
      pairs = savePairs ly saves
      saveItems = [I ((plain "save" [] []) {siNote = show k}) | (k, _) <- zip [0 :: Int ..] pairs]
      wrapped = if tuneShrinkWrap (cfgTune cfg) then shrinkWrap (alSaved alloc) allocatedBody else Nothing
      body = I ((plain "enter" [] []) {siImplicitDefs = [Phys "sp", x 29, x 16]})
        : case wrapped of
            Nothing -> saveItems ++ allocatedBody
            Just items -> concatMap (\it -> case it of I s | siOp s == "saves.here" -> saveItems; _ -> [it]) items
      restores = concatMap (uncurry (pairAccess "ldp" "ldr")) pairs
      reserve = if large then reserveFrame cfg name (toInteger (lyBytes ly)) (length (sfParams sel)) else []
      rendered = map (\it -> (it, renderItem cfg ly large name pairs restores it)) body
      toks = [TIns (length (filter isInstruction reserve)) FNext False
                (1 + if cfgHart cfg == HartTlvMachO then 3 else 0) | large]
             ++ concatMap (uncurry tokOf) rendered
      report = analyse toks
      header =
        ["# fn " ++ name ++ " (arity " ++ show (length (sfParams sel)) ++ ") typed-ir a64 frame=" ++ show (lyBytes ly)
           ++ (if large then " reserve=yes" else "")
           ++ (if shallow then " shallow=yes" else " shallow=no") ++ (if null entrySlots then "" else " forward=yes") ++ (if wrapped == Nothing then "" else " wrapped=yes") ++ " saved=" ++ (case alSaved alloc of [] -> "none"; ps -> intercalate "," (map phys ps)) ++ " " ++ statsLine (alStats alloc)]
          ++ ["    " ++ visibility ++ " " ++ gsym cfg sym | S.member name (cfgExports cfg)]
          ++ [gsym cfg sym ++ ":"]
      visibility = if cfgWeak cfg && '@' `notElem` name then ".weak" else ".globl"
      lines' = header ++ map (\s -> if last s == ':' then s else "    " ++ s) reserve ++ concatMap snd rendered ++ [reportLine name report, ""]
  pure (NativeFn name lines' report (S.toList nulls) (S.toList strs) [])
  where
    tokOf (ILabel (Label l)) _ = [TLabel l]
    tokOf (I i) ls =
      [ TIns
          { tCost = length [() | l <- ls, isInstruction l],
            tFlow = case siControl i of
              Next -> FNext
              CondTo ls' -> FCond [l | Label l <- ls']
              JumpTo (Label l) -> FJump l
              Return -> FExit,
            tReset = any callSafepoint (siCalls i),
            tCCalls = length (filter callRuntime (siCalls i))
          }
      ]
    isInstruction l = case dropWhile (== ' ') l of
      "" -> False
      '#' : _ -> False
      '.' : _ -> False
      t -> last t /= ':'

-- The saved registers grouped for paired accesses: two adjacent words
-- whose lower offset is a multiple of 8 within the signed scaled range of
-- stp/ldp ([-512, 504]) form a pair, written as (registers, lowest
-- offset); a register without a partner, or beyond that range, is a single
-- access (never x27 with x28: x28 is not in the budget).
savePairs :: Layout -> [FrameObj] -> [([String], Integer)]
savePairs ly = go
  where
    off o = fromIntegral (M.findWithDefault (error "A64: a saved register without an offset") (foRef o) (lyOffset ly)) :: Integer
    nameOf o = case foKind o of SavedRegister p -> p; _ -> error "A64: not a saved register"
    go (a : b : rest)
      | off b == off a - 8, pairable (off b), take 1 (nameOf a) == take 1 (nameOf b) = ([nameOf b, nameOf a], off b) : go rest
    go (a : rest) = ([nameOf a], off a) : go rest
    go [] = []
    pairable o = o >= -512 && o <= 504 && o `mod` 8 == 0

-- `stp rb, ra, [x29, #lo]` stores rb at lo and ra at lo+8; `ldp` the reverse
pairAccess :: String -> String -> [String] -> Integer -> [String]
pairAccess paired single regs lo = case regs of
  [b, a] -> [paired ++ " " ++ b ++ ", " ++ a ++ ", [x29, #" ++ show lo ++ "]"]
  [a] -> ldst single (if single == "ldr" then "ldur" else "stur") a "x29" lo
  _ -> error "A64: a save group that is not one or two registers"

-- a C-visible symbol: Mach-O prefixes the underscore; a .L local label
-- becomes the L private prefix there
gsym :: A64Config -> String -> String
gsym cfg s = case cfgFormat cfg of
  MachO | take 2 s == ".L" -> drop 1 s
        | otherwise -> '_' : s
  ELF -> s

-- function-local labels, unique across the unit through the function's symbol
local :: A64Config -> String -> Label -> String
local cfg fname (Label l) = gsym cfg (".Ltir_" ++ mangleName fname ++ "_" ++ l)

phys :: Phys -> String
phys (Phys p) = p

-- No allocated value exists yet: only incoming words and the link must
-- survive reservation. x17 carries the original SP into the full prologue.
-- The TLV lookup uses its documented preservation ABI (all but x0/x16/x17),
-- and hartReadFor parks x0 and the link around that lookup itself.
reserveFrame :: A64Config -> String -> Integer -> Int -> [String]
reserveFrame cfg name bytes argc =
  ["mov x10, sp"] ++ movImm "x11" bytes
  ++ ["cmp x10, x11", "b.lo " ++ slow, "sub x10, x10, x11"]
  ++ hartReadFor cfg
  ++ ["ldr x11, [x9, #456]", "cbz x11, " ++ slow,
      "sub x10, x10, x11", "ldr x11, [x9, #464]", "cmp x10, x11", "b.lo " ++ fast,
      slow ++ ":", "sub sp, sp, #" ++ show stageBytes]
  ++ concat [mem "str" ("x"++show i) "sp" (8*fromIntegral i) | i <- [0..min argc 8-1]]
  ++ mem "str" "x30" "sp" (8*fromIntegral argc)
  ++ hartReadFor cfg
  ++ concat [mem "ldr" "x11" "x9" (8*fromIntegral (i-7)) ++ mem "str" "x11" "sp" (8*fromIntegral i) | i <- [8..argc-1]]
  ++ ["add x0, sp, #" ++ show stageBytes] ++ movImm "x1" bytes
  ++ ["bl " ++ gsym cfg "fpr_stack_reserve", "mov x10, x0"]
  ++ hartReadFor cfg
  ++ concat [mem "ldr" "x11" "sp" (8*fromIntegral i) ++ mem "str" "x11" "x9" (8*fromIntegral (i-7)) | i <- [8..argc-1]]
  ++ concat [mem "ldr" ("x"++show i) "sp" (8*fromIntegral i) | i <- [0..min argc 8-1]]
  ++ mem "ldr" "x30" "sp" (8*fromIntegral argc)
  ++ ["add x17, sp, #" ++ show stageBytes, "cbz x10, " ++ same, "mov sp, x10", "b " ++ ready,
      same ++ ":", "mov sp, x17", "b " ++ ready, fast ++ ":", "mov x17, sp", ready ++ ":"]
  where
    stageBytes = ((fromIntegral (argc+1)*8+15) `div` 16)*16 :: Integer
    mem op = ldst op (if op=="ldr" then "ldur" else "stur")
    label s = local cfg name (Label ("reserve_"++s))
    slow=label "slow";fast=label "fast";same=label "same";ready=label "ready"

renderItem :: A64Config -> Layout -> Bool -> String -> [([String], Integer)] -> [String] -> Item -> [String]
renderItem cfg _ _ fname _ _ (ILabel l) = [local cfg fname l ++ ":"]
renderItem cfg ly large fname pairs restores (I i) = map indent (go (siOp i) (siDefs i) (siUses i))
  where
    indent l = if last l == ':' then l else "    " ++ l -- a pseudo's internal labels stand in column one
    lbl = local cfg fname
    reg = \case
      OP p -> phys p
      o -> error ("A64 render: an unplaced operand " ++ show o)
    sreg o = "s" ++ drop 1 (reg o)
    fpcond c = case c of "lt" -> "mi"; "le" -> "ls"; "gt" -> "gt"; "ge" -> "ge"; "eq" -> "eq"; _ -> "ne"
    wreg o = 'w' : drop 1 (reg o)
    imm = \case
      OI n -> n
      o -> error ("A64 render: not an immediate " ++ show o)
    off ref = M.findWithDefault (error "A64 render: an object without an offset") ref (lyOffset ly)
    go op ds us = case (op, ds, us) of
      ("enter", [], []) -> enter
      ("save", [], []) -> let (regs, lo) = pairs !! read (siNote i) in pairAccess "stp" "str" regs lo
      ("params", _, []) -> [] -- the parameters are where the ABI put them
      ("ldr", [d], [OF ref 0]) -> ldst "ldr" "ldur" (reg d) "x29" (fromIntegral (off ref))
      ("str", [], [s, OF ref 0]) -> ldst "str" "stur" (reg s) "x29" (fromIntegral (off ref))
      ("mov", [d], [s]) -> ["mov " ++ reg d ++ ", " ++ reg s]
      ("li", [d], [n]) -> movImm (reg d) (imm n)
      ("la", [d], [OS s]) -> address (reg d) s
      ("lsl", [d], [s, n]) -> ["lsl " ++ reg d ++ ", " ++ reg s ++ ", #" ++ show (imm n)]
      ("asr", [d], [s, n]) -> ["asr " ++ reg d ++ ", " ++ reg s ++ ", #" ++ show (imm n)]
      ("orri", [d], [s, n]) -> ["orr " ++ reg d ++ ", " ++ reg s ++ ", #" ++ show (imm n)] -- 1: a valid bitmask immediate
      ("andi", [d], [s, n]) -> ["and " ++ reg d ++ ", " ++ reg s ++ ", #" ++ show (imm n)]
      ("eori", [d], [s, n]) -> ["eor " ++ reg d ++ ", " ++ reg s ++ ", #" ++ show (imm n)]
      ("sbfx63", [d], [s, _]) -> ["sbfx " ++ reg d ++ ", " ++ reg s ++ ", #0, #63"]
      ("sbfx31", [d], [s, _]) -> ["sbfx " ++ reg d ++ ", " ++ reg s ++ ", #0, #31"]
      ("load.byte", [d], [base, n]) -> ["ldrb w" ++ drop 1 (reg d) ++ ", [" ++ reg base ++ ", #" ++ show (imm n) ++ "]"]
      ("load.field", [d], [base, n]) -> ldst "ldr" "ldur" (reg d) (reg base) (imm n)
      ("store.field", [], [base, value, n]) -> ldst "str" "stur" (reg value) (reg base) (imm n)
      ("store.header", [], [base, value, n]) -> ["str w" ++ drop 1 (reg value) ++ ", [" ++ reg base ++ ", #" ++ show (imm n) ++ "]"]
      ("ldrsw", [d], [s, n]) -> ["ldursw " ++ reg d ++ ", [" ++ reg s ++ ", #" ++ show (imm n) ++ "]"]
      (o, [d], [a, b]) | o `elem` ["add", "sub", "mul", "sdiv", "and", "eor", "orr"] -> [o ++ " " ++ reg d ++ ", " ++ reg a ++ ", " ++ reg b]
      ("lslr", [d], [a, b]) -> ["lsl " ++ reg d ++ ", " ++ reg a ++ ", " ++ reg b] -- the register-count form (lslv)
      ("lsrr", [d], [a, b]) -> ["lsr " ++ reg d ++ ", " ++ reg a ++ ", " ++ reg b]
      ("cmp", [], [a, b]) -> ["cmp " ++ reg a ++ ", " ++ reg b]
      ("cmpi", [], [a, n]) -> ["cmp " ++ reg a ++ ", #" ++ show (imm n)]
      ('c' : 's' : 'e' : 't' : '.' : c, [d], []) -> ["cset " ++ reg d ++ ", " ++ c]
      ('c' : 's' : 'e' : 'l' : '.' : c, [d], [a, b]) -> ["csel " ++ reg d ++ ", " ++ reg a ++ ", " ++ reg b ++ ", " ++ c]
      ('b' : '.' : c, [], [OL l]) -> ["b." ++ c ++ " " ++ lbl l]
      ("cbz", [], [r, OL l]) -> ["cbz " ++ reg r ++ ", " ++ lbl l]
      ("cbnz", [], [r, OL l]) -> ["cbnz " ++ reg r ++ ", " ++ lbl l]
      ("b", [], [OL l]) -> ["b " ++ lbl l]
      ("jump.loop", [], [OL l]) -> ["b " ++ lbl l]
      ("bl", _, OS s : _) -> ["bl " ++ gsym cfg s]
      ("push", [], [v]) -> ["sub sp, sp, #16", "str " ++ reg v ++ ", [sp]"]
      ("applyn", [_], [OI n]) ->
        [ "mov x2, sp", "mov x1, #" ++ show n, "ldr x0, [sp, #" ++ show (16 * n) ++ "]",
          "bl " ++ gsym cfg "fpr_applyN", "add sp, sp, #" ++ show (16 * (n + 1)) ]
      ("panic", [], [OS s]) -> address "x0" s ++ ["bl " ++ gsym cfg "fpr_panic"]
      ("ret", [], [_]) -> epilogue ++ ["ret"]
      ("tailjump", [], OS s : _) -> epilogue ++ ["b " ++ gsym cfg s]
      ("store.spill", [], [s, OI j]) -> hartRead ++ ldst "str" "stur" (reg s) "x9" (8 * (1 + j))
      ("load.spill", [d], [OI j]) -> hartRead ++ ldst "ldr" "ldur" (reg d) "x9" (8 * (1 + j))
      ("entry.check.tick", _, _) -> hartRead ++ stackCheck ++ tick
      ("entry.check", _, _) -> hartRead ++ stackCheck
      ("entry.tick", _, _) -> hartRead ++ tick
      ("tick.n", _, [OI n]) -> hartRead ++ tickN n
      ("simd.ld", [], [base, OI n]) -> ["ldr q" ++ show n ++ ", [" ++ reg base ++ "]"]
      ("simd.st", [], [base, OI n]) -> ["str q" ++ show n ++ ", [" ++ reg base ++ "]"]
      ("simd.dup", [], [src, OI n]) -> ["dup v" ++ show n ++ ".2d, " ++ reg src]
      (o, [], [OI d, OI a, OI b]) | Just inst <- stripPrefix "simd." o -> [inst ++ " v" ++ show d ++ ".2d, v" ++ show a ++ ".2d, v" ++ show b ++ ".2d"]
      -- F32: the low 32 bits of the word; fmov w<-s zero-extends, as the
      -- legacy translation of fmv.x.w does
      -- a float tree, one step an instruction: scratch d16.., a node in its
      -- left subtree's register
      (o, [d], []) | Just c <- stripPrefix "ftree.cmp." o ->
        ["fcmp d16, d17", "cset " ++ reg d ++ ", " ++ (case c of "lt" -> "mi"; "le" -> "ls"; "gt" -> "gt"; "ge" -> "ge"; "eq" -> "eq"; _ -> "ne")]
      (o, [d], []) | Just c <- stripPrefix "ftree32.cmp." o ->
        ["fcmp s16, s17", "cset " ++ reg d ++ ", " ++ (case c of "lt" -> "mi"; "le" -> "ls"; "gt" -> "gt"; "ge" -> "ge"; "eq" -> "eq"; _ -> "ne")]
      ("fmov", [d], [src]) -> ["fmov " ++ reg d ++ ", " ++ reg src]
      ("pool.ftree.leaf", [], [src, OI n]) -> ["fmov d" ++ show (16+n) ++ ", " ++ reg src]
      ("pool.ftree32.leaf", [], [src, OI n]) -> ["fmov s" ++ show (16+n) ++ ", " ++ sreg src]
      ("pool.ftree.out", [d], [OI n]) -> ["fmov " ++ reg d ++ ", d" ++ show (16+n)]
      ("pool.ftree32.out", [d], [OI n]) -> ["fmov " ++ sreg d ++ ", s" ++ show (16+n)]
      (o, [d], [a,b]) | Just f <- stripPrefix "pool.bin64." o -> ["f" ++ f ++ " " ++ reg d ++ ", " ++ reg a ++ ", " ++ reg b]
      (o, [d], [a,b]) | Just f <- stripPrefix "pool.bin32." o -> ["f" ++ f ++ " " ++ sreg d ++ ", " ++ sreg a ++ ", " ++ sreg b]
      (o, [d], [a,b]) | Just c <- stripPrefix "pool.cmp64." o ->
        ["fcmp " ++ reg a ++ ", " ++ reg b, "cset " ++ reg d ++ ", " ++ fpcond c]
      (o, [d], [a,b]) | Just c <- stripPrefix "pool.cmp32." o ->
        ["fcmp " ++ sreg a ++ ", " ++ sreg b, "cset " ++ reg d ++ ", " ++ fpcond c]
      ("ftree.leaf", [], [x, OI n]) -> ["fmov d" ++ show (16 + n) ++ ", " ++ reg x]
      ("ftree.out", [d], [OI n]) -> ["fmov " ++ reg d ++ ", d" ++ show (16 + n)]
      (o, [], [OI n]) | Just inst <- stripPrefix "ftree." o -> ["f" ++ inst ++ " d" ++ show (16 + n) ++ ", d" ++ show (16 + n) ++ ", d" ++ show (17 + n)]
      ("ftree32.leaf", [], [x, OI n]) -> ["fmov s" ++ show (16 + n) ++ ", " ++ wreg x]
      ("ftree32.out", [d], [OI n]) -> ["fmov " ++ wreg d ++ ", s" ++ show (16 + n)]
      (o, [], [OI n]) | Just inst <- stripPrefix "ftree32." o -> ["f" ++ inst ++ " s" ++ show (16 + n) ++ ", s" ++ show (16 + n) ++ ", s" ++ show (17 + n)]
      (o, [d], [a, b]) | Just f <- stripPrefix "fbin32." o ->
        ["fmov s16, " ++ wreg a, "fmov s17, " ++ wreg b, "f" ++ f ++ " s16, s16, s17", "fmov " ++ wreg d ++ ", s16"]
      (o, [d], [a, b]) | Just c <- stripPrefix "fcmp32." o ->
        ["fmov s16, " ++ wreg a, "fmov s17, " ++ wreg b, "fcmp s16, s17",
         "cset " ++ reg d ++ ", " ++ (case c of "lt" -> "mi"; "le" -> "ls"; "gt" -> "gt"; "ge" -> "ge"; "eq" -> "eq"; _ -> "ne")]
      (o, [d], [a, b]) | Just f <- stripPrefix "fbin." o ->
        ["fmov d16, " ++ reg a, "fmov d17, " ++ reg b, "f" ++ f ++ " d16, d16, d17", "fmov " ++ reg d ++ ", d16"]
      -- the conditions are false when unordered except ne (feq negated)
      (o, [d], [a, b]) | Just c <- stripPrefix "fcmp." o ->
        ["fmov d16, " ++ reg a, "fmov d17, " ++ reg b, "fcmp d16, d17",
         "cset " ++ reg d ++ ", " ++ (case c of "lt" -> "mi"; "le" -> "ls"; "gt" -> "gt"; "ge" -> "ge"; "eq" -> "eq"; _ -> "ne")]
      _ -> error ("A64 render: no form for " ++ op ++ " " ++ show ds ++ " " ++ show us)
    -- the legacy frame: sp down, ra and the caller's fp at the top, fp = old sp
    -- with FPR_TYPED_IR_LINK_PAIRS the link is one stp/ldp when its offset
    -- is in the scaled signed range: the same two words, the same layout
    linkPaired = tuneLinkPairs (cfgTune cfg) && lyBytes ly - 16 <= 504
    enter =
      let n = fromIntegral (lyBytes ly) :: Integer
       in if large then movImm "x16" n ++
            ["sub sp, sp, x16", "add x16, sp, x16", "stur x30, [x16, #-8]",
             "stur x29, [x16, #-16]", "mov x29, x16", "stur x17, [x29, #-24]"]
          else (if n < 4096 then ["sub sp, sp, #" ++ show n] else movImm "x16" n ++ ["sub sp, sp, x16"])
            ++ (if linkPaired then ["stp x29, x30, [sp, #" ++ show (n - 16) ++ "]"]
                else ldst "str" "stur" "x30" "sp" (n - 8) ++ ldst "str" "stur" "x29" "sp" (n - 16))
            ++ (if n < 4096 then ["add x29, sp, #" ++ show n] else ["add x29, sp, x16"])
    -- the callee-saved registers come back first (x29-relative, so after a
    -- stack-segment change they still read the frame they were saved in)
    epilogue = (if siNote i == "norestore" then [] else restores)
      ++ (if linkPaired then ["mov x9, x29", "ldp x29, x30, [x9, #-16]"]
          else ["ldur x30, [x29, #-8]", "mov x9, x29", "ldur x29, [x29, #-16]"])
      ++ ["ldur x9, [x9, #-24]" | large] ++ ["mov sp, x9"]
    base = siNote i
    parkArgs scaled unscaled = concat
      [ldst scaled unscaled (reg o) "x29" (fromIntegral (lyOffset ly M.! FrameRef (entrySlot n)))
      | (n, o) <- zip [0..] (siDefs i)]
    stackCheck =
      [ "mov x10, sp",
        "ldr x11, [x9, #" ++ show (8 * (1 + 56 :: Int)) ++ "]", -- stk_lo
        "sub x10, x10, x11",
        "ldr x11, [x9, #" ++ show (8 * (2 + 56 :: Int)) ++ "]", -- stk_span
        "cmp x10, x11",
        "b.lo " ++ lbl (Label (base ++ "_stk"))
      ] ++ parkArgs "str" "stur" ++ [
        "bl " ++ gsym cfg "fpr_stack_grow",
        "cbz x0, " ++ lbl (Label (base ++ "_same")),
        "mov sp, x0",
        lbl (Label (base ++ "_same")) ++ ":"
      ]
        ++ parkArgs "ldr" "ldur"
        ++ hartRead -- the call clobbered x9
        ++ [lbl (Label (base ++ "_stk")) ++ ":"]
    tick = tickN 1
    tickN n =
      [ "ldur x10, [x9, #0]",
        "sub x10, x10, #" ++ show n,
        "stur x10, [x9, #0]",
        "cmp x10, #0",
        "b.gt " ++ lbl (Label (base ++ "_fuel"))
      ] ++ parkArgs "str" "stur" ++ [
        "bl " ++ gsym cfg "fpr_fuel_exhausted"
      ] ++ parkArgs "ldr" "ldur" ++ [
        lbl (Label (base ++ "_fuel")) ++ ":"
      ]
    -- x9 <- the hart block (A64.hs `mv rd, tp` and deTlsQosAppA64)
    hartRead = hartReadFor cfg
    address d s = case cfgFormat cfg of
      MachO -> let g = gsym cfg s in ["adrp " ++ d ++ ", " ++ g ++ "@PAGE", "add " ++ d ++ ", " ++ d ++ ", " ++ g ++ "@PAGEOFF"]
      ELF -> ["adrp " ++ d ++ ", " ++ s, "add " ++ d ++ ", " ++ d ++ ", :lo12:" ++ s]

hartReadFor :: A64Config -> [String]
hartReadFor cfg = case cfgHart cfg of
  HartX28 -> ["mov x9, x28"]
  HartGlobal -> case cfgFormat cfg of
    MachO -> ["adrp x9, " ++ gsym cfg "fpr_posix_hart" ++ "@PAGE", "ldr x9, [x9, " ++ gsym cfg "fpr_posix_hart" ++ "@PAGEOFF]"]
    ELF -> ["adrp x9, fpr_posix_hart", "ldr x9, [x9, #:lo12:fpr_posix_hart]"]
  HartTlvMachO ->
    [ "sub sp, sp, #16",
      "stp x0, x30, [sp]",
      "adrp x0, _fpr_posix_hart@TLVPPAGE",
      "ldr x0, [x0, _fpr_posix_hart@TLVPPAGEOFF]",
      "ldr x16, [x0]",
      "blr x16",
      "ldr x17, [x0]",
      "ldp x0, x30, [sp]",
      "add sp, sp, #16",
      "mov x9, x17"
    ]
  HartTlsElf ->
    [ "mrs x9, tpidr_el0",
      "add x9, x9, :tprel_hi12:fpr_posix_hart",
      "add x9, x9, :tprel_lo12_nc:fpr_posix_hart",
      "ldr x9, [x9]"
    ]

-- a word load/store at base+off: unscaled within +-256, scaled when
-- positive and a multiple of 8 within the 12-bit field, otherwise through
-- x16 (never an operand register)
ldst :: String -> String -> String -> String -> Integer -> [String]
ldst scaled unscaled r b off
  | off >= -256 && off <= 255 = [unscaled ++ " " ++ r ++ ", [" ++ b ++ ", #" ++ show off ++ "]"]
  | off >= 0 && off `mod` 8 == 0 && off <= 32760 = [scaled ++ " " ++ r ++ ", [" ++ b ++ ", #" ++ show off ++ "]"]
  | otherwise = movImm "x16" off ++ ["add x16, " ++ b ++ ", x16", scaled ++ " " ++ r ++ ", [x16]"]

movImm :: String -> Integer -> [String]
movImm d n
  | n >= -65535 && n <= 65535 = ["mov " ++ d ++ ", #" ++ show n]
  | otherwise =
      let w = fromIntegral n :: Word64
          hws = [(w `shiftR` s) .&. 0xffff | s <- [0, 16, 32, 48]]
       in ("movz " ++ d ++ ", #" ++ show (head hws))
            : ["movk " ++ d ++ ", #" ++ show h ++ ", lsl #" ++ show s | (h, s) <- zip (tail hws) [16 :: Int, 32, 48], h /= 0]

