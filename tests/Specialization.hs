{-# LANGUAGE LambdaCase #-}
import FPRISC
import Mono
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Control.Monad (unless)

app n = foldl CApp (CVar n)
check label condition = unless condition (error label)
main = do
  -- A mutual group with two callbacks must close over clone identities,
  -- and never retain the removed callback as a parameter or indirect head.
  let p = M.fromList
        [("inc",(["x"],app "+" [CVar "x", CInt 1])),
         ("even",(["f","n"],CIf (app "==" [CVar "n",CInt 0]) (CInt 0)
             (app "odd" [CVar "f", app "f" [CVar "n"]]))),
         ("odd",(["f","n"],app "even" [CVar "f",CVar "n"])),
         ("main",([],app "even" [CVar "inc",CInt 4]))]
      out = specializeFunctions "test" (M.fromList [("+",2),("==",2)]) M.empty p
      extra = out `M.difference` p
  check "mutual group must converge to two clones" (M.size extra == 2)
  check "callback parameters must be removed" (all ((==1) . length . fst) (M.elems extra))
  check "clones must call clones, not generic recursive group" (all (S.null . S.intersection (S.fromList ["even","odd"]) . uncurry references) (M.elems extra))
  -- Lexical globals are not static callbacks. A dynamic record projection
  -- is never baked in, even when a same-spelled global exists.
  let shadow = M.insert "main" (["inc"], app "even" [CVar "inc",CInt 4]) p
  check "shadowed global must stay dynamic" (M.size (specializeFunctions "shadow" M.empty M.empty shadow) == M.size p)
  let dynamic = M.insert "main" (["record"], app "even" [CProj 0 (CVar "record"),CInt 4]) p
  check "record callback must stay dynamic" (M.size (specializeFunctions "dynamic" M.empty M.empty dynamic) == M.size p)
  -- Imported lifts must be copied with a caller-private identity.
  let aux = qualifyAux "$specaux.unit." (S.singleton "public")
        (M.fromList [("public",(["f","x"],app "lifted_0" [CVar "f",CVar "x"])),
                     ("lifted_0",(["f","x"],app "f" [CVar "x"]))])
      imported = specializeFunctions "import" M.empty aux
        (M.fromList [("inc",p M.! "inc"),("main",([],app "public" [CVar "inc",CInt 1]))])
  check "private lift must specialize transitively" (M.size imported == 4)
  -- Expanding recursive callback identities cannot grow without a bound.
  let runaway = M.fromList [("wrap",(["f","x"],app "f" [app "f" [CVar "x"]])),
            ("go",(["f","n"],app "go" [app "wrap" [CVar "f"],CVar "n"])),
            ("inc",p M.! "inc"),("main",([],app "go" [CVar "inc",CInt 1]))]
      bounded = specializeFunctions "budget" M.empty M.empty runaway
  check "changing recursive callbacks must stay dynamic" (M.size bounded == M.size runaway)
  -- The clone-count budget leaves excess sites as the original calls.
  let many = M.fromList ([ ("cb" ++ show i, (["x"],CVar "x")) | i <- [1..300] ] ++
             [("apply",(["f","x"],app "f" [CVar "x"])),
              ("main",([],CMk 10 0 [app "apply" [CVar ("cb" ++ show i),CInt i] | i <- [1..300]]))])
      capped = specializeFunctions "count" M.empty M.empty many
  check "clone count budget must retain excess generic calls" (M.size capped == M.size many + 256)
  -- Expensive definitions hit the node budget, even below the count limit.
  let huge = M.insert "apply" (["f","x"], CMk 10 0 (replicate 2000 (app "f" [CVar "x"]))) many
      weighed = specializeFunctions "size" M.empty M.empty huge
  check "node budget must bound total clone expansion" (M.size weighed < M.size huge + 20)
  -- A legal 64-argument callee specialized on a two-capture callback
  -- would need 65 parameters. The original PAP path remains a fallback.
  let wide = M.fromList [("wide",("f" : map (('p':) . show) [1..63],app "f" [CInt 1])),
              ("cb",(["a","b","x"],CVar "x")),
              ("main",([],app "wide" (app "cb" [CInt 1,CInt 2] : replicate 63 (CInt 1))))]
  check "ABI-oversized clones must stay dynamic" (M.size (specializeFunctions "wide" M.empty M.empty wide) == M.size wide)
  putStrLn "Specialization Core: recursive groups, shadowing, dynamic callbacks, imported lifts, bounded growth: PASS"
