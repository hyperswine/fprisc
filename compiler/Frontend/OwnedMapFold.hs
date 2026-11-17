-- Owned map folds: an ordered Map built by a fold is built in a hash table.
--
--   counts = List.fold (fn m w -> Map.update w bump m) Map.strings ws
--
-- builds a persistent AVL tree one path copy (or, owned, one in-place walk)
-- per element, comparing string keys at every level.  Nothing but the fold
-- holds the map while it is built, so the same entries can be collected in
-- std/mutmap's linear hash table and turned into the ordered Map once, at the
-- end:
--
--   counts = MutMap.freeze Order.string
--              (List.fold (fn m w -> MutMap.update w bump m) (MutMap.strings Unit) ws)
--
-- (docs/2026-11-18-OWNED-MAP-FOLDS.md).  The rewrite is on the root's surface
-- tree, before modules are loaded, and the program it produces is type and
-- linearity checked like any other: MutMap is linear, so a step that let the
-- map escape would not check.  The syntactic conditions below are what make
-- that never happen:
--
--   * the fold is List.fold, String.foldLines or String.foldWords, its start
--     Map.strings or Map.ints (std/map; the keys MutMap hashes);
--   * the step is a two-parameter lambda, or a top-level function of one
--     clause with a signature `Map.Map k v -> a -> Map.Map k v`;
--   * in the step's body the map is only threaded: on every path it is either
--     the result itself or the last argument of a fully applied Map.update,
--     insert, insertWith, remove or alter whose other arguments do not
--     mention it; case scrutinees and block statements do not mention it.
--
-- What changes is not observable through Map's contract: the entries are the
-- same, and every traversal is in key order.  The TREE's shape differs (a
-- balanced build instead of the insertion order's), which std/map already
-- says `==` sees and `Map.equal` does not.  FPR_NO_OWNED_MAP_FOLD=1 turns
-- the rewrite off.
module Frontend.OwnedMapFold (ownedMapFolds, mutMapAlias, orderAlias) where

import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (isSuffixOf, stripPrefix)
import Data.Maybe (mapMaybe)
import Frontend.Syntax
import Core.Syntax (Name)

mutMapAlias, orderAlias :: Name
mutMapAlias = "FprOwnedMapFoldMutMap"
orderAlias = "FprOwnedMapFoldOrder"

