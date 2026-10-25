{-# LANGUAGE DeriveGeneric #-}
-- Source coordinates are independent of surface syntax, inference and Core.
-- Offsets count decoded characters, as the parser does; spans are half-open.
module Source.Span (SourceOffset(..), SourceSpan(..), SourceLocation(..), pointSpan, offsetPosition) where
import GHC.Generics (Generic)
import Control.DeepSeq (NFData)
newtype SourceOffset = SourceOffset {offsetCharacters :: Int} deriving (Eq,Ord,Show,Generic)
data SourceSpan = SourceSpan
  { spanFile :: FilePath, spanStart :: SourceOffset, spanEnd :: SourceOffset }
  deriving (Eq,Ord,Show,Generic)
data SourceLocation = AtPoint FilePath Int Int | AtLine FilePath Int deriving (Eq,Ord,Show,Generic)
pointSpan :: FilePath -> SourceOffset -> SourceSpan
pointSpan file offset=SourceSpan file offset offset
offsetPosition :: String -> SourceOffset -> Maybe (Int,Int)
offsetPosition source (SourceOffset off)
  | off<0 || off>length source = Nothing
  | otherwise = let pre=take off source in
      Just (1+length (filter (=='\n') pre),1+length (takeWhile (/='\n') (reverse pre)))

instance NFData SourceOffset
instance NFData SourceSpan
instance NFData SourceLocation
