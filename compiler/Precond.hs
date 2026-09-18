{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- Precond: type-level preconditions ("contracts") for FPRISC.
--
-- A signature part may name and constrain a parameter:
--
--     addAmount : (n : Int | n > 0) -> State -> State.
--
-- The predicate is NOT a type-system feature: it is a runtime check at
-- the call boundary, in the crash/supervision tier -- EXCEPT where the
-- compiler can discharge it statically from local facts, in which case
-- no code is emitted at all.  Facts come from exactly the places a
-- proposition becomes locally true:
--
--   * the function's OWN preconditions (obligations propagate: a
--     precondition on my signature is a fact inside my body)
--   * clause guards        f x | x > 0 = ...
--   * case discrimination  case n != 0 of True -> ... (and int-literal
--     arms: matching 0 / falling through past 0)
--   * literal block binds  k = 3; ...
--
-- The predicate grammar is deliberately the smallest decidable
-- fragment: comparisons (== != < <= > >=) over integer arithmetic
-- (+ - *) of variables and literals, combined with and2/or2.  Anything
-- outside the fragment is a compile error on the SIGNATURE, never a
-- silent fallback -- the line between "provable" and "runtime-checked"
-- must be stable, not solver-mood-dependent.
--
-- An undischarged obligation compiles to a call-site check with blame:
--
--     precondition violated: addAmount requires (n > 0), got n=-3 (in update)
--
-- crashing the actor via the ordinary `error` prim (the BEAM tier).
-- The builtin division axiom (`/` requires divisor != 0) is analyzed
-- and reported identically, but an undischarged divisor falls back on
-- the runtime's existing division-by-zero trap instead of a wrapper:
-- `/` is operator-dispatched by operand TYPE after this pass runs, so
-- an inserted Int comparison could mistype a non-Int division site.

module Precond where

import Control.Monad (forM)
import Control.Monad.State.Strict
import Data.List (foldl')
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import FPRISC

--------------------------------------------------------------------------------
-- the precondition table (from TSig) + fragment validation
--------------------------------------------------------------------------------

type PreTable = M.Map Name [Maybe (Name, SExpr)]

preTable :: [STop] -> PreTable
preTable tops =
  M.fromList
    [ (n, pres')
      | TSig n _ pres <- tops,
        let pres' = [ if maybe False (isMeasureP . snd) p then Nothing else p
                    | p <- pres, (fst <$> p) /= Just "$unsafe" ],
        any (/= Nothing) (map (fmap (const ())) pres')
    ]

-- `(x : T | measure e)` is a TERMINATION declaration, not a value
-- precondition: route it to Safety.measureCheck and keep it out of
-- the obligation machinery (it is not in the decidable value
-- fragment, and it must never become a runtime check)
isMeasureP :: SExpr -> Bool
isMeasureP e = case e of
  SApp (SVar "measure") _ -> True
  _ -> False

-- the decidable fragment: cmp atoms over +,-,* of vars/ints, and2/or2
validatePre :: PreTable -> [String]
validatePre tab =
  [ "precondition on " ++ f ++ " (" ++ v ++ "): outside the decidable fragment: " ++ renderP p
    | (f, pres) <- M.toList tab,
      Just (v, p) <- pres,
      not (okPred p)
  ]
  where
    okPred e = case e of
      SApp (SApp (SVar c) a) b | c `elem` ["and2", "or2"] -> okPred a && okPred b
      SBin op a b | op `elem` ["and", "or"] -> okPred a && okPred b
      SBin op a b | op `elem` cmpOps -> okA a && okA b
      _ -> False
    okA = \case
      SVar _ -> True
      SInt _ -> True
      SBin op a b | op `elem` ["+", "-", "*"] -> okA a && okA b
      _ -> False

cmpOps :: [Name]
cmpOps = ["==", "!=", "<", "<=", ">", ">="]

--------------------------------------------------------------------------------
-- notes (the compile-time obligation report)
--------------------------------------------------------------------------------

data PreStatus = Discharged | RuntimeCheck | BuiltinTrap deriving (Eq)

data PreNote = PreNote
  { pnCaller :: Name,
    pnCallee :: Name,
    pnPred :: String,
    pnStatus :: PreStatus
  }

renderNote :: PreNote -> String
renderNote (PreNote caller callee p st) =
  "precond: " ++ caller ++ " -> " ++ callee ++ " requires (" ++ p ++ "): " ++ s
  where
    s = case st of
      Discharged -> "discharged statically"
      RuntimeCheck -> "runtime check inserted"
      BuiltinTrap -> "runtime trap (builtin)"

renderP :: SExpr -> String
renderP = \case
  SVar n -> n
  SInt n -> show n
  SBin op a b -> renderP a ++ " " ++ op ++ " " ++ renderP b
  SApp (SApp (SVar c) a) b
    | c `elem` ["and2", "or2"] ->
        "(" ++ renderP a ++ ") " ++ take (length c - 1) c ++ " (" ++ renderP b ++ ")"
  _ -> "<pred>"

--------------------------------------------------------------------------------
-- facts and entailment
--------------------------------------------------------------------------------

-- a fact/pred atom: lhs `op` rhs over the arithmetic fragment
type Atom = (SExpr, Name, SExpr)

-- flatten a (guard) expression into conjunct atoms; only shapes we
-- understand contribute -- anything else contributes NO facts (sound:
-- fewer facts only means fewer discharges)
conjuncts :: SExpr -> [Atom]
conjuncts e = case e of
  SApp (SApp (SVar "and2") a) b -> conjuncts a ++ conjuncts b
  SBin "and" a b -> conjuncts a ++ conjuncts b
  SBin op a b | op `elem` cmpOps -> [(a, op, b)]
  _ -> []

negAtom :: SExpr -> [Atom]
negAtom e = case e of
  SBin op a b | Just op' <- lookup op negs -> [(a, op', b)]
  _ -> []
  where
    negs = [("==", "!="), ("!=", "=="), ("<", ">="), (">=", "<"), (">", "<="), ("<=", ">")]

