{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- FPRISC syntax PoC: parse (megaparsec) + desugar to a minimal functional core.
--
-- Core has ONLY:
--   variables, int/string literals, application, let, if-else,
--   tagged product construction (typeid + variant id + fields),
--   tag tests, positional projections, primitive references.

module FPRISC where

import Control.Monad (foldM, unless, void, when)
import Control.Monad.State.Strict
import Data.Bits (shiftR, xor)
import qualified Data.Bits
import GHC.Float (castDoubleToWord64, castFloatToWord32)
import Data.Char (isAlphaNum, isLetter, isLower, isUpper, ord)
import Data.List (foldl', intercalate, isPrefixOf, nub, sort, sortOn)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Maybe (fromMaybe)
import Data.Void (Void)
import Data.Word (Word32)
import Text.Megaparsec
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L

type Name = String

--------------------------------------------------------------------------------
-- Surface AST
--------------------------------------------------------------------------------

data SExpr
  = SVar Name
  | SMark !Int SExpr -- source position wrapper (spans step 3): the Int
                     -- is the SOURCE OFFSET in the defining file,
                     -- attached by the parser at block-statement and
                     -- case-arm granularity.  INVISIBLE to semantics:
                     -- shape-sensitive matchers look through it
                     -- (unmark), stripPosTops erases it before module
                     -- hashing, the desugarer drops it at the Core
                     -- boundary.  Infer stamps the innermost enclosing
                     -- mark into its diagnostics ("@OFF~ "), which the
                     -- error sinks resolve to file:line:col.
  | SInt Integer
  | SAtom Name
  | SStrI [Seg]
  | SApp SExpr SExpr
  | SLam [Name] SExpr
  | SBlock [SStmt] SExpr
  | SCase SExpr [(SPat, SExpr)]
  | SBin Name SExpr SExpr
  | SProj SExpr [Name]
  | SRec [(Name, SExpr)]
  | SUpd SExpr [([Name], SExpr)]
  | STup [SExpr]
  | SList [SExpr]
  deriving (Show)

data Seg = SegStr String | SegExpr SExpr deriving (Show)

data SStmt
  = SBind Name [Name] SExpr
  | SBindPat SPat SExpr
  deriving (Show)

data SPat
  = PVar Name
  | PWild
  | PInt Integer
  | PStr String
  | PCon Name [SPat]
  | PTup [SPat]
  | PRec [Name]
  | PSig Name Name -- (s : Functor) — a param constrained by a named sig
  deriving (Show)

-- one component of a clause guard: `| e1, p <- e2, e3 = body`
data SGuard
  = GBool SExpr -- boolean condition
  | GPat SPat SExpr -- pattern-match binding `pat <- expr`
  deriving (Show)

guardBools :: [SGuard] -> [SExpr]
guardBools gs = [e | GBool e <- gs]

mapGuardE :: (SExpr -> SExpr) -> SGuard -> SGuard
mapGuardE f' (GBool e) = GBool (f' e)
mapGuardE f' (GPat p e) = GPat p (f' e)

data STop
  = TBind Name [SPat] [SGuard] SExpr
  | TType Name Bool [Name] [(Name, [Ty])]
  | TShape Name [(Name, Ty)]
  | TSig Name ([Ty], Ty) [Maybe (Name, SExpr)] -- per-PARAM precondition: (n : Int | n > 0)
  | TSigDef Name [(Name, Maybe Ty)] -- `Functor = Sig { map : ... }.`
  | TStruct Name [Name] [(Name, SExpr)] -- `Numeric = Struct Arith { ... }.`
  | TUse Name String -- MyMod = use "MyMod#hash".  (compile-time module import)
  | TAlias Name Name -- T = MyMod.T.  (name alias: types, constructors, values)
  | TEval SExpr -- `> effect.`  top-level eval (the HostedBytecode/sol view; profile-gated in Main)
  | TSkip
  deriving (Show)

data Ty = TCon Name [Ty] | TVarT Name | TTup [Ty] | TArrT Ty Ty | TVApp Name [Ty] | TOther
  deriving (Show)

--------------------------------------------------------------------------------
-- Core AST
--------------------------------------------------------------------------------

data Core
  = CVar Name
  | CInt Integer
  | CStr String
  | CApp Core Core
  | CLam [Name] Core
  | CLet Name Core Core
  | CIf Core Core Core
  | CMk Int Int [Core]
  | CTagEq Int Int Core
  | CProj Int Core
  | CErr String
  deriving (Show, Eq)

type Prog = M.Map Name ([Name], Core)

--------------------------------------------------------------------------------
-- Lexer
--------------------------------------------------------------------------------

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
reserved = ["fn", "case", "of", "Type", "Sig", "Struct", "use"]

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
integer = lexeme L.decimal

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
-- F64 splices as f64frombits hi lo (a tagged V carries 62 payload
-- bits, not 64); F32 fits one tagged Int, so it takes f32frombits.
floatLit :: P SExpr
floatLit = try $ do
  ipart <- some digitChar
  frac <- optional (try (char '.' *> some digitChar))
  ex <- optional (try ((:) <$> oneOf ("eE" :: String) <*> ((++) <$> (maybe "" pure <$> optional (oneOf ("+-" :: String))) <*> some digitChar)))
  suf <- optional (oneOf ("fFdD" :: String) <* notFollowedBy (satisfy (\c -> isAlphaNum c || c == '_')))
  sc
  let isF32 = suf `elem` [Just 'f', Just 'F']
      txt = ipart ++ maybe "" ('.' :) frac ++ maybe "" id ex
  -- an unsuffixed whole number with no fraction/exponent is an Int:
  -- this parser runs BEFORE `integer`, so it must decline those
  when (frac == Nothing && ex == Nothing && suf == Nothing) (fail "integer")
  let d = read (if frac == Nothing then ipart ++ ".0" ++ maybe "" id ex else txt) :: Double
  pure $
    if isF32
      then SApp (SVar "f32frombits") (SInt (fromIntegral (castFloatToWord32 (realToFrac d))))
      else
        let bits = castDoubleToWord64 d
         in SApp (SApp (SVar "f64frombits") (SInt (fromIntegral (bits `shiftR` 32))))
              (SInt (fromIntegral (bits Data.Bits..&. 0xFFFFFFFF)))

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

--------------------------------------------------------------------------------
-- Expression parser
--------------------------------------------------------------------------------

expr :: P SExpr
expr = lamE <|> opExpr
  where
    lamE = do
      keyword "fn" -- word-boundary: `fnv1a ...` is an application, not a lambda
      ps <- some lowerName
      _ <- symbol "->"
      SLam ps <$> block -- bindings allowed, same block form as arms

