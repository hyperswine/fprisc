{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}

-- Core planning and typed native generation for RV32/RV64, AArch64 and x86-64.
-- All executable functions and column kernels pass through verified typed IR.
-- Static PAPs, constructor constants and module registries have a separate
-- native data owner. Refusals are diagnostics; no text translator is retained.

module Codegen (emitProgram, emitProgramWith, Emission (..), NativeMode (..), NativeBackend (..), Granularity (..), Strict (..), externals, Target (..), rv64, rv32, codegenRev, normArc) where
-- NOTE: emitProgram's `spec` flag gates Vec.map/filter/fold loop
-- specialization. All scalar backends support the shared saved-register
-- convention; x64 uses its XMM shadow bank for s6..s11.

import Modules (ModExport (..))

import Control.Monad (when, unless)
import Control.Monad.State.Strict (evalStateT,get,put,lift)
import Data.Graph (SCC(..), stronglyConnComp)
import Data.Bits (shiftR, (.&.))
import Data.List (stripPrefix, isSuffixOf, foldl', intercalate, isPrefixOf, nub, sort, sortOn)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Text.Read (readMaybe)
import Data.Maybe (fromMaybe, isJust)
import Codegen.IR (Fn (..), Block (..), Width, ArithOp (..), FloatOp (..), simdRegisters)
import qualified Codegen.NativeData as NativeData
import qualified Codegen.Kernel as K
import Codegen.Lower (lowerProgram, Prim (..))
import Codegen.Simplify (simplifyProgram)
import Codegen.Split (splitEntryValues)
import Codegen.Target.Common (Tune (..), noTune, mangleName)
import Codegen.Policy (Profile (..), Policy (..), m2Policy, policyWidth)
import qualified Codegen.Target.X64 as X64
import qualified Codegen.Target.RV as RV
import Codegen.Target.A64 (A64Config (..), HartAccess, NativeFn (..), ObjectFormat (..), emitFnA64)
import Codegen.Target.Common (rodataDirective, stringLabel, stringObjectWidth, boxedFloatObject)
import Codegen.Bounds (Report (..))
import Codegen.Verify (verifyProgram, verifyProgramWidth, simdExprOk)
import Codegen.Dump (dumpFn)
import Codegen.Eval (Outcome (..), Failure (..), Event (..), RV (..), evalProgramWidth)
import KernelKinds (Kind(..), signature)
import Reuse (reuseFresh, reuseProgram, reuseView)
import Workers (workerizeWithSignatures, ScalarSignatures, internalWorker, scalarPrimitives)

import FPRISC (Core (..), Prog, freeVars, occurs)

-- bump on ANY change to emitted code: it keys the build/units cache
-- (a unit's content hash names its SOURCE, not its compilation)
codegenRev :: Int
codegenRev = 105 -- loop regions at the back edge (inline hart clock), call regions (REGIONS-LOOPS-CALLS)

-- Target planning and native selection. The value
-- representation is IDENTICAL on both targets modulo the word size W:
-- header u32 tid | u32 var at 0/4, fields at 8 + W*i, ints (n<<1)|1.
data Target = Target
  { tgtW :: Int,        -- bytes per word (8 / 4)
    tgtName :: String,  -- for the banner comment
    tgtFuel :: Bool,    -- cooperative scheduler instrumentation
    tgtArc :: Bool,     -- explicit field layouts for managed constructors
    tgtWeak :: Bool,    -- a LIBRARY unit: its unqualified globals (the
                        -- constructor stubs, $arc.mainManaged) are emitted
                        -- .weak so a program unit's copies win at link
    tgtSimd :: Bool, -- A64 NEON/x64 SSE2, scalar fallback/tails remain available
    tgtFusion :: Bool, -- differential switch for pipeline passes
    tgtFloatInline :: Bool, -- F64 fast paths; false keeps the C primitives for differential checks
    tgtScalarFast :: Bool, -- normalize Core and enable private scalar workers
    tgtIndexedMemory :: Bool, -- fuse private manual Addr.add/access/release
    tgtScalarWorkers :: Bool,
    tgtFieldWorkers :: Bool,
    tgtPipelineInline :: Bool,
    tgtReuse :: Bool,
    tgtTypedIr :: Maybe String, -- FPR_TYPED_IR: report the typed-IR lowering (M1); changes no emitted code
    tgtHal :: M.Map String Int, -- primitive name -> arity (builtin schemes and
                        -- foreign declarations): a saturated call to one is
                        -- a direct `call fpr_g_<name>_call<n>` (fpr.h FPR_FN)
    tgtPolicy :: Policy, -- the profile the typed-IR lowering states (Codegen.Policy)
    tgtNative :: Maybe NativeMode -- FPR_TYPED_IR_BACKEND: route units through the typed-IR native backend (M2)
  }

-- Diagnostic selection granularity. Every CLI emission requires complete
-- native coverage; a refusal never selects a different generator.
data Granularity
  = WholeUnit -- collect unit-wide refusals before emission
  | PerFunction -- collect each function's selection result
  deriving (Eq, Show)

data Strict = StrictOff | StrictAll | StrictNames [String] deriving (Eq, Show)

data NativeBackend = DirectA64 ObjectFormat HartAccess | DirectX64 ObjectFormat | DirectQX64 | DirectRV Width RV.RVHart deriving (Show)

data NativeMode = NativeMode
  { nmGranularity :: Granularity,
    nmStrict :: Strict,
    nmTargetName :: String,
    nmBackend :: Maybe NativeBackend, -- Nothing: the switch is on but this target has no direct backend yet
    nmForwardParams :: Bool, -- preserve forwarding arguments only on entry slow paths
    nmTune :: Tune, -- the fib experiments (docs/2026-10-22-TYPED-IR-FIB.md)
    nmSplitEntry :: Bool, -- FPR_TYPED_IR_SPLIT_ENTRY: Codegen.Split before selection
    nmSelfLoops :: Bool -- M3: self tail calls as loops in the native backends (FPR_TYPED_IR_SELF_LOOPS, on unless 0)
  }
  deriving (Show)

data Emission = Emission
  { emNotes :: [String],
    emNative :: [String], -- native instructions and their literal pools
    emNativeNames :: [String], -- the functions the native backend emitted
    emScalarFallbacks :: [(String, String)], -- scalar selection refusals, before kernel diagnostics
    emFallbacks :: [(String, String)], -- functions and kernels it did not emit natively, with reasons
    emData :: [String] -- static objects in the selected target syntax
  }

rv64, rv32 :: Target
rv64 = Target {tgtW=8,tgtName="rv64",tgtFuel=True,tgtArc=False,tgtWeak=False,
  tgtSimd=False,tgtFusion=True,tgtFloatInline=True,tgtScalarFast=True,tgtIndexedMemory=True,
  tgtScalarWorkers=True,tgtFieldWorkers=True,tgtPipelineInline=True,tgtReuse=True,
  tgtTypedIr=Nothing,tgtHal=M.empty,tgtPolicy=m2Policy,
  tgtNative=Just (defaultMode (DirectRV (policyWidth m2Policy) RV.HartTp))}
rv32 = rv64 {tgtW=4,tgtName="rv32",tgtFloatInline=False,
  tgtPolicy=m2Policy {polProfile=Rv32},
  tgtNative=Just (defaultMode (DirectRV (policyWidth (m2Policy {polProfile=Rv32})) RV.HartTp))}

defaultMode :: NativeBackend -> NativeMode
defaultMode backend = NativeMode PerFunction StrictAll "native" (Just backend) False noTune False True

-- The typed-IR lowering of M1 (docs/2026-10-20-TYPED-NATIVE-IR-PLAN.md), as a
-- diagnostic report: which functions lower, why the others
-- do not, their dumps (`dump`) and the reference evaluator's answer for
-- `eval:<fn>:<int>...`.  A verifier failure is a compiler error, never a
-- fallback.  Nothing here changes what is emitted.
typedIrNotes :: Maybe String -> Policy -> ScalarSignatures -> M.Map String Int -> M.Map String Prim -> Prog -> Prog -> [String]
typedIrNotes Nothing _ _ _ _ _ _ = []
typedIrNotes (Just mode) policy sigs ext hal prog emitted =
  case verifyProgramWidth (policyWidth policy) lowered >> verifyProgramWidth (policyWidth policy) simplified of
    Left err -> error ("typed-ir: " ++ err)
    Right () ->
      ["typed-ir: coverage " ++ show (M.size simplified) ++ "/" ++ show (M.size emitted) ++ " functions"]
        ++ ["typed-ir: " ++ n ++ " lowered (" ++ show (length (fnBlocks f)) ++ " blocks, " ++ show (sum (map (length . bInstrs) (fnBlocks f))) ++ " instructions"
              ++ maybe "" (\k -> ", " ++ show k ++ " removed by simplification") (M.lookup n removed) ++ ")" | (n, f) <- M.toList simplified]
        ++ ["typed-ir: " ++ n ++ " fallback: " ++ r | (n, r) <- failures]
        ++ (if "dump" `elem` ws then concatMap (map ("typed-ir: | " ++) . lines . dumpFn) (M.elems simplified) else [])
        ++ (if "dumplowered" `elem` ws then concatMap (map ("typed-ir: lowered | " ++) . lines . dumpFn) (M.elems lowered) else [])
        ++ concatMap evalNote ws
  where
    (lowered, failures) = lowerProgram policy sigs prog emitted ext hal
    -- the simplified program is what the backend consumes; the lowered one
    -- is kept beside it as the differential oracle of every evaluation
    (simplified, removed) = either (\e -> error ("typed-ir: " ++ e)) id (simplifyProgram lowered)
    ws = words mode
    evalNote w = case splitOn ':' w of
      ("eval" : fn : args) | Just ns <- mapM readMaybe args ->
        let out = evalProgramWidth (policyWidth policy) simplified fn (map RInt ns)
            out0 = evalProgramWidth (policyWidth policy) lowered fn (map RInt ns)
            shown = "typed-ir: eval " ++ fn ++ concatMap ((' ' :) . show) (ns :: [Integer])
            counts = " (" ++ show (length [() | EvSafepoint _ <- ocEvents out]) ++ " safepoints, " ++ show (length [() | EvCall _ _ <- ocEvents out]) ++ " calls)"
         in if out /= out0
              then error ("typed-ir: simplification changed the evaluation of " ++ shown ++ ":\n  lowered:    " ++ show out0 ++ "\n  simplified: " ++ show out)
              else [ case ocResult out of
                       Right (RInt n) -> shown ++ " = " ++ show n ++ counts
                       Right v -> shown ++ " = " ++ show v ++ counts
                       Left (Trap msg) -> shown ++ " trap: " ++ msg ++ counts
                       Left (Stuck msg) -> shown ++ " stuck: " ++ msg ++ counts ]
      _ -> []
    splitOn c s = case break (== c) s of
      (a, _ : rest) -> a : splitOn c rest
      (a, []) -> [a]

corePrims :: [String]
corePrims = ["+", "-", "*", "/", "==", "!=", "<", ">", "<=", ">=", "strcat", "str", "error", "print", "String.len", "!"]


-- every CVar that is neither local, global, nor core prim: the assumed
-- external symbol set (for reporting the HAL contract)
externals :: M.Map String Int -> Prog -> [String]
externals ext prog = S.toList (S.fromList (concat [go (S.fromList ps) b [] | (_, (ps, b)) <- M.toList prog]))
  where
    -- `env` is a Set and the result an accumulator: a list env made every
    -- variable test cost the number of lets above it (a 16000-let body
    -- spent a quarter of its compile here)
    prims = S.fromList (corePrims ++ map fst scalarPrimitives)
    go env e acc = case e of
      CVar n
        | S.member n env || M.member n prog || M.member n ext || S.member n prims -> acc
        | "$sym." `isPrefixOf` n -> acc -- a linker symbol, not a runtime contract
        | n == "$fuel" -> acc -- an inlined entry's fuel tick (genT)
        | otherwise -> n : acc
      CApp a b -> go env a (go env b acc)
      CLet x a b -> go env a (go (S.insert x env) b acc)
      CIf a b c -> go env a (go env b (go env c acc))
      CMk _ _ fs -> foldr (go env) acc fs
      CTagEq _ _ x -> go env x acc
      CProj _ x -> go env x acc
      CLam ps b -> go (S.union (S.fromList ps) env) b acc
      _ -> acc

-- one specialization request: a Vec.map/filter/fold call site whose
-- element function is statically known and arithmetic-only
data SpecPlan = SpecPlan
  { spOp :: String, -- "map" | "filter" | "fold"
    spFn :: String, -- the element function (top-level supercombinator)
    spScalar :: Bool, -- scalar-Int loop possible (arith closure exists)
    spClosure :: S.Set String, -- fpr_ufn_ bodies this needs
    spSoa :: Maybe ([Int], [String], Core, (Int, Int)), -- fold only: (used cols, params, dualized body, required eltid/elvar)
    spRvv :: Maybe RvvPlan,
    -- Vec.map (f cap) v where f's body (after inlining) is a
    -- record->record multiply-add over the element's columns and the
    -- captured record's fields (the Mat4*Vec4 shape).  Per output
    -- column one tiny unboxed field fn; the loop runs IN PLACE.
    spMv :: Maybe MvPlan,
    -- Accumulator/result float width. Element and capture kinds are
    -- independent in spKinds; primitive opcodes select their own arithmetic.
    spFloat :: Maybe String,
    -- Vec.map (f c1 .. ck) v / Vec.filter (p c1 .. ck) v with k SCALAR
    -- captures: the kernel takes them in a0..a(k-1) ahead of the vector,
    -- Int captures are guarded/untagged once; typed float captures retain
    -- their IEEE bits. Each argument has an independent kind in spKinds.  0 for the capture-free and record-captured plans.
    spCaps :: Int,
    spKinds :: Maybe ([Kind], Kind), -- captures, accumulator/columns, result
    spPipe :: Maybe PipePlan
  }

-- Stage order is execution order; capture indices refer to entry arguments
-- saved in frame slots. Those arguments retain source evaluation order.
data PipePlan = PipePlan
  { pipeStages :: [(String,String,[Int])],
    pipeElement :: Kind,
    pipeAccumulator :: Maybe (Int,Kind)
  } deriving (Show)

data MvPlan = MvPlan
  { mvTid :: (Int, Int), -- required eltid/elvar (spec guard)
    mvN :: Int, -- field/column count (cols 0..n-1, in place)
    mvKinds :: Maybe [([Kind],Kind)],
    mvFields :: [(([Int], [Int]), ([String], Core))] -- per field: ((cap projs, col idxs), (params, dual body))
  }
  deriving (Eq)

data RvvPlan
  = RvvMap String Core -- param name, straight-line body
  | RvvFoldSum -- fold whose fn is \a b -> a + b
  deriving (Eq)


-- Runtime entries for saturated primitive calls and first-class primitive
-- values. Core primitives use fpr_prim_fn_/fpr_prim_obj_; foreign declarations
-- use fpr_g_ with the runtime's C ABI arity limit.
foreignEntries :: Target -> M.Map String Prim
foreignEntries tgt =
  M.union
    (M.fromList [(n, Prim a (Just ("fpr_prim_fn_" ++ mangleName n)) (if n `elem` corePrims then Just ("fpr_prim_obj_" ++ mangleName n) else Nothing)) | (n, a) <- primArities])
    -- Inference introduces layout-aware vector entries and boxed I64
    -- operators after source
    -- declarations have been collected (Infer.applySites). They are not
    -- public source primitives, so tgtHal need not contain them. Preserve
    -- the existing runtime V ABI and any explicitly declared entry.
    (M.fromList [(n, Prim a (if a <= 6 then Just ("fpr_g_" ++ mangleName n ++ "_call" ++ show a) else Nothing) (Just ("fpr_g_" ++ mangleName n)))
                | (n, a) <- M.toList (M.union (tgtHal tgt) (M.fromList ([("Vec.fromListAs", 2), ("Vec.mapAs", 3)]
                     ++ [("I64." ++ op, 2) | op <- ["+", "-", "*", "/", "<", ">", "<=", ">=", "==", "!="]])))])

-- The native backend's selection over a unit's emitted functions: the
-- typed-IR lowering, the verifier (a failure is a compiler error), then
-- direct target selection per function.  A lowering refusal or a selection
-- refusal is a reported fallback; an invalid
-- selection, placement or layout is a compiler error.  Whole-unit
-- granularity turns one fallback into the unit's.
emitNative :: Target -> NativeMode -> S.Set String -> NativeBackend -> Fn -> Either String NativeFn
emitNative tgt nm exps backend = case backend of
  DirectA64 fmt hart -> emitFnA64 (A64Config fmt hart (tgtPolicy tgt) exps (tgtWeak tgt) (nmSelfLoops nm) (nmForwardParams nm) (nmTune nm))
  DirectQX64 -> X64.emitFnX64 (X64.X64Config (tgtPolicy tgt) exps (tgtWeak tgt) (nmSelfLoops nm) (nmForwardParams nm) (nmTune nm) X64.HartBorrow)
  DirectRV width hart -> RV.emitFnRV (RV.RVConfig width (tgtPolicy tgt) hart exps (tgtWeak tgt) (nmSelfLoops nm))
  DirectX64 fmt -> X64.emitFnX64 (X64.X64Config (tgtPolicy tgt) exps (tgtWeak tgt) (nmSelfLoops nm) (nmForwardParams nm) (nmTune nm) (if fmt == MachO then X64.HartTlvMachO else X64.HartTls))

nativeSelect :: Target -> Bool -> NativeMode -> ScalarSignatures -> M.Map String Int -> S.Set String -> Prog -> Prog -> ([(String, SpecPlan)], M.Map String NativeFn, [(String, String)], [String])
nativeSelect tgt spec nm sigs ext exps prog emitted =
  case verifyProgramWidth (policyWidth (tgtPolicy tgt)) lowered0 >> verifyProgramWidth (policyWidth (tgtPolicy tgt)) lowered of
    Left err -> error ("typed-ir: " ++ err)
    Right () -> case nmBackend nm of
      Nothing -> ([], M.empty, [(n, "no typed-IR native backend for " ++ nmTargetName nm) | n <- M.keys emitted], [])
      Just backend ->
        let emit = emitNative tgt nm exps backend
            results = [(n, emit f) | (n, f) <- M.toList lowered]
            errors = [n ++ ": " ++ e | (n, Left e) <- results, "compiler error: " `isPrefixOf` e]
            refusals = [(n, e) | (n, Left e) <- results, not ("compiler error: " `isPrefixOf` e)]
            accepted = M.fromList [(n, nf) | (n, Right nf) <- results]
            declined = failures ++ refusals
            nativeNote nf = "typed-ir-backend: " ++ nfName nf ++ " native (frame " ++ frameOf nf ++ ", native-insns-v1 segmax=" ++ bound (rSegMax (nfReport nf)) ++ " exittail=" ++ bound (rExitTail (nfReport nf)) ++ " ccalls=" ++ show (rCCalls (nfReport nf)) ++ ")"
            -- the header's layout and allocation facts: `frame=N saved=... values=... spills=...` (M3)
            frameOf nf = case dropWhile (not . isPrefixOf "frame=") (words (head (nfLines nf))) of (f : rest) -> unwords (drop 6 f : rest); [] -> "?"
            bound = maybe "UNBOUNDED" show
            unbounded = [n | polFuel (tgtPolicy tgt), (n, nf) <- M.toList accepted, rSegMax (nfReport nf) == Nothing]
         in if not (null errors)
              then error ("typed-ir backend: " ++ intercalate "; " errors)
              else case nmGranularity nm of
                PerFunction ->
                  ( kernelsOf accepted, accepted,
                    declined ++ [(n, "native-insns-v1 is UNBOUNDED: a cycle without a safepoint") | n <- unbounded],
                    ("typed-ir-backend: native " ++ show (M.size accepted) ++ "/" ++ show (M.size emitted) ++ " functions (per-function)")
                      : map nativeNote (M.elems accepted) ++ ["typed-ir-backend: " ++ n ++ " fallback: " ++ r | (n, r) <- declined]
                  )
                WholeUnit
                  | null declined && null unbounded ->
                      ( kernelsOf accepted, accepted, [],
                        ("typed-ir-backend: native " ++ show (M.size accepted) ++ "/" ++ show (M.size emitted) ++ " functions (whole unit)")
                          : map nativeNote (M.elems accepted)
                      )
                  | otherwise ->
                      let reasons = declined ++ [(n, "native-insns-v1 is UNBOUNDED: a cycle without a safepoint") | n <- unbounded]
                          why = "whole-unit fallback: " ++ show (length reasons) ++ " of " ++ show (M.size emitted) ++ " functions declined"
                       in ( [], M.empty,
                            reasons ++ [(n, why) | n <- M.keys emitted, n `notElem` map fst reasons],
                            ("typed-ir-backend: native 0/" ++ show (M.size emitted) ++ " functions (" ++ why ++ ")")
                              : ["typed-ir-backend: " ++ n ++ " fallback: " ++ r | (n, r) <- reasons]
                          )
  where
    (lowered0, loweringFailures) = lowerProgram (tgtPolicy tgt) sigs lookupProg eligible ext (M.union kernelPrims (foreignEntries tgt))
    -- The same Core equivalences the ownership-aware generator uses,
    -- before typed lowering. In particular a nullary constructor remains
    -- an immortal object, while effectful nullary definitions remain calls.
    normalizedArc (ps,b) = (ps,normIn (S.fromList ps) b)
    lookupProg = if tgtArc tgt then M.map normalizedArc prog else prog
    -- The direct backend must not silently replace an enabled specialized
    -- column loop with generic per-element apply.  A specialisation site is
    -- rewritten into a native kernel call using the generated-code ABI.
    -- Both callers and kernels lower independently to typed CFGs;
    -- (docs/2026-10-22-TYPED-IR-KERNELS.md).  Uses the shared planner gates.
    rewritten = if spec then M.map (\(ps, b) -> let (b', ks) = kernelSites (S.fromList ps) b in ((ps, b'), ks)) emitted else M.map (\d -> (d, [])) emitted
    eligible = M.map prepare (M.map fst rewritten)
    prepare def@(ps,b)
      | tgtArc tgt = normalizedArc def
      | otherwise = (ps, if tgtIndexedMemory tgt && not (tgtFuel tgt || tgtArc tgt)
          then indexedMemory (M.keysSet prog `S.union` M.keysSet ext) (S.fromList ps) b else b)
    failures = loweringFailures
    kernelPrims = M.fromList [(kernelName sym, Prim (length args) (Just sym) Nothing) | (_, ks) <- M.elems rewritten, (sym, _, args) <- ks]
    kernelsOf accepted = M.toList (M.fromList [(sym, plan) | (n, (_, ks)) <- M.toList rewritten, M.member n accepted, (sym, plan, _) <- ks])
    kernelName sym = "$vkernel:" ++ sym
    -- every site, innermost arguments first, in source evaluation order
    kernelSites bound e
      | Just (plan, args) <- vecSpec (tgtFusion tgt) prog (`S.member` bound) e,
        (tgtW tgt == 8 && tgtFloatInline tgt) || not (specUsesFloat prog plan) =
          let sym = specSymbol plan
              (args', ks) = unzip (map (kernelSites bound) args)
           in (foldl CApp (CVar (kernelName sym)) args', concat ks ++ [(sym, plan, args')])
      | otherwise = case e of
          CApp a b -> let (a', ka) = kernelSites bound a; (b', kb) = kernelSites bound b in (CApp a' b', ka ++ kb)
          CLet x a b -> let (a', ka) = kernelSites bound a; (b', kb) = kernelSites (S.insert x bound) b in (CLet x a' b', ka ++ kb)
          CIf c t f -> let (c', kc) = kernelSites bound c; (t', kt) = kernelSites bound t; (f', kf) = kernelSites bound f in (CIf c' t' f', kc ++ kt ++ kf)
          CMk t v fs -> let (fs', ks) = unzip (map (kernelSites bound) fs) in (CMk t v fs', concat ks)
          CTagEq t v x -> let (x', k) = kernelSites bound x in (CTagEq t v x', k)
          CProj i x -> let (x', k) = kernelSites bound x in (CProj i x', k)
          CLam ps b -> let (b', k) = kernelSites (S.union bound (S.fromList ps)) b in (CLam ps b', k)
          _ -> (e, [])
    -- the simplification passes (Codegen.Simplify), each verified; a
    -- failure is a compiler error
    lowered1 = either (\e -> error ("typed-ir: " ++ e)) fst (simplifyProgram lowered0)
    -- FPR_TYPED_IR_SPLIT_ENTRY: verified like the simplification (a refusal is a compiler error)
    lowered = if nmSplitEntry nm then M.map splitEntryValues lowered1 else lowered1

