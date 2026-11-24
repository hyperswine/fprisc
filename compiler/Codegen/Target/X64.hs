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
  ( X64Config (..), X64Hart (..), x64InterfaceRev, x64SelectionRev, emitFnX64, emitFnX64WithSymbols, x64RegisterFile, allocConfig, fuelSaveWrapper, allocSaveWrapper, stackGrowWrapper, renderItem ) where

import Compiler.DataLayout (storedListTid)
import qualified Codegen.Calling as Calling
import Codegen.Calling (CallConvention(FprCall), FuelEntry(..), TransferResult(..))
import qualified Codegen.Call as Call
import qualified Codegen.Protocol as Protocol
import Codegen.Allocate
import Codegen.Bounds (Flow (..), Tok (..), analyse, reportLine)
import Codegen.Frame
import qualified Codegen.Stack as Stack
import Codegen.IR
import Codegen.Policy
import Codegen.Selected hiding (plain)
import Codegen.Annotation (EntryPoint(..),entryLabel)
import qualified Codegen.Opcode as O
import Codegen.Target.X64.Forms (checkForms)
import Codegen.Target.Common
import Control.Monad (forM_, unless, when)
import Control.Monad.State.Strict hiding (fix)
import Data.List (intercalate, isPrefixOf)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust)
import qualified Data.Set as S

x64SelectionRev :: Int
x64SelectionRev = 41 -- G8: fuse OArithFits/OIsInt/ONot/ORegionRoom/OI64Cmp/known-small OEqVal/OCmpVal branches + bare OArithU Mul (40: OVariantOf)

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
-- The tick's slow path: a unit-local wrapper saves the caller-saved
-- registers (rax, rcx, rdx, rsi, rdi, r8..r11) on the actor's stack around
-- fpr_fuel_exhausted. Entered with rsp 8 mod 16 (the tick keeps the C call
-- alignment), nine pushes realign it for the call.
fuelSaveWrapper :: X64Hart -> [String]
fuelSaveWrapper hart =
  ["    .text", "    .balign 16", Call.runtimeName Call.FuelSaveEntry ++ ":"]
  ++ ["    pushq %" ++ r | r <- saved] ++ saveFloats
  ++ ["    call " ++ gsym hart (Call.runtimeName Call.FuelEntry)]
  ++ restoreFloats ++ ["    popq %" ++ r | r <- reverse saved]
  ++ ["    ret", ""]
  where saved = ["rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11"]

-- The inline bump's refill: a unit-local wrapper saving every allocatable
-- register around fpr_alloc. Entered with rsp 8 mod 16, as the tick's
-- wrapper is; eight pushes and one alignment word realign it for the call.
-- The raw size arrives in r11 and the cell returns in r11.
allocSaveWrapper :: X64Hart -> [String]
allocSaveWrapper hart =
  ["    .text", "    .balign 16", Call.runtimeName Call.AllocSaveEntry ++ ":"]
  ++ ["    pushq %" ++ r | r <- saved] ++ saveFloats
  ++ ["    subq $8, %rsp", "    movq %r11, %rdi", "    call " ++ gsym hart (Call.runtimeName Call.AllocEntry),
      "    movq %rax, %r11", "    addq $8, %rsp"]
  ++ restoreFloats ++ ["    popq %" ++ r | r <- reverse saved]
  ++ ["    ret", ""]
  where saved = ["rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10"]

-- C9 stage 1: fpr_stack_grow behind a unit-local wrapper that keeps every
-- allocatable caller-saved register but rax (the entry declares rax, r10
-- and r11 written), the xmm pool included, so values stay where the
-- allocator put them through the entry check (Protocol.keepingEntry).
-- Entered with rsp 8 mod 16, as the tick's wrapper is; six pushes, the 96
-- bytes of float saves and one alignment word realign it. The new segment
-- (or 0) returns in rax; the caller adopts it.
stackGrowWrapper :: X64Hart -> [String]
stackGrowWrapper hart =
  ["    .text", "    .balign 16", gsym hart (Call.runtimeName Call.GrowStackSaveEntry) ++ ":"]
  ++ ["    pushq %" ++ g | g <- saved] ++ saveFloats
  ++ ["    subq $8, %rsp", "    call " ++ gsym hart (Call.runtimeName Call.GrowStackEntry), "    addq $8, %rsp"]
  ++ restoreFloats ++ ["    popq %" ++ g | g <- reverse saved]
  ++ ["    ret", ""]
  where saved = ["rcx", "rdx", "rsi", "rdi", "r8", "r9"]

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
    cfgHart :: X64Hart,
    -- C9 stage 1 (docs/perf/2026-11-17-REGALLOC-DESIGN.md): shrink-wrapped
    -- saves, the short epilogue and live-set saves around the deep
    -- equality's slow path. Hosted x86-64 only; FPR_NO_X64_RA=1 is off.
    cfgFrames :: Bool
  }

r :: String -> Phys
r = Phys

x64RegisterFile :: RegisterFile
x64RegisterFile = RegisterFile classOf (map r ["rsp", "rbp", "r11"])
  where
    -- built once: the allocator asks for every operand
    classOf (Phys p) = M.lookup p x64RegisterClasses

x64RegisterClasses :: M.Map String RegClass
x64RegisterClasses = M.fromList $
  [(p, GPR) | p <- ["rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rsp", "rbp"] ++ ["r" ++ show n | n <- [8 :: Int .. 15]]]
  ++ [("xmm" ++ show n, FPR) | n <- [0 :: Int .. 15]]

callerSaved, argRegs, calleeBudget, callerPool, allocScratch :: [Phys]
callerSaved = Calling.callerClobbers Calling.X86_64
argRegs = Calling.argumentRegisters Calling.X86_64
-- M3: the budget (docs/2026-10-19-REGISTER-ALLOCATION.md 3.3: s1..s5, what
-- ctx_x64.S saves), the caller-saved pool, and the never-allocated scratch
-- (r10 and r11 are the expansions' own scratch inside the entry sequence
-- and the epilogue; between instructions they are free). r10 may be fixed
-- for the eighth product result, but never belongs to the allocation pool.
calleeBudget = map r ["rbx", "r12", "r13", "r14", "r15"]
callerPool = map r ["rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9"]
allocScratch = map r ["r10", "r11"]

-- The float class (C1): xmm0..xmm5 and xmm8..xmm13 for pooled F64
-- values, xmm6/xmm7 the allocator's float reload scratch. SysV preserves
-- no xmm register, so a float live across a call is spilled; the unit's
-- fuel and refill wrappers save the twelve. The tree and SSE2 pair
-- expansions write xmm8 and up as their own scratch, so those instructions
-- name what they write as clobbers (floatClobbers); xmm14/xmm15 stay the
-- word bank's operands and are never allocated.
floatPoolNumbers :: [Int]
floatPoolNumbers = [0 .. 5] ++ [8 .. 13]
floatPoolRegs, floatScratch :: [Phys]
floatPoolRegs = [r ("xmm" ++ show n) | n <- floatPoolNumbers]
floatScratch = map r ["xmm6", "xmm7"]

-- the wrappers' float saves: twelve 8-byte slots below the pushes (96
-- bytes, so the call alignment is unchanged)
saveFloats, restoreFloats :: [String]
saveFloats = "    subq $96, %rsp" : ["    movq %xmm" ++ show n ++ ", " ++ show (8 * k) ++ "(%rsp)" | (k, n) <- zip [0 :: Int ..] floatPoolNumbers]
restoreFloats = ["    movq " ++ show (8 * k) ++ "(%rsp), %xmm" ++ show n | (k, n) <- zip [0 :: Int ..] floatPoolNumbers] ++ ["    addq $96, %rsp"]

