-- P2 typed lowering, slice 1, step 0 (docs/2026-11-08-P2-TYPED-LOWERING-SLICE-1.md):
-- classify the checked definitions a unit emits by what a typed lowering
-- would have to handle. Each definition is counted once, in the narrowest
-- class of a widening ladder that admits it, so each column reads as "what
-- this widening adds":
--
--   t1          first-order Int/Bool: scalar signature, scalar primitives,
--               literal/binder matches (Match, MatchTail: `if` arrives as
--               a MatchTail), calls only to other t1 functions
--   calls       t1 plus calls to any known function (tagged convention)
--   joins       plus join calls (closed-program join points become blocks)
--   products    plus constructors, tuples, records and their patterns
--   strings     plus string literals and string patterns
--   lists       plus list literals and list builders
--   closures    plus lambdas, closures, code and join calls
--   vectors     plus vector builds and pair-free reads
--   polymorphic a type variable in the signature (counted before the rest)
--   other       anything else (LetRec, layout literals, regions, ...)
module Compiler.Native.TypedCensus (Census(..), census, censusNote) where
import Core.Typed.Syntax
import Core.Typed.Walk (mapChildrenM)
import Type.Syntax (Type(..))
import Data.Functor.Const (Const(..))
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data Class = T1 | Calls | Joins | Products | Strings | Lists | Closures | Vectors | Polymorphic | Other
  deriving (Eq, Ord, Show, Enum, Bounded)

newtype Census = Census (M.Map Class Int)

-- The scalar primitives Codegen.Lower and the worker pass accept by name.
scalarPrimitives :: S.Set String
scalarPrimitives = S.fromList ["+","-","*","/","%","==","!=","<",">","<=",">=","not","&&","||"]

data Feature = FCall | FJoin | FProduct | FString | FList | FClosure | FVector | FOther
  deriving (Eq, Ord, Show)

census :: M.Map String Function -> Census
census functions = Census (M.fromListWith (+) [(classOf n, 1) | n <- M.keys functions])
  where
    info = M.map describe functions
    describe f = (scalarSig f, polymorphicSig f, features f, globals (functionBody f))
    -- t1 is a greatest fixed point: drop candidates calling a non-t1 global
    candidates = M.keysSet (M.filter (\(s, p, fs, _) -> s && not p && S.null fs) info)
    t1 = fixT1 candidates
    fixT1 set =
      let keep n = case M.lookup n info of
            Just (_, _, _, gs) -> all (\g -> S.member g set || S.member g scalarPrimitives) (S.toList gs)
            Nothing -> False
          next = S.filter keep set
      in if next == set then set else fixT1 next
    classOf n = case M.lookup n info of
      Nothing -> Other
      Just (s, p, fs, _)
        | S.member n t1 -> T1
        | p -> Polymorphic
        | s && fs `S.isSubsetOf` S.fromList [FCall] -> Calls
        | s && fs `S.isSubsetOf` S.fromList [FCall, FJoin] -> Joins
        | fs `S.isSubsetOf` S.fromList [FCall, FJoin, FProduct] -> Products
        | fs `S.isSubsetOf` S.fromList [FCall, FJoin, FProduct, FString] -> Strings
        | fs `S.isSubsetOf` S.fromList [FCall, FJoin, FProduct, FString, FList] -> Lists
        | fs `S.isSubsetOf` S.fromList [FCall, FJoin, FProduct, FString, FList, FClosure] -> Closures
        | fs `S.isSubsetOf` S.fromList [FCall, FJoin, FProduct, FString, FList, FClosure, FVector] -> Vectors
        | otherwise -> Other
    -- a call to a known function: a global that is neither a scalar primitive
    -- nor itself (self recursion keeps t1 candidacy; the fixed point checks it)
    features f = S.union (bodyFeatures (functionBody f))
      (if any (\g -> not (S.member g scalarPrimitives) && g /= functionName f) (S.toList (globals (functionBody f)))
         then S.singleton FCall else S.empty)

scalarType :: Type -> Bool
scalarType t = t == TC "Int" || t == TC "Bool"

signatureTypes :: Function -> [Type]
signatureTypes f = exprType (functionBody f) : map binderType (functionParameters f)

scalarSig :: Function -> Bool
scalarSig = all scalarType . signatureTypes