opExpr :: P SExpr
opExpr = dollarChain
  where
    dollarChain = do
      a <- pipeChain
      option a (symbol "$" *> (SApp a <$> dollarChain))

    pipeChain = chainl1' pipeOperand pipeOp
    pipeOperand =
      ( do
          keyword "fn"
          ps <- some lowerName
          _ <- symbol "->"
          SLam ps <$> expr
      )
        <|> orLayer
    pipeOp =
      choice
        [ SBin "|>?" <$ try (symbol "|>?"),
          SBin "|>" <$ try (symbol "|>"),
          SBin ">>" <$ try (lexeme (string ">>" <* notFollowedBy (char '=')))
        ]

    orLayer = chainl1' andLayer (SBin "or" <$ keyword "or")

    andLayer = chainl1' cmpLayer (SBin "and" <$ keyword "and")

    cmpLayer = chainl1' consLayer cmpOp
    cmpOp =
      choice
        [ SBin "==" <$ try (symbol "=="),
          SBin "!=" <$ try (symbol "!="),
          SBin "<=" <$ try (symbol "<="),
          SBin ">=" <$ try (symbol ">="),
          SBin "<" <$ try (lexeme (char '<' <* notFollowedBy (oneOf "="))),
          SBin ">" <$ try (lexeme (char '>' <* notFollowedBy (oneOf ">=")))
        ]

    consLayer = do
      a <- addLayer
      option a (try (symbol "::") *> (SBin "::" a <$> consLayer))

    addLayer = chainl1' mulLayer addOp
    addOp =
      choice
        [ SBin "+" <$ try (symbol "+"),
          SBin "-" <$ try (lexeme (char '-' <* notFollowedBy (char '>')))
        ]

    mulLayer = chainl1' powLayer mulOp
    mulOp =
      choice
        [ SBin "*" <$ symbol "*",
          SBin "/" <$ symbol "/",
          SBin "%" <$ symbol "%"
        ]

    -- `^` binds tighter than * / % and is RIGHT-associative: 2 ^ 3 ^ 2 = 2 ^ 9
    powLayer = do
      a <- bangLayer
      option a (symbol "^" *> (SBin "^" a <$> powLayer))

    bangLayer = chainl1' btLayer bangOp
    bangOp = SBin "!" <$ try (lexeme (char '!' <* notFollowedBy (char '=')))

    btLayer = chainl1' appLayer btOp
    btOp =
      (\f a b -> SApp (SApp (SVar f) a) b)
        <$> try (lexeme (char '`' *> ident' <* char '`'))
      where
        ident' = (:) <$> satisfy isLower <*> takeWhileP Nothing identChar

    appLayer = do
      f <- term
      as <- many (notFollowedBy boolOp *> term)
      pure (foldl' SApp f as)
      where
        boolOp = keyword "and" <|> keyword "or"

chainl1' :: P a -> P (a -> a -> a) -> P a
chainl1' p op = p >>= rest
  where
    rest a = (do f <- op; b <- p; rest (f a b)) <|> pure a

-- TIGHT MINUS is a literal: '-' immediately followed by a digit (no
-- space) negates the numeral -- `-1`, `-2.5`, `-1e3f`.  A SPACED
-- minus is untouched: `a - 1` is subtraction (the binary layer wins
-- wherever a left operand exists), and only `f -1`-style application
-- arguments change meaning -- the corpus had zero code uses of that
-- spelling.  Floats negate by flipping the IEEE sign bit inside the
-- already-desugared frombits splice.
negLit :: P SExpr
negLit = try $ do
  _ <- char '-'
  e <- floatLit <|> (SInt <$> integer)
  pure $ case e of
    SInt n -> SInt (negate n)
    SApp (SApp v@(SVar "f64frombits") (SInt hi)) lo ->
      SApp (SApp v (SInt (hi `xor` 0x80000000))) lo
    SApp v@(SVar "f32frombits") (SInt b) -> SApp v (SInt (b `xor` 0x80000000))
    other -> other

term :: P SExpr
term =
  choice
    [ negLit,
      try floatLit,
      SInt <$> integer,
      holeLit,
      atomLit,
      pathLit,
      stringLit,
      caseE,
      listLit,
      recordish,
      parensOrTuple,
      SVar <$> upperName,
      varOrProj
    ]

-- ?name / ?? — typed holes.  Parsed as the shape
--   SApp (SVar "?hole") (SStrI [SegStr name])     (name = "" for ??)
-- so every downstream pass handles them generically.  Semantics live
-- in Infer: NAMED holes typecheck the rest of the program and then
-- refuse to compile, reporting the hole's inferred type; ?? elaborates
-- to a runtime trap, so the pipeline BEFORE it still runs.
holeLit :: P SExpr
holeLit = try $ do
  _ <- char '?'
  n <- (lexeme (char '?') >> pure "") <|> lowerNameRaw
  pure (SApp (SVar "?hole") (SStrI [SegStr n]))

-- @/tmp/x.txt — sol's path literal, admitted into the shared grammar
-- as (Path "…"): structurally identical to sol's SPath desugar
-- (CApp (CVar "Path") (CStr p)), so the HostedBytecode pipeline sees
-- the value it always saw; the AOT profiles see an ordinary
-- constructor application (honest "Path is not defined" if unused
-- there).  Same trailing-dot rule as dotTerm.
pathLit :: P SExpr
pathLit = lexeme . try $ do
  _ <- char '@'
  p <- some pathElem
  pure (SApp (SVar "Path") (SStrI [SegStr p]))
  where
    pathOk c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c `elem` "./_-~"
    pathElem =
      satisfy (\c -> pathOk c && c /= '.')
        <|> try (char '.' <* lookAhead (satisfy pathOk))

atomLit :: P SExpr
atomLit = lexeme . try $ do
  _ <- char ':'
  s <- (:) <$> satisfy isLower <*> takeWhileP Nothing identChar
  pure (SAtom s)

varOrProj :: P SExpr
varOrProj = try $ do
  segs <- dottedIdent
  case segs of
    [s] | isLower (head s) -> pure (SVar s)
    (s : rest) | isLower (head s) -> pure (SProj (SVar s) rest)
    _ -> fail "not a lowercase name"

parensOrTuple :: P SExpr
parensOrTuple = parens $ do
  e <- expr
  es <- many (symbol "," *> expr)
  pure $ if null es then e else STup (e : es)

listLit :: P SExpr
listLit = SList <$> brackets (expr `sepBy` symbol ",")

recordish :: P SExpr
recordish = braces (try litRec <|> updRec)
  where
    litRec = SRec <$> (fieldAssign `sepBy1` symbol ",")
    fieldAssign = do n <- pName; eqSign; (n,) <$> expr
    updRec = do
      m <- expr
      pipeSep
      as <- pathAssign `sepBy1` symbol ","
      pure (SUpd m as)
    pathAssign = do
      path <- dottedIdent
      eqSign
      (path,) <$> expr

caseE :: P SExpr
caseE = do
  _ <- symbol "case"
  scrut <- expr
  _ <- symbol "of"
  arms <- arm `sepBy1` pipeSep
  pure (SCase scrut arms)
  where
    -- arm bodies take the BLOCK form: bindings then a final
    -- expression, exactly like a clause body.  The block is
    -- self-delimiting (every stmt ends in ';' behind a try), so the
    -- arm still stops cleanly at '|' or the clause terminator --
    -- the doX/doX2 helper-splitting idiom is retired.
    arm = do p <- pattern'; _ <- symbol "->"; o <- getOffset; b <- block; pure (p, SMark o b)

stringLit :: P SExpr
stringLit = lexeme $ do
  _ <- char '"'
  segs <- manyTill seg (char '"')
  pure (SStrI (mergeSegs segs))
  where
    seg =
      choice
        [ SegExpr <$> (char '{' *> sc *> expr <* char '}'),
          SegStr . pure <$> (char '\\' *> escaped),
          -- A LITERAL source character is TEXT: encode it to UTF-8
          -- bytes here, at the one place that knows it came from the
          -- file rather than from a \xHH escape. FP-RISC strings are
          -- BYTE strings (strlen counts bytes, charAt returns bytes),
          -- so 'e-acute' becomes two chars and a wire escape stays one.
          -- Doing this later is impossible: by then 0xB7 could equally
          -- be a middle dot or an SPI payload byte, and guessing gets
          -- one of them wrong (it got '·' wrong, and served invalid
          -- UTF-8 to the browser).
          SegStr . utf8Bytes . pure <$> satisfy (\c -> c /= '"' && c /= '{' && c /= '\\')
        ]
    escaped =
      choice
        [ '\n' <$ char 'n',
          '\t' <$ char 't',
          '\r' <$ char 'r',
          '\0' <$ char '0',
          '{' <$ char '{',
          '}' <$ char '}',
          '"' <$ char '"',
          '\\' <$ char '\\',
          -- \xHH: raw byte escapes, because a HAL wants "\x01\x02" SPI
          -- payloads without a bytes-literal syntax detour
          char 'x' *> (toEnum . fromIntegral <$> hexByte)
        ]
    hexByte = do
      a <- hexDigitChar
      b <- hexDigitChar
      pure (16 * hval a + hval b :: Integer)
    hval c
      | c >= '0' && c <= '9' = fromIntegral (fromEnum c - fromEnum '0')
      | c >= 'a' && c <= 'f' = fromIntegral (fromEnum c - fromEnum 'a' + 10)
      | otherwise = fromIntegral (fromEnum c - fromEnum 'A' + 10)
    utf8Bytes :: String -> String
    utf8Bytes = concatMap enc
      where
        enc c
          | v < 0x80 = [c]
          | v < 0x800 = map toEnum [0xC0 + div v 64, 0x80 + mod v 64]
          | v < 0x10000 = map toEnum [0xE0 + div v 4096, 0x80 + mod (div v 64) 64, 0x80 + mod v 64]
          | otherwise = map toEnum [0xF0 + div v 262144, 0x80 + mod (div v 4096) 64, 0x80 + mod (div v 64) 64, 0x80 + mod v 64]
          where v = fromEnum c
    mergeSegs (SegStr a : SegStr b : r) = mergeSegs (SegStr (a ++ b) : r)
    mergeSegs (x : r) = x : mergeSegs r
    mergeSegs [] = []

--------------------------------------------------------------------------------
-- Patterns
--------------------------------------------------------------------------------

pattern' :: P SPat
pattern' = do
  p <- patApp
  option p (try (symbol "::") *> (PCon "Cons" . (p :) . pure <$> pattern'))

patApp :: P SPat
patApp =
  choice
    [ do c <- upperName; args <- many patAtom; pure (PCon c args),
      patAtom
    ]

patAtom :: P SPat
patAtom =
  choice
    [ PWild <$ symbol "_",
      PInt <$> integer,
      strPat,
      listPat,
      PRec <$> braces (lowerName `sepBy1` symbol ","),
      parens patInParens,
      flip PCon [] <$> upperName,
      PVar <$> lowerName
    ]
  where
    listPat = do
      ps <- between (symbol "[") (symbol "]") (pattern' `sepBy` symbol ",")
      pure (foldr (\p acc -> PCon "Cons" [p, acc]) (PCon "Nil" []) ps)
    strPat = lexeme $ do
      _ <- char '"'
      s <- manyTill (satisfy (/= '"')) (char '"')
      pure (PStr s)
    patInParens = try sigParam <|> tupleOrOne
    sigParam = do
      n <- lowerName
      _ <- lexeme (char ':' <* notFollowedBy (char ':'))
      PSig n <$> upperName
    tupleOrOne = do
      p <- pattern'
      ps <- many (symbol "," *> pattern')
      pure $ if null ps then p else PTup (p : ps)

--------------------------------------------------------------------------------
-- Top level
--------------------------------------------------------------------------------

program :: P [STop]
program = sc *> many topDecl <* eof

topDecl :: P STop
topDecl =
  choice
    [ try unsafeModuleDecl,
      evalDecl,
      sigDecl,
      structDecl,
      try typeDecl,
      try shapeAlias,
      try useDecl,
      try otherAlias,
      try signature,
      binding
    ]

-- `unsafe program.` / `unsafe module.` — the blanket safety marker.
-- Yesterday's 75 signatures carried zero information: the compiler
-- printed every one itself.  This pragma marks EVERY function in the
-- file unsafe at once (represented as a TSig for the reserved name
-- "$module" carrying the $unsafe marker, so Safety.hs needs no new
-- plumbing).  Per-function sigs remain the STRICT mode: a module
-- packaged under std.* is REFUSED with this pragma (core-only) --
-- library code must state its safe/unsafe line per function.
unsafeModuleDecl :: P STop
unsafeModuleDecl = do
  _ <- lexeme (string "unsafe" <* notFollowedBy (satisfy identChar))
  _ <- lexeme ((string "program" <|> string "module") <* notFollowedBy (satisfy identChar))
  dotTerm
  pure (TSig "$module" ([], TCon "Unit" []) [Just ("$unsafe", SVar "$unsafe")])

-- `> expr.` — a top-level effect statement.  Parsed unconditionally so
-- the surface is ONE grammar; whether the profile ACCEPTS it is the
-- driver's decision (--sol / .sol input = the HostedBytecode view).
evalDecl :: P STop
evalDecl = do
  _ <- try (lexeme (char '>' <* notFollowedBy (oneOf ">=")))
  e <- block
  dotTerm
  pure (TEval e)

-- ---- aritySpill: the >64 extension over the native wide convention ----
-- The ABI carries 64 arguments natively: 8 registers + 56 per-hart
-- argspill cells (fpr.h / Codegen.hs compileFn -- tail-call-safe and
-- preemption-safe by construction, no heap traffic).  Historically >8
-- field-packing by hand (lksc = sc*16384 + lk) or a bespoke wide
-- constructor.  This pass spills instead: a >8-parameter function
-- keeps its first 7 parameters and takes the rest as ONE tuple
-- (Tup2..Tup8 exist since codegenRev 5), destructured as the body's
-- first statement; every saturated call site packs the same way.
-- Costs one heap tuple per call to a wide function -- exactly the
-- "indirection on the rare wide call" trade.  Limits, stated honestly:
-- clause GUARDS may not reference spilled parameters (the destructure
-- runs after guard selection; such a function is reported and left for
-- a manual wide constructor), and only SATURATED call sites rewrite
-- (partial application of a wide function was impossible before this
-- pass and remains so).  Max spilled arity: 7 + 8 = 15.
aritySpill :: [STop] -> ([STop], [String])
aritySpill tops = (map top tops, notes)
  where
    -- the NATIVE convention (8 regs + 56 hart argspill cells,
    -- Codegen.hs/fpr.h) carries arity <= 64 with no restrictions --
    -- this pass is only the >64 extension: keep 63 params + ONE
    -- spilled tuple (Tup2..Tup8), honest cap 63+8 = 71.
    natCeil = 64
    keepN = natCeil - 1
    wide = M.fromList [(n, length ps) | TBind n ps _ _ <- tops,
                       length ps > natCeil, length ps <= keepN + 8]
    tooWide = [n | TBind n ps _ _ <- tops, length ps > keepN + 8]
    guardy = [n | TBind n ps gs _ <- tops, length ps > natCeil,
                  any (refG (spilledNames ps)) gs]
    spillable = M.filterWithKey (\n _ -> n `notElem` guardy) wide
    notes =
      ["aritySpill: " ++ n ++ ": " ++ show a ++ " params -> " ++ show keepN ++ " + spilled tuple"
        | (n, a) <- M.toList spillable]
      ++ ["aritySpill: " ++ n ++ ": guards reference spilled params -- NOT spilled (use a constructor)"
           | n <- guardy]
      ++ ["aritySpill: " ++ n ++ ": more than " ++ show (keepN + 8) ++ " params -- NOT spilled (use a constructor)"
           | n <- tooWide]
    spilledNames ps = [v | PVar v <- drop keepN ps]
    refG vs (GBool e) = any (\v -> refE' v e) vs
    refG vs (GPat _ e) = any (\v -> refE' v e) vs
    refE' v e = case e of
      SMark _ e' -> refE' v e'
      SVar x -> x == v
      SApp a b -> refE' v a || refE' v b
      SLam _ b -> refE' v b
      SBlock ss fin -> any (refE' v) (concatMap es ss) || refE' v fin
      SCase sc arms -> refE' v sc || any (refE' v . snd) arms
      SBin _ a b -> refE' v a || refE' v b
      SProj a _ -> refE' v a
      STup xs -> any (refE' v) xs
      SList xs -> any (refE' v) xs
      SRec fs -> any (refE' v . snd) fs
      SUpd a us -> refE' v a || any (refE' v . snd) us
      SStrI segs -> or [refE' v e' | SegExpr e' <- segs]
      _ -> False
      where es (SBind _ _ x) = [x]
            es (SBindPat _ x) = [x]
    spillVar n = "_spill_" ++ n
    top (TBind n ps gs b)
      | Just _ <- M.lookup n spillable =
          let kept = take keepN ps
              rest = drop keepN ps
              b' = SBlock [SBindPat (PTup rest) (SVar (spillVar n))] (goE b)
              b'' = case goE b of
                SBlock ss fin -> SBlock (SBindPat (PTup rest) (SVar (spillVar n)) : ss) fin
                other -> b' `seq` SBlock [SBindPat (PTup rest) (SVar (spillVar n))] other
           in TBind n (kept ++ [PVar (spillVar n)]) gs b''
    top (TBind n ps gs b) = TBind n ps gs (goE b)
    top t = t
    -- call sites: rewrite saturated applications of spillable functions
    goE e = case unspine e of
      (SVar n, args)
        | Just a <- M.lookup n spillable, length args == a ->
            respine (SVar n) (map goE (take keepN args) ++ [STup (map goE (drop keepN args))])
      _ -> descend e
    unspine (SApp f a) = let (h, as) = unspine f in (h, as ++ [a])
    unspine e = (e, [])
    respine h = foldl SApp h
    descend e = case e of
      SMark o a -> SMark o (goE a)
      SApp a b -> SApp (goE a) (goE b)
      SLam x b -> SLam x (goE b)
      SBlock ss fin -> SBlock (map stmt ss) (goE fin)
      SCase sc arms -> SCase (goE sc) [(p, goE x) | (p, x) <- arms]
      SBin o a b -> SBin o (goE a) (goE b)
      SProj a f' -> SProj (goE a) f'
      STup xs -> STup (map goE xs)
      SList xs -> SList (map goE xs)
      SRec fs -> SRec [(f', goE x) | (f', x) <- fs]
      SUpd a us -> SUpd (goE a) [(f', goE x) | (f', x) <- us]
      SStrI segs -> SStrI (map seg segs)
      _ -> e
      where
        stmt (SBind x xs rhs) = SBind x xs (goE rhs)
        stmt (SBindPat p rhs) = SBindPat p (goE rhs)
        seg (SegExpr x) = SegExpr (goE x)
        seg s = s

-- ---- autodrop: compiler-inserted drops on receive paths ---------------
-- THE LAW (docs/MEMORY.md): every received message root is dropped once
-- read.  Every leak in the qosp campaign was a missed manual drop.  This
-- pass discharges the common shapes mechanically:
--
--   shape 1   m = receive me; (a, b) = m; ...      drop after destructure
--   shape 2   m = receive me; case m of ...        drop at each arm start
--   shape 3   m = <receive-origin>; <borrow uses>  drop after the LAST use
--             (v2: the general shape -- covers the rpc-helper idiom
--              `r = rpc svc msg; k = case r of ...; ...` that every
--              client used to discharge by hand)
--
-- RECEIVE-ORIGIN (v2) is TRANSITIVE: a fixpoint over the program marks
-- every function whose result position IS the message root -- receive/
-- receiveFrom/receiveRes themselves, then anything that tail-returns
-- one (mvu's svcCall, std.uart's rpc, svc.fpr's storeRpc), then
-- anything that tail-returns THOSE.  The old hardcoded name list
-- ("ask", "svcCall") survives only as extra seeds.
--
-- Shape 3 inserts ONLY when every use of m is BORROW-SHAPED: a case
-- scrutinee, a destructure source, or a direct argument to a borrowing
-- builtin (send deep-copies; the string prims read).  A bare m in any
-- other context -- returned, tupled up, captured under a lambda,
-- passed whole to a user function -- blocks insertion, as does an
-- explicit `drop m` anywhere.  Conservative and reported, never
-- silently wrong; the early-drop placement is SOUND because the
-- runtime defers the slab release to this actor's next receive
-- (fpr_drop_park), where copy-on-retain says every borrow is dead.
autoDrop :: [STop] -> ([STop], [String])
autoDrop tops = (tops', concat notess)
  where
    -- the transitive receive-origin set: name -> all clause bodies;
    -- a name joins when EVERY clause's result position resolves to a
    -- known origin (through blocks, and through cases whose arms all
    -- qualify).  Monotone, bounded by the name count.
    clauseBodies = M.fromListWith (++) [(n, [b]) | TBind n _ _ b <- tops]
    originSeeds = S.fromList ["receive", "receiveFrom", "receiveRes", "ask", "svcCall"]
    origins = fixOrigins originSeeds
    fixOrigins known =
      let step = S.fromList
            [ nm | (nm, bs) <- M.toList clauseBodies,
                   not (S.member nm known),
                   all (resultIsOrigin known) bs ]
       in if S.null step then known else fixOrigins (S.union known step)
    resultIsOrigin known e = case e of
      SMark _ e' -> resultIsOrigin known e'
      SBlock _ fin -> resultIsOrigin known fin
      SCase _ arms -> not (null arms) && all (resultIsOrigin known . snd) arms
      _ -> case adHeadName e of
        Just h -> S.member h known
        Nothing -> False
    (tops', notess) = unzip (map top tops)
    top (TBind n ps gs b) = let (b', ns) = goE n b in (TBind n ps gs b', ns)
    top t = (t, [])
    goE n e = case e of
      SBlock ss fin -> let (ss', fin', ns) = goStmts n ss fin in (SBlock ss' fin', ns)
      _ -> (e, [])
    -- shape 1: destructure-next-statement.  The inserted drop precedes
    -- later uses of the pattern's children -- SOUND because the runtime
    -- defers the slab's release to this actor's next receive
    -- (fpr_drop_park), where copy-on-retain says every borrow is dead.
    goStmts n (SBind m [] rhs : rest) fin
      | isReceive rhs,
        (SBindPat p rhsP : after) <- rest,
        SVar m' <- unmark rhsP,
        m' == m,
        not (refStmts m after || refE m fin),
        not (droppedIn m rest fin) =
          let (after', fin', ns) = goStmts n after fin
           in ( SBind m [] rhs
                  : SBindPat p (SVar m)
                  : SBind ("_autodrop_" ++ m) [] (SApp (SVar "drop") (SVar m))
                  : after',
                fin',
                ("autodrop: " ++ n ++ ": inserted `drop " ++ m ++ "` after destructure") : ns )
    -- shape 2: the case-scrutinee actor loop --
    --     m = receive me;            m = receive me;
    --     case m of              =>  case m of
    --       C a b -> body              C a b -> _autodrop_m = drop m; body
    -- -- the storage-actor shape (mods/qlog's aLoop), which leaked one
    -- Arc entry per request when the drop stayed manual and forgotten.
    -- Same deferral argument as shape 1; an arm whose pattern rebinds m
    -- (shadowing) or whose body still references m blocks insertion.
    goStmts n (SBind m [] rhs : rest) fin
      | isReceive rhs,
        not (refStmts m rest),
        SCase (SVar m') arms <- fin,
        m' == m,
        not (any (\(pt, b) -> m `elem` patVars pt || refE m b) arms),
        not (droppedIn m rest fin) =
          ( SBind m [] rhs : rest,
            SCase (SVar m) [(pt, dropInto m b) | (pt, b) <- arms],
            [ "autodrop: " ++ n ++ ": inserted `drop " ++ m ++ "` into "
                ++ show (length arms) ++ " case arm(s)" ] )
    -- shape 3 (v2): the general last-use drop.  Applies when shapes 1
    -- and 2 declined but every use of m is borrow-shaped and m does
    -- not reach the block's final expression.
    goStmts n (SBind m [] rhs : rest) fin
      | isReceive rhs,
        not (droppedIn m rest fin),
        not (refE m fin),
        all (okUse m) rest =
          let (rest', fin', ns) = goStmts n rest fin
              lastUse = maximum (0 : [i | (i, st) <- zip [1 ..] rest', any (refE m) (stmtEs st)])
              (pre, post) = splitAt lastUse rest'
              d = SBind ("_autodrop_" ++ m) [] (SApp (SVar "drop") (SVar m))
           in ( SBind m [] rhs : pre ++ d : post,
                fin',
                ("autodrop: " ++ n ++ ": inserted `drop " ++ m ++ "` after its last use") : ns )
    goStmts n (st : rest) fin =
      let (rest', fin', ns) = goStmts n rest fin in (st : rest', fin', ns)
    goStmts _ [] fin = ([], fin, [])
    -- borrow-shaped uses of m within one statement: the destructure
    -- statement itself, a case scrutinee (arms checked recursively),
    -- or a DIRECT argument of a borrowing builtin.  Anything else
    -- containing a bare m refuses shape 3.
    okUse m (SBindPat _ rhsP) | SVar x <- unmark rhsP, x == m = True
    okUse m st = all (okE m) (stmtEs st)
    okE m e = case e of
      SMark _ e' -> okE m e'
      SVar x -> x /= m
      SCase (SVar x) arms | x == m -> all (okE m . snd) arms
      _ | (SVar h, as@(_ : _)) <- adSpine e [],
          h `elem` ["send", "print", "strlen", "strcat", "charAt", "substr", "chr"] ->
            all (\x -> case x of SVar _ -> True; _ -> okE m x) as
      SApp a b -> okE m a && okE m b
      SLam _ b -> not (refE m b) -- capture: lifetime unknown, refuse
      SBlock ss f -> all (okUse m) ss && okE m f
      SCase sc arms -> okE m sc && all (okE m . snd) arms
      SBin _ a b -> okE m a && okE m b
      SProj a _ -> okE m a
      SRec fs -> all (okE m . snd) fs
      SUpd a us -> okE m a && all (okE m . snd) us
      STup es -> all (okE m) es
      SList es -> all (okE m) es
      SStrI segs -> and [okE m e' | SegExpr e' <- segs]
      _ -> True
    adSpine (SMark _ e) acc = adSpine e acc
    adSpine (SApp f a) acc = adSpine f (a : acc)
    adSpine e acc = (e, acc)
    dropInto m b =
      let d = SBind ("_autodrop_" ++ m) [] (SApp (SVar "drop") (SVar m))
       in case b of
            SBlock ss f -> SBlock (d : ss) f
            e -> SBlock [d] e
    patVars pt = case pt of
      PVar v -> [v]
      PCon _ ps -> concatMap patVars ps
      PTup ps -> concatMap patVars ps
      PRec ns -> ns
      PSig v _ -> [v]
      _ -> []
    isReceive e = case adHeadName e of
      Just n -> S.member n origins
      Nothing -> False
    droppedIn m ss fin = any isDropM (concatMap stmtEs ss ++ [fin])
      where
        isDropM e = case e of
          SApp (SVar "drop") (SVar x) | x == m -> True
          _ -> anySub isDropM e
    stmtEs (SBind _ _ e) = [e]
    stmtEs (SBindPat _ e) = [e]
    refStmts m = any (\st -> any (refE m) (stmtEs st))
    refE m e = case e of
      SVar x -> x == m
      _ -> anySub (refE m) e
    anySub f e = case e of
      SMark _ a -> f a
      SApp a b -> f a || f b
      SLam _ b -> f b
      SBlock ss fin -> any f (concatMap stmtEs ss) || f fin
      SCase sc arms -> f sc || any (f . snd) arms
      SBin _ a b -> f a || f b
      SProj a _ -> f a
      SRec fs -> any (f . snd) fs
      SUpd a us -> f a || any (f . snd) us
      STup es -> any f es
      SList es -> any f es
      SStrI segs -> or [f e' | SegExpr e' <- segs]
      _ -> False

adHeadName :: SExpr -> Maybe Name
adHeadName (SMark _ e) = adHeadName e
adHeadName (SVar n) = Just n
adHeadName (SApp f _) = adHeadName f
adHeadName _ = Nothing

-- fold the `> e.` statements into a synthesized `main` (a block whose
-- statements bind throwaways, last one is the result).  An explicit
-- `main` alongside `>` statements is a conflict, reported by Main.
desugarEvals :: [STop] -> ([STop], Int)
desugarEvals tops =
  let evs = [e | TEval e <- tops]
      rest = [t | t <- tops, notEval t]
      notEval (TEval _) = False
      notEval _ = True
   in case evs of
        [] -> (tops, 0)
        _ ->
          let stmts = [SBind ("_top" ++ show i) [] e | (i, e) <- zip [(1 :: Int) ..] (init evs)]
              mainB = TBind "main" [] [] (SBlock stmts (last evs))
           in (rest ++ [mainB], length evs)

keyword :: String -> P ()
keyword w = lexeme . try $ void (string w <* notFollowedBy (satisfy identChar))

-- `Functor = Sig { map : (a -> b) -> t a -> t b }.`  (a named row)
sigDecl :: P STop
sigDecl = try $ do
  n <- upperName
  eqSign
  keyword "Sig"
  fs <- braces (sigField `sepBy1` symbol ",")
  dotTerm
  pure (TSigDef n fs)
  where
    sigField = do
      f <- pName
      mt <- optional (lexeme (char ':') *> (foldr1 TArrT <$> tyApp `sepBy1` symbol "->"))
      pure (f, mt)

-- `Numeric = Struct Arith { add = fn a b -> a + b, zero = 0 }.`
structDecl :: P STop
structDecl = try $ do
  n <- upperName
  eqSign
  keyword "Struct"
  sigs <- many upperName
  fs <- braces (fieldAssign `sepBy1` symbol ",")
  dotTerm
  pure (TStruct n sigs fs)
  where
    fieldAssign = do f <- pName; eqSign; (f,) <$> expr

-- MyMod = use "MyMod#4f2a...".   The spec is a plain (uninterpolated)
-- string: module name, optionally #-pinned to an AST hash.  Resolution,
-- hashing, and namespace splicing happen in Modules.hs at compile time.
useDecl :: P STop
useDecl = do
  a <- upperName <|> lowerNameRaw -- sol writes lowercase aliases (`std = use "..."`)
  eqSign
  _ <- lexeme (try (string "use" <* notFollowedBy (satisfy identChar)))
  spec <- rawString
  dotTerm
  pure (TUse a spec)

rawString :: P String
rawString = lexeme (char '"' *> manyTill (satisfy (/= '"')) (char '"'))

signature :: P STop
signature = do
  n <- (pName <|> upperName <|> lowerNameRaw)
  _ <- lexeme (char ':' <* notFollowedBy (char ':'))
  try (fullSig n) <|> (skipTillDot >> pure TSkip)
  where
    fullSig n = do
      mu <- optional (try (lexeme (string "unsafe" <* notFollowedBy (satisfy identChar))))
      parts <- sigPart `sepBy1` symbol "->"
      dotTerm
      let mark = case mu of Just _ -> [Just ("$unsafe", SVar "$unsafe")]; Nothing -> []
      case parts of
        [] -> fail "empty signature"
        -- the $unsafe marker is APPENDED so the per-param precondition
        -- list stays position-aligned (consumers zip with params)
        ps -> pure (TSig n (map fst (init ps), fst (last ps)) (map snd (init ps) ++ mark))
    -- a signature part is a type, optionally precondition-annotated:
    --   (b : Int | b != 0)   -- name the param, constrain its value
    sigPart =
      try preParam <|> ((,Nothing) <$> tyApp)
    preParam = parens $ do
      v <- lowerName
      _ <- lexeme (char ':' <* notFollowedBy (char ':'))
      t <- tyApp
      -- the precondition is optional: `(s : Add)` names a sig-carrier
      -- param in a signature (typed.fpr style) without constraining it
      mp <- optional (pipeSep *> expr)
      pure (t, (\p -> (v, p)) <$> mp)

tyApp :: P Ty
tyApp = do
  atoms <- some tyAtom
  pure $ case atoms of
    [t] -> t
    (TCon n [] : args) -> TCon n args
    (TVarT n : args) -> TVApp n args
    _ -> TOther

tyAtom :: P Ty
tyAtom =
  choice
    [ parens tyParenBody,
      -- module-qualified type names (logic.PT) -- spliced aliases keep
      -- their qualifier, and unsafe-sig suggestions print them
      try (do m <- lowerNameRaw; _ <- char '.'; u <- upperName; pure (TCon (m ++ "." ++ u) [])),
      flip TCon [] <$> upperName,
      TOther <$ lexeme (char '_' <* notFollowedBy (satisfy identChar)),
      try (do _ <- char '?'; _ <- char '?'; sc; pure (TCon "??" [])),
      try (do _ <- char '?'; n <- lowerNameRaw; pure (TCon ("?" ++ n) [])),
      TVarT <$> lowerName
    ]
  where
    -- inside parens: a possibly-arrowed, possibly-tupled type
    tyParenBody = do
      -- each tuple element is a full arrow-chain, so types like
      -- (a, (b, c) -> List d) round-trip (the unsafe-sig printer
      -- emits them)
      ts <- tyArrowChain `sepBy1` symbol ","
      pure $ case ts of [t] -> t; _ -> TTup ts
    tyArrowChain = do
      t <- tyApp
      arrows <- many (try (symbol "->") *> tyApp)
      pure (foldr1 TArrT (t : arrows))

skipTillDot :: P ()
skipTillDot = void (skipManyTill anySingle dotTerm)

typeDecl :: P STop
typeDecl = do
  n <- upperName
  mult <- optional integer
  params <- many lowerName
  eqSign
  _ <- symbol "Type"
  cons <-
    parens (conDecl `sepBy1` pipeSep)
      <|> newtypeCon n
  dotTerm
  pure (TType n (mult == Just 1) params cons)
  where
    conDecl = do
      c <- upperName
      args <- many tyAtom
      pure (c, args)
    newtypeCon n = do
      args <- some tyAtom
      pure [(n, args)]

shapeAlias :: P STop
shapeAlias = do
  n <- upperName
  eqSign
  fs <- braces (fieldDecl `sepBy1` symbol ",")
  dotTerm
  pure (TShape n fs)
  where
    fieldDecl = do
      f <- pName
      _ <- lexeme (char ':')
      t <- foldr1 TArrT <$> tyApp `sepBy1` symbol "->"
      pure (f, t)

otherAlias :: P STop
otherAlias = do
  a <- upperName
  eqSign
  b <- qualTarget
  dotTerm
  pure (TAlias a b)
  where
    qualTarget =
      try
        ( do
            m <- lowerNameNoWs
            _ <- char '.'
            t <- upperName
            pure (m ++ "." ++ t)
        )
        <|> upperName
    lowerNameNoWs = do
      c <- satisfy (\ch -> ch >= 'a' && ch <= 'z')
      rest <- many (satisfy identChar)
      pure (c : rest)

binding :: P STop
binding = do
  n <- pName
  pats <- many patAtom
  g <- option [] (pipeSep *> guardItem `sepBy1` symbol ",")
  eqSign
  body <- block
  dotTerm
  pure (TBind n pats g body)

-- `pat <- expr` (pattern-match binding) or a boolean condition
guardItem :: P SGuard
guardItem =
  try (GPat <$> pattern' <* symbol "<-" <*> expr)
    <|> (GBool <$> expr)

block :: P SExpr
block = do
  stmts <- many (try stmt)
  e <- expr
  pure $ if null stmts then e else SBlock stmts e
  where
    stmt = try nameStmt <|> patStmt
    nameStmt = do
      n <- pName
      ps <- many lowerName
      eqSign
      o <- getOffset
      e <- expr
      _ <- symbol ";"
      pure (SBind n ps (SMark o e))
    patStmt = do
      p <- pattern'
      eqSign
      o <- getOffset
      e <- expr
      _ <- symbol ";"
      pure (SBindPat p (SMark o e))

--------------------------------------------------------------------------------
-- Desugaring
--------------------------------------------------------------------------------

data DEnv = DEnv
  { dFresh :: Int,
    dCons :: M.Map Name (Int, Int, Int),
    dShapes :: M.Map [Name] Int,
    dLifted :: [(Name, [Name], Core)]
  }

type D = Control.Monad.State.Strict.State DEnv

fresh :: String -> D Name
fresh pre = do
  s <- get
  put s {dFresh = dFresh s + 1}
  pure (pre ++ "_" ++ show (dFresh s))

builtinCons :: M.Map Name (Int, Int, Int)
builtinCons =
  M.fromList
    [ ("Unit", (0, 0, 0)),
      ("False", (1, 0, 0)),
      ("True", (1, 1, 0)),
      ("Nil", (2, 0, 0)),
      ("Cons", (2, 1, 2)),
      ("Ok", (3, 0, 1)),
      ("Err", (3, 1, 1)),
      ("Tup2", (4, 0, 2)),
      ("Tup3", (5, 0, 3)),
      -- wide tuples: tids 10..14 (fpr.h T_TUP4..T_TUP8).  Capped at 8
      -- to match call arity's register span; wider anonymous data
      -- should be a record or a declared constructor.
      ("Tup4", (10, 0, 4)),
      ("Tup5", (11, 0, 5)),
      ("Tup6", (12, 0, 6)),
      ("Tup7", (13, 0, 7)),
      ("Tup8", (14, 0, 8))
    ]

boolT, listT, atomT :: Int
boolT = 1
listT = 2
atomT = 6

-- CONTENT-ADDRESSED typeids (separate compilation): a type's id is a
-- function of (owning unit's hash, type name), so the defining unit and
-- every importer -- compiled separately -- assign the same id from the
-- same inputs, with no shared counter.  Ranges (all u32, disjoint from
-- builtins 0..14 (incl. Tup4..Tup8 at 10..14) and runtime 9000..):
--   record shapes : 0x00010000 + fnv32(fields)  mod 0x0FF00000
--   unit types    : 0x20000000 + fnv32(hash.T)  mod 0x5F000000
-- Main checks the merged maps for collisions and aborts loudly.
fnv32 :: String -> Int
fnv32 = fromIntegral . foldl' step (0x811c9dc5 :: Word32)
  where step acc c = (acc `xor` fromIntegral (ord c)) * 0x01000193

tidFor :: String -> Name -> Int
tidFor h n = 0x20000000 + fnv32 (h ++ "." ++ n) `mod` 0x5F000000

collectCons :: String -> [STop] -> M.Map Name (Int, Int, Int)
collectCons unitHash tops = M.union builtinCons (M.fromList user)
  where
    tdecls = [(n, cs) | TType n _ _ cs <- tops]
    user = concat [one (tidFor unitHash n) cs | (n, cs) <- tdecls]
    one tid cs = [(c, (tid, v, length tys)) | ((c, tys), v) <- zip cs [0 ..]]

collectShapes :: [STop] -> M.Map [Name] Int
collectShapes tops = M.fromList [(fs, shapeIdFor fs) | fs <- allShapes]
  where
    shapeIdFor fs = 0x00010000 + fnv32 (intercalate "," fs) `mod` 0x0FF00000
    allShapes = nub (concatMap topShapes tops)
    topShapes (TShape _ fs) = [sort (map fst fs)]
    topShapes (TBind _ ps g b) =
      concatMap patShapes ps
        ++ concatMap gShapes g
        ++ exprShapes b
      where
        gShapes (GBool e) = exprShapes e
        gShapes (GPat p e) = patShapes p ++ exprShapes e
    topShapes _ = []
    patShapes = \case
      PCon _ ps -> concatMap patShapes ps
      PTup ps -> concatMap patShapes ps
      _ -> []
    exprShapes = \case
      SMark _ e -> exprShapes e
      SRec fs -> [sort (map fst fs)] ++ concatMap (exprShapes . snd) fs
      SApp a b -> exprShapes a ++ exprShapes b
      SLam _ e -> exprShapes e
      SBlock ss e -> concatMap stmtShapes ss ++ exprShapes e
      SCase s as -> exprShapes s ++ concatMap (\(p, e) -> patShapes p ++ exprShapes e) as
      SBin _ a b -> exprShapes a ++ exprShapes b
      SProj e _ -> exprShapes e
      SUpd m as -> exprShapes m ++ concatMap (exprShapes . snd) as
      STup es -> concatMap exprShapes es
      SList es -> concatMap exprShapes es
      SStrI segs -> concat [exprShapes e | SegExpr e <- segs]
      _ -> []
    stmtShapes (SBind _ _ x) = exprShapes x
    stmtShapes (SBindPat p x) = patShapes p ++ exprShapes x

-- ---- first-class paths (docs/PATHS.md) --------------------------------
--
-- A TYPE-ROOTED path literal `@Model.field.sub` is validated here --
-- unconditionally, against the record alias's declared field types --
-- and desugars to an ORDINARY record value
--
--   { get  = fn s -> s.field.sub,
--     set  = fn v s -> {s | field.sub = v},
--     segs = ["field", "sub"] }
--
-- at plain type Path s a: no new type-system machinery, all the magic
-- lives in this one rewrite (composition is a normal function, in
-- std/lens).  The parser already turns every `@...` into
-- SApp (SVar "Path") <string> (sol's file-path literal); a literal
-- whose FIRST segment names a declared record alias is a path into
-- that shape and rewrites, everything else passes through untouched
-- (file paths start lowercase or '/', so the split is honest).
--
-- The BARE root `@Model` is the SCHEMA: the flattened list of every
-- string-addressable leaf, each entry
--
--   { path = "a.b", tag = "int"|"str",
--     get  = fn s -> <leaf rendered as String>,
--     set  = fn v s -> <s with leaf := v parsed by tag> }
--
-- -- the string tier for wires, shells and inspectors (std/lens walks
-- it).  Both tiers construct the SAME {get,set} closures, so a parsed
-- path and a literal path are indistinguishable downstream.  Leaves
-- are Int/String fields plus nested record aliases (flattened);
-- fields of any other type are typed-tier-only (a List index is a
-- traversal, not a total path) and are skipped by the schema.
--
-- Runs on the SURFACE tree right after module load (Compile.hs), so
-- collectShapes sees the generated records like any user record and
-- every profile downstream is oblivious.

shapeTyTable :: [STop] -> M.Map Name [(Name, Ty)]
shapeTyTable tops = M.fromList [(n, fs) | TShape n fs <- tops]

expandPathLits :: M.Map Name [(Name, Ty)] -> [STop] -> ([String], [STop])
expandPathLits tbl tops = (nub (concatMap errsTop tops), map top tops)
  where
    top (TBind n ps gs b) = TBind n ps (map (mapGuardE goE) gs) (goE b)
    top (TStruct n as fs) = TStruct n as [(f, goE e) | (f, e) <- fs]
    top t = t
    errsTop (TBind _ _ gs b) = concatMap errsG gs ++ errsE b
      where errsG (GBool e) = errsE e
            errsG (GPat _ e) = errsE e
    errsTop (TStruct _ _ fs) = concatMap (errsE . snd) fs
    errsTop _ = []

    splitDots s = case break (== '.') s of
      (a, []) -> [a]
      (a, _ : r) -> a : splitDots r

    pathTarget e = case e of
      SApp (SVar "Path") (SStrI [SegStr p])
        | (root : fields) <- splitDots p,
          not (null root),
          isUpper (head root),
          Just fs <- M.lookup root tbl ->
            Just (p, root, fields, fs)
      _ -> Nothing

    goE e
      | Just (p, root, fields, fs) <- pathTarget e =
          case rewriteLit p root fields fs of
            Right e' -> e'
            Left _ -> e -- reported via errsE; keep the tree well-formed
    goE e = descend e

    errsE e
      | Just (p, root, fields, fs) <- pathTarget e =
          either (: []) (const []) (rewriteLit p root fields fs)
    errsE e = concatMap errsE (children e)

    rewriteLit p root [] _ = schemaFor p root
    rewriteLit p root fields fs = do
      validate p root fields fs
      pure $
        SRec
          [ ("get", SLam ["s"] (SProj (SVar "s") fields)),
            ("set", SLam ["v", "s"] (SUpd (SVar "s") [(fields, SVar "v")])),
            ("segs", SList [SStrI [SegStr f] | f <- fields])
          ]

    validate _ _ [] _ = Right ()
    validate p shape (f : rest) fs = case lookup f fs of
      Nothing ->
        Left
          ( "path literal @" ++ p ++ ": " ++ shape ++ " has no field '" ++ f
              ++ "' (fields: " ++ intercalate ", " (map fst fs) ++ ")"
          )
      Just t
        | null rest -> Right ()
        | TCon sub [] <- t, Just fs' <- M.lookup sub tbl -> validate p sub rest fs'
        | otherwise ->
            Left
              ( "path literal @" ++ p ++ ": field '" ++ f
                  ++ "' is not a declared record shape -- cannot descend into it"
              )

    -- the schema: flatten every addressable leaf under the root alias.
    -- visited guards against a (declared) recursive shape cycle.
    schemaFor p root = SList . map entry <$> leaves p [root] [] (tbl M.! root)
    leaves p visited pre fs = concat <$> mapM leaf fs
      where
        leaf (f, TCon "Int" []) = pure [(pre ++ [f], "int")]
        leaf (f, TCon "String" []) = pure [(pre ++ [f], "str")]
        leaf (f, TCon sub [])
          | Just fs' <- M.lookup sub tbl =
              if sub `elem` visited
                then
                  Left
                    ( "schema @" ++ p ++ ": shape " ++ sub
                        ++ " recursively contains itself -- cannot flatten"
                    )
                else leaves p (sub : visited) (pre ++ [f]) fs'
        leaf _ = pure [] -- typed-tier-only leaf: not string-addressable
    entry (segs, tag) =
      SRec
        [ ("path", SStrI [SegStr (intercalate "." segs)]),
          ("tag", SStrI [SegStr tag]),
          ("get", SLam ["s"] (renderLeaf tag (SProj (SVar "s") segs))),
          ("set", SLam ["v", "s"] (SUpd (SVar "s") [(segs, parseLeaf tag (SVar "v"))]))
        ]
    renderLeaf "int" e = SApp (SVar "str") e
    renderLeaf _ e = e
    parseLeaf "int" v = SApp (SVar "parseInt") v
    parseLeaf _ v = v

    children e = case e of
      SMark _ a -> [a]
      SApp a b -> [a, b]
      SLam _ b -> [b]
      SBlock ss fin -> concatMap sChildren ss ++ [fin]
      SCase sc arms -> sc : map snd arms
      SBin _ a b -> [a, b]
      SProj a _ -> [a]
      STup xs -> xs
      SList xs -> xs
      SRec fs -> map snd fs
      SUpd a us -> a : map snd us
      SStrI segs -> [x | SegExpr x <- segs]
      _ -> []
      where
        sChildren (SBind _ _ x) = [x]
        sChildren (SBindPat _ x) = [x]

    descend e = case e of
      SMark o a -> SMark o (goE a)
      SApp a b -> SApp (goE a) (goE b)
      SLam x b -> SLam x (goE b)
      SBlock ss fin -> SBlock (map stmt ss) (goE fin)
      SCase sc arms -> SCase (goE sc) [(pt, goE x) | (pt, x) <- arms]
      SBin o a b -> SBin o (goE a) (goE b)
      SProj a f' -> SProj (goE a) f'
      STup xs -> STup (map goE xs)
      SList xs -> SList (map goE xs)
      SRec fs -> SRec [(f', goE x) | (f', x) <- fs]
      SUpd a us -> SUpd (goE a) [(f', goE x) | (f', x) <- us]
      SStrI segs -> SStrI (map seg segs)
      _ -> e
      where
        stmt (SBind x xs rhs) = SBind x xs (goE rhs)
        stmt (SBindPat pt rhs) = SBindPat pt (goE rhs)
        seg (SegExpr x) = SegExpr (goE x)
        seg s = s

dExpr :: SExpr -> D Core
dExpr = \case
  SMark _ e -> dExpr e -- positions stop at the Core boundary
  SVar n -> do
    cons <- gets dCons
    pure $ case M.lookup n cons of
      Just (_, _, _) -> CVar n
      Nothing -> CVar n
  SInt i -> pure (CInt i)
  SAtom a -> pure (CMk atomT 0 [CStr a])
  SApp a b -> CApp <$> dExpr a <*> dExpr b
  SLam ps e -> CLam ps <$> dExpr e
  SBlock stmts e -> go stmts
    where
      go [] = dExpr e
      go (SBind n ps rhs : rest) = do
        rhs' <- dExpr rhs
        let rhs'' = if null ps then rhs' else CLam ps rhs'
        CLet n rhs'' <$> go rest
      go (SBindPat p rhs : rest) = do
        rhs' <- dExpr rhs
        s <- fresh "bind"
        k <- go rest
        body <- matchPat (CVar s) p k (CErr ("let pattern: no match; pattern was " ++ show p))
        pure (CLet s rhs' body)
  SCase scrut arms -> do
    s <- fresh "scrut"
    sc' <- dExpr scrut
    body <-
      compileArms
        (CVar s)
        [(p, Nothing, e) | (p, e) <- arms]
        (CErr ("case: no matching pattern; arms were " ++ show (map fst arms)))
    pure (CLet s sc' body)
  SBin "|>" a f -> CApp <$> dExpr f <*> dExpr a
  SBin ">>" a b -> do
    a' <- dExpr a
    b' <- dExpr b
    u <- fresh "seq"
    pure (CLet u a' b')
  SBin "|>?" a f -> do
    v <- fresh "ok"
    e <- fresh "err"
    dExpr (SCase a [(PCon "Ok" [PVar v], SApp f (SVar v)), (PCon "Err" [PVar e], SApp (SVar "Err") (SVar e))])
  SBin "and" a b ->
    dExpr (SCase a [(PCon "True" [], b), (PCon "False" [], SVar "False")])
  SBin "or" a b ->
    dExpr (SCase a [(PCon "True" [], SVar "True"), (PCon "False" [], b)])
  SBin "::" a b -> dExpr (SApp (SApp (SVar "Cons") a) b)
  SBin op a b -> do
    a' <- dExpr a
    b' <- dExpr b
    pure (CApp (CApp (CVar op) a') b')
  SProj e path -> do
    e' <- dExpr e
    foldM projField e' path
  SRec fs -> do
    let sorted = sortOn fst fs
    tid <- shapeId (map fst sorted)
    -- records carry their FIELD COUNT in var (unused for shapes: one
    -- shape per tid).  The runtime's Vec fix_layout reads it to give
    -- record elements SoA columns by default -- the "no field counts
    -- in headers" limitation, closed where it bit hardest.
    CMk tid (length sorted) <$> mapM (dExpr . snd) sorted
  SUpd m assigns -> do
    m' <- dExpr m
    v <- fresh "rec"
    body <- updateRecord (CVar v) assigns
    pure (CLet v m' body)
  STup es -> do
    -- tuples are Tup2..Tup8 (a wider tuple used to be packed into a
    -- Tup2 header and silently corrupt its own payload; now 4..8 are
    -- real constructors and >8 is a hard error).
    con <- tupCon (length es)
    (tid, var, _) <- conInfo con
    CMk tid var <$> mapM dExpr es
  SList es -> dExpr (foldr (\x acc -> SApp (SApp (SVar "Cons") x) acc) (SVar "Nil") es)
  SStrI segs -> do
    parts <- mapM segCore segs
    pure $ case parts of
      [] -> CStr ""
      (p : ps) -> foldl' (\acc x -> CApp (CApp (CVar "strcat") acc) x) p ps
    where
      segCore (SegStr s) = pure (CStr s)
      segCore (SegExpr e) = CApp (CVar "str") <$> dExpr e

-- the ABI has Tup2..Tup8; past that, name your fields
tupCon :: Int -> D String
tupCon n
  | n >= 2 && n <= 8 = pure ("Tup" ++ show n)
  | otherwise =
      error
        ( "tuple of "
            ++ show n
            ++ " elements: this ABI has Tup2..Tup8 -- past 8, "
            ++ "declare a constructor or use a record instead"
        )

conInfo :: Name -> D (Int, Int, Int)
conInfo c = do
  cons <- gets dCons
  case M.lookup c cons of
    Just i -> pure i
    Nothing -> error ("unknown constructor: " ++ c)

shapeId :: [Name] -> D Int
shapeId fs = do
  shapes <- gets dShapes
  case M.lookup (sort fs) shapes of
    Just i -> pure i
    Nothing -> error ("unknown record shape: " ++ show fs)

projField :: Core -> Name -> D Core
projField scrut f = do
  shapes <- gets dShapes
  let cands = [(tid, idx, length fs) | (fs, tid) <- M.toList shapes, f `elem` fs, let idx = length (takeWhile (/= f) (sort fs))]
  case cands of
    [] -> pure (CErr ("no record shape has field ." ++ f))
    [(_, idx, _)] -> pure (CProj idx scrut)
    many' -> do
      v <- fresh "r"
      let chain = foldr (\(tid, idx, ar) rest -> CIf (CTagEq tid ar (CVar v)) (CProj idx (CVar v)) rest) (CErr ("no shape with field ." ++ f ++ " matched")) many'
      pure (CLet v scrut chain)

updateRecord :: Core -> [([Name], SExpr)] -> D Core
updateRecord scrut assigns = do
  shapes <- gets dShapes
  let roots = nub (map (head . fst) assigns)
      cands = [(fs, tid) | (fs, tid) <- M.toList shapes, all (`elem` fs) roots]
  when (null cands) $ error ("no record shape has fields " ++ show roots)
  arms <- mapM rebuild cands
  pure $ case arms of
    [(_, _, body)] -> body
    _ ->
      foldr
        (\(tid, ar, body) rest -> CIf (CTagEq tid ar scrut) body rest)
        (CErr "record update: no shape matched")
        arms
  where
    rebuild (fs, tid) = do
      let sorted = sort fs
      fields <- mapM (fieldValue tid) (zip [0 ..] sorted)
      pure (tid, length fs, CMk tid (length fs) fields)
      where
        fieldValue _ (idx, f) =
          case [(path, e) | (path, e) <- assigns, head path == f] of
            [] -> pure (CProj idx scrut)
            [([_], e)] -> dExpr e
            deeper -> do
              let subAssigns = [(tail p, e) | (p, e) <- deeper]
              updateRecord (CProj idx scrut) subAssigns

compileArms :: Core -> [(SPat, Maybe SExpr, SExpr)] -> Core -> D Core
compileArms scrut arms fallback = go arms
  where
    go [] = pure fallback
    go ((p, g, body) : rest) = do
      nxt <- go rest
      body' <- dExpr body
      inner <- case g of
        Nothing -> pure body'
        Just ge -> do
          ge' <- dExpr ge
          pure (CIf ge' body' nxt)
      matchPat scrut p inner nxt

matchPat :: Core -> SPat -> Core -> Core -> D Core
matchPat scrut p ok fail' = case p of
  PWild -> pure ok
  PVar x -> pure (CLet x scrut ok)
  PSig x _ -> pure (CLet x scrut ok) -- erased by erasePSig; PVar behavior if one survives
  PInt n -> pure (CIf (CApp (CApp (CVar "==") scrut) (CInt n)) ok fail')
  PStr s -> pure (CIf (CApp (CApp (CVar "==") scrut) (CStr s)) ok fail')
  PCon c ps -> do
    (tid, var, ar) <- conInfo c
    unless (length ps == ar) $ error ("constructor " ++ c ++ " arity mismatch in pattern")
    inner <- matchFields scrut ps ok fail'
    pure (CIf (CTagEq tid var scrut) inner fail')
  PTup ps -> do
    con <- tupCon (length ps)
    (tid, var, _) <- conInfo con
    inner <- matchFields scrut ps ok fail'
    pure (CIf (CTagEq tid var scrut) inner fail')
  PRec fs -> do
    let bind [] = pure ok
        bind (f : rest) = do
          proj <- projField scrut f
          CLet f proj <$> bind rest
    bind fs

matchFields :: Core -> [SPat] -> Core -> Core -> D Core
matchFields scrut ps ok fail' = go (zip [0 ..] ps)
  where
    go [] = pure ok
    go ((i, p) : rest) = do
      inner <- go rest
      matchPat (CProj i scrut) p inner fail'

compileTop :: [STop] -> D Prog
compileTop tops = do
  cons <- gets dCons
  let conGlobals = [(c, (params, CMk tid var (map CVar params))) | (c, (tid, var, ar)) <- M.toList cons, let params = ["x" ++ show i | i <- [1 .. ar]]]
  binds <- mapM compileGroup (groupClauses [b | b@TBind {} <- tops])
  pure (M.fromList (conGlobals ++ binds))
  where
    -- EVERY clause of a name, in source order, wherever it sits: the
    -- inferencer (Infer.clausesOf) already reads a function that way,
    -- and a contiguous-run grouping here let a definition dropped
    -- between two clauses of `key` silently discard the earlier ones
    -- (M.fromList kept the last run) -- a well-typed program that
    -- ignored half its keys.  One rule for both passes now.
    groupClauses bs =
      [ (n, [(ps, g, b) | TBind n' ps g b <- bs, n' == n])
      | n <- nub [n | TBind n _ _ _ <- bs] ]

compileGroup :: (Name, [([SPat], [SGuard], SExpr)]) -> D (Name, ([Name], Core))
compileGroup (n, clauses@((ps0, _, _) : _)) = do
  let arity = length ps0
  args <- mapM (\i -> fresh ("a" ++ show i)) [1 .. arity]
  body <- goClauses args clauses
  pure (n, (args, body))
  where
    goClauses _ [] = pure (CErr ("no matching clause for " ++ n))
    goClauses args ((ps, g, b) : rest) = do
      nxt0 <- goClauses args rest
      -- JOIN POINT: matchPat inlines the fail continuation at EVERY
      -- test site, so a clause with t tests duplicates the whole
      -- remaining-clauses tree t times — exponential in the worst
      -- case. When a clause can fail from more than one place, bind
      -- the rest ONCE as a lifted top-level function and fail into a
      -- saturated call to it: in tail position that is a TCO'd jump
      -- (zero stack), it passes the function-entry fuel safepoint
      -- (uniform accounting: one unit per clause fallen through), and
      -- code size goes linear in the number of clauses.
      nxt <- case failSites ps + length g of
        t | t > 1, not (trivial nxt0) -> do
          jn <- fresh (n ++ "_fb")
          modify (\s -> s {dLifted = (jn, args, nxt0) : dLifted s})
          pure (foldl' CApp (CVar jn) (map CVar args))
        _ -> pure nxt0
      b' <- dExpr b
      inner <- foldGuards g b' nxt
      matchMany (zip (map CVar args) ps) inner nxt
    -- guards run left to right; a pattern guard binds its pattern for
    -- the guards to its right and for the body, and falls through to
    -- the next clause on a non-match, exactly like a pattern test
    foldGuards [] ok _ = pure ok
    foldGuards (gd : rest) ok nxt = do
      inner <- foldGuards rest ok nxt
      case gd of
        GBool ge -> do ge' <- dExpr ge; pure (CIf ge' inner nxt)
        GPat p ge -> do
          ge' <- dExpr ge
          sv <- fresh "gp"
          m <- matchPat (CVar sv) p inner nxt
          pure (CLet sv ge' m)
    failSites = sum . map tests
    tests = \case
      PWild -> 0; PVar _ -> 0; PRec _ -> 0; PSig _ _ -> 0
      PInt _ -> 1; PStr _ -> 1
      PCon _ ps -> 1 + sum (map tests ps)
      PTup ps -> 1 + sum (map tests ps)
    trivial (CErr _) = True
    trivial _ = False
    matchMany [] ok _ = pure ok
    matchMany ((s, p) : rest) ok fail' = do
      inner <- matchMany rest ok fail'
      matchPat s p inner fail'
compileGroup (n, []) = error ("empty clause group: " ++ n)

--------------------------------------------------------------------------------
-- Lambda lifting
--------------------------------------------------------------------------------

liftProg :: Prog -> D Prog
liftProg prog = do
  -- clause-fallthrough JOIN functions were registered in dLifted during
  -- compileTop; they are globals-to-be, so lifting must not treat a
  -- reference to one as a lambda capture
  joins0 <- gets (map (\(jn, _, _) -> jn) . dLifted)
  let globalNames = M.keysSet prog `S.union` S.fromList joins0
  lifted <- M.traverseWithKey (\_ (ps, b) -> (ps,) <$> liftC globalNames ps b) prog
  extra <- gets dLifted
  modify (\s -> s {dLifted = []})
  extra' <-
    mapM
      ( \(n, ps, b) -> do
          b' <- liftC globalNames ps b
          pure (n, (ps, b'))
      )
      extra
  pure (M.union lifted (M.fromList extra'))
  where
    liftC globals bound = go (foldr (:) [] bound)
      where
        go env = \case
          CLam ps body -> do
            body' <- go (ps ++ env) body
            -- A LEXICAL BINDER WINS over a global of the same name.
            -- Testing globals/prims first dropped such a name from the
            -- capture set, so the lifted body resolved it to the global
            -- instead of the enclosing parameter -- silently, with a
            -- wrong value (`wrap tag x = (fn y -> "{tag}-{y}") x` printed
            -- the global `tag` function). Membership in `env` already
            -- means "bound out here", which is exactly what to capture;
            -- anything not in `env` is a global or prim reference and is
            -- filtered out by that same test.
            let capture = nub [v | v <- freeVars body', v `notElem` ps, v `elem` (env :: [Name])]
            nm <- fresh "lifted"
            modify (\s -> s {dLifted = (nm, capture ++ ps, body') : dLifted s})
            pure (foldl' CApp (CVar nm) (map CVar capture))
          CApp a b -> CApp <$> go env a <*> go env b
          CLet x a b -> CLet x <$> go env a <*> go (x : env) b
          CIf c t e -> CIf <$> go env c <*> go env t <*> go env e
          CMk t v fs -> CMk t v <$> mapM (go env) fs
          CTagEq t v e -> CTagEq t v <$> go env e
          CProj i e -> CProj i <$> go env e
          other -> pure other

freeVars :: Core -> [Name]
freeVars = \case
  CVar n -> [n]
  CApp a b -> freeVars a ++ freeVars b
  CLam ps b -> filter (`notElem` ps) (freeVars b)
  CLet x a b -> freeVars a ++ filter (/= x) (freeVars b)
  CIf c t e -> freeVars c ++ freeVars t ++ freeVars e
  CMk _ _ fs -> concatMap freeVars fs
  CTagEq _ _ e -> freeVars e
  CProj _ e -> freeVars e
  _ -> []

liftFix :: Prog -> D Prog
liftFix p = do
  -- NOTE dLifted is NOT cleared here: compileTop registers clause-
  -- fallthrough join functions in it, and clearing before the first
  -- liftProg round would silently drop them (their call sites then
  -- resolve as fpr_g_ closure loads of a symbol that never exists).
  -- liftProg consumes-and-clears instead, which keeps the fixpoint
  -- rounds from re-adding old entries.
  p' <- liftProg p
  if any (hasLam . snd . snd) (M.toList p') then liftFix p' else pure p'
  where
    hasLam = \case
      CLam _ _ -> True
      CApp a b -> hasLam a || hasLam b
      CLet _ a b -> hasLam a || hasLam b
      CIf c t e -> hasLam c || hasLam t || hasLam e
      CMk _ _ fs -> any hasLam fs
      CTagEq _ _ e -> hasLam e
      CProj _ e -> hasLam e
      _ -> False

--------------------------------------------------------------------------------
-- Pretty printer for Core
--------------------------------------------------------------------------------

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

-- ---- source anchors (spans, step 1: bind-level) -----------------------------
--
-- The compiler's post-parse diagnostics were location-free strings.
-- Step 1 anchors every "in NAME: ..." message to file:line of NAME's
-- definition, with NO change to the AST (so nothing downstream moves
-- and no pinned module hash churns):
--
--   * top declarations start at COLUMN 0 by the grammar, so a bind's
--     anchor is the first col-0 line beginning with its name -- the
--     signature line when one precedes the clauses, which is the
--     better anchor anyway;
--   * the map is keyed by the (possibly splice-renamed) top name; the
--     scan token strips the @hash suffix module splicing appends, so
--     unit anchors survive qualification.
--
-- Step 3 (statement-level SMark wrappers) replaces the scan with real
-- parser positions; stripPosTops below is already the seam that keeps
-- module identity blind to them.

-- the SPAN-PROOFING seam (spans, step 0): module identity is the hash
-- of the POSITIONLESS tree.  Any future source-position node (an SMark
-- wrapper, a located bind) is erased HERE before Modules.hs hashes, so
-- spans can never churn pinned module hashes.  Today no such node
-- exists and this is the identity -- the hash string stays
-- bit-compatible with every existing pin.
stripPosTops :: [STop] -> [STop]
stripPosTops = map stripTop
  where
    stripTop = \case
      TBind n ps g b -> TBind n ps (map (mapGuardE stripE) g) (stripE b)
      TEval e -> TEval (stripE e)
      TStruct n sigs fs -> TStruct n sigs [(f, stripE e) | (f, e) <- fs]
      t -> t

-- erase every position wrapper (module identity, and any consumer that
-- needs the pure syntactic tree)
stripE :: SExpr -> SExpr
stripE = \case
  SMark _ e -> stripE e
  SApp a b -> SApp (stripE a) (stripE b)
  SLam ps e -> SLam ps (stripE e)
  SBlock ss e -> SBlock (map stripS ss) (stripE e)
  SCase s arms -> SCase (stripE s) [(p, stripE e) | (p, e) <- arms]
  SBin o a b -> SBin o (stripE a) (stripE b)
  SProj e fs -> SProj (stripE e) fs
  SRec fs -> SRec [(f, stripE e) | (f, e) <- fs]
  SUpd m as -> SUpd (stripE m) [(p, stripE e) | (p, e) <- as]
  STup es -> STup (map stripE es)
  SList es -> SList (map stripE es)
  SStrI segs -> SStrI [case sg of SegExpr e -> SegExpr (stripE e); s -> s | sg <- segs]
  e -> e
  where
    stripS (SBind n ps e) = SBind n ps (stripE e)
    stripS (SBindPat p e) = SBindPat p (stripE e)

-- look through position wrappers: every SHAPE-SENSITIVE match (a pass
-- recognizing a special form by syntax) goes through this first
unmark :: SExpr -> SExpr
unmark (SMark _ e) = unmark e
unmark e = e

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

-- the primitive names the lambda lifter must not treat as free
-- variables (the host-side evaluator this list once served is gone --
-- both its copies; the Sol VM and Codegen are the executors)
primNames :: [Name]
primNames =
  [ "+",
    "-",
    "*",
    "/",
    "%",
    "^",
    "==",
    "!=",
    "<",
    ">",
    "<=",
    ">=",
    "!",
    "print",
    "String.len",
    "str",
    "strcat",
    "error"
  ]


--------------------------------------------------------------------------------
-- Linearity checker (static, pre-desugar).
--------------------------------------------------------------------------------

data LShape = LU | LL | LTupS [LShape] deriving (Show)

isLin :: LShape -> Bool
isLin LL = True
isLin (LTupS ss) = any isLin ss
isLin LU = False

data LinInfo = LinInfo
  { liLinTys :: [Name],
    liSigs :: M.Map Name ([LShape], LShape),
    liConSh :: M.Map Name (LShape, [LShape]),
    liConAr :: M.Map Name Int
  }

shapeOfTy :: [Name] -> Ty -> LShape
shapeOfTy lin = \case
  TTup ts -> LTupS (map (shapeOfTy lin) ts)
  TCon n as -> if n `elem` lin || any (isLin . shapeOfTy lin) as then LL else LU
  TVarT _ -> LU
  TArrT _ _ -> LU
  TVApp _ _ -> LU
  TOther -> LU

buildLinInfo :: [STop] -> LinInfo
buildLinInfo tops = LinInfo lin sigs conSh conAr
  where
    -- TAlias resolves here too (the sol profile's module aliasing):
    -- an alias of a linear type is linear, and its constructors carry
    -- the target's shapes/arities
    aliases = [(t, tgt) | TAlias t tgt <- tops]
    lin0 = [n | TType n True _ _ <- tops]
    lin = lin0 ++ [t | (t, tgt) <- aliases, tgt `elem` lin0]
    sigs = M.fromList [(n, (map sh ps, sh r)) | TSig n (ps, r) _ <- tops]
    conSh0 = M.fromList [(c, (if linear then LL else LU, map sh tys)) | TType _ linear _ cs <- tops, (c, tys) <- cs]
    conSh = foldl' (\m (t, tgt) -> maybe m (\e -> M.insert t e m) (M.lookup tgt m)) conSh0 aliases
    conAr0 = M.fromList [(c, length tys) | TType _ _ _ cs2 <- tops, (c, tys) <- cs2]
    conAr = foldl' (\m (t, tgt) -> maybe m (\e -> M.insert t e m) (M.lookup tgt m)) conAr0 aliases
    sh = shapeOfTy lin

type Cnt = M.Map Name Int

type LRes = ([String], Maybe Cnt, LShape)

lcheck :: LinInfo -> [STop] -> [String]
lcheck li tops = concatMap checkGroup groups
  where
    groups = groupTB [b | b@TBind {} <- tops]
    groupTB [] = []
    groupTB (TBind n ps g b : rest) = let (same, others) = span (\(TBind n' _ _ _) -> n' == n) rest in (n, (ps, g, b) : [(p', g', b') | TBind _ p' g' b' <- same]) : groupTB others
    groupTB (_ : rest) = groupTB rest

    checkGroup (n, clauses) = concatMap (checkClause n) clauses

    checkClause n (pats, g, body) =
      let paramShapes = case M.lookup n (liSigs li) of
            Just (ps, _) | length ps == length pats -> ps
            _ -> replicate (length pats) LU
          binds = concat (zipWith (bindPat li) pats paramShapes)
          wildErrs = ["in " ++ n ++ ": " ++ w | w <- concat (zipWith wildLinErrs pats paramShapes)]
          env = M.fromList binds
          linear = [v | (v, s) <- binds, isLin s]
          (genv, ge, gc) =
            foldl'
              ( \(en, errs, cnt) gd -> case gd of
                  GBool gx ->
                    let (e', c', _) = lin' en gx
                     in (en, errs ++ e', M.unionWith (+) cnt (fromMaybe M.empty c'))
                  GPat p gx ->
                    let (e', c', _) = lin' en gx
                        en' = M.union (M.fromList (bindPat li p LU)) en
                     in (en', errs ++ e', M.unionWith (+) cnt (fromMaybe M.empty c'))
              )
              (env, [], M.empty)
              g
          (be, bc, _) = lin' genv body
          guardErr = ["in " ++ n ++ ": guard uses linear variable(s) " ++ show (M.keys (M.filter (> 0) gc)) ++ " (guards may re-evaluate on fallthrough)" | not (M.null (M.filter (> 0) gc))]
          useErrs = case bc of
            Nothing -> []
            Just c -> ["in " ++ n ++ ": linear variable '" ++ v ++ "' used " ++ show (M.findWithDefault 0 v c) ++ " time(s), expected exactly 1" | v <- linear, M.findWithDefault 0 v c /= 1]
          -- EVERY linearity error names its bind (spans step 1: the
          -- "in NAME:" prefix is what the error sinks anchor to
          -- file:line) -- body/guard errors from linExpr gain it here
          pre e = if ("in " ++ n ++ ":") `isPrefixOf` e then e else "in " ++ n ++ ": " ++ e
       in map pre (wildErrs ++ ge ++ be ++ guardErr ++ useErrs)
      where
        lin' = linExpr li

-- a WILDCARD that swallows a linear shape is a silent leak: the value
-- is never counted, never consumed, never dropped.  Refuse it -- bind
-- a name and consume it (or `drop` it) instead.  Distributes through
-- tuple patterns so `(x, _) = Vec.get i v` (discarding the returned
-- HANDLE) is caught too.
wildLinErrs :: SPat -> LShape -> [String]
wildLinErrs p s = case p of
  PWild | isLin s -> ["a linear value is DISCARDED by `_` -- bind it and consume it (or drop it explicitly)"]
  PTup ps -> case s of
    LTupS ss | length ss == length ps -> concat (zipWith wildLinErrs ps ss)
    _ -> []
  _ -> []

bindPat :: LinInfo -> SPat -> LShape -> [(Name, LShape)]
bindPat li p s = case p of
  PVar x -> [(x, s)]
  PSig x _ -> [(x, s)] -- erased by erasePSig; PVar behavior if one survives
  PWild -> []
  PInt _ -> []
  PStr _ -> []
  PRec fs -> [(f, LU) | f <- fs]
  PTup ps -> case s of
    LTupS ss | length ss == length ps -> concat (zipWith (bindPat li) ps ss)
    _ -> concatMap (\q -> bindPat li q LU) ps
  PCon c ps -> case M.lookup c (liConSh li) of
    Just (_, argShapes) | length argShapes == length ps -> concat (zipWith (bindPat li) ps argShapes)
    _ -> concatMap (\q -> bindPat li q LU) ps

linExpr :: LinInfo -> M.Map Name LShape -> SExpr -> LRes
linExpr li env0 = go env0
  where
    zero = M.empty
    addC = M.unionWith (+)
    plus (Just a) (Just b) = Just (addC a b)
    plus _ _ = Nothing

    go :: M.Map Name LShape -> SExpr -> LRes
    go env = \case
      SMark _ e -> go env e
      SVar v -> case M.lookup v env of
        Just s | isLin s -> ([], Just (M.singleton v 1), s)
        Just s -> ([], Just zero, s)
        Nothing -> ([], Just zero, globalShape v)
      SInt _ -> ([], Just zero, LU)
      SAtom _ -> ([], Just zero, LU)
      SStrI segs ->
        let rs = [go env e | SegExpr e <- segs]
         in (concat [e | (e, _, _) <- rs], foldl' plus (Just zero) [c | (_, c, _) <- rs], LU)
      e@SApp {} -> appSpine env e
      SBin "|>" a f -> go env (SApp f a)
      SBin "::" a b -> go env (SApp (SApp (SVar "Cons") a) b)
      SBin ">>" a b ->
        let (e1, c1, _) = go env a; (e2, c2, s2) = go env b
         in (e1 ++ e2, plus c1 c2, s2)
      SBin _ a b ->
        let (e1, c1, _) = go env a; (e2, c2, _) = go env b
         in (e1 ++ e2, plus c1 c2, LU)
      SProj e _ -> let (er, c, _) = go env e in (er, c, LU)
      SRec fs ->
        let rs = map (go env . snd) fs
         in (concat [e | (e, _, _) <- rs], foldl' plus (Just zero) [c | (_, c, _) <- rs], LU)
      SUpd m as ->
        let rs = go env m : map (go env . snd) as
         in (concat [e | (e, _, _) <- rs], foldl' plus (Just zero) [c | (_, c, _) <- rs], LU)
      SList es ->
        let rs = map (go env) es
            sh = if any (\(_, _, s) -> isLin s) rs then LL else LU
         in (concat [e | (e, _, _) <- rs], foldl' plus (Just zero) [c | (_, c, _) <- rs], sh)
      STup es ->
        let rs = map (go env) es
         in (concat [e | (e, _, _) <- rs], foldl' plus (Just zero) [c | (_, c, _) <- rs], LTupS [s | (_, _, s) <- rs])
      SLam ps body ->
        -- a lambda may CAPTURE linear values: defining it consumes them
        -- (they live in the closure now), the body must use each
        -- exactly once, and the closure itself becomes LINEAR -- one
        -- application, enforced by the same counting as any LL value.
        -- (Runtime: the PAP carries the handle; the saturating apply
        -- hands it on.  A never-applied linear closure strands its
        -- handle -- consumed, not unsafe.)
        let env' = M.union (M.fromList [(p, LU) | p <- ps]) env
            (be, bc, _) = go env' body
            caps = [v | v <- sFree body, v `notElem` ps, maybe False isLin (M.lookup v env)]
            capErrs = case bc of
              Nothing -> []
              Just cc ->
                [ "lambda body uses linear capture '" ++ v ++ "' " ++ show k ++ " time(s), expected exactly 1"
                  | v <- caps, let k = M.findWithDefault 0 v cc, k /= 1 ]
            sh = if null caps then LU else LL
         in (be ++ capErrs, bc, sh)
      SCase scrut arms ->
        let (se, sc, sshape) = go env scrut
            armRes = map (checkArm env sshape) arms
            errs = se ++ concat [e | (e, _, _) <- armRes]
            live = [(c, s) | (_, Just c, s) <- armRes]
            agree = case live of
              [] -> []
              ((c0, _) : rest) -> ["case branches disagree on use of linear variable(s) " ++ show (disagreeing c0 c) | (c, _) <- rest, not (M.null (disagreeingM c0 c))]
            total = case live of
              [] -> Nothing
              ((c0, _) : _) -> plus sc (Just c0)
            shape = case live of ((_, s) : _) -> s; [] -> LU
         in (errs ++ agree, total, shape)
      SBlock stmts final -> goBlock env stmts final

    disagreeingM a b = M.filter id (M.intersectionWith (/=) a' b')
      where
        a' = M.unionWith (+) a (M.map (const 0) b)
        b' = M.unionWith (+) b (M.map (const 0) a)
    disagreeing a b = M.keys (disagreeingM a b)

    checkArm env sshape (p, body) =
      let binds = bindPat li p sshape
          env' = M.union (M.fromList binds) env
          (es, c, s) = go env' body
          linear = [v | (v, sh) <- binds, isLin sh]
          errs = case c of
            Nothing -> []
            Just cc -> ["linear variable '" ++ v ++ "' bound in pattern used " ++ show (M.findWithDefault 0 v cc) ++ " time(s), expected 1" | v <- linear, M.findWithDefault 0 v cc /= 1]
          c' = fmap (\cc -> foldr M.delete cc (map fst binds)) c
       in (wildLinErrs p sshape ++ es ++ errs, c', s)

    goBlock env [] final = go env final
    goBlock env (SBind n [] rhs : rest) final =
      let (e1, c1, sh) = go env rhs
          env' = M.insert n sh env
          (e2, c2, shf) = goBlock env' rest final
          errs = case c2 of
            Nothing -> []
            Just cc | isLin sh, M.findWithDefault 0 n cc /= 1 -> ["linear variable '" ++ n ++ "' used " ++ show (M.findWithDefault 0 n cc) ++ " time(s), expected exactly 1"]
            _ -> []
          c2' = fmap (M.delete n) c2
       in (e1 ++ e2 ++ errs, plus c1 c2', shf)
    goBlock env (SBind n _ps rhs : rest) final =
      let caps = [v | v <- sFree rhs, maybe False isLin (M.lookup v env)]
          errs = ["local function '" ++ n ++ "' captures linear variable(s) " ++ show caps | not (null caps)]
          (e2, c2, shf) = goBlock (M.insert n LU env) rest final
       in (errs ++ e2, c2, shf)
    goBlock env (SBindPat p rhs : rest) final =
      let (e1, c1, sh) = go env rhs
          e1w = e1 ++ wildLinErrs p sh
          binds = bindPat li p sh
          env' = M.union (M.fromList binds) env
          (e2, c2, shf) = goBlock env' rest final
          linear = [v | (v, s) <- binds, isLin s]
          errs = case c2 of
            Nothing -> []
            Just cc -> ["linear variable '" ++ v ++ "' used " ++ show (M.findWithDefault 0 v cc) ++ " time(s), expected exactly 1" | v <- linear, M.findWithDefault 0 v cc /= 1]
          c2' = fmap (\cc -> foldr M.delete cc (map fst binds)) c2
       in (e1w ++ e2 ++ errs, plus c1 c2', shf)

    appSpine env e =
      let (h, args) = flatten e []
          argRes = map (go env) args
          argErrs = concat [er | (er, _, _) <- argRes]
          argCnt = foldl' plus (Just zero) [c | (_, c, _) <- argRes]
          anyLinArg = any (\(_, _, s) -> isLin s) argRes
       in case h of
            SVar "error" -> (argErrs, Nothing, LU)
            SVar g ->
              -- a PARTIAL application over linear argument(s) is a
              -- linear PAP: the args are consumed into it (argCnt
              -- already counts them once) and the PAP itself must be
              -- applied exactly once.
              let (sh, full) = headShape g (length args)
                  sh2 = if anyLinArg && not full then LL else sh
                  (he, hc, _) = go env (SVar g)
               in (argErrs ++ he, plus hc argCnt, sh2)
            _ ->
              let (he, hc, _) = go env h
               in (argErrs ++ he, plus hc argCnt, LU)
      where
        flatten (SApp f a) acc = flatten f (a : acc)
        flatten f acc = (f, acc)

    headShape g nargs
      | Just (retSh, _) <- M.lookup g (liConSh li),
        Just ar <- M.lookup g (liConAr li) =
          (if nargs == ar then retSh else LU, nargs >= ar)
      | Just (ps, r) <- M.lookup g (liSigs li) = (if nargs == length ps then r else LU, nargs >= length ps)
      | otherwise = (LU, True)
    globalShape v
      | Just (ps, r) <- M.lookup v (liSigs li), null ps = r
      | Just (r, as) <- M.lookup v (liConSh li), null as = r
      | otherwise = LU

sFree :: SExpr -> [Name]
sFree = nub . go
  where
    go = \case
      SMark _ e -> go e
      SVar v -> [v]
      SApp a b -> go a ++ go b
      SLam ps e -> filter (`notElem` ps) (go e)
      SBin _ a b -> go a ++ go b
      SProj e _ -> go e
      SRec fs -> concatMap (go . snd) fs
      SUpd m as -> go m ++ concatMap (go . snd) as
      STup es -> concatMap go es
      SList es -> concatMap go es
      SStrI segs -> concat [go e | SegExpr e <- segs]
      SCase s arms -> go s ++ concatMap armF arms
      SBlock ss e -> blockF ss e
      _ -> []
    armF (p, e) = filter (`notElem` patB p) (go e)
    patB = \case
      PVar x -> [x]
      PCon _ ps -> concatMap patB ps
      PTup ps -> concatMap patB ps
      PRec fs -> fs
      _ -> []
    blockF [] e = go e
    blockF (SBind n ps rhs : rest) e = filter (`notElem` ps) (go rhs) ++ filter (/= n) (blockF rest e)
    blockF (SBindPat p rhs : rest) e = go rhs ++ filter (`notElem` patB p) (blockF rest e)

--------------------------------------------------------------------------------
-- Generic expr traversal + pattern vars (shared by Struct/Infer)
--------------------------------------------------------------------------------

patVars :: SPat -> [Name]
patVars = \case
  PVar n -> [n]
  PSig n _ -> [n]
  PCon _ ps -> concatMap patVars ps
  PTup ps -> concatMap patVars ps
  PRec ns -> ns
  _ -> []

-- generic bottom-up expr transform threading the set of locally-bound names
transformE :: (S.Set Name -> SExpr -> SExpr) -> S.Set Name -> SExpr -> SExpr
transformE f = transformEP f id

transformEP :: (S.Set Name -> SExpr -> SExpr) -> (SPat -> SPat) -> S.Set Name -> SExpr -> SExpr
transformEP f pf = go
  where
    go bs e0 = f bs $ case e0 of
      SMark o e -> SMark o (go bs e)
      SApp a b -> SApp (go bs a) (go bs b)
      SLam ps b -> SLam ps (go (bs `S.union` S.fromList ps) b)
      SBlock stmts fin ->
        let (stmts', bs') = goStmts bs stmts
         in SBlock stmts' (go bs' fin)
      SCase s alts -> SCase (go bs s) [(pf p, go (bs `S.union` S.fromList (patVars p)) e) | (p, e) <- alts]
      SBin op a b -> SBin op (go bs a) (go bs b)
      SProj e path -> SProj (go bs e) path
      SRec fs -> SRec [(n, go bs e) | (n, e) <- fs]
      SUpd m as -> SUpd (go bs m) [(p, go bs e) | (p, e) <- as]
      STup es -> STup (map (go bs) es)
      SList es -> SList (map (go bs) es)
      SStrI segs -> SStrI [case s of SegExpr e -> SegExpr (go bs e); o -> o | s <- segs]
      other -> other
    goStmts bs [] = ([], bs)
    goStmts bs (SBind n ps x : rest) =
      let x' = go (bs `S.union` S.fromList (n : ps)) x
          (rest', bs') = goStmts (S.insert n bs) rest
       in (SBind n ps x' : rest', bs')
    goStmts bs (SBindPat p x : rest) =
      let x' = go bs x
          (rest', bs') = goStmts (bs `S.union` S.fromList (patVars p)) rest
       in (SBindPat (pf p) x' : rest', bs')

-- import list needs S/M already imported in FPRISC.hs
