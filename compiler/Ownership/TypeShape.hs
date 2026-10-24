-- Ownership shapes are a projection of checked types, independent of the
-- inference solver. Sharing this projection lets Core lint validate retained
-- shape annotations against the same linear-type model as source checking.
module Ownership.TypeShape (linShapeT) where
import Core.Syntax (Name)
import Type.Syntax
import Ownership.Shape

-- Infer.Type -> LShape, mirroring FPRISC.shapeOfTy's rules on the
-- inference-side type language: a linear-named TC is LL, a type variable
-- is symbolic (LVar: instantiated at each call, constrained by the body),
-- a generic type keeps its arguments' shapes (LCon), tuples/records
-- preserve their fields.  Functional types are LU: callable capture and
-- call multiplicity remain required compiler work (see the ownership audit).
linShapeT :: [Name] -> Type -> LShape
linShapeT linNs = go
  where
    go t = case t of
      TTupT ts -> LTupS (map go ts)
      TRec row -> let (fs, open) = fields row in LRecS fs open
      TC n | n `elem` linNs -> LL
      TV v -> LVar ('?' : show v)
      TAp _ _ ->
        let (h, as) = unroll t []
         in case h of
              TC n | n `elem` linNs -> lown n (map go as)
              TC n -> lcon n (map go as)
              _ -> if any (isLin . go) as then LL else LU
      _ -> LU
    unroll (TAp f a) acc = unroll f (a : acc)
    unroll h acc = (h, acc)
    fields (RExt f t r) = let (fs, open) = fields r in ((f, go t) : fs, open)
    fields RNil = ([], False)
    fields (RV _) = ([], True)

