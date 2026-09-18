-- A local cleanup of one function's emitted rv64 lines (builtin, --arc).
--
-- The generator moves every intermediate value through a frame slot:
-- `sd a0, -40(s0)` and then, a line later, `ld a0, -40(s0)`.  Two
-- passes remove what that costs without changing what runs:
--
--   * forwarding: within a basic block, a register that was just
--     stored to (or loaded from) a slot still holds the slot's value,
--     so a reload of that slot from the same register is dropped and a
--     reload into another register becomes a `mv`.  Anything that can
--     write the register or the slot (a call, a store through a
--     pointer, a label that code can jump to, a change of s0/sp)
--     forgets what is known.
--   * dead stores: a slot the function never loads from is never
--     stored to.  Slots are private to the frame (callees open their
--     own; the hart spill cells and the sp-relative push/pop scratch
--     are other memory), so a store nobody loads is dead.  Functions
--     that address slots through a computed base (the deep-frame t2
--     form) keep every store.
--
-- The x64/a64 translators never see this output: the pass runs only
-- for the rv64 builtin target.

{-# LANGUAGE LambdaCase #-}

module Peephole (peephole) where

import Data.Char (isDigit)
import Data.List (isPrefixOf, tails)
import qualified Data.Set as S

peephole :: [String] -> [String]
peephole = deadStores . forward

data Ins = Ins String [String]

parse :: String -> Maybe Ins
parse l
  | "    " `isPrefixOf` l, (op : _) <- words l, not ("." `isPrefixOf` op) =
      Just (Ins op (splitOps (drop (length op) (dropWhile (== ' ') l))))
  | otherwise = Nothing
  where
    splitOps s = case break (== ',') (dropWhile (== ' ') s) of
      (a, ',' : rest) -> a : splitOps rest
      ("", []) -> []
      (a, _) -> [a]

-- "-40(s0)" -> Just (-40)
slotOf :: String -> Maybe Int
slotOf s = case break (== '(') s of
  (n, "(s0)") | isNum n -> Just (read n)
  _ -> Nothing
  where
    isNum ('-' : ds@(_ : _)) = all isDigit ds
    isNum ds@(_ : _) = all isDigit ds
    isNum _ = False

stores, loads, branches, clobbersAll :: S.Set String
stores = S.fromList ["sd", "sw", "sh", "sb", "fsd", "fsw", "sc.d", "sc.w"]
loads = S.fromList ["ld", "lw", "lwu", "lh", "lhu", "lb", "lbu", "fld", "flw", "lr.d", "lr.w"]
branches = S.fromList ["beq", "bne", "blt", "bge", "bltu", "bgeu", "beqz", "bnez", "blez", "bgez", "bltz", "bgtz", "j"]
clobbersAll = S.fromList ["call", "jal", "jalr", "jr", "ret", "tail", "ecall", "ebreak", "fence", "fence.i", "wfi"]

-- pairs (register, slot): the register holds the slot's current value
forward :: [String] -> [String]
forward = go S.empty
  where
    go _ [] = []
    go known (l : ls) = case parse l of
      Nothing -> l : go S.empty ls
      Just (Ins op args)
        | op == "ld", [r, m] <- args, Just k <- slotOf m ->
            if S.member (r, k) known
              then go known ls
              else case [r2 | (r2, k2) <- S.toList known, k2 == k, r2 /= r] of
                (r2 : _) ->
                  ("    mv " ++ r ++ ", " ++ r2)
                    : go (S.union (S.fromList [(r, s) | (r', s) <- S.toList known, r' == r2]) (dropReg r known)) ls
                [] -> l : go (S.insert (r, k) (dropReg r known)) ls
        | S.member op stores, [r, m] <- args, Just k <- slotOf m ->
            l : go (if op == "sd" then S.insert (r, k) (dropSlot k known) else dropSlot k known) ls
        | S.member op stores -> l : go S.empty ls
        | S.member op clobbersAll -> l : go S.empty ls
        | S.member op branches -> l : go known ls
        | op == "mv", [rd, rs] <- args ->
            l : go (S.union (S.fromList [(rd, s) | (r', s) <- S.toList known, r' == rs]) (dropReg rd known)) ls
        | (rd : _) <- args, rd `notElem` ["s0", "sp"], all (`notElem` ["s0", "sp"]) (drop 1 args) || op `S.member` loads || op == "add" && rd == "t2" ->
            l : go (dropReg rd known) ls
        | otherwise -> l : go S.empty ls
    dropReg r = S.filter ((/= r) . fst)
    dropSlot k = S.filter ((/= k) . snd)

deadStores :: [String] -> [String]
deadStores ls
  | computedBase = ls
  | backward = [l | l <- ls, not (deadAnywhere l)]
  | otherwise = [l | (l, after, later) <- zip3 ls (drop 1 (tails ls)) (drop 1 laterLoads), not (dead l after later)]
  where
    ins = [i | Just i <- map parse ls]
    loaded = S.fromList [k | Ins op [_, m] <- ins, S.member op loads, Just k <- [slotOf m]]
    -- slots reached through a computed address, or s0 used as a value
    -- anywhere but the epilogue's `mv t0, s0`: keep everything
    computedBase =
      or
        [ "s0" `elem` drop 1 args && not (S.member op loads || S.member op stores) && (op, args) /= ("mv", ["t0", "s0"])
          | Ins op args <- ins
        ]
    -- control flow in a body is forward-only (loops are tail calls);
    -- should a branch ever go back, fall back to the function-wide rule
    labels = [(init l, i) | (i, l) <- zip [0 :: Int ..] ls, not ("    " `isPrefixOf` l), not (null l), last l == ':']
    backward =
      or
        [ maybe False (<= i) (lookup t labels)
          | (i, l) <- zip [0 ..] ls,
            Just (Ins op args) <- [parse l],
            S.member op branches,
            (t : _) <- [reverse args]
        ]
    storeTo l = case parse l of
      Just (Ins op [_, m]) | S.member op stores, Just k <- slotOf m -> Just k
      _ -> Nothing
    loadFrom l = case parse l of
      Just (Ins op [_, m]) | S.member op loads, Just k <- slotOf m -> Just k
      _ -> Nothing
    deadAnywhere l = maybe False (`S.notMember` loaded) (storeTo l)
    -- laterLoads !! i = the slots loaded at lines >= i
    laterLoads = scanr (\l acc -> maybe acc (`S.insert` acc) (loadFrom l)) S.empty ls
    -- a store is dead when no later line loads its slot, or when the
    -- same block stores the slot again before anything can load it
    -- (no load, label, branch or call in between)
    dead l after later = case storeTo l of
      Just k -> S.notMember k later || overwritten k after
      Nothing -> False
    overwritten k = \case
      [] -> False
      (l : more)
        | storeTo l == Just k -> True
        | loadFrom l == Just k -> False
        | Just (Ins op _) <- parse l, not (S.member op branches || S.member op clobbersAll) -> overwritten k more
        | otherwise -> False
