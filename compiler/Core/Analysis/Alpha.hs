-- Scope-aware equality of representation projections. Local spellings are
-- irrelevant, while free/global symbols retain their exact home identities.
module Core.Analysis.Alpha (sameFunction) where
import Core.Syntax
import qualified Data.Map.Strict as M
sameFunction (ps,a) (qs,b)=length ps==length qs && go (M.fromList (zip ps [0..])) (M.fromList (zip qs [0..])) (length ps) a b
  where
    go left right next x y=case (x,y) of
      (CVar a,CVar b)->case (M.lookup a left,M.lookup b right) of
        (Just i,Just j)->i==j
        (Nothing,Nothing)->a==b
        _->False
      (CApp a b,CApp c d)->go left right next a c && go left right next b d
      (CLet n a b,CLet m c d)->go left right next a c && go (M.insert n next left) (M.insert m next right) (next+1) b d
      (CLam ps a,CLam qs b)->length ps==length qs && go
        (M.union (M.fromList (zip ps [next..])) left) (M.union (M.fromList (zip qs [next..])) right) (next+length ps) a b
      (CIf a b c,CIf d e f)->go left right next a d && go left right next b e && go left right next c f
      (CMk t k as,CMk u l bs)->t==u && k==l && length as==length bs && and (zipWith (go left right next) as bs)
      (CTagEq t k a,CTagEq u l b)->t==u && k==l && go left right next a b
      (CProj i a,CProj j b)->i==j && go left right next a b
      _->x==y
