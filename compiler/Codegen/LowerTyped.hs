{-# LANGUAGE LambdaCase #-}
-- Codegen.LowerTyped: typed Core -> native typed CFGs, for the first class
-- of checked functions (P2 typed lowering, slice 1:
-- docs/2026-11-08-P2-TYPED-LOWERING-SLICE-1.md).
--
-- The class: any signature (slice 1 had Int and Bool; slices 3a and 3b
-- admit any type, monomorphic or not, since every value of a public function
-- is a tagged word), first-order, calls to known functions and the integer
-- operators, literal/binder/Bool matches with Boolean guards. Everything else is refused with a reason naming the
-- form, as Codegen.Lower refuses.
--
-- Slice 1 runs this beside the erased lowering and requires the same SSA, so
-- the dispatch follows Codegen.Lower form for form and shares its emission
-- core. A match is planned the way the erasure boundary plans it
-- (Core.Typed.Erase: scrutinee binding, test order, fallback duplication,
-- the Bool-coverage shortcut) with typed leaves; where erasure would build
-- a join or a lambda, this lowering refuses.
module Codegen.LowerTyped (lowerFn, Layout (..)) where

import Core.Region.Runtime (Hook (..), hookName)
import Codegen.IR
import Codegen.Lower (Prim, Reason, L, Cx (..), lowerEntry, refuse, ended, newBlock, newBlock1,
  open, suspend, resume, emit, emitDo, close, coerce, asVal, asInt, asPred, unify, calleeOf, isPrimName,
  lowerGlobal, nullaryValue, arithOps, cmpOps, isStaticNominalTid)
import Codegen.Policy
import Core.Identity (BinderId)
import Core.Syntax (Core (..), Prog)
import Type.Syntax (Type (..))
import Core.Typed.Syntax hiding (Local)
import qualified Core.Typed.Syntax as T
import Control.Monad (when)
import Control.Monad.Except (throwError)
import Data.List (intercalate)
import qualified Data.Map.Strict as M

-- The constructor facts a Bool pattern needs, from the closed program
-- (the same layout authority erasure reads).
data Layout = Layout
  { layoutConstructor :: String -> Maybe (Int, Int, Int),
    layoutConstructors :: [String] }

-- A local the lowering bound: a checked binder, or a scrutinee the match
-- plan names (erasure's fresh `scrut`).
data Key = KBinder BinderId | KScrut Int deriving (Eq, Ord, Show)

-- The planned body: the shapes erasure produces for S1, with typed leaves.
data TE
  = PRef Key
  | PGlobal String
  | PInt Integer
  | PBool Bool
  | PApp String [TE]
  | PTick
  | PIf TE TE TE
  | PLet Key TE TE
  | PErr String
  | PEqInt TE Integer -- erased `(==) scrutinee n`
  | PTag Int Int TE -- erased `CTagEq tid variant scrutinee`

-- The shapes Codegen.Lower dispatches on, read from a plan node.
data V
  = VVar Key
  | VGlobal String
  | VInt Integer
  | VBool Bool
  | VApp String [TE]
  | VLet Key TE TE
  | VIf TE TE TE
  | VErr String
  | VTag Int Int TE
  | VEqInt TE Integer
  | VTick

type TEnv = M.Map Key (VId, Ty)

data Plan = Plan {planLayout :: Layout, planNext :: Int}

lowerFn :: Policy -> Layout -> Prog -> M.Map String Int -> M.Map String Prim -> Function -> Either Reason Fn
lowerFn policy layout prog ext hal f = do
  planned <- plan layout (functionBody f)
  lowerEntry policy M.empty prog ext hal (functionName f) (map binderName (functionParameters f)) $ \cx pvs ->
    lowerTail cx (M.fromList (zip (map (KBinder . binderId) (functionParameters f)) pvs)) planned

-- Plan the whole body once, before lowering, with one supply of scrutinee
-- names: the plan is pure, and erasure's fallback duplication lowers the same
-- subtree more than once.
plan :: Layout -> Expr -> Either Reason TE
plan layout body = fst <$> go 0 body
  where
    go :: Int -> Expr -> Either Reason (TE, Int)
    go n e = case exprNode e of
      Note x -> go n x
      Var (T.Local uid) -> pure (PRef (KBinder uid), n)
      Var (Global name _) -> pure (PGlobal name, n)
      IntValue i -> pure (PInt i, n)
      BoolValue b -> pure (PBool b, n)
      BoolTest b x -> do (x', n1) <- go n x; pure (PTag 1 (if b then 1 else 0) x', n1)
      EntryTick -> pure (PTick, n)
      Fail m -> pure (PErr m, n)
      Let p a b -> do
        (a', n1) <- go n a
        (b', n2) <- go n1 b
        pure (PLet (KBinder (binderId p)) a' b', n2)
      If a b c -> do
        (a', n1) <- go n a
        (b', n2) <- go n1 b
        (c', n3) <- go n2 c
        pure (PIf a' b' c', n3)
      Apply _ _ -> case spine e [] of
        (h, args) -> case exprNode h of
          Var (Global name _) -> do
            (args', n1) <- goList n args
            pure (PApp name args', n1)
          _ -> Left "typed lowering: an application whose head is not a known name"
      -- a call region (placement's typed result): erasure's token binding
      -- around the call (Core.Typed.Erase); the two operations are lowered
      -- as foreign calls (regionHooks)
      CallRegion x -> do
        (x', n1) <- go (n + 1) x
        let k = KScrut n
        pure (PLet k (PApp (hookName CallPending) [PInt 0]) (PApp (hookName CallLeave) [PRef k, x']), n1)
      Match CaseMatch [arg] alts -> do
        (arg', n1) <- go n arg
        let k = KScrut n1
            message = "case: no matching pattern; arms were [" ++ intercalate "," [patDisplay p | Alternative [p] _ _ <- alts] ++ "]"
        (arms, n2) <- caseArms (n1 + 1) True (PErr message) (PRef k) alts
        pure (PLet k arg' arms, n2)
      Match (FunctionMatch owner) args alts -> do
        (args', n1) <- goList n args
        functionArms n1 True (PErr ("no matching clause for " ++ owner)) args' alts
      MatchTail CaseMatch [arg] alts fallback -> do
        (arg', n1) <- go n arg
        (fb, n2) <- go n1 fallback
        caseArms n2 False fb arg' alts
      MatchTail (FunctionMatch _) args alts fallback -> do
        (args', n1) <- goList n args
        (fb, n2) <- go n1 fallback
        functionArms n2 False fb args' alts
      Match {} -> Left "typed lowering: a malformed case arity"
      MatchTail {} -> Left "typed lowering: a malformed match tail"
      other -> Left ("typed lowering: the form " ++ formName other)
    goList n [] = pure ([], n)
    goList n (x : xs) = do
      (x', n1) <- go n x
      (xs', n2) <- goList n1 xs
      pure (x' : xs', n2)
    spine x acc = case exprNode x of
      Apply f a -> spine f (a : acc)
      Note y -> spine y acc
      _ -> (x, acc)
    caseArms n0 makeJoins fallback scrut alts = loop n0 True alts
      where
        loop n _ [] = pure (fallback, n)
        loop n first (Alternative [p] gs body : rest) = do
          (next, n1) <- loop n False rest
          when (makeJoins && not (trivial next) && tests p + length gs > 1)
            (Left "typed lowering: a case fallback join (erasure builds a lambda)")
          (body', n2) <- go n1 body
          (inner, n3) <- guards n2 gs body' next
          certain <- if null rest && not first && all (\(Alternative _ g _) -> null g) alts
            then coveredHead p else pure False
          matched <- if certain then case patNode p of
              ConstructorPattern _ [] -> pure inner
              _ -> matchPat scrut p inner next
            else matchPat scrut p inner next
          pure (matched, n3)
        loop _ _ _ = Left "typed lowering: a case pattern arity"
        coveredHead p = case patNode p of
          ConstructorPattern name _ -> do
            (tid, _, _) <- constructor name
            let earlier = [c | Alternative [q] _ _ <- init alts, ConstructorPattern c ps <- [patNode q], all irrefutable ps]
                siblings = [c | c <- layoutConstructors layout, Just (t, _, _) <- [layoutConstructor layout c], t == tid, c /= name]
            pure (all (`elem` earlier) siblings)
          _ -> pure False
    functionArms n0 makeJoins bottom args alts = loop n0 alts
      where
        loop n [] = pure (bottom, n)
        loop n (Alternative ps gs body : rest) = do
          (next, n1) <- loop n rest
          when (makeJoins && sum (map tests ps) + length gs > 1 && not (trivial next))
            (Left "typed lowering: a function clause join")
          when (length ps /= length args) (Left "typed lowering: a function clause arity")
          (body', n2) <- go n1 body
          (inner, n3) <- guards n2 gs body' next
          matched <- foldr (\(x, p) k -> k >>= \b -> matchPat x p b next) (pure inner) (zip args ps)
          pure (matched, n3)
    guards n [] ok _ = pure (ok, n)
    guards n (g : rest) ok fallback = case g of
      BoolGuard e -> do
        (e', n1) <- go n e
        (inner, n2) <- guards n1 rest ok fallback
        pure (PIf e' inner fallback, n2)
      PatternGuard _ _ -> Left "typed lowering: a pattern guard"
    matchPat scrut p ok failed = case patNode p of
      Wildcard -> pure ok
      Bind b -> pure (PLet (KBinder (binderId b)) scrut ok)
      IntegerPattern i -> pure (PIf (PEqInt scrut i) ok failed)
      ConstructorPattern name [] | name `elem` ["True", "False"] -> do
        (tid, variant, _) <- constructor name
        pure (PIf (PTag tid variant scrut) ok failed)
      _ -> Left ("typed lowering: the pattern " ++ patDisplay p)
    constructor name = maybe (Left ("typed lowering: unknown constructor " ++ name)) Right (layoutConstructor layout name)
    tests p = case patNode p of
      IntegerPattern _ -> 1 :: Int
      StringPattern _ -> 1
      ConstructorPattern _ ps -> 1 + sum (map tests ps)
      TuplePattern ps -> 1 + sum (map tests ps)
      _ -> 0
    irrefutable p = case patNode p of Bind _ -> True; Wildcard -> True; RecordPattern _ -> True; _ -> False
    -- erasure's `trivial`: the fallback erases to CErr
    trivial = \case
      PErr _ -> True
      _ -> False

-- Read a plan node as the Core shape Codegen.Lower dispatches on.
view :: TE -> V
view = \case
  PRef k -> VVar k
  PGlobal n -> VGlobal n
  PInt n -> VInt n
  PBool b -> VBool b
  PApp h args -> VApp h args
  PTick -> VTick
  PIf c a b -> VIf c a b
  PLet k a b -> VLet k a b
  PErr m -> VErr m
  PEqInt s n -> VEqInt s n
  PTag t v s -> VTag t v s

formName :: Node -> String
formName = \case
  StringValue _ -> "string literal"
  Lambda _ _ -> "lambda"
  LetRec {} -> "recursive let"
  Construct {} -> "constructor"
  AtomValue _ -> "atom"
  TupleValue _ -> "tuple"
  ListValue _ -> "list literal"
  RecordValue _ -> "record"
  RecordField {} -> "record field"
  RecordUpdate {} -> "record update"
  PlannedUpdate {} -> "planned record update"
  ResultPipe {} -> "result pipe"
  Sequence {} -> "sequence"
  LetPattern {} -> "pattern binding"
  ClosureValue {} -> "closure"
  CodeCall {} -> "code call"
  JoinCall {} -> "join call"
  LayoutLiteral _ -> "layout literal"
  VectorBuild {} -> "vector build"
  VectorReadPair {} -> "vector read"
  CallRegion _ -> "call region"
  ListBuilder {} -> "list builder"
  SetField {} -> "field store"
  _ -> "node"

-- the call region operations: HAL primitives (Compile's region arities)
-- that Codegen.Lower lowers as foreign calls through calleeOf
regionHooks :: [String]
regionHooks = map hookName [CallPending, CallLeave]

-- Each function below follows its namesake in Codegen.Lower for the S1 shapes.

lowerTail :: Cx -> TEnv -> TE -> L ()
lowerTail cx env expr = ended (go expr) >> pure ()
  where
    go te = case view te of
      VLet k a b -> lowerBind cx env k a >>= \env' -> lowerTail cx env' b
      VIf c t f -> do
        p <- lowerCond cx env c
        (bt, _) <- newBlock []
        (bf, _) <- newBlock []
        close (TCondBr p bt [] bf [])
        open bt [] >> lowerTail cx env t
        open bf [] >> lowerTail cx env f
      VErr msg -> close (TUnreachable msg)
      VGlobal h | polProfile (cxPolicy cx) == BuiltinArc,
        not (case M.lookup h (cxProg cx) of Just ([], CMk _ _ []) -> True; _ -> False),
        Just c <- calleeOf cx h 0 ->
          if h == cxSelf cx then close (TBr (cxEntry cx) [])
          else close (TTailCall c [])
      VApp h _
        | isPrimName cx h, M.notMember h arithOps, M.notMember h cmpOps, h `notElem` regionHooks ->
            refuse ("typed lowering: the primitive `" ++ h ++ "`")
      VApp h args@(_ : _)
        | Just c <- calleeOf cx h (length args) -> do
            as <- mapM (lowerVal cx env) args
            if h == cxSelf cx
              then do
                as' <- mapM (uncurry coerce) (zip as (cxEntryTys cx))
                close (TBr (cxEntry cx) as')
              else do
                when (calleeResult c /= cxResult cx) $ refuse ("a tail call to " ++ h ++ " answers " ++ show (calleeResult c) ++ ", this function " ++ show (cxResult cx))
                as' <- mapM (uncurry coerce) (zip as (calleeParams c))
                close (TTailCall c as')
      _ -> do
        r <- lowerVal cx env te
        v <- coerce r (cxResult cx)
        close (TRet v)

lowerBind :: Cx -> TEnv -> Key -> TE -> L TEnv
lowerBind cx env k a = case view a of
  VVar y | Just b <- M.lookup y env -> pure (M.insert k b env)
  _ -> do
    r <- lowerVal cx env a
    pure (M.insert k r env)

lowerCond :: Cx -> TEnv -> TE -> L VId
lowerCond cx env te = case view te of
  VLet k a b -> lowerBind cx env k a >>= \env' -> lowerCond cx env' b
  _ -> lowerVal cx env te >>= asPred

lowerVal :: Cx -> TEnv -> TE -> L (VId, Ty)
lowerVal cx env te = case view te of
  VVar k -> maybe (refuse "typed lowering: an unbound local") pure (M.lookup k env)
  VGlobal x -> lowerGlobal cx x
  VInt n -> int n
  VBool b -> nullaryValue 1 (if b then 1 else 0)
  VErr msg -> close (TUnreachable msg) >> throwError ()
  VTick -> when (polFuel (cxPolicy cx)) (emitDo OSafepoint) >> nullaryValue 0 0
  VTag 1 variant c -> do
    value@(x, ty) <- lowerVal cx env c
    p <- case (ty, variant) of
      (TPred, 1) -> pure x
      (TPred, 0) -> emit TPred (ONot x)
      _ -> asVal value >>= emit TPred . OTagTest 1 variant
    pure (p, TPred)
  VTag t v c -> do
    x <- lowerVal cx env c >>= asVal
    let op = if polTypedCase (cxPolicy cx) && isStaticNominalTid t then OVariantTest t v x else OTagTest t v x
    p <- emit TPred op
    pure (p, TPred)
  VLet k a b -> lowerBind cx env k a >>= \env' -> lowerVal cx env' b
  VIf c t f -> do
    p <- lowerCond cx env c
    (bt, _) <- newBlock []
    (bf, _) <- newBlock []
    close (TCondBr p bt [] bf [])
    open bt []
    rt <- ended (lowerVal cx env t)
    st <- traverse (const suspend) rt
    open bf []
    rf <- ended (lowerVal cx env f)
    sf <- traverse (const suspend) rf
    case (rt, rf, st, sf) of
      (Just r, Nothing, Just c', _) -> resume c' >> pure r
      (Nothing, Just r, _, Just c') -> resume c' >> pure r
      (Just r1, Just r2, Just c1, Just c2) -> do
        let jty = unify (snd r1) (snd r2)
        (bj, vj) <- newBlock1 jty
        resume c1
        vt <- coerce r1 jty
        close (TBr bj [vt])
        resume c2
        vf <- coerce r2 jty
        close (TBr bj [vf])
        open bj [(vj, jty)]
        pure (vj, jty)
      (Nothing, Nothing, _, _) -> throwError ()
      _ -> refuse "internal: inconsistent branch termination"
  VEqInt s n -> do
    ra <- lowerVal cx env s
    rb <- int n
    compareWith Eq ra rb
  VApp h args
    | isPrimName cx h, Just o <- M.lookup h arithOps, [a, b] <- args -> do
        x <- lowerVal cx env a >>= asInt
        y <- lowerVal cx env b >>= asInt
        v <- emit TInt (OArith o x y)
        pure (v, TInt)
    | isPrimName cx h, Just o <- M.lookup h cmpOps, [a, b] <- args -> do
        ra <- lowerVal cx env a
        rb <- lowerVal cx env b
        compareWith o ra rb
    | isPrimName cx h, h `notElem` regionHooks -> refuse ("typed lowering: the primitive `" ++ h ++ "`")
    | Just c <- calleeOf cx h (length args) -> do
        when (case calleeResult c of TProduct _ -> True; _ -> False) (refuse ("a product worker call " ++ h ++ " outside a let binding"))
        as <- mapM (lowerVal cx env) args
        as' <- mapM (uncurry coerce) (zip as (calleeParams c))
        v <- emit (calleeResult c) (OCall c as')
        pure (v, calleeResult c)
    | otherwise -> do
        f <- lowerGlobal cx h >>= asVal
        as <- mapM (\a -> lowerVal cx env a >>= asVal) args
        v <- emit TVal (OApply f as)
        pure (v, TVal)
  where
    int n
      | intFitsWidth (policyWidth (cxPolicy cx)) n = (\v -> (v, TInt)) <$> emit TInt (OConstInt n)
      | otherwise = refuse ("the literal " ++ show n ++ " does not fit an Int")
    -- an ordering is Int by typing; == and != are deep unless both sides are already Ints
    compareWith o ra rb = do
      p <- case (o, snd ra, snd rb) of
        (Eq, ta, tb) | ta /= TInt || tb /= TInt -> deep True ra rb
        (Ne, ta, tb) | ta /= TInt || tb /= TInt -> deep False ra rb
        _ -> do
          x <- asInt ra
          y <- asInt rb
          emit TPred (OCmp o x y)
      pure (p, TPred)
    deep eq ra rb = do
      x <- asVal ra
      y <- asVal rb
      emit TPred (OEqVal eq x y)