emitProgram :: Target -> Bool -> Bool -> [ModExport] -> M.Map String Int -> S.Set String -> S.Set String -> Prog -> (String, [String])
emitProgram tgt rvv spec exports ext exps elide prog0 =
  let e = emitProgramWith tgt rvv spec exports ext exps elide prog0
   in if null (emFallbacks e) then (unlines (emNative e ++ emData e), emNotes e)
      else error ("typed-ir: native emission refused: "++show (emFallbacks e))

emitProgramWith :: Target -> Bool -> Bool -> [ModExport] -> M.Map String Int -> S.Set String -> S.Set String -> Prog -> Emission
emitProgramWith tgt rvv spec exports ext exps elide prog0 =
  let (fused,fnotes) = if tgtFusion tgt then fuseVecFix prog0 else (prog0,[])
      enable = tgtW tgt == 8 && tgtFuel tgt && tgtScalarFast tgt && not (tgtArc tgt)
      (workers,wnotes,workerSigs) = workerizeWithSignatures (enable && tgtFieldWorkers tgt) (enable && tgtScalarWorkers tgt) fused
      reuseEnabled = tgtReuse tgt && tgtW tgt==8 && tgtFuel tgt && not (tgtArc tgt)
      normalized = M.map (\(ps,b)->(ps,if tgtScalarFast tgt then normIn (S.fromList ps) b else b)) workers
      (prog,rnotes) = if reuseEnabled then reuseProgram elide normalized else (workers,[])
      emitted = M.withoutKeys prog elide
      nm = fromMaybe (error "typed-ir: no native backend selected") (tgtNative tgt)
      (requests,nativeFns,failures,notes) = nativeSelect tgt spec nm workerSigs ext exps prog emitted
      (kernels,kernelFailures,kernelNotes) = emitSpecs tgt rvv ext exps prog requests
      allFns = M.elems nativeFns ++ kernels
      strings = M.elems (M.fromList [(stringLabel str,str) | nf <- allFns,str <- nfStrings nf])
      floats = S.toList (S.fromList (concatMap nfBoxedFloats allFns))
      format = case nmBackend nm of Just (DirectA64 fmt _) -> fmt; Just (DirectX64 fmt) -> fmt; _ -> ELF
      nativeText = RV.rvvPreamble rvv ++ ["    .text","    .balign 4",""] ++ concatMap nfLines allFns
        ++ (if null strings then [] else rodataDirective format : concatMap (stringObjectWidth (policyWidth (tgtPolicy tgt)) format) strings)
        ++ (if null floats then [] else rodataDirective format : concatMap (uncurry boxedFloatObject) floats)
      dat = NativeData.emitStaticData format (policyWidth (tgtPolicy tgt)) (tgtArc tgt) (tgtWeak tgt) exports exps emitted
              (S.fromList (concatMap nfNullaries allFns))
   in Emission
      { emNotes = fnotes ++ wnotes ++ rnotes ++ concat [declines tgt spec prog fn b | (fn,(_,b)) <- M.toList emitted]
          ++ kernelNotes ++ typedIrNotes (tgtTypedIr tgt) (tgtPolicy tgt) workerSigs ext (foreignEntries tgt) prog emitted ++ notes,
        emNative = nativeText,
        emNativeNames = M.keys nativeFns,
        emScalarFallbacks = failures,
        emFallbacks = failures ++ kernelFailures,
        emData = dat }

