import Codegen (wcetAnnotate)
import Peephole (peepholeFor)
import Control.Monad (unless)
import Data.List (isInfixOf)

check name yes = unless yes (error name)
main = do
  let cycle = ["Lloop:", "    addi a0, a0, 1", "    j Lloop"]
      note entries ls = last (wcetAnnotate entries "probe" ls)
  check "unregistered back-edge stays unbounded"
    ("segmax=UNBOUNDED" `isInfixOf` note [] cycle)
  check "proven entry edge bounds the repeated segment"
    ("segmax=1 " `isInfixOf` note ["Lloop"] cycle)
  check "a similar label name is not a fuel proof"
    ("segmax=UNBOUNDED" `isInfixOf` note ["Lother"] cycle)
  let bypass = ["Lentry:", "    beqz a0, Lbad", "    j Lentry",
                "Lbad:", "    addi a0, a0, 1", "    j Lbad"]
  check "a second cycle without a reset stays unbounded"
    ("segmax=UNBOUNDED" `isInfixOf` note ["Lentry"] bypass)
  let slotCycle = ["Lloop:", "    ld a0, -24(s0)",
                   "    sd a1, -24(s0)", "    j Lloop"]
  check "loop-carried store survives dead-store elimination"
    ("    sd a1, -24(s0)" `elem` peepholeFor "ld" "sd" slotCycle)
  let forward = ["    sd a1, -24(s0)", "Lloop:", "    ld a0, -24(s0)",
                 "    sd a2, -24(s0)", "    j Lloop"]
  check "forwarding forgets the initial value at a back-edge target"
    ("    ld a0, -24(s0)" `elem` peepholeFor "ld" "sd" forward)
  putStrLn "Self loops: WCET reset boundaries, unbounded negative controls and loop-carried slot values PASS"