-- what a tree or SSE2 pair step writes beyond its operands: its slot
-- (xmm8 + n for a tree, the lane register for a pair). A pooled value
-- live across the step is kept out of it.
floatClobbers :: SInstr -> SInstr
floatClobbers i = case (siOpcode i, siUses i) of
  (O.X64 (O.TreeLeaf _ _), [_, OI n]) -> slot (8 + n)
  (O.X64 (O.TreeNode _ _), [OI n]) -> slot (8 + n)
  (O.X64 (O.TreeCompare _ _), []) -> i {siClobbers = siClobbers i ++ [xmm 8, xmm 9]}
  (O.X64 O.PairLoad, [_, OI n]) -> slot n
  (O.X64 O.PairDuplicate, [_, OI n]) -> slot n
  (O.X64 (O.PairBinary _), [OI d, _, _]) -> slot d
  _ -> i
  where
    xmm n = r ("xmm" ++ show n)
    slot n = i {siClobbers = siClobbers i ++ [xmm n]}

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
la :: VReg -> AddressSymbol -> SInstr
la d s = plain (O.X64 O.Address) [any' d] [OAddr s]

-- A two-address result occupies the first source's register, after loading
-- that source from its home. Its home is unchanged (no destructive IR use).
rrr :: O.X64Op -> VReg -> VReg -> VReg -> SInstr
rrr op d a b = (plain (O.X64 op) [OV d (Tied 0)] [any' a, any' b]) {siFlags = FlagsDef}
rri :: O.X64Op -> VReg -> VReg -> Integer -> SInstr
rri op d s n = (plain (O.X64 op) [OV d (Tied 0)] [any' s, OI n]) {siFlags = FlagsDef}
-- rd <- rs + n and rd <- 2 * rs + 1 (the tagged Int): one lea each
addi :: VReg -> VReg -> Integer -> SInstr
addi d s n = plain (O.X64 O.AddImmediate) [any' d] [any' s, OI n]
tagw :: VReg -> VReg -> SInstr
tagw d s = plain (O.X64 O.TagWord) [any' d] [any' s]
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
-- testq $n, a: the flags of a AND n, nothing written (a tag-bit test)
testi :: VReg -> Integer -> SInstr
testi a n = (plain (O.X64 O.TestImmediate) [] [any' a, OI n]) {siFlags = FlagsDef}
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

emitCall :: CodeSymbol -> CallConvention -> [VReg] -> Maybe VReg -> Se ()
emitCall sym convention args res = do
  stageArgs convention args
  selected <- either refuse pure (Calling.selectTransfer Calling.X86_64 convention
    (maybe DiscardResult (const WordResult) res) sym args res
    ((plain (O.X64 O.Call) [] []) {siImplicitDefs=[r "rsp"],siFlags=FlagsDef}))
  emitI selected

-- A vector element read or store that the flat view did not serve calls
-- its C entry (vec.c) through a function-local wrapper that saves every
-- caller-saved word register but the result and the xmm pool
-- (keepingWrapper): the call is a PreservingRuntime event that clobbers
-- nothing, so the values live across a cold slow path, F64 values
-- included, keep their registers instead of being kept in callee-saved
-- registers or spilled on the hot path (C6 stage 1).
emitKeepingCall :: CodeSymbol -> [VReg] -> VReg -> Se ()
emitKeepingCall sym args res = do
  stageArgs Calling.RuntimeCall args
  selected <- either refuse pure (Calling.selectTransfer Calling.X86_64 Calling.RuntimeCall WordResult sym args (Just res)
    ((plain (O.X64 O.Call) [] []) {siImplicitDefs=[r "rsp"],siFlags=FlagsDef}))
  emitI selected {siClobbers = [], siCalls = [Call sym PreservingRuntime]}

-- the cold slow paths of inline vector accesses (Lower.vectorAccess) and
-- of checked Int arithmetic (retagged), only where floats have registers:
-- a QOS app keeps the plain call
keepsRegisters :: X64Config -> Callee -> Bool
keepsRegisters cfg c = case calleeKind c of
  Foreign _ -> keepingEnabled cfg && length (calleeParams c) <= 3
    && any (`isPrefixOf` calleeName c) ["$vec.get", "$vec.at", "$vec.set", "$vec.put", "Vec.set", "Vec.put"]
  _ -> False

keepingEnabled :: X64Config -> Bool
keepingEnabled cfg = polProfile (cfgPolicy cfg) /= QosApp && tuneFpPool (cfgTune cfg)

keepingCall :: SInstr -> Bool
keepingCall i = siOpcode i == O.X64 O.Call && case siCalls i of
  [c] -> callEffect c == PreservingRuntime
  _ -> False

-- C9 stage 1: annotate each preserving runtime call of an allocated body
-- with the caller-saved registers live across it (Allocate.liveAcross)
keepLive :: [Item] -> [Item]
keepLive items
  | not (or [keepingCall i | I i <- items]) = items -- no physical liveness pass for the rest
  | otherwise = go items (liveAcross items)
  where
    go (I i : rest) ((_, live) : ls)
      | keepingCall i = I i {siAnnotation = KeepsLive [p | p <- live, saves p]} : go rest ls
      | otherwise = I i : go rest ls
    go (it : rest) ls = it : go rest ls
    go [] _ = []
    saves p@(Phys n) = p `elem` callerSaved || M.lookup n x64RegisterClasses == Just FPR

keepsLive :: SInstr -> Bool
keepsLive i = case siAnnotation i of
  KeepsLive _ -> True
  _ -> False

keepingLabel :: String -> Label
keepingLabel sym = Label ("keep_" ++ sym)

-- one wrapper per C entry a function calls this way, after its code.
-- Entered with rsp 8 mod 16 (the call site keeps the C alignment): eight
-- pushes, the 96 bytes of float saves and one alignment word realign it.
keepingWrappers :: X64Hart -> String -> [Item] -> [String]
keepingWrappers hart name body = concat
  [ [local hart name (keepingLabel sym) ++ ":"]
    ++ ["    pushq %" ++ g | g <- saved] ++ saveFloats
    ++ ["    subq $8, %rsp", "    call " ++ gsym hart sym, "    addq $8, %rsp"]
    ++ restoreFloats ++ ["    popq %" ++ g | g <- reverse saved] ++ ["    ret"]
  | sym <- S.toList (S.fromList [codeName s | I i <- body, keepingCall i, not (keepsLive i), OCode s : _ <- [siUses i]]) ]
  where saved = ["rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11"]

-- A private multi-word result, with the complete bank checked by Calling.
emitCallProduct :: CodeSymbol -> CallConvention -> [VReg] -> [VReg] -> Se ()
emitCallProduct sym convention args results = do
  stageArgs convention args
  selected <- either refuse pure (Calling.selectProductTransfer Calling.X86_64 convention sym args results
    ((plain (O.X64 O.Call) [] []) {siImplicitDefs=[r "rsp"],siFlags=FlagsDef}))
  emitI selected

-- a call into a noreturn runtime trap: it ends the path (Calling.NeverReturns)
trapCall :: String -> Se ()
trapCall s = do
  selected <- either refuse pure (Calling.selectTransfer Calling.X86_64 Calling.RuntimeCall NeverReturns (CodeSymbol s) [] Nothing
    ((plain (O.X64 O.Call) [] []) {siImplicitDefs=[r "rsp"],siFlags=FlagsDef}))
  emitI selected

retProduct :: [VReg] -> Se ()
retProduct values = do
  places <- either refuse pure (Calling.resultPlaces Calling.X86_64 (FprCall NoFuel) (ProductResult (length values)))
  emitI ((plain (O.X64 O.Ret) [] (zipWith fix values places))
    {siImplicitDefs = map r ["r11", "rbp", "rsp"], siControl = Return})

ret :: VReg -> SInstr
ret v = (plain (O.X64 O.Ret) [] [fix v (r "rax")])
  {siImplicitDefs = map r ["r11", "rbp", "rsp"], siControl = Return}
emitTail :: CodeSymbol -> CallConvention -> [VReg] -> Se ()
emitTail sym convention args = do
  stageArgs convention args
  selected <- either refuse pure (Calling.selectTransfer Calling.X86_64 convention TailTransfer sym args Nothing
    ((plain (O.Common O.TailJump) [] []) {siImplicitDefs=map r ["r11","rbp","rsp"]}))
  emitI selected

entrySeq :: Protocol.EntryChecks -> Label -> SInstr
entrySeq checks base=Protocol.selectProtocol Calling.X86_64
  ((plain (O.Common (Protocol.entryOpcode checks)) [] []) {siAnnotation=EntryLabels base})

-- ---- selection ---------------------------------------------------------

primSymbol :: ArithOp -> String
primSymbol o = "fpr_prim_fn_" ++ mangleName (arithSymbol o)

calleeSymbol :: Callee -> CodeSymbol
calleeSymbol = calleeCodeSymbol

nullarySymbol :: Int -> Int -> Se AddressSymbol
nullarySymbol t v = case (t, v) of
  (0, 0) -> pure (StaticObject "fpr_unit")
  (1, 0) -> pure (StaticObject "fpr_false")
  (1, 1) -> pure (StaticObject "fpr_true")
  _ -> do
    modify (\s -> s {selNullaries = S.insert (t, v) (selNullaries s)})
    pure (StaticObject (".Lnul_" ++ show t ++ "_" ++ show v))

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
      facts = fnFacts fn
      following = zip (fnBlocks fn) (map (Just . bId) (drop 1 (fnBlocks fn)) ++ [Nothing])
  when (length params > arityCeiling) (Left ("arity above " ++ show arityCeiling))
  (_, st) <- runStateT (mapM_ (\(b, next) -> selectBlock cfg fn facts next b) following) st0
  pure (SFn (fnName fn) params (reverse (selItems st)), selManaged st, selNullaries st, selStrings st)

entryBlock :: Fn -> Block
entryBlock fn = case [b | b <- fnBlocks fn, bId b == fnEntry fn] of
  (b : _) -> b
  [] -> error ("x64: missing entry block " ++ show (fnEntry fn))

-- What selection reads of the whole function, made once: the constants an
-- instruction can take as an immediate operand (a signed 32-bit field, its
-- negation too: a subtraction is the addition of the negative), those no
-- instruction needs in a register (never made), how often each value is
-- read, and every block's parameters.
data Facts = Facts
  { fImmediates :: M.Map VId Integer,
    fImmediateOnly :: S.Set VId,
    fUses :: M.Map VId Int,
    fParams :: M.Map BId [VReg],
    fConsts :: M.Map VId Integer,
    fTagSrc :: M.Map VId VId,
    fTagOnlyConsts :: S.Set VId,
    fLazyTags :: S.Set VId }

fnFacts :: Fn -> Facts
fnFacts fn = Facts immediates only uses params consts tagSrc tagOnlyConsts lazyTags
  where
    ops = [o | blk <- fnBlocks fn, Instr _ o <- bInstrs blk]
    terms = concat [termUses (bTerm blk) | blk <- fnBlocks fn]
    termSet = S.fromList terms
    immediates = M.fromList [(v, n) | blk <- fnBlocks fn, Instr (Just (v, _)) (OConstInt n) <- bInstrs blk, abs n < 2 ^ (31 :: Int)]
    -- a read that is not an immediate operand keeps the constant's register
    held = S.fromList (terms ++ [u | o <- ops, u <- opUses o, M.member u immediates, fmap (\(_, iv, _) -> iv) (immediateForm immediates o) /= Just u])
    only = M.keysSet immediates `S.difference` held
    uses = M.fromListWith (+) [(u, 1) | u <- terms ++ concatMap opUses ops]
    params = M.fromList [(bId blk, [vreg v | (v, _) <- bParams blk]) | blk <- fnBlocks fn]
    -- exact Int operations know a TVal is small when it is `OTag` of a raw
    -- Int (a TInt always fits); such a tag is made only where a slow path
    -- needs the word, when every use of it is one of those operations
    consts = M.fromList [(v, n) | blk <- fnBlocks fn, Instr (Just (v, _)) (OConstInt n) <- bInstrs blk]
    tagSrc = M.fromList [(v, u) | blk <- fnBlocks fn, Instr (Just (v, TVal)) (OTag u) <- bInstrs blk]
    smallAware o = case o of OArithVal {} -> True; OCmpVal {} -> True; OEqVal {} -> True; _ -> False
    tagOnlyConsts = S.fromList
      [ v | v <- M.keys consts, S.notMember v termSet,
            let users = [o | o <- ops, v `elem` opUses o],
            not (null users), all (\o -> case o of OTag _ -> True; _ -> False) users ]
    lazyTags = S.fromList
      [ v | v <- M.keys tagSrc, S.notMember v termSet,
            let users = [o | o <- ops, v `elem` opUses o],
            not (null users), all smallAware users ]

-- The instructions with an immediate form, and which operand is which:
-- (the register operand, the constant's value id, the constant).  The one
-- rule both the selection of the instruction and the decision to never make
-- the constant read, so they cannot disagree.
immediateForm :: M.Map VId Integer -> Op -> Maybe (VId, VId, Integer)
immediateForm immediates = \case
  OCmp _ a b -> right a b
  OArith o a b | o `elem` [Add, Sub] -> case right a b of
    Nothing | o == Add -> right b a
    form -> form
  OArithU o a b | o `elem` [Add, Sub] -> case right a b of
    Nothing | o == Add -> right b a
    form -> form
  _ -> Nothing
  where
    right a b | a /= b, Just n <- M.lookup b immediates = Just (a, b, n)
              | otherwise = Nothing

selectBlock :: X64Config -> Fn -> Facts -> Maybe BId -> Block -> Se ()
selectBlock cfg fn facts next b = do
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
      forM_ (Protocol.entryChecks stack fuel) $ \checks -> freshL "entry" >>= emitI . entrySeq checks
    else do
      when stack (refuse "a stack check outside the entry block")
      -- an inlined callee's tick ($fuel) at the start of a non-entry block
      forM_ entryOps $ \_ -> freshL "tick" >>= emitI . entrySeq Protocol.FuelOnly
  let run (Instr d (OCallProduct c as) : following) = do
        (results, more) <- either (refuse) pure (productCallResults c d following)
        emitCallProduct (calleeSymbol c) (Calling.calleeCall (cfgPolicy cfg) c) (map vreg as) (map vreg results)
        run more
      run (Instr (Just (v, _)) (OConstInt _) : more) | S.member v (fImmediateOnly facts) || S.member v (fTagOnlyConsts facts) = run more
      run (Instr (Just (v, _)) (OTag _) : more) | S.member v (fLazyTags facts) = run more
      -- a byte address made for one load: the load takes base and index
      run (Instr (Just (p, _)) (OIndexByte a i) : Instr (Just (v, _)) (OLoadByte p' n) : more)
        | p == p', M.lookup p (fUses facts) == Just 1 = do
            emitI (plain (O.X64 O.LoadByteIndexed) [any' (vreg v)] [any' (vreg a), any' (vreg i), OI (fromIntegral n)])
            run more
      run (i : more) = selectInstr cfg facts i >> run more
      run [] = pure ()
      moves target args = filter (uncurry (/=)) (zip (M.findWithDefault [] target (fParams facts)) (map vreg args))
      -- a comparison whose only reader is this block's branch: compare and
      -- branch on the flags (no set, no zero-extension, no test).  The edge
      -- moves come after the branch and x86 moves leave the flags alone.
      rawOfF v = M.lookup v (fTagSrc facts)
      fused = case (reverse rest, bTerm b) of
        (Instr (Just (p, _)) op : _, TCondBr p' t as e bs)
          | p == p', M.lookup p (fUses facts) == Just 1 -> case op of
              OCmp {} -> Just op
              OI64Cmp {} -> Just op
              OIsInt {} -> Just op
              ONot {} -> Just op
              ORegionRoom {} -> Just op
              OArithFits {} -> Just op
              OCmpVal _ a b' | isJust (rawOfF a) && isJust (rawOfF b') -> Just op
              OEqVal _ a b' | isJust (rawOfF a) || isJust (rawOfF b') -> Just op
              OVariantTest {} -> Just op
              OTagTest {} -> Just op
              -- an ordered float comparison: ucomis and an unsigned branch,
              -- which is not taken on NaN (as the reference evaluator's
              -- ordered predicates are false); eq/ne need the parity flag
              -- too and keep the materialised answer
              OFloatCmp o _ _ | ordered o -> Just op
              OFloat32Cmp o _ _ | ordered o -> Just op
              OFloatCmpTree o _ _ | ordered o -> Just op
              OFloat32CmpTree o _ _ | ordered o -> Just op
              _ -> Nothing
        _ -> Nothing
  case (fused, bTerm b) of
    (Just op, TCondBr _ t as e bs) -> do
      run (init rest)
      let flags c = condBranch fn facts next (bcond c) (bcond (negateCond c)) t as e bs
          rawVF u = case M.lookup u (fConsts facts) of
            Just n -> do tmp <- freshV False; emitI (li tmp n); pure tmp
            Nothing -> pure (vreg u)
          taggedVF v = case rawOfF v of
            Just u | S.member v (fLazyTags facts) -> case M.lookup u (fConsts facts) of
              Just n -> do tmp <- freshV True; emitI (li tmp (2 * n + 1)); pure tmp
              Nothing -> do tmp <- freshV True; emitI (tagw tmp (vreg u)); pure tmp
            _ -> pure (vreg v)
          flipCmp = \case Lt -> Gt; Gt -> Lt; Le -> Ge; Ge -> Le; Eq -> Eq; Ne -> Ne
      case op of
        OCmp o x y -> do
          case immediateForm (fImmediates facts) op of
            Just (_, _, n) -> emitI (cmpi (vreg x) n)
            Nothing -> emitI (cmp (vreg x) (vreg y))
          flags (cmpCond o)
        OI64Cmp o x y -> do
          emitI (cmp (vreg x) (vreg y))
          flags (cmpCond o)
        OIsInt v -> do
          emitI (testi (vreg v) 1)
          flags O.NotEqual
        ONot p' -> condBranch fn facts next (cbz (vreg p')) (cbnz (vreg p')) t as e bs
        ORegionRoom mark -> do
          clock <- freshV False
          used <- freshV False
          scaled <- freshV False
          untagged <- freshV False
          emitI (plain (O.Common O.LoadSpill) [any' clock] [OI 58])
          emitI (rri O.ShiftRightArithmeticImmediate untagged (vreg mark) 1)
          emitI (rrr O.Subtract used clock untagged)
          emitI (rri O.ShiftLeftImmediate scaled used 3)
          emitI (cmpi scaled (65536 * 8))
          flags O.UnsignedBelow
        OArithFits o a b' -> testBranchWith O.NoOverflow $ \miss -> do
          tmp <- freshV False
          case o of
            Add -> emitI (rrr O.Add tmp (vreg a) (vreg b'))
            Sub -> emitI (rrr O.Subtract tmp (vreg a) (vreg b'))
            Mul -> emitI (rrr O.Multiply tmp (vreg a) (vreg b')) >> emitI (bcond O.Overflow miss)
            Div -> emitI (cbz (vreg b') miss) >> emitI (divide tmp (vreg a) (vreg b'))
          n <- freshV False
          emitI (rri O.ShiftLeftImmediate n tmp 1)
        OCmpVal o a b' | Just ua <- rawOfF a, Just ub <- rawOfF b' -> do
          case (M.lookup ua (fConsts facts), M.lookup ub (fConsts facts)) of
            (Nothing, Just n) -> cmpConst (vreg ua) n >> flags (cmpCond o)
            (Just n, Nothing) -> cmpConst (vreg ub) n >> flags (cmpCond (flipCmp o))
            _ -> do
              xa <- rawVF ua
              xb <- rawVF ub
              emitI (cmp xa xb)
              flags (cmpCond o)
        OEqVal eq a b' | Just ua <- rawOfF a, Just ub <- rawOfF b' -> do
          case (M.lookup ua (fConsts facts), M.lookup ub (fConsts facts)) of
            (Nothing, Just n) -> cmpConst (vreg ua) n
            (Just n, Nothing) -> cmpConst (vreg ub) n
            _ -> do
              xa <- rawVF ua
              xb <- rawVF ub
              emitI (cmp xa xb)
          flags (if eq then O.Equal else O.NotEqual)
        OEqVal eq a b' -> do
          case (rawOfF a >>= \u -> M.lookup u (fConsts facts), rawOfF b' >>= \u -> M.lookup u (fConsts facts)) of
            (Nothing, Just n) -> cmpConst (vreg a) (2 * n + 1)
            (Just n, Nothing) -> cmpConst (vreg b') (2 * n + 1)
            _ -> do
              ta <- taggedVF a
              tb <- taggedVF b'
              emitI (cmp ta tb)
          flags (if eq then O.Equal else O.NotEqual)
        OVariantTest tg c v | Just imm <- immediateNullary tg c -> do
          emitI (cmpi (vreg v) imm)
          flags O.Equal
        -- a tagged Int or 010 immediate is no match; else the header word against the pair
        OVariantTest tg c v -> testBranch $ \miss -> do
          emitI (testi (vreg v) 7)
          emitI (bcond O.NotEqual miss)
          hdr <- freshV False
          emitI (plain (O.X64 O.LoadField) [any' hdr] [any' (vreg v), OI 0])
          cmpConst hdr (headerWord tg c)
        OTagTest tg c v | Just imm <- immediateNullary tg c -> do
          emitI (cmpi (vreg v) imm)
          flags O.Equal
        -- a tagged Int or 010 immediate is no match; then the typeid word and the variant
        -- word.  Both are 32-bit fields of one little-endian header word, so
        -- when the pair is in [0, 2^31) (every tid the compiler assigns) the
        -- two sign-extending loads and compares are exactly one 64-bit
        -- compare against the header word, as OVariantTest does.
        OTagTest tg c v
          | inHalf tg && inHalf c -> testBranch $ \miss -> do
              emitI (testi (vreg v) 7)
              emitI (bcond O.NotEqual miss)
              hdr <- freshV False
              emitI (plain (O.X64 O.LoadField) [any' hdr] [any' (vreg v), OI 0])
              cmpConst hdr (headerWord tg c)
          where inHalf n = n >= 0 && toInteger n < 2 ^ (31 :: Int)
        OTagTest tg c v -> testBranch $ \miss -> do
          emitI (testi (vreg v) 7)
          emitI (bcond O.NotEqual miss)
          tid <- freshV False
          emitI (ldrsw tid (vreg v) 0)
          cmpConst tid (fromIntegral tg)
          emitI (bcond O.NotEqual miss)
          var <- freshV False
          emitI (ldrsw var (vreg v) 4)
          cmpConst var (fromIntegral c)
        OFloatCmp o x y -> floatTest flags O.Float64 o x y
        OFloat32Cmp o x y -> floatTest flags O.Float32 o x y
        OFloatCmpTree o x y -> treeTest flags O.Float64 o x y
        OFloat32CmpTree o x y -> treeTest flags O.Float32 o x y
        _ -> refuse "internal: an unfusable branch condition"
      where
        -- FloatTest [l, r] renders `ucomis r, l`: above when l > r. An
        -- unordered pair sets CF and ZF, so `a`/`ae` are not taken on NaN
        -- and their negations are. gt/ge test the operands in order, lt/le
        -- swapped, so the branch is always above or above-or-equal.
        floatCond o = if o `elem` [Gt, Lt] then O.UnsignedAbove else O.UnsignedAboveEqual
        floatTest flags' w o x y = do
          let (l, r') = if o `elem` [Gt, Ge] then (x, y) else (y, x)
          emitI ((plain (O.X64 (O.FloatTest O.WordBits w)) [] [any' (vreg l), any' (vreg r')]) {siFlags = FlagsDef})
          flags' (floatCond o)
        -- the two trees in xmm8 (left) and xmm9 (right), as OFloatCmpTree
        -- lays them out; TreeTest orders the ucomis by the predicate the
        -- same way
        treeTest flags' w o x y = do
          forM_ (ftreeScheduleAt 0 x ++ ftreeScheduleAt 1 y) $ \case
            FSLeaf v n -> emitI (plain (O.X64 (O.TreeLeaf O.WordBits w)) [] [any' (vreg v), OI (fromIntegral n)])
            FSNode f n -> emitI (plain (O.X64 (O.TreeNode w f)) [] [OI (fromIntegral n)])
          emitI ((plain (O.X64 (O.TreeTest w o)) [] []) {siFlags = FlagsDef})
          flags' (floatCond o)
        -- A layout test leaves early to the no-match side and ends in the
        -- flags of a compare that holds on a match (`hitCond`).  Without
        -- block-parameter moves on the no-match edge, every early exit is a
        -- direct branch to that block and the final compare takes condBranch's
        -- layout.  With them, the early exits and the final miss share one
        -- edge that performs the moves; the match side is branched to (or
        -- through its own edge when it has moves too).
        testBranch = testBranchWith O.Equal
        testBranchWith hitCond body
          | null movesE = body (blockLabel e) >> condBranch fn facts next (bcond hitCond) (bcond (negateCond hitCond)) t as e bs
          | otherwise = do
              miss <- freshL "miss"
              body miss
              let missEdge = parallelMoves movesE >> emitI (jump (blockLabel e))
                  hitEdge = parallelMoves movesT >> unless (Just t == next) (emitI (jump (blockLabel t)))
              if null movesT
                then do
                  emitI (bcond hitCond (blockLabel t))
                  emitL miss
                  parallelMoves movesE
                  unless (Just e == next) (emitI (jump (blockLabel e)))
                else if Just e == next
                  then do
                    emitI (bcond (negateCond hitCond) miss)
                    parallelMoves movesT
                    emitI (jump (blockLabel t))
                    emitL miss
                    parallelMoves movesE
                  else do
                    hit <- freshL "hit"
                    emitI (bcond hitCond hit)
                    emitL miss
                    missEdge
                    emitL hit
                    hitEdge
          where movesT = moves t as
                movesE = moves e bs
    _ -> do
      run rest
      selectTerm cfg fn facts next b

-- a compare against a constant: the immediate where it fits the field
cmpConst :: VReg -> Integer -> Se ()
cmpConst v n
  | abs n < 2 ^ (31 :: Int) = emitI (cmpi v n)
  | otherwise = do
      want <- freshV False
      emitI (li want n)
      emitI (cmp v want)

-- a function's F64 constants sit after its code, one 8-byte word each
floatLiteralLabel :: Integer -> Label
floatLiteralLabel n = Label ("f64_" ++ show (n `mod` (2 ^ (64 :: Int))))

floatLiterals :: X64Hart -> String -> [Item] -> [String]
floatLiterals hart name body = case S.toList (S.fromList [n | I i <- body, siOpcode i == O.X64 O.FloatLiteral, [OI n] <- [siUses i], n /= 0]) of
  [] -> []
  ns -> "    .p2align 3" : concat [[local hart name (floatLiteralLabel n) ++ ":", "    .quad " ++ show (n `mod` (2 ^ (64 :: Int)))] | n <- ns]

-- the comparisons that are false on NaN (eq/ne need the parity flag too)
ordered :: CmpOp -> Bool
ordered o = o `elem` [Lt, Gt, Le, Ge]

cmpCond :: CmpOp -> O.Condition
cmpCond = \case Lt -> O.Less; Gt -> O.Greater; Le -> O.LessEqual; Ge -> O.GreaterEqual; Eq -> O.Equal; Ne -> O.NotEqual

negateCond :: O.Condition -> O.Condition
negateCond = \case
  O.Less -> O.GreaterEqual; O.GreaterEqual -> O.Less; O.Greater -> O.LessEqual; O.LessEqual -> O.Greater
  O.Equal -> O.NotEqual; O.NotEqual -> O.Equal
  O.UnsignedBelow -> O.UnsignedAboveEqual; O.UnsignedAboveEqual -> O.UnsignedBelow
  O.Overflow -> O.NoOverflow; O.NoOverflow -> O.Overflow
  O.UnsignedAbove -> O.UnsignedBelowEqual; O.UnsignedBelowEqual -> O.UnsignedAbove

-- A two-way branch given the jump taken when the condition holds and the
-- jump taken when it does not.  Whichever target is laid out next is fallen
-- into; a side with no block-parameter moves is branched to directly, and
-- only an edge with moves on both sides gets a block of its own.
condBranch :: Fn -> Facts -> Maybe BId -> (Label -> SInstr) -> (Label -> SInstr) -> BId -> [VId] -> BId -> [VId] -> Se ()
condBranch _ facts next whenTrue whenFalse t as e bs = case (null movesT, null movesE) of
  (True, True)
    | Just e == next -> emitI (whenTrue (blockLabel t))
    | Just t == next -> emitI (whenFalse (blockLabel e))
    | otherwise -> emitI (whenTrue (blockLabel t)) >> emitI (jump (blockLabel e))
  (True, False) -> do
    emitI (whenTrue (blockLabel t))
    parallelMoves movesE
    jumpOn e
  (False, True) -> do
    emitI (whenFalse (blockLabel e))
    parallelMoves movesT
    jumpOn t
  (False, False) -> do
    edge <- freshL "edge"
    emitI (whenTrue edge)
    parallelMoves movesE
    emitI (jump (blockLabel e))
    emitL edge
    parallelMoves movesT
    jumpOn t
  where
    moves target args = filter (uncurry (/=)) (zip (M.findWithDefault [] target (fParams facts)) (map vreg args))
    movesT = moves t as
    movesE = moves e bs
    jumpOn target = unless (Just target == next) (emitI (jump (blockLabel target)))

selectInstr :: X64Config -> Facts -> Instr -> Se ()
selectInstr cfg facts (Instr d op) = case op of
  OStackCheck -> refuse "internal: a stack check reached selection"
  OSafepoint -> freshL "tick" >>= emitI . entrySeq Protocol.FuelOnly -- an inlined callee's tick mid-block
  OSafepointN n -> freshL "tick" >>= \l -> emitI ((entrySeq Protocol.FuelOnly l) {siOpcode = O.Common O.TickN, siUses = [OI (fromIntegral n)]})
  OSimdPair int e caps a -> do
    when (simdRegisters e > 7) (refuse "an SSE2 pair exceeds seven scratch temporaries")
    simdPair int e (map vreg caps) (vreg a)
  ORvvVlMax -> refuse "a RISC-V vector length on x86-64"
  ORvvLanes _ _ -> refuse "RISC-V vector lanes on x86-64"
  ORvvSumLoaded _ -> refuse "a RISC-V vector sum on x86-64"
  OAddress v -> def (\r -> emitI (mov r (vreg v)))
  OVectorView {} -> refuse "internal: a vector view reached selection unexpanded"
  OIndex a i -> def $ \r -> do
    offset <- freshV False
    emitI (rri O.ShiftLeftImmediate offset (vreg i) 3)
    emitI (rrr O.Add r (vreg a) offset)
  OIndexByte a i -> def (\r -> emitI (rrr O.Add r (vreg a) (vreg i)))
  OLoad _ a n -> def (\r -> emitI (plain (O.X64 O.LoadField) [any' r] [any' (vreg a), OI (fromIntegral n)]))
  OLoadByte a n -> def (\r -> emitI (plain (O.X64 O.LoadByte) [any' r] [any' (vreg a), OI (fromIntegral n)]))
  OStore _ a n v -> emitI (plain (O.X64 O.StoreField) [] [any' (vreg a), any' (vreg v), OI (fromIntegral n)])
  OSetField index obj val -> emitI (plain (O.X64 O.StoreField) [] [any' (vreg obj), any' (vreg val), OI (8 + 8 * fromIntegral index)])
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
  ONullary t v -> def $ \r -> case immediateNullary t v of
    Just imm -> emitI (li r imm)
    Nothing -> nullarySymbol t v >>= emitI . la r
  OString text -> def $ \rd -> do
    modify (\st -> st {selStrings = S.insert text (selStrings st)})
    emitI (la rd (StaticObject (stringLabel text)))
  OMake tid variant fields -> makeCell tid (Left variant) fields
  OMakeSpine ordinal fields
    | polProfile (cfgPolicy cfg)==HostedBase -> makeCell storedListTid (Right ordinal) fields
    | otherwise -> refuse "private stored lists require hosted Base"
  OReuse _ _ root fields -> def $ \rd -> do
    forM_ (zip [0..] fields) $ \(index, value) ->
      emitI (plain (O.X64 O.StoreField) [] [any' (vreg root), any' (vreg value), OI (8 + 8 * index)])
    emitI (mov rd (vreg root))
  OField index obj -> def $ \rd ->
    emitI (plain (O.X64 O.LoadField) [any' rd] [any' (vreg obj), OI (8 + 8 * fromIntegral index)])
  OStrLen str -> def $ \rd -> do
    tagged <- freshV True
    emitCall (CodeSymbol "fpr_g_strlen_call1") Calling.RuntimeCall [vreg str] (Just tagged)
    emitI (rri O.ShiftRightArithmeticImmediate rd tagged 1)
  OCharAt str index -> def $ \rd -> do
    shifted <- freshV False
    taggedIndex <- freshV True
    taggedResult <- freshV True
    emitI (rri O.ShiftLeftImmediate shifted (vreg index) 1)
    emitI (rri O.OrImmediate taggedIndex shifted 1)
    emitCall (CodeSymbol "fpr_g_charAt_call2") Calling.RuntimeCall [vreg str, taggedIndex] (Just taggedResult)
    emitI (rri O.ShiftRightArithmeticImmediate rd taggedResult 1)
  OSymbol sym -> def (\r -> emitI (la r (ExternalAddress sym))) -- an immutable symbol address
  OFunValue n -> def (\r -> emitI (la r (StaticObject ("fpr_obj_" ++ mangleName n))))
  -- the generic application: the head then every argument pushed 16 bytes
  -- apart (the last at the stack pointer), fpr_applyN(head, n, &args) with
  -- the call-alignment adjustment, the pushes popped; slots are %rbp-relative
  OApply f as -> def $ \rd -> do
    forM_ (f : as) $ \v -> emitI (Protocol.selectProtocol Calling.X86_64 (plain (O.X64 O.Push) [] [any' (vreg v)]))
    emitI (Protocol.selectProtocol Calling.X86_64 (plain (O.X64 O.ApplyN) [fix rd (r "rax")] [OI (fromIntegral (length as))]))
  OTag v | Just n <- M.lookup v (fConsts facts) -> def (\r -> emitI (li r (2 * n + 1)))
  OTag v -> def (\r -> emitI (tagw r (vreg v)))
  OUntag v -> def (\r -> emitI (rri O.ShiftRightArithmeticImmediate r (vreg v) 1))
  OBoolOf p -> def $ \r -> do
    sh <- freshV False
    emitI (rri O.ShiftLeftImmediate sh (vreg p) 8)
    emitI (addi r sh 10)
  OTruth v -> def (\r -> emitI (rri O.ShiftRightArithmeticImmediate r (vreg v) 8))
  ONot p -> def (\r -> emitI (rri O.XorImmediate r (vreg p) 1))
  OIsInt v -> def (\r -> emitI (rri O.AndImmediate r (vreg v) 1))
  OTagTest t c v | Just imm <- immediateNullary t c -> def $ \r -> do
    emitI (cmpi (vreg v) imm)
    emitI (cset O.Equal r)
  OTagTest t c v -> def $ \r -> do
    miss <- freshL "tagno"
    done <- freshL "tagdone"
    bit <- freshV False
    emitI (rri O.AndImmediate bit (vreg v) 7)
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
  OVariantTest t c v | Just imm <- immediateNullary t c -> def $ \r -> do
    emitI (cmpi (vreg v) imm)
    emitI (cset O.Equal r)
  -- OTagTest's answer with one header load: typeid (+0) and variant (+4)
  -- compared as one little-endian word, after the non-pointer check
  OVariantTest t c v -> def $ \r -> do
    miss <- freshL "varno"
    done <- freshL "vardone"
    bit <- freshV False
    emitI (rri O.AndImmediate bit (vreg v) 7)
    emitI (cbnz bit miss)
    hdr <- freshV False
    want <- freshV False
    emitI (plain (O.X64 O.LoadField) [any' hdr] [any' (vreg v), OI 0])
    emitI (li want (headerWord t c))
    emitI (cmp hdr want)
    emitI (cset O.Equal r)
    emitI (jump done)
    emitL miss
    emitI (li r 0)
    emitL done
  OVariantOf t v -> def $ \r -> do
    miss <- freshL "vofno"
    done <- freshL "vofdone"
    emitI (testi (vreg v) 7)
    emitI (bcond O.NotEqual miss)
    tid <- freshV False
    emitI (ldrsw tid (vreg v) 0)
    cmpConst tid (fromIntegral t)
    emitI (bcond O.NotEqual miss)
    emitI (ldrsw r (vreg v) 4)
    emitI (jump done)
    emitL miss
    emitI (li r (-1))
    emitL done
  OKernelArith o a b -> def (\r -> arith True o r (vreg a) (vreg b))
  -- a constant operand of + or -: the immediate instruction (the slow path
  -- makes the constant, for the C primitive)
  OArith o _ _ | Just (x, _, n) <- immediateForm (fImmediates facts) op -> def (\r -> arithImm o r (vreg x) n)
  OArith o a b -> def (\r -> arith False o r (vreg a) (vreg b))
  -- a raw-Int copy's fit test (Codegen.RawInts): 1 when the exact result
  -- of the two small Ints is a small Int (Div: the divisor is not 0); the
  -- truncated quotient leaves the range exactly when the floored one does
  OArithFits o a b -> def (\r -> do
    no <- freshL "nofit"
    done <- freshL "fitdone"
    t <- freshV False
    case o of
      Add -> emitI (rrr O.Add t (vreg a) (vreg b))
      Sub -> emitI (rrr O.Subtract t (vreg a) (vreg b))
      Mul -> emitI (rrr O.Multiply t (vreg a) (vreg b)) >> emitI (bcond O.Overflow no)
      Div -> emitI (cbz (vreg b) no) >> emitI (divide t (vreg a) (vreg b))
    n <- freshV False
    emitI (rri O.ShiftLeftImmediate n t 1)
    emitI (bcond O.Overflow no)
    emitI (li r 1)
    emitI (jump done)
    emitL no
    emitI (li r 0)
    emitL done)
  OArithVal o a b | Just ua <- rawOf a, Just ub <- rawOf b -> def (\r -> arithSmall o r (Just ua) (Just ub) a b)
  OArithVal Add a b | Just k <- constOf b -> def (\r -> addConst r (vreg a) (2 * k) a b Add)
  OArithVal Add a b | Just k <- constOf a -> def (\r -> addConst r (vreg b) (2 * k) a b Add)
  OArithVal Sub a b | Just k <- constOf b, k /= -(2 ^ (62 :: Int)) -> def (\r -> addConst r (vreg a) (negate (2 * k)) a b Sub)
  OArithVal o a b | Just ua <- rawOf a -> def (\r -> arithSmall o r (Just ua) Nothing a b)
  OArithVal o a b | Just ub <- rawOf b -> def (\r -> arithSmall o r Nothing (Just ub) a b)
  OArithVal o a b -> def (\r -> arithVal o r (vreg a) (vreg b))
  OArithU o _ _ | Just (x, _, n) <- immediateForm (fImmediates facts) op ->
    def (\r -> emitI (addi r (vreg x) (if o == Sub then negate n else n)))
  -- proven not to trap; Div keeps the checked form here (floored division)
  OArithU o a b -> def (\r -> case o of
    Add -> emitI (rrr O.Add r (vreg a) (vreg b))
    Sub -> emitI (rrr O.Subtract r (vreg a) (vreg b))
    Mul -> emitI (rrr O.Multiply r (vreg a) (vreg b))
    _ -> arith False o r (vreg a) (vreg b))
  -- band/bor/bxor on the untagged values: one instruction, the result fits
  OBit o a b -> def (\r -> emitI (rrr (case o of BAnd -> O.And; BOr -> O.Or; BXor -> O.Xor) r (vreg a) (vreg b)))
  -- I64 on the raw words: the machine's own wrapping instruction
  OI64Arith o a b -> def (\r -> emitI (rrr (case o of Add -> O.Add; Sub -> O.Subtract; _ -> O.Multiply) r (vreg a) (vreg b)))
  OI64Bit o a b -> def (\r -> emitI (rrr (case o of BAnd -> O.And; BOr -> O.Or; BXor -> O.Xor) r (vreg a) (vreg b)))
  OI64Cmp o a b -> def $ \r -> do
    emitI (cmp (vreg a) (vreg b))
    emitI (cset (cond o) r)
  -- F64 on the bits through xmm14/xmm15, inside the expansion only (SysV:
  -- caller-saved; no float register is allocated)
  OFloatBin o a b -> def (\r -> emitI (plain (O.X64 (O.FloatBinary O.WordBits O.Float64 o)) [any' r] [any' (vreg a), any' (vreg b)]))
  OFloatOfInt a -> def (\r -> emitI (plain (O.X64 (O.IntToFloat O.WordBits)) [any' r] [any' (vreg a)]))
  OFloatCmp o a b -> def (\r -> emitI ((plain (O.X64 (O.FloatCompare O.WordBits O.Float64 o)) [any' r] [any' (vreg a), any' (vreg b)]) {siFlags = FlagsDef}))
  OFloat32Bin o a b -> def (\r -> emitI (plain (O.X64 (O.FloatBinary O.WordBits O.Float32 o)) [any' r] [any' (vreg a), any' (vreg b)]))
  OFloatCmpTree o x y -> def (\r -> do
    forM_ (ftreeScheduleAt 0 x ++ ftreeScheduleAt 1 y) $ \case
      FSLeaf v n -> emitI (plain (O.X64 (O.TreeLeaf O.WordBits O.Float64)) [] [any' (vreg v), OI (fromIntegral n)])
      FSNode f n -> emitI (plain (O.X64 (O.TreeNode O.Float64 f)) [] [OI (fromIntegral n)])
    emitI ((plain (O.X64 (O.TreeCompare O.Float64 o)) [any' r] []) {siFlags = FlagsDef}))
  OFloat32CmpTree o x y -> def (\r -> do
    forM_ (ftreeScheduleAt 0 x ++ ftreeScheduleAt 1 y) $ \case
      FSLeaf v n -> emitI (plain (O.X64 (O.TreeLeaf O.WordBits O.Float32)) [] [any' (vreg v), OI (fromIntegral n)])
      FSNode f n -> emitI (plain (O.X64 (O.TreeNode O.Float32 f)) [] [OI (fromIntegral n)])
    emitI ((plain (O.X64 (O.TreeCompare O.Float32 o)) [any' r] []) {siFlags = FlagsDef}))
  OFloatTree t -> def (\r -> do
    let (steps, root) = ftreeSchedule t
    forM_ steps $ \case
      FSLeaf v n -> emitI (plain (O.X64 (O.TreeLeaf O.WordBits O.Float64)) [] [any' (vreg v), OI (fromIntegral n)])
      FSNode o n -> emitI (plain (O.X64 (O.TreeNode O.Float64 o)) [] [OI (fromIntegral n)])
    emitI (plain (O.X64 (O.TreeOutput O.WordBits O.Float64)) [any' r] [OI (fromIntegral root)]))
  OFloat32Tree t -> def (\r -> do
    let (steps, root) = ftreeSchedule t
    forM_ steps $ \case
      FSLeaf v n -> emitI (plain (O.X64 (O.TreeLeaf O.WordBits O.Float32)) [] [any' (vreg v), OI (fromIntegral n)])
      FSNode o n -> emitI (plain (O.X64 (O.TreeNode O.Float32 o)) [] [OI (fromIntegral n)])
    emitI (plain (O.X64 (O.TreeOutput O.WordBits O.Float32)) [any' r] [OI (fromIntegral root)]))
  OFloat32Cmp o a b -> def (\r -> emitI ((plain (O.X64 (O.FloatCompare O.WordBits O.Float32 o)) [any' r] [any' (vreg a), any' (vreg b)]) {siFlags = FlagsDef}))
  OShift o a b -> def (\r -> shift o r (vreg a) (vreg b))
  OCmp o a b -> def $ \r -> do
    case immediateForm (fImmediates facts) op of
      Just (_, _, n) -> emitI (cmpi (vreg a) n)
      Nothing -> emitI (cmp (vreg a) (vreg b))
    emitI (cset (cond o) r)
  -- both small: the raw words order as the Ints do; no tag test, no slow path
  OCmpVal o a b | Just ua <- rawOf a, Just ub <- rawOf b -> def $ \r -> do
    xa <- rawV ua
    xb <- rawV ub
    emitI (cmp xa xb)
    emitI (cset (cond o) r)
  -- one side small: only the other side's tag is tested, then raw against raw
  OCmpVal o a b | isJust (rawOf a) || isJust (rawOf b) -> def $ \r -> do
    slow <- freshL "cmpslow"
    done <- freshL "cmpdone"
    let other = if isJust (rawOf a) then b else a
    emitI (testi (vreg other) 1)
    emitI (bcond O.Equal slow)
    xo <- freshV False
    emitI (rri O.ShiftRightArithmeticImmediate xo (vreg other) 1)
    let side v = maybe (pure xo) rawV (rawOf v)
    sa <- side a
    sb <- side b
    emitI (cmp sa sb)
    emitI (cset (cond o) r)
    emitI (jump done)
    emitL slow
    ta <- taggedV a
    tb <- taggedV b
    res <- freshV True
    exactCall ("fpr_prim_fn_" ++ mangleName (cmpSym o)) [ta, tb] res
    emitI (rri O.ShiftRightArithmeticImmediate r res 8)
    emitL done
  OCmpVal o a b -> def $ \r -> do
    slow <- freshL "cmpslow"
    done <- freshL "cmpdone"
    both <- freshV False
    bit <- freshV False
    emitI (rrr O.And both (vreg a) (vreg b))
    emitI (rri O.AndImmediate bit both 1)
    emitI (cbz bit slow)
    emitI (cmp (vreg a) (vreg b))
    emitI (cset (cond o) r)
    emitI (jump done)
    emitL slow
    res <- freshV True
    exactCall ("fpr_prim_fn_" ++ mangleName (cmpSym o)) [vreg a, vreg b] res
    emitI (rri O.ShiftRightArithmeticImmediate r res 8)
    emitL done
  -- both small: raw equality; one small: the tagged word is the Int, and a
  -- bignum (an even pointer) never equals a small Int's odd word
  OEqVal eq a b | Just ua <- rawOf a, Just ub <- rawOf b -> def $ \r -> do
    xa <- rawV ua
    xb <- rawV ub
    emitI (cmp xa xb)
    emitI (cset (if eq then O.Equal else O.NotEqual) r)
  OEqVal eq a b | isJust (rawOf a) || isJust (rawOf b) -> def $ \r -> do
    ta <- taggedV a
    tb <- taggedV b
    emitI (cmp ta tb)
    emitI (cset (if eq then O.Equal else O.NotEqual) r)
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
    -- C9 stage 1: the deep comparison saves only what is live across it
    -- (KeepsLive), so tagged-Int comparisons do not push their operands
    -- into callee-saved registers for a slow path they rarely take
    exactCall ("fpr_prim_fn_" ++ mangleName (if eq then "==" else "!=")) [vreg a, vreg b] res
    emitI (rri O.ShiftRightArithmeticImmediate r res 8)
    emitL done
  OCallProduct _ _ -> refuse "internal: a product call outside its result packet"
  OResult _ -> refuse "internal: a product word without its call"
  OCall c as -> do
    when (length as > arityCeiling) (refuse ("a call with more than " ++ show arityCeiling ++ " arguments"))
    if keepsRegisters cfg c
      then def (\r -> emitKeepingCall (calleeSymbol c) (map vreg as) r)
      else def (\r -> emitCall (calleeSymbol c) (Calling.calleeCall (cfgPolicy cfg) c) (map vreg as) (Just r))
  where
    makeCell tid variant fields = def $ \rd -> do
      let literal n = do r <- freshV False; emitI (li r (fromIntegral n)); pure r
          storeHeader offset h = emitI (plain (O.X64 O.StoreHeader) [] [any' rd, any' h, OI offset])
          raw = 8 + 8 * fromIntegral (length fields)
      case bumpCellFor (cfgPolicy cfg) raw of
        -- the inline bump (docs/2026-11-03-INLINE-BUMP-ALLOC.md); a loaded QOS
        -- app (the borrowed hart cell) keeps the call
        Just _ | bumpAllocates (cfgPolicy cfg) && cfgHart cfg /= HartBorrow -> do
          l <- freshL "bump"
          emitI (Protocol.selectProtocol Calling.X86_64 ((plain (O.Common O.BumpAlloc) [any' rd] [OI raw]) {siAnnotation = EntryLabels l}))
        _ -> do
          size <- freshV False
          emitI (li size raw)
          emitCall (CodeSymbol "fpr_alloc") Calling.RuntimeCall [size] (Just rd)
      storeHeader 0 =<< literal tid
      header <- case variant of
        Left v -> literal v
        Right v -> do
          shifted <- freshV False
          emitI (rri O.ShiftLeftImmediate shifted (vreg v) 3)
          if length fields==2 then pure shifted else do
            extra <- literal (length fields-2)
            encoded <- freshV False
            emitI (rrr O.Add encoded shifted extra)
            pure encoded
      storeHeader 4 header
      forM_ (zip [0..] fields) $ \(index, value) ->
        emitI (plain (O.X64 O.StoreField) [] [any' rd, any' (vreg value), OI (8 + 8 * index)])
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
      trapCall "fpr_int_overflow_kernel"
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
        FSqrt -> refuse "an SSE2 pair square root is outside the SIMD proof"
    simdBinary caps op a b next = do
      (ra,n1) <- simdGo caps a next
      (rb,n2) <- simdGo caps b n1
      emitI (plain (O.X64 (O.PairBinary op)) [] [OI (fromIntegral n2),OI (fromIntegral ra),OI (fromIntegral rb)])
      pure (n2,n2+1)
    -- Checked Int arithmetic agrees with Codegen.Eval and runtime/runtime.c:
    -- the fast path computes and checks the 63-bit fit, the
    -- slow path retags the ORIGINAL operands and re-enters the C primitive,
    -- whose panic text and failure order are the language's
    arithImm o r a n = do
      slow <- freshL "slow"
      done <- freshL "done"
      emitI (addi r a (if o == Sub then negate n else n))
      fits r done
      emitL slow
      b <- freshV False
      emitI (li b n)
      retagged o r a b
      emitL done
    -- the answer is in r before the check, so the fitting path is one
    -- taken branch over the slow path and no jump around it (the slow path
    -- still reads the operands: r never shares a register with them)
    fits r done = do
      n <- freshV False
      emitI (rri O.ShiftLeftImmediate n r 1)
      emitI (bcond O.NoOverflow done)
    retagged o r a b = do
      ta' <- freshV True
      tb' <- freshV True
      emitI (tagw ta' a)
      emitI (tagw tb' b)
      res <- freshV True
      -- the cold re-entry keeps every register too (keepingWrappers)
      if keepingEnabled cfg
        then emitKeepingCall (CodeSymbol (primSymbol o)) [ta', tb'] res
        else emitCall (CodeSymbol (primSymbol o)) Calling.RuntimeCall [ta', tb'] (Just res)
      emitI (rri O.ShiftRightArithmeticImmediate r res 1)
    cmpSym = \case Lt -> "<"; Gt -> ">"; Le -> "<="; Ge -> ">="; Eq -> "=="; Ne -> "!="
    exactCall sym args res =
      if cfgFrames cfg && keepingEnabled cfg
        then emitKeepingCall (CodeSymbol sym) args res
        else emitCall (CodeSymbol sym) Calling.RuntimeCall args (Just res)
    rawOf v = M.lookup v (fTagSrc facts)
    constOf v = rawOf v >>= \u -> M.lookup u (fConsts facts)
    rawV u = case M.lookup u (fConsts facts) of
      Just n -> do
        t <- freshV False
        emitI (li t n)
        pure t
      Nothing -> pure (vreg u)
    taggedV v = case rawOf v of
      Just u | S.member v (fLazyTags facts) -> case M.lookup u (fConsts facts) of
        Just n -> do
          t <- freshV True
          emitI (li t (2 * n + 1))
          pure t
        Nothing -> do
          t <- freshV True
          emitI (tagw t (vreg u))
          pure t
      _ -> pure (vreg v)
    rawKernel o t xa yb slow = case o of
      Add -> emitI (rrr O.Add t xa yb) >> fit t slow
      Sub -> emitI (rrr O.Subtract t xa yb) >> fit t slow
      Mul -> emitI (rrr O.Multiply t xa yb) >> emitI (bcond O.Overflow slow) >> fit t slow
      Div -> do
        emitI (cbz yb slow)
        ok <- freshL "avfdivok"
        p <- freshV False
        remV <- freshV False
        xr <- freshV False
        emitI (divide t xa yb)
        emitI (rrr O.Multiply p t yb)
        emitI (rrr O.Subtract remV xa p)
        emitI (cbz remV ok)
        emitI (rrr O.Xor xr remV yb)
        emitI (cmpi xr 0)
        emitI (bcond (cond Ge) ok)
        emitI (addi t t (-1))
        emitL ok
        fit t slow
    -- an exact Int operation where at least one operand is known small: the
    -- other (if any) is tag-tested and untagged, nothing is retested
    arithSmall o r ma mb a b = do
      slow <- freshL "asslow"
      done <- freshL "asdone"
      case [v | (v, Nothing) <- [(a, ma), (b, mb)]] of
        [v] -> emitI (testi (vreg v) 1) >> emitI (bcond O.Equal slow)
        _ -> pure ()
      let rawSide v m = case m of
            Just u -> rawV u
            Nothing -> do
              x <- freshV False
              emitI (rri O.ShiftRightArithmeticImmediate x (vreg v) 1)
              pure x
      xa <- rawSide a ma
      yb <- rawSide b mb
      t <- freshV False
      rawKernel o t xa yb slow
      emitI (tagw r t)
      emitI (jump done)
      emitL slow
      ta <- taggedV a
      tb <- taggedV b
      exactCall (primSymbol o) [ta, tb] r
      emitL done
    -- x + k for a literal k, on the tagged word: 2x+1 + 2k is 2(x+k)+1, and
    -- the 64-bit add overflows (OF=1) iff x+k left the 63-bit small range
    addConst r x d oa ob o = do
      slow <- freshL "acslow"
      done <- freshL "acdone"
      emitI (testi x 1)
      emitI (bcond O.Equal slow)
      if d == 0
        then emitI (mov r x)
        else do
          dv <- freshV False
          t <- freshV False
          emitI (li dv d)
          emitI (rrr O.Add t x dv)
          emitI (bcond O.Overflow slow)
          emitI (mov r t)
      emitI (jump done)
      emitL slow
      ta <- taggedV oa
      tb <- taggedV ob
      exactCall (primSymbol o) [ta, tb] r
      emitL done
    arithVal o r a b = do
      slow <- freshL "avslow"
      done <- freshL "avdone"
      both <- freshV False
      bit <- freshV False
      emitI (rrr O.And both a b)
      emitI (rri O.AndImmediate bit both 1)
      emitI (cbz bit slow)
      xa <- freshV False
      yb <- freshV False
      t <- freshV False
      emitI (rri O.ShiftRightArithmeticImmediate xa a 1)
      emitI (rri O.ShiftRightArithmeticImmediate yb b 1)
      rawKernel o t xa yb slow
      emitI (tagw r t)
      emitI (jump done)
      emitL slow
      exactCall (primSymbol o) [a, b] r
      emitL done
    arith kernel o r a b = do
      slow <- freshL "slow"
      done <- freshL "done"
      t <- freshV False
      case o of
        Add -> emitI (rrr O.Add r a b) >> fits r done
        Sub -> emitI (rrr O.Subtract r a b) >> fits r done
        Mul -> do
          emitI (rrr O.Multiply t a b)
          emitI (bcond O.Overflow slow) -- full 64-bit overflow, then 63-bit language fit
          fit t slow
        Div -> do
          emitI (cbz b slow)
          ok <- freshL "fdivok"
          p <- freshV False
          remV <- freshV False
          xr <- freshV False
          emitI (divide t a b)
          emitI (rrr O.Multiply p t b)
          emitI (rrr O.Subtract remV a p)
          emitI (cbz remV ok)
          emitI (rrr O.Xor xr remV b)
          emitI (cmpi xr 0)
          emitI (bcond (cond Ge) ok)
          emitI (addi t t (-1))
          emitL ok
          fit t slow
      when (o `elem` [Mul, Div]) $ do
        emitI (mov r t)
        emitI (jump done)
      emitL slow
      if kernel then do
        zero <- freshL "kernelzero"
        when (o == Div) (emitI (cbz b zero))
        trapCall "fpr_int_overflow_kernel"
        when (o == Div) $ do
          emitL zero
          trapCall "fpr_div_zero_kernel"
        -- Both entries are noreturn. Define the result on the impossible
        -- continuation as well so the allocation oracle needs no exception.
        emitI (li r 0)
      else retagged o r a b
      emitL done
    -- the 63-bit fit check: a value fits when its top two bits agree, and
    -- a left shift by one sets the overflow flag exactly when they do not
    fit t slow = do
      n <- freshV False
      emitI (rri O.ShiftLeftImmediate n t 1)
      emitI (bcond O.Overflow slow)
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
      emitCall (CodeSymbol ("fpr_g_" ++ mangleName (shiftName o) ++ "_call2")) Calling.RuntimeCall [ta', tb'] (Just res)
      emitI (rri O.ShiftRightArithmeticImmediate r res 1)
      emitL done

-- block parameters are assigned in parallel: a cycle is broken with a
-- fresh temporary
parallelMoves :: [(VReg, VReg)] -> Se ()
parallelMoves = go . filter (uncurry (/=))
  where
    go [] = pure ()
    go ms@((d0, s0) : msRest) = case [m | m@(d, _) <- ms, d `notElem` map snd ms] of
      ((d, s) : _) -> emitI (mov d s) >> go (filter (/= (d, s)) ms)
      [] -> do
        t <- freshV True -- a tagged word may travel through it
        emitI (mov t s0)
        go ((d0, t) : [(d', if s' == s0 then t else s') | (d', s') <- msRest])

selectTerm :: X64Config -> Fn -> Facts -> Maybe BId -> Block -> Se ()
selectTerm cfg fn facts nextBlock b = case bTerm b of
  TRet v -> emitI (ret (vreg v))
  TRetProduct vs -> retProduct (map vreg vs)
  TBr target as
    | target == fnEntry fn -> -- a self tail transfer re-enters through the function symbol
        emitTail (CodeSymbol (functionSymbol (fnName fn))) (FprCall TicksFuel) (map vreg as)
    | otherwise -> do
        parallelMoves (zip (paramsOf target) (map vreg as))
        -- the block laid out next is fallen into
        unless (Just target == nextBlock) (emitI (jump (blockLabel target)))
  TCondBr p t as e bs -> condBranch fn facts nextBlock (cbnz (vreg p)) (cbz (vreg p)) t as e bs
  TTailCall c as -> do
    when (length as > arityCeiling) (refuse ("a tail call with more than " ++ show arityCeiling ++ " arguments"))
    emitTail (calleeSymbol c) (Calling.calleeCall (cfgPolicy cfg) c) (map vreg as)
  -- A reached dead arm calls fpr_panic with its reason. It does not
  -- return; the function's text ends here
  TUnreachable msg -> do
    modify (\s -> s {selStrings = S.insert msg (selStrings s)})
    emitI (Protocol.selectProtocol Calling.X86_64 (plain (O.X64 O.Panic) [] [OAddr (StaticObject (stringLabel msg))]))
  where
    paramsOf bid = M.findWithDefault [] bid (fParams facts)

-- the allocator's view of this target (M3): the first six parameters
-- arrive in the SysV registers, seven and eight are read from the private
-- cells before the entry sequence can destroy them
allocConfig :: Bool -> Maybe CodeSymbol -> S.Set VReg -> AllocConfig
allocConfig split self managed = AllocConfig
  { acCalleeSaved = calleeBudget,
    acCallerSaved = callerPool ++ floatPoolRegs,
    acScratch = allocScratch ++ floatScratch,
    acPreserved = map r ["rbp", "rsp"],
    acArrival = \params ->
      let placed=Calling.arrivalArguments Calling.X86_64 params
      in plain (O.Common O.Params) [fix v p | (Calling.ArgumentRegister p,v)<-placed] []
        : [plain (O.Common O.LoadCell) [any' v] [OC cell] | (Calling.NamedArgument cell,v)<-placed]
        ++ [plain (O.Common O.LoadSpill) [any' v] [OI (toInteger j)] | (Calling.HartArgument j,v)<-placed],
    acLoad = \p ref -> plain (O.X64 O.FrameLoad) [OP p] [OF ref 0],
    acStore = \p ref -> plain (O.X64 O.FrameStore) [] [OP p, OF ref 0],
    acMove = \d s' -> plain (O.X64 (if rfClassOf x64RegisterFile d == Just FPR || rfClassOf x64RegisterFile s' == Just FPR then O.FloatMove else O.Move)) [OP d] [OP s'],
    acSlot = \n v -> frameObj n 8 8 (SpillSlot n) (S.member v managed),
    -- cqto writes rdx before idivq reads the divisor
    -- store.spill writes a scratch register before it reads the value
    acEarlyDef = \i -> siOpcode i `elem` [O.X64 O.Divide, O.Common O.StoreSpill, O.Common O.StoreCell],
    acClassOf = rfClassOf x64RegisterFile,
    acSelfLoop = self,
    acSpillMoves = split,
    acColdCall = \i -> split && keepingCall i }

-- Floating results get their own virtual register class (C1, as A64's
-- floatPool: docs/2026-11-15-VECTOR-VIEWS-BUFFERED-OUTPUT.md section 5).
-- Function and block parameters fixed to registers keep the word ABI; a
-- word reader of a pooled value gets a bit-preserving movq. Only F64 is
-- pooled: an F32 word is the zero-extended low half, which movq would not
-- keep.
floatPool :: SFn -> SFn
floatPool fn0
  | not (any floatItem (sfBody fn0)) = fn0
  | otherwise = fn {sfBody = map clobbering (forwardOutputs (evalState (concat <$> mapM item (sfBody fn)) (start, M.empty)))}
  where
    (fn, hoisted) = hoistFloatParams floatContext fn0
    clobbering (I i) = I (floatClobbers i)
    clobbering l = l
    floatItem (I i) = floatingDef (siOpcode i) || floatContext (siOpcode i)
    floatItem _ = False
    produced = S.fromList [v | I i <- sfBody fn, floatingDef (siOpcode i), OV v _ <- siDefs i]
    floatingDef = \case
      O.X64 (O.FloatBinary O.WordBits O.Float64 _) -> True
      O.X64 (O.TreeOutput O.WordBits O.Float64) -> True
      O.X64 (O.IntToFloat O.WordBits) -> True
      _ -> False
    floatContext = \case
      O.X64 (O.FloatBinary O.WordBits O.Float64 _) -> True
      O.X64 (O.FloatCompare O.WordBits O.Float64 _) -> True
      O.X64 (O.FloatTest O.WordBits O.Float64) -> True
      O.X64 (O.TreeLeaf O.WordBits O.Float64) -> True
      _ -> False
    -- a value only plain moves define (a block parameter: one move per
    -- edge) joins the class when one of those moves brings a float and a
    -- float operation reads it: a loop then carries its floats in xmm
    -- registers, and the edges that bring a word pay one move in
    plainMove i = case (siOpcode i, siDefs i, siUses i) of
      (O.X64 O.Move, [OV d (Any GPR)], [OV src (Any GPR)]) -> Just (d, src)
      _ -> Nothing
    pinned = S.fromList (sfParams fn) `S.union` S.fromList
      [v | I i <- sfBody fn, OV v c <- siDefs i ++ siUses i, c /= Any GPR]
    sources = M.fromListWith (++) ([(d, [Just src]) | I i <- sfBody fn, Just (d, src) <- [plainMove i]]
      ++ [(v, [Nothing]) | I i <- sfBody fn, Nothing <- [plainMove i], OV v _ <- siDefs i])
    floatRead = S.fromList [v | I i <- sfBody fn, floatContext (siOpcode i), OV v _ <- siUses i]
    carried have =
      let wanted = floatRead `S.union` S.fromList [src | I i <- sfBody fn, Just (d, src) <- [plainMove i], S.member d have]
          more = S.fromList [v | (v, from) <- M.toList sources, S.notMember v pinned, S.member v wanted,
                                 all (/= Nothing) from,
                                 or [S.member src have | Just src <- from] || onlyFloatReads v]
          next = have `S.union` more
       in if next == have then have else carried next
    readCounts = M.fromListWith (\(a, b) (c, d) -> (a + c, b + d)) [(v, (1 :: Int, if floatContext (siOpcode i) then 1 else 0 :: Int)) | I i <- sfBody fn, OV v _ <- siUses i]
    onlyFloatReads v = case M.lookup v readCounts of
      Just (every, floating) -> floating >= 2 && every == floating
      Nothing -> False
    -- a constant that only float operations read is made in its register
    -- (FloatLiteral: one load from the function's literals, or xorps)
    literals = S.fromList [v | I i <- sfBody fn, O.X64 O.Literal <- [siOpcode i], [OV v (Any GPR)] <- [siDefs i],
                               S.notMember v pinned, everyFloat v]
    everyFloat v = case M.lookup v readCounts of
      Just (every, floating) -> floating >= 1 && every == floating
      Nothing -> False
    -- a word loaded for float operations alone (a vector's F64 element)
    -- is loaded into its xmm register: movq reads memory into either class
    loads = S.fromList [v | I i <- sfBody fn, O.X64 O.LoadField <- [siOpcode i], [OV v (Any GPR)] <- [siDefs i],
                            S.notMember v pinned, everyFloat v]
    floats = carried (produced `S.union` literals `S.union` loads `S.union` hoisted)
    start = 1 + maximum (0 : [n | I i <- sfBody fn, OV (VReg n) _ <- siDefs i ++ siUses i])
    fresh :: RegClass -> State (Int, M.Map Integer Operand) Operand
    fresh cls = do (n, m) <- get; put (n + 1, m); pure (OV (VReg n) (Any cls))
    slotOf :: Integer -> State (Int, M.Map Integer Operand) (Maybe Operand)
    slotOf n = gets (M.lookup n . snd)
    setSlot :: Integer -> Operand -> State (Int, M.Map Integer Operand) ()
    setSlot n o = modify (\(k, m) -> (k, M.insert n o m))
    -- An F64 tree's slots become pooled values: a leaf names its value (a
    -- word is moved in once), a step writes a fresh value, and the output
    -- or the comparison reads the slots. No xmm8+ scratch is involved, and
    -- a slot whose value dies at its step shares the register.
    treeStep i = case (siOpcode i, siDefs i, siUses i) of
      (O.X64 (O.TreeLeaf O.WordBits O.Float64), [], [OV v _, OI n]) -> do
        (moves, o) <- asFloat (OV v (Any GPR))
        setSlot n o
        pure (Just moves)
      (O.X64 (O.TreeNode O.Float64 op), [], [OI n]) -> do
        b <- slotOf (n + 1)
        a <- slotOf n
        case (b, if op == FSqrt then maybe b Just a else a) of
          (Just b', Just a') -> do
            t <- fresh FPR
            setSlot n t
            pure (Just [I (plain (O.X64 (O.FloatBinary O.FloatRegisters O.Float64 op)) [t] [a', b'])])
          _ -> unset n
      (O.X64 (O.TreeOutput O.WordBits O.Float64), [d], [OI n]) -> slotOf n >>= \case
        Just o -> clear >> pure (Just [I (plain (O.X64 O.FloatMove) [def d] [o])])
        Nothing -> unset n
      (O.X64 (O.TreeCompare O.Float64 c), [d], []) -> do
        (x, y) <- both
        clear
        pure (Just [I ((plain (O.X64 (O.FloatCompare O.FloatRegisters O.Float64 c)) [d] [x, y]) {siFlags = FlagsDef})])
      (O.X64 (O.TreeTest O.Float64 c), [], []) -> do
        (x, y) <- both
        clear
        pure (Just [I ((plain (O.X64 (O.FloatTest O.FloatRegisters O.Float64)) [] (if c `elem` [Gt, Ge] then [x, y] else [y, x])) {siFlags = FlagsDef})])
      _ -> pure Nothing
    -- the schedule fills every slot a step reads (Codegen.IR ftreeSchedule)
    unset n = error ("X64 float pool: a tree reads slot " ++ show n ++ " before it is written")
    both = do
      a <- slotOf 0
      b <- slotOf 1
      case (a, b) of
        (Just x, Just y) -> pure (x, y)
        (Nothing, _) -> unset 0
        _ -> unset 1
    clear :: State (Int, M.Map Integer Operand) ()
    clear = modify (\(k, _) -> (k, M.empty))
    -- the tree's last step writes the output's value itself: a fresh value
    -- read once, by the move right after the step that defines it
    forwardOutputs (I a : I b : rest)
      | O.X64 O.FloatMove <- siOpcode b, [d@(OV _ (Any FPR))] <- siDefs b, [OV t (Any FPR)] <- siUses b,
        [OV t' (Any FPR)] <- siDefs a, t == t', unVReg t >= start, onlyUse t
        = forwardOutputs (I a {siDefs = [d]} : rest)
    forwardOutputs (x : rest) = x : forwardOutputs rest
    forwardOutputs [] = []
    unVReg (VReg n) = n
    -- a tree temporary is read by the next step or the output alone
    onlyUse t = M.findWithDefault (0 :: Int) t tempUses == 1
    tempUses = M.fromListWith (+) [(v, 1) | I i <- evalState (concat <$> mapM item (sfBody fn)) (start, M.empty), OV v _ <- siUses i]
    fp v = OV v (Any FPR)
    asFloat o@(OV v _) | S.member v floats = pure ([], fp v)
                       | otherwise = do t <- fresh FPR; pure ([I (plain (O.X64 O.FloatMove) [t] [o])], t)
    asFloat o = pure ([], o)
    asWord o@(OV v constraint) | S.member v floats = do
      t <- fresh GPR
      let use = case t of OV w _ -> OV w constraint; _ -> error "X64 float pool: invalid fresh operand"
      pure ([I (plain (O.X64 O.FloatMove) [t] [fp v])], use)
                               | otherwise = pure ([], o)
    asWord o = pure ([], o)
    def (OV v _) | S.member v floats = fp v
    def o = o
    item (ILabel l) = pure [ILabel l]
    item (I i) = treeStep i >>= \case
      Just out -> pure out
      Nothing -> plainItem i
    plainItem i = case siOpcode i of
      O.X64 O.Literal | [OV v _] <- siDefs i, S.member v floats ->
        pure [I i {siOpcode = O.X64 O.FloatLiteral, siDefs = map def (siDefs i)}]
      O.X64 O.LoadField | [OV v _] <- siDefs i, S.member v floats ->
        pure [I i {siDefs = map def (siDefs i)}]
      -- the stored value straight from its xmm register (movq to memory)
      O.X64 O.StoreField | [base, OV v _, n] <- siUses i, S.member v floats -> do
        (moves, base') <- asWord base
        pure (moves ++ [I i {siUses = [base', fp v, n]}])
      O.X64 (O.FloatBinary O.WordBits O.Float64 op) -> pooled i (O.FloatBinary O.FloatRegisters O.Float64 op) True
      O.X64 (O.FloatCompare O.WordBits O.Float64 c) -> pooled i (O.FloatCompare O.FloatRegisters O.Float64 c) False
      O.X64 (O.FloatTest O.WordBits O.Float64) -> pooled i (O.FloatTest O.FloatRegisters O.Float64) False
      O.X64 (O.IntToFloat O.WordBits) | [OV v _] <- siDefs i, S.member v floats ->
        pure [I i {siOpcode = O.X64 (O.IntToFloat O.FloatRegisters), siDefs = map def (siDefs i)}]
      O.X64 (O.TreeOutput O.WordBits O.Float64) | [OV v _] <- siDefs i, S.member v floats ->
        pure [I i {siOpcode = O.X64 (O.TreeOutput O.FloatRegisters O.Float64), siDefs = map def (siDefs i)}]
      O.X64 (O.TreeLeaf O.WordBits O.Float64) | OV v _ : rest <- siUses i, S.member v floats ->
        pure [I i {siOpcode = O.X64 (O.TreeLeaf O.FloatRegisters O.Float64), siUses = fp v : rest}]
      O.X64 O.Move | Just (d, src) <- plainMove i, S.member d floats ->
        pure [I i {siOpcode = O.X64 O.FloatMove, siDefs = [fp d], siUses = [if S.member src floats then fp src else OV src (Any GPR)]}]
      O.X64 O.Move | Just (d, src) <- plainMove i, S.member src floats ->
        pure [I i {siOpcode = O.X64 O.FloatMove, siDefs = [OV d (Any GPR)], siUses = [fp src]}]
      _ -> do
        args <- mapM asWord (siUses i)
        pure (concatMap fst args ++ [I i {siUses = map snd args}])
    -- the float form's uses all in the class; its definition in the class
    -- when it is a float (a compare's answer stays a word)
    pooled i op floating = do
      args <- mapM asFloat (siUses i)
      pure (concatMap fst args ++ [I i {siOpcode = O.X64 op, siDefs = if floating then map def (siDefs i) else siDefs i, siUses = map snd args}])

-- Unboxed F64 loop values (C6 stage 1): a function parameter is pinned
-- to its word register by the ABI, so a float operation in a loop that
-- reads a loop-invariant F64 parameter paid a movq into xmm on every
-- iteration. When a call-free loop (a back edge from the end of a layout
-- range [header, jump]) reads such a parameter in float operations, the
-- parameter is moved into a fresh value once, on the single edge that
-- enters the header from outside the loop, and every float read the
-- header dominates takes that value; floatPool then gives it an xmm
-- register. Word readers keep the parameter's own register.
hoistFloatParams :: (O.Opcode -> Bool) -> SFn -> (SFn, S.Set VReg)
hoistFloatParams floatContext fn
  | null plans = (fn, S.empty)
  | otherwise = (fn {sfBody = rewritten}, S.fromList [t | (_, moves) <- plans, (_, t) <- moves])
  where
    items = sfBody fn
    n = length items
    arr = M.fromList (zip [0 :: Int ..] items)
    labelAt = M.fromList [(l, k) | (k, ILabel l) <- zip [0 ..] items]
    -- a parameter some instruction redefines (a self loop's moves) is not invariant
    params = S.fromList (sfParams fn) `S.difference` S.fromList [v | I i <- items, OV v _ <- siDefs i]
    targets i = case siControl i of
      JumpTo l -> [l]
      CondTo ls -> ls
      _ -> []
    falls i = case siControl i of
      Next -> True
      CondTo _ -> True
      _ -> False
    succs k = case M.lookup k arr of
      Just (ILabel _) -> [k + 1 | k + 1 < n]
      Just (I i) -> [k + 1 | falls i, k + 1 < n] ++ [t | l <- targets i, Just t <- [M.lookup l labelAt]]
      Nothing -> []
    -- the items reachable from the entry without passing the header
    outside h = go S.empty [0 | h /= 0]
      where go seen [] = seen
            go seen (k : ks) | S.member k seen || k == h = go seen ks
                             | otherwise = go (S.insert k seen) (succs k ++ ks)
    loops = [ (h, j) | (j, I i) <- zip [0 ..] items, l <- targets i, Just h <- [M.lookup l labelAt], h <= j,
                       null [() | k <- [h .. j], Just (I c) <- [M.lookup k arr], clobbersFloats c] ]
    -- the fuel and allocation wrappers preserve the xmm pool (saveFloats)
    clobbersFloats c = not (all callPreserves (siCalls c)) || any (`elem` floatPoolRegs) (siClobbers c)
    floatReads k = case M.lookup k arr of
      Just (I i) | floatContext (siOpcode i) -> [v | OV v _ <- siUses i, S.member v params]
      _ -> []
    start0 = 1 + maximum (0 : [m | I i <- items, OV (VReg m) _ <- siDefs i ++ siUses i] ++ [m | VReg m <- sfParams fn])
    -- one plan per header: its parameters, each with its fresh value
    candidates = M.toList (M.fromListWith S.union
      [ (h, S.fromList vs) | (h, j) <- loops, let vs = concatMap floatReads [h .. j], not (null vs) ])
    plans = assign start0 [ (h, out, S.toList vs) | (h, vs) <- candidates, h > 0, let out = outside h, entryOk h out ]
    assign _ [] = []
    assign next ((h, out, vs) : rest) =
      let moves = zip vs (map VReg [next ..])
       in (h, moves) : assign (next + length vs) rest
    -- the header is entered from outside only by falling through from the item before it
    entryOk h out =
      S.member (h - 1) out
        && (case M.lookup (h - 1) arr of Just (I i) -> falls i; Just (ILabel _) -> True; Nothing -> False)
        && null [ () | k <- S.toList out, k /= h - 1, h `elem` succs k ]
    -- headers already planned own their dominated reads; the first plan wins
    planFor = [ (h, out, M.fromList moves) | (h, moves) <- plans, let out = outside h ]
    rewritten = concat [ before k ++ [rewrite k it] | (k, it) <- zip [0 ..] items ]
    before k = [ I (plain (O.X64 O.Move) [OV t (Any GPR)] [OV p (Any GPR)]) | (h, moves) <- plans, h == k, (p, t) <- moves ]
    rewrite k (I i) | floatContext (siOpcode i) =
      I i {siUses = [ case o of
                        OV v c | Just t <- dominating k v -> OV t c
                        _ -> o
                    | o <- siUses i ]}
    rewrite _ it = it
    dominating k v = case [ t | (_, out, m) <- planFor, S.notMember k out, Just t <- [M.lookup v m] ] of
      (t : _) -> Just t
      [] -> Nothing

savedObjs :: [Phys] -> [FrameObj]
savedObjs saved = [FrameObj (FrameRef (negate (k + 1))) 8 8 (SavedRegister p) False False | (k, Phys p) <- zip [0 ..] saved]

emitFnX64 :: X64Config -> Fn -> Either String NativeFn
emitFnX64 cfg=emitFnX64WithSymbols (publicSymbols (cfgExports cfg)) cfg

emitFnX64WithSymbols :: SymbolPolicy -> X64Config -> Fn -> Either String NativeFn
emitFnX64WithSymbols symbols cfg fn = do
  (sel0, managed, nulls, strs) <- select cfg fn
  let pooled = if polProfile (cfgPolicy cfg) == QosApp || not (tuneFpPool (cfgTune cfg)) then sel0 else floatPool sel0
      fpValues = S.fromList [v | I i <- sfBody pooled, OV v (Any FPR) <- siDefs i ++ siUses i]
      -- C9 stage 1: the entry's two slow paths keep every allocatable
      -- register themselves (the tick's wrapper, and stackGrowWrapper for
      -- the stack check: Protocol.keepingEntry), so the parameters stay
      -- wherever the allocator puts them, with no parking slots
      (sel, entrySlots)
        | cfgFrames cfg = (pooled {sfBody = [case it of I i -> I (Protocol.keepingEntryWith (tuneSplit (cfgTune cfg)) Calling.X86_64 i); _ -> it | it <- sfBody pooled]}, [])
        | otherwise = forwardEntry (cfgForwardParams cfg) (tuneEntryArgs (cfgTune cfg)) argRegs fn pooled
  -- (floatPool annotates the xmm clobbers only when it pools anything)
  checkForms (fnName fn) (sfBody sel)
  either (Left . ("compiler error: " ++)) Right (checkFn x64RegisterFile sel)
  let ac = allocConfig (cfgFrames cfg && tuneSplit (cfgTune cfg)) (if cfgSelfLoops cfg then Just (CodeSymbol (functionSymbol (fnName fn))) else Nothing) (S.difference managed fpValues)
  alloc <- either (Left . ("compiler error: " ++)) Right (allocateFn ac sel)
  either (Left . ("compiler error: " ++)) Right (checkAllocation ac (fnName fn) (alBody alloc))
  let saves = savedObjs (alSaved alloc)
      objs = saves ++ alSlots alloc ++ entrySlots
      ordinary = layout 16 16 objs
      large = polStackCheck (cfgPolicy cfg) /= StackStatic && lyBytes ordinary > 32768
      ly = if large then layout 24 16 objs else ordinary
      (shallow, shallowBody) = shallowEntry (polStackCheck (cfgPolicy cfg)) (lyBytes ly) (alBody alloc)
      -- C9 stage 1: each register-preserving runtime call saves only the
      -- caller-saved registers live across it, inline (KeepsLive)
      allocatedBody = if cfgFrames cfg then keepLive shallowBody else shallowBody
  when (not large && lyBytes ly > 32768) $ Left ("a frame of " ++ show (lyBytes ly) ++ " bytes exceeds the 32768-byte ceiling (half the runtime's stack headroom)")
  let name = fnName fn
      sym = gsym (cfgHart cfg) (functionSymbol name)
      saveOff o = show (M.findWithDefault (error "X64: a saved register without an offset") (foRef o) (lyOffset ly)) ++ "(%rbp)"
      saveLines = ["movq %" ++ p ++ ", " ++ saveOff o | o <- saves, SavedRegister p <- [foKind o]]
      restores = ["movq " ++ saveOff o ++ ", %" ++ p | o <- saves, SavedRegister p <- [foKind o]]
      saveItem = I (plain (O.X64 O.Save) [] [])
      -- shrink-wrapping (Common.shrinkWrap): the saves move to the deepest
      -- acyclic block dominating every use of a saved register; returns
      -- it does not dominate skip the restores. The frame itself (and so
      -- the stack bound) is unchanged.
      wrapped = if tuneShrinkWrap (cfgTune cfg) && not large then shrinkWrap False (alSaved alloc) allocatedBody else Nothing
      body = I ((plain (O.X64 O.Enter) [] []) {siImplicitDefs = map r (["rsp", "rbp"] ++ [p | large,p <- ["rax","r11"]])})
        : case wrapped of
            Nothing -> [saveItem | not (null saves)] ++ allocatedBody
            Just items -> concatMap (\it -> case it of I s | siOpcode s == O.Common O.SavesHere -> [saveItem]; _ -> [it]) items
      reserve = if large then reserveFrame (cfgHart cfg) name (toInteger (lyBytes ly)) (length (sfParams sel)) else []
      refills = planBumpRefills 2 body
      -- The site's call supplies the alignment word the old inline refill
      -- reserved explicitly. The wrapper sees exactly the same stack depth.
      refillCode = concat
        [[local (cfgHart cfg) name label ++ ":", "    movq $"++show raw++", %r11",
          "    call "++Call.runtimeName Call.AllocSaveEntry,
          "    movq %r11, %"++d, "    ret"] | ((d,raw),label)<-M.toList refills]
      renderOne = renderItem cfg ly large name saveLines restores refills
      reserveToks = [TIns (length (filter isInstruction reserve)) FNext False 1 | large]
      rendered = weighTicks (polTickWeight (cfgPolicy cfg)) reserveToks renderOne (tokOf refills) body
      report = analyse (reserveToks ++ concatMap (uncurry (tokOf refills)) rendered)
      header = ["# fn " ++ name ++ " (arity " ++ show (length (sfParams sel)) ++ ") typed-ir x64 frame=" ++ show (lyBytes ly)
                  ++ (if large then " reserve=yes" else "")
                  ++ (if shallow then " shallow=yes" else " shallow=no") ++ (if null entrySlots then "" else " forward=yes") ++ (if wrapped == Nothing then "" else " wrapped=yes") ++ " saved=" ++ (case alSaved alloc of [] -> "none"; ps -> intercalate "," [p | Phys p <- ps]) ++ " " ++ statsLine (alStats alloc)]
        ++ visibilityLines (x64Format (cfgHart cfg)) (if x64Format (cfgHart cfg)==MachO then WeakDefinitionDirective else WeakDirective) (visibilityFor (cfgWeak cfg) symbols name) sym ++ [sym ++ ":"]
  checkForms name body
  let stack = Stack.selectedFrame Stack.StackReturnAddress ly (CodeSymbol (functionSymbol name))
        (["interposable-entry:"++functionSymbol name | visibilityFor (cfgWeak cfg) symbols name == WeakSymbol]
          ++ ["segmented-stack-reservation" | large] ++ ["darwin-tlv-boundary" | cfgHart cfg == HartTlvMachO]) body
  pure (NativeFn name (header ++ map (\s -> if last s==':' then s else "    "++s) reserve ++ concatMap snd rendered ++ refillCode ++ keepingWrappers (cfgHart cfg) name allocatedBody ++ floatLiterals (cfgHart cfg) name allocatedBody ++ [reportLine name report, ""]) report stack (S.toList nulls) (S.toList strs) [] (usesTick allocatedBody) (usesBump allocatedBody))
  where
    tokOf _ (ILabel (Label l)) _ = [TLabel l]
    tokOf pools (I i) ls = [TIns
      { tCost = length [() | l <- ls, isInstruction l] + (case bumpRefill pools i of Just _ -> 4; Nothing -> 0),
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
      "call " ++ gsym hart (Call.runtimeName Call.ReserveStackEntry)]
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

renderItem :: X64Config -> Layout -> Bool -> String -> [String] -> [String] -> BumpRefills -> Item -> [String]
renderItem cfg _ _ fname _ _ _ (ILabel l) = [local (cfgHart cfg) fname l ++ ":"]
renderItem cfg ly large fname saveLines restores pools (I i) = map indent (go (siOpcode i) (siDefs i) (siUses i))
  where
    hart = cfgHart cfg
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
    cc = \case O.Equal -> "e"; O.NotEqual -> "ne"; O.Less -> "l"; O.Greater -> "g"; O.LessEqual -> "le"; O.GreaterEqual -> "ge"; O.Overflow -> "o"; O.NoOverflow -> "no"; O.UnsignedAboveEqual -> "ae"; O.UnsignedBelow -> "b"; O.UnsignedAbove -> "a"; O.UnsignedBelowEqual -> "be"
    call sym = ["subq $8, %rsp", "call " ++ gsym hart sym, "addq $8, %rsp"]
    go op ds us = case (op,ds,us) of
      (O.Common O.BumpAlloc,[d],[OI raw]) | Just c <- bumpCellFor (cfgPolicy cfg) raw -> bump (reg d) c
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
      -- movq loads and stores an xmm register as well as a word
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
      (O.X64 O.FloatMove,[d],[s]) -> [fmove s d]
      -- +0.0 by xorps (no flags touched), anything else from the literals
      (O.X64 O.FloatLiteral,[d],[OI 0]) -> ["xorps " ++ reg d ++ ", " ++ reg d]
      (O.X64 O.FloatLiteral,[d],[OI n]) -> ["movsd " ++ local hart fname (floatLiteralLabel n) ++ "(%rip), " ++ reg d]
      -- the shortest move that makes the constant (none touches the flags:
      -- a fused compare may sit between its test and its branch): a 32-bit
      -- move zero-extends, a quad move sign-extends 32 bits, movabs the rest
      (O.X64 O.Literal,[d],[OI n])
        | n >= 0, n < 2 ^ (32 :: Int) -> ["movl $" ++ show n ++ ", " ++ word32 d]
        | n >= -(2 ^ (31 :: Int)), n < 0 -> ["movq $" ++ show n ++ ", " ++ reg d]
        | otherwise -> ["movabsq $" ++ show n ++ ", " ++ reg d]
      (O.X64 O.Address,[d],[OAddr s]) -> ["leaq " ++ gsym hart (addressName s) ++ "(%rip), " ++ reg d]
      -- three-address forms through the address unit: no tie to a source's
      -- register and the flags untouched
      (O.X64 O.AddImmediate,[d],[s,n]) -> ["leaq " ++ imm n ++ "(" ++ reg s ++ "), " ++ reg d]
      (O.X64 O.TagWord,[d],[s]) -> ["leaq 1(" ++ reg s ++ "," ++ reg s ++ "), " ++ reg d]
      (O.X64 O.LoadByteIndexed,[d],[base,index,n]) -> ["movzbq " ++ imm n ++ "(" ++ reg base ++ "," ++ reg index ++ "), " ++ reg d]
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
      (O.X64 (O.TreeLeaf O.WordBits w),[],[x,OI n]) -> [moveIn w x ("%xmm" ++ show (8+n))]
      (O.X64 (O.TreeOutput O.WordBits w),[d],[OI n]) -> [moveOut w ("%xmm" ++ show (8+n)) d]
      (O.X64 (O.TreeLeaf O.FloatRegisters _),[],[x,OI n]) -> ["movapd " ++ reg x ++ ", %xmm" ++ show (8+n)]
      (O.X64 (O.TreeOutput O.FloatRegisters _),[d],[OI n]) -> ["movapd %xmm" ++ show (8+n) ++ ", " ++ reg d]
      (O.X64 (O.TreeTest w c),[],[]) ->
        [if c `elem` [Gt, Ge] then "ucomi" ++ suffix w ++ " %xmm9, %xmm8" else "ucomi" ++ suffix w ++ " %xmm8, %xmm9"]
      (O.X64 (O.TreeNode w op),[],[OI n]) ->
        [O.floatName op ++ suffix w ++ " %xmm" ++ show (9+n) ++ ", %xmm" ++ show (8+n)]
      (O.X64 (O.IntToFloat O.WordBits),[d],[a]) -> ["cvtsi2sdq " ++ reg a ++ ", %xmm14","movq %xmm14, " ++ reg d]
      -- cleared first: cvtsi2sd writes only the low lane and would wait on
      -- the register's previous value
      (O.X64 (O.IntToFloat O.FloatRegisters),[d],[a]) -> ["xorps " ++ reg d ++ ", " ++ reg d,"cvtsi2sdq " ++ reg a ++ ", " ++ reg d]
      -- two-address SSE: the result in d after a copy of a, or the operands
      -- swapped when d holds b and the operation commutes; sqrt reads b only
      (O.X64 (O.FloatBinary O.FloatRegisters w op),[d],[a,b])
        | op == FSqrt -> [O.floatName op ++ suffix w ++ " " ++ reg b ++ ", " ++ reg d]
        | reg d == reg a -> [O.floatName op ++ suffix w ++ " " ++ reg b ++ ", " ++ reg d]
        | reg d /= reg b -> [fmove a d, O.floatName op ++ suffix w ++ " " ++ reg b ++ ", " ++ reg d]
        | op `elem` [FAdd, FMul] -> [O.floatName op ++ suffix w ++ " " ++ reg a ++ ", " ++ reg d]
        | otherwise -> [fmove a (OP (Phys "xmm15")), O.floatName op ++ suffix w ++ " " ++ reg b ++ ", %xmm15", fmove (OP (Phys "xmm15")) d]
      (O.X64 (O.FloatCompare O.FloatRegisters w c),[d],[a,b]) ->
        let (x,y,pred')=comparison c a b
         in [fmove x (OP (Phys "xmm15")),
             "cmp" ++ pred' ++ suffix w ++ " " ++ reg y ++ ", %xmm15",
             moveOut w "%xmm15" d,"andq $1, " ++ reg d]
      (O.X64 (O.FloatTest O.FloatRegisters w),[],[l,r']) -> ["ucomi" ++ suffix w ++ " " ++ reg r' ++ ", " ++ reg l]
      (O.X64 (O.FloatTest O.WordBits w),[],[l,r']) ->
        [moveIn w l "%xmm14",moveIn w r' "%xmm15","ucomi" ++ suffix w ++ " %xmm15, %xmm14"]
      (O.X64 (O.FloatBinary O.WordBits w op),[d],[a,b]) ->
        [moveIn w a "%xmm14",moveIn w b "%xmm15",
         O.floatName op ++ suffix w ++ " %xmm15, %xmm14",moveOut w "%xmm14" d]
      -- Ordered predicates are false for NaN; inequality is true. gt/ge
      -- compare swapped operands, preserving the reference evaluator's rule.
      (O.X64 (O.FloatCompare O.WordBits w c),[d],[a,b]) ->
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
      (O.X64 O.TestImmediate,[],[a,n]) -> ["testq $" ++ imm n ++ ", " ++ reg a]
      (O.X64 (O.Set c),[d],[]) -> ["set" ++ cc c ++ " " ++ byte d, "movzbq " ++ byte d ++ ", " ++ reg d]
      (O.X64 (O.Select c),[d],[_,a]) -> ["cmov" ++ cc c ++ " " ++ reg a ++ ", " ++ reg d]
      (O.X64 (O.Branch c),[],[OL l]) -> ["j" ++ cc c ++ " " ++ lbl l]
      (O.X64 O.BranchZero,[],[v,OL l]) -> ["testq " ++ reg v ++ ", " ++ reg v,"jz " ++ lbl l]
      (O.X64 O.BranchNonzero,[],[v,OL l]) -> ["testq " ++ reg v ++ ", " ++ reg v,"jnz " ++ lbl l]
      (O.X64 O.Jump,[],[OL l]) -> ["jmp " ++ lbl l]
      (O.Common O.JumpLoop,[],[OL l]) -> ["jmp " ++ lbl l]
      (O.X64 O.Call,_,OCode s:_) | keepingCall i, KeepsLive live <- siAnnotation i -> keepInline (codeName s) live
      (O.X64 O.Call,_,OCode s:_) | keepingCall i -> ["subq $8, %rsp", "call " ++ lbl (keepingLabel (codeName s)), "addq $8, %rsp"]
      (O.X64 O.Call,_,OCode s:_) -> call (codeName s)
      (O.X64 O.Push,[],[v]) -> ["subq $16, %rsp", "movq " ++ reg v ++ ", (%rsp)"]
      (O.X64 O.ApplyN,[_],[OI n]) | n >= 1 && n <= 6 ->
        -- a function value applied to exactly the arguments it still needs
        -- is called directly when it holds at most two captured arguments
        -- and its arity fits the six argument registers: the A64 fast path
        -- (runtime.c fpr_applyN does the same through callf, which is what
        -- every other case still reaches).  pap_t is tid/var, fn @8, arity
        -- @16, nargs @24, captured args @32; captured args go first, then
        -- the pushed ones.  The callee's entry tick charges its own fuel, as
        -- it does when callf calls it; Bounds counts every line printed here.
        let held = [h | h <- [0, 1, 2], n + h <= 6]
            label h = show (5 + h)
            argReg k = ["%rdi", "%rsi", "%rdx", "%rcx", "%r8", "%r9"] !! fromIntegral k
            explicit h = ["movq " ++ show (16 * (n - 1 - i)) ++ "(%rsp), " ++ argReg (h + i) | i <- [0 .. n - 1]]
            captured h = ["movq " ++ show (32 + 8 * k) ++ "(%rax), " ++ argReg k | k <- [0 .. h - 1]]
            arm h = [label h ++ ":", "movq 8(%rax), %r11"] ++ explicit h ++ captured h
              ++ ["subq $8, %rsp", "call *%r11", "addq $8, %rsp", "jmp 2f"]
         in [ "movq " ++ show (16 * n) ++ "(%rsp), %rax", "testq $7, %rax", "jnz 1f",
              "cmpl $9001, (%rax)", "jne 1f",
              "movq 16(%rax), %r10", "subq 24(%rax), %r10", "cmpq $" ++ show n ++ ", %r10", "jne 1f",
              "movq 24(%rax), %r10" ]
            ++ concat [["cmpq $" ++ show h ++ ", %r10", "je " ++ label h ++ "f"] | h <- held]
            ++ ["jmp 1f"]
            ++ concatMap arm held
            ++ ["1:", "movq %rsp, %rdx", "movq $" ++ show n ++ ", %rsi", "movq " ++ show (16 * n) ++ "(%rsp), %rdi"]
            ++ call (Call.runtimeName Call.ApplyEntry) ++ ["2:", "addq $" ++ show (16 * (n + 1)) ++ ", %rsp"]
      (O.X64 O.ApplyN,[_],[OI n]) -> ["movq %rsp, %rdx", "movq $" ++ show n ++ ", %rsi", "movq " ++ show (16 * n) ++ "(%rsp), %rdi"]
        ++ call (Call.runtimeName Call.ApplyEntry) ++ ["addq $" ++ show (16 * (n + 1)) ++ ", %rsp"]
      (O.X64 O.Panic,[],[OAddr s]) -> ("leaq " ++ gsym hart (addressName s) ++ "(%rip), %rdi") : call (Call.runtimeName Call.PanicEntry)
      (O.X64 O.Ret,[],values) | not (null values),length values<=8 -> epilogue ++ ["ret"]
      (O.Common O.TailJump,[],OCode s:_) -> epilogue ++ ["jmp " ++ gsym hart (codeName s)]
      (O.Common O.EntryCheckTick,_,us) -> hartRead ++ stackCheck ++ tickN (tickWeightOf us)
      (O.Common O.EntryCheck,_,_) -> hartRead ++ stackCheck
      (O.Common O.EntryTick,_,us) -> hartRead ++ tickN (tickWeightOf us)
      (O.Common O.TickN,_,us) -> hartRead ++ tickN (tickWeightOf us)
      _ -> error ("X64 render: no form for " ++ show (op,ds,us))
    suffix O.Float64="sd"
    suffix O.Float32="ss"
    -- between two xmm registers the whole register; a word through movq
    fmove a d
      | isXmm a && isXmm d = "movapd " ++ reg a ++ ", " ++ reg d
      | otherwise = "movq " ++ reg a ++ ", " ++ reg d
    isXmm o = take 4 (reg o) == "%xmm"
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
    -- a return the shrink-wrapped save point does not dominate restores
    -- nothing (C9 stage 1); the short form pops the saved frame pointer
    -- from where the prologue stored it (rbp - 16, below the return PC)
    epilogue = (if siAnnotation i == SkipRestores then [] else restores)
      ++ if cfgFrames cfg && not large then ["leaq -16(%rbp), %rsp", "popq %rbp"]
         else ["movq %rbp, %r11", "movq -16(%rbp), %rbp"]
              ++ [if large then "movq -24(%r11), %rsp" else "leaq -8(%r11), %rsp"]
    -- the live-set form of a preserving call: the live caller-saved words
    -- pushed, the live xmm values below them, one alignment word when the
    -- count is even (the body runs at rsp 8 mod 16), then the C entry
    keepInline sym live =
      let gs = [p | Phys p <- live, M.lookup p x64RegisterClasses == Just GPR, Phys p `elem` callerSaved]
          fs = [p | Phys p <- live, M.lookup p x64RegisterClasses == Just FPR]
          pad = if even (length gs + length fs) then 8 else 0
          below = 8 * length fs + pad
       in ["pushq %" ++ g | g <- gs]
          ++ ["subq $" ++ show below ++ ", %rsp" | below > 0]
          ++ ["movq %" ++ f ++ ", " ++ show (8 * k) ++ "(%rsp)" | (k, f) <- zip [0 :: Int ..] fs]
          ++ ["call " ++ gsym hart sym]
          ++ ["movq " ++ show (8 * k) ++ "(%rsp), %" ++ f | (k, f) <- zip [0 :: Int ..] fs]
          ++ ["addq $" ++ show below ++ ", %rsp" | below > 0]
          ++ ["popq %" ++ g | g <- reverse gs]
    -- QOS publishes the host TLS displacement, shared by all hart threads.
    -- The borrow block is {hart, a6, a7}; never use the app's ELF TLS offsets.
    loadCell = loadCellFor hart
    storeCell = storeCellFor hart
    hartRead = loadCell HartPointer "%r10"
    parkArgs save = ["movq " ++ (if save then reg o ++ ", " ++ slot ref else slot ref ++ ", " ++ reg o)
      | (n, o) <- zip [0..] (siDefs i), let ref = FrameRef (entrySlot n)]
    stackCheck =
      ["leaq 8(%rsp), %r11", "subq 456(%r10), %r11", "cmpq 464(%r10), %r11", "jb " ++ lbl (entryLabel i StackReady)]
      ++ parkArgs True ++ call (Call.runtimeName (if Call.runtimeEvent Call.GrowStackSaveEntry `elem` siCalls i then Call.GrowStackSaveEntry else Call.GrowStackEntry))
      ++ ["testq %rax, %rax", "jz " ++ lbl (entryLabel i SameStack), "leaq -8(%rax), %rsp", lbl (entryLabel i SameStack) ++ ":"]
      ++ parkArgs False ++ hartRead ++ [lbl (entryLabel i StackReady) ++ ":"]
    -- The inline bump (Protocol BumpAllocate; runtime/fpr.h bump_slab): r11
    -- is the hart and then the pool, r10 the window's slab, d the new cell's
    -- end and then the cell.  Every test precedes every store; the refill
    -- passes the raw size in r11 and takes the cell in r11 from
    -- fpr_alloc_save_local, which preserves every allocatable register.
    --
    -- A spilled (or dead) cell arrives here in an allocator scratch, and
    -- x64's two scratches are r10 and r11 themselves: the fast path would
    -- overwrite its own slab or hart with the cell.  It then builds the cell
    -- in rax, borrowed around the fast path, and hands it to d once r10 and
    -- r11 are done.  Nothing between the push and either pop touches rsp.
    bump dest c =
      let t = show (bcTotal c)
          cell k = show (8 * (1 + toInteger k))
          w k = show (8 * k)
          refill = lbl (entryLabel i BumpRefill)
          done = lbl (entryLabel i BumpDone)
          borrowed = dest `elem` ["%r10", "%r11"]
          d = if borrowed then "%rax" else dest
       in loadCell HartPointer "%r11"
          ++ ["pushq %rax" | borrowed]
          ++ [ "movq " ++ cell bumpSlabCell ++ "(%r11), %r10",
               "testq %r10, %r10",
               "jz " ++ refill,
               "movq " ++ cell bumpBucketsCell ++ "(%r11), " ++ d,
               "cmpq $0, " ++ show (8 * bcIndex c) ++ "(" ++ d ++ ")",
               "jne " ++ refill,
               "movq " ++ w bumpSlabHp ++ "(%r10), " ++ d,
               "addq $" ++ t ++ ", " ++ d,
               "cmpq " ++ w bumpSlabEnd ++ "(%r10), " ++ d,
               "ja " ++ refill,
               "movq " ++ d ++ ", " ++ w bumpSlabHp ++ "(%r10)",
               "addq $" ++ t ++ ", " ++ cell bumpRegionCell ++ "(%r11)",
               "movq " ++ w bumpSlabOwner ++ "(%r10), %r11",
               "addq $" ++ t ++ ", " ++ w bumpPoolAllocated ++ "(%r11)",
               "subq $" ++ show (bcTotal c - bcPrefix c) ++ ", " ++ d ]
          ++ ["movq $" ++ t ++ ", -16(" ++ d ++ ")" | bcPrefix c == 16]
          ++ ["movq %r10, -8(" ++ d ++ ")"]
          ++ ["movq $0, " ++ show p ++ "(" ++ d ++ ")" | Just p <- [bcPad c]]
          ++ concat [["movq %rax, " ++ dest, "popq %rax"] | borrowed]
          ++ [ "jmp " ++ done,
               refill ++ ":" ]
          ++ ["popq %rax" | borrowed]
          ++ (case bumpRefill pools i of
                Just shared -> ["call " ++ lbl shared]
                Nothing -> ["movq $" ++ show (bcRaw c) ++ ", %r11",
                            "subq $8, %rsp", "call " ++ Call.runtimeName Call.AllocSaveEntry, "addq $8, %rsp",
                            "movq %r11, " ++ dest])
          ++ [done ++ ":"]
    -- the subtraction sets the flags the branch reads (jg after it: the
    -- fuel was above the weight, so what is left is above zero)
    tickN n = ["subq $" ++ show (min n 0x7fffffff) ++ ", (%r10)", "jg " ++ lbl (entryLabel i FuelReady)]
      ++ parkArgs True ++ ["subq $8, %rsp", "call " ++ Call.runtimeName Call.FuelSaveEntry, "addq $8, %rsp"] ++ parkArgs False ++ [lbl (entryLabel i FuelReady) ++ ":"]
