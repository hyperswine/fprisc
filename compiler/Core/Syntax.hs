{-# OPTIONS_GHC -O2 #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
-- The native Core syntax and lexical queries, independent of parsing/inference.
-- Constructor order and Binary encoding remain compatible with FPRISC.Core.
module Core.Syntax (Name, Core(..), Prog, occurs, freeVars) where
import Control.DeepSeq (NFData)
import Data.Binary (Binary)
import GHC.Generics (Generic)
import qualified Data.Map.Strict as M

type Name = String

data Core
  = CVar Name
  | CInt Integer
  | CStr String
  | CApp Core Core
  | CLam [Name] Core
  | CLet Name Core Core
  | CIf Core Core Core
  | CMk Int Int [Core]
  | CTagEq Int Int Core
  | CProj Int Core
  | CErr String
  deriving (Show, Eq, Ord, Generic, NFData, Binary)

type Prog = M.Map Name ([Name], Core)

-- does `x` occur free in `e`?  Stops at the first occurrence, where
-- `freeVars` lists every one (and filters the list at every lambda).
occurs :: Name -> Core -> Bool
occurs x = \case
  CVar n -> n == x
  CApp a b -> occurs x a || occurs x b
  CLam ps b -> x `notElem` ps && occurs x b
  CLet y a b -> occurs x a || (y /= x && occurs x b)
  CIf c t e -> occurs x c || occurs x t || occurs x e
  CMk _ _ fs -> any (occurs x) fs
  CTagEq _ _ e -> occurs x e
  CProj _ e -> occurs x e
  _ -> False

freeVars :: Core -> [Name]
freeVars = \case
  CVar n -> [n]
  CApp a b -> freeVars a ++ freeVars b
  CLam ps b -> filter (`notElem` ps) (freeVars b)
  CLet x a b -> freeVars a ++ filter (/= x) (freeVars b)
  CIf c t e -> freeVars c ++ freeVars t ++ freeVars e
  CMk _ _ fs -> concatMap freeVars fs
  CTagEq _ _ e -> freeVars e
  CProj _ e -> freeVars e
  _ -> []

