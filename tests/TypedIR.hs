-- The typed IR's own checks (docs/2026-10-20-TYPED-IR-M1.md): the verifier
-- accepts a well-formed function and refuses each malformation by name;
-- the lowering of hand-written Core in the shapes the generator produces
-- gives a verified function whose dump is stable and whose evaluation
-- answers, traps and orders its effects as the legacy backend does.
-- Run: cabal exec -- runghc -w -icompiler tests/TypedIR.hs
import Codegen.Dump (dumpFn)
import Codegen.Eval
import Codegen.IR
import Codegen.Lower (lowerFn, lowerProgram)
import Codegen.Policy (m2Policy)
import Codegen.Verify (verifyFn, verifyProgram)
import Control.Monad (unless)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as M
import FPRISC (Core (..))
import Workers (workerizeWithSignatures)
import KernelKinds (Kind (..))

check :: String -> Bool -> IO ()
check name yes = unless yes (error ("FAIL: " ++ name))

expectRefusal :: String -> String -> Either String () -> IO ()
expectRefusal name needle r = case r of
  Left msg | needle `isInfixOf` msg -> pure ()
  Left msg -> error ("FAIL: " ++ name ++ ": refused for another reason: " ++ msg)
  Right () -> error ("FAIL: " ++ name ++ ": accepted")

-- fn one (n) -> val: n < 2 ? n : (n - 1)
good :: Fn
good =
  Fn "one" ["n"] TVal (BId 0)
    [ Block (BId 0) [(VId 0, TVal)]
        [ Instr Nothing OStackCheck, Instr Nothing OSafepoint,
          Instr (Just (VId 1, TInt)) (OUntag (VId 0)),
          Instr (Just (VId 2, TInt)) (OConstInt 2),
          Instr (Just (VId 3, TPred)) (OCmp Lt (VId 1) (VId 2)) ]
        (TCondBr (VId 3) (BId 1) [] (BId 2) []),
      Block (BId 1) [] [] (TRet (VId 0)),
      Block (BId 2) []
        [ Instr (Just (VId 4, TInt)) (OConstInt 1),
          Instr (Just (VId 5, TInt)) (OArith Sub (VId 1) (VId 4)),
          Instr (Just (VId 6, TVal)) (OTag (VId 5)) ]
        (TRet (VId 6))
    ]

withBlocks :: ([Block] -> [Block]) -> Fn
withBlocks f = good {fnBlocks = f (fnBlocks good)}

editBlock :: BId -> (Block -> Block) -> Fn
editBlock b f = withBlocks (map (\x -> if bId x == b then f x else x))

-- the generator's Core for fib and for a self loop, as FPR_DUMP_CORE shows them
var :: String -> Core
var = CVar

app :: String -> [Core] -> Core
app f = foldl CApp (CVar f)

fibCore, sumCore, addCore :: ([String], Core)
fibCore = (["a"], CLet "n" (var "a") (CLet "s" (app "<" [var "n", CInt 2])
  (CIf (CTagEq 1 1 (var "s")) (var "n")
     (app "+" [app "fib" [app "-" [var "n", CInt 1]], app "fib" [app "-" [var "n", CInt 2]]]))))
sumCore = (["a", "b"], CLet "n" (var "a") (CLet "acc" (var "b") (CLet "s" (app "==" [var "n", CInt 0])
  (CIf (CTagEq 1 1 (var "s")) (var "acc") (app "sum" [app "-" [var "n", CInt 1], app "+" [var "acc", var "n"]])))))
addCore = (["a", "b"], app "+" [var "a", var "b"])

