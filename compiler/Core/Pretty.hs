{-# OPTIONS_GHC -O2 #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# LANGUAGE LambdaCase, TupleSections #-}

-- Core diagnostic rendering, independent of frontend parsing.
module Core.Pretty where

import Core.Syntax ( Prog, Core(..), Name )
import Data.List ( intercalate )
import qualified Data.Map.Strict as M ( lookup )

pretty :: Core -> String
pretty = go 0
  where
    ind n = replicate (n * 2) ' '
    go _ (CVar n) = n
    go _ (CInt i) = show i
    go _ (CStr s) = show s
    go _ (CErr m) = "error " ++ show m
    go d e@CApp {} = let (f, as) = spine e in "(" ++ unwords (map (go d) (f : as)) ++ ")"
    go d (CLam ps b) = "(\\" ++ unwords ps ++ " -> " ++ go d b ++ ")"
    go d (CLet x a b) = "let " ++ x ++ " = " ++ go (d + 1) a ++ " in\n" ++ ind (d + 1) ++ go (d + 1) b
    go d (CIf c t e) = "if " ++ go d c ++ "\n" ++ ind (d + 1) ++ "then " ++ go (d + 1) t ++ "\n" ++ ind (d + 1) ++ "else " ++ go (d + 1) e
    go d (CMk t v fs) = "mk[" ++ show t ++ "." ++ show v ++ "](" ++ intercalate ", " (map (go d) fs) ++ ")"
    go d (CTagEq t v e) = "tag?(" ++ go d e ++ " == " ++ show t ++ "." ++ show v ++ ")"
    go d (CProj i e) = "proj." ++ show i ++ "(" ++ go d e ++ ")"
    spine (CApp a b) = let (f, as) = spine a in (f, as ++ [b])
    spine f = (f, [])

prettyProg :: Prog -> [Name] -> String
prettyProg prog names = unlines [n ++ " " ++ unwords ps ++ " =\n  " ++ pretty b ++ "\n" | n <- names, Just (ps, b) <- [M.lookup n prog]]
