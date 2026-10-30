-- Project.hs -- FP-RISC projects: the fpr.toml manifest and the commands
-- that work inside a project (docs/2026-10-31-PROJECT-WORKFLOW.md).
--
--   fpr new NAME [--template=cli|service|sol]   scaffold a project
--   fpr check [FILE...]                         check every module (no `main` needed)
--   fpr build [--release] [flags]               build the entry point into build/
--   fpr run [flags] [-- args]                   build and run it (Sol: on the VM)
--   fpr test [-v] [FILE...]                     run the programs in tests/
--   fpr doctor                                  report toolchain, C tools, SDK, caches
--
-- A project is the directory holding fpr.toml, found by walking up from
-- the current directory.  The name is not QOS's qos.toml, and the walk
-- stops at a qos.toml: neither tool picks up the other's project.  An
-- explicit file (`fpr build prog.fpr`, `fpr run prog.fpr`, `fpr sol x.sol`)
-- never consults a manifest; Main sends build/run here only when they are
-- given no file (projectMode).
module Project
  ( Kind (..), Manifest (..), Template (..),
    manifestFile, parseManifest, renderManifest, compatible, parseVersion,
    projectMode, templateFiles,
    newMain, checkMain, buildMain, runMain, testMain, doctorMain
  ) where

import Control.Exception (SomeException, try)
import Control.Monad (forM, forM_, unless, when)
import Data.Char (isAlphaNum, isDigit, isHexDigit, isLower, isSpace)
import Data.List (intercalate, isPrefixOf, isSuffixOf, sort)
import Data.Maybe (fromMaybe, isJust)
import qualified Build
import qualified Compile
import qualified Compiler.Options as Options
import Frontend.Syntax (STop (..))
import Frontend.Traverse (stripPosTops)
import Home (fprHome)
import qualified Data.IORef
import qualified Data.Map.Strict as M
import qualified Sol.Cache
import qualified Sol.Txn
import System.Directory
  ( XdgDirectory (..), canonicalizePath, createDirectoryIfMissing, doesDirectoryExist, doesFileExist,
    findExecutable, getCurrentDirectory, getHomeDirectory, getXdgDirectory, listDirectory, makeAbsolute,
    setCurrentDirectory )
import System.Environment (getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (isRelative, joinPath, makeRelative, normalise, splitDirectories, takeDirectory, takeExtension, takeFileName, (</>))
import System.IO (hFlush, hPutStrLn, stderr, stdout)
import qualified System.Info
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode, readProcessWithExitCode)
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Numeric (showFFloat)

-- ---- the manifest ---------------------------------------------------------

manifestFile :: FilePath
manifestFile = "fpr.toml"

-- the one format this toolchain reads; a newer one is refused, not guessed at
manifestFormat :: Int
manifestFormat = 1

data Kind = Cli | Service | SolScript deriving (Eq, Show)

data Manifest = Manifest
  { mFormat :: Int,
    mName :: String,
    mVersion :: String, -- the application's own version
    mKind :: Kind,
    mEntry :: FilePath, -- relative to the project root
    mToolchain :: String, -- the oldest compatible fpr (same series: see `compatible`)
    mTarget :: String, -- "host", or a Build --target name
    mDeps :: [(String, String)] -- name, "vX.Y#hash": a committed version (fpr commit / fpr pull)
  }
  deriving (Eq, Show)

kindName :: Kind -> String
kindName k = case k of Cli -> "cli"; Service -> "service"; SolScript -> "sol"

-- the targets `fpr build --target=` names (Build.plan), plus this machine
targets :: [String]
targets = ["host", "linux-aarch64", "linux-x86_64", "linux-riscv64", "macos-x86_64"]

-- A TOML subset: comments, [section] headers, and `key = value` where a value
-- is a "string", an integer, true/false, or a one-line ["string", ...] array.
-- Every key is known; an unknown one is an error with its line, so a typo or
-- a section from a newer toolchain is never silently ignored.
data Value = VStr String | VInt Int | VBool Bool | VList [String] deriving (Eq, Show)

