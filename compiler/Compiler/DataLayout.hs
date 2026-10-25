-- Runtime layout vocabulary shared by native lowering and compatibility APIs.
module Compiler.DataLayout (Layouts(..),tupWideBase,wideTup) where
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
