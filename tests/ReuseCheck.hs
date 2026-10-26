import FPRISC (Core(..))
import Reuse
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (isPrefixOf)
import Control.Monad (unless)
check label ok = unless ok (error label)
main = do
  let v=CVar; mk=CMk 42 0; initial=mk [CInt 1,CInt 2]
      rebuild=mk [CProj 1 (v "r"),CProj 0 (v "r")]
      local b=CLet "r" initial b
      marked b=case reuseFresh (local b) of CLet _ _ x -> has x; _ -> False
      has e=case reuseView e of
        Just _ -> True
        _ -> case e of
          CLet _ a b -> has a || has b
          CIf c a b -> has c || has a || has b
          _ -> False
  check "swapped projections" (marked rebuild)
  check "branch-local reuse" (marked (CIf (CMk 1 1 []) rebuild rebuild))
  check "error branch" (marked (CIf (CMk 1 1 []) rebuild (CErr "bad")))
  check "projected child can enter another constructor" (marked (CLet "z" (CMk 51 0 [CProj 0 (v "r")]) rebuild))
  check "whole-value escape" (not (marked (CLet "z" (CApp (v "keep") (v "r")) rebuild)))
  check "local alias" (marked (CLet "z" (v "r") (mk [CProj 1 (v "z"), CProj 0 (v "r")])))
  check "closure escape" (not (marked (CLet "z" (CLam [] (CProj 0 (v "r"))) rebuild)))
  check "shadowed binder" (not (marked (CLet "r" (CInt 0) rebuild)))
  check "invalid projection" (not (marked (mk [CProj 2 (v "r"),CInt 0])))
  check "shape mismatch" (not (marked (CMk 43 0 [CInt 0,CInt 1])))
  check "width mismatch" (not (marked (mk [CInt 0])))
  check "self reference" (not (marked (mk [v "r",CInt 0])))
  -- a pool reset frees the old object: no reuse across it, directly, through
  -- a field, or through a function that reaches one.
  check "no reuse across Sys.poolReset" (not (marked (CLet "z" (CApp (v "Sys.poolReset") (CInt 0)) rebuild)))
  check "no reuse when a field resets the pool" (not (marked (mk [CApp (v "Sys.poolReset") (CInt 0),CProj 0 (v "r")])))
  check "pool resetters are found transitively"
    (poolResetters (M.fromList [("boundary",(["s"],CLet "u" (CApp (v "Sys.poolReset") (CInt 0)) (v "s"))),
                                ("tidy",(["p"],CApp (v "boundary") (v "p"))),("other",(["q"],v "q"))])
      `S.intersection` S.fromList ["boundary","tidy","other"] == S.fromList ["boundary","tidy"])
  check "unknown foreign call is a reset barrier" (not (marked (CLet "z" (CApp (v "foreignReset") (CInt 0)) rebuild)))
  check "borrowed parameter unchanged" (reuseFresh rebuild==rebuild)
  let width n = CLet "r" (mk (replicate n (CInt 0)))
        (mk [CProj i (v "r") | i<-[0..n-1]])
      selected n=case reuseFresh (width n) of CLet _ _ b -> has b; _ -> False
  check "64 fields admitted" (selected 64)
  check "65 fields declined" (not (selected 65))
  check "node budget" (not (marked (foldr (\i b->CLet ("x"++show i) (CInt 0) b) rebuild [1..260])))
  let apply f xs=foldl CApp (v f) xs
      update=mk [CProj 1 (v "p"),CProj 0 (v "p")]
      call=apply "update" [v "r"]
      program body=M.fromList [("update",(["p"],update)),("entry",(["flag"],local body))]
      compile p=fst (reuseProgram (poolResetters p) S.empty p)
      private p=[n | n<-M.keys p,"$worker.consume." `isPrefixOf` n]
      selects b=not (null (private (compile (program b))))
      aliasesCall=CLet "s" (v "r") (apply "update" [v "s"])
      constants=mk [CInt 3,CInt 4] -- source does not access the old root after resetting
      viaCAF=M.fromList [("resetCAF",([],apply "Sys.poolReset" [CInt 0])),
                         ("entry",([],local (CLet "z" (v "resetCAF") constants)))]
      viaCallback=M.fromList [("invoke",(["f"],apply "f" [CInt 0])),
        ("entry",(["callback"],local (CLet "z" (apply "invoke" [v "callback"]) constants)))]
      entryHas p=has (snd (compile p M.! "entry"))
  check "no reuse across resetting CAF evaluation" (not (entryHas viaCAF))
  check "callback wrappers propagate reset effects" ("invoke" `S.member` poolResetters viaCallback && not (entryHas viaCallback))
  check "local callable is a reset barrier" (not (entryHas (M.singleton "entry"
    (["callback"],local (CLet "z" (apply "callback" [CInt 0]) constants)))))
  check "known nonresetting calls permit child escape" (entryHas (M.fromList
    [("keep",(["child"],v "child")),("entry",([],local (CLet "z" (apply "keep" [CProj 0 (v "r")]) rebuild)))]))
  check "private consuming entry" (selects call)
  check "alias consuming entry" (selects aliasesCall)
  check "branch consuming entries" (selects (CIf (v "flag") call aliasesCall))
  check "public body unchanged" (M.lookup "update" (compile (program call))==Just (["p"],update))
  check "retained alias blocks transfer" (not (selects (CLet "s" (v "r") (CLet "u" call (mk [v "u",v "s"])))))
  check "capture blocks transfer" (not (selects (CLet "closure" (CLam [] (v "r")) call)))
  check "non-tail last-use transfer" (selects (CLet "u" call (CProj 0 (v "u"))))
  check "post-transfer read blocks" (not (selects (CLet "u" call (CProj 0 (v "r")))))
  check "unknown call blocks" (not (selects (CLet "u" (apply "unknown" [v "r"]) call)))
  check "borrowed entry unchanged" $ null $ private $ compile $ M.fromList [("update",(["p"],update)),("borrow",(["r"],call))]
  check "excluded entry cannot clone" (null (private (fst (reuseProgram (S.singleton "Sys.poolReset") (S.singleton "update") (program call)))))
  check "shadowed callee cannot select" (not (selects (CLet "update" (v "unknown") call)))
  check "other argument cannot alias" $ null $ private $ compile $ M.fromList
    [("update",(["p","other"],update)),("entry",([],local (apply "update" [v "r",v "r"])))]
  let freshBranch=CLet "r" (CIf (v "flag") initial initial) rebuild
      mismatched=CLet "r" (CIf (v "flag") initial (CMk 99 0 [CInt 0])) rebuild
  check "fresh branch join" (has (reuseFresh freshBranch))
  check "different-shape branch join declined" (not (has (reuseFresh mismatched)))
  -- A transfer followed by a scalar result must not become a proof that the
  -- scalar is the original allocation, even if another helper accepts it.
  let scalarTail=CLet "u" call (CInt 9)
      trap=local (CLet "q" scalarTail (apply "update" [v "q"]))
      out=compile (M.insert "entry" ([],trap) (program call))
      calls e=case e of
        CApp a b -> calls a++calls b
        CLet _ a b -> calls a++calls b
        CIf c a b -> calls c++calls a++calls b
        CVar n | "$worker.consume." `isPrefixOf` n -> [n]
        _ -> []
  check "scalar tail does not confer uniqueness" (length (calls (snd (out M.! "entry")))<=1)
  putStrLn "Fresh reuse: nonescape, last-use, shape, branch, shadow and size proof checks PASS"