parseToml :: String -> Either String [((String, String), (Int, Value))]
parseToml text = go "" (zip [1 ..] (lines text)) []
  where
    go _ [] acc = Right (reverse acc)
    go sec ((n, raw) : rest) acc =
      let l = trim (stripComment raw)
       in if null l then go sec rest acc
          else if "[" `isPrefixOf` l then
            if "]" `isSuffixOf` l && length l > 2 && all keyChar (trim (init (drop 1 l)))
              then go (trim (init (drop 1 l))) rest acc
              else Left (at n "a section header is [name]")
          else case break (== '=') l of
            (k, '=' : v) | k' <- trim k, not (null k'), all keyChar k' ->
              case value (trim v) of
                Right x
                  | any ((== (sec, k')) . fst) acc -> Left (at n ("`" ++ k' ++ "` is given twice"))
                  | otherwise -> go sec rest (((sec, k'), (n, x)) : acc)
                Left why -> Left (at n why)
            _ -> Left (at n "expected `key = value`")
    at n why = manifestFile ++ ":" ++ show (n :: Int) ++ ": " ++ why
    keyChar c = isAlphaNum c || c == '_' || c == '-'
    value v
      | "\"" `isPrefixOf` v = case str (drop 1 v) of
          Right (s, "") -> Right (VStr s)
          Right _ -> Left "text after a string"
          Left why -> Left why
      | v == "true" = Right (VBool True)
      | v == "false" = Right (VBool False)
      | not (null v), all isDigit v = Right (VInt (read v))
      | "[" `isPrefixOf` v, "]" `isSuffixOf` v = VList <$> items (trim (init (drop 1 v)))
      | otherwise = Left ("not a value: " ++ v ++ " (strings are quoted)")
    items s
      | null s = Right []
      | otherwise = case s of
          '"' : r -> do
            (x, after) <- str r
            case trim after of
              "" -> Right [x]
              ',' : more -> (x :) <$> items (trim more)
              _ -> Left "array items are separated by commas"
          _ -> Left "array items are quoted strings"
    -- a basic string: \" \\ \n \t escapes
    str s = case s of
      [] -> Left "unterminated string"
      '"' : r -> Right ("", r)
      '\\' : c : r -> do
        e <- case c of '"' -> Right '"'; '\\' -> Right '\\'; 'n' -> Right '\n'; 't' -> Right '\t'; _ -> Left ("unknown escape \\" ++ [c])
        (x, after) <- str r
        Right (e : x, after)
      c : r -> do
        (x, after) <- str r
        Right (c : x, after)
    stripComment = scan False
      where
        scan _ [] = []
        scan q ('\\' : c : r) | q = '\\' : c : scan q r
        scan q ('"' : r) = '"' : scan (not q) r
        scan False ('#' : _) = []
        scan q (c : r) = c : scan q r

trim :: String -> String
trim = f . f where f = reverse . dropWhile isSpace

parseManifest :: String -> Either String Manifest
parseManifest text = do
  kvs <- parseToml text
  let known =
        [("", "manifest"), ("project", "name"), ("project", "version"), ("project", "kind"), ("project", "entry"),
         ("toolchain", "fpr"), ("target", "name")]
      line k = maybe "" (\(n, _) -> manifestFile ++ ":" ++ show n ++ ": ") (lookup k kvs)
  forM_ kvs $ \((sec, k), (n, _)) ->
    unless ((sec, k) `elem` known || sec == "dependencies") $
      Left (manifestFile ++ ":" ++ show n ++ ": unknown " ++ (if null sec then "key `" ++ k ++ "`" else "key `" ++ k ++ "` in [" ++ sec ++ "]")
            ++ " (this fpr reads manifest format " ++ show manifestFormat ++ "; a newer toolchain may know it)")
  format <- case lookup ("", "manifest") kvs of
    Just (_, VInt v) -> Right v
    Just _ -> Left (line ("", "manifest") ++ "`manifest` is the format number, an integer")
    Nothing -> Left (manifestFile ++ ": no `manifest = " ++ show manifestFormat ++ "` line (the format version)")
  when (format /= manifestFormat) $
    Left (line ("", "manifest") ++ "manifest format " ++ show format ++ " is not one this fpr reads (it reads " ++ show manifestFormat ++ ")")
  let need k = case lookup k kvs of
        Just (_, VStr s) -> Right s
        Just _ -> Left (line k ++ "`" ++ snd k ++ "` is a quoted string")
        Nothing -> Left (manifestFile ++ ": [" ++ fst k ++ "] has no `" ++ snd k ++ "`")
      opt k d = case lookup k kvs of Nothing -> Right d; _ -> need k
  name <- need ("project", "name")
  unless (validName name) $
    Left (line ("project", "name") ++ "a project name is lower-case letters, digits, - and _, starting with a letter")
  version <- need ("project", "version")
  unless (not (null version) && all (\c -> isAlphaNum c || c `elem` ".+-") version) $
    Left (line ("project", "version") ++ "a version is letters, digits and . + - (for example 0.1.0)")
  kindS <- need ("project", "kind")
  kind <- case kindS of
    "cli" -> Right Cli
    "service" -> Right Service
    "sol" -> Right SolScript
    _ -> Left (line ("project", "kind") ++ "kind is cli, service or sol")
  entry <- need ("project", "entry")
  let want = if kind == SolScript then ".sol" else ".fpr"
  unless (isRelative entry && ".." `notElem` splitDirectories entry && takeExtension entry == want) $
    Left (line ("project", "entry") ++ "the entry is a " ++ want ++ " file inside the project (a relative path)")
  tool <- need ("toolchain", "fpr")
  unless (isJust (parseVersion tool)) $
    Left (line ("toolchain", "fpr") ++ "the toolchain is a version, for example 0.12.0")
  target <- opt ("target", "name") "host"
  unless (target `elem` targets) $
    Left (line ("target", "name") ++ "target is one of " ++ intercalate ", " targets)
  when (kind == SolScript && target /= "host") $
    Left (line ("target", "name") ++ "a sol project runs on this machine's VM: target is host")
  deps <- forM [(k, v) | (("dependencies", k), v) <- kvs] $ \(k, (n, v)) -> case v of
    VStr s | validDep s -> Right (k, s)
    _ -> Left (manifestFile ++ ":" ++ show n ++ ": a dependency is \"vX.Y#HASH\", a committed version (fpr versions NAME)")
  Right (Manifest format name version kind entry tool target deps)

validName :: String -> Bool
validName n = case n of
  c : r -> isLower c && all (\x -> isLower x || isDigit x || x == '-' || x == '_') r
  [] -> False

validDep :: String -> Bool
validDep s = case break (== '#') s of
  ('v' : v, '#' : h) -> isJust (parseVersion v) && length h >= 8 && all isHexDigit h
  _ -> False

renderManifest :: Manifest -> String
renderManifest m =
  unlines $
    [ "# " ++ manifestFile ++ " -- an FP-RISC project (docs/2026-10-31-PROJECT-WORKFLOW.md in the fprisc repo)",
      "manifest = " ++ show (mFormat m),
      "",
      "[project]",
      "name = " ++ q (mName m),
      "version = " ++ q (mVersion m),
      note ("kind = " ++ q (kindName (mKind m))) "cli | service | sol",
      "entry = " ++ q (mEntry m),
      "",
      "[toolchain]",
      note ("fpr = " ++ q (mToolchain m)) "this fpr or a later compatible one",
      "",
      "[target]",
      note ("name = " ++ q (mTarget m)) (intercalate " | " targets),
      "",
      "[dependencies]",
      "# name = \"vX.Y#HASH\"     a committed version: fpr commit, fpr versions, fpr pull"
    ]
      ++ [k ++ " = " ++ q v | (k, v) <- mDeps m]
  where
    q s = show s
    note l n = l ++ replicate (max 1 (24 - length l)) ' ' ++ "# " ++ n

-- "0.12.0" -> [0,12,0]
parseVersion :: String -> Maybe [Int]
parseVersion s = case splitOn '.' s of
  parts | not (null parts), length parts <= 3, all (\p -> not (null p) && all isDigit p) parts -> Just (map read parts)
  _ -> Nothing
  where
    splitOn c t = case break (== c) t of
      (a, _ : b) -> a : splitOn c b
      (a, []) -> [a]

-- `running` satisfies a manifest asking for `wanted` when it is the same
-- release series (major.minor while the major is 0, else the major) and
-- not older.  Either side unparsable is incompatible.
compatible :: String -> String -> Bool
compatible running wanted = case (parseVersion running, parseVersion wanted) of
  (Just r, Just w) ->
    let pad v = take 3 (v ++ repeat 0)
        (r', w') = (pad r, pad w)
        series v = if take 1 v == [0] then take 2 v else take 1 v
     in series r' == series w' && r' >= w'
  _ -> False

-- ---- finding the project --------------------------------------------------

data Project = Project {pRoot :: FilePath, pManifest :: Manifest}

-- walk up from `dir`: the first fpr.toml is the project; a qos.toml met
-- first is QOS's project, which this tool does not build
discover :: FilePath -> IO (Either String FilePath)
discover dir0 = canonicalizePath dir0 >>= go
  where
    go dir = do
      own <- doesFileExist (dir </> manifestFile)
      qos <- doesFileExist (dir </> "qos.toml")
      if own then pure (Right dir)
      else if qos then pure (Left ("this is a QOS project (" ++ (dir </> "qos.toml") ++ "): build it with `qos build`; fpr projects have an " ++ manifestFile))
      else if takeDirectory dir == dir then pure (Left ("no " ++ manifestFile ++ " here or in a parent directory: give a file (fpr build prog.fpr) or make a project (fpr new NAME)"))
      else go (takeDirectory dir)

-- the project around the current directory, its manifest read, checked
-- against this toolchain; any problem ends the command with status 2
loadProject :: String -> String -> IO Project
loadProject version cmd = do
  here <- getCurrentDirectory
  found <- discover here
  root <- either (usageError cmd) pure found
  text <- readFile (root </> manifestFile)
  m <- either (\why -> usageError cmd (root </> why)) pure (parseManifest text)
  unless (compatible version (mToolchain m)) $
    usageError cmd (root </> manifestFile ++ ": the project asks for fpr " ++ mToolchain m ++ " (a compatible release); this is fpr " ++ version)
  pure (Project root m)

usageError :: String -> String -> IO a
usageError cmd why = hPutStrLn stderr ("fpr " ++ cmd ++ ": " ++ why) >> exitWith (ExitFailure 2)

-- Is this build/run meant for the project?  Only when no file is named: the
-- first positional argument (skipping flags and their values, before `--`)
-- is the explicit file of the existing commands, which stay unchanged.
projectMode :: [String] -> Bool
projectMode args = "--target=qos-portable" `notElem` args && go args
  where
    go [] = True
    go ("--" : _) = True
    go (a : _ : rest) | a `elem` valued = go rest
    go (a : rest) | "-" `isPrefixOf` a = go rest
    go _ = False

-- Build.plan's flags that take the next argument as their value
valued :: [String]
valued = ["-o", "--harts", "--cc", "--with", "--cflag", "--link", "--port"]

-- ---- fpr new --------------------------------------------------------------

data Template = TCli | TService | TSol deriving (Eq, Show)

newMain :: String -> [String] -> IO ()
newMain version args = do
  (template, path) <- case parseNew TCli Nothing args of
    Right (t, Just p) -> pure (t, p)
    Right (_, Nothing) -> usageError "new" newUsage
    Left why -> usageError "new" (why ++ "\n" ++ newUsage)
  let name = takeFileName (normalise path)
  unless (validName name) $ usageError "new" ("`" ++ name ++ "`: a project name is lower-case letters, digits, - and _, starting with a letter")
  exists <- doesDirectoryExist path
  when exists $ do
    entries <- listDirectory path
    unless (null entries) $ usageError "new" (path ++ " already exists and is not empty")
  isFile <- doesFileExist path
  when isFile $ usageError "new" (path ++ " is a file")
  forM_ (templateFiles version template name) $ \(rel, body) -> do
    let f = path </> rel
    createDirectoryIfMissing True (takeDirectory f)
    writeFile f body
  putStrLn ("created " ++ name ++ " (" ++ templateName template ++ ") in " ++ path)
  putStrLn ("  cd " ++ path ++ " && fpr check && fpr test && fpr run")
  where
    parseNew t p as = case as of
      [] -> Right (t, p)
      a : rest
        | "--template=" `isPrefixOf` a -> case drop (length "--template=") a of
            "cli" -> parseNew TCli p rest
            "service" -> parseNew TService p rest
            "sol" -> parseNew TSol p rest
            other -> Left ("unknown template `" ++ other ++ "`")
        | "-" `isPrefixOf` a -> Left ("unknown option " ++ a)
        | Nothing <- p -> parseNew t (Just a) rest
        | otherwise -> Left "one project at a time"

newUsage :: String
newUsage = "usage: fpr new NAME [--template=cli|service|sol]   (NAME may be a path; its last part names the project)"

templateName :: Template -> String
templateName t = case t of TCli -> "cli"; TService -> "service"; TSol -> "sol"

-- every file a template writes, relative to the new project's root
templateFiles :: String -> Template -> String -> [(FilePath, String)]
templateFiles version template name =
  [ (manifestFile, renderManifest manifest),
    (".gitignore", "build/\n")
  ]
    ++ body
  where
    manifest =
      Manifest manifestFormat name "0.1.0" kind entry version "host" []
    (kind, entry) = case template of
      TCli -> (Cli, "src/main.fpr")
      TService -> (Service, "src/main.fpr")
      TSol -> (SolScript, "src/main.sol")
    body = case template of
      TCli ->
        [ ( "src/main.fpr",
            unlines
              [ "# main.fpr -- " ++ name ++ "'s entry point (" ++ manifestFile ++ ": entry).",
                "#   fpr run              prints a greeting",
                "#   fpr run -- Ada       greets Ada",
                "profile base.",
                "",
                "Program = use \"std/program\".",
                "Greeting = use \"greeting\".",
                "",
                "main = case Program.args Unit of",
                "    who :: _ -> print (Greeting.greet who)",
                "  | Nil -> print (Greeting.greet \"world\")."
              ]
          ),
          ( "src/greeting.fpr",
            unlines
              [ "# greeting.fpr -- a module: no `main`; `fpr check` checks it on its own.",
                "",
                "greet : String -> String .",
                "greet who = \"hello, {who}\"."
              ]
          ),
          ( "tests/greeting.fpr",
            unlines
              [ "# A test is a program in tests/: exit status 0 passes (fpr test).",
                "Greeting = use \"../src/greeting\".",
                "Test = use \"std/test\".",
                "",
                "main = Test.run (",
                "     Test.equalString \"greets by name\" \"hello, Ada\" (Greeting.greet \"Ada\")",
                "  :: Test.that \"keeps an empty name\" (Greeting.greet \"\" == \"hello, \")",
                "  :: Nil)."
              ]
          )
        ]
      TService ->
        [ ( "src/main.fpr",
            unlines
              [ "# main.fpr -- " ++ name ++ ", an HTTP service on 127.0.0.1 (" ++ manifestFile ++ ": entry).",
                "#   fpr run              listens on port 8080",
                "#   fpr run -- 9000      listens on port 9000 (0 picks a free port)",
                "#   curl localhost:8080/health",
                "# It runs until it is stopped (Ctrl-C, or SIGTERM from a supervisor).",
                "unsafe base.",
                "",
                "Http = use \"std/http\".",
                "Tcp = use \"std/tcp\".",
                "Program = use \"std/program\".",
                "String = use \"std/string\".",
                "Routes = use \"routes\".",
                "",
                "portOf : List String -> Int .",
                "portOf args = case args of",
                "    p :: _ -> (case String.toInt p of Ok n -> n | Err _ -> 8080)",
                "  | Nil -> 8080.",
                "",
                "main = case Tcp.listen \"127.0.0.1\" (portOf (Program.args Unit)) of",
                "    Err why -> Program.fail 1 \"" ++ name ++ ": cannot listen: {why}\"",
                "  | Ok listener ->",
                "      _ = print \"" ++ name ++ " listening on 127.0.0.1:{Tcp.port listener}\";",
                "      why = Http.serve listener Routes.handle;",
                "      Program.fail 1 \"" ++ name ++ ": stopped: {why}\"."
              ]
          ),
          ( "src/routes.fpr",
            unlines
              [ "# routes.fpr -- what the service answers.  A request in, a response out,",
                "# so tests/routes.fpr checks it without opening a socket.",
                "Http = use \"std/http\".",
                "",
                "handle : { method : String, path : String, query : String, headers : List (String, String), body : String } -> { status : Int, headers : List (String, String), body : String } .",
                "handle req = case req.path of",
                "    \"/health\" -> Http.text 200 \"ok\\n\"",
                "  | \"/\" -> Http.text 200 \"hello from " ++ name ++ "\\n\"",
                "  | _ -> Http.text 404 \"no such page: {req.path}\\n\"."
              ]
          ),
          ( "tests/routes.fpr",
            unlines
              [ "# A test is a program in tests/: exit status 0 passes (fpr test).",
                "Routes = use \"../src/routes\".",
                "Test = use \"std/test\".",
                "",
                "get path = Routes.handle { method = \"GET\", path = path, query = \"\", headers = Nil, body = \"\" }.",
                "",
                "health = get \"/health\".",
                "missing = get \"/missing\".",
                "",
                "main = Test.run (",
                "     Test.equalInt \"health answers 200\" 200 health.status",
                "  :: Test.equalString \"health says ok\" \"ok\\n\" health.body",
                "  :: Test.equalInt \"an unknown path is 404\" 404 missing.status",
                "  :: Nil)."
              ]
          )
        ]
      TSol ->
        [ ( "src/main.sol",
            unlines
              [ "# main.sol -- " ++ name ++ "'s entry point (" ++ manifestFile ++ ": entry).",
                "# `fpr run` runs it on the Sol VM; no C toolchain is needed.",
                "W = use \"words\".",
                "",
                "> print (W.shout \"hello from " ++ name ++ "\")."
              ]
          ),
          ( "src/words.sol",
            unlines
              [ "# words.sol -- a module: definitions only; `fpr check` checks it on its own.",
                "shout s = \"{s}!\"."
              ]
          ),
          ( "tests/words.sol",
            unlines
              [ "# A test is a script in tests/: exit status 0 passes (fpr test).",
                "W = use \"../src/words\".",
                "T = use \"sol/lib/test\".",
                "",
                "> T.run [T.equal \"shout adds a bang\" \"hi!\" (W.shout \"hi\"),",
                "         T.that \"an empty shout\" (W.shout \"\" == \"!\")]."
              ]
          )
        ]

-- ---- fpr check ------------------------------------------------------------

-- The project's sources: the entry, then every .fpr/.sol under src/ and tests/.
sources :: Project -> IO [FilePath]
sources p = do
  found <- fmap concat (mapM (filesUnder (pRoot p)) ["src", "tests"])
  let entry = normalise (mEntry (pManifest p))
  pure (entry : filter (/= entry) found)

filesUnder :: FilePath -> FilePath -> IO [FilePath]
filesUnder root rel = do
  let dir = root </> rel
  e <- doesDirectoryExist dir
  if not e then pure [] else do
    names <- sort <$> listDirectory dir
    fmap concat $ forM names $ \n -> do
      let r = rel </> n
      isDir <- doesDirectoryExist (root </> r)
      if isDir then filesUnder root r
      else pure [r | takeExtension n `elem` [".fpr", ".sol"]]

-- the tests: programs directly in tests/; its subdirectories hold helpers
filesIn :: FilePath -> FilePath -> IO [FilePath]
filesIn root rel = do
  e <- doesDirectoryExist (root </> rel)
  if not e then pure [] else do
    names <- sort <$> listDirectory (root </> rel)
    fmap concat $ forM names $ \n -> do
      isFile <- doesFileExist (root </> rel </> n)
      pure [rel </> n | isFile, takeExtension n `elem` [".fpr", ".sol"]]

-- One file through the normal checker, no code generated: a .fpr module with
-- `fpr compile --check-only` (which needs no `main`), a .sol one with the Sol
-- compiler (`sol --asm`, its listing discarded).  Diagnostics come back as text.
checkFile :: FilePath -> IO (Either String ())
checkFile f = do
  self <- getExecutablePath
  home <- fprHome
  let command
        | takeExtension f == ".sol" = [ "sol", "--asm", f ]
        | otherwise = ["compile", "--system=posix", "--check-only", "--prelude=" ++ (home </> "core" </> "prelude.fpr"), f, "/dev/null"]
  r <- try (readProcessWithExitCode self command "") :: IO (Either SomeException (ExitCode, String, String))
  pure $ case r of
    Left why -> Left (show why)
    Right (ExitSuccess, _, _) -> Right ()
    Right (_, out, err)
      | takeExtension f == ".sol" -> Left (trim err)
      | otherwise ->
          -- the compiler reports refusals on stdout among its progress lines
          let ls = lines out
              said = dropWhile (not . Build.isDiagnostic) ls
           in Left (trim (unlines ((if null said then ls else said) ++ lines err)))

checkMain :: String -> [String] -> IO ()
checkMain version args = do
  case [a | a <- args, "-" `isPrefixOf` a] of
    [] -> pure ()
    a : _ -> usageError "check" ("unknown option " ++ a ++ "\nusage: fpr check [FILE...]   (no FILE: the project's entry, src/ and tests/)")
  if not (null args)
    then do
      results <- mapM (\f -> (,) f <$> checkFile f) args
      finish (length args) [(f, why) | (f, Left why) <- results]
    else do
      p <- loadProject version "check"
      setCurrentDirectory (pRoot p)
      let m = pManifest p
      entryExists <- doesFileExist (mEntry m)
      unless entryExists $ usageError "check" (manifestFile ++ ": the entry " ++ mEntry m ++ " does not exist")
      files <- sources p
      results <- checkInOrder files
      entryProblems <- entryHasMain m [f | (f, Right ()) <- results]
      depProblems <- dependencyProblems p
      finish (length files) ([(f, why) | (f, Left why) <- results] ++ entryProblems ++ depProblems)
  where
    finish n failed = do
      forM_ failed $ \(f, why) -> hPutStrLn stderr ("fpr check: " ++ f ++ "\n" ++ indent why)
      if null failed
        then putStrLn ("fpr check: " ++ plural n "file" ++ " ok")
        else do
          let skipped = length [() | (_, why) <- failed, "not checked:" `isPrefixOf` why]
          hPutStrLn stderr ("fpr check: " ++ plural (length failed - skipped) "problem" ++ (if skipped > 0 then ", " ++ show skipped ++ " not checked" else "") ++ " (" ++ plural n "file" ++ ")")
          exitWith (ExitFailure 1)

-- Check imports before importers: a file importing a project file that
-- failed is not checked again (its diagnostics would be the import's, once
-- per importer), it is reported as depending on that failure.
checkInOrder :: [FilePath] -> IO [(FilePath, Either String ())]
checkInOrder files = do
  deps <- forM files $ \f -> (,) f <$> localImports files f
  done <- Data.IORef.newIORef M.empty
  let visit seen f = do
        have <- M.lookup f <$> Data.IORef.readIORef done
        case have of
          Just r -> pure r
          Nothing -> do
            let mine = [d | d <- fromMaybe [] (lookup f deps), d `notElem` seen]
            rs <- mapM (\d -> (,) d <$> visit (f : seen) d) mine
            r <- case [d | (d, Left _) <- rs] of
              [] -> checkFile f
              bad -> pure (Left ("not checked: it imports " ++ intercalate ", " bad ++ ", which failed"))
            Data.IORef.modifyIORef' done (M.insert f r)
            pure r
  mapM (\f -> (,) f <$> visit [] f) files

-- the project files a file `use`s, resolved beside it as the compilers do
localImports :: [FilePath] -> FilePath -> IO [FilePath]
localImports files f = do
  text <- readFile f
  let names = [takeWhile (/= '"') r | l <- lines text, take 1 (trim l) /= "#", Just r <- [after "use \"" l]]
  pure [c | n <- names, let base = collapse (takeDirectory f </> takeWhile (/= '#') n),
            c <- take 1 [x | x <- [base, base ++ takeExtension f], x `elem` files]]
  where
    -- "tests/../src/x" is "src/x" (normalise keeps the ..)
    collapse = joinPath . reverse . foldl step [] . splitDirectories
    step acc "." = acc
    step (a : acc) ".." | a /= ".." = acc
    step acc d = d : acc
    after pat l
      | null l = Nothing
      | pat `isPrefixOf` l = Just (drop (length pat) l)
      | otherwise = after pat (drop 1 l)

-- A module needs no `main`; the native entry point is the one file that does.
entryHasMain :: Manifest -> [FilePath] -> IO [(FilePath, String)]
entryHasMain m checked
  | mKind m == SolScript || mEntry m `notElem` checked = pure []
  | otherwise = do
      tops <- stripPosTops <$> Compile.parseFile (mEntry m)
      pure [(mEntry m, "the entry point has no `main` (a program starts at main)") | null [() | TBind "main" _ _ _ <- tops]]

-- Each [dependencies] identity must be present in the project's store: the
-- source blob .fpr/store/HASH.fpr, and, where .fpr/versions.db binds the
-- name and version, that same hash.
dependencyProblems :: Project -> IO [(FilePath, String)]
dependencyProblems p = fmap concat $ forM (mDeps (pManifest p)) $ \(name, ident) -> do
  let (v, h) = fmap (drop 1) (break (== '#') ident)
      blob = ".fpr" </> "store" </> (h ++ ".fpr")
  have <- doesFileExist blob
  dbOk <- doesFileExist (".fpr" </> "versions.db")
  bindings <- if dbOk then map words . lines <$> readFile (".fpr" </> "versions.db") else pure []
  let clash = [h' | [n', v', h'] <- bindings, n' == name, v' == v, h' /= h]
  pure $
    [(manifestFile, "dependency " ++ name ++ " " ++ ident ++ ": no " ++ blob ++ " (fpr pull " ++ name ++ "." ++ v ++ ")") | not have]
      ++ [(manifestFile, "dependency " ++ name ++ " " ++ ident ++ ": .fpr/versions.db binds " ++ name ++ "." ++ v ++ " to " ++ c) | c <- take 1 clash]

-- ---- fpr build / fpr run in a project ----------------------------------------

buildMain :: String -> [String] -> IO ()
buildMain version args = do
  p <- loadProject version "build"
  let m = pManifest p
  when (mKind m == SolScript) $
    usageError "build" "a sol project runs on the VM and is not built into an executable: `fpr check` checks it, `fpr run` runs it"
  let release = "--release" `elem` args
      out = pRoot p </> "build" </> (if release then "release" else "") </> mName m
  flags <- absoluteFlags args
  setCurrentDirectory (pRoot p)
  createDirectoryIfMissing True (takeDirectory out)
  Build.buildMain ([mEntry m, "-o", out] ++ targetFlag m flags ++ flags)

runMain :: String -> [String] -> IO ()
runMain version args = do
  p <- loadProject version "run"
  let m = pManifest p
      (flags, rest) = break (== "--") args
  when (mTarget m /= "host" && not (any ("--target=" `isPrefixOf`) flags)) $
    usageError "run" ("the project targets " ++ mTarget m ++ ", which does not run here: `fpr build` builds it")
  -- the program keeps the caller's working directory; only its file is the project's
  Build.runMain (flags ++ [pRoot p </> mEntry m] ++ drop 1 rest)

-- the manifest's target unless the command line names one
targetFlag :: Manifest -> [String] -> [String]
targetFlag m flags
  | mTarget m == "host" || any ("--target=" `isPrefixOf`) flags = []
  | otherwise = ["--target=" ++ mTarget m]

-- paths given to the build are the caller's; the build itself runs in the root
absoluteFlags :: [String] -> IO [String]
absoluteFlags as = case as of
  f : v : rest | f `elem` ["-o", "--with"] -> do
    v' <- makeAbsolute v
    ((f : [v']) ++) <$> absoluteFlags rest
  f : v : rest | f `elem` valued -> ([f, v] ++) <$> absoluteFlags rest
  a : rest -> (a :) <$> absoluteFlags rest
  [] -> pure []

-- ---- fpr test -------------------------------------------------------------

-- A test is a program under tests/: a .fpr program built and run like
-- `fpr run`, or a .sol script run on the VM.  It passes when it exits 0;
-- anything else (a non-zero status, a trap, a refusal by the checker) fails
-- it.  Tests run one at a time, in the project root, in name order; only
-- files directly in tests/ are tests, so a subdirectory can hold helpers.
testMain :: String -> [String] -> IO ()
testMain version args = do
  let verbose = "-v" `elem` args
      named = filter (/= "-v") args
  case [a | a <- named, "-" `isPrefixOf` a] of
    [] -> pure ()
    a : _ -> usageError "test" ("unknown option " ++ a ++ "\nusage: fpr test [-v] [FILE...]   (no FILE: every .fpr and .sol under tests/)")
  files <-
    if not (null named) then pure named else do
      p <- loadProject version "test"
      setCurrentDirectory (pRoot p)
      filesIn (pRoot p) "tests"
  when (null files) $ do
    putStrLn "fpr test: no tests (a test is a .fpr or .sol program under tests/)"
    exitWith ExitSuccess
  self <- getExecutablePath
  results <- forM files $ \f -> do
    let command = if takeExtension f == ".sol" then ["sol", f] else ["run", f]
    start <- getCurrentTime
    r <- try (readCreateProcessWithExitCode (proc self command) "") :: IO (Either SomeException (ExitCode, String, String))
    end <- getCurrentTime
    let secs = showFFloat (Just 2) (realToFrac (diffUTCTime end start) :: Double) "" ++ " s"
        (ok, status, said) = case r of
          Right (ExitSuccess, o, e) -> (True, "", o ++ e)
          Right (ExitFailure c, o, e) -> (False, "exit " ++ show c, o ++ e)
          Left why -> (False, "could not run", show why)
    putStrLn ((if ok then "PASS " else "FAIL ") ++ f ++ " (" ++ (if ok then secs else status ++ ", " ++ secs) ++ ")")
    when (not ok || verbose) $ unless (null (trim said)) $ putStrLn (indent (trim said))
    hFlush stdout
    pure ok
  let failed = length (filter not results)
  putStrLn ("fpr test: " ++ show (length results - failed) ++ " passed, " ++ show failed ++ " failed")
  when (failed > 0) $ exitWith (ExitFailure 1)

-- ---- fpr doctor -----------------------------------------------------------

-- What this toolchain is, what native builds will use, and where it keeps
-- things.  Exit 0 when native builds should work; 1 when something they need
-- is missing (Sol needs none of the C tools).
doctorMain :: String -> [String] -> IO ()
doctorMain version args = do
  unless (null args) $ usageError "doctor" "usage: fpr doctor"
  self <- getExecutablePath
  real <- either (const self) id <$> (try (canonicalizePath self) :: IO (Either SomeException FilePath))
  home <- fprHome
  envHome <- lookupEnv "FPR_HOME"
  problems <- newProblems
  section "toolchain"
  row "fpr" version
  row "executable" real
  row "home" (home ++ (if isJust envHome then "  (FPR_HOME)" else ""))
  missing <- filterM' (fmap not . doesPathExist') [home </> "core" </> "prelude.fpr", home </> "std", home </> "sol" </> "lib", home </> "runtime", home </> "machine" </> "posix", home </> "machine" </> "unix"]
  if null missing then row "files" "core, std, sol/lib, runtime, machine: present"
  else problem problems "files" ("missing " ++ unwords (map (makeRelative home) missing))
  meta <- tryRead (home </> "toolchain.json")
  row "install" $ case meta of
    Just t -> "installed SDK (toolchain.json" ++ maybe "" (", revision " ++) (jsonField "sourceRevision" t) ++ maybe "" (", release " ++) (jsonField "release" t) ++ ")"
    Nothing -> "a checkout or unpackaged build (no toolchain.json)"
  section "native builds (Sol needs none of these)"
  configured <- Options.readCompilerOptions
  let cc = fromMaybe "cc" (Options.driverCC (Options.driverOptions configured))
  isMac <- pure (System.Info.os == "darwin")
  developer <- if isMac then firstLine "xcode-select" ["-p"] else pure Nothing
  when isMac $ case developer of
    Just d -> row "developer" (d ++ (if "CommandLineTools" `isSuffixOf` d then "  (Command Line Tools)" else "  (Xcode)"))
    Nothing -> do
      tool <- findExecutable "xcode-select"
      problem problems "developer" (if isJust tool then "no Xcode or Command Line Tools: xcode-select --install" else "xcode-select is not on PATH")
  ccPath <- findExecutable cc
  -- on a Mac without developer tools /usr/bin/cc only offers to install them
  ccVersion <- if isMac && developer == Nothing then pure Nothing else maybe (pure Nothing) (\c -> firstLine c ["--version"]) ccPath
  case (ccPath, ccVersion) of
    (Just c, Just v) -> row "C compiler" (cc ++ " -> " ++ c ++ ": " ++ v)
    (Just c, Nothing) -> problem problems "C compiler" (cc ++ " -> " ++ c ++ " does not run")
    (Nothing, _) -> problem problems "C compiler" (cc ++ " is not on PATH" ++ (if isMac then " (xcode-select --install)" else " (install a C compiler, e.g. gcc or clang)"))
  if isMac
    then do
      sdk <- if developer == Nothing then pure Nothing else firstLine "xcrun" ["--show-sdk-path"]
      case sdk of
        Just s -> row "SDK" s
        Nothing -> problem problems "SDK" "xcrun --show-sdk-path found no macOS SDK"
    else row "SDK" "the C compiler's own headers and libc"
  section "caches and state"
  fprCache <- getXdgDirectory XdgCache "fpr"
  row "fpr cache" (fprCache ++ "  (build, run, rt, unit-obj)")
  solCache <- Sol.Cache.cacheDirectory
  row "sol cache" solCache
  solState <- Sol.Txn.stateDirectoryPath
  row "sol state" (solState ++ "  (recovery journals)")
  section "project"
  here <- getCurrentDirectory
  found <- discover here
  case found of
    Left why -> row "project" why
    Right root -> do
      text <- readFile (root </> manifestFile)
      case parseManifest text of
        Left why -> problem problems "manifest" (root </> why)
        Right m -> do
          row "manifest" (root </> manifestFile)
          row "project" (mName m ++ " " ++ mVersion m ++ " (" ++ kindName (mKind m) ++ "), entry " ++ mEntry m ++ ", target " ++ mTarget m)
          if compatible version (mToolchain m)
            then row "toolchain" ("asks for " ++ mToolchain m ++ ": compatible")
            else problem problems "toolchain" ("asks for " ++ mToolchain m ++ "; this is " ++ version)
  n <- countProblems problems
  if n == 0 then putStrLn "\nno problems found" else hPutStrLn stderr ("\n" ++ plural n "problem" ++ " found") >> exitWith (ExitFailure 1)
  where
    section s = putStrLn ("\n" ++ s)
    row k v = putStrLn ("  " ++ pad 12 k ++ " " ++ v)
    pad n s = s ++ replicate (n - length s) ' '
    problem ref k v = row k ("PROBLEM: " ++ v) >> addProblem ref
    filterM' f = fmap concat . mapM (\x -> f x >>= \b -> pure [x | b])
    doesPathExist' f = (||) <$> doesFileExist f <*> doesDirectoryExist f

newtype Problems = Problems (IORefInt)

type IORefInt = Data.IORef.IORef Int

newProblems :: IO Problems
newProblems = Problems <$> Data.IORef.newIORef 0

addProblem :: Problems -> IO ()
addProblem (Problems r) = Data.IORef.modifyIORef' r (+ 1)

countProblems :: Problems -> IO Int
countProblems (Problems r) = Data.IORef.readIORef r

-- the first line a tool prints, if it runs and succeeds
firstLine :: String -> [String] -> IO (Maybe String)
firstLine cmd as = do
  r <- try (readProcessWithExitCode cmd as "") :: IO (Either SomeException (ExitCode, String, String))
  pure $ case r of
    Right (ExitSuccess, out, _) | (l : _) <- lines out, not (null (trim l)) -> Just (trim l)
    _ -> Nothing

tryRead :: FilePath -> IO (Maybe String)
tryRead f = do
  e <- doesFileExist f
  if e then Just <$> readFile f else pure Nothing

-- a top-level "key": "string" of a small JSON file, enough for toolchain.json
jsonField :: String -> String -> Maybe String
jsonField key t = case breakOn ("\"" ++ key ++ "\"") t of
  Nothing -> Nothing
  Just rest -> case dropWhile (\c -> isSpace c || c == ':') rest of
    '"' : v -> Just (takeWhile (/= '"') v)
    _ -> Nothing
  where
    breakOn pat s
      | null s = Nothing
      | pat `isPrefixOf` s = Just (drop (length pat) s)
      | otherwise = breakOn pat (drop 1 s)

-- ---- small things -----------------------------------------------------------

indent :: String -> String
indent = intercalate "\n" . map ("    " ++) . lines

plural :: Int -> String -> String
plural n w = show n ++ " " ++ w ++ (if n == 1 then "" else "s")
