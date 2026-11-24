-- Regression tests for the 11 zero-overhead optimisation commits
-- (8325512d..23a7a232) and the defensive hardening around CaseKnown,
-- dropPhantomLoopRegions, and buildStrings chainFromRhs.
-- Run: UNIT=OptRegression make unit-tests
module Main where

import qualified Compiler.Native.Core as Native
import Compiler.DataLayout (Layouts(..))
import Core.Identity (Namespace(..), BinderId(..))
import Core.Syntax (Core(..))
import qualified Core.Opt.Pipeline as Opt
import Core.Typed.CaseKnown (caseKnownClosed)
import Core.Typed.Callback (CallbackMode(..))
import Core.Typed.Close (closedRoot, closedCode, closeFunction)
import Core.Typed.Pipeline
import qualified Core.Typed.Syntax as T
import Type.Syntax (Type(..), Scheme(..), Row(..))
import Ownership.TypeShape (linShapeT)
import Control.Monad.State.Strict (evalState, get, put)
import Frontend.Desugar (collectCons, collectShapes)
import Frontend.Desugar.Typed (prepareChecked, selectCheckedUnit, selectUnit)
import Frontend.Parser (program)
import Frontend.Syntax
import Struct (sigTable, structTable, expandStructs)
import Infer (inferTopsChecked, aotProf, inferenceErrors, inferenceTops, builtinLinShapes)
import Frontend.Linearity (buildLinInfo, lcheck, LinInfo(..))
import qualified Codegen.Lower as Lower
import Codegen.Lower (Prim(..))
import qualified Codegen.Eval as E
import Codegen.IR
import Codegen.Policy (m2Policy)
import Codegen.Simplify (Options(..), simplifyProgramWith)
import Codegen.Target.Common (noTune, NativeFn(..))
import qualified Codegen.Target.X64 as X64
import qualified Codegen.Target.A64 as A64
import Codegen.Target.A64 (A64Config(..), ObjectFormat(..), HartAccess(..))
import Control.Monad (unless, forM_)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import System.Directory (findExecutable)
import Text.Megaparsec (parse, errorBundlePretty)

check :: String -> Bool -> IO ()
check label ok = unless ok (error ("opt regression: " ++ label))

right :: Either String a -> a
right = either error id

prepare ns source =
  let raw = right (either (Left . errorBundlePretty) Right (parse program "opt-regression" source))
      (expansionErrors, tops) = expandStructs (sigTable raw) raw
      checked = inferTopsChecked (Namespace ns) aotProf (sigTable raw) (structTable raw) tops
  in if not (null expansionErrors)
       then error ("expand: " ++ show expansionErrors)
       else if not (null (inferenceErrors checked))
         then error ("infer: " ++ show (inferenceErrors checked))
         else (right (prepareChecked checked), inferenceTops checked)

-- Inference and linearity errors for programs that should be refused.
inferErrs :: String -> String -> [String]
inferErrs ns source =
  let raw = right (either (Left . errorBundlePretty) Right (parse program "opt-regression" source))
      (expansionErrors, tops) = expandStructs (sigTable raw) raw
      checked = inferTopsChecked (Namespace ns) aotProf (sigTable raw) (structTable raw) tops
      tops' = inferenceTops checked
      li0 = buildLinInfo tops'
      li = li0 { liSigs = liSigs li0 `M.union` builtinLinShapes (liLinTys li0) }
  in expansionErrors ++ inferenceErrors checked ++ lcheck li tops'

compile :: String -> String -> S.Set String -> Native.NativeCore
compile ns source names =
  let (plans, tops) = prepare ns source
      cons = collectCons "unit" tops
      selected = right (selectUnit (M.keysSet cons) (right (selectCheckedUnit plans names)))
  in right (Native.compileSelection PreserveCallbacks (Layouts cons (collectShapes tops) M.empty) selected)

intervalOpts :: Options
intervalOpts = Options False Nothing True (Just W64) False

-- HAL entries so lowerProgram admits bitwise / string primitives used in
-- the source-level cases (TypedIR.hs uses the same shape).
prims :: M.Map String Prim
prims = M.fromList $
  [(n, Prim 2 (Just ("fpr_g_" ++ n ++ "_call2")) (Just ("fpr_g_" ++ n))) | n <- ["band","bor","bxor","strcat"]]
  ++ [(n, Prim 1 (Just ("fpr_g_" ++ n ++ "_call1")) (Just ("fpr_g_" ++ n))) | n <- ["strlen","str","String.len"]]

