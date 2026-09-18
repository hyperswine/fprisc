{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}

-- Sol/KIR.hs -- the kernel IR of the hand-rolled JIT tier, and the
-- lowering from typed Core into it.
--
-- One IR, two assemblers (Sol/AsmX64.hs, Sol/AsmA64.hs).  The IR is a
-- STACK machine over 64-bit words: every value on the operand stack is
-- one word, read as an i64 or as f64 bits by the op that consumes it.
-- That uniformity is what makes both backends small and mechanical --
-- the machine stack IS the operand stack, arguments are pushed words,
-- and a float op is "move two words to FP registers, operate, move the
-- result back".  It is not the fastest shape; it is the shape whose
-- correctness is easy to see per instruction, on both ISAs.
--
-- Functions (Fn) come in two flavours:
--   * EXTERN: the driver the VM calls through the FFI.  Its parameters
--     arrive in the platform argument registers (SysV / AAPCS64), the
--     prologue spills them into frame slots 0..n-1, and parameter 0 is
--     ALWAYS the fuel cell pointer, which the prologue also parks in a
--     callee-saved register for the whole call tree.
--   * INTERNAL: compiled Sol variants.  Arguments are the top `nargs`
--     stack words (first argument deepest); the callee reads them as
--     slots 0..nargs-1 through the frame pointer, its own lets follow.
--     Result comes back on the operand stack (via the return register).
--
-- Fuel is REIFIED the way the interpreter and the old LLVM tier did it:
-- every internal function decrements the cell at entry (FuelTick), the
-- driver never does, and the VM reconciles the cell on return.
module Sol.KIR
  ( Ty (..), CC (..), BinOp (..), Op (..), Fn (..), Unit (..), Label,
    LowerEnv (..), VecAcc (..), lowerVariant, lowerDual,
    driverList, driverVec, driverVecMapR, mangleV, showUnit, fuelPoison, fuelTrap,
  ) where

import Control.Monad (forM_, when)
import Control.Monad.State.Strict
import Data.Bits (shiftL, (.&.), (.|.))
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import GHC.Float (castDoubleToWord64, castWord32ToFloat)
import qualified Sol.Bytecode as B
import Sol.JitCore
import Sol.Lang (Core (..), Name)

type Label = String

-- integer division by zero cannot panic from inside native code, so the
-- kernel POISONS the fuel cell with this value (and yields 0) and the VM
-- turns it into the interpreter's "division by zero" panic on return.
-- No legitimate fuel count is anywhere near it.
fuelPoison :: Int64
fuelPoison = -4611686018427387904 -- -2^62

-- an `error` reached inside a kernel: a second poison, further below, so
-- the VM can tell it from a division by zero after any later ticks
fuelTrap :: Int64
fuelTrap = -6917529027641081856 -- -(2^62 + 2^61)

data Ty = TI | TD deriving (Eq, Show)

data CC = CLt | CLe | CGt | CGe | CEq | CNe deriving (Eq, Show)

data BinOp = AddI | SubI | MulI | DivI | AddD | SubD | MulD | DivD deriving (Eq, Show)

data Op
  = PushImm Int64 -- push a word
  | Local Int -- push slot i
  | SetLocal Int -- pop -> slot i
  | LoadIx -- pop idx, pop base; push mem[base + 8*idx]
  | StoreIx -- pop idx, pop base, pop val; mem[base + 8*idx] = val
  | Bin BinOp -- pop b, pop a; push a op b   (DivI is quot: trunc toward 0)
  | Cmp Ty CC -- pop b, pop a; push (a cc b) as 0/1
  | IToD -- pop i64; push f64 bits (exact int -> inexact, sitofp)
  | DToI -- pop f64 bits; push i64 (truncating fptosi; used after floor/rint)
  | SqrtD
  | FloorD
  | RintD -- round to nearest, ties to even (Haskell `round`)
  | Jz Label -- pop; jump if zero
  | Jmp Label
  | Lbl Label
  | Call Label Int -- call with the top n words as args; push the result
  | Ret -- pop; return it
  | FuelTick -- *fuel -= 1
  | Trap -- `error` inside a kernel: poison the fuel cell with fuelTrap, push 0
  deriving (Eq, Show)

