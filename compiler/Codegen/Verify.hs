{-# LANGUAGE LambdaCase #-}
-- Codegen.Verify: the mandatory checks on a typed-IR function.
--
-- A function that fails here is a compiler error, never a fallback
-- (docs/2026-10-20-TYPED-NATIVE-IR-PLAN.md, "Selection, fallback and
-- cache policy").  The checks: block identities, single definitions,
-- operation signatures and result types, terminators and their edges,
-- block-argument counts and types, reachability, and dominance of every
-- use by its definition.
module Codegen.Verify (verifyFn, verifyProgram, opSignature) where

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
  OTag v -> expect v TInt >> pure (Just TVal)
  OUntag v -> expect v TVal >> pure (Just TInt)
  OBoolOf v -> expect v TPred >> pure (Just TVal)
  OTruth v -> expect v TVal >> pure (Just TPred)
  ONot v -> expect v TPred >> pure (Just TPred)
  OIsInt v -> expect v TVal >> pure (Just TPred)
  OTagTest _ _ v -> expect v TVal >> pure (Just TPred)
  OArith _ a b -> expect a TInt >> expect b TInt >> pure (Just TInt)
  OBit _ a b -> expect a TInt >> expect b TInt >> pure (Just TInt)
  OShift _ a b -> expect a TInt >> expect b TInt >> pure (Just TInt)
  OCmp _ a b -> expect a TInt >> expect b TInt >> pure (Just TPred)
  OEqVal _ a b -> expect a TVal >> expect b TVal >> pure (Just TPred)
  OCall c as -> do
    when (length as /= length (calleeParams c)) $
      Left ("call " ++ calleeName c ++ ": " ++ show (length as) ++ " arguments for " ++ show (length (calleeParams c)) ++ " parameters")
    when (length as > arityCeiling) $ Left ("call " ++ calleeName c ++ ": " ++ show (length as) ++ " arguments is above the ceiling of " ++ show arityCeiling)
    mapM_ (uncurry expect) (zip as (calleeParams c))
    pure (Just (calleeResult c))
  OSafepoint -> pure Nothing
  OStackCheck -> pure Nothing
  where
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
