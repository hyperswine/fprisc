{-# LANGUAGE FlexibleContexts #-}
-- Checked product values travel as ordered words through private calls
-- and locals. Heap fields and ordinary/generic entries keep real nominal boxes.
-- This lowering runs only after representation inference has fixed every shape.
module Arc.Products (lowerProducts, productEntryName) where

import Core.Syntax
import Core.ProductABI (packName,valueName)
import Representation.Types
import Control.Monad.State.Strict
import Control.Monad (forM,forM_,when)
import Data.List (isPrefixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data Value = One Core | Packet ProductShape [Core]

type G = StateT Int (Either String)
fresh :: G String
fresh = do n <- get; put (n+1); pure ("$arc.product.local."++show n)
bad :: String -> G a
bad = lift . Left . ("automatic ARC products: "++)
call n = foldl CApp (CVar n)
spine = go [] where
  go as (CApp f x) = go (x:as) f
  go as f = (f,as)
width shape = let (_,_,ks)=productParts shape in length ks
-- Source fields retain their nominal boundaries while private values occupy
-- a flat leaf vector. Each slice records its starting leaf offset.
fieldSlices shape=go 0 (productFields shape)
  where
    go _ [] _=[]
    go offset (field:rest) values=let n=productFieldWidth field;(part,remaining)=splitAt n values in
      (offset,field,part):go (offset+n) rest remaining

productEntryName :: S.Set String -> ProductEvidence -> String -> String
productEntryName pinned evidence name
  | S.member name pinned || name `elem` ["main","machineInterrupt"] = name
  | Just (Just shape)<-M.lookup name (productResults evidence) =
      (if width shape==1 then "$worker.payload.$product."
       else "$worker.ret"++show (width shape)++".$product.")++name
  | otherwise = name

lowerProducts :: Bool -> S.Set String -> Prog -> M.Map Core Kind -> M.Map String [Kind] ->
  S.Set Core -> M.Map String [Bool] -> M.Map Core (Int,Int) -> ProductEvidence ->
  [(String,Int,String)] -> Either String Prog
lowerProducts instrument pinned prog ann paramKinds immortals immortalArgs scalars evidence contracts =
  evalStateT (do
    forM_ (M.toList names) $ \(old,new) ->
      when (old/=new && M.member new prog) (bad ("reserved entry collision at "++new))
    M.fromList <$> mapM lower (M.toList prog)) 0
  where
    shapes = productValues evidence
    arguments n = M.findWithDefault (repeat Nothing) n (productArguments evidence)
    results n = M.findWithDefault Nothing n (productResults evidence)
    public n = S.member n pinned || n `elem` ["main","machineInterrupt"]
    resultABI n = if public n then Nothing else results n
    argumentABI n = case M.lookup n prog of
      Just (ps,_) | not (public n), sum (zipWith (\_ -> maybe 1 width) ps (arguments n)) <= 64 -> take (length ps) (arguments n)
      Just (ps,_) -> replicate (length ps) Nothing
      Nothing -> []
    names = M.mapWithKey (\n _ -> productEntryName pinned evidence n) prog
    arities = M.map (length . fst) prog
    primitives = M.fromList [(n,(a,"$arc."++adapter)) | (n,a,adapter)<-contracts]
    managed e = instrument && ann M.! e == Managed
    owned e = managed e && S.notMember e immortals && M.notMember e shapes
    release [] body = pure body
    release _ body | not instrument = pure body
    release (n:ns) body = do
      rest <- release ns body
      ignored <- fresh
      pure (CLet ignored (call "$arc.release" [CVar n]) rest)
    bind e k = do n <- fresh; CLet n e <$> k (CVar n)
    releaseValue original (One (CVar n)) body = release [n | owned original] body
    releaseValue _ (Packet shape fields) body = release (packetOwners shape fields) body
    releaseValue _ _ body = pure body
    sequenceValues [] k = k []
    sequenceValues (v:vs) k = bind v $ \x -> sequenceValues vs (k . (x:))

    -- A packet has no container owner. Each owned component has one reference;
    -- materialization transfers those references into the nominal heap box.
    packetOwners shape fields=[n | (CVar n,True)<-zip fields (productOwners shape)]
    retainField isOwned value k
      | instrument && isOwned = bind (call "$arc.retain" [value]) k
      | otherwise = k value
    clonePacket shape fields k = copy (zip fields (productOwners shape)) []
      where
        copy [] values = k (Packet shape (reverse values))
        copy ((v,o):rest) values = retainField o v (\v'->copy rest (v':values))
    word (One v) k = k v
    word (Packet shape fields) k = do
      when (length fields/=width shape) (bad "incomplete product materialization")
      let (tid,variant,_)=productParts shape
          kinds=[case f of ProductWord kind _->kind;ProductNested _->Managed | f<-productFields shape]
          materialize [] cont=cont []
          materialize ((_,field,values):rest) cont=case (field,values) of
            (ProductWord _ _,[v])->materialize rest (cont . (v:))
            (ProductNested child,_)->word (Packet child values) (\v->materialize rest (cont . (v:)))
            _->bad "incomplete product field"
      materialize (fieldSlices shape fields) $ \values -> bind (CMk tid variant values) $ \v ->
        if instrument then bind (call "$arc.setLayout" [v,CStr (map kindTag kinds)]) (const (k v)) else k v
    unpack shape boxed k = bind boxed $ \v ->
      let extract [] cont=cont []
          extract ((i,field):rest) cont=case field of
            ProductWord _ ownedField -> bind (if instrument && ownedField then call "$arc.retain" [CProj i v] else CProj i v) $ \value ->
              extract rest (cont . (value:))
            ProductNested child -> unpack child (if instrument then call "$arc.retain" [CProj i v] else CProj i v) $ \value ->case value of
              Packet actual values | actual==child->extract rest (cont . (values++))
              _->bad "nested unpack lost its product shape"
      in extract (zip [0..] (productFields shape)) $ \fields -> do
           rest <- k (Packet shape fields)
           case v of CVar n -> release [n] rest; _ -> bad "unbound product box"
    -- A one-leaf packet uses the ordinary one-word private result convention.
    -- Its ownership is still carried by the checked packet, not by a box.
    packet shape body k | width shape==1 = bind body (\v->k (Packet shape [v]))
    packet shape body k = do
      root <- fresh
      fields <- mapM (const fresh) [0..width shape-1]
      rest <- k (Packet shape (map CVar fields))
      pure (CLet root body (foldr (\(i,n) b -> CLet n (CProj i (CVar root)) b) rest (zip [0..] fields)))
    encode (One v) = v
    encode (Packet shape [v]) | width shape==1 = v
    encode (Packet shape fields) = call (packName (width shape)) fields
    bindValue value k = case value of
      One v -> bind v (k . One)
      Packet shape fields -> sequenceValues fields (k . Packet shape)
    owner value original = case value of
      One (CVar n) | owned original -> [n]
      Packet shape fields -> packetOwners shape fields
      _ -> []

    -- A local packet's owners outlive its lexical aliases and field bindings.
    -- Borrow here; each consuming use still retains through ordinary evaluation
    -- before the enclosing owners are released. A nested packet alias borrows
    -- its exact leaf slice from those same live parent owners.
    borrowedBinding env expr = case expr of
      CVar n | Just packetValue@(Packet _ _)<-M.lookup n env -> Just packetValue
      CProj i obj@(CVar n)
        | Just shape<-M.lookup obj shapes,
          Just (Packet actual fields)<-M.lookup n env,
          actual==shape,i>=0,
          (_,field,values):_<-drop i (fieldSlices shape fields) ->case (field,values) of
            (ProductWord _ _,[v]) | M.notMember expr shapes->Just (One v)
            (ProductNested child,_) | M.lookup expr shapes==Just child->Just (Packet child values)
            _->Nothing
      _ -> Nothing

    lower (name,(ps,body)) = do
      slots <- forM (zip3 ps (arguments name) (argumentABI name)) $ \(source,shape,abi) -> do
        physical <- mapM (const fresh) [1..maybe 1 width abi]
        pure (source,shape,abi,physical)
      let parameters = concat [ns | (_,_,_,ns)<-slots]
          owners = [head ns | ((_,shape,_,ns),kind,immortal)<-zip3 slots (paramKinds M.! name)
                            (M.findWithDefault (repeat False) name immortalArgs),
                            shape==Nothing, kind==Managed, not immortal]
          enter [] env pending = tailE (resultABI name) env pending body
          enter ((source,shape,abi,ns):rest) env pending = case (shape,abi,ns) of
            (Just sh,Just sh',_) | sh==sh' ->
              enter rest (M.insert source (Packet sh (map CVar ns)) env) (packetOwners sh (map CVar ns)++pending)
            (Just sh,Nothing,[n]) -> unpack sh (CVar n) (\v -> enter rest (M.insert source v env) (owner v body++pending))
            (Nothing,Nothing,[n]) -> enter rest (M.insert source (One (CVar n)) env) pending
            _ -> bad "inconsistent checked product parameter ABI"
      output <- enter slots M.empty owners
      pure (names M.! name,(parameters,output))

    target env f args = case f of
      CVar n | M.notMember n env -> case M.lookup n arities of
        Just ar | ar==length args -> pure (n,names M.! n,argumentABI n,resultABI n)
                | otherwise -> bad ("partial/over-application of "++n)
        Nothing -> case M.lookup n primitives of
          Just (ar,adapter) | ar==length args -> do
            let selected = case (n,args) of
                  (op,[a,_]) | op `elem` ["==","!="], not (managed a) ->
                    case M.lookup a ann of
                      Just RawF64 -> "$arc.F64"++if op=="==" then "eq" else "ne"
                      Just RawF32 -> "$arc.F32"++if op=="==" then "eq" else "ne"
                      _ -> if op=="==" then "$arc.rawEq" else "$arc.rawNe"
                  (op,[a]) | op `elem` ["str","print"], not (managed a) ->
                    if M.lookup a ann `elem` [Just RawWord,Just RawAddr]
                    then if op=="str" then "$arc.wordStr" else "$arc.wordPrint"
                    else "$arc."++(if M.lookup a ann==Just RawF64 then "F64" else "F32")++op
                  _ -> adapter
            pure (n,selected,replicate ar Nothing,Nothing)
          _ -> bad ("unsupported primitive or application: "++n)
      _ -> bad "indirect calls and partial applications are not supported yet"
    argsE _ [] [] k = k []
    argsE env (a:as) (shape:shapes') k = eval env a $ \value ->
      let rest values = argsE env as shapes' (k . (values++)) in
      case (shape,value) of
        (Nothing,_) -> word value (rest . (:[]))
        (Just expected,Packet actual fields) | expected==actual -> rest fields
        _ -> bad "call argument lost its checked product shape"
    argsE _ _ _ _ = bad "call argument shape arity mismatch"
    withCall env expr k = let (f,args)=spine expr in do
      (_,name,params,result) <- target env f args
      argsE env args params (\vs -> k name vs result)
    callValue env expr k = withCall env expr $ \name args result -> case result of
      Just shape -> packet shape (call name args) k
      Nothing -> bind (call name args) (k . One)
    wordE env expr k = eval env expr (\value -> word value k)

    eval env expr k = case M.lookup expr shapes of
      Just shape -> productE shape env expr k
      Nothing -> ordinary env expr k
    productE shape env expr k = case expr of
      CVar n | Just value<-M.lookup n env -> case value of
        Packet actual fields | actual==shape -> clonePacket shape fields k
        _ -> bad "local value lost its checked product shape"
      CLet x a b | Just borrowed<-borrowedBinding env a ->
        productE shape (M.insert x borrowed env) b k
      CLet x a b -> eval env a $ \v -> bindValue v $ \bound ->
        productE shape (M.insert x bound env) b (\r -> k r >>= release (owner bound a))
      CIf c t f -> wordE env c $ \cv -> do
        yes <- eval env t (pure . encode) >>= releaseValue c (One cv)
        no <- eval env f (pure . encode) >>= releaseValue c (One cv)
        let joined=CIf cv yes no
        packet shape (if width shape==1 then joined else call (valueName (width shape)) [joined]) k
      CMk tid variant fs | let (t,v,_)=productParts shape, (tid,variant)==(t,v),length fs==length (productFields shape) ->
        argsE env fs [case field of ProductNested child->Just child;_->Nothing | field<-productFields shape] (k . Packet shape)
      -- A product stored inside a heap object is still a nominal box. Retain
      -- that child before releasing its parent, retain its owned fields, then
      -- release the child exactly once. The packet owns those field references.
      CProj _ obj | M.member obj shapes -> ordinary env expr $ \value -> case value of
        One child -> unpack shape child k
        Packet actual _ | actual==shape -> k value
        _ -> bad "nested product field lost its boxed representation"
      CProj i obj -> wordE env obj $ \v ->
        bind (if instrument then call "$arc.retain" [CProj i v] else CProj i v) $ \child -> do
          rest <- unpack shape child k
          releaseValue obj (One v) rest
      CErr _ -> pure expr
      CApp {} -> callValue env expr $ \value -> case value of
        Packet actual _ | actual==shape -> k value
        One boxed -> unpack shape boxed k
        _ -> bad "call result has a different product shape"
      CVar n | Just 0<-M.lookup n arities -> callValue env expr $ \value -> case value of
        Packet actual _ | actual==shape -> k value
        One boxed -> unpack shape boxed k
        _ -> bad "nullary call result has a different product shape"
      _ -> bad "unsupported checked product expression"

    ordinary env expr k = case expr of
      CVar n -> case M.lookup n env of
        Just (One v) -> if owned expr then bind (call "$arc.retain" [v]) (k . One) else k (One v)
        Just (Packet shape fields) -> clonePacket shape fields k
        Nothing | "$sym." `isPrefixOf` n -> k (One expr)
        Nothing | Just 0<-M.lookup n arities -> callValue env expr k
        Nothing -> bad ("function values or unsupported global: "++n)
      CInt _ -> k (One expr)
      CStr _ -> k (One expr)
      CLet x a b | Just borrowed<-borrowedBinding env a ->
        eval (M.insert x borrowed env) b k
      CLet x a b -> eval env a $ \v -> bindValue v $ \bound ->
        eval (M.insert x bound env) b (\r -> k r >>= release (owner bound a))
      CIf c t f -> wordE env c $ \cv -> do
        yes <- wordE env t pure >>= releaseValue c (One cv)
        no <- wordE env f pure >>= releaseValue c (One cv)
        bind (CIf cv yes no) (k . One)
      CMk tid variant [field] | Just shape<-M.lookup expr scalars ->
        if shape==(tid,variant) then eval env field k else bad "scalar constructor disagrees with checked layout"
      CMk tid variant fields -> argsE env fields (replicate (length fields) Nothing) $ \vs ->
        bind (CMk tid variant vs) $ \v ->
          if null fields || not instrument then k (One v)
          else bind (call "$arc.setLayout" [v,CStr [kindTag (ann M.! f) | f<-fields]]) (const (k (One v)))
      CProj i obj | M.member obj scalars -> if i==0 then eval env obj k else bad "scalar projection exceeds checked layout"
      CProj i obj | Just shape<-M.lookup obj shapes ->
        if i<0 || i>=length (productFields shape) then bad "product projection exceeds checked layout"
        else let project fields retain = case fieldSlices shape fields!!i of
                   (_,ProductWord _ ownedField,[v])->if retain then retainField ownedField v (k . One) else k (One v)
                   (_,ProductNested child,values)->if retain then clonePacket child values k else k (Packet child values)
                   _->bad "incomplete projected product field"
             in case obj of
          CVar n | Just (Packet actual fields)<-M.lookup n env,actual==shape ->
            project fields True
          _ -> productE shape env obj $ \value -> case value of
            Packet _ fields -> let (offset,field,_)=fieldSlices shape fields!!i in project fields False >>=
              release [n | (j,(CVar n,True))<-zip [0..] (zip fields (productOwners shape)),j<offset || j>=offset+productFieldWidth field]
            _ -> bad "product projection lost its checked shape"
      CProj i obj -> wordE env obj $ \v ->
        bind (if owned expr then call "$arc.retain" [CProj i v] else CProj i v) $ \r ->
          k (One r) >>= releaseValue obj (One v)
      CTagEq tid variant obj | Just shape<-M.lookup obj scalars ->
        eval env obj (const (k (One (CMk 1 (if shape==(tid,variant) then 1 else 0) []))))
      CTagEq tid variant obj | Just shape<-M.lookup obj shapes ->
        let (t,v,_)=productParts shape;answer=One (CMk 1 (if (tid,variant)==(t,v) then 1 else 0) []) in
        case obj of
          CVar n | Just (Packet actual _)<-M.lookup n env,actual==shape -> k answer
          _ -> eval env obj (\value->k answer >>= releaseValue obj value)
      CTagEq tid variant obj -> wordE env obj $ \v ->
        bind (CTagEq tid variant v) $ \r -> k (One r) >>= releaseValue obj (One v)
      CApp {} -> callValue env expr k
      CErr _ -> pure expr
      CLam {} -> bad "lambda survived lifting"

    finish wanted owners value = case (wanted,value) of
      (Just expected,Packet actual fields) | expected==actual -> release owners (encode (Packet actual fields))
      (Nothing,_) -> word value (release owners)
      _ -> bad "function result lost its checked product shape"
    tailE wanted env owners expr = case expr of
      CLet x a b | Just borrowed<-borrowedBinding env a ->
        tailE wanted (M.insert x borrowed env) owners b
      CLet x a b -> eval env a $ \v -> bindValue v $ \bound ->
        tailE wanted (M.insert x bound env) (owner bound a++owners) b
      CIf c t f -> wordE env c $ \cv -> do
        yes <- tailE wanted env owners t >>= releaseValue c (One cv)
        no <- tailE wanted env owners f >>= releaseValue c (One cv)
        pure (CIf cv yes no)
      CErr _ -> pure expr
      _ | CApp {}<-expr -> tailCall
        | CVar n<-expr, M.notMember n env, Just 0<-M.lookup n arities -> tailCall
        | otherwise -> eval env expr (finish wanted owners)
      where
        tailCall = withCall env expr $ \name args result ->
          if result==wanted then release owners (call name args) else case result of
            Just shape -> packet shape (call name args) (finish wanted owners)
            Nothing -> bind (call name args) $ \boxed -> case wanted of
              Just shape -> unpack shape boxed (finish wanted owners)
              Nothing -> finish wanted owners (One boxed)
