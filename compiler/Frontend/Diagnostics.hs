{-# OPTIONS_GHC -O2 #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# LANGUAGE LambdaCase, TupleSections #-}

-- Source anchoring compatibility; structured diagnostics are a later stage.
module Frontend.Diagnostics where

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
anchorMsg srcs anchors msg = case msg of
  'i' : 'n' : ' ' : rest
    | (n, ':' : ' ' : body) <- break (== ':') rest ->
        let cleaned = "in " ++ n ++ ": " ++ dropMark body
         in case M.lookup n anchors of
              Nothing -> cleaned
              Just (f, bindLn) -> case markPos f body of
                Just (l, c) -> at f l c cleaned
                Nothing -> case tokenPos f n bindLn body of
                  Just (l, c) -> at f l c cleaned
                  Nothing -> f ++ ":" ++ show bindLn ++ ": " ++ cleaned
  _ -> dropMark msg
  where
    at f l c rest' = f ++ ":" ++ show l ++ ":" ++ show c ++ ": " ++ rest'
    -- step 3: "@OFF~ " stamp from the inference engine
    markPos f ('@' : b)
      | (ds@(_ : _), '~' : ' ' : _) <- span (`elem` ("0123456789" :: String)) b =
          offsetPos f (read ds)
    markPos _ _ = Nothing
    dropMark ('@' : b)
      | (_ : _, '~' : ' ' : real) <- span (`elem` ("0123456789" :: String)) b = real
    dropMark b = b
    offsetPos f off = do
      src <- M.lookup f srcs
      let pre = take off src
          l = 1 + length (filter (== '\n') pre)
          c = 1 + length (takeWhile (/= '\n') (reverse pre))
      pure (l, c)
    -- step 2: the token the message names, found in the bind's range
    tokenPos f n bindLn body = do
      src <- M.lookup f srcs
      tok <- msgToken body
      let endLn = case [l | (_, (f', l)) <- M.toList anchors, f' == f, l > bindLn] of
            [] -> length (lines src)
            ls -> minimum ls - 1
          slice = take (endLn - bindLn + 1) (drop (bindLn - 1) (lines src))
      case [ (bindLn + i, c)
             | (i, l) <- zip [0 ..] slice,
               c <- take 1 (wordHits tok l)
           ] of
        (p : _) -> Just p
        [] -> Nothing
    msgToken body = case break (== '\'') body of
      (_, '\'' : q) | (tok@(_ : _), '\'' : _) <- break (== '\'') q -> Just tok
      _
        | Just r <- afterStr "application of " body -> Just (takeWhile identChar r)
        | otherwise -> Nothing
    afterStr pat s
      | pat `isPrefixOf` s = Just (drop (length pat) s)
      | otherwise = case s of (_ : t) -> afterStr pat t; [] -> Nothing
    wordHits tok l =
      [ i + 1
        | i <- [0 .. length l - length tok],
          take (length tok) (drop i l) == tok,
          i == 0 || not (identChar (l !! (i - 1))),
          i + length tok >= length l || not (identChar (l !! (i + length tok)))
      ]
    identChar c = c `elem` ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.'@" :: String)
