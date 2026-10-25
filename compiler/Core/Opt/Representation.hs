-- Compiler Layout casts are representation identities. Keep their erasure in
-- one owner so region/cost analysis and native emission see the same program.
module Core.Opt.Representation (eraseLayoutCasts) where
import Core.Syntax
import qualified Data.Map.Strict as M

eraseLayoutCasts :: Prog -> Prog
eraseLayoutCasts=M.map (fmap go)
  where
    go c=case c of
      CApp (CVar "$cast") x->go x
      CApp f x->CApp (go f) (go x)
      CLam ps b->CLam ps (go b)
      CLet n a b->CLet n (go a) (go b)
      CIf a b c->CIf (go a) (go b) (go c)
      CMk t k xs->CMk t k (map go xs)
      CTagEq t k x->CTagEq t k (go x)
      CProj i x->CProj i (go x)
      _->c