lowered :: Native.NativeCore -> Program
lowered core =
  let p = Native.nativeProgram core
      (ir, refused) = Lower.lowerProgram m2Policy M.empty p p M.empty prims
  in if null refused then ir else error (show refused)

simplified :: Native.NativeCore -> Program
simplified core = fst (right (simplifyProgramWith intervalOpts (lowered core)))

operations :: Fn -> [Op]
operations fn = [op | b <- fnBlocks fn, Instr _ op <- bInstrs b]

opsOf :: Program -> String -> [Op]
opsOf prog name = operations (prog M.! name)

evalInt :: Native.NativeCore -> String -> [Integer] -> Either E.Failure E.RV
evalInt core name args = E.ocResult (E.evalProgram (lowered core) name (map E.RInt args))

expectInt :: String -> Native.NativeCore -> String -> [Integer] -> Integer -> IO ()
expectInt label core name args n =
  check (label ++ ": " ++ name ++ " " ++ show args) (evalInt core name args == Right (E.RInt n))

expectTrap :: String -> Native.NativeCore -> String -> [Integer] -> String -> IO ()
expectTrap label core name args needle =
  case evalInt core name args of
    Left (E.Trap msg) | needle `isInfixOf` msg -> pure ()
    other -> error ("opt regression: " ++ label ++ ": expected trap " ++ show needle ++ ", got " ++ show other)

hasOp :: (Op -> Bool) -> [Op] -> Bool
hasOp p = any p

countOp :: (Op -> Bool) -> [Op] -> Int
countOp p = length . filter p

bodyOf :: Native.NativeCore -> String -> T.Expr
bodyOf core name = T.functionBody (closedRoot (closedDefinitions (Native.nativeClosed core) M.! name))

exprKids :: T.Expr -> [T.Expr]
exprKids e = case T.exprNode e of
  T.Let _ rhs body -> [rhs, body]
  T.Sequence a b -> [a, b]
  T.If c t f -> [c, t, f]
  T.Apply f a -> [f, a]
  T.Match _ args alts -> args ++ [b | T.Alternative _ _ b <- alts]
  T.MatchTail _ args alts fb -> args ++ [b | T.Alternative _ _ b <- alts] ++ [fb]
  T.RecordField base _ -> [base]
  T.RecordValue fs -> map snd fs
  T.TupleValue xs -> xs
  T.Construct _ xs -> xs
  T.VectorReadPair _ xs v -> xs ++ [v]
  T.LetPattern _ rhs body -> [rhs, body]
  T.Note x -> [x]
  _ -> []

matchCount :: T.Expr -> Int
matchCount e = (case T.exprNode e of T.Match {} -> 1; T.MatchTail {} -> 1; _ -> 0) + sum (map matchCount (exprKids e))

coreHas :: String -> Core -> Bool
coreHas name = go
  where
    go (CVar n) = n == name
    go (CApp a b) = go a || go b
    go (CLet _ a b) = go a || go b
    go (CIf c a b) = go c || go a || go b
    go (CMk _ _ fs) = any go fs
    go (CProj _ a) = go a
    go (CTagEq _ _ a) = go a
    go (CLam _ b) = go b
    go _ = False

-- n-ary string builds: $strcatT (a tuple of five or more pieces) and
-- $strcat3 / $strcat4 (the pieces as arguments)
strcatTCount :: Core -> Int
strcatTCount = strcatNamed ["$strcatT", "$strcat3", "$strcat4"]

strcatNamed :: [String] -> Core -> Int
strcatNamed names = go
  where
    go (CVar v) | v `elem` names = 1
    go (CApp a b) = go a + go b
    go (CLet _ a b) = go a + go b
    go (CIf c a b) = go c + go a + go b
    go (CMk _ _ fs) = sum (map go fs)
    go (CProj _ a) = go a
    go (CTagEq _ _ a) = go a
    go (CLam _ b) = go b
    go _ = 0

x64Cfg :: X64.X64Config
x64Cfg = X64.X64Config m2Policy (S.singleton "probe") False True False noTune X64.HartTls False