polymorphicSig :: Function -> Bool
polymorphicSig = any hasVariable . signatureTypes
  where
    hasVariable t = case t of
      TV _ -> True
      TAp a b -> hasVariable a || hasVariable b
      TFn a b -> hasVariable a || hasVariable b
      TTupT ts -> any hasVariable ts
      _ -> False

globals :: Expr -> S.Set String
globals e = here <> getConst (mapChildrenM (Const . globals) e)
  where here = case exprNode e of Var (Global n _) -> S.singleton n; _ -> S.empty

bodyFeatures :: Expr -> S.Set Feature
bodyFeatures e = here <> getConst (mapChildrenM (Const . bodyFeatures) e) <> patterns
  where
    here = case exprNode e of
      Var _ -> S.empty
      IntValue _ -> S.empty
      BoolValue _ -> S.empty
      BoolTest _ _ -> S.empty
      Apply _ _ -> S.empty
      Let _ _ _ -> S.empty
      If _ _ _ -> S.empty
      Note _ -> S.empty
      EntryTick -> S.empty
      Fail _ -> S.empty
      CallRegion _ -> S.empty
      Match CaseMatch _ _ -> S.empty
      Match (FunctionMatch _) _ _ -> S.empty
      Sequence _ _ -> S.empty
      LetPattern _ _ _ -> S.empty
      StringValue _ -> S.singleton FString
      Construct _ _ -> S.singleton FProduct
      AtomValue _ -> S.singleton FProduct
      TupleValue _ -> S.singleton FProduct
      RecordValue _ -> S.singleton FProduct
      RecordField _ _ -> S.singleton FProduct
      RecordUpdate _ _ -> S.singleton FProduct
      PlannedUpdate _ _ -> S.singleton FProduct
      SetField _ _ _ -> S.singleton FProduct
      ListValue _ -> S.singleton FList
      ListBuilder _ _ _ -> S.singleton FList
      -- a match with a fallback arm: control flow, judged by its patterns
      MatchTail _ _ _ _ -> S.empty
      JoinCall _ _ _ -> S.singleton FJoin
      Lambda _ _ -> S.singleton FClosure
      ClosureValue _ _ -> S.singleton FClosure
      CodeCall _ _ _ -> S.singleton FClosure
      ResultPipe _ _ -> S.singleton FClosure
      VectorBuild _ _ -> S.singleton FVector
      VectorReadPair _ _ _ -> S.singleton FVector
      LetRec _ _ _ -> S.singleton FOther
      LayoutLiteral _ -> S.singleton FOther
    patterns = case exprNode e of
      Match _ _ alts -> S.unions [S.unions (map patternFeatures ps) <> S.unions (map guardFeatures gs) | Alternative ps gs _ <- alts]
      MatchTail _ _ alts _ -> S.unions [S.unions (map patternFeatures ps) | Alternative ps _ _ <- alts]
      LetPattern p _ _ -> patternFeatures p
      _ -> S.empty
    guardFeatures g = case g of BoolGuard _ -> S.empty; PatternGuard p _ -> patternFeatures p

patternFeatures :: Pattern -> S.Set Feature
patternFeatures p = case patNode p of
  Bind _ -> S.empty
  Wildcard -> S.empty
  IntegerPattern _ -> S.empty
  StringPattern _ -> S.singleton FString
  ConstructorPattern n ps
    | n `elem` ["True", "False"] && null ps -> S.empty
    | n `elem` ["Cons", "Nil"] -> S.insert FList (S.unions (map patternFeatures ps))
    | otherwise -> S.insert FProduct (S.unions (map patternFeatures ps))
  TuplePattern ps -> S.insert FProduct (S.unions (map patternFeatures ps))
  RecordPattern _ -> S.singleton FProduct

censusNote :: Census -> String
censusNote (Census m) = "# typed lowering census: " ++ intercalate " "
  [label c ++ "=" ++ show (M.findWithDefault 0 c m) | c <- [minBound .. maxBound]]
  where
    label c = case c of
      T1 -> "t1"; Calls -> "calls"; Joins -> "joins"; Products -> "products"; Strings -> "strings"; Lists -> "lists"
      Closures -> "closures"; Vectors -> "vectors"; Polymorphic -> "polymorphic"; Other -> "other"
