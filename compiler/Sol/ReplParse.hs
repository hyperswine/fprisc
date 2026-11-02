{-# LANGUAGE LambdaCase #-}
-- Parsing a new REPL command does not require parsing accepted source again.
-- Marks still point into the full accumulated source (decoded characters).
module Sol.ReplParse (appendCommand) where

import Frontend.Syntax
import Frontend.Traverse (transformE)
import qualified Data.Set as S

appendCommand :: Int -> [STop] -> [STop] -> [STop]
appendCommand offset accepted = (accepted ++) . map shiftTop
  where
    shift = transformE (\_ -> \case SMark n e -> SMark (offset+n) e; e -> e) S.empty
    shiftTop = \case
      TBind n ps gs e -> TBind n ps (map (mapGuardE shift) gs) (shift e)
      TEval e -> TEval (shift e)
      TStruct n ss fs -> TStruct n ss [(f,shift e) | (f,e) <- fs]
      TSig n ty pre -> TSig n ty [fmap (\(v,e) -> (v,shift e)) p | p <- pre]
      t -> t
