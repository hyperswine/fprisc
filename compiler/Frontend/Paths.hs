{-# OPTIONS_GHC -O2 #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# LANGUAGE LambdaCase, TupleSections #-}

-- Typed path/schema expansion as a source-to-source transformation.
module Frontend.Paths where

import Core.Syntax ( Name )
import Data.Char ( isUpper )
import Data.List ( intercalate, nub )
import Frontend.Syntax
    ( Ty(TCon, TTup),
      STop(TStruct, TShape, TType, TBind),
      SGuard(GPat, GBool),
      SPat(PWild, PStr, PCon, PTup, PVar),
      SStmt(SBindPat, SBind),
      Seg(SegExpr, SegStr),
      SExpr(SStrI, SInt, SVar, SMark, SApp, SLam, SBlock, SCase, SBin,
            SProj, STup, SList, SRec, SUpd),
      mapGuardE )
import qualified Data.Map.Strict as M
    ( (!), lookup, notMember, fromList, Map )

shapeTyTable :: [STop] -> M.Map Name [(Name, Ty)]
shapeTyTable tops = M.fromList [(n, fs) | TShape n fs <- tops]

-- the declared SUM types, for codec literals (`@Msg`): name -> constructors
typeTyTable :: [STop] -> M.Map Name [(Name, [Ty])]
typeTyTable tops = M.fromList [(n, cs) | TType n _ _ cs <- tops]

expandPathLits :: M.Map Name [(Name, Ty)] -> M.Map Name [(Name, [Ty])] -> [STop] -> ([String], [STop])
expandPathLits tbl ttbl tops = (nub (concatMap errsTop tops), map top tops)
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

    -- `@Msg` where Msg is a declared SUM type: its wire codec (codecFor)
    codecTarget e = case e of
      SApp (SVar "Path") (SStrI [SegStr p])
        | not (null p), isUpper (head p), '.' `notElem` p,
          M.notMember p tbl, Just cs <- M.lookup p ttbl -> Just (p, cs)
      _ -> Nothing

    goE e
      | Just (p, root, fields, fs) <- pathTarget e =
          case rewriteLit p root fields fs of
            Right e' -> e'
            Left _ -> e -- reported via errsE; keep the tree well-formed
      | Just (p, cs) <- codecTarget e = either (const e) id (codecFor p cs)
    goE e = descend e

    errsE e
      | Just (p, root, fields, fs) <- pathTarget e =
          either (: []) (const []) (rewriteLit p root fields fs)
      | Just (p, cs) <- codecTarget e = either (: []) (const []) (codecFor p cs)
    errsE e = concatMap errsE (children e)

    -- THE CODEC.  A bare literal `@Msg` over a declared sum type is
    --
    --   { enc : Msg -> Wire, dec : Wire -> Result Msg String }
    --
    -- minted from the declaration, as a path is from a record's.  It is what
    -- lets a message cross a wire (a page, a log) as TEXT and still be a checked
    -- value of its type on the other side: an unknown constructor, a wrong
    -- number of fields or a field of the wrong kind is an Err that says so,
    -- never a value of the wrong shape.  Fields may be anything `wireable`
    -- accepts.  Ordinary code downstream: no new type-system machinery.
    codecFor p _ = case wireable [] (TCon p []) of
      Left why -> Left ("codec literal @" ++ bare p ++ ": " ++ why)
      Right () -> Right (SRec [("enc", encE (TCon p [])), ("dec", decE (TCon p []))])

    rewriteLit p root [] _ = schemaFor p root
    rewriteLit p root fields fs = do
      validate p root fields fs
      -- a field whose type can go on the wire also carries its codec, so a
      -- durable field needs nothing but its path (std/live.fpr `field`), and
      -- the ZERO of its type, a value to build a message around when the
      -- page supplies the field (std/view.fpr `sendWith codec Cash @Client.tender`)
      let codec = case fieldTy root fields of
            Just t | Right () <- wireable [] t -> [("enc", encE t), ("dec", decE t), ("zero", zeroE t)]
            _ -> []
      pure $
        SRec
          ( [ ("get", SLam ["s"] (SProj (SVar "s") fields)),
              ("set", SLam ["v", "s"] (SUpd (SVar "s") [(fields, SVar "v")])),
              ("segs", SList [SStrI [SegStr f] | f <- fields])
            ]
              ++ codec
          )

    fieldTy shape (f : rest) = case lookup f =<< M.lookup shape tbl of
      Just t | null rest -> Just t
      Just (TCon sub []) -> fieldTy sub rest
      _ -> Nothing
    fieldTy _ [] = Nothing

    -- ---- the wire: encoders and decoders BY TYPE STRUCTURE ---------------------
    -- Int, String, Bool, List t, tuples, declared records and declared sum types
    -- (recursively) go through the prelude's neutral `Wire` tree.  The code is
    -- generated inline at the literal, from prelude names only, so it is
    -- ordinary code in whichever unit holds the literal.  A RECURSIVE type is
    -- refused: inlining it would not end.
    wireable seen t = case t of
      TCon "Int" [] -> Right ()
      TCon "String" [] -> Right ()
      TCon "Bool" [] -> Right ()
      TCon "List" [a] -> wireable seen a
      TTup ts -> mapM_ (wireable seen) ts
      TCon n []
        | n `elem` seen -> Left ("type " ++ n ++ " is recursive: it cannot go on the wire yet")
        | Just fs <- M.lookup n tbl -> mapM_ (wireable (n : seen) . snd) fs
        | Just cs <- M.lookup n ttbl -> mapM_ (mapM_ (wireable (n : seen)) . snd) cs
      _ -> Left "a field's type is not Int, String, Bool, a List or tuple of those, or a declared record or sum type"

    bare c = reverse (takeWhile (/= '.') (reverse (takeWhile (/= '@') c)))
    lit x = SStrI [SegStr x]
    app f xs = foldl SApp (SVar f) xs

    encE t = case t of
      TCon "Int" [] -> SVar "WInt"
      TCon "String" [] -> SVar "WStr"
      TCon "Bool" [] -> SVar "WBool"
      TCon "List" [a] -> SLam ["xs"] (SApp (SVar "WList") (app "wireMap" [encE a, SVar "xs"]))
      TTup ts ->
        let vs = ["t" ++ show i | i <- [1 .. length ts]]
         in SLam ["p"] (SCase (SVar "p") [(PTup (map PVar vs), SApp (SVar "WList") (SList [SApp (encE ti) (SVar v) | (ti, v) <- zip ts vs]))])
      TCon n []
        | Just fs <- M.lookup n tbl ->
            SLam ["r"] (SApp (SVar "WRec") (SList [STup [lit f, SApp (encE ft) (SProj (SVar "r") [f])] | (f, ft) <- fs]))
        | Just cs <- M.lookup n ttbl ->
            SLam ["m"] (SCase (SVar "m")
              [ (PCon c [PVar ("f" ++ show i) | (i, _) <- zip [1 :: Int ..] tys],
                 app "WCon" [lit (bare c), SList [SApp (encE ti) (SVar ("f" ++ show i)) | (i, ti) <- zip [1 :: Int ..] tys]])
              | (c, tys) <- cs ])
      _ -> SVar "WStr"

    -- decoders answer Result a String; `wireAnd` is bind, `wireAt` names the place
    decE t = case t of
      TCon "Int" [] -> SVar "wireToInt"
      TCon "String" [] -> SVar "wireToStr"
      TCon "Bool" [] -> SVar "wireToBool"
      TCon "List" [a] -> SApp (SVar "wireToList") (decE a)
      TTup ts ->
        let n = length ts
            ws = ["w" ++ show i | i <- [1 .. n]]
            vs = ["v" ++ show i | i <- [1 .. n]]
            done = SApp (SVar "Ok") (STup (map SVar vs))
            step (ti, w, v) rest = app "wireAnd" [SApp (decE ti) (SVar w), SLam [v] rest]
         in SLam ["w"] (SCase (SVar "w")
              [ (PCon "WList" [foldr (\x acc -> PCon "Cons" [PVar x, acc]) (PCon "Nil" []) ws], foldr step done (zip3 ts ws vs)),
                (PWild, SApp (SVar "Err") (lit ("expected a " ++ show n ++ "-tuple"))) ])
      TCon n []
        | Just fs <- M.lookup n tbl ->
            let vs = ["v" ++ show i | i <- [1 .. length fs]]
                done = SApp (SVar "Ok") (SRec [(f, SVar v) | ((f, _), v) <- zip fs vs])
                step ((f, ft), v) rest =
                  app "wireAnd" [app "wireAt" [lit f, app "wireAnd" [app "wireField" [lit f, SVar "fs"], decE ft]], SLam [v] rest]
             in SLam ["w"] (SCase (SVar "w")
                  [ (PCon "WRec" [PVar "fs"], foldr step done (zip fs vs)),
                    (PWild, SApp (SVar "Err") (lit ("expected a " ++ bare n ++ " record"))) ])
        | Just cs <- M.lookup n ttbl ->
            let con (c, tys) =
                  let k = length tys
                      ws = ["w" ++ show i | i <- [1 .. k]]
                      vs = ["v" ++ show i | i <- [1 .. k]]
                      done = SApp (SVar "Ok") (foldl SApp (SVar c) (map SVar vs))
                      step (i, ti, w, v) rest = app "wireAnd" [app "wireAt" [lit (bare c ++ " field " ++ show i), SApp (decE ti) (SVar w)], SLam [v] rest]
                   in ( PStr (bare c),
                        SCase (SVar "as")
                          [ (foldr (\x acc -> PCon "Cons" [PVar x, acc]) (PCon "Nil" []) ws, foldr step done (zip4' [1 :: Int ..] tys ws vs)),
                            (PWild, SApp (SVar "Err") (lit (bare c ++ ": expected " ++ show k ++ " field(s)"))) ] )
             in SLam ["w"] (app "wireAnd" [SApp (SVar "wireCon") (SVar "w"),
                  SLam ["na"] (SCase (SVar "na")
                    [ (PTup [PVar "n", PVar "as"],
                       SCase (SVar "n") (map con cs ++ [(PWild, SApp (SVar "Err") (SStrI [SegStr (bare n ++ ": no such message: "), SegExpr (SVar "n")]))])) ])])
      _ -> SVar "wireToStr"
    zip4' (a : as) (b : bs) (c : cs) (d : ds) = (a, b, c, d) : zip4' as bs cs ds
    zip4' _ _ _ _ = []

    -- the zero of a wireable type: 0, "", False, Nil, tuples and records of
    -- zeros, a sum type's FIRST constructor over zeros.  `wireable` has
    -- refused recursive types, so this ends.
    zeroE t = case t of
      TCon "Int" [] -> SInt 0
      TCon "String" [] -> lit ""
      TCon "Bool" [] -> SVar "False"
      TCon "List" [_] -> SList []
      TTup ts -> STup (map zeroE ts)
      TCon n []
        | Just fs <- M.lookup n tbl -> SRec [(f, zeroE ft) | (f, ft) <- fs]
        | Just ((c, tys) : _) <- M.lookup n ttbl -> foldl SApp (SVar c) (map zeroE tys)
      _ -> lit ""

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

    -- the schema: flatten every leaf under the root alias that can go on
    -- the wire, each entry
    --
    --   { path   = "a.b",
    --     tag    = "int" | "str" | "bool" | "enum" | "wire",
    --     wire   = fn s -> <the leaf, through its codec>,
    --     unwire = fn w s -> <s with the leaf decoded from w> or the Err }
    --
    -- "enum" is a declared sum type of bare constructors, "wire" any other
    -- leaf with a codec (a list, a tuple, a sum with fields).  Text reaches a
    -- leaf through the SAME codec (std/lens hands `unwire` the text as a
    -- WStr, and the decoders read numbers, booleans and bare constructors
    -- from text), so the string tier cannot disagree with the typed one and
    -- a bad value is an Err, never a guess.  A leaf with no codec (a
    -- function) is typed-tier-only.  visited guards against a (declared)
    -- recursive shape cycle.
    schemaFor p root = SList . map entry <$> leaves p [root] [] (tbl M.! root)
    leaves p visited pre fs = concat <$> mapM leaf fs
      where
        leaf (f, TCon sub [])
          | Just fs' <- M.lookup sub tbl =
              if sub `elem` visited
                then
                  Left
                    ( "schema @" ++ p ++ ": shape " ++ sub
                        ++ " recursively contains itself -- cannot flatten"
                    )
                else leaves p (sub : visited) (pre ++ [f]) fs'
        leaf (f, t) = case wireable [] t of
          Right () -> pure [(pre ++ [f], leafTag t, t)]
          Left _ -> pure []
    leafTag t = case t of
      TCon "Int" [] -> "int"
      TCon "String" [] -> "str"
      TCon "Bool" [] -> "bool"
      TCon n [] | Just cs <- M.lookup n ttbl, all (null . snd) cs -> "enum"
      _ -> "wire"
    entry (segs, tag, t) =
      SRec
        [ ("path", lit (intercalate "." segs)),
          ("tag", lit tag),
          ("wire", SLam ["s"] (SApp (encE t) (SProj (SVar "s") segs))),
          ("unwire", SLam ["w", "s"] (app "wireAnd" [SApp (decE t) (SVar "w"), SLam ["x"] (SApp (SVar "Ok") (SUpd (SVar "s") [(segs, SVar "x")]))]))
        ]

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
