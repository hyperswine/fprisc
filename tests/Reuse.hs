import FPRISC (Core(..))
import Reuse
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
  check "branch-local reuse" (marked (CIf (v "flag") rebuild rebuild))
  check "error branch" (marked (CIf (v "flag") rebuild (CErr "bad")))
  check "projected child may escape" (marked (CLet "z" (CApp (v "keep") (CProj 0 (v "r"))) rebuild))
  check "whole-value escape" (not (marked (CLet "z" (CApp (v "keep") (v "r")) rebuild)))
  check "local alias" (not (marked (CLet "z" (v "r") rebuild)))
  check "closure escape" (not (marked (CLet "z" (CLam [] (CProj 0 (v "r"))) rebuild)))
  check "shadowed binder" (not (marked (CLet "r" (CInt 0) rebuild)))
  check "invalid projection" (not (marked (mk [CProj 2 (v "r"),CInt 0])))
  check "shape mismatch" (not (marked (CMk 43 0 [CInt 0,CInt 1])))
  check "width mismatch" (not (marked (mk [CInt 0])))
  check "self reference" (not (marked (mk [v "r",CInt 0])))
  check "borrowed parameter unchanged" (reuseFresh rebuild==rebuild)
  let width n = CLet "r" (mk (replicate n (CInt 0)))
        (mk [CProj i (v "r") | i<-[0..n-1]])
      selected n=case reuseFresh (width n) of CLet _ _ b -> has b; _ -> False
  check "64 fields admitted" (selected 64)
  check "65 fields declined" (not (selected 65))
  check "node budget" (not (marked (foldr (\i b->CLet ("x"++show i) (CInt 0) b) rebuild [1..260])))
  putStrLn "Fresh reuse: nonescape, last-use, shape, branch, shadow and size proof checks PASS"
