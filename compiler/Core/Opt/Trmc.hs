{-# LANGUAGE LambdaCase #-}
-- Tail Recursion Modulo Cons (TRMC) for accumulator-reverse list loops and
-- two-pass `append`.
--
-- Many list functions in `std/list.fpr` (`mapGo`, `imapGo`, `filterGo`,
-- `mapFilterGo`, `filterMappedGo`, `fmapGo`, `takeGo`, `twGo`, `zipGo`,
-- `merge`, `mergePairs`, `groupGo`) accumulate elements in reverse (`x :: acc`)
-- and finish with `reverse acc` or `revOnto acc tail`. That allocates two
-- `Cons` cells per output element and walks the list a second time at the end.
--
-- For each such self-recursive function `f`, this pass emits a private worker
-- `$worker.trmc.<f>` in which the accumulator parameter `acc` is replaced by
-- `root` (the first `Cons` cell of the output list) and `last` (the most
-- recently allocated `Cons` cell, whose tail field is currently `Nil`).
--
-- `f` itself keeps its public signature and transitions into `$worker.trmc.<f>`
-- as soon as `acc` is `Nil` and the first `Cons` cell `cell0` is allocated
-- (`root = cell0`, `last = cell0`). Inside `$worker.trmc.<f>`, `last` is
-- guaranteed to be a freshly allocated, uniquely owned `Cons` cell, so each
-- subsequent `Cons` step allocates `cell = Cons hd Nil`, links `last` to `cell`
-- in place via `$trmc.setTail` (`OSetField 1`), and loops with `(root, cell)`
-- without any branch on `last`. At an exit leaf `reverse acc` / `revOnto acc Nil`,
-- `$worker.trmc.<f>` simply returns `root`.
module Core.Opt.Trmc
  ( trmcProgram,
    trmcProgramWithImports,
    trmcWorker,
    trmcWorkerName,
    trmcSetTailName,
  ) where

import Core.Primitives (entryTickName)
import Core.Syntax (Core (..), Name, Prog)
import Core.Utils (spineOf)
import Data.List (isPrefixOf)
import Data.Maybe (mapMaybe)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Workers (internalWorker)

trmcPrefix :: String
trmcPrefix = "$worker.trmc."

trmcAppendName :: String
trmcAppendName = "$worker.trmc.append"

trmcSetTailName :: String
trmcSetTailName = "$trmc.setTail"

trmcWorker :: Name -> Bool
trmcWorker = isPrefixOf trmcPrefix

trmcWorkerName :: Name -> Name
trmcWorkerName = (trmcPrefix ++)

bodyBound :: Int
bodyBound = 1024

arityLimit :: Int
arityLimit = 63

children :: Core -> [Core]
children = \case
  CApp a b -> [a, b]
  CLet _ a b -> [a, b]
  CIf a b c -> [a, b, c]
  CMk _ _ xs -> xs
  CTagEq _ _ x -> [x]
  CProj _ x -> [x]
  CLam _ x -> [x]
  _ -> []

size :: Core -> Int
size e = 1 + sum (map size (children e))

mentions :: Name -> Core -> Bool
mentions x = \case
  CVar y -> x == y
  CLet y a b -> mentions x a || (y /= x && mentions x b)
  CLam ps b -> x `notElem` ps && mentions x b
  e -> any (mentions x) (children e)

freeIn :: Core -> S.Set Name
freeIn = \case
  CVar x -> S.singleton x
  CLet x a b -> freeIn a `S.union` S.delete x (freeIn b)
  CLam ps b -> foldr S.delete (freeIn b) ps
  e -> S.unions (map freeIn (children e))

boundIn :: Core -> S.Set Name
boundIn = \case
  CLet x a b -> S.insert x (boundIn a `S.union` boundIn b)
  CLam ps b -> S.fromList ps `S.union` boundIn b
  e -> S.unions (map boundIn (children e))

rebinds :: Name -> Core -> Bool
rebinds x = \case
  CLet y a b -> x == y || rebinds x a || rebinds x b
  CLam ps b -> x `elem` ps || rebinds x b
  e -> any (rebinds x) (children e)

subst :: Name -> Core -> Core -> Core
subst n value = go
  where
    go (CVar x) | x == n = value
    go (CLet x a b) = CLet x (go a) (if x == n then b else go b)
    go (CLam ps b) | n `elem` ps = CLam ps b
    go (CApp a b) = CApp (go a) (go b)
    go (CIf a b c) = CIf (go a) (go b) (go c)
    go (CMk t v xs) = CMk t v (map go xs)
    go (CTagEq t v x) = CTagEq t v (go x)
    go (CProj k x) = CProj k (go x)
    go e = e

-- Resolve local variable aliases (`let x = y in b` where `y` is a local or
-- parameter and not rebound in `b`), so erased typed-Core parameter aliases
-- expose `acc` and `Nil` directly even when `NormalizeForReuse` is disabled.
aliases :: S.Set Name -> Core -> Core
aliases locals = \case
  CLet n (CVar x) b
    | S.member x locals, not (rebinds x b) ->
        aliases locals (subst n (CVar x) b)
  CLet n a b -> CLet n (aliases locals a) (aliases (S.insert n locals) b)
  CIf a b c -> CIf (aliases locals a) (aliases locals b) (aliases locals c)
  CApp a b -> CApp (aliases locals a) (aliases locals b)
  CMk t v xs -> CMk t v (map (aliases locals) xs)
  CTagEq t v x -> CTagEq t v (aliases locals x)
  CProj k x -> CProj k (aliases locals x)
  CLam ps b -> CLam ps (aliases (S.union (S.fromList ps) locals) b)
  e -> e

isTick :: Core -> Bool
isTick e = case spineOf e of
  (CVar h, [CInt _]) -> h == entryTickName
  _ -> False

isNil :: S.Set Name -> Core -> Bool
isNil bound = \case
  CMk 2 0 [] -> True
  CVar n -> S.notMember n bound && (n == "Nil" || "Nil@" `isPrefixOf` n)
  CLet x a b -> isTick a && isNil (S.insert x bound) b
  _ -> False

-- Strip qualification prefixes (`$specaux.u...`, `$typed.mono.`) and suffixes
-- (`@hash`, `.0`) to recover a function's base identifier.
baseIdent :: Name -> Name
baseIdent = dropMonoSuffix . takeWhile (/= '@') . dropPrefixes
  where
    dropPrefixes s
      | "$specaux." `isPrefixOf` s =
          case dropWhile (/= '.') (drop (length "$specaux.") s) of
            '.' : rest -> dropPrefixes rest
            _ -> s
      | "$typed.mono." `isPrefixOf` s = drop (length "$typed.mono.") s
      | otherwise = s
    dropMonoSuffix s = case break (== '.') s of
      (base, '.' : digits) | not (null digits) && all (\c -> c >= '0' && c <= '9') digits -> base
      _ -> s

-- Structural recognition of `revOnto` and `reverse` definitions in `prog` or
-- `imports`, falling back to the base name only for external imports whose
-- bodies are not present in the unit.
revOntoSet :: Prog -> S.Set Name
revOntoSet allDefs =
  S.fromList [n | (n, def) <- M.toList allDefs, isRevOntoDef n def]
  where
    isRevOntoDef name (ps, body)
      | [xs, acc] <- ps =
          let b = aliases (S.fromList ps) body
           in matchRevOnto name xs acc (S.fromList ps) b
      | otherwise = False
    matchRevOnto name xs acc bound = \case
      CLet x a b
        | isTick a -> matchRevOnto name xs acc (S.insert x bound) b
      CIf (CTagEq 2 0 (CVar l)) nilArm consArm
        | l == xs,
          peelTicks nilArm == CVar acc ->
            matchConsArm name xs acc bound consArm
      _ -> False
    matchConsArm name xs acc bound e =
      let (lets, leaf) = peelLets acc e
          lookupAlias v = lookup v lets
          isHead (CVar v) = lookupAlias v == Just (CProj 0 (CVar xs))
          isHead (CProj 0 (CVar v)) = v == xs
          isHead _ = False
          isTail (CVar v) = lookupAlias v == Just (CProj 1 (CVar xs))
          isTail (CProj 1 (CVar v)) = v == xs
          isTail _ = False
       in case spineOf leaf of
            (CVar g, [tlArg, consArg])
              | g == name,
                S.notMember g bound,
                isTail tlArg,
                Just (cLets, hd) <- peelCons acc consArg,
                all (isTick . snd) cLets,
                isHead hd ->
                  True
            _ -> False
    peelTicks (CLet _ a b) | isTick a = peelTicks b
    peelTicks e = e

reverseSet :: Prog -> S.Set Name -> S.Set Name
reverseSet allDefs revOntos =
  S.fromList [n | (n, def) <- M.toList allDefs, isReverseDef def]
  where
    isReverseDef ([xs], body) =
      let b = aliases (S.singleton xs) body
          (lets, leaf) = peelLets xs b
       in all (isTick . snd) lets
            && case spineOf leaf of
              (CVar rv, [CVar x, nilE]) ->
                x == xs && isRevOnto allDefs revOntos S.empty rv && isNil (S.singleton xs) nilE
              _ -> False
    isReverseDef _ = False

isRevOnto :: Prog -> S.Set Name -> S.Set Name -> Name -> Bool
isRevOnto allDefs revOntos bound n
  | S.member n bound = False
  | M.member n allDefs = S.member n revOntos
  | otherwise = baseIdent n == "revOnto"

isReverse :: Prog -> S.Set Name -> S.Set Name -> S.Set Name -> Name -> Bool
isReverse allDefs revOntos reverses bound n
  | S.member n bound = False
  | M.member n allDefs = S.member n reverses
  | otherwise = baseIdent n == "reverse"

-- Peel leading `CLet`s whose right-hand sides do not mention `acc`.
peelLets :: Name -> Core -> ([(Name, Core)], Core)
peelLets acc = go []
  where
    go accLets (CLet x rhs b)
      | x /= acc, not (mentions acc rhs) = go (accLets ++ [(x, rhs)]) b
    go accLets e = (accLets, e)

-- Peel `CLet`s wrapping `CMk 2 1 [hd, CVar acc]` where `acc` is not mentioned
-- anywhere in the peeled bindings or `hd`.
peelCons :: Name -> Core -> Maybe ([(Name, Core)], Core)
peelCons acc e =
  let (lets, leaf) = peelLets acc e
   in case leaf of
        CMk 2 1 [hd, CVar y]
          | y == acc, not (mentions acc hd) -> Just (lets, hd)
        _ -> Nothing

data TailLeaf
  = ExitLeaf
  | RecKeep
  | RecCons

-- Check whether parameter `i` (`acc = ps !! i`) of `(ps, b0)` is a valid TRMC
-- accumulator: every non-trapping tail leaf is either an exit (`reverse acc`
-- or `revOnto acc tailExpr`, optionally with one final `Cons` onto `acc`),
-- a self tail call keeping `acc`, or a self tail call consing onto `acc`;
-- and there is at least one exit leaf and at least one consing self tail call.
candidateParam :: Prog -> S.Set Name -> S.Set Name -> Name -> [Name] -> Core -> Int -> Bool
candidateParam allDefs revOntos reverses name ps b0 i =
  not (rebinds acc b0)
    && case checkTail (S.fromList ps) b0 of
      Just leaves ->
        any isExit leaves && any isRecCons leaves
      Nothing -> False
  where
    acc = ps !! i
    arity = length ps
    isExit ExitLeaf = True
    isExit _ = False
    isRecCons RecCons = True
    isRecCons _ = False
    checkTail bound = \case
      CLet x rhs rest
        | x /= acc, not (mentions acc rhs) ->
            checkTail (S.insert x bound) rest
        | otherwise -> Nothing
      CIf cond t f
        | not (mentions acc cond) ->
            (++) <$> checkTail bound t <*> checkTail bound f
        | otherwise -> Nothing
      CErr _ -> Just []
      leaf
        | Just _ <- matchExit allDefs revOntos reverses bound acc leaf ->
            Just [ExitLeaf]
        | (CVar g, args) <- spineOf leaf,
          g == name,
          S.notMember g bound,
          length args == arity,
          and [not (mentions acc a) | (j, a) <- zip [0 ..] args, j /= i] ->
            case args !! i of
              CVar y | y == acc -> Just [RecKeep]
              argI
                | Just (cLets, _) <- peelCons acc argI,
                  let afterFree = S.unions (map freeIn (drop (i + 1) args)),
                  S.null (S.fromList (map fst cLets) `S.intersection` afterFree) ->
                    Just [RecCons]
              _ -> Nothing
        | otherwise -> Nothing

-- Match an exit leaf `reverse acc`, `revOnto acc tailExpr`, `reverse (hd :: acc)`,
-- or `revOnto (hd :: acc) tailExpr`, returning `(peeledLets, tailExpr)`.
matchExit :: Prog -> S.Set Name -> S.Set Name -> S.Set Name -> Name -> Core -> Maybe ([(Name, Core)], Core)
matchExit allDefs revOntos reverses bound acc e =
  let (lets, core) = peelLets acc e
      bound' = S.union bound (S.fromList (map fst lets))
   in case spineOf core of
        (CVar r, [arg])
          | isReverse allDefs revOntos reverses bound' r ->
              case arg of
                CVar y | y == acc -> Just (lets, CMk 2 0 [])
                _
                  | Just (cLets, hd) <- peelCons acc arg ->
                      Just (lets ++ cLets, CMk 2 1 [hd, CMk 2 0 []])
                _ -> Nothing
        (CVar rv, [arg, tailExpr])
          | isRevOnto allDefs revOntos bound' rv,
            not (mentions acc tailExpr) ->
              case arg of
                CVar y | y == acc -> Just (lets, tailExpr)
                _
                  | Just (cLets, hd) <- peelCons acc arg,
                    S.null (S.fromList (map fst cLets) `S.intersection` freeIn tailExpr) ->
                      Just (lets ++ cLets, CMk 2 1 [hd, tailExpr])
                _ -> Nothing
        _ -> Nothing

isTrivial :: Core -> Bool
isTrivial = \case
  CInt _ -> True
  CStr _ -> True
  CMk _ _ [] -> True
  CVar _ -> True
  _ -> False

-- Bind non-trivial arguments to fresh temporaries so strict left-to-right
-- evaluation order is preserved around the accumulator construction.
stageArgs :: S.Set Name -> String -> [Core] -> ([(Name, Core)], [Core], S.Set Name)
stageArgs avoid0 tag = go 0 [] [] avoid0
  where
    go _ binds vars avoid [] = (reverse binds, reverse vars, avoid)
    go idx binds vars avoid (a : as)
      | isTrivial a = go (idx + 1) binds (a : vars) avoid as
      | otherwise =
          let v = freshName avoid (tag ++ "." ++ show idx)
           in go (idx + 1) ((v, a) : binds) (CVar v : vars) (S.insert v avoid) as

freshName :: S.Set Name -> String -> Name
freshName avoid stem
  | S.notMember stem avoid = stem
  | otherwise = head [c | k <- [0 :: Int ..], let c = stem ++ "." ++ show k, S.notMember c avoid]

-- Rewrite `f`'s own body so that when `acc` is `Nil`, its first `Cons` step
-- allocates `cell0 = Cons hd Nil` and transitions into `$worker.trmc.<f>`, and
-- its exit leaves return `tailExpr` directly without calling `revOnto`.
rewriteEntryBody :: Prog -> S.Set Name -> S.Set Name -> Name -> [Name] -> Int -> Core -> Core
rewriteEntryBody allDefs revOntos reverses name ps i b0 =
  go (S.fromList ps) b0
  where
    acc = ps !! i
    worker = trmcWorkerName name
    baseAvoid = S.fromList ps `S.union` boundIn b0 `S.union` freeIn b0
    go bound = \case
      CLet x rhs rest -> CLet x rhs (go (S.insert x bound) rest)
      CIf cond t f -> CIf cond (go bound t) (go bound f)
      CErr msg -> CErr msg
      leaf
        | Just (lets, tailExpr) <- matchExit allDefs revOntos reverses bound acc leaf ->
            let (_, core) = peelLets acc leaf
             in foldr (uncurry CLet) (CIf (CTagEq 2 0 (CVar acc)) tailExpr core) lets
        | (CVar g, args) <- spineOf leaf,
          g == name,
          S.notMember g bound,
          length args == length ps ->
            case args !! i of
              CVar y | y == acc -> leaf
              argI
                | Just (cLets, hd) <- peelCons acc argI ->
                    let before = take i args
                        after = drop (i + 1) args
                        avoid1 = baseAvoid `S.union` bound
                        (bBinds, bVars, avoid2) = stageArgs avoid1 ("$trmc.eb." ++ name) before
                        hdV = freshName avoid2 ("$trmc.ehd." ++ name)
                        avoid3 = S.insert hdV avoid2
                        (aBinds, aVars, avoid4) = stageArgs avoid3 ("$trmc.ea." ++ name) after
                        cellV = freshName avoid4 ("$trmc.ecell." ++ name)
                        trmcCall = foldl CApp (CVar worker) (bVars ++ [CVar cellV, CVar cellV] ++ aVars)
                        origCall = foldl CApp (CVar name) (bVars ++ [CMk 2 1 [CVar hdV, CVar acc]] ++ aVars)
                        branch =
                          CIf
                            (CTagEq 2 0 (CVar acc))
                            (CLet cellV (CMk 2 1 [CVar hdV, CMk 2 0 []]) trmcCall)
                            origCall
                        allBinds = bBinds ++ cLets ++ [(hdV, hd)] ++ aBinds
                     in foldr (uncurry CLet) branch allBinds
              _ -> leaf
        | otherwise -> leaf

-- Construct `$worker.trmc.<f>` where parameter `acc` at `i` is replaced by
-- `rootP` and `lastP` (both guaranteed to be non-`Nil` `Cons` cells).
makeWorkerDef :: Prog -> S.Set Name -> S.Set Name -> Name -> [Name] -> Int -> Core -> ([Name], Core)
makeWorkerDef allDefs revOntos reverses name ps i b0 =
  (workerParams, go (S.fromList ps) b0)
  where
    acc = ps !! i
    worker = trmcWorkerName name
    baseAvoid = S.fromList ps `S.union` boundIn b0 `S.union` freeIn b0
    rootP = freshName baseAvoid ("$trmc.root." ++ name)
    lastP = freshName (S.insert rootP baseAvoid) ("$trmc.last." ++ name)
    workerParams = take i ps ++ [rootP, lastP] ++ drop (i + 1) ps
    avoid0 = S.insert rootP (S.insert lastP baseAvoid)
    go bound = \case
      CLet x rhs rest -> CLet x rhs (go (S.insert x bound) rest)
      CIf cond t f -> CIf cond (go bound t) (go bound f)
      CErr msg -> CErr msg
      leaf
        | Just (lets, tailExpr) <- matchExit allDefs revOntos reverses bound acc leaf ->
            let bound' = S.union bound (S.fromList (map fst lets))
                exitCore
                  | isNil bound' tailExpr = CVar rootP
                  | otherwise =
                      let tailV = freshName (avoid0 `S.union` bound') ("$trmc.tail." ++ name)
                          uV = freshName (S.insert tailV (avoid0 `S.union` bound')) ("$trmc.u." ++ name)
                          setCall = CApp (CApp (CVar trmcSetTailName) (CVar lastP)) (CVar tailV)
                       in CLet tailV tailExpr (CLet uV setCall (CVar rootP))
             in foldr (uncurry CLet) exitCore lets
        | (CVar g, args) <- spineOf leaf,
          g == name,
          S.notMember g bound,
          length args == length ps ->
            let before = take i args
                after = drop (i + 1) args
             in case args !! i of
                  CVar y
                    | y == acc ->
                        foldl CApp (CVar worker) (before ++ [CVar rootP, CVar lastP] ++ after)
                  argI
                    | Just (cLets, hd) <- peelCons acc argI ->
                        let avoid1 = avoid0 `S.union` bound
                            (bBinds, bVars, avoid2) = stageArgs avoid1 ("$trmc.wb." ++ name) before
                            cellV = freshName avoid2 ("$trmc.wcell." ++ name)
                            avoid3 = S.insert cellV avoid2
                            (aBinds, aVars, avoid4) = stageArgs avoid3 ("$trmc.wa." ++ name) after
                            uV = freshName avoid4 ("$trmc.wu." ++ name)
                            setCall = CApp (CApp (CVar trmcSetTailName) (CVar lastP)) (CVar cellV)
                            recCall = foldl CApp (CVar worker) (bVars ++ [CVar rootP, CVar cellV] ++ aVars)
                            allBinds = bBinds ++ cLets ++ [(cellV, CMk 2 1 [hd, CMk 2 0 []])] ++ aBinds ++ [(uV, setCall)]
                         in foldr (uncurry CLet) recCall allBinds
                  _ -> leaf
        | otherwise -> leaf

-- Recognize `revOnto (revOnto xs Nil) ys` and `revOnto (reverse xs) ys` (both
-- nested and let-bound) and rewrite them to single-pass TRMC append calls.
rewriteAppendSites :: Prog -> S.Set Name -> S.Set Name -> S.Set Name -> Core -> (Core, Int)
rewriteAppendSites allDefs revOntos reverses = go
  where
    avoidBase e = boundIn e `S.union` freeIn e
    peelTickLets bound = \case
      CLet x a b | isTick a ->
        let (lets, rest, bound') = peelTickLets (S.insert x bound) b
         in ((x, a) : lets, rest, bound')
      e -> ([], e, bound)
    matchInnerRev bound e =
      let (lets, core, bound') = peelTickLets bound e
       in case spineOf core of
            (CVar r, [xs])
              | isReverse allDefs revOntos reverses bound' r ->
                  Just (lets, xs)
            (CVar rv, [xs, nilE])
              | isRevOnto allDefs revOntos bound' rv,
                isNil bound' nilE ->
                  Just (lets, xs)
            _ -> Nothing
    buildAppend avoid lets1 xs lets2 ys =
      let xsV = freshName avoid "$trmc.ap.xs"
          avoid1 = S.insert xsV avoid
          ysV = freshName avoid1 "$trmc.ap.ys"
          avoid2 = S.insert ysV avoid1
          hdV = freshName avoid2 "$trmc.ap.hd"
          avoid3 = S.insert hdV avoid2
          tlV = freshName avoid3 "$trmc.ap.tl"
          avoid4 = S.insert tlV avoid3
          cellV = freshName avoid4 "$trmc.ap.cell"
          callWorker = foldl CApp (CVar trmcAppendName) [CVar tlV, CVar ysV, CVar cellV, CVar cellV]
          branch =
            CIf
              (CTagEq 2 0 (CVar xsV))
              (CVar ysV)
              (CLet
                hdV
                (CProj 0 (CVar xsV))
                (CLet
                  tlV
                  (CProj 1 (CVar xsV))
                  (CLet cellV (CMk 2 1 [CVar hdV, CMk 2 0 []]) callWorker)))
          binds = lets1 ++ [(xsV, xs)] ++ lets2 ++ [(ysV, ys)]
       in foldr (uncurry CLet) branch binds
    go bound e = case e of
      -- Let-bound form: `let t = revOnto xs Nil in revOnto t ys`
      CLet t a b
        | Just (lets1, xs) <- matchInnerRev bound a,
          let (lets2, coreB, boundB) = peelTickLets (S.insert t bound) b,
          (CVar rv2, [CVar t', ys]) <- spineOf coreB,
          t' == t,
          isRevOnto allDefs revOntos boundB rv2,
          not (mentions t ys),
          all (not . mentions t . snd) lets2 ->
            let (xs', n1) = go bound xs
                (ys', n2) = go boundB ys
                avoid = avoidBase e `S.union` boundB
             in (buildAppend avoid lets1 xs' lets2 ys', 1 + n1 + n2)
      -- Nested form: `revOnto (revOnto xs Nil) ys`
      _
        | (CVar rv2, [inner, ys]) <- spineOf e,
          isRevOnto allDefs revOntos bound rv2,
          Just (lets1, xs) <- matchInnerRev bound inner ->
            let (xs', n1) = go bound xs
                (ys', n2) = go bound ys
                avoid = avoidBase e `S.union` bound
             in (buildAppend avoid lets1 xs' [] ys', 1 + n1 + n2)
      CLet x a b ->
        let (a', n1) = go bound a
            (b', n2) = go (S.insert x bound) b
         in (CLet x a' b', n1 + n2)
      CApp a b ->
        let (a', n1) = go bound a
            (b', n2) = go bound b
         in (CApp a' b', n1 + n2)
      CIf c t f ->
        let (c', n1) = go bound c
            (t', n2) = go bound t
            (f', n3) = go bound f
         in (CIf c' t' f', n1 + n2 + n3)
      CMk t v xs ->
        let rs = map (go bound) xs
         in (CMk t v (map fst rs), sum (map snd rs))
      CTagEq t v x ->
        let (x', n) = go bound x
         in (CTagEq t v x', n)
      CProj k x ->
        let (x', n) = go bound x
         in (CProj k x', n)
      CLam ps b ->
        let (b', n) = go (S.union (S.fromList ps) bound) b
         in (CLam ps b', n)
      _ -> (e, 0)

appendWorkerDef :: ([Name], Core)
appendWorkerDef =
  ( [xs, ys, root, lastP],
    CIf
      (CTagEq 2 0 (CVar xs))
      (CLet u (CApp (CApp (CVar trmcSetTailName) (CVar lastP)) (CVar ys)) (CVar root))
      (CLet
        hd
        (CProj 0 (CVar xs))
        (CLet
          tl
          (CProj 1 (CVar xs))
          (CLet
            cell
            (CMk 2 1 [CVar hd, CMk 2 0 []])
            (CLet
              u
              (CApp (CApp (CVar trmcSetTailName) (CVar lastP)) (CVar cell))
              (foldl CApp (CVar trmcAppendName) [CVar tl, CVar ys, CVar root, CVar cell])))))
  )
  where
    xs = "$trmc.ap.xs"
    ys = "$trmc.ap.ys"
    root = "$trmc.ap.root"
    lastP = "$trmc.ap.last"
    hd = "$trmc.ap.hd"
    tl = "$trmc.ap.tl"
    cell = "$trmc.ap.cell"
    u = "$trmc.ap.u"

trmcProgram :: Prog -> (Prog, [String])
trmcProgram = trmcProgramWithImports M.empty

trmcProgramWithImports :: Prog -> Prog -> (Prog, [String])
trmcProgramWithImports imports prog
  | M.null plans && appendSites == 0 = (prog, [])
  | otherwise = (prog', [note])
  where
    allDefs = prog `M.union` imports
    revOntos = revOntoSet allDefs
    reverses = reverseSet allDefs revOntos
    eligibleName n =
      not (internalWorker n)
        && not ("$loop." `isPrefixOf` n)
        && not ("$receive." `isPrefixOf` n)
        && S.notMember n revOntos
        && S.notMember n reverses
    choose (name, (ps, body))
      | not (eligibleName name) || length ps < 2 || length ps > arityLimit || size body > bodyBound = Nothing
      | otherwise =
          let b0 = aliases (S.fromList ps) body
           in case [i | i <- [0 .. length ps - 1], candidateParam allDefs revOntos reverses name ps b0 i] of
                (i : _) -> Just (name, (i, ps, b0))
                [] -> Nothing
    plans = M.fromList (take 128 (mapMaybe choose (M.toAscList prog)))
    entries =
      M.mapWithKey
        (\name def -> case M.lookup name plans of
          Nothing -> def
          Just (i, ps, b0) -> (ps, rewriteEntryBody allDefs revOntos reverses name ps i b0))
        prog
    workers =
      M.fromList
        [ (trmcWorkerName name, makeWorkerDef allDefs revOntos reverses name ps i b0)
        | (name, (i, ps, b0)) <- M.toList plans
        ]
    withLoops = M.union entries workers
    appendRewritten =
      M.map
        (\(ps, b) ->
          let b0 = aliases (S.fromList ps) b
              (b', k) = rewriteAppendSites allDefs revOntos reverses (S.fromList ps) b0
           in ((ps, if k > 0 then b' else b), k))
        withLoops
    appendSites = sum (map snd (M.elems appendRewritten))
    prog' =
      (if appendSites > 0 then M.insert trmcAppendName appendWorkerDef else id)
        (M.map fst appendRewritten)
    note =
      "# trmc: loops="
        ++ show (M.size plans)
        ++ " appends="
        ++ show appendSites
