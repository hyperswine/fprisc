-- Codegen.Liveness: live ranges over a selected stream
-- (docs/2026-10-20-TYPED-NATIVE-IR-PLAN.md, milestone M3: "liveness and an
-- initial linear-scan allocator").
--
-- The selected stream (Codegen.Selected) is a list of labels and
-- instructions over virtual registers.  It is not SSA: a block parameter
-- is written by every predecessor's parallel copy, and a loop-carried one
-- is written again at the loop's tail.  Liveness is therefore the classic
-- backward dataflow over the stream's basic blocks (a label starts one, a
-- transfer ends one), and each virtual register is then summarised as ONE
-- interval on the position line: from the first point where it is live to
-- the last.  Holes inside the interval are ignored, which is conservative:
-- a value is treated as live wherever the interval says so, so a register
-- assigned to it is never reused inside the interval, and every clobber
-- point inside the interval counts as crossed.
--
-- Positions: instruction i sits at position 2i.  A value live out of a
-- block whose last instruction is at 2q ends at 2q+1 (strictly after that
-- instruction, strictly before the next); a value live into a block whose
-- first instruction is at 2f starts at 2f-1.  So an interval that STARTS at
-- an even position starts with a definition by that instruction, and one
-- that ENDS at an even position ends with a use by that instruction;
-- those are the only two points where an allocator may let two intervals
-- meet in one register.
--
-- What the allocator reads from here, per virtual register: the interval,
-- the positions of its definitions and uses, and `reservedAt`, the physical
-- registers an instruction names beyond its virtual operands (fixed
-- operands, implicit uses and definitions, clobbers): a value whose
-- interval contains such a position may not sit in such a register.
module Codegen.Liveness
  ( Pos, Interval (..), Liveness (..), SBlock (..),
    analyseLiveness, blocksOf, reservedAt, instrUses, instrDefs,
    containsPos, crossesPos, instrLiveSets, loopDepths,
  ) where

