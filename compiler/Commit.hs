{-# LANGUAGE LambdaCase #-}

-- Commit.hs — `fpr commit`: module versioning into the local .fpr store.
--
-- The model (the fpr-commit design): <name>.fpr is a mutable SCRATCH
-- AREA for the id <name> — not the identity-bearing artifact.  `fpr
-- commit file.fpr` mints an immutable, hash-addressed version:
--
--     .fpr/store/<hash>.fpr      the exact source bytes (content blob)
--     .fpr/versions.db           append-only "name version hash date"
--
-- The hash is the frontend's OWN pin hash (Modules.hashAST over the
-- pin-normalized tree — a Merkle root over the dependency tree), so a
-- committed version is addressable by the SAME `use "name#<hash>"`
-- syntax the compiler already prints on every unpinned use.  Module
-- resolution falls back to .fpr/store when the scratch file is gone or
-- has drifted from the pinned hash (Modules.loadModule).
--
-- Version classification is a SIGNATURE DIFF against the prior
-- version, per the design:
--   identical hash          -> no-op (nothing changed)
--   old signature <= new    -> PATCH bump  (compatible subset: every
--                              exported name keeps arity + declared
--                              sig and inferred type; additions are fine)
--   otherwise               -> MAJOR, refused without --major
-- The subset check is the commit-time face of the row-compatibility
-- question: a patch retains the checked inferred types and written contracts.
-- Equality is conservative; this is not semantic subsumption or an image certificate.
--
-- .fpr/versions.db is structurally pkgstore's model (content blobs +
-- append-only name/version->hash bindings): `fpr push` to a pkgstore
-- is blob upload + binding registration, nothing more.
module Commit (commitMain, pinMain, versionsMain, pushMain, pullMain) where

import Control.Exception (throwIO, try)
import Control.Monad (foldM, forM, unless, when)
import qualified Compile
import qualified Data.IORef
import Data.IORef (newIORef, readIORef)
import Data.List (intercalate, isInfixOf, isPrefixOf, isSuffixOf, nub, sort)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Maybe (fromMaybe)
import Frontend.Syntax
import Frontend.Traverse (stripPosTops)
import Home (underHome)
import Modules (ModUnit (..), loadModule)
import System.Directory (canonicalizePath, copyFile, createDirectoryIfMissing, doesFileExist, getCurrentDirectory, makeRelativeToCurrentDirectory)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath (makeRelative, splitDirectories, takeBaseName, takeDirectory, (</>))
import System.Process (readProcess)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)

readIORefMap :: Data.IORef.IORef (M.Map FilePath ModUnit) -> IO [(FilePath, ModUnit)]
readIORefMap ref = M.toList <$> readIORef ref

dbPath, storeDir :: FilePath
dbPath = ".fpr/versions.db"
storeDir = ".fpr/store"

-- one line per binding, append-only: name<SP>version<SP>hash
readDb :: IO [(String, String, String)]
readDb = do
  ok <- doesFileExist dbPath
  if not ok
    then pure []
    else do
      ls <- lines <$> readFile dbPath
      pure [(n, v, h) | l <- ls, [n, v, h] <- [words l]]

-- ---- the exported signature of a module ---------------------------------
-- name + arity for every binding, full rendered sig for every TSig,
-- constructor shapes for every Type.  Sorted, so subset = compatibility.
sigOf :: [STop] -> [String]
sigOf source =
  let tops = stripPosTops source
   in sort $
    [ "fn " ++ n ++ "/" ++ show (length ps) | TBind n ps _ _ <- tops ]
      -- the resource bounds are part of the written interface: a changed
      -- bound (wider or tighter) is a different signature, hence a major
      -- version -- callers compose on the declared bound
      ++ [ "sig " ++ n ++ " : " ++ show (ps, r) ++ " | contracts " ++ show pres | TSig n (ps, r) pres <- tops ]
      ++ [ "type " ++ n ++ " " ++ show (lin, ps, cs) | TType n lin ps cs <- tops ]

subsetOf :: [String] -> [String] -> Bool
subsetOf old new = all (`elem` new) old

