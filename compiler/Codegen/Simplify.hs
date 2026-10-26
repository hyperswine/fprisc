{-# LANGUAGE LambdaCase #-}
-- Codegen.Simplify: the IR-to-IR simplification the M1 page deferred
-- (docs/2026-10-20-TYPED-IR-M1.md "Conversions are explicit";
-- docs/2026-10-21-TYPED-IR-COVERAGE.md, increment 4).
--
-- Named passes, each a function on a verified function that yields a
-- verified function, each a compiler error (never a fallback) when the
-- verifier refuses its result:
--
--   * fold conversion pairs: `untag (tag u)` is u, `tag (untag v)` is v (a
--     TVal that is an Int by typing is exactly its retagged payload),
--     `truth (boolof p)` is p; the inner conversion goes when nothing else
--     uses it;
--   * branch on the comparison: a join block whose one parameter feeds
--     only a `truth` that a `condbr` tests is threaded edge by edge: an
--     edge passing a Bool constant jumps straight to the arm, an edge whose
--     block passes `boolof p` and ends in that jump branches on p itself;
--     the join stays for the edges that pass anything else and goes when
--     none remain;
--   * share repeated pure operations within a block: the second `untag v`
--     (or `const`, `nullary`, `cmp`, ...) of a block becomes the first.
--
-- Pure definitions nothing uses are dropped afterwards; an operation that
-- may trap, calls, or ticks is never moved, merged or removed, so the
-- order of traps and effects is the lowered program's.  The evaluator's
-- results, traps and event order are unchanged by construction and are
-- checked to be so: tests/TypedIR.hs runs both programs on the fixtures,
-- and FPR_TYPED_IR's eval report runs both and errors on a difference.
module Codegen.Simplify (Options(..),defaultOptions,simplifyFn,simplifyProgram,simplifyFnWith,simplifyProgramWith,passes) where

import Codegen.IR
import Codegen.LoopOptimize (moveInvariants)
import Codegen.Verify (verifyFn)
import Codegen.Dump (dumpFn)
import Data.List (foldl')
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data Options=Options { moveLoopInvariants :: Bool } deriving (Eq,Show)
defaultOptions :: Options
defaultOptions=Options False

-- the passes in order, by name
passes :: [(String, Fn -> Fn)]
passes=passesWith defaultOptions

passesWith :: Options -> [(String,Fn -> Fn)]
passesWith options=
  [ ("fold-conversions", dropDeadPure . foldConversions),
    ("branch-on-comparison", dropDeadPure . threadBooleanJoins),
    ("share-pure-in-block", dropDeadPure . sharePureInBlock)
  ] ++ [("move-loop-invariants",dropDeadPure . moveInvariants) | moveLoopInvariants options]
    ++ [("fuse-float-trees", dropDeadPure . fuseFloatTrees)]

-- the simplified function and the number of instructions it lost
simplifyFn :: Program -> Fn -> Either String (Fn, Int)
simplifyFn=simplifyFnWith defaultOptions

simplifyFnWith :: Options -> Program -> Fn -> Either String (Fn,Int)
simplifyFnWith options program fn0 = go fn0 (passesWith options)
  where
    size f = sum (map (length . bInstrs) (fnBlocks f))
    go f [] = Right (f, size fn0 - size f)
    go f ((name, pass) : rest) =
      let f' = pass f
       in case verifyFn program f' of
            -- the function before and after the pass, for the report: this is
            -- a compiler error, and the IR is what a fix needs
            Left err -> Left ("simplify " ++ name ++ " on " ++ fnName f ++ ": " ++ err
                               ++ "\n-- before " ++ name ++ ":\n" ++ dumpFn f ++ "-- after:\n" ++ dumpFn f')
            Right () -> go f' rest

-- every function; the callers' conventions do not change (entry
-- parameters and results are untouched), so the program verifies whole
simplifyProgram :: Program -> Either String (Program, M.Map Name Int)
simplifyProgram=simplifyProgramWith defaultOptions

simplifyProgramWith :: Options -> Program -> Either String (Program,M.Map Name Int)
simplifyProgramWith options program = do
  results <- mapM (\(n, f) -> (\(f', k) -> (n, (f', k))) <$> simplifyFnWith options program f) (M.toList program)
  pure (M.fromList [(n, f) | (n, (f, _)) <- results], M.fromList [(n, k) | (n, (_, k)) <- results, k > 0])

-- ---- shared helpers ------------------------------------------------------

defsOf :: Fn -> M.Map VId Op
defsOf fn = M.fromList [(v, op) | b <- fnBlocks fn, Instr (Just (v, _)) op <- bInstrs b]

-- rename values everywhere; a substitution chain is followed to its end
substitute :: M.Map VId VId -> Fn -> Fn
substitute sub fn
  | M.null sub = fn
  | otherwise = fn {fnBlocks = map blk (fnBlocks fn)}
  where
    f v = case M.lookup v sub of
      Just w | w /= v -> f w
      _ -> v
    blk b = b {bInstrs = [Instr d (mapOpUses f op) | Instr d op <- bInstrs b], bTerm = mapTermUses f (bTerm b)}

usesOf :: Fn -> S.Set VId
usesOf fn = S.fromList (concat [concatMap (\(Instr _ op) -> opUses op) (bInstrs b) ++ termUses (bTerm b) | b <- fnBlocks fn])

-- pure definitions nothing uses, to a fixpoint (a dropped use may free another)
dropDeadPure :: Fn -> Fn
dropDeadPure fn =
  let used = usesOf fn
      live (Instr (Just (v, _)) op) = opEffect op /= Pure || S.member v used
      live (Instr Nothing _) = True
      fn' = fn {fnBlocks = [b {bInstrs = filter live (bInstrs b)} | b <- fnBlocks fn]}
   in if fn' == fn then fn else dropDeadPure fn'

-- ---- pass 1: conversion pairs ---------------------------------------------

foldConversions :: Fn -> Fn
foldConversions fn =
  let defs = defsOf fn
      sub = M.fromList
        [ (v, u)
        | (v, op) <- M.toList defs,
          Just u <- [case op of
            OUntag w | Just (OTag u) <- M.lookup w defs -> Just u
            OTag w | Just (OUntag u) <- M.lookup w defs -> Just u
            OTruth w | Just (OBoolOf u) <- M.lookup w defs -> Just u
            _ -> Nothing]
        ]
      fn' = substitute sub fn
      -- the folded definitions themselves are now unused and pure: dropDeadPure takes them
   in fn'

-- ---- pass 2: branch on the comparison ---------------------------------------

threadBooleanJoins :: Fn -> Fn
threadBooleanJoins fn = foldl' threadJoin fn [bId b | b <- fnBlocks fn, isBoolJoin b]
  where
    -- the parameter and its truth must have no use outside the join: once
    -- the join is threaded away, nothing would define them on the
    -- threaded paths (a QOS module tested the Bool again two joins later)
    usedOutside b v = or [v `elem` (concat [opUses op | Instr _ op <- bInstrs o] ++ termUses (bTerm o)) | o <- fnBlocks fn, bId o /= bId b]
    isBoolJoin b = case (bParams b, bInstrs b, bTerm b) of
      ([(vj, TVal)], [Instr (Just (q, TPred)) (OTruth w)], TCondBr c t as e bs) ->
        w == vj && c == q && bId b /= fnEntry fn && t /= bId b && e /= bId b
          && vj `notElem` (as ++ bs) && q `notElem` (as ++ bs)
          && not (usedOutside b vj) && not (usedOutside b q)
      _ -> False

threadJoin :: Fn -> BId -> Fn
threadJoin fn j = case [b | b <- fnBlocks fn, bId b == j] of
  [join] | TCondBr _ t as e bs <- bTerm join ->
    let defs = defsOf fn
        -- an edge into the join: the argument it passes decides
        redirect a = case M.lookup a defs of
          Just (ONullary 1 1) -> Just (Left (TBr t as))
          Just (ONullary 1 0) -> Just (Left (TBr e bs))
          Just (OBoolOf p) -> Just (Right (TCondBr p t as e bs))
          _ -> Nothing
        rewriteTerm = \case
          TBr b [a] | b == j, Just r <- redirect a -> either id id r
          -- a conditional edge into the join: only a constant can be threaded
          TCondBr c b1 as1 b2 bs2 ->
            let one b args = case (b == j, args) of
                  (True, [a]) | Just (Left (TBr b' args')) <- redirect a -> (b', args')
                  _ -> (b, args)
                (b1', as1') = one b1 as1
                (b2', bs2') = one b2 bs2
             in TCondBr c b1' as1' b2' bs2'
          other -> other
        blocks' = [b {bTerm = rewriteTerm (bTerm b)} | b <- fnBlocks fn]
        stillTargeted = or [j `elem` map fst (termSuccs (bTerm b)) | b <- blocks', bId b /= j]
     in fn {fnBlocks = if stillTargeted then blocks' else filter ((/= j) . bId) blocks'}
  _ -> fn

-- ---- pass 3: share pure operations within a block ---------------------------

sharePureInBlock :: Fn -> Fn
sharePureInBlock fn =
  let sub = M.unions (map blockSub (fnBlocks fn))
      blockSub b = snd (foldl' step (M.empty, M.empty) (bInstrs b))
      step (seen, sub') (Instr (Just (v, _)) op)
        | opEffect op == Pure =
            let op' = mapOpUses (resolve sub') op
             in case M.lookup op' seen of
                  Just u -> (seen, M.insert v u sub')
                  Nothing -> (M.insert op' v seen, sub')
      step acc _ = acc
      resolve m v = case M.lookup v m of
        Just w -> resolve m w
        Nothing -> v
   in substitute sub fn

-- Single-use F64/F32 arithmetic within a block becomes a tree, including
-- arithmetic operands of comparisons. Each precision has its own candidates;
-- effects clear both maps, and the fixed scratch budget bounds every tree.
-- Operand order and the operation at each node stay unchanged: no FMA,
-- reassociation, or removal of an intermediate F32 rounding step.
fuseFloatTrees :: Fn -> Fn
fuseFloatTrees fn = fn {fnBlocks = map blk (fnBlocks fn)}
  where
    uses = M.fromListWith (+) [(v, 1 :: Int) | b <- fnBlocks fn, v <- concatMap (\(Instr _ op) -> opUses op) (bInstrs b) ++ termUses (bTerm b)]
    once v = M.lookup v uses == Just 1
    blk b = b {bInstrs = go M.empty M.empty (bInstrs b)}
    go _ _ [] = []
    go ds ss (Instr (Just (v, ty)) op : rest)
      | Just (single, tree, fused) <- treeOf ds ss op =
          let op' = if fused then (if single then OFloat32Tree else OFloatTree) tree else op
              add m = if once v then M.insert v tree m else m
           in Instr (Just (v, ty)) op' : go (if single then ds else add ds) (if single then add ss else ss) rest
      | Just op' <- comparison ds ss op = Instr (Just (v, ty)) op' : go ds ss rest
    go ds ss (i@(Instr _ op) : rest) = i : (if opEffect op == Pure then go ds ss else go M.empty M.empty) rest
    treeOf ds _ (OFloatBin o a b) = Just (False, fst (fuse ds o a b), snd (fuse ds o a b))
    treeOf _ ss (OFloat32Bin o a b) = Just (True, fst (fuse ss o a b), snd (fuse ss o a b))
    treeOf _ _ _ = Nothing
    comparison ds _ (OFloatCmp o a b) = cmp ds (OFloatCmpTree o) a b
    comparison _ ss (OFloat32Cmp o a b) = cmp ss (OFloat32CmpTree o) a b
    comparison _ _ _ = Nothing
    cmp cands ctor a b =
      let x = graft cands (FLeaf a); y = graft cands (FLeaf b)
       in if (x /= FLeaf a || y /= FLeaf b) && max (ftreeRegisters x) (1 + ftreeRegisters y) <= ftreeScratch
          then Just (ctor x y) else Nothing
    fuse cands o a b =
      let whole = FNode o (graft cands (FLeaf a)) (graft cands (FLeaf b))
          original = FNode o (FLeaf a) (FLeaf b)
       in if ftreeRegisters whole <= ftreeScratch && whole /= original then (whole, True) else (original, False)
    graft cands (FLeaf v) = M.findWithDefault (FLeaf v) v cands
    graft cands (FNode o x y) = FNode o (graft cands x) (graft cands y)