import Codegen.Selected
import Data.List (foldl', sort)
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import qualified Data.Map.Strict as M
import qualified Data.Set as S

type Pos = Int

data Interval = Interval
  { ivStart :: Pos, -- even: defined there; odd: live into the block that follows
    ivEnd :: Pos, -- even: last used there; odd: live out of the block that precedes
    ivDefs :: [Pos], -- instruction positions that define the value
    ivUses :: [Pos], -- instruction positions that use the value
    ivSegments :: [(Pos, Pos)] -- the interval with its holes at block granularity, sorted, disjoint, inside [ivStart, ivEnd]
  }
  deriving (Eq, Show)

-- a basic block of the stream: the instructions [sbFirst .. sbLast] (as
-- instruction indices, not positions), its labels and its successors
data SBlock = SBlock
  { sbLabels :: [Label],
    sbFirst :: Int,
    sbLast :: Int, -- sbLast < sbFirst: an empty block (labels only, at the end)
    sbSuccs :: [Int] -- block indices
  }
  deriving (Eq, Show)

data Liveness = Liveness
  { lvInstrs :: [(Pos, SInstr)], -- the instructions with their positions, in order
    lvBlocks :: [SBlock],
    lvIntervals :: M.Map VReg Interval, -- only values that are used somewhere (a dead definition has none)
    lvLive :: IM.IntMap (IS.IntSet, IS.IntSet) -- per position: the values live into and out of that instruction (exact, holes included)
  }

instrUses, instrDefs :: SInstr -> [VReg]
instrUses i = [v | OV v _ <- siUses i]
instrDefs i = [v | OV v _ <- siDefs i]

-- the physical registers an instruction names beyond its virtual operands
reservedAt :: SInstr -> S.Set Phys
reservedAt i =
  S.fromList
    ( siImplicitDefs i ++ siImplicitUses i ++ siClobbers i
        ++ [p | OV _ (Fix p) <- siDefs i ++ siUses i]
        ++ [p | OP p <- siDefs i ++ siUses i]
    )

containsPos :: Interval -> Pos -> Bool
containsPos iv p = ivStart iv <= p && p <= ivEnd iv

-- strictly inside: the value is live before and after the instruction there
crossesPos :: Interval -> Pos -> Bool
crossesPos iv p = ivStart iv < p && p < ivEnd iv

-- the basic blocks of a stream: a label starts a block (consecutive labels
-- share one), an instruction whose control is not Next ends one; the
-- fall-through successor is the next block, a branch's targets are found
-- by label
blocksOf :: [Item] -> [SBlock]
blocksOf items = [b {sbSuccs = succs k b e} | (k, (b, e)) <- zip [0 ..] raw]
  where
    -- (labels, first, count, last instruction) of the open block
    raw = go [] 0 (0 :: Int) Nothing items 0
    go ls f cnt _ [] n
      | cnt > 0 || not (null ls) = [(SBlock (reverse ls) f (n - 1) [], Nothing)]
      | otherwise = []
    go ls f cnt _ (ILabel l : rest) n
      | cnt > 0 = (SBlock (reverse ls) f (n - 1) [], Nothing) : go [l] n 0 Nothing rest n
      | otherwise = go (l : ls) n 0 Nothing rest n
    go ls f cnt _ (I i : rest) n =
      let f' = if cnt == 0 then n else f
       in case siControl i of
            Next -> go ls f' (cnt + 1) Nothing rest (n + 1)
            _ -> (SBlock (reverse ls) f' n [], Just i) : go [] (n + 1) 0 Nothing rest (n + 1)
    byLabel = M.fromList [(l, k) | (k, (b, _)) <- zip [0 ..] raw, l <- sbLabels b]
    target l = M.findWithDefault (error ("liveness: undefined label " ++ show l)) l byLabel
    succs k _ e =
      let next = [k + 1 | k + 1 < length raw]
       in case e of
            Nothing -> next
            Just i -> case siControl i of
              Next -> next
              CondTo ls -> map target ls ++ next
              JumpTo l -> [target l]
              Return -> []

analyseLiveness :: [Item] -> Liveness
analyseLiveness items = Liveness instrs blocks intervals live
  where
    vn (VReg n) = n
    sets = instrLiveSets (map vn . instrUses) (map vn . instrDefs) items
    instrs = zip [0, 2 ..] [i | (i, _, _) <- sets]
    live = IM.fromList [(p, (inn, out)) | (p, (_, inn, out)) <- zip [0, 2 ..] sets]
    blocks = blocksOf items
    -- the intervals from the block-level sets (never by enumerating the
    -- per-instruction sets, whose total size is the overlap of all ranges):
    -- from a definition at 2i or the entry of a block at 2f-1 to a use at
    -- 2i or the exit of a block at 2q+1
    firstOf b = [(VReg n, 2 * sbFirst b - 1) | sbLast b >= sbFirst b, n <- IS.toList (blockIn b)]
    lastOf b = [(VReg n, 2 * sbLast b + 1) | sbLast b >= sbFirst b, n <- IS.toList (blockOut b)]
    setAt k = IM.findWithDefault IS.empty k byIndexSets
    byIndexSets = IM.fromList (zip [0 ..] [inn | (_, inn, _) <- sets])
    outAt k = IM.findWithDefault IS.empty k byIndexOuts
    byIndexOuts = IM.fromList (zip [0 ..] [out | (_, _, out) <- sets])
    blockIn b = setAt (sbFirst b)
    blockOut b = outAt (sbLast b)
    defPositions = M.fromListWith (flip (++)) [(v, [p]) | (p, i) <- instrs, v <- instrDefs i]
    usePositions = M.fromListWith (flip (++)) [(v, [p]) | (p, i) <- instrs, v <- instrUses i]
    entries = M.fromListWith min (concatMap firstOf blocks)
    exits = M.fromListWith max (concatMap lastOf blocks)
    intervals =
      M.fromList
        [ (v, Interval (fst (head segs)) (snd (last segs)) ds us segs)
          | (v, us) <- M.toList usePositions,
            let ds = M.findWithDefault [] v defPositions
                segs = merge (M.findWithDefault [] v pieces)
        ]
    -- Segments: per block, a value occupies from its entry (live in) or its
    -- first definition or use there, to its exit (live out) or its last
    -- definition or use there.  A hole inside one block (a last use, then a
    -- redefinition that is live out) is not split: conservative.  Pieces of
    -- consecutive blocks meet at the odd position between them and merge.
    byIdx = IM.fromList (zip [0 ..] [i | (_, i) <- instrs])
    pieces =
      M.fromListWith (++)
        [ (VReg n, [(lo, hi)])
          | b <- reverse blocks,
            sbLast b >= sbFirst b,
            let occ =
                  IM.fromListWith (\(a1, b1) (a2, b2) -> (min a1 a2, max b1 b2))
                    [ (n', (2 * k, 2 * k))
                      | k <- [sbFirst b .. sbLast b],
                        VReg n' <- let i = byIdx IM.! k in instrDefs i ++ instrUses i
                    ]
                ins = blockIn b
                outs = blockOut b,
            n <- IS.toList (IS.unions [ins, outs, IM.keysSet occ]),
            let lo = if IS.member n ins then 2 * sbFirst b - 1 else fst (occ IM.! n)
                hi = if IS.member n outs then 2 * sbLast b + 1 else snd (occ IM.! n)
        ]
    merge = go . sort
      where
        go ((a1, b1) : (a2, b2) : rest) | a2 <= b1 + 1 = go ((a1, max b1 b2) : rest)
        go (x : rest) = x : go rest
        go [] = []

-- Per-instruction live-in and live-out sets over any integer-keyed
-- register notion (virtual registers, or physical registers for the
-- post-allocation oracle): the block dataflow, then a backward walk
-- inside each block.  Labels are skipped; the result is in stream order.
instrLiveSets :: (SInstr -> [Int]) -> (SInstr -> [Int]) -> [Item] -> [(SInstr, IS.IntSet, IS.IntSet)]
instrLiveSets usesOf defsOf items = concat [walk k | k <- [0 .. nblocks - 1]]
  where
    raw = [i | I i <- items]
    byIndex = IM.fromList (zip [0 ..] raw)
    blocks = blocksOf items
    nblocks = length blocks
    bmap = IM.fromList (zip [0 ..] blocks)
    genKill b = foldl' step (IS.empty, IS.empty) [byIndex IM.! k | k <- [sbFirst b .. sbLast b]]
      where
        step (g, kl) i =
          let us = IS.fromList (usesOf i)
              ds = IS.fromList (defsOf i)
           in (IS.union g (IS.difference us kl), IS.union kl ds)
    gks = IM.map genKill bmap
    empty = IM.fromList [(k, IS.empty) | k <- [0 .. nblocks - 1]]
    (_, liveOut) = fixpoint (empty, empty)
      where
        fixpoint st = let st' = step st in if st' == st then st else fixpoint st'
        step (li, lo) = foldl' visit (li, lo) (reverse [0 .. nblocks - 1])
        visit (li, lo) k =
          let b = bmap IM.! k
              out = IS.unions [li IM.! s | s <- sbSuccs b]
              (g, kl) = gks IM.! k
              inn = IS.union g (IS.difference out kl)
           in (IM.insert k inn li, IM.insert k out lo)
    walk k =
      let b = bmap IM.! k
          ins = [byIndex IM.! n | n <- [sbFirst b .. sbLast b]]
          go _ [] = []
          go out (i : rest) =
            let inn = IS.union (IS.fromList (usesOf i)) (IS.difference out (IS.fromList (defsOf i)))
             in (i, inn, out) : go inn rest
       in reverse (go (liveOut IM.! k) (reverse ins))

-- The loop depth of each block of a stream (block index -> depth): the
-- natural loops of its back edges (an edge to a block on the depth-first
-- stack), one per header, body = the blocks that reach a latch without
-- passing the header.  Irreducible cycles still count the blocks a retreating
-- edge reaches, which is what a spill weight needs.
loopDepths :: [SBlock] -> IM.IntMap Int
loopDepths blocks = IM.fromListWith (+) ([(k, 0) | k <- [0 .. n - 1]] ++ [(k, 1) | body <- bodies, k <- IS.toList body])
  where
    n = length blocks
    succsOf = IM.fromList (zip [0 ..] (map sbSuccs blocks))
    predsOf = IM.fromListWith (++) [(t, [k]) | (k, ts) <- IM.toList succsOf, t <- ts]
    -- iterative DFS collecting back edges
    backs = dfs [(0, IM.findWithDefault [] 0 succsOf)] (IS.singleton 0) (IS.singleton 0) []
      where
        dfs [] _ _ acc = acc
        dfs ((k, []) : stack) seen onStack acc = dfs stack seen (IS.delete k onStack) acc
        dfs ((k, t : ts) : stack) seen onStack acc
          | IS.member t onStack = dfs ((k, ts) : stack) seen onStack ((k, t) : acc)
          | IS.member t seen = dfs ((k, ts) : stack) seen onStack acc
          | otherwise = dfs ((t, IM.findWithDefault [] t succsOf) : (k, ts) : stack) (IS.insert t seen) (IS.insert t onStack) acc
    headers = IM.fromListWith (++) [(h, [l]) | (l, h) <- backs]
    bodies = [grow h (IS.singleton h) ls | (h, ls) <- IM.toList headers, n > 0]
    grow _ acc [] = acc
    grow h acc (k : ks)
      | IS.member k acc = grow h acc ks
      | otherwise = grow h (IS.insert k acc) (IM.findWithDefault [] k predsOf ++ ks)
