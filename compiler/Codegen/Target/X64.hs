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
-- hosted uses ELF TLS; QOS borrows {hart, a6, a7} through fpr_g_tlsoff;
-- macOS uses Mach-O syntax and reaches each cell through its Darwin TLV
-- descriptor (HartTlvMachO, docs/2026-10-24-X64-MACOS.md).
-- Runtime frame pointer = entry rsp + 8, return address fp-8, saved rbp fp-16.
-- Parameters are parked before any entry check/tick, and rsp is restored
-- from rbp at exit to preserve the runtime stack-segment contract.
module Codegen.Target.X64
  ( X64Config (..), X64Hart (..), x64InterfaceRev, x64SelectionRev, emitFnX64, emitFnX64WithSymbols, x64RegisterFile, placement, allocConfig ) where

import qualified Codegen.Calling as Calling
import Codegen.Calling (CallConvention(FprCall), FuelEntry(..), TransferResult(..))
import Codegen.Allocate
import Codegen.Bounds (Flow (..), Report (..), Tok (..), analyse, reportLine)
import Codegen.Frame
import Codegen.IR
import Codegen.Place
import Codegen.Policy
import Codegen.Selected hiding (plain)
import Codegen.Annotation (EntryPoint(..),entryLabel)
import qualified Codegen.Opcode as O
import Codegen.Target.X64.Forms (checkForms)
import Codegen.Target.Common
import Control.Monad (forM_, unless, when)
import Control.Monad.State.Strict
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

x64SelectionRev :: Int
x64SelectionRev = 26 -- the hart-cell load (loop region clock); sized frames; prior: SSE2, comparison/F32 trees, QOS borrowed TLS cells

-- Module ABI identity is independent of native selector/cache revisions.
x64InterfaceRev :: Int
x64InterfaceRev = 10

data X64Hart = HartTls | HartBorrow | HartTlvMachO deriving (Eq, Show)

-- Mach-O is the only object format that reads its cells through TLV
-- descriptors, so the hart form names the format as well.
x64Format :: X64Hart -> ObjectFormat
x64Format = \case HartTlvMachO -> MachO; _ -> ELF

-- a C-visible symbol: Mach-O prefixes the underscore, and a .L local label
-- takes Mach-O's private prefix L (as Common.dataSyntax spells the data)
gsym :: X64Hart -> String -> String
gsym hart s = case x64Format hart of
  MachO | take 2 s == ".L" -> drop 1 s
        | otherwise -> '_' : s
  ELF -> s