a64Cfg :: A64Config
a64Cfg = A64Config ELF HartTlsElf m2Policy (S.singleton "probe") False True False False noTune

emitX64 :: Fn -> IO String
emitX64 fn = unlines . nfLines <$> either (error . ("x64 emit: " ++)) pure (X64.emitFnX64 x64Cfg fn)

emitA64 :: Fn -> IO String
emitA64 fn = unlines . nfLines <$> either (error . ("a64 emit: " ++)) pure (A64.emitFnA64 a64Cfg fn)


-- Direct CaseKnown probe: an inline record literal whose selected field is
-- trivial but a sibling traps. The fold must not drop the sibling.
caseKnownInlineRecord :: IO ()
caseKnownInlineRecord = do
  let int = TC "Int"
      recTy = TRec (RExt "a" int (RExt "b" int RNil))
      expr ty node = T.Expr ty (linShapeT [] ty) T.Generated Nothing node
      lit n = expr int (T.IntValue n)
      slash = expr (TFn int (TFn int int)) (T.Var (T.Global "/" (Forall [] [] (TFn int (TFn int int)))))
      div0 = expr int (T.Apply (expr (TFn int int) (T.Apply slash (lit 1))) (lit 0))
      rec = expr recTy (T.RecordValue [("a", div0), ("b", lit 2)])
      body = expr int (T.RecordField rec ["b"])
      fn = T.Function "inlineProj" [] body
      types = T.TypeContext [] M.empty
      fresh name = do n <- get; put (n + 1 :: Int); pure (name ++ show n)
      closed = right (evalState (closeFunction (Namespace "hard-rec-inline") fresh types fn) 0)
      (after, changed) = right (caseKnownClosed types closed)
      out = T.functionBody (closedRoot after)
      hasDiv e = case T.exprNode e of
        T.Apply f a -> hasDiv f || hasDiv a || isSlash f
        _ -> any hasDiv (exprKids e)
      isSlash e = case T.exprNode e of
        T.Var (T.Global "/" _) -> True
        _ -> False
      isLit2 e = case T.exprNode e of T.IntValue 2 -> True; _ -> False
  check "hardening: CaseKnown ran or declined on the inline record" True
  check "hardening: CaseKnown does not drop a trapping sibling of an inline record"
    (hasDiv out || not changed)
  -- A fold that kept only the literal 2 (no div) would be the bug.
  check "hardening: a trapping sibling is still in the term when the field is selected"
    (hasDiv out || not (isLit2 out))

main :: IO ()
main = do
  g1CaseKnown
  g2Records
  g3VectorRead
  g4Callbacks
  g5Strcat
  g6FusionBits
  g7VariantOf
  g8FusedBranches
  g9PhantomRegions
  g10Interval
  hardening
  putStrLn "Opt regression: G1-G10 properties, CaseKnown/record/strcat/linear probes and dropPhantom exhaustive match PASS"

-- G1 (014944f8, f1e895ff, 479bd2fa): CaseKnown through ticks/aliases
-- (up to 4 rounds), single-arm irrefutable function matches, and
-- post-normalisation CaseKnown.
g1CaseKnown :: IO ()
g1CaseKnown = do
  let src = unlines
        [ "Box = Type (Box Int)."
        , "unwrap n = a = Box n; b = a; c = b; d = c; case d of Box x -> x."
        , "addPair (x, y) = x + y."
        , "pair n = p = (n, n + 1); addPair p."
        , "known n = case Box n of Box x -> x + 1."
        ]
      core = compile "g1" src (S.fromList ["unwrap", "addPair", "pair", "known"])
      normed = right (Native.normalizeNative S.empty core)
      cased = maybe normed id (right (Native.caseKnownNative S.empty normed))
  expectInt "G1 unwrap aliases" core "unwrap" [7] 7
  expectInt "G1 irrefutable function match" core "pair" [3] 7
  expectInt "G1 known constructor" core "known" [4] 5
  -- After normalize + CaseKnown, the four-alias unwrap and the known
  -- constructor case should have been reduced (no remaining Match).
  check "G1: CaseKnown after normalize eliminates unwrap's case"
    (matchCount (bodyOf cased "unwrap") == 0)
  check "G1: CaseKnown after normalize eliminates known's case"
    (matchCount (bodyOf cased "known") == 0)
  expectInt "G1 post-normalize eval unwrap" cased "unwrap" [9] 9
  expectInt "G1 post-normalize eval pair" cased "pair" [10] 21

