{-# LANGUAGE LambdaCase #-}
-- Two list rewrites on the root's surface tree (docs/2026-11-18-KEYED-LIST-FOLDS.md):
--
-- Shared maps.  A map that changes only the elements a cheap test picks,
--
--   m.sales |> List.map (fn x -> if x.n == n then { x | voided = 1 } else x)
--
-- (or `fn x -> h x a ..` with a root `h` of two clauses, `h x .. | TEST = NEW`
-- and `h x .. = x`), is rewritten to std/list's mapWhere, which copies the
-- list only up to the last element the test picks and shares the rest:
--
--   List.mapWhere (fn x -> x.n == n) (fn x -> { x | voided = 1 }) m.sales
--
-- The test must be total and effect-free, because mapWhere calls it on every
-- element first and again on the ones it copies: comparisons (== != < <= > >=)
-- of variables, field reads and literals, joined by and/or/not, or a root
-- helper `g a b = a == b` (or !=).  The new element is evaluated exactly when
-- and in the order the map would.  Off unless FPR_SHARED_MAP=1: measured
-- slower than the map it replaces when the list is owned (List.map's own
-- lowering reuses the cells; mapWhere is two passes through closure calls).
--
-- Snoc folds.  A fold that appends to the end of its accumulator,
--
--   List.fold (fn acc x -> if ok x then acc + [f x] else acc) start xs
--
-- copies the accumulator at every step.  When the accumulator is only ever
-- the result (`acc`, `acc + [e..]`, `List.append acc [e..]`, through cases and
-- blocks that do not otherwise mention it), the fold conses onto a reversed
-- list and reverses once:
--
--   List.append start (List.reverse (List.fold (fn acc x -> if ok x then f x :: acc else acc) Nil xs))
--
-- The appended elements are evaluated in the same order.  FPR_NO_SNOC_FOLD=1
-- turns it off.
module Frontend.ListRewrites (sharedMaps, snocFolds) where

import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Control.Monad.State.Strict
import Frontend.Syntax
import Frontend.KeyedListFold (walkM, spineP, unmark, substitute, patVars, modulePath, mentions, isVar, trivial)
import Core.Syntax (Name)

type Clause = ([SPat], [SGuard], SExpr)

listAliases :: [STop] -> [Name]
listAliases tops = [a | TUse a p <- tops, modulePath p == "std/list"]

rootClauses :: [STop] -> M.Map Name [Clause]
rootClauses tops = M.fromListWith (flip (++)) [(f, [(ps, gs, b)]) | TBind f ps gs b <- tops]

-- the rewritten program and, per rewrite, the function it is in
rewriteTops :: (S.Set Name -> SExpr -> State Int SExpr) -> [STop] -> ([STop], [Name])
rewriteTops f tops = (map fst done, concatMap snd done)
  where
    done = map visit tops
    visit t = case t of
      TBind n ps gs b -> let (b', k) = runState (walkM f (S.fromList (concatMap patVars ps)) b) 0
                         in (TBind n ps gs b', replicate k n)
      _ -> (t, [])

-- ---- shared maps -----------------------------------------------------------

sharedMaps :: [STop] -> ([STop], [Name])
sharedMaps tops = case listAliases tops of
  [] -> (tops, [])
  l : _ -> rewriteTops (node l) tops
  where
    clauses = rootClauses tops
    node l bound e = case spineP e of
      (SVar h, [fn, xs]) | h == l ++ ".map", Just (x, test, new) <- picked bound fn -> do
        modify (+ 1)
        pure (foldl SApp (SVar (l ++ ".mapWhere")) [SLam [x] test, SLam [x] new, xs])
      _ -> pure e
    picked bound fn = case unmark fn of
      SLam [x] body -> case unmark body of
        SCase c arms
          | [(PCon "True" [], a), (PCon "False" [], b)] <- sorted arms -> choose x c a b
        b | (SVar h, SVar x' : rest) <- spineP b, x' == x, S.notMember h bound,
            Just [(PVar px : ps1, [GBool g], new1), (PVar py : ps2, [], idb)] <- M.lookup h clauses,
            length ps1 == length rest, length ps2 == length rest, isVar py idb,
            Just n1 <- mapM pv ps1, all trivial rest -> do
              -- simultaneous: `mark x n` called as `mark y n` is fine
              let sub = M.fromList ((px, SVar x) : zip n1 rest)
              g' <- substitute sub g
              new' <- substitute sub new1
              if testOk bound g' then Just (x, g', new') else Nothing
        _ -> Nothing
      _ -> Nothing
      where
        choose x c a b
          | isVar x b, testOk bound c = Just (x, c, a)
          | isVar x a, testOk bound c, notFree bound = Just (x, SApp (SVar "not") c, b)
          | otherwise = Nothing
    sorted arms = case [(p, b) | (p@(PCon c []), b) <- arms, c `elem` ["True", "False"]] of
      [t@(PCon "True" [], _), f@(PCon "False" [], _)] | length arms == 2 -> [t, f]
      [f@(PCon "False" [], _), t@(PCon "True" [], _)] | length arms == 2 -> [t, f]
      _ -> []
    pv = \case PVar v -> Just v; PWild -> Just "_"; _ -> Nothing
    notFree bound = S.notMember "not" bound && M.notMember "not" clauses
    -- total and effect-free: comparisons of plain values, and/or/not
    testOk bound t = case unmark t of
      SBin op a b | op `elem` ["==", "!=", "<", "<=", ">", ">="] -> plain a && plain b
                  | op `elem` ["and", "or"] -> testOk bound a && testOk bound b
      SVar v -> v `elem` ["True", "False"] || S.member v bound
      t' | (SVar "not", [a]) <- spineP t', notFree bound -> testOk bound a
         | (SVar g, [a, b]) <- spineP t', S.notMember g bound, eqHelper g -> plain a && plain b
      _ -> False
    plain v = case unmark v of
      SVar _ -> True
      SInt _ -> True
      SStrI segs -> all (\case SegStr _ -> True; _ -> False) segs
      SProj a _ -> plain a
      _ -> False
    eqHelper g = case M.lookup g clauses of
      Just [([PVar a, PVar b], [], body)] | SBin op l r <- unmark body, op `elem` ["==", "!="],
                                           (isVar a l && isVar b r) || (isVar b l && isVar a r) -> True
      _ -> False

-- ---- snoc folds ------------------------------------------------------------

snocFolds :: [STop] -> ([STop], [Name])
snocFolds tops = case listAliases tops of
  [] -> (tops, [])
  l : _ -> rewriteTops (node l) tops
  where
    node l _ e = case spineP e of
      (SVar h, [step, start, xs]) | h == l ++ ".fold", SLam [acc, x] body <- unmark step, acc /= x,
                                    not (mentions acc start), Just (body', n) <- snoc l acc body, n > 0 -> do
        k <- get
        put (k + 1)
        let folded = foldl SApp (SVar (l ++ ".fold")) [SLam [acc, x] body', SList [], xs]
            rev = SApp (SVar (l ++ ".reverse")) folded
        pure (if isNil start then rev else foldl SApp (SVar (l ++ ".append")) [start, rev])
      _ -> pure e
    isNil s = case unmark s of
      SList [] -> True
      SVar "Nil" -> True
      _ -> False

-- the body with every `acc + [e..]` turned into `e.. :: acc` (reversed), and
-- how many there were; Nothing when acc is used any other way
snoc :: Name -> Name -> SExpr -> Maybe (SExpr, Int)
snoc l acc e = case e of
  SMark o a -> (\(a', n) -> (SMark o a', n)) <$> snoc l acc a
  SVar v | v == acc -> Just (e, 0)
  SBin "+" a (SList es) | isVar acc a, not (any (mentions acc) es) -> Just (consed es, 1)
  _ | (SVar h, [a, SList es]) <- spineP e, h == l ++ ".append", isVar acc a, not (any (mentions acc) es) -> Just (consed es, 1)
  SCase s arms | not (mentions acc s), all (\(p, _) -> acc `notElem` patVars p) arms -> do
    arms' <- mapM (\(p, b) -> (\(b', n) -> ((p, b'), n)) <$> snoc l acc b) arms
    Just (SCase s (map fst arms'), sum (map snd arms'))
  SBlock ss r | all stmtOk ss -> (\(r', n) -> (SBlock ss r', n)) <$> snoc l acc r
  _ -> Nothing
  where
    stmtOk st = case st of
      SBind v ps rhs -> acc `notElem` (v : ps) && not (mentions acc rhs)
      SBindPat p rhs -> acc `notElem` patVars p && not (mentions acc rhs)
    -- e1, e2 .. are evaluated in order, then consed last first
    consed es
      | length (filter (not . trivial) es) <= 1 = foldl (\a x -> SBin "::" x a) (SVar acc) es
      | otherwise =
          let names = ["kl__e" ++ show i | i <- [1 .. length es]]
          in SBlock [SBind nm [] x | (nm, x) <- zip names es] (foldl (\a nm -> SBin "::" (SVar nm) a) (SVar acc) names)
