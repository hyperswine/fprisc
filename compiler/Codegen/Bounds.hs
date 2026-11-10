-- Codegen.Bounds: structured segment analysis over a final selected
-- stream (docs/2026-10-21-NATIVE-IR-CONTRACTS.md, "Bounds, consumers and
-- compatibility strategy", items 2 and 3).
--
-- The metric is `native-insns-v1`: the maximum number of target
-- instructions on any path between two consecutive safepoint boundaries
-- (the entry fuel tick, an inlined tick, a call to a generated function
-- whose entry ticks, a tail transfer to one), counted on the stream as it
-- is printed, after placement, frame expansion and every pseudo's
-- expansion.  Calls into C are counted separately (`ccalls`) and bound
-- nothing here: their cost is the runtime's.  A cycle with no boundary is
-- UNBOUNDED, loudly.
--
-- It is not the retired `# wcet:` metric, which counted shared-RISC lines
-- on the retired slot generator's emission.
-- Neither is elapsed time.
module Codegen.Bounds (Tok (..), Flow (..), Report (..), analyse, reportLine, tickWeights) where

import Data.List (foldl')
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data Flow
  = FNext -- falls through
  | FCond [String] -- may go to these labels, else falls through
  | FJump String -- always
  | FExit -- leaves the function
  deriving (Eq, Show)

data Tok
  = TLabel String
  | TIns
      { tCost :: Int, -- target instructions this item prints
        tFlow :: Flow,
        tReset :: Bool, -- its last instruction is a safepoint boundary
        tCCalls :: Int -- calls into C inside it
      }
  deriving (Eq, Show)

data Report = Report
  { rSegMax :: Maybe Int, -- Nothing: UNBOUNDED
    rExitTail :: Maybe Int, -- the longest run from a boundary to an exit
    rCCalls :: Int
  }
  deriving (Eq, Show)

reportLine :: String -> Report -> String
reportLine name r =
  "# native-insns-v1: " ++ name ++ " segmax=" ++ bound (rSegMax r) ++ " exittail=" ++ bound (rExitTail r) ++ " ccalls=" ++ show (rCCalls r)
  where
    bound = maybe "UNBOUNDED" show

data Blk = Blk
  { bRuns :: [Int], -- instruction counts between boundaries; n runs = n-1 boundaries inside
    bSuccs :: [String],
    bExit :: Bool
  }

analyse :: [Tok] -> Report
analyse toks
  | invalid = Report Nothing Nothing ccalls
  | otherwise = Report segMax exitTail ccalls
  where
    ccalls = sum [tCCalls t | t@TIns {} <- toks]
    labels = [l | TLabel l <- toks]
    labelSet = S.fromList labels
    targets = concat [case tFlow t of FCond ls -> ls; FJump l -> [l]; _ -> [] | t@TIns {} <- toks]
    invalid = length labels /= S.size labelSet
      || S.member "%entry" labelSet
      || any (`S.notMember` labelSet) targets
      || any (\t -> tCost t < 0 || tCCalls t < 0) [t | t@TIns {} <- toks]
    -- A conditional transfer ends a basic block even without an explicit
    -- source label afterward. Otherwise a later reset can incorrectly cut
    -- a back-edge that branches BEFORE it (and understate the segment bound).
    prefix = head [p | n <- [0 :: Int ..], let p = "%bound" ++ show n ++ ":",
                       all (\l -> take (length p) l /= p) labels]
    split = concat [case t of
      TIns {tFlow = flow} | flow /= FNext -> [t, TLabel (prefix ++ show n)]
      _ -> [t] | (n,t) <- zip [0 :: Int ..] toks]
    -- blocks: the entry (unnamed) and one per label, in order
    blocks = go "%entry" [] split
      where
        go cur acc [] = [(cur, reverse acc)]
        go cur acc (TLabel l : rest) = (cur, reverse acc) : go l [] rest
        go cur acc (t : rest) = go cur (t : acc) rest
    names = map fst blocks
    nameSet = S.fromList names
    nextOf = M.fromList (zip names (drop 1 names))
    summarize (lbl, ins) = Blk runs succs exits
      where
        runs = split 0 ins
        split n [] = [n]
        split n (t : rest)
          | tReset t = (n + tCost t) : split 0 rest
          | otherwise = split (n + tCost t) rest
        lastFlow = if null ins then FNext else tFlow (last ins)
        condTargets = concat [ls | TIns {tFlow = FCond ls} <- ins]
        fallsOff = case lastFlow of
          FJump _ -> False
          FExit -> False
          _ -> True
        jumpT = case lastFlow of FJump l -> [l]; _ -> []
        succs = filter (`S.member` nameSet) (condTargets ++ jumpT ++ [n | fallsOff, Just n <- [M.lookup lbl nextOf]])
        exits = lastFlow == FExit || (fallsOff && M.notMember lbl nextOf)
    bmap = M.fromList [(l, summarize b) | b@(l, _) <- blocks]
    -- the longest run from a block's start to the first boundary or exit
    maxTab = foldl' (\m l -> fst (visit S.empty m l)) M.empty names
    visit grey m l
      | Just v <- M.lookup l m = (m, v)
      | S.member l grey = (m, Nothing)
      | otherwise = case M.lookup l bmap of
          Nothing -> (m, Just 0)
          Just b ->
            let r1 = head (bRuns b)
             in if length (bRuns b) > 1
                  then (M.insert l (Just r1) m, Just r1)
                  else
                    let (m1, v) = succMax (S.insert l grey) m b
                        r = fmap (r1 +) v
                     in (M.insert l r m1, r)
    succMax grey m b
      | null (bSuccs b) = (m, Just 0)
      | otherwise =
          let step (mm, acc) s = let (mm1, v) = visit grey mm s in (mm1, v : acc)
              (m1, vs) = foldl' step (m, []) (bSuccs b)
           in (m1, maximumM vs)
    maxFrom l = M.findWithDefault (Just 0) l maxTab
    maximumM ms = if any (== Nothing) ms then Nothing else Just (maximum (0 : [v | Just v <- ms]))
    afterResets =
      sequence
        [ seg
          | (_, b) <- M.toList bmap,
            length (bRuns b) > 1,
            let inner = init (drop 1 (bRuns b)),
            seg <- map Just inner ++ [fmap (last (bRuns b) +) (if null (bSuccs b) then Just 0 else maximumM (map maxFrom (bSuccs b)))]
        ]
    segMax = do
      entry <- maxFrom "%entry"
      rest <- afterResets
      pure (maximum (entry : rest))
    -- the longest run from a block's start to an exit with no boundary on the way
    tailTab = foldl' (\m l -> fst (tvisit S.empty m l)) M.empty names
    tvisit grey m l
      | Just v <- M.lookup l m = (m, v)
      | S.member l grey = (m, Left ()) -- a cycle: unbounded unless a boundary cuts it (checked by segMax)
      | otherwise = case M.lookup l bmap of
          Nothing -> (m, Right Nothing)
          Just b
            | length (bRuns b) > 1 -> (M.insert l (Right Nothing) m, Right Nothing) -- a boundary inside: no boundary-free path to an exit starts here
            | otherwise ->
                let r1 = head (bRuns b)
                    step (mm, acc) s = let (mm1, v) = tvisit (S.insert l grey) mm s in (mm1, v : acc)
                    (m1, vs) = foldl' step (m, []) (bSuccs b)
                    here = [r1 | bExit b]
                    r = case sequence vs of
                      Left () -> Left ()
                      Right rs -> Right (case here ++ [r1 + v | Just v <- rs] of [] -> Nothing; xs -> Just (maximum xs))
                 in (M.insert l r m1, r)
    tailFrom l = M.findWithDefault (Right Nothing) l tailTab
    exitTail = case segMax of
      Nothing -> Nothing
      Just _ ->
        let starts = tailFrom "%entry" : [tailOf b | (_, b) <- M.toList bmap, length (bRuns b) > 1]
            tailOf b = case sequence (map tailFrom (bSuccs b)) of
              Left () -> Left ()
              Right rs -> Right (case [last (bRuns b) | bExit b] ++ [last (bRuns b) + v | Just v <- rs] of [] -> Nothing; xs -> Just (maximum xs))
         in case sequence starts of
              Left () -> Nothing
              Right rs -> Just (maximum (0 : [v | Just v <- rs]))

-- The weight of each fuel tick (docs/2026-11-11-WEIGHTED-TICKS.md): the
-- largest number of target instructions the function itself can execute
-- from that tick, the tick's own item included, to the next tick or to an
-- exit.  A call is transparent: the callee charges its own instructions at
-- its own ticks, and the instructions after the call return are this
-- function's, covered by the tick before the call.  The instructions
-- between the function's first instruction and the first tick it reaches
-- (the prologue, the stack check) have no tick before them, so every tick
-- reachable from the entry without crossing another one carries them too.
--
-- The stream is the one `analyse` reads, each item paired with whether it
-- is a tick.  The result has one weight per tick, in stream order; Nothing
-- when some cycle has no tick in it (the function is UNBOUNDED for
-- `analyse` as well, and keeps unit ticks).
tickWeights :: [(Tok, Bool)] -> Maybe [Int]
tickWeights marked
  | invalid = Nothing
  | otherwise = do
      prefix <- startOf "%entry"
      mapM (\(l, i) -> do rest <- runFrom l (i + 1)
                          pure (itemCost l i + rest + (if S.member (l, i) firsts then prefix else 0))) ticks
  where
    toks = map fst marked
    labels = [l | TLabel l <- toks]
    labelSet = S.fromList labels
    targets = concat [case tFlow t of FCond ls -> ls; FJump l -> [l]; _ -> [] | t@TIns {} <- toks]
    invalid = length labels /= S.size labelSet || S.member "%entry" labelSet || any (`S.notMember` labelSet) targets
    -- a conditional or unconditional transfer ends its block, as in `analyse`
    prefixName = head [q | n <- [0 :: Int ..], let q = "%tick" ++ show n ++ ":", all (\l -> take (length q) l /= q) labels]
    split = concat [case t of
      TIns {tFlow = flow} | flow /= FNext -> [(t, k), (TLabel (prefixName ++ show n), False)]
      _ -> [(t, k)] | (n, (t, k)) <- zip [0 :: Int ..] marked]
    blocks = go "%entry" [] split
      where
        go cur acc [] = [(cur, reverse acc)]
        go cur acc ((TLabel l, _) : rest) = (cur, reverse acc) : go l [] rest
        go cur acc (t : rest) = go cur (t : acc) rest
    names = map fst blocks
    nextOf = M.fromList (zip names (drop 1 names))
    bmap = M.fromList blocks
    itemsOf l = M.findWithDefault [] l bmap
    itemCost l i = tCost (fst (itemsOf l !! i))
    succMap = M.fromList [(l, succsOf ins l) | (l, ins) <- blocks]
    succsOf ins l =
      let lastFlow = if null ins then FNext else tFlow (fst (last ins))
          cond = concat [ls | (TIns {tFlow = FCond ls}, _) <- ins]
          falls = case lastFlow of FJump _ -> False; FExit -> False; _ -> True
       in cond ++ (case lastFlow of FJump t -> [t]; _ -> []) ++ [n | falls, Just n <- [M.lookup l nextOf]]
    ticks = [(l, i) | (l, ins) <- blocks, (i, (_, True)) <- zip [0 :: Int ..] ins]
    -- within one block: the tick-free cost from item i, and whether the run
    -- reaches the block's end (False: a tick stops it)
    runIn l i = case break snd (drop i (itemsOf l)) of
      (free, rest) -> (sum (map (tCost . fst) free), null rest)
    -- the longest tick-free run from a block's start to a tick or an exit,
    -- memoised; Nothing on a cycle with no tick
    startTab = foldl' (\m l -> fst (visit S.empty m l)) M.empty names
    visit grey m l
      | Just v <- M.lookup l m = (m, v)
      | S.member l grey = (m, Nothing)
      | otherwise =
          let (cost, open) = runIn l 0
           in if not open then (M.insert l (Just cost) m, Just cost)
              else
                let step (mm, acc) s' = let (mm1, v) = visit (S.insert l grey) mm s' in (mm1, v : acc)
                    (m1, vs) = foldl' step (m, []) (M.findWithDefault [] l succMap)
                    r = if any (== Nothing) vs then Nothing else Just (cost + maximum (0 : [v | Just v <- vs]))
                 in (M.insert l r m1, r)
    startOf l = M.findWithDefault (Just 0) l startTab
    runFrom l i =
      let (cost, open) = runIn l i
       in if not open then Just cost
          else do vs <- mapM startOf (M.findWithDefault [] l succMap)
                  pure (cost + maximum (0 : vs))
    -- the ticks the entry reaches without crossing another tick
    firsts = reach S.empty S.empty ["%entry"]
      where
        reach _ acc [] = acc
        reach seen acc (l : rest)
          | S.member l seen = reach seen acc rest
          | otherwise = case [i | (i, (_, True)) <- zip [0 :: Int ..] (itemsOf l)] of
              i : _ -> reach (S.insert l seen) (S.insert (l, i) acc) rest
              [] -> reach (S.insert l seen) acc (M.findWithDefault [] l succMap ++ rest)
