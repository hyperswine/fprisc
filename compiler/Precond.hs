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
-- Escaping function values use typed checked entries instead: aliases,
-- fields and higher-order calls cannot discard the contract. Direct named
-- partial applications check supplied arguments immediately and retain an
-- entry for the rest. Escaped function values check their full boundary
-- when saturated; their PAP arguments are still evaluated/captured once.

module Precond where

import Control.Monad (forM)
import Control.Monad.State.Strict
import Data.List (foldl', isPrefixOf)
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
        -- reserved entries ($unsafe, $work, $alloc) are not value predicates
        let pres' = [ p >>= \(v, q) -> (,) v . logicalPred <$> snd (splitMeasure q)
                    | p <- pres, not (reservedEntry p) ],
        any (/= Nothing) (map (fmap (const ())) pres')
    ]

-- and2/or2 are predicate grammar, not calls to a caller's (possibly
-- shadowed) helper. Lower them to the unshadowable Boolean syntax before
-- checks or own facts are generated. Source guards keep ordinary call
-- semantics and cannot acquire facts merely from a helper's spelling.
logicalPred :: SExpr -> SExpr
logicalPred = \case
  SApp (SApp (SVar "and2") a) b -> SBin "and" (logicalPred a) (logicalPred b)
  SApp (SApp (SVar "or2") a) b -> SBin "or" (logicalPred a) (logicalPred b)
  SBin op a b -> SBin op (logicalPred a) (logicalPred b)
  e -> e

-- the signature list also carries the $unsafe marker and the $work/$alloc
-- resource bounds (FPRISC.fullSig): never a value predicate
reservedEntry :: Maybe (Name, SExpr) -> Bool
reservedEntry = maybe False ((== "$") . take 1 . fst)

