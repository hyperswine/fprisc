import A64 (lowerA64WithOptions)
import Control.Monad (unless)
import Data.List (isInfixOf)
import System.Environment (getArgs)
import System.FilePath ((</>))

main :: IO ()
main = do
  [dir] <- getArgs
  let saves n = unlines ["    sd ra, " ++ show (n+8) ++ "(sp)",
                         "    sd s0, " ++ show n ++ "(sp)"]
      restore = unlines ["    ld ra, -8(s0)", "    mv t0, s0",
                         "    ld s0, -16(s0)", "    mv sp, t0"]
      lower = lowerA64WithOptions False True False
  mapM_ (\n -> unless ("stp x29, x30" `isInfixOf` lower (saves n)) $
    error ("legal pair missed " ++ show n)) [-512,0,48,504]
  mapM_ (\n -> unless (not ("stp x29, x30" `isInfixOf` lower (saves n))) $
    error ("illegal pair " ++ show n)) [-520,1,512]
  let interrupted = "    sd ra, 56(sp)\nLbarrier:\n    sd s0, 48(sp)\n"
  unless (not ("stp x29, x30" `isInfixOf` lower interrupted)) $ error "crossed label"
  unless ("ldp x29, x30, [x9, #-16]" `isInfixOf` lower restore) $ error "restore missed"
  let input = unlines [".text", "    .globl fpr_fn_pair_probe", "fpr_fn_pair_probe:",
                       "    addi sp, sp, -64"] ++ saves 48 ++
              unlines ["    addi s0, sp, 64", "    sd a0, -24(s0)",
                       "    call pair_clobber", "    ld t1, -24(s0)", "    add a0, a0, t1"] ++
              restore ++ "    ret\n"
  mapM_ (\(mach,name) -> writeFile (dir </> name) (lowerA64WithOptions False True mach input))
    [(False,"pair-elf.s"),(True,"pair-mac.s")]
  putStrLn "A64 frame pairs: offset limits, label barriers, frame-pointer restore ordering PASS"
