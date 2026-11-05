-- Runtime layout vocabulary shared by native lowering and compatibility APIs.
module Compiler.DataLayout (Layouts(..),tupWideBase,wideTup,smallTupleLayouts,storedListTid,storedListVariant) where
import Data.Char (isDigit)
import qualified Data.Map.Strict as M

data Layouts=Layouts
  { constructorLayouts :: M.Map String (Int,Int,Int), shapeLayouts :: M.Map [String] Int }
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
