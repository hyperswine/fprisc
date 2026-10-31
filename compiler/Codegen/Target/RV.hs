{-# LANGUAGE LambdaCase #-}
-- Direct RV32/RV64 selection from typed IR with an explicit word policy. No RISC-V text from Codegen.hs is
-- consumed here. Checked arithmetic is inline with the Int-domain fit proof;
-- the exact C primitives remain as the slow path, and
-- the shared allocator handles calls, spills, parallel arguments and loops.
module Codegen.Target.RV
  ( RVConfig (..), RVHart (..), rvSelectionRev, rvvPreamble, emitFnRV, emitFnRVWithSymbols, fuelSaveWrapper ) where

import qualified Codegen.Calling as Calling
import Codegen.Calling (CallConvention(FprCall), FuelEntry(..), TransferResult(..))
import qualified Codegen.Call as Call
import qualified Codegen.Protocol as Protocol
import Codegen.Allocate
import Codegen.Bounds
import Codegen.Frame
import Codegen.IR
import Codegen.Policy
import Codegen.Selected hiding (plain)
import Codegen.Annotation (EntryPoint(..),entryLabel)
import qualified Codegen.Opcode as O
import qualified Codegen.Opcode.RV as R
import Codegen.Target.RV.Forms (checkForms)
import Codegen.Target.Common
import Control.Monad (forM_, unless, when)
import Control.Monad.State.Strict
import Data.List (isPrefixOf, intercalate)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

rvSelectionRev :: Int
rvSelectionRev = 27 -- checked Int arithmetic is inline (fit-check fast path, the C primitive as the slow path); prior: the hart-cell load (loop region clock)

-- Native startup, shared by every RVV unit. The runtime calls the surviving
-- COMDAT definition on each hart; ordinary builds retain its weak no-op.
-- VS=Dirty (both bits) permits vector instructions from machine mode.
rvvPreamble :: Bool -> [String]
rvvPreamble False = []
rvvPreamble True =
  [ "    .option arch, +v",
    "    .section .text.fpr_rvv_enable,\"axG\",@progbits,fpr_rvv_enable,comdat",
    "    .balign 4",
    "    .globl fpr_rvv_enable",
    "fpr_rvv_enable:",
    "    li t0, 0x600",
    "    csrs mstatus, t0",
    "    ret",
    "    .text", "" ]

-- HartTp: the hart pointer is tp (bare metal, QOS); HartTls: the posix
-- runtime's thread-local cell, local-exec (an executable); HartTlsIe: the
-- same cell through initial-exec TLS, the GOT entry a loaded posix module
-- resolves against its host's cell (RV64.lowerPosixRV64's shared form)
-- HartQos: a loaded QOS app or plugin borrows the host's thread-local cell
-- through the displacement QOS publishes in fpr_g_tlsoff (RV64.lowerQosRV64)
-- HartTlsEsp: the ESP-IDF host's thread-local cell (fpr_esp_hart), local-exec
-- on the 32-bit word (Compile.espTls's form)
data RVHart = HartTp | HartTls | HartTlsIe | HartQos | HartTlsEsp deriving (Eq, Show)
data RVConfig = RVConfig
  { cfgWidth :: Width, cfgPolicy :: Policy, cfgHart :: RVHart, cfgExports :: S.Set String,
    cfgWeak :: Bool, cfgSelfLoops :: Bool }

p :: String -> Phys
p = Phys
args, callers, saved, scratch :: [Phys]
args = Calling.argumentRegisters Calling.RiscV
callers = Calling.callerClobbers Calling.RiscV
saved = map (p . ("s" ++) . show) [1..11 :: Int]
scratch = map p ["t0", "t1", "t2"]
reserved :: [Phys]
reserved = map p ["zero", "ra", "sp", "gp", "tp", "s0", "t3", "t4", "t5", "t6"]
regFile :: RegisterFile
regFile = RegisterFile (\r -> if S.member r regFileMembers then Just GPR else Nothing) reserved

-- built once: the allocator asks for every operand
regFileMembers :: S.Set Phys
regFileMembers = S.fromList (callers ++ saved ++ reserved)
vreg :: VId -> VReg
vreg (VId n) = VReg n
anyV :: VReg -> Operand
anyV v = OV v (Any GPR)
fixed :: VReg -> Phys -> Operand
fixed v r = OV v (Fix r)
label :: BId -> Label
label (BId n) = Label ("b" ++ show n)

-- A function-local builder. Every temporary is an ordinary selected value.
data Sel = Sel { nextV :: Int, nextL :: Int, items :: [Item], nulls :: S.Set (Int, Int), strings :: S.Set String, boxedFloats :: S.Set (Width,Integer) }
type S = StateT Sel (Either String)
emit :: SInstr -> S ()
emit i = modify (\s -> s {items = I i : items s})
mark :: Label -> S ()
mark l = modify (\s -> s {items = ILabel l : items s})
fresh :: S VReg
fresh = do n <- gets nextV; modify (\s -> s {nextV = n+1}); pure (VReg n)
freshLabel :: S Label
freshLabel = do n <- gets nextL; modify (\s -> s {nextL = n+1}); pure (Label ("edge" ++ show n))
plain :: O.Opcode -> [Operand] -> [Operand] -> SInstr
plain = plainOpcode

li :: VReg -> Integer -> S ()
li d n = emit (plain (O.RV R.Literal) [anyV d] [OI n])
rr :: R.Opcode -> VReg -> VReg -> VReg -> S ()
rr op d a b = emit (plain (O.RV op) [anyV d] [anyV a, anyV b])
ri :: R.Opcode -> VReg -> VReg -> Integer -> S ()
ri op d a n = emit (plain (O.RV op) [anyV d] [anyV a, OI n])
address :: VReg -> AddressSymbol -> S ()
address d sym = emit (plain (O.RV R.Address) [anyV d] [OAddr sym])
branch :: VReg -> Label -> S ()
branch v l = emit ((plain (O.RV R.BranchNonzero) [] [anyV v, OL l]) {siControl = CondTo [l]})
jump :: Label -> S ()
jump l = emit ((plain (O.RV R.Jump) [] [OL l]) {siControl = JumpTo l})
loadAt :: R.Opcode -> VReg -> VReg -> Integer -> S ()
loadAt op d base off = emit ((plain (O.RV op) [anyV d] [anyV base, OI off]) {siImplicitDefs = [p "t6"]})
storeAt :: R.Opcode -> VReg -> VReg -> Integer -> S ()
storeAt op base value off = emit ((plain (O.RV op) [] [anyV base, anyV value, OI off]) {siImplicitDefs = [p "t6"]})

stage :: CallConvention -> [VReg] -> S ()
stage convention vs = do
  staged <- lift (Calling.stagedArguments Calling.RiscV convention vs)
  forM_ [(n,v) | (Calling.HartArgument n,v)<-staged] $ \(n,v) ->
    emit ((plain (O.Common O.StoreSpill) [] [anyV v,OI (toInteger n)]) {siImplicitDefs=map p ["t3","t4"]})
call :: CodeSymbol -> CallConvention -> [VReg] -> Maybe VReg -> Bool -> S ()
call sym convention vs result tailCall = do
  stage convention vs
  selected <- lift (Calling.selectTransfer Calling.RiscV convention
    (if tailCall then TailTransfer else maybe DiscardResult (const WordResult) result) sym vs result
    ((plain (if tailCall then O.Common O.TailJump else O.RV R.Call) [] [])
      {siImplicitDefs=if tailCall then map p ["sp","s0","ra","t3"] else []}))
  emit selected
-- a call into a noreturn runtime trap: it ends the path (Calling.NeverReturns)
trapCall :: String -> S ()
trapCall s = do
  selected <- lift (Calling.selectTransfer Calling.RiscV Calling.RuntimeCall NeverReturns (CodeSymbol s) [] Nothing (plain (O.RV R.Call) [] []))
  emit selected
calleeSym :: Callee -> CodeSymbol
calleeSym = calleeCodeSymbol
entry :: Protocol.EntryChecks -> S ()
entry checks = do
  l <- freshLabel
  emit (Protocol.selectProtocol Calling.RiscV
    ((plain (O.Common (Protocol.entryOpcode checks)) [] []) {siAnnotation=EntryLabels l}))
boxed :: VReg -> S VReg
boxed v = do t <- fresh; d <- fresh; ri R.ShiftLeftImmediate t v 1; ri R.OrImmediate d t 1; pure d

-- Checked Int arithmetic agrees with Codegen.Eval and runtime/runtime.c: the
-- fast path computes on the raw words and checks the Int-domain fit (the word
-- overflow of +- and the mulh sign check coincide with the C primitive's
-- __builtin_*_overflow, and the fit shift is its fits_int); the slow path
-- either retags the ORIGINAL operands and re-enters the C primitive, whose
-- panic text and failure order are the language's, or traps with the kernel
-- diagnostics. Operands are always in the Int domain, so re-tagging
-- reconstructs the primitive's exact arguments and both paths trap together.
-- A zero divisor branches to the slow path BEFORE dividing: RISC-V div by
-- zero returns -1 instead of trapping, and -1 would pass the fit check.
arith :: Integer -> Bool -> ArithOp -> VReg -> VReg -> VReg -> S ()
arith w kernel op d x y = do
  slow <- freshLabel; zero <- freshLabel; done <- freshLabel
  result <- fresh
  let failUnlessEqual lhs rhs = do bad <- fresh; rr (R.Compare Ne) bad lhs rhs; branch bad slow
  case op of
    Add -> rr R.Add result x y
    Sub -> rr R.Subtract result x y
    Mul -> do
      rr R.Multiply result x y
      high <- fresh; sign <- fresh
      rr R.MultiplyHigh high x y
      ri R.ShiftRightArithmeticImmediate sign result (8*w-1)
      failUnlessEqual high sign
    Div -> do
      isZero <- fresh; z <- fresh; li z 0
      rr (R.Compare Eq) isZero y z; branch isZero (if kernel then zero else slow)
      rr R.Divide result x y
  shifted <- fresh; fit <- fresh
  ri R.ShiftLeftImmediate shifted result 1; ri R.ShiftRightArithmeticImmediate fit shifted 1
  failUnlessEqual fit result
  emit (plain (O.RV R.Move) [anyV d] [anyV result]); jump done
  mark slow
  if kernel then trapCall "fpr_int_overflow_kernel" else do
    tx <- boxed x; ty <- boxed y; t <- fresh
    call (CodeSymbol ("fpr_prim_fn_" ++ mangleName (arithSymbol op))) Calling.RuntimeCall [tx,ty] (Just t) False
    ri R.ShiftRightArithmeticImmediate d t 1
  when kernel $ do
    mark zero; trapCall "fpr_div_zero_kernel"
    li d 0 -- both trap entries are noreturn; define d for the allocation oracle
  mark done
parallel :: [(VReg,VReg)] -> S ()
parallel pairs = do
  -- Simultaneous block arguments: first copy every source to a fresh value.
  staged <- mapM (\(d,s) -> do t <- fresh; emit (plain (O.RV R.Move) [anyV t] [anyV s]); pure (d,t)) pairs
  forM_ staged $ \(d,t) -> emit (plain (O.RV R.Move) [anyV d] [anyV t])

select :: RVConfig -> Fn -> Either String (SFn, S.Set VReg, Sel)
select cfg fn = do
  validatePolicy (cfgPolicy cfg)
  unless (cfgWidth cfg == policyWidth (cfgPolicy cfg)) (Left "RISC-V word width disagrees with the IR policy")
  unless (all (intFitsWidth (cfgWidth cfg)) [n | b <- fnBlocks fn, Instr _ (OConstInt n) <- bInstrs b]) (Left "RISC-V literal is outside the target Int range")
  let defs = concatMap blockDefs (fnBlocks fn)
      params = [vreg v | b <- fnBlocks fn, bId b == fnEntry fn, (v,_) <- bParams b]
      managed = S.fromList [vreg v | (v,TVal) <- defs]
      start = 1 + maximum (0 : [n | (VId n,_) <- defs])
  when (length params > arityCeiling) (Left ("arity above " ++ show arityCeiling))
  unless (all ((`elem` [TVal,TInt,TPred,TAddr]) . snd) defs) (Left "RV64: a raw or float-register value is not legalized")
  (_, st) <- runStateT (mapM_ block (fnBlocks fn)) (Sel start 0 [] S.empty S.empty S.empty)
  pure (SFn (fnName fn) params (reverse (items st)), managed, st)
  where
    w = toInteger (wordBytes cfg)
    ld = if cfgWidth cfg == W32 then R.Load32 else R.Load64
    stWord = if cfgWidth cfg == W32 then R.Store32 else R.Store64
    block b = do
      mark (label (bId b))
      let (prefix, rest) = span (\(Instr _ op) -> op `elem` [OStackCheck,OSafepoint]) (bInstrs b)
      if bId b == fnEntry fn then do
        let stack = any (\(Instr _ op) -> op == OStackCheck) prefix
            fuel = any (\(Instr _ op) -> op == OSafepoint) prefix
        let wantStack = polStackCheck (cfgPolicy cfg) /= StackStatic
            wantFuel = polFuel (cfgPolicy cfg)
        unless (stack == wantStack && fuel == wantFuel) (lift (Left "RISC-V entry disagrees with the profile stack/fuel obligations"))
        case Protocol.entryChecks stack fuel of
          Just checks->entry checks
          Nothing->emit (plain (O.Common O.EntryStatic) [] [])
      else forM_ prefix $ \(Instr _ op) -> case op of
        OSafepoint -> if polFuel (cfgPolicy cfg) then entry Protocol.FuelOnly else lift (Left "a no-fuel profile contains a safepoint")
        _ -> lift (Left "RV64: non-entry stack check")
      mapM_ instruction rest
      terminator b
    instruction (Instr result op) = case op of
      OStore _ a n v -> storeAt stWord (vreg a) (vreg v) (fromIntegral n)
      OStackCheck -> lift (Left "RV64: misplaced stack check")
      OSafepoint -> if polFuel (cfgPolicy cfg) then entry Protocol.FuelOnly else lift (Left "a no-fuel profile contains a safepoint")
      OSafepointN n -> do
        unless (polFuel (cfgPolicy cfg)) (lift (Left "a no-fuel profile contains a counted safepoint"))
        Label l <- freshLabel
        emit (Protocol.selectProtocol Calling.RiscV ((plain (O.Common O.TickN) [] [OI (fromIntegral n)])
          {siAnnotation=EntryLabels (Label l)}))
      OSimdPair {} -> lift (Left "a NEON pair on RISC-V")
      _ -> case result of
        Nothing -> lift (Left "compiler error: RV64 instruction lacks result")
        Just (v,_) -> value (vreg v) op
    value d = \case
      OAddress v -> emit (plain (O.RV R.Move) [anyV d] [anyV (vreg v)])
      OIndex a i -> do
        offset <- fresh
        ri R.ShiftLeftImmediate offset (vreg i) (if cfgWidth cfg == W32 then 2 else 3)
        rr R.Add d (vreg a) offset
      OIndexByte a i -> rr R.Add d (vreg a) (vreg i)
      OLoad _ a n -> loadAt ld d (vreg a) (fromIntegral n)
      OLoadByte a n -> loadAt R.LoadByte d (vreg a) (fromIntegral n)
      OStore {} -> lift (Left "compiler error: a store has a result")
      OConstInt n -> li d n
      OHartCell j -> emit ((plain (O.Common O.LoadSpill) [anyV d] [OI (fromIntegral j)]) {siImplicitDefs = map p ["t3","t4"]})
      ORegionRoom mark -> do
        clock <- fresh; used <- fresh; scaled <- fresh; limit <- fresh; untagged <- fresh
        emit ((plain (O.Common O.LoadSpill) [anyV clock] [OI 58]) {siImplicitDefs = map p ["t3","t4"]})
        ri R.ShiftRightArithmeticImmediate untagged (vreg mark) 1 -- the mark is a tagged Int
        rr R.Subtract used clock untagged
        ri R.ShiftLeftImmediate scaled used 3
        li limit (65536 * 8)
        rr R.LessUnsigned d scaled limit
      OBits n -> li d n
      ONullary t v -> do
        sym <- case (t,v) of
          (0,0) -> pure "fpr_unit"; (1,0) -> pure "fpr_false"; (1,1) -> pure "fpr_true"
          _ -> modify (\s -> s {nulls = S.insert (t,v) (nulls s)}) >> pure (".Lnul_" ++ show t ++ "_" ++ show v)
        address d (StaticObject sym)
      OString s -> modify (\st -> st {strings = S.insert s (strings st)}) >> address d (StaticObject (stringLabel s))
      OBoxedFloat width bits -> do
        unless (cfgWidth cfg == W32) (lift (Left "boxed float constants require RV32"))
        modify (\st -> st {boxedFloats = S.insert (width,bits) (boxedFloats st)})
        address d (StaticObject (boxedFloatLabel width bits))
      OSymbol s -> address d (ExternalAddress s)
      OFunValue n -> address d (StaticObject ("fpr_obj_" ++ mangleName n))
      OTag v -> do t <- fresh; ri R.ShiftLeftImmediate t (vreg v) 1; ri R.OrImmediate d t 1
      OUntag v -> ri R.ShiftRightArithmeticImmediate d (vreg v) 1
      ONot v -> ri R.XorImmediate d (vreg v) 1
      OIsInt v -> ri R.AndImmediate d (vreg v) 1
      OTruth v -> loadAt R.Load32 d (vreg v) 4
      OBoolOf v -> do
        yes <- freshLabel; done <- freshLabel
        branch (vreg v) yes; address d (StaticObject "fpr_false"); jump done
        mark yes; address d (StaticObject "fpr_true"); mark done
      OTagTest t variant v -> do
        miss <- freshLabel; done <- freshLabel
        bit <- fresh; ri R.AndImmediate bit (vreg v) 1; branch bit miss
        actual <- fresh; want <- fresh; bad <- fresh
        loadAt R.Load32 actual (vreg v) 0; li want (fromIntegral t); rr (R.Compare Ne) bad actual want; branch bad miss
        loadAt R.Load32 actual (vreg v) 4; li want (fromIntegral variant); rr (R.Compare Eq) d actual want; jump done
        mark miss; li d 0; mark done
      OMake t variant fs -> do
        size <- fresh; li size (8 + w * fromIntegral (length fs))
        if polProfile (cfgPolicy cfg) == BuiltinArc then do
          fields <- fresh; li fields (fromIntegral (length fs))
          call (CodeSymbol "fpr_builtin_alloc_adt") Calling.RuntimeCall [size,fields] (Just d) False
        else call (CodeSymbol "fpr_alloc") Calling.RuntimeCall [size] (Just d) False
        forM_ [(0,t),(4,variant)] $ \(off,n) -> do h <- fresh; li h (fromIntegral n); storeAt R.Store32 d h off
        forM_ (zip [0..] fs) $ \(n,v) -> storeAt stWord d (vreg v) (8+w*n)
      OReuse _ _ root fs -> do
        forM_ (zip [0..] fs) $ \(n,v) -> storeAt stWord (vreg root) (vreg v) (8+w*n)
        emit (plain (O.RV R.Move) [anyV d] [anyV (vreg root)])
      OField n v -> loadAt ld d (vreg v) (8+w*fromIntegral n)
      OStrLen s -> do t <- fresh; call (CodeSymbol "fpr_g_strlen_call1") Calling.RuntimeCall [vreg s] (Just t) False; ri R.ShiftRightArithmeticImmediate d t 1
      OCharAt s n -> do i <- boxed (vreg n); t <- fresh; call (CodeSymbol "fpr_g_charAt_call2") Calling.RuntimeCall [vreg s,i] (Just t) False; ri R.ShiftRightArithmeticImmediate d t 1
      OKernelArith op a b -> arith w True op d (vreg a) (vreg b)
      OArith op a b -> arith w False op d (vreg a) (vreg b)
      -- the difference-bound proof removed the overflow check: a plain
      -- instruction where the checked form keeps the C primitive; Mul/Div
      -- keep the call (the pass produces only Add/Sub)
      OArithU Add a b -> rr R.Add d (vreg a) (vreg b)
      OArithU Sub a b -> rr R.Subtract d (vreg a) (vreg b)
      OArithU op a b -> do
        x <- boxed (vreg a); y <- boxed (vreg b); t <- fresh
        call (CodeSymbol ("fpr_prim_fn_" ++ mangleName (arithSymbol op))) Calling.RuntimeCall [x,y] (Just t) False
        ri R.ShiftRightArithmeticImmediate d t 1
      OBit op a b -> rr (case op of BAnd -> R.And; BOr -> R.Or; BXor -> R.Xor) d (vreg a) (vreg b)
      OFloatBin o a b -> rr (R.FloatBinary O.Float64 o) d (vreg a) (vreg b)
      OFloatCmp o a b -> rr (R.FloatCompare O.Float64 o) d (vreg a) (vreg b)
      OFloat32Bin o a b -> rr (R.FloatBinary O.Float32 o) d (vreg a) (vreg b)
      OFloatCmpTree o x y -> do
        forM_ (ftreeScheduleAt 0 x ++ ftreeScheduleAt 1 y) $ \case
          FSLeaf v n -> emit (plain (O.RV (R.TreeLeaf O.Float64)) [] [anyV (vreg v), OI (fromIntegral n)])
          FSNode f n -> emit (plain (O.RV (R.TreeNode O.Float64 f)) [] [OI (fromIntegral n)])
        emit (plain (O.RV (R.TreeCompare O.Float64 o)) [anyV d] [])
      OFloat32CmpTree o x y -> do
        forM_ (ftreeScheduleAt 0 x ++ ftreeScheduleAt 1 y) $ \case
          FSLeaf v n -> emit (plain (O.RV (R.TreeLeaf O.Float32)) [] [anyV (vreg v), OI (fromIntegral n)])
          FSNode f n -> emit (plain (O.RV (R.TreeNode O.Float32 f)) [] [OI (fromIntegral n)])
        emit (plain (O.RV (R.TreeCompare O.Float32 o)) [anyV d] [])
      OFloatTree t -> do
        let (steps, root) = ftreeSchedule t
        forM_ steps $ \step -> case step of
          FSLeaf v n -> emit (plain (O.RV (R.TreeLeaf O.Float64)) [] [anyV (vreg v), OI (fromIntegral n)])
          FSNode o n -> emit (plain (O.RV (R.TreeNode O.Float64 o)) [] [OI (fromIntegral n)])
        emit (plain (O.RV (R.TreeOutput O.Float64)) [anyV d] [OI (fromIntegral root)])
      OFloat32Tree t -> do
        let (steps, root) = ftreeSchedule t
        forM_ steps $ \step -> case step of
          FSLeaf v n -> emit (plain (O.RV (R.TreeLeaf O.Float32)) [] [anyV (vreg v), OI (fromIntegral n)])
          FSNode o n -> emit (plain (O.RV (R.TreeNode O.Float32 o)) [] [OI (fromIntegral n)])
        emit (plain (O.RV (R.TreeOutput O.Float32)) [anyV d] [OI (fromIntegral root)])
      OFloat32Cmp o a b -> rr (R.FloatCompare O.Float32 o) d (vreg a) (vreg b)
      -- RISC-V V: v8 the lanes, v9/v10 reductions; t4..t6 scratch (declared)
      ORvvVlMax -> emit (plain (O.RV R.VectorMax) [anyV d] [])
      ORvvLanes a n -> emit ((plain (O.RV R.VectorLanes) [anyV d] [anyV (vreg a), anyV (vreg n), OI (rvvLaneBound (cfgWidth cfg))]) {siImplicitDefs = map p ["t4","t5","t6"]})
      ORvvSumLoaded acc -> emit ((plain (O.RV R.VectorSum) [anyV d] [anyV (vreg acc)]) {siImplicitDefs = [p "t5"]})
      OShift op a b -> do
        x <- boxed (vreg a); y <- boxed (vreg b); t <- fresh
        call (CodeSymbol (if op == Shl then "fpr_g_BITSHIFTL_call2" else "fpr_g_BITSHIFTR_call2")) Calling.RuntimeCall [x,y] (Just t) False
        ri R.ShiftRightArithmeticImmediate d t 1
      OCmp op a b -> rr (R.Compare op) d (vreg a) (vreg b)
      OEqVal eq a b -> do
        t <- fresh; call (CodeSymbol ("fpr_prim_fn_" ++ mangleName (if eq then "==" else "!="))) Calling.RuntimeCall [vreg a,vreg b] (Just t) False
        loadAt R.Load32 d t 4
      OCall c vs -> do
        inlined <- rawAdapter c (map vreg vs) d
        unless inlined (call (calleeSym c) (Calling.calleeCall (cfgPolicy cfg) c) (map vreg vs) (Just d) False)
      OApply f vs -> do
        forM_ (f:vs) $ \v -> emit (Protocol.selectProtocol Calling.RiscV (plain (O.RV R.Push) [] [anyV (vreg v)]))
        emit (Protocol.selectProtocol Calling.RiscV
          (plain (O.RV R.ApplyN) [fixed d (p "a0")] [OI (fromIntegral (length vs))]))
      op -> lift (Left ("compiler error: RV64 value " ++ show op))
    targetParams bid = [vreg v | b <- fnBlocks fn, bId b == bid, (v,_) <- bParams b]
    edge bid vs = parallel (zip (targetParams bid) (map vreg vs)) >> jump (label bid)
    terminator b = case bTerm b of
      TRet v -> emit ((plain (O.RV R.Ret) [] [fixed (vreg v) (p "a0")]) {siImplicitDefs = map p ["sp","s0","ra","t3"], siControl = Return})
      TBr bid vs | bid == fnEntry fn -> call (CodeSymbol (functionSymbol (fnName fn))) (Calling.nativeCall (cfgPolicy cfg)) (map vreg vs) Nothing True
                 | otherwise -> edge bid vs
      TCondBr v yes ys no ns -> do l <- freshLabel; branch (vreg v) l; edge no ns; mark l; edge yes ys
      TTailCall c vs -> do
        d <- fresh
        inlined <- rawAdapter c (map vreg vs) d
        if inlined then emit ((plain (O.RV R.Ret) [] [fixed d (p "a0")]) {siImplicitDefs = map p ["sp","s0","ra","t3"], siControl = Return})
        else call (calleeSym c) (Calling.calleeCall (cfgPolicy cfg) c) (map vreg vs) Nothing True
      TUnreachable s -> do
        modify (\st -> st {strings = S.insert s (strings st)})
        emit (Protocol.selectProtocol Calling.RiscV (plain (O.RV R.Panic) [] [OAddr (StaticObject (stringLabel s))]))

    -- The ARC representation pass has proved Word/Addr are raw bits and
    -- Ints tagged. These non-owning adapters can be selected directly.
    -- Memory and shift guards call the audited adapter with the original
    -- arguments on failure, preserving its diagnostic and volatile behavior.
    -- Managed operands retain their consuming calls. Tagged immediates
    -- need no retain/release, exactly as both builtin heaps specify.
    rawAdapter c vs d
      | polProfile (cfgPolicy cfg) /= BuiltinArc || not (isForeign c) = pure False
      | otherwise = case (calleeName c,vs) of
          (n,[a]) | n `elem` ["$arc.retain","$arc.release"] -> yes (guarded (\slow -> do
            bit <- fresh; ri R.AndImmediate bit a 1; bad <- fresh; ri R.XorImmediate bad bit 1; branch bad slow) $
              if n=="$arc.retain" then emit (plain (O.RV R.Move) [anyV d] [anyV a]) else address d (StaticObject "fpr_unit"))
          (n,[a,b]) | Just op <- M.lookup n intBinary -> yes (do
            x <- fresh; y <- fresh; result <- fresh
            ri R.ShiftRightArithmeticImmediate x a 1; ri R.ShiftRightArithmeticImmediate y b 1
            guarded (\slow -> do
              when (op==R.Divide) $ do z <- fresh; li z 0; zero <- fresh; rr (R.Compare Eq) zero y z; branch zero slow
              rr op result x y
              when (op==R.Multiply) $ do
                hi <- fresh; sign <- fresh; rr R.MultiplyHigh hi x y; ri R.ShiftRightArithmeticImmediate sign result 63
                bad <- fresh; rr (R.Compare Ne) bad hi sign; branch bad slow
              fit <- fresh; ri R.ShiftLeftImmediate fit result 1; ri R.ShiftRightArithmeticImmediate fit fit 1
              bad <- fresh; rr (R.Compare Ne) bad fit result; branch bad slow) (tagged result d))
          (n,[a,b]) | Just op <- M.lookup n intCompare -> yes (do t <- fresh; rr op t a b; bool t)
          (n,[a,b]) | n `elem` ["$arc.eq","$arc.ne"] -> yes (guarded (\slow -> do
            both <- fresh; ri R.AndImmediate both a 1; bit <- fresh; ri R.AndImmediate bit b 1
            rr R.And both both bit; bad <- fresh; ri R.XorImmediate bad both 1; branch bad slow) $ do
              t <- fresh; rr (R.Compare (if n=="$arc.eq" then Eq else Ne)) t a b; bool t)
          (n,[a,b]) | Just op <- M.lookup n wordBinary -> yes (rr op d a b)
          ("$arc.wordnot",[a]) -> yes (ri R.XorImmediate d a (-1))
          ("$arc.wordfromInt",[a]) -> yes (ri R.ShiftRightArithmeticImmediate d a 1)
          ("$arc.wordtoInt",[a]) -> yes (tagged a d)
          ("$arc.wordbits",[_]) -> yes (li d 129)
          (n,[a]) | n `elem` ["$arc.addrfromWord","$arc.addrtoWord"] -> yes (emit (plain (O.RV R.Move) [anyV d] [anyV a]))
          ("$arc.addrnull",[_]) -> yes (li d 0)
          ("$arc.addradd",[a,b]) -> yes (do t <- fresh; ri R.ShiftRightArithmeticImmediate t b 1; rr R.Add d a t)
          (n,[a,b]) | n `elem` ["$arc.wordeq","$arc.addreq","$arc.rawEq","$arc.rawNe"] -> yes (do
            t <- fresh; rr (R.Compare (if n == "$arc.rawNe" then Ne else Eq)) t a b; bool t)
          (n,[a,b]) | n `elem` ["$arc.wordshl","$arc.wordshr","$arc.wordbitSet","$arc.wordbitClear","$arc.wordbitTest"] -> yes (do
            count <- fresh; ri R.ShiftRightArithmeticImmediate count b 1
            guarded (\slow -> do limit <- fresh; li limit 64; valid <- fresh; rr R.LessUnsigned valid count limit; bad <- fresh; ri R.XorImmediate bad valid 1; branch bad slow) $ case n of
              "$arc.wordshl" -> rr R.ShiftLeft d a count
              "$arc.wordshr" -> rr R.ShiftRight d a count
              "$arc.wordbitTest" -> do t <- fresh; rr R.ShiftRight t a count; ri R.AndImmediate t t 1; bool t
              _ -> do one <- fresh; li one 1; mask <- fresh; rr R.ShiftLeft mask one count
                      if n == "$arc.wordbitClear" then ri R.XorImmediate mask mask (-1) >> rr R.And d a mask else rr R.Or d a mask)
          (n,[a]) | Just (op,alignment,small) <- M.lookup n reads -> yes (memoryGuard a alignment $ do
            if small then do t <- fresh; loadAt op t a 0; tagged t d else loadAt op d a 0)
          (n,[a,b]) | Just (op,alignment,small) <- M.lookup n writes -> yes (memoryGuard a alignment $ do
            v <- if small then do t <- fresh; ri R.ShiftRightArithmeticImmediate t b 1; pure t else pure b
            storeAt op a v 0; address d (StaticObject "fpr_unit"))
          ("$arc.memfence",[_]) -> yes (emit (plain (O.RV R.Fence) [] []) >> address d (StaticObject "fpr_unit"))
          _ -> pure False
      where
        yes action = action >> pure True
        tagged a result = do t <- fresh; ri R.ShiftLeftImmediate t a 1; ri R.OrImmediate result t 1
        bool t = do yesLabel <- freshLabel; done <- freshLabel; branch t yesLabel
                    address d (StaticObject "fpr_false"); jump done; mark yesLabel; address d (StaticObject "fpr_true"); mark done
        guarded check body = do slow <- freshLabel; done <- freshLabel
                                check slow; body; jump done; mark slow
                                call (calleeSym c) Calling.RuntimeCall vs (Just d) False; mark done
        -- Every byte address is aligned. Emitting even an unreachable slow
        -- call requires a nonexistent adapter when this is a RAW library
        -- linked into the hosted runtime (machine/virt/rawunit.c).
        memoryGuard _ 0 body = body
        memoryGuard a mask body = guarded (aligned a mask) body
        aligned a mask slow = when (mask /= 0) $ do t <- fresh; ri R.AndImmediate t a mask; branch t slow
        intBinary = M.fromList [("$arc."++n,op) | (n,op)<-[("add",R.Add),("sub",R.Subtract),("mul",R.Multiply),("div",R.Divide)]]
        intCompare = M.fromList [("$arc."++O.comparisonName c,R.Compare c) | c<-[Lt,Gt,Le,Ge]]
        wordBinary = M.fromList [("$arc.word"++n,op) | (n,op)<-[("add",R.Add),("sub",R.Subtract),("and",R.And),("or",R.Or),("xor",R.Xor)]]
        reads = M.fromList [("$arc.memread"++n,(op,mask,small)) | (n,op,mask,small)<-[("8",R.LoadByte,0,True),("16",R.LoadHalf,1,True),("32",R.LoadUnsigned32,3,False),("Word",R.Load64,7,False)]]
        writes = M.fromList [("$arc.memwrite"++n,(op,mask,small)) | (n,op,mask,small)<-[("8",R.StoreByte,0,True),("16",R.StoreHalf,1,True),("32",R.Store32,3,False),("Word",R.Store64,7,False)]]

-- The tick's slow path: a unit-local wrapper saves ra, t0..t6 and a0..a7
-- on the actor's stack around fpr_fuel_exhausted (16 words, 16-byte aligned).
fuelSaveWrapper :: Width -> [String]
fuelSaveWrapper width =
  ["    .text", "    .balign 4", Call.runtimeName Call.FuelSaveEntry ++ ":", "    addi sp, sp, -" ++ show (16 * w)]
  ++ ["    " ++ st ++ " " ++ r ++ ", " ++ show (w * k) ++ "(sp)" | (k, r) <- zip [0 :: Int ..] saved]
  ++ ["    call " ++ Call.runtimeName Call.FuelEntry]
  ++ ["    " ++ ld ++ " " ++ r ++ ", " ++ show (w * k) ++ "(sp)" | (k, r) <- zip [0 :: Int ..] saved]
  ++ ["    addi sp, sp, " ++ show (16 * w), "    ret", ""]
  where
    w = if width == W32 then 4 else 8 :: Int
    st = if width == W32 then "sw" else "sd"
    ld = if width == W32 then "lw" else "ld"
    saved = "ra" : map (("t" ++) . show) [0 .. 6 :: Int] ++ map (("a" ++) . show) [0 .. 7 :: Int]

allocConfig :: RVConfig -> Fn -> S.Set VReg -> AllocConfig
allocConfig cfg fn managed = AllocConfig
  { acCalleeSaved = saved, acCallerSaved = args, acScratch = scratch,
    acPreserved = map p ["sp","s0","gp","tp"], acClassOf = rfClassOf regFile,
    acArrival = \vs -> let placed=Calling.arrivalArguments Calling.RiscV vs
      in plain (O.Common O.Params) [fixed v p | (Calling.ArgumentRegister p,v)<-placed] [] :
        [(plain (O.Common O.LoadSpill) [anyV v] [OI (toInteger n)]) {siImplicitDefs=map p ["t3","t4"]} | (Calling.HartArgument n,v)<-placed],
    acLoad = \r ref -> (plain (O.RV R.FrameLoad) [OP r] [OF ref 0]) {siImplicitDefs = [p "t6"]},
    acStore = \r ref -> (plain (O.RV R.FrameStore) [] [OP r,OF ref 0]) {siImplicitDefs = [p "t6"]},
    acMove = \d s -> plain (O.RV R.Move) [OP d] [OP s],
    acSlot = \n v -> frameObj n (wordBytes cfg) (wordBytes cfg) (SpillSlot n) (S.member v managed),
    acEarlyDef = const False,
    acSelfLoop = if cfgSelfLoops cfg then Just (CodeSymbol (functionSymbol (fnName fn))) else Nothing }

emitFnRV :: RVConfig -> Fn -> Either String NativeFn
emitFnRV cfg=emitFnRVWithSymbols (publicSymbols (cfgExports cfg)) cfg

emitFnRVWithSymbols :: SymbolPolicy -> RVConfig -> Fn -> Either String NativeFn
emitFnRVWithSymbols symbols cfg fn = do
  (sf, managed, st) <- select cfg fn
  let checked = either (Left . ("compiler error: " ++)) Right
      ac = allocConfig cfg fn managed
  checkForms regFile (fnName fn) (sfBody sf)
  checked (checkFn regFile sf)
  allocation <- checked (allocateFn ac sf)
  checked (checkAllocation ac (fnName fn) (alBody allocation))
  let saveObjects = [frameObj (-n-1) (wordBytes cfg) (wordBytes cfg) (SavedRegister r) False | (n,Phys r) <- zip [0..] (alSaved allocation)]
      objects = saveObjects ++ alSlots allocation
      ordinary = layout (2 * wordBytes cfg) 16 objects
      large = polStackCheck (cfgPolicy cfg) /= StackStatic && lyBytes ordinary > 1024
      ly = if large then layout (3 * wordBytes cfg) 16 objects else ordinary
      (shallow, body) = shallowEntry (polStackCheck (cfgPolicy cfg)) (lyBytes ly) (alBody allocation)
  let reg (Phys r) = r
      off ref = toInteger (lyOffset ly M.! ref)
      w = toInteger (wordBytes cfg)
      ld = if cfgWidth cfg == W32 then "lw" else "ld"
      stWord = if cfgWidth cfg == W32 then "sw" else "sd"
      saves = concat [memory stWord r "s0" (off (foRef o)) | o <- saveObjects, SavedRegister r <- [foKind o]]
      restores = concat [memory ld r "s0" (off (foRef o)) | o <- saveObjects, SavedRegister r <- [foKind o]]
      n = toInteger (lyBytes ly)
      prologue = (if large then reserveFrame cfg fn n (length (sfParams sf)) (cfgHart cfg /= HartTp && lyBytes ordinary <= 32768) else [])
        ++ adjust "sp" "sp" (-n) ++ memory stWord "ra" "sp" (n-w) ++ memory stWord "s0" "sp" (n-2*w)
        ++ adjust "s0" "sp" n ++ (if large then memory stWord "t3" "s0" (-3*w) else []) ++ saves
      rendered = [(it, render cfg fn ly large restores it) | it <- body]
      -- The reserve call is in the entry ABI shim, before allocated values
      -- exist. It stages/restores every incoming parameter and the link.
      report = analyse (TIns (instructionCost prologue) FNext False (if large then 1 else 0) : concatMap token rendered)
      name = fnName fn
      header = ["# fn " ++ name ++ " (arity " ++ show (length (sfParams sf)) ++ ") typed-ir rv" ++ show (widthBits (cfgWidth cfg)) ++ " frame=" ++ show n
                 ++ (if large then " reserve=yes" else "") ++ (if shallow then " shallow=yes" else " shallow=no") ++ " saved="
                 ++ (if null (alSaved allocation) then "none" else intercalate "," (map reg (alSaved allocation))) ++ " " ++ statsLine (alStats allocation)]
          ++ ["    .section .text." ++ functionSymbol name ++ ",\"ax\",@progbits" | polProfile (cfgPolicy cfg) == BuiltinArc]
          ++ ["    .balign 4" | polProfile (cfgPolicy cfg) == BuiltinArc]
          ++ visibilityLines ELF WeakDirective (visibilityFor (cfgWeak cfg) symbols name) (functionSymbol name)
          ++ [functionSymbol name ++ ":"]
  checkForms regFile name body
  pure (NativeFn name (header ++ map ("    " ++) prologue ++ concatMap snd rendered ++ [reportLine name report, ""]) report (S.toList (nulls st)) (S.toList (strings st)) (S.toList (boxedFloats st)) (usesTick body))
  where
    token (ILabel (Label l),_) = [TLabel l]
    token (I i,ls) = [TIns (instructionCost ls)
      (case siControl i of Next -> FNext; CondTo ls' -> FCond [l | Label l <- ls']; JumpTo (Label l) -> FJump l; Return -> FExit)
      (any callSafepoint (siCalls i)) (length (filter callRuntime (siCalls i)))]

