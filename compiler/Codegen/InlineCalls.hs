-- Codegen.InlineCalls: a call inside a loop becomes the callee's blocks.
--
-- The checked inliner (Core.Typed.Inline) works on expressions, takes small
-- templates and never a recursive one, so a loop that calls a helper, or an
-- inner loop, pays an activation per iteration: the frame, the stack check,
-- the vector views formed again, and every bound the caller knew forgotten.
-- Here the callee is a control-flow graph, and a loop is only a cycle in it,
-- so both cases are one splice: the calling block ends in a jump to a copy
-- of the callee's entry, every `ret` of the copy jumps to the rest of the
-- calling block with the result, and a tail call of the copy becomes a call
-- followed by that jump.
--
-- What is taken: a direct call to a function of this unit, from a block that
-- lies on a cycle of its function, when that call is the only place the
-- program names the callee, the callee is not part of the caller's own
-- recursion, and both fit the budgets below. The callee keeps its
-- definition (an export or another unit may still reach it).
--
-- What is preserved: the order of every effect and trap (the copy runs
-- where the call ran, with the same arguments), and every safepoint of the
-- callee (its entry tick stays, so fuel is charged as before). The callee's
-- stack check goes: the copy lives in the caller's frame, which the
-- caller's own entry checked.
module Codegen.InlineCalls (inlineCalls) where

import Codegen.IR
import Data.Graph (SCC (..), stronglyConnComp)
import Data.List (isPrefixOf, minimumBy)
import Data.Ord (comparing)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- The largest callee taken (instructions) and the size a caller may reach.
-- Only a callee the program names in this one place is taken: it moves
-- rather than multiplies. Taking small shared callees too was measured: the
-- compiler allocated 6% to 14% more on the prelude alone (every loop of
-- every program grows by its helpers) for nothing on the benchmarks at 12
-- instructions, and a few percent on three of them at 24.
calleeLimit, callerLimit, mutualLimit :: Int
calleeLimit = 400
callerLimit = 450
mutualLimit = 80

size :: Fn -> Int
size = sum . map (length . bInstrs) . fnBlocks