data Fn = Fn
  { fnLabel :: Label,
    fnExtern :: Bool,
    fnParams :: Int, -- extern: register args spilled to slots 0..n-1
    fnSlots :: Int, -- total frame slots (params included)
    fnBody :: [Op]
  }

-- the first fn is the extern entry whose address the VM receives
newtype Unit = Unit [Fn]

showUnit :: Unit -> String
showUnit (Unit fs) = unlines (concatMap sh fs)
  where
    sh f = (fnLabel f ++ (if fnExtern f then " [extern]" else "") ++ " params=" ++ show (fnParams f) ++ " slots=" ++ show (fnSlots f) ++ ":") : map (("  " ++) . show) (fnBody f)

-- ---------------------------------------------------------------------
-- lowering monad: ops (reversed), next free slot, next label id
-- ---------------------------------------------------------------------

data G = G {gOps :: [Op], gSlot :: Int, gLbl :: Int}

type Gen = State G

emit :: Op -> Gen ()
emit o = modify' (\g -> g {gOps = o : gOps g})

fresh :: Gen Int
fresh = state (\g -> (gSlot g, g {gSlot = gSlot g + 1}))

label :: String -> Gen Label
label s = state (\g -> (s ++ "_" ++ show (gLbl g), g {gLbl = gLbl g + 1}))

runGen :: Int -> Gen a -> (a, [Op], Int)
runGen slots0 m = let (a, g) = runState m (G [] slots0 0) in (a, reverse (gOps g), gSlot g)

mangleV :: String -> VKey -> Label
mangleV pre (n, ats) = pre ++ map (\c -> if c `elem` ['a' .. 'z'] ++ ['A' .. 'Z'] ++ ['0' .. '9'] then c else '_') n ++ "_" ++ map tyChar ats

-- ---------------------------------------------------------------------
-- Core -> IR, type-directed (the twin of the old cgExprT: same rules,
-- ops instead of LLVMBuild*)
-- ---------------------------------------------------------------------

data VecAcc = VecAcc
  { vaParam :: Name,
    vaScalar :: Bool,
    vaColTys :: [JTy], -- JW = boxed, never loaded (the guard refused it)
    vaColsSlot :: Int, -- slot holding cols** (the lent column-pointer array)
    vaIdxSlot :: Int -- slot holding the row index
  }

data LowerEnv = LowerEnv
  { leSigs :: M.Map VKey JTy,
    leCl :: M.Map Name ([Name], Core),
    lePre :: String, -- label prefix of this unit's variants
    leVec :: Maybe VecAcc
  }

-- promote-only coercion of the word on top of the stack
coerceTop :: JTy -> JTy -> Gen ()
coerceTop from to
  | from == JB = pure () -- a trapped branch: its word is never read
  | isF from == isF to = pure ()
  | not (isF from) = emit IToD
  | otherwise = error ("kir coerce: demotion " ++ show from ++ " -> " ++ show to ++ " (inference bug)")

-- pure typing of a subterm (same rules as the emitter; used where an
-- operand's type is needed BEFORE it is emitted: the other side of a
-- binary op, the branches of an if)
tyOf :: LowerEnv -> S.Set Name -> M.Map Name (Int, JTy) -> Core -> JTy
tyOf le es env e =
  let tenv = M.map snd env
      r = case leVec le of
        Just va -> tyExprV (leSigs le) (leCl le) (vaScalar va) (vaColTys va) es tenv e
        Nothing -> tyExpr (leSigs le) (leCl le) tenv e
   in maybe (error ("kir tyOf: untypeable subterm survived the guard: " ++ show e)) fst r

