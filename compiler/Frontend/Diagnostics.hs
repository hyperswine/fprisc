{-# OPTIONS_GHC -O2 #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# LANGUAGE LambdaCase, TupleSections #-}

-- Source definition anchors and compatibility API for diagnostic rendering.
module Frontend.Diagnostics where

import qualified Diagnostic.Render as Render
import Core.Syntax ( Name )
import Data.List ( isPrefixOf, nub )
import Frontend.Syntax ( STop(TSig, TBind) )
import qualified Data.Map.Strict as M
    ( lookup, toList, fromList, Map )

type Anchors = M.Map Name (FilePath, Int)

bindAnchors :: FilePath -> String -> [STop] -> Anchors
bindAnchors file src tops =
  M.fromList [(n, (file, ln)) | n <- names, Just ln <- [findLn (baseName n)]]
  where
    names = nub ([n | TBind n _ _ _ <- tops] ++ [n | TSig n _ _ <- tops])
    baseName = takeWhile (/= '@')
    srcLines = zip [1 :: Int ..] (lines src)
    findLn tok =
      case [i | (i, l) <- srcLines, tok `isPrefixOf` l, defLike (drop (length tok) l)] of
        (i : _) -> Just i
        [] -> Nothing -- struct fields etc. define off-column: no anchor, graceful
    defLike (c : _) = c `elem` (" \t:=(" :: String)
    defLike [] = True

type Sources = M.Map FilePath String

-- rewrite one diagnostic (spans steps 1-3, best available precision):
--
--   "in NAME: @OFF~ msg"  -> "file:line:col: in NAME: msg"   (step 3:
--       Infer stamped the enclosing statement mark's source offset)
--   "in NAME: ...'tok'..." -> "file:line:col: in NAME: ..."  (step 2:
--       the first word-boundary occurrence of the token the message
--       names, scanned within NAME's definition range)
--   "in NAME: msg"         -> "file:line: in NAME: msg"      (step 1:
--       NAME's definition line)
--
-- messages without a known "in NAME:" prefix pass through untouched.
-- The stamp is machinery, never output: EVERY path below drops it, so a
-- message that cannot be positioned (a bind with no col-0 definition --
-- prelude, struct-expanded, generated) still reads as prose instead of
-- leaking "@6~ ".
-- `> expr.` statements are top-level too, and the sol profile reports
-- their errors as `in <eval N>:`. They start at column 0 like every other
-- top declaration, so the same col-0 scan anchors them by ordinal.
evalAnchors :: FilePath -> String -> Anchors
evalAnchors file src =
  M.fromList
    [ ("<eval " ++ show i ++ ">", (file, ln))
      | (i, ln) <- zip [1 :: Int ..] [ln | (ln, l) <- zip [1 ..] (lines src), take 1 l == ">"]
    ]

anchorMsg :: Sources -> Anchors -> String -> String
anchorMsg = Render.anchorLegacyMessage
