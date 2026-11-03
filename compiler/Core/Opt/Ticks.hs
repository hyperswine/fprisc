-- Batched fuel ticks in self-looping functions.
--
-- Inlining keeps an inlined callee's entry tick (`let t = $fuel 0 in b`,
-- Core/Typed/Inline.hs and Inline.hs), so fuel still counts calls. A function
-- that calls itself ticks on every invocation, and when codegen turns the self
-- tail call into a loop (Codegen.Allocate.loopForm) that entry tick sits on the
-- loop head, so the ticks of the callees inlined into the body are redundant:
-- every iteration still charges one unit, and the work between two ticks stays
-- bounded by the body, because an inlined callee is non-recursive and a call
-- that was not inlined ticks at its own entry.
module Core.Opt.Ticks (batchTicks, selfLooping, selfLoopingWith, batchProgramTicks) where
import Core.Primitives (entryTickName)
import Core.Syntax (Core(..), Prog)
import Core.Utils (spineOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- The body-size bound the scalar workers already use (Workers.hs): batching
-- keeps one tick per iteration, so a body larger than this keeps its inlined
-- ticks and the work between two ticks with them.
bodyBound :: Int
bodyBound = 1024

-- A direct call to the function itself, at any unshadowed call position.
selfLooping :: String -> Core -> Bool
selfLooping = selfLoopingWith S.empty

selfLoopingWith :: S.Set String -> String -> Core -> Bool
selfLoopingWith params name body
  | S.member name params = False
  | otherwise = go params body
  where
    go bound e =
      (case spineOf e of
        (CVar h, _ : _) -> h == name && S.notMember h bound
        _ -> False)
      || case e of
        CLet x a b -> go bound a || go (S.insert x bound) b
        CLam ps b -> go (S.union (S.fromList ps) bound) b
        _ -> any (go bound) (children e)

-- Drop inlined callees' entry ticks (`let t = $fuel 0 in b`, t unused) from a
-- self-looping body. Every other position is rebuilt unchanged, including the
-- inside of a lambda: a lambda's callers do not tick for it.
batchTicks :: Core -> Core
batchTicks e = case e of
  CLet n a b | isTick a, not (mentions n b) -> batchTicks b
  CLet n a b -> CLet n (batchTicks a) (batchTicks b)
  CIf a b c -> CIf (batchTicks a) (batchTicks b) (batchTicks c)
  CMk t v xs -> CMk t v (map batchTicks xs)
  CTagEq t v x -> CTagEq t v (batchTicks x)
  CProj k x -> CProj k (batchTicks x)
  CApp f x -> CApp (batchTicks f) (batchTicks x)
  _ -> e
  where
    isTick x = case spineOf x of (CVar h,[CInt _]) -> h == entryTickName; _ -> False
    mentions v (CVar x) = x == v
    mentions v (CLet x a b) = mentions v a || (x /= v && mentions v b)
    mentions v (CLam ps b) = v `notElem` ps && mentions v b
    mentions v x = any (mentions v) (children x)

children :: Core -> [Core]
children e = case e of
  CApp a b -> [a,b]; CLet _ a b -> [a,b]; CIf a b c -> [a,b,c]
  CMk _ _ xs -> xs; CTagEq _ _ x -> [x]; CProj _ x -> [x]
  CLam _ x -> [x]; _ -> []

size :: Core -> Int
size e = 1 + sum (map size (children e))

-- Every self-looping function within the bound keeps one tick per iteration.
-- A note is reported only when the pass had something to decide.
batchProgramTicks :: Prog -> (Prog, [String])
batchProgramTicks prog = (M.mapWithKey one prog, note)
  where
    isLoop name (ps, b) = selfLoopingWith (S.fromList ps) name b
    one name def@(ps, b)
      | isLoop name def && size b <= bodyBound = (ps, batchTicks b)
      | otherwise = def
    loops = [(name, size b) | (name, def@(_, b)) <- M.toList prog, isLoop name def]
    batched = length [() | (_, n) <- loops, n <= bodyBound]
    declined = [name ++ " (" ++ show n ++ " nodes)" | (name, n) <- loops, n > bodyBound]
    note
      | null loops = []
      | otherwise = ["# tick batching: self-loops=" ++ show (length loops) ++ " batched=" ++ show batched
                     ++ concatMap (\name -> "; declined " ++ name) declined]