lowerExpr :: LowerEnv -> S.Set Name -> M.Map Name (Int, JTy) -> Core -> Gen JTy
lowerExpr le es0 env0 e0 = go es0 env0 e0
  where
    go es env = \case
      CInt i -> emit (PushImm (fromIntegral i)) >> pure JI
      CApp (CVar "error") (CStr _) -> emit Trap >> pure JB
      CApp (CApp (CVar "f64frombits") (CInt hi)) (CInt lo) -> do
        emit (PushImm (fromIntegral ((fromIntegral hi `shiftL` 32) .|. (fromIntegral lo .&. 0xFFFFFFFF) :: Integer)))
        pure JD
      CApp (CVar "f32frombits") (CInt b) -> do
        emit (PushImm (fromIntegral (castDoubleToWord64 (realToFrac (castWord32ToFloat (fromIntegral b))))))
        pure JD
      CVar x
        | Just va <- leVec le, S.member x es -> loadCol va 0
        | Just (s, t) <- M.lookup x env -> emit (Local s) >> pure t
        | Just ret <- M.lookup (x, []) (leSigs le) -> emit (Call (mangleV (lePre le) (x, [])) 0) >> pure ret
        | otherwise -> error ("kir lower: unbound " ++ x)
      CProj k (CVar x)
        | Just va <- leVec le, S.member x es -> loadCol va k
      CLet x (CVar v) b | S.member v es -> go (S.insert x es) env b -- alias of the element
      CLet x a b -> do
        ta <- go es env a
        s <- fresh
        emit (SetLocal s)
        go (S.delete x es) (M.insert x (s, ta) env) b
      CIf c t f -> do
        _ <- go es env c
        lElse <- label "else"
        lEnd <- label "end"
        let tj = joinT (tyOf le es env t) (tyOf le es env f)
        emit (Jz lElse)
        tt <- go es env t
        coerceTop tt tj
        emit (Jmp lEnd)
        emit (Lbl lElse)
        tf <- go es env f
        coerceTop tf tj
        emit (Lbl lEnd)
        pure tj
      CTagEq 1 v e -> do
        _ <- go es env e
        emit (PushImm 0)
        emit (Cmp TI (if v == 1 then CNe else CEq))
        pure JI
      e@CApp {} ->
        let (h, args) = B.spine e
         in case h of
              CVar g
                | Just op <- M.lookup g B.arithOps,
                  [x, y] <- args,
                  not (M.member g env),
                  not (S.member g es) -> do
                    let ty0 = tyOf le es env y
                    tx <- go es env x
                    let rt = case op of
                          B.ODiv -> promoT tx ty0
                          B.OAdd -> promoT tx ty0
                          B.OSub -> promoT tx ty0
                          B.OMul -> promoT tx ty0
                          _ -> promoT tx ty0 -- comparisons: operand kind
                    when (isF rt) (coerceTop tx JD)
                    ty <- go es env y
                    when (isF rt) (coerceTop ty JD)
                    arith op rt
                | Just (_, _) <- M.lookup g numPrims,
                  not (M.member g env),
                  not (S.member g es) -> do
                    forM_ args $ \a -> go es env a >>= \ta -> coerceTop ta JD
                    numPrim g
                | not (M.member g env),
                  not (S.member g es) -> do
                    tys <- mapM (go es env) args
                    let key = (g, tys)
                    case M.lookup key (leSigs le) of
                      Just ret -> emit (Call (mangleV (lePre le) key) (length args)) >> pure ret
                      Nothing -> error ("kir lower: missing variant " ++ g ++ "/" ++ map tyChar tys)
              _ -> error "kir lower: non-compilable application survived the guard"
      other -> error ("kir lower: non-compilable node survived the guard: " ++ show other)

    loadCol va k = do
      let t = vaColTys va !! k
      emit (Local (vaColsSlot va))
      emit (PushImm (fromIntegral k))
      emit LoadIx -- cols[k]: the column base
      emit (Local (vaIdxSlot va))
      emit LoadIx -- base[idx]
      pure t

    arith op rt = case op of
      B.OAdd -> bin AddI AddD
      B.OSub -> bin SubI SubD
      B.OMul -> bin MulI MulD
      B.ODiv -> case rt of
        JW -> error "kir arith: ODiv on JW operands (inference bug)"
        _ -> bin DivI DivD
      B.OLt -> cmp CLt
      B.OLe -> cmp CLe
      B.OGt -> cmp CGt
      B.OGe -> cmp CGe
      B.OEq -> cmp CEq
      B.ONe -> cmp CNe
      where
        bin i d = emit (Bin (if isF rt then d else i)) >> pure rt
        cmp cc = emit (Cmp (if isF rt then TD else TI) cc) >> pure JI

    numPrim g = case g of
      "Num.div" -> emit (Bin DivD) >> pure JD
      "Num.sqrt" -> emit SqrtD >> pure JD
      "Num.floor" -> emit FloorD >> emit DToI >> pure JI
      "Num.round" -> emit RintD >> emit DToI >> pure JI
      _ -> error ("kir numPrim: " ++ g)

