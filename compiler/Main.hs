-- Main.hs — `fpr`: the ONE binary for the merged project.
--
-- Profiles are SUBCOMMANDS of one tool, not separate executables:
--
--   fpr compile [flags] in.fpr out.s     the AOT pipeline (old fprc)
--   fpr sol script.sol [args]            the HostedBytecode profile —
--                                        sol IS a set of configuration
--                                        options + libraries: the
--                                        bytecode VM/JIT (Sol.*), the
--                                        transactional runtime, the `>`
--                                        surface view, std auto-visible
--   fpr stdcheck file.fpr               the std proof pass
--   fpr commit file.fpr [--major]       mint an immutable version into
--                                        .fpr (Commit.hs)
--   fpr versions [name]                 list committed versions
--
-- The sol pipeline links in as Sol.* modules (same GHC build, same
-- binary); its argv shape is preserved via withArgs, so everything sol
-- accepted, `fpr sol` accepts.  `fprc`-compatible direct invocation
-- (fpr with flag/file args and no subcommand) still works, so the
-- Makefiles don't care which name they call.
module Main where

import qualified Commit
import qualified Compile
import qualified Sol.Main
import Data.List (elem)
import System.Environment (getArgs, withArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import GHC.IO.Encoding (setLocaleEncoding, utf8)

usage :: String
usage =
  unlines
    [ "fpr — the merged FP-RISC tool (one frontend, four profiles)",
      "",
      "  fpr compile [flags] <in.fpr> <out.s>   AOT (BareMetal/QOS profiles; old fprc)",
      "  fpr compile --target=bytecode <f>      the VM as a target: bytecode listing",
      "  fpr sol <script.sol> [args]            HostedBytecode profile (the sol VM)",
      "  fpr stdcheck <file.fpr>                the std proof pass",
      "  fpr commit <file.fpr> [--major]        mint an immutable version into .fpr/",
      "  fpr versions [name]                    list committed versions (use \"name#hash\")",
      "  fpr push <name>                        push committed versions to a pkgstore",
      "  fpr pull <name>[.vX.Y]                 fetch a version into .fpr/store (PKGSTORE_URL)",
      "",
      "bare flags/files (no subcommand) fall through to `compile` for fprc compatibility"
    ]

main :: IO ()
main = do
  setLocaleEncoding utf8
  args <- getArgs
  case args of
    ("sol" : rest) -> withArgs rest Sol.Main.main
    -- the VM as a TARGET: `fpr compile --target=bytecode f` (or the
    -- bare-flags form) routes the shared frontend's output into the
    -- Sol pipeline's bytecode emitter — the HostedBytecode profile is
    -- literally one more backend of the one compiler.
    ("compile" : rest) | "--target=bytecode" `elem` rest ->
      withArgs ("--asm" : [a | a <- rest, a /= "--target=bytecode"]) Sol.Main.main
    ("compile" : rest) -> withArgs rest Compile.compileMain
    ("stdcheck" : rest) -> withArgs ("--stdcheck" : rest) Compile.compileMain
    ("commit" : rest) -> Commit.commitMain rest
    ("versions" : rest) -> Commit.versionsMain rest
    ("push" : rest) -> Commit.pushMain rest
    ("pull" : rest) -> Commit.pullMain rest
    ("help" : _) -> putStrLn usage
    ("--help" : _) -> putStrLn usage
    [] -> hPutStrLn stderr usage >> exitFailure
    _ | "--target=bytecode" `elem` args ->
          withArgs ("--asm" : [a | a <- args, a /= "--target=bytecode"]) Sol.Main.main
      | otherwise -> withArgs args Compile.compileMain -- fprc-compatible fallthrough