-- the rewritten program and the number of folds rewritten
ownedMapFolds :: [STop] -> ([STop], Int)
ownedMapFolds tops
  | null mapAliases = (tops, 0)
  | count == 0 = (tops, 0)
  | otherwise = (uses ++ rewritten ++ twins, count)
  where
    aliases = [(a, modulePath p) | TUse a p <- tops]
    aliasOf path = [a | (a, p) <- aliases, p == path]
    mapAliases = aliasOf "std/map"
    -- List.fold is std/list's, or the prelude's when nothing is named List
    listAliases = aliasOf "std/list" ++ ["List" | "List" `notElem` map fst aliases]
    stringAliases = aliasOf "std/string"
    folds = S.fromList ([l ++ ".fold" | l <- listAliases] ++
                        [s ++ f | s <- stringAliases, f <- [".foldLines", ".foldWords"]])
    topNames = S.fromList [n | TBind n _ _ _ <- tops]
    sigs = M.fromList [(n, t) | TSig n t _ <- tops]
    sigPres = M.fromList [(n, p) | TSig n _ p <- tops]
    clauses = M.fromListWith (++) [(n, [(ps, gs, b)]) | TBind n ps gs b <- tops]

    -- top-level steps that qualify, with the map alias their signature names
    namedSteps = M.fromList (mapMaybe namedStep (M.toList clauses))
    namedStep (n, [([PVar m, PVar x], [], body)])
      | m /= x, Just ([TCon pt [k, v], _], TCon rt [k', v']) <- M.lookup n sigs,
        Just ma <- mapTypeAlias pt, mapTypeAlias rt == Just ma, show k == show k', show v == show v',
        threaded m body = Just (n, (m, x, body, k, v))
    namedStep _ = Nothing
    mapTypeAlias t = case [a | a <- mapAliases, t == a ++ ".Map"] of
      a : _ -> Just a
      [] -> Nothing

    -- the program's binds, folds rewritten; the steps they used
    (rewritten, used) = foldr visitTop ([], S.empty) tops
    count = length [() | t <- rewritten, n <- [rewrites t], _ <- [1 .. n]]
    rewrites t = case t of
      TBind _ _ _ b -> foldsIn b
      _ -> 0
    foldsIn e = length [() | SVar v <- universe e, v == mutMapAlias ++ ".freeze"]
    visitTop t (acc, us) = case t of
      TBind n ps gs b ->
        let bound = S.fromList (concatMap patVars ps)
            (b', us1) = expr bound b
        in (TBind n ps gs b' : acc, us `S.union` us1)
      _ -> (t : acc, us)

    -- rewrite every qualifying fold in an expression (bound: names a local
    -- binding may have shadowed, so a step named by them is not the top-level one)
    expr :: S.Set Name -> SExpr -> (SExpr, S.Set Name)
    expr bound e = case e of
      _ | Just (f, step, start, xs) <- foldCall e, Just (rebuilt, us) <- owned bound f step start ->
            let (xs', us') = expr bound xs in (rebuilt xs', us `S.union` us')
      SMark o a -> let (a', u) = expr bound a in (SMark o a', u)
      SApp a b -> let (a', u1) = expr bound a; (b', u2) = expr bound b in (SApp a' b', S.union u1 u2)
      SLam ps b -> let (b', u) = expr (bound `S.union` S.fromList ps) b in (SLam ps b', u)
      SBlock ss r ->
        let go bd [] = let (r', u) = expr bd r in ([], r', u)
            go bd (st : rest) = case st of
              SBind n ps rhs ->
                let bd' = S.insert n bd
                    (rhs', u1) = expr (if null ps then bd else bd' `S.union` S.fromList ps) rhs
                    (rest', r', u2) = go bd' rest
                in (SBind n ps rhs' : rest', r', S.union u1 u2)
              SBindPat p rhs ->
                let (rhs', u1) = expr bd rhs
                    (rest', r', u2) = go (bd `S.union` S.fromList (patVars p)) rest
                in (SBindPat p rhs' : rest', r', S.union u1 u2)
            (ss', r'', u) = go bound ss
        in (SBlock ss' r'', u)
      SCase s arms ->
        let (s', u0) = expr bound s
            arms' = [(p, expr (bound `S.union` S.fromList (patVars p)) b) | (p, b) <- arms]
        in (SCase s' [(p, b) | (p, (b, _)) <- arms'], S.unions (u0 : map (snd . snd) arms'))
      SBin o a b -> let (a', u1) = expr bound a; (b', u2) = expr bound b in (SBin o a' b', S.union u1 u2)
      SProj a fs -> let (a', u) = expr bound a in (SProj a' fs, u)
      SRec fs -> let rs = [(n, expr bound v) | (n, v) <- fs] in (SRec [(n, v) | (n, (v, _)) <- rs], S.unions (map (snd . snd) rs))
      SUpd a fs -> let (a', u) = expr bound a; rs = [(p, expr bound v) | (p, v) <- fs]
                   in (SUpd a' [(p, v) | (p, (v, _)) <- rs], S.unions (u : map (snd . snd) rs))
      STup es -> let rs = map (expr bound) es in (STup (map fst rs), S.unions (map snd rs))
      SList es -> let rs = map (expr bound) es in (SList (map fst rs), S.unions (map snd rs))
      SStrI segs -> let rs = [case g of SegExpr x -> let (x', u) = expr bound x in (SegExpr x', u); _ -> (g, S.empty) | g <- segs]
                    in (SStrI (map fst rs), S.unions (map snd rs))
      _ -> (e, S.empty)

    foldCall e = case unmark e of
      SApp (SApp (SApp f step) start) xs | SVar fn <- unmark f, S.member fn folds -> Just (fn, step, start, xs)
      _ -> Nothing

    owned bound f step start = do
      SVar s0 <- Just (unmark start)
      (ma, kind) <- case [(a, k) | a <- mapAliases, k <- ["strings", "ints"], s0 == a ++ "." ++ k] of
        r : _ -> Just r
        [] -> Nothing
      (step', us) <- case unmark step of
        SLam [m, x] body | m /= x, threadedBy ma m body -> Just (SLam [m, x] (convert ma m body), S.empty)
        SVar n | S.notMember n bound, S.member n topNames, Just (m, _, body, _, _) <- M.lookup n namedSteps,
                 threadedBy ma m body -> Just (SVar (twinName n), S.singleton n)
        _ -> Nothing
      let cmp = SVar (orderAlias ++ (if kind == "strings" then ".string" else ".int"))
          empty = SApp (SVar (mutMapAlias ++ "." ++ kind)) (SVar "Unit")
      pure (\xs' -> SApp (SApp (SVar (mutMapAlias ++ ".freeze")) cmp)
                         (SApp (SApp (SApp (SVar f) step') empty) xs'), us)

    -- the steps a rewritten fold calls, retyped to the MutMap
    twins = concat [twin n | n <- S.toList used]
    twin n = case M.lookup n namedSteps of
      Just (m, x, body, k, v) | Just ([TCon pt _, a], _) <- M.lookup n sigs, Just ma <- mapTypeAlias pt ->
        let mt = TCon "MutMap" [k, v]
        in [TSig (twinName n) ([mt, a], mt) (M.findWithDefault [Nothing, Nothing] n sigPres),
            TBind (twinName n) [PVar m, PVar x] [] (convert ma m body)]
      _ -> []
    twinName n = n ++ "__ownedmap"

    uses = [TUse mutMapAlias "std/mutmap", TUse orderAlias "std/order"]

    threaded m body = or [threadedBy a m body | a <- mapAliases]

-- the map m is only threaded through the body (see the header)
threadedBy :: Name -> Name -> SExpr -> Bool
threadedBy ma m e = case unmark e of
  SVar v | v == m -> True
  e' | Just (_, args) <- mapOp ma e', isVar m (last args) ->
         not (any (mentions m) (init args))
  SCase s arms -> not (mentions m s) && and [m `notElem` patVars p && threadedBy ma m b | (p, b) <- arms]
  SBlock ss r -> not (any (stmtMentions m) ss) && m `notElem` concatMap stmtBinds ss && threadedBy ma m r
  _ -> False

-- Map.op applied to all its arguments
mapOp :: Name -> SExpr -> Maybe (Name, [SExpr])
mapOp ma e = case spine e of
  (SVar f, args) | Just op <- stripPrefix (ma ++ ".") f, Just n <- lookup op arities, length args == n -> Just (op, args)
  _ -> Nothing
  where arities = [("update", 3), ("insert", 3), ("insertWith", 4), ("remove", 2), ("alter", 3)]

convert :: Name -> Name -> SExpr -> SExpr
convert ma m e = case e of
  SMark o a -> SMark o (convert ma m a)
  _ | Just (op, args) <- mapOp ma e -> foldl SApp (SVar (mutMapAlias ++ "." ++ op)) args
  SCase s arms -> SCase s [(p, convert ma m b) | (p, b) <- arms]
  SBlock ss r -> SBlock ss (convert ma m r)
  _ -> e

spine :: SExpr -> (SExpr, [SExpr])
spine = go []
  where go acc x = case x of
          SApp f a -> go (a : acc) f
          SMark _ a -> go acc a
          _ -> (x, acc)

isVar :: Name -> SExpr -> Bool
isVar m e = case unmark e of SVar v -> v == m; _ -> False

unmark :: SExpr -> SExpr
unmark (SMark _ a) = unmark a
unmark e = e

-- every name occurrence, syntactically (shadowing is ignored: conservative)
mentions :: Name -> SExpr -> Bool
mentions m e = or [v == m | SVar v <- universe e] ||
               or [v == m | SProj (SVar v) _ <- universe e]

stmtMentions :: Name -> SStmt -> Bool
stmtMentions m s = case s of
  SBind _ _ rhs -> mentions m rhs
  SBindPat _ rhs -> mentions m rhs

stmtBinds :: SStmt -> [Name]
stmtBinds s = case s of
  SBind n ps _ -> n : ps
  SBindPat p _ -> patVars p

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

-- a module path as written, without a pin or extension: "std/map#ab12" and
-- "../std/map.fpr" are both "std/map"
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
