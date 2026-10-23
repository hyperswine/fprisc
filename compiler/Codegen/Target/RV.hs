{-# LANGUAGE LambdaCase #-}
-- Direct RV32/RV64 selection from typed IR with an explicit word policy. No RISC-V text from Codegen.hs is
-- consumed here. Checked arithmetic initially uses the exact C primitives;
-- the shared allocator handles calls, spills, parallel arguments and loops.
module Codegen.Target.RV
  ( RVConfig (..), RVHart (..), rvSelectionRev, emitFnRV ) where

import Codegen.Allocate
import Codegen.Bounds
import Codegen.Frame
import Codegen.IR
import Codegen.Policy
import Codegen.Selected
import Codegen.Target.Common
import Control.Monad (forM_, unless, when)
import Control.Monad.State.Strict
import Data.List (isPrefixOf, intercalate, stripPrefix)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

rvSelectionRev :: Int
rvSelectionRev = 14 -- comparison and F32 trees; prior: 13: the ESP-IDF host (the hart in fpr_esp_hart, local-exec, the 32-bit word); prior: 12: 12: QOS RISC-V apps and plugins: the hart borrowed through fpr_g_tlsoff; prior: 11: 11: posix modules: the hart through initial-exec TLS (la.tls.ie), local labels PC-relative under .option pic; prior: 10: generic HAL partial/opaque application; prior 9: inferred boxed I64 operators; prior 8: inference-generated vector runtime entries; prior 7: typed column memory and kernel arithmetic; prior: 6: an ESP-IDF host keeps the legacy generator (its hart is fpr_esp_hart); 5: units with no legacy code skip translation; 4: in-place constructor reuse; 3: inline F64 arithmetic and comparisons, kernel calls by symbol; prior 2:

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
args = map (p . ("a" ++) . show) [0..7 :: Int]
callers = args ++ map (p . ("t" ++) . show) [0..6 :: Int] ++ [p "ra"]
saved = map (p . ("s" ++) . show) [1..11 :: Int]
scratch = map p ["t0", "t1", "t2"]
reserved :: [Phys]
reserved = map p ["zero", "ra", "sp", "gp", "tp", "s0", "t3", "t4", "t5", "t6"]
regFile :: RegisterFile
regFile = RegisterFile (\r -> if r `elem` callers ++ saved ++ reserved then Just GPR else Nothing) reserved
vreg :: VId -> VReg
vreg (VId n) = VReg n
anyV :: VReg -> Operand
anyV v = OV v (Any GPR)
fixed :: VReg -> Phys -> Operand
fixed v r = OV v (Fix r)
label :: BId -> Label
label (BId n) = Label ("b" ++ show n)

-- A function-local builder. Every temporary is an ordinary selected value.
data Sel = Sel { nextV :: Int, nextL :: Int, items :: [Item], nulls :: S.Set (Int, Int), strings :: S.Set String }
type S = StateT Sel (Either String)
emit :: SInstr -> S ()
emit i = modify (\s -> s {items = I i : items s})
mark :: Label -> S ()
mark l = modify (\s -> s {items = ILabel l : items s})
fresh :: S VReg
fresh = do n <- gets nextV; modify (\s -> s {nextV = n+1}); pure (VReg n)
freshLabel :: S Label
freshLabel = do n <- gets nextL; modify (\s -> s {nextL = n+1}); pure (Label ("edge" ++ show n))
li :: VReg -> Integer -> S ()
li d n = emit (plain "li" [anyV d] [OI n])
rr :: String -> VReg -> VReg -> VReg -> S ()
rr op d a b = emit (plain op [anyV d] [anyV a, anyV b])
ri :: String -> VReg -> VReg -> Integer -> S ()
ri op d a n = emit (plain op [anyV d] [anyV a, OI n])
address :: VReg -> String -> S ()
address d sym = emit (plain "la" [anyV d] [OS sym])
branch :: VReg -> Label -> S ()
branch v l = emit ((plain "bnez" [] [anyV v, OL l]) {siControl = CondTo [l]})
jump :: Label -> S ()
jump l = emit ((plain "j" [] [OL l]) {siControl = JumpTo l})
loadAt :: String -> VReg -> VReg -> Integer -> S ()
loadAt op d base off = emit ((plain op [anyV d] [anyV base, OI off]) {siImplicitDefs = [p "t6"]})
storeAt :: String -> VReg -> VReg -> Integer -> S ()
storeAt op base value off = emit ((plain op [] [anyV base, anyV value, OI off]) {siImplicitDefs = [p "t6"]})

stage :: [VReg] -> S ()
stage vs = forM_ (zip [0..] (drop 8 vs)) $ \(n,v) ->
  emit ((plain "store.spill" [] [anyV v, OI n]) {siImplicitDefs = map p ["t3","t4"]})
call :: String -> Bool -> Bool -> [VReg] -> Maybe VReg -> Bool -> S ()
call sym tick runtime vs result tailCall = do
  stage vs
  emit ((plain (if tailCall then "tailjump" else "call")
    [fixed v (p "a0") | Just v <- [result]] (OS sym : zipWith fixed vs args))
    {siClobbers = filter (\r -> r /= p "a0" || result == Nothing) callers,
     siImplicitDefs = if tailCall then map p ["sp","s0","ra","t3"] else [],
     siControl = if tailCall then Return else Next,
     siCalls = [Call sym tick runtime]})
calleeSym :: Callee -> String
calleeSym c = case calleeKind c of Foreign s -> s; Generated s -> s; _ -> functionSymbol (calleeName c)
entry :: Bool -> Bool -> S ()
entry stack fuel = do
  Label l <- freshLabel
  emit ((plain (if stack then if fuel then "entry.check.tick" else "entry.check" else "entry.tick") [] [])
    {siImplicitDefs = map p ["t3","t4","t5","sp"], siImplicitUses = [p "tp"],
     siClobbers = callers, siNote = l,
     siCalls = [Call "fpr_stack_grow" False True | stack] ++ [Call "fpr_fuel_exhausted" True False | fuel]})
boxed :: VReg -> S VReg
boxed v = do t <- fresh; d <- fresh; ri "slli" t v 1; ri "ori" d t 1; pure d
parallel :: [(VReg,VReg)] -> S ()
parallel pairs = do
  -- Simultaneous block arguments: first copy every source to a fresh value.
  staged <- mapM (\(d,s) -> do t <- fresh; emit (plain "mv" [anyV t] [anyV s]); pure (d,t)) pairs
  forM_ staged $ \(d,t) -> emit (plain "mv" [anyV d] [anyV t])

select :: RVConfig -> Fn -> Either String (SFn, S.Set VReg, Sel)
select cfg fn = do
  validatePolicy (cfgPolicy cfg)
  unless (cfgWidth cfg == policyWidth (cfgPolicy cfg)) (Left "RISC-V word width disagrees with the IR policy")
  unless (all (intFitsWidth (cfgWidth cfg)) [n | b <- fnBlocks fn, Instr _ (OConstInt n) <- bInstrs b]) (Left "RISC-V literal is outside the target Int range")
  let defs = concatMap blockDefs (fnBlocks fn)
      params = [vreg v | b <- fnBlocks fn, bId b == fnEntry fn, (v,_) <- bParams b]
      managed = S.fromList [vreg v | (v,TVal) <- defs]
      start = 1 + maximum (0 : [n | (VId n,_) <- defs])
  unless (all ((`elem` [TVal,TInt,TPred,TAddr]) . snd) defs) (Left "RV64: a raw or float-register value is not legalized")
  (_, st) <- runStateT (mapM_ block (fnBlocks fn)) (Sel start 0 [] S.empty S.empty)
  pure (SFn (fnName fn) params (reverse (items st)), managed, st)
  where
    w = toInteger (wordBytes cfg)
    ld = if cfgWidth cfg == W32 then "lw" else "ld"
    stWord = if cfgWidth cfg == W32 then "sw" else "sd"
    block b = do
      mark (label (bId b))
      let (prefix, rest) = span (\(Instr _ op) -> op `elem` [OStackCheck,OSafepoint]) (bInstrs b)
      if bId b == fnEntry fn then do
        let stack = any (\(Instr _ op) -> op == OStackCheck) prefix
            fuel = any (\(Instr _ op) -> op == OSafepoint) prefix
        unless (stack && fuel) (lift (Left "RV64: hosted entry lacks stack/fuel obligations"))
        entry stack fuel
      else forM_ prefix $ \(Instr _ op) -> case op of
        OSafepoint -> entry False True
        _ -> lift (Left "RV64: non-entry stack check")
      mapM_ instruction rest
      terminator b
    instruction (Instr result op) = case op of
      OStore _ a n v -> storeAt stWord (vreg a) (vreg v) (fromIntegral n)
      OStackCheck -> lift (Left "RV64: misplaced stack check")
      OSafepoint -> entry False True
      OSafepointN n -> do
        Label l <- freshLabel
        emit ((plain "tick.n" [] [OI (fromIntegral n)])
          {siImplicitDefs = map p ["t3","t4","t5","sp"], siImplicitUses = [p "tp"],
           siClobbers = callers, siNote = l, siCalls = [Call "fpr_fuel_exhausted" True False]})
      OSimdPair {} -> lift (Left "a NEON pair on RISC-V")
      _ -> case result of
        Nothing -> lift (Left "compiler error: RV64 instruction lacks result")
        Just (v,_) -> value (vreg v) op
    value d = \case
      OAddress v -> emit (plain "mv" [anyV d] [anyV (vreg v)])
      OIndex a i -> do
        offset <- fresh
        ri "slli" offset (vreg i) (if cfgWidth cfg == W32 then 2 else 3)
        rr "add" d (vreg a) offset
      OLoad _ a n -> loadAt ld d (vreg a) (fromIntegral n)
      OLoadByte a n -> loadAt "lbu" d (vreg a) (fromIntegral n)
      OStore {} -> lift (Left "compiler error: a store has a result")
      OConstInt n -> li d n
      OBits n -> li d n
      ONullary t v -> do
        sym <- case (t,v) of
          (0,0) -> pure "fpr_unit"; (1,0) -> pure "fpr_false"; (1,1) -> pure "fpr_true"
          _ -> modify (\s -> s {nulls = S.insert (t,v) (nulls s)}) >> pure (".Lnul_" ++ show t ++ "_" ++ show v)
        address d sym
      OString s -> modify (\st -> st {strings = S.insert s (strings st)}) >> address d (stringLabel s)
      OSymbol s -> address d s
      OFunValue n -> address d ("fpr_obj_" ++ mangleName n)
      OTag v -> do t <- fresh; ri "slli" t (vreg v) 1; ri "ori" d t 1
      OUntag v -> ri "srai" d (vreg v) 1
      ONot v -> ri "xori" d (vreg v) 1
      OIsInt v -> ri "andi" d (vreg v) 1
      OTruth v -> loadAt "lw" d (vreg v) 4
      OBoolOf v -> do
        yes <- freshLabel; done <- freshLabel
        branch (vreg v) yes; address d "fpr_false"; jump done
        mark yes; address d "fpr_true"; mark done
      OTagTest t variant v -> do
        miss <- freshLabel; done <- freshLabel
        bit <- fresh; ri "andi" bit (vreg v) 1; branch bit miss
        actual <- fresh; want <- fresh; bad <- fresh
        loadAt "lw" actual (vreg v) 0; li want (fromIntegral t); rr "cmp.ne" bad actual want; branch bad miss
        loadAt "lw" actual (vreg v) 4; li want (fromIntegral variant); rr "cmp.eq" d actual want; jump done
        mark miss; li d 0; mark done
      OMake t variant fs -> do
        size <- fresh; li size (8 + w * fromIntegral (length fs)); call "fpr_alloc" False True [size] (Just d) False
        forM_ [(0,t),(4,variant)] $ \(off,n) -> do h <- fresh; li h (fromIntegral n); storeAt "sw" d h off
        forM_ (zip [0..] fs) $ \(n,v) -> storeAt stWord d (vreg v) (8+w*n)
      OReuse _ _ root fs -> do
        forM_ (zip [0..] fs) $ \(n,v) -> storeAt stWord (vreg root) (vreg v) (8+w*n)
        emit (plain "mv" [anyV d] [anyV (vreg root)])
      OField n v -> loadAt ld d (vreg v) (8+w*fromIntegral n)
      OStrLen s -> do t <- fresh; call "fpr_g_strlen_call1" False True [vreg s] (Just t) False; ri "srai" d t 1
      OCharAt s n -> do i <- boxed (vreg n); t <- fresh; call "fpr_g_charAt_call2" False True [vreg s,i] (Just t) False; ri "srai" d t 1
      OKernelArith op a b -> do
        slow <- freshLabel; zero <- freshLabel; done <- freshLabel
        result <- fresh
        let x = vreg a; y = vreg b
            failUnlessEqual lhs rhs = do bad <- fresh; rr "cmp.ne" bad lhs rhs; branch bad slow
        case op of
          Add -> rr "add" result x y
          Sub -> rr "sub" result x y
          Mul -> do
            rr "mul" result x y
            high <- fresh; sign <- fresh
            rr "mulh" high x y
            ri "srai" sign result (8*w-1)
            failUnlessEqual high sign
          Div -> do
            isZero <- fresh; z <- fresh; li z 0
            rr "cmp.eq" isZero y z; branch isZero zero
            rr "div" result x y
        shifted <- fresh; fit <- fresh
        ri "slli" shifted result 1; ri "srai" fit shifted 1
        failUnlessEqual fit result
        emit (plain "mv" [anyV d] [anyV result]); jump done
        mark slow; call "fpr_int_overflow_kernel" False True [] Nothing False
        mark zero; call "fpr_div_zero_kernel" False True [] Nothing False
        li d 0 -- unreachable after a noreturn trap
        mark done
      OArith op a b -> do
        x <- boxed (vreg a); y <- boxed (vreg b); t <- fresh
        call ("fpr_prim_fn_" ++ mangleName (arithSymbol op)) False True [x,y] (Just t) False
        ri "srai" d t 1
      OBit op a b -> rr (case op of BAnd -> "and"; BOr -> "or"; BXor -> "xor") d (vreg a) (vreg b)
      OFloatBin o a b -> rr ("fbin." ++ (case o of FAdd -> "add"; FSub -> "sub"; FMul -> "mul"; FDiv -> "div")) d (vreg a) (vreg b)
      OFloatCmp o a b -> rr ("fcmp." ++ (case o of Lt -> "lt"; Gt -> "gt"; Le -> "le"; Ge -> "ge"; Eq -> "eq"; Ne -> "ne")) d (vreg a) (vreg b)
      OFloat32Bin o a b -> rr ("fbin32." ++ (case o of FAdd -> "add"; FSub -> "sub"; FMul -> "mul"; FDiv -> "div")) d (vreg a) (vreg b)
      OFloatCmpTree o x y -> do
        forM_ (ftreeScheduleAt 0 x ++ ftreeScheduleAt 1 y) $ \case
          FSLeaf v n -> emit (plain "ftree.leaf" [] [anyV (vreg v), OI (fromIntegral n)])
          FSNode f n -> emit (plain ("ftree." ++ (case f of FAdd -> "add"; FSub -> "sub"; FMul -> "mul"; FDiv -> "div")) [] [OI (fromIntegral n)])
        emit (plain ("ftree.cmp." ++ (case o of Lt -> "lt"; Gt -> "gt"; Le -> "le"; Ge -> "ge"; Eq -> "eq"; Ne -> "ne")) [anyV d] [])
      OFloat32CmpTree o x y -> do
        forM_ (ftreeScheduleAt 0 x ++ ftreeScheduleAt 1 y) $ \case
          FSLeaf v n -> emit (plain "ftree32.leaf" [] [anyV (vreg v), OI (fromIntegral n)])
          FSNode f n -> emit (plain ("ftree32." ++ (case f of FAdd -> "add"; FSub -> "sub"; FMul -> "mul"; FDiv -> "div")) [] [OI (fromIntegral n)])
        emit (plain ("ftree32.cmp." ++ (case o of Lt -> "lt"; Gt -> "gt"; Le -> "le"; Ge -> "ge"; Eq -> "eq"; Ne -> "ne")) [anyV d] [])
      OFloatTree t -> do
        let (steps, root) = ftreeSchedule t
        forM_ steps $ \step -> case step of
          FSLeaf v n -> emit (plain "ftree.leaf" [] [anyV (vreg v), OI (fromIntegral n)])
          FSNode o n -> emit (plain ("ftree." ++ (case o of FAdd -> "add"; FSub -> "sub"; FMul -> "mul"; FDiv -> "div")) [] [OI (fromIntegral n)])
        emit (plain "ftree.out" [anyV d] [OI (fromIntegral root)])
      OFloat32Tree t -> do
        let (steps, root) = ftreeSchedule t
        forM_ steps $ \step -> case step of
          FSLeaf v n -> emit (plain "ftree32.leaf" [] [anyV (vreg v), OI (fromIntegral n)])
          FSNode o n -> emit (plain ("ftree32." ++ (case o of FAdd -> "add"; FSub -> "sub"; FMul -> "mul"; FDiv -> "div")) [] [OI (fromIntegral n)])
        emit (plain "ftree32.out" [anyV d] [OI (fromIntegral root)])
      OFloat32Cmp o a b -> rr ("fcmp32." ++ (case o of Lt -> "lt"; Gt -> "gt"; Le -> "le"; Ge -> "ge"; Eq -> "eq"; Ne -> "ne")) d (vreg a) (vreg b)
      -- RISC-V V: v8 the lanes, v9/v10 reductions; t4..t6 scratch (declared)
      ORvvVlMax -> emit (plain "rvv.vlmax" [anyV d] [])
      ORvvLanes a n -> emit ((plain "rvv.lanes" [anyV d] [anyV (vreg a), anyV (vreg n), OI (rvvLaneBound (cfgWidth cfg))]) {siImplicitDefs = map p ["t4","t5","t6"]})
      ORvvSumLoaded acc -> emit ((plain "rvv.sum" [anyV d] [anyV (vreg acc)]) {siImplicitDefs = [p "t5"]})
      OShift op a b -> do
        x <- boxed (vreg a); y <- boxed (vreg b); t <- fresh
        call (if op == Shl then "fpr_g_BITSHIFTL_call2" else "fpr_g_BITSHIFTR_call2") False True [x,y] (Just t) False
        ri "srai" d t 1
      OCmp op a b -> rr ("cmp." ++ case op of Eq -> "eq"; Ne -> "ne"; Lt -> "lt"; Gt -> "gt"; Le -> "le"; Ge -> "ge") d (vreg a) (vreg b)
      OEqVal eq a b -> do
        t <- fresh; call ("fpr_prim_fn_" ++ mangleName (if eq then "==" else "!=")) False True [vreg a,vreg b] (Just t) False
        loadAt "lw" d t 4
      OCall c vs -> call (calleeSym c) (not (isForeign c)) (isForeign c) (map vreg vs) (Just d) False
      OApply f vs -> do
        forM_ (f:vs) $ \v -> emit ((plain "push" [] [anyV (vreg v)]) {siImplicitDefs = [p "sp"]})
        emit ((plain "applyn" [fixed d (p "a0")] [OI (fromIntegral (length vs))])
          {siImplicitDefs = map p ["a1","a2","sp","t6"], siClobbers = filter (/= p "a0") callers,
           siCalls = [Call "fpr_applyN" False True]})
      op -> lift (Left ("compiler error: RV64 value " ++ show op))
    targetParams bid = [vreg v | b <- fnBlocks fn, bId b == bid, (v,_) <- bParams b]
    edge bid vs = parallel (zip (targetParams bid) (map vreg vs)) >> jump (label bid)
    terminator b = case bTerm b of
      TRet v -> emit ((plain "ret" [] [fixed (vreg v) (p "a0")]) {siImplicitDefs = map p ["sp","s0","ra","t3"], siControl = Return})
      TBr bid vs | bid == fnEntry fn -> call (functionSymbol (fnName fn)) True False (map vreg vs) Nothing True
                 | otherwise -> edge bid vs
      TCondBr v yes ys no ns -> do l <- freshLabel; branch (vreg v) l; edge no ns; mark l; edge yes ys
      TTailCall c vs -> call (calleeSym c) (not (isForeign c)) (isForeign c) (map vreg vs) Nothing True
      TUnreachable s -> do
        modify (\st -> st {strings = S.insert s (strings st)})
        emit ((plain "panic" [] [OS (stringLabel s)]) {siImplicitDefs = [p "a0"], siClobbers = callers, siControl = Return, siCalls = [Call "fpr_panic" False True]})

allocConfig :: RVConfig -> Fn -> S.Set VReg -> AllocConfig
allocConfig cfg fn managed = AllocConfig
  { acCalleeSaved = saved, acCallerSaved = args, acScratch = scratch,
    acPreserved = map p ["sp","s0","gp","tp"], acClassOf = rfClassOf regFile,
    acArrival = \vs -> plain "params" (zipWith fixed (take 8 vs) args) [] :
      [(plain "load.spill" [anyV v] [OI n]) {siImplicitDefs = map p ["t3","t4"]} | (n,v) <- zip [0..] (drop 8 vs)],
    acLoad = \r ref -> (plain "load.slot" [OP r] [OF ref 0]) {siImplicitDefs = [p "t6"]},
    acStore = \r ref -> (plain "store.slot" [] [OP r,OF ref 0]) {siImplicitDefs = [p "t6"]},
    acMove = \d s -> plain "mv" [OP d] [OP s],
    acSlot = \n v -> frameObj n (wordBytes cfg) (wordBytes cfg) (SpillSlot n) (S.member v managed),
    acEarlyDef = const False,
    acSelfLoop = if cfgSelfLoops cfg then Just (functionSymbol (fnName fn)) else Nothing }

emitFnRV :: RVConfig -> Fn -> Either String NativeFn
emitFnRV cfg fn = do
  (sf, managed, st) <- select cfg fn
  let checked = either (Left . ("compiler error: " ++)) Right
      ac = allocConfig cfg fn managed
  checked (checkFn regFile sf)
  allocation <- checked (allocateFn ac sf)
  checked (checkAllocation ac (fnName fn) (alBody allocation))
  let saveObjects = [frameObj (-n-1) (wordBytes cfg) (wordBytes cfg) (SavedRegister r) False | (n,Phys r) <- zip [0..] (alSaved allocation)]
      ly = layout (2 * wordBytes cfg) 16 (saveObjects ++ alSlots allocation)
      (shallow, body) = shallowEntry (polStackCheck (cfgPolicy cfg)) (lyBytes ly) (alBody allocation)
  let ceiling = if cfgHart cfg `elem` [HartTls, HartTlsIe, HartQos, HartTlsEsp] then 32768 else 1024
  when (lyBytes ly > ceiling) (Left ("RISC-V frame exceeds the profile ceiling of " ++ show ceiling ++ " bytes"))
  let reg (Phys r) = r
      off ref = toInteger (lyOffset ly M.! ref)
      w = toInteger (wordBytes cfg)
      ld = if cfgWidth cfg == W32 then "lw" else "ld"
      stWord = if cfgWidth cfg == W32 then "sw" else "sd"
      saves = concat [memory stWord r "s0" (off (foRef o)) | o <- saveObjects, SavedRegister r <- [foKind o]]
      restores = concat [memory ld r "s0" (off (foRef o)) | o <- saveObjects, SavedRegister r <- [foKind o]]
      n = toInteger (lyBytes ly)
      prologue = adjust "sp" "sp" (-n) ++ memory stWord "ra" "sp" (n-w) ++ memory stWord "s0" "sp" (n-2*w) ++ adjust "s0" "sp" n ++ saves
      rendered = [(it, render cfg fn ly restores it) | it <- body]
      report = analyse (TIns (instructionCost prologue) FNext False 0 : concatMap token rendered)
      name = fnName fn
      header = ["# fn " ++ name ++ " (arity " ++ show (length (sfParams sf)) ++ ") typed-ir rv" ++ show (widthBits (cfgWidth cfg)) ++ " frame=" ++ show n
                 ++ (if shallow then " shallow=yes" else " shallow=no") ++ " saved="
                 ++ (if null (alSaved allocation) then "none" else intercalate "," (map reg (alSaved allocation))) ++ " " ++ statsLine (alStats allocation)]
          ++ ["    " ++ (if cfgWeak cfg && '@' `notElem` name then ".weak" else ".globl") ++ " " ++ functionSymbol name | S.member name (cfgExports cfg)]
          ++ [functionSymbol name ++ ":"]
  pure (NativeFn name (header ++ map ("    " ++) prologue ++ concatMap snd rendered ++ [reportLine name report, ""]) report (S.toList (nulls st)) (S.toList (strings st)))
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
render :: RVConfig -> Fn -> Layout -> [String] -> Item -> [String]
render _ fn _ _ (ILabel l) = [local fn l ++ ":"]
render cfg fn ly restores (I i) = map (\s -> if last s == ':' then s else "    " ++ s) (go (siOp i) (siDefs i) (siUses i))
  where
    r (OP (Phys name)) = name
    r o = error ("RV64 unplaced operand " ++ show o)
    num (OI n) = n
    num o = error ("RV64 non-immediate " ++ show o)
    off ref = toInteger (lyOffset ly M.! ref)
    w = toInteger (wordBytes cfg)
    ld = if cfgWidth cfg == W32 then "lw" else "ld"
    stWord = if cfgWidth cfg == W32 then "sw" else "sd"
    epilogue = restores ++ ["mv t3, s0"] ++ memory ld "ra" "s0" (-w) ++ memory ld "s0" "s0" (-2*w) ++ ["mv sp, t3"]
    hart = case cfgHart cfg of
      HartTp -> ["mv t3, tp"]
      HartTls -> ["lui t3, %tprel_hi(fpr_posix_hart)", "add t3, t3, tp, %tprel_add(fpr_posix_hart)", ld ++ " t3, %tprel_lo(fpr_posix_hart)(t3)"]
      HartTlsIe -> ["la.tls.ie t3, fpr_posix_hart", "add t3, t3, tp", ld ++ " t3, 0(t3)"]
      HartQos -> ["lla t3, fpr_g_tlsoff", ld ++ " t3, 0(t3)", "add t3, t3, tp", ld ++ " t3, 0(t3)"]
      HartTlsEsp -> ["lui t3, %tprel_hi(fpr_esp_hart)", "add t3, t3, tp, %tprel_add(fpr_esp_hart)", ld ++ " t3, %tprel_lo(fpr_esp_hart)(t3)"]
    l suffix = local fn (Label (siNote i ++ suffix))
    stack = [ld ++ " t5, " ++ show (57*w) ++ "(t3)", "sub t4, sp, t5", ld ++ " t5, " ++ show (58*w) ++ "(t3)", "bltu t4, t5, " ++ l "_stk", "call fpr_stack_grow", "beqz a0, " ++ l "_same", "mv sp, a0", l "_same" ++ ":"] ++ hart ++ [l "_stk" ++ ":"]
    tick = tickN 1
    tickN n = [ld ++ " t4, 0(t3)", "addi t4, t4, -" ++ show n, stWord ++ " t4, 0(t3)", "bgtz t4, " ++ l "_fuel", "call fpr_fuel_exhausted", l "_fuel" ++ ":"]
    ew = if cfgWidth cfg == W32 then "32" else "64"
    go op ds us = case (op,ds,us) of
      ("params",_,[]) -> []
      ("load.slot",[d],[OF ref 0]) -> memory ld (r d) "s0" (off ref)
      ("store.slot",[],[v,OF ref 0]) -> memory stWord (r v) "s0" (off ref)
      ("load.spill",[d],[n]) -> hart ++ memory ld (r d) "t3" (w*(1+num n))
      ("store.spill",[],[v,n]) -> hart ++ memory stWord (r v) "t3" (w*(1+num n))
      ("li",[d],[n]) -> ["li " ++ r d ++ ", " ++ show (num n)]
      -- a module's unit is assembled under .option pic: `la` of an external
      -- symbol goes through the GOT (interposable), a unit-local label stays
      -- PC-relative (`lla`), as the A64 module pass keeps local labels
      ("la",[d],[OS sym]) -> [(if cfgHart cfg == HartTlsIe && ".L" `isPrefixOf` sym then "lla " else "la ") ++ r d ++ ", " ++ sym]
      ("mv",[d],[v]) -> ["mv " ++ r d ++ ", " ++ r v]
      (o,[d],[v,n]) | o `elem` ["slli","srai","andi","ori","xori"] -> [o ++ " " ++ r d ++ ", " ++ r v ++ ", " ++ show (num n)]
      (o,[d],[a,b]) | o `elem` ["add","sub","mul","mulh","div","and","or","xor"] -> [o ++ " " ++ r d ++ ", " ++ r a ++ ", " ++ r b]
      (o,[d],[a,b]) | o `elem` ["cmp.eq","cmp.ne"] -> ["xor " ++ r d ++ ", " ++ r a ++ ", " ++ r b, (if o == "cmp.eq" then "seqz " else "snez ") ++ r d ++ ", " ++ r d]
      (o,[d],[a,b]) | o `elem` ["cmp.lt","cmp.gt","cmp.le","cmp.ge"] ->
        let (x,y) = if o `elem` ["cmp.gt","cmp.le"] then (b,a) else (a,b)
         in ["slt " ++ r d ++ ", " ++ r x ++ ", " ++ r y] ++ ["xori " ++ r d ++ ", " ++ r d ++ ", 1" | o `elem` ["cmp.le","cmp.ge"]]
      (o,[d],[base,n]) | o `elem` ["ld","lw","lbu"] -> memory o (r d) (r base) (num n)
      (o,[],[base,v,n]) | o `elem` ["sd","sw"] -> memory o (r v) (r base) (num n)
      ("bnez",[],[v,OL l']) -> ["bnez " ++ r v ++ ", " ++ local fn l']
      (o,[],[OL l']) | o `elem` ["j","jump.loop"] -> ["j " ++ local fn l']
      ("call",_,OS sym:_) -> ["call " ++ sym]
      ("tailjump",[],OS sym:_) -> epilogue ++ ["tail " ++ sym]
      ("ret",[],[_]) -> epilogue ++ ["ret"]
      ("push",[],[v]) -> ["addi sp, sp, -16", stWord ++ " " ++ r v ++ ", 0(sp)"]
      ("applyn",[_],[n]) -> ["mv a2, sp", "li a1, " ++ show (num n)] ++ memory ld "a0" "sp" (16*num n) ++ ["call fpr_applyN"] ++ adjust "sp" "sp" (16*(num n+1))
      ("panic",[],[OS sym]) -> ["la a0, " ++ sym, "call fpr_panic"]
      ("entry.check.tick",[],[]) -> hart ++ stack ++ tick
      ("entry.check",[],[]) -> hart ++ stack
      ("entry.tick",[],[]) -> hart ++ tick
      ("tick.n",[],[OI n]) -> hart ++ tickN n
      ("rvv.vlmax",[d],[]) -> ["vsetvli " ++ r d ++ ", x0, e" ++ ew ++ ", m1, ta, ma"]
      ("rvv.lanes",[d],[a,n,OI bound]) ->
        ["vsetvli t4, " ++ r n ++ ", e" ++ ew ++ ", m1, ta, ma", "vle" ++ ew ++ ".v v8, (" ++ r a ++ ")",
         "vredmax.vs v9, v8, v8", "vredmin.vs v10, v8, v8",
         "vmv.x.s t5, v9", "li t6, " ++ show bound, "slt " ++ r d ++ ", t5, t6",
         "vmv.x.s t5, v10", "li t6, " ++ show (negate bound), "slt t5, t6, t5",
         "and " ++ r d ++ ", " ++ r d ++ ", t5"]
      ("rvv.sum",[d],[acc]) -> ["vmv.s.x v9, x0", "vredsum.vs v9, v8, v9", "vmv.x.s t5, v9", "add " ++ r d ++ ", " ++ r acc ++ ", t5"]
      -- F64 on the bits through ft0/ft1, as the legacy inline table does
      -- F32: the legacy genU forms (fmv.x.w sign-extends; the runtime reads the low 32 bits)
      -- a float tree, one step an instruction: scratch ft0..ft7
      (o, [d], []) | Just c <- stripPrefix "ftree.cmp." o -> case c of
        "lt" -> ["flt.d " ++ r d ++ ", ft0, ft1"]; "gt" -> ["flt.d " ++ r d ++ ", ft1, ft0"]
        "le" -> ["fle.d " ++ r d ++ ", ft0, ft1"]; "ge" -> ["fle.d " ++ r d ++ ", ft1, ft0"]
        "eq" -> ["feq.d " ++ r d ++ ", ft0, ft1"]; _ -> ["feq.d " ++ r d ++ ", ft0, ft1", "xori " ++ r d ++ ", " ++ r d ++ ", 1"]
      (o, [d], []) | Just c <- stripPrefix "ftree32.cmp." o -> case c of
        "lt" -> ["flt.s " ++ r d ++ ", ft0, ft1"]; "gt" -> ["flt.s " ++ r d ++ ", ft1, ft0"]
        "le" -> ["fle.s " ++ r d ++ ", ft0, ft1"]; "ge" -> ["fle.s " ++ r d ++ ", ft1, ft0"]
        "eq" -> ["feq.s " ++ r d ++ ", ft0, ft1"]; _ -> ["feq.s " ++ r d ++ ", ft0, ft1", "xori " ++ r d ++ ", " ++ r d ++ ", 1"]
      ("ftree.leaf",[],[x,OI n]) -> ["fmv.d.x ft" ++ show n ++ ", " ++ r x]
      ("ftree.out",[d],[OI n]) -> ["fmv.x.d " ++ r d ++ ", ft" ++ show n]
      (o,[],[OI n]) | Just inst <- stripPrefix "ftree." o -> ["f" ++ inst ++ ".d ft" ++ show n ++ ", ft" ++ show n ++ ", ft" ++ show (n + 1)]
      ("ftree32.leaf",[],[x,OI n]) -> ["fmv.w.x ft" ++ show n ++ ", " ++ r x]
      ("ftree32.out",[d],[OI n]) -> ["fmv.x.w " ++ r d ++ ", ft" ++ show n]
      (o,[],[OI n]) | Just inst <- stripPrefix "ftree32." o -> ["f" ++ inst ++ ".s ft" ++ show n ++ ", ft" ++ show n ++ ", ft" ++ show (n + 1)]
      (o,[d],[a,b]) | Just f <- stripPrefix "fbin32." o ->
        ["fmv.w.x ft0, " ++ r a, "fmv.w.x ft1, " ++ r b, "f" ++ f ++ ".s ft0, ft0, ft1", "fmv.x.w " ++ r d ++ ", ft0"]
      (o,[d],[a,b]) | Just c <- stripPrefix "fcmp32." o ->
        ["fmv.w.x ft0, " ++ r a, "fmv.w.x ft1, " ++ r b] ++ case c of
          "lt" -> ["flt.s " ++ r d ++ ", ft0, ft1"]; "gt" -> ["flt.s " ++ r d ++ ", ft1, ft0"]
          "le" -> ["fle.s " ++ r d ++ ", ft0, ft1"]; "ge" -> ["fle.s " ++ r d ++ ", ft1, ft0"]
          "eq" -> ["feq.s " ++ r d ++ ", ft0, ft1"]; _ -> ["feq.s " ++ r d ++ ", ft0, ft1", "xori " ++ r d ++ ", " ++ r d ++ ", 1"]
      (o,[d],[a,b]) | Just f <- stripPrefix "fbin." o ->
        ["fmv.d.x ft0, " ++ r a, "fmv.d.x ft1, " ++ r b, "f" ++ f ++ ".d ft0, ft0, ft1", "fmv.x.d " ++ r d ++ ", ft0"]
      (o,[d],[a,b]) | Just c <- stripPrefix "fcmp." o ->
        ["fmv.d.x ft0, " ++ r a, "fmv.d.x ft1, " ++ r b] ++ case c of
          "lt" -> ["flt.d " ++ r d ++ ", ft0, ft1"]; "gt" -> ["flt.d " ++ r d ++ ", ft1, ft0"]
          "le" -> ["fle.d " ++ r d ++ ", ft0, ft1"]; "ge" -> ["fle.d " ++ r d ++ ", ft1, ft0"]
          "eq" -> ["feq.d " ++ r d ++ ", ft0, ft1"]; _ -> ["feq.d " ++ r d ++ ", ft0, ft1", "xori " ++ r d ++ ", " ++ r d ++ ", 1"]
      _ -> error ("RV64 no render form " ++ show (op,ds,us))
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
