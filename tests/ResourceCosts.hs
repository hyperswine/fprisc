module ResourceCosts (checkResourceCosts) where

import Control.Monad (unless)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Cost as C
import Core.Syntax
import Safety (Measure(..),MeasureKind(..))

check label yes = unless yes (error ("resource costs: " ++ label))
app n = foldl CApp (CVar n)
v = CVar
dec = app "-" [v "n",CInt 1]
cond = app "<=" [v "n",CInt 0]
node xs = CMk 20 1 xs
measure n ps group = Measure n ps (MLinear (M.singleton "n" 1) 0) 1 group
derive defs measures = M.map fst (C.costProgram measures M.empty (M.fromList defs))
allocs eqs n = C.ceAlloc (eqs M.! n)
work eqs n = C.ceWork (eqs M.! n)

checkResourceCosts :: IO ()
checkResourceCosts = do
  let measured = M.singleton "grow" (measure "grow" ["n"] ["grow"])
      recurse = app "grow" [dec]
      binary = (["n"],CIf cond (CMk 20 0 []) (node [recurse,recurse]))
      branching = derive [("grow",binary),("main",([],app "grow" [CInt 5]))] measured
  -- A full binary tree of depth five has 31 allocating internal nodes:
  -- 744 requested bytes, already greater than the old linear 24*(5+1)=144.
  check "branching recursion cannot borrow a linear depth allocation bound"
    (C.hasOmega (allocs branching "main") && C.hasOmega (work branching "grow"))
  check "a previously accepted undersized contract is unproved"
    (case C.checkBounds (allocs branching "grow") (C.CAdd [C.CMul [C.CN 24,C.CP "n"],C.CN 24]) of
      C.Unproved _ -> True; _ -> False)
  let cases =
        [ ("exclusive", CIf cond (CInt 0) (CIf (v "flag") (node [recurse]) (node [recurse])))
        , ("sequence", CIf cond (CInt 0) (CLet "a" recurse (node [recurse])))
        , ("condition", CIf cond (CInt 0) (CIf recurse (node [recurse]) (CInt 0)))
        , ("argument", CIf cond (CInt 0) (app "grow" [recurse]))
        , ("escaped", CIf cond (CInt 0) (app "unknown" [v "grow"]))
        , ("alias", CIf cond (CInt 0) (CLet "g" (v "grow") (app "g" [dec])))
        ]
  mapM_ (\(label,body) -> let eqs=derive [("grow",(["n"],body))] measured in
    check label (C.hasOmega (work eqs "grow") == (label /= "exclusive"))) cases
  let noAlloc = derive [("grow",(["n"],CIf cond (CInt 0) (app "+" [recurse,recurse])))] measured
  check "allocation-free branching keeps its zero allocation fact"
    (allocs noAlloc "grow" == C.CN 0 && C.hasOmega (work noAlloc "grow"))
  let mutual = M.fromList [(n,measure n ["n"] ["left","right"]) | n<- ["left","right"]]
      eqs = derive [("left",(["n"],CIf cond (CInt 0) (node [app "right" [dec],app "right" [dec]]))),
                    ("right",(["n"],CIf cond (CInt 0) (app "left" [dec])))] mutual
  check "fanout in a mutual partner invalidates the group's linear multiplier"
    (all (C.hasOmega . allocs eqs) ["left","right"])

  let stringBody next = CIf cond (CInt 0)
        (CLet "allocated" (app "strcat" [v "s",v "s"]) (app "grow" [dec,next]))
      stringCosts next = derive [("grow",(["n","s"],stringBody next))]
        (M.singleton "grow" (measure "grow" ["n","s"] ["grow"]))
  check "unchanged per-step payload length remains composable"
    (not (C.hasOmega (allocs (stringCosts (v "s")) "grow")))
  check "growing payload lengths cannot be bounded by the initial payload"
    (C.hasOmega (allocs (stringCosts (v "allocated")) "grow"))
  let callback = derive [("grow",(["n","f"],CIf cond (CInt 0)
        (CLet "answer" (app "f" [CInt 0]) (CLet "alias" (v "f") (app "grow" [dec,v "alias"])))))]
        (M.singleton "grow" (measure "grow" ["n","f"] ["grow"]))
  check "unchanged callback costs survive local aliases"
    (not (C.hasOmega (allocs callback "grow")))

  let functions = [("f",(["a","b","c"],v "a")),
                   ("partial",([],app "f" [CInt 1])),
                   ("partial2",([],app "f" [CInt 1,CInt 2]))]
      partials = derive functions M.empty
  check "PAP allocation reserves its full three-slot capacity"
    (allocs partials "partial" == C.CN 56 && allocs partials "partial2" == C.CN 56)
  let oversaturated = derive [("f",(["x"],v "x")),("over",([],app "f" [CInt 1,CInt 2]))] M.empty
  check "over-application has no invented returned-callable resource contract"
    (C.hasOmega (allocs oversaturated "over") && C.hasOmega (work oversaturated "over"))
  let shadows = derive [("f",(["x"],CInt 0)),
        ("param",(["f"],app "f" [CInt 0])),
        ("local",([],CLet "f" (app "unknown" []) (app "f" [CInt 0]))),
        ("primitive",(["strlen"],app "strlen" [CStr "hello"])),
        ("lambda",([],CLam ["x"] (v "x")))] M.empty
  check "parameter shadow cannot inherit a global's allocation-free contract"
    (allocs shadows "param" == C.CA "f")
  check "primitive shadow is a callback, not the builtin"
    (allocs shadows "primitive" == C.CA "strlen")
  check "local shadow and unlifted lambda stay unproved"
    (C.hasOmega (allocs shadows "local") && C.hasOmega (allocs shadows "lambda"))

  -- A measure bounds recursive depth only above its floor. A negative entry
  -- still executes the base case, and must never make its cost negative.
  let signedBody = CIf cond (node [CInt 0]) (app "grow" [dec])
      signed = derive [("grow",(["n"],signedBody))] measured
      at n = derive [("grow",(["n"],signedBody)),("main",([],app "grow" [CInt n]))] measured
  mapM_ (\n -> check ("negative/base measure " ++ show n)
    (allocs (at n) "main" == C.CN 16)) [-(2^63),-20,-1,0]
  check "a negative span still executes one body"
    (let spanMeasure = Measure "grow" ["n","lim"]
            (MLinear (M.fromList [("n",-1),("lim",1)]) 0) 1 ["grow"]
         eqs = derive [("grow",(["n","lim"],CIf (app ">=" [v "n",v "lim"])
                     (node [CInt 0]) (app "grow" [app "+" [v "n",CInt 1],v "lim"]))),
                       ("main",([],app "grow" [CInt 10,CInt (-10)]))]
                 (M.singleton "grow" spanMeasure)
     in allocs eqs "main" == C.CN 16)
  let unknownSpan = derive
        [("seed",(["x"],app "+" [v "x",CInt 1])),
         ("walk",(["i","lim"],CIf (app ">=" [v "i",v "lim"]) (node [CInt 0])
           (node [app "walk" [app "+" [v "i",CInt 1],v "lim"]]))),
         ("main",([],app "walk" [app "seed" [CInt 0],app "seed" [CInt 5]]))]
        (M.singleton "walk" (Measure "walk" ["i","lim"]
          (MLinear (M.fromList [("i",-1),("lim",1)]) 0) 1 ["walk"]))
  check "different unknown arguments cannot cancel in a span measure"
    (C.hasOmega (allocs unknownSpan "main"))
  check "unknown values cannot witness equality by sharing a placeholder"
    (C.checkBounds (C.CV "?") (C.CV "?") /= C.Proven &&
     C.hasOmega (C.CAdd [C.CV "?",C.CMul [C.CN (-1),C.CV "?"]]) &&
     C.evalConst (C.CAdd [C.CV "?",C.CMul [C.CN (-1),C.CV "?"]]) == Nothing)
  let n = C.CP "n"; m = C.CP "m"; len = C.CLen "xs"
      add a b = C.CAdd [a,b]
      mul a b = C.CMul [a,b]
      neg a = mul (C.CN (-1)) a
      max2 a b = C.CMax [a,b]
      rejects a b = C.checkBounds a b /= C.Proven
  check "unconstrained signed inputs do not inherit a natural domain"
    (rejects (C.CN 0) n && rejects (allocs signed "grow") (mul (C.CN 16) (add n (C.CN 1))))
  check "explicit nonnegative domain preserves valid linear bounds"
    (C.checkBoundsUnderWith (S.singleton "n") id (allocs signed "grow")
      (mul (C.CN 16) (add n (C.CN 1))) == C.Proven)
  check "explicit clamp preserves signed callers"
    (C.checkBounds (allocs signed "grow") (mul (C.CN 16) (add (max2 (C.CN 0) n) (C.CN 1))) == C.Proven)
  check "max preserves a constant branch above a negative signed parameter"
    (C.prettyCost (max2 (C.CN 0) n) == "max(0, n)")
  check "signed terms can cancel and even powers stay nonnegative"
    (C.checkBounds n (add n (C.CN 1)) == C.Proven &&
     C.checkBounds (C.CN 0) (mul n n) == C.Proven)
  check "declared max is not a coefficient-wise envelope"
    (rejects (add len (C.CN 1)) (max2 len (C.CN 1)) &&
     rejects (C.CN 2) (max2 len (C.CN 1)))
  check "negative coefficients present only in declaration are checked"
    (rejects (C.CN 0) (add (C.CN 1) (neg len)))
  check "ceil upper estimate is not accepted as a declared lower budget"
    (rejects (add (mul (C.CN 2) (C.CDivC len 2)) (C.CN 1)) (add len (C.CN 1)) &&
     rejects (C.CN 1) (C.CDivC (C.CN 0) 2))
  check "ceil bounds use the correct polarity"
    (C.checkBounds (C.CDivC len 2) (add len (C.CN 1)) == C.Proven &&
     C.checkBounds (C.CN 0) (C.CDivC len 2) == C.Proven)

  -- Independent integer evaluation checks every claimed proof over signed
  -- values and both machine limits. It includes max under negative/signed
  -- products, nested maxima, ceiling division and declaration-only terms.
  check "opaque values stay signed but opaque resource costs stay nonnegative"
    (C.prettyCost (C.CMax [C.CN 0,C.CV "?"]) == "max(0, ω(?))" &&
     C.prettyCost (C.CMax [C.CN 0,C.CO "f"]) == "ω(f)" &&
     C.evalConst (C.resolvePrims (const (Just (-3))) (C.CNat (C.CV "?"))) == Nothing)
  let expressions = [C.CN (-1),C.CN 0,C.CN 1,C.CN 2,n,m,len,
        neg n,neg len,add n (C.CN 1),add len (C.CN 1),add (C.CN 1) (neg len),
        mul n n,mul n m,mul len len,max2 n m,max2 n (C.CN 1),
        max2 len (C.CN 1),max2 (neg n) (C.CN 0),C.CNat n,C.CNat (neg n),
        mul (C.CN (-2)) (max2 n m),mul n (max2 m (C.CN 1)),
        max2 (add n m) (C.CN 2),add (max2 n m) (max2 (neg n) (neg m)),
        C.CDivC n 2,C.CDivC len 2,neg (C.CDivC n 2),
        add (mul (C.CN 2) (C.CDivC len 2)) (C.CN 1),
        mul (C.CDivC n 2) (C.CDivC n 2),C.CNat (C.CDivC n 2)]
      values = [-(2^63),-(2^62),-3,-1,0,1,3,2^62-1,2^63-1]
      eval x y z expr = case expr of
        C.CN k -> k
        C.CP "n" -> x
        C.CP "m" -> y
        C.CLen _ -> z
        C.CAdd xs -> sum (map (eval x y z) xs)
        C.CMul xs -> product (map (eval x y z) xs)
        C.CMax xs -> maximum (map (eval x y z) xs)
        C.CNat e -> max 0 (eval x y z e)
        C.CDivC e k -> (eval x y z e + k - 1) `div` k
        _ -> error "unexpected resource oracle atom"
      proofs = [(a,b) | a <- expressions,b <- expressions,C.checkBounds a b == C.Proven]
  mapM_ (\(a,b) -> check ("signed exhaustive oracle: " ++ show (a,b))
    (and [eval x y z a <= eval x y z b | x <- values,y <- values,z <- [0,1,3,100]])) proofs
  let domains=[[n],[add m (neg n)],[add (C.CN 3) (neg n)],[add len (C.CN (-1))]]
  mapM_ (\facts -> mapM_ (\(a,b) -> check ("path-fact oracle: "++show (facts,a,b))
      (and [eval x y z a <= eval x y z b | x<-values,y<-values,z<-[0,1,3,100],
            all (\f->eval x y z f>=0) facts]))
    [(a,b) | a<-expressions,b<-expressions,C.checkBoundsAssuming facts a b==C.Proven]) domains

  let encoded=map toEnum [0xc3,0xa9,0xce,0xbb,0xf0,0x9f,0x99,0x82]
      strings=derive [("main",([],app "strcat" [CStr encoded,CStr encoded]))] M.empty
  check "resource String lengths use UTF-8 bytes rather than code points"
    (allocs strings "main" == C.CN 32)
  let fact=C.CAdd [C.CP "hi",C.CMul [C.CN (-1),C.CP "lo"]]
  check "a checked path fact can witness a signed affine inequality"
    (C.checkBoundsAssuming [fact] (C.CN 0) (C.CAdd [fact,C.CN 1]) == C.Proven &&
     C.checkBounds (C.CN 0) (C.CAdd [fact,C.CN 1]) /= C.Proven)

  let producer=("make",(["n"],CStr "abcdefgh"))
      consumer=("use",(["n"],app "strcat" [app "make" [v "n"],app "make" [v "n"]]))
      forged=M.singleton "make" (C.Declared Nothing Nothing Nothing (Just (C.CN 0)))
      untrusted=C.costProgram M.empty forged (M.fromList [producer,consumer])
  check "an unchecked result-size annotation cannot supply a caller length"
    (C.hasOmega (C.ceAlloc (fst (untrusted M.! "use"))))
  let nonmonotone=M.singleton "consume" (C.Declared
        (Just (C.CNat (C.CAdd [C.CN 10,C.CMul [C.CN (-1),C.CLen "xs"]]))) Nothing Nothing Nothing)
      source=M.fromList [("make",(["flag"],CIf (v "flag") (CMk 2 0 []) (CMk 2 0 []))),("consume",(["xs"],CInt 0)),
                        ("main",([],app "consume" [app "make" [CInt 1]]))]
      composed=C.costProgramForWithSizes (M.singleton "make" (C.CN 10)) (M.keysSet source) M.empty nonmonotone source
  check "an upper size estimate cannot reduce a decreasing callee budget"
    (C.hasOmega (C.ceWork (fst (composed M.! "main"))))
  let fakeList=derive [("main",([],app "strcat" [CMk 77 1 [CInt 1,CMk 77 0 []],CStr ""]))] M.empty
  check "two fields do not establish builtin list length"
    (C.hasOmega (allocs fakeList "main"))

  -- An accumulator consed onto at every step is read only by the exit path:
  -- the chain charges that path once, at the accumulator's grown length.
  let structural n p = Measure n [p] (MStructural p) 1 [n]
      isNil x = CTagEq 2 0 x
      count = ("count",(["ys"],CIf (isNil (v "ys")) (CInt 0) (app "count" [CProj 1 (v "ys")])))
      walkWith exitE nextAcc = derive
        [count,
         ("walk",(["xs","acc"],CIf (isNil (v "xs")) exitE
            (app "walk" [CProj 1 (v "xs"),nextAcc]))),
         ("main",([],app "walk" [CMk 2 1 [CInt 1,CMk 2 1 [CInt 2,CMk 2 0 []]],CMk 2 0 []]))]
        (M.fromList [("count",structural "count" "ys"),("walk",structural "walk" "xs")])
      consed = walkWith (app "count" [v "acc"]) (CMk 2 1 [CProj 0 (v "xs"),v "acc"])
      atEntry = derive [count,("main",([],app "count" [CMk 2 1 [CInt 1,CMk 2 1 [CInt 2,CMk 2 0 []]]]))]
        (M.singleton "count" (structural "count" "ys"))
  check "a consed accumulator read on the exit path has a linear bound"
    (not (C.hasOmega (work consed "walk")) && not (C.hasOmega (work consed "main")))
  -- count costs 4 per cell plus 4. Each of walk's steps costs 6; its exit
  -- (if, tag test, the call) is 3 plus count over every consed cell, not
  -- over the entry accumulator alone. For main's 2-cell input that is
  -- 2*6 + 3 + 12, plus the call and four list cells: 32 (count over the
  -- same 2 cells alone, with its call and three cells, is 16).
  check "the exit path is charged at the grown accumulator length"
    (C.prettyCost (work consed "walk") == "6\183len xs + 4\183(len acc + len xs + 1) + 3" &&
     C.evalConst (work consed "main") == Just 32 && C.evalConst (work atEntry "main") == Just 16)
  check "an accumulator that grows by an unknown amount stays opaque"
    (C.hasOmega (work (walkWith (app "count" [v "acc"]) (app "strcat" [v "acc",v "acc"])) "walk"))
  check "a consed accumulator read on every step stays opaque"
    (let body = CIf (isNil (v "xs")) (CInt 0)
                  (CLet "n" (app "count" [v "acc"]) (app "walk" [CProj 1 (v "xs"),CMk 2 1 [v "n",v "acc"]]))
         eqs = derive [count,("walk",(["xs","acc"],body))]
                 (M.fromList [("count",structural "count" "ys"),("walk",structural "walk" "xs")])
      in C.hasOmega (work eqs "walk"))