data X64Config = X64Config
  { cfgPolicy :: Policy, cfgExports :: S.Set String, cfgWeak :: Bool,
    cfgSelfLoops :: Bool, -- M3: self tail calls as loops (FPR_TYPED_IR_SELF_LOOPS, on unless 0)
    cfgForwardParams :: Bool,
    cfgTune :: Tune,
    cfgHart :: X64Hart
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
callerSaved = Calling.callerClobbers Calling.X86_64
argRegs = Calling.argumentRegisters Calling.X86_64
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
plain :: O.Opcode -> [Operand] -> [Operand] -> SInstr
plain = plainOpcode
any' :: VReg -> Operand
any' v = OV v (Any GPR)
fix :: VReg -> Phys -> Operand
fix v p = OV v (Fix p)
mov :: VReg -> VReg -> SInstr
mov d s = plain (O.X64 O.Move) [any' d] [any' s]
li :: VReg -> Integer -> SInstr
li d n = plain (O.X64 O.Literal) [any' d] [OI n]
la :: VReg -> String -> SInstr
la d s = plain (O.X64 O.Address) [any' d] [OS s]

-- A two-address result occupies the first source's register, after loading
-- that source from its home. Its home is unchanged (no destructive IR use).
rrr :: O.X64Op -> VReg -> VReg -> VReg -> SInstr
rrr op d a b = (plain (O.X64 op) [OV d (Tied 0)] [any' a, any' b]) {siFlags = FlagsDef}
rri :: O.X64Op -> VReg -> VReg -> Integer -> SInstr
rri op d s n = (plain (O.X64 op) [OV d (Tied 0)] [any' s, OI n]) {siFlags = FlagsDef}
ldrsw :: VReg -> VReg -> Integer -> SInstr
ldrsw d s off = plain (O.X64 O.LoadSigned32) [any' d] [any' s, OI off]
cmp :: VReg -> VReg -> SInstr
cmp a b = (plain (O.X64 O.Compare) [] [any' a, any' b]) {siFlags = FlagsDef}
cmpi :: VReg -> Integer -> SInstr
cmpi a n = (plain (O.X64 O.CompareImmediate) [] [any' a, OI n]) {siFlags = FlagsDef}
cset :: O.Condition -> VReg -> SInstr
cset cond d = (plain (O.X64 (O.Set cond)) [any' d] []) {siFlags = FlagsUse}
csel :: O.Condition -> VReg -> VReg -> VReg -> SInstr
csel cond d a b = (plain (O.X64 (O.Select cond)) [OV d (Tied 0)] [any' b, any' a]) {siFlags = FlagsUse}
bcond :: O.Condition -> Label -> SInstr
bcond cond l = (plain (O.X64 (O.Branch cond)) [] [OL l]) {siFlags = FlagsUse, siControl = CondTo [l]}
cbz, cbnz :: VReg -> Label -> SInstr
cbz v l = (plain (O.X64 O.BranchZero) [] [any' v, OL l]) {siFlags = FlagsDef, siControl = CondTo [l]}
cbnz v l = (plain (O.X64 O.BranchNonzero) [] [any' v, OL l]) {siFlags = FlagsDef, siControl = CondTo [l]}
jump :: Label -> SInstr
jump l = (plain (O.X64 O.Jump) [] [OL l]) {siControl = JumpTo l}

-- a variable shift: the count in %rcx (the instruction reads %cl), the
-- value tied to the destination
shiftv :: O.X64Op -> VReg -> VReg -> VReg -> SInstr
shiftv op d a b = (plain (O.X64 op) [OV d (Tied 0)] [any' a, fix b (r "rcx")]) {siFlags = FlagsDef}

-- cqto sign-extends the dividend into rdx before idivq. Placement excludes
-- both fixed rax and implicit rdx when choosing the divisor's register.
divide :: VReg -> VReg -> VReg -> SInstr
divide d a b = (plain (O.X64 O.Divide) [fix d (r "rax")] [fix a (r "rax"), any' b])
  {siImplicitDefs = [r "rdx"], siFlags = FlagsDef}

-- arguments 7 and 8 into the private TLS cells, 9.. into the per-hart
-- spill cells (cell j at 8*(1+j) in the hart block, read into %r10 for
-- each store); every argument is evaluated by now and no call separates
-- these stores from the transfer, so the callee's prologue copies them
stageArgs :: CallConvention -> [VReg] -> Se ()
stageArgs convention args = do
  staged <- either refuse pure (Calling.stagedArguments Calling.X86_64 convention args)
  forM_ [(cell,v) | (Calling.NamedArgument cell,v)<-staged] $ \(cell,v) ->
    emitI ((plain (O.Common O.StoreCell) [] [any' v,OC cell]) {siImplicitDefs=[r "r10",r "r11"]})
  forM_ [(j,v) | (Calling.HartArgument j,v)<-staged] $ \(j,v) ->
    emitI ((plain (O.Common O.StoreSpill) [] [any' v,OI (toInteger j)]) {siImplicitDefs=[r "r10",r "r11"]})

emitCall :: String -> CallConvention -> [VReg] -> Maybe VReg -> Se ()
emitCall sym convention args res = do
  stageArgs convention args
  selected <- either refuse pure (Calling.selectTransfer Calling.X86_64 convention
    (maybe DiscardResult (const WordResult) res) sym args res
    ((plain (O.X64 O.Call) [] []) {siImplicitDefs=[r "rsp"],siFlags=FlagsDef}))
  emitI selected

ret :: VReg -> SInstr
ret v = (plain (O.X64 O.Ret) [] [fix v (r "rax")])
  {siImplicitDefs = map r ["r11", "rbp", "rsp"], siControl = Return}
emitTail :: String -> CallConvention -> [VReg] -> Se ()
emitTail sym convention args = do
  stageArgs convention args
  selected <- either refuse pure (Calling.selectTransfer Calling.X86_64 convention TailTransfer sym args Nothing
    ((plain (O.Common O.TailJump) [] []) {siImplicitDefs=map r ["r11","rbp","rsp"]}))
  emitI selected

entrySeq :: Bool -> Bool -> Label -> SInstr
entrySeq stack fuel (Label base) =
  (plain (O.Common (case (stack, fuel) of (True, True) -> O.EntryCheckTick; (True, False) -> O.EntryCheck; _ -> O.EntryTick)) [] [])
    {siImplicitDefs = map r ["r10", "r11", "rax", "rsp"], siClobbers = callerSaved,
     siFlags = FlagsDef,
     siCalls = [Call "fpr_stack_grow" False True | stack] ++ [Call "fpr_fuel_exhausted" True False | fuel],
     siAnnotation = EntryLabels (Label base)}

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
selectInstr cfg _ (Instr d op) = case op of
  OStackCheck -> refuse "internal: a stack check reached selection"
  OSafepoint -> freshL "tick" >>= emitI . entrySeq False True -- an inlined callee's tick mid-block
  OSafepointN n -> freshL "tick" >>= \l -> emitI ((entrySeq False True l) {siOpcode = O.Common O.TickN, siUses = [OI (fromIntegral n)]})
  OSimdPair int e caps a -> do
    when (simdRegisters e > 7) (refuse "an SSE2 pair exceeds seven scratch temporaries")
    simdPair int e (map vreg caps) (vreg a)
  ORvvVlMax -> refuse "a RISC-V vector length on x86-64"
  ORvvLanes _ _ -> refuse "RISC-V vector lanes on x86-64"
  ORvvSumLoaded _ -> refuse "a RISC-V vector sum on x86-64"
  OAddress v -> def (\r -> emitI (mov r (vreg v)))
  OIndex a i -> def $ \r -> do
    offset <- freshV False
    emitI (rri O.ShiftLeftImmediate offset (vreg i) 3)
    emitI (rrr O.Add r (vreg a) offset)
  OLoad _ a n -> def (\r -> emitI (plain (O.X64 O.LoadField) [any' r] [any' (vreg a), OI (fromIntegral n)]))
  OLoadByte a n -> def (\r -> emitI (plain (O.X64 O.LoadByte) [any' r] [any' (vreg a), OI (fromIntegral n)]))
  OStore _ a n v -> emitI (plain (O.X64 O.StoreField) [] [any' (vreg a), any' (vreg v), OI (fromIntegral n)])
  OConstInt n -> def (\r -> emitI (li r n))
  OHartCell j -> def (\r -> emitI (plain (O.Common O.LoadSpill) [any' r] [OI (fromIntegral j)]))
  ORegionRoom mark -> def $ \r -> do
    clock <- freshV False
    used <- freshV False
    scaled <- freshV False
    untagged <- freshV False
    emitI (plain (O.Common O.LoadSpill) [any' clock] [OI 58])
    emitI (rri O.ShiftRightArithmeticImmediate untagged (vreg mark) 1) -- the mark is a tagged Int
    emitI (rrr O.Subtract used clock untagged)
    emitI (rri O.ShiftLeftImmediate scaled used 3)
    emitI (cmpi scaled (65536 * 8))
    emitI (cset O.UnsignedBelow r)
  OBits n -> def (\r -> emitI (li r n))
  ONullary t v -> def (\r -> nullarySymbol t v >>= emitI . la r)
  OString text -> def $ \rd -> do
    modify (\st -> st {selStrings = S.insert text (selStrings st)})
    emitI (la rd (stringLabel text))
  OMake tid variant fields -> def $ \rd -> do
    size <- freshV False
    emitI (li size (8 + 8 * fromIntegral (length fields)))
    emitCall "fpr_alloc" Calling.RuntimeCall [size] (Just rd)
    forM_ [(0, tid), (4, variant)] $ \(offset, value) -> do
      header <- freshV False
      emitI (li header (fromIntegral value))
      emitI (plain (O.X64 O.StoreHeader) [] [any' rd, any' header, OI offset])
    forM_ (zip [0..] fields) $ \(index, value) ->
      emitI (plain (O.X64 O.StoreField) [] [any' rd, any' (vreg value), OI (8 + 8 * index)])
  OReuse _ _ root fields -> def $ \rd -> do
    forM_ (zip [0..] fields) $ \(index, value) ->
      emitI (plain (O.X64 O.StoreField) [] [any' (vreg root), any' (vreg value), OI (8 + 8 * index)])
    emitI (mov rd (vreg root))
  OField index obj -> def $ \rd ->
    emitI (plain (O.X64 O.LoadField) [any' rd] [any' (vreg obj), OI (8 + 8 * fromIntegral index)])
  OStrLen str -> def $ \rd -> do
    tagged <- freshV True
    emitCall "fpr_g_strlen_call1" Calling.RuntimeCall [vreg str] (Just tagged)
    emitI (rri O.ShiftRightArithmeticImmediate rd tagged 1)
  OCharAt str index -> def $ \rd -> do
    shifted <- freshV False
    taggedIndex <- freshV True
    taggedResult <- freshV True
    emitI (rri O.ShiftLeftImmediate shifted (vreg index) 1)
    emitI (rri O.OrImmediate taggedIndex shifted 1)
    emitCall "fpr_g_charAt_call2" Calling.RuntimeCall [vreg str, taggedIndex] (Just taggedResult)
    emitI (rri O.ShiftRightArithmeticImmediate rd taggedResult 1)
  OSymbol sym -> def (\r -> emitI (la r sym)) -- an immutable symbol address
  OFunValue n -> def (\r -> emitI (la r ("fpr_obj_" ++ mangleName n)))
  -- the generic application: the head then every argument pushed 16 bytes
  -- apart (the last at the stack pointer), fpr_applyN(head, n, &args) with
  -- the call-alignment adjustment, the pushes popped; slots are %rbp-relative
  OApply f as -> def $ \rd -> do
    forM_ (f : as) $ \v -> emitI ((plain (O.X64 O.Push) [] [any' (vreg v)]) {siImplicitDefs = [r "rsp"]})
    emitI ((plain (O.X64 O.ApplyN) [fix rd (r "rax")] [OI (fromIntegral (length as))])
             { siImplicitDefs = map r ["rdi", "rsi", "rdx", "rsp"], siClobbers = filter (/= r "rax") callerSaved,
               siFlags = FlagsDef, siCalls = [Call "fpr_applyN" False True] })
  OTag v -> def $ \r -> do
    t <- freshV False
    emitI (rri O.ShiftLeftImmediate t (vreg v) 1)
    emitI (rri O.OrImmediate r t 1)
  OUntag v -> def (\r -> emitI (rri O.ShiftRightArithmeticImmediate r (vreg v) 1))
  OBoolOf p -> def $ \r -> do
    f <- freshV True
    t <- freshV True
    emitI (la f "fpr_false")
    emitI (la t "fpr_true")
    emitI (cmpi (vreg p) 0)
    emitI (csel O.NotEqual r t f)
  OTruth v -> def (\r -> emitI (ldrsw r (vreg v) 4))
  ONot p -> def (\r -> emitI (rri O.XorImmediate r (vreg p) 1))
  OIsInt v -> def (\r -> emitI (rri O.AndImmediate r (vreg v) 1))
  OTagTest t c v -> def $ \r -> do
    miss <- freshL "tagno"
    done <- freshL "tagdone"
    bit <- freshV False
    emitI (rri O.AndImmediate bit (vreg v) 1)
    emitI (cbnz bit miss)
    tid <- freshV False
    want <- freshV False
    emitI (ldrsw tid (vreg v) 0)
    emitI (li want (fromIntegral t))
    emitI (cmp tid want)
    emitI (bcond O.NotEqual miss)
    var <- freshV False
    wantv <- freshV False
    emitI (ldrsw var (vreg v) 4)
    emitI (li wantv (fromIntegral c))
    emitI (cmp var wantv)
    emitI (cset O.Equal r)
    emitI (jump done)
    emitL miss
    emitI (li r 0)
    emitL done
  OKernelArith o a b -> def (\r -> arith True o r (vreg a) (vreg b))
  OArith o a b -> def (\r -> arith False o r (vreg a) (vreg b))
  -- band/bor/bxor on the untagged values: one instruction, the result fits
  OBit o a b -> def (\r -> emitI (rrr (case o of BAnd -> O.And; BOr -> O.Or; BXor -> O.Xor) r (vreg a) (vreg b)))
  -- F64 on the bits through xmm14/xmm15, inside the expansion only (SysV:
  -- caller-saved; no float register is allocated)
  OFloatBin o a b -> def (\r -> emitI (plain (O.X64 (O.FloatBinary O.Float64 o)) [any' r] [any' (vreg a), any' (vreg b)]))
  OFloatCmp o a b -> def (\r -> emitI ((plain (O.X64 (O.FloatCompare O.Float64 o)) [any' r] [any' (vreg a), any' (vreg b)]) {siFlags = FlagsDef}))
  OFloat32Bin o a b -> def (\r -> emitI (plain (O.X64 (O.FloatBinary O.Float32 o)) [any' r] [any' (vreg a), any' (vreg b)]))
  OFloatCmpTree o x y -> def (\r -> do
    forM_ (ftreeScheduleAt 0 x ++ ftreeScheduleAt 1 y) $ \case
      FSLeaf v n -> emitI (plain (O.X64 (O.TreeLeaf O.Float64)) [] [any' (vreg v), OI (fromIntegral n)])
      FSNode f n -> emitI (plain (O.X64 (O.TreeNode O.Float64 f)) [] [OI (fromIntegral n)])
    emitI ((plain (O.X64 (O.TreeCompare O.Float64 o)) [any' r] []) {siFlags = FlagsDef}))
  OFloat32CmpTree o x y -> def (\r -> do
    forM_ (ftreeScheduleAt 0 x ++ ftreeScheduleAt 1 y) $ \case
      FSLeaf v n -> emitI (plain (O.X64 (O.TreeLeaf O.Float32)) [] [any' (vreg v), OI (fromIntegral n)])
      FSNode f n -> emitI (plain (O.X64 (O.TreeNode O.Float32 f)) [] [OI (fromIntegral n)])
    emitI ((plain (O.X64 (O.TreeCompare O.Float32 o)) [any' r] []) {siFlags = FlagsDef}))
  OFloatTree t -> def (\r -> do
    let (steps, root) = ftreeSchedule t
    forM_ steps $ \case
      FSLeaf v n -> emitI (plain (O.X64 (O.TreeLeaf O.Float64)) [] [any' (vreg v), OI (fromIntegral n)])
      FSNode o n -> emitI (plain (O.X64 (O.TreeNode O.Float64 o)) [] [OI (fromIntegral n)])
    emitI (plain (O.X64 (O.TreeOutput O.Float64)) [any' r] [OI (fromIntegral root)]))
  OFloat32Tree t -> def (\r -> do
    let (steps, root) = ftreeSchedule t
    forM_ steps $ \case
      FSLeaf v n -> emitI (plain (O.X64 (O.TreeLeaf O.Float32)) [] [any' (vreg v), OI (fromIntegral n)])
      FSNode o n -> emitI (plain (O.X64 (O.TreeNode O.Float32 o)) [] [OI (fromIntegral n)])
    emitI (plain (O.X64 (O.TreeOutput O.Float32)) [any' r] [OI (fromIntegral root)]))
  OFloat32Cmp o a b -> def (\r -> emitI ((plain (O.X64 (O.FloatCompare O.Float32 o)) [any' r] [any' (vreg a), any' (vreg b)]) {siFlags = FlagsDef}))
  OShift o a b -> def (\r -> shift o r (vreg a) (vreg b))
  OCmp o a b -> def $ \r -> do
    emitI (cmp (vreg a) (vreg b))
    emitI (cset (cond o) r)
  OEqVal eq a b -> def $ \r -> do
    slow <- freshL "eqslow"
    done <- freshL "eqdone"
    both <- freshV False
    bit <- freshV False
    emitI (rrr O.And both (vreg a) (vreg b))
    emitI (rri O.AndImmediate bit both 1)
    emitI (cbz bit slow)
    emitI (cmp (vreg a) (vreg b))
    emitI (cset (if eq then O.Equal else O.NotEqual) r)
    emitI (jump done)
    emitL slow
    res <- freshV True
    emitCall ("fpr_prim_fn_" ++ mangleName (if eq then "==" else "!=")) Calling.RuntimeCall [vreg a, vreg b] (Just res)
    emitI (ldrsw r res 4)
    emitL done
  OCall c as -> do
    when (length as > arityCeiling) (refuse ("a call with more than " ++ show arityCeiling ++ " arguments"))
    def (\r -> emitCall (calleeSymbol c) (Calling.calleeCall (cfgPolicy cfg) c) (map vreg as) (Just r))
  where
    def k = case d of
      Just (v, _) -> k (vreg v)
      Nothing -> refuse ("internal: " ++ take 20 (show op) ++ " without a definition")
    cond = \case Lt -> O.Less; Gt -> O.Greater; Le -> O.LessEqual; Ge -> O.GreaterEqual; Eq -> O.Equal; Ne -> O.NotEqual
    -- xmm8 holds two lanes; xmm9..xmm15 are expression temporaries.
    -- Every selected broadcast has one word operand, keeping reloads bounded.
    simdPair int e caps base = do
      trap <- freshL "lanes"
      done <- freshL "lanesok"
      emitI (plain (O.X64 O.PairLoad) [] [any' base, OI 8])
      (res,_) <- simdGo caps e (9 :: Int)
      emitI (plain (O.X64 O.PairStore) [] [any' base, OI (fromIntegral res)])
      when int $ forM_ [0,8] $ \off -> do
        t <- freshV False
        emitI (plain (O.X64 O.LoadField) [any' t] [any' base, OI off])
        fit t trap
      emitI (jump done)
      emitL trap
      emitCall "fpr_int_overflow_kernel" Calling.RuntimeCall [] Nothing
      emitL done
    simdGo caps e next = case e of
      SLane -> pure (8,next)
      SCapture n -> do
        emitI (plain (O.X64 O.PairDuplicate) [] [any' (caps !! n), OI (fromIntegral next)])
        pure (next,next+1)
      SConst n -> do
        t <- freshV False
        emitI (li t n)
        emitI (plain (O.X64 O.PairDuplicate) [] [any' t, OI (fromIntegral next)])
        pure (next,next+1)
      SInt op a b -> case op of
        Add -> simdBinary caps O.PairAdd a b next
        Sub -> simdBinary caps O.PairSub a b next
        _ -> refuse "an SSE2 Int pair supports only add/subtract"
      SFloat op a b -> case op of
        FAdd -> simdBinary caps O.PairFloatAdd a b next
        FSub -> simdBinary caps O.PairFloatSub a b next
        FMul -> simdBinary caps O.PairFloatMul a b next
        FDiv -> refuse "an SSE2 pair division is outside the SIMD proof"
    simdBinary caps op a b next = do
      (ra,n1) <- simdGo caps a next
      (rb,n2) <- simdGo caps b n1
      emitI (plain (O.X64 (O.PairBinary op)) [] [OI (fromIntegral n2),OI (fromIntegral ra),OI (fromIntegral rb)])
      pure (n2,n2+1)
    -- Checked Int arithmetic agrees with Codegen.Eval and runtime/runtime.c:
    -- the fast path computes and checks the 63-bit fit, the
    -- slow path retags the ORIGINAL operands and re-enters the C primitive,
    -- whose panic text and failure order are the language's
    arith kernel o r a b = do
      slow <- freshL "slow"
      done <- freshL "done"
      t <- freshV False
      case o of
        Add -> emitI (rrr O.Add t a b) >> fit t slow
        Sub -> emitI (rrr O.Subtract t a b) >> fit t slow
        Mul -> do
          emitI (rrr O.Multiply t a b)
          emitI (bcond O.Overflow slow) -- full 64-bit overflow, then 63-bit language fit
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
        emitCall "fpr_int_overflow_kernel" Calling.RuntimeCall [] Nothing
        when (o == Div) $ do
          emitL zero
          emitCall "fpr_div_zero_kernel" Calling.RuntimeCall [] Nothing
        -- Both entries are noreturn. Define the result on the impossible
        -- continuation as well so the allocation oracle needs no exception.
        emitI (li r 0)
      else do
        ta <- freshV False
        ta' <- freshV True
        tb <- freshV False
        tb' <- freshV True
        emitI (rri O.ShiftLeftImmediate ta a 1)
        emitI (rri O.OrImmediate ta' ta 1)
        emitI (rri O.ShiftLeftImmediate tb b 1)
        emitI (rri O.OrImmediate tb' tb 1)
        res <- freshV True
        emitCall (primSymbol o) Calling.RuntimeCall [ta', tb'] (Just res)
        emitI (rri O.ShiftRightArithmeticImmediate r res 1)
      emitL done
    -- the 63-bit fit check: sign-extend the low 63 bits and compare
    fit t slow = do
      n <- freshV False
      emitI (rri O.SignExtend63 n t 0)
      emitI (cmp n t)
      emitI (bcond O.NotEqual slow)
    -- BITSHIFTL / BITSHIFTR agree with runtime/bits.c: a count outside
    -- 0..63 (negative counts included, compared unsigned) takes the slow
    -- path, the HAL entry fpr_g_<name>_call2 with the original operands
    -- retagged, which traps with the primitive's text; the fast path is
    -- the 64-bit shift (%cl) of the untagged value with the low 63 bits kept
    shift o r a b = do
      slow <- freshL "shslow"
      done <- freshL "shdone"
      t <- freshV False
      emitI (cmpi b 64)
      emitI (bcond O.UnsignedAboveEqual slow)
      emitI (shiftv (case o of Shl -> O.ShiftLeft; Shr -> O.ShiftRight) t a b)
      emitI (rri O.SignExtend63 r t 0)
      emitI (jump done)
      emitL slow
      ta <- freshV False
      ta' <- freshV True
      tb <- freshV False
      tb' <- freshV True
      emitI (rri O.ShiftLeftImmediate ta a 1)
      emitI (rri O.OrImmediate ta' ta 1)
      emitI (rri O.ShiftLeftImmediate tb b 1)
      emitI (rri O.OrImmediate tb' tb 1)
      res <- freshV True
      emitCall ("fpr_g_" ++ mangleName (shiftName o) ++ "_call2") Calling.RuntimeCall [ta', tb'] (Just res)
      emitI (rri O.ShiftRightArithmeticImmediate r res 1)
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
selectTerm cfg fn b = case bTerm b of
  TRet v -> emitI (ret (vreg v))
  TBr target as
    | target == fnEntry fn -> -- a self tail transfer re-enters through the function symbol
        emitTail (functionSymbol (fnName fn)) (FprCall TicksFuel) (map vreg as)
    | otherwise -> do
        parallelMoves (zip (paramsOf target) (map vreg as))
        emitI (jump (blockLabel target))
  TCondBr p t as e bs
    | null as && null bs, Just e == nextBlock -> emitI (cbnz (vreg p) (blockLabel t))
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
    emitTail (calleeSymbol c) (Calling.calleeCall (cfgPolicy cfg) c) (map vreg as)
  -- A reached dead arm calls fpr_panic with its reason. It does not
  -- return; the function's text ends here
  TUnreachable msg -> do
    modify (\s -> s {selStrings = S.insert msg (selStrings s)})
    emitI ((plain (O.X64 O.Panic) [] [OS (stringLabel msg)])
             {siImplicitDefs = map r ["rdi", "rsp"], siClobbers = callerSaved, siControl = Return, siCalls = [Call "fpr_panic" False True]})
  where
    paramsOf bid = [vreg v | blk <- fnBlocks fn, bId blk == bid, (v, _) <- bParams blk]
    nextBlock = case dropWhile ((/= bId b) . bId) (fnBlocks fn) of
      (_ : n : _) -> Just (bId n)
      _ -> Nothing

-- ---- placement, frame layout and rendering ------------------------------
placement :: S.Set VReg -> Placement
placement managed = Placement
  { plScratch = \case GPR -> scratchPool; FPR -> [],
    plLoad = \p ref -> plain (O.X64 O.FrameLoad) [OP p] [OF ref 0],
    plStore = \p ref -> plain (O.X64 O.FrameStore) [] [OP p, OF ref 0],
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
      let placed=Calling.arrivalArguments Calling.X86_64 params
      in plain (O.Common O.Params) [fix v p | (Calling.ArgumentRegister p,v)<-placed] []
        : [plain (O.Common O.LoadCell) [any' v] [OC cell] | (Calling.NamedArgument cell,v)<-placed]
        ++ [plain (O.Common O.LoadSpill) [any' v] [OI (toInteger j)] | (Calling.HartArgument j,v)<-placed],
    acLoad = \p ref -> plain (O.X64 O.FrameLoad) [OP p] [OF ref 0],
    acStore = \p ref -> plain (O.X64 O.FrameStore) [] [OP p, OF ref 0],
    acMove = \d s' -> plain (O.X64 O.Move) [OP d] [OP s'],
    acSlot = \n v -> frameObj n 8 8 (SpillSlot n) (S.member v managed),
    -- cqto writes rdx before idivq reads the divisor
    -- store.spill writes a scratch register before it reads the value
    acEarlyDef = \i -> siOpcode i `elem` [O.X64 O.Divide, O.Common O.StoreSpill, O.Common O.StoreCell],
    acClassOf = rfClassOf x64RegisterFile,
    acSelfLoop = self }

savedObjs :: [Phys] -> [FrameObj]
savedObjs saved = [FrameObj (FrameRef (negate (k + 1))) 8 8 (SavedRegister p) False False | (k, Phys p) <- zip [0 ..] saved]

emitFnX64 :: X64Config -> Fn -> Either String NativeFn
emitFnX64 cfg=emitFnX64WithSymbols (publicSymbols (cfgExports cfg)) cfg

emitFnX64WithSymbols :: SymbolPolicy -> X64Config -> Fn -> Either String NativeFn
emitFnX64WithSymbols symbols cfg fn = do
  (sel0, managed, nulls, strs) <- select cfg fn
  let (sel, entrySlots) = forwardEntry (cfgForwardParams cfg) (tuneEntryArgs (cfgTune cfg)) argRegs fn sel0
  checkForms (fnName fn) (sfBody sel)
  either (Left . ("compiler error: " ++)) Right (checkFn x64RegisterFile sel)
  let ac = allocConfig (if cfgSelfLoops cfg then Just (functionSymbol (fnName fn)) else Nothing) managed
  alloc <- either (Left . ("compiler error: " ++)) Right (allocateFn ac sel)
  either (Left . ("compiler error: " ++)) Right (checkAllocation ac (fnName fn) (alBody alloc))
  let saves = savedObjs (alSaved alloc)
      objs = saves ++ alSlots alloc ++ entrySlots
      ordinary = layout 16 16 objs
      large = polStackCheck (cfgPolicy cfg) /= StackStatic && lyBytes ordinary > 32768
      ly = if large then layout 24 16 objs else ordinary
      (shallow, allocatedBody) = shallowEntry (polStackCheck (cfgPolicy cfg)) (lyBytes ly) (alBody alloc)
  when (not large && lyBytes ly > 32768) $ Left ("a frame of " ++ show (lyBytes ly) ++ " bytes exceeds the 32768-byte ceiling (half the runtime's stack headroom)")
  let name = fnName fn
      sym = gsym (cfgHart cfg) (functionSymbol name)
      saveOff o = show (M.findWithDefault (error "X64: a saved register without an offset") (foRef o) (lyOffset ly)) ++ "(%rbp)"
      saveLines = ["movq %" ++ p ++ ", " ++ saveOff o | o <- saves, SavedRegister p <- [foKind o]]
      restores = ["movq " ++ saveOff o ++ ", %" ++ p | o <- saves, SavedRegister p <- [foKind o]]
      body = I ((plain (O.X64 O.Enter) [] []) {siImplicitDefs = map r (["rsp", "rbp"] ++ [p | large,p <- ["rax","r11"]])})
        : [I (plain (O.X64 O.Save) [] []) | not (null saves)]
        ++ allocatedBody
      reserve = if large then reserveFrame (cfgHart cfg) name (toInteger (lyBytes ly)) (length (sfParams sel)) else []
      rendered = [(it, renderItem (cfgHart cfg) ly large name saveLines restores it) | it <- body]
      report = analyse ([TIns (length (filter isInstruction reserve)) FNext False 1 | large] ++ concatMap (uncurry tokOf) rendered)
      header = ["# fn " ++ name ++ " (arity " ++ show (length (sfParams sel)) ++ ") typed-ir x64 frame=" ++ show (lyBytes ly)
                  ++ (if large then " reserve=yes" else "")
                  ++ (if shallow then " shallow=yes" else " shallow=no") ++ (if null entrySlots then "" else " forward=yes") ++ " saved=" ++ (case alSaved alloc of [] -> "none"; ps -> intercalate "," [p | Phys p <- ps]) ++ " " ++ statsLine (alStats alloc)]
        ++ visibilityLines (x64Format (cfgHart cfg)) (if x64Format (cfgHart cfg)==MachO then WeakDefinitionDirective else WeakDirective) (visibilityFor (cfgWeak cfg) symbols name) sym ++ [sym ++ ":"]
  checkForms name body
  pure (NativeFn name (header ++ map (\s -> if last s==':' then s else "    "++s) reserve ++ concatMap snd rendered ++ [reportLine name report, ""]) report (S.toList nulls) (S.toList strs) [])
  where
    tokOf (ILabel (Label l)) _ = [TLabel l]
    tokOf (I i) ls = [TIns
      { tCost = length [() | l <- ls, isInstruction l],
        tFlow = case siControl i of
          Next -> FNext; CondTo labels -> FCond [l | Label l <- labels]; JumpTo (Label l) -> FJump l; Return -> FExit,
        tReset = any callSafepoint (siCalls i), tCCalls = length (filter callRuntime (siCalls i)) }]
    isInstruction l = case dropWhile (== ' ') l of
      "" -> False; '#':_ -> False; '.':_ -> False; t -> last t /= ':'

local :: X64Hart -> String -> Label -> String
local hart fname (Label l) = gsym hart (".Ltir_" ++ mangleName fname ++ "_" ++ l)

-- The caller's return PC remains on the original stack. A new segment gets
-- a copy for the ordinary frame header, while the third header word restores
-- the original entry RSP on every return or tail transfer. Include that PC
-- word in the new-top reservation. The staging frame aligns RSP for C.
reserveFrame :: X64Hart -> String -> Integer -> Int -> [String]
reserveFrame hart name bytes argc =
  ["movabsq $" ++ show (bytes+8) ++ ", %r11", "cmpq %r11, %rsp", "jb " ++ slow,
   "negq %r11", "addq %rsp, %r11"] ++ loadCellFor hart HartPointer "%r10"
  ++ ["cmpq $0, 456(%r10)", "je " ++ slow, "subq 456(%r10), %r11",
      "cmpq 464(%r10), %r11", "jb " ++ fast, slow ++ ":", "subq $" ++ show stageBytes ++ ", %rsp"]
  ++ ["movq %" ++ reg ++ ", " ++ slot i | (i,Phys reg) <- zip [0..] (take argc argRegs)]
  ++ concat [loadCellFor hart cell "%r10" ++ ["movq %r10, " ++ slot i] | (i,cell) <- named]
  ++ loadCellFor hart HartPointer "%r10"
  ++ concat [["movq " ++ show (8*(i-7)) ++ "(%r10), %r11", "movq %r11, " ++ slot i] | i <- [8..argc-1]]
  ++ ["leaq " ++ show stageBytes ++ "(%rsp), %rdi", "movabsq $" ++ show (bytes+8) ++ ", %rsi",
      "call " ++ gsym hart "fpr_stack_reserve"]
  ++ loadCellFor hart HartPointer "%r10"
  ++ concat [["movq " ++ slot i ++ ", %r11", "movq %r11, " ++ show (8*(i-7)) ++ "(%r10)"] | i <- [8..argc-1]]
  ++ concat [["movq " ++ slot i ++ ", %r11"] ++ storeCellFor hart cell "%r11" | (i,cell) <- named]
  ++ ["movq " ++ slot i ++ ", %" ++ reg | (i,Phys reg) <- zip [0..] (take argc argRegs)]
  ++ ["leaq " ++ show stageBytes ++ "(%rsp), %r10", "testq %rax, %rax", "jz " ++ same,
      "movq (%r10), %r11", "movq %r11, -8(%rax)", "leaq -8(%rax), %rsp", "jmp " ++ ready,
      same ++ ":", "movq %r10, %rsp", "jmp " ++ ready, fast ++ ":", "movq %rsp, %r10", ready ++ ":"]
  where
    stageBytes = ((argc*8+15) `div` 16)*16+8
    slot i = show (i*8) ++ "(%rsp)"
    named = take (max 0 (argc-6)) [(6,ArgumentCell Calling.Argument7),(7,ArgumentCell Calling.Argument8)]
    label s = local hart name (Label ("reserve_"++s))
    slow=label "slow";fast=label "fast";same=label "same";ready=label "ready"

-- The renderer receives roles, never strings to decode as protocol tags.
data TlsCell = HartPointer | ArgumentCell Calling.ArgumentCell
cellName :: TlsCell -> String
cellName HartPointer="fpr_posix_hart"
cellName (ArgumentCell cell)=Calling.cellSymbol cell
cellOff :: TlsCell -> String
cellOff HartPointer="0"
cellOff (ArgumentCell cell)=show (Calling.cellOffset cell)
loadCellFor :: X64Hart -> TlsCell -> String -> [String]
loadCellFor hart cell dst = case hart of
  HartTls -> ["movq %fs:" ++ cellName cell ++ "@tpoff, " ++ dst]
  HartBorrow -> ["movq fpr_g_tlsoff(%rip), " ++ dst,
                 "movq %fs:" ++ cellOff cell ++ "(" ++ dst ++ "), " ++ dst]
  HartTlvMachO -> tlvSave ++ tlvAddress (cellName cell)
    ++ ["movq (%rax), %rax", "movq %rax, (%rsp)"] ++ tlvRestore ++ ["movq (%rsp), " ++ dst, "leaq 32(%rsp), %rsp"]
storeCellFor :: X64Hart -> TlsCell -> String -> [String]
storeCellFor hart cell src = case hart of
  HartTls -> ["movq " ++ src ++ ", %fs:" ++ cellName cell ++ "@tpoff"]
  HartBorrow -> let scratch = if src == "%r10" then "%r11" else "%r10" in
    ["movq fpr_g_tlsoff(%rip), " ++ scratch,
     "movq " ++ src ++ ", %fs:" ++ cellOff cell ++ "(" ++ scratch ++ ")"]
  HartTlvMachO -> tlvSave ++ ["movq " ++ src ++ ", (%rsp)"] ++ tlvAddress (cellName cell)
    ++ ["movq (%rsp), %rdi", "movq %rdi, (%rax)"] ++ tlvRestore ++ ["leaq 32(%rsp), %rsp"]

-- Darwin x86-64 thread-local variables are reached through a descriptor:
-- `movq _v@TLVP(%rip), %rdi; call *(%rdi)` returns the variable's address
-- in %rax for the calling thread, and the thunk preserves every register
-- but %rax and the flags (the contract clang relies on). Cell accesses
-- occur only at arrival, around calls and in the entry sequence, never
-- inside a flags window. Each access keeps rax, rdi and rbx in a 32-byte
-- block below rsp (slot 0 carries the value), and aligns rsp for the call
-- through rbx, since the entry sequence and the reservation stage run at
-- different alignments. Generated code keeps nothing below rsp.
tlvSave, tlvRestore :: [String]
tlvSave = ["leaq -32(%rsp), %rsp", "movq %rax, 24(%rsp)", "movq %rdi, 16(%rsp)", "movq %rbx, 8(%rsp)"]
tlvRestore = ["movq 8(%rsp), %rbx", "movq 16(%rsp), %rdi", "movq 24(%rsp), %rax"]
tlvAddress :: String -> [String]
tlvAddress cell =
  ["movq %rsp, %rbx", "andq $-16, %rsp", "movq " ++ gsym HartTlvMachO cell ++ "@TLVP(%rip), %rdi",
   "call *(%rdi)", "movq %rbx, %rsp"]

renderItem :: X64Hart -> Layout -> Bool -> String -> [String] -> [String] -> Item -> [String]
renderItem hart _ _ fname _ _ (ILabel l) = [local hart fname l ++ ":"]
renderItem hart ly large fname saveLines restores (I i) = map indent (go (siOpcode i) (siDefs i) (siUses i))
  where
    indent l = if last l == ':' then l else "    " ++ l
    lbl = local hart fname
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
    cc = \case O.Equal -> "e"; O.NotEqual -> "ne"; O.Less -> "l"; O.Greater -> "g"; O.LessEqual -> "le"; O.GreaterEqual -> "ge"; O.Overflow -> "o"; O.UnsignedAboveEqual -> "ae"; O.UnsignedBelow -> "b"
    call sym = ["subq $8, %rsp", "call " ++ gsym hart sym, "addq $8, %rsp"]
    go op ds us = case (op,ds,us) of
      (O.X64 O.Enter,[],[]) ->
        if large then ["movq %rbp, %rax", "movabsq $" ++ show (lyBytes ly) ++ ", %r11",
                       "subq %r11, %rsp", "leaq 8(%rsp,%r11), %rbp",
                       "movq %rax, -16(%rbp)", "movq %r10, -24(%rbp)"]
        else ["subq $" ++ show (lyBytes ly) ++ ", %rsp",
         "movq %rbp, " ++ show (lyBytes ly - 8) ++ "(%rsp)",
         "leaq " ++ show (lyBytes ly + 8) ++ "(%rsp), %rbp"]
      (O.X64 O.Save,[],[]) -> saveLines
      (O.Common O.Params,_,[]) -> [] -- the parameters are where the ABI put them
      (O.Common O.LoadCell,[d],[OC cell]) -> loadCell (ArgumentCell cell) (reg d)
      (O.X64 O.FrameLoad,[d],[OF ref 0]) -> ["movq " ++ slot ref ++ ", " ++ reg d]
      (O.X64 O.FrameStore,[],[s,OF ref 0]) -> ["movq " ++ reg s ++ ", " ++ slot ref]
      (O.Common O.StoreCell,[],[s,OC cell]) -> storeCell (ArgumentCell cell) (reg s)
      -- the hart block in whichever scratch register the value is not in
      -- (a spilled value is reloaded into %r10, the allocator's first
      -- scratch: the merge, docs/2026-10-21-TYPED-IR-MERGE.md)
      (O.Common O.StoreSpill,[],[s,OI j]) -> let h = if reg s == "%r10" then "%r11" else "%r10" in
        loadCell HartPointer h ++ ["movq " ++ reg s ++ ", " ++ show (8 * (1 + j)) ++ "(" ++ h ++ ")"]
      (O.Common O.LoadSpill,[d],[OI j]) -> loadCell HartPointer (reg d) ++ ["movq " ++ show (8 * (1 + j)) ++ "(" ++ reg d ++ "), " ++ reg d]
      (O.X64 O.Move,[d],[s]) -> ["movq " ++ reg s ++ ", " ++ reg d]
      (O.X64 O.Literal,[d],[n]) -> ["movabsq $" ++ imm n ++ ", " ++ reg d]
      (O.X64 O.Address,[d],[OS s]) -> ["leaq " ++ gsym hart s ++ "(%rip), " ++ reg d]
      (O.X64 O.LoadByte,[d],[base,n]) -> ["movzbq " ++ imm n ++ "(" ++ reg base ++ "), " ++ reg d]
      (O.X64 O.LoadField,[d],[base,n]) -> ["movq " ++ imm n ++ "(" ++ reg base ++ "), " ++ reg d]
      (O.X64 O.StoreField,[],[base,value,n]) -> ["movq " ++ reg value ++ ", " ++ imm n ++ "(" ++ reg base ++ ")"]
      (O.X64 O.StoreHeader,[],[base,value,n]) -> ["movl " ++ word32 value ++ ", " ++ imm n ++ "(" ++ reg base ++ ")"]
      (O.X64 O.LoadSigned32,[d],[s,n]) -> ["movslq " ++ imm n ++ "(" ++ reg s ++ "), " ++ reg d]
      (O.X64 O.SignExtend63,[d],[_,_]) -> ["shlq $1, " ++ reg d, "sarq $1, " ++ reg d]
      (O.X64 O.PairLoad,[],[base,OI n]) -> ["movdqu (" ++ reg base ++ "), %xmm" ++ show n]
      (O.X64 O.PairStore,[],[base,OI n]) -> ["movdqu %xmm" ++ show n ++ ", (" ++ reg base ++ ")"]
      (O.X64 O.PairDuplicate,[],[src,OI n]) -> ["movq " ++ reg src ++ ", %xmm" ++ show n,"punpcklqdq %xmm" ++ show n ++ ", %xmm" ++ show n]
      (O.X64 (O.PairBinary op),[],[OI d,OI a,OI b]) ->
        ["movdqa %xmm" ++ show a ++ ", %xmm" ++ show d,O.simdMnemonic op ++ " %xmm" ++ show b ++ ", %xmm" ++ show d]
      -- Widths and operations retain their constructors through allocation.
      (O.X64 (O.TreeCompare w c),[d],[]) ->
        let (x,y,pred')=comparison c "%xmm8" "%xmm9"
         in ["cmp" ++ pred' ++ suffix w ++ " " ++ y ++ ", " ++ x,
             moveOut w x d,"andq $1, " ++ reg d]
      (O.X64 (O.TreeLeaf w),[],[x,OI n]) -> [moveIn w x ("%xmm" ++ show (8+n))]
      (O.X64 (O.TreeOutput w),[d],[OI n]) -> [moveOut w ("%xmm" ++ show (8+n)) d]
      (O.X64 (O.TreeNode w op),[],[OI n]) ->
        [O.floatName op ++ suffix w ++ " %xmm" ++ show (9+n) ++ ", %xmm" ++ show (8+n)]
      (O.X64 (O.FloatBinary w op),[d],[a,b]) ->
        [moveIn w a "%xmm14",moveIn w b "%xmm15",
         O.floatName op ++ suffix w ++ " %xmm15, %xmm14",moveOut w "%xmm14" d]
      -- Ordered predicates are false for NaN; inequality is true. gt/ge
      -- compare swapped operands, preserving the reference evaluator's rule.
      (O.X64 (O.FloatCompare w c),[d],[a,b]) ->
        let (x,y,pred')=comparison c a b
         in [moveIn w x "%xmm14",moveIn w y "%xmm15",
             "cmp" ++ pred' ++ suffix w ++ " %xmm15, %xmm14",
             moveOut w "%xmm14" d,"andq $1, " ++ reg d]
      (O.X64 o,[d],[_,n]) | Just mnemonic <- immediateMnemonic o ->
        [mnemonic ++ " $" ++ imm n ++ ", " ++ reg d]
      (O.X64 o,[d],[_,b]) | Just mnemonic <- binaryMnemonic o ->
        [mnemonic ++ " " ++ reg b ++ ", " ++ reg d]
      (O.X64 O.ShiftLeft,[d],[_,c]) -> ["shlq " ++ byte c ++ ", " ++ reg d]
      (O.X64 O.ShiftRight,[d],[_,c]) -> ["shrq " ++ byte c ++ ", " ++ reg d]
      (O.X64 O.Divide,[_],[_,b]) -> ["cqto", "idivq " ++ reg b]
      (O.X64 O.Compare,[],[a,b]) -> ["cmpq " ++ reg b ++ ", " ++ reg a]
      (O.X64 O.CompareImmediate,[],[a,n]) -> ["cmpq $" ++ imm n ++ ", " ++ reg a]
      (O.X64 (O.Set c),[d],[]) -> ["set" ++ cc c ++ " " ++ byte d, "movzbq " ++ byte d ++ ", " ++ reg d]
      (O.X64 (O.Select c),[d],[_,a]) -> ["cmov" ++ cc c ++ " " ++ reg a ++ ", " ++ reg d]
      (O.X64 (O.Branch c),[],[OL l]) -> ["j" ++ cc c ++ " " ++ lbl l]
      (O.X64 O.BranchZero,[],[v,OL l]) -> ["testq " ++ reg v ++ ", " ++ reg v,"jz " ++ lbl l]
      (O.X64 O.BranchNonzero,[],[v,OL l]) -> ["testq " ++ reg v ++ ", " ++ reg v,"jnz " ++ lbl l]
      (O.X64 O.Jump,[],[OL l]) -> ["jmp " ++ lbl l]
      (O.Common O.JumpLoop,[],[OL l]) -> ["jmp " ++ lbl l]
      (O.X64 O.Call,_,OS s:_) -> call s
      (O.X64 O.Push,[],[v]) -> ["subq $16, %rsp", "movq " ++ reg v ++ ", (%rsp)"]
      (O.X64 O.ApplyN,[_],[OI n]) -> ["movq %rsp, %rdx", "movq $" ++ show n ++ ", %rsi", "movq " ++ show (16 * n) ++ "(%rsp), %rdi"]
        ++ call "fpr_applyN" ++ ["addq $" ++ show (16 * (n + 1)) ++ ", %rsp"]
      (O.X64 O.Panic,[],[OS s]) -> ("leaq " ++ gsym hart s ++ "(%rip), %rdi") : call "fpr_panic"
      (O.X64 O.Ret,[],[_]) -> epilogue ++ ["ret"]
      (O.Common O.TailJump,[],OS s:_) -> epilogue ++ ["jmp " ++ gsym hart s]
      (O.Common O.EntryCheckTick,_,_) -> hartRead ++ stackCheck ++ tick
      (O.Common O.EntryCheck,_,_) -> hartRead ++ stackCheck
      (O.Common O.EntryTick,_,_) -> hartRead ++ tick
      (O.Common O.TickN,_,[OI n]) -> hartRead ++ tickN n
      _ -> error ("X64 render: no form for " ++ show (op,ds,us))
    suffix O.Float64="sd"
    suffix O.Float32="ss"
    moveIn O.Float64 x dst="movq " ++ reg x ++ ", " ++ dst
    moveIn O.Float32 x dst="movd " ++ word32 x ++ ", " ++ dst
    moveOut O.Float64 src d="movq " ++ src ++ ", " ++ reg d
    moveOut O.Float32 src d="movd " ++ src ++ ", " ++ word32 d
    comparison c a b=case c of
      Lt->(a,b,"lt");Le->(a,b,"le");Gt->(b,a,"lt");Ge->(b,a,"le");Eq->(a,b,"eq");Ne->(a,b,"neq")
    immediateMnemonic op=case op of
      O.ShiftLeftImmediate->Just "shlq";O.ShiftRightArithmeticImmediate->Just "sarq"
      O.OrImmediate->Just "orq";O.AndImmediate->Just "andq";O.XorImmediate->Just "xorq"
      _->Nothing
    binaryMnemonic op=case op of
      O.Add->Just "addq";O.Subtract->Just "subq";O.Multiply->Just "imulq"
      O.And->Just "andq";O.Or->Just "orq";O.Xor->Just "xorq"
      _->Nothing
    -- the callee-saved registers come back first (rbp-relative, so after a
    -- stack-segment change they still read the frame they were saved in)
    epilogue = restores ++ ["movq %rbp, %r11", "movq -16(%rbp), %rbp"]
      ++ [if large then "movq -24(%r11), %rsp" else "leaq -8(%r11), %rsp"]
    -- QOS publishes the host TLS displacement, shared by all hart threads.
    -- The borrow block is {hart, a6, a7}; never use the app's ELF TLS offsets.
    loadCell = loadCellFor hart
    storeCell = storeCellFor hart
    hartRead = loadCell HartPointer "%r10"
    parkArgs save = ["movq " ++ (if save then reg o ++ ", " ++ slot ref else slot ref ++ ", " ++ reg o)
      | (n, o) <- zip [0..] (siDefs i), let ref = FrameRef (entrySlot n)]
    stackCheck =
      ["leaq 8(%rsp), %r11", "subq 456(%r10), %r11", "cmpq 464(%r10), %r11", "jb " ++ lbl (entryLabel i StackReady)]
      ++ parkArgs True ++ call "fpr_stack_grow"
      ++ ["testq %rax, %rax", "jz " ++ lbl (entryLabel i SameStack), "leaq -8(%rax), %rsp", lbl (entryLabel i SameStack) ++ ":"]
      ++ parkArgs False ++ hartRead ++ [lbl (entryLabel i StackReady) ++ ":"]
    tick = tickN 1
    tickN n = ["subq $" ++ show n ++ ", (%r10)", "cmpq $0, (%r10)", "jg " ++ lbl (entryLabel i FuelReady)]
      ++ parkArgs True ++ call "fpr_fuel_exhausted" ++ parkArgs False ++ [lbl (entryLabel i FuelReady) ++ ":"]
