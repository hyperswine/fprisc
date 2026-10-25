-- Shared semantic operations. Planners and native kernel lowering retain
-- these constructors; only ABI symbol rendering uses their spellings.
module Compiler.VectorOperation (ElementOp(..), elementOpName) where

data ElementOp = Map | Filter | Fold deriving (Eq, Show)

elementOpName :: ElementOp -> String
elementOpName Map = "map"
elementOpName Filter = "filter"
elementOpName Fold = "fold"