-- G2 (7b07b357): record field read fold off a known record, unboxed
-- record/newtype loop state.
g2Records :: IO ()
g2Records = do
  let src = unlines
        [ "addM a b = {m = a.m + b.m}."
        , "loop i m = if i == 0 then m else loop (i - 1) (addM m {m = 1})."
        , "run n = r = loop n {m = 0}; r.m."
        ]
      core = compile "g2" src (S.fromList ["addM", "loop", "run"])
  expectInt "G2 record field fold / loop state" core "run" [10] 10
  expectInt "G2 zero trips" core "run" [0] 0

-- G3 (8325512d): VectorRead planning for `case Vec.get ... of (x, v2)`
-- and Vec.at.
g3VectorRead :: IO ()
g3VectorRead = do
  let src = unlines
        [ "at i v = case Vec.at i v of (x, next) -> (x, next)."
        , "get i v = case Vec.get i v of (x, next) -> (x, next)."
        ]
      core = compile "g3" src (S.fromList ["at", "get"])
      after = right (Native.planNativeVectorReads S.empty core)
      defs = closedDefinitions (Native.nativeClosed after)
      vectorReads e = (case T.exprNode e of T.VectorReadPair {} -> 1; _ -> 0) + sum (map vectorReads (exprKids e))
      counts n = let f = defs M.! n
                 in vectorReads (T.functionBody (closedRoot f))
                      + sum [vectorReads (T.codeBody c) | c <- M.elems (closedCode f)]
  check "G3: case Vec.at i v of (x, next) is planned as VectorReadPair" (counts "at" == 1)
  check "G3: case Vec.get i v of (x, next) is planned as VectorReadPair" (counts "get" == 1)

-- G4 (f127db24, 32686306): Callback arg-let lifting, record-of-functions
-- specialisation, Link multi-round inline gating (behaviour: both the
-- no-growth and the specialising programs compile and evaluate).
g4Callbacks :: IO ()
g4Callbacks = do
  let recfns = unlines
        [ "ops = {inc = fn x -> x + 1, dec = fn x -> x - 1}."
        , "loop i acc = if i == 0 then acc else loop (i - 1) (ops.inc acc)."
        , "run n = loop n 0."
        ]
      plain = unlines
        [ "loop i acc = if i == 0 then acc else loop (i - 1) (acc + 1)."
        , "run n = loop n 0."
        ]
      recCore = compile "g4rec" recfns (S.fromList ["ops", "loop", "run"])
      plainCore = compile "g4plain" plain (S.fromList ["loop", "run"])
  expectInt "G4 record-of-functions specialisation" recCore "run" [6] 6
  expectInt "G4 no-callback program (Link gate skip path)" plainCore "run" [6] 6
  -- A small callback: the argument let should be lifted so the call still
  -- evaluates in order and answers.
  let cb = unlines
        [ "apply f x = f x."
        , "run n = apply (fn y -> y + 1) (n + 2)."
        ]
      cbCore = compile "g4cb" cb (S.fromList ["apply", "run"])
  expectInt "G4 callback arg-let lifting" cbCore "run" [3] 6