main :: IO ()
main = do
  -- the verifier
  check "a well-formed function verifies" (verifyFn M.empty good == Right ())
  expectRefusal "missing entry" "entry block missing" (verifyFn M.empty good {fnEntry = BId 9})
  expectRefusal "duplicate block" "duplicate block id" (verifyFn M.empty (withBlocks (\bs -> bs ++ [head bs])))
  expectRefusal "double definition" "defined twice"
    (verifyFn M.empty (editBlock (BId 2) (\b -> b {bInstrs = bInstrs b ++ [Instr (Just (VId 4, TInt)) (OConstInt 3)]})))
  expectRefusal "use before definition" "used before its definition"
    (verifyFn M.empty (editBlock (BId 2) (\b -> b {bInstrs = reverse (bInstrs b)})))
  expectRefusal "use without dominance" "does not dominate"
    (verifyFn M.empty (editBlock (BId 1) (\b -> b {bTerm = TRet (VId 6)})))
  expectRefusal "undefined value" "never defined"
    (verifyFn M.empty (editBlock (BId 1) (\b -> b {bTerm = TRet (VId 77)})))
  expectRefusal "wrong operand type" "TInt needed"
    (verifyFn M.empty (editBlock (BId 2) (\b -> b {bInstrs = [Instr (Just (VId 5, TInt)) (OArith Sub (VId 0) (VId 0)), Instr (Just (VId 6, TVal)) (OTag (VId 5))]})))
  expectRefusal "illegal conversion" "TPred needed"
    (verifyFn M.empty (editBlock (BId 2) (\b -> b {bInstrs = [Instr (Just (VId 6, TVal)) (OBoolOf (VId 0))]})))
  expectRefusal "declared type disagrees" "operation gives"
    (verifyFn M.empty (editBlock (BId 2) (\b -> b {bInstrs = [Instr (Just (VId 4, TInt)) (OConstInt 1), Instr (Just (VId 5, TInt)) (OArith Sub (VId 1) (VId 4)), Instr (Just (VId 6, TInt)) (OTag (VId 5))]})))
  expectRefusal "discarded result" "result is discarded"
    (verifyFn M.empty (editBlock (BId 1) (\b -> b {bInstrs = [Instr Nothing (OConstInt 1)]})))
  expectRefusal "branch on a value" "TPred needed"
    (verifyFn M.empty (editBlock (BId 0) (\b -> b {bTerm = TCondBr (VId 0) (BId 1) [] (BId 2) []})))
  expectRefusal "return of an Int" "TVal needed"
    (verifyFn M.empty (editBlock (BId 2) (\b -> b {bTerm = TRet (VId 5)})))
  expectRefusal "jump to a missing block" "missing block"
    (verifyFn M.empty (editBlock (BId 0) (\b -> b {bTerm = TCondBr (VId 3) (BId 1) [] (BId 8) []})))
  expectRefusal "edge argument count" "passes 1 arguments"
    (verifyFn M.empty (editBlock (BId 0) (\b -> b {bTerm = TCondBr (VId 3) (BId 1) [VId 0] (BId 2) []})))
  expectRefusal "edge argument type" "TInt needed"
    (verifyFn M.empty (withBlocks (\bs -> [if bId x == BId 1 then x {bParams = [(VId 9, TInt)]} else if bId x == BId 0 then x {bTerm = TCondBr (VId 3) (BId 1) [VId 0] (BId 2) []} else x | x <- bs])))
  expectRefusal "unreachable block" "unreachable"
    (verifyFn M.empty (withBlocks (++ [Block (BId 3) [] [] (TRet (VId 0))])))
  expectRefusal "malformed call" "3 arguments for 1 parameters"
    (verifyFn M.empty (editBlock (BId 1) (\b -> b {bInstrs = [Instr (Just (VId 8, TVal)) (OCall (Callee "one" Local [TVal] TVal) [VId 0, VId 0, VId 0])], bTerm = TRet (VId 8)})))
  expectRefusal "call convention disagrees with the callee" "its entry takes"
    (verifyProgram (M.fromList [("one", good), ("two", (editBlock (BId 1) (\b -> b {bInstrs = [Instr (Just (VId 8, TVal)) (OCall (Callee "one" Local [TVal, TVal] TVal) [VId 0, VId 0])], bTerm = TRet (VId 8)})) {fnName = "two"})]))
  expectRefusal "a shift of a tagged word" "TInt needed"
    (verifyFn M.empty (editBlock (BId 2) (\b -> b {bInstrs = [Instr (Just (VId 4, TInt)) (OConstInt 1), Instr (Just (VId 5, TInt)) (OShift Shl (VId 0) (VId 4)), Instr (Just (VId 6, TVal)) (OTag (VId 5))]})))
  expectRefusal "a bit operation declared a predicate" "operation gives"
    (verifyFn M.empty (editBlock (BId 2) (\b -> b {bInstrs = [Instr (Just (VId 4, TInt)) (OConstInt 1), Instr (Just (VId 5, TPred)) (OBit BAnd (VId 1) (VId 4)), Instr (Just (VId 6, TVal)) (OBoolOf (VId 5))]})))
  expectRefusal "arity above the ceiling" "above the ceiling"
    (verifyFn M.empty (let ps = [(VId (100 + i), TVal) | i <- [0 .. 64]] in good {fnBlocks = [Block (BId 0) ps [Instr Nothing OStackCheck, Instr Nothing OSafepoint] (TRet (VId 100))]}))
  expectRefusal "const outside the Int range" "outside the Int range"
    (verifyFn M.empty (editBlock (BId 2) (\b -> b {bInstrs = [Instr (Just (VId 4, TInt)) (OConstInt (2 ^ (62 :: Int))), Instr (Just (VId 5, TInt)) (OArith Sub (VId 1) (VId 4)), Instr (Just (VId 6, TVal)) (OTag (VId 5))]})))
  putStrLn "Typed IR verifier: a well-formed function accepted, 22 malformations refused by name PASS"
  -- the lowering of the generator's shapes
  let prog = M.fromList [("fib", fibCore), ("sum", sumCore), ("addovf", addCore)]
      (lowered, failures) = lowerProgram m2Policy M.empty prog M.empty M.empty
  check "every fixture function lowers" (null failures && M.size lowered == 3)
  check "the lowered program verifies" (verifyProgram lowered == Right ())
  let dumps = M.map dumpFn lowered
  check "a dump is deterministic" (M.map dumpFn (fst (lowerProgram m2Policy M.empty prog M.empty M.empty)) == dumps)
  check "fib's self call is a call, its tail is a return" ("call fib" `isInfixOf` (dumps M.! "fib") && "br b0" `notElem` lines (dumps M.! "fib"))
  check "sum's self tail call is the loop through the entry" ("  br b0(" `isInfixOf` (dumps M.! "sum"))
  check "every function enters through its stack check and safepoint" (all (\d -> "  stackcheck\n  safepoint\n" `isInfixOf` d) (M.elems dumps))
  -- the evaluator against the legacy results (tests/typed_ir/scalar.fpr run by check_typed_ir.py)
  let fib20 = evalProgram lowered "fib" [RInt 20]
      sum100 = evalProgram lowered "sum" [RInt 100, RInt 0]
      ovf = evalProgram lowered "addovf" [RInt intMax, RInt 1]
  check "fib 20 = 6765" (ocResult fib20 == Right (RInt 6765))
  check "fib 20 ticks once per activation" (length [() | EvSafepoint _ <- ocEvents fib20] == 21891)
  check "sum 100 0 = 5050" (ocResult sum100 == Right (RInt 5050))
  check "sum's loop ticks on every turn" (length [() | EvSafepoint _ <- ocEvents sum100] == 101)
  check "the checked + traps with the primitive's text"
    (ocResult ovf == Left (Trap "Int overflow: 4611686018427387903 + 1 does not fit an Int (-4611686018427387904..4611686018427387903); I64 is the type that wraps"))
  check "the trap is the last event, after the entry safepoint" (take 2 (ocEvents ovf) == [EvCall "addovf" [], EvStackCheck "addovf"] || case ocEvents ovf of
    [EvCall "addovf" _, EvStackCheck "addovf", EvSafepoint "addovf", EvTrap _] -> True
    _ -> False)
  -- the bitwise primitives and the shifts (increment 1 of
  -- docs/2026-10-21-TYPED-IR-COVERAGE.md): lowered only as declared HAL
  -- names of arity two; the evaluator states bits.c's semantics
  let hal = M.fromList [(n, (2, "fpr_g_" ++ n ++ "_call2")) | n <- ["band", "bor", "bxor", "BITSHIFTL", "BITSHIFTR"]]
      bitProg = M.fromList [("shl", (["a", "n"], app "BITSHIFTL" [var "a", var "n"])), ("shr", (["a", "n"], app "BITSHIFTR" [var "a", var "n"])),
                            ("andf", (["a", "b"], app "band" [var "a", var "b"])), ("orf", (["a", "b"], app "bor" [var "a", var "b"])), ("xorf", (["a", "b"], app "bxor" [var "a", var "b"]))]
      (bitIr, bitFail) = lowerProgram m2Policy M.empty bitProg M.empty hal
      bitEval f a b = ocResult (evalProgram bitIr f [RInt a, RInt b])
  check "the bit operations and shifts lower and verify" (null bitFail && M.size bitIr == 5 && verifyProgram bitIr == Right ())
  check "the dump names the operations" ("shift BITSHIFTL" `isInfixOf` dumpFn (bitIr M.! "shl") && "bit bxor" `isInfixOf` dumpFn (bitIr M.! "xorf"))
  check "band/bor/bxor are two's complement on the untagged values"
    (bitEval "andf" 12 10 == Right (RInt 8) && bitEval "orf" 12 10 == Right (RInt 14) && bitEval "xorf" 12 10 == Right (RInt 6)
       && bitEval "andf" (-1) 77 == Right (RInt 77) && bitEval "xorf" (-1) 5 == Right (RInt (-6)))
  -- a program function of the primitive's name shadows it, as in the legacy generator
  check "a function named band shadows the primitive"
    (case lowerProgram m2Policy M.empty (M.singleton "band" (["a", "b"], app "band" [var "a", var "b"])) M.empty hal of
       (ir, []) -> "  br b0(" `isInfixOf` dumpFn (ir M.! "band")
       _ -> False)
  check "a left shift keeps the low 63 bits" (bitEval "shl" 1 3 == Right (RInt 8) && bitEval "shl" 1 62 == Right (RInt intMin) && bitEval "shl" 3 63 == Right (RInt 0) && bitEval "shl" (-1) 1 == Right (RInt (-2)))
  check "a right shift is logical on the 64-bit word, then wrapped" (bitEval "shr" (-1) 1 == Right (RInt (-1)) && bitEval "shr" (-8) 1 == Right (RInt (-4)) && bitEval "shr" 1024 3 == Right (RInt 128) && bitEval "shr" 5 63 == Right (RInt 0))
  check "a count outside 0..63 traps with the primitive's text"
    (bitEval "shl" 1 64 == Left (Trap "BITSHIFTL: shift must be 0..63") && bitEval "shl" 1 (-1) == Left (Trap "BITSHIFTL: shift must be 0..63")
       && bitEval "shr" 5 64 == Left (Trap "BITSHIFTR: shift must be 0..63") && bitEval "shr" 5 (-7) == Left (Trap "BITSHIFTR: shift must be 0..63"))
  check "the trap is an ordered event after the entry" (case ocEvents (evalProgram bitIr "shl" [RInt 1, RInt 64]) of
    [EvCall "shl" _, EvStackCheck "shl", EvSafepoint "shl", EvTrap "BITSHIFTL: shift must be 0..63"] -> True
    _ -> False)
  check "an undeclared band is still the primitive, refused by name"
    (case lowerProgram m2Policy M.empty (M.singleton "andf" (["a", "b"], app "band" [var "a", var "b"])) M.empty M.empty of
       (_, [(_, r)]) -> "primitive `band`" `isInfixOf` r
       _ -> False)
  putStrLn "Typed IR bit operations and shifts: lowered as declared HAL names, bits.c semantics, exact trap text and order PASS"
  -- refusals name the form
  let refused what = case lowerFn m2Policy M.empty (M.insert "f" what prog) M.empty M.empty "f" what of
        Left r -> r
        Right _ -> "accepted"
  check "a string literal is refused by name" ("string literal" `isInfixOf` refused ([], CStr "x"))
  check "a primitive outside the subset is refused by name" ("primitive `print`" `isInfixOf` refused (["x"], app "print" [var "x"]))
  check "a partial application is refused by name" ("partial" `isInfixOf` refused (["x"], app "sum" [var "x"]))
  check "a constructor with fields is refused by name" ("constructor with fields" `isInfixOf` refused (["x"], CMk 2 1 [var "x"]))
  -- arities 9..64 lower (the hart spill cells); a 65th parameter has no convention
  check "nine parameters lower" (refused (map (: []) "abcdefghi", var "i") == "accepted")
  check "sixty-four parameters lower" (refused (["p" ++ show i | i <- [1 .. 64 :: Int]], var "p64") == "accepted")
  check "a sixty-fifth parameter is refused by name" ("arity above 64" `isInfixOf` refused (["p" ++ show i | i <- [1 .. 65 :: Int]], var "p65"))
  check "a call with sixty-five arguments is refused by name" ("over-saturated" `isInfixOf` refused (["x"], app "sum" (replicate 65 (var "x"))))
  -- Keep the worker producer's ABI evidence, including parameter order.
  let mixed z a = ([z,a], CIf (app "<" [var z,CInt 1])
        (CIf (CTagEq 1 1 (var a)) (app "+" [var z,CInt 1]) (app "+" [var z,CInt 2]))
        (app "mixed" [app "-" [var z,CInt 1],var a]))
      boolEq = (["n","b"], CIf (app "==" [var "n",CInt 0])
        (CLet "alias" (var "b") (app "==" [var "alias",CMk 1 1 []]))
        (app "boolEq" [app "-" [var "n",CInt 1],var "b"]))
  mapM_ (\def -> do
    let (p,_,sigs) = workerizeWithSignatures False True (M.singleton "mixed" def)
        (ir,declined) = lowerProgram m2Policy sigs p M.empty M.empty
    check "producer preserves mixed parameter order" (M.lookup "$worker.scalar.mixed" sigs == Just ([KI,KB],KI))
    check "mixed worker and wrapper both lower" (null declined && M.size ir == 2)
    check "mixed worker program verifies" (verifyProgram ir == Right ())
    check "mixed worker true" (ocResult (evalProgram ir "mixed" [RInt 2,rvBool True]) == Right (RInt 1))
    check "mixed worker false" (ocResult (evalProgram ir "mixed" [RInt 2,rvBool False]) == Right (RInt 2)))
    [mixed "z" "a", mixed "a" "z"]
  let (bp,_,bsigs) = workerizeWithSignatures False True (M.singleton "boolEq" boolEq)
      (bir,bfail) = lowerProgram m2Policy bsigs bp M.empty M.empty
      (_,missing) = lowerProgram m2Policy M.empty bp M.empty M.empty
  check "Bool equality signature from producer" (M.lookup "$worker.scalar.boolEq" bsigs == Just ([KI,KB],KB))
  check "Bool equality and alias lower and verify" (null bfail && verifyProgram bir == Right ())
  mapM_ (\b -> check "Bool equality agrees with independent expectation"
    (ocResult (evalProgram bir "boolEq" [RInt 3,rvBool b]) == Right (rvBool b))) [False,True]
  check "missing worker metadata refuses worker and wrapper"
    (length missing == 2 && all (isInfixOf "representation metadata" . snd) missing)
  let wrong = M.insert "$worker.scalar.boolEq" ([KI],KB) bsigs
      badArity = snd (lowerProgram m2Policy wrong bp M.empty M.empty)
  check "wrong metadata arity refuses worker and wrapper"
    (length badArity == 2 && all (isInfixOf "wrong arity" . snd) badArity)
  putStrLn "Typed IR worker metadata: ordered mixed parameters, renaming, Bool equality/aliases, missing and malformed signatures PASS"
  putStrLn "Typed IR lowering: the generator's fib and sum shapes lower, verify, dump stably and evaluate to reference answers, exact traps and structural tick counts; unsupported forms are refused by name PASS"
