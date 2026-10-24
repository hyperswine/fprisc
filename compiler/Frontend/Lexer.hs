{-# OPTIONS_GHC -O2 #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# LANGUAGE LambdaCase, TupleSections #-}

-- Token parsers and lexical identifier rules.
module Frontend.Lexer where

import Control.Monad ( when, void )
import Core.Syntax ( Name )
import Data.Char ( isAlphaNum, isLetter, isLower, isUpper )
import Data.List ( intercalate )
import Data.Void ( Void )
import Text.Megaparsec
    ( (<|>),
      empty,
      optional,
      oneOf,
      satisfy,
      between,
      many,
      some,
      Parsec,
      MonadParsec(notFollowedBy, takeWhileP, lookAhead, try) )
import Text.Megaparsec.Char ( char, hexDigitChar, space1, string )
import qualified Text.Megaparsec.Char.Lexer as L
    ( decimal, skipLineComment, lexeme, space, symbol )

type P = Parsec Void String

sc :: P ()
sc = L.space space1 (L.skipLineComment "#") empty

lexeme :: P a -> P a
lexeme = L.lexeme sc

symbol :: String -> P String
symbol = L.symbol sc

identChar :: Char -> Bool
identChar c = isAlphaNum c || c == '_' || c == '\''

reserved :: [String]
reserved = ["fn", "case", "of", "if", "then", "else", "Type", "Sig", "Struct", "use"]

dottedIdent :: P [String]
dottedIdent = lexeme $ do
  first <- rawSeg
  rest <- many (try (char '.' *> rawSeg))
  let n = first : rest
  when (first `elem` reserved) $ fail ("reserved word: " ++ first)
  pure n
  where
    rawSeg = (:) <$> satisfy isLetter <*> takeWhileP Nothing identChar

lowerName :: P Name
lowerName = try $ do
  segs <- dottedIdent
  case segs of
    [s] | isLower (head s) -> pure s
    _ -> fail "expected simple lowercase identifier"

pName :: P Name
pName = try (parens operatorName) <|> lowerName
  where
    operatorName = lexeme (some (oneOf "+-*/%^=!<>|$?"))

-- a lower identifier WITHOUT the reserved-word check: for positions
-- that are syntactically unambiguous (signature names, use aliases),
-- where `use : String -> Module.` must be admissible as a name.
lowerNameRaw :: P Name
lowerNameRaw = try . lexeme $ do
  c <- satisfy (\ch -> ch >= 'a' && ch <= 'z')
  rest <- many (satisfy identChar)
  pure (c : rest)

upperName :: P Name
upperName = try $ do
  segs <- dottedIdent
  case segs of
    (s : _) | isUpper (head s) -> pure (intercalate "." segs)
    _ -> fail "expected uppercase identifier"

integer :: P Integer
integer = integerN False

-- An Int is tagged: 63 bits, -4611686018427387904..4611686018427387903.
-- A literal past that is refused HERE, at its position, not deep in
-- codegen (which used to stop with a Haskell `error`).  `neg`: the
-- literal follows a minus sign, so the magnitude may reach 2^62.
intMax :: Integer
intMax = 2 ^ (62 :: Int) - 1

integerN :: Bool -> P Integer
integerN neg = lexeme $ do
  n <- L.decimal
  hex <- optional (lookAhead (try (oneOf ("xX" :: String) *> hexDigitChar)))
  when (n == 0 && hex /= Nothing) $
    fail "0x...: FP-RISC has no hexadecimal literal; write the number in decimal"
  when (n > intMax + (if neg then 1 else 0)) $
    fail ("integer literal " ++ (if neg then "-" else "") ++ show n
          ++ " does not fit an Int (-4611686018427387904..4611686018427387903)")
  pure n

-- 1.5 / 2.0e-3 : an F64 literal.  `try` in term backtracks cleanly on
-- "1." (int + the clause terminator) since the fraction needs a digit.
-- A tagged V carries 62 payload bits, not 64, so the literal desugars
-- as f64frombits hi lo (two tagged 32-bit halves spliced by the prim);
-- no new AST node, no Core change, and float literals in patterns are
-- impossible by construction (deliberately: compare with <=, not ==).
-- ONE numeric literal parser, so the width is decided in ONE place:
--
--   1        Int                 1.5      F64 (a fraction implies F64)
--   1.5f     F32                 2f       F32  (suffix wins; no '.' needed)
--   1.5d     F64 (explicit)      2d       F64
--   1e3      F64                 1.5e-3f  F32
--
-- The suffix must not be followed by more identifier characters, so
-- `2fold` stays `2` applied to `fold` and only a deliberate `2f` is a
-- literal.  `1.` still lexes as Int 1 + the clause terminator: the
-- fraction is inside `try` and needs a digit after the dot.
--
-- F64 splices as f64frombits hi lo; F32 takes f32frombits. On RV32
-- code generation pools immutable boxes for these raw literal words,
-- because a tagged Int cannot carry every binary32 bit pattern.
parens :: P a -> P a
parens = between (symbol "(") (symbol ")")

braces :: P a -> P a
braces = between (symbol "{") (symbol "}")

brackets :: P a -> P a
brackets = between (symbol "[") (symbol "]")

dotTerm :: P ()
dotTerm = lexeme . try $ void (char '.' <* notFollowedBy (satisfy isLetter))

pipeSep :: P ()
pipeSep = lexeme . try $ void (char '|' <* notFollowedBy (oneOf ">?"))

eqSign :: P ()
eqSign = lexeme . try $ void (char '=' <* notFollowedBy (char '='))


keyword :: String -> P ()
keyword w = lexeme . try $ void (string w <* notFollowedBy (satisfy identChar))
