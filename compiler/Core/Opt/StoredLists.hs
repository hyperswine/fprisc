{-# LANGUAGE FlexibleContexts #-}
-- Private persistent lists with their scalar constructor payloads in the
-- spine. Whole-value uses must agree before changing any caller or callee.
module Core.Opt.StoredLists (storeLists) where

import Core.Syntax
import Core.Utils (spineOf)
import Core.ProductABI (packName,storedNodeName)
import Compiler.DataLayout (storedListTid,storedListVariant,smallTupleLayouts)
import Core.Opt.ProductParameters (ProductParameters,StorageLayout(..),StorageField(..),storagePlans)
import Control.Monad (guard,foldM)
import Control.Monad.State.Strict
import Data.List (foldl')
import Data.Graph (stronglyConnComp,flattenSCC)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

elementLayout (ListStorage el)=el
elementLayout (FieldStorage _ _ _ _ el)=el
isList (ListStorage _)=True
isList _=False
producerRole l=if isList l then "list" else "aggregate"
tupleLayout n=M.lookup ("Tup"++show n) smallTupleLayouts
data Rep = Ordinary | Spine | Element deriving (Eq,Ord,Show)
data Build = Build Int Prog (S.Set Name) Bool
data Definition = Definition { code :: ([Name],Core), helpers :: Prog, calls :: S.Set Name, buildsCell :: Bool }
type Builder = StateT Build Maybe

-- Runtime layout_total and the iterative spine walkers use the same header.
fields = maximum . M.elems . snd
hasTag layout=M.size (snd layout)>1
wordsIn layout=fields layout+fromEnum (hasTag layout)
header layout=storedListVariant (fields layout)
ordinaryCons layout=not (hasTag layout) && fields layout==1
worker role n="$worker.storage."++role++"."++n
app n=foldl' CApp (CVar n)
pack [word]=word
pack words'=app (packName (length words')) words'
at layout name i | wordsIn layout==1=CVar name
                 | otherwise=CProj i (CVar name)

names e=case e of
  CLet x a b->x:names a++names b
  CLam ps b->ps++names b
  CVar x->[x]
  _->concatMap names (children e)
children e=case e of
  CApp a b->[a,b];CLet _ a b->[a,b];CLam _ b->[b];CIf c a b->[c,a,b]
  CMk _ _ xs->xs;CTagEq _ _ x->[x];CProj _ x->[x];_->[]

fresh :: S.Set Name -> Builder Name
fresh taken=do
  Build i aux deps made<-get
  put (Build (i+1) aux deps made)
  let x="$storage.slot."++show i
  if S.member x taken then fresh taken else pure x

merge a b=do
  guard (and (M.elems (M.intersectionWith (==) a b)))
  pure (M.union a b)