bump :: Bool -> String -> String
bump major v =
  let (mj, mn) = case break (== '.') (dropWhile (== 'v') v) of
        (a, '.' : b) -> (readI a, readI b)
        (a, _) -> (readI a, 0)
      readI s = fromMaybe 0 (readMaybe s)
      readMaybe s = case reads s of [(x, "")] -> Just x; _ -> Nothing :: Maybe Int
   in if major then "v" ++ show (mj + 1) ++ ".0" else "v" ++ show mj ++ "." ++ show (mn + 1)

commitMain :: [String] -> IO ()
commitMain args = do
  let major = "--major" `elem` args
      files = [a | a <- args, not ("--" `isPrefixOf` a)]
  file <- case files of
    [f] -> pure f
    _ -> hPutStrLn stderr "usage: fpr commit <module.fpr> [--major]   (pin its uses first: fpr pin <module.fpr> [--deps] [--update[=spec,...]])" >> exitFailure >> pure ""
  cache <- newIORef M.empty
  r <- loadModule cache [] file
  mu <- case r of
    Left e -> hPutStrLn stderr e >> exitFailure >> undefined
    Right mu -> pure mu
  -- THE CLOSURE RULE: a committed module must be closed under its pin
  -- hash.  (1) Every `use` in the transitive closure must be PINNED —
  -- an unpinned spec would resolve relative to wherever the blob sits,
  -- which for a store-resolved copy is the store directory: refuse,
  -- printing the exact pinned line to paste (the hashes are already
  -- computed).  (2) Every dependency source in the closure is copied
  -- into .fpr/store under its own hash, so store-fallback resolution
  -- works for the whole tree, not just the root.
  closure <- readIORefMap cache
  let unpinned =
        [ (p, a, spec, h)
          | (p, m) <- closure,
            TUse a spec <- muTops m,
            '#' `notElem` spec,
            let h = fromMaybe "?" (lookup a (muAliases m))
        ]
  unless (null unpinned) $ do
    mapM_
      (\(p, a, spec, h) ->
         hPutStrLn stderr ("  unpinned use in " ++ p ++ ":  " ++ a ++ " = use \"" ++ spec ++ "\".   -> pin it:  " ++ a ++ " = use \"" ++ spec ++ "#" ++ h ++ "\"."))
      unpinned
    hPutStrLn stderr "commit refused: committed modules must be closed under their pin hash (all uses pinned)"
    hPutStrLn stderr ("  fix: fpr pin " ++ file ++ " --deps   (pins every unpinned use above, dependencies first, in files under this directory)")
    exitFailure
  -- Check before any store/database mutation, including no-op commits.
  let deprecated = deprecatedIntBounds (muTops mu)
  unless (null deprecated) $ do
    hPutStrLn stderr ("commit refused: " ++ intercalate ", " deprecated ++ " deprecated (Int is arbitrary-precision in v1.0); remove them before committing a new version")
    exitFailure
  inferred <- checkedOrRefuse ("commit refused: " ++ file ++ " does not pass the checker (diagnostics above); nothing was written") (Compile.checkedInterface file)
  let name = takeBaseName file
      h = muHash mu
      newSig = sigOf (muTops mu) ++ inferredSig inferred
  db <- readDb
  let mine = [(v, hh) | (n, v, hh) <- db, n == name]
  case reverse mine of
    [] -> do
      writeVersion closure name "v1.0" h file
      putStrLn ("committed " ++ name ++ ".v1.0#" ++ h ++ "  (first version)")
    ((pv, ph) : _)
      | ph == h -> do
          _ <- storeUnit ph
          putStrLn (name ++ "." ++ pv ++ "#" ++ h ++ " is already this exact content — no-op")
      | otherwise -> do
          prior <- storeInterface ph
          (oldTops, oldInferred) <- case prior of
            Just x -> pure x
            Nothing
              | major -> do
                  putStrLn ("  note: the prior version " ++ name ++ "." ++ pv ++ " cannot be re-checked by this compiler (above); nothing to compare, minting a major version")
                  pure ([], [("(prior " ++ pv ++ " cannot be re-checked)", "")])
              | otherwise -> do
                  hPutStrLn stderr ("commit refused: the prior version " ++ name ++ "." ++ pv ++ " (.fpr/store/" ++ ph ++ ".fpr) cannot be re-checked by this compiler (above),")
                  hPutStrLn stderr ("  so this version cannot be shown signature-compatible with it; re-run with --major to mint " ++ bump True pv)
                  exitFailure
                  pure ([], [])
          let oldSig = sigOf oldTops ++ inferredSig oldInferred
              compatible = oldSig `subsetOf` newSig
          if compatible
            then do
              let v = bump False pv
              writeVersion closure name v h file
              putStrLn ("committed " ++ name ++ "." ++ v ++ "#" ++ h ++ "  (patch: signature-compatible with " ++ pv ++ ")")
            else do
              let missing = nub [s | s <- oldSig, s `notElem` newSig]
                  -- a root-declared nominal type's identity is Type@<version
                  -- hash> (its runtime tid follows the unit hash), so an
                  -- export that mentions one differs in EVERY new version
                  renamed = [s | s <- missing, ('@' : ph) `isInfixOf` s, replaceAll ('@' : ph) ('@' : h) s `elem` newSig]
                  real = [s | s <- missing, s `notElem` renamed]
              mapM_ (\s -> putStrLn ("  incompatible: " ++ pv ++ " exported `" ++ s ++ "`, this version does not")) real
              unless (null renamed) $
                putStrLn ("  incompatible: " ++ show (length renamed) ++ " export(s) differ only because they mention this module's own nominal types, whose identity is Type@<version hash> (" ++ "@" ++ ph ++ " -> @" ++ h ++ "): a value of the old type is not a value of the new one")
              unless major $ do
                hPutStrLn stderr ("commit refused: not a compatible subset of " ++ pv ++ " — re-run with --major to mint " ++ bump True pv
                  ++ (if null real && not (null renamed) then " (only nominal type identities changed; pinned users keep " ++ pv ++ " from the store until re-pinned with `fpr pin --update`)" else ""))
                exitFailure
              let v = bump True pv
              writeVersion closure name v h file
              putStrLn ("committed " ++ name ++ "." ++ v ++ "#" ++ h ++ "  (MAJOR: breaks " ++ pv ++ "'s signature)")
  where
    inferredSig = map (\(n, t) -> "inferred " ++ n ++ " : " ++ t)
    writeVersion closure name v h file = do
      createDirectoryIfMissing True storeDir
      mapM_ (\(p, m) -> when (p /= file) $ do
        let dest = storeDir ++ "/" ++ muHash m ++ ".fpr"
        present <- doesFileExist dest
        unless present (copyFile p dest)) closure
      copyFile file (storeDir ++ "/" ++ h ++ ".fpr")
      appendFile' dbPath (name ++ " " ++ v ++ " " ++ h ++ "\n")
    appendFile' p s = do
      createDirectoryIfMissing True ".fpr"
      appendFile p s
    -- The prior version is an immutable blob that the checker of its day
    -- admitted.  Its interface comes from the normal checker minus the
    -- safe/unsafe lint (Compile.recordedInterface): that lint tightens
    -- between releases and no edit can update a committed blob.  A prior
    -- version that no longer loads, reproduces its own hash, or TYPE-checks
    -- yields Nothing (refused, or a major version under --major).
    storeInterface h = do
      let p = storeDir ++ "/" ++ h ++ ".fpr"
      ok <- doesFileExist p
      unless ok $ hPutStrLn stderr ("commit refused: prior version blob missing: " ++ p) >> exitFailure
      cache <- newIORef M.empty
      loaded <- loadModule cache [] p
      case loaded of
        Left e -> putStrLn ("  prior version " ++ p ++ " cannot load: " ++ e) >> pure Nothing
        Right mu
          | muHash mu /= h -> do
              -- only possible for a blob committed before the closure rule:
              -- an unpinned use resolves to TODAY's file, so the blob no
              -- longer hashes to its own name
              let loose = [a ++ " = use \"" ++ spec ++ "\"" | TUse a spec <- muTops mu, '#' `notElem` spec]
              putStrLn ("  prior version " ++ p ++ " no longer reproduces its hash (now #" ++ muHash mu ++ ")"
                ++ (if null loose then "" else ": it predates the closure rule and has unpinned use(s) " ++ intercalate ", " loose ++ ", which resolve to today's files"))
              pure Nothing
          | otherwise -> do
              r <- try (Compile.recordedInterface p)
              case r of
                Left (ExitFailure _) -> pure Nothing
                Left ExitSuccess -> pure Nothing
                Right interface -> pure (Just (muTops mu, interface))
    storeUnit h = do
      let p = storeDir ++ "/" ++ h ++ ".fpr"
      ok <- doesFileExist p
      unless ok $ hPutStrLn stderr ("commit refused: prior version blob missing: " ++ p) >> exitFailure
      cache <- newIORef M.empty
      r <- loadModule cache [] p
      case r of
        Left e -> hPutStrLn stderr ("commit refused: prior version cannot load: " ++ e) >> exitFailure >> undefined
        Right mu -> do
          unless (muHash mu == h) $ hPutStrLn stderr "commit refused: prior version blob hash mismatch" >> exitFailure
          pure mu