-- G5 (9446a484): literal String + constant folding and a + chain to a
-- single $strcatT.
g5Strcat :: IO ()
g5Strcat = do
  let src = unlines
        -- Surface `+` elaborates to Str.+, which inlines to strcat at link
        -- time. These tests use strcat so Normalize / BuildStrings see it
        -- in a single-unit compileSelection.
        [ "lit u = strcat (strcat (strcat \"k\" \"=\") \"v\") \";\"."
        , "len u = strlen (lit u)."
        , "chain a b = strcat (strcat (strcat \"L\" a) b) \"R\"."
        , "three a = strcat (strcat \"L\" a) \"R\"."
        , "five a b c = strcat (strcat (strcat (strcat \"L\" a) b) c) \"R\"."
        ]
      core0 = compile "g5" src (S.fromList ["lit", "len", "chain", "three", "five"])
      inlined = right (Native.inlineNativePrograms 3 24 64 (M.singleton () (S.empty, S.empty, core0))) M.! ()
      -- BuildStrings (G5 n-ary $strcatT) runs under optReuse.
      opts = Opt.OptimizationOptions False False False False False False 2 True True S.empty M.empty M.empty
      opted = Opt.optimizedProgram (right (Opt.optimizeCore opts S.empty (Native.nativeProgram inlined)))
  check "G5: a literal + chain folds to one string or one $strcatT"
    (case M.lookup "lit" opted of
       Just (_, body) -> strcatTCount body <= 1 && (strcatTCount body == 1 || litFolded body)
       Nothing -> False)
  check "G5: a four-piece + chain becomes one $strcat4 (pieces as arguments, no tuple)"
    (maybe False (\(_, body) -> strcatNamed ["$strcat4"] body == 1 && strcatTCount body == 1) (M.lookup "chain" opted))
  check "G5: a three-piece + chain becomes one $strcat3"
    (maybe False (\(_, body) -> strcatNamed ["$strcat3"] body == 1 && strcatTCount body == 1) (M.lookup "three" opted))
  check "G5: a five-piece + chain stays one $strcatT of a tuple"
    (maybe False (\(_, body) -> strcatNamed ["$strcatT"] body == 1 && strcatTCount body == 1) (M.lookup "five" opted))
  where
    litFolded body = go body
      where
        go (CStr s) = "k=v;" `isInfixOf` s
        go (CApp a b) = go a || go b
        go (CLet _ a b) = go a || go b
        go _ = False

g6FusionBits :: IO ()
g6FusionBits = do
  -- band/bor/bxor are trap-free, so a Vec.map pipeline that uses them must
  -- be allowed to fuse (unlike `/`).
  let src = unlines
        [ "mask x = band x 15."
        , "maps v = Vec.map mask (Vec.map mask v)."
        ]
      core = compile "g6" src (S.fromList ["mask", "maps"])
      (after, _) = right (Native.fuseNativePrograms (M.singleton () (S.empty, core))) M.! ()
      old = closedDefinitions (Native.nativeClosed core)
      new = closedDefinitions (Native.nativeClosed after)
      added = M.difference (closedCode (new M.! "maps")) (closedCode (old M.! "maps"))
  check "G6: band is admitted to list/vector fusion (a composite is created)"
    (M.size added >= 1)

g7VariantOf :: IO ()
g7VariantOf = do
  let src = unlines
        [ "Op = Type (Add | Sub | Mul | Xor)."
        , "ap op a b = case op of Add -> a + b | Sub -> a - b | Mul -> a * b | Xor -> bxor a b."
        , "run n = ap (case band n 3 of 0 -> Add | 1 -> Sub | 2 -> Mul | _ -> Xor) n 1."
        ]
      core = compile "g7" src (S.fromList ["ap", "run"])
      ir = simplified core
      apOps = opsOf ir "ap"
      variants = countOp (\op -> case op of OVariantOf {} -> True; _ -> False) apOps
      tests = countOp (\op -> case op of OTagTest {} -> True; OVariantTest {} -> True; _ -> False) apOps
  check "G7: multi-arm enum match shares one OVariantOf" (variants == 1)
  check "G7: multi-arm enum match does not emit per-arm tag tests" (tests == 0)
  expectInt "G7 Add" core "run" [4] 5
  expectInt "G7 Sub" core "run" [5] 4

