-- Codegen.Frame: symbolic frame objects and their final layout
-- (docs/2026-10-20-TYPED-NATIVE-IR-PLAN.md, "Calls, frames and runtime
-- integration": keep frame objects symbolic, including alignment, size,
-- managed-reference status and address escape).
--
-- Selection and placement create frame objects by reference and never
-- name an offset; `layout` assigns the offsets once the set is complete.
-- The layout reproduces the legacy generated-code frame
-- (Codegen.compileFnBody, docs/2026-10-19-REGISTER-ALLOCATION.md 1.1):
-- the link area holds the return address at fp-W and the caller's frame
-- pointer at fp-2W, objects follow below it in creation order, and the
-- frame is a multiple of the alignment.  Nothing is shared or reused: M2
-- gives every object its own bytes; slot reuse with compatible lifetime,
-- representation and root status is M3's.
module Codegen.Frame
  ( FrameRef (..), FrameKind (..), FrameObj (..), Layout (..),
    layout, frameObj,
  ) where

import qualified Data.Map.Strict as M

newtype FrameRef = FrameRef Int deriving (Eq, Ord, Show)

data FrameKind
  = SpillSlot Int -- the home of virtual register n
  | SavedRegister String -- a callee-saved register parked for the function's duration
  | Temporary -- scratch the target's expansions own
  deriving (Eq, Ord, Show)

data FrameObj = FrameObj
  { foRef :: FrameRef,
    foSize :: Int, -- bytes
    foAlign :: Int, -- bytes; a power of two
    foKind :: FrameKind,
    foManaged :: Bool, -- may hold a managed reference the runtime must see (a tagged word in M2: yes)
    foEscapes :: Bool -- its address is taken; never a candidate for reuse
  }
  deriving (Eq, Ord, Show)

frameObj :: Int -> Int -> Int -> FrameKind -> Bool -> FrameObj
frameObj n size align kind managed = FrameObj (FrameRef n) size align kind managed False

data Layout = Layout
  { lyBytes :: Int, -- the whole frame: link area and objects, aligned
    lyLinkBytes :: Int, -- the link area at the top of the frame
    lyOffset :: M.Map FrameRef Int -- each object's offset from the frame pointer (negative)
  }
  deriving (Eq, Show)

-- link bytes, frame alignment, the objects in creation order
layout :: Int -> Int -> [FrameObj] -> Layout
layout link align objs =
  let step (off, acc) o =
        let off' = roundDown (off - foSize o) (foAlign o)
         in (off', (foRef o, off') : acc)
      (bottom, offs) = foldl step (negate link, []) objs
      bytes = roundUp (negate bottom) align
   in Layout bytes link (M.fromList offs)
  where
    roundDown x a = x - (x `mod` a)
    roundUp x a = ((x + a - 1) `div` a) * a
