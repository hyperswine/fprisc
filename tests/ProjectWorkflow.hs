-- The project manifest (fpr.toml), toolchain compatibility, when build/run
-- act on a project, and the templates `fpr new` writes (compiler/Project.hs).
module Main where

import Control.Monad (forM_, unless)
import Data.List (isInfixOf)
import Project

require :: Bool -> String -> IO ()
require ok message = unless ok (error message)

refused :: String -> String -> String -> IO ()
refused label text expected = case parseManifest text of
  Right m -> error (label ++ ": accepted " ++ show m)
  Left why -> require (expected `isInfixOf` why) (label ++ ": said " ++ show why)

base :: String
base =
  unlines
    [ "manifest = 1",
      "[project]",
      "name = \"hello\"",
      "version = \"0.1.0\"",
      "kind = \"cli\"",
      "entry = \"src/main.fpr\"",
      "[toolchain]",
      "fpr = \"0.12.0\""
    ]

main :: IO ()
main = do
  -- the smallest manifest: target defaults to host, no dependencies
  case parseManifest base of
    Right m -> require (mName m == "hello" && mKind m == Cli && mTarget m == "host" && null (mDeps m)) ("base: " ++ show m)
    Left why -> error ("base refused: " ++ why)
  -- what render writes, parse reads back
  let full = Manifest 1 "tool-2" "1.4.0-rc1" Service "src/srv.fpr" "0.12.0" "linux-aarch64" [("greet", "v1.2#3f2e7b4929116f16")]
  require (parseManifest (renderManifest full) == Right full) "render/parse round trip"
  -- comments, blank lines, a # inside a string, escapes
  case parseManifest (base ++ "# trailing comment\n\n[dependencies]\nlib = \"v1.0#0123456789abcdef\"   # pinned\n") of
    Right m -> require (mDeps m == [("lib", "v1.0#0123456789abcdef")]) "dependency read"
    Left why -> error why
  case parseManifest (replace "src/main.fpr" "src/a#b.fpr" base) of
    Right m -> require (mEntry m == "src/a#b.fpr") "a # inside a string is not a comment"
    Left why -> error why
  -- refusals: each names its problem, nothing is ignored
  refused "no format" (unlines (drop 1 (lines base))) "no `manifest = 1`"
  refused "newer format" (replace "manifest = 1" "manifest = 2" base) "format 2"
  refused "unknown key" (base ++ "colour = \"red\"\n") "unknown key `colour` in [toolchain]"
  refused "unknown top key" ("colour = \"red\"\n" ++ base) "unknown key `colour`"
  refused "unknown section" (base ++ "[assets]\nfiles = [\"a.png\"]\n") "unknown key `files` in [assets]"
  refused "duplicate" (base ++ "[project]\nname = \"again\"\n") "given twice"
  refused "kind" (replace "\"cli\"" "\"gui\"" base) "kind is cli, service or sol"
  refused "name" (replace "\"hello\"" "\"Hello\"" base) "project name"
  refused "entry escapes" (replace "src/main.fpr" "../main.fpr" base) "inside the project"
  refused "entry absolute" (replace "src/main.fpr" "/tmp/main.fpr" base) "inside the project"
  refused "entry extension" (replace "src/main.fpr" "src/main.sol" base) "a .fpr file"
  refused "sol target" (replace "src/main.fpr" "src/main.sol" (replace "\"cli\"" "\"sol\"" base) ++ "[target]\nname = \"linux-aarch64\"\n") "target is host"
  refused "target" (base ++ "[target]\nname = \"windows\"\n") "target is one of"
  refused "toolchain" (replace "\"0.12.0\"" "\"latest\"" base) "toolchain is a version"
  refused "dependency" (base ++ "[dependencies]\nlib = \"1.0\"\n") "a dependency is"
  refused "unterminated" (replace "\"hello\"" "\"hello" base) "unterminated string"
  refused "unquoted" (replace "\"hello\"" "hello" base) "strings are quoted"
  refused "string type" (replace "\"hello\"" "3" base) "quoted string"
  -- compatibility: the same series, not older
  forM_
    [ ("0.12.0", "0.12.0", True), ("0.12.1", "0.12.0", True), ("0.12.0", "0.12.1", False),
      ("0.13.0", "0.12.0", False), ("0.12", "0.12.0", True), ("1.3.0", "1.0", True),
      ("2.0.0", "1.9.9", False), ("1.0.0", "0.12.0", False), ("x", "0.12.0", False)
    ]
    $ \(running, wanted, ok) -> require (compatible running wanted == ok) ("compatible " ++ running ++ " " ++ wanted)
  -- build/run with no file act on the project; a named file never does
  forM_
    [ ([], True), (["--release"], True), (["-o", "out"], True), (["--harts", "4", "-v"], True),
      (["--", "main.fpr"], True), (["--target=macos-x86_64"], True),
      (["main.fpr"], False), (["-o", "out", "main.fpr"], False), (["--cc", "gcc", "x.fpr", "--release"], False),
      (["--target=qos-portable"], False)
    ]
    $ \(args, project) -> require (projectMode args == project) ("projectMode " ++ show args)
  -- every template: its manifest parses, names its own entry, and the
  -- entry, a module under src/ and a test under tests/ are all written
  forM_ [TCli, TService, TSol] $ \t -> do
    let files = templateFiles "0.12.0" t "demo"
    case lookup manifestFile files >>= either (const Nothing) Just . parseManifest of
      Nothing -> error ("template manifest " ++ show t)
      Just m -> do
        require (mName m == "demo" && mToolchain m == "0.12.0") ("template identity " ++ show t)
        require (mEntry m `elem` map fst files) ("template entry " ++ show t)
        require (length [f | (f, _) <- files, take 6 f == "tests/"] == 1) ("template test " ++ show t)
        require (length [f | (f, _) <- files, take 4 f == "src/"] == 2) ("template modules " ++ show t)
  putStrLn "ProjectWorkflow: ok"
  where
    replace old new s = case s of
      [] -> []
      _ | take (length old) s == old -> new ++ replace old new (drop (length old) s)
      c : rest -> c : replace old new rest
