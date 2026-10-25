-- Scope-aware renaming of private erased definitions. Shared source/checked
-- code identities remain unchanged; compatibility counters belong to a view.
module Core.Analysis.Scope (qualifyPrivate,programNames) where
import Core.Syntax
import qualified Data.Map.Strict as M
import qualified Data.Set as S

qualifyPrivate :: String -> S.Set Name -> Prog -> Prog
qualifyPrivate prefix shared input=M.fromList
  [(rename n,(ps,go (S.fromList ps) body)) | (n,(ps,body))<-M.toList input]
  where
    mapping=M.fromList [(n,prefix++n) | n<-M.keys input,n `S.notMember` shared]
    rename n=M.findWithDefault n n mapping
    go bound e=case e of
      CVar n | n `S.notMember` bound->CVar (rename n)
      CApp a b->CApp (go bound a) (go bound b)
      CLam ps b->CLam ps (go (bound<>S.fromList ps) b)
      CLet n a b->CLet n (go bound a) (go (S.insert n bound) b)
      CIf a b c->CIf (go bound a) (go bound b) (go bound c)
      CMk t k xs->CMk t k (map (go bound) xs)
      CTagEq t k x->CTagEq t k (go bound x)
      CProj i x->CProj i (go bound x)
      _->e

programNames :: Prog -> S.Set Name
programNames p=M.keysSet p<>S.unions [S.fromList ps<>names body | (ps,body)<-M.elems p]
  where
    names e=case e of
      CVar n->S.singleton n
      CApp a b->names a<>names b
      CLam ps b->S.fromList ps<>names b
      CLet n a b->S.insert n (names a<>names b)
      CIf a b c->names a<>names b<>names c
      CMk _ _ xs->S.unions (map names xs)
      CTagEq _ _ x->names x
      CProj _ x->names x
      _->S.empty