-- Callees first: a function is expanded against the finished versions of the
-- functions it calls, and never against a member of its own recursion.
inlineCalls :: Program -> Program
inlineCalls program = foldl component M.empty (stronglyConnComp [(f, n, called f) | (n, f) <- M.toList program])
  where
    -- how often the program names each function: its calls and its uses as a value
    named = M.fromListWith (+) [(n, 1 :: Int) | f <- M.elems program, b <- fnBlocks f,
                                 n <- map calleeName (blockCallees b) ++ [v | Instr _ (OFunValue v) <- bInstrs b]]
    limit n = if M.lookup n named == Just 1 then calleeLimit else 0
    expand done = expandWith limit done
    called f = S.toList (S.fromList [calleeName c | b <- fnBlocks f, c <- blockCallees b, M.member (calleeName c) program])
    component done scc = case scc of
      AcyclicSCC f -> M.insert (fnName f) (expand done f) done
      CyclicSCC fs ->
        let expanded = map (expand done) fs
            userFns = filter (not . ("$loop." `isPrefixOf`) . fnName) expanded
            merged = case userFns of
              (_ : _ : _) ->
                let headFn = minimumBy (comparing fnName) userFns
                    peers = M.fromList [(fnName g, g) | g <- userFns, fnName g /= fnName headFn]
                    headFn' = splitSelfLoop (expandMutualTail peers headFn)
                 in [if fnName f == fnName headFn then headFn' else f | f <- expanded]
              _ -> expanded
         in foldl (\d f -> M.insert (fnName f) f d) done merged

blockCallees :: Block -> [Callee]
blockCallees b = [c | Instr _ op <- bInstrs b, c <- opCallee op] ++ (case bTerm b of TTailCall c _ -> [c]; _ -> [])
  where
    opCallee op = case op of
      OCall c _ -> [c]
      OCallProduct c _ -> [c]
      _ -> []

expandWith :: (Name -> Int) -> Program -> Fn -> Fn
expandWith limit done = go
  where
    go fn = maybe fn go (firstSite fn)
    firstSite fn =
      let cyclic = onCycle fn
          room = callerLimit - size fn
       in case [ splice fn b k results args g
               | b <- fnBlocks fn, S.member (bId b) cyclic,
                 (k, c, results, args) <- sites (bInstrs b),
                 calleeKind c == Local,
                 Just g <- [M.lookup (calleeName c) done],
                 size g <= limit (calleeName c), size g <= room, fits c (length results) g ] of
            fn' : _ -> Just fn'
            [] -> Nothing

-- the calls of a block: where each is, what it calls, the values it defines
-- (one word, or the words of a product: the call and the results after it)
sites :: [Instr] -> [(Int, Callee, [VId], [VId])]
sites instrs = [site | (k, i) <- zip [0 ..] instrs, site <- at k i]
  where
    at k i = case i of
      Instr (Just (r, TVal)) (OCall c args) | calleeResult c == TVal -> [(k, c, [r], args)]
      Instr first (OCallProduct c args) | Right (rs, _) <- productCallResults c first (drop (k + 1) instrs) -> [(k, c, rs, args)]
      _ -> []

-- the blocks that lie on a cycle of the function's graph
onCycle :: Fn -> S.Set BId
onCycle fn = S.fromList (concat [bs | CyclicSCC bs <- stronglyConnComp [(bId b, bId b, map fst (termSuccs (bTerm b))) | b <- fnBlocks fn]])

-- the call passes what the entry takes, and every way out of the callee
-- answers what the call defines: one word, or the n words of a product
fits :: Callee -> Int -> Fn -> Bool
fits c n g = fnResult g == answers
  && case [b | b <- fnBlocks g, bId b == fnEntry g] of
       [entry] -> map snd (bParams entry) == calleeParams c
       _ -> False
  && all (way . bTerm) (fnBlocks g)
  where
    answers = calleeResult c
    way term = case term of
      TRet _ -> n == 1 && answers == TVal
      TRetProduct vs -> answers == TProduct n && length vs == n
      TTailCall h _ -> calleeResult h == answers
      _ -> True

-- Replace the call at instruction k of block b, which defines `results`, by
-- the callee.
splice :: Fn -> Block -> Int -> [VId] -> [VId] -> Fn -> Fn
splice fn b k results args g = fn {fnBlocks = concatMap place (fnBlocks fn)}
  where
    n = length results
    firstV = 1 + maximum (0 : [i | x <- fnBlocks fn, (VId i, _) <- blockDefs x])
    firstB = 1 + maximum (0 : [i | x <- fnBlocks fn, BId i <- [bId x]])
    value (VId i) = VId (i + firstV)
    label (BId i) = BId (i + firstB)
    lastV = maximum (0 : [i | x <- fnBlocks g, (VId i, _) <- blockDefs x])
    lastB = maximum (0 : [i | x <- fnBlocks g, BId i <- [bId x]])
    rest = BId (firstB + lastB + 1)
    -- a tail call of the callee needs values for its answer: n per block
    answer (BId i) j = VId (firstV + lastV + 1 + i * n + j)
    place x
      | bId x /= bId b = [x]
      | otherwise =
          [b {bInstrs = take k (bInstrs b), bTerm = TBr (label (fnEntry g)) args}]
            ++ map copy (entryFirst (fnBlocks g))
            -- the call and, for a product, the n-1 results that follow it
            ++ [Block rest [(r, TVal) | r <- results] (drop (k + n) (bInstrs b)) (bTerm b)]
    entryFirst bs = [x | x <- bs, bId x == fnEntry g] ++ [x | x <- bs, bId x /= fnEntry g]
    copy x =
      let instrs = [Instr (fmap (\(v, ty) -> (value v, ty)) d) (mapOpUses value op) | Instr d op <- bInstrs x, op /= OStackCheck]
          (more, term) = case mapTermUses value (bTerm x) of
            TRet v -> ([], TBr rest [v])
            TRetProduct vs -> ([], TBr rest vs)
            TTailCall h as ->
              let vs = map (answer (bId x)) [0 .. n - 1]
                  call = if n == 1 then [Instr (Just (answer (bId x) 0, TVal)) (OCall h as)]
                         else Instr (Just (answer (bId x) 0, TVal)) (OCallProduct h as)
                                : [Instr (Just (answer (bId x) j, TVal)) (OResult j) | j <- [1 .. n - 1]]
               in (call, TBr rest vs)
            TBr t as -> ([], TBr (label t) as)
            TCondBr p t as e bs -> ([], TCondBr p (label t) as (label e) bs)
            other -> ([], other)
       in Block (label (bId x)) [(value v, ty) | (v, ty) <- bParams x] (instrs ++ more) term

-- Break small mutual tail-recursion cycles (e.g. ev <-> od) into a direct
-- self-loop in the canonical SCC member so self-loop formation and RawInts
-- apply. Each peer is spliced at most once, preserving every safepoint.
expandMutualTail :: M.Map Name Fn -> Fn -> Fn
expandMutualTail peers = go S.empty
  where
    entryTys f = case [b | b <- fnBlocks f, bId b == fnEntry f] of
      [e] -> Just (map snd (bParams e))
      _ -> Nothing
    go seen fn =
      let room = callerLimit - size fn
       in case [ (b, g)
               | b <- fnBlocks fn,
                 TTailCall c args <- [bTerm b],
                 calleeKind c == Local,
                 S.notMember (calleeName c) seen,
                 Just g <- [M.lookup (calleeName c) peers],
                 size g <= mutualLimit, size g <= room,
                 fnResult g == fnResult fn,
                 entryTys g == Just (calleeParams c),
                 length args == length (calleeParams c) ] of
            (b, g) : _ -> go (S.insert (fnName g) seen) (spliceTail fn b g)
            [] -> fn

-- When mutual tail splicing introduces a back-edge to fnEntry, separate the
-- entry prefix (stack check + initial fuel tick) into a dedicated entry block
-- just like Codegen.LoopOptimize.formSelfLoop, so downstream RawInts and native
-- backends see a clean preheader + loop header with an entry fuel tick.
splitSelfLoop :: Fn -> Fn
splitSelfLoop fn = case [b | b <- fnBlocks fn, bId b == fnEntry fn] of
  [entry]
    | not (null backs), all directEntryEdge (fnBlocks fn) ->
        let (prefix, rest) = span (\(Instr _ op) -> op `elem` [OStackCheck, OSafepoint]) (bInstrs entry)
            hasFuel = any (\(Instr _ op) -> op == OSafepoint) prefix
            nextV = 1 + maximum (0 : [i | x <- fnBlocks fn, (VId i, _) <- blockDefs x])
            nextB = 1 + maximum (0 : [i | x <- fnBlocks fn, BId i <- [bId x]])
            arrivals = [(VId (nextV + i), ty) | (i, (_, ty)) <- zip [0 ..] (bParams entry)]
            pre = Block (BId nextB) arrivals prefix (TBr (fnEntry fn) (map fst arrivals))
            rewrite b =
              let self = case bTerm b of TBr target _ -> target == fnEntry fn; _ -> False
                  ops = if bId b == fnEntry fn then rest else bInstrs b
               in b {bInstrs = ops ++ [Instr Nothing OSafepoint | self && hasFuel]}
         in fn {fnEntry = bId pre, fnBlocks = pre : map rewrite (fnBlocks fn)}
  _ -> fn
  where
    backs = [b | b <- fnBlocks fn, TBr target _ <- [bTerm b], target == fnEntry fn]
    directEntryEdge b = case bTerm b of
      TBr target _ | target == fnEntry fn -> True
      t -> all ((/= fnEntry fn) . fst) (termSuccs t)

spliceTail :: Fn -> Block -> Fn -> Fn
spliceTail fn b g = fn {fnBlocks = concatMap place (fnBlocks fn)}
  where
    firstV = 1 + maximum (0 : [i | x <- fnBlocks fn, (VId i, _) <- blockDefs x])
    firstB = 1 + maximum (0 : [i | x <- fnBlocks fn, BId i <- [bId x]])
    value (VId i) = VId (i + firstV)
    label (BId i) = BId (i + firstB)
    selfTys = case [x | x <- fnBlocks fn, bId x == fnEntry fn] of
      [e] -> Just (map snd (bParams e))
      _ -> Nothing
    entryFirst bs = [x | x <- bs, bId x == fnEntry g] ++ [x | x <- bs, bId x /= fnEntry g]
    place x
      | bId x /= bId b = [x]
      | TTailCall _ args <- bTerm b =
          [b {bTerm = TBr (label (fnEntry g)) args}] ++ map copy (entryFirst (fnBlocks g))
      | otherwise = [x]
    copy x =
      let instrs = [Instr (fmap (\(v, ty) -> (value v, ty)) d) (mapOpUses value op) | Instr d op <- bInstrs x, op /= OStackCheck]
          term = case mapTermUses value (bTerm x) of
            TBr t as -> TBr (label t) as
            TCondBr p t as e bs -> TCondBr p (label t) as (label e) bs
            TTailCall h as | calleeKind h == Local, calleeName h == fnName fn, Just (calleeParams h) == selfTys -> TBr (fnEntry fn) as
            other -> other
       in Block (label (bId x)) [(value v, ty) | (v, ty) <- bParams x] instrs term
