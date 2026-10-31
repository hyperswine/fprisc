module Main where
-- Numeric defaulting visits only sites that may still be a bare type
-- variable. The work counter is deterministic and grows linearly with the
-- number of independent groups (the old whole-map scan was quadratic), and
-- an earlier group's still-unsolved site is still defaulted by a later group.
import Frontend.Parser (program)
import Infer
import Struct (sigTable,structTable)
import Text.Megaparsec (parse,errorBundlePretty)
import Control.Monad (unless)

work :: String -> (Int, [String])
work source =
  let tops=either (error . errorBundlePretty) id (parse program "w.fpr" source)
      r=inferTopsResult Nothing aotProf (sigTable tops) (structTable tops) tops
  in (inferenceDefaultingWork r, inferenceErrors r)

wide :: Int -> String
wide n=concat ["f"++show i++" x = x + "++show i++".\n" | i<-[0..n-1]]++"main = f0 1.\n"

main :: IO ()
main = do
  let ws=[fst (work (wide n)) | n<-[50,100,200,400]]
  unless (all null [snd (work (wide n)) | n<-[50,400]]) (error "unexpected inference errors")
  unless (ws==[fst (work (wide n)) | n<-[50,100,200,400]]) (error "work counter not deterministic")
  unless (and (zipWith (\a b->b<=2*a+8) ws (tail ws))) (error ("defaulting work is not linear: "++show ws))
  unless (head ws>=50) (error ("defaulting did not visit the sites: "++show ws))
  putStrLn ("DefaultingWorklist: work "++show ws++" linear, deterministic PASS")
