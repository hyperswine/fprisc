-- Return the discriminant and scalar fields of a checked sum in registers.
-- The public result and any unapplied, imported or escaping call stay tagged.
module Core.Opt.VariantReturns (Plan,plans,entry,reader,regionResult) where

import Compiler.DataLayout (smallTupleLayouts)
import Core.Syntax
import Core.Utils (spineOf)
import Core.ProductABI (packName)
import Core.Opt.ProductParameters (VariantLayout)
import Control.Monad (guard)
import Data.Graph (stronglyConnComp,flattenSCC)
import Data.List (foldl')
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data Plan=Plan Name VariantLayout
entry (Plan n _)=n
width (_,variants)=1+maximum (M.elems variants)
worker layout n="$worker.ret"++show (width layout)++".$variant."++n

-- Use an ordinary Bool as the discriminant for binary sums. Wider sums use
-- the declaration's tagged Int variant number. Padding has no source value.
discriminant (_,variants) v
  | M.size variants==2=CMk 1 (if v==fst (M.findMin variants) then 0 else 1) []
  | otherwise=CInt (fromIntegral v)

data Exit=Constructed | Forward Name
plans :: Int -> Prog -> M.Map Name VariantLayout -> (M.Map Name Plan,Prog)
plans capacity prog checked=(admitted,twins)
  where
    eligible=M.filter ((<=capacity) . width) checked
    -- A source constructor call has its own entry fuel. Keep the call even
    -- without ordinary inlining, by giving the exact constructor a twin.
    makers=M.mapMaybe (\(ps,b)->case b of
      CMk tid v fields | fields==map CVar ps ->Just (tid,v,length ps)
      _->Nothing) prog
    candidates=M.mapMaybeWithKey compile eligible
    compile n layout=do
      (ps,b)<-M.lookup n prog
      guard (not (null ps) && M.notMember (worker layout n) prog)
      convert layout (S.fromList ps) b
    convert layout@(tid,vs) bound expr=case expr of
      -- ANF may name the return value before returning it directly.
      -- The RHS runs once in the original outer scope.
      CLet x a (CVar y) | x==y -> convert layout bound a
      CLet x a b->do (body,exits,aux)<-convert layout (S.insert x bound) b
                     pure (CLet x a body,exits,aux)
      CIf c a b->do (yes,xs,p)<-convert layout bound a
                    (no,ys,q)<-convert layout bound b
                    pure (CIf c yes no,xs++ys,M.union p q)
      -- Forward a nested result through its existing region boundary. The
      -- slow path moves the packet fields before closing the active region.
      CApp (CApp (CVar "$callLeave") (CVar token)) value
        | S.notMember "$callLeave" bound, S.member token bound -> do
            (packet,ends,aux)<-convert layout bound value
            let local=unused "$variant.forward"
                unused name | S.member name bound || occurs name value || M.member name prog = unused (name++"$")
                            | otherwise = name
            wrapped<-regionResult prog bound (Plan "" layout) local token packet
            pure (wrapped,ends,aux)
      CErr _->Just (expr,[],M.empty)
      CMk t v fields | t==tid, M.lookup v vs==Just (length fields)->do
        result<-pack layout bound v fields
        pure (result,[Constructed],M.empty)
      _->do
        let (callee,args)=spineOf expr
        CVar f<-Just callee
        (ps,_)<-M.lookup f prog
        let target=worker layout f
        guard (S.notMember f bound && length ps==length args && S.notMember target bound && M.notMember target prog)
        let call=foldl' CApp (CVar target) args
        case M.lookup f makers of
          Just (t,v,0) | t==tid,M.lookup v vs==Just 0->do
            -- Like lowerVal, a locally known nullary constructor is static.
            body<-pack layout bound v []
            pure (body,[Constructed],M.empty)
          Just (t,v,k) | t==tid,M.lookup v vs==Just k->do
            body<-pack layout (S.fromList ps) v (map CVar ps)
            pure (call,[Constructed],M.singleton target (ps,body))
          _->do guard (M.lookup f eligible==Just layout)
                pure (call,[Forward f],M.empty)
    pack layout bound v fields=do
      let size=width layout
          marker=packName size
      guard (S.notMember marker bound && M.notMember marker prog)
      pure (foldl' CApp (CVar marker)
              (discriminant layout v:fields++replicate (size-1-length fields) (CInt 0)))
    groups=map flattenSCC (stronglyConnComp
      [(n,n,[f | Forward f<-ends]) | (n,(_,ends,_))<-M.toList candidates])
    admitted=foldl' admit M.empty groups
    admit known names
      | all valid ends && any productive ends=foldl' add known names
      | otherwise=known
      where
        members=S.fromList names
        ends=concat [xs | n<-names,let (_,xs,_)=candidates M.! n]
        valid Constructed=True
        valid (Forward f)=S.member f members || M.member f known
        productive Constructed=True
        productive (Forward f)=M.member f known
        add m n=let layout=eligible M.! n in M.insert n (Plan (worker layout n) layout) m
    twins=M.unions [M.insert (entry plan) (fst (prog M.! n),b) aux
                   | (n,plan)<-M.toList admitted,let (b,_,aux)=candidates M.! n]

-- The pending-region protocol still executes exactly once. If allocation
-- opened a region, move all live words together through its usual copy/adopt
-- operation. The carrier tuple is local to that slow path. In particular,
-- no dynamic field is trusted to outlive the close based only on its type.
regionResult :: Prog -> S.Set Name -> Plan -> Name -> Name -> Core -> Maybe Core
regionResult prog bound (Plan _ layout) result token call=do
  let size=width layout
      marker=packName size
      local=S.insert result bound
      free n=S.notMember n local && M.notMember n prog
  guard (result/=token && all free [marker,"$callActive","$callLeave"])
  let leave x=CApp (CApp (CVar "$callLeave") (CVar token)) x
      saved=result++"$saved"
      direct=CLet saved (leave (CInt 0)) (CVar result)
      staticWord (CStr _) = True
      staticWord (CInt _) = True
      staticWord (CMk _ _ []) = True
      staticWord _ = False
      -- For a known constructor, padding and literal fields can cross the
      -- close directly. For an unknown variant only the tag is always static.
      representatives = case spineOf call of
        (CVar target,fields) | target==marker && length fields==size ->
          [(i,representative i field fields) | (i,field)<-zip [0..] fields, not (staticWord field)]
        _ -> [(i,i) | i<-[1..size-1]]
      -- Only repeated reads of a bound local are known to be identical.
      representative i field@(CVar n) fields | S.member n bound =
        maybe i id (lookup field (zip (take i fields) [0..]))
      representative i _ _ = i
      liveFields = [i | (i,j)<-representatives, i==j]
      original i=CProj i (CVar result)
      pack fields=foldl' CApp (CVar marker) fields
      positions=[(i,slot) | (i,j)<-representatives, Just slot<-[lookup j (zip liveFields [0..])]]
      rebuild i=maybe (original i) (\slot->CProj slot (CVar saved)) (lookup i positions)
  close<-case liveFields of
    [] -> pure direct
    [i] -> pure (CLet saved (leave (original i))
            (pack [if lookup j positions==Just 0 then CVar saved else original j | j<-[0..size-1]]))
    _ -> do
      (tid,v,_)<-M.lookup ("Tup"++show (length liveFields)) smallTupleLayouts
      let copied=CLet saved (leave (CMk tid v (map original liveFields)))
                   (pack (map rebuild [0..size-1]))
      pure (CIf (CApp (CVar "$callActive") (CVar token)) copied direct)
  pure (CLet result call close)

-- A packet never becomes a first-class language value. Projections require
-- the field to exist in every variant still possible on this branch.
reader :: Prog -> S.Set Name -> Plan -> Name -> Core -> Maybe Core
reader prog bound (Plan _ layout@(tid,variants)) result body=do
  guard (occurs result body)
  go (S.insert result bound) variants body
  where
    tag=CProj 0 (CVar result)
    test scope v
      | M.size variants==2=Just (CTagEq 1 (if v==fst (M.findMin variants) then 0 else 1) tag)
      | S.notMember "==" scope && M.notMember "==" prog=Just (CApp (CApp (CVar "==") tag) (discriminant layout v))
      | otherwise=Nothing
    go scope possible e=case e of
      CVar x | x==result->Nothing
      CIf (CTagEq t v (CVar x)) a b | x==result->do
        guard (t==tid)
        case M.lookup v possible of
          Nothing->go scope possible b
          Just k | M.size possible==1->go scope possible a
                 | otherwise->CIf <$> test scope v <*> go scope (M.singleton v k) a <*> go scope (M.delete v possible) b
      CTagEq t v (CVar x) | x==result->do
        guard (t==tid)
        if M.notMember v possible then pure (CMk 1 0 [])
        else if M.size possible==1 then pure (CMk 1 1 [])
        else test scope v
      CProj i (CVar x) | x==result->do
        guard (i>=0 && all (>i) possible)
        pure (CProj (i+1) (CVar result))
      CLet alias (CVar x) b | x==result -> inlineAlias alias b >>= go scope possible
      CLet x a b->CLet x <$> go scope possible a <*> (if x==result then Just b else go (S.insert x scope) possible b)
      CLam ps b | result `notElem` ps && occurs result b->Nothing
      CApp a b->CApp <$> child a <*> child b
      CIf c a b->CIf <$> child c <*> child a <*> child b
      CMk t v xs->CMk t v <$> traverse child xs
      CTagEq t v x->CTagEq t v <$> child x
      CProj i x->CProj i <$> child x
      _->Just e
      where child=go scope possible
    -- Substitute only free alias reads. Refuse a rewrite that would capture
    -- the packet name; an escaping read is still rejected by go.
    inlineAlias alias = walk
      where
        walk e = case e of
          CVar x | x==alias -> Just (CVar result)
          CLet x a b -> CLet x <$> walk a <*> under [x] b
          CLam ps b -> CLam ps <$> under ps b
          CApp a b -> CApp <$> walk a <*> walk b
          CIf c a b -> CIf <$> walk c <*> walk a <*> walk b
          CMk t v xs -> CMk t v <$> traverse walk xs
          CTagEq t v a -> CTagEq t v <$> walk a
          CProj i a -> CProj i <$> walk a
          _ -> Just e
        under names b
          | alias `elem` names = Just b
          | result `elem` names && occurs alias b = Nothing
          | otherwise = walk b
