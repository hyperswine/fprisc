{-# OPTIONS_GHC -O2 #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
-- The native Core syntax and lexical queries, independent of parsing/inference.
-- Constructor order and Binary encoding remain compatible with FPRISC.Core.
module Core.Syntax (Name, Core(..), Prog, occurs, freeVars,
  ProductMarker(..), productMarker, packName, valueName, storedNodeName, spineOf, floatLitBits
) where
import Data.List (stripPrefix)
import Control.DeepSeq (NFData)
import Data.Binary (Binary)
import GHC.Generics (Generic)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

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
freeVars e = walk S.empty e []
  where
    -- Preserve occurrence order and duplicates. Filtering the whole suffix
    -- at every let copied the same free occurrences repeatedly; record the
    -- lexical scope instead, and append each free occurrence only once.
    walk bound expr rest = case expr of
      CVar n | S.notMember n bound -> n : rest
      CApp a b -> walk bound a (walk bound b rest)
      CLam ps b -> walk (S.union bound (S.fromList ps)) b rest
      CLet x a b -> walk bound a (walk (S.insert x bound) b rest)
      CIf c t f -> walk bound c (walk bound t (walk bound f rest))
      CMk _ _ fs -> foldr (walk bound) rest fs
      CTagEq _ _ x -> walk bound x rest
      CProj _ x -> walk bound x rest
      _ -> rest

-- Product ABI markers (formerly Core.Syntax)
data ProductMarker = PackWords Int | JoinWords Int deriving (Eq,Show)
packName n = "$product.pack"++show n
valueName n = "$product.value"++show n
productMarker name = do
  suffix <- stripPrefix "$product." name
  lookup suffix ([("pack"++show n,PackWords n) | n<-[2..8]]
    ++ [("value"++show n,JoinWords n) | n<-[2..8]])

storedNodeName :: String
storedNodeName="$storage.makeNode"

-- Core utilities (formerly Core.Syntax)
spineOf :: Core -> (Core, [Core])
spineOf = go []
  where
    go acc (CApp f a) = go (a : acc) f
    go acc f = (f, acc)

-- a float LITERAL inside an unboxable body: the desugarer emits
-- f64frombits hi lo (or f32frombits bits) with constant arguments, so
-- it folds to one `li` of the bit pattern.  Without this, any body
-- mentioning 2.0 would fail admission and lose its specialized loop.
floatLitBits :: Core -> Maybe Integer
floatLitBits e = case spineOf e of
  (CVar "f64frombits", [CInt hi, CInt lo]) -> Just ((hi * 4294967296) + (lo `mod` 4294967296))
  (CVar "f32frombits", [CInt b]) -> Just b
  _ -> Nothing

