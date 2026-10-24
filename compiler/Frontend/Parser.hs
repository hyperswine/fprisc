{-# OPTIONS_GHC -O2 #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# LANGUAGE LambdaCase, TupleSections #-}

-- Surface grammar; normalization and lowering have separate owners.
module Frontend.Parser where

import Control.Monad ( when )
import Data.Bits ( shiftR, xor )
import Data.Char ( isAlphaNum, isLower )
import Data.List ( foldl' )
import Frontend.Lexer
    ( P,
      sc,
      lexeme,
      symbol,
      identChar,
      dottedIdent,
      lowerName,
      pName,
      lowerNameRaw,
      upperName,
      integer,
      integerN,
      parens,
      braces,
      brackets,
      dotTerm,
      pipeSep,
      eqSign,
      keyword )
import Frontend.MemoryLayout ( expandLayout )
import Frontend.Normalize ( profileNames )
import Frontend.Syntax
    ( Ty(..),
      STop(TBind, TEval, TSigDef, TStruct, TUse, TSig, TType, TShape,
           TAlias),
      SGuard(..),
      SPat(..),
      SStmt(SBindPat, SBind),
      Seg(SegStr, SegExpr),
      SExpr(..) )
import GHC.Float ( castDoubleToWord64, castFloatToWord32 )
import Text.Megaparsec
    ( (<|>),
      empty,
      optional,
      anySingle,
      getOffset,
      oneOf,
      registerParseError,
      satisfy,
      between,
      choice,
      option,
      many,
      manyTill,
      sepBy,
      sepBy1,
      skipManyTill,
      some,
      MonadParsec(try, lookAhead, takeWhileP, observing, takeWhile1P,
                  eof, notFollowedBy) )
import Text.Megaparsec.Char
    ( char, digitChar, hexDigitChar, string )
import qualified Data.Bits ( Bits((.&.)) )

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
  -- `empty`, not `fail "integer"`: a message here would be merged into
  -- the error of a literal `integer` refuses at the same position
  when (frac == Nothing && ex == Nothing && suf == Nothing) empty
  let d = read (if frac == Nothing then ipart ++ ".0" ++ maybe "" id ex else txt) :: Double
  pure $
    if isF32
      then SApp (SVar "f32frombits") (SInt (fromIntegral (castFloatToWord32 (realToFrac d))))
      else
        let bits = castDoubleToWord64 d
         in SApp (SApp (SVar "f64frombits") (SInt (fromIntegral (bits `shiftR` 32))))
              (SInt (fromIntegral (bits Data.Bits..&. 0xFFFFFFFF)))

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
  e <- floatLit <|> (SInt <$> integerN True)
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
      ifE,
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

-- `if c then a else b` is exactly `case c of True -> a | False -> b`: sugar,
-- no new semantics.  Both branches take the block form, as a case arm does,
-- and `else if` chains because the else branch is an expression.  (Every
-- two-way choice used to be the four-token-longer case; parsers written in
-- FP-RISC were mostly that: docs/2026-09-20-STD.md.)
ifE :: P SExpr
ifE = do
  _ <- try (keyword "if")
  c <- expr
  _ <- keyword "then"
  o1 <- getOffset
  a <- block
  _ <- keyword "else"
  o2 <- getOffset
  b <- block
  pure (SCase c [(PCon "True" [], SMark o1 a), (PCon "False" [], SMark o2 b)])

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

-- the expression inside `{...}`.  A failure here is reported AT ITS
-- OWN POSITION: the statement around the string sits behind a `try`,
-- which would drop the error and report the next statement instead
-- (the battery saw `"{S.join}"` blamed on the line after it), so the
-- error is registered as a delayed one, the braces are skipped, and the
-- parse goes on; the bundle reports it at the end with the position.
interpolation :: P SExpr
interpolation = do
  r <- observing (expr <* char '}')
  case r of
    Right e -> pure e
    Left err -> do
      registerParseError err
      _ <- skipManyTill anySingle (char '}')
      pure (SInt 0)

stringLit :: P SExpr
stringLit = lexeme $ do
  _ <- char '"'
  segs <- manyTill seg (char '"')
  pure (SStrI (mergeSegs segs))
  where
    seg =
      choice
        [ SegExpr <$> (char '{' *> sc *> interpolation),
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
          -- a RUN of plain characters at a time (not one per segment:
          -- that was a segment per byte, merged by repeated append)
          SegStr . utf8Bytes <$> takeWhile1P Nothing (\c -> c /= '"' && c /= '{' && c /= '\\')
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
    -- adjacent text segments become one, concatenated ONCE per run:
    -- merging two at a time copied the growing head at every step
    -- (quadratic: a 100 KB literal took 116 s to lex)
    mergeSegs (SegStr a : r) = let (bs, r') = textRun r in SegStr (concat (a : bs)) : mergeSegs r'
    mergeSegs (x : r) = x : mergeSegs r
    mergeSegs [] = []
    textRun (SegStr b : t) = let (bs, t') = textRun t in (b : bs, t')
    textRun t = ([], t)

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
program = sc *> (concat <$> many (layoutDecl <|> ((: []) <$> topDecl))) <* eof

topDecl :: P STop
topDecl =
  choice
    [ try unsafeModuleDecl,
      try profileDecl,
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
  what <- lexeme (choice (map (\w -> try (string w <* notFollowedBy (satisfy identChar))) ("program" : "module" : profileNames)))
  dotTerm
  -- `unsafe base.` is the blanket marker AND the profile declaration in
  -- one line: the $module sig carries the profile as its type
  let carried = if what `elem` profileNames then what else "Unit"
  pure (TSig "$module" ([], TCon carried []) [Just ("$unsafe", SVar "$unsafe")])

-- `profile base.` -- what the program is written against (docs/2026-09-19-PROFILES.md):
-- the surface it may use and the systems it may run on.  Represented as
-- a TSig for the reserved name "$profile" whose type names the profile,
-- so no pass needs a new constructor.  The SYSTEM (bare metal, QOS,
-- posix) is the compiler's --system flag, not the file's business.
profileDecl :: P STop
profileDecl = do
  _ <- lexeme (string "profile" <* notFollowedBy (satisfy identChar))
  name <- lexeme (choice (map (\w -> try (string w <* notFollowedBy (satisfy identChar))) profileNames))
  dotTerm
  pure (TSig "$profile" ([], TCon name []) [])

-- the profile a file declares, from either form
evalDecl :: P STop
evalDecl = do
  _ <- try (lexeme (char '>' <* notFollowedBy (oneOf ">=")))
  e <- block
  dotTerm
  pure (TEval e)

layoutDecl :: P [STop]
layoutDecl = do
  -- committed once `Name = Layout` is read, so a bad field says why
  n <- try (upperName <* eqSign <* keyword "Layout")
  fs <- braces (field `sepBy1` symbol ",")
  dotTerm
  either fail pure (expandLayout n fs)
  where
    field = do
      f <- pName <|> (lexeme (char '_' <* notFollowedBy (satisfy identChar)) >> pure "_")
      _ <- lexeme (char ':')
      t <- upperName
      off <- optional (symbol "@" *> integer)
      pure (f, t, off)

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
  -- no fallback: a `name :` header that does not parse as a signature is a
  -- parse error at the offending token.  Until 2026-10-02 this backtracked
  -- to `skipTillDot >> pure TSkip`, which DROPPED the signature and let the
  -- body be inferred unannotated -- `f : Int -> Int | junk .` over a body
  -- returning a String compiled and ran (docs/2026-10-02-TOOLING-SEMANTICS-AUDIT.md).
  fullSig n
  where
    fullSig n = do
      mu <- optional (try (lexeme (string "unsafe" <* notFollowedBy (satisfy identChar))))
      parts <- sigPart `sepBy1` symbol "->"
      -- resource bounds after the result type (docs/2026-10-02-RESOURCE-BOUNDS.md):
      --   f : (a : Int) -> Int | work f <= 12 * a + 40 | alloc f <= 16 * a .
      --   map : (a -> b) -> (xs : List a) -> List b | size map <= len xs .
      -- carried as reserved entries ("$work" | "$alloc" | "$size", rhs)
      -- after the per-param list, like the $unsafe marker.  work and alloc
      -- are CHECKED against the derived cost; size (the result's length)
      -- is an ASSUMPTION callers substitute, reported as such.
      bounds <- many (pipeSep *> (expr >>= bound))
      dotTerm
      let mark = case mu of Just _ -> [Just ("$unsafe", SVar "$unsafe")]; Nothing -> []
      case parts of
        [] -> fail "empty signature"
        -- the $unsafe marker is APPENDED so the per-param precondition
        -- list stays position-aligned (consumers zip with params)
        ps -> pure (TSig n (map fst (init ps), fst (last ps)) (map snd (init ps) ++ mark ++ bounds))
      where
        bound e = case e of
          SBin "<=" lhs rhs | Just k <- kindOf lhs -> pure (Just ('$' : k, rhs))
          _ -> fail ("a signature bound is `work " ++ n ++ " <= ...`, `alloc " ++ n ++ " <= ...`, `live " ++ n ++ " <= ...` or `size " ++ n ++ " <= ...` (an upper bound in the parameters)")
        kindOf = \case
          SVar k | k `elem` ["work", "alloc", "live", "size"] -> Just k
          SApp (SVar k) (SVar f) | f == n, k `elem` ["work", "alloc", "live", "size"] -> Just k
          _ -> Nothing
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
      recordTy,
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
    -- a record type: `{ f : T, g : U }`, or `{ f : T | r }` open on the
    -- row variable r (shared across the signature by name).  Until
    -- 2026-10-02 this was not in the grammar: every signature mentioning a
    -- record (13 std modules) was silently dropped and never checked.
    recordTy = braces $ do
      fs <- recField `sepBy` symbol ","
      tl <- optional (pipeSep *> lowerName)
      pure (TRecT fs tl)
    recField = do
      f <- lowerName
      _ <- lexeme (char ':' <* notFollowedBy (char ':'))
      t <- tyArrowChain
      pure (f, t)


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

