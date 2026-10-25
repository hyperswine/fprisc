-- Callback demand and recursive stability over lexical identities.
module Core.Typed.Callback.Analysis (CallbackAnalysis,analyzeCallbacks,callbackDemands,stableCallback) where
import Core.Typed.Callback.Model
import Core.Typed.Syntax
import Core.Typed.Walk (mapChildrenM,localUses)
import Core.Identity (BinderId)
import Data.Functor.Const (Const(..))
import Data.Graph (SCC(..),stronglyConnComp)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data CallbackAnalysis=CallbackAnalysis (M.Map Target Template) (M.Map Target [Site]) (M.Map Target (S.Set Slot)) (M.Map Target (S.Set Target))
analyzeCallbacks templates=CallbackAnalysis templates sites demands groups
  where
    sites=M.map (templateSites templates) templates
    demands=demanded templates sites
    groups=M.fromList [(t,S.fromList ts) | component<-stronglyConnComp
      [(t,t,S.toList (dependencies template `S.intersection` M.keysSet templates)) | (t,template)<-M.toList templates],
      let ts=case component of AcyclicSCC t->[t];CyclicSCC xs->xs,t<-ts]
callbackDemands (CallbackAnalysis _ _ demands _)=demands
stableCallback (CallbackAnalysis templates sites demands groups) target slot=
  stableRole templates demands sites (M.findWithDefault (S.singleton target) target groups) target slot

-- Symbolic callback roles use term identities, never analysis-only spellings.
data AValue=AParam BinderId | AKnown Target [AValue] [AValue] | AOther (S.Set BinderId) deriving (Eq,Show)
data Site=Site (Either BinderId Target) (M.Map Slot AValue)
slots (Template cs ps _ _ _)=zip (map CaptureSlot [0..]) cs++zip (map ArgumentSlot [0..]) ps
bodyOf (Template _ _ body _ _)=body
refs value=case value of
  AParam uid->S.singleton uid
  AKnown _ cs ps->S.unions (map refs (cs++ps))
  AOther us->us

templateSites templates template=go initial (bodyOf template)
  where
    initial=M.fromList [(binderId b,AParam (binderId b)) | (_,b)<-slots template]
    local env uid=M.findWithDefault (AOther S.empty) uid env
    fields cs ps=M.fromList (zip (map CaptureSlot [0..]) cs++zip (map ArgumentSlot [0..]) ps)
    abstract env e=case exprNode (unNote e) of
      Var (Local uid)->local env uid
      Var (Global n _)->AKnown (RootTarget n) [] []
      ClosureValue label cs->AKnown (CodeTarget label) (map (local env) cs) []
      Apply {}->let (head',args)=spine e [] in case abstract env head' of
        AKnown target cs leading | Just (Template _ ps _ _ _)<-M.lookup target templates,
          length leading+length args<length ps->AKnown target cs (leading++map (abstract env) args)
        _->AOther (S.unions (map (refs . abstract env) (head':args)))
      _->AOther (S.unions [refs (local env uid) | uid<-localUses e])
    patternEnv env p value=case patNode p of
      Bind b->M.insert (binderId b) value env
      _->foldr (\b->M.insert (binderId b) (AOther S.empty)) env (patternBinders p)
    alt env args (Alternative ps guards body)=guards' (foldl (\s (p,v)->patternEnv s p v) env (zip ps args)) guards
      where
        guards' scope []=go scope body
        guards' scope (BoolGuard x:rest)=go scope x++guards' scope rest
        guards' scope (PatternGuard p x:rest)=go scope x++guards' (patternEnv scope p (abstract scope x)) rest
    go env e=case exprNode e of
      Let b rhs body->go env rhs++go (M.insert (binderId b) (abstract env rhs) env) body
      LetPattern p rhs body->go env rhs++go (patternEnv env p (abstract env rhs)) body
      MatchTail _ args alternatives fallback->concatMap (go env) args
        ++concatMap (alt env (map (abstract env) args)) alternatives++go env fallback
      ClosureValue label cs->[Site (Right (CodeTarget label)) (fields (map (local env) cs) [])]
      CodeCall label cs ps->Site (Right (CodeTarget label)) (fields (map (local env) cs) (map (abstract env) ps)):concatMap (go env) ps
      JoinCall label cs ps->Site (Right (CodeTarget label)) (fields (map (local env) cs) (map (abstract env) ps)):concatMap (go env) ps
      Apply {}->let (head',args)=spine e []
                    site=case abstract env head' of
                      AParam uid->[Site (Left uid) M.empty]
                      AKnown target cs leading->[Site (Right target) (fields cs (leading++map (abstract env) args))]
                      _->[]
                in site++concatMap (go env) (head':args)
      _->getConst (mapChildrenM (Const . go env) e)

demanded templates sites=fix (M.map (const S.empty) templates)
  where
    step old=M.mapWithKey (\target template->S.fromList
      [slot | (slot,b)<-slots template,any (uses old (binderId b)) (sites M.! target)]) templates
    uses _ uid (Site (Left called) _)=uid==called
    uses old uid (Site (Right target) values)=any
      (\slot->M.lookup slot values==Just (AParam uid)) (S.toList (M.findWithDefault S.empty target old))
    fix old=let new=step old in if old==new then old else fix new

stableRole templates demands sites group start slot=visit S.empty [(start,slot)]
  where
    roleParameter target position=binderId <$> (M.lookup target templates >>= lookup position . slots)
    visit _ []=True
    visit seen (role@(target,position):rest)
      | role `S.member` seen=visit seen rest
      | otherwise=case M.lookup target sites of
          Nothing->visit (S.insert role seen) rest
          Just ss->let parameter=roleParameter target position
                       edges=[(t,p,value) | Site (Right t) values<-ss,t `S.member` group,
                         p<-S.toList (M.findWithDefault S.empty t demands),Just value<-[M.lookup p values]]
                       same value=case (parameter,value) of (Just uid,AParam used)->uid==used;_->False
                       changed (t,p,value)=not (same value) &&
                         (maybe False (`S.member` refs value) parameter || (t,p) `S.member` S.insert role seen)
                       forwarded=[(t,p) | (t,p,value)<-edges,same value]
                   in not (any changed edges) && visit (S.insert role seen) (forwarded++rest)

dependencies template=go (bodyOf template)
  where
    go e=(case exprNode e of
      Var (Global n _)->S.singleton (RootTarget n)
      ClosureValue label _->S.singleton (CodeTarget label)
      CodeCall label _ _->S.singleton (CodeTarget label)
      JoinCall label _ _->S.singleton (CodeTarget label)
      _->S.empty)<>getConst (mapChildrenM (Const . go) e)