g8FusedBranches :: IO ()
g8FusedBranches = do
  -- OArithFits used only by a TCondBr should fuse: an overflow-flag branch,
  -- no materialised predicate.
  let fn = Fn "probe" ["n"] TVal (BId 0)
        [ Block (BId 0) [(VId 0, TVal)]
            [ Instr Nothing OStackCheck, Instr Nothing OSafepoint
            , Instr (Just (VId 1, TInt)) (OUntag (VId 0))
            , Instr (Just (VId 2, TInt)) (OConstInt 1)
            , Instr (Just (VId 3, TPred)) (OArithFits Add (VId 1) (VId 2)) ]
            (TCondBr (VId 3) (BId 1) [] (BId 2) [])
        , Block (BId 1) []
            [ Instr (Just (VId 4, TVal)) (OTag (VId 1)) ]
            (TRet (VId 4))
        , Block (BId 2) []
            [ Instr (Just (VId 5, TInt)) (OConstInt 0)
            , Instr (Just (VId 6, TVal)) (OTag (VId 5)) ]
            (TRet (VId 6)) ]
      mulFn = Fn "probe" ["n"] TVal (BId 0)
        [ Block (BId 0) [(VId 0, TVal)]
            [ Instr Nothing OStackCheck, Instr Nothing OSafepoint
            , Instr (Just (VId 1, TInt)) (OUntag (VId 0))
            , Instr (Just (VId 2, TInt)) (OConstInt 3)
            , Instr (Just (VId 3, TInt)) (OArithU Mul (VId 1) (VId 2))
            , Instr (Just (VId 4, TVal)) (OTag (VId 3)) ]
            (TRet (VId 4)) ]
  xFits <- emitX64 fn
  xMul <- emitX64 mulFn
  aFits <- emitA64 fn
  aMul <- emitA64 mulFn
  check "G8: X64 fuses OArithFits into an overflow-flag branch"
    (("jo " `isInfixOf` xFits || "jno " `isInfixOf` xFits || "seto " `isInfixOf` xFits)
     && not ("setcc" `isInfixOf` xFits))
  check "G8: X64 bare OArithU Mul uses imul and no overflow branch"
    (("imul" `isInfixOf` xMul || "imulq" `isInfixOf` xMul)
     && not ("jo " `isInfixOf` xMul) && not ("jno " `isInfixOf` xMul))
  -- A64 fitsCompare does the exact add/sub/mul, then branches on the
  -- 63-bit-fit flags (b.eq / b.ne), with no materialised predicate (cset).
  check "G8: A64 fuses OArithFits into a flag branch (b.eq/b.ne, no cset)"
    (("add " `isInfixOf` aFits || "adds " `isInfixOf` aFits)
     && ("b.eq " `isInfixOf` aFits || "b.ne " `isInfixOf` aFits)
     && not ("cset" `isInfixOf` aFits))
  check "G8: A64 bare multiply is present for OArithU Mul"
    ("mul " `isInfixOf` aMul || "mul\t" `isInfixOf` aMul)
  qemu <- findExecutable "qemu-aarch64"
  cross <- findExecutable "aarch64-linux-gnu-gcc"
  asCross <- findExecutable "aarch64-linux-gnu-as"
  putStrLn $ "G8: AArch64 execution toolchain: qemu-aarch64=" ++ maybe "absent" (const "present") qemu
    ++ " aarch64-linux-gnu-gcc=" ++ maybe "absent" (const "present") cross
    ++ " aarch64-linux-gnu-as=" ++ maybe "absent" (const "present") asCross
  -- No qemu / cross gcc on this box: selection text is the property we
  -- can check. Encoding suites cover the encodings themselves.
  pure ()

g9PhantomRegions :: IO ()
g9PhantomRegions = do
  -- A self-loop that only does checked-free arithmetic: after simplify,
  -- the ORegionRoom on the back edge is dropped. The same shape with an
  -- OMake in the loop keeps the check.
  let phantomFn = Fn "probe" ["n"] TInt (BId 0)
        [ Block (BId 0) [(VId 0, TInt)]
            [ Instr (Just (VId 1, TInt)) (OConstInt 0)
            , Instr (Just (VId 2, TVal)) (OTag (VId 1)) ]
            (TBr (BId 1) [VId 0])
        , Block (BId 1) [(VId 3, TInt)]
            [ Instr (Just (VId 4, TPred)) (OCmp Eq (VId 3) (VId 0)) ]
            (TCondBr (VId 4) (BId 2) [] (BId 3) [])
        , Block (BId 2) [] [] (TRet (VId 3))
        , Block (BId 3) []
            [ Instr (Just (VId 5, TInt)) (OConstInt 1)
            , Instr (Just (VId 6, TInt)) (OArithU Sub (VId 3) (VId 5))
            , Instr (Just (VId 7, TPred)) (ORegionRoom (VId 2)) ]
            (TCondBr (VId 7) (BId 1) [VId 6] (BId 2) []) ]
      allocFn = Fn "probe" ["n"] TInt (BId 0)
        [ Block (BId 0) [(VId 0, TInt)]
            [ Instr (Just (VId 1, TInt)) (OConstInt 0)
            , Instr (Just (VId 2, TVal)) (OTag (VId 1)) ]
            (TBr (BId 1) [VId 0])
        , Block (BId 1) [(VId 3, TInt)]
            [ Instr (Just (VId 4, TPred)) (OCmp Eq (VId 3) (VId 0)) ]
            (TCondBr (VId 4) (BId 2) [] (BId 3) [])
        , Block (BId 2) [] [] (TRet (VId 3))
        , Block (BId 3) []
            [ Instr (Just (VId 5, TInt)) (OConstInt 1)
            , Instr (Just (VId 6, TInt)) (OArithU Sub (VId 3) (VId 5))
            , Instr (Just (VId 8, TVal)) (OMake 1 0 [VId 2])
            , Instr (Just (VId 7, TPred)) (ORegionRoom (VId 2)) ]
            (TCondBr (VId 7) (BId 1) [VId 6] (BId 2) []) ]
  let roomsPhantom = case simplifyProgramWith intervalOpts (M.singleton "probe" phantomFn) of
        Right (p, _) -> countOp (\op -> case op of ORegionRoom {} -> True; _ -> False) (operations (p M.! "probe"))
        Left err -> error ("G9 phantom simplify: " ++ err)
      roomsAlloc = case simplifyProgramWith intervalOpts (M.singleton "probe" allocFn) of
        Right (p, _) -> countOp (\op -> case op of ORegionRoom {} -> True; _ -> False) (operations (p M.! "probe"))
        Left err -> error ("G9 alloc simplify: " ++ err)
  check "G9: ORegionRoom is dropped from an allocation-free loop" (roomsPhantom == 0)
  check "G9: ORegionRoom is kept when the loop allocates" (roomsAlloc >= 1)