-- Infer representation demands backwards through strict bindings, emitting
-- each RHS only at its original evaluation point. Conflicting uses decline.
producer prog eligible constructors container ps body=do
  ((code,uses),Build _ aux deps made)<-runStateT (emit (S.fromList ps) Spine body) (Build 0 M.empty S.empty False)
  guard (all (==Ordinary) uses)
  pure (Definition (ps,code) aux deps made)
  where
    layout=elementLayout container
    taken=S.fromList (ps++names body)
    plain e=(e,M.fromList [(x,Ordinary)|x<-freeVars e])
    reserved bound n=S.member n bound || M.member n prog
    emit _ Ordinary e=pure (plain e)
    emit bound want e=case e of
      CVar n | S.member n bound->pure (e,M.singleton n (want))
      CErr _->pure (e,M.empty)
      CLet x a b->do
        (b',ub)<-emit (S.insert x bound) want b
        let req=M.findWithDefault (Ordinary) x ub
        (a',ua)<-emit bound req a
        u<-merge ua (M.delete x ub)
        pure (CLet x a' b',u)
      CIf c a b->do
        (a',ua)<-emit bound want a
        (b',ub)<-emit bound want b
        u<-merge ua ub >>= merge (snd (plain c))
        pure (CIf c a' b',u)
      CMk t v xs->make bound want Nothing t v xs
      _ | (CVar f,args)<-spineOf e,S.notMember f bound,Just (t,v,k)<-M.lookup f constructors,k==length args->
            make bound want (Just f) t v args
        | want==Spine,(CVar f,args@(_:_))<-spineOf e,S.notMember f bound,
          Just (qs,_)<-M.lookup f prog,length qs==length args,M.lookup f eligible==Just container->do
            let entry=worker (producerRole container) f
            guard (not (reserved bound entry))
            modify' (\(Build i aux deps made)->Build i aux (S.insert f deps) made)
            pure (app entry args,snd (plain e))
        | otherwise->lift Nothing
    make bound Element callee t v args=do
      guard (t==fst layout && M.lookup v (snd layout)==Just (length args))
      let width=wordsIn layout
          ordinal | not (isList container) && M.size (snd layout)==2=CMk 1 (if v==fst (M.findMin (snd layout)) then 0 else 1) []
                  | otherwise=CInt (fromIntegral v)
          packet xs=pack ([ordinal|hasTag layout]++xs++replicate (fields layout-length xs) (CInt 0))
      guard (width==1 || not (reserved bound (packName width)))
      value<-case callee of
        Just f | not (null args)->do
          let entry=(if width>1 then "$worker.ret"++show width++"." else "$worker.")++(if isList container then "storage.element." else "storage.field.")++f
              qs=["$storage.arg."++show i|i<-[0..length args-1]]
          guard (not (reserved bound entry))
          addAux entry (qs,packet (map CVar qs))
          pure (app entry args)
        _->pure (packet args)
      pure (value,M.unions [snd (plain a)|a<-args])
    make _ Spine _ 2 0 [] | isList container=pure (CMk 2 0 [],M.empty)
    make bound Spine callee 2 1 [headValue,tailValue] | isList container=do
      modify' (\(Build i aux deps _)->Build i aux deps True)
      (head',uh)<-emit bound Element headValue
      (tail',ut)<-emit bound Spine tailValue
      u<-merge uh ut
      h<-fresh taken
      t<-fresh taken
      let lanes=[at layout h i | i<-[0..wordsIn layout-1]]
          construct xs tailRef
            | ordinaryCons layout=CMk 2 1 (xs++[tailRef])
            | hasTag layout=app storedNodeName (xs++[tailRef])
            | otherwise=CMk storedListTid (header layout (fst (M.findMin (snd layout)))) (xs++[tailRef])
      guard (not (hasTag layout) || not (reserved bound storedNodeName))
      cell<-case callee of
        Nothing->pure (construct lanes (CVar t))
        Just _->do
          let entry=worker "cons" (show (fst layout))
              qs=["$storage.word."++show i|i<-[0..length lanes-1]]
              tailArg="$storage.tail"
          guard (not (reserved bound entry))
          addAux entry (qs++[tailArg],construct (map CVar qs) (CVar tailArg))
          pure (app entry (lanes++[CVar t]))
      pure (CLet h head' (CLet t tail' cell),u)
    make bound Spine callee t v args | FieldStorage tid branch empty roles _<-container,t==tid=
      if v `elem` empty && null args then pure (CMk t v [],M.empty) else do
        guard (v==branch && length args==length roles)
        modify' (\(Build i aux deps _)->Build i aux deps True)
        let want InlineField=Element
            want ChildField=Spine
            want PublicField=Ordinary
            width=wordsIn layout
            n=length roles+width-1
        (tuple,tag,_)<-lift (tupleLayout n)
        values<-sequence [emit bound (want role) arg | (role,arg)<-zip roles args]
        uses<-foldM merge M.empty (map snd values)
        ns<-mapM (const (fresh taken)) roles
        let expand (InlineField,name)=[at layout name i | i<-[0..width-1]]
            expand (_,name)=[CVar name]
            slots=concatMap expand (zip roles ns)
        cell<-case callee of
          Nothing->pure (CMk tuple tag slots)
          Just f->do
            -- All layout-specific expansion happens in the caller. The twin
            -- preserves constructor entry fuel and only needs the physical width.
            let entry=worker ("node"++show n) f
                qs=["$storage.word."++show i | i<-[1..n]]
            guard (not (reserved bound entry))
            addAux entry (qs,CMk tuple tag (map CVar qs))
            pure (app entry slots)
        pure (foldr (uncurry CLet) cell (zip ns (map fst values)),uses)
    make _ _ _ _ _ _=lift Nothing
    addAux n code=modify' (\(Build i aux deps made)->Build i (M.insert n code aux) deps made)

-- A logical head here denotes its containing cell. Returning its ordinary
-- value, storing it or capturing it would expose the private layout.
data Local = Plain | ListRef | ConsRef | Remaining [Int] | Head (M.Map Int Int) deriving (Eq)
isSpine ListRef=True
isSpine ConsRef=True
isSpine (Remaining _)=True
isSpine _=False

readBody prog readers container initial e=runStateT (normal initial e) S.empty
  where
    layout=elementLayout container
    inlineOffset roles=length (takeWhile (/=InlineField) roles)
    occupied env n=case M.lookup n env of
      Just ConsRef->True
      Just ListRef | FieldStorage _ _ [] _ _<-container->True
      _->False
    normal env x=do
      (x',role)<-value env x
      guard (role==Plain)
      pure x'
    value env x=case x of
      CVar n->pure (x,M.findWithDefault Plain n env)
      CLet n a b->do
        (a',role)<-value env a
        (b',r)<-value (M.insert n role env) b
        pure (CLet n a' b',r)
      CProj i (CVar n) | FieldStorage _ _ _ roles _<-container,occupied env n->do
        guard (i>=0 && i<length roles)
        let offset=inlineOffset roles
            slot=if i>offset then i+wordsIn layout-1 else i
        pure (case roles!!i of
          InlineField->(CVar n,Head (snd layout))
          ChildField->(CProj slot (CVar n),ListRef)
          PublicField->(CProj slot (CVar n),Plain))
      CProj i (CVar n) | isList container,Just ConsRef<-M.lookup n env->case i of
        0->pure (CVar n,Head (snd layout))
        1->pure (CProj (fields layout) (CVar n),ListRef)
        _->lift Nothing
      CProj i (CVar n) | Just (Head possible)<-M.lookup n env->do
        guard (i>=0 && all (>i) possible)
        let offset=case container of
              ListStorage _->0
              FieldStorage _ _ _ roles _->inlineOffset roles+fromEnum (hasTag layout)
        pure (CProj (offset+i) (CVar n),Plain)
      CIf (CTagEq t v (CVar n)) a b | FieldStorage tid tag empty roles _<-container,
        t==tid,Just role<-M.lookup n env,isSpine role->do
          let choices=case role of
                ConsRef->[tag]
                Remaining vs->vs
                _->tag:empty
              refine [k] | k==tag=ConsRef
              refine vs=Remaining vs
          if v `notElem` choices then value env b else if choices==[v] then value env a else do
            test<-outerTest tid tag roles v n
            branch test (M.insert n (refine [v]) env,a) (M.insert n (refine (filter (/=v) choices)) env,b)
      CIf (CTagEq 2 v (CVar n)) a b | isList container,Just r<-M.lookup n env,isSpine r,v==0 || v==1->do
        let nonempty=M.insert n ConsRef env
            nil=CTagEq 2 0 (CVar n)
        if v==0 then branch nil (env,a) (nonempty,b) else branch nil (env,b) (nonempty,a)
      CIf (CTagEq t v (CVar n)) a b | Just (Head possible)<-M.lookup n env->do
        guard (t==fst layout)
        case M.lookup v possible of
          Nothing->value env b
          Just k | M.size possible==1->value env a
                 | otherwise->do
                    test<-case container of
                      ListStorage _->pure (CTagEq storedListTid (header layout v) (CVar n))
                      FieldStorage _ _ _ roles _->do
                        let tag=CProj (inlineOffset roles) (CVar n)
                        if M.size (snd layout)==2 then
                          pure (CTagEq 1 (if v==fst (M.findMin (snd layout)) then 0 else 1) tag)
                        else do
                          guard (M.notMember "==" env && M.notMember "==" prog)
                          pure (app "==" [tag,CInt (fromIntegral v)])
                    branch test (M.insert n (Head (M.singleton v k)) env,a) (M.insert n (Head (M.delete v possible)) env,b)
      CTagEq t v (CVar n) | FieldStorage tid tag empty roles _<-container,t==tid,
        Just role<-M.lookup n env,isSpine role->do
          guard (v==tag || v `elem` empty)
          test<-outerTest tid tag roles v n
          pure (test,Plain)
      CTagEq 2 v (CVar n) | isList container,Just r<-M.lookup n env,isSpine r->do
        guard (v==0 || v==1)
        let nil=CTagEq 2 0 (CVar n)
        pure (if v==0 || ordinaryCons layout then x else CTagEq 1 0 nil,Plain)
      CIf c a b->do c'<-normal env c;branch c' (env,a) (env,b)
      CLam qs b->do
        guard (all (\n->M.findWithDefault Plain n env==Plain) (freeVars (CLam qs b)))
        pure (x,Plain)
      CApp _ _ | (CVar f,args)<-spineOf x,M.notMember f env,Just (j,l)<-M.lookup f readers,
        container==l,Just (qs,_)<-M.lookup f prog,length args==length qs->do
          actual<-traverse (value env) args
          if all ((==Plain) . snd) actual then pure (app f (map fst actual),Plain) else do
            guard (and [if i==j then isSpine role else role==Plain | (i,(_,role))<-zip [0..] actual])
            let target=worker "read" f
            guard (M.notMember target env && M.notMember target prog)
            modify' (S.insert f)
            pure (app target (map fst actual),Plain)
      CApp a b->do a'<-normal env a;b'<-normal env b;pure (CApp a' b',Plain)
      CMk t v xs->do xs'<-traverse (normal env) xs;pure (CMk t v xs',Plain)
      CProj i a->do a'<-normal env a;pure (CProj i a',Plain)
      CTagEq t v a->do a'<-normal env a;pure (CTagEq t v a',Plain)
      _->pure (x,Plain)
    outerTest tid tag roles v n
      | v/=tag=pure (CTagEq tid v (CVar n))
      | otherwise=do
          (tuple,tv,_)<-lift (tupleLayout (length roles+wordsIn layout-1))
          pure (CTagEq tuple tv (CVar n))
    branch c (ea,a) (eb,b)=do
      (a',ka)<-value ea a;(b',kb)<-value eb b
      case () of
        _ | ka==kb->pure (CIf c a' b',ka)
          | isSpine ka && isSpine kb->pure (CIf c a' b',ListRef)
          | otherwise->lift Nothing

-- Keep the greatest closed set of candidate workers. A missing or refused
-- body invalidates callers in the same recursive component as well.
closed :: M.Map Name Definition -> M.Map Name Definition
closed candidates=foldl' admit M.empty components
  where
    components=map flattenSCC (stronglyConnComp
      [(n,n,S.toList (calls def))|(n,def)<-M.toList candidates])
    admit known group
      | all valid local=M.union (M.map mark local) known
      | otherwise=known
      where
        local=M.restrictKeys candidates (S.fromList group)
        valid def=all (\f->M.member f local || M.member f known) (calls def)
        productive=any buildsCell local || any (any (maybe False buildsCell . (`M.lookup` known)) . calls) local
        mark def=def {buildsCell=productive}

storeLists :: ProductParameters -> Int -> Prog -> (Prog,[String])
storeLists facts capacity prog
  | M.null producers || S.null used=(prog,[])
  | otherwise=(rewritten `M.union` workers,["# stored lists: private entries="++show (M.size workers)])
  where
    (producerTypes,readerTypes)=storagePlans prog facts
    supported container=let layout=elementLayout container in fields layout>=1 && wordsIn layout<=capacity && fields layout<=8
                      && all (\v->v>=0 && toInteger v<=0x0fffffff) (M.keys (snd layout))
                      && case container of
                           ListStorage _->True
                           FieldStorage _ _ _ roles _->case tupleLayout (length roles+wordsIn layout-1) of
                             Just _->True
                             _->False
    owned=M.filter supported producerTypes
    constructors=M.mapMaybe (\(qs,b)->case b of
      CMk t v xs | xs==map CVar qs->Just (t,v,length qs)
      _->Nothing) prog
    producers=closed (M.mapMaybeWithKey build owned)
    build n layout=do
      let (ps,b)=prog M.! n
      guard (not (null ps) && M.notMember (worker (producerRole layout) n) prog)
      producer prog owned constructors layout ps b
    qualifiedReaders=M.filter (supported . snd) readerTypes
    readers=closed (M.mapMaybeWithKey readFn qualifiedReaders)
    readFn n (i,layout)=do
      let (ps,b)=prog M.! n
      guard (M.notMember (worker "read" n) prog)
      (body,deps)<-readBody prog qualifiedReaders layout
        (M.fromList [(p,if j==i then ListRef else Plain)|(j,p)<-zip [0..] ps]) b
      pure (Definition (ps,body) M.empty deps False)
    knownReaders=M.restrictKeys qualifiedReaders (M.keysSet readers)
    entries role=M.mapKeys (worker role) . M.map (\def->def {calls=S.map (worker role) (calls def)})
    producerName n=worker (producerRole (owned M.! n)) n
    privateProducers=M.mapKeys producerName (M.map (\def->def {calls=S.map producerName (calls def)}) producers)
    both=M.union privateProducers (entries "read" readers)
    live seen pending=case S.minView pending of
      Nothing->seen
      Just (n,rest) | n `S.member` seen->live seen rest
                    | otherwise->live (S.insert n seen) (S.union (calls (both M.! n)) rest)
    workers=M.unions [M.insert n (code def) (helpers def)|(n,def)<-M.toList (M.restrictKeys both (live S.empty used))]
    (rewritten,used)=runState (traverse owner prog) S.empty
    owner (ps,b)=do b'<-walk (S.fromList ps) b;pure (ps,b')
    walk scope e=case e of
      CLet x a b | Just (a',n)<-root scope a,Just l<-M.lookup n owned,
        Just (b',deps)<-readBody prog knownReaders l (M.insert x ListRef (M.fromSet (const Plain) scope)) b,
        occurs x b->do
          modify' (S.union (S.insert (producerName n) (S.map (worker "read") deps)))
          CLet x a' <$> walk (S.insert x scope) b'
      CLet x a b->CLet x <$> walk scope a <*> walk (S.insert x scope) b
      CApp a b->CApp <$> walk scope a <*> walk scope b
      CIf c a b->CIf <$> walk scope c <*> walk scope a <*> walk scope b
      CLam ps b->CLam ps <$> walk (scope<>S.fromList ps) b
      CMk t v xs->CMk t v <$> traverse (walk scope) xs
      CProj i a->CProj i <$> walk scope a
      CTagEq t v a->CTagEq t v <$> walk scope a
      _->pure e
    root scope e=case e of
      CLet x a b->do (b',n)<-root (S.insert x scope) b;pure (CLet x a b',n)
      CApp (CApp (CVar "$callLeave") tok) arg | S.notMember "$callLeave" scope,
        M.notMember "$callLeave" prog->do (arg',n)<-root scope arg;pure (app "$callLeave" [tok,arg'],n)
      _->do
        let (f,args)=spineOf e
        CVar n<-Just f
        def<-M.lookup n producers
        guard (buildsCell def && length (fst (code def))==length args && S.notMember n scope && S.notMember (producerName n) scope)
        pure (app (producerName n) args,n)
