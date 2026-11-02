module Main where

import qualified Data.Binary as Bin
import qualified Data.Map.Strict as M
import Control.Monad (unless, forM_)
import Frontend.Parser (program)
import Frontend.Syntax
import Infer
import qualified Sol.Infer as Sol
import Sol.ReplParse (appendCommand)
import Struct (sigTable, structTable)
import Text.Megaparsec (parse, errorBundlePretty)

readTops :: String -> [STop]
readTops = either (error . errorBundlePretty) id . parse program "<repl>"
assert :: String -> Bool -> IO ()
assert msg ok = unless ok (error msg)
check old tops = Sol.inferSession old (sigTable tops) (structTable tops) tops

main :: IO ()
main = do
  -- Command parsing retains EXACT marks, including UTF-8 text before an
  -- error, guards, nested expressions and signature preconditions.
  let commands = ["# λ and 🦀\nidentity x = x.\n", "positive : (n : Int | n > 0) -> Int.\n",
                  "positive n = n + 1.\n", "record = {a = 1, b = identity}.\n",
                  "> identity \"é🦀\".\n", "nested x =\n  case x of True -> 1 | False -> 2.\n"]
      go _ _ [] = pure ()
      go src accepted (command:rest) = do
        let src' = src ++ command
            tops = appendCommand (length src) accepted (readTops command)
        assert "delta parse changed source marks" (Bin.encode tops == Bin.encode (readTops src'))
        go src' tops rest
  go "" [] commands

  let source = concat ["f" ++ show i ++ " x = x + " ++ show i ++ ".\n" | i <- [0..399::Int]]
      initial = readTops source
      (first, snapshot, firstCount) = check Nothing initial
  assert "initial definitions rejected" (null (inferenceErrors first))
  assert "initial snapshot missing" (case snapshot of Just _ -> True; _ -> False)
  assert "unexpected initial reuse" (firstCount == 0)
  let query = readTops (source ++ "> f399 1.\n> f0 2.\n")
      (fast, _, reused) = check snapshot query
      full = Sol.inferResult (sigTable query) (structTable query) query
  assert "query did not reuse definitions" (reused == 400)
  assert "cached rewrite differs" (Bin.encode (inferenceTops fast) == Bin.encode (inferenceTops full))
  assert "cached errors differ" (inferenceErrors fast == inferenceErrors full)
  assert "definitions were inferred again" (inferenceDefaultingWork fast == 0 && inferenceDefaultingWork full >= 400)
  assert "ownership metadata differs" (show (inferenceLinearity fast) == show (inferenceLinearity full))

  -- Fresh definitions are checked against the closed interfaces; old bodies
  -- and interfaces must be exact. New bindings that could shadow old names
  -- (including implicit operator/member targets) conservatively check it all.
  let appended = readTops (source ++ "added x = f0 x + 1.\n")
      (newResult,newSnapshot,newCount) = check snapshot appended
  assert "fresh helper did not reuse old definitions" (newCount == 400 && null (inferenceErrors newResult))
  assert "new helper was not checked" (inferenceDefaultingWork newResult == 1)
  let badAppend = readTops (source ++ "added x = f0 True.\n")
      (badNew,_,badCount) = check snapshot badAppend
  assert "bad new helper was not checked" (badCount == 400 && not (null (inferenceErrors badNew)))
  let (_,_,allNew) = check newSnapshot (readTops (source ++ "added x = f0 x + 1.\n> added 1.\n"))
  assert "new helper interface not retained" (allNew == 401)
  let ordinaryAppend = Sol.inferResult (sigTable appended) (structTable appended) appended
  assert "new helper changed elaboration" (Bin.encode (inferenceTops newResult) == Bin.encode (inferenceTops ordinaryAppend))
  -- Type interfaces, imported body edits and new clauses invalidate.
  forM_ [source ++ "T = Type (A | B).\n",
         "f0 x = x + 999.\n" ++ concat ["f" ++ show i ++ " x = x + " ++ show i ++ ".\n" | i <- [1..399::Int]]] $ \changed -> do
    let (_,_,count) = check snapshot (readTops changed)
    assert "changed definitions reused" (count == 0)
  let (_,_,changedTables) = Sol.inferSession snapshot M.empty (M.singleton "New" ([],[])) query
  assert "changed external interface reused" (changedTables == 0)

  forM_ ["identity x = x.\n", "get r = r.a.\n", "choose True x = x.\nchoose False x = x.\n"] $ \defs -> do
    let tops = readTops defs
        (_,old,_) = check Nothing tops
        es | take 3 defs == "get" = "> get {a = 1}.\n> get {a = \"str\", b = True}.\n"
           | take 6 defs == "choose" = "> choose True 1.\n> choose False \"str\".\n"
           | otherwise = "> identity 1.\n> identity \"str\".\n"
        trial = readTops (defs ++ es)
        (result,_,count) = check old trial
        ordinary = Sol.inferResult (sigTable trial) (structTable trial) trial
    assert "polymorphic definitions not reused" (count == 1)
    assert "polymorphic reuse failed" (null (inferenceErrors result))
    assert "polymorphic clause order changed" (Bin.encode (inferenceTops result) == Bin.encode (inferenceTops ordinary))

  forM_ ["bad = 1 + True.\n", "missing x = ?? .\n", "missing x = ?named.\n"] $ \defs -> do
    let (_,snapshot',_) = check Nothing (readTops defs)
    assert "failed/holed check published a snapshot" (case snapshot' of Nothing -> True; _ -> False)

  forM_ [("size x = strlen x.\n", readTops "strlen x = True.\n"),
         ("arithmetic x = x + 1.\n", [TBind "Fresh.+" [PVar "x", PVar "y"] [] (SInt 1)]),
         ("member x = x.a.\n", [TBind "Fresh.a" [PVar "x"] [] (SInt 1)])] $ \(defs, added) -> do
    let (_,old,_) = check Nothing (readTops defs)
        (_,_,count) = check old (readTops defs ++ added)
    assert "shadowing/member candidate reused old definitions" (count == 0)

  let bad = readTops (source ++ "> f0 True.\n")
      (refused,next,count) = check snapshot bad
  assert "invalid eval was not checked" (count == 400 && not (null (inferenceErrors refused)))
  assert "failed eval published a snapshot" (case next of Nothing -> True; _ -> False)
  putStrLn "SolReplIncremental: marks, closed schemes, exact invalidation, polymorphism, clause order, work avoidance and rejection PASS"