replaceAll :: String -> String -> String -> String
replaceAll from to = go
  where
    go [] = []
    go t@(c : rest)
      | from `isPrefixOf` t = to ++ go (drop (length from) t)
      | otherwise = c : go rest

-- Run a checker step that reports through exitFailure; on failure name what
-- was refused (the checker's own diagnostics are already printed above).
checkedOrRefuse :: String -> IO a -> IO a
checkedOrRefuse why act = do
  r <- try act
  case r of
    Right x -> pure x
    Left (ExitFailure _) -> hPutStrLn stderr why >> exitFailure
    Left ExitSuccess -> throwIO ExitSuccess

-- ---- fpr pin: write the pins `fpr commit` asks for --------------------------
--
--   fpr pin <module.fpr>             pin every unpinned `use "spec"` in the file
--                                    to the hash it resolves to now
--   fpr pin <module.fpr> --deps      first do the same, recursively and
--                                    dependencies first, for every scratch module
--                                    of the closure under the current directory
--                                    (never the toolchain's files, never
--                                    .fpr/store)
--   fpr pin <module.fpr> --update    also RE-pin pinned uses whose scratch source
--                                    has moved on: the supported migration (the
--                                    old pin keeps resolving from the store until
--                                    you run this)
--   fpr pin <module.fpr> --update=std/actor,ep
--                                    re-pin only those specs, plus any pin whose
--                                    module this run rewrote (the cascade)
--   --dry-run                        print the edits, write nothing
--
-- Edits are textual and exact: only the string literal after `use` changes,
-- so comments and layout survive.  A file whose re-pinned form no longer
-- loads is restored and reported.  Nothing is committed: run `fpr commit`
-- afterwards, dependencies first (the order this command printed).
pinMain :: [String] -> IO ()
pinMain args = do
  let flags = [a | a <- args, "--" `isPrefixOf` a]
      files = [a | a <- args, not ("--" `isPrefixOf` a)]
      updateOnly = concat [splitComma (drop (length "--update=") f) | f <- flags, "--update=" `isPrefixOf` f]
      unknown = [f | f <- flags, f `notElem` ["--deps", "--dry-run", "--update"], not ("--update=" `isPrefixOf` f)]
      mode = PinMode ("--deps" `elem` flags) ("--dry-run" `elem` flags) ("--update" `elem` flags) updateOnly
  unless (null unknown) $ hPutStrLn stderr ("pin: unknown flag(s): " ++ unwords unknown) >> exitFailure
  file <- case files of
    [f] -> pure f
    _ -> hPutStrLn stderr "usage: fpr pin <module.fpr> [--deps] [--update | --update=spec,...] [--dry-run]" >> exitFailure >> pure ""
  ok <- doesFileExist file
  unless ok $ hPutStrLn stderr ("pin: no such file: " ++ file) >> exitFailure
  cwd <- getCurrentDirectory >>= canonicalizePath
  root <- canonicalizePath file
  (_, order) <- pinFile mode cwd ([], []) root
  rel <- mapM makeRelativeToCurrentDirectory (reverse order)
  putStrLn
    ( if null rel
        then "pin: nothing to change"
        else (if pmDry mode then "pin: would rewrite " else "pin: rewrote ") ++ show (length rel) ++ " file(s), commit them in this order: " ++ unwords rel
    )
  where
    splitComma t = case break (== ',') t of
      (a, ',' : b) -> filter (not . null) [a] ++ splitComma b
      (a, _) -> filter (not . null) [a]

data PinMode = PinMode {pmDeps :: Bool, pmDry :: Bool, pmUpdateAll :: Bool, pmUpdateOnly :: [String]}

-- (visited, rewritten newest-first) threaded through a post-order walk.
pinFile :: PinMode -> FilePath -> ([FilePath], [FilePath]) -> FilePath -> IO ([FilePath], [FilePath])
pinFile mode cwd (visited, changed) path
  | path `elem` visited = pure (visited, changed)
  | otherwise = do
      src <- readFile path
      length src `seq` pure ()
      loaded <- freshLoad path
      tops <- case loaded of
        Left e -> hPutStrLn stderr e >> exitFailure >> pure []
        Right mu -> pure (muTops mu)
      let dir = takeDirectory path
      targets <- forM [(a, spec) | TUse a spec <- tops] $ \(_, spec) -> do
        let (nm, h) = specPartsP spec
        p <- resolveScratch dir nm
        pure (spec, nm, h, p)
      -- dependencies first: a scratch dependency under this tree that this
      -- run may rewrite (unpinned, or pinned and selected for --update)
      let recurseInto (_, nm, h, p) = case p of
            Just q | pmDeps mode && local q && (null h || updating nm || pmUpdateAll mode || not (null (pmUpdateOnly mode))) -> Just q
            _ -> Nothing
      (visited', changed') <-
        foldM (\acc t -> maybe (pure acc) (pinFile mode cwd acc) (recurseInto t)) (path : visited, changed) targets
      -- then this file, from each dependency's CURRENT hash
      edits <- fmap concat $ forM targets $ \(spec, nm, h, p) -> case p of
        Nothing
          | null h -> hPutStrLn stderr ("pin: cannot resolve " ++ show spec ++ " from " ++ path) >> exitFailure >> pure []
          | otherwise -> pure []
        Just q -> do
          let cascaded = q `elem` changed'
          if not (null h) && not (updating nm || cascaded)
            then pure []
            else
              if pmDry mode && cascaded
                then pure [(spec, nm ++ "#<new hash>")]
                else do
                  r <- freshLoad q
                  case r of
                    Left e -> hPutStrLn stderr e >> exitFailure >> pure []
                    Right mu
                      | muHash mu == h -> pure []
                      | otherwise -> pure [(spec, nm ++ "#" ++ muHash mu)]
      if null edits
        then pure (visited', changed')
        else do
          shown <- makeRelativeToCurrentDirectory path
          mapM_ (\(old, new) -> putStrLn ("  " ++ shown ++ ": use \"" ++ old ++ "\" -> use \"" ++ new ++ "\"")) edits
          if pmDry mode
            then pure (visited', path : changed')
            else do
              let src' = foldl (\t (old, new) -> rewriteUse old new t) src edits
              writeFile path src'
              check <- freshLoad path
              case check of
                Right _ -> pure (visited', path : changed')
                Left e -> do
                  writeFile path src
                  hPutStrLn stderr ("pin: " ++ shown ++ " does not load once re-pinned; restored it:\n" ++ e)
                  exitFailure
                  pure (visited', changed')
  where
    updating nm = pmUpdateAll mode || nm `elem` pmUpdateOnly mode
    local q =
      let r = makeRelative cwd q
       in r /= q && take 1 (splitDirectories r) /= [".fpr"] && not (".." `isPrefixOf` r)
    freshLoad q = do
      cache <- newIORef M.empty
      loadModule cache [] q

-- The same lookup `use` makes for the SCRATCH file of a spec (Modules.loadDeps):
-- importer-relative first, then the toolchain home / FPR_PATH roots.
resolveScratch :: FilePath -> String -> IO (Maybe FilePath)
resolveScratch dir nm = do
  let f = if ".fpr" `isSuffixOf` nm then nm else nm ++ ".fpr"
      p0 = if take 1 f == "/" then f else dir </> f
  here <- doesFileExist p0
  if here
    then Just <$> canonicalizePath p0
    else
      if take 1 nm == "/"
        then pure Nothing
        else underHome f >>= maybe (pure Nothing) (fmap Just . canonicalizePath)

specPartsP :: String -> (String, String)
specPartsP spec = let (n, h) = break (== '#') spec in (n, drop 1 h)

-- Replace the string literal of `use "old"` (any blanks after `use`) by
-- `use "new"`; every other byte is kept.
rewriteUse :: String -> String -> String -> String
rewriteUse old new = go
  where
    lit = "\"" ++ old ++ "\""
    go [] = []
    go t@(c : rest)
      | "use" `isPrefixOf` t,
        (ws, after) <- span (`elem` " \t") (drop 3 t),
        lit `isPrefixOf` after =
          "use" ++ ws ++ "\"" ++ new ++ "\"" ++ go (drop (length lit) after)
      | otherwise = c : go rest

-- Free references to deprecated intMax/intMin in a module being committed.
-- Local bindings (e.g. a module defining its own `intMax`) shadow the builtin.
deprecatedIntBounds :: [STop] -> [String]
deprecatedIntBounds tops = nub (concatMap top tops)
  where
    defined = S.fromList [n | TBind n _ _ _ <- tops]
    top = \case
      TBind _ pats gs body ->
        let bound0 = foldl patNames defined pats
            (usedG, bound1) = foldl guardStep ([], bound0) gs
         in usedG ++ expr bound1 body
      TStruct _ _ fs -> concatMap (expr defined . snd) fs
      _ -> []
    guardStep (acc, b) = \case
      GBool e -> (acc ++ expr b e, b)
      GPat p e -> (acc ++ expr b e, patNames b p)
    patNames b = \case
      PVar n -> S.insert n b
      PCon _ ps -> foldl patNames b ps
      PTup ps -> foldl patNames b ps
      PRec fs -> foldr S.insert b fs
      PSig n _ -> S.insert n b
      _ -> b
    expr b = \case
      SMark _ e -> expr b e
      SVar n | n `elem` ["intMax", "intMin"], S.notMember n b -> [n]
      SStrI segs -> concat [expr b e | SegExpr e <- segs]
      SApp f a -> expr b f ++ expr b a
      SLam ps body -> expr (foldr S.insert b ps) body
      SBlock ss e -> let (u, b') = stmts b ss in u ++ expr b' e
      SCase s arms -> expr b s ++ concat [expr (patNames b p) e | (p, e) <- arms]
      SBin _ l r -> expr b l ++ expr b r
      SProj e _ -> expr b e
      SRec fs -> concatMap (expr b . snd) fs
      SUpd m as -> expr b m ++ concatMap (expr b . snd) as
      STup es -> concatMap (expr b) es
      SList es -> concatMap (expr b) es
      _ -> []
    stmts b [] = ([], b)
    stmts b (SBind n ps e : rest) =
      let inner = foldr S.insert (S.insert n b) ps
          (u, b') = stmts (S.insert n b) rest
       in (expr inner e ++ u, b')
    stmts b (SBindPat p e : rest) =
      let (u, b') = stmts (patNames b p) rest
       in (expr b e ++ u, b')

-- ---- push / pull: the pkgstore seam, wired -----------------------------
-- .fpr IS pkgstore one level down (docs/VERSIONING.md), so push is two
-- HTTP calls and pull is three.  The server's hash is sha256 over the
-- blob bytes; OUR identity is the AST pin hash — so pull re-derives the
-- pin hash by parsing the fetched source, and the store entry lands
-- under the name `use "x#<pin>"` actually resolves.  curl does the
-- transport (PKGSTORE_URL, default http://127.0.0.1:8323).

serverUrl :: IO String
serverUrl = fromMaybe "http://127.0.0.1:8323" <$> lookupEnv "PKGSTORE_URL"

curl :: [String] -> IO String
curl as = readProcess "curl" ("-s" : as) ""

-- crude but sufficient: pull "key":"value" pairs out of flat JSON
jstr :: String -> String -> Maybe String
jstr key s = case breakOn ("\"" ++ key ++ "\":") s of
  Nothing -> Nothing
  Just rest ->
    let v = drop 1 (dropWhile (/= '"') (drop (length key + 3) rest))
     in Just (takeWhile (/= '"') v)
  where
    breakOn pat str = go str
      where
        go [] = Nothing
        go t@(_ : r) = if pat `isPrefixOf` t then Just t else go r

pushMain :: [String] -> IO ()
pushMain args = do
  name <- case args of
    [n] -> pure n
    _ -> hPutStrLn stderr "usage: fpr push <name>   (pushes every committed version)" >> exitFailure >> pure ""
  srv <- serverUrl
  db <- readDb
  let mine = [(v, h) | (n, v, h) <- db, n == name]
  when (null mine) $ hPutStrLn stderr ("push: no committed versions of " ++ name) >> exitFailure
  mapM_
    ( \(v, h) -> do
        let blob = storeDir ++ "/" ++ h ++ ".fpr"
        up <- curl ["-X", "POST", "--data-binary", "@" ++ blob, srv ++ "/upload"]
        case jstr "hash" up of
          Nothing -> hPutStrLn stderr ("push: upload failed: " ++ up) >> exitFailure
          Just sh -> do
            r <- curl ["-X", "POST", "-H", "Content-Type: application/json",
                       "-d", "{\"hash\":\"" ++ sh ++ "\"}",
                       srv ++ "/index/" ++ name ++ "/" ++ v]
            putStrLn ("pushed " ++ name ++ "." ++ v ++ "  pin #" ++ h ++ "  blob " ++ take 18 sh ++ "…  " ++ (if "already" `isInfixOf` r then "(already registered)" else "ok"))
    )
    mine

pullMain :: [String] -> IO ()
pullMain args = do
  spec <- case args of
    [n] -> pure n
    _ -> hPutStrLn stderr "usage: fpr pull <name>[.vX.Y]" >> exitFailure >> pure ""
  srv <- serverUrl
  let (name, wantV) = case break (== '.') spec of
        (n, "") -> (n, Nothing)
        (n, '.' : v) -> (n, Just v)
        (n, _) -> (n, Nothing)
  idx <- curl [srv ++ "/index/" ++ name]
  vs <- case versionsOf idx of
    [] -> hPutStrLn stderr ("pull: no such package: " ++ name ++ " (" ++ take 80 idx ++ ")") >> exitFailure >> pure []
    xs -> pure xs
  let pick = case wantV of
        Nothing -> [last vs]
        Just v -> [p | p@(v', _) <- vs, v' == v]
  case pick of
    [] -> hPutStrLn stderr ("pull: version not found; available: " ++ show (map fst vs)) >> exitFailure
    ((v, sh) : _) -> do
      blob <- curl [srv ++ "/blob/" ++ sh]
      let tmp = ".fpr/pull.tmp.fpr"
      createDirectoryIfMissing True storeDir
      writeFile tmp blob
      cache <- newIORef M.empty
      r <- loadModule cache [] tmp
      case r of
        Left e -> hPutStrLn stderr ("pull: fetched blob does not load: " ++ e) >> exitFailure
        Right mu -> do
          let ph = muHash mu
          copyFile tmp (storeDir ++ "/" ++ ph ++ ".fpr")
          db <- readDb
          unless (any (\(n', v', h') -> n' == name && v' == v && h' == ph) db) $
            appendFile dbPath (name ++ " " ++ v ++ " " ++ ph ++ "\n")
          putStrLn ("pulled " ++ name ++ "." ++ v ++ " -> .fpr/store, pin it:  use \"" ++ name ++ "#" ++ ph ++ "\"")
  where
    -- the /index/{name} JSON: versions:[{version,hash,...},...] in order
    versionsOf s = go s
      where
        go t = case jstr "version" t of
          Nothing -> []
          Just v ->
            let rest = drop 1 (snd (break (== '}') t))
             in case jstr "hash" t of
                  Just h -> (v, h) : go rest
                  Nothing -> go rest

versionsMain :: [String] -> IO ()
versionsMain args = do
  db <- readDb
  let sel = case args of [n] -> [e | e@(n', _, _) <- db, n' == n]; _ -> db
  case sel of
    [] -> putStrLn "(no committed versions)"
    es -> mapM_ (\(n, v, h) -> putStrLn (n ++ "." ++ v ++ "  use \"" ++ n ++ "#" ++ h ++ "\"")) es
