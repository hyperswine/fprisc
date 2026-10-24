{-# OPTIONS_GHC -O2 #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# LANGUAGE LambdaCase, TupleSections #-}

-- Nominal raw-memory layout expansion into surface declarations.
module Frontend.MemoryLayout where

import Core.Syntax ( Name )
import Data.Char ( toUpper )
import Frontend.Syntax
    ( Ty(TCon),
      STop(TType, TSig, TBind),
      SPat(PVar),
      SExpr(SVar, SApp, SBin, SInt) )

expandLayout :: Name -> [(Name, Name, Maybe Integer)] -> Either String [STop]
expandLayout l fs0 = do
  placed <- place 0 fs0
  let named = [x | x@(f, _, _) <- placed, f /= "_"]
      dups = [f | (f, _, _) <- named, length [() | (g, _, _) <- named, g == f] > 1]
      clash = [f | (f, _, _) <- named, f `elem` ["at", "addr", "sizeOf", "index", "null", "isNull", "eq"]]
  case (dups, clash) of
    (f : _, _) -> Left ("Layout " ++ l ++ ": field `" ++ f ++ "` is declared twice")
    (_, f : _) -> Left ("Layout " ++ l ++ ": field `" ++ f ++ "` collides with the generated " ++ l ++ "." ++ f)
    _ -> pure ()
  -- like a C struct: the size rounds up to the WIDEST field's alignment, so
  -- `L.index` strides correctly over an array of them (a bank of 32-bit
  -- registers is 4 bytes apart, not 8)
  let widest = maximum (1 : [widthOf t | (_, t, _) <- placed])
      total = roundUp widest (maximum (0 : [o + widthOf t | (_, t, o) <- placed]))
  pure $
    [TType l False [] []]
      ++ def "at" [ty "Addr"] (ty l) ["a"] (cast (v "a"))
      ++ def "addr" [ty l] (ty "Addr") ["p"] (cast (v "p"))
      ++ def "sizeOf" [ty "Unit"] (ty "Int") ["u"] (SInt total)
      ++ def "index" [ty l, ty "Int"] (ty l) ["p", "i"]
           (cast (call "Addr.add" [addrOf, SBin "*" (v "i") (SInt total)]))
      ++ def "null" [ty "Unit"] (ty l) ["u"] (cast (call "Addr.null" [v "u"]))
      ++ def "isNull" [ty l] (ty "Bool") ["p"] (call "Addr.eq" [addrOf, call "Addr.null" [SVar "Unit"]])
      ++ def "eq" [ty l, ty l] (ty "Bool") ["p", "q"] (call "Addr.eq" [addrOf, cast (v "q")])
      ++ concat [fieldDefs f t o | (f, t, o) <- named]
  where
    v = SVar
    ty t = TCon t []
    call f = foldl SApp (SVar f)
    cast e = SApp (SVar "$cast") e
    -- a pointer field casts with `$cast` itself, not the other layout's
    -- at/addr: the accessor's SIGNATURE pins both ends, and a body with no
    -- call in it cannot grow under inlining.  (With a call inside, ARC's
    -- let-normal form pushed the body past Inline's size limit after one
    -- round, so sites exposed in round two -- a setter reached through a
    -- helper -- stayed calls, and kept the accessor in the image.)
    castTo _ e = cast e
    castFrom _ e = cast e
    -- flat on purpose: `$cast p`, not a call to L.addr -- an accessor is then one
    -- primitive expression and folds into its site in a single inlining round
    addrOf = cast (v "p")
    def f args res ps body =
      [ TSig (l ++ "." ++ f) (args, res) (map (const Nothing) args),
        TBind (l ++ "." ++ f) (map PVar ps) [] body
      ]
    widthOf t = case t of "U8" -> 1; "U16" -> 2; "U32" -> 4; _ -> 8
    roundUp a x = ((x + a - 1) `div` a) * a
    place _ [] = Right []
    place cur ((f, t, moff) : rest) = do
      let w = widthOf t
          o = maybe (roundUp w cur) id moff
      if o < 0 || o `mod` w /= 0
        then Left ("Layout " ++ l ++ ": field `" ++ f ++ "` at offset " ++ show o ++ " is not aligned to its " ++ show w ++ "-byte type " ++ t)
        else ((f, t, o) :) <$> place (o + w) rest
    fieldDefs f t o =
      let cap = toUpper (head f) : tail f
          at = if o == 0 then addrOf else call "Addr.add" [addrOf, SInt o]
          here = at
          (fty, get, set) = case t of
            "Word" -> (ty "Word", call "Mem.readWord" [here], call "Mem.writeWord" [here, v "x"])
            "Addr" -> (ty "Addr", call "Addr.fromWord" [call "Mem.readWord" [here]], call "Mem.writeWord" [here, call "Addr.toWord" [v "x"]])
            "Int" -> (ty "Int", call "Word.toInt" [call "Mem.readWord" [here]], call "Mem.writeWord" [here, call "Word.fromInt" [v "x"]])
            "U8" -> (ty "Int", call "Mem.read8" [here], call "Mem.write8" [here, v "x"])
            "U16" -> (ty "Int", call "Mem.read16" [here], call "Mem.write16" [here, v "x"])
            "U32" -> (ty "Word", call "Mem.read32" [here], call "Mem.write32" [here, v "x"])
            other ->
              ( ty other,
                castTo other (call "Addr.fromWord" [call "Mem.readWord" [here]]),
                call "Mem.writeWord" [here, call "Addr.toWord" [castFrom other (v "x")]]
              )
       in def (f ++ "At") [ty l] (ty "Addr") ["p"] at
            ++ def f [ty l] fty ["p"] get
            ++ def ("set" ++ cap) [ty l, fty] (ty "Unit") ["p", "x"] set

