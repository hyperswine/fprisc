-- Reuse only a fresh, local, nonescaping constructor. No runtime uniqueness
-- guess: parameters, aliases, closure captures and whole-value uses decline.
module Reuse (reuseFresh, reuseView) where
import FPRISC (Core(..))

reuseView :: Core -> Maybe (String,[Core])
reuseView (CApp (CApp (CVar "$reuse.fresh") (CVar x)) (CMk _ _ fs)) = Just (x,fs)
reuseView _ = Nothing

reuseFresh :: Core -> Core
reuseFresh = go
  where
    go e = case e of
      CLet x a b ->
        let a'=go a; b'=go b in CLet x a' $ case a' of
          CMk t v fs | not (null fs), length fs<=64,
            bounded 256 b', readsOnly x (length fs) b',
            Just out <- finish x t v (length fs) b' -> out
          _ -> b'
      CIf a b c -> CIf (go a) (go b) (go c)
      CApp a b -> CApp (go a) (go b)
      CMk t v fs -> CMk t v (map go fs)
      CProj k a -> CProj k (go a)
      CTagEq t v a -> CTagEq t v (go a)
      -- Lifted before this pass; never introduce mutation inside a closure.
      _ -> e
    finish x t v n (CMk t' v' fs)
      | (t,v,n)==(t',v',length fs) =
          Just (CApp (CApp (CVar "$reuse.fresh") (CVar x)) (CMk t v fs))
    finish x t v n (CLet y a b) = CLet y a <$> finish x t v n b
    finish x t v n (CIf c a b) = CIf c <$> finish x t v n a <*> finish x t v n b
    finish _ _ _ _ e@(CErr _) = Just e
    finish _ _ _ _ _ = Nothing

-- A projection can escape, but the parent allocation cannot. Projections are
-- evaluated before any stores, so field swaps and shared child values are safe.
readsOnly :: String -> Int -> Core -> Bool
readsOnly x width = go
  where
    go (CVar y) = x/=y
    go (CProj k (CVar y)) | x==y = k>=0 && k<width
    go (CTagEq _ _ (CVar y)) | x==y = True
    go (CLet y a b) = x/=y && go a && go b
    go (CLam ps b) = x `notElem` ps && not (mentions x b)
    go e = all go (children e)
    mentions n (CVar y) = n==y
    mentions n e = any (mentions n) (children e)

bounded :: Int -> Core -> Bool
bounded n e = length (take (n+1) (walk e))<=n
  where walk x = x : concatMap walk (children x)

children :: Core -> [Core]
children (CApp a b) = [a,b]
children (CLet _ a b) = [a,b]
children (CIf c a b) = [c,a,b]
children (CMk _ _ fs) = fs
children (CProj _ a) = [a]
children (CTagEq _ _ a) = [a]
children (CLam _ b) = [b]
children _ = []
