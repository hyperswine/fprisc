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
--   place    Codegen.Place.placeInSlots: every virtual register in a frame
--            slot of its own, loaded and stored around each instruction;
--            no value is in a register between instructions
--   layout   Codegen.Frame.layout: the legacy frame shape (ra at fp-8, the
--            caller's fp at fp-16, slots below, 16-aligned)
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
--     x19..x28; with nothing in a register between instructions, no value
--     needs a callee-saved register, so this backend saves none (x19..x27
--     are untouched, as the context switch, which saves exactly those and
--     x29, requires);
--   * the entry parks the parameters in their slots before the stack
--     check and the fuel tick, both real C calls;
--   * the overflow and zero-divisor slow paths re-enter the C primitive
--     with the original operands retagged, so the trap text and failure
--     order are the primitive's.
module Codegen.Target.A64
  ( A64Config (..), ObjectFormat (..), HartAccess (..), NativeFn (..),
    a64SelectionRev, emitFnA64, a64RegisterFile, mangleName, functionSymbol,
  ) where

import Codegen.Bounds (Flow (..), Report (..), Tok (..), analyse, reportLine)
import Codegen.Frame
import Codegen.IR
import Codegen.Place
import Codegen.Policy
import Codegen.Selected
import Control.Monad (forM_, unless, when)
import Control.Monad.State.Strict
import Data.Bits (shiftR, (.&.))
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Word (Word64)
import Codegen.Target.Common

-- bump when the selection, placement, layout or rendering changes what is
-- emitted (a unit-cache and run-cache identity component)
a64SelectionRev :: Int
a64SelectionRev = 4 -- coverage: bit operations and shifts; arities 9..64 through the spill cells

-- how generated code reaches the hart block
data HartAccess
  = HartX28 -- hosted AArch64 under fpr build: `mov x9, x28`
  | HartTlvMachO -- Darwin TLV descriptor call: _tlv_get_addr preserves all but x0, x16, x17
  | HartTlsElf -- local-exec TLS: mrs tpidr_el0 and the :tprel: adds
  deriving (Eq, Ord, Show)

data A64Config = A64Config
  { cfgFormat :: ObjectFormat,
    cfgHart :: HartAccess,
    cfgPolicy :: Policy,
    cfgExports :: S.Set String, -- functions that get a visibility directive
    cfgWeak :: Bool -- a library unit: unqualified globals are .weak
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
callerSaved = map x ([0 .. 17] ++ [30])

-- the placement's scratch: caller-saved registers the runtime ABI leaves
-- free and the expansions do not use (x16/x17 are the expansions')
scratchPool :: [Phys]
scratchPool = map x [9 .. 15]

-- ---- selection state ---------------------------------------------------

data Sel = Sel
  { selNext :: Int, -- next virtual register
    selLabel :: Int,
    selItems :: [Item], -- reversed
    selManaged :: S.Set VReg, -- virtual registers that hold tagged words
    selNullaries :: S.Set (Int, Int)
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

-- the prologue's copy of cell j into a parameter's slot: x9 holds the
-- hart block (`hart.x9`, read once after the frame is opened), x10 the value
parkCell :: Int -> FrameRef -> Item
parkCell j ref = I ((plain "park.spill" [] [OI (fromIntegral j), OF ref 0]) {siImplicitDefs = [x 10], siImplicitUses = [x 9]})

hartX9 :: Item
hartX9 = I ((plain "hart.x9" [] []) {siImplicitDefs = [x 9, x 16, x 17]})

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
  _ -> functionSymbol (calleeName c)

nullarySymbol :: Int -> Int -> Se String
nullarySymbol t v = case (t, v) of
  (0, 0) -> pure "fpr_unit"
  (1, 0) -> pure "fpr_false"
  (1, 1) -> pure "fpr_true"
  _ -> do
    modify (\s -> s {selNullaries = S.insert (t, v) (selNullaries s)})
    pure (".Lnul_" ++ show t ++ "_" ++ show v)

select :: A64Config -> Fn -> Either String (SFn, S.Set VReg, S.Set (Int, Int))
select cfg fn = do
  let maxV = maximum (0 : [n | b <- fnBlocks fn, (VId n, _) <- blockDefs b]) + 1
      tyMap = M.fromList (concatMap blockDefs (fnBlocks fn))
      managed0 = S.fromList [vreg v | (v, TVal) <- M.toList tyMap]
      params = [vreg v | (v, _) <- bParams (entryBlock fn)]
      st0 = Sel maxV 0 [] managed0 S.empty
  when (length params > arityCeiling) (Left ("arity above " ++ show arityCeiling))
  (_, st) <- runStateT (mapM_ (selectBlock cfg fn tyMap) (fnBlocks fn)) st0
  pure (SFn (fnName fn) params (reverse (selItems st)), selManaged st, selNullaries st)

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
  OConstInt n -> def (\r -> emitI (li r n))
  ONullary t v -> def (\r -> nullarySymbol t v >>= emitI . la r)
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
  OArith o a b -> def (\r -> arith o r (vreg a) (vreg b))
  -- band/bor/bxor on the untagged values: one instruction, the result fits
  OBit o a b -> def (\r -> emitI (rrr (case o of BAnd -> "and"; BOr -> "orr"; BXor -> "eor") r (vreg a) (vreg b)))
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
    -- checked Int arithmetic: the legacy worker sequences (Codegen.inlineTable,
    -- ScalarChecked): the fast path computes and checks the 63-bit fit, the
    -- slow path retags the ORIGINAL operands and re-enters the C primitive,
    -- whose panic text and failure order are the language's
    arith o r a b = do
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

emitFnA64 :: A64Config -> Fn -> Either String NativeFn
emitFnA64 cfg fn = do
  (sel, managed, nulls) <- select cfg fn
  either (\e -> Left ("compiler error: " ++ e)) Right (checkFn a64RegisterFile sel)
  (placed, objs) <- either (\e -> Left ("compiler error: " ++ e)) Right (placeInSlots (placement managed) sel)
  let ly = layout 16 16 objs
  when (lyBytes ly > frameCeiling) $
    Left ("a frame of " ++ show (lyBytes ly) ++ " bytes exceeds the " ++ show frameCeiling ++ "-byte ceiling (half the runtime's stack headroom)")
  let name = fnName fn
      sym = functionSymbol name
      -- the prologue: the frame, then the parameters into their slots
      -- before the entry sequence's calls (the legacy order): x0..x7, then
      -- the ninth and later from the hart spill cells, which are dead once
      -- copied (the fuel tick may deschedule the actor)
      paramStores = [I (plain "str" [] [OP (x i), OF (slotRef v) 0]) | (i, v) <- zip [0 .. 7] (sfParams placed)]
        ++ (if length (sfParams placed) > 8 then hartX9 : [parkCell j (slotRef v) | (j, v) <- zip [0 ..] (drop 8 (sfParams placed))] else [])
      slotRef (VReg n) = head [foRef o | o <- objs, foKind o == SpillSlot n]
      body = I ((plain "enter" [] []) {siImplicitDefs = [Phys "sp", x 29, x 16]}) : paramStores ++ sfBody placed
      rendered = map (\it -> (it, renderItem cfg ly name it)) body
      toks = concatMap (uncurry tokOf) rendered
      report = analyse toks
      header =
        ["# fn " ++ name ++ " (arity " ++ show (length (sfParams placed)) ++ ") typed-ir a64 frame=" ++ show (lyBytes ly)]
          ++ ["    " ++ visibility ++ " " ++ gsym cfg sym | S.member name (cfgExports cfg)]
          ++ [gsym cfg sym ++ ":"]
      visibility = if cfgWeak cfg && '@' `notElem` name then ".weak" else ".globl"
      lines' = header ++ concatMap snd rendered ++ [reportLine name report, ""]
  pure (NativeFn name lines' report (S.toList nulls))
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

renderItem :: A64Config -> Layout -> String -> Item -> [String]
renderItem cfg _ fname (ILabel l) = [local cfg fname l ++ ":"]
renderItem cfg ly fname (I i) = map indent (go (siOp i) (siDefs i) (siUses i))
  where
    indent l = if last l == ':' then l else "    " ++ l -- a pseudo's internal labels stand in column one
    lbl = local cfg fname
    reg = \case
      OP p -> phys p
      o -> error ("A64 render: an unplaced operand " ++ show o)
    imm = \case
      OI n -> n
      o -> error ("A64 render: not an immediate " ++ show o)
    off ref = M.findWithDefault (error "A64 render: an object without an offset") ref (lyOffset ly)
    go op ds us = case (op, ds, us) of
      ("enter", [], []) -> enter
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
      ("bl", _, OS s : _) -> ["bl " ++ gsym cfg s]
      ("ret", [], [_]) -> epilogue ++ ["ret"]
      ("tailjump", [], OS s : _) -> epilogue ++ ["b " ++ gsym cfg s]
      ("store.spill", [], [s, OI j]) -> hartRead ++ ldst "str" "stur" (reg s) "x9" (8 * (1 + j))
      ("hart.x9", [], []) -> hartRead
      ("park.spill", [], [OI j, OF ref 0]) -> ldst "ldr" "ldur" "x10" "x9" (8 * (1 + j)) ++ ldst "str" "stur" "x10" "x29" (fromIntegral (off ref))
      ("entry.check.tick", [], []) -> hartRead ++ stackCheck ++ tick
      ("entry.check", [], []) -> hartRead ++ stackCheck
      ("entry.tick", [], []) -> hartRead ++ tick
      _ -> error ("A64 render: no form for " ++ op ++ " " ++ show ds ++ " " ++ show us)
    -- the legacy frame: sp down, ra and the caller's fp at the top, fp = old sp
    enter =
      let n = fromIntegral (lyBytes ly) :: Integer
       in (if n < 4096 then ["sub sp, sp, #" ++ show n] else movImm "x16" n ++ ["sub sp, sp, x16"])
            ++ ldst "str" "stur" "x30" "sp" (n - 8)
            ++ ldst "str" "stur" "x29" "sp" (n - 16)
            ++ (if n < 4096 then ["add x29, sp, #" ++ show n] else ["add x29, sp, x16"])
    epilogue = ["ldur x30, [x29, #-8]", "mov x9, x29", "ldur x29, [x29, #-16]", "mov sp, x9"]
    base = siNote i
    stackCheck =
      [ "mov x10, sp",
        "ldr x11, [x9, #" ++ show (8 * (1 + 56 :: Int)) ++ "]", -- stk_lo
        "sub x10, x10, x11",
        "ldr x11, [x9, #" ++ show (8 * (2 + 56 :: Int)) ++ "]", -- stk_span
        "cmp x10, x11",
        "b.lo " ++ lbl (Label (base ++ "_stk")),
        "bl " ++ gsym cfg "fpr_stack_grow",
        "cbz x0, " ++ lbl (Label (base ++ "_same")),
        "mov sp, x0",
        lbl (Label (base ++ "_same")) ++ ":"
      ]
        ++ hartRead -- the call clobbered x9
        ++ [lbl (Label (base ++ "_stk")) ++ ":"]
    tick =
      [ "ldur x10, [x9, #0]",
        "sub x10, x10, #1",
        "stur x10, [x9, #0]",
        "cmp x10, #0",
        "b.gt " ++ lbl (Label (base ++ "_fuel")),
        "bl " ++ gsym cfg "fpr_fuel_exhausted",
        lbl (Label (base ++ "_fuel")) ++ ":"
      ]
    -- x9 <- the hart block (A64.hs `mv rd, tp` and deTlsQosAppA64)
    hartRead = case cfgHart cfg of
      HartX28 -> ["mov x9, x28"]
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
    address d s = case cfgFormat cfg of
      MachO -> let g = gsym cfg s in ["adrp " ++ d ++ ", " ++ g ++ "@PAGE", "add " ++ d ++ ", " ++ d ++ ", " ++ g ++ "@PAGEOFF"]
      ELF -> ["adrp " ++ d ++ ", " ++ s, "add " ++ d ++ ", " ++ d ++ ", :lo12:" ++ s]

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

