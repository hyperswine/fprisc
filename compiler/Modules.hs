{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}

-- Modules.hs — content-addressed file modules for FPRISC.
--
--     MyMod = use "MyMod#4f2a91cc0d9e33b7".
--
--     x   = MyMod.x.
--     res = MyMod.f "hi".
--     T   = MyMod.T.        # alias the type (constructors + patterns too)
--
-- Every .fpr file IS a module.  Its identity is the FNV-1a-64 hash of the
-- AST it parses to, with each of ITS OWN `use` specs pin-normalized to the
-- resolved dependency hash first — so the hash is a Merkle root over the
-- whole dependency tree: pin one hash and you have pinned the exact code
-- of everything below it.  Whitespace and comments don't change identity;
-- code does.
--
-- Splicing is COMPILE TIME and purely name-based: a module's top-level
-- names are qualified to `name@hash`, references through the alias
-- (`MyMod.f`) rewrite to the qualified name, and the qualified tops are
-- concatenated into the one flat program the rest of the pipeline already
-- compiles.  Two different hashes of "the same" module therefore coexist
-- in one image with zero ceremony — immutable versioning falls out of the
-- naming scheme rather than being a feature.
--
-- The alias itself is a first-class value: `MyMod` in expression position
-- is the module's hash as a String.  Together with the emitted module
-- table (hash × export name → function object; see Codegen/mod.c) that is
-- the local half of FPRLive remote calling: `Mod.fn MyMod "f"` resolves
-- the same (hash, name) pair a remote node would ship over the wire.
module Modules
  ( loadProgram,
    LoadResult (..),
    ModExport (..),
    ModUnit (..),
    loadModule,
    hashAST,
  )
where

