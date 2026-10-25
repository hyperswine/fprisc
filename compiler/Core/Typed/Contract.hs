-- Checked code interfaces. Code quantifiers are distinct from each captured
-- value's own forall; one instantiation relates captures, arguments and result.
module Core.Typed.Contract (codeContracts,checkInstance) where
import Core.Typed.Syntax
import Core.Typed.Walk (mapChildrenM)
import Type.Syntax
import Type.Substitution
import Control.Monad (unless,foldM)
import Data.Functor.Const (Const(..))
import Data.List (nub,sortOn)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

codeContracts :: M.Map String Scheme -> M.Map CodeId CodeFunction -> M.Map CodeId CodeContract
codeContracts globals codes=M.mapWithKey contract codes
  where
    -- Ambient variables in checked global schemas remain rigid, including
    -- those used through another code entry. A reference's instantiated
    -- monotype is not evidence that a polymorphic global has become rigid.
    external e=(case exprNode e of
      Var (Global n sc)->schemeVariables (M.findWithDefault sc n globals)
      _->mempty)<>getConst (mapChildrenM (Const . external) e)
    references e=(case exprNode e of
      ClosureValue k _->S.singleton k
      CodeCall k _ _->S.singleton k
      JoinCall k _ _->S.singleton k
      _->S.empty)<>getConst (mapChildrenM (Const . references) e)
    direct=M.map (external . codeBody) codes
    dependencies=M.map (references . codeBody) codes
    step env=M.mapWithKey (\k own->own<>mconcat [M.findWithDefault mempty dep env | dep<-S.toList (dependencies M.! k)]) direct
    fix env=let next=step env in if next==env then env else fix next
    rigid=fix direct
    contract k f=let c=codeContract f
                     (ts,rs)=mconcat (map schemeVariables (map fst (contractCaptures c)))
                       <>mconcat (map variables (contractResult c:contractParameters c))
                     (rt,rr)=rigid M.! k
                 in c {contractQuantifiers=(S.toAscList (ts S.\\ rt),S.toAscList (rs S.\\ rr))}

checkInstance :: CodeContract -> [Scheme] -> Type -> Either String ()
checkInstance c actualCaptures actualType=do
  unless (length actualCaptures==length captures) (Left "code capture arity")
  let (qs,rs)=contractQuantifiers c
      allTypes=actualType:signature:map schemeBody (actualCaptures++captures)
      next=above allTypes
      (sub,flex,start)=freshSubstitution next (Forall qs rs (TTupT allTypes))
      expected=map (applyScheme sub) captures
  (pairs,skolems,end)<-foldM capture ([],mempty,start) (zip expected actualCaptures)
  (solved,_)<-unifyTypes flex end ((applyType sub signature,actualType):pairs)
  -- Capture-local quantifiers cannot solve an outer code quantifier. Such a
  -- solution would let the capture's private type escape its lexical scope.
  let images=mconcat ([variables (applyType solved (TV q)) | q<-S.toList (fst flex)]
                ++[variables (applyType solved (TRec (RV q))) | q<-S.toList (snd flex)])
  unless (S.null (fst images `S.intersection` fst skolems)
       && S.null (snd images `S.intersection` snd skolems)) (Left "code capture quantifier escapes")
  where
    captures=map fst (contractCaptures c)
    signature=foldr TFn (contractResult c) (contractParameters c)
    schemeBody (Forall _ _ t)=t
    above types=let (ts,rs)=mconcat (map variables types) in 1+maximum (0:S.toList ts++S.toList rs)
    capture (pairs,bound,next) (a@(Forall aq ar at),b@(Forall bq br bt))=do
      unless (length aq==length bq && length ar==length br) (Left "code capture scheme quantifiers")
      -- Forall lists have no semantic ordering. Canonicalize by occurrences
      -- (record fields are unordered), then introduce shared rigid skolems.
      let start=maximum [next,above [at,bt],1+maximum (0:aq++ar++bq++br)]
          (a',sk,end)=freshen start (canonical a)
          (b',_,_)=freshen start (canonical b)
      pure ((a',b'):pairs,bound<>sk,end)
    canonical (Forall qs rs ty)=let (ts,rvs)=ordered ty
                                  in Forall (order qs ts) (order rs rvs) ty
    order qs seen=nub (filter (`elem` qs) seen++qs)
    ordered ty=case ty of
      TV v->([v],[])
      TAp a b->ordered a<>ordered b
      TFn a b->ordered a<>ordered b
      TTupT xs->mconcat (map ordered xs)
      TLayout a->ordered a
      TRec r->let (fields,tail')=row r
              in mconcat (map (ordered . snd) (sortOn fst fields))<>([],tail')
      _->mempty
    row (RExt n t rest)=let (fs,tail')=row rest in ((n,t):fs,tail')
    row (RV v)=([],[v])
    row RNil=([],[])