-- The printer expands only selected RV64 instructions/pseudos. t6 is
-- reserved for offsets outside the signed 12-bit displacement range.
adjust :: String -> String -> Integer -> [String]
adjust d s n | n >= -2048 && n <= 2047 = ["addi " ++ d ++ ", " ++ s ++ ", " ++ show n]
             | otherwise = ["li t6, " ++ show n, "add " ++ d ++ ", " ++ s ++ ", t6"]
memory :: String -> String -> String -> Integer -> [String]
memory op r base n | n >= -2048 && n <= 2047 = [op ++ " " ++ r ++ ", " ++ show n ++ "(" ++ base ++ ")"]
                   | otherwise = adjust "t6" base n ++ [op ++ " " ++ r ++ ", 0(t6)"]
-- A large entry checks its full decrement while SP is still untouched. On
-- a miss, only a bounded staging frame is written on the caller's headroom.
-- All 64 possible parameters, including the hart cells, survive the C call.
reserveFrame :: RVConfig -> Fn -> Integer -> Int -> Bool -> [String]
reserveFrame cfg fn bytes argc foreignWindow =
  ["li t5, " ++ show bytes, "bltu sp, t5, " ++ slow]
  ++ hartRead cfg ++ memory ld "t5" "t3" (57*w)
  -- A zero low bound is the existing runtime's unchecked foreign-stack
  -- window. Preserve the previously admitted TLS/QOS ceiling there; new
  -- sizes require an explicit bounded window or an actor-owned reserve.
  ++ ["beqz t5, " ++ if foreignWindow then fast else slow] ++ adjust "t4" "sp" (-bytes)
  ++ ["sub t4, t4, t5"] ++ memory ld "t5" "t3" (58*w)
  ++ ["bltu t4, t5, " ++ fast, slow ++ ":"]
  ++ adjust "sp" "sp" (-stageBytes)
  ++ concat [memory st reg "sp" (fromIntegral i*w) | (i,reg) <- zip [0..] (take argc (map (("a"++) . show) [0..7::Int]))]
  ++ hartRead cfg
  ++ concat [memory ld "t4" "t3" (fromIntegral (i-7)*w) ++ memory st "t4" "sp" (fromIntegral i*w) | i <- [8..argc-1]]
  ++ memory st "ra" "sp" (fromIntegral argc*w)
  ++ adjust "a0" "sp" stageBytes ++ ["li a1, " ++ show bytes, ("call " ++ Call.runtimeName Call.ReserveStackEntry), "mv t5, a0"]
  ++ hartRead cfg
  ++ concat [memory ld "t4" "sp" (fromIntegral i*w) ++ memory st "t4" "t3" (fromIntegral (i-7)*w) | i <- [8..argc-1]]
  ++ concat [memory ld reg "sp" (fromIntegral i*w) | (i,reg) <- zip [0..] (take argc (map (("a"++) . show) [0..7::Int]))]
  ++ memory ld "ra" "sp" (fromIntegral argc*w)
  ++ adjust "t3" "sp" stageBytes
  ++ ["beqz t5, " ++ same, "mv sp, t5", "j " ++ ready, same ++ ":", "mv sp, t3", "j " ++ ready,
      fast ++ ":", "mv t3, sp", ready ++ ":"]
  where
    w = toInteger (wordBytes cfg)
    ld = if cfgWidth cfg == W32 then "lw" else "ld"
    st = if cfgWidth cfg == W32 then "sw" else "sd"
    stageBytes = ((fromIntegral (argc+1)*w+15) `div` 16)*16
    slow = local fn (Label "reserve_slow")
    fast = local fn (Label "reserve_fast")
    same = local fn (Label "reserve_same")
    ready = local fn (Label "reserve_ready")

