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
--                              sig; additions are fine)
--   otherwise               -> MAJOR, refused without --major
-- The subset check is the commit-time face of the row-compatibility
-- question: a minor/patch version is safe to LiveReload into by
-- construction; only major versions carry compatibility risk.
--
-- .fpr/versions.db is structurally pkgstore's model (content blobs +
-- append-only name/version->hash bindings): `fpr push` to a pkgstore
-- is blob upload + binding registration, nothing more.
module Commit (commitMain, versionsMain, pushMain, pullMain) where

import Control.Monad (unless, when)
import qualified Data.IORef
import Data.IORef (newIORef, readIORef)
import Data.List (intercalate, isInfixOf, isPrefixOf, sort)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import FPRISC
import Modules (ModUnit (..), loadModule)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist)
import System.Exit (exitFailure)
import System.FilePath (takeBaseName)
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
sigOf tops =
  sort $
    [ "fn " ++ n ++ "/" ++ show (length ps) | TBind n ps _ _ <- tops ]
      ++ [ "sig " ++ n ++ " : " ++ show (ps, r) | TSig n (ps, r) _ <- tops ]
      ++ [ "type " ++ n ++ " " ++ show cs | TType n _ _ cs <- tops ]

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
    _ -> hPutStrLn stderr "usage: fpr commit <module.fpr> [--major]" >> exitFailure >> pure ""
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
    exitFailure
  createDirectoryIfMissing True storeDir
  mapM_
    (\(p, m) -> when (p /= file) $ copyFile p (storeDir ++ "/" ++ muHash m ++ ".fpr"))
    closure
  let name = takeBaseName file
      h = muHash mu
      newSig = sigOf (muTops mu)
  db <- readDb
  let mine = [(v, hh) | (n, v, hh) <- db, n == name]
  case reverse mine of
    [] -> do
      writeVersion name "v1.0" h file
      putStrLn ("committed " ++ name ++ ".v1.0#" ++ h ++ "  (first version)")
    ((pv, ph) : _)
      | ph == h ->
          putStrLn (name ++ "." ++ pv ++ "#" ++ h ++ " is already this exact content — no-op")
      | otherwise -> do
          oldTops <- storeTops ph
          let oldSig = sigOf oldTops
              compatible = oldSig `subsetOf` newSig
          if compatible
            then do
              let v = bump False pv
              writeVersion name v h file
              putStrLn ("committed " ++ name ++ "." ++ v ++ "#" ++ h ++ "  (patch: signature-compatible with " ++ pv ++ ")")
            else do
              let missing = [s | s <- oldSig, s `notElem` newSig]
              mapM_ (\s -> putStrLn ("  incompatible: " ++ pv ++ " exported `" ++ s ++ "`, this version does not")) missing
              unless major $ do
                hPutStrLn stderr ("commit refused: not a compatible subset of " ++ pv ++ " — re-run with --major to mint " ++ bump True pv)
                exitFailure
              let v = bump True pv
              writeVersion name v h file
              putStrLn ("committed " ++ name ++ "." ++ v ++ "#" ++ h ++ "  (MAJOR: breaks " ++ pv ++ "'s signature)")
  where
    writeVersion name v h file = do
      createDirectoryIfMissing True storeDir
      copyFile file (storeDir ++ "/" ++ h ++ ".fpr")
      appendFile' dbPath (name ++ " " ++ v ++ " " ++ h ++ "\n")
    appendFile' p s = do
      createDirectoryIfMissing True ".fpr"
      appendFile p s
    storeTops h = do
      let p = storeDir ++ "/" ++ h ++ ".fpr"
      ok <- doesFileExist p
      when (not ok) $ hPutStrLn stderr ("warning: prior version's blob missing from store: " ++ p)
      if not ok
        then pure []
        else do
          cache <- newIORef M.empty
          r <- loadModule cache [] p
          pure (either (const []) muTops r)

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
