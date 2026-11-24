{-# LANGUAGE LambdaCase #-}
-- Core analysis utilities: alpha equality, private-name scoping, fusion policy & safety.
module Core.Analysis
  ( sameFunction, qualifyPrivate, programNames,
    safePrimitives, trapFreePrimitives, safePrimitiveArity,
    fusionSafe, fusionUnsafeReason
  ) where

import Core.Syntax
import Core.Primitives
import Data.List (isSuffixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- Alpha equality (formerly Core.Analysis)
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

-- Private-name scoping (formerly Core.Analysis)
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

-- Fusion policy (formerly Core.Analysis)
bitwisePrimitives :: [String]
bitwisePrimitives = ["band","bor","bxor"]

safePrimitives :: [String]
safePrimitives = [op | op<-uPrims,op/="/"]
  ++[op | width<-[Float64,Float32],op<-fPrimsOf width,not ("/" `isSuffixOf` op)]
  ++["and","or","not","and2","or2"]
  ++bitwisePrimitives

-- What cannot trap at all: comparisons, Boolean operators, bitwise ops, and
-- float arithmetic other than division. band/bor/bxor are total on exact Int
-- (including T_BIGINT): they may allocate a bignum result but never trap on a
-- well-typed Int. FusionSafety is an effect-order judgement, not a no-heap
-- one, so allocation does not make them unsafe to fuse. Int +, - and * trap on overflow.
trapFreePrimitives :: [String]
trapFreePrimitives = ["==","!=","<",">","<=",">="]
  ++[op | width<-[Float64,Float32],op<-fPrimsOf width,not ("/" `isSuffixOf` op)]
  ++["and","or","not","and2","or2"]
  ++bitwisePrimitives

-- Arity of a fusion-safe primitive, including total HAL bitwise ops that are
-- not core primArities entries.
safePrimitiveArity :: String -> Maybe Int
safePrimitiveArity name
  | name `elem` bitwisePrimitives = Just 2
  | otherwise = lookup name primArities

-- Fusion safety (formerly Core.Analysis)
fusionSafe :: Prog -> String -> Bool
fusionSafe prog f = fusionUnsafeReason prog f == Nothing

-- the first construct that makes a function observable, if any
fusionUnsafeReason :: Prog -> String -> Maybe String
fusionUnsafeReason prog = go S.empty
  where
    go seen n
      | S.member n seen = Nothing
      | otherwise = case M.lookup n prog of
          Nothing -> Just ("`" ++ n ++ "` is not a known function")
          Just (ps, body) -> body' (S.insert n seen) (S.fromList ps) body
    body' _ _ e | Just _ <- floatLitBits e = Nothing
    body' seen env e = case spineOf e of
      (CVar h, args@(_ : _))
        | h `elem` safePrims, Just ar <- safePrimitiveArity h, length args == ar -> firstJust (map (body' seen env) args)
        | h `elem` safePrims -> Just ("a partial application of `" ++ h ++ "`")
        | h == entryTickName -> Nothing
        | S.member h env -> Just ("a call through the parameter `" ++ h ++ "` (unknown function)")
        | Just (ps, _) <- M.lookup h prog, length ps == length args -> firstJust (map (body' seen env) args ++ [go seen h])
        | Just _ <- M.lookup h prog -> Just ("a partial application of `" ++ h ++ "`")
        | otherwise -> Just ("the primitive `" ++ h ++ "`")
      _ -> case e of
        CVar v | S.member v env -> Nothing
        CVar g | Just (ps, _) <- M.lookup g prog, null ps -> go seen g -- a CAF
        CVar g -> Just ("the function value `" ++ g ++ "`")
        CInt _ -> Nothing
        CStr _ -> Nothing
        CMk _ _ fs -> firstJust (map (body' seen env) fs)
        CTagEq _ _ x -> body' seen env x
        CProj _ x -> body' seen env x
        CIf c t f -> firstJust (map (body' seen env) [c, t, f])
        CLet x a b -> firstJust [body' seen env a, body' seen (S.insert x env) b]
        CLam ps b -> body' seen (S.union (S.fromList ps) env) b
        CErr _ -> Nothing -- an exhaustiveness-proven dead arm
        _ -> Just "an unrecognized construct"
    firstJust xs = case [r | Just r <- xs] of
      (r : _) -> Just r
      [] -> Nothing
    -- cannot be OBSERVED: everything in the Int/F64/F32 arithmetic tiers
    -- except division, plus comparison and logic.  Int + - * trap on
    -- overflow (docs/2026-10-12-INT-OVERFLOW.md); a fused pair may then
    -- panic on an earlier element, or in the other function, than the
    -- two passes would -- the ONE reordering fusion is allowed, by the
    -- relaxation of 2026-10-13 (docs/2026-10-03-FUSION-EFFECT-ORDER.md):
    -- the program still fail-stops with an Int overflow, and the pair
    -- was its own two passes otherwise.  Division stays out: a zero
    -- divisor is a different failure, and the line is kept narrow.
    safePrims = safePrimitives

