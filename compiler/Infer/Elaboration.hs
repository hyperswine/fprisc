{-# LANGUAGE LambdaCase #-}
-- Decisions made by checked operator/layout resolution. Consumers must not
-- rediscover these decisions by parsing marker strings in a rewritten body.
module Infer.Elaboration (OpTarget(..), ElaborationFact(..), markerPrefix, applySites) where
import Source.Span (SourceOffset)
import Core.Identity (ExprId)
import Frontend.Syntax (SExpr(..), SStmt(..), Seg(..))
import Core.Syntax (Name)
import qualified Data.Set as S
import qualified Data.IntMap.Strict as IM
import Data.List (stripPrefix)
import Precond (checkedName)
import Type.Syntax (Type)
import Compiler.VectorLayout

data OpTarget = OpPrim String | OpGlobal String | OpVector VectorBuilder LayoutEvidence
              | OpDeclaredVector LayoutEvidence | OpDictionary String [LayoutEvidence]
              | OpProj String String deriving (Show)
data ElaborationFact = ElaborationFact
  { elaborationSite :: Int, elaborationOperation :: String,
    elaborationType :: Type, elaborationTarget :: OpTarget,
    elaborationOffset :: Maybe SourceOffset, elaborationExpression :: Maybe ExprId }
  deriving (Show)

markerPrefix :: String
markerPrefix = "op#"

-- rewrite the markers by the decided targets
applySites :: S.Set Name -> IM.IntMap OpTarget -> SExpr -> SExpr
applySites globals tgts = go
  where
    -- Operator/layout resolution happens after the precondition pass.
    -- A newly selected global therefore needs its checked function entry,
    -- just as a source function value does. Inspect the actual inference
    -- inputs so standalone unit resolution selects only available entries.
    checked g = let entry = checkedName g 0
                 in if entry `S.member` globals then entry else g
    call g = SApp (SVar (checked g))
    go = \case
      -- str! sites wrap an ARGUMENT: op#N#str! applied to e.  OpPrim ""
      -- strips the wrapper; OpPrim "F64.str" wraps the rendering prim.
      SApp (SVar op) a
        | Just rest <- stripPrefix markerPrefix op,
          (num, '#' : _) <- break (== '#') rest,
          Just tgt <- IM.lookup (read num) tgts ->
            case tgt of
              OpPrim "" -> go a
              OpPrim o -> call o (go a)
              OpDictionary _ es -> foldl SApp (go a) (map evidenceExpr es)
              OpVector builder evidence
                | plainBuilder builder evidence->go a
                | otherwise->let desc=evidenceExpr evidence in case builder of
                    BuildEmpty->SLam ["?vecUnit"] (call (builderRuntimeName builder) desc)
                    _->call (builderRuntimeName builder) desc
              OpDeclaredVector _ -> go a
              _ -> go a
      SBin op a b
        | Just rest <- stripPrefix markerPrefix op,
          (num, '#' : _rawOp) <- break (== '#') rest,
          Just tgt <- IM.lookup (read num) tgts ->
            case tgt of
              OpPrim o -> SBin o (go a) (go b)
              OpGlobal g -> SApp (call g (go a)) (go b)
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
    evidenceExpr (StaticLayout _ spec)=SStrI [SegStr spec]
    evidenceExpr (ForwardLayout _ slot)=SVar (layoutParameterName slot)