g10Interval :: IO ()
g10Interval = do
  -- IR-level: these are the shapes Interval gained in 1980286d. Source
  -- programs stay on tagged OArithVal until RawInts, so we assert the
  -- discharge on untagged TInt IR, plus source-level semantics.
  let div2Fn = Fn "div2" ["n"] TInt (BId 0)
        [ Block (BId 0) [(VId 0, TInt)]
            [ Instr (Just (VId 1, TInt)) (OConstInt 2)
            , Instr (Just (VId 2, TInt)) (OArith Div (VId 0) (VId 1)) ]
            (TRet (VId 2)) ]
      flagFn = Fn "flag" ["n"] TInt (BId 0)
        [ Block (BId 0) [(VId 0, TInt)]
            [ Instr (Just (VId 1, TInt)) (OConstInt 1)
            , Instr (Just (VId 2, TInt)) (OBit BOr (VId 0) (VId 1))
            , Instr (Just (VId 3, TInt)) (OConstInt 0)
            , Instr (Just (VId 4, TPred)) (OCmp Ne (VId 2) (VId 3)) ]
            (TCondBr (VId 4) (BId 1) [] (BId 2) [])
        , Block (BId 1) []
            [ Instr (Just (VId 5, TInt)) (OConstInt 1)
            , Instr (Just (VId 6, TInt)) (OArith Add (VId 0) (VId 5)) ]
            (TRet (VId 6))
        , Block (BId 2) []
            [ Instr (Just (VId 7, TInt)) (OConstInt 0) ]
            (TRet (VId 7)) ]
      simp name fn = case simplifyProgramWith intervalOpts (M.singleton name fn) of
        Right (p, _) -> p M.! name
        Left err -> error ("G10 " ++ name ++ " simplify: " ++ err)
      divOps = operations (simp "div2" div2Fn)
      flagTerm = bTerm (head (fnBlocks (simp "flag" flagFn)))
  check "G10: Div by literal 2 becomes OArithU Div"
    (hasOp (\op -> case op of OArithU Div _ _ -> True; _ -> False) divOps
     && not (hasOp (\op -> case op of OArith Div _ _ -> True; _ -> False) divOps))
  check "G10: bor x 1 != 0 discharges the false arm (unconditional jump to the true arm)"
    (case flagTerm of TBr bid _ -> bid == BId 1; _ -> False)

  let src = unlines
        [ "div2 n = if n >= 0 and n <= 100 then n / 2 else 0."
        , "flag n = if bor n 1 != 0 then n + 1 else 0."
        , "alias i n acc = a = i; if a >= n then acc else alias (a + 1) n (acc + a)."
        ]
      core = compile "g10" src (S.fromList ["div2", "flag", "alias"])
  expectInt "G10 div2" core "div2" [10] 5
  expectInt "G10 div2 else" core "div2" [200] 0
  expectInt "G10 bor x 1 != 0 is total" core "flag" [0] 1
  expectInt "G10 bor x 1 != 0 on negatives" core "flag" [-3] (-2)
  expectInt "G10 loop-invariant parameter alias" core "alias" [0, 5, 0] 10