-- `(x : T | x >= 0 and measure x)`: one predicate slot, two readers.  The
-- `measure` conjunct is a termination declaration for Safety.measureCheck;
-- whatever remains is the value precondition this pass discharges or
-- guards.  Returns (the measure's expression, the remaining predicate).
splitMeasure :: SExpr -> (Maybe SExpr, Maybe SExpr)
splitMeasure e = case e of
  SApp (SVar "measure") m -> (Just m, Nothing)
  SBin "and" a b -> comb a b (SBin "and")
  SApp (SApp (SVar "and2") a) b -> comb a b (\x y -> SApp (SApp (SVar "and2") x) y)
  _ -> (Nothing, Just e)
  where
    comb a b mk =
      let (ma, ra) = splitMeasure a
          (mb, rb) = splitMeasure b
       in ( case ma of Just _ -> ma; Nothing -> mb,
            case (ra, rb) of
              (Just x, Just y) -> Just (mk x y)
              (Just x, Nothing) -> Just x
              (Nothing, y) -> y
          )

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
  ++
  [ "precondition on " ++ f ++ " (" ++ v ++ "): free predicate names are not supported: "
      ++ unwords (S.toList free) ++ "; only its own parameter " ++ v
      ++ " is in scope (relational/global predicates require explicit support)"
    | (f, pres) <- M.toList tab,
      Just (v, p) <- pres,
      okPred p,
      let free = predVars p `S.difference` S.singleton v,
      not (S.null free)
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
    -- Do not capture a global or another parameter by spelling its name
    -- into a caller's scope. This pass currently substitutes one binder,
    -- so only that binder can be a sound value-predicate variable. A
    -- separate measure expression was already removed by splitMeasure.
    predVars = \case
      SApp (SApp (SVar c) a) b | c `elem` ["and2", "or2"] -> predVars a `S.union` predVars b
      SBin _ a b -> predVars a `S.union` predVars b
      SVar n -> S.singleton n
      _ -> S.empty

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
  -- '$' cannot occur in a source identifier. A user binding named pcv0
  -- must not capture a generated check (or be captured by its let).
  pure ("$pcv" ++ show (pFresh s))

note :: PreNote -> PM ()
note n = modify (\s -> s {pNotes = n : pNotes s})

-- transform every TBind; fresh counter resets per bind so a bind
-- rewrites identically whether it is visited in the merged program or
-- in its own unit's list (unit codegen is cached + separate)
applyPreconds :: PreTable -> [STop] -> ([PreNote], [STop])
applyPreconds tab tops = (concat notes ++ concat entryNotes, tops' ++ concat entries)
  where
    (tops', notes) = unzip (map top tops)
    top (TBind n pats g body) =
      let shadow = S.unions (map pvars pats)
          rewrite = do
            (g', sh, facts) <- guards n shadow (ownFacts n pats) g
            body' <- goE tab n sh facts body
            pure (g', body')
          ((g', body'), PEnv _ ns) = runState rewrite (PEnv 0 [])
       in (TBind n pats g' body', reverse ns)
    top (TEval body) =
      let (body', PEnv _ ns) = runState (goE tab "<eval>" S.empty [] body) (PEnv 0 [])
       in (TEval body', reverse ns)
    top (TStruct n sigs fs) =
      let field (f, body) =
            let (body', PEnv _ ns) = runState (goE tab (n ++ "." ++ f) S.empty [] body) (PEnv 0 [])
             in ((f, body'), reverse ns)
          (fs', ns) = unzip (map field fs)
       in (TStruct n sigs fs', concat ns)
    top t = (t, [])
    -- Guards have sequential scope, including pattern-bound names. A
    -- Boolean guard becomes a fact only AFTER its own calls are checked.
    guards _ sh facts [] = pure ([], sh, facts)
    guards n sh facts (g : gs) = do
      (g', sh', facts') <- case g of
        GBool e -> do
          e' <- goE tab n sh facts e
          pure (GBool e', sh, facts ++ conjuncts e)
        GPat p e -> do
          e' <- goE tab n sh facts e
          let vs = pvars p
          pure (GPat p e', S.union sh vs, dropFacts vs facts)
      (gs', sh'', facts'') <- guards n sh' facts' gs
      pure (g' : gs', sh'', facts'')
    -- Keep the original arrow signature on each checked entry. An
    -- anonymous eta lambda loses parameter/return ownership information
    -- in the surface linearity checker, allowing a captured Vector PAP
    -- to be reused. Typed globals retain that existing linear discipline.
    -- Entry k receives all arguments but checks only slots k..arity-1:
    -- slots before k were checked when the partial application was made.
    localSigs = M.fromList [(n, (ty, ps)) | TSig n ty ps <- tops]
    (entries, entryNotes) = unzip
      [ let args = ["$pcarg" ++ show i | i <- [0 .. length pres - 1]]
            obs = [(i, SVar a, if i < supplied then Nothing else p)
                  | (i, a, p) <- zip3 [0 ..] args pres]
            entry = checkedName n supplied
            (body, PEnv _ ns) = runState (buildChecked n "higher-order call" n obs) (PEnv 0 [])
            -- Resource declarations belong to the original body. The
            -- added checks have a real cost, derived normally; never
            -- copy a budget or invent an unsafe escape to hide that cost.
            markers = filter (maybe False ((== "$unsafe") . fst)) sigPres
         in ([TSig entry ty (replicate (length pres) Nothing ++ markers),
              TBind entry (map PVar args) [] body], reverse ns)
      | (n, (ty, sigPres)) <- M.toList localSigs,
        Just pres <- [M.lookup n tab],
        supplied <- [0 .. length pres - 1],
        any hasPre (drop supplied pres)
      ]
    ownFacts n pats = case M.lookup n tab of
      Nothing -> []
      Just pres ->
        concat
          [ conjuncts (substV pn (SVar v) p)
            | (pat, Just (pn, p)) <- zip pats pres,
              PVar v <- [pat]
          ]

hasPre :: Maybe a -> Bool
hasPre Nothing = False
hasPre (Just _) = True

checkedName :: Name -> Int -> Name
checkedName n supplied = "$precond" ++ show supplied ++ "." ++ n

-- A signature may describe more arrows than the definition accepts
-- syntactically (the body returns a function). A full-arity checked entry
-- would defer that body's effects until the remaining arrows arrive.
-- Refuse such escaping uses until staged entries can preserve the real
-- application boundaries. Ordinary saturated calls retain their existing
-- checks and are unaffected. Bodyless foreign signatures use their stated
-- arity. The scan reads the same deterministic rewrite codegen consumes.
validatePreUses :: PreTable -> [STop] -> [String]
validatePreUses tab tops =
  [ "precondition on " ++ n ++ ": a contracted function value/partial application requires its definition to accept all "
      ++ show (length pres) ++ " declared parameters (definition accepts " ++ show arity
      ++ "); move returned-function arguments into the definition to preserve application timing"
    | (n, pres) <- M.toList tab,
      Just arity <- [M.lookup n arities], arity /= length pres,
      any (`S.member` used) [checkedName n k | k <- [0 .. length pres - 1]]
  ]
  where
    arities = M.fromList [(n, length ps) | TBind n ps _ _ <- tops]
    transformed = snd (applyPreconds tab tops)
    used = S.unions (map topNames transformed)
    topNames (TBind n _ gs e) | not ("$precond" `isPrefixOf` n) =
      names e `S.union` S.unions [names x | g <- gs, x <- case g of GBool q -> [q]; GPat _ q -> [q]]
    topNames (TEval e) = names e
    topNames (TStruct _ _ fs) = S.unions (map (names . snd) fs)
    topNames _ = S.empty
    names = \case
      SVar n -> S.singleton n
      SMark _ e -> names e
      SApp f x -> names f `S.union` names x
      SLam _ e -> names e
      SBlock ss e -> names e `S.union` S.unions [names x | s <- ss, x <- case s of SBind _ _ q -> [q]; SBindPat _ q -> [q]]
      SCase s arms -> names s `S.union` S.unions (map (names . snd) arms)
      SBin _ a b -> names a `S.union` names b
      SProj e _ -> names e
      SRec fs -> S.unions (map (names . snd) fs)
      SUpd e fs -> names e `S.union` S.unions (map (names . snd) fs)
      STup es -> S.unions (map names es)
      SList es -> S.unions (map names es)
      SStrI ss -> S.unions [names e | SegExpr e <- ss]
      _ -> S.empty

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
      SVar f | not (S.member f sh), M.member f tab ->
        do checkedValueNotes f (tab M.! f)
           pure (SVar (checkedName f 0))
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
      -- Local bindings are recursive, as in Infer.goBlock. Both their
      -- own name and their parameters shadow contracted global names.
      let rhsNames = S.fromList (x : ps)
          shR = S.union sh rhsNames
      rhs' <- go shR (dropFacts rhsNames facts) rhs
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
      case unmark h of
        SVar f
          | not (S.member f sh),
            Just pres <- M.lookup f tab -> do
              -- The result itself may be a function. Its overapplied
              -- arguments belong to a later boundary: evaluate them only
              -- after the checked declared prefix has called f.
              let (given, trailing) = splitAt (length pres) args'
              obs <- forM (zip3 [0 :: Int ..] given pres) $ \(i, arg, mpre) ->
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
              let supplied = length given
                  target = if any hasPre (drop supplied pres)
                             then checkedName f supplied else f
              checkedValueNotes f (drop supplied pres)
              checked <- buildChecked f caller target obs
              pure (foldl' SApp checked trailing)
        _ -> do
          h' <- go sh facts h
          pure (foldl' SApp h' args')

    checkedValueNotes f pres = mapM_ report [p | Just (_, p) <- pres]
      where report p = note (PreNote caller f (renderP p) RuntimeCheck)

-- Bind arguments once, in source order, before checking them in parameter
-- order. This matters for effectful expressions and for partial calls:
-- creating a direct named PAP evaluates/checks its supplied arguments
-- immediately; its eventual invocation must neither repeat nor reorder
-- them. Escaped values enter their checked function only at saturation.
buildChecked :: Name -> Name -> Name -> [(Int, SExpr, Maybe (Name, SExpr))] -> PM SExpr
buildChecked f caller target obs
  | not (any (hasPre . third) obs) = pure (foldl' SApp (SVar target) [a | (_, a, _) <- obs])
  | otherwise = do
      bound <- forM obs $ \(_, arg, mchk) -> do
        t <- freshV
        pure (t, arg, mchk)
      let call = foldl' SApp (SVar target) [SVar t | (t, _, _) <- bound]
          checks = [(t, pn, p0) | (t, _, Just (pn, p0)) <- bound]
          wrap (t, pn, p0) body =
            SCase
              (substV pn (SVar t) p0)
              [ (PCon "True" [], body),
                ( PWild,
                  SApp (SVar "error")
                    (SStrI
                      [ SegStr ("precondition violated: " ++ f ++ " requires (" ++ renderP p0 ++ "), got " ++ pn ++ "="),
                        SegExpr (SVar t),
                        SegStr (" (in " ++ caller ++ ")")
                      ])
                )
              ]
      pure (SBlock [SBind t [] arg | (t, arg, _) <- bound] (foldr wrap call checks))
  where third (_, _, x) = x

-- is an arg expression inside the arithmetic fragment (so substituting
-- it into a predicate keeps the predicate decidable)?
fragA :: SExpr -> Bool
fragA = \case
  SVar _ -> True
  SInt _ -> True
  SBin op a b | op `elem` ["+", "-", "*"] -> fragA a && fragA b
  _ -> False