-- a compiled Sol variant: params are slots 0..k-1, typed by the key
lowerVariant :: LowerEnv -> VKey -> JTy -> Fn
lowerVariant le key@(n, ats) ret =
  let Just (ps, body) = M.lookup n (leCl le)
      env0 = M.fromList (zip ps (zip [0 ..] ats))
      ((), ops, slots) = runGen (length ps) $ do
        emit FuelTick
        t <- lowerExpr le S.empty env0 body
        coerceTop t ret
        emit Ret
   in Fn (mangleV (lePre le) key) False (length ps) slots ops

-- the vec DUAL: params = extras ++ [acc] ++ [cols, idx]; the element
-- param never holds a value -- it resolves to column loads
lowerDual :: LowerEnv -> Label -> [Name] -> [JTy] -> Maybe (Name, JTy) -> Name -> Bool -> [JTy] -> Core -> JTy -> Fn
lowerDual le lab exPs exTys macc elemP scalar colTys body ret =
  let nEx = length exTys
      accEnv = maybe [] (\(a, t) -> [(a, (nEx, t))]) macc
      nAcc = maybe 0 (const 1) macc
      colsSlot = nEx + nAcc
      idxSlot = colsSlot + 1
      env0 = M.fromList (zip exPs (zip [0 ..] exTys) ++ accEnv)
      va = VecAcc elemP scalar colTys colsSlot idxSlot
      le' = le {leVec = Just va}
      ((), ops, slots) = runGen (idxSlot + 1) $ do
        emit FuelTick
        t <- lowerExpr le' (S.singleton elemP) env0 body
        coerceTop t ret
        emit Ret
   in Fn lab False (idxSlot + 1) slots ops

-- ---------------------------------------------------------------------
-- drivers, in the same IR (so the A64 backend gets them for free)
-- ---------------------------------------------------------------------

-- list tier: i64 drv(fuel*, in*, n, out*/acc0)
--   map:    out[i] = f(in[i]); returns n
--   filter: out[k++] = in[i] when f(in[i]) != 0; returns k
--   foldl:  acc = f(acc, in[i]); returns acc (f64 acc travels as bits)
driverList :: Label -> String -> Label -> JTy -> JTy -> Fn
driverList lab scheme root accTy retTy =
  let pin = 1; n = 2; p3 = 3; i = 4; k = 5; x = 6
      ((), ops, slots) = runGen 7 $ do
        emit (PushImm 0) >> emit (SetLocal i)
        emit (PushImm 0) >> emit (SetLocal k)
        emit (Lbl "loop")
        emit (Local i) >> emit (Local n) >> emit (Cmp TI CLt) >> emit (Jz "exit")
        emit (Local pin) >> emit (Local i) >> emit LoadIx >> emit (SetLocal x)
        case scheme of
          "map" -> do
            emit (Local x) >> emit (Call root 1)
            emit (Local p3) >> emit (Local i) >> emit StoreIx
          "filter" -> do
            emit (Local x) >> emit (Call root 1) >> emit (Jz "skip")
            emit (Local x) >> emit (Local p3) >> emit (Local k) >> emit StoreIx
            emit (Local k) >> emit (PushImm 1) >> emit (Bin AddI) >> emit (SetLocal k)
            emit (Lbl "skip")
          _ -> do
            emit (Local p3) >> emit (Local x) >> emit (Call root 2)
            when (isF accTy && not (isF retTy)) (emit IToD)
            emit (SetLocal p3)
        emit (Local i) >> emit (PushImm 1) >> emit (Bin AddI) >> emit (SetLocal i)
        emit (Jmp "loop")
        emit (Lbl "exit")
        emit (Local (case scheme of "map" -> n; "filter" -> k; _ -> p3))
        emit Ret
   in Fn lab True 4 slots ops

