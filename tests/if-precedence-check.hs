-- Run with: cabal exec -- runghc -icompiler tests/if-precedence-check.hs
import FPRISC
import Text.Megaparsec (parse, errorBundlePretty)
import Control.Monad (unless, forM_)
import System.Environment (getArgs)

parsed source = case parse program "if-precedence" source of
  Left err -> error (errorBundlePretty err)
  Right tops -> show (stripPosTops tops)

same (label, a, b) = do
  unless (parsed a == parsed b) (error (label ++ ": different syntax trees"))
  putStrLn (label ++ ": OK")

main = do
  forM_ checks same
  forM_ boundaries $ \(label, a, b) -> do
    unless (parsed a /= parsed b) (error (label ++ ": grouping was lost"))
    putStrLn (label ++ ": OK")
  args <- getArgs
  case args of
    [before, after] -> do
      a <- readFile before
      b <- readFile after
      same ("whole application", a, b)
    [] -> pure ()
    _ -> error "expected zero arguments or two source paths"
  where
    checks =
      [ ("case arm with branch bindings",
         "main = case result of Err why -> fail why | Ok replay -> (if replay then check store else exe = path; cfg = setup exe; _ = serve cfg; 0).",
         "main = case result of Err why -> fail why | Ok replay -> if replay then check store else exe = path; cfg = setup exe; _ = serve cfg; 0.")
      , ("record field", "main = {watch = (if dev then src :: Nil else Nil), other = 1}.",
         "main = {watch = if dev then src :: Nil else Nil, other = 1}.")
      , ("statement RHS", "main = _ = (if moved > 0 then report moved else Unit); serve cfg.",
         "main = _ = if moved > 0 then report moved else Unit; serve cfg.")
      , ("nested conditional", "main = if a then 1 else (if b then 2 else 3).",
         "main = if a then 1 else if b then 2 else 3.")
      , ("nearest else", "main = if a then (if b then 1 else 2) else 3.",
         "main = if a then if b then 1 else 2 else 3.")
      , ("operator RHS", "main = 10 + (if c then 1 else 2).",
         "main = 10 + if c then 1 else 2.")
      , ("final argument", "main = f (if c then x else y).",
         "main = f if c then x else y.")
      , ("else owns trailing operator", "main = if c then 1 else (2 + 3).",
         "main = if c then 1 else 2 + 3.")
      , ("else owns trailing pipeline", "main = if c then x else (y |> f).",
         "main = if c then x else y |> f.")
      , ("non-final case arm", "main = case x of A -> (if c then 1 else 2) | B -> 3.",
         "main = case x of A -> if c then 1 else 2 | B -> 3.")
      ]

    boundaries =
      [ ("parentheses end conditional before pipeline",
         "main = (if c then x else y) |> f.",
         "main = if c then x else y |> f.")
      , ("parentheses end conditional before next argument",
         "main = f (if c then x else y) z.",
         "main = f if c then x else y z.")
      ]
