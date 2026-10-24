import qualified FPRISC as Compatibility
import Frontend.Syntax
import Frontend.Parser (program)
import Frontend.Traverse (sFree, stripPosTops, transformE)
import Frontend.Diagnostics (anchorMsg, bindAnchors)
import Frontend.Linearity (buildLinInfo, lcheck, shapeOfTyIn)
import Ownership.Shape (isLin)
import Modules (hashAST)
import Text.Megaparsec (parse, errorBundlePretty)
import qualified Data.ByteString.Lazy as B
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Binary (encode, decode)
import Control.Monad (unless)
import Data.List (isInfixOf)
import System.Environment (getArgs)

check label ok = unless ok (error label)
readTree src = either (error . errorBundlePretty) id (parse program "compat.fpr" src)
main = do
  [destination] <- getArgs
  src <- readFile "tests/frontend/compat.fpr"
  let tops = readTree src
      compatible :: [Compatibility.STop]
      compatible = tops
      bytes = encode tops
  check "compatibility facade preserves AST identity" (show compatible == show tops)
  check "surface Binary roundtrip" (show (decode bytes :: [STop]) == show tops)
  check "comments/positions do not change module identity"
    (hashAST tops == hashAST (readTree ("# shifted source\n\n" ++ src)))
  check "position erasure remains compatible"
    (show (stripPosTops tops) == show (Compatibility.stripPosTops tops))
  let term = SLam ["x"] (SBlock [SBind "y" [] (SVar "outside")] (SApp (SVar "x") (SVar "y")))
  check "surface scope traversal" (sFree term == ["outside"])
  let mapped = transformE (\bound e -> case e of
        SVar n | n `S.notMember` bound -> SVar ("free." ++ n)
        _ -> e) S.empty term
  check "transforms respect lambda/block binders" (sFree mapped == ["free.outside"])
  let line = head [i | (i,text) <- zip [1::Int ..] (lines src), "  items =" `isInfixOf` text]
      offset = sum (map ((+1) . length) (take (line-1) (lines src))) + 2
      message = "in helper: @" ++ show offset ++ "~ checked failure"
      expected = "compat.fpr:" ++ show line ++ ":3: in helper: checked failure"
  check "source anchor survives owner split"
    (anchorMsg (M.singleton "compat.fpr" src) (bindAnchors "compat.fpr" src tops) message == expected)
  check "unknown anchors never expose offset stamps"
    (anchorMsg M.empty M.empty "in absent: @5~ failure" == "in absent: failure")
  check "ownership evidence independent of the parser"
    (isLin (shapeOfTyIn ["Token"] (M.singleton "Holder" [("owned",TCon "Token" [])]) (TCon "Holder" [])))
  let bad = [TType "Token" True [] [("Token",[TCon "Int" []])],
             TSig "use" ([TCon "Token" []],TCon "Int" []) [Nothing],
             TBind "use" [PVar "t"] [] (STup [SVar "t",SVar "t"])]
  check "linearity still refuses duplicated owners" (not (null (lcheck (buildLinInfo bad) bad)))
  B.writeFile destination bytes
  putStrLn ("module-hash=" ++ hashAST tops)
  putStrLn "Frontend scope, anchors, ownership, cache and compatibility API checks passed"