hartRead :: RVConfig -> [String]
hartRead cfg = case cfgHart cfg of
  HartTp -> ["mv t3, tp"]
  HartTls -> ["lui t3, %tprel_hi(fpr_posix_hart)", "add t3, t3, tp, %tprel_add(fpr_posix_hart)", ld ++ " t3, %tprel_lo(fpr_posix_hart)(t3)"]
  HartTlsIe -> ["la.tls.ie t3, fpr_posix_hart", "add t3, t3, tp", ld ++ " t3, 0(t3)"]
  HartQos -> ["lla t3, fpr_g_tlsoff", ld ++ " t3, 0(t3)", "add t3, t3, tp", ld ++ " t3, 0(t3)"]
  HartTlsEsp -> ["lui t3, %tprel_hi(fpr_esp_hart)", "add t3, t3, tp, %tprel_add(fpr_esp_hart)", ld ++ " t3, %tprel_lo(fpr_esp_hart)(t3)"]
  where ld = if cfgWidth cfg == W32 then "lw" else "ld"

render :: RVConfig -> Fn -> Layout -> Bool -> [String] -> Item -> [String]
render _ fn _ _ _ (ILabel l) = [local fn l ++ ":"]
render cfg fn ly large restores (I i) = map (\s -> if last s == ':' then s else "    " ++ s) (go (siOpcode i) (siDefs i) (siUses i))
  where
    r (OP (Phys name)) = name
    r o = error ("RV64 unplaced operand " ++ show o)
    num (OI n) = n
    num o = error ("RV64 non-immediate " ++ show o)
    off ref = toInteger (lyOffset ly M.! ref)
    w = toInteger (wordBytes cfg)
    ld = if cfgWidth cfg == W32 then "lw" else "ld"
    stWord = if cfgWidth cfg == W32 then "sw" else "sd"
    epilogue = restores ++ ["mv t3, s0"] ++ memory ld "ra" "s0" (-w) ++ memory ld "s0" "s0" (-2*w) ++ (if large then memory ld "sp" "t3" (-3*w) else ["mv sp, t3"])
    hart = hartRead cfg
    l point = local fn (entryLabel i point)
    stack = [ld ++ " t5, " ++ show (57*w) ++ "(t3)", "sub t4, sp, t5", ld ++ " t5, " ++ show (58*w) ++ "(t3)", "bltu t4, t5, " ++ l StackReady, ("call " ++ Call.runtimeName Call.GrowStackEntry), "beqz a0, " ++ l SameStack, "mv sp, a0", l SameStack ++ ":"] ++ hart ++ [l StackReady ++ ":"]
    tick = tickN 1
    tickN n = [ld ++ " t4, 0(t3)", "addi t4, t4, -" ++ show n, stWord ++ " t4, 0(t3)", "bgtz t4, " ++ l FuelReady, ("call " ++ Call.runtimeName Call.FuelSaveEntry), l FuelReady ++ ":"]
    ew = if cfgWidth cfg == W32 then "32" else "64"
    go op ds us = case (op,ds,us) of
      (O.Common O.EntryStatic,[],[]) -> []
      (O.Common O.Params,_,[]) -> []
      (O.RV R.FrameLoad,[d],[OF ref 0]) -> memory ld (r d) "s0" (off ref)
      (O.RV R.FrameStore,[],[v,OF ref 0]) -> memory stWord (r v) "s0" (off ref)
      (O.Common O.LoadSpill,[d],[n]) -> hart ++ memory ld (r d) "t3" (w*(1+num n))
      (O.Common O.StoreSpill,[],[v,n]) -> hart ++ memory stWord (r v) "t3" (w*(1+num n))
      (O.RV R.Literal,[d],[n]) -> ["li " ++ r d ++ ", " ++ show (num n)]
      -- a module's unit is assembled under .option pic: `la` of an external
      -- symbol goes through the GOT (interposable), a unit-local label stays
      -- PC-relative (`lla`), as the A64 module pass keeps local labels
      (O.RV R.Address,[d],[OAddr sym]) -> [(if cfgHart cfg == HartTlsIe && ".L" `isPrefixOf` addressName sym then "lla " else "la ") ++ r d ++ ", " ++ addressName sym]
      (O.RV R.Move,[d],[v]) -> ["mv " ++ r d ++ ", " ++ r v]
      (O.RV o,[d],[v,n]) | o `elem` [R.ShiftLeftImmediate,R.ShiftRightArithmeticImmediate,R.AndImmediate,R.OrImmediate,R.XorImmediate] -> [R.name o ++ " " ++ r d ++ ", " ++ r v ++ ", " ++ show (num n)]
      (O.RV o,[d],[a,b]) | o `elem` [R.Add,R.Subtract,R.Multiply,R.MultiplyHigh,R.Divide,R.And,R.Or,R.Xor,R.LessUnsigned,R.ShiftLeft,R.ShiftRight] -> [R.name o ++ " " ++ r d ++ ", " ++ r a ++ ", " ++ r b]
      (O.RV (R.Compare c),[d],[a,b]) -> integerCompare c d a b
      (O.RV o,[d],[base,n]) | o `elem` [R.Load64,R.Load32,R.LoadByte,R.LoadHalf,R.LoadUnsigned32] -> memory (R.name o) (r d) (r base) (num n)
      (O.RV o,[],[base,v,n]) | o `elem` [R.Store64,R.Store32,R.StoreHalf,R.StoreByte] -> memory (R.name o) (r v) (r base) (num n)
      (O.RV R.Fence,[],[]) -> ["fence iorw, iorw"]
      (O.RV R.BranchNonzero,[],[v,OL l']) -> ["bnez " ++ r v ++ ", " ++ local fn l']
      (O.RV R.Jump,[],[OL l']) -> ["j " ++ local fn l']
      (O.Common O.JumpLoop,[],[OL l']) -> ["j " ++ local fn l']
      (O.RV R.Call,_,OCode sym:_) -> ["call " ++ codeName sym]
      (O.Common O.TailJump,[],OCode sym:_) -> epilogue ++ ["tail " ++ codeName sym]
      (O.RV R.Ret,[],[_]) -> epilogue ++ ["ret"]
      (O.RV R.Push,[],[v]) -> ["addi sp, sp, -16", stWord ++ " " ++ r v ++ ", 0(sp)"]
      (O.RV R.ApplyN,[_],[n]) -> ["mv a2, sp", "li a1, " ++ show (num n)] ++ memory ld "a0" "sp" (16*num n) ++ [("call " ++ Call.runtimeName Call.ApplyEntry)] ++ adjust "sp" "sp" (16*(num n+1))
      (O.RV R.Panic,[],[OAddr sym]) -> ["la a0, " ++ addressName sym, ("call " ++ Call.runtimeName Call.PanicEntry)]
      (O.Common O.EntryCheckTick,[],[]) -> hart ++ stack ++ tick
      (O.Common O.EntryCheck,[],[]) -> hart ++ stack
      (O.Common O.EntryTick,[],[]) -> hart ++ tick
      (O.Common O.TickN,[],[OI n]) -> hart ++ tickN n
      (O.RV R.VectorMax,[d],[]) -> ["vsetvli " ++ r d ++ ", x0, e" ++ ew ++ ", m1, ta, ma"]
      (O.RV R.VectorLanes,[d],[a,n,OI bound]) ->
        ["vsetvli t4, " ++ r n ++ ", e" ++ ew ++ ", m1, ta, ma", "vle" ++ ew ++ ".v v8, (" ++ r a ++ ")",
         "vredmax.vs v9, v8, v8", "vredmin.vs v10, v8, v8",
         "vmv.x.s t5, v9", "li t6, " ++ show bound, "slt " ++ r d ++ ", t5, t6",
         "vmv.x.s t5, v10", "li t6, " ++ show (negate bound), "slt t5, t6, t5",
         "and " ++ r d ++ ", " ++ r d ++ ", t5"]
      (O.RV R.VectorSum,[d],[acc]) -> ["vmv.s.x v9, x0", "vredsum.vs v9, v8, v9", "vmv.x.s t5, v9", "add " ++ r d ++ ", " ++ r acc ++ ", t5"]
      -- Floating-point leaves retain IEEE bits in the word ABI. The
      -- typed operation chooses width and predicate; rendering never parses it.
      (O.RV (R.TreeCompare width c),[d],[]) -> floatCompare width c d
      (O.RV (R.TreeLeaf width),[],[x,OI n]) -> ["fmv." ++ moveWidth width ++ ".x ft" ++ show n ++ ", " ++ r x]
      (O.RV (R.TreeOutput width),[d],[OI n]) -> ["fmv.x." ++ moveWidth width ++ " " ++ r d ++ ", ft" ++ show n]
      (O.RV (R.TreeNode width op),[],[OI n]) ->
        ["f" ++ O.floatName op ++ "." ++ suffix width ++ " ft" ++ show n ++ ", ft" ++ show n ++ ", ft" ++ show (n+1)]
      (O.RV (R.FloatBinary width op),[d],[a,b]) ->
        [moveIn width a "ft0",moveIn width b "ft1",
         "f" ++ O.floatName op ++ "." ++ suffix width ++ " ft0, ft0, ft1","fmv.x." ++ moveWidth width ++ " " ++ r d ++ ", ft0"]
      (O.RV (R.FloatCompare width c),[d],[a,b]) ->
        [moveIn width a "ft0",moveIn width b "ft1"] ++ floatCompare width c d
      _ -> error ("RV64 no render form " ++ show (op,ds,us))
    suffix O.Float64="d";suffix O.Float32="s"
    moveWidth O.Float64="d";moveWidth O.Float32="w"
    moveIn width a dest="fmv." ++ moveWidth width ++ ".x " ++ dest ++ ", " ++ r a
    floatCompare width c d=case c of
      Lt->cmp "flt" "ft0" "ft1";Gt->cmp "flt" "ft1" "ft0"
      Le->cmp "fle" "ft0" "ft1";Ge->cmp "fle" "ft1" "ft0"
      Eq->cmp "feq" "ft0" "ft1";Ne->cmp "feq" "ft0" "ft1" ++ ["xori " ++ r d ++ ", " ++ r d ++ ", 1"]
      where cmp op a b=[op ++ "." ++ suffix width ++ " " ++ r d ++ ", " ++ a ++ ", " ++ b]
    integerCompare c d a b=case c of
      Eq->equal "seqz";Ne->equal "snez"
      Lt->less a b False;Gt->less b a False;Le->less b a True;Ge->less a b True
      where
        equal op=["xor " ++ r d ++ ", " ++ r a ++ ", " ++ r b,op ++ " " ++ r d ++ ", " ++ r d]
        less x y invert=["slt " ++ r d ++ ", " ++ r x ++ ", " ++ r y] ++ ["xori " ++ r d ++ ", " ++ r d ++ ", 1" | invert]

local :: Fn -> Label -> String
local fn (Label l) = ".Ltir_" ++ mangleName (fnName fn) ++ "_" ++ l

-- RV assembler pseudos may expand to several instructions. Count a safe
-- unrelaxed maximum, so linker relaxation can only lower this bound.
instructionCost :: [String] -> Int
instructionCost = sum . map cost
  where
    cost line = case words line of
      [] -> 0
      (op:_) | last line == ':' -> 0
             | op `elem` ["call", "tail", "la"] -> 2
             | op == "li" -> 8 -- any signed 64-bit constant
             | otherwise -> 1

wordBytes :: RVConfig -> Int
wordBytes cfg = widthBits (cfgWidth cfg) `div` 8