-- vec tier: i64 drv(fuel*, extras*, cols**, n, out*/acc0)
--   the dual takes (extras..., [acc,] cols, idx); extras are loaded once
--   vecfilter stores kept row INDICES
driverVec :: Label -> String -> Label -> Int -> JTy -> JTy -> Fn
driverVec lab scheme dual nEx accTy retTy =
  let extras = 1; cols = 2; n = 3; p4 = 4; i = 5; k = 6; ex0 = 7
      isFold = scheme == "vecfold"
      ((), ops, slots) = runGen (ex0 + nEx) $ do
        forM_ [0 .. nEx - 1] $ \j ->
          emit (Local extras) >> emit (PushImm (fromIntegral j)) >> emit LoadIx >> emit (SetLocal (ex0 + j))
        emit (PushImm 0) >> emit (SetLocal i)
        emit (PushImm 0) >> emit (SetLocal k)
        emit (Lbl "loop")
        emit (Local i) >> emit (Local n) >> emit (Cmp TI CLt) >> emit (Jz "exit")
        let callDual = do
              forM_ [0 .. nEx - 1] $ \j -> emit (Local (ex0 + j))
              when isFold (emit (Local p4))
              emit (Local cols) >> emit (Local i)
              emit (Call dual (nEx + (if isFold then 1 else 0) + 2))
        case scheme of
          "vecmap" -> do
            callDual
            emit (Local p4) >> emit (Local i) >> emit StoreIx
          "vecfilter" -> do
            callDual >> emit (Jz "skip")
            emit (Local i) >> emit (Local p4) >> emit (Local k) >> emit StoreIx
            emit (Local k) >> emit (PushImm 1) >> emit (Bin AddI) >> emit (SetLocal k)
            emit (Lbl "skip")
          _ -> do
            callDual
            when (isF accTy && not (isF retTy)) (emit IToD)
            emit (SetLocal p4)
        emit (Local i) >> emit (PushImm 1) >> emit (Bin AddI) >> emit (SetLocal i)
        emit (Jmp "loop")
        emit (Lbl "exit")
        emit (Local (case scheme of "vecmap" -> n; "vecfilter" -> k; _ -> p4))
        emit Ret
   in Fn lab True 5 slots ops

-- vecmapr: i64 drv(fuel*, extras*, cols**, n, outs**): one dual per
-- field, each row's k results landing in k output columns; returns n
driverVecMapR :: Label -> [Label] -> Int -> Fn
driverVecMapR lab duals nEx =
  let extras = 1; cols = 2; n = 3; outs = 4; i = 5; ex0 = 6; ob0 = ex0 + nEx
      nf = length duals
      ((), ops, slots) = runGen (ob0 + nf) $ do
        forM_ [0 .. nEx - 1] $ \j ->
          emit (Local extras) >> emit (PushImm (fromIntegral j)) >> emit LoadIx >> emit (SetLocal (ex0 + j))
        forM_ [0 .. nf - 1] $ \j ->
          emit (Local outs) >> emit (PushImm (fromIntegral j)) >> emit LoadIx >> emit (SetLocal (ob0 + j))
        emit (PushImm 0) >> emit (SetLocal i)
        emit (Lbl "loop")
        emit (Local i) >> emit (Local n) >> emit (Cmp TI CLt) >> emit (Jz "exit")
        forM_ (zip [0 ..] duals) $ \(j, d) -> do
          forM_ [0 .. nEx - 1] $ \q -> emit (Local (ex0 + q))
          emit (Local cols) >> emit (Local i)
          emit (Call d (nEx + 2))
          emit (Local (ob0 + j)) >> emit (Local i) >> emit StoreIx
        emit (Local i) >> emit (PushImm 1) >> emit (Bin AddI) >> emit (SetLocal i)
        emit (Jmp "loop")
        emit (Lbl "exit")
        emit (Local n)
        emit Ret
   in Fn lab True 5 slots ops
