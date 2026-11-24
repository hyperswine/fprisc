{-# LANGUAGE LambdaCase #-}
-- Keyed-list folds: a list kept by key while a fold runs is kept in a table.
--
--   replayed m ls = List.fold (fn mm l -> apply { mm | events = mm.events + 1 } l) m ls
--   ...
--   putItem renamed m it = case List.find (fn x -> x.id == it.id) m.items of
--       Option.None -> { m | items = it :: m.items }
--     | Option.Some old -> new = { it | created = old.created };
--                          { m | items = List.map (fn x -> if x.id == it.id then new else x) m.items }
--   applyOp m op v | strEq op "del" = { m | items = List.filter (fn it -> it.id != int "id" v) m.items }
--
-- rebuilds the list (and walks it) for every step.  Nothing but the fold holds
-- the list while it is built, so the same entries are kept in std/keyedlist's
-- linear table (a MutMap from key to element, plus the keys' order) and turned
-- back into the list once, at the end (docs/2026-11-18-KEYED-LIST-FOLDS.md).
-- The list is either the accumulator itself or one field F of a record
-- accumulator; in the record case every root function the step hands the
-- record to gets a twin, NAME__keyedfoldN, that takes and returns the table
-- beside the record.
--
-- When it applies (all syntactic, on the root's surface tree; the result is
-- type and linearity checked like any other program):
--
--   * the fold is List.fold of std/list, applied to a step (a two-parameter
--     lambda or a root function of two parameters), a start and a list;
--   * the list is read and written ONLY by these, all with the same key
--     field K (x.K == e may also be e == x.K, or a root helper whose body is
--     a == b; a root helper whose body is one of these forms is inlined):
--       find     List.find (fn x -> x.K == e) L       as a case scrutinee
--       put      y :: L     in the None arm of that find, y.K being e, with
--                           no other table operation in between
--       replace  List.map (fn x -> if x.K == e then NEW else x) L
--                (or a root helper of two clauses, `h x .. | x.K == p = NEW`
--                and `h x .. = x`), NEW keeping K: { x | .. }, or a record
--                update or literal whose K is e
--       delete   List.filter (fn x -> x.K != e) L    (or not (x.K == e))
--     and e is effect-free (no Sys/print/error, no unknown closures; root
--     functions are checked through, std modules by a list of pure ones);
--   * the record (record case) only flows: field reads other than F, record
--     updates, case scrutinee reads, arguments of root functions that
--     themselves qualify (not recursive, no preconditions), and results;
--   * the fold changes the list at least once.
--
-- Why the order is the list's: keys start unique (the start's list is
-- empty, checked when the fold runs; otherwise the fold runs as written) and
-- stay unique (put only when find said absent, replace keeps the key), so
-- find, replace and delete touch the one element with that key, and put
-- adds it at the front.  The table's order list holds keys newest first;
-- the list is the entries in that order, each key at its newest place.
--
-- The key's type decides the table: the step is wrapped in the special form
-- `fprKeyedFold# ORIGINAL (fn table -> REWRITTEN)`, which inference types as
-- both and resolves by the key type: Int and String keep the rewritten fold
-- with an Int or String MutMap; any other key type keeps the original.
-- FPR_NO_KEYED_LIST_FOLD=1 turns the rewrite off.
module Frontend.KeyedListFold (keyedListFolds, keyedFoldMarker, keyedListAlias,
  walkM, spineP, unmark, substitute, universe, patVars, modulePath, mentions, isVar, trivial) where

import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (isSuffixOf)
import Data.Maybe (isJust)
import Control.Monad (forM, unless, when)
import Control.Monad.State.Strict
import Frontend.Syntax
import Core.Syntax (Name)

keyedFoldMarker, keyedListAlias :: Name
keyedFoldMarker = "fprKeyedFold#"
keyedListAlias = "FprKeyedListFold"

type Clause = ([SPat], [SGuard], SExpr)

data Prog = Prog
  { pLists :: [Name]                 -- aliases of std/list
  , pClauses :: M.Map Name [Clause]  -- root functions
  , pPre :: S.Set Name               -- root functions with a precondition
  , pPure :: S.Set Name              -- aliases of std modules with no effects
  }

-- the rewritten program and, per fold rewritten, the function it is in
keyedListFolds :: [STop] -> ([STop], [Name])
keyedListFolds tops
  | null lists = (tops, [])
  | null sites = (tops, [])
  | otherwise = (TUse keyedListAlias "std/keyedlist" : tops' ++ twins, sites)
  where
    aliases = [(a, modulePath p) | TUse a p <- tops]
    lists = [a | (a, p) <- aliases, p == "std/list"]
    prog = Prog
      { pLists = lists
      , pClauses = M.fromListWith (flip (++)) [(f, [(ps, gs, b)]) | TBind f ps gs b <- tops]
      , pPre = S.fromList [f | TSig f _ pre <- tops, any isJust pre]
      , pPure = S.fromList [a | (a, p) <- aliases, p `elem` pureModules] }
    (tops', st) = runState (mapM (visitTop prog) tops) (Gen 0 [] [])
    twins = reverse (gTwins st)
    sites = reverse (gSites st)

-- keyedListFolds only runs with std/list imported
listAlias :: Prog -> Name
listAlias prog = case pLists prog of a : _ -> a; [] -> "List"

pureModules :: [String]
pureModules = ["std/list", "std/option", "std/order", "std/string", "std/json", "std/decode",
               "std/map", "std/char", "std/result", "std/text"]

data Gen = Gen { gFresh :: Int, gTwins :: [STop], gSites :: [Name] }

visitTop :: Prog -> STop -> State Gen STop
visitTop prog t = case t of
  TBind f ps gs b -> TBind f ps gs <$> walk prog f (S.fromList (concatMap patVars ps)) b
  _ -> pure t

-- every qualifying fold in an expression, innermost first
walk :: Prog -> Name -> S.Set Name -> SExpr -> State Gen SExpr
walk prog site = walkM $ \bound e' -> case foldCall prog e' of
  Just (step, start, xs) -> do
    g <- get
    case tryFold prog bound (gFresh g) step start xs of
      Just (rebuilt, fresh', twins) -> do
        put g {gFresh = fresh', gTwins = reverse twins ++ gTwins g, gSites = site : gSites g}
        pure rebuilt
      Nothing -> pure e'
  Nothing -> pure e'

-- bottom up: children first, then f at the node with the names bound there
-- (a name in the set may shadow a top-level one)
walkM :: Monad m => (S.Set Name -> SExpr -> m SExpr) -> S.Set Name -> SExpr -> m SExpr
walkM f bound e = descend >>= f bound
  where
    w = walkM f
    descend = case e of
      SMark o a -> SMark o <$> w bound a
      SApp a b -> SApp <$> w bound a <*> w bound b
      SLam ps b -> SLam ps <$> w (bound `S.union` S.fromList ps) b
      SBlock ss r -> do
        let go bd [] = (\r' -> ([], r')) <$> w bd r
            go bd (s : rest) = case s of
              SBind v ps rhs -> do
                rhs' <- w (bd `S.union` S.fromList (v : ps)) rhs
                (rest', r') <- go (S.insert v bd) rest
                pure (SBind v ps rhs' : rest', r')
              SBindPat p rhs -> do
                rhs' <- w bd rhs
                (rest', r') <- go (bd `S.union` S.fromList (patVars p)) rest
                pure (SBindPat p rhs' : rest', r')
        (ss', r') <- go bound ss
        pure (SBlock ss' r')
      SCase s arms -> SCase <$> w bound s <*> mapM (\(p, b) -> (,) p <$> w (bound `S.union` S.fromList (patVars p)) b) arms
      SBin o a b -> SBin o <$> w bound a <*> w bound b
      SProj a fs -> (`SProj` fs) <$> w bound a
      SRec fs -> SRec <$> mapM (\(n, v) -> (,) n <$> w bound v) fs
      SUpd a fs -> SUpd <$> w bound a <*> mapM (\(p, v) -> (,) p <$> w bound v) fs
      STup es -> STup <$> mapM (w bound) es
      SList es -> SList <$> mapM (w bound) es
      SStrI segs -> SStrI <$> mapM (\case SegExpr x -> SegExpr <$> w bound x; o -> pure o) segs
      _ -> pure e

foldCall :: Prog -> SExpr -> Maybe (SExpr, SExpr, SExpr)
foldCall prog e = case spineP e of
  (SVar f, [step, start, xs]) | f `elem` [l ++ ".fold" | l <- pLists prog] -> Just (step, start, xs)
  _ -> Nothing

-- ---- one fold -------------------------------------------------------------

data Mode = Rec Name | Lst deriving (Eq, Show)

data Env = Env
  { eModels :: M.Map Name Name  -- model variable -> the table it goes with
  , eKt :: Name                 -- the current table
  , eAbsent :: Maybe SExpr      -- a key the last find said is absent
  , eLocals :: M.Map Name SExpr -- clean let-bound locals
  , eBound :: S.Set Name        -- every local name in scope
  }

data St = St
  { sFresh :: Int
  , sKey :: Maybe Name
  , sNeed :: [(Name, Int)]       -- twins asked for: (function, model position)
  , sChanges :: Int              -- table writes converted
  , sOwner :: Name               -- the function being converted (cycle check)
  , sCalls :: [(Name, Name)]     -- twin call edges
  }

type C = StateT St Maybe

failC :: C a
failC = lift Nothing

fresh :: String -> C Name
fresh s = do
  st <- get
  put st {sFresh = sFresh st + 1}
  pure ("kl__" ++ s ++ show (sFresh st))

tryFold :: Prog -> S.Set Name -> Int -> SExpr -> SExpr -> SExpr -> Maybe (SExpr, Int, [STop])
tryFold prog bound fresh0 step start xs = firstJust [attempt m | m <- Lst : map Rec (candidateFields prog step)]
  where
    firstJust = foldr (\a b -> maybe b Just a) Nothing
    suffix = show fresh0
    attempt mode = do
      (res, st) <- runStateT (build mode) (St (fresh0 + 1) Nothing [] 0 "" [])
      twins <- closeTwins prog mode suffix st
      unless (tChanges twins > 0) Nothing
      pure (res, tFresh twins, tTops twins)
      where
        build m = do
          (accP, xP, body) <- stepParts
          kt0 <- fresh "t"
          s <- fresh "s"
          xv <- fresh "xs"
          t0 <- fresh "t0"
          r <- fresh "r"
          kN <- fresh "k"
          st' <- fresh "st"
          modify (\x -> x {sOwner = ""})
          let env = Env (M.singleton accP kt0) kt0 Nothing M.empty (S.fromList [xP] `S.union` bound)
          body' <- prod prog m suffix env body
          let fold f z l = foldl SApp (SVar (listAlias prog ++ ".fold")) [f, z, l]
              orig = fold step (SVar s) (SVar xv)
              table = SApp (SVar (keyedListAlias ++ ".empty")) (SVar t0)
              (step', z, finish) = case m of
                Rec f -> ( SLam [st', xP] (SCase (SVar st') [(PTup [PVar accP, PVar kt0], body')])
                         , STup [SVar s, table]
                         , \folded -> SCase folded [(PTup [PVar r, PVar kN], SUpd (SVar r) [([f], SApp (SVar (keyedListAlias ++ ".toList")) (SVar kN))])] )
                Lst -> ( SLam [kt0, xP] body', table, SApp (SVar (keyedListAlias ++ ".toList")) )
              fast = SLam [t0] (finish (fold step' z (SVar xv)))
              guardE = case m of Rec f -> SProj (SVar s) [f]; Lst -> SVar s
          pure (SBlock [SBind s [] start, SBind xv [] xs]
                  (SCase guardE [(PCon "Nil" [], SApp (SApp (SVar keyedFoldMarker) orig) fast), (PWild, orig)]))
        stepParts = case unmark step of
          SLam [a, x] b | a /= x -> pure (a, x, b)
          SVar f | S.notMember f bound, Just cls <- M.lookup f (pClauses prog), all ((== 2) . arity) cls -> do
            a <- fresh "a"
            x <- fresh "x"
            pure (a, x, SApp (SApp (SVar f) (SVar a)) (SVar x))
          _ -> failC
        arity (ps, _, _) = length ps

data Twins = Twins { tFresh :: Int, tTops :: [STop], tChanges :: Int }

-- convert every function the step handed the model to, until none is new
closeTwins :: Prog -> Mode -> String -> St -> Maybe Twins
closeTwins prog mode suffix st0 = go st0 S.empty []
  where
    go st done acc = case [nd | nd@(f, _) <- sNeed st, S.notMember f done] of
      [] -> do
        when (cyclic (sCalls st)) Nothing
        pure (Twins (sFresh st) (reverse acc) (sChanges st))
      (f, pos) : _ -> do
        -- one function, one model position
        when (S.size (S.fromList [p | (g, p) <- sNeed st, g == f]) > 1) Nothing
        when (S.member f (pPre prog)) Nothing
        cls <- M.lookup f (pClauses prog)
        (cls', st') <- runStateT (mapM (twinClause f pos) cls) st {sOwner = f}
        let tn = twinName suffix f
        go st' (S.insert f done) (reverse [TBind tn ps gs b | (ps, gs, b) <- cls'] ++ acc)
    twinClause f pos (ps, gs, b) = do
      unless (pos < length ps) failC
      mp <- case ps !! pos of PVar v -> pure v; _ -> failC
      kt <- fresh "t"
      let others = concat [patVars p | (i, p) <- zip [0 :: Int ..] ps, i /= pos]
          env = Env (M.singleton mp kt) kt Nothing M.empty (S.fromList others)
      -- guards may read the model's other fields, nothing more
      gsOk <- pure (all (guardClean env) gs)
      unless gsOk failC
      let gBound = concat [patVars p | GPat p _ <- gs]
      when (mp `elem` gBound) failC
      b' <- prod prog mode suffix env {eBound = eBound env `S.union` S.fromList gBound} b
      let ps' = case mode of
            Rec _ -> ps ++ [PVar kt]
            Lst -> [if i == pos then PVar kt else p | (i, p) <- zip [0 :: Int ..] ps]
      _ <- pure f
      pure (ps', gs, b')
    guardClean env g = case g of
      GBool x -> cleanE mode env x
      GPat _ x -> cleanE mode env x
    cyclic edges =
      let gr = M.fromListWith (++) [(a, [b]) | (a, b) <- edges]
          reach seen [] = seen
          reach seen (x : xs) | S.member x seen = reach seen xs
                              | otherwise = reach (S.insert x seen) (M.findWithDefault [] x gr ++ xs)
      in or [S.member a (reach S.empty (M.findWithDefault [] a gr)) | a <- M.keys gr]

twinName :: String -> Name -> Name
twinName suffix f = f ++ "__keyedfold" ++ suffix

-- the fields a record step could be keeping a list in: every F read as
-- `v.F` where a list operation takes its list
candidateFields :: Prog -> SExpr -> [Name]
candidateFields prog _ = S.toList (S.fromList
  [f | cls <- M.elems (pClauses prog), (_, gs, b) <- cls, x <- universe b ++ concat [universe g | GBool g <- gs], f <- listArgField x])
  where
    listArgField x = case spineP x of
      (SVar h, [_, l]) | h `elem` [a ++ "." ++ op | a <- pLists prog, op <- ["find", "map", "filter"]] -> projField l
      _ -> case unmark x of
        SBin "::" _ l -> projField l
        _ -> []
    projField l = case unmark l of
      SProj (SVar _) [f] -> [f]
      _ -> []

-- ---- converting a body ----------------------------------------------------

isModel :: Env -> Name -> Bool
isModel env v = M.lookup v (eModels env) == Just (eKt env)

-- the model's list, as an operation's argument
isTable :: Mode -> Env -> SExpr -> Bool
isTable mode env l = case (mode, unmark l) of
  (Rec f, SProj (SVar v) [f']) -> f == f' && isModel env v
  (Lst, SVar v) -> isModel env v
  _ -> False

-- no model mentioned, except (record mode) reads of other fields
cleanE :: Mode -> Env -> SExpr -> Bool
cleanE mode env e = go e
  where
    models = M.keysSet (eModels env)
    go x = case x of
      SVar v -> S.notMember v models
      SProj (SVar v) (f : _) | S.member v models -> case mode of Rec fl -> f /= fl; Lst -> False
      SMark _ a -> go a
      SApp a b -> go a && go b
      SLam ps b -> not (any (`S.member` models) ps) && go b
      SBlock ss r -> all stmt ss && go r
      SCase s arms -> go s && and [go b | (_, b) <- arms]
      SBin _ a b -> go a && go b
      SProj a _ -> go a
      SRec fs -> all (go . snd) fs
      SUpd a fs -> go a && all (go . snd) fs
      STup es -> all go es
      SList es -> all go es
      SStrI segs -> and [go g | SegExpr g <- segs]
      _ -> True
    stmt s = case s of
      SBind _ _ rhs -> go rhs
      SBindPat _ rhs -> go rhs

pairE :: Mode -> SExpr -> Name -> SExpr
pairE mode r kt = case mode of
  Rec _ -> STup [r, SVar kt]
  Lst -> SVar kt

-- an expression that yields the model, rewritten to yield (record, table)
-- (record mode) or the table (list mode)
prod :: Prog -> Mode -> String -> Env -> SExpr -> C SExpr
prod prog mode suffix env e = case e of
  SMark o a -> SMark o <$> prod prog mode suffix env a
  SVar v | isModel env v -> pure (pairE mode (SVar v) (eKt env))
  SUpd (SVar v) flds | Rec f <- mode, isModel env v -> do
    let (mine, others) = (filter ((== [f]) . fst) flds, filter ((/= [f]) . fst) flds)
    when (any ((== [f]) . take 1) [p | (p, _) <- others]) failC
    unless (all (cleanE mode env . snd) others) failC
    let rec' = if null others then SVar v else SUpd (SVar v) others
    case mine of
      [] -> pure (pairE mode rec' (eKt env))
      [(_, val)] -> do
        op <- tableWrite prog mode env val
        k' <- fresh "t"
        pure (SBlock [SBind k' [] op] (pairE mode rec' k'))
      _ -> failC
  SCase s arms -> do
    (pre, s', env') <- scrutinee s
    arms' <- forM arms $ \(p, b) -> do
      let pv = patVars p
      when (any (`M.member` eModels env') pv) failC
      let absent = case eAbsent env' of
            Just k | isNone p -> Just k
            _ -> Nothing
          env'' = scope pv env' {eAbsent = if null pre then eAbsent env' else absent}
      (,) p <$> prod prog mode suffix env'' b
    pure (wrap pre (SCase s' arms'))
  SBlock ss r -> block env ss
    where
      block en [] = prod prog mode suffix en r
      block en (st : rest) = case st of
        SBind v [] rhs
          | cleanE mode en rhs -> do
              when (M.member v (eModels en)) failC
              (SBlock [st] <$> block (scope [v] en) {eLocals = M.insert v rhs (eLocals en)} rest) >>= flat
          | SUpd (SVar m) flds <- unmark rhs, Rec f <- mode, isModel en m, all ((/= [f]) . fst) flds,
            all (cleanE mode en . snd) flds -> do
              -- a record update that leaves the list alone: the same table
              when (M.member v (eModels en)) failC
              let en' = (scope [v] en) {eModels = M.insert v (eKt en) (eModels en)}
              (SBlock [st] <$> block en' rest) >>= flat
          | otherwise -> do
              when (M.member v (eModels en)) failC
              rhs' <- prod prog mode suffix en rhs
              k' <- fresh "t"
              let en' = (scope [v] en) {eModels = M.insert v k' (eModels en), eKt = k', eAbsent = Nothing}
                  bind = case mode of
                    Rec _ -> SBindPat (PTup [PVar v, PVar k']) rhs'
                    Lst -> SBind k' [] rhs'
              (SBlock [bind] <$> block en' rest) >>= flat
        SBind v ps rhs -> do
          unless (cleanE mode en rhs) failC
          when (any (`M.member` eModels en) (v : ps)) failC
          (SBlock [st] <$> block (scope [v] en) rest) >>= flat
        SBindPat p rhs -> do
          unless (cleanE mode en rhs) failC
          when (any (`M.member` eModels en) (patVars p)) failC
          (SBlock [st] <$> block (scope (patVars p) en) rest) >>= flat
  _ | Lst <- mode, writeShape -> tableWrite prog mode env e
  _ | (SVar f, args) <- spineP e, S.notMember f (eBound env), Just cls <- M.lookup f (pClauses prog),
      all (\(ps, _, _) -> length ps == length args) cls ->
        twinCall f args
  _ -> failC
  where
    writeShape = case unmark e of
      SBin "::" _ l -> isTable mode env l
      _ -> case spineP e of
        (SVar h, [_, l]) -> isTable mode env l && h `elem` (listOps prog "map" ++ listOps prog "filter")
        _ -> False
    flat x = pure (case x of
      SBlock [s1] (SBlock ss r) -> SBlock (s1 : ss) r
      _ -> x)
    wrap pre x = if null pre then x else SBlock pre x
    scope vs en = en { eBound = eBound en `S.union` S.fromList vs
                     , eLocals = foldr M.delete (eLocals en) vs
                     , eAbsent = dropIf vs (eAbsent en) }
    dropIf vs a = case a of
      Just k | any (`mentions` k) vs -> Nothing
      _ -> a
    -- a case scrutinee: clean, or a find on the table
    scrutinee s
      | cleanE mode env s = pure ([], s, env)
      | otherwise = do
          (k, kexpr) <- findOp prog mode env s
          setKey k
          rv <- fresh "r"
          k' <- fresh "t"
          let call = keyCall prog env "find" kexpr [SVar (eKt env)]
              env' = env { eModels = M.map (\t -> if t == eKt env then k' else t) (eModels env)
                         , eKt = k', eAbsent = Just kexpr }
          pure ([SBindPat (PTup [PVar rv, PVar k']) call], SVar rv, env')
    twinCall f args = do
      let dirty = [i | (i, a) <- zip [0 :: Int ..] args, not (cleanE mode env a)]
      i <- case dirty of [i] -> pure i; _ -> failC
      let arg = args !! i
      modify (\st -> st { sNeed = sNeed st ++ [(f, i)], sCalls = (sOwner st, f) : sCalls st })
      let call m k = foldl SApp (SVar (twinName suffix f)) (case mode of
            Rec _ -> [if j == i then m else a | (j, a) <- zip [0 :: Int ..] args] ++ [SVar k]
            Lst -> [if j == i then SVar k else a | (j, a) <- zip [0 :: Int ..] args])
      case unmark arg of
        SVar v | isModel env v -> pure (call (SVar v) (eKt env))
        _ -> do
          -- the model argument is evaluated first: the ones before it must not notice
          unless (all (effectFree prog (eBound env)) (take i args) || effectFree prog (eBound env) arg) failC
          arg' <- prod prog mode suffix env arg
          mv <- fresh "m"
          k' <- fresh "t"
          pure $ case mode of
            Rec _ -> SBlock [SBindPat (PTup [PVar mv, PVar k']) arg'] (call (SVar mv) k')
            Lst -> SBlock [SBind k' [] arg'] (call (SVar mv) k')
    setKey k = do
      st <- get
      case sKey st of
        Nothing -> put st {sKey = Just k}
        Just k0 | k0 == k -> pure ()
        _ -> failC
    -- a write to the list, as an expression of the new table
    tableWrite :: Prog -> Mode -> Env -> SExpr -> C SExpr
    tableWrite pr md en val = case spineP val of
      -- put: y :: L, where the last find said y's key is absent
      _ | SBin "::" y l <- unmark val, isTable md en l, Just ka <- eAbsent en, cleanE md en y -> do
            k <- gets sKey >>= maybe failC pure
            yv <- fresh "y"
            let keyOk = case unmark y of
                  SVar v -> exprEq (SProj (SVar v) [k]) ka
                  SRec fs -> maybe False (`exprEq` ka) (lookup k fs)
                  _ -> False
            unless keyOk failC
            bump
            pure (SBlock [SBind yv [] y]
                    (foldl SApp (SVar (keyedListAlias ++ ".insertNew")) [SProj (SVar yv) [k], SVar yv, SVar (eKt en)]))
      (SVar h, [fn, l]) | isTable md en l, h `elem` listOps pr "map" -> do
        (x, k, kexpr, new) <- replaceFn pr en fn
        setKey k
        unless (keyKept en x k kexpr new) failC
        unless (cleanE md en new) failC
        bump
        pure (keyCall pr en "update" kexpr [SLam [x] new, SVar (eKt en)])
      (SVar h, [fn, l]) | isTable md en l, h `elem` listOps pr "filter" -> do
        (k, kexpr) <- predicate pr en False fn
        setKey k
        bump
        pure (keyCall pr en "remove" kexpr [SVar (eKt en)])
      _ -> failC
    bump = modify (\st -> st {sChanges = sChanges st + 1})

isNone :: SPat -> Bool
isNone p = case p of
  PCon c [] -> c == "None" || ".None" `isSuffixOf` c
  _ -> False

listOps :: Prog -> String -> [Name]
listOps prog op = [a ++ "." ++ op | a <- pLists prog]

-- KL.op key args, or KL.opLazy (fn _ -> key) args when the key is not a
-- plain variable or field read (the list form evaluates it only for a
-- non-empty list)
keyCall :: Prog -> Env -> String -> SExpr -> [SExpr] -> SExpr
keyCall _ _ op kexpr rest
  | trivial kexpr = foldl SApp (SVar (keyedListAlias ++ "." ++ op)) (kexpr : rest)
  | otherwise = foldl SApp (SVar (keyedListAlias ++ "." ++ op ++ "Lazy")) (SLam ["kl__u"] kexpr : rest)

trivial :: SExpr -> Bool
trivial e = case unmark e of
  SVar _ -> True
  SInt _ -> True
  SProj a _ -> trivial a
  SStrI [SegStr _] -> True
  SStrI [] -> True
  _ -> False

-- List.find (fn x -> x.K == e) L, directly or through a root helper
findOp :: Prog -> Mode -> Env -> SExpr -> C (Name, SExpr)
findOp prog mode env s = case spineP s of
  (SVar h, [p, l]) | h `elem` listOps prog "find", isTable mode env l -> predicate prog env True p
  (SVar h, args) | S.notMember h (eBound env), Just [(ps, [], body)] <- M.lookup h (pClauses prog),
                   length ps == length args, Just names <- mapM pvar ps -> do
    -- inline: the helper's body is a find on one of its parameters
    (hp, p, lp) <- case spineP (unmark body) of
      (SVar hv, [pe, SVar lv]) -> pure (hv, pe, lv)
      _ -> failC
    unless (hp `elem` listOps prog "find") failC
    j <- maybe failC pure (lookup lp (zip names [0 :: Int ..]))
    unless (isTable mode env (args !! j)) failC
    let sub = M.fromList [(nm, a) | (nm, a, i) <- zip3 names args [0 :: Int ..], i /= j]
    unless (all (cleanE mode env) (M.elems sub)) failC
    p' <- maybe failC pure (substitute sub p)
    predicate prog env True p'
  _ -> failC
  where pvar = \case PVar v -> Just v; _ -> Nothing

-- (fn x -> x.K == e) for a find (eq = True) or (fn x -> x.K != e) for a filter
predicate :: Prog -> Env -> Bool -> SExpr -> C (Name, SExpr)
predicate prog env eq p = case unmark p of
  SLam [x] b -> do
    (k, e) <- maybe failC pure (if eq then keyEq prog env x b else keyNe prog env x b)
    unless (effectFree prog (S.insert x (eBound env)) e) failC
    pure (k, e)
  _ -> failC

keyEq, keyNe :: Prog -> Env -> Name -> SExpr -> Maybe (Name, SExpr)
keyEq prog env x b = case unmark b of
  SBin "==" l r -> sides l r
  b' | (SVar g, [l, r]) <- spineP b', S.notMember g (eBound env), helperOp prog g == Just "==" -> sides l r
  _ -> Nothing
  where
    sides l r = case (unmark l, unmark r) of
      (SProj (SVar v) [k], e) | v == x, not (mentions x e) -> Just (k, e)
      (e, SProj (SVar v) [k]) | v == x, not (mentions x e) -> Just (k, e)
      _ -> Nothing
keyNe prog env x b = case unmark b of
  SBin "!=" l r -> keyEq prog env x (SBin "==" l r)
  b' | (SVar g, [l, r]) <- spineP b', S.notMember g (eBound env), helperOp prog g == Just "!=" -> keyEq prog env x (SBin "==" l r)
     | (SVar "not", [a]) <- spineP b', S.notMember "not" (eBound env), M.notMember "not" (pClauses prog) -> keyEq prog env x a
  _ -> Nothing

-- a root function `g a b = a == b` (or !=)
helperOp :: Prog -> Name -> Maybe Name
helperOp prog g = case M.lookup g (pClauses prog) of
  Just [([PVar a, PVar b], [], body)] | SBin op l r <- unmark body, op `elem` ["==", "!="],
                                       (isVar a l && isVar b r) || (isVar b l && isVar a r) -> Just op
  _ -> Nothing

-- the map function of a replace: (x, K, e, NEW)
replaceFn :: Prog -> Env -> SExpr -> C (Name, Name, SExpr, SExpr)
replaceFn prog env fn = case unmark fn of
  SLam [x] body -> case unmark body of
    SCase c arms | Just new <- ifKey x arms, Just (k, e) <- keyEq prog env x c -> done x k e new
    b | (SVar h, SVar x' : rest) <- spineP b, x' == x, S.notMember h (eBound env),
        Just [(PVar px : ps1, [GBool g], new1), (PVar py : ps2, [], idb)] <- M.lookup h (pClauses prog),
        length ps1 == length rest, length ps2 == length rest, isVar py idb,
        Just n1 <- mapM pv ps1 -> do
          unless (all trivial rest) failC
          let sub = M.fromList ((px, SVar x) : zip n1 rest)
          g' <- maybe failC pure (substitute sub g)
          new' <- maybe failC pure (substitute sub new1)
          (k, e) <- maybe failC pure (keyEq prog env x g')
          done x k e new'
    _ -> failC
  _ -> failC
  where
    pv = \case PVar v -> Just v; PWild -> Just "_"; _ -> Nothing
    done x k e new = do
      unless (effectFree prog (S.insert x (eBound env)) e) failC
      pure (x, k, e, new)
    ifKey x arms = case [(p, unmark b) | (p, b) <- arms] of
      [(PCon "True" [], _), (PCon "False" [], b)] | isVar x b -> lookup' "True" arms
      [(PCon "False" [], b), (PCon "True" [], _)] | isVar x b -> lookup' "True" arms
      _ -> Nothing
    lookup' c arms = case [b | (PCon c' [], b) <- arms, c' == c] of
      b : _ -> Just b
      [] -> Nothing

-- NEW keeps the key: { x | .. } (x.K == e there), or a record whose K is e
keyKept :: Env -> Name -> Name -> SExpr -> SExpr -> Bool
keyKept env x k e new = go (8 :: Int) new
  where
    go 0 _ = False
    go n v = case unmark v of
      SUpd (SVar y) fs | all (\(p, _) -> take 1 p /= [k]) fs ->
        y == x || exprEq (SProj (SVar y) [k]) e || (y /= x && maybe False (go (n - 1)) (M.lookup y (eLocals env)))
      SRec fs -> maybe False (`exprEq` e) (lookup k fs)
      SVar y | y /= x, Just rhs <- M.lookup y (eLocals env) -> go (n - 1) rhs
      _ -> False

-- ---- effects ---------------------------------------------------------------

-- no Sys/print/error/HAL call, no call of an unknown closure: evaluating it
-- once, or once per element, cannot be told apart
effectFree :: Prog -> S.Set Name -> SExpr -> Bool
effectFree prog bound0 e0 = go S.empty bound0 e0
  where
    go seen bound e = case e of
      SMark _ a -> go seen bound a
      SVar v | S.member v bound -> True
             | otherwise -> headOk seen bound (SVar v)
      SInt _ -> True
      SStrI segs -> and [go seen bound g | SegExpr g <- segs]
      SLam ps b -> go seen (bound `S.union` S.fromList ps) b
      SBlock ss r -> let (ok, bd) = foldl (\(o, b) s -> case s of
                                              SBind v ps rhs -> (o && go seen (b `S.union` S.fromList (v : ps)) rhs, S.insert v b)
                                              SBindPat p rhs -> (o && go seen b rhs, b `S.union` S.fromList (patVars p)))
                                          (True, bound) ss
                     in ok && go seen bd r
      SCase s arms -> go seen bound s && and [go seen (bound `S.union` S.fromList (patVars p)) b | (p, b) <- arms]
      SBin "|>" a f -> go seen bound (SApp f a)
      SBin _ a b -> go seen bound a && go seen bound b
      SProj a _ -> go seen bound a
      SRec fs -> all (go seen bound . snd) fs
      SUpd a fs -> go seen bound a && all (go seen bound . snd) fs
      STup es -> all (go seen bound) es
      SList es -> all (go seen bound) es
      SApp _ _ -> let (h, args) = spineP e in all (go seen bound) args && headOk seen bound h
    headOk seen bound h = case unmark h of
      SVar f
        | S.member f bound -> False
        | isCon f -> True
        | Just cls <- M.lookup f (pClauses prog) ->
            S.member f seen || and [ all (guardOk (S.insert f seen) (S.fromList (concatMap patVars ps))) gs
                                     && go (S.insert f seen) (S.fromList (concatMap patVars ps ++ concat [patVars p | GPat p _ <- gs])) b
                                   | (ps, gs, b) <- cls ]
        | (a, '.' : _) <- break (== '.') f, S.member a (pPure prog) -> True
        | f `elem` ["not", "strlen", "min", "max", "abs"] -> True
        | otherwise -> False
      SLam ps b -> go seen (bound `S.union` S.fromList ps) b
      _ -> False
    guardOk seen bd g = case g of
      GBool x -> go seen bd x
      GPat _ x -> go seen bd x
    isCon f = case reverse (takeWhile (/= '.') (reverse f)) of
      c : _ -> c >= 'A' && c <= 'Z'
      [] -> False

-- ---- helpers ---------------------------------------------------------------

-- application spine, `a |> f` read as `f a`
spineP :: SExpr -> (SExpr, [SExpr])
spineP = go []
  where go acc x = case x of
          SApp f a -> go (a : acc) f
          SBin "|>" a f -> go (a : acc) f
          SMark _ a -> go acc a
          _ -> (x, acc)

isVar :: Name -> SExpr -> Bool
isVar m e = case unmark e of SVar v -> v == m; _ -> False

unmark :: SExpr -> SExpr
unmark (SMark _ a) = unmark a
unmark e = e

exprEq :: SExpr -> SExpr -> Bool
exprEq a b = strip a `eqE` strip b
  where
    eqE x y = show x == show y
    strip x = case x of
      SMark _ i -> strip i
      SApp f g -> SApp (strip f) (strip g)
      SProj i fs -> SProj (strip i) fs
      SBin o l r -> SBin o (strip l) (strip r)
      STup es -> STup (map strip es)
      _ -> x

mentions :: Name -> SExpr -> Bool
mentions m e = or [v == m | SVar v <- universe e]

-- replace free variables (no lambda, block or case in the target binds any
-- of the names substituted or mentioned: refused otherwise)
substitute :: M.Map Name SExpr -> SExpr -> Maybe SExpr
substitute sub e0 = if clash then Nothing else Just (go e0)
  where
    names = M.keysSet sub `S.union` S.fromList [v | a <- M.elems sub, SVar v <- universe a]
    clash = or [any (`S.member` names) bs | x <- universe e0, bs <- [binders x]]
    binders x = case x of
      SLam ps _ -> ps
      SBlock ss _ -> concat [v : ps | SBind v ps _ <- ss] ++ concat [patVars p | SBindPat p _ <- ss]
      SCase _ arms -> concatMap (patVars . fst) arms
      _ -> []
    go x = case x of
      SVar v | Just a <- M.lookup v sub -> a
      SMark o a -> SMark o (go a)
      SApp a b -> SApp (go a) (go b)
      SLam ps b -> SLam ps (go b)
      SBlock ss r -> SBlock (map st ss) (go r)
      SCase s arms -> SCase (go s) [(p, go b) | (p, b) <- arms]
      SBin o a b -> SBin o (go a) (go b)
      SProj a fs -> SProj (go a) fs
      SRec fs -> SRec [(f, go v) | (f, v) <- fs]
      SUpd a fs -> SUpd (go a) [(p, go v) | (p, v) <- fs]
      STup es -> STup (map go es)
      SList es -> SList (map go es)
      SStrI segs -> SStrI [case g of SegExpr y -> SegExpr (go y); o -> o | g <- segs]
      _ -> x
    st s = case s of
      SBind v ps rhs -> SBind v ps (go rhs)
      SBindPat p rhs -> SBindPat p (go rhs)

universe :: SExpr -> [SExpr]
universe e = e : concatMap universe (children e)
  where
    children x = case x of
      SMark _ a -> [a]
      SApp a b -> [a, b]
      SLam _ b -> [b]
      SBlock ss r -> [rhs | SBind _ _ rhs <- ss] ++ [rhs | SBindPat _ rhs <- ss] ++ [r]
      SCase s arms -> s : map snd arms
      SBin _ a b -> [a, b]
      SProj a _ -> [a]
      SRec fs -> map snd fs
      SUpd a fs -> a : map snd fs
      STup es -> es
      SList es -> es
      SStrI segs -> [g | SegExpr g <- segs]
      _ -> []

patVars :: SPat -> [Name]
patVars p = case p of
  PVar n -> [n]
  PCon _ ps -> concatMap patVars ps
  PTup ps -> concatMap patVars ps
  PRec ns -> ns
  PSig n _ -> [n]
  _ -> []

modulePath :: String -> String
modulePath p0 =
  let p1 = takeWhile (/= '#') p0
      p2 = if ".fpr" `isSuffixOf` p1 then take (length p1 - 4) p1 else p1
      segs = splitPath p2
  in case reverse segs of
       base : "std" : _ -> "std/" ++ base
       _ -> p2
  where
    splitPath s = case break (== '/') s of
      (a, []) -> [a]
      (a, _ : rest) -> a : splitPath rest
