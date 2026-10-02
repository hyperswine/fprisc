{-# LANGUAGE LambdaCase #-}
-- Safety.hs — the safe/unsafe line, drawn and ENFORCED.
--
-- The division (see docs/2026-08-25-SAFETY.md):
--
--   UNSAFE code is code whose WCET the compiler cannot see through:
--     * implicit recursion — a custom recursive function (self or
--       mutual), as opposed to the builtin/std recursion SCHEMES
--       (Vec.map/fold, Std.fold, ...) whose bounds are the scheme's
--     * and, transitively, code that leans on such functions OUTSIDE
--       the vetted library
--
--   The RULES:
--     1. every function in a recursive SCC MUST carry an explicit
--        signature of the form   f : unsafe T1 -> T2 .
--        No inference hides recursion.  Missing marker = compile error.
--     2. calling a MARKED-unsafe function from an unmarked function is
--        itself unsafe and requires a marker — UNLESS the callee is
--        LIBRARY code (the prelude or explicitly allow-listed modules).
--        The library is the vetted set: its recursive
--        internals are marked (rule 1 applies to it too — honesty),
--        but USING it is the sanctioned way to recurse, so the taint
--        stops at the library boundary.  "Core functions rather than
--        std functions" is exactly the taint this rule tracks.
--     3. safe functions need no signature and are preferred bare.
--        A function marked unsafe that the analysis finds safe gets a
--        note, not an error.
--
-- FPR_UNSAFE_SUGGEST=1 prints paste-ready signatures (with the
-- INFERRED types) for every violation, so adopting the discipline is
-- mechanical rather than archaeological.
module Safety (safetyCheck, trustedLibraryPaths, Measure (..), MeasureKind (..), measureCheck) where

import Data.Char (isHexDigit)
import System.Directory (canonicalizePath)
import System.FilePath (takeDirectory, (</>))
import Home (underHome)
import Data.Maybe (catMaybes)
import Data.Graph (SCC (..), stronglyConnComp)
import Data.List (intercalate, nub, isInfixOf, isPrefixOf, isSuffixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import FPRISC
import Precond (reservedEntry, splitMeasure)


-- Explicit transitional trust policy for shipped library schemes and QOS
-- service plumbing. Qualification alone conveys no trust. These are source
-- allow-list entries, not proof certificates; local toolchain configuration
-- controls their resolution. New library files require an explicit entry.
trustedLibraryPaths :: IO (S.Set FilePath)
trustedLibraryPaths = do
  shipped <- catMaybes <$> mapM underHome approvedLibraries
  -- The platform owns its own explicit allow-list, just as it owns the
  -- foreign primitive declarations. Entries are relative to this file.
  manifest <- underHome "core/trusted-modules.txt"
  platform <- case manifest of
    Nothing -> pure []
    Just p -> do
      entries <- lines <$> readFile p
      pure [takeDirectory p </> line | line <- entries, c : _ <- [line], c /= '#']
  S.fromList <$> mapM canonicalizePath (shipped ++ platform)

approvedLibraries :: [FilePath]
approvedLibraries =
  [ "sol/lib/auth.sol",
    "sol/lib/base.sol",
    "sol/lib/csv.sol",
    "sol/lib/fix.sol",
    "sol/lib/git.sol",
    "sol/lib/json.sol",
    "sol/lib/logic.sol",
    "sol/lib/matrix.sol",
    "sol/lib/plot.sol",
    "sol/lib/plparse.sol",
    "sol/lib/proc.sol",
    "sol/lib/rand.sol",
    "sol/lib/ui.sol",
    "sol/lib/web.sol",
    "std/actor.fpr",
    "std/binary.fpr",
    "std/ble.fpr",
    "std/clock.fpr",
    "std/config.fpr",
    "std/decode.fpr",
    "std/digest.fpr",
    "std/dir.fpr",
    "std/encoding.fpr",
    "std/esp.fpr",
    "std/file.fpr",
    "std/gpio.fpr",
    "std/http.fpr",
    "std/httpcore.fpr",
    "std/job.fpr",
    "std/json.fpr",
    "std/kvlog.fpr",
    "std/lens.fpr",
    "std/list.fpr",
    "std/live.fpr",
    "std/livejs.fpr",
    "std/log.fpr",
    "std/ma.fpr",
    "std/map.fpr",
    "std/math.fpr",
    "std/mvu.fpr",
    "std/option.fpr",
    "std/order.fpr",
    "std/os.fpr",
    "std/osfs.fpr",
    "std/osio.fpr",
    "std/osnet.fpr",
    "std/oswatch.fpr",
    "std/path.fpr",
    "std/poller.fpr",
    "std/proc.fpr",
    "std/program.fpr",
    "std/result.fpr",
    "std/set.fpr",
    "std/std.fpr",
    "std/std.sol",
    "std/store.fpr",
    "std/stream.fpr",
    "std/string.fpr",
    "std/task.fpr",
    "std/tcp.fpr",
    "std/term.fpr",
    "std/view.fpr",
    "std/viewcache.fpr",
    "std/wifi.fpr",
    "std/ws.fpr"
  ]

safetyCheck :: S.Set Name -> [STop] -> [(Name, String)] -> ([String], [String])
safetyCheck preludeNames tops notes = (errs, suggests)
  where
    cg = callGraphOf tops
    bindNames = cgBinds cg
    topSet = S.fromList bindNames
    callsOf = cgCalls cg
    sccs = cgSccs cg
    markedSigs =
      S.fromList
        [ n
          | TSig n _ pres <- tops,
            any (\p -> (fst <$> p) == Just "$unsafe") pres
        ]
    -- `unsafe program.` / `unsafe module.`: the blanket marker (parsed
    -- as a $module sig).  Every bind counts as marked, and the
    -- redundant-marker nag below is silenced -- blanket IS the loose
    -- mode.  Per-function sigs remain the strict mode for library code.
    blanket = S.member "$module" markedSigs
    -- Imported blanket declarations apply to their module, never the caller.
    scopedMarkers = [n | n <- S.toList markedSigs, "$module@" `isPrefixOf` n || ".$module" `isSuffixOf` n]
    moduleUnsafe n = any (owns n) scopedMarkers
    owns n marker
      | "$module@" `isPrefixOf` marker = drop (length "$module") marker `isInfixOf` n
      | otherwise = take (length marker - length "$module") marker `isPrefixOf` n
    marked = if blanket then S.union markedSigs topSet
             else markedSigs <> S.fromList [n | n <- bindNames, moduleUnsafe n]
    blessed n = S.member n preludeNames
    recursive0 =
      S.fromList
        (concat [ns | CyclicSCC ns <- sccs]
           ++ [n | AcyclicSCC n <- sccs, n `elem` callsOf n])
    -- declared termination measures: verified by measureCheckCG below,
    -- shared with the std proof pass (StdBridge) so both see ONE language
    (measTable, mErrs) = measureCheckCG cg tops
    proven = M.keysSet measTable
    recursive = recursive0 `S.difference` proven
    -- rule 2: taint from marked, non-library callees
    importedTaint n = any (\g -> S.member g marked && not (blessed g) && ('.' `elem` g || '@' `elem` g)) (callsOf n)
    taints n = any (\g -> S.member g marked && not (blessed g)) (callsOf n)
    -- main retains the local-entry policy, but imported unsafe assumptions
    -- must be explicit there too. Only the supplied allow-list stops taint.
    required =
      S.union
        (S.filter (not . blessed) recursive)
        (S.fromList [n | n <- bindNames, (n /= "main" || importedTaint n), not (blessed n), taints n])
    violated = [n | n <- bindNames, S.member n required, not (S.member n marked)]
    why n
      | S.member n recursive = "recursive"
      | otherwise = "calls an unsafe-marked function"
    errs =
      mErrs
        ++ [ n ++ " is unsafe (" ++ why n ++ ") but has no explicit `" ++ n ++ " : unsafe ...` signature"
             | n <- violated
           ]
        ++ [ n ++ " is declared unsafe but the analysis finds it safe -- drop the marker (or keep it only if the WCET is opaque for another reason)"
             | not blanket,
               n <- S.toList marked,
               not (S.member n required),
               S.member n topSet,
               not (blessed n),
               not (moduleUnsafe n)
           ]
    tyOf n = unhash (holed (maybe "_" id (M.lookup n (M.fromList notes))))
    -- the suggestion must be SOURCE: the inferred type names this module's
    -- own types by their hash-qualified compile names (Caps@81bf...), which
    -- the signature grammar does not read.  Pasting one used to be
    -- silently dropped (qos's svc.fpr accumulated nine stale copies per
    -- function); now it would be a parse error.  Print the bare name.
    unhash [] = []
    unhash ('@' : rest) | (h, rest') <- span isHexDigit rest, length h == 16 = unhash rest'
    unhash (c : rest) = c : unhash rest
    -- rows aren't writable in the sig grammar: print '_' (the mono
    -- hole) for any {...} segment, balanced-brace aware
    holed [] = []
    holed ('{' : rest) = '_' : holed (dropBraces (1 :: Int) rest)
    holed (c : rest) = c : holed rest
    dropBraces 0 s' = s'
    dropBraces k ('{' : s') = dropBraces (k + 1) s'
    dropBraces k ('}' : s') = dropBraces (k - 1) s'
    dropBraces k (_ : s') = dropBraces k s'
    dropBraces _ [] = []
    suggests = [n ++ " : unsafe " ++ tyOf n ++ " ." | n <- violated]

--------------------------------------------------------------------------------
-- the call graph: shared by the safe/unsafe line and the measure checker
--------------------------------------------------------------------------------

data CallGraph = CallGraph
  { cgBinds :: [Name],
    cgClauses :: Name -> [([SPat], [SGuard], SExpr)],
    cgCalls :: Name -> [Name],
    cgSccs :: [SCC Name]
  }

callGraphOf :: [STop] -> CallGraph
callGraphOf tops = CallGraph bindNames clausesOf callsOf sccs
  where
    bindNames = nub [n | TBind n _ _ _ <- tops]
    topSet = S.fromList bindNames
    clausesOf n = [(ps, g, b) | TBind n' ps g b <- tops, n' == n]
    refs (ps, g, b) =
      let bound = S.fromList (concatMap patVars ps)
          gbound = S.union bound (S.fromList (concatMap gPatVars g))
          gPatVars (GPat p _) = patVars p
          gPatVars (GBool _) = []
          gExprs = [e | gd <- g, e <- case gd of GBool e' -> [e']; GPat _ e' -> [e']]
       in topRefs2 gbound b ++ concatMap (topRefs2 bound) gExprs
    callsOf n = nub (concatMap refs (clausesOf n))
    -- free applied top-level names (same recipe as Infer's SCC pass)
    topRefs2 bound e = [n | n <- coll bound e, S.member n topSet]
      where
        coll bs = \case
          SMark _ x -> coll bs x
          SVar v | not (S.member v bs) -> [v]
          SApp a b -> coll bs a ++ coll bs b
          SLam ps x -> coll (bs <> S.fromList ps) x
          SBlock stmts fin -> gos bs stmts fin
          SCase s as -> coll bs s ++ concat [coll (bs <> S.fromList (patVars p)) x | (p, x) <- as]
          SBin _ a b -> coll bs a ++ coll bs b
          SProj x _ -> coll bs x
          SRec fs -> concatMap (coll bs . snd) fs
          SUpd m as -> coll bs m ++ concatMap (coll bs . snd) as
          STup es -> concatMap (coll bs) es
          SList es -> concatMap (coll bs) es
          SStrI segs -> concat [coll bs x | SegExpr x <- segs]
          _ -> []
        gos bs [] fin = coll bs fin
        gos bs (SBind n ps x : rest) fin = coll (bs <> S.fromList (n : ps)) x ++ gos (S.insert n bs) rest fin
        gos bs (SBindPat p x : rest) fin = coll bs x ++ gos (bs <> S.fromList (patVars p)) rest fin
    sccs = stronglyConnComp [(n, n, callsOf n) | n <- bindNames]

--------------------------------------------------------------------------------
-- declared termination measures
--------------------------------------------------------------------------------
--
-- `f : (x : T | measure e) -> ...` (or `(x : T | x >= 0 and measure x)`) is
-- the user's half of the bargain: they NAME what decreases, the compiler
-- verifies the easy obligations.  At every call from f into its recursive
-- group (f itself, or the whole mutually recursive SCC when every member
-- declares a measure) the CALLEE's measure, evaluated on the call's
-- arguments, must be below the CALLER's measure on its parameters:
--
--   * STRUCTURALLY: the callee's measured argument is a strict subterm of
--     the caller's measured value, bound by pattern matching; or
--   * LINEARLY: by at least 1, with a FLOOR (measure >= 0) derivable from
--     the clause guards, the case path, or the signature's own value
--     preconditions.
--
-- A verified measure lifts the group out of the unsafe rule: it is PROVEN
-- terminating, with at most measure(entry)/step + 1 calls in total.  That
-- bound is the datum the std proof pass turns into a cost equation
-- (StdCheck), so there is exactly one measure language.  Verification
-- failure is a loud error: the user claimed a measure.

data MeasureKind
  = MStructural Name -- descent on a pattern-matched parameter: at most len(param) calls
  | MLinear (M.Map Name Integer) Integer -- coefficients over the parameters, plus a constant; >= 0 wherever a call happens
  deriving (Eq, Show)

data Measure = Measure
  { mFn :: Name,
    mParams :: [Name], -- canonical parameter names (first clause); the measure is over these
    mKind :: MeasureKind,
    mStep :: Integer, -- every call in the group lowers the measure by at least this
    mGroup :: [Name] -- the recursive group this measure was verified with
  }
  deriving (Eq, Show)

data Delta = Structural | Lin Integer

measureCheck :: [STop] -> (M.Map Name Measure, [String])
measureCheck tops = measureCheckCG (callGraphOf tops) tops

measureCheckCG :: CallGraph -> [STop] -> (M.Map Name Measure, [String])
measureCheckCG cg tops = (M.fromList [(mFn m, m) | m <- concat oks], concat errs)
  where
    measureOf = M.fromList [(n, e) | TSig n _ pres <- tops, pr@(Just (_, p)) <- pres, not (reservedEntry pr), (Just e, _) <- [splitMeasure p]]
    -- the signature's value preconditions are facts inside the body
    sigFacts n = concat [msConj r | TSig n' _ pres <- tops, n' == n, pr@(Just (_, p)) <- pres, not (reservedEntry pr), (_, Just r) <- [splitMeasure p]]
    cycles = [ns | CyclicSCC ns <- cgSccs cg]
    groupOf n = case [ns | ns <- cycles, n `elem` ns] of (ns : _) -> ns; [] -> [n]
    groups = nub [groupOf n | n <- M.keys measureOf]
    (oks, errs) = unzip (map checkGroup groups)
    firstClause n = case cgClauses cg n of (c : _) -> Just c; [] -> Nothing
    pnamesOf n = case firstClause n of
      Just (ps, _, _) -> [maybe ("_p" ++ show i) id (pnameOf p) | (i, p) <- zip [0 :: Int ..] ps]
      Nothing -> []
    arityOf n = maybe 0 (\(ps, _, _) -> length ps) (firstClause n)
    checkGroup grp
      | not (null missing) =
          ( [],
            [ n ++ ": measure declared but the recursion is MUTUAL with " ++ intercalate ", " missing ++ ", which " ++ (if length missing == 1 then "declares" else "declare") ++ " no measure -- every function in the cycle needs one"
              | n <- grp,
                M.member n measureOf
            ]
          )
      | not (null es) = ([], es)
      | otherwise = ([Measure n (pnamesOf n) (kindOf n) step grp | n <- grp], [])
      where
        missing = [g | g <- grp, not (M.member g measureOf)]
        gtab = M.fromList [(g, (measureOf M.! g, pnamesOf g, arityOf g)) | g <- grp]
        results = [(n, measureErrs gtab n (sigFacts n) (cgClauses cg n)) | n <- grp]
        es = concat [e | (_, (e, _)) <- results]
        steps = concat [[1 | Structural <- ds] ++ [negate d | Lin d <- ds] | (_, (_, ds)) <- results]
        step = if null steps then 1 else minimum steps
        kindOf n =
          let (_, ds) = maybe ([], []) id (lookup n results)
              mexpr = measureOf M.! n
           in case (mexpr, [() | Structural <- ds], linE mexpr) of
                (SVar x, _ : _, _) -> MStructural x
                (_, _, Just (cm, km)) -> MLinear (M.filter (/= 0) cm) km
                (SVar x, _, _) -> MStructural x
                _ -> MLinear M.empty 0

pnameOf :: SPat -> Maybe Name
pnameOf (PVar v) = Just v
pnameOf (PSig v _) = Just v
pnameOf _ = Nothing

-- one clause at a time; a clause with no group calls owes nothing.
-- Returns the errors and, per verified call, how the measure dropped.
measureErrs :: M.Map Name (SExpr, [Name], Int) -> Name -> [(SExpr, Name, SExpr)] -> [([SPat], [SGuard], SExpr)] -> ([String], [Delta])
measureErrs gtab n sigFacts cls = (concat es, concat ds)
  where
    (mexpr, _, _) = gtab M.! n
    (es, ds) = unzip (zipWith chk [1 :: Int ..] cls)
    mvars = linVars mexpr
    chk ci (ps, g, b)
      | null calls = ([], [])
      | any (`notElem` pnames) (S.toList mvars) =
          ([n ++ " (clause " ++ show ci ++ "): the measure names a param this clause does not bind as a plain variable"], [])
      | bindsAny mvars b =
          ([n ++ " (clause " ++ show ci ++ "): a measure variable is rebound in the body -- rename the binding"], [])
      | otherwise = let rs = map callErr calls in (concat [e | Left e <- rs], [d | Right d <- rs])
      where
        pnames = [v | Just v <- pnameL]
        pnameL = map pnameOf ps
        ownFacts = concat [msConj e | GBool e <- g] ++ sigFacts
        priorFacts =
          concat
            [ concatMap msNeg (take 1 (map atomE (msConj ge)))
              | (ps', g', _) <- take (ci - 1) cls,
                [GBool ge0] <- [g'],
                Just ren <- [renamer ps' ps],
                let ge = ren ge0
            ]
          where
            atomE (a, op, bb) = SBin op a bb
        renamer ps' ps2
          | length ps' == length ps2,
            Just vs' <- mapM pnameOf ps',
            Just vs2 <- mapM pnameOf ps2 =
              Just (renameVars (M.fromList (zip vs' vs2)))
          | otherwise = Nothing
        calls = mcollect (ownFacts ++ priorFacts) S.empty b
        callErr (callee, args, facts, smaller)
          | structuralOk callee args smaller = Right Structural
          | Just d <- linDelta callee args, d <= -1 =
              if floorOk facts then Right (Lin d) else
                Left [ n ++ " (clause " ++ show ci ++ "): the measure decreases at the call to " ++ callee ++ " but its FLOOR (measure >= 0) is not derivable from the guards -- add a base clause/branch guarded on the measure (e.g. `| x <= 0 = ...`) or a precondition (`x >= 0 and measure x`)" ]
          | Just d <- linDelta callee args =
              Left [n ++ " (clause " ++ show ci ++ "): the measure does not decrease at the call to " ++ callee ++ " (delta " ++ show d ++ ", need <= -1)"]
          | otherwise =
              Left [n ++ " (clause " ++ show ci ++ "): the call to " ++ callee ++ " has arguments outside the linear fragment and is not a structural descent -- the measure cannot be verified"]
        -- the callee's measured argument is a strict subterm of the caller's measured value
        structuralOk callee args smaller = case gtab M.! callee of
          (SVar x, cpn, _)
            | Just i <- lookup x (zip cpn [0 ..]),
              i < length args,
              SVar w <- args !! i ->
                S.member w smaller
          _ -> False
        -- callee measure on the arguments, minus caller measure on the parameters
        linDelta callee args = do
          let (cm, cpn, _) = gtab M.! callee
              sub = M.fromList (zip cpn args)
          (cNew, kNew) <- linE (substMany sub cm)
          (cOld, kOld) <- linE mexpr
          let dc = M.filter (/= 0) (M.unionWith (+) cNew (M.map negate cOld))
          if M.null dc then Just (kNew - kOld) else Nothing
        floorOk facts =
          case linE mexpr of
            Just (cm, km)
              | M.null (M.filter (/= 0) cm) -> km >= 0
              | otherwise ->
                  -- measure m = <cm.x> + km, fact <fc.x> >= flo with
                  -- fc == cm gives m >= flo + km: the floor holds when
                  -- flo + km >= 0.
                  any
                    ( \(fc, flo) ->
                        M.filter (/= 0) (M.unionWith (+) fc (M.map negate cm)) == M.empty
                          && flo + km >= 0
                    )
                    (concatMap factGe facts)
            Nothing -> False
    -- walk the body: collect (callee, its args, path facts, subterm set)
    mcollect facts smaller e = case e of
      SMark _ x -> mcollect facts smaller x
      SBlock ss fin -> goB facts smaller ss fin
      SCase sc arms ->
        mcollect facts smaller sc
          ++ concat
            [ mcollect (facts ++ armF sc pt) (smaller `S.union` armSm smaller sc pt) bdy
              | (pt, bdy) <- arms
            ]
      _ ->
        let (h, as) = mspine e []
         in ( case h of
                SVar hn | Just (_, _, ar) <- M.lookup hn gtab, length as >= ar -> [(hn, take ar as, facts, smaller)]
                _ -> []
            )
              ++ concatMap (mcollect facts smaller) as
              ++ (case h of SLam _ lb -> mcollect facts smaller lb; SBin _ a bb -> mcollect facts smaller a ++ mcollect facts smaller bb; SProj a _ -> mcollect facts smaller a; STup es -> concatMap (mcollect facts smaller) es; SList es -> concatMap (mcollect facts smaller) es; SRec fs -> concatMap (mcollect facts smaller . snd) fs; SUpd a us -> mcollect facts smaller a ++ concatMap (mcollect facts smaller . snd) us; SStrI segs -> concat [mcollect facts smaller x | SegExpr x <- segs]; _ -> [])
      where
        goB f sm [] fin = mcollect f sm fin
        goB f sm (st : rest) fin =
          (case st of SBind _ _ x -> mcollect f sm x; SBindPat _ x -> mcollect f sm x)
            ++ goB f (sm `S.union` stSm sm st) rest fin
        stSm sm (SBindPat pt rhs) | SVar y <- unmark rhs, S.member y sm || isMeasVar y = subPat pt
        stSm _ _ = S.empty
    armF sc pt = case pt of
      PCon "True" [] -> msConj sc
      PCon "False" [] -> msNeg sc
      _ -> []
    armSm sm sc pt = case sc of
      SVar y | S.member y sm || isMeasVar y -> subPat pt
      _ -> S.empty
    isMeasVar y = case mexpr of SVar x -> x == y; _ -> False
    subPat pt = case pt of
      PVar _ -> S.empty -- an alias, NOT smaller
      _ -> S.fromList (patVars pt)

-- the linear fragment: coeff map + constant
linE e = case e of
  SInt k -> Just (M.empty, k)
  SVar v -> Just (M.singleton v (1 :: Integer), 0)
  SBin "+" a b -> comb (+) a b
  SBin "-" a b -> do (ca, ka) <- linE a; (cb, kb) <- linE b; Just (M.unionWith (+) ca (M.map negate cb), ka - kb)
  SBin "*" (SInt k) b -> do (cb, kb) <- linE b; Just (M.map (* k) cb, k * kb)
  SBin "*" a (SInt k) -> do (ca, ka) <- linE a; Just (M.map (* k) ca, k * ka)
  _ -> Nothing
  where
    comb f a b = do (ca, ka) <- linE a; (cb, kb) <- linE b; Just (M.unionWith (+) ca cb, f ka kb)
linVars e = maybe S.empty (M.keysSet . M.filter (/= 0) . fst) (linE e)
-- comparison atoms -> "linform >= lo" normal form
factGe (a, op, b) = case (linE a, linE b) of
  (Just (ca, ka), Just (cb, kb)) ->
    let dAB = (M.filter (/= 0) (M.unionWith (+) ca (M.map negate cb)), ka - kb)
        dBA = (M.filter (/= 0) (M.unionWith (+) cb (M.map negate ca)), kb - ka)
        ge (c, k) lo = [(c, lo - k)]
     in case op of
          ">" -> ge dAB 1
          ">=" -> ge dAB 0
          "<" -> ge dBA 1
          "<=" -> ge dBA 0
          "==" -> ge dAB 0 ++ ge dBA 0
          _ -> []
  _ -> []
msConj e = case e of
  SApp (SApp (SVar "and2") a) b -> msConj a ++ msConj b
  SBin "and" a b -> msConj a ++ msConj b
  SBin op a b | op `elem` mCmps -> [(a, op, b)]
  _ -> []
msNeg e = case e of
  SBin op a b | Just op' <- lookup op negPairs -> [(a, op', b)]
  _ -> []
  where
    negPairs = [("==", "!="), ("!=", "=="), ("<", ">="), (">=", "<"), (">", "<="), ("<=", ">")]
mCmps = ["==", "!=", "<", "<=", ">", ">="]
substMany sub = goSub
  where
    goSub e = case e of
      SVar v -> M.findWithDefault (SVar v) v sub
      SApp a b -> SApp (goSub a) (goSub b)
      SBin o a b -> SBin o (goSub a) (goSub b)
      _ -> e
renameVars ren = goR
  where
    goR e = case e of
      SVar v -> SVar (M.findWithDefault v v ren)
      SApp a b -> SApp (goR a) (goR b)
      SBin o a b -> SBin o (goR a) (goR b)
      _ -> e
bindsAny vs e = case e of
  SMark _ x -> bindsAny vs x
  SBlock ss fin -> any stB ss || bindsAny vs fin
  SCase sc arms -> bindsAny vs sc || any (bindsAny vs . snd) arms
  SApp a b -> bindsAny vs a || bindsAny vs b
  SBin _ a b -> bindsAny vs a || bindsAny vs b
  SLam _ b -> bindsAny vs b
  _ -> False
  where
    stB (SBind x _ rhs) = S.member x vs || bindsAny vs rhs
    stB (SBindPat pt rhs) = any (`S.member` vs) (patVars pt) || bindsAny vs rhs
mspine (SMark _ e) acc = mspine e acc
mspine (SApp f a) acc = mspine f (a : acc)
mspine h acc = (h, acc)