normArc :: Core -> Core
normArc = normIn S.empty

-- `ps`: the function's parameters.  A variable is LOCAL when it is a
-- parameter or bound inside the body; only a local is a pure value.  A
-- global of arity 0 is evaluated where it is named (base code: a CAF
-- that prints), so an alias of one is never substituted -- that would
-- drop the evaluation, or repeat it at every use.
normIn :: S.Set String -> Core -> Core
normIn ps body0 = go M.empty body0
  where
    locals = S.union ps (S.fromList (binders body0))
    -- `env`: the substitutions pending (an Int literal or an alias for a
    -- let-bound name), applied as the walk reaches each variable.  ONE
    -- pass: substituting with substE and re-walking the result cost a
    -- whole traversal per let, and a let per element made an 8000-
    -- element list literal take 86 s to compile (quadratic); the free-
    -- variable tests use `occurs`, which stops at the first hit, where
    -- `freeVars` built the whole list and filtered it by the parameter
    -- list at every lambda (a 400-parameter function took 67 s: cubic).
    go env e = case e of
      CLet x a b -> letChain env (counts e) [] x a b -- rw is applied inside, per let
      _ -> rw (descend env e)
    descend env = \case
      CVar n -> fromMaybe (CVar n) (M.lookup n env)
      CApp a b -> CApp (go env a) (go env b)
      CLam qs b -> CLam qs (go (foldr M.delete env qs) b)
      CLet x a b -> letChain env (counts (CLet x a b)) [] x a b
      CIf c t e -> CIf (go env c) (go env t) (go env e)
      CMk t v fs -> CMk t v (map (go env) fs)
      CTagEq t v x -> CTagEq t v (go env x)
      CProj i x -> CProj i (go env x)
      e -> e
    -- A chain of lets (every block is one) is walked top-down ONCE.
    -- Each let's right-hand side is normalized under the substitutions
    -- so far; the let then vanishes (an Int, or an alias of a local),
    -- or stays as a PENDING binding.  A pending binding used only by
    -- the next let's right-hand side sinks into it (the rule
    -- `let x = a in let y = b in r -> let y = (let x = a in b) in r`),
    -- which the nest of earlier sinks may repeat: `absorb` pops the
    -- pending bindings from the innermost while each sinks.  Applying
    -- the sink rule per let, bottom-up, re-descended the nest the inner
    -- sinks had built at every level: cubic, 114 s for a 4000-statement
    -- block.  "Used later" is answered from `left`, the raw occurrence
    -- counts of every variable in what remains of the chain, kept as
    -- the walk passes each right-hand side (a scan of the remainder per
    -- let was still quadratic); an alias that vanishes hands its
    -- remaining uses to the variable it named.
    letChain env left pend x a b =
      let a' = go env a
          here = counts a
          left1 = M.differenceWith (\l h -> Just (l - h)) left here
       in case a' of
            -- let x = <int> in b  ->  b[x := <int>]
            CInt _ -> chainOn (M.insert x a' env) left1 pend b
            -- let x = y in b  ->  b[x := y]: a local alias, when nothing
            -- in the body rebinds y (so the substitution is not captured)
            CVar y | S.member y locals, not (rebinds y b) ->
              chainOn (M.insert x a' env) (M.insertWith (+) y (M.findWithDefault 0 x left1) left1) pend b
            _ -> let (n, pend') = absorb env left1 here pend a' in chainOn (M.delete x env) left1 ((x, n) : pend') b
    chainOn env left pend b = case b of
      CLet y c rest -> letChain env left pend y c rest
      _ -> foldl (\acc (x, a') -> rw (CLet x a' acc)) (go env b) pend
    absorb env left here pend n = case pend of
      (y, c) : more | usedHere env here y, M.findWithDefault 0 y left == 0 -> absorb env left here more (rw (CLet y c n))
      _ -> (n, pend)
    -- is y used in the right-hand side just passed, by name or through
    -- an alias that vanished into it?
    usedHere env here y = M.member y here || any (\v -> M.lookup v env == Just (CVar y)) (M.keys here)
    -- raw occurrence counts of the variables in e (accumulator form:
    -- `concatMap` would copy the deep last child at every level)
    counts e = M.fromListWith (+) [(v, 1 :: Int) | v <- varsInto e []]
    varsInto e acc = case e of
      CVar n -> n : acc
      CApp a b -> varsInto a (varsInto b acc)
      CLam _ b -> varsInto b acc
      CLet _ a b -> varsInto a (varsInto b acc)
      CIf c t f -> varsInto c (varsInto t (varsInto f acc))
      CMk _ _ fs -> foldr varsInto acc fs
      CTagEq _ _ x -> varsInto x acc
      CProj _ x -> varsInto x acc
      _ -> acc
    -- accumulator form, like varsInto (the `++` form copied the deep
    -- part of a nest at every level)
    binders e = bindersInto e []
    bindersInto e acc = case e of
      CLet x a b -> x : bindersInto a (bindersInto b acc)
      CLam qs b -> qs ++ bindersInto b acc
      CApp a b -> bindersInto a (bindersInto b acc)
      CIf c t f -> bindersInto c (bindersInto t (bindersInto f acc))
      CMk _ _ fs -> foldr bindersInto acc fs
      CTagEq _ _ x -> bindersInto x acc
      CProj _ x -> bindersInto x acc
      _ -> acc
    rebinds y = \case
      CLet x a b -> x == y || rebinds y a || rebinds y b
      CLam qs b -> y `elem` qs || rebinds y b
      CApp a b -> rebinds y a || rebinds y b
      CIf c t e -> rebinds y c || rebinds y t || rebinds y e
      CMk _ _ fs -> any (rebinds y) fs
      CTagEq _ _ x -> rebinds y x
      CProj _ x -> rebinds y x
      _ -> False
    rw = \case
      CLet x a (CVar y) | x == y -> a
      CLet x a (CIf (CTagEq t v (CVar y)) th el)
        | x == y, not (occurs x th), not (occurs x el) -> rw (CIf (CTagEq t v a) th el)
      CLet x a (CIf (CVar y) th el)
        | x == y, not (occurs x th), not (occurs x el) -> rw (CIf a th el)
      -- (a binding used only by the next binding sinks into it: the
      -- same evaluation order, a, then b, then the rest -- done by
      -- letChain over the whole chain, not here)
      CIf (CLet x a c) th el
        | not (occurs x th), not (occurs x el) -> rw (CLet x a (rw (CIf c th el)))
      e -> e

-- Manual Builtin only: a private address used for one volatile access and
-- immediately released has no observable identity. Keep the base/offset
-- evaluation order, access checks and result representation, but avoid the
-- temporary box. No alias, intervening effect, shadowed primitive, retained
-- address or effectful write argument is accepted by this deliberately small
-- pattern. The release still yields Unit when its result is used.
indexedMemory :: S.Set String -> S.Set String -> Core -> Core
indexedMemory globals initial body = go initial body
  where
    -- One occurrence ledger for the function, not a scan of the remaining
    -- let chain per candidate. Reused/shadowed names conservatively decline.
    uses = M.fromListWith (+) [(n, 1 :: Int) | n <- vars body []]
    vars e acc = case e of
      CVar n -> n : acc
      CApp a b -> vars a (vars b acc)
      CLet _ a b -> vars a (vars b acc)
      CIf c t f -> vars c (vars t (vars f acc))
      CLam _ b -> vars b acc
      CMk _ _ fs -> foldr vars acc fs
      CTagEq _ _ x -> vars x acc
      CProj _ x -> vars x acc
      _ -> acc
    primitive bound h = S.notMember h bound && S.notMember h globals
    call h = foldl CApp (CVar h)
    access h = lookup h [("Mem." ++ op ++ width, "$mem." ++ op ++ width ++ "at")
                        | op <- ["read", "write"], width <- ["8", "16", "32", "Word"]]
    release bound addr e = case e of
      CLet r a rest | spineOf a == (CVar "Rc.release", [CVar addr]),
                      primitive bound "Rc.release", r /= addr ->
        Just (CLet r (CMk 0 0 []) rest)
      _ | spineOf e == (CVar "Rc.release", [CVar addr]), primitive bound "Rc.release" -> Just (CMk 0 0 [])
      _ -> Nothing
    pureArg bound (CVar n) = S.member n bound
    pureArg _ (CInt _) = True
    pureArg _ _ = False
    fuse bound e = case e of
      CLet addr a (CLet v mem rest)
        | (CVar "Addr.add", [base, offset]) <- spineOf a,
          primitive bound "Addr.add", addr /= v,
          M.findWithDefault 0 addr uses == 2,
          (CVar h, args) <- spineOf mem, primitive (S.insert addr bound) h,
          Just fused <- access h,
          CVar p : values <- args, p == addr,
          (null values && "Mem.read" `isPrefixOf` h)
            || (length values == 1 && "Mem.write" `isPrefixOf` h && all (pureArg bound) values),
          Just tail' <- release (S.insert v (S.insert addr bound)) addr rest ->
            CLet v (call fused (base : offset : values)) tail'
      _ -> e
    go bound e = fuse bound $ case e of
      CLet x a b -> CLet x (go bound a) (go (S.insert x bound) b)
      CApp a b -> CApp (go bound a) (go bound b)
      CIf c t f -> CIf (go bound c) (go bound t) (go bound f)
      CLam ps b -> CLam ps (go (S.union bound (S.fromList ps)) b)
      CMk t v fs -> CMk t v (map (go bound) fs)
      CTagEq t v x -> CTagEq t v (go bound x)
      CProj k x -> CProj k (go bound x)
      _ -> e

-- hart argument-spill cells (fpr.h fpr_hart_t.argspill): cell j at
-- W*(1+j)(tp) -- fuel is 0(tp), the cells start one word past it
-- (pinned by the _Static_assert in fpr.h)
spillCells :: Int
spillCells = 56 -- must equal fpr.h FPR_ARGSPILL (arity ceiling 8+56=64)

-- core prims the desugarer can emit, with their arities (the C symbols
-- fpr_prim_fn_* are exported by runtime.c precisely for direct calls)
primArities :: [(String, Int)]
primArities = scalarPrimitives ++
  [ ("+", 2), ("-", 2), ("*", 2), ("/", 2),
    ("==", 2), ("!=", 2), ("<", 2), (">", 2), ("<=", 2), (">=", 2),
    ("strcat", 2), ("str", 1), ("error", 1),
    ("print", 1), ("String.len", 1), ("!", 2),
    -- floats: raw-bits payloads; every op is a C prim the type-directed
    -- site resolution routes to (Infer.hs).  f64frombits is the
    -- literal encoding (a tagged V cannot carry 64 raw bits).
    ("f64frombits", 2), ("f32frombits", 1)
  ]
  ++ [ ("F" ++ w ++ "." ++ op, 2)
       | w <- ["64", "32"], op <- ["+", "-", "*", "/", "<", ">", "<=", ">=", "==", "!="] ]
  ++ [ ("F" ++ w ++ "." ++ f, 1)
       | w <- ["64", "32"],
         f <- ["str", "sqrt", "ofInt", "toInt",
               "log", "log2", "exp", "sin", "cos"] ]
  ++ [ ("F" ++ w ++ ".pow", 2) | w <- ["64", "32"] ]
  ++ [("F64.ofF32", 1), ("F32.ofF64", 1)]
  ++ [("$mem." ++ op ++ width ++ "at", if op == "read" then 2 else 3)
       | op <- ["read", "write"], width <- ["8", "16", "32", "Word"]]

-- the full application spine: (head expr, args left-to-right)
spineOf :: Core -> (Core, [Core])
spineOf = go []
  where
    go acc (CApp f a) = go (a : acc) f
    go acc f = (f, acc)

declines :: Target -> Bool -> Prog -> String -> Core -> [String]
declines tgt spec prog owner = goD S.empty
  where
    goD bound e =
      here ++ case e of
        CApp a b -> goD bound a ++ goD bound b
        CLet x a b -> goD bound a ++ goD (S.insert x bound) b
        CIf c t f -> concatMap (goD bound) [c, t, f]
        CMk _ _ fs -> concatMap (goD bound) fs
        CTagEq _ _ x -> goD bound x
        CProj _ x -> goD bound x
        CLam ps b -> goD (foldr S.insert bound ps) b
        _ -> []
      where
        here = case spineOf e of
          (CVar op, args)
            | Just n <- lookup op [("Vec.map", 2), ("Vec.mapAs", 3), ("Vec.filter", 2), ("Vec.fold", 3)],
              length args == n, -- FULL spines only: a partial spine is
              -- just the inside of the real call, not a site
              fe : _ <- (if op == "Vec.mapAs" then drop 1 args else args),
              (CVar f, caps) <- spineOf fe,
              M.member f prog,
              not (S.member f bound) ->
                case vecSpec (tgtFusion tgt) prog (`S.member` bound) e of
                  Nothing ->
                    [ "vec note: " ++ op ++ " over `" ++ f ++ "`" ++ capsNote caps ++ " (in " ++ owner
                        ++ ") runs in the GENERIC apply tier -- " ++ why op f caps
                    ]
                  Just (plan,_)
                    | (tgtW tgt /= 8 || not (tgtFloatInline tgt)), specUsesFloat prog plan ->
                        [ "vec note: " ++ op ++ " over `" ++ f ++ "` (in " ++ owner
                            ++ ") uses generic C callbacks in software-float mode"
                        ]
                    | not spec ->
                        [ "vec note: " ++ op ++ " over `" ++ f ++ "` (in " ++ owner
                            ++ ") runs in the GENERIC apply tier -- a column loop"
                            ++ " accepts this site, but the specialization tier is"
                            ++ " OFF on this target"
                        ]
                    | otherwise -> []
          _ -> []
        returnsRecord g = case M.lookup g prog of
          Just (_, b) -> endsInRecord b
          Nothing -> False
        endsInRecord = \case
          CLet _ _ b -> endsInRecord b
          CIf _ t f -> endsInRecord t || endsInRecord f
          CMk _ _ (_ : _) -> True
          _ -> False
        capsNote [] = ""
        capsNote cs = " with " ++ show (length cs) ++ " capture" ++ (if length cs == 1 then "" else "s")
        why op f caps
          | op == "Vec.map", returnsRecord f, length caps > 1 =
              "a record map's column kernel takes ONE capture: a record of the scalars it needs, whose fields the element fn projects"
          | op == "Vec.map", returnsRecord f =
              "a record map's fields did not dualize: they may use literals, + - * / and comparisons, if and let over the element's fields and a captured record's fields (a capture used whole escapes); a call the dualizer could not inline, a top-level constant or a nested record declines"
          | arithClosure prog [f] == Nothing =
              "the element fn is not a closed arithmetic/record dual, so no column loop specializes this site"
          | not (null caps), length caps + 1 > 8 = "the element fn takes " ++ show (length caps) ++ " captures; the kernels pass at most 7 ahead of the element"
          | otherwise = "callback input/output kinds or layout do not admit this column kernel"


-- run fusion to a FIXPOINT: a 3+ chain's outer pair fuses in round 1,
-- the composite-over-inner pair in round 2, and so on until no pair is
-- left.  Each round's composites get a round-tagged name so rounds
-- never collide; the plan-level machinery already composes through
-- composites (soaDualMap0 recognizes the f(g el) body shape
-- recursively), so a fully collapsed chain still dualizes.  The bound
-- is a backstop, not a budget: a chain of length n needs n-1 rounds
-- and real programs stop far short of it.
fuseVecFix :: Prog -> (Prog, [String])
fuseVecFix prog = go (0 :: Int) (nestPipelines prog)
  where
    go r p
      | r >= 16 = (p, [])
      | otherwise =
          let (p', notes) = fuseVec r p
           in if M.size p' == M.size p then (p', nub notes) else let (p'', more) = go (r + 1) p' in (p'', nub (notes ++ more))

-- EFFECT ORDER (docs/2026-10-03-FUSION-EFFECT-ORDER.md).  Two
-- materializing maps run the first over EVERY element before the second
-- starts; a fused pass interleaves them per element.  That is only
-- unobservable when neither element function can be observed running:
-- no I/O, no sends, no mutation, and no FAILURE either, since a panic in
-- the first map on element 2 must come before any work of the second
-- map on element 1.  `fusionSafe` is that judgement: the function and
-- every known callee use only locals, literals, constructors, tag tests,
-- projections, if/let, the arithmetic/comparison/logic primitives and
-- the fuel tick -- Int + - * trap on overflow since 2026-10-12, and the
-- 2026-10-13 relaxation lets a fused pair raise that one trap out of
-- order (safePrims below).  Division is excluded (it traps), as is
-- every other primitive, every call through a parameter, and every
-- partial application.  Declined pairs are reported, never silent.
fusionSafe :: Prog -> String -> Bool
fusionSafe prog f = fusionUnsafeReason prog f == Nothing

-- the first construct that makes a function observable, if any
fusionUnsafeReason :: Prog -> String -> Maybe String
fusionUnsafeReason prog = go S.empty
  where
    go seen n
      | S.member n seen = Nothing
      | otherwise = case M.lookup n prog of
          Nothing -> Just ("`" ++ n ++ "` is not a known function")
          Just (ps, body) -> body' (S.insert n seen) (S.fromList ps) body
    body' _ _ e | Just _ <- floatLitBits e = Nothing
    body' seen env e = case spineOf e of
      (CVar h, args@(_ : _))
        | h `elem` safePrims, Just ar <- lookup h primArities, length args == ar -> firstJust (map (body' seen env) args)
        | h `elem` safePrims -> Just ("a partial application of `" ++ h ++ "`")
        | h == "$fuel" -> Nothing
        | S.member h env -> Just ("a call through the parameter `" ++ h ++ "` (unknown function)")
        | Just (ps, _) <- M.lookup h prog, length ps == length args -> firstJust (map (body' seen env) args ++ [go seen h])
        | Just _ <- M.lookup h prog -> Just ("a partial application of `" ++ h ++ "`")
        | otherwise -> Just ("the primitive `" ++ h ++ "`")
      _ -> case e of
        CVar v | S.member v env -> Nothing
        CVar g | Just (ps, _) <- M.lookup g prog, null ps -> go seen g -- a CAF
        CVar g -> Just ("the function value `" ++ g ++ "`")
        CInt _ -> Nothing
        CStr _ -> Nothing
        CMk _ _ fs -> firstJust (map (body' seen env) fs)
        CTagEq _ _ x -> body' seen env x
        CProj _ x -> body' seen env x
        CIf c t f -> firstJust (map (body' seen env) [c, t, f])
        CLet x a b -> firstJust [body' seen env a, body' seen (S.insert x env) b]
        CLam ps b -> body' seen (S.union (S.fromList ps) env) b
        CErr _ -> Nothing -- an exhaustiveness-proven dead arm
        _ -> Just "an unrecognized construct"
    firstJust xs = case [r | Just r <- xs] of
      (r : _) -> Just r
      [] -> Nothing
    -- cannot be OBSERVED: everything in the Int/F64/F32 arithmetic tiers
    -- except division, plus comparison and logic.  Int + - * trap on
    -- overflow (docs/2026-10-12-INT-OVERFLOW.md); a fused pair may then
    -- panic on an earlier element, or in the other function, than the
    -- two passes would -- the ONE reordering fusion is allowed, by the
    -- relaxation of 2026-10-13 (docs/2026-10-03-FUSION-EFFECT-ORDER.md):
    -- the program still fail-stops with an Int overflow, and the pair
    -- was its own two passes otherwise.  Division stays out: a zero
    -- divisor is a different failure, and the line is kept narrow.
    safePrims =
      [op | op <- uPrims, op /= "/"]
        ++ [op | w <- ["64", "32"], op <- fPrimsOf w, not ("/" `isSuffixOf` op) && op /= "F" ++ w ++ "./"]
        ++ ["and", "or", "not", "and2", "or2"]

fuseVec :: Int -> Prog -> (Prog, [String])
fuseVec round' prog = (M.union extras (M.map (\(ps,b) -> (ps,rewrite b)) prog), nub notes)
  where
    apps = foldl' CApp
    opAt e = case spineOf e of
      (CVar op,[fe,v]) | op `elem` ["Vec.map","Vec.filter"],
        (CVar f,caps) <- spineOf fe,
        Just (ps,_) <- M.lookup f prog, length ps == length caps + 1 -> Just ((op,f,caps),v)
      _ -> Nothing
    -- Moving capture evaluation across a pass requires the same effect/trap
    -- judgement as moving callbacks. Locals and pure expressions are safe.
    capSafe e = fusionSafe (M.insert "$capture" (locals,e) prog) "$capture"
      where locals = [n | n <- freeVars e, M.notMember n prog, n `notElem` prims]
            prims = map fst primArities
    fusedAt e = do
      ((op,f,fc),v1) <- opAt e
      ((op',g,gc),v) <- opAt v1
      if op == op' && fusionSafe prog f && fusionSafe prog g && all capSafe (fc++gc)
         && length fc + length gc <= 7 then Just () else Nothing
      pure ((op,f,g,length fc,length gc),fc++gc,v)
    -- accumulator form: `e : concatMap walk (children e)` ended in
    -- `walk lastChild ++ []`, which copies the deep child's whole list at
    -- every level of a let chain or a list literal (quadratic)
    walk e0 = walkInto e0 []
    walkInto e0 acc = let e = seeLet e0 in e : foldr walkInto acc (children e)
    children (CApp a b) = [a,b]
    children (CLet _ a b) = [a,b]
    children (CIf c a b) = [c,a,b]
    children (CMk _ _ fs) = fs
    children (CTagEq _ _ x) = [x]
    children (CProj _ x) = [x]
    children (CLam _ x) = [x]
    children _ = []
    nodes = concat [walk b | (_,b) <- M.elems prog]
    keys = S.toList (S.fromList [k | e <- nodes, Just (k,_,_) <- [fusedAt e]])
    names = M.fromList [(k,"_vfuse_" ++ show round' ++ "_" ++ show i) | (i,k) <- zip [0::Int ..] keys]
    extras = M.fromList [(names M.! k,composite k) | k <- keys]
    composite (op,f,g,nf,ng) =
      let ps = ["$fc" ++ show i | i <- [0..nf+ng-1]]
          x = CVar "$fe"
          outer = apps (CVar f) (map CVar (take nf ps) ++ [x])
          inner = apps (CVar g) (map CVar (drop nf ps) ++ [x])
          body | op == "Vec.map" = apps (CVar f) (map CVar (take nf ps) ++ [inner])
               | otherwise = CIf (CTagEq 1 1 inner) outer (CMk 1 0 [])
       in (ps ++ ["$fe"],body)
    notes = ["vec note: " ++ op ++ " `" ++ f ++ "` after " ++ op ++ " `" ++ g
               ++ "` is NOT fused: " ++ why ++ " -- the two passes run in order, each over the whole vector"
            | e <- nodes ++ concatMap letCandidates nodes, Just ((op,f,fc),v) <- [opAt e], Just ((op',g,gc),_) <- [opAt v], op == op',
              Nothing <- [fusedAt e],
              let why = case [(n,r) | (n,Just r) <- [(g,fusionUnsafeReason prog g),(f,fusionUnsafeReason prog f)]] of
                          (n,r):_ -> "`" ++ n ++ "` uses " ++ r
                          [] | not (all capSafe (fc++gc)) -> "capture evaluation can have effects or fail"
                             | otherwise -> "combined capture budget exceeded"]
    rewrite e0 = let e = seeLet e0 in case fusedAt e of
      Just (key,caps,v) -> let (op,_,_,_,_) = key
                          in apps (CVar op) [apps (CVar (names M.! key)) (map rewrite caps),rewrite v]
      _ -> case e of
        CApp a b -> CApp (rewrite a) (rewrite b)
        CLet x a b -> CLet x (rewrite a) (rewrite b)
        CIf c a b -> CIf (rewrite c) (rewrite a) (rewrite b)
        CMk t v fs -> CMk t v (map rewrite fs)
        CTagEq t v x -> CTagEq t v (rewrite x)
        CProj k x -> CProj k (rewrite x)
        CLam ps x -> CLam ps (rewrite x)
        _ -> e
    seeLet (CLet x ve b) | Just ((op,_,_),_) <- opAt ve =
      let next m = case opAt m of
            Just ((op',_,caps),CVar v) -> op == op' && v == x && all (not . elem x . freeVars) caps &&
              case fusedAt (plug m) of Just _ -> True; Nothing -> False
            _ -> False
          plug m = case spineOf m of (CVar h,[fe,_]) -> apps (CVar h) [fe,ve]; _ -> m
       in case b of
            _ | next b -> seeLet (plug b)
            CLet y inner rest | next inner, x `notElem` freeVars rest -> seeLet (CLet y (plug inner) rest)
            _ -> CLet x ve b
    seeLet e = e
    letCandidates (CLet x ve b) | Just ((op,_,_),_) <- opAt ve =
      [apps (CVar op) [fe,ve] | m <- b : (case b of CLet _ inner rest | x `notElem` freeVars rest -> [inner]; _ -> []),
         (CVar op',[fe,CVar v]) <- [spineOf m], op == op', v == x]
    letCandidates _ = []

-- A bounded, same-element-kind scalar pipeline. Entry arguments are flattened
-- outermost-first, just like source evaluation; stages execute innermost-first.
-- Captures and seed must already be values, so let nesting cannot move effects.
pipelinePlan :: Prog -> (String -> Bool) -> Core -> Maybe (SpecPlan,[Core])
pipelinePlan prog local expr = do
  (stages,args,kinds,acc,vector) <- collect True 0 expr
  -- Start with genuinely mixed, filtering pipelines. Keep map-only chains
  -- (including map/fold) on their existing SIMD/worker paths.
  let ops=[op | (op,_,_,_)<-stages]
  if length stages < 2 || length stages > 16 || length args > 7 ||
     "filter" `notElem` ops || not (any (`elem` ["map","fold"]) ops)
    then Nothing else Just ()
  let elems=[last ks | (_,_,_,ks)<-stages]
  element <- case elems of k:rest | k/=KB && all (==k) rest -> Just k; _ -> Nothing
  let names=[f | (_,f,_,_)<-stages]
  cl <- arithClosure prog names
  if S.size cl > 64 || not (all (fusionSafe prog) names) ||
     not (acyclic cl) then Nothing else Just ()
  let pipeline=PipePlan [(op,f,slots) | (op,f,slots,_)<-stages] element acc
      result=maybe element snd acc
      plan=SpecPlan ("pipeline@"++show pipeline) (head names) True cl Nothing Nothing Nothing
             (case result of KD->Just "64"; KS->Just "32"; _->Nothing)
             (length args) (Just (kinds++[element],result)) (Just pipeline)
  pure (plan,args++[vector])
  where
    primitive op = not (local op) && M.notMember op prog
    value (CVar n) = local n
    value (CInt _) = True
    value (CMk 1 _ []) = True
    value e = isJust (floatLitBits e)
    callback count fe = do
      (CVar f,caps) <- Just (spineOf fe)
      (ps,b) <- M.lookup f prog
      if local f || length ps/=length caps+count || length ps>8 || not (all value caps)
        then Nothing else Just ()
      sig <- signature prog ps b
      pure (f,caps,sig)
    collect top offset e = case spineOf e of
      (CVar op,[fe,z,v]) | top, op=="Vec.fold", primitive op -> do
        (f,caps,(ks,out)) <- callback 2 fe
        let n=length caps; ak=ks!!n
        if not (value z) || ak/=out || out==KB then Nothing else Just ()
        (ss,as,ts,_,input) <- collect False (offset+n+1) v
        pure (ss++[("fold",f,[offset..offset+n-1],ks)],caps++[z]++as,
              take n ks++[ak]++ts,Just (offset+n,ak),input)
      (CVar op,[fe,v]) | op `elem` ["Vec.map","Vec.filter"], primitive op -> do
        (f,caps,(ks,out)) <- callback 1 fe
        let n=length caps; short=drop 4 op
        if (short=="map" && (last ks/=out || out==KB)) ||
           (short=="filter" && out/=KB) then Nothing else Just ()
        (ss,as,ts,acc,input) <- collect False (offset+n) v
        pure (ss++[(short,f,[offset..offset+n-1],ks)],caps++as,take n ks++ts,acc,input)
      _ -> Just ([],[],[],Nothing,e)
    -- Cyclic callback graphs can change divergence-versus-failure behavior
    -- when passes interleave. Start with finite arithmetic callbacks only.
    acyclic cl = all isAcyclic (stronglyConnComp
      [(f,f,S.toList calls) | f<-S.toList cl, let (ps,b)=prog M.! f,
                            let calls=fromMaybe S.empty (bodyOK prog (S.fromList ps) b)])
    isAcyclic (AcyclicSCC _) = True
    isAcyclic _ = False

-- Only adjacent, single-consumer lets are nested; a successfully planned
-- pipeline proves that moved captures/seed are already values. Bindings remain
-- lexical, and a retained intermediate prevents this rewrite.
nestPipelines :: Prog -> Prog
nestPipelines prog = M.map (\(ps,b)->(ps,go (S.fromList ps) b)) prog
  where
    go bound e = join bound $ case e of
      CLet n a b -> CLet n (go bound a) (go (S.insert n bound) b)
      CApp a b -> CApp (go bound a) (go bound b)
      CIf c a b -> CIf (go bound c) (go bound a) (go bound b)
      CMk t v xs -> CMk t v (map (go bound) xs)
      CTagEq t v x -> CTagEq t v (go bound x)
      CProj k x -> CProj k (go bound x)
      _ -> e
    join bound e@(CLet x producer body) =
      let replace consumer = case spineOf consumer of
            (CVar op,args) | op `elem` ["Vec.map","Vec.filter","Vec.fold"],
              not (null args), all (not . elem x . freeVars) (init args) -> do
                input <- if last args==CVar x then Just producer else replace (last args)
                pure (foldl' CApp (CVar op) (init args++[input]))
            _ -> Nothing
          plug consumer = do
            candidate <- replace consumer
            _ <- pipelinePlan prog (`S.member` bound) candidate
            pure candidate
      in case body of
        CLet y consumer rest | x `notElem` freeVars rest, Just candidate<-plug consumer ->
          go bound (CLet y candidate rest)
        _ | Just candidate<-plug body -> go bound candidate
        _ -> e
    join _ e = e

vecSpec :: Bool -> Prog -> (String -> Bool) -> Core -> Maybe (SpecPlan, [Core])
vecSpec fusion prog isLocal e = do
  (p,args) <- case if fusion then pipelinePlan prog isLocal e else Nothing of
    Just plan -> Just plan
    Nothing -> vecSpecRaw fusion prog isLocal e
  typed <- typePlan prog p
  pure (typed,args)

-- The soft-float switch covers column kernels as well as scalar primitives.
-- A comparison can return Bool/Int while still consuming floats; record maps
-- can mix integer and floating fields. Inspect inputs and the whole closure,
-- not just the result representation, before requesting an unboxed clone.
specUsesFloat :: Prog -> SpecPlan -> Bool
specUsesFloat prog p =
  isJust (spFloat p) || isJust (floatWidthOf prog (spClosure p))
    || any floating (maybe [] (:[]) (spKinds p)
                    ++ maybe [] (maybe [] id . mvKinds) (spMv p))
  where
    floating (ks,k) = any (\t -> t == KD || t == KS) (k:ks)

-- Each raw argument has its own kind. Record maps retain their field plans;
-- mapAs retains the ordinary tagged callback ABI, rather than guessing kinds.
typePlan :: Prog -> SpecPlan -> Maybe SpecPlan
typePlan prog p
  | Just _ <- spPipe p = Just p
  | Just mp <- spMv p = do
      sigs <- mapM (\(_, (ps,b)) -> signature prog ps b) (mvFields mp)
      if any (\(ks,out) -> KB `elem` (out:ks)) sigs then Nothing else Just ()
      let reads = [(col,k) | (((ms,cs),_), (ks,_)) <- zip (mvFields mp) sigs,
                            (col,k) <- zip cs (drop (length ms) ks)]
          outputs = zip [0..] (map snd sigs)
      if all (\(col,k) -> all (\(c,t) -> c /= col || t == k) reads) outputs then Just () else Nothing
      pure p {spMv=Just mp {mvKinds=Just sigs}}
  | "mapAs@" `isPrefixOf` spOp p = Just p
  | otherwise = do
      (ps,b) <- case spSoa p of
        Just (_,ps,b,_) -> Just (ps,b)
        Nothing -> M.lookup (spFn p) prog
      sig@(ks,out) <- signature prog ps b
      let foldOp = spOp p == "fold" || wfoldG p /= Nothing
          args = drop (spCaps p) ks
      pure () -- Bool captures have a checked boxed-to-raw entry path
      if foldOp then case args of
        acc:_ | acc == out, out /= KB -> Just ()
        _ -> Nothing
      else if spOp p `elem` ["filter","rfilter"] then
        if out == KB then Just () else Nothing
      else if args == [out] && out /= KB then Just () else Nothing
      if any (== KB) args then Nothing else Just ()
      pure p {spKinds=Just sig, spFloat=case out of KD -> Just "64"; KS -> Just "32"; _ -> Nothing}

vecSpecRaw :: Bool -> Prog -> (String -> Bool) -> Core -> Maybe (SpecPlan,[Core])
vecSpecRaw fusion prog isLocal e = case spineOf e of
  (CVar "Vec.mapAs", [CStr layout, fe, v])
    | (CVar f, caps) <- spineOf fe,
      okOp "Vec.mapAs", okFn f (length caps + 1), length caps + 1 <= 8 ->
        Just (SpecPlan ("mapAs@" ++ layout) f False S.empty Nothing Nothing Nothing Nothing (length caps) Nothing Nothing, caps ++ [v])
  (CVar "Vec.map", [fe, v])
    | (CVar f, [capE]) <- spineOf fe,
      okOp "Vec.map",
      okFn f 2,
      Just mp <- soaDualMap prog f (capShapeOf capE) -> do
        cl <- arithClosure prog [fn | (_, (_, b)) <- mvFields mp, fn <- S.toList (calleesOf prog b)]
        Just (SpecPlan "mvmap" f False cl Nothing Nothing (Just mp) Nothing 0 Nothing Nothing, [capE, v])
  (CVar "Vec.map", [CVar f, v])
    | okOp "Vec.map",
      okFn f 1,
      Just mp <- soaDualMap0 prog f -> do
        cl <- arithClosure prog [fn | (_, (_, b)) <- mvFields mp, fn <- S.toList (calleesOf prog b)]
        -- capture-free record->record map: same in-place column loop,
        -- with a dead capture slot (a0 = tagged 0, never dereferenced:
        -- ms is empty for every field, so nothing loads off s8)
        Just (SpecPlan "mvmap" f False cl Nothing Nothing (Just mp) Nothing 0 Nothing Nothing, [CInt 0, v])
  (CVar "Vec.map", [CVar f, v]) | okOp "Vec.map", okFn f 1 -> plan "map" f [v]
  (CVar "Vec.filter", [CVar f, v])
    | okOp "Vec.filter", okFn f 1, Just pl <- planSpec prog "filter" f -> Just (pl, [v])
  -- a predicate over a RECORD element: the column-compaction kernel
  (CVar "Vec.filter", [CVar f, v])
    | okOp "Vec.filter",
      okFn f 1,
      Just (ks, ps, b, tv, cl) <- soaDualPred prog f ->
        Just (SpecPlan "rfilter" f False cl (Just (ks, ps, b, tv)) Nothing Nothing Nothing 0 Nothing Nothing, [v])
  -- scalar captures: Vec.map (affine a b) v, Vec.filter (above k) v.  The
  -- captures ride ahead of the vector in the kernel's argument list; the
  -- element function's arity is captures + 1 and fits the 8 registers.
  (CVar "Vec.map", [fe, v])
    | (CVar f, caps@(_ : _)) <- spineOf fe,
      okOp "Vec.map",
      okFn f (length caps + 1),
      length caps + 1 <= 8 ->
        (,caps ++ [v]) <$> planSpecCaps prog "map" f (length caps)
  (CVar "Vec.filter", [fe, v])
    | (CVar f, caps@(_ : _)) <- spineOf fe,
      okOp "Vec.filter",
      okFn f (length caps + 1),
      length caps + 1 <= 8 ->
        (,caps ++ [v]) <$> planSpecCaps prog "filter" f (length caps)
  -- WRITE-BACK FOLD: Vec.fold f z (Vec.map g v) fuses into ONE pass
  -- that stores g(el) back into the column AND folds f over it -- the
  -- map's writes stay program-visible through the returned vector, so
  -- this is the fusion the map/map rewrite could never express (2026-08-25-VEC.md
  -- open item 1).  Scalar int tier only in v1; anything else falls
  -- through to the plain fold plan below, whose map argument then
  -- specializes on its own.
  (CVar "Vec.fold", [CVar f, z, me])
    | fusion, (CVar "Vec.map", [CVar g, v]) <- spineOf me,
      okOp "Vec.fold",
      not (isLocal "Vec.map"),
      okFn f 2,
      okFn g 1,
      fusionSafe prog f,
      fusionSafe prog g, -- a fold step and a map step interleave per element
      Just clf <- arithClosure prog [f],
      Just clg <- arithClosure prog [g],
      floatWidthOf prog clf == Nothing,
      floatWidthOf prog clg == Nothing ->
        Just (SpecPlan ("wfold@" ++ g) f True (clf `S.union` clg) Nothing Nothing Nothing Nothing 0 Nothing Nothing, [z, v])
  (CVar "Vec.fold", [fe, z, v])
    | (CVar f, caps@(_ : _)) <- spineOf fe,
      okOp "Vec.fold", okFn f (length caps + 2), length caps + 2 <= 8 ->
        let k = length caps in (,caps ++ [z,v]) <$> case planSpecCaps prog "fold" f k of
          Just p -> Just p
          Nothing -> do
            (ks,ps,b,tv,cl) <- soaDualCaps prog f k
            Just (SpecPlan "fold" f False cl (Just (ks,ps,b,tv)) Nothing Nothing Nothing k Nothing Nothing)
  (CVar "Vec.fold", [CVar f, z, v]) | okOp "Vec.fold", okFn f 2 -> plan "fold" f [z, v]
  _ -> Nothing
  where
    okOp h = not (isLocal h) && M.notMember h prog
    okFn f n = not (isLocal f) && maybe False ((== n) . length . fst) (M.lookup f prog)
    plan op f args = (,args) <$> planSpec prog op f

calleesOf :: Prog -> Core -> S.Set String
calleesOf prog = go
  where
    go e = case spineOf e of
      (CVar h, args@(_ : _)) | M.member h prog -> S.insert h (S.unions (map go args))
      _ -> case e of
        CApp a b -> go a `S.union` go b
        CLet _ a b -> go a `S.union` go b
        CIf c t f' -> S.unions [go c, go t, go f']
        CMk _ _ fs -> S.unions (map go fs)
        CTagEq _ _ x -> go x
        CProj _ x -> go x
        _ -> S.empty

planSpec :: Prog -> String -> String -> Maybe SpecPlan
planSpec prog "fold" f =
  let scal = arithClosure prog [f]
      fw = floatWidthOf prog (maybe S.empty id scal)
      soa = soaDual prog f
      rvv = if isSumFn prog f then Just RvvFoldSum else Nothing
   in if scal == Nothing && soa == Nothing
        then Nothing
        else
          Just
            SpecPlan
              { spOp = "fold",
                spFn = f,
                spScalar = scal /= Nothing,
                spClosure = S.unions [maybe S.empty id scal, maybe S.empty (\(_, _, _, _, cl) -> cl) soa],
                spSoa = (\(ks, ps, b, tv, _) -> (ks, ps, b, tv)) <$> soa,
                spRvv = if fw == Nothing then rvv else Nothing,
                spMv = Nothing,
                spFloat = fw,
                spCaps = 0,
                spKinds = Nothing,
                spPipe = Nothing
              }
planSpec prog op f = planSpecCaps prog op f 0

-- a map/filter plan whose element function takes k scalar captures
-- ahead of the element.  Float closures decline: a raw float capture
-- carries no tag to check, so the entry guard could not tell it from
-- a pointer.
planSpecCaps :: Prog -> String -> String -> Int -> Maybe SpecPlan
planSpecCaps prog op f k = do
  cl <- arithClosure prog [f]
  let rvv = case M.lookup f prog of
        Just ([p], body) | op == "map", k == 0, Just b <- straightLine [p] body -> Just (RvvMap p b)
        _ -> Nothing
  let fw = floatWidthOf prog cl
  pure () -- captures are validated individually by typePlan
   -- RVV lanes are integer vadd/vmul in this pass, so a float
   -- closure takes the scalar float loop, not the vector one
  Just (SpecPlan op f True cl Nothing (if fw == Nothing then rvv else Nothing) Nothing fw k Nothing Nothing)

-- the closed arithmetic call graph rooted at the given functions;
-- Nothing if anything outside the unboxable fragment is reachable
arithClosure :: Prog -> [String] -> Maybe (S.Set String)
arithClosure prog = go S.empty
  where
    go acc [] = Just acc
    go acc (n : rest)
      | S.member n acc = go acc rest
      | otherwise = do
          (ps, body) <- M.lookup n prog
          calls <- bodyOK prog (S.fromList ps) body
          go (S.insert n acc) (S.toList calls ++ rest)

-- checks one body against the unboxable fragment; returns callees
bodyOK :: Prog -> S.Set String -> Core -> Maybe (S.Set String)
bodyOK prog = ok
  where
    ok env e
      | Just _ <- floatLitBits e = Just S.empty -- a folded float literal
    ok env e = case spineOf e of
      (CVar h, args@(_ : _))
        | h `elem` uPrims || h `elem` fPrims,
          Just 2 <- lookup h primArities,
          length args == 2 ->
            S.unions <$> mapM (ok env) args
        | Just (ps, _) <- M.lookup h prog,
          not (S.member h env),
          length ps == length args ->
            S.insert h . S.unions <$> mapM (ok env) args
      _ -> case e of
        CVar n | S.member n env -> Just S.empty
        CInt _ -> Just S.empty
        CMk 1 _ [] -> Just S.empty -- True/False literals
        CTagEq 1 _ x -> ok env x -- Bool tag test on a raw 0/1
        CIf c t f -> S.unions <$> sequence [ok env c, ok env t, ok env f]
        CLet x a b -> S.union <$> ok env a <*> ok (S.insert x env) b
        CErr _ -> Just S.empty -- dead case arms
        _ -> Nothing

uPrims :: [String]
uPrims = ["+", "-", "*", "/", "==", "!=", "<", ">", "<=", ">="]

-- the same op set at each float width.  An unboxed clone over a FLOAT
-- column gets raw IEEE bits in its integer registers exactly as an Int
-- clone gets raw ints -- identical calling convention, different
-- instructions -- so the whole specialized-loop machinery carries over
-- with only the arithmetic and the rep guard changed.
fPrimsOf :: String -> [String]
fPrimsOf w = [ "F" ++ w ++ "." ++ o | o <- uPrims ]

fPrims :: [String]
fPrims = fPrimsOf "64" ++ fPrimsOf "32"

planCapKinds :: SpecPlan -> [Kind]
planCapKinds p = maybe (replicate (spCaps p) KI) (take (spCaps p) . fst) (spKinds p)

-- does this closure compute in floats (and at which width)?  Decided
-- from the bodies, which is also what picks the loop's rep guard.
floatWidthOf :: Prog -> S.Set String -> Maybe String
floatWidthOf prog names =
  case [w | w <- ["64", "32"], any (usesW w) (S.toList names)] of
    (w : _) -> Just w
    [] -> Nothing
  where
    usesW w n = maybe False (goB w . snd) (M.lookup n prog)
    goB w e = case spineOf e of
      (CVar h, args) | h `elem` fPrimsOf w -> True
                     | otherwise -> any (goB w) args
      _ -> case e of
        CIf c t f -> goB w c || goB w t || goB w f
        CLet _ a b -> goB w a || goB w b
        _ -> False

-- a float LITERAL inside an unboxable body: the desugarer emits
-- f64frombits hi lo (or f32frombits bits) with constant arguments, so
-- it folds to one `li` of the bit pattern.  Without this, any body
-- mentioning 2.0 would fail admission and lose its specialized loop.
floatLitBits :: Core -> Maybe Integer
floatLitBits e = case spineOf e of
  (CVar "f64frombits", [CInt hi, CInt lo]) -> Just ((hi * 4294967296) + (lo `mod` 4294967296))
  (CVar "f32frombits", [CInt b]) -> Just b
  _ -> Nothing

-- inline trivial re-lets (the desugarer's  let a = a1_0 in ...)
peel :: Core -> Core
peel (CLet x (CVar y) b) = peel (subst x y b)
peel e = e

subst :: String -> String -> Core -> Core
subst x y = go
  where
    go (CVar n) = CVar (if n == x then y else n)
    go (CApp a b) = CApp (go a) (go b)
    go (CLet n a b) = CLet n (go a) (if n == x then b else go b)
    go (CIf c t f) = CIf (go c) (go t) (go f)
    go (CMk t v fs) = CMk t v (map go fs)
    go (CTagEq t v e) = CTagEq t v (go e)
    go (CProj k e) = CProj k (go e)
    go e = e

-- is f literally \a b -> a + b (mod trivial lets / arg order)?
isSumFn :: Prog -> String -> Bool
isSumFn prog f = case M.lookup f prog of
  Just ([a, b], body) -> case spineOf (peel body) of
    (CVar "+", [CVar x, CVar y]) -> (x == a && y == b) || (x == b && y == a)
    _ -> False
  _ -> False

-- straight-line +/-/* expression over the param: RVV-mappable
straightLine :: [String] -> Core -> Maybe Core
straightLine ps body0 = body0 <$ chk (S.fromList ps) (peel body0)
  where
    chk env e = case spineOf e of
      (CVar h, [a, b]) | h `elem` ["+", "-", "*"] -> chk env a >> chk env b
      _ -> case e of
        CVar n | S.member n env -> Just ()
        CInt _ -> Just ()
        CLet x a b -> chk env a >> chk (S.insert x env) b
        _ -> Nothing

-- fold-over-SoA dualization: rewrite  CProj k (CVar el)  to a fresh
-- column variable; the loop feeds those from per-column cursors and the
-- tuple is never built.  Returns (used columns, ufn params, body, extra
-- arithmetic closure needed by calls inside the body).
soaDual :: Prog -> String -> Maybe ([Int], [String], Core, (Int, Int), S.Set String)
soaDual prog f = soaDualCaps prog f 0

soaDualCaps :: Prog -> String -> Int -> Maybe ([Int], [String], Core, (Int, Int), S.Set String)
soaDualCaps prog f k = do
  (params, body0) <- M.lookup f prog
  [acc,el] <- Just (drop k params)
  let caps = take k params
  -- the desugarer re-lets params and the case scrutinee; peelDeep
  -- exposes projections as CProj k (CVar el) and the shape test as
  -- CTagEq tid var (CVar el)
  (body', (ks, tvs)) <- runDual el (peelDeep body0)
  tv <- case S.toList (S.fromList tvs) of
    [one] -> Just one -- exactly one shape test: the required eltid/elvar
    -- NO shape test but real column reads: projField bound each field
    -- against a UNIQUE candidate shape and emitted a bare CProj, no
    -- CTagEq -- the generic body is exactly as unchecked, so the dual
    -- may run guarded only by ncols/kinds ((-1,-1) = skip the
    -- eltid/elvar compare).  This is what un-declines NAMED record
    -- folds: their row-polymorphic bodies never carry a dispatch chain.
    [] | not (null ks) -> Just (-1, -1)
    _ -> Nothing -- conflicting shape tests: bail
  if null ks || S.size (S.fromList ks) + k + 1 > 8 + spillCells || acc == el -- accumulator/captures plus used columns, with hart spills after a7
    then Nothing
    else do
      let cols = S.toAscList (S.fromList ks)
          cvars = ["$c" ++ show k | k <- cols]
      calls <- bodyOK prog (S.fromList (caps ++ acc : cvars)) body'
      cl <- arithClosure prog (S.toList calls)
      -- The raw ABI receives separately typed accumulator and columns.
      pure () -- typePlan supplies accumulator/capture/column kinds
      Just (cols, caps ++ acc : cvars, body', tv, cl)
  where
    -- peel trivial alias-lets at every depth (not just the spine)
    peelDeep e = case peel e of
      CApp a b -> CApp (peelDeep a) (peelDeep b)
      CLet x a b -> CLet x (peelDeep a) (peelDeep b)
      CIf c t f' -> CIf (peelDeep c) (peelDeep t) (peelDeep f')
      CMk t v fs -> CMk t v (map peelDeep fs)
      CTagEq t v x -> CTagEq t v (peelDeep x)
      CProj k x -> CProj k (peelDeep x)
      e' -> e'
    runDual el = go
      where
        go (CProj k (CVar v)) | v == el = Just (CVar ("$c" ++ show k), ([k], []))
        -- a shape test on the element: statically true under the spec
        -- guard (which checks the vector's eltid/elvar), so it rewrites
        -- to True -- and RECORDS the tid/var the guard must check
        go (CTagEq t v (CVar x)) | x == el = Just (CMk 1 1 [], ([], [(t, v)]))
        go (CVar n) | n == el = Nothing -- el escapes: cannot dualize
        go e@(CVar _) = Just (e, mempty)
        go e@(CInt _) = Just (e, mempty)
        go e@(CStr _) = Just (e, mempty)
        go (CApp a b) = app2 CApp a b
        go (CLet x a b) | x /= el = app2 (CLet x) a b
        go (CIf c t f') = do (c', k1) <- go c; (t', k2) <- go t; (f'', k3) <- go f'; Just (CIf c' t' f'', k1 <> k2 <> k3)
        go (CTagEq t v e) = do (e', ks') <- go e; Just (CTagEq t v e', ks')
        go e@(CErr _) = Just (e, mempty)
        go (CMk t v fs) = do rs <- mapM go fs; Just (CMk t v (map fst rs), mconcat (map snd rs))
        go _ = Nothing
        app2 c a b = do (a', k1) <- go a; (b', k2) <- go b; Just (c a' b', k1 <> k2)

-- record FILTER dualization: a 1-ary predicate over a record element,
-- rewritten like soaDual so the loop feeds it the used columns and the
-- row is never built.  Returns (used cols, params, body, eltid/elvar,
-- closure).  Helpers taking the whole element are inlined first, so
-- `keep r = total r > 10` dualizes.
soaDualPred :: Prog -> String -> Maybe ([Int], [String], Core, (Int, Int), S.Set String)
soaDualPred prog f = do
  ([el], body0) <- M.lookup f prog
  let body1 = peelDeepC (inl (8 :: Int) (peelDeepC body0))
      inl 0 e = e
      inl d e = case spineOf e of
        (CVar h, args@(_ : _))
          | h /= f,
            Just (ps, hb) <- M.lookup h prog,
            length ps == length args,
            any (mentions el) args ->
              inl (d - 1) (peelDeepC (foldr (\(p, a) acc -> substE p a acc) hb (zip ps args)))
        _ -> case e of
          CApp a b -> CApp (inl d a) (inl d b)
          CLet x a b -> CLet x (inl d a) (inl d b)
          CIf c t e' -> CIf (inl d c) (inl d t) (inl d e')
          CTagEq t v x -> CTagEq t v (inl d x)
          CProj k x -> CProj k (inl d x)
          other -> other
      mentions v e = v `elem` freeVars e
  (body', (ks, tvs)) <- go el body1
  tv <- case S.toList (S.fromList tvs) of
    [one] -> Just one
    [] | not (null ks) -> Just (-1, -1)
    _ -> Nothing
  if null ks || S.size (S.fromList ks) > 8 + spillCells -- columns past the eighth ride the hart spill cells
    then Nothing
    else do
      let cols = S.toAscList (S.fromList ks)
          cvars = ["$c" ++ show k | k <- cols]
      calls <- bodyOK prog (S.fromList cvars) body'
      cl <- arithClosure prog (S.toList calls)
      -- a float predicate would need float column loads: not in this kernel
      if floatWidthOf prog cl /= Nothing || usesFloat body' then Nothing else Just ()
      Just (cols, cvars, body', tv, cl)
  where
    usesFloat e = case spineOf e of
      (CVar h, args) | h `elem` fPrims -> True
                     | otherwise -> any usesFloat args
      _ -> case e of
        CIf c t f' -> any usesFloat [c, t, f']
        CLet _ a b -> usesFloat a || usesFloat b
        _ -> False
    go el = g
      where
        g (CProj k (CVar v)) | v == el = Just (CVar ("$c" ++ show k), ([k], []))
        g (CTagEq t v (CVar x)) | x == el = Just (CMk 1 1 [], ([], [(t, v)]))
        g (CVar n) | n == el = Nothing -- the row escapes: cannot dualize
        g e@(CVar _) = Just (e, mempty)
        g e@(CInt _) = Just (e, mempty)
        g e@(CErr _) = Just (e, mempty)
        g (CApp a b) = app2 CApp a b
        g (CLet x a b) | x /= el = app2 (CLet x) a b
        g (CIf c t f') = do (c', k1) <- g c; (t', k2) <- g t; (f'', k3) <- g f'; Just (CIf c' t' f'', k1 <> k2 <> k3)
        g (CTagEq t v e) = do (e', ks') <- g e; Just (CTagEq t v e', ks')
        g e@(CMk 1 _ []) = Just (e, mempty) -- True / False
        g _ = Nothing
        app2 c a b = do (a', k1) <- g a; (b', k2) <- g b; Just (c a' b', k1 <> k2)

-- map-over-SoA with one captured record: dualize
--   f cap el = <inline everything> = Mk etid evar [e0..e_{n-1}]
-- into one unboxed fn PER OUTPUT FIELD whose params are the used
-- captured-record fields ($m<j>) then the used element columns
-- ($c<k>).  The loop runs IN PLACE: same shape in and out, results
-- buffered per element before the stores.
-- capture-free variant: a 1-ary record->record map runs through the
-- SAME dual with a phantom capture name nothing can reference (the
-- desugarer never emits "$"-prefixed user names), so ms comes back
-- empty for every field and the emitter's capture loads vanish.
-- a captured record's shape, when the call site constructs it: the element
-- fn's projections of the capture may be shape dispatches (another record
-- type carries the same field name), and only the capture's own arm is right
capShapeOf :: Core -> Maybe (Int, Int)
capShapeOf = \case
  CMk t v (_ : _) -> Just (t, v)
  _ -> Nothing

soaDualMap0 :: Prog -> String -> Maybe MvPlan
soaDualMap0 prog h = do
  ([el], body0) <- M.lookup h prog
  case body0 of
    -- a fuseVec composite: h el = f (g el).  Compose the two duals
    -- directly -- g's output field k IS f's input column k (records
    -- construct and project in the same sorted-field order), so f's
    -- $c_k references substitute with g's field-k dual bodies.  No
    -- normalization of the inlined mess, no emitter change.
    CApp (CVar f) (CApp (CVar g) (CVar e')) | e' == el ->
      composePlans <$> soaDualMap0 prog g <*> soaDualMap0 prog f
    _ -> soaDualMapOn prog h "$nocap" el Nothing body0

soaDualMap :: Prog -> String -> Maybe (Int, Int) -> Maybe MvPlan
soaDualMap prog h capShape = do
  ([cap, el], body0) <- M.lookup h prog
  case body0 of
    -- captured composites (one side only, by fuseVec construction):
    -- outer-captured  h c el = f c (g el)
    CApp (CApp (CVar f) (CVar c')) (CApp (CVar g) (CVar e'))
      | c' == cap, e' == el ->
          composePlans <$> soaDualMap0 prog g <*> soaDualMap prog f capShape
    -- inner-captured  h c el = f (g c el)
    CApp (CVar f) (CApp (CApp (CVar g) (CVar c')) (CVar e'))
      | c' == cap, e' == el ->
          composePlans <$> soaDualMap prog g capShape <*> soaDualMap0 prog f
    _ -> soaDualMapOn prog h cap el capShape body0

-- compose per-field duals: for each of f's output fields, replace its
-- element-column reads ($c_k) with g's field-k body.  Placeholder
-- rename first so g's own $c/$m names never collide with the ones
-- being replaced.  Exactly one side carries $m captures (fuseVec
-- skips both-captured), so the merged capture set is that side's.
composePlans :: MvPlan -> MvPlan -> MvPlan
composePlans gp fp =
  MvPlan (mvTid gp) (length fields') Nothing fields'
  where
    gduals = mvFields gp
    fields' =
      [ composed | ((fms, fks), (_, fbody)) <- mvFields fp,
        let renamed = foldr (\k b -> substE ("$c" ++ show k) (CVar ("$X" ++ show k)) b) fbody fks
            plugged = foldr plug renamed fks
            plug k b
              | k < length gduals, ((_, _), (_, gb)) <- gduals !! k =
                  substE ("$X" ++ show k) gb b
              | otherwise = substE ("$X" ++ show k) (CVar ("$c" ++ show k)) b
            ms' = S.toAscList (S.fromList (fms ++ concat [gms | k <- fks, k < length gduals, let ((gms, _), _) = gduals !! k]))
            ks' = S.toAscList (S.fromList (concat [gks | k <- fks, k < length gduals, let ((_, gks), _) = gduals !! k]))
            ps' = ["$m" ++ show j | j <- ms'] ++ ["$c" ++ show k | k <- ks']
            composed = ((ms', ks'), (ps', plugged))
      ]

soaDualMapOn :: Prog -> String -> String -> String -> Maybe (Int, Int) -> Core -> Maybe MvPlan
soaDualMapOn prog f cap el capShape body0 = do
  -- peel alias lets again AFTER inlining: a helper taking the whole
  -- element (`total r`) inlines to `let r' = el in ..`, and an unpeeled
  -- alias reads as the element escaping
  let body1 = peelDeepC (inlineSat (8 :: Int) (peelDeepC body0))
  (tv, fs) <- strip cap el Nothing body1
  let n = length fs
  if n == 0 then Nothing else Just () -- any width: cursors and results are frame slots
  duals <- mapM (dualField tv cap el) fs
  Just (MvPlan tv n Nothing duals)
  where
    inlineSat 0 e = e
    inlineSat d e = case spineOf e of
      (CVar h, args@(_ : _))
        | h /= f,
          Just (ps, hb) <- M.lookup h prog,
          length ps == length args ->
            inlineSat (d - 1) (peelDeepC (foldr (\(p, a) acc -> substE p a acc) hb (zip ps args)))
      _ -> case e of
        CApp a b -> CApp (inlineSat d a) (inlineSat d b)
        CLet x a b -> CLet x (inlineSat d a) (inlineSat d b)
        CIf c t e' -> CIf (inlineSat d c) (inlineSat d t) (inlineSat d e')
        CMk t v xs -> CMk t v (map (inlineSat d) xs)
        CTagEq t v x -> CTagEq t v (inlineSat d x)
        CProj k x -> CProj k (inlineSat d x)
        other -> other
    -- walk down to the record construction, consuming shape tests.  A
    -- shape test on the element is a DISPATCH the desugarer emits when
    -- several record shapes could be meant (`{ r | f0 = .. }` with two
    -- shapes carrying f0): the first arm is only right for vectors of
    -- that first shape.  The kernel never materializes the row, so it
    -- cannot run the dispatch; it takes the arm only when it is the sole
    -- candidate (the else branch is the error arm), and declines
    -- otherwise -- the generic tier runs bump on real rows.  Taking the
    -- first arm regardless planned a two-field kernel for a four-field
    -- vector (tests/base/vecwide.fpr, found 2026-10-03).
    strip cap el tv e = case e of
      CIf (CTagEq t v (CVar x)) th rest
        | x == el, soleCandidate rest -> strip cap el (tv `orKeep` Just (t, v)) th
        | x == el -> Nothing
        -- a dispatch on the CAPTURE: its arm when the call site built the
        -- record (capShapeOf), the sole arm otherwise, else decline
        | x == cap, Just sh <- capShape -> strip cap el tv (if (t, v) == sh then th else rest)
        | x == cap, soleCandidate rest -> strip cap el tv th
        | x == cap -> Nothing
      CLet x a b -> strip cap el tv (substE x a b)
      CMk t v fs' -> do
        (et, ev) <- tv `orKeep` Just (t, v) -- untested el: require Mk matches nothing... use Mk's own only if tested
        if (et, ev) == (t, v) then Just ((et, ev), fs') else Nothing
      _ -> Nothing
    orKeep (Just x) _ = Just x
    orKeep Nothing y = y
    soleCandidate = \case
      CErr _ -> True
      _ -> False
    dualField tv cap el e0 = do
      (e1, (ms, ks)) <- go e0
      let ms' = S.toAscList (S.fromList ms)
          ks' = S.toAscList (S.fromList ks)
          ps = ["$m" ++ show j | j <- ms'] ++ ["$c" ++ show k | k <- ks']
      if length ps > 8 + spillCells then Nothing else Just () -- args 8+ ride the hart spill cells
      _ <- bodyOK prog (S.fromList ps) e1
      Just ((ms', ks'), (ps, e1))
      where
        go e = case e of
          CProj k (CVar v)
            | v == el -> Just (CVar ("$c" ++ show k), ([], [k]))
            | v == cap -> Just (CVar ("$m" ++ show k), ([k], []))
          CVar v | v == el || v == cap -> Nothing -- escapes
          -- a shape DISPATCH on the element inside a field (`p.x` when
          -- several record shapes carry x): only the arm of the element's
          -- own shape is this kernel's; the other arms project another
          -- record's columns.  Taking the first arm regardless read a
          -- four-field record's column index on a two-field vector
          -- (found 2026-10-16: a second record type declared in the
          -- module, and the kernel read a frame slot as a cursor).
          CIf (CTagEq t v (CVar x)) th rest
            | x == el -> go (if (t, v) == tv then th else rest)
            | x == cap, Just sh <- capShape -> go (if (t, v) == sh then th else rest)
            | x == cap, soleCandidate rest -> go th
            | x == cap -> Nothing -- another record carries this field: the arm is unknown
          CTagEq t v (CVar x)
            | x == el -> Just (CMk 1 (if (t, v) == tv then 1 else 0) [], ([], []))
            | x == cap, Just sh <- capShape -> Just (CMk 1 (if (t, v) == sh then 1 else 0) [], ([], []))
            | x == cap -> Nothing
          CApp a b -> ap2 CApp a b
          CLet x a b | x /= el, x /= cap -> ap2 (CLet x) a b
          CIf c t e' -> do (c', k1) <- go c; (t', k2) <- go t; (e'', k3) <- go e'; Just (CIf c' t' e'', k1 <> k2 <> k3)
          CTagEq t v x -> do (x', ks') <- go x; Just (CTagEq t v x', ks')
          CMk {} -> Nothing -- nested construction inside a field: bail
          e'@(CVar _) -> Just (e', mempty)
          e'@(CInt _) -> Just (e', mempty)
          e'@(CStr _) -> Just (e', mempty)
          e'@(CErr _) -> Just (e', mempty)
          _ -> Nothing
        ap2 c a b = do (a', k1) <- go a; (b', k2) <- go b; Just (c a' b', k1 <> k2)

-- capture-naive expression substitution: sound here because the
-- desugarer's names are globally fresh
substE :: String -> Core -> Core -> Core
substE x v = go
  where
    go (CVar n) = if n == x then v else CVar n
    go (CApp a b) = CApp (go a) (go b)
    go (CLet n a b) = CLet n (go a) (if n == x then b else go b)
    go (CIf c t f') = CIf (go c) (go t) (go f')
    go (CMk t v' fs) = CMk t v' (map go fs)
    go (CTagEq t v' e) = CTagEq t v' (go e)
    go (CProj k e) = CProj k (go e)
    go e = e

peelDeepC :: Core -> Core
peelDeepC e = case peel e of
  CApp a b -> CApp (peelDeepC a) (peelDeepC b)
  CLet x a b -> CLet x (peelDeepC a) (peelDeepC b)
  CIf c t f' -> CIf (peelDeepC c) (peelDeepC t) (peelDeepC f')
  CMk t v fs -> CMk t v (map peelDeepC fs)
  CTagEq t v x -> CTagEq t v (peelDeepC x)
  CProj k x -> CProj k (peelDeepC x)
  e' -> e'

-- a kernel's symbol: one per (op, element function), as requestSpec names it
specSymbol :: SpecPlan -> String
specSymbol p = case wfoldG p of
  Just g -> "fpr_vspec_wfold_" ++ mangleName (spFn p) ++ "_" ++ mangleName g
  Nothing -> "fpr_vspec_" ++ mangleName (spOp p) ++ "_" ++ mangleName (spFn p)

-- A write-back fold carries its map function in its unique operation key.
wfoldG :: SpecPlan -> Maybe String
wfoldG p = case splitAt 6 (spOp p) of
  ("wfold@", g) -> Just g
  _ -> Nothing

simdPlan :: Target -> Prog -> SpecPlan -> Maybe (K.SimdExpr, Int)
simdPlan tgt prog p = do
  if tgtSimd tgt && spOp p == "map" then Just () else Nothing
  (params,b) <- M.lookup (spFn p) prog
  if length params == spCaps p + 1 then Just () else Nothing
  (body,ticks) <- expandKernel prog 12 b
  kind <- case spKinds p of
    Just (ks,out) | out `elem` [KI,KD], length ks == length params, all (==out) ks -> Just out
    _ -> Nothing
  expr <- simdExprOf kind (init params) (last params) body
  let budget = case tgtNative tgt >>= nmBackend of Just (DirectX64 _) -> 7; Just DirectQX64 -> 7; _ -> 15
  if simdRegisters expr <= budget then Just () else Nothing
  either (const Nothing) (const (Just (expr,ticks))) (simdExprOk (kind == KI) expr)

-- The lane, matching scalar captures and literals, with Int + - or F64 + - *.
simdExprOf :: Kind -> [String] -> String -> Core -> Maybe K.SimdExpr
simdExprOf kind caps prm body = evalStateT (go env0 body) (0 :: Int)
  where
    env0 = M.insert prm K.SLane (M.fromList (zip caps (map K.SCapture [0..])))
    reg = do n <- get; if n >= 15 then lift Nothing else put (n+1)
    go env e | Just bits <- floatLitBits e, kind == KD = reg >> pure (K.SConst bits)
    go env (CInt n) | kind == KI = reg >> pure (K.SConst n)
    go env (CVar n) = do
      e <- lift (M.lookup n env)
      case e of K.SCapture _ -> reg; _ -> pure ()
      pure e
    go env (CLet x a b) = do v <- go env a; go (M.insert x v env) b
    go env e | (CVar op,[a,b]) <- spineOf e = do
      x <- go env a; y <- go env b; reg
      case (kind, op) of
        (KI,"+") -> pure (K.SInt Add x y)
        (KI,"-") -> pure (K.SInt Sub x y)
        (KD,"F64.+") -> pure (K.SFloat FAdd x y)
        (KD,"F64.-") -> pure (K.SFloat FSub x y)
        (KD,"F64.*") -> pure (K.SFloat FMul x y)
        _ -> lift Nothing
    go _ _ = lift Nothing

typedKernelPlan :: String -> SpecPlan -> Either String K.Kernel
typedKernelPlan sym p
  | Just pipeline <- spPipe p = Right (K.Kernel sym (planCapKinds p) (pipeElement pipeline)
      (pipeAccumulator pipeline) [K.Stage op f caps | (op,f,caps) <- pipeStages pipeline] Nothing False)
  | spOp p `elem` ["map","filter","fold"], spScalar p,
    spSoa p == Nothing, spMv p == Nothing =
      let k = spCaps p
          kinds = planCapKinds p
          element = case spKinds p of Just (ks,_) -> last ks; _ -> KI
          accKind = case spKinds p of Just (ks,_) -> ks !! k; _ -> KI
          folding = spOp p == "fold"
       in Right (K.Kernel sym (kinds ++ [accKind | folding]) element
            (if folding then Just (k,accKind) else Nothing) [K.Stage (spOp p) (spFn p) [0..k-1]] Nothing False)
  -- the write-back fold Vec.fold f z (Vec.map g v): one pass that stores
  -- g(el) and folds f over it, the pipeline shape with map then fold
  | Just g <- wfoldG p, Just (ks,_) <- spKinds p, spScalar p =
      Right (K.Kernel sym [head ks] (last ks) (Just (0,head ks)) [K.Stage "map" g [], K.Stage "fold" (spFn p) []] Nothing False)
  | otherwise = Left ("typed " ++ spOp p ++ " record/SIMD kernel not implemented")

-- Reuse the planner's column duals as ordinary Core functions, so callback
-- lowering, checked arithmetic, allocation and target selection stay shared.
typedRecordPlan :: Target -> Prog -> String -> SpecPlan -> Either String (K.RecordKernel, Prog)
typedRecordPlan tgt prog sym p
  | Just mp <- spMv p, Just sigs <- mvKinds mp = do
      let kinds = concat [out:ks | (ks,out) <- sigs]
      unless (all (`elem` [KI,KD,KS]) kinds) (Left "typed record map supports Int/F64/F32 fields")
      when (tgtW tgt == 4 && any (`elem` kinds) [KD,KS]) (Left "RV32 float record columns use boxed values")
      let fields = [(dual ++ "_" ++ show i,ms,cs,body) | (i,((ms,cs),body)) <- zip [0::Int ..] (mvFields mp)]
          defs = M.fromList [(f,body) | (f,_,_,body) <- fields]
          hasCap = maybe False ((==2) . length . fst) (M.lookup (spFn p) prog)
      pure (K.RecordKernel sym (spFn p) [] hasCap (mvTid mp) (zip [0..] (map snd sigs))
            (K.RecordMap [(f,ms,cs) | (f,ms,cs,_) <- fields]) False,defs)
  | Just (cs,ps,b,shape) <- spSoa p, Just (ks,out) <- spKinds p,
    spOp p `elem` ["fold","rfilter"] =
      let foldOp = spOp p == "fold"
          ncaps = spCaps p
          columnKinds = drop (ncaps + if foldOp then 1 else 0) ks
          op = if foldOp then K.RecordFold dual out else K.RecordFilter dual
       in Right (K.RecordKernel sym (spFn p) (take ncaps ks) False shape (zip cs columnKinds) op
                   (foldOp && ncaps == 0 && isGpuPairSum p),
                 M.singleton dual (ps,b))
  | otherwise = Left ("typed " ++ spOp p ++ " record/SIMD kernel not implemented")
  where dual = "$record:" ++ sym

emitSpecs :: Target -> Bool -> M.Map String Int -> S.Set String -> Prog -> [(String,SpecPlan)] -> ([NativeFn],[(String,String)],[String])
emitSpecs tgt rvv ext exps prog requested =
  let native pair@(sym,p) = case tgtNative tgt of
        Just nm | Just backend <- nmBackend nm -> do
          (builder, extra, roots) <- case stripPrefix "mapAs@" (spOp p) of
           Just layout -> pure (const (K.lowerMapAsKernel (tgtPolicy tgt) (K.MapAsKernel sym (spFn p) (spCaps p) layout)), M.empty, [])
           Nothing -> if isJust (spSoa p) || isJust (spMv p)
            then do
              (kernel,defs) <- typedRecordPlan tgt prog sym p
              pure (\callbacks -> K.lowerRecordKernel (tgtPolicy tgt) callbacks kernel, defs, M.keys defs)
            else do
              kernel0 <- typedKernelPlan sym p
              let kernel = kernel0 {K.kernelSimd = simdPlan tgt prog p,
                                    K.kernelRvvSum = rvv && spRvv p == Just RvvFoldSum && spScalar p && spCaps p == 0}
              pure (\callbacks -> K.lowerKernel (tgtPolicy tgt)
                      (if isJust (spPipe p) && not (tgtPipelineInline tgt) then M.empty else callbacks) kernel,
                    M.empty, [f | K.Stage _ f _ <- K.kernelStages kernel])
          let names = S.toList (spClosure p) ++ roots
              available = M.union extra prog
              chosen = M.filterWithKey (\n _ -> n `elem` names) available
              (loweredCallbacks, failures) = lowerProgram (tgtPolicy tgt) M.empty available chosen ext (foreignEntries tgt)
              callbacks = K.kernelCallbacks loweredCallbacks
          when (not (null failures)) (Left ("callback lowering: " ++ show failures))
          fn <- builder callbacks
          nfs <- mapM (\f -> emitNative tgt nm (S.insert (fnName f) exps) backend f) (fn : M.elems callbacks)
          if polFuel (tgtPolicy tgt) && any ((== Nothing) . rSegMax . nfReport) nfs
            then Left "native-insns-v1 is UNBOUNDED"
            else Right nfs
        _ -> Left "typed backend unavailable"
      results = [(pair,native pair) | pair <- requested]
      errors = [sym ++ ": " ++ e | ((sym,_),Left e) <- results, "compiler error:" `isPrefixOf` e]
      natives = M.elems (M.fromList [(nfName nf,nf) | (_,Right nfs) <- results, nf <- nfs])
      notes = ["typed-ir-kernel: " ++ sym ++ either (" refused: " ++) (const " native") result | ((sym,_),result) <- results]
   in if null errors then (natives,[(sym,reason) | ((sym,_),Left reason) <- results],notes)
      else error ("typed-ir kernel: " ++ intercalate "; " errors)

-- Normalize synthesized callbacks before SIMD selection, retaining the number
-- of callback entry ticks. Depth and register budgets decline to scalar code.
expandKernel :: Prog -> Int -> Core -> Maybe (Core,Int)
expandKernel prog depth e
  | Just _ <- floatLitBits e = Just (e,0)
  | depth <= 0 = Nothing
  | otherwise = case spineOf e of
      (CVar f,args@(_:_)) | Just (ps,b) <- M.lookup f prog, length ps == length args -> do
        (body,n) <- expandKernel prog (depth-1) (foldr (\(p,a) rest -> CLet p a rest) b (zip ps args))
        pure (body,n+1)
      _ -> case e of
        CApp a b -> do (x,n) <- expandKernel prog depth a; (y,m) <- expandKernel prog depth b; pure (CApp x y,n+m)
        CLet x a b -> do (v,n) <- expandKernel prog depth a; (body,m) <- expandKernel prog depth b; pure (CLet x v body,n+m)
        _ -> Just (e,0)

isGpuPairSum :: SpecPlan -> Bool
isGpuPairSum p = case spSoa p of
  Just ([0, 1], [acc, c0, c1], body, _) ->
    sort (addTerms (strip body)) == sort [acc, c0, c1]
  _ -> False
  where
    strip (CLet x a b) = substGpu x (strip a) (strip b)
    strip (CIf (CMk 1 1 []) t _) = strip t
    strip e = e
    addTerms (CApp (CApp (CVar "+") a) b) = addTerms a ++ addTerms b
    addTerms (CVar x) = [x]
    addTerms _ = ["<not-add>"]
    substGpu x a = go
      where
        go (CVar y) | y == x = a
        go (CApp f y) = CApp (go f) (go y)
        go (CLet y v b) | y /= x = CLet y (go v) (go b)
        go (CIf c t e) = CIf (go c) (go t) (go e)
        go e = e
