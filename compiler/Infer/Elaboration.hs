-- Decisions made by checked operator/layout resolution. Consumers must not
-- rediscover these decisions by parsing marker strings in a rewritten body.
module Infer.Elaboration (OpTarget(..), ElaborationFact(..)) where
import Core.Identity (ExprId)
import Frontend.Syntax (SExpr)
import Type.Syntax (Type)

data OpTarget = OpPrim String | OpGlobal String | OpVecLayout String String
              | OpVecDynamic String SExpr | OpDictionary [SExpr]
              | OpProj String String deriving (Show)
data ElaborationFact = ElaborationFact
  { elaborationSite :: Int, elaborationOperation :: String,
    elaborationType :: Type, elaborationTarget :: OpTarget,
    elaborationOffset :: Maybe Int, elaborationExpression :: Maybe ExprId }
  deriving (Show)