flipOp :: Name -> Name
flipOp op = case op of "<" -> ">"; ">" -> "<"; "<=" -> ">="; ">=" -> "<="; o -> o

-- structural equality on the arithmetic fragment
eqA :: SExpr -> SExpr -> Bool
eqA (SVar a) (SVar b) = a == b
eqA (SInt a) (SInt b) = a == b
eqA (SBin o a b) (SBin o' a' b') = o == o' && eqA a a' && eqA b b'
eqA _ _ = False

-- variables mentioned by an atom/expr (fragment only)
varsA :: SExpr -> S.Set Name
varsA = \case
  SVar n -> S.singleton n
  SBin _ a b -> varsA a `S.union` varsA b
  _ -> S.empty

atomVars :: Atom -> S.Set Name
atomVars (a, _, b) = varsA a `S.union` varsA b

-- equality environment: x == k facts (either orientation)
constEnv :: [Atom] -> M.Map Name Integer
constEnv facts =
  M.fromList $
    [(v, k) | (SVar v, "==", SInt k) <- facts]
      ++ [(v, k) | (SInt k, "==", SVar v) <- facts]

evalA :: M.Map Name Integer -> SExpr -> Maybe Integer
evalA env = \case
  SInt n -> Just n
  SVar v -> M.lookup v env
  SBin "+" a b -> (+) <$> evalA env a <*> evalA env b
  SBin "-" a b -> (-) <$> evalA env a <*> evalA env b
  SBin "*" a b -> (*) <$> evalA env a <*> evalA env b
  _ -> Nothing

-- per-var bounds gathered from facts: (lower, upper, not-equal set)
data Bounds = Bounds {bLo :: Maybe Integer, bHi :: Maybe Integer, bNe :: S.Set Integer}

bounds :: M.Map Name Integer -> [Atom] -> Name -> Bounds
bounds env facts x = foldl' step (Bounds Nothing Nothing S.empty) facts
  where
    step b (l, op, r)
      | SVar v <- l, v == x, Just k <- evalA env r = apply b op k
      | SVar v <- r, v == x, Just k <- evalA env l = apply b (flipOp op) k
      | otherwise = b
    apply b op k = case op of
      "==" -> b {bLo = maxLo (bLo b) k, bHi = minHi (bHi b) k}
      "!=" -> b {bNe = S.insert k (bNe b)}
      ">" -> b {bLo = maxLo (bLo b) (k + 1)}
      ">=" -> b {bLo = maxLo (bLo b) k}
      "<" -> b {bHi = minHi (bHi b) (k - 1)}
      "<=" -> b {bHi = minHi (bHi b) k}
      _ -> b
    maxLo Nothing k = Just k
    maxLo (Just j) k = Just (max j k)
    minHi Nothing k = Just k
    minHi (Just j) k = Just (min j k)

-- does the fact set entail the predicate?  (conservative: False just
-- means "insert the runtime check")
entails :: [Atom] -> SExpr -> Bool
entails facts p = case p of
  SApp (SApp (SVar "and2") a) b -> entails facts a && entails facts b
  SApp (SApp (SVar "or2") a) b -> entails facts a || entails facts b
  SBin "and" a b -> entails facts a && entails facts b
  SBin "or" a b -> entails facts a || entails facts b
  SBin op a b | op `elem` cmpOps -> atomEnt (a, op, b)
  _ -> False
  where
    env = constEnv facts
    atomEnt at@(l, op, r)
      -- 1. fully evaluable under the equality env
      | Just kl <- evalA env l, Just kr <- evalA env r = cmpInt op kl kr
      -- 2. var-vs-const: decide against gathered interval/ne bounds
      | SVar v <- l, Just k <- evalA env r = varCmp v op k
      | SVar v <- r, Just k <- evalA env l = varCmp v (flipOp op) k
      -- 3. syntactic match against a fact (modulo orientation)
      | otherwise = any (matches at) facts
    cmpInt op x y = case op of
      "==" -> x == y; "!=" -> x /= y
      "<" -> x < y; "<=" -> x <= y
      ">" -> x > y; ">=" -> x >= y
      _ -> False
    varCmp v op k =
      let Bounds lo hi ne = bounds env facts v
       in case op of
            "!=" -> S.member k ne || maybe False (> k) lo || maybe False (< k) hi
            ">" -> maybe False (> k) lo
            ">=" -> maybe False (>= k) lo
            "<" -> maybe False (< k) hi
            "<=" -> maybe False (<= k) hi
            "==" -> lo == Just k && hi == Just k
            _ -> False
    matches (l, op, r) (l', op', r') =
      (op == op' && eqA l l' && eqA r r')
        || (flipOp op == op' && eqA l r' && eqA r l')
        || (op `elem` ["==", "!="] && op == op' && eqA l r' && eqA r l')

--------------------------------------------------------------------------------
-- the pass
--------------------------------------------------------------------------------

data PEnv = PEnv {pFresh :: Int, pNotes :: [PreNote]}

type PM = State PEnv

freshV :: PM Name
freshV = do
  s <- get
  put s {pFresh = pFresh s + 1}
  pure ("pcv" ++ show (pFresh s))

note :: PreNote -> PM ()
note n = modify (\s -> s {pNotes = n : pNotes s})

-- transform every TBind; fresh counter resets per bind so a bind
-- rewrites identically whether it is visited in the merged program or
-- in its own unit's list (unit codegen is cached + separate)
applyPreconds :: PreTable -> [STop] -> ([PreNote], [STop])
applyPreconds tab tops = (concat notes, tops')
  where
    (tops', notes) = unzip (map top tops)
    top (TBind n pats g body) =
      let facts = ownFacts n pats ++ concatMap conjuncts (guardBools g)
          shadow = S.empty
          (body', PEnv _ ns) = runState (goE tab n shadow facts body) (PEnv 0 [])
       in (TBind n pats g body', reverse ns)
    top t = (t, [])
    ownFacts n pats = case M.lookup n tab of
      Nothing -> []
      Just pres ->
        concat
          [ conjuncts (substV pn (SVar v) p)
            | (pat, Just (pn, p)) <- zip pats pres,
              PVar v <- [pat]
          ]

substV :: Name -> SExpr -> SExpr -> SExpr
substV x e = go
  where
    go = \case
      SVar v | v == x -> e
      SVar v -> SVar v
      SInt n -> SInt n
      SBin op a b -> SBin op (go a) (go b)
      SApp a b -> SApp (go a) (go b)
      other -> other

dropFacts :: S.Set Name -> [Atom] -> [Atom]
dropFacts names = filter (S.null . S.intersection names . atomVars)

pvars :: SPat -> S.Set Name
pvars = S.fromList . patVars

-- application spine, looking through the |> sugar (x |> f a  ==  f a x)
spine :: SExpr -> (SExpr, [SExpr])
spine = go []
  where
    go acc (SApp f a) = go (a : acc) f
    go acc (SBin "|>" x f) = let (h, as) = go [] f in (h, as ++ (x : acc))
    go acc e = (e, acc)

goE :: PreTable -> Name -> S.Set Name -> [Atom] -> SExpr -> PM SExpr
goE tab caller = go
  where
    go :: S.Set Name -> [Atom] -> SExpr -> PM SExpr
    go sh facts e = case e of
      -- builtin axiom: the divisor of / must be nonzero.  Analyzed and
      -- reported; the dynamic tier is the runtime's existing trap (no
      -- wrapper: / is TYPE-dispatched after this pass).
      SBin "/" a b -> do
        a' <- go sh facts a
        b' <- go sh facts b
        let p = SBin "!=" b' (SInt 0)
        if fragA b' && entails facts p
          then note (PreNote caller "(/)" (renderP p) Discharged)
          else note (PreNote caller "(/)" "divisor != 0" BuiltinTrap)
        pure (SBin "/" a' b')
      SBin "|>" _ _ -> goSpine sh facts e
      SApp _ _ -> goSpine sh facts e
      SMark o e -> SMark o <$> go sh facts e
      SBin op a b -> SBin op <$> go sh facts a <*> go sh facts b
      SLam ps b ->
        let sh' = S.union sh (S.fromList ps)
         in SLam ps <$> go sh' (dropFacts (S.fromList ps) facts) b
      SBlock stmts body -> do
        (stmts', sh', facts') <- goStmts sh facts stmts
        SBlock stmts' <$> go sh' facts' body
      SCase scrut arms -> do
        scrut' <- go sh facts scrut
        arms' <- goArms sh facts scrut' [] arms
        pure (SCase scrut' arms')
      SProj a fs -> flip SProj fs <$> go sh facts a
      SRec fs -> SRec <$> mapM (\(f, x) -> (,) f <$> go sh facts x) fs
      SUpd a us -> SUpd <$> go sh facts a <*> mapM (\(p, x) -> (,) p <$> go sh facts x) us
      STup xs -> STup <$> mapM (go sh facts) xs
      SList xs -> SList <$> mapM (go sh facts) xs
      SStrI segs -> SStrI <$> mapM seg segs
        where
          seg (SegExpr x) = SegExpr <$> go sh facts x
          seg s = pure s
      other -> pure other

    goStmts sh facts [] = pure ([], sh, facts)
    goStmts sh facts (SBind x ps rhs : rest) = do
      let shR = S.union sh (S.fromList ps)
      rhs' <- go shR (dropFacts (S.fromList ps) facts) rhs
      let facts1 = dropFacts (S.singleton x) facts
          facts2 = case (ps, rhs') of
            ([], SInt k) -> (SVar x, "==", SInt k) : facts1
            ([], SVar v) | not (S.member v sh) -> (SVar x, "==", SVar v) : facts1
            _ -> facts1
          sh' = S.insert x sh
      (rest', sh'', facts') <- goStmts sh' facts2 rest
      pure (SBind x ps rhs' : rest', sh'', facts')
    goStmts sh facts (SBindPat p rhs : rest) = do
      rhs' <- go sh facts rhs
      let vs = pvars p
          sh' = S.union sh vs
      (rest', sh'', facts') <- goStmts sh' (dropFacts vs facts) rest
      pure (SBindPat p rhs' : rest', sh'', facts')

    -- case arms: an int-literal arm on a var scrutinee adds v == k in
    -- the arm and v != k in all LATER arms; True/False arms on a
    -- comparison scrutinee add the comparison / its negation
    goArms _ _ _ _ [] = pure []
    goArms sh facts scrut prior ((p, body) : rest) = do
      let vs = pvars p
          armFacts = dropFacts vs facts ++ patFacts scrut p ++ negPrior scrut prior
          sh' = S.union sh vs
      body' <- go sh' armFacts body
      rest' <- goArms sh facts scrut (prior ++ [p]) rest
      pure ((p, body') : rest')
    patFacts (SVar v) (PInt k) = [(SVar v, "==", SInt k)]
    patFacts scrut (PCon "True" []) = conjuncts scrut
    patFacts scrut (PCon "False" []) = negAtom scrut
    patFacts _ _ = []
    negPrior (SVar v) prior = [(SVar v, "!=", SInt k) | PInt k <- prior]
    negPrior scrut prior =
      concat
        [ negAtom scrut | PCon "True" [] <- prior
        ]
        ++ concat [conjuncts scrut | PCon "False" [] <- prior]

    -- an application spine: recurse into args, then settle each
    -- preconditioned parameter -- discharged, or bound + checked
    goSpine sh facts e = do
      let (h, args) = spine e
      args' <- mapM (go sh facts) args
      case h of
        SVar f
          | not (S.member f sh),
            Just pres <- M.lookup f tab -> do
              obs <- forM (zip3 [0 :: Int ..] args' (pres ++ repeat Nothing)) $ \(i, arg, mpre) ->
                case mpre of
                  Nothing -> pure (i, arg, Nothing)
                  Just (pn, p0) -> do
                    let p = substV pn arg p0
                    if fragA arg && entails facts p
                      then do
                        note (PreNote caller f (renderP p) Discharged)
                        pure (i, arg, Nothing)
                      else do
                        note (PreNote caller f (renderP (substV pn (SVar pn) p0)) RuntimeCheck)
                        pure (i, arg, Just (pn, p0))
              buildChecked f obs
        _ -> do
          h' <- go sh facts h
          pure (foldl' SApp h' args')

    -- rebuild `f a1 .. an`: every checked arg is let-bound to a fresh
    -- var; checks nest as True/_ cases around the call, blame + value
    -- interpolated into the error string
    buildChecked f obs = do
      bound <- forM obs $ \(_, arg, mchk) -> case mchk of
        Nothing -> pure (arg, Nothing)
        Just (pn, p0) -> do
          t <- freshV
          pure (SVar t, Just (t, arg, pn, p0))
      let call = foldl' SApp (SVar f) (map fst bound)
          checks = [c | (_, Just c) <- bound]
          wrap body (t, _, pn, p0) =
            SCase
              (substV pn (SVar t) p0)
              [ (PCon "True" [], body),
                ( PWild,
                  SApp
                    (SVar "error")
                    ( SStrI
                        [ SegStr ("precondition violated: " ++ f ++ " requires (" ++ renderP p0 ++ "), got " ++ pn ++ "="),
                          SegExpr (SVar t),
                          SegStr (" (in " ++ caller ++ ")")
                        ]
                    )
                )
              ]
          body0 = foldl' wrap call checks
          stmts = [SBind t [] arg | (t, arg, _, _) <- checks]
      pure $ if null stmts then call else SBlock stmts body0

-- is an arg expression inside the arithmetic fragment (so substituting
-- it into a predicate keeps the predicate decidable)?
fragA :: SExpr -> Bool
fragA = \case
  SVar _ -> True
  SInt _ -> True
  SBin op a b | op `elem` ["+", "-", "*"] -> fragA a && fragA b
  _ -> False
