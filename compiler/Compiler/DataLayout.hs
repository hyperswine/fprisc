-- Runtime layout vocabulary shared by native lowering and compatibility APIs.
module Compiler.DataLayout (Layouts(..),tupWideBase,wideTup,smallTupleLayouts,storedListTid,storedListVariant,i64Store,i64Load,i64StoreAt,i64Fields) where
import Data.Char (isDigit)
import Core.Syntax (Core(..))
import qualified Data.Map.Strict as M

data Layouts=Layouts
  { constructorLayouts :: M.Map String (Int,Int,Int), shapeLayouts :: M.Map [String] Int,
    -- C6 stage 3c: the fields of each constructor declared I64, stored as the
    -- integer's raw bits (Frontend.Desugar.collectI64Fields); empty where the
    -- image publishes no raw-field masks, so every I64 field stays a box
    i64FieldLayouts :: M.Map String [Int] }
tupWideBase :: Int
tupWideBase=0x10000000
wideTup :: String -> Maybe (Int,Int,Int)
wideTup c=case c of
  'T':'u':'p':ds | not (null ds),all isDigit ds,n>8->Just (tupWideBase+n,0,n)
    where n=read ds
  _->Nothing


-- The hosted runtime reserves these ids for its two- to eight-field tuples.
smallTupleLayouts :: M.Map String (Int,Int,Int)
smallTupleLayouts=M.fromList [("Tup"++show n,(tid,0,n)) | (n,tid)<-zip [2..8] [4,5,10,11,12,13,14]]


-- Matches the runtime's T_STORED_LIST. The width belongs to the actual
-- allocation even when its nominal variant is supplied in a register.
storedListTid :: Int
storedListTid=9008
storedListVariant :: Int -> Int -> Int
storedListVariant payloads variant=8*variant+payloads-1


-- C6 stage 3c: a constructor field declared I64 holds the integer's bits.
-- Construction stores the box's value (I64.toField, the runtime reads it out
-- of the box); a pattern binds a fresh box of the bits (I64.ofField). The
-- raw-field masks tell every runtime walker that the word is not a pointer.
i64Store :: Core -> Core
i64Store=CApp (CVar "I64.toField")
i64Load :: Core -> Core
i64Load=CApp (CVar "I64.ofField")
-- the fields of a constructor value, the I64 ones (by index) stored raw
i64StoreAt :: [Int] -> [Core] -> [Core]
i64StoreAt [] xs=xs
i64StoreAt is xs=[if i `elem` is then i64Store x else x | (i,x)<-zip [0..] xs]
-- a constructor's fields declared I64 and stored raw, from the layouts
i64Fields :: Layouts -> String -> [Int]
i64Fields layouts c=M.findWithDefault [] c (i64FieldLayouts layouts)
