{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}

{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# LANGUAGE FlexibleContexts #-}

-- Infer.hs — Hindley–Milner inference with row-polymorphic records for Sol.
--
-- Algorithm W over:
--
--   τ ::= α | C | τ τ | τ -> τ | (τ, ..) | { ρ }
--   ρ ::= ρα | ∅ | (l : τ | ρ)
--
-- Records are rows (Leijen-style): projection `e.f` constrains e to
-- {f : α | ρ} with fresh ρ — structural, width-subtyped via the open
-- tail. Sigs are rows by construction, so `(s : Sig)` params type as
-- {sig fields | ρ} and struct conformance is type-level: each struct
-- field's inferred type must unify with the sig's declared field type
-- under one shared carrier (`t`) instantiation per struct/sig pair.
--
-- Type application is structural (no kinds): `t a` in a sig unifies as
-- TAp (TV t) a — first-order HKT, enough for Functor without a kind
-- system, same simplification the specializer already banks on.
--
-- Deliberate PoC simplifications, called out where they bite:
--   * no value restriction (no ML-style refs at the language level)
--   * monomorphic recursion; polymorphism via SCC-ordered generalization
--   * sig matching by unification, not subsumption (weaker but simple)
--   * a handful of HAL builtins get generous schemes (Vec.get : Int ->
--     Vector -> (a, Vector) — the untyped-storage escape hatch)

module Infer where

import Control.Monad (foldM, forM, forM_, unless, when, zipWithM, zipWithM_)
import Control.Monad.State.Strict
import Data.Graph (SCC (..), stronglyConnComp)
import qualified Data.IntMap.Strict as IM
import qualified Data.List
import Data.List (foldl', intercalate, nub, stripPrefix)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import qualified Data.Set as S
import FPRISC
import Struct (Sigs, Structs)

-- ---- types ------------------------------------------------------------------

data Type
  = TV Int
  | TC Name
  | TAp Type Type
  | TFn Type Type
  | TRec Row
  | TTupT [Type]
  deriving (Eq, Show)

data Row
  = RV Int
  | RNil
  | RExt Name Type Row
  deriving (Eq, Show)

data Scheme = Forall [Int] [Int] Type deriving (Show) -- tvars, rowvars

tcon :: Name -> [Type] -> Type
tcon n = foldl' TAp (TC n)

tInt, tStr, tBool, tUnit, tAtom :: Type
tInt = TC "Int"

tF64, tF32 :: Type
tF64 = TC "F64"
tF32 = TC "F32"

-- does a type MENTION a float anywhere?  Bare floats str/render via
-- their prims; floats inside containers may not reach the tid-directed
-- render (raw bits would be dereferenced as headers) -- refused with a
-- named restriction instead of printed wrong.
mentionsFloat :: Type -> Bool
mentionsFloat = \case
  TC "F64" -> True
  TC "F32" -> True
  TAp a b -> mentionsFloat a || mentionsFloat b
  TFn a b -> mentionsFloat a || mentionsFloat b
  TTupT ts -> any mentionsFloat ts
  TRec r -> goR r
  _ -> False
  where
    goR = \case
      RExt _ t rest -> mentionsFloat t || goR rest
      _ -> False
tStr = TC "String"
tBool = TC "Bool"
tUnit = TC "Unit"
tAtom = TC "Atom"

tList :: Type -> Type
tList a = TAp (TC "List") a

tVector :: Type
tVector = TC "Vector"

tSString :: Type
tSString = TC "SString"

-- ---- inference monad --------------------------------------------------------

data IEnv = IEnv
  { iFresh :: !Int,
    iSub :: IM.IntMap Type, -- tvar solutions
    iRSub :: IM.IntMap Row, -- rowvar solutions
    iErrs :: [String],
    iNotes :: [(Name, String)], -- pretty-printed inferred schemes
    iHoles :: [(String, Type)], -- typed holes: ?name / ?? with site type
    iHolesP :: [(String, String)], -- same, pretty (zonked at end)
    iHoledCons :: S.Set (Name, Int), -- constructors with ?? fields: calls trap
    iNextSite :: !Int,
    iSites :: IM.IntMap (Name, Type), -- operator sites awaiting resolution
    iCarriers :: IM.IntMap (Name, Name), -- carrier var -> (param, sig)
    iHere :: Maybe Int, -- spans step 3: the innermost enclosing SMark's
                        -- source offset while inference walks under it;
                        -- report stamps it into diagnostics as "@OFF~ "
    iPairs :: IM.IntMap (Type, Type), -- operator sites whose operand types
                                     -- were NOT unified eagerly (both concrete,
                                     -- at least one user type): resolution may
                                     -- pick a two-typed operator global
    iLinSigs :: [(Name, ([LShape], LShape))] -- INFERRED linearity shapes
      -- per user bind (zonked types -> LShape): the linearity checker
      -- consumes these for functions WITHOUT an explicit sig, closing
      -- the audited hole where an unannotated function (main included)
      -- could double-use a Vec because liSigs only knew declared TSigs
  }

type I = State IEnv

freshT :: I Type
freshT = do s <- get; put s {iFresh = iFresh s + 1}; pure (TV (iFresh s))

freshR :: I Row
freshR = do s <- get; put s {iFresh = iFresh s + 1}; pure (RV (iFresh s))

report :: String -> I ()
report e = modify (\s -> s {iErrs = iErrs s ++ [stamp (iHere s) e]})
  where
    -- the error sinks resolve "@OFF~ " to file:line:col (anchorMsg)
    stamp (Just o) msg = "@" ++ show o ++ "~ " ++ msg
    stamp Nothing msg = msg

-- ---- zonking (chase solutions) ----------------------------------------------

zonk :: Type -> I Type
zonk = \case
  TV v -> do
    sub <- gets iSub
    case IM.lookup v sub of
      Just t -> zonk t
      Nothing -> pure (TV v)
  TAp a b -> TAp <$> zonk a <*> zonk b
  TFn a b -> TFn <$> zonk a <*> zonk b
  TRec r -> TRec <$> zonkR r
  TTupT ts -> TTupT <$> mapM zonk ts
  t -> pure t

zonkR :: Row -> I Row
zonkR = \case
  RV v -> do
    sub <- gets iRSub
    case IM.lookup v sub of
      Just r -> zonkR r
      Nothing -> pure (RV v)
  RExt l t r -> RExt l <$> zonk t <*> zonkR r
  RNil -> pure RNil

-- ---- unification ------------------------------------------------------------

occursT :: Int -> Type -> Bool
occursT v = \case
  TV v' -> v == v'
  TAp a b -> occursT v a || occursT v b
  TFn a b -> occursT v a || occursT v b
  TRec r -> occursTR v r
  TTupT ts -> any (occursT v) ts
  _ -> False

occursTR :: Int -> Row -> Bool
occursTR v = \case
  RExt _ t r -> occursT v t || occursTR v r
  _ -> False

rowTail :: Row -> Maybe Int
rowTail = \case
  RV v -> Just v
  RNil -> Nothing
  RExt _ _ r -> rowTail r

unify :: String -> Type -> Type -> I ()
unify ctx a0 b0 = do
  a <- zonk a0
  b <- zonk b0
  case (a, b) of
    (TV v, t) -> bindT v t
    (t, TV v) -> bindT v t
    (TC x, TC y) | x == y -> pure ()
    (TAp f x, TAp g y) -> unify ctx f g >> unify ctx x y
    (TFn x r, TFn y s) -> unify ctx x y >> unify ctx r s
    (TTupT xs, TTupT ys) | length xs == length ys -> zipWithM_ (unify ctx) xs ys
    (TRec r1, TRec r2) -> unifyRow ctx r1 r2
    _ -> do
      pa <- prettyT a
      pb <- prettyT b
      report (ctx ++ ": cannot unify " ++ pa ++ " with " ++ pb)
  where
    bindT v t
      | t == TV v = pure ()
      | occursT v t = report (ctx ++ ": occurs check (infinite type)")
      | otherwise = modify (\s -> s {iSub = IM.insert v t (iSub s)})

-- Leijen-style row unification: to unify (l : τ | r1) with row2, rewrite
-- row2 to expose l (inserting through its tail var if open), then unify
-- τ with the exposed type and the remainders with each other.
unifyRow :: String -> Row -> Row -> I ()
unifyRow ctx r1z r2z = do
  r1 <- zonkR r1z
  r2 <- zonkR r2z
  case (r1, r2) of
    (RV v, r) -> bindR v r
    (r, RV v) -> bindR v r
    (RNil, RNil) -> pure ()
    (RExt l t rest, r) -> walk l t rest r id
    (RNil, RExt l _ _) -> report (ctx ++ ": closed record has no field ." ++ l)
  where
    -- find l among r's EXPLICIT labels first; only if absent and r ends
    -- in a tail var do we instantiate the tail — and only THEN does a
    -- shared tail between the two rows mean an infinite row (Leijen)
    walk l t rest r acc = case r of
      RExt l' t' r'
        | l == l' -> unify ctx t t' >> unifyRow ctx rest (acc r')
        | otherwise -> walk l t rest r' (acc . RExt l' t')
      RV v
        | rowTail rest == Just v -> report (ctx ++ ": recursive row (field " ++ l ++ ")")
        | otherwise -> do
            a <- freshT
            tl <- freshR
            modify (\s -> s {iRSub = IM.insert v (RExt l a tl) (iRSub s)})
            unify ctx t a
            unifyRow ctx rest (acc tl)
      RNil -> do
        p2 <- prettyRow (acc RNil)
        report (ctx ++ ": record lacks field ." ++ l ++ " (has " ++ p2 ++ "))")
    bindR v r
      | r == RV v = pure ()
      | occursR v r = report (ctx ++ ": occurs check (recursive row)")
      | otherwise = modify (\s -> s {iRSub = IM.insert v r (iRSub s)})
    occursR v = \case
      RV v' -> v == v'
      RExt _ _ r -> occursR v r
      RNil -> False

-- ---- schemes ----------------------------------------------------------------

instantiate :: Scheme -> I Type
instantiate (Forall tvs rvs t) = do
  tm <- IM.fromList <$> mapM (\v -> (,) v <$> freshT) tvs
  rm <- IM.fromList <$> mapM (\v -> (,) v <$> freshR) rvs
  let goT = \case
        TV v -> fromMaybe (TV v) (IM.lookup v tm)
        TAp a b -> TAp (goT a) (goT b)
        TFn a b -> TFn (goT a) (goT b)
        TRec r -> TRec (goR r)
        TTupT ts -> TTupT (map goT ts)
        o -> o
      goR = \case
        RV v -> fromMaybe (RV v) (IM.lookup v rm)
        RExt lb ty r -> RExt lb (goT ty) (goR r)
        RNil -> RNil
  pure (goT t)

ftv :: Type -> (S.Set Int, S.Set Int) -- (tvars, rowvars)
ftv = \case
  TV v -> (S.singleton v, S.empty)
  TAp a b -> ftv a <> ftv b
  TFn a b -> ftv a <> ftv b
  TTupT ts -> mconcat (map ftv ts)
  TRec r -> ftvR r
  _ -> mempty
  where
    ftvR = \case
      RV v -> (S.empty, S.singleton v)
      RExt _ t r -> ftv t <> ftvR r
      RNil -> mempty

type TEnv = M.Map Name Scheme

generalize :: TEnv -> Type -> I Scheme
generalize env t0 = do
  t <- zonk t0
  envFtv <- mconcat <$> mapM schemeFtv (M.elems env)
  let (tv, rv) = ftv t
      (etv, erv) = envFtv
  pure (Forall (S.toList (tv S.\\ etv)) (S.toList (rv S.\\ erv)) t)
  where
    schemeFtv (Forall qs rqs ty) = do
      ty' <- zonk ty
      let (tv, rv) = ftv ty'
      pure (tv S.\\ S.fromList qs, rv S.\\ S.fromList rqs)

mono :: Type -> Scheme
mono = Forall [] []

-- ---- Ty (surface annotations) -> Type ---------------------------------------

-- named surface vars (a, b, t) map through a shared table so `t` is the
-- same var across a sig's fields; unseen names allocate fresh
tyToType :: M.Map Name Type -> Ty -> I (Type, M.Map Name Type)
tyToType = tyToTypeA M.empty

-- with named record aliases (`MyRecord = {a : String, b : Int}.`): a bare
-- TCon hit in the alias table becomes its (closed) record type
type ShapeAliases = M.Map Name [(Name, Ty)]

keepBoth :: Type -> Type -> Type
keepBoth a (TTupT xs) = TTupT (a : xs)
keepBoth a b = TTupT [a, b]

tyToTypeA :: ShapeAliases -> M.Map Name Type -> Ty -> I (Type, M.Map Name Type)
tyToTypeA aliases tbl0 ty = runStateT (go ty) tbl0
  where
    go :: Ty -> StateT (M.Map Name Type) I Type
    go = \case
      TVarT n -> var n
      TCon "??" [] -> lift freshT
      TCon ('?' : hn) [] -> do
        a <- lift freshT
        lift (modify (\st -> st {iHoles = iHoles st ++ [(hn, a)]}))
        pure a
      TCon n [] | Just fs <- M.lookup n aliases -> do
        tfs <- mapM (\(f, t) -> (,) f <$> go t) fs
        pure (TRec (foldr (\(f, t) r -> RExt f t r) RNil tfs))
      TCon n args -> foldl' TAp (TC (canon n)) <$> mapM go args
      TVApp n args -> do h <- var n; foldl' TAp h <$> mapM go args
      TArrT a b -> TFn <$> go a <*> go b
      TTup ts -> TTupT <$> mapM go ts
      TOther -> do
        a <- lift freshT
        Control.Monad.State.Strict.modify (M.insertWith keepBoth "$holes" a)
        pure a
    var n = do
      tbl <- get
      case M.lookup n tbl of
        Just v -> pure v
        Nothing -> do v <- lift freshT; put (M.insert n v tbl); pure v
    canon "Str" = "String"
    canon n = n

-- ---- builtin schemes --------------------------------------------------------

sv :: Int -> Type
sv = TV

scheme :: [Int] -> Type -> Scheme
scheme vs = Forall vs []

-- The FP-RISC HAL/runtime contract: low-level primitives the compiler
-- emits directly (arith/cmp/str) or calls as fpr_g_ externs (MMIO,
-- actors, Vec, Sys). These keep their bare names; the typed stdlib
-- (Arith/Str/VList structures in the prelude) is layered ON TOP and
-- resolves down to these. Message-passing prims are polymorphic —
-- messages carry any payload.
builtinEnv :: TEnv
builtinEnv =
  M.fromList
    [ -- string / conversion prims (compiler-emitted or fpr_g_)
      ("str", scheme [0] (TFn (sv 0) tStr)),
      -- SString: fixed 128B inline string (sstr.c fpr_g_ externs)
      ("sstrNew", mono (TFn tUnit tSString)),
      ("sstrLen", mono (TFn tSString (TTupT [tInt, tSString]))),
      ("sstrAt", mono (TFn tSString (TFn tInt (TTupT [tInt, tSString])))),
      ("sstrPut", mono (TFn tSString (TFn tInt (TFn tInt tSString)))),
      ("sstrPush", mono (TFn tSString (TFn tInt tSString))),
      ("sstrFromStr", mono (TFn tStr tSString)),
      ("sstrToStr", mono (TFn tSString (TTupT [tStr, tSString]))),
      ("sstrClear", mono (TFn tSString tSString)),
      ("strcat", mono (TFn tStr (TFn tStr tStr))),
      ("strlen", mono (TFn tStr tInt)),
      ("String.len", mono (TFn tStr tInt)),
      ("charAt", mono (TFn tStr (TFn tInt tInt))), -- returns the char CODE
      ("chr", mono (TFn tInt tStr)),
      ("parseInt", mono (TFn tStr tInt)),
      ("fileRead", mono (TFn tStr tStr)),
      ("print", scheme [0] (TFn (sv 0) tUnit)),
      ("error", scheme [0] (TFn tStr (sv 0))),
      -- raw MMIO (registers are Ints): read/write a device word
      ("read", mono (TFn tInt tInt)),
      ("write", mono (TFn tInt (TFn tInt tUnit))),
      -- SMP actors: messages are polymorphic; an actor id is an Int.
      -- send : Actor -> msg -> Unit ; receive : Actor -> msg
      ("send", scheme [0] (TFn tInt (TFn (sv 0) (tcon "Result" [tUnit, tStr])))),
      ("sendLinear", scheme [0] (TFn tInt (TFn (sv 0) (tcon "Result" [tUnit, tStr])))),
      ("sendArc", scheme [0] (TFn tInt (TFn (sv 0) (tcon "Result" [tUnit, tStr])))),
      ("receive", scheme [0] (TFn tInt (sv 0))),
      ("receiveRes", scheme [0, 1] (TFn tInt (tcon "Result" [sv 0, sv 1]))),
      ("spawn", scheme [0] (TFn (TFn tInt (sv 0)) tInt)),
      ("spawnCap", scheme [0] (TFn tInt (TFn tInt (TFn (TFn tInt (sv 0)) tInt)))),
      ("spawnCapOn", scheme [0] (TFn tInt (TFn tInt (TFn tInt (TFn (TFn tInt (sv 0)) tInt))))),
      ("spawnOn", scheme [0] (TFn tInt (TFn (TFn tInt (sv 0)) tInt))),
      ("myself", mono (TFn tInt tInt)),
      ("yield", scheme [0] (TFn tInt (sv 0))),
      -- the `!` list/vector index — loosely typed pending an Index sig
      ("!", scheme [0, 1] (TFn (sv 0) (TFn tInt (sv 1)))),
      -- linear SoA Vector (vec.c) — carrier is the opaque Vector type
      ("Vec.new", scheme [0] (TFn tUnit (tVector))),
      -- DECLARED column layout ("d" F64, "s" F32, "i" Int, "b" boxed;
      -- 2..8 chars = SoA).  Floats cannot be classified by first push:
      -- their bits are indistinguishable from a pointer.
      ("Vec.newAs", mono (TFn tStr tVector)),
      -- bulk construction at native speed: one Int column filled by the
      -- HAL loop; `Vec.range 1 n |> Vec.map f` is the fast spelling of
      -- "generate n samples" (the per-element push loop it replaces is
      -- the dominant cost of ML-scale pipelines)
      ("Vec.range", mono (TFn tInt (TFn tInt tVector))),
      ("Vec.push", scheme [0] (TFn (sv 0) (TFn tVector tVector))),
      ("Vec.len", mono (TFn tVector (TTupT [tInt, tVector]))),
      ("Vec.get", scheme [0] (TFn tInt (TFn tVector (TTupT [sv 0, tVector])))),
      ("Vec.set", scheme [0] (TFn tInt (TFn (sv 0) (TFn tVector tVector)))),
      ("Vec.at", scheme [0] (TFn tInt (TFn tVector (TTupT [sv 0, tVector])))),
      ("Vec.put", scheme [0] (TFn tInt (TFn (sv 0) (TFn tVector tVector)))),
      ("Vec.map", scheme [0, 1] (TFn (TFn (sv 0) (sv 1)) (TFn tVector tVector))),
      ("Vec.filter", scheme [0] (TFn (TFn (sv 0) tBool) (TFn tVector tVector))),
      ("Vec.fold", scheme [0, 1] (TFn (TFn (sv 1) (TFn (sv 0) (sv 1))) (TFn (sv 1) (TFn tVector (TTupT [sv 1, tVector]))))),
      ("Vec.fromList", scheme [0] (TFn (tList (sv 0)) tVector)),
      ("Vec.toList", scheme [0] (TFn tVector (tList (sv 0)))),
      ("Vec.free", mono (TFn tVector tUnit)),
      ("Vec.split", mono (TFn tInt (TFn tVector (TTupT [tVector, tVector])))),
      -- the numeric SIMD tier (vec.c): element-wise ops over the raw
      -- unboxed Int column; unary ops are in place, zips consume src
      ("Vec.iota", mono (TFn tInt tVector)),
      ("Vec.dup", mono (TFn tVector (TTupT [tVector, tVector]))),
      ("Vec.axpb", mono (TFn tInt (TFn tInt (TFn tVector tVector)))),
      ("Vec.sar", mono (TFn tInt (TFn tVector tVector))),
      ("Vec.minS", mono (TFn tInt (TFn tVector tVector))),
      ("Vec.maxS", mono (TFn tInt (TFn tVector tVector))),
      ("Vec.ges", mono (TFn tInt (TFn tVector tVector))),
      ("Vec.zipAdd", mono (TFn tVector (TFn tVector tVector))),
      ("Vec.dot", mono (TFn tVector (TFn tVector tInt))),
      ("Vec.scale", mono (TFn tInt (TFn tVector tVector))),
      ("Vec.zipMul", mono (TFn tVector (TFn tVector tVector))),
      ("Vec.zipMin", mono (TFn tVector (TFn tVector tVector))),
      ("Vec.zipLt", mono (TFn tVector (TFn tVector tVector))),
      ("Vec.zipDiv", mono (TFn tVector (TFn tVector tVector))),
      ("Vec.gather", mono (TFn tVector (TFn tVector (TTupT [tVector, tVector])))),
      ("Vec.blend", mono (TFn tVector (TFn tVector (TFn tVector tVector)))),
      ("Vec.slice", mono (TFn tInt (TFn tInt (TFn tVector (TTupT [tVector, tVector]))))),
      ("Vec.burst", mono (TFn tInt (TFn tVector (TFn tVector tVector)))),
      ("Vec.zipSub", mono (TFn tVector (TFn tVector tVector))),
      ("Vec.zipEq", mono (TFn tVector (TFn tVector tVector))),
      ("Vec.zipMax", mono (TFn tVector (TFn tVector tVector))),
      ("Vec.absv", mono (TFn tVector tVector)),
      ("Vec.eqS", mono (TFn tInt (TFn tVector tVector))),
      -- floats (raw-bits payloads; see runtime.c's float essay)
      ("f64frombits", mono (TFn tInt (TFn tInt tF64))),
      ("f32frombits", mono (TFn tInt tF32)),
      ("myPid", mono (TFn tInt tInt)),
      ("F64.sqrt", mono (TFn tF64 tF64)),
      ("F64.log", mono (TFn tF64 tF64)),
      ("F64.log2", mono (TFn tF64 tF64)),
      ("F64.exp", mono (TFn tF64 tF64)),
      ("F64.sin", mono (TFn tF64 tF64)),
      ("F64.cos", mono (TFn tF64 tF64)),
      ("F64.pow", mono (TFn tF64 (TFn tF64 tF64))),
      ("F64.ofInt", mono (TFn tInt tF64)),
      ("F64.toInt", mono (TFn tF64 tInt)),
      ("F64.ofF32", mono (TFn tF32 tF64)),
      ("F64.str", mono (TFn tF64 tStr)),
      ("F32.sqrt", mono (TFn tF32 tF32)),
      ("F32.log", mono (TFn tF32 tF32)),
      ("F32.log2", mono (TFn tF32 tF32)),
      ("F32.exp", mono (TFn tF32 tF32)),
      ("F32.sin", mono (TFn tF32 tF32)),
      ("F32.cos", mono (TFn tF32 tF32)),
      ("F32.pow", mono (TFn tF32 (TFn tF32 tF32))),
      ("F32.ofInt", mono (TFn tInt tF32)),
      ("F32.toInt", mono (TFn tF32 tInt)),
      ("F32.ofF64", mono (TFn tF64 tF32)),
      ("F32.str", mono (TFn tF32 tStr)),
      -- process / system seam (fpr_g_ HAL)
      ("Sys.init", mono (TFn tUnit tUnit)),
      ("Sys.loadImageAt", scheme [0] (TFn tStr (TFn tInt (TFn tInt (TFn tInt (TFn tInt (TFn (sv 0) (TTupT [tInt, tStr])))))))),
      ("Sys.arenaFree", mono (TFn tUnit tInt)),
      ("Sys.sleepUs", mono (TFn tInt tUnit)),
      ("Sys.arena", scheme [0] (TFn (TFn tUnit (sv 0)) (sv 0))),
      ("heapUsed", mono (TFn tUnit tInt)),
      -- bit ops: band/bor/bxor are Int->Int->Int; BITTEST returns Bool
      ("band", mono (TFn tInt (TFn tInt tInt))),
      ("bor", mono (TFn tInt (TFn tInt tInt))),
      ("bxor", mono (TFn tInt (TFn tInt tInt))),
      ("BITSET", mono (TFn tInt (TFn tInt tInt))),
      ("BITCLEAR", mono (TFn tInt (TFn tInt tInt))),
      ("BITTEST", mono (TFn tInt (TFn tInt tBool))),
      ("BITMASK", mono (TFn tInt (TFn tInt tInt))),
      ("BITSHIFTL", mono (TFn tInt (TFn tInt tInt))),
      ("BITSHIFTR", mono (TFn tInt (TFn tInt tInt))),
      ("bitlen", scheme [0] (TFn (sv 0) tInt)),
      -- Bits value: length+endian-tagged word (net/blk framing)
      ("bitsLE", scheme [0] (TFn tInt (TFn tInt (sv 0)))),
      ("bitsBE", scheme [0] (TFn tInt (TFn tInt (sv 0)))),
      ("toInt", scheme [0] (TFn (sv 0) tInt)),
      -- device / register access: device : String -> Device (opaque)
      ("device", scheme [0] (TFn tStr (sv 0))),
      ("reg8", scheme [0, 1] (TFn (sv 0) (TFn tInt (sv 1)))),
      ("reg32", scheme [0, 1] (TFn (sv 0) (TFn tInt (sv 1)))),
      -- ARC / process introspection + control
      ("arcLive", scheme [0] (TFn (sv 0) tInt)),
      ("drop", scheme [0] (TFn (sv 0) tUnit)),
      ("keep", scheme [0] (TFn (sv 0) (sv 0))),
      ("kill", mono (TFn tInt tUnit)),
      ("hartId", mono (TFn tInt tInt)),
      -- device interrupts -> actor messages (actors.c irq bridge):
      -- bind a PLIC source to an actor (deliveries arrive as plain
      -- Int messages); ack re-arms the claimed-and-masked source
      ("Sys.irqBind", mono (TFn tInt (TFn tInt tUnit))),
      ("Sys.irqAck", mono (TFn tInt tUnit)),
      -- the CLINT timer bridge (actors.c tmr_drain): bind Timer.qa's
      -- actor (answers 1 = hardware timer present, 0 = host fallback);
      -- arm the ONE deadline, a DELTA in CLINT ticks -- once due, a
      -- bare Int lands in the bound actor's mailbox
      ("Sys.timerBind", mono (TFn tInt tInt)),
      ("Sys.timerArm", mono (TFn tInt tUnit)),
      ("schedTau", mono (TFn tInt tInt)),
      ("schedSetTau", mono (TFn tInt tUnit)),
      ("schedMaxWait", mono (TFn tInt tInt)),
      ("schedSteals", mono (TFn tInt tInt)),
      ("harts", mono (TFn tInt tInt)),
      ("fuelPreempts", mono (TFn tInt tInt)),
      ("fuelQuantum", mono (TFn tInt tInt)),
      ("receiveFrom", scheme [0] (TFn tInt (TFn tInt (sv 0)))),
      ("substr", mono (TFn tStr (TFn tInt (TFn tInt tStr)))),
      -- block device + net (bytes/words; loosely typed payloads)
      ("blkPages", scheme [0] (TFn (sv 0) tInt)),
      ("blkRead", scheme [0, 1] (TFn (sv 0) (TFn tInt (sv 1)))),
      ("blkWrite", scheme [0, 1] (TFn (sv 0) (TFn tInt (TFn (sv 1) tUnit)))),
      ("netPoll", scheme [0] (TFn tInt (sv 0))),
      ("netRead", scheme [0] (TFn tInt (sv 0))),
      ("netWrite", scheme [0] (TFn tInt (TFn (sv 0) tUnit))),
      ("netClose", mono (TFn tInt tUnit)),
      -- GPU tier (runtime/posix/gfx.c: scene-driven render function)
      ("glInit", mono (TFn tInt (TFn tInt tInt))),
      ("glRender", scheme [0, 1] (TFn (sv 0) (sv 1))),
      ("glRenderUi", scheme [0, 1, 2] (TFn (sv 0) (TFn (sv 1) (TFn tInt (sv 2))))),
      ("timeNow", scheme [0] (TFn (sv 0) tInt)),
      ("glSavePpm", mono (TFn tStr tInt)),
      ("inputPoll", scheme [0, 1] (TFn (sv 0) (sv 1))),
      ("sndPlay", scheme [0] (TFn (sv 0) tInt)),
      ("glMesh", mono (TFn tStr (TFn tStr tInt))),
      ("sndMusic", mono (TFn tStr (TFn tInt tInt))),
      -- Pin / GPIO service (fpr_g_ Pin.*)
      ("Pin.read", scheme [0] (TFn (sv 0) tInt)),
      ("Pin.write", scheme [0] (TFn (sv 0) (TFn tInt tUnit))),
      ("Pin.mode", scheme [0] (TFn (sv 0) (TFn tInt tUnit))),
      ("Pin.wire", scheme [0, 1] (TFn (sv 0) (TFn (sv 1) tUnit))),
      ("Pin.feed", scheme [0] (TFn (sv 0) (TFn tInt (TFn tInt tUnit)))),
      ("Pin.tget", scheme [0] (TFn (sv 0) tInt)),
      ("Pin.tlen", scheme [0] (TFn (sv 0) tInt)),
      ("Pin.tclear", scheme [0] (TFn (sv 0) tUnit)),
      -- Mod runtime resolution (remote calling)
      ("Mod.resolve", scheme [0] (TFn tStr (TFn tStr (sv 0)))),
      ("Mod.fn", scheme [0] (TFn tStr (TFn tStr (sv 0)))),
      ("Mod.find", scheme [0] (TFn tStr (sv 0))),
      ("Mod.plugs", scheme [0] (TFn tInt tInt)),
      ("Mod.findAt", scheme [0] (TFn tInt (TFn tStr (sv 0)))),
      ("Sys.attachQa", scheme [0] (TFn tStr (sv 0))),
      ("Sys.actLive", scheme [0] (TFn tInt tInt)),
      ("Sys.actInfo", scheme [0] (TFn tInt (sv 0))),
      ("Sys.logAt", scheme [0] (TFn tInt (TFn tStr tUnit))),
      ("Sys.logSeq", scheme [0] (TFn tInt tInt)),
      ("Sys.logSnap", scheme [0] (TFn tInt (sv 0))),
      ("Sys.memStats", scheme [0] (TFn tInt (sv 0))),
      ("Sys.memInfo", mono (TFn tInt (tList tInt))),
      ("Sys.spawnApp", scheme [0] (TFn (TFn tInt (sv 0)) tInt)),
      ("Sys.stkStats", scheme [0] (TFn tInt (sv 0))),
      ("Sys.growLog", scheme [0] (TFn tInt (sv 0))),
      ("Sys.poolReset", scheme [0] (TFn tInt (sv 0))),
      ("log", scheme [0] (TFn tStr tUnit)),
      ("logWarn", scheme [0] (TFn tStr tUnit)),
      ("logErr", scheme [0] (TFn tStr tUnit)),
      ("Mod.has", mono (TFn tStr tBool)),
      -- live-reload gate: every old export present in new, same arity
      ("Mod.compatAt", scheme [0] (TFn tInt (TFn tInt (sv 0)))),
      ("Mod.detachLast", mono (TFn tUnit tUnit)),
      -- Apps registry + Sys binding seam
      ("Apps.list", scheme [0] (TFn tUnit (sv 0))),
      ("Apps.read", scheme [0] (TFn tStr (sv 0))),
      ("Sys.caps", scheme [0] (TFn tUnit (sv 0))),
      ("Sys.harts", mono (TFn tUnit tInt)),
      ("Sys.bindApp", scheme [0, 1] (TFn (sv 0) (sv 1))),
      ("Sys.bindStore", scheme [0, 1] (TFn (sv 0) (sv 1))),
      ("Sys.storeReq", scheme [0, 1] (TFn (sv 0) (sv 1))),
      -- host compiler server (qosp tag-7 channel): profile -> source -> Result
      ("Sys.compile", mono (TFn tStr (TFn tStr (tcon "Result" [tStr, tStr]))))
    ]

builtinCons' :: TEnv
builtinCons' =
  M.fromList
    [ ("Unit", mono tUnit),
      ("True", mono tBool),
      ("False", mono tBool),
      ("Nil", scheme [0] (tList (sv 0))),
      ("Cons", scheme [0] (TFn (sv 0) (TFn (tList (sv 0)) (tList (sv 0))))),
      ("Ok", scheme [0, 1] (TFn (sv 0) (tcon "Result" [sv 0, sv 1]))),
      ("Err", scheme [0, 1] (TFn (sv 1) (tcon "Result" [sv 0, sv 1]))),
      ("Tup2", scheme [0, 1] (TFn (sv 0) (TFn (sv 1) (TTupT [sv 0, sv 1])))),
      ("Tup3", scheme [0, 1, 2] (TFn (sv 0) (TFn (sv 1) (TFn (sv 2) (TTupT [sv 0, sv 1, sv 2]))))),
      ("Tup4", scheme [0, 1, 2, 3] (TFn (sv 0) (TFn (sv 1) (TFn (sv 2) (TFn (sv 3) (TTupT [sv 0, sv 1, sv 2, sv 3])))))),
      ("Tup5", scheme [0, 1, 2, 3, 4] (TFn (sv 0) (TFn (sv 1) (TFn (sv 2) (TFn (sv 3) (TFn (sv 4) (TTupT [sv 0, sv 1, sv 2, sv 3, sv 4]))))))),
      ("Tup6", scheme [0, 1, 2, 3, 4, 5] (TFn (sv 0) (TFn (sv 1) (TFn (sv 2) (TFn (sv 3) (TFn (sv 4) (TFn (sv 5) (TTupT [sv 0, sv 1, sv 2, sv 3, sv 4, sv 5])))))))),
      ("Tup7", scheme [0, 1, 2, 3, 4, 5, 6] (TFn (sv 0) (TFn (sv 1) (TFn (sv 2) (TFn (sv 3) (TFn (sv 4) (TFn (sv 5) (TFn (sv 6) (TTupT [sv 0, sv 1, sv 2, sv 3, sv 4, sv 5, sv 6]))))))))),
      ("Tup8", scheme [0, 1, 2, 3, 4, 5, 6, 7] (TFn (sv 0) (TFn (sv 1) (TFn (sv 2) (TFn (sv 3) (TFn (sv 4) (TFn (sv 5) (TFn (sv 6) (TFn (sv 7) (TTupT [sv 0, sv 1, sv 2, sv 3, sv 4, sv 5, sv 6, sv 7]))))))))))
    ]

-- user `N a b = Type (C τ.. | D τ..).` — constructor schemes; free surface
-- vars in con args that aren't declared params quantify per-constructor
-- (the prelude's `Cmd = Type (Print x | ...)` style)
consEnv :: ShapeAliases -> [STop] -> I TEnv
consEnv aliases tops = M.fromList . concat <$> mapM one [t | t@TType {} <- tops]
  where
    one (TType n _ params cs) = forM cs $ \(c, argTys) -> do
      let hasHole ty = case ty of
            TCon "??" [] -> True
            TCon _ as -> any hasHole as
            TVApp _ as -> any hasHole as
            TArrT a b -> hasHole a || hasHole b
            TTup ts -> any hasHole ts
            _ -> False
      when (any hasHole argTys) $
        modify (\st -> st {iHoledCons = S.insert (c, length argTys) (iHoledCons st)})
      let ptbl0 = M.fromList (zip params (map TV [-1, -2 ..])) -- placeholder
      -- allocate real vars for params, shared across this con's args
      pvars <- mapM (const freshT) params
      let ptbl = M.fromList (zip params pvars)
      (args, tbl') <- foldM step ([], ptbl) argTys
      let res = foldl' TAp (TC n) pvars
          ty = foldr TFn res (reverse args)
          (tvs, rvs) = ftv ty
      _ <- pure ptbl0
      pure (c, Forall (S.toList tvs) (S.toList rvs) ty)
    one _ = pure []
    step (acc, tbl) ty = do
      (t, tbl') <- tyToTypeA aliases tbl ty
      pure (t : acc, tbl')

-- `n : τ1 -> .. -> τr.` prelude/user annotations become declared schemes
sigAnnEnv :: ShapeAliases -> [STop] -> I TEnv
sigAnnEnv aliases tops = M.fromList <$> mapM one [(n, ps, r) | TSig n (ps, r) _ <- tops]
  where
    one (n, ps, r) = do
      (t, tbl) <- tyToTypeA aliases M.empty (foldr TArrT r ps)
      let (tvs, rvs) = ftv t
          holes = maybe S.empty (fst . ftv) (M.lookup "$holes" tbl)
      pure (n, Forall (S.toList (tvs S.\\ holes)) (S.toList rvs) t)

-- ---- pattern inference ------------------------------------------------------

inferPat :: TEnv -> SPat -> I (Type, TEnv)
inferPat cons = \case
  PWild -> (,M.empty) <$> freshT
  PInt _ -> pure (tInt, M.empty)
  PStr _ -> pure (tStr, M.empty)
  PVar n -> do a <- freshT; pure (a, M.singleton n (mono a))
  PSig n sg -> do
    -- reaches here only if a PSig survives outside a top-level param
    a <- freshT
    _ <- pure sg
    pure (a, M.singleton n (mono a))
  PTup ps -> do
    (ts, envs) <- unzip <$> mapM (inferPat cons) ps
    pure (TTupT ts, M.unions envs)
  PRec ns -> do
    fields <- mapM (\n -> (,) n <$> freshT) ns
    tail' <- freshR
    let row = foldr (\(n, t) r -> RExt n t r) tail' fields
    pure (TRec row, M.fromList [(n, mono t) | (n, t) <- fields])
  PCon c ps -> do
    (ts, envs) <- unzip <$> mapM (inferPat cons) ps
    res <- freshT
    case M.lookup c cons of
      Nothing -> report ("pattern: unknown constructor " ++ c) >> pure (res, M.unions envs)
      Just sc -> do
        ct <- instantiate sc
        unify ("pattern " ++ c) ct (foldr TFn res ts)
        pure (res, M.unions envs)

-- ---- expression inference ---------------------------------------------------

-- ---- profile parameterization ----------------------------------------------
-- ONE inference engine, per-profile surfaces (the un-forking of
-- Sol/Infer.hs): everything that genuinely differs between the AOT
-- tiers and HostedBytecode rides here.  The float story needs no flag
-- -- float literals splice to f64frombits/f32frombits calls, and the
-- PROFILE'S TABLE types those (F64/F32 for AOT, Int-is-Numeric for
-- sol), so the width sites resolve to plain ops under sol's table and
-- the rewritten AST comes out exactly as sol's old engine produced.
data IProf = IProf
  { ipBuiltins :: TEnv, -- the profile's primitive surface
    ipTopEvals :: Bool, -- infer + rewrite `> expr.` tops (HostedBytecode;
                        -- the AOT driver handles TEval itself)
    ipPathStr :: Bool, -- @Path literals type as String (HostedBytecode;
                       -- AOT expands them structurally before inference)
    ipMat4 :: Bool -- Mat4/Vec4 `*` elaboration -- only where the prelude
                   -- defines mulMM/mulMV (the AOT tiers)
  }

aotProf :: IProf
aotProf = IProf builtinEnv False False True

data ICtx = ICtx
  { icEnv :: TEnv, -- values in scope
    icCons :: TEnv, -- constructor schemes (for patterns)
    icSigs :: Sigs,
    icProf :: IProf
  }

extend :: TEnv -> ICtx -> ICtx
extend e c = c {icEnv = M.union e (icEnv c)}

-- ---- operator resolution sites ----------------------------------------------
--
-- Arith operators (+ - * /) are ROW-DISPATCHED: inference gives each site
-- a type; after solving, each site rewrites by its operand type —
--   Int         -> the primitive opcode (SBin stays)
--   String      -> Str.+            List a -> List.+
--   sig carrier -> s.(+)            (the specializer then monomorphizes)
--   unconstrained -> DEFAULTS to Int (Julia-style numeric default)
-- Inference marks each site (SBin "op#N#+") and resolveSites rewrites.

markerPrefix :: String
markerPrefix = "op#"

newSite :: Name -> Type -> I Int
newSite op t = do
  st <- get
  let n = iNextSite st
  put st {iNextSite = n + 1, iSites = IM.insert n (op, t) (iSites st)}
  pure n

-- carrier var of an in-scope `(s : Sig)` param: var id -> (param, sig)
addCarrier :: Int -> (Name, Name) -> I ()
addCarrier v sn = modify (\st -> st {iCarriers = IM.insert v sn (iCarriers st)})

-- unification may have rebound a carrier var to another var (which then
-- became the representative) — the check must be against zonked reps
carrierReps :: I (IM.IntMap (Name, Name))
carrierReps = do
  cs <- gets iCarriers
  fmap IM.fromList . forM (IM.toList cs) $ \(v, pn) ->
    zonk (TV v) >>= \case
      TV r -> pure (r, pn)
      _ -> pure (v, pn)

-- the Mat4/Vec4 shapes, by their (structural) field sets: records are
-- rows here, so the operator convention is field-name-directed
vec4Fields, mat4Fields :: [Name]
vec4Fields = ["w", "x", "y", "z"]
mat4Fields = ["m" ++ show r ++ show c | r <- [0 :: Int .. 3], c <- [0 :: Int .. 3]]

sortNames :: [Name] -> [Name]
sortNames = Data.List.sort

isInt :: Type -> Bool
isInt (TC "Int") = True
isInt _ = False

recFields :: Type -> Maybe [Name]
recFields (TRec r) = go r
  where
    go RNil = Just []
    go (RExt n _ rest) = (n :) <$> go rest
    go (RV _) = Nothing
recFields _ = Nothing

inferE :: ICtx -> SExpr -> I (Type, SExpr)
inferE ctx e0 = case e0 of
  -- position wrapper: remember the statement we are inside (errors
  -- reported below it carry its offset), infer through, keep the mark
  SMark o e -> do
    old <- gets iHere
    modify (\s -> s {iHere = Just o})
    (t, e') <- inferE ctx e
    modify (\s -> s {iHere = old})
    pure (t, SMark o e')
  -- @paths (parsed by the shared grammar as (Path "…")) are URL strings
  -- in the HostedBytecode profile; the AOT tiers expand them
  -- structurally before inference (expandPathLits) and never reach here
  SApp (SVar "Path") (SStrI [SegStr _]) | ipPathStr (icProf ctx) -> pure (tStr, e0)
  -- ?name / ?? — typed holes (parsed as this shape).  A fresh var lets
  -- everything AROUND the hole typecheck.  Named holes are recorded and
  -- REFUSE compilation later (with the zonked type); ?? elaborates to a
  -- runtime trap so the pipeline before it still runs.
  SApp (SVar "?hole") (SStrI [SegStr hn]) -> do
    a <- freshT
    modify (\st -> st {iHoles = iHoles st ++ [(hn, a)]})
    if null hn
      then do
        k <- gets (length . iHoles)
        pure (a, SApp (SVar "?trap!") (SInt (fromIntegral k - 1)))
      else pure (a, e0)
  SInt n -> pure (tInt, SInt n)
  SAtom a -> pure (tAtom, SAtom a)
  SStrI segs -> do
    segs' <- forM segs $ \case
      SegExpr e -> do
        -- interpolation str's anything -- so each segment is a str!
        -- site: floats rewrite to their render prims, structures
        -- containing floats are refused, everything else passes
        -- through untouched (the marker strips to the bare segment).
        (te, e') <- inferE ctx e
        site <- newSite "str!" te
        pure (SegExpr (SApp (SVar (markerPrefix ++ show site ++ "#str!")) e'))
      o -> pure o
    pure (tStr, SStrI segs')
  SApp (SVar h) arg | h `elem` ["str", "print"] -> do
    -- same guard as interpolation: str/print of a bare float routes
    -- through F64.str/F32.str (str of the resulting String is the
    -- identity; print of it prints the bytes), a float-containing
    -- structure is refused, anything else is untouched.
    (tf, _) <- inferE ctx (SVar h)
    (ta, a') <- inferE ctx arg
    r <- freshT
    unify h tf (TFn ta r)
    site <- newSite "str!" ta
    pure (r, SApp (SVar h) (SApp (SVar (markerPrefix ++ show site ++ "#str!")) a'))
  SVar n -> do
    (t, e') <-
      case M.lookup n (icEnv ctx) of
        Just sc -> (,SVar n) <$> instantiate sc
        Nothing -> case M.lookup n (icCons ctx) of
          Just sc -> (,SVar n) <$> instantiate sc
          Nothing -> do
            report ("unbound name: " ++ n)
            (,SVar n) <$> freshT
    -- constructor with a ?? field: the VALUE types normally; CALLING it
    -- traps at runtime (eta-wrapped, so earlier args still evaluate)
    hc <- gets iHoledCons
    case [ar | (c, ar) <- S.toList hc, c == n] of
      (ar : _) ->
        pure (t, foldr (\i b -> SLam ["?c" ++ show (i :: Int)] b) (SApp (SVar "error") (SStrI [SegStr ("typed hole ?? in constructor " ++ n ++ " (unimplemented)")])) [1 .. ar])
      [] -> pure (t, e')
  SApp f x -> do
    (tf, f') <- inferE ctx f
    (tx, x') <- inferE ctx x
    r <- freshT
    unify (describe f) tf (TFn tx r)
    pure (r, SApp f' x')
  SLam ps b -> do
    pvs <- mapM (const freshT) ps
    let env' = M.fromList (zip ps (map mono pvs))
    (tb, b') <- inferE (extend env' ctx) b
    pure (foldr TFn tb pvs, SLam ps b')
  SBlock stmts fin -> do
    (stmts', fin', t) <- goBlock ctx stmts
    pure (t, SBlock stmts' fin')
    where
      goBlock c [] = do (t, fin') <- inferE c fin; pure ([], fin', t)
      goBlock c (SBind n ps rhs : rest) = do
        a <- freshT
        let cRec = extend (M.singleton n (mono a)) c
        pvs <- mapM (const freshT) ps
        let env' = M.fromList (zip ps (map mono pvs))
        (tb, rhs') <- inferE (extend env' cRec) rhs
        let t = foldr TFn tb pvs
        unify ("local " ++ n) a t
        sc <-
          if null ps && not (isLamE rhs)
            then pure (mono t)
            else generalize (icEnv c) t
        (rest', fin', tr) <- goBlock (extend (M.singleton n sc) c) rest
        pure (SBind n ps rhs' : rest', fin', tr)
      goBlock c (SBindPat p rhs : rest) = do
        (tr, rhs') <- inferE c rhs
        (tp, benv) <- inferPat (icCons c) p
        unify "let pattern" tp tr
        (rest', fin', tfin) <- goBlock (extend benv c) rest
        pure (SBindPat p rhs' : rest', fin', tfin)
      isLamE SLam {} = True
      isLamE _ = False
  SCase scrut arms -> do
    (ts, scrut') <- inferE ctx scrut
    res <- freshT
    arms' <- forM arms $ \(p, e) -> do
      (tp, benv) <- inferPat (icCons ctx) p
      unify "case scrutinee" tp ts
      (te, e') <- inferE (extend benv ctx) e
      unify "case arm" te res
      pure (p, e')
    pure (res, SCase scrut' arms')
  SBin op a b -> inferBin ctx op a b
  SProj e path -> do
    (te, e') <- inferE ctx e
    t <- foldM projOne te path
    pure (t, SProj e' path)
    where
      projOne t f = do
        a <- freshT
        rest <- freshR
        unify ("projection ." ++ f) t (TRec (RExt f a rest))
        pure a
  SRec fs -> do
    tfs <- forM fs $ \(n, e) -> do (t, e') <- inferE ctx e; pure (n, t, e')
    pure
      ( TRec (foldr (\(n, t, _) r -> RExt n t r) RNil tfs),
        SRec [(n, e') | (n, _, e') <- tfs]
      )
  SUpd m as -> do
    (tm, m') <- inferE ctx m
    as' <- forM as $ \(path, e) -> do
      (te, e') <- inferE ctx e
      constrainPath tm path te
      pure (path, e')
    pure (tm, SUpd m' as')
    where
      constrainPath t [] te = unify "record update" t te
      constrainPath t (f : rest) te = do
        a <- freshT
        tl <- freshR
        unify ("update ." ++ f) t (TRec (RExt f a tl))
        constrainPath a rest te
  STup es -> do
    tes <- mapM (inferE ctx) es
    pure (TTupT (map fst tes), STup (map snd tes))
  SList es -> do
    a <- freshT
    es' <- forM es $ \e -> do
      (t, e') <- inferE ctx e
      unify "list element" a t
      pure e'
    pure (tList a, SList es')

describe :: SExpr -> String
describe = \case
  SVar n -> "application of " ++ n
  SApp f _ -> describe f
  _ -> "application"

inferBin :: ICtx -> Name -> SExpr -> SExpr -> I (Type, SExpr)
inferBin ctx op a b = case op of
  "|>" -> do
    (ta, a') <- inferE ctx a
    (tb, b') <- inferE ctx b
    r <- freshT
    unify "(|>)" tb (TFn ta r)
    pure (r, SBin op a' b')
  ">>" -> do
    (_, a') <- inferE ctx a
    (tb, b') <- inferE ctx b
    pure (tb, SBin op a' b')
  "::" -> do
    (ta, a') <- inferE ctx a
    (tb, b') <- inferE ctx b
    unify "(::)" tb (tList ta)
    pure (tb, SBin op a' b')
  "|>?" -> do
    (ta, a') <- inferE ctx a
    (tb, b') <- inferE ctx b
    x <- freshT; y <- freshT; err <- freshT
    unify "(|>?) source" ta (tcon "Result" [x, err])
    unify "(|>?) fn" tb (TFn x (tcon "Result" [y, err]))
    pure (tcon "Result" [y, err], SBin op a' b')
  _ | op `elem` ["and", "or"] -> do
        (ta, a') <- inferE ctx a
        (tb, b') <- inferE ctx b
        unify ("(" ++ op ++ ") left") ta tBool
        unify ("(" ++ op ++ ") right") tb tBool
        pure (tBool, SBin op a' b')
  _ | op `elem` ["+", "-", "*", "/", "%", "^"] -> do
        (ta, a') <- inferE ctx a
        (tb, b') <- inferE ctx b
        -- MATRIX * VECTOR: `*` on the Mat4/Vec4 shapes elaborates to
        -- the library multiply, so `mvp * vert` is real syntax and the
        -- Vec.map specializer sees an ordinary known call it can lower
        -- to fused multiply-add column loops (the axpb shape).
        za <- zonk ta
        zb <- zonk tb
        let m4 = ipMat4 (icProf ctx) -- only where the prelude has mulMM/mulMV
            isShape ns t = maybe False ((== ns) . sortNames) (recFields t)
            matL = m4 && isShape mat4Fields za
            matR = m4 && isShape mat4Fields zb
            vecR = m4 && isShape vec4Fields zb
        case op of
          "*" | matL && matR -> do
                (tr, _) <- inferE ctx (SApp (SApp (SVar "mulMM") a) b)
                pure (tr, SApp (SApp (SVar "mulMM") a') b')
              -- fire when EITHER side pins the shape: H-M order means a
              -- lambda param's type may still be open on one side
              | matL || (vecR && not (isInt za)) -> do
                (tr, _) <- inferE ctx (SApp (SApp (SVar "mulMV") a) b)
                pure (tr, SApp (SApp (SVar "mulMV") a') b')
          _ -> do
            t <- freshT
            -- MIXED OPERAND TYPES: when both sides are already concrete and
            -- at least one is a user type (Vector, Matrix, ...), the operator
            -- may be a two-typed global (`Matrix * Vector`, `Int * Vector`),
            -- so unification with the site type is deferred to resolution;
            -- every other site unifies eagerly exactly as before
            let builtinTy c = c `elem` ["Int", "F64", "F32", "String", "List", "Bool", "Unit"]
                userTy ty = maybe False (not . builtinTy) (headCon ty)
                concreteTy ty = headCon ty /= Nothing
            site <- newSite op t
            if concreteTy za && concreteTy zb && (userTy za || userTy zb)
              then modify (\st -> st {iPairs = IM.insert site (ta, tb) (iPairs st)})
              else do
                unify ("(" ++ op ++ ")") ta t
                unify ("(" ++ op ++ ")") tb t
            pure (t, SBin (markerPrefix ++ show site ++ "#" ++ op) a' b')
    | op `elem` ["<", "<=", ">", ">="] -> do
        (ta, a') <- inferE ctx a
        (tb, b') <- inferE ctx b
        -- ordered comparison is a SITE like arith: Int (the numeric
        -- default) or a float width, decided post-solve
        t <- freshT
        unify ("(" ++ op ++ ")") ta t
        unify ("(" ++ op ++ ")") tb t
        site <- newSite op t
        pure (tBool, SBin (markerPrefix ++ show site ++ "#" ++ op) a' b')
    | op `elem` ["==", "!="] -> do
        (ta, a') <- inferE ctx a
        (tb, b') <- inferE ctx b
        unify ("(" ++ op ++ ")") ta tb
        -- floats rewrite to IEEE compare prims (NaN /= NaN); everything
        -- else keeps the generic shallow veq, exactly as before
        site <- newSite op ta
        pure (tBool, SBin (markerPrefix ++ show site ++ "#" ++ op) a' b')
    | otherwise -> do
        -- user-defined operator: an ordinary binding applied infix
        (t, _) <- inferE ctx (SVar op)
        (ta, a') <- inferE ctx a
        (tb, b') <- inferE ctx b
        r <- freshT
        unify ("(" ++ op ++ ")") t (TFn ta (TFn tb r))
        pure (r, SBin op a' b')

-- ---- post-solve operator resolution -----------------------------------------

data OpTarget = OpPrim Name | OpGlobal Name | OpProj Name Name -- s.(+)

-- head type constructor: Matrix -> "Matrix", Grid a b -> "Grid"
headCon :: Type -> Maybe Name
headCon (TC n) = Just n
headCon (TAp f _) = headCon f
headCon _ = Nothing

-- the operator global implementing `op` for type `tyName`: any
-- `<Struct>.<op>` whose FIRST parameter is that type. Deterministic when
-- several match (sorted), so a program compiles the same way every run.
namedOpTarget :: TEnv -> Name -> Name -> Maybe Name
namedOpTarget env tyName op =
  case Data.List.sort [g | (g, Forall _ _ t) <- M.toList env, isOpNamed g, firstArgIs t] of
    (g : _) -> Just g
    [] -> Nothing
  where
    isOpNamed g = ("." ++ op) `Data.List.isSuffixOf` g
    firstArgIs (TFn a _) = headCon a == Just tyName
    firstArgIs _ = False

-- the two-typed form: `<Struct>.<op>` whose first AND second parameters
-- are the given types (Matrix * Vector, Int * Vector)
namedOpTarget2 :: TEnv -> Name -> Name -> Name -> Maybe (Name, Scheme)
namedOpTarget2 env tyA tyB op =
  case Data.List.sort [g | (g, Forall _ _ t) <- M.toList env, ("." ++ op) `Data.List.isSuffixOf` g, argsAre t] of
    (g : _) -> (,) g <$> M.lookup g env
    [] -> Nothing
  where
    argsAre (TFn a (TFn b _)) = headCon a == Just tyA && headCon b == Just tyB
    argsAre _ = False

-- decide every site once the substitution is final
resolveSites :: Sigs -> TEnv -> I (IM.IntMap OpTarget)
resolveSites sigs env = do
  sites <- gets iSites
  IM.traverseWithKey one sites
  where
    one k (op, t0) = do
      pairs <- gets iPairs
      case IM.lookup k pairs of
        Nothing -> one' op t0
        Just (ta0, tb0) -> do
          ta <- zonk ta0
          tb <- zonk tb0
          case (headCon ta, headCon tb) of
            (Just ca, Just cb)
              | Just (g, sc) <- namedOpTarget2 env ca cb op -> do
                  ft <- instantiate sc
                  unify ("(" ++ op ++ ") at " ++ g) ft (TFn ta (TFn tb t0))
                  pure (OpGlobal g)
            _ -> do
              -- no two-typed operator: the ordinary same-type site
              unify ("(" ++ op ++ ")") ta t0
              unify ("(" ++ op ++ ")") tb t0
              one' op t0
    one' op t0 = do
      t <- zonk t0
      if op `elem` ["==", "!="]
        then pure $ case t of
          -- IEEE compare prims (NaN /= NaN, -0.0 == 0.0); every other
          -- type keeps the generic shallow veq EXACTLY as before --
          -- including type variables: polymorphic == must not be
          -- defaulted to Int, and a poly == reached with raw float
          -- bits is the documented shallow-honesty hazard, not a
          -- resolver decision.
          TC "F64" -> OpPrim ("F64." ++ op)
          TC "F32" -> OpPrim ("F32." ++ op)
          _ -> OpPrim op
      else if op == "str!"
        then case t of
          -- the str/print/interpolation guard: bare floats render via
          -- their prims; a float INSIDE a structure would reach the
          -- tid-directed render as raw bits and be dereferenced as a
          -- header -- refused with the restriction named, instead of
          -- printed wrong.  OpPrim "" means "strip the marker".
          TC "F64" -> pure (OpPrim "F64.str")
          TC "F32" -> pure (OpPrim "F32.str")
          _ | mentionsFloat t -> do
                p <- prettyT t
                OpPrim "" <$ report ("str/print of " ++ p ++ ": render is tid-directed and floats are raw bits -- format float fields individually with F64.str/F32.str (v1)")
            | otherwise -> pure (OpPrim "")
      else case t of
        -- % and ^ have no opcode: they are the prelude's Int.mod / Int.pow
        -- (every backend sees an ordinary call; the JIT inlines it)
        TC "Int" | op == "%" -> pure (OpGlobal "Int.mod")
                 | op == "^" -> pure (OpGlobal "Int.pow")
                 | otherwise -> pure (OpPrim op)
        TC "F64" | op == "^" -> pure (OpPrim "F64.pow")
                 | op == "%" -> OpPrim op <$ report "(%) is not defined for F64 (Int/Numeric has it)"
                 | otherwise -> pure (OpPrim ("F64." ++ op))
        TC "F32" | op `elem` ["%", "^"] -> OpPrim op <$ report ("(" ++ op ++ ") is not defined for F32")
                 | otherwise -> pure (OpPrim ("F32." ++ op))
        TC "String"
          | op == "+" -> pure (OpGlobal "Str.+")
          | op == "-" -> pure (OpGlobal "Str.-") -- deconcatenation: suffix removal
          | otherwise -> OpPrim op <$ report ("(" ++ op ++ ") is not defined for String")
        TAp (TC "List") _
          | op == "+" -> pure (OpGlobal "List.+")
          | op == "-" -> pure (OpGlobal "List.-") -- deconcatenation: suffix removal
          | otherwise -> OpPrim op <$ report ("(" ++ op ++ ") is not defined for List")
        TV v -> do
          carriers <- carrierReps
          case IM.lookup v carriers of
            Just (pn, sg)
              | op `elem` maybe [] (map fst) (M.lookup sg sigs) -> pure (OpProj pn op)
              | otherwise ->
                  OpPrim op <$ report ("(" ++ op ++ ") used at carrier of sig " ++ sg ++ ", which lacks it")
            Nothing -> do
              -- unconstrained: default to Int (numeric default)
              unify "numeric default" (TV v) tInt
              pure (case op of "%" -> OpGlobal "Int.mod"; "^" -> OpGlobal "Int.pow"; _ -> OpPrim op)
        -- A CONCRETE TYPE CARRIES ITS OWN OPERATORS. `Str.+` and `List.+`
        -- above are the two the compiler happens to know by name; every
        -- other type says so in the operator's own signature, so no
        -- instance table and no new syntax is needed -- a global named
        -- `<Anything>.<op>` whose first parameter is this type IS the
        -- implementation, and the specializer sees an ordinary call.
        other
          | Just tn <- headCon other,
            Just g <- namedOpTarget env tn op ->
              pure (OpGlobal g)
        other -> do
          p <- prettyT other
          OpPrim op <$ report ("(" ++ op ++ ") is not defined for " ++ p)

-- rewrite the markers by the decided targets
applySites :: IM.IntMap OpTarget -> SExpr -> SExpr
applySites tgts = go
  where
    go = \case
      -- str! sites wrap an ARGUMENT: op#N#str! applied to e.  OpPrim ""
      -- strips the wrapper; OpPrim "F64.str" wraps the rendering prim.
      SApp (SVar op) a
        | Just rest <- stripPrefix markerPrefix op,
          (num, '#' : _) <- break (== '#') rest,
          Just tgt <- IM.lookup (read num) tgts ->
            case tgt of
              OpPrim "" -> go a
              OpPrim o -> SApp (SVar o) (go a)
              _ -> go a
      SBin op a b
        | Just rest <- stripPrefix markerPrefix op,
          (num, '#' : _rawOp) <- break (== '#') rest,
          Just tgt <- IM.lookup (read num) tgts ->
            case tgt of
              OpPrim o -> SBin o (go a) (go b)
              OpGlobal g -> SApp (SApp (SVar g) (go a)) (go b)
              OpProj s o -> SApp (SApp (SProj (SVar s) [o]) (go a)) (go b)
        | otherwise -> SBin op (go a) (go b)
      SMark o e -> SMark o (go e)
      SApp a b -> SApp (go a) (go b)
      SLam ps b -> SLam ps (go b)
      SBlock stmts fin -> SBlock (map goS stmts) (go fin)
      SCase s as -> SCase (go s) [(p, go e) | (p, e) <- as]
      SProj e p -> SProj (go e) p
      SRec fs -> SRec [(n, go e) | (n, e) <- fs]
      SUpd m as -> SUpd (go m) [(p, go e) | (p, e) <- as]
      STup es -> STup (map go es)
      SList es -> SList (map go es)
      SStrI segs -> SStrI [seg s | s <- segs]
      o -> o
    goS (SBind n ps e) = SBind n ps (go e)
    goS (SBindPat p e) = SBindPat p (go e)
    seg (SegExpr e) = SegExpr (go e)
    seg o = o

-- ---- top-level driver -------------------------------------------------------

-- infer all top-level bindings; returns errors (empty = well-typed)
typecheck :: Sigs -> Structs -> [STop] -> [String]
typecheck sigs structs tops = let (e, _, _, _, _) = inferTops sigs structs tops in e

-- Infer.Type -> LShape, mirroring FPRISC.shapeOfTy's rules on the
-- inference-side type language: a linear-named TC is LL, a type
-- applied to a linear argument (List Vector, ...) is LL wholesale,
-- tuples distribute, and everything unresolved/polymorphic/functional
-- is LU (a quantified var can never BE the linear carrier itself --
-- prims that consume one say so with a concrete Vector in their type).
linShapeT :: [Name] -> Type -> LShape
linShapeT linNs = go
  where
    go t = case t of
      TTupT ts -> LTupS (map go ts)
      TC n | n `elem` linNs -> LL
      TAp _ _ ->
        let (h, as) = unroll t []
         in case h of
              TC n | n `elem` linNs -> LL
              _ -> if any (isLin . go) as then LL else LU
      _ -> LU
    unroll (TAp f a) acc = unroll f (a : acc)
    unroll h acc = (h, acc)

-- the BUILTIN prims' linearity shapes, derived from builtinEnv itself
-- so this table can never drift from the types: Vec.push consumes and
-- returns a Vector because its type says so, and any prim added later
-- participates automatically.  Full-spine peel: prims are first-order
-- at the top level (higher-order ARGUMENTS like Vec.map's element fn
-- are TFn and shape LU, exactly right).
builtinLinShapes :: [Name] -> M.Map Name ([LShape], LShape)
builtinLinShapes linNs =
  -- sendLinear MOVES its payload: the polymorphic type would derive LU
  -- (a quantified var is never the carrier), but move semantics is the
  -- verb's whole meaning, so the consume is declared here explicitly --
  -- passing a linear value consumes it exactly like Vec.free does.
  M.insert "sendLinear" ([LU, LL], LU) $
  M.fromList
    [ (n, (map (linShapeT linNs) ps, linShapeT linNs r))
      | (n, Forall _ _ t) <- M.toList builtinEnv,
        let (ps, r) = peelFn t
    ]
  where
    peelFn (TFn a b) = let (as, r) = peelFn b in (a : as, r)
    peelFn t = ([], t)

inferTops :: Sigs -> Structs -> [STop] -> ([String], [(Name, String)], [(String, String)], [(Name, ([LShape], LShape))], [STop])
inferTops = inferTopsWith aotProf

inferTopsWith :: IProf -> Sigs -> Structs -> [STop] -> ([String], [(Name, String)], [(String, String)], [(Name, ([LShape], LShape))], [STop])
inferTopsWith prof sigs structs tops =
  let (tops', st) = runState run (IEnv 0 IM.empty IM.empty [] [] [] [] S.empty 0 IM.empty IM.empty Nothing IM.empty [])
   in (iErrs st, iNotes st, iHolesP st, iLinSigs st, tops')
  where
    aliases = M.fromList [(n, fs) | TShape n fs <- tops]
    run :: I [STop]
    run = do
      cons <- (\u -> M.union u builtinCons') <$> consEnv aliases tops
      declared <- sigAnnEnv aliases tops
      let env0 = M.union declared (ipBuiltins prof)
      -- group multi-clause binds under one name, preserving first-seen order
      let bindNames = nub [n | TBind n _ _ _ <- tops]
          clausesOf n = [(ps, g, b) | TBind n' ps g b <- tops, n' == n]
          -- `> expr.` top-level effects: inferred and rewritten in the
          -- HostedBytecode profile; the AOT driver owns them otherwise
          -- (empty list = rebuild leaves every TEval untouched)
          evals = if ipTopEvals prof then [e | TEval e <- tops] else []
          topSet = S.fromList bindNames
          nodes =
            [ (n, n, nub (concatMap refs (clausesOf n)))
              | n <- bindNames
            ]
          refs (ps, g, b) =
            let bound = S.fromList (concatMap patVars ps)
                gbound = S.union bound (S.fromList (concatMap gPatVars g))
                gPatVars (GPat p _) = patVars p
                gPatVars (GBool _) = []
                gExprs = [e | gd <- g, e <- case gd of GBool e' -> [e']; GPat _ e' -> [e']]
             in topRefs2 topSet gbound b ++ concatMap (topRefs2 topSet bound) gExprs
          sccs = stronglyConnComp nodes
      (env, rwBinds) <-
        foldM
          (\(e, acc) ns -> do (e', rws) <- inferSCC cons e ns; pure (e', acc ++ rws))
          (env0, [])
          [ns | scc <- sccs, let ns = flat scc]
      -- `> expr.` errors get the same "in NAME:" treatment a clause gets,
      -- under the eval's ordinal -- otherwise they reach the sinks
      -- unprefixed, which is also unanchored, which leaked the raw
      -- statement-offset stamp instead of a file:line:col
      rwEvals <- forM (zip [1 :: Int ..] evals) $ \(evi, e) -> do
        nerrs0 <- length <$> gets iErrs
        r <- snd <$> inferE (ICtx env cons sigs prof) e
        modify $ \st ->
          let (old, new) = splitAt nerrs0 (iErrs st)
           in st {iErrs = old ++ ["in <eval " ++ show evi ++ ">: " ++ m | m <- new]}
        pure r
      -- typed struct conformance
      checkStructConformance sigs structs env
      -- ?? markers -> traps: eta-wrap by the hole's ZONKED type so the
      -- pipeline before a functional hole runs first (args evaluate
      -- before the call in this strict language), then trap
      hz <- gets iHoles
      hzt <- mapM (\(n, t) -> (,) n <$> zonk t) hz
      let trapFor t =
            let arrows tt = case tt of TFn _ b -> 1 + arrows b; _ -> 0
                nA = min 1 (arrows t) -- one level: consume the piped arg, then trap
                body = SApp (SVar "error") (SStrI [SegStr "typed hole ?? (unimplemented)"])
             in if nA == 0 then body else SLam ["?h"] body
          fixT e = case e of
            SApp (SVar "?trap!") (SInt k) | Just (_, t) <- lookupK (fromIntegral k) hzt -> trapFor t
            _ -> e
          lookupK k xs = if k >= 0 && k < length xs then Just (xs !! k) else Nothing
      -- zonk the recorded typed holes for reporting
      hs0 <- gets iHoles
      hs <- mapM (\(n, t) -> (,) n <$> prettyT t) hs0
      modify (\st -> st {iHolesP = hs})
      -- record pretty schemes for reporting (user binds, in file order),
      -- and the same types as LINEARITY SHAPES: params peeled to the
      -- bind's own clause arity, so the checker can enforce
      -- exactly-once on Vec/Handle/SString params even when the user
      -- wrote no signature (the audited unannotated-main hole)
      let linNs = nub [n | TType n True _ _ <- tops]
      forM_ bindNames $ \n ->
        forM_ (M.lookup n env) $ \sc -> do
          t <- instantiate sc
          p <- prettyT t
          tz <- zonk t
          let ar = case clausesOf n of ((ps0, _, _) : _) -> length ps0; [] -> 0
              peel 0 tt = ([], tt)
              peel k (TFn a b) = let (as, r) = peel (k - 1 :: Int) b in (a : as, r)
              peel _ tt = ([], tt)
              (pts, rt) = peel ar tz
              lsig = (map (linShapeT linNs) pts, linShapeT linNs rt)
          modify (\s -> s {iNotes = iNotes s ++ [(n, p)], iLinSigs = iLinSigs s ++ [(n, lsig)]})
      -- resolve operator sites against the final substitution, then
      -- rebuild the top list with markers rewritten, in original order
      tgts <- resolveSites sigs env
      let rwMap = M.fromListWith (++) [(n, [(ps, g, b)]) | (n, ps, g, b) <- rwBinds]
          apE0 = applySites tgts
          apE = everyE fixT . apE0
          everyE f = go'
            where
              go' e = f (step' e)
              step' e = case e of
                SMark o x -> SMark o (go' x)
                SApp a b -> SApp (go' a) (go' b)
                SLam ps x -> SLam ps (go' x)
                SBlock stmts fin -> SBlock (map goS stmts) (go' fin)
                SCase sc as -> SCase (go' sc) [(p, go' x) | (p, x) <- as]
                SBin o a b -> SBin o (go' a) (go' b)
                SProj x fdn -> SProj (go' x) fdn
                SRec fs -> SRec [(fdn, go' x) | (fdn, x) <- fs]
                SUpd m as -> SUpd (go' m) [(fdn, go' x) | (fdn, x) <- as]
                STup es -> STup (map go' es)
                SList es -> SList (map go' es)
                SStrI segs -> SStrI [case sg of SegExpr x -> SegExpr (go' x); other -> other | sg <- segs]
                other -> other
              goS (SBind n ps x) = SBind n ps (go' x)
              goS (SBindPat p x) = SBindPat p (go' x)
      let rebuild (evs, bnds) t = case t of
            TEval _ -> case evs of
              (e : rest) -> ((rest, bnds), TEval (apE e))
              [] -> ((evs, bnds), t)
            TBind n _ _ _ -> case M.lookup n bnds of
              Just ((ps, g, b) : more) ->
                ((evs, M.insert n more bnds), TBind n ps (map (mapGuardE apE) g) (apE b))
              _ -> ((evs, bnds), t)
            _ -> ((evs, bnds), t)
          (_, tops') = foldl' (\(st', acc) t -> let (st2, t') = rebuild st' t in (st2, acc ++ [t'])) ((rwEvals, fmap reverse rwMap), []) tops
      pure tops'
    flat (AcyclicSCC n) = [n]
    flat (CyclicSCC ns) = ns

    inferSCC :: TEnv -> TEnv -> [Name] -> I (TEnv, [(Name, [SPat], [SGuard], SExpr)])
    inferSCC cons env ns = do
      -- monomorphic recursion within the SCC
      mvs <- mapM (const freshT) ns
      let recEnv = M.union (M.fromList (zip ns (map mono mvs))) env
      rws <- forM (zip ns mvs) $ \(n, mv) ->
        forM (clauses n) $ \(ps, g, b) -> do
          nerrs0 <- gets (length . iErrs)
          -- params: PSig gets its sig's record type; others infer
          (ptys, penvs) <- unzip <$> mapM (inferParam cons) ps
          let ctx = ICtx (M.union (M.unions penvs) recEnv) cons sigs prof
          -- guards run left to right; a pattern guard's binds are in
          -- scope for the guards to its right and for the body
          (ctx2, g') <-
            foldM
              ( \(cx, acc) gd -> case gd of
                  GBool ge -> do
                    (tg, ge') <- inferE cx ge
                    unify ("guard of " ++ n) tg tBool
                    pure (cx, acc ++ [GBool ge'])
                  GPat p ge -> do
                    (tg, ge') <- inferE cx ge
                    (tp, benv) <- inferPat cons p
                    unify ("pattern guard of " ++ n) tg tp
                    pure (extend benv cx, acc ++ [GPat p ge'])
              )
              (ctx, [])
              g
          (tb, b') <- inferE ctx2 b
          declaredOrRec n mv (foldr TFn tb ptys)
          -- prefix errors this clause produced with the bind name
          modify $ \st ->
            let (old, new) = splitAt nerrs0 (iErrs st)
             in st {iErrs = old ++ ["in " ++ n ++ ": " ++ e | e <- new]}
          pure (n, ps, g', b')
      -- numeric defaulting BEFORE generalization: an ARITH/ORDERED-CMP
      -- site still at an unbound non-carrier var here must pin to Int
      -- now — otherwise the scheme generalizes while the site compiles
      -- as the Int primitive.  ONLY those: an ==/!= site at a TV stays
      -- polymorphic (generic veq, exactly as before floats), and a
      -- str! site at a TV is a polymorphic interpolation ("{x}" in a
      -- generic helper) whose marker simply strips -- defaulting
      -- either would Int-pin every generic function that compares or
      -- interpolates its argument.
      do
        sites <- gets iSites
        reps <- carrierReps
        forM_ (IM.elems sites) $ \(op, t0) ->
          when (op `elem` ["+", "-", "*", "/", "<", "<=", ">", ">="]) $ do
            t <- zonk t0
            case t of
              TV v | not (IM.member v reps) -> unify "numeric default" (TV v) tInt
              _ -> pure ()
      -- generalize against the OUTER env
      newEnv <- forM (zip ns mvs) $ \(n, mv) -> do
        sc <- case M.lookup n env of
          Just declared -> pure declared -- keep the declared scheme
          Nothing -> generalize env mv
        pure (n, sc)
      pure (M.union (M.fromList newEnv) env, concat rws)
      where
        clauses n = [(ps, g, b) | TBind n' ps g b <- tops, n' == n]
        declaredOrRec n mv t = case M.lookup n env of
          Just declared -> do
            dt <- instantiate declared
            unify ("declared type of " ++ n) dt t
          Nothing -> unify ("definition of " ++ n) mv t

    inferParam :: TEnv -> SPat -> I (Type, TEnv)
    inferParam cons p = case p of
      PSig n sg ->
        sigRecType sg >>= \case
          Nothing -> do
            report ("(" ++ n ++ " : " ++ sg ++ "): unknown sig")
            a <- freshT
            pure (a, M.singleton n (mono a))
          Just (t, mcarrier) -> do
            forM_ mcarrier $ \cv -> addCarrier cv (n, sg)
            pure (t, M.singleton n (mono t))
      _ -> inferPat cons p

    sigRecType :: Name -> I (Maybe (Type, Maybe Int))
    sigRecType sg = case M.lookup sg sigs of
      Nothing -> pure Nothing
      Just fields -> do
        (mk, tbl) <- foldM step (id, M.empty) fields
        tl <- freshR
        let carrier = case M.lookup "t" tbl of Just (TV v) -> Just v; _ -> Nothing
        pure (Just (TRec (mk tl), carrier))
      where
        step (acc, tbl) (f, mty) = case mty of
          Nothing -> do t <- freshT; pure (acc . RExt f t, tbl)
          Just ty -> do (t, tbl') <- tyToTypeA aliases tbl ty; pure (acc . RExt f t, tbl')

    -- typed conformance: for struct N implementing Sig, each declared
    -- sig field type must unify with an instantiation of N.f's inferred
    -- scheme — under ONE shared var table per struct/sig pair, so the
    -- carrier `t` is consistent across the sig's fields
    checkStructConformance :: Sigs -> Structs -> TEnv -> I ()
    checkStructConformance sgs sts env =
      forM_ (M.toList sts) $ \(sn, (declSigs, _fields)) ->
        forM_ declSigs $ \sg -> do
          _ <-
            foldM
              ( \tbl (f, mty) -> case (mty, M.lookup (sn ++ "." ++ f) env) of
                  (Just ty, Just sc) -> do
                    have <- instantiate sc
                    (want, tbl') <- tyToTypeA aliases tbl ty
                    unify ("struct " ++ sn ++ " field ." ++ f ++ " vs sig " ++ sg) have want
                    pure tbl'
                  _ -> pure tbl
              )
              M.empty
              (M.findWithDefault [] sg sgs)
          pure ()

    topRefs2 topSet bound e = [n | n <- coll bound e, S.member n topSet]
      where
        coll bs = \case
          SMark _ x -> coll bs x
          SVar v | not (S.member v bs) -> [v]
          SApp a b -> coll bs a ++ coll bs b
          SLam ps x -> coll (bs <> S.fromList ps) x
          SBlock stmts fin -> gos bs stmts fin
          SCase s as -> coll bs s ++ concat [coll (bs <> S.fromList (patVars p)) x | (p, x) <- as]
          SBin _ a b -> coll bs a ++ coll bs b
          SProj x _ -> coll bs x
          SRec fs -> concatMap (coll bs . snd) fs
          SUpd m as -> coll bs m ++ concatMap (coll bs . snd) as
          STup es -> concatMap (coll bs) es
          SList es -> concatMap (coll bs) es
          SStrI segs -> concat [coll bs x | SegExpr x <- segs]
          _ -> []
        gos bs [] fin = coll bs fin
        gos bs (SBind n ps x : rest) fin = coll (bs <> S.fromList (n : ps)) x ++ gos (S.insert n bs) rest fin
        gos bs (SBindPat p x : rest) fin = coll bs x ++ gos (bs <> S.fromList (patVars p)) rest fin

-- ---- pretty printing --------------------------------------------------------

prettyT :: Type -> I String
prettyT t0 = do t <- zonk t0; pure (go 0 t)
  where
    go :: Int -> Type -> String
    go p = \case
      TV v -> tvName v
      TC n -> n
      TAp a b -> paren (p > 9) (go 9 a ++ " " ++ go 10 b)
      TFn a b -> paren (p > 0) (go 1 a ++ " -> " ++ go 0 b)
      TTupT ts -> "(" ++ intercalate ", " (map (go 0) ts) ++ ")"
      TRec r -> "{" ++ rowStr r ++ "}"
    rowStr = \case
      RNil -> ""
      RV v -> tvName v
      RExt l t r -> l ++ " : " ++ go 0 t ++ next r
    next = \case
      RNil -> ""
      RV v -> " | " ++ tvName v
      r@RExt {} -> ", " ++ rowStr r
    paren True s = "(" ++ s ++ ")"
    paren False s = s
    tvName v = let l = ['a' ..] !! (v `mod` 26) in l : (if v >= 26 then show (v `div` 26) else "")

prettyRow :: Row -> I String
prettyRow r = do
  s <- prettyT (TRec r)
  pure s
