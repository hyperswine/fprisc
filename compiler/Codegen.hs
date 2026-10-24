{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}

-- Core planning and typed native generation for RV32/RV64, AArch64 and x86-64.
-- All executable functions and column kernels pass through verified typed IR.
-- Static PAPs, constructor constants and module registries have a separate
-- native data owner. Refusals are diagnostics; no text translator is retained.

module Codegen (emitProgram, emitProgramWith, Emission (..), NativeMode (..), NativeBackend (..), Granularity (..), Strict (..), externals, Target (..), rv64, rv32, codegenRev) where
-- NOTE: emitProgram's `spec` flag gates Vec.map/filter/fold loop
-- specialization. All scalar backends support the shared saved-register
-- convention; x64 uses its XMM shadow bank for s6..s11.

import Modules (ModExport (..))

import Control.Monad (when, unless)
import Control.Monad.State.Strict (evalStateT,get,put,lift)
import Data.List (intercalate, isPrefixOf, sort)
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
import KernelKinds (Kind(..))
import Workers (ScalarSignatures, internalWorker, scalarPrimitives)

import Core.Syntax (Core (..), Prog)
import Core.Utils
import Core.Primitives (corePrims, primArities)
import Core.Opt.Normalize (normIn, indexedMemory)
import Core.Opt.Vector
import Core.Opt.Vector.Plan
import Core.Opt.Pipeline

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
  let opts = OptimizationOptions
        { optFusion = tgtFusion tgt,
          optWorkers = tgtW tgt == 8 && tgtFuel tgt && tgtScalarFast tgt && not (tgtArc tgt),
          optFieldWorkers = tgtFieldWorkers tgt,
          optScalarWorkers = tgtScalarWorkers tgt,
          optNormalize = tgtScalarFast tgt,
          optReuse = tgtReuse tgt && tgtW tgt == 8 && tgtFuel tgt && not (tgtArc tgt) }
      optimized = either (error . ("Core optimization: " ++)) id (optimizeCore opts elide prog0)
      prog = optimizedProgram optimized
      workerSigs = optimizedSignatures optimized
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
      { emNotes = optimizationNotes optimized ++ concat [declines tgt spec prog fn b | (fn,(_,b)) <- M.toList emitted]
          ++ kernelNotes ++ typedIrNotes (tgtTypedIr tgt) (tgtPolicy tgt) workerSigs ext (foreignEntries tgt) prog emitted ++ notes,
        emNative = nativeText,
        emNativeNames = M.keys nativeFns,
        emScalarFallbacks = failures,
        emFallbacks = failures ++ kernelFailures,
        emData = dat }

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


-- a kernel's symbol: one per (op, element function), as requestSpec names it
specSymbol :: SpecPlan -> String
specSymbol p = case wfoldG p of
  Just g -> "fpr_vspec_wfold_" ++ mangleName (spFn p) ++ "_" ++ mangleName g
  Nothing -> "fpr_vspec_" ++ mangleName (operationKey (spOp p)) ++ "_" ++ mangleName (spFn p)

simdPlan :: Target -> Prog -> SpecPlan -> Maybe (K.SimdExpr, Int)
simdPlan tgt prog p = do
  if tgtSimd tgt && spOp p == ScalarOp Map then Just () else Nothing
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
  | Just pipeline <- pipelineOf p = Right (K.Kernel sym (planCapKinds p) (pipeElement pipeline)
      (pipeAccumulator pipeline) [K.Stage (elementOpName op) f caps | (op,f,caps) <- pipeStages pipeline] Nothing False)
  | spOp p `elem` [ScalarOp Map,ScalarOp Filter,ScalarOp Fold], spScalar p,
    spSoa p == Nothing, spMv p == Nothing =
      let k = spCaps p
          kinds = planCapKinds p
          element = case spKinds p of Just (ks,_) -> last ks; _ -> KI
          accKind = case spKinds p of Just (ks,_) -> ks !! k; _ -> KI
          folding = spOp p == ScalarOp Fold
       in Right (K.Kernel sym (kinds ++ [accKind | folding]) element
            (if folding then Just (k,accKind) else Nothing) [K.Stage (operationKey (spOp p)) (spFn p) [0..k-1]] Nothing False)
  -- the write-back fold Vec.fold f z (Vec.map g v): one pass that stores
  -- g(el) and folds f over it, the pipeline shape with map then fold
  | Just g <- wfoldG p, Just (ks,_) <- spKinds p, spScalar p =
      Right (K.Kernel sym [head ks] (last ks) (Just (0,head ks)) [K.Stage "map" g [], K.Stage "fold" (spFn p) []] Nothing False)
  | otherwise = Left ("typed " ++ operationKey (spOp p) ++ " record/SIMD kernel not implemented")

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
    spOp p `elem` [ScalarOp Fold,RecordFilter] =
      let foldOp = spOp p == ScalarOp Fold
          ncaps = spCaps p
          columnKinds = drop (ncaps + if foldOp then 1 else 0) ks
          op = if foldOp then K.RecordFold dual out else K.RecordFilter dual
       in Right (K.RecordKernel sym (spFn p) (take ncaps ks) False shape (zip cs columnKinds) op
                   (foldOp && ncaps == 0 && isGpuPairSum p),
                 M.singleton dual (ps,b))
  | otherwise = Left ("typed " ++ operationKey (spOp p) ++ " record/SIMD kernel not implemented")
  where dual = "$record:" ++ sym

emitSpecs :: Target -> Bool -> M.Map String Int -> S.Set String -> Prog -> [(String,SpecPlan)] -> ([NativeFn],[(String,String)],[String])
emitSpecs tgt rvv ext exps prog requested =
  let native pair@(sym,p) = case tgtNative tgt of
        Just nm | Just backend <- nmBackend nm -> do
          (builder, extra, roots) <- case spOp p of
           LayoutMap layout -> pure (const (K.lowerMapAsKernel (tgtPolicy tgt) (K.MapAsKernel sym (spFn p) (spCaps p) layout)), M.empty, [])
           _ -> if isJust (spSoa p) || isJust (spMv p)
            then do
              (kernel,defs) <- typedRecordPlan tgt prog sym p
              pure (\callbacks -> K.lowerRecordKernel (tgtPolicy tgt) callbacks kernel, defs, M.keys defs)
            else do
              kernel0 <- typedKernelPlan sym p
              let kernel = kernel0 {K.kernelSimd = simdPlan tgt prog p,
                                    K.kernelRvvSum = rvv && spRvv p == Just RvvFoldSum && spScalar p && spCaps p == 0}
              pure (\callbacks -> K.lowerKernel (tgtPolicy tgt)
                      (if isJust (pipelineOf p) && not (tgtPipelineInline tgt) then M.empty else callbacks) kernel,
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
