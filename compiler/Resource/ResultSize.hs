{-# LANGUAGE LambdaCase #-}
-- Checked, partial-correctness result-size lemmas. Source annotations are
-- candidate invariants, never assumptions. Recursive lemmas are published
-- only after every returning path preserves the entire group's invariant.
module Resource.ResultSize (Proofs, proveSizes, verifiedBounds) where

import qualified Cost as C
import Core.Identity (BinderId)
import Core.Syntax (Name,Prog)
import qualified Compiler.Native.Core as Native
import qualified Core.Typed.Syntax as T
import Core.Typed.Walk (mapChildrenM)
import Type.Syntax (Type(..))
import Safety (Measure(..),MeasureKind(..))
import Data.Graph (SCC(..),stronglyConnComp)
import Data.Functor.Const (Const(..))
import Data.List (nub)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- A list spine counts elements; a String counts its actual UTF-8 bytes.
data Kind = ListSize | StringSize deriving (Eq,Show)
data Fact = Fact [Name] Kind C.Cost Bool deriving (Eq,Show)
data Proofs = Proofs Prog (M.Map Name Fact)
data Value = Unknown | Number C.Cost | Sized Kind C.Cost Bool
  | Product [Value] | Fields (M.Map String Value)
  | Boolean (Maybe Bool) [C.Cost] [C.Cost] deriving Show
data Path = Path (M.Map BinderId Value) (M.Map C.Cost C.Cost) [C.Cost]

kind :: Type -> Maybe Kind
kind (TAp (TC "List") _) = Just ListSize
kind (TC "String") = Just StringSize
kind _ = Nothing
simp = C.simplifyCost
add a b = simp (C.CAdd [a,b])
neg a = C.CMul [C.CN (-1),a]
sub a b = add a (neg b)
-- Frontend strings already contain UTF-8/raw bytes, including byte escapes.
-- Re-encoding them here would double-count non-ASCII payloads.
bytes = fromIntegral . length

-- Publish only against the erasure owned by the checked native product.
-- Callers cannot attach a proof to an unrelated program by matching names.
verifiedBounds :: Proofs -> M.Map Name C.Cost
verifiedBounds (Proofs prog facts) = M.mapMaybeWithKey one facts
  where
    one name (Fact ps _ bound _) = do
      (qs,_) <- M.lookup name prog
      if length ps /= length qs then Nothing else Just
        (C.substituteCost (M.fromList (zip ps (map C.CP qs)))
          (M.fromList (zip ps (map C.CLen qs))) bound)

proveSizes :: M.Map Name Measure -> M.Map Name C.Cost -> Native.NativeCore -> Proofs
proveSizes measures candidates native = Proofs (Native.nativeProgram native) (foldl solve M.empty groups)
  where
    definitions = M.map Native.checkedFunction (Native.nativeDefinitions native)
    sized = M.filter (maybe False (const True) . kind . T.exprType . T.functionBody) definitions
    refs e = (case T.exprNode e of
      T.Var (T.Global n _) -> S.singleton n
      T.CodeCall (T.CodeId n) _ _ -> S.singleton n
      T.JoinCall (T.CodeId n) _ _ -> S.singleton n
      _ -> S.empty) <> getConst (mapChildrenM (Const . refs) e)
    deps f = S.toList (refs (T.functionBody f) `S.intersection` M.keysSet sized)
    groups = stronglyConnComp [(n,n,deps f) | (n,f) <- M.toList sized]
    solve done (AcyclicSCC n) = case infer done (sized M.! n) of
      Just fact -> M.insert n fact done
      Nothing -> done
    solve done (CyclicSCC ns) = try (nub [M.fromList [(n,choose family (options M.! n)) | n<-ns] | family<-[0..width-1]])
      where
        options=M.fromList [(n,templates (sized M.! n)) | n<-ns]
        width=maximum (map length (M.elems options))
        choose index fs=fs !! min index (length fs-1)
        try [] = done
        try (proposed:rest)
          | all (valid (proposed `M.union` done)) ns = proposed `M.union` done
          | otherwise = try rest
        valid assumed n = case assumed M.! n of
          Fact _ expectedKind bound _ -> all (verifies expectedKind bound)
            (outcomes assumed (sized M.! n))
    templates fn = [Fact ps result bound False | bound<-nub bounds]
      where
        n=T.functionName fn
        bs=T.functionParameters fn
        ps=map T.binderName bs
        Just result=kind (T.exprType (T.functionBody fn))
        sequenceParameters=[T.binderName b | b<-bs,kind (T.binderType b)==Just result]
        lengths=simp (C.CAdd (map C.CLen sequenceParameters))
        renamed m=M.fromList (zip (mParams m) ps)
        sourceParam m p=M.findWithDefault p p (renamed m)
        structural=case M.lookup n measures of
          Just m | MStructural p<-mKind m,let fuel=sourceParam m p,fuel `elem` sequenceParameters ->
            C.CLen fuel:[add (C.CLen fuel) (C.CLen acc) | acc<-sequenceParameters,acc/=fuel]
          _->[]
        linear=case M.lookup n measures of
          Just m | MLinear cs k<-mKind m ->
            let count=simp (C.CAdd (C.CN k:[C.CMul [C.CN c,C.CP (sourceParam m p)] | (p,c)<-M.toList cs]))
            in [add lengths (C.CNat (add count (C.CN offset))) | offset<-[0,1]]
          _->[]
        bounds=maybe [] (:[]) (M.lookup n candidates) ++ structural ++ [lengths] ++ linear
    outcomes known fn = evaluate definitions known (initial fn) (T.functionBody fn)
    infer known fn = do
      k<-kind (T.exprType (T.functionBody fn))
      let paths=outcomes known fn
      values<-mapM (\(p,v)->case v of
        Sized k' b exact | k==k', not (C.hasOmega b) -> Just (normal p b,exact)
        _ -> Nothing) paths
      let bound=simp (C.CMax (map fst values))
          exact=not (null values) && all snd values && all ((==bound) . fst) values
      pure (Fact (map T.binderName (T.functionParameters fn)) k bound exact)
    verifies k bound (p,Sized k' value _) = k==k' &&
      C.checkBoundsAssuming (pathFacts p) (normal p value) (normal p bound)==C.Proven
    verifies _ _ _ = False

initial fn = Path (M.fromList [(T.binderId b,value b) | b<-T.functionParameters fn]) M.empty []
  where
    value b = case kind (T.binderType b) of
      Just k -> Sized k (C.CLen (T.binderName b)) True
      Nothing | T.binderType b==TC "Int" -> Number (C.CP (T.binderName b))
      _ -> Unknown
lookupValue (Path env _ _) uid=M.findWithDefault Unknown uid env
bind uid value (Path env eq facts)=Path (M.insert uid value env) eq facts
pathFacts p@(Path _ _ facts)=map (normal p) facts
assume facts (Path env eq fs)=Path env eq (facts++fs)
normal (Path _ equalities _) = simp . go
  where
    go c | Just v<-M.lookup (simp c) equalities = v
    go (C.CAdd xs)=C.CAdd (map go xs)
    go (C.CMul xs)=C.CMul (map go xs)
    go (C.CMax xs)=C.CMax (map go xs)
    go (C.CNat x)=C.CNat (go x)
    go (C.CDivC x k)=C.CDivC (go x) k
    go c=c
refine key value p@(Path env eq fs)=Path env (M.insert (normal p key) value eq) fs

-- A bound may consume an upper estimate only in a monotone position. Exact
-- arguments can be substituted everywhere; an unknown signed value cannot.
monotone = \case
  C.CN _ -> True
  C.CLen _ -> True
  C.CAdd xs -> all monotone xs
  C.CMax xs -> all monotone xs
  C.CNat e -> monotone e
  C.CDivC e k -> k>0 && monotone e
  C.CMul xs -> all monotone xs && all (\x->C.checkBounds (C.CN 0) x==C.Proven) xs
  _ -> False

instantiate p (Fact ps k bound exact) args
  | length ps /= length args = Unknown
  | otherwise =
      let values=M.fromList [(n,normal p c) | (n,Number c)<-zip ps args]
          lengths=M.fromList [(n,normal p c) | (n,Sized _ c isExact)<-zip ps args,isExact || monotone bound]
          result=C.substituteCost values lengths bound
          allExact=all (\case Sized _ _ e->e;_->True) args
      in if C.hasOmega result then Unknown else Sized k result (exact && allExact)

evaluate definitions known = go
  where
    go p e = case T.exprNode e of
      T.Note x -> go p x
      T.Var (T.Local uid) -> [(p,lookupValue p uid)]
      T.Var (T.Global n _) -> [(p,call p n [])]
      T.IntValue n -> [(p,Number (C.CN n))]
      T.StringValue s -> [(p,Sized StringSize (C.CN (bytes s)) True)]
      T.BoolValue b -> [(p,Boolean (Just b) [] [])]
      T.BoolTest b x -> [(q,if b then v else flipBoolean v) | (q,v)<-go p x]
      T.ListValue xs -> [(p,Sized ListSize (C.CN (fromIntegral (length xs))) True)]
      T.TupleValue xs -> [(q,Product vs) | (q,vs)<-many p xs]
      T.RecordValue fs -> [(q,Fields (M.fromList (zip (map fst fs) vs))) | (q,vs)<-many p (map snd fs)]
      T.RecordField x fields -> [(q,foldl field v fields) | (q,v)<-go p x]
      T.Construct name xs -> case (kind (T.exprType e),name,xs) of
        (Just ListSize,"Nil",[]) -> [(p,Sized ListSize (C.CN 0) True)]
        (Just ListSize,"Cons",[_,tailExpr]) -> [(q,construct (Just ListSize) name [Unknown,v]) | (q,v)<-go p tailExpr]
        _ -> [(p,Unknown)]
      T.Let b rhs body -> [(r,v) | (q,value)<-go p rhs,(r,v)<-go (bind (T.binderId b) value q) body]
      T.LetRec b _ body -> go (bind (T.binderId b) Unknown p) body
      -- Prefix failure prevents a result; ignoring it widens successful paths.
      T.Sequence _ b -> go p b
      T.LetPattern pat rhs body -> [(r,v) | (q,value)<-go p rhs,Just q'<-[match q pat value],(r,v)<-go q' body]
      T.If condition yes no -> concat
        [maybe [] (\r->go r yes) (truth True q value) ++ maybe [] (\r->go r no) (truth False q value)
         | (q,value)<-go p condition]
      T.Match _ xs alternatives -> [(r,v) | (q,vs)<-many p xs,a<-alternatives,(r,v)<-alternative q vs a]
      T.MatchTail _ xs alternatives fallback ->
        [(r,v) | (q,vs)<-many p xs,a<-alternatives,(r,v)<-alternative q vs a] ++ go p fallback
      T.Apply {} ->
        let (headExpr,args)=spine e [] in
        case T.exprNode headExpr of
          T.Var (T.Global n _) | n=="error",M.notMember n definitions -> []
          T.Var (T.Global n _) | M.member n known || (M.notMember n definitions && n `elem` ["+","-","*","<","<=",">",">=","==","!=","strcat","strlen","substr"]) ->
            [(q,call q n vs) | (q,vs)<-many p args]
          _ -> [(p,Unknown)]
      T.CodeCall (T.CodeId n) captures xs -> [(q,call q n (map (lookupValue q) captures++vs)) | (q,vs)<-many p xs]
      T.JoinCall (T.CodeId n) captures xs -> [(q,call q n (map (lookupValue q) captures++vs)) | (q,vs)<-many p xs]
      T.CallRegion x -> go p x
      T.Fail _ -> []
      _ -> [(p,Unknown)]
    many p []=[(p,[])]
    many p (x:xs)=[(r,v:vs) | (q,v)<-go p x,(r,vs)<-many q xs]
    alternative p vs (T.Alternative pats guards body)
      | length pats/=length vs=[]
      | otherwise=case foldl (\mp (pat,v)->mp >>= \q->match q pat v) (Just p) (zip pats vs) of
          Nothing->[]
          Just q->[(r,v) | q'<-guardPaths q guards,(r,v)<-go q' body]
    guardPaths p []=[p]
    guardPaths p (g:gs)=case g of
      T.BoolGuard e->[r | (q,v)<-go p e,Just q'<-[truth True q v],r<-guardPaths q' gs]
      T.PatternGuard pat e->[r | (q,v)<-go p e,Just q'<-[match q pat v],r<-guardPaths q' gs]
    call p n args=case M.lookup n known of
      Just fact->instantiate p fact args
      Nothing | M.notMember n definitions->primitive n args
      _->Unknown
    field (Fields fs) n=M.findWithDefault Unknown n fs
    field _ _=Unknown
    spine e xs=case T.exprNode e of
      T.Note x->spine x xs
      T.Apply f a->spine f (a:xs)
      _->(e,xs)

construct (Just ListSize) "Nil" []=Sized ListSize (C.CN 0) True
construct (Just ListSize) "Cons" [_,Sized ListSize tailSize exact]=Sized ListSize (add (C.CN 1) tailSize) exact
construct _ _ _=Unknown
flipBoolean (Boolean literal yes no)=Boolean (not <$> literal) no yes
flipBoolean _=Unknown
truth wanted p (Boolean literal yes no)=case literal of
  Just actual | actual/=wanted->Nothing
  _->Just (assume (if wanted then yes else no) p)
truth _ p _=Just p

primitive name args=case (name,args) of
  ("+",[Number a,Number b])->Number (add a b)
  ("-",[Number a,Number b])->Number (sub a b)
  ("*",[Number a,Number b])->Number (simp (C.CMul [a,b]))
  (op,[Number a,Number b]) | op `elem` ["<","<=",">",">=","==","!="]->
    let ge x y=sub x y; gt x y=sub (sub x y) (C.CN 1)
        (yes,no)=case op of
          "<"->([gt b a],[ge a b]); "<="->([ge b a],[gt a b])
          ">"->([gt a b],[ge b a]); ">="->([ge a b],[gt b a])
          "=="->([ge a b,ge b a],[]); _->([],[ge a b,ge b a])
    in Boolean Nothing yes no
  ("strcat",[Sized StringSize a ea,Sized StringSize b eb])->Sized StringSize (add a b) (ea&&eb)
  ("strlen",[Sized StringSize a True])->Number a
  ("substr",[Sized StringSize a _,_,_])->Sized StringSize a False
  _->Unknown

match p pat value=case T.patNode pat of
  T.Bind b->Just (bind (T.binderId b) value p)
  T.Wildcard->Just p
  T.IntegerPattern n->case value of
    Number (C.CN k) | n/=k->Nothing
    Number c->Just (refine c (C.CN n) p)
    _->Just p
  T.StringPattern text->case value of
    Sized StringSize c True->Just (refine c (C.CN (bytes text)) p)
    _->Just p
  T.ConstructorPattern n ps
    | T.patType pat==TC "Bool",n `elem` ["True","False"],null ps->truth (n=="True") p value
    | kind (T.patType pat)==Just ListSize,n=="Nil",null ps->case value of
        Sized ListSize c exact->case C.evalConst (normal p c) of
          Just k | exact && k/=0->Nothing
          _->Just (if exact then refine c (C.CN 0) p else p)
        _->Just p
    | kind (T.patType pat)==Just ListSize,n=="Cons",[headPat,tailPat]<-ps->case value of
        Sized ListSize c exact->case C.evalConst (normal p c) of
          Just 0->Nothing
          _->match (assume [sub c (C.CN 1)] p) headPat Unknown >>=
            \q->match q tailPat (Sized ListSize (sub c (C.CN 1)) exact)
        _->matchUnknown p ps
    | otherwise->matchUnknown p ps
  T.TuplePattern ps->case value of
    Product vs | length ps==length vs->foldl (\mp (q,v)->mp >>= \r->match r q v) (Just p) (zip ps vs)
    _->matchUnknown p ps
  T.RecordPattern fields->Just (foldl (\q (n,b)->bind (T.binderId b)
    (case value of Fields fs->M.findWithDefault Unknown n fs;_->Unknown) q) p fields)
  where
    matchUnknown q=foldl (\mp p'->mp >>= \r->match r p' Unknown) (Just q)
