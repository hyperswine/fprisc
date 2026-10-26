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
module Codegen.Bounds (Tok (..), Flow (..), Report (..), analyse, reportLine) where

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
    targets = concat [case tFlow t of FCond ls -> ls; FJump l -> [l]; _ -> [] | t@TIns {} <- toks]
    invalid = length labels /= S.size (S.fromList labels)
      || "%entry" `elem` labels
      || any (`notElem` labels) targets
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
