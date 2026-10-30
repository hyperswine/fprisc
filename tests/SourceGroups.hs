module Main where
-- sourceGroups must keep first-occurrence name order and source clause order
-- (first-match semantics). Compared against the original list
-- formulation on interleaved clauses and non-binding tops, including a
-- large input that the old O(names * tops) version took seconds on.
import Frontend.Syntax
import Frontend.Traverse (sourceGroups)
import Data.List (nub)
import Control.Monad (unless)

reference :: [STop] -> [(String,[([SPat],[SGuard],SExpr)])]
reference tops=[(n,[(ps,g,b) | TBind n' ps g b<-tops,n'==n]) | n<-nub [n | TBind n _ _ _<-tops]]

clause n i = TBind n [PVar ("p" ++ show i)] [] (SInt i)

main :: IO ()
main = do
  let small = [clause "b" 1, TAlias "T" "M.T", clause "a" 2, clause "b" 3, TUse "M" "m", clause "c" 4, clause "a" 5]
      large = concat [[clause ("f" ++ show (i `mod` 3000)) i] | i <- [1 .. 9000 :: Integer]]
      same xs = show (sourceGroups xs) == show (reference xs)
  unless (same small) (error "sourceGroups: order differs from reference (small)")
  unless (same []) (error "sourceGroups: empty")
  unless (map fst (sourceGroups small) == ["b", "a", "c"]) (error "sourceGroups: name order")
  unless (same (take 3000 large)) (error "sourceGroups: order differs from reference (large)")
  unless (length (sourceGroups large) == 3000 && all ((== 3) . length . snd) (sourceGroups large)) (error "sourceGroups: grouping")
  putStrLn "SourceGroups: ok"
