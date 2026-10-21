import A64 (lowerA64WithGuards)
import Control.Monad (unless, forM_)
import Data.List (isInfixOf)
import System.Environment (getArgs)
import System.FilePath ((</>))

marker = "# a comment before the guard"
guard = ["    slli t1, t0, 1", "    srai t1, t1, 1", "    bne t1, t0, .Lslow"]
ending = ["    li a0, 1", "    ret", ".Lslow:", "    li a0, 0", "    ret"]
lower on mach = lowerA64WithGuards on mach . unlines
check name yes ls = forM_ [False, True] $ \mach ->
  unless (("sbfx" `isInfixOf` lower True mach ls) == yes) (error name)

main = do
  check "fit after a comment" True (marker : guard ++ ending)
  check "unannotated scratch preserved" True (guard ++ ending)
  check "intervening label" False (marker : head guard : ".Lentry:" : tail guard ++ ending)
  check "different shift" False (marker : "    slli t1, t0, 2" : tail guard ++ ending)
  check "different branch operand" False (marker : take 2 guard ++ ["    bne t1, a0, .Lslow"] ++ ending)
  check "distant branch keeps B.cond reach" True (marker : guard ++ replicate 65 "    mv a0, a0" ++ ending)
  check "data after guard keeps B.cond reach" True (marker : guard ++ ["    .space 40000"] ++ ending)
  check "alignment after guard keeps B.cond reach" True (marker : guard ++ ["    .p2align 16"] ++ ending)
  check "external target keeps B.cond reach" True (marker : guard)
  unless (not ("sbfx" `isInfixOf` lower False True (marker : guard ++ ending))) (error "disabled")
  -- Generate two leaf functions from the real translator for a C oracle.
  args <- getArgs
  case args of
    [dir] -> forM_ [(False,"elf"),(True,"mac")] $ \(mach, suffix) -> do
      let fn on name tailCode = lower on mach
            (["    .text", "    .globl " ++ name, name ++ ":", "    mv t0, a0"] ++
             [marker] ++ map (rename name) guard ++ map (rename name) tailCode)
          rename name s = if s == ".Lslow:" then ".L" ++ name ++ ":"
            else if s == last guard then "    bne t1, t0, .L" ++ name else s
          normEnd = [".Lslow:", "    mv a0, t1", "    ret"]
      writeFile (dir </> ("fit-" ++ suffix ++ ".s"))
        (fn False "fit_old" ending ++ fn True "fit_new" ending ++
         fn False "norm_old" normEnd ++ fn True "norm_new" normEnd)
    [] -> pure ()
    _ -> error "usage: A64Guards.hs [output-directory]"
  putStrLn "A64 fit guards: exact match, preserved scratch value, original branch reach and both syntaxes PASS"
