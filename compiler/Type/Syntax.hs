{-# LANGUAGE LambdaCase, DeriveGeneric, DeriveAnyClass #-}
-- Checked type vocabulary, independent of the inference engine and either AST.
-- Type-constructor names and row labels are textual; lexical term identities
-- live in Core.Identity. TLayout is private to compiler evidence/calling
-- contracts, with no source syntax. Existing Show output is diagnostic ABI.
module Type.Syntax
  (Type(..), Row(..), Scheme(..), tcon, tInt, tStr, tBool, tUnit, tAtom,
   tF64, tF32, tI64, tI32, tList, tVector, tSString, mentionsFloat) where
import Data.List (foldl')
import Control.DeepSeq (NFData)
import GHC.Generics (Generic)

data Type
  = TV Int
  | TC String
  | TAp Type Type
  | TFn Type Type
  | TRec Row
  | TTupT [Type]
  | TLayout Type -- compiler-private evidence for an element's native layout
  deriving (Eq, Ord, Show, Generic, NFData)

data Row
  = RV Int
  | RNil
  | RExt String Type Row
  deriving (Eq, Ord, Show, Generic, NFData)

data Scheme = Forall [Int] [Int] Type deriving (Show, Generic, NFData) -- tvars, rowvars

tcon :: String -> [Type] -> Type
tcon n = foldl' TAp (TC n)

tInt, tStr, tBool, tUnit, tAtom :: Type
tInt = TC "Int"

tF64, tF32, tI64, tI32 :: Type
tF64 = TC "F64"
tF32 = TC "F32"
-- I64: a 64-bit two's-complement integer (Int is tagged and 63 bits).
-- Wraps on overflow, by contract.  A boxed leaf at run time (runtime.c), so
-- unlike the raw-bits floats it may sit inside any structure and render:
-- only its operators, == and str/print route to its own prims.
tI64 = TC "I64"
tI32 = TC "I32"

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

tVector :: Type -> Type
tVector a = TAp (TC "Vector") a

tSString :: Type
tSString = TC "SString"

