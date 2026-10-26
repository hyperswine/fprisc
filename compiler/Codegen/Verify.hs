{-# LANGUAGE LambdaCase #-}
-- Codegen.Verify: the mandatory checks on a typed-IR function.
--
-- A function that fails here is a compiler error, never a fallback
-- (docs/2026-10-20-TYPED-NATIVE-IR-PLAN.md, "Selection, fallback and
-- cache policy").  The checks: block identities, single definitions,
-- operation signatures and result types, terminators and their edges,
-- block-argument counts and types, reachability, and dominance of every
-- use by its definition.
module Codegen.Verify (verifyFn, verifyProgram, verifyProgramWidth, opSignature, simdExprOk) where

import Codegen.IR
import Control.Monad (forM_, unless, when)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- the operand types an operation needs and the type it produces
opSignature :: (VId -> Either String Ty) -> Op -> Either String (Maybe Ty)
opSignature tyOf = \case
  OConstInt n -> do
    unless (intFits64 n) (Left ("const " ++ show n ++ " is outside the Int range"))
    pure (Just TInt)
  ONullary _ _ -> pure (Just TVal)
  OString _ -> pure (Just TVal)
  OBoxedFloat width bits -> do
    unless (bits >= 0 && bits < 2 ^ widthBits width) (Left "a boxed float has out-of-range IEEE bits")
    pure (Just TVal)
  OMake tid variant fields -> do
    when (tid < 0 || variant < 0 || toInteger tid > 2147483647 || toInteger variant > 2147483647) (Left "constructor header is outside signed 32-bit layout")
    when (null fields) (Left "an empty constructor uses nullary")
    mapM_ (`expect` TVal) fields
    pure (Just TVal)
  OReuse tid variant root fields -> do
    when (tid < 0 || variant < 0) (Left "constructor header is outside signed 32-bit layout")
    when (null fields) (Left "a reuse of a nullary constructor")
    expect root TVal
    mapM_ (`expect` TVal) fields
    pure (Just TVal)
  OAddress v -> expect v TVal >> pure (Just TAddr)
  OIndex a i -> expect a TAddr >> expect i TInt >> pure (Just TAddr)
  OLoad t a n -> memory t a n >> pure (Just t)
  OLoadByte a n -> memory TInt a n >> pure (Just TInt)
  OStore t a n v -> memory t a n >> expect v t >> pure Nothing
  OField index obj -> do
    when (index < 0 || toInteger index > 268435454) (Left "field index is outside the native displacement range")
    expect obj TVal
    pure (Just TVal)
  OStrLen str -> expect str TVal >> pure (Just TInt)
  ORegionRoom m -> expect m TVal >> pure (Just TPred)
  OHartCell j -> do
    when (j < 0 || j > 63) (Left "hart cell outside the hart block's addressed words")
    pure (Just TInt)
  OCharAt str index -> expect str TVal >> expect index TInt >> pure (Just TInt)
  OTag v -> expect v TInt >> pure (Just TVal)
  OUntag v -> expect v TVal >> pure (Just TInt)
  OBoolOf v -> expect v TPred >> pure (Just TVal)
  OTruth v -> expect v TVal >> pure (Just TPred)
  ONot v -> expect v TPred >> pure (Just TPred)
  OIsInt v -> expect v TVal >> pure (Just TPred)
  OTagTest _ _ v -> expect v TVal >> pure (Just TPred)
  OSymbol sym -> do
    when (null sym) (Left "an empty symbol")
    pure (Just TVal)
  OFunValue n -> do
    when (null n) (Left "a function value without a name")
    pure (Just TVal)
  OApply f as -> do
    expect f TVal
    mapM_ (`expect` TVal) as
    when (null as) (Left "an application without arguments")
    pure (Just TVal)
  OKernelArith _ a b -> expect a TInt >> expect b TInt >> pure (Just TInt)
  OArith _ a b -> expect a TInt >> expect b TInt >> pure (Just TInt)
  OBit _ a b -> expect a TInt >> expect b TInt >> pure (Just TInt)
  OShift _ a b -> expect a TInt >> expect b TInt >> pure (Just TInt)
  OCmp _ a b -> expect a TInt >> expect b TInt >> pure (Just TPred)
  OEqVal _ a b -> expect a TVal >> expect b TVal >> pure (Just TPred)
  OBits n -> do
    unless (n >= negate (2 ^ (63 :: Int)) && n < 2 ^ (63 :: Int)) (Left ("bits " ++ show n ++ " is not a signed 64-bit word"))
    pure (Just TVal)
  OFloatBin _ a b -> expect a TVal >> expect b TVal >> pure (Just TVal)
  OFloatCmp _ a b -> expect a TVal >> expect b TVal >> pure (Just TPred)
  OFloatTree t -> do
    case t of FNode {} -> pure (); FLeaf _ -> Left "a float tree is at least one operation"
    unless (ftreeRegisters t <= ftreeScratch) (Left ("a float tree needs " ++ show (ftreeRegisters t) ++ " scratch registers, " ++ show ftreeScratch ++ " exist"))
    mapM_ (`expect` TVal) (ftreeLeaves t)
    pure (Just TVal)
  OFloat32Tree t -> do
    case t of FNode {} -> pure (); FLeaf _ -> Left "a float tree is at least one operation"
    unless (ftreeRegisters t <= ftreeScratch) (Left ("a float tree needs " ++ show (ftreeRegisters t) ++ " scratch registers, " ++ show ftreeScratch ++ " exist"))
    mapM_ (`expect` TVal) (ftreeLeaves t)
    pure (Just TVal)
  OFloatCmpTree _ a b -> checkTrees a b
  OFloat32CmpTree _ a b -> checkTrees a b
  OFloat32Bin _ a b -> expect a TVal >> expect b TVal >> pure (Just TVal)
  OFloat32Cmp _ a b -> expect a TVal >> expect b TVal >> pure (Just TPred)
  OCall c as -> do
    when (length as /= length (calleeParams c)) $
      Left ("call " ++ calleeName c ++ ": " ++ show (length as) ++ " arguments for " ++ show (length (calleeParams c)) ++ " parameters")
    when (length as > arityCeiling) $ Left ("call " ++ calleeName c ++ ": " ++ show (length as) ++ " arguments is above the ceiling of " ++ show arityCeiling)
    mapM_ (uncurry expect) (zip as (calleeParams c))
    pure (Just (calleeResult c))
  OSafepoint -> pure Nothing
  OSafepointN n -> do
    unless (n >= 1) (Left "a counted safepoint charges at least one tick")
    pure Nothing
  OSimdPair int e caps a -> do
    expect a TAddr
    mapM_ (`expect` (if int then TInt else TVal)) caps
    unless (all (\n -> n >= 0 && n < length caps) (simdCaptures e)) (Left "SIMD capture index outside its operand list")
    simdExprOk int e
    pure Nothing
  ORvvVlMax -> pure (Just TInt)
  ORvvLanes a n -> expect a TAddr >> expect n TInt >> pure (Just TPred)
  ORvvSumLoaded acc -> expect acc TInt >> pure (Just TInt)
  OStackCheck -> pure Nothing
  where
    checkTrees a b = do
      let budget = max (ftreeRegisters a) (1 + ftreeRegisters b)
      unless (budget <= ftreeScratch) (Left "a comparison tree exceeds the scratch register budget")
      mapM_ (`expect` TVal) (ftreeLeaves a ++ ftreeLeaves b)
      pure (Just TPred)
    memory t a n = do
      unless (t `elem` [TInt,TVal,TAddr]) (Left "unsupported memory representation")
      unless (n >= 0 && n <= 255) (Left "memory offset outside portable displacement range")
      expect a TAddr
    expect v t = do
      t' <- tyOf v
      unless (t' == t) (Left (show v ++ " is " ++ show t' ++ ", " ++ show t ++ " needed"))

verifyFn :: Program -> Fn -> Either String ()
verifyFn program fn = mapLeft (("verify " ++ fnName fn ++ ": ") ++) $ do
  let blocks = fnBlocks fn
      ids = map bId blocks
  when (null blocks) (Left "no blocks")
  when (length (S.fromList ids) /= length ids) (Left "duplicate block id")
  let byId = M.fromList [(bId b, b) | b <- blocks]
  entry <- maybe (Left "entry block missing") Right (M.lookup (fnEntry fn) byId)
  when (length (bParams entry) > arityCeiling) (Left ("arity " ++ show (length (bParams entry)) ++ " is above the ceiling of " ++ show arityCeiling))
  -- single definitions, and the type of every value
  let defs = concatMap blockDefs blocks
      defIds = map fst defs
  when (length (S.fromList defIds) /= length defIds) (Left "a value is defined twice")
  let tyMap = M.fromList defs
      tyOf v = maybe (Left (show v ++ " is never defined")) Right (M.lookup v tyMap)
  -- operation signatures and declared result types
  forM_ blocks $ \b -> forM_ (bInstrs b) $ \(Instr d op) -> do
    r <- mapLeft ((show (bId b) ++ ": ") ++) (opSignature tyOf op)
    case (d, r) of
      (Nothing, Nothing) -> pure ()
      (Just (v, t), Just t') -> unless (t == t') (Left (show (bId b) ++ ": " ++ show v ++ " declared " ++ show t ++ ", operation gives " ++ show t'))
      (Nothing, Just _) -> Left (show (bId b) ++ ": a result is discarded")
      (Just (v, _), Nothing) -> Left (show (bId b) ++ ": " ++ show v ++ " defined by an operation without a result")
  -- terminators: targets, argument counts and types
  forM_ blocks $ \b -> do
    let here = show (bId b) ++ ": "
    case bTerm b of
      TRet v -> do
        t <- tyOf v
        unless (t == fnResult fn) (Left (here ++ "returns " ++ show t ++ ", " ++ show (fnResult fn) ++ " needed"))
      TCondBr c _ _ _ _ -> do
        t <- tyOf c
        unless (t == TPred) (Left (here ++ "branches on " ++ show t ++ ", TPred needed"))
      TTailCall c as -> do
        when (length as /= length (calleeParams c)) (Left (here ++ "tail call " ++ calleeName c ++ ": wrong arity"))
        when (length as > arityCeiling) (Left (here ++ "tail call " ++ calleeName c ++ ": " ++ show (length as) ++ " arguments is above the ceiling of " ++ show arityCeiling))
        when (calleeResult c /= fnResult fn) (Left (here ++ "tail call " ++ calleeName c ++ " answers " ++ show (calleeResult c) ++ ", this function " ++ show (fnResult fn)))
        forM_ (zip as (calleeParams c)) $ \(a, t) -> do
          t' <- tyOf a
          unless (t' == t) (Left (here ++ "tail call argument " ++ show a ++ " is " ++ show t' ++ ", " ++ show t ++ " needed"))
      TBr _ _ -> pure ()
      TUnreachable msg -> when (null msg) (Left (here ++ "an unreachable terminator without a reason"))
    forM_ (termSuccs (bTerm b)) $ \(target, args) -> do
      tb <- maybe (Left (here ++ "jump to a missing block " ++ show target)) Right (M.lookup target byId)
      when (length args /= length (bParams tb)) (Left (here ++ "jump to " ++ show target ++ " passes " ++ show (length args) ++ " arguments for " ++ show (length (bParams tb)) ++ " parameters"))
      forM_ (zip args (bParams tb)) $ \(a, (_, t)) -> do
        t' <- tyOf a
        unless (t' == t) (Left (here ++ "jump argument " ++ show a ++ " is " ++ show t' ++ ", " ++ show t ++ " needed"))
  -- reachability and dominance
  let succs b = map fst (termSuccs (bTerm b))
      reach seen [] = seen
      reach seen (x : xs)
        | S.member x seen = reach seen xs
        | otherwise = reach (S.insert x seen) (maybe [] succs (M.lookup x byId) ++ xs)
      reachable = reach S.empty [bId entry]
  forM_ blocks $ \b -> unless (S.member (bId b) reachable) (Left (show (bId b) ++ " is unreachable"))
  let preds = M.fromListWith (++) [(s, [bId b]) | b <- blocks, s <- succs b]
      allIds = S.fromList ids
      dom0 = M.fromList [(i, if i == bId entry then S.singleton i else allIds) | i <- ids]
      step dm = M.mapWithKey (\i d -> if i == bId entry then d
                                      else S.insert i (foldr1 S.intersection [dm M.! p | p <- M.findWithDefault [] i preds])) dm
      fixDom dm = let dm' = step dm in if dm' == dm then dm else fixDom dm'
      doms = fixDom dom0
      definedIn = M.fromList [(v, bId b) | b <- blocks, (v, _) <- blockDefs b]
      -- a use in block b is dominated when the value is a parameter of b,
      -- an earlier instruction of b, or a definition in a strict dominator
      check b seen v = case M.lookup v definedIn of
        Nothing -> Left (show (bId b) ++ ": " ++ show v ++ " is never defined")
        Just d | d == bId b -> unless (S.member v seen) (Left (show (bId b) ++ ": " ++ show v ++ " is used before its definition"))
               | otherwise -> unless (S.member d (doms M.! bId b)) (Left (show (bId b) ++ ": " ++ show v ++ " is defined in " ++ show d ++ ", which does not dominate"))
  forM_ blocks $ \b -> do
    let go seen [] = forM_ (termUses (bTerm b)) (check b seen)
        go seen (Instr d op : rest) = do
          forM_ (opUses op) (check b seen)
          go (maybe seen (\(v, _) -> S.insert v seen) d) rest
    go (S.fromList (map fst (bParams b))) (bInstrs b)
  -- a known local callee that is in the program must agree on its convention
  forM_ blocks $ \b -> do
    let callees = [c | Instr _ (OCall c _) <- bInstrs b] ++ [c | TTailCall c _ <- [bTerm b]]
    forM_ callees $ \c -> case M.lookup (calleeName c) program of
      Just f | calleeKind c == Local, (entryOf : _) <- [x | x <- fnBlocks f, bId x == fnEntry f] -> do
        let ps = map snd (bParams entryOf)
        unless (ps == calleeParams c) (Left ("call " ++ calleeName c ++ ": declared " ++ show (calleeParams c) ++ ", its entry takes " ++ show ps))
        unless (fnResult f == calleeResult c) (Left ("call " ++ calleeName c ++ ": declared to answer " ++ show (calleeResult c) ++ ", it answers " ++ show (fnResult f)))
      _ -> pure ()
  pure ()
  where
    mapLeft f = either (Left . f) Right

verifyProgram :: Program -> Either String ()
verifyProgram p = mapM_ (verifyFn p) (M.elems p)

-- Width is an explicit compilation policy, shared by lowering, validation,
-- evaluation and target selection. Do not admit a 63-bit constant in RV32.
verifyProgramWidth :: Width -> Program -> Either String ()
verifyProgramWidth width program = do
  verifyProgram program
  forM_ (M.elems program) $ \fn -> forM_ (fnBlocks fn) $ \b ->
    forM_ (bInstrs b) $ \(Instr _ op) -> case op of
      OLoad _ _ n -> aligned n
      OStore _ _ n _ -> aligned n
      OConstInt n -> unless (intFitsWidth width n) (Left ("verify " ++ fnName fn ++ ": literal exceeds " ++ show width ++ " Int range"))
      OBoxedFloat _ _ -> unless (width == W32) (Left "boxed float constants require the 32-bit word policy")
      _ -> pure ()
  where
    aligned n = unless (n `mod` (widthBits width `div` 8) == 0) (Left "unaligned word memory operation")

-- A SIMD pair body: at most the 15 scratch vector registers (v17..v31); an
-- Int body is exactly one + or - over the lane, captures and literals (the stored
-- lanes' 63-bit fit is then the whole overflow test); an F64 body uses + - * only.
simdExprOk :: Bool -> SimdExpr -> Either String ()
simdExprOk int e = do
  unless (simdRegisters e <= 15) (Left "a SIMD pair expression needs more than the 15 scratch vector registers")
  if int
    then case e of
      SInt op x y | op `elem` [Add, Sub], leaf x, leaf y -> pure ()
      _ -> Left "an Int SIMD pair is exactly one + or - over the lane, captures and literals"
    else unless (floatOnly e) (Left "an F64 SIMD pair uses F64 + - * over the lane, captures and literals")
  where
    leaf = \case SLane -> True; SCapture _ -> True; SConst _ -> True; _ -> False
    floatOnly = \case SLane -> True; SCapture _ -> True; SConst _ -> True; SFloat op x y -> op /= FDiv && floatOnly x && floatOnly y; SInt {} -> False
