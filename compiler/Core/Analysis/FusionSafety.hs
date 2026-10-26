module Core.Analysis.FusionSafety (fusionSafe, fusionUnsafeReason) where
import Core.Syntax
import Core.Utils
import Core.Primitives
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (isSuffixOf)

-- EFFECT ORDER (docs/2026-10-03-FUSION-EFFECT-ORDER.md).  Two
-- materializing maps run the first over EVERY element before the second
-- starts; a fused pass interleaves them per element.  That is only
-- unobservable when neither element function can be observed running:
-- no I/O, no sends, no mutation, and no FAILURE either, since a panic in
-- the first map on element 2 must come before any work of the second
-- map on element 1.  `fusionSafe` is that judgement: the function and
-- every known callee use only locals, literals, constructors, tag tests,
-- projections, if/let, the arithmetic/comparison/logic primitives and
-- the fuel tick -- Int + - * trap on overflow since 2026-10-12, and the
-- 2026-10-13 relaxation lets a fused pair raise that one trap out of
-- order (safePrims below).  Division is excluded (it traps), as is
-- every other primitive, every call through a parameter, and every
-- partial application.  Declined pairs are reported, never silent.
fusionSafe :: Prog -> String -> Bool
fusionSafe prog f = fusionUnsafeReason prog f == Nothing

-- the first construct that makes a function observable, if any
fusionUnsafeReason :: Prog -> String -> Maybe String
fusionUnsafeReason prog = go S.empty
  where
    go seen n
      | S.member n seen = Nothing
      | otherwise = case M.lookup n prog of
          Nothing -> Just ("`" ++ n ++ "` is not a known function")
          Just (ps, body) -> body' (S.insert n seen) (S.fromList ps) body
    body' _ _ e | Just _ <- floatLitBits e = Nothing
    body' seen env e = case spineOf e of
      (CVar h, args@(_ : _))
        | h `elem` safePrims, Just ar <- lookup h primArities, length args == ar -> firstJust (map (body' seen env) args)
        | h `elem` safePrims -> Just ("a partial application of `" ++ h ++ "`")
        | h == entryTickName -> Nothing
        | S.member h env -> Just ("a call through the parameter `" ++ h ++ "` (unknown function)")
        | Just (ps, _) <- M.lookup h prog, length ps == length args -> firstJust (map (body' seen env) args ++ [go seen h])
        | Just _ <- M.lookup h prog -> Just ("a partial application of `" ++ h ++ "`")
        | otherwise -> Just ("the primitive `" ++ h ++ "`")
      _ -> case e of
        CVar v | S.member v env -> Nothing
        CVar g | Just (ps, _) <- M.lookup g prog, null ps -> go seen g -- a CAF
        CVar g -> Just ("the function value `" ++ g ++ "`")
        CInt _ -> Nothing
        CStr _ -> Nothing
        CMk _ _ fs -> firstJust (map (body' seen env) fs)
        CTagEq _ _ x -> body' seen env x
        CProj _ x -> body' seen env x
        CIf c t f -> firstJust (map (body' seen env) [c, t, f])
        CLet x a b -> firstJust [body' seen env a, body' seen (S.insert x env) b]
        CLam ps b -> body' seen (S.union (S.fromList ps) env) b
        CErr _ -> Nothing -- an exhaustiveness-proven dead arm
        _ -> Just "an unrecognized construct"
    firstJust xs = case [r | Just r <- xs] of
      (r : _) -> Just r
      [] -> Nothing
    -- cannot be OBSERVED: everything in the Int/F64/F32 arithmetic tiers
    -- except division, plus comparison and logic.  Int + - * trap on
    -- overflow (docs/2026-10-12-INT-OVERFLOW.md); a fused pair may then
    -- panic on an earlier element, or in the other function, than the
    -- two passes would -- the ONE reordering fusion is allowed, by the
    -- relaxation of 2026-10-13 (docs/2026-10-03-FUSION-EFFECT-ORDER.md):
    -- the program still fail-stops with an Int overflow, and the pair
    -- was its own two passes otherwise.  Division stays out: a zero
    -- divisor is a different failure, and the line is kept narrow.
    safePrims =
      [op | op <- uPrims, op /= "/"]
        ++ [op | w <- [Float64, Float32], op <- fPrimsOf w, not ("/" `isSuffixOf` op) && op /= "F" ++ floatWidthName w ++ "./"]
        ++ ["and", "or", "not", "and2", "or2"]