import Control.Monad (foldM, forM)
import Data.Bits (xor)
import Data.Char (isUpper, ord)
import Data.IORef
import Data.List (foldl', intercalate, isInfixOf, isPrefixOf, isSuffixOf)
import Data.Maybe (isNothing)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Word (Word64)
import FPRISC
import Numeric (showHex)
import Home (underHome)
import System.Directory (canonicalizePath, doesFileExist)
import System.FilePath (takeDirectory, (</>))
import Text.Megaparsec (errorBundlePretty, parse)

-- one remote-callable export: hash, surface name, qualified program name
data ModExport = ModExport
  { meHash :: String,
    meName :: String,
    meQual :: String,
    meArity :: Int
  }
  deriving (Show)

data LoadResult = LoadResult
  { lrTops :: [STop], -- the merged, qualified, alias-resolved program
    lrExports :: [ModExport], -- every module top-level bind (0-ary included;
                              -- Codegen's modtab filters to arity >= 1)
    lrNotes :: [String], -- unpinned-use resolutions worth printing
    -- separate compilation: each dep module as its own unit --
    -- (unit hash, its RENAMED tops), plus the root's renamed tops and
    -- the root's own Merkle hash (over pin-normalized uses, like any
    -- module's).  lrTops == prelude ++ concat units ++ root, unchanged.
    lrUnits :: [(String, [STop])],
    lrRootTops :: [STop],
    lrRootHash :: String,
    lrAnchors :: Anchors, -- QUALIFIED bind name -> (file, line) across
                          -- every spliced unit (spans step 1: the error
                          -- sinks anchor "in NAME:" messages with this)
    lrSources :: Sources -- unit file -> source (spans steps 2-3: the
                         -- locator scans ranges / resolves offsets)
  }

--------------------------------------------------------------------------------
-- Hashing
--------------------------------------------------------------------------------

-- FNV-1a 64 over the printed AST: deterministic, dependency-free.
-- (A real registry would use SHA-256 over a canonical serialization.)
hashAST :: [STop] -> String
hashAST tops = pad (showHex h "")
  where
    -- SPAN-PROOF (spans step 0): identity is the POSITIONLESS tree --
    -- stripPosTops (FPRISC.hs) erases any future source-position node
    -- before hashing, so spans can never churn a pinned hash.  Today
    -- it is the identity: bit-compatible with every existing pin.
    posless = stripPosTops tops
    -- precondition-free sigs print in the pre-contract shape so
    -- existing pinned module hashes stay valid (the AST is the same
    -- module; only the constructor grew a field)
    stable (TSig n tys pres) | all isNothing pres = "TSig " ++ show n ++ " " ++ show tys
    stable t = show t
    h = foldl' step 0xcbf29ce484222325 ("[" ++ intercalate "," (map stable posless) ++ "]") :: Word64
    step acc c = (acc `xor` fromIntegral (ord c)) * 0x100000001b3
    pad s = replicate (16 - length s) '0' ++ s

qualify :: String -> Name -> Name
qualify h n = n ++ "@" ++ h

--------------------------------------------------------------------------------
-- Loading (IO): resolve, parse, hash, recurse
--------------------------------------------------------------------------------

data ModUnit = ModUnit
  { muHash :: String,
    muTops :: [STop], -- as parsed (uses pin-normalized, not yet qualified)
    muAliases :: [(Name, String)], -- import alias -> dep hash
    muAnchors :: Anchors, -- bind name -> (file, line), pre-qualification
    muSrc :: (FilePath, String) -- the unit's source (the locator scans it)
  }

-- "Name", "Name#hash", "dir/Name", "Name.fpr#hash" — resolved relative
-- to the importing file's directory.
specParts :: String -> (String, String)
specParts spec = let (n, h) = break (== '#') spec in (n, drop 1 h)

specFile :: FilePath -> String -> FilePath
specFile baseDir name =
  let f = if ".fpr" `isSuffixOf` name then name else name ++ ".fpr"
   in if take 1 f == "/" then f else baseDir </> f

-- Load the transitive closure below a root file's tops.  State:
--   cache  : canonical path -> ModUnit (parse/hash once)
--   stack  : in-progress canonical paths (cycle detection)
loadDeps ::
  IORef (M.Map FilePath ModUnit) ->
  [FilePath] ->
  FilePath ->
  [STop] ->
  IO (Either String ([(Name, String)], [String]))
loadDeps cache stack dir tops = do
  let uses = [(a, s) | TUse a s <- tops]
  r <- foldM step (Right ([], [])) uses
  pure (fmap (\(as, ns) -> (reverse as, reverse ns)) r)
  where
    step (Left e) _ = pure (Left e)
    step (Right (as, ns)) (alias, spec) = do
      let (nm, wantHash) = specParts spec
          path0 = specFile dir nm
      -- importer-relative first, as always; a miss then looks under the
      -- toolchain's home (Home.hs), so a program OUTSIDE the tree can say
      -- `use "std/mvu"` and find the installed std.  The error names
      -- both places, because "no such module file" with one path was
      -- exactly the message that used to send people cd-ing around.
      here <- doesFileExist path0
      homeHit <- if here || take 1 nm == "/" then pure Nothing else underHome (specFile "" nm)
      let path = maybe path0 id homeHit
      r00 <- loadModule cache stack path
      let r0 = case (r00, homeHit, here) of
            (Left _, Nothing, False) ->
              Left ("use: no such module file: " ++ path0 ++ "  (nor " ++ specFile "$FPR_HOME" nm ++ ")")
            _ -> r00
      -- the committed-version fallback: a pinned use whose scratch file
      -- is missing OR has drifted from the pin resolves from the local
      -- .fpr store (fpr commit's content blobs) — the scratch file is a
      -- working copy, the store entry is the identity.
      r <- case r0 of
        Right mu | null wantHash || muHash mu == wantHash -> pure r0
        _ | not (null wantHash) -> do
          -- the store: this tree's first, the toolchain home's second
          -- (an installed fpr carries the versions its std was released with)
          let sp0 = ".fpr/store/" ++ wantHash ++ ".fpr"
          local <- doesFileExist sp0
          homeStore <- if local then pure Nothing else underHome sp0
          let sp = maybe sp0 id homeStore
              inStore = local || homeStore /= Nothing
          if not inStore
            then pure r0
            else do
              rs <- loadModule cache stack sp
              case rs of
                Right ms | muHash ms == wantHash -> do
                  putStrLn ("use: " ++ nm ++ "#" ++ take 8 wantHash ++ "… resolved from .fpr store (committed version)")
                  pure rs
                _ -> pure r0
        _ -> pure r0
      pure $ case r of
        Left e -> Left e
        Right mu
          -- packaging rule: blanket `unsafe module.` is CORE-ONLY.  A
          -- module used under a std.* name must carry per-function
          -- unsafe signatures (the strict mode) -- blanket-unsafe
          -- library code can only ship as core.*.
          | "std/" `isInfixOf` nm || "std." `isPrefixOf` nm,
            or [ True | TSig "$module" _ pres <- muTops mu,
                        any (\p -> (fst <$> p) == Just "$unsafe") pres ] ->
              Left
                ( "use: " ++ nm ++ " declares blanket `unsafe module.` -- "
                    ++ "std.* modules must mark unsafe per function "
                    ++ "(blanket unsafe is core-only); "
                    ++ "eliminate the unsafes or package it as core.*"
                )
          | not (null wantHash) && muHash mu /= wantHash ->
              Left
                ( "use: hash mismatch for " ++ nm
                    ++ ":\n  pinned  #" ++ wantHash
                    ++ "\n  on disk #" ++ muHash mu
                    ++ "\n(the module's AST changed since it was pinned; `fpr commit` the module to make the pin resolvable from the store)"
                )
          | otherwise ->
              let note =
                    [ "use: " ++ alias ++ " resolves to \"" ++ nm ++ "#" ++ muHash mu
                        ++ "\"  (pin it to freeze this exact code)"
                      | null wantHash
                    ]
               in Right ((alias, muHash mu) : as, note ++ ns)

loadModule ::
  IORef (M.Map FilePath ModUnit) ->
  [FilePath] ->
  FilePath ->
  IO (Either String ModUnit)
loadModule cache stack path0 = do
  ok <- doesFileExist path0
  if not ok
    then pure (Left ("use: no such module file: " ++ path0))
    else do
      path <- canonicalizePath path0
      if path `elem` stack
        then pure (Left ("use: module cycle through " ++ path))
        else do
          c <- readIORef cache
          case M.lookup path c of
            Just mu -> pure (Right mu)
            Nothing -> do
              src <- readFile path
              case parse program path src of
                Left e -> pure (Left ("use: module " ++ path ++ " does not parse:\n" ++ errorBundlePretty e))
                Right tops -> do
                  r <- loadDeps cache (path : stack) (takeDirectory path) tops
                  case r of
                    Left e -> pure (Left e)
                    Right (aliases, _notes) -> do
                      -- pin-normalize this module's own uses before hashing:
                      -- the hash is a Merkle root over the dependency tree
                      let pinned = [pinUse aliases t | t <- tops]
                          h = hashAST pinned
                          mu = ModUnit h tops aliases (bindAnchors path src tops) (path, src)
                      modifyIORef' cache (M.insert path mu)
                      pure (Right mu)
  where
    pinUse aliases (TUse a spec) =
      let (nm, _) = specParts spec
          hs = maybe "?" id (lookup a aliases)
       in TUse a (nm ++ "#" ++ hs)
    pinUse _ t = t

--------------------------------------------------------------------------------
-- Renaming: qualify a module's namespace, rewrite alias references
--------------------------------------------------------------------------------

data REnv = REnv
  { reSelf :: Name -> Maybe Name, -- this unit's top-level names -> qualified
    reAliases :: M.Map Name String, -- import alias -> dep hash
    reAliasSubst :: M.Map Name Name, -- T = MyMod.T style name aliases
    -- struct names, for dotted-field resolution: a struct qualifies as
    -- `Rand@hash` and expands to `Rand@hash.next`, so a reference
    -- `Rand.next` (self) / `M.Rand.next` (through an alias) / `R.next`
    -- (through `R = M.Rand.`) must qualify the HEAD only -- unlike plain
    -- module members, where the whole name qualifies.
    reSelfStructs :: S.Set Name, -- this unit's own struct tops
    reDepStructs :: M.Map Name (S.Set Name) -- import alias -> dep's struct tops
  }

-- resolve one name occurrence (non-binding position).
-- conPos: constructor/type position (bare alias does NOT become a hash there).
refName :: REnv -> Bool -> S.Set Name -> Name -> Either Name String
refName env conPos bound nm0
  | S.member nm0 bound = Left nm0
  | otherwise = go (chase (0 :: Int) nm0)
  where
    chase k n
      | k > 32 = n -- alias cycle: give up, let it fail downstream
      | Just t <- M.lookup n (reAliasSubst env) = chase (k + 1) t
      -- `R = M.Rand.` then `R.next`: substitute the HEAD of a dotted
      -- name through the alias, then resolve the result normally
      | (h, '.' : rest) <- break (== '.') n,
        Just t <- M.lookup h (reAliasSubst env) =
          chase (k + 1) (t ++ "." ++ rest)
      | otherwise = n
    go nm
      | not conPos, Just h <- M.lookup nm (reAliases env) = Right h -- bare alias = hash string
      | (a, '.' : rest) <- break (== '.') nm,
        Just h <- M.lookup a (reAliases env) =
          case break (== '.') rest of
            -- `M.Rand.next` where Rand is a struct in M: the struct name
            -- qualifies, the field stays -- `Rand@hash.next` is the flat
            -- global expandStructs creates
            (s, '.' : fld)
              | S.member s (M.findWithDefault S.empty a (reDepStructs env)) ->
                  Left (qualify h s ++ "." ++ fld)
            _ -> Left (qualify h rest)
      | Just q <- reSelf env nm = Left q
      -- `Rand.next` inside the module that declares struct Rand: the
      -- head qualifies to this unit's hash, the field stays
      | (s, '.' : fld) <- break (== '.') nm,
        S.member s (reSelfStructs env),
        Just qs <- reSelf env s =
          Left (qs ++ "." ++ fld)
      | otherwise = Left nm

refVar :: REnv -> S.Set Name -> Name -> SExpr
refVar env bound nm = case refName env False bound nm of
  Left n -> SVar n
  Right h -> SStrI [SegStr h]

refCon :: REnv -> S.Set Name -> Name -> Name
refCon env bound nm = case refName env True bound nm of
  Left n -> n
  Right h -> h -- unreachable: conPos never yields a hash

--------------------------------------------------------------------------------

renameTops :: REnv -> String -> [STop] -> [STop]
renameTops env qh = concatMap top
  where
    qual n = case qh of "" -> n; h -> qualify h n
    top = \case
      TUse {} -> [] -- consumed by the loader
      TAlias {} -> [] -- folded into reAliasSubst
      TSkip -> []
      TShape n fs -> [TShape n [(f, ty t) | (f, t) <- fs]] -- structural: never qualified
      TSig n (as, r) pres -> [TSig (qual n) (map ty as, ty r) pres]
      TType n lin ps cons ->
        [TType (qual n) lin ps [(qual c, map ty ts) | (c, ts) <- cons]]
      TSigDef n fs -> [TSigDef (qual n) [(f, fmap ty mt) | (f, mt) <- fs]]
      -- NOTE: structs are expanded to flat globals + a record BEFORE
      -- module qualification (see loadProgram), so renameTops should not
      -- see a TStruct. Kept total for safety.
      TStruct n sigs fs -> [TStruct (qual n) (map (refCon env S.empty) sigs) [(f, expr S.empty e) | (f, e) <- fs]]
      TBind n pats g body ->
        let (pats', bound) = pats1 S.empty pats
            (g', bound') =
              foldl'
                ( \(acc, b) gd -> case gd of
                    GBool e -> (acc ++ [GBool (expr b e)], b)
                    GPat p e ->
                      let e' = expr b e
                          (p', b2) = pat b p
                       in (acc ++ [GPat p' e'], b2)
                )
                ([], bound)
                g
         in [TBind (qual n) pats' g' (expr bound' body)]

    ty = \case
      TCon n ts -> TCon (refCon env S.empty n) (map ty ts)
      TTup ts -> TTup (map ty ts)
      TArrT a b -> TArrT (ty a) (ty b)
      TVApp n ts -> TVApp n (map ty ts)
      t -> t

    pats1 bound = foldl' (\(ps, b) p -> let (p', b') = pat b p in (ps ++ [p'], b')) ([], bound)

    pat bound = \case
      PVar n -> (PVar n, S.insert n bound)
      PWild -> (PWild, bound)
      PInt i -> (PInt i, bound)
      PStr s -> (PStr s, bound)
      PCon c ps -> let (ps', b') = pats1 bound ps in (PCon (refCon env bound c) ps', b')
      PTup ps -> let (ps', b') = pats1 bound ps in (PTup ps', b')
      PRec fs -> (PRec fs, foldr S.insert bound fs)
      PSig n sg -> (PSig n sg, S.insert n bound)

    expr bound = \case
      SMark o e -> SMark o (expr bound e)
      SVar n
        | isUpper (head' n) -> refVar env bound n
        | otherwise -> if S.member n bound then SVar n else refVar env bound n
      SInt i -> SInt i
      SAtom a -> SAtom a
      SStrI segs -> SStrI (map seg segs)
      SApp f a -> SApp (expr bound f) (expr bound a)
      SLam ps b -> SLam ps (expr (foldr S.insert bound ps) b)
      SBlock ss e ->
        let (ss', bound') = stmts bound ss in SBlock ss' (expr bound' e)
      SCase s arms ->
        SCase (expr bound s) [let (p', b') = pat bound p in (p', expr b' e) | (p, e) <- arms]
      SBin o a b -> SBin o (expr bound a) (expr bound b)
      SProj e fs -> SProj (expr bound e) fs
      SRec fs -> SRec [(f, expr bound e) | (f, e) <- fs]
      SUpd m as -> SUpd (expr bound m) [(p, expr bound e) | (p, e) <- as]
      STup es -> STup (map (expr bound) es)
      SList es -> SList (map (expr bound) es)
      where
        seg (SegExpr e) = SegExpr (expr bound e)
        seg s = s

    stmts bound [] = ([], bound)
    stmts bound (SBind n ps e : rest) =
      let inner = foldr S.insert (S.insert n bound) ps
          (rest', bound') = stmts (S.insert n bound) rest
       in (SBind n ps (expr inner e) : rest', bound')
    stmts bound (SBindPat p e : rest) =
      let e' = expr bound e
          (p', bound1) = pat bound p
          (rest', bound') = stmts bound1 rest
       in (SBindPat p' e' : rest', bound')

    head' [] = ' '
    head' (c : _) = c

--------------------------------------------------------------------------------
-- The whole program
--------------------------------------------------------------------------------

-- loadProgram preludeTops rootPath rootTops:
--   * loads the transitive module closure below rootTops,
--   * qualifies each module's namespace by its hash and splices everything
--     (prelude + modules + root) into one flat [STop],
--   * returns module-table exports and unpinned-use notes.
loadProgram :: [STop] -> FilePath -> [STop] -> IO (Either String LoadResult)
loadProgram preludeTops rootPath rootTops = do
  cache <- newIORef M.empty
  r <- loadDeps cache [] (takeDirectory rootPath) rootTops
  case r of
    Left e -> pure (Left e)
    Right (rootAliases, notes) -> do
      units <- M.elems <$> readIORef cache -- every loaded module, once per hash
      -- notes from nested (module-internal) unpinned uses:
      depNotes <- fmap concat . forM units $ \mu ->
        pure ["  (inside a module) use of unpinned dep resolves to #" ++ h | (_, h) <- muAliases mu, False] -- deps are pin-normalized silently
      let unitPairs = [(muHash mu, qualifyUnit unitStructs' mu) | mu <- units]
          unitStructs' =
            M.fromList
              [(muHash mu, S.fromList [n | TStruct n _ _ <- muTops mu]) | mu <- units]
          unitTops = map snd unitPairs
          unitStructs =
            M.fromList
              [(muHash mu, S.fromList [n | TStruct n _ _ <- muTops mu]) | mu <- units]
          depStructsFor aliases =
            M.fromList
              [ (a, M.findWithDefault S.empty h unitStructs)
                | (a, h) <- aliases
              ]
          rootEnv =
            REnv
              { reSelf = const Nothing, -- root names stay unqualified
                reAliases = M.fromList rootAliases,
                reAliasSubst = M.fromList [(a, b) | TAlias a b <- rootTops],
                reSelfStructs = S.empty, -- root structs keep their names; refs already match
                reDepStructs = depStructsFor rootAliases
              }
          root' = renameTops rootEnv "" rootTops
          merged = preludeTops ++ concat unitTops ++ root'
          rootHash = hashAST [pinRoot rootAliases t | t <- rootTops]
          exports =
            [ ModExport (muHash mu) n (qualify (muHash mu) n) (length ps)
              | mu <- units,
                TBind n ps _ _ <- muTops mu
            ]
      let unitAnchors =
            M.unions [M.mapKeys (qualify (muHash mu)) (muAnchors mu) | mu <- units]
          unitSources = M.fromList [muSrc mu | mu <- units]
      pure (Right (LoadResult merged exports (notes ++ depNotes) unitPairs root' rootHash unitAnchors unitSources))
  where
    pinRoot aliases (TUse a spec) =
      let (nm, _) = specParts spec
          hs = maybe "?" id (lookup a aliases)
       in TUse a (nm ++ "#" ++ hs)
    pinRoot _ t = t
    qualifyUnit unitStructs mu =
      let env =
            REnv
              { reSelf = \n -> if S.member n selfNames then Just (qualify (muHash mu) n) else Nothing,
                reAliases = M.fromList (muAliases mu),
                reAliasSubst = M.fromList [(a, b) | TAlias a b <- muTops mu],
                reSelfStructs = S.fromList [n | TStruct n _ _ <- muTops mu],
                reDepStructs =
                  M.fromList
                    [ (a, M.findWithDefault S.empty h unitStructs)
                      | (a, h) <- muAliases mu
                    ]
              }
          selfNames =
            S.fromList $
              concat
                [ case t of
                    TBind n _ _ _ -> [n]
                    TSig n _ _ -> [n]
                    TSigDef n _ -> [n]
                    TStruct n _ _ -> [n]
                    TType n _ _ cons -> n : map fst cons
                    _ -> []
                  | t <- muTops mu
                ]
       in renameTops env (muHash mu) (muTops mu)