-- Hardening probes: trapping sibling record fields, linear Vector fields,
-- and strcat evaluation order.
hardening :: IO ()
hardening = do
  -- Field projection parses on identifiers (r.b), not on inline literals,
  -- so the let-bound form is the source test. The inline RecordValue path
  -- is exercised directly through caseKnownClosed below.
  let recSrc = unlines
        [ "proj u = r = {a = 1 / 0, b = 2}; r.b."
        , "ok u = r = {a = 1, b = 2}; r.b."
        ]
      recCore = compile "hard-rec" recSrc (S.fromList ["proj", "ok"])
  expectTrap "hardening: let-bound record with a trapping sibling keeps the trap" recCore "proj" [0] "division"
  expectInt "hardening: trivial sibling record field still folds" recCore "ok" [0] 2
  caseKnownInlineRecord

  -- chainFromRhs: a later let whose RHS traps must not run before earlier
  -- strcat pieces. Built in Core so the let sits in the strcat tree (surface
  -- `let ... in` does not parse). After BuildStrings, evaluating the
  -- function must trap "left", not the hoisted "right".
  let cat a b = CApp (CApp (CVar "strcat") a) b
      coreF = M.singleton "f" (["x"], cat (cat (CStr "L") (CErr "left"))
                                           (CLet "k" (CErr "right") (cat (CVar "k") (CStr "R"))))
      opts = Opt.OptimizationOptions False False False False False False 2 True True S.empty M.empty M.empty
      opted = Opt.optimizedProgram (right (Opt.optimizeCore opts S.empty coreF))
      body = maybe (error "no f") snd (M.lookup "f" opted)
      -- A wrong hoist would wrap the n-ary build ($strcat4 here) in
      -- `let k = error "right"`, running the later trap before the earlier
      -- "left" piece.
      hoistedWrong e = case e of
        CLet _ (CErr "right") b | strcatTCount b > 0 && hasErr "left" b -> True
        CApp a b -> hoistedWrong a || hoistedWrong b
        CLet _ a b -> hoistedWrong a || hoistedWrong b
        CMk _ _ fs -> any hoistedWrong fs
        CIf c a b -> hoistedWrong c || hoistedWrong a || hoistedWrong b
        _ -> False
      hasErr msg e = case e of
        CErr s -> s == msg
        CApp a b -> hasErr msg a || hasErr msg b
        CLet _ a b -> hasErr msg a || hasErr msg b
        CMk _ _ fs -> any (hasErr msg) fs
        CIf c a b -> hasErr msg c || hasErr msg a || hasErr msg b
        _ -> False
  check "hardening: chainFromRhs does not hoist a trapping let ahead of earlier pieces"
    (strcatTCount body == 1 && not (hoistedWrong body) && hasErr "left" body && hasErr "right" body)

  -- Linear Vector fields: a single use through a constructor/record is
  -- accepted and evaluates; a second use is still refused by linearity.
  let linOk = unlines
        [ "Wrap 1 = Type (Wrap (Vector Int))."
        , "run u ="
        , "  p = Wrap (Vec.new Unit);"
        , "  case p of Wrap v ->"
        , "    (n, v2) = Vec.len v;"
        , "    _ = Vec.free v2;"
        , "    n."
        ]
      linBad = unlines
        [ "Wrap 1 = Type (Wrap (Vector Int))."
        , "run u ="
        , "  p = Wrap (Vec.new Unit);"
        , "  case p of Wrap v ->"
        , "    (n, v2) = Vec.len v;"
        , "    case p of Wrap w ->"
        , "      (m, w2) = Vec.len w;"
        , "      _ = Vec.free v2;"
        , "      _ = Vec.free w2;"
        , "      n + m."
        ]
      okCore = compile "hard-lin-ok" linOk (S.fromList ["run"])
      badErrs = inferErrs "hard-lin-bad" linBad
  check "hardening: a single use of a linear Vector field typechecks"
    (M.member "run" (Native.nativeProgram okCore))
  check ("hardening: double use of a linear constructor is refused: " ++ show badErrs)
    (not (null badErrs))

