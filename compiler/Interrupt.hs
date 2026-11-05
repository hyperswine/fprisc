{-# LANGUAGE FlexibleContexts #-}
-- Allocation-free, non-reentrant interrupt entry contract, checked transitively
-- on lifted Core before ownership instrumentation. Raw memory remains unsafe:
-- the programmer must not touch the allocator, ARC objects or reserved stacks.
module Interrupt
  (checkInterrupt, checkRawUnit, checkInterruptWithStorage, checkRawUnitWithStorage,
   checkInterruptWithProducts, checkRawUnitWithProducts, rawRoots,
   checkLoweredProducts) where
import Core.Syntax (Core(..), Prog)
import Representation (primitiveShape)
import Representation.Types (ProductShape(..),productOwners,productParts,productFields)
import Core.ProductABI (ProductMarker(..),productMarker)
import Core.Opt.PairReturns (productWorkerWidth)
import Control.Monad.State.Strict (evalStateT,get,modify,lift)
import Control.Monad (foldM, unless)
import Data.List (isPrefixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

checkInterrupt :: Prog -> Either String ()
checkInterrupt=checkInterruptWithStorage M.empty

checkInterruptWithStorage :: M.Map Core (Int,Int) -> Prog -> Either String ()
checkInterruptWithStorage scalars=checkInterruptWithProducts scalars M.empty

checkInterruptWithProducts :: M.Map Core (Int,Int) -> M.Map Core ProductShape -> Prog -> Either String ()
checkInterruptWithProducts scalars products prog
  | M.notMember "machineInterrupt" prog = Right ()
  | otherwise = checkFrom scalars products "interrupt contract" handlerPrim prog ["machineInterrupt"]

-- A handler may not touch the allocator or interrupt control.
handlerPrim :: String -> Bool
handlerPrim n = rawPrim n && n `notElem`
  ["CPU.csrWrite","CPU.irqEnable","CPU.irqRestore","CPU.wait"]

rawPrim :: String -> Bool
rawPrim n = n `notElem`
  ["str","print","strcat","String.len","error","F64.str","F32.str",
   "I32.str","I32.strU","I32.hex","I32.parse","I32.toInt","I32.toIntU",
   "Mem.alloc","Mem.realloc","Mem.free","Mem.liveAllocations"]

-- A RAW UNIT (--raw): every function is held to the allocation-free
-- contract, so ownership instrumentation can be left out entirely --
-- the unit's only values are raw words, addresses, floats, tagged Ints
-- and the immortal Bool/Unit, and retain/release of those are no-ops.
-- This is what lets the allocator itself be written in FP-RISC: an
-- instrumented allocator would call fpr_builtin_retain on its own Int
-- temporaries, which is the allocator, which ... (the first heap.fpr
-- image died exactly that way).  Unlike a handler, a raw unit may touch
-- CSRs and interrupt control: drivers live here.
checkRawUnit :: Prog -> Either String ()
checkRawUnit=checkRawUnitWithStorage M.empty

checkRawUnitWithStorage :: M.Map Core (Int,Int) -> Prog -> Either String ()
checkRawUnitWithStorage scalars=checkRawUnitWithProducts scalars M.empty S.empty

checkRawUnitWithProducts :: M.Map Core (Int,Int) -> M.Map Core ProductShape -> S.Set String -> Prog -> Either String ()
checkRawUnitWithProducts scalars products pinned prog =
  checkFrom scalars products "raw unit" rawPrim prog (rawRoots pinned prog)

-- Uncalled constructor stubs may be present in every unit. An exported stub
-- is callable from outside, so it must satisfy the raw contract as a root.
rawRoots :: S.Set String -> Prog -> [String]
rawRoots pinned prog = [n | (n,(ps,b))<-M.toList prog, S.member n pinned || not (isStub ps b)]
  where
    isStub ps (CMk _ _ fs) = fs == map CVar ps
    isStub _ _ = False

checkFrom :: M.Map Core (Int,Int) -> M.Map Core ProductShape -> String -> (String -> Bool) -> Prog -> [String] -> Either String ()
checkFrom scalars products what allowedPrim prog roots = () <$ foldM visit S.empty roots
  where
    bad msg = Left ("automatic ARC: " ++ what ++ ": " ++ msg)
    visit seen n
      | S.member n seen = Right seen
      | otherwise = case M.lookup n prog of
          Just (ps,b) -> do
            unless (length ps <= 8) $ bad (n ++ " exceeds the register-only argument ABI")
            either (Left . (++ " (in " ++ n ++ ")")) Right (walk (S.insert n seen) b)
          Nothing -> if allowed n || "$sym." `isPrefixOf` n then Right seen else bad ("call to " ++ n ++ " may allocate or alter interrupt control")
    -- Representation lowering can introduce boxing after source checking.
    -- A known conversion primitive is not evidence that it is allocation-
    -- free: promotion allocates and demotion may release owned heap storage.
    -- Neither belongs in a handler or allocator-bootstrap raw unit.
    allowed n = not ("$uniform." `isPrefixOf` n) && primitiveShape n /= Nothing && allowedPrim n
    walk seen e | Just shape<-M.lookup e products,or (productOwners shape) =
      bad "owned-reference products are not admitted here"
    walk seen e = case e of
      -- `error "literal"`: a static, non-returning panic through a rodata
      -- string -- no allocation, so it is admitted where nothing else
      -- string-shaped is
      CApp (CVar "error") (CStr _) -> Right seen
      CStr _ -> bad "string values are not admitted here"
      CMk tid variant [field] | M.lookup e scalars==Just (tid,variant) -> walk seen field
      CProj 0 obj | M.member obj scalars -> walk seen obj
      CMk tid variant fields
        | Just shape<-M.lookup e products,let (t,v,_)=productParts shape,
          (tid,variant)==(t,v),length fields==length (productFields shape) -> foldM walk seen fields
      CProj i obj | Just shape<-M.lookup obj products,
                    i>=0,i<length (productFields shape) -> walk seen obj
      CMk _ _ (_:_) -> bad "heap construction is not admitted here"
      CProj {} -> bad "managed field projection is not admitted here"
      CLam {} -> bad "lambda survived lifting"
      CErr _ -> Right seen -- static diagnostic and non-returning, allocation-free panic
      CVar n | M.member n prog -> visit seen n
      CApp {} -> let (f,as)=spine e in case f of
        CVar n -> do s <- visit seen n; foldM walk s as
        _ -> bad "indirect application is not admitted here"
      CLet _ a b -> walk seen a >>= (`walk` b)
      CIf c t f -> walk seen c >>= (`walk` t) >>= (`walk` f)
      CTagEq _ _ x -> walk seen x
      _ -> Right seen

spine :: Core -> (Core,[Core])
spine = go [] where
  go as (CApp f x) = go (x:as) f
  go as f = (f,as)


-- Source proofs alone cannot admit products: lowering can materialize a box
-- at a one-word boundary or expand arguments beyond the register-only ABI.
-- Inspect the actual lowered call graph. Every projection must select a word
-- from a statically known private packet; a heap load is never admitted.
-- This check follows the source representation/primitive check above, which
-- establishes that ordinary values are raw scalars or immortal/tagged values.
data PhysicalValue = WordValue | ProductValue Int | Stops deriving (Eq,Show)

checkLoweredProducts :: Bool -> [(String,Int,String)] -> [String] -> Prog -> Either String ()
checkLoweredProducts handler contracts roots prog = evalStateT (mapM_ visit roots) S.empty
  where
    what=if handler then "interrupt contract" else "raw unit"
    bad msg=lift (Left ("automatic ARC: "++what++": "++msg))
    allowedSource n = not ("$uniform." `isPrefixOf` n) && primitiveShape n/=Nothing
      && (if handler then handlerPrim else rawPrim) n
    adapters=M.fromList ([("$arc."++adapter,arity) | (source,arity,adapter)<-contracts,allowedSource source]
      ++ [("$arc.rawEq",2),("$arc.rawNe",2)]
      ++ [(n,1) | handler,n<-["$arc.retain","$arc.release"]])
    result n=maybe WordValue ProductValue (productWorkerWidth n)
    compatible Stops _=True
    compatible a b=a==b
    scalar value=unless (compatible value WordValue) (bad "product passed to a one-word operation")
    visit n=do
      seen<-get
      unless (S.member n seen) $ case M.lookup n prog of
        Nothing->bad ("missing lowered entry "++n)
        Just (ps,body)->do
          unless (length ps<=8) (bad (n++" exceeds the register-only argument ABI after product expansion"))
          modify (S.insert n)
          value<-walk (M.fromList [(p,WordValue) | p<-ps]) body
          unless (compatible value (result n)) (bad ("lowered result convention mismatch in "++n))
    wordsOf env args=mapM_ (\a->walk env a >>= scalar) args
    invoke env n args=case M.lookup n prog of
      Just (ps,_)->do
        unless (length ps==length args) (bad ("lowered call arity mismatch at "++n))
        visit n
        wordsOf env args
        pure (result n)
      Nothing | Just arity<-M.lookup n adapters,arity==length args->wordsOf env args >> pure WordValue
      _->bad ("lowered call to "++n++" may allocate or alter interrupt control")
    walk env expr=case expr of
      CVar n | Just value<-M.lookup n env->pure value
             | "$sym." `isPrefixOf` n->pure WordValue
             | otherwise->invoke env n []
      CInt _->pure WordValue
      CStr _->bad "string values are not admitted after product lowering"
      CErr _->pure Stops
      CLet x a b->do value<-walk env a; walk (M.insert x value env) b
      CIf c t f->do
        walk env c >>= scalar
        yes<-walk env t
        no<-walk env f
        case (yes,no) of
          (Stops,v)->pure v
          (v,Stops)->pure v
          _ | yes==no->pure yes
            | otherwise->bad "branch arms disagree on the product convention"
      CMk _ _ []->pure WordValue
      CMk {}->bad "heap materialization is not admitted after product lowering"
      CProj i obj->do
        value<-walk env obj
        case value of
          ProductValue n | i>=0 && i<n->pure WordValue
          Stops->pure Stops
          _->bad "heap projection is not admitted after product lowering"
      CTagEq _ _ obj->walk env obj >>= scalar >> pure WordValue
      CApp (CVar "$arc.error") (CStr _)->pure Stops
      CApp {}->case spine expr of
        (CVar name,args) | M.notMember name env->case productMarker name of
          Just (PackWords n) | length args==n->wordsOf env args >> pure (ProductValue n)
          Just (JoinWords n) | [body]<-args->do
            value<-walk env body
            unless (compatible value (ProductValue n)) (bad "invalid product branch join")
            pure value
          Just _->bad "invalid private product marker arity"
          Nothing->invoke env name args
        _->bad "indirect application is not admitted after product lowering"
      CLam {}->bad "lambda survived product lowering"
