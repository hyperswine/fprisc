{-# LANGUAGE TupleSections #-}
-- Session-local, closed definition interfaces. No unifier, operator-site IDs,
-- execution state or effects cross the checking boundary.
module Infer.Session
  (CheckedDefinitions, matchingDefinitions, checkedSchemes, checkedTops,
   rememberDefinitions) where

import Control.DeepSeq (NFData(..))
import qualified Data.Binary as Bin
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Frontend.Syntax (STop(..))
import Core.Syntax (Name)
import Type.Syntax (Scheme)

-- The exact declaration context, original clauses, closed schemes and fully
-- resolved clauses. This is an in-memory value, never a disk cache.
data CheckedDefinitions = CheckedDefinitions BL.ByteString [STop] (M.Map Name Scheme) [STop]
instance NFData CheckedDefinitions where
  rnf (CheckedDefinitions key source schemes rewritten) = rnf (key,source,schemes,rewritten)

context :: BL.ByteString -> [STop] -> BL.ByteString
context extra = Bin.encode . (extra,) . filter declaration
  where
    declaration TBind{} = False
    declaration TEval{} = False
    declaration TSkip = False
    declaration _ = True

bindings :: [STop] -> [STop]
bindings = filter (\t -> case t of TBind{} -> True; _ -> False)

matchingDefinitions :: BL.ByteString -> [STop] -> Maybe CheckedDefinitions -> Maybe CheckedDefinitions
matchingDefinitions extra tops (Just old@(CheckedDefinitions key original schemes rewritten))
  | context extra tops == key
  , Bin.encode retained == Bin.encode original
  , S.null additions || S.null (S.intersection newParts used) = Just old
  where
    oldNames = M.keysSet schemes
    name (TBind n _ _ _) = n
    name _ = error "binding expected"
    retained = [t | t <- bindings tops, S.member (name t) oldNames]
    additions = S.fromList [name t | t <- bindings tops, S.notMember (name t) oldNames]
    newParts = S.unions (map nameParts (S.toList additions))
    -- Over-approximate every name an old definition or an accepted eval
    -- mentions, including compiler-introduced operator targets. Dotted suffixes
    -- and parenthesized operators prevent new globals from changing implicit
    -- field/member or builtin resolution. Literal strings can over-invalidate.
    used = mentioned (retained ++ rewritten ++ [t | t@TEval{} <- tops])
matchingDefinitions _ _ _ = Nothing

checkedSchemes :: CheckedDefinitions -> M.Map Name Scheme
checkedSchemes (CheckedDefinitions _ _ schemes _) = schemes
checkedTops :: CheckedDefinitions -> [STop]
checkedTops (CheckedDefinitions _ _ _ tops) = tops

-- Only the inference driver calls this after checking every scheme is closed.
-- The session owner publishes it only after the ENTIRE compiler succeeds.
rememberDefinitions :: BL.ByteString -> [STop] -> M.Map Name Scheme -> [STop] -> CheckedDefinitions
rememberDefinitions extra source schemes = CheckedDefinitions (context extra source) (bindings source) schemes . bindings

mentioned :: Show a => a -> S.Set Name
mentioned = S.unions . map nameParts . strings . show
  where
    strings ('"':rest) = case reads ('"':rest) of
      [(s,rest')] -> s : strings rest'
      _ -> strings rest
    strings (_:rest) = strings rest
    strings [] = []

nameParts :: Name -> S.Set Name
nameParts name = S.fromList (name : bare : parts bare)
  where
    bare = case name of
      '(' : rest -> case reverse rest of ')' : inner -> reverse inner; _ -> name
      _ -> name
    parts s = case break (== '.') s of
      (a,[]) -> [a]
      (a,_:b) -> a : b : parts b
