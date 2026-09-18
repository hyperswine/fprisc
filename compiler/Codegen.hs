{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}

-- Core -> RISC-V (rv64) assembly.
--
-- Value representation (uniform 64-bit "V"):
--   * integers:   (n << 1) | 1                      (63-bit tagged)
--   * everything else: 8-aligned pointer to object:
--       [ u32 typeid | u32 variant | u64 fields... ]
--     typeids: 0..8 = FPRISC builtins, 10+/100+ = user types/shapes,
--              9000 = string, 9001 = PAP (function), 9002 = Device,
--              9003 = Register, 9004 = Array Bit
--
-- Calling convention: supercombinator fpr_fn_X takes its args in a0..a7
-- (C ABI), returns V in a0. CApp always goes through fpr_apply(f, arg)
-- so partial application Just Works (no closures survive lifting; a
-- function value is a static PAP object = code address + arity).
--
-- Name resolution at codegen time (this IS the linking model):
--   local slot -> known global (fpr_fn_/fpr_obj_) -> core prim
--   (fpr_prim_obj_) -> ANYTHING ELSE becomes an extern fpr_g_<name>:
--   the discoverable-symbol contract the HAL/runtime must satisfy.
--
-- Codegen is deliberately naive: result always in a0, temporaries on
-- the real stack, locals in frame slots. Every effect is a real call;
-- combined with volatile MMIO in the HAL this guarantees device access
-- order matches program order -- nothing is elided or reordered.

module Codegen (emitProgram, externals, Target (..), rv64, rv32, tgtName, codegenRev) where
-- NOTE: emitProgram's `spec` flag gates Vec.map/filter/fold loop
-- specialization: x64 lowering runs with it OFF (SysV has too few
-- callee-saved registers for the s1..s9 spec loops; the generic C
-- vec path is used instead -- slower, correct).

import Modules (ModExport (..))

import Control.Monad (when)
import Control.Monad.State.Strict
import Data.Bits (shiftR, (.&.))
import Data.Char (isAlphaNum, ord)
import Data.List (foldl', intercalate, nub, sort)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Numeric (showHex)

import FPRISC (Core (..), Prog)

-- bump on ANY change to emitted code: it keys the build/units cache
-- (a unit's content hash names its SOURCE, not its compilation)
codegenRev :: Int
codegenRev = 8 -- r7 + native wide arity to 64 (argspill 56); aritySpill only past it

-- Target word parameterization: everything the emitted assembly does
-- that depends on XLEN funnels through these five fields.  The value
-- representation is IDENTICAL on both targets modulo the word size W:
-- header u32 tid | u32 var at 0/4, fields at 8 + W*i, ints (n<<1)|1.
data Target = Target
  { tgtW :: Int,        -- bytes per word (8 / 4)
    tgtLd :: String,    -- word load  (ld / lw)
    tgtSt :: String,    -- word store (sd / sw)
    tgtDir :: String,   -- word data directive (.quad / .word)
    tgtName :: String   -- for the banner comment
  }

rv64, rv32 :: Target
rv64 = Target 8 "ld" "sd" ".quad" "rv64"
rv32 = Target 4 "lw" "sw" ".word" "rv32"

-- tagged-int range check: (n << 1) | 1 must fit a signed word
intFits :: Target -> Integer -> Bool
intFits t n = n >= -b && n < b where b = 2 ^ (tgtW t * 8 - 2)

corePrims :: [String]
corePrims = ["+", "-", "*", "/", "==", "!=", "<", ">", "<=", ">=", "strcat", "str", "error", "print", "String.len", "!"]


--------------------------------------------------------------------------------
-- G1: max IR instructions between fuel safepoints (docs/FUEL-RC-ABI.md)
--------------------------------------------------------------------------------
-- The fuel model bounds GENERATED-code time between safepoints, but a
-- fuel unit is "one safepoint passed", not a duration — G1 in
-- FUEL-RC-ABI.md. This closes it at the compiler: for every emitted
-- function, walk the assembly as a CFG (a DAG — all loops are tail
-- calls, so intra-function branches are forward) and compute the
-- maximum number of instructions on any path between two consecutive
-- safepoint events. Events: the entry fuel check, any later
-- `call fpr_fuel_exhausted` (vector-kernel checks), and any call/jump
-- into an fpr_fn_* (the callee's entry check fires next).
--
-- Counts are pre-lowering IR instructions: the per-target lowering
-- multiplies by a small bounded factor (x64 fixups etc.), which
-- belongs to the hw/target column of the WCET triple, not here.
-- Calls to C (anything not fpr_fn_*/fpr_fuel_exhausted) do NOT reset
-- and contribute their own per-(qos,hw) bound (G2); we count them.
-- Cross-function chaining caveat: the tail of a caller after its last
-- fpr call extends the callee's final segment; the per-function
-- segmax composes with that via the printed exit-tail term.
--
-- Output: one `# wcet:` comment per function; FPRC_WCET=1 makes Main
-- print the table and the program maximum.

data WBlock = WBlock
  { wRuns :: [Int], -- instruction runs split by reset events (n runs = n-1 resets inside)
    wCCalls :: Int,
    wSuccs :: [String], -- label successors (branch targets + fallthrough)
    wExit :: Bool -- ends in ret (or falls off the end / tail-jumps out)
  }

wcetAnnotate :: String -> [String] -> [String]
wcetAnnotate fname lns =
  lns ++ ["# wcet: " ++ fname ++ " segmax=" ++ segS ++ " exittail=" ++ tailS ++ " ccalls=" ++ show ccTotal]
  where
    segS = maybe "UNBOUNDED" show segMax'
    tailS = maybe "UNBOUNDED" show exitTail'
    -- ---- tokenize into (label | instruction) stream ----
    toks = concatMap tok lns
    tok l =
      let t = dropWhile (== ' ') l
       in if null t || head t == '#'
            then []
            else
              if last t == ':' && ' ' `notElem` t
                then [Left (init t)]
                else
                  if head t == '.'
                    then [] -- directive
                    else [Right (words t)]
    -- ---- split into blocks at labels ----
    blocks :: [(String, [[String]])]
    blocks = go "%entry" [] toks
      where
        go cur acc [] = [(cur, reverse acc)]
        go cur acc (Left lbl : rest) = (cur, reverse acc) : go lbl [] rest
        go cur acc (Right i : rest) = go cur (i : acc) rest
    labels = [l | (l, _) <- blocks]
    labelSet = S.fromList labels
    nextMap = M.fromList (zip labels (drop 1 labels))
    nextOf l = M.lookup l nextMap
    -- ---- classify one instruction ----
    isReset ws = case ws of
      ("call" : t : _) -> t == "fpr_fuel_exhausted" || isFprFn t
      ("j" : t : _) -> isFprFn t
      ("jmp" : t : _) -> isFprFn t
      _ -> False
    isFprFn t = take 7 t == "fpr_fn_"
    isCCall ws = case ws of
      ("call" : t : _) -> not (t == "fpr_fuel_exhausted" || isFprFn t)
      _ -> False
    isRet ws = ws == ["ret"]
    isUncond ws = case ws of ("j" : t : _) -> not (isFprFn t); _ -> False
    isCond ws = case ws of
      (op : _) -> take 1 op == "b" && op /= "call"
      _ -> False
    target ws = last ws
    -- ---- per-block summary ----
    summarize :: String -> [[String]] -> WBlock
    summarize lbl is = WBlock runs cc succs exits
      where
        cc = length (filter isCCall is)
        runs = splitRuns 0 is
        splitRuns n [] = [n]
        splitRuns n (w : rest)
          | isReset w = n : splitRuns 0 rest
          | otherwise = splitRuns (n + 1) rest
        condTargets = [target w | w <- is, isCond w]
        lastI = if null is then [] else last is
        fallsOff = null is || not (isUncond lastI || isRet lastI || endsInFprJump lastI)
        endsInFprJump w = case w of ("j" : t : _) -> isFprFn t; ("jmp" : t : _) -> isFprFn t; _ -> False
        uncondT = [target lastI | not (null is), isUncond lastI]
        succs = filter (`S.member` labelSet) (condTargets ++ uncondT ++ [n | fallsOff, Just n <- [nextOf lbl]])
        exits = (not (null is) && (isRet lastI || endsInFprJump lastI)) || (fallsOff && nextOf lbl == Nothing)
    bmap = [(l, summarize l is) | (l, is) <- blocks]
    blockMap = M.fromList bmap
    -- ---- maxFrom: max insns from block start to first reset/exit ----
    -- Memoized DFS with a grey (on-stack) set: a back-edge (shouldn't
    -- exist — all loops are tail calls) yields Nothing = UNBOUNDED,
    -- loudly, exactly as before; the memo table makes the walk linear.
    -- (The previous path-guarded walk recomputed every diamond's tail
    -- once per path through the diamond — exponential in join depth;
    -- voxel's ddaStep was the first function big enough to make that
    -- non-terminating in practice.)
    maxTab :: M.Map String (Maybe Int)
    maxTab = foldl' (\m l -> fst (visit S.empty m l)) M.empty labels
    visit grey m l
      | Just v <- M.lookup l m = (m, v)
      | S.member l grey = (m, Nothing) -- back-edge: l is on a real cycle
      | otherwise = case M.lookup l blockMap of
          Nothing -> (m, Just 0)
          Just b ->
            let r1 = head (wRuns b)
             in if length (wRuns b) > 1
                  then (M.insert l (Just r1) m, Just r1) -- reset inside this block ends the segment
                  else
                    let (m1, v) = visitSuccs (S.insert l grey) m b
                        r = fmap (r1 +) v
                     in (M.insert l r m1, r)
    visitSuccs grey m b
      | null (wSuccs b) = (m, Just 0)
      | otherwise =
          let step (mm, acc) s = let (mm1, v) = visit grey mm s in (mm1, v : acc)
              (m1, vs) = foldl' step (m, []) (wSuccs b)
           in (m1, maximumM vs)
    maxFrom :: String -> Maybe Int
    maxFrom l = M.findWithDefault (Just 0) l maxTab -- absent label: not a block, 0 (as before)
    succMax b
      | null (wSuccs b) = Just 0
      | otherwise = maximumM [maxFrom s | s <- wSuccs b]
    maximumM ms = if any (== Nothing) ms then Nothing else Just (maximum [m | Just m <- ms])
    -- segments STARTING at a reset inside a block: trailing run + onward
    afterResets :: Maybe [Int]
    afterResets = sequence
      [ seg
        | (l, b) <- bmap,
          length (wRuns b) > 1,
          let lastRun = last (wRuns b),
          let inner = init (drop 1 (wRuns b)), -- complete segments inside the block
          seg <-
            map Just inner
              ++ [fmap (lastRun +) (succMax b)]
      ]
    segMax' = do
      entry <- maxFrom (fst (head bmap))
      rest <- afterResets
      pure (maximum (entry : rest ++ [0]))
    -- exit-tail: max insns from the LAST reset to a ret (for chaining)
    exitTail' = segMax' -- conservative: the true tail <= segmax; refine later
    ccTotal = sum [wCCalls b | (_, b) <- bmap]

mangle :: String -> String
mangle = concatMap enc
  where
    enc c
      | isAlphaNum c = [c]
      | otherwise = "_x" ++ pad (showHex (ord c) "")
    pad s = if length s < 2 then '0' : s else s

-- every CVar that is neither local, global, nor core prim: the assumed
-- external symbol set (for reporting the HAL contract)
externals :: M.Map String Int -> Prog -> [String]
externals ext prog = sort . nub $ concat [go ps b | (_, (ps, b)) <- M.toList prog]
  where
    go env = \case
      CVar n
        | n `elem` env || M.member n prog || M.member n ext || n `elem` corePrims -> []
        | otherwise -> [n]
      CApp a b -> go env a ++ go env b
      CLet x a b -> go env a ++ go (x : env) b
      CIf a b c -> go env a ++ go env b ++ go env c
      CMk _ _ fs -> concatMap (go env) fs
      CTagEq _ _ e -> go env e
      CProj _ e -> go env e
      CLam ps b -> go (ps ++ env) b
      _ -> []

data CG = CG
  { cgN :: Int,
    cgStrs :: M.Map String String,
    cgTgt :: Target,
    cgRvv :: Bool,
    cgSpec :: Bool, -- vec loop specialization enabled for this target?
    cgSpecs :: M.Map (String, String) (String, SpecPlan), -- (op, fn) -> (label, plan)
    -- separate compilation:
    cgExt :: M.Map String Int, -- extern known globals (other units): name -> arity
    cgExports :: S.Set String, -- THIS unit's cross-unit-visible names (.globl gate)
    cgVNotes :: [String] -- Vec.x sites that DECLINED specialization (printed by Compile)
  }

-- one specialization request: a Vec.map/filter/fold call site whose
-- element function is statically known and arithmetic-only
data SpecPlan = SpecPlan
  { spOp :: String, -- "map" | "filter" | "fold"
    spFn :: String, -- the element function (top-level supercombinator)
    spScalar :: Bool, -- scalar-Int loop possible (arith closure exists)
    spClosure :: S.Set String, -- fpr_ufn_ bodies this needs
    spSoa :: Maybe ([Int], [String], Core, (Int, Int)), -- fold only: (used cols, params, dualized body, required eltid/elvar)
    spRvv :: Maybe RvvPlan,
    -- Vec.map (f cap) v where f's body (after inlining) is a
    -- record->record multiply-add over the element's columns and the
    -- captured record's fields (the Mat4*Vec4 shape).  Per output
    -- column one tiny unboxed field fn; the loop runs IN PLACE.
    spMv :: Maybe MvPlan,
    -- Just w when the element closure computes in floats: the loop's
    -- rep guard demands the FLOAT column rep instead of the Int one,
    -- and the unboxed clone's arithmetic is fadd.d/fmul.d/...  The
    -- loop body itself is unchanged -- a raw column word is a raw
    -- column word.
    spFloat :: Maybe String
  }

data MvPlan = MvPlan
  { mvTid :: (Int, Int), -- required eltid/elvar (spec guard)
    mvN :: Int, -- field/column count (cols 0..n-1, in place)
    mvFields :: [(([Int], [Int]), ([String], Core))] -- per field: ((cap projs, col idxs), (params, dual body))
  }
  deriving (Eq)

data RvvPlan
  = RvvMap String Core -- param name, straight-line body
  | RvvFoldSum -- fold whose fn is \a b -> a + b
  deriving (Eq)


type G = State CG

freshL :: String -> G String
freshL p = do
  n <- gets cgN
  modify (\s -> s {cgN = n + 1})
  pure (".L" ++ p ++ show n)

strLabel :: String -> G String
strLabel s = do
  m <- gets cgStrs
  case M.lookup s m of
    Just l -> pure l
    Nothing -> do
      l <- freshL "str"
      modify (\c -> c {cgStrs = M.insert s l (cgStrs c)})
      pure l

emitProgram :: Target -> Bool -> Bool -> [ModExport] -> M.Map String Int -> S.Set String -> Prog -> (String, [String])
emitProgram tgt rvv spec exports ext exps prog0 =
  let prog = fuseVecFix prog0 -- fusion is tier-independent: fewer passes
      -- win in the generic apply tier too, and linearity (not the spec
      -- loops) is what makes the rewrite sound
      (body, st) = runState (top prog) (CG 0 M.empty tgt rvv spec M.empty ext exps [])
   in (unlines body, reverse (cgVNotes st))
  where
    top prog = do
      -- specialization-decline scan: a Vec.map/filter/fold site whose
      -- element fn is a NAMED global but which no plan accepts runs
      -- row-by-row in the generic apply tier.  Say so at compile time
      -- -- the record-SoA round was bitten by exactly this class of
      -- silent fallback (emitted, grepped for, never run).  Lambdas /
      -- closures are not candidates (lifting gives them capture shapes
      -- beyond the plans) and stay quiet; a named fn that fails is
      -- worth a line.  The scan runs even where the tier itself is OFF
      -- (x64): a target that runs EVERY site generic owes the loudest
      -- notes of all, not silence -- there the note names the target
      -- gate, and distinguishes sites that would specialize elsewhere.
      modify (\st -> st {cgVNotes = concat [declines spec prog fn b | (fn, (_, b)) <- M.toList prog] ++ cgVNotes st})
      fns <- concat <$> mapM (uncurry (compileFn prog)) (M.toList prog)
      specs <- emitSpecs prog
      modtab <- if null exports then pure [] else modTable
      strs <- gets cgStrs
      pure $
        ( ["# target: " ++ tgtName tgt]
            ++ ["    .option arch, +v" | rvv] -- let gas accept vector mnemonics
            ++ ["    .text", "    .balign 4", ""]
        )
          ++ rvvInit
          ++ fns
          ++ specs
          ++ ["    .section .rodata", ""]
          ++ concatMap objFor (M.toList prog)
          ++ modtab
          ++ concatMap strFor (M.toList strs)
          ++ concatMap nulFor (S.toList (nullaries prog))
    -- the module table: (hash str, export-name str, static PAP) triples,
    -- zero-terminated.  mod.c's `Mod.fn hash name` scans it — the local
    -- half of FPRLive remote calling: dispatch is by module HASH plus
    -- function name, never by position or link order.
    modTable = do
      rows <- concat <$> mapM row [me | me <- exports, meArity me >= 1]
      pure $
        [ "    .balign 8",
          "    .globl fpr_modtab",
          "fpr_modtab:"
        ]
          ++ rows
          ++ ["    " ++ tgtDir tgt ++ " 0", ""]
      where
        row me = do
          hl <- strLabel (meHash me)
          nl <- strLabel (meName me)
          pure
            [ "    " ++ tgtDir tgt ++ " " ++ hl,
              "    " ++ tgtDir tgt ++ " " ++ nl,
              "    " ++ tgtDir tgt ++ " fpr_obj_" ++ mangle (meQual me)
            ]
    -- with --rvv the runtime calls this (weak hook from fpr_rt_init) to
    -- turn the vector unit on: mstatus.VS = Initial (01 << 9).  Emitted
    -- here so images built WITHOUT --rvv never touch mstatus.VS and run
    -- on V-less cores untouched.
    rvvInit
      | not rvv = []
      | otherwise =
          -- COMDAT group: every --rvv unit carries this identical
          -- definition and the linker keeps exactly ONE -- the fix for
          -- the audit's multiple-definition failure (program + prelude
          -- + every module unit each used to emit a strong copy).  The
          -- surviving strong symbol still overrides runtime.c's weak
          -- no-op, so V-less builds never touch mstatus.VS.
          [ "    .section .text.fpr_rvv_enable,\"axG\",@progbits,fpr_rvv_enable,comdat",
            "    .balign 4",
            "    .globl fpr_rvv_enable",
            "fpr_rvv_enable:",
            "    li t0, 0x600", -- VS field, both bits: Dirty (safe superset)
            "    csrs mstatus, t0",
            "    ret",
            "    .text",
            ""
          ]
    -- static PAP object per global with arity > 0: a "function value"
    -- is just this object's address (code ptr + arity + no args yet)
    objFor (n, (ps, _))
      | null ps = []
      | otherwise =
          let m = mangle n
           in [ "    .balign 8" ]
              ++ [ "    .globl fpr_obj_" ++ m | S.member n exps ]
              ++ [
                "fpr_obj_" ++ m ++ ":",
                "    .long 9001",
                "    .long 0",
                "    " ++ tgtDir tgt ++ " fpr_fn_" ++ m,
                "    " ++ tgtDir tgt ++ " " ++ show (length ps),
                "    " ++ tgtDir tgt ++ " 0",
                ""
              ]
    -- one immortal object per (tid, var) nullary constructor used here
    nullaries p = S.fromList (concat [scan b | (_, (_, b)) <- M.toList p])
      where
        scan = \case
          CMk t v [] -> [(t, v)]
          CMk _ _ fs -> concatMap scan fs
          CApp a b -> scan a ++ scan b
          CLam _ b -> scan b
          CLet _ a b -> scan a ++ scan b
          CIf a b c -> scan a ++ scan b ++ scan c
          CTagEq _ _ e -> scan e
          CProj _ e -> scan e
          _ -> []
    nulFor (t, v) =
      [ "    .balign 8",
        ".Lnul_" ++ show t ++ "_" ++ show v ++ ":",
        "    .long " ++ show t,
        "    .long " ++ show v,
        ""
      ]
    strFor (content, label) =
      -- string payloads are UTF-8 BYTES: a codepoint above 0x7F must be
      -- encoded, not truncated to its low byte by the assembler (which
      -- is what `.byte 8212` silently does -- em-dashes became 0x14).
      -- The length field is the BYTE length for the same reason.
      let bs = concatMap utf8 content
       in [ "    .balign 8",
            label ++ ":",
            "    .long 9000",
            "    .long 0",
            "    " ++ tgtDir tgt ++ " " ++ show (length bs)
          ]
            ++ byteLines bs
            ++ [""]
    utf8 c
      -- 0x00-0xFF pass through as RAW single bytes: \xNN escapes are
      -- wire data (SPI/OLED byte strings) and must stay bytes.
      -- Codepoints >= 0x100 are text and encode as UTF-8 (em-dashes
      -- etc. were being truncated to their low byte before this).
      | v < 0x100 = [v]
      | v < 0x800 = [0xC0 + shiftR v 6, 0x80 + (v .&. 0x3F)]
      | v < 0x10000 = [0xE0 + shiftR v 12, 0x80 + (shiftR v 6 .&. 0x3F), 0x80 + (v .&. 0x3F)]
      | otherwise = [0xF0 + shiftR v 18, 0x80 + (shiftR v 12 .&. 0x3F), 0x80 + (shiftR v 6 .&. 0x3F), 0x80 + (v .&. 0x3F)]
      where v = ord c
    byteLines [] = []
    byteLines s =
      let (a, b) = splitAt 16 s
       in ("    .byte " ++ intercalate ", " (map show a)) : byteLines b

-- True high-water mark of frame slots `gen` will use for a body,
-- mirroring go's slot discipline exactly:
--   * CLet: the bound value evaluates at nxt (result stored in slot
--     nxt), the body runs at nxt+1  ->  max (slots a) (1 + slots b)
--   * known saturated call: arg i is STAGED in slot nxt+i and its own
--     evaluation runs above at nxt+i+1  ->  nesting compounds, which is
--     exactly what the old flat `countLets + 8` estimate missed (deeply
--     nested constructor literals like a whole VFS tree overflow the
--     frame and calls then clobber the below-sp temporaries)
--   * everything else (CIf branches, CMk fields, generic CApp) runs
--     subterms at the same nxt: intermediate values go via the machine
--     stack, not slots.
slotsNeeded :: M.Map String Int -> Prog -> S.Set String -> Core -> Int
slotsNeeded ext prog = go0
  where
    isKnown bound h n
      | S.member h bound = False
      | Just (ps, _) <- M.lookup h prog = length ps == n && n > 0
      -- CROSS-UNIT known calls spill args to slots exactly like local
      -- ones; omitting ext here undercounted the frame, spilled below
      -- sp, and let the timer trap eat the temp (the slotclobber bug)
      | Just a <- M.lookup h ext = a == n && n > 0
      | Just a <- lookup h primArities = a == n
      | otherwise = False
    go0 bound e
      | (CVar h, args@(_ : _)) <- spineOf e,
        isKnown bound h (length args) =
          maximum (length args : [i + 1 + go0 bound a | (i, a) <- zip [0 ..] args])
    go0 bound e
      | Just (_, args) <- vecSpec prog (`S.member` bound) e =
          maximum (length args : [i + 1 + go0 bound a | (i, a) <- zip [0 ..] args])
    go0 bound (CIf c t e) = maximum [go0 bound c, go0 bound t, go0 bound e]
    go0 bound (CLet x a b) = max (go0 bound a) (1 + go0 (S.insert x bound) b)
    go0 bound (CApp f a) = max (go0 bound f) (go0 bound a)
    go0 bound (CMk _ _ fs) = maximum (0 : map (go0 bound) fs)
    go0 bound (CTagEq _ _ s) = go0 bound s
    go0 bound (CProj _ s) = go0 bound s
    go0 bound (CLam _ b) = go0 bound b -- lifted away before codegen; defensive
    go0 _ _ = 0

compileFn :: Prog -> String -> ([String], Core) -> G [String]
compileFn prog name (params, body) = do
  tgt <- gets cgTgt
  exps <- gets cgExports
  ext <- gets cgExt
  let w = tgtW tgt
  -- arity 0..8 in a0..a7; 9..24 route args 8+ through the per-hart
  -- argspill cells (fpr.h) -- the x64 a6/a7 TLS-cell mechanism promoted
  -- to the portable convention.  The cells are only live between a call
  -- site's stores and this prologue's copies, a window containing no
  -- safepoint, so stealing/preemption can never observe them.
  when (length params > 8 + spillCells) $
    error (name ++ ": arity > " ++ show (8 + spillCells) ++ " unsupported (8 regs + " ++ show spillCells ++ " hart spill cells)")
  let m = mangle name
      -- exact high-water mark (see slotsNeeded); +2 is pure paranoia
      nslots = length params + slotsNeeded ext prog (S.fromList params) body + 2
      frame = ((2 * w + w * nslots + 15) `div` 16) * 16
      env0 = M.fromList (zip params [0 ..])
  bodyLines <- gen prog env0 (length params) Tail body
  -- FUEL: every supercombinator entry decrements the global fuel
  -- counter and traps to the scheduler at zero. Function entry is the
  -- one safepoint every FPRISC loop must pass through (all loops are tail
  -- calls to top-level functions after lifting), so even an
  -- allocation-free busy spin gets descheduled -- which is why the
  -- check lives here and not in fpr_alloc. It runs AFTER the args are
  -- spilled to frame slots: fpr_fuel_exhausted is a real C call and
  -- clobbers a0..a7, but ra/args are already safe in the frame. Cost:
  -- 6 instructions on the fast path, t0/t1 only.
  fuelOk <- freshL "fuel"
  let fuelCheck =
        [ "    mv t0, tp", -- per-hart fuel: 0(tp) is fpr_hart_t.fuel
          "    " ++ tgtLd tgt ++ " t1, 0(t0)",
          "    addi t1, t1, -1",
          "    " ++ tgtSt tgt ++ " t1, 0(t0)",
          "    bgtz t1, " ++ fuelOk,
          "    call fpr_fuel_exhausted",
          fuelOk ++ ":"
        ]
  pure $ wcetAnnotate name $
    [ "# " ++ name ++ " (arity " ++ show (length params) ++ ")" ]
      ++ [ "    .globl fpr_fn_" ++ m | S.member name exps ]
      ++ [ "fpr_fn_" ++ m ++ ":" ]
      ++ framePro tgt frame
      ++ concat [stSlot tgt ("a" ++ show i) i | (i, _) <- zip [0 :: Int ..] params, i < 8]
      -- wide params ride the hart spill cells: copy them into frame
      -- slots BEFORE the fuel check (fpr_fuel_exhausted may deschedule;
      -- by then the cells must be dead)
      ++ (if length params > 8 then "    mv t0, tp" : concat
            [ ("    " ++ tgtLd tgt ++ " t1, " ++ spillRef tgt (i - 8) ++ "(t0)")
                : stSlot tgt "t1" i
            | i <- [8 .. length params - 1] ]
          else [])
      ++ fuelCheck
      ++ bodyLines
      ++ [ "    " ++ tgtLd tgt ++ " ra, " ++ show (-w) ++ "(s0)",
           "    mv t0, s0",
           "    " ++ tgtLd tgt ++ " s0, " ++ show (-2 * w) ++ "(s0)",
           "    mv sp, t0",
           "    ret",
           ""
         ]

-- slot k lives below the saved ra/s0 pair: -(3W + W*k)(s0)
slotRef :: Target -> Int -> String
slotRef t k = show (slotOff t k) ++ "(s0)"

slotOff :: Target -> Int -> Int
slotOff t k = -((3 + k) * tgtW t)

-- slot access that stays legal past the rv64 12-bit displacement:
-- in-range slots keep the one-liner, deeper ones ride t2 (self-
-- contained; t0/t1 stay untouched for the staging sequences around).
-- The x64/a64 translators accept either form.
ldSlot :: Target -> String -> Int -> [String]
ldSlot t r k
  | slotOff t k >= -2048 = ["    " ++ tgtLd t ++ " " ++ r ++ ", " ++ slotRef t k]
  | otherwise =
      [ "    li t2, " ++ show (slotOff t k),
        "    add t2, s0, t2",
        "    " ++ tgtLd t ++ " " ++ r ++ ", 0(t2)" ]

stSlot :: Target -> String -> Int -> [String]
stSlot t r k
  | slotOff t k >= -2048 = ["    " ++ tgtSt t ++ " " ++ r ++ ", " ++ slotRef t k]
  | otherwise =
      [ "    li t2, " ++ show (slotOff t k),
        "    add t2, s0, t2",
        "    " ++ tgtSt t ++ " " ++ r ++ ", 0(t2)" ]

-- sp/fp adjust in 12-bit-legal steps: a big frame is several addi's,
-- which every backend already translates (x64/a64 fold immediates)
frameSteps :: Int -> [Int]
frameSteps n = replicate (n `div` 2032) 2032 ++ [r | r <- [n `mod` 2032], r > 0]

framePro :: Target -> Int -> [String]
framePro tgt frame
  | frame <= 2032 =
      [ "    addi sp, sp, -" ++ show frame,
        "    " ++ tgtSt tgt ++ " ra, " ++ show (frame - w) ++ "(sp)",
        "    " ++ tgtSt tgt ++ " s0, " ++ show (frame - 2 * w) ++ "(sp)",
        "    addi s0, sp, " ++ show frame ]
  | otherwise =
      ["    addi sp, sp, -" ++ show c | c <- frameSteps frame]
        ++ ["    mv t1, s0"] -- the caller's fp, parked while s0 rebuilds
        ++ (case frameSteps frame of
              (c : cs) ->
                ("    addi s0, sp, " ++ show c)
                  : ["    addi s0, s0, " ++ show c' | c' <- cs]
              [] -> [])
        ++ [ "    " ++ tgtSt tgt ++ " ra, " ++ show (-w) ++ "(s0)",
             "    " ++ tgtSt tgt ++ " t1, " ++ show (-2 * w) ++ "(s0)" ]
  where
    w = tgtW tgt

-- hart argument-spill cells (fpr.h fpr_hart_t.argspill): cell j at
-- W*(1+j)(tp) -- fuel is 0(tp), the cells start one word past it
-- (pinned by the _Static_assert in fpr.h)
spillCells :: Int
spillCells = 56 -- must equal fpr.h FPR_ARGSPILL (arity ceiling 8+56=64)

spillRef :: Target -> Int -> String
spillRef t j = show ((1 + j) * tgtW t)

-- Saturated applications of statically known targets compile to direct
-- calls (no fpr_apply, no intermediate PAP allocation). In tail
-- position they compile to frame teardown + `j` -- which generalizes
-- TCO from self-recursion to ANY known saturated tail call, mutual
-- recursion included: the target builds its own frame and returns
-- straight to our caller through the restored ra.
data Pos = Tail | NonTail deriving (Eq)

-- core prims the desugarer can emit, with their arities (the C symbols
-- fpr_prim_fn_* are exported by runtime.c precisely for direct calls)
primArities :: [(String, Int)]
primArities =
  [ ("+", 2), ("-", 2), ("*", 2), ("/", 2),
    ("==", 2), ("!=", 2), ("<", 2), (">", 2), ("<=", 2), (">=", 2),
    ("strcat", 2), ("str", 1), ("error", 1),
    ("print", 1), ("String.len", 1), ("!", 2),
    -- floats: raw-bits payloads; every op is a C prim the type-directed
    -- site resolution routes to (Infer.hs).  f64frombits is the
    -- literal encoding (a tagged V cannot carry 64 raw bits).
    ("f64frombits", 2), ("f32frombits", 1)
  ]
  ++ [ ("F" ++ w ++ "." ++ op, 2)
       | w <- ["64", "32"], op <- ["+", "-", "*", "/", "<", ">", "<=", ">=", "==", "!="] ]
  ++ [ ("F" ++ w ++ "." ++ f, 1)
       | w <- ["64", "32"],
         f <- ["str", "sqrt", "ofInt", "toInt",
               "log", "log2", "exp", "sin", "cos"] ]
  ++ [ ("F" ++ w ++ ".pow", 2) | w <- ["64", "32"] ]
  ++ [("F64.ofF32", 1), ("F32.ofF64", 1)]

-- the full application spine: (head expr, args left-to-right)
spineOf :: Core -> (Core, [Core])
spineOf = go []
  where
    go acc (CApp f a) = go (a : acc) f
    go acc f = (f, acc)

push :: Target -> [String]
push t = ["    addi sp, sp, -16", "    " ++ tgtSt t ++ " a0, 0(sp)"]

popTo :: Target -> String -> [String]
popTo t r = ["    " ++ tgtLd t ++ " " ++ r ++ ", 0(sp)", "    addi sp, sp, 16"]

-- gen: result in a0. env: var -> slot. nxt: next free slot index.
-- pos: is this expression the last thing the supercombinator does?
-- Sibling/nested expressions reuse slots above nxt (dead after their
-- value is produced), so the countLets sum is a safe upper bound.
gen :: Prog -> M.Map String Int -> Int -> Pos -> Core -> G [String]
gen prog env nxt pos e0 = do
  tgt <- gets cgTgt
  ext <- gets cgExt
  spec <- gets cgSpec
  genT tgt spec prog ext env nxt pos e0

genT :: Target -> Bool -> Prog -> M.Map String Int -> M.Map String Int -> Int -> Pos -> Core -> G [String]
genT tgt spec prog ext = go
  where
    w = tgtW tgt
    ld = tgtLd tgt
    st = tgtSt tgt
    -- a saturated application of a known target? (locals shadow: a
    -- variable named like a global is NOT a known target)
    known env h n
      | M.member h env = Nothing
      | Just (ps, _) <- M.lookup h prog, length ps == n, n > 0 = Just ("fpr_fn_" ++ mangle h)
      | Just a <- M.lookup h ext, a == n, n > 0 = Just ("fpr_fn_" ++ mangle h) -- cross-unit direct call
      | Just a <- lookup h primArities, a == n = Just ("fpr_prim_fn_" ++ mangle h)
      | otherwise = Nothing

    go env nxt pos e
      | (CVar h, args@(_ : _)) <- spineOf e,
        Just target <- known env h (length args) =
          knownCall env nxt pos target args
    -- Vec.map/filter/fold with a statically known arithmetic-only element
    -- function: route through a specialized column loop (emitted once per
    -- (op, fn); see emitSpecs).  The spec symbol behaves exactly like a
    -- supercombinator, so knownCall staging + TCO apply unchanged.
    go env nxt pos e
      | spec, Just (plan, callArgs) <- vecSpec prog (`M.member` env) e = do
          sym <- requestSpec plan
          knownCall env nxt pos sym callArgs

    -- CIf and CLet are the only forms whose "last thing done" is a
    -- nested expression rather than themselves: propagate position so a
    -- known call in an if-branch or let-body (the shape every
    -- case-desugared recursive function has) is still a tail call.
    go env nxt pos (CIf c t e) = do
      lc <- go env nxt NonTail c
      lt <- go env nxt pos t
      le <- go env nxt pos e
      lE <- freshL "else"
      lD <- freshL "endif"
      pure $
        lc
          ++ ["    lw t0, 4(a0)", "    beqz t0, " ++ lE]
          ++ lt
          ++ ["    j " ++ lD, lE ++ ":"]
          ++ le
          ++ [lD ++ ":"]
    go env nxt pos (CLet x a b) = do
      la <- go env nxt NonTail a
      lb <- go (M.insert x nxt env) (nxt + 1) pos b
      pure (la ++ stSlot tgt "a0" nxt ++ lb)
    go env nxt _pos core = base env nxt core

    -- Evaluate args left-to-right into consecutive slots (arg i's own
    -- sub-lets stage above slot nxt+i, overwriting earlier args' dead
    -- scratch, never their results), then load a0..an and transfer.
    -- Tail: restore ra/s0/sp exactly as the epilogue would and `j` --
    -- the target returns to OUR caller; O(1) stack for any chain of
    -- known saturated tail calls (self, mutual, whatever).
    knownCall env nxt pos target args = do
      argLines <-
        concat
          <$> sequence
            [ (++ stSlot tgt "a0" (nxt + i)) <$> go env (nxt + i + 1) NonTail a
              | (i, a) <- zip [0 :: Int ..] args
            ]
      -- args 0..7 in registers; 8+ through the hart spill cells.  ALL
      -- args are fully evaluated into slots first (an arg's own
      -- evaluation may contain wide calls that clobber the cells), so
      -- the store phase below contains no calls -- nothing can touch
      -- the cells between here and the callee's prologue copies.  In
      -- Tail position the cell stores happen before teardown (slots
      -- are s0-relative and t0 is clobbered by the teardown itself).
      let loads = concat [ldSlot tgt ("a" ++ show i) (nxt + i) | i <- [0 .. min 7 (length args - 1)]]
          spills =
            if length args > 8
              then "    mv t0, tp" : concat
                     [ ldSlot tgt "t1" (nxt + i)
                         ++ ["    " ++ st ++ " t1, " ++ spillRef tgt (i - 8) ++ "(t0)"]
                     | i <- [8 .. length args - 1] ]
              else []
      pure $
        argLines
          ++ spills
          ++ loads
          ++ case pos of
            NonTail -> ["    call " ++ target]
            Tail ->
              [ "    " ++ ld ++ " ra, " ++ show (-w) ++ "(s0)",
                "    mv t0, s0",
                "    " ++ ld ++ " s0, " ++ show (-2 * w) ++ "(s0)", -- read old s0 before losing it; sp last via the copy
                "    mv sp, t0",
                "    j " ++ target
              ]

    base env nxt = \case
      CVar n
        | Just k <- M.lookup n env -> pure (ldSlot tgt "a0" k)
        | Just (ps, _) <- M.lookup n prog ->
            pure $
              if null ps
                then ["    call fpr_fn_" ++ mangle n] -- 0-ary: evaluate
                else ["    la a0, fpr_obj_" ++ mangle n] -- function value
        | Just a <- M.lookup n ext -> -- another unit's export: same shapes, extern symbols
            pure $
              if a == 0
                then ["    call fpr_fn_" ++ mangle n]
                else ["    la a0, fpr_obj_" ++ mangle n]
        | n `elem` corePrims -> pure ["    la a0, fpr_prim_obj_" ++ mangle n]
        | otherwise -> pure ["    la a0, fpr_g_" ++ mangle n] -- HAL contract
      CInt i
        | intFits tgt i -> pure ["    li a0, " ++ show (2 * i + 1)]
        | otherwise -> error ("int literal " ++ show i ++ " does not fit a tagged " ++ tgtName tgt ++ " word")
      CStr s -> do
        l <- strLabel s
        pure ["    la a0, " ++ l]
      -- generic application: partial, over-saturated, unknown arity
      -- (fpr_g_ HAL fns), or a computed head.  The whole SPINE goes to
      -- ONE fpr_applyN call: saturating an n-ary extern allocates
      -- NOTHING (the curried one-fpr_apply-per-arg emission built an
      -- intermediate PAP per argument -- ~48 B x millions/sec inside
      -- any polling loop that calls a 2-ary HAL prim like charAt).
      CApp f a -> do
        let spine g acc = case g of CApp g' b -> spine g' (b : acc); _ -> (g, acc)
            (hd, args) = spine (CApp f a) []
        lh <- go env nxt NonTail hd
        las <- mapM (go env nxt NonTail) args
        let nA = length args
        pure $
          lh
            ++ push tgt -- head deepest
            ++ concat [la ++ push tgt | la <- las] -- args; LAST arg at 0(sp)
            ++ [ "    mv a2, sp", -- &args (reverse order, 16-byte strided)
                 "    li a1, " ++ show nA,
                 "    " ++ tgtLd tgt ++ " a0, " ++ show (16 * nA) ++ "(sp)", -- the head
                 "    call fpr_applyN",
                 "    addi sp, sp, " ++ show (16 * (nA + 1)) ]
      CTagEq tid var e -> do
        le <- go env nxt NonTail e
        lF <- freshL "tagf"
        lD <- freshL "tagd"
        pure $
          le
            ++ [ "    andi t0, a0, 1", -- tagged int: never matches a data tag
                 "    bnez t0, " ++ lF,
                 "    lw t0, 0(a0)",
                 "    li t1, " ++ show tid,
                 "    bne t0, t1, " ++ lF,
                 "    lw t0, 4(a0)",
                 "    li t1, " ++ show var,
                 "    bne t0, t1, " ++ lF,
                 "    la a0, fpr_true",
                 "    j " ++ lD,
                 lF ++ ":",
                 "    la a0, fpr_false",
                 lD ++ ":"
               ]
      CProj i e -> do
        le <- go env nxt NonTail e
        pure (le ++ ["    " ++ ld ++ " a0, " ++ show (8 + w * i) ++ "(a0)"])
      -- NULLARY constructors (True, False, Nil, Unit, atoms, 0-field
      -- user variants) are immutable and compared STRUCTURALLY (veq:
      -- tid+var), so every construction references one immortal local
      -- static instead of calling fpr_alloc.  Before this, `strEq`
      -- allocated a fresh 8-byte Bool per character compared -- which
      -- a polling loop turned into ~100 MB/s of slab garbage.
      CMk tid var [] ->
        pure ["    la a0, .Lnul_" ++ show tid ++ "_" ++ show var]
      CMk tid var fs -> do
        ls <- mapM (\f -> (++ push tgt) <$> go env nxt NonTail f) fs
        let n = length fs
            pops =
              concat
                [ popTo tgt "t1" ++ ["    " ++ st ++ " t1, " ++ show (8 + w * i) ++ "(a0)"]
                  | i <- reverse [0 .. n - 1]
                ]
        pure $
          concat ls
            ++ [ "    li a0, " ++ show (8 + w * n),
                 "    call fpr_alloc",
                 "    li t0, " ++ show tid,
                 "    sw t0, 0(a0)",
                 "    li t0, " ++ show var,
                 "    sw t0, 4(a0)"
               ]
            ++ pops
      CErr msg -> do
        l <- strLabel msg
        pure ["    la a0, " ++ l, "    call fpr_panic"]
      CIf {} -> error "internal: CIf reached base"
      CLet {} -> error "internal: CLet reached base"
      CLam _ _ -> error "internal: CLam survived lambda lifting"

--------------------------------------------------------------------------------
-- Vec specialization: the AOT twin of the Sol PoC's tracing JIT.
--
-- A call site  Vec.map f v / Vec.filter p v / Vec.fold f z v  where the
-- element function is a statically known top-level supercombinator with
-- an ARITHMETIC-ONLY closed call graph (ints, arith/cmp prims, if/case-
-- on-Bool, let, saturated known calls -- recursion allowed) compiles to
-- a per-(op,fn) specialized loop that strides the vector's raw unboxed
-- column blocks directly, calling an UNBOXED clone of f (raw machine
-- ints in registers, native add/mul/slt, no tagging, no fpr_apply).
-- Layout is only known at runtime, so every specialized loop opens with
-- a guard: wrong rep (boxed, or non-Int z) tail-jumps into the generic
-- C tier in vec.c -- same observable semantics, just slower.  Linearity
-- of Vector is what licenses map/filter running IN PLACE here.
--
-- Vec.fold over an SoA vector additionally DUALIZES the element
-- function: field projections of the tuple parameter become per-column
-- register loads (the tuple is never materialized), the loop walking
-- one cursor per used column.
--
-- With --rvv, two shapes drop to actual RISC-V vector instructions:
-- map with a straight-line +/-/* body becomes a strip-mined vsetvli
-- loop (vle -> vadd/vmul.vv/.vx -> vse), and fold(\a b -> a+b) becomes
-- vector accumulation + one vredsum.  Fuel is decremented once per
-- BLOCK in specialized loops (the unboxed fn keeps its own per-entry
-- check, preserving the safepoint contract even for collatz-style
-- recursion).
--------------------------------------------------------------------------------

-- layout mirrors vec_t/col_t in runtime/vec.c
vRep, vLen :: Int
vRep = 4 -- u32
vLen = 8

vNcols, vKinds, vFkinds, vCols0 :: Target -> Int
vNcols t = 8 + 3 * tgtW t
vKinds t = 8 + 4 * tgtW t
vFkinds t = 8 + 5 * tgtW t -- bit i: column i holds raw IEEE float bits
vCols0 t = 8 + 6 * tgtW t

colBlk0 :: Target -> Int
colBlk0 = tgtW -- col_t: cap at 0, base (the one contiguous span) at W

logW :: Target -> Int
logW t = if tgtW t == 8 then 3 else 2

-- detect a specializable call site; isLocal reports lexical shadowing
-- ---- stream fusion v1: adjacent Vec.map passes collapse into one ------
--
-- `Vec.map f (Vec.map g v)` -- and the let-bound pipeline spelling
-- `v2 = Vec.map g v; v3 = Vec.map f v2;` when v2's ONLY use is the
-- immediately following map -- rewrites to `Vec.map (f . g) v` with the
-- composite synthesized as a real supercombinator.  Soundness is the
-- linear in-place map itself: both passes mutate the same columns and
-- return the same reference, so the fused single pass leaves byte-
-- identical final state and the g-only intermediate was unobservable
-- (single ownership: nobody else ever held it).  The composite then
-- flows through ALL the existing machinery unchanged -- arithClosure
-- and soaDualMap open the f/g calls via their own inlining -- so
-- scalar, record-SoA, and float column loops all fuse, and even the
-- generic apply tier wins a whole traversal.
--
-- Deliberate v1 bounds, stated: at most ONE side carries a capture
-- (the composite keeps the one-capture mvmap shape; both-captured
-- skips); a chain of 3+ maps fuses its OUTER pair per compile (the
-- composite is not re-examined -- full collapse is a fixpoint
-- follow-up); Vec.fold-of-map does NOT fuse, because fold returns the
-- vector it was given and the map's writes are program-visible after
-- it -- that one needs a write-back fold variant, not a rewrite.
-- Vec.x sites that LOOK like specialization candidates (named global
-- element fn) but no plan accepts -- reported per enclosing function
declines :: Bool -> Prog -> String -> Core -> [String]
declines spec prog owner = goD S.empty
  where
    goD bound e =
      here ++ case e of
        CApp a b -> goD bound a ++ goD bound b
        CLet x a b -> goD bound a ++ goD (S.insert x bound) b
        CIf c t f -> concatMap (goD bound) [c, t, f]
        CMk _ _ fs -> concatMap (goD bound) fs
        CTagEq _ _ x -> goD bound x
        CProj _ x -> goD bound x
        CLam ps b -> goD (foldr S.insert bound ps) b
        _ -> []
      where
        here = case spineOf e of
          (CVar op, args)
            | Just n <- lookup op [("Vec.map", 2), ("Vec.filter", 2), ("Vec.fold", 3)],
              length args == n, -- FULL spines only: a partial spine is
              -- just the inside of the real call, not a site
              fe : _ <- args,
              Just f <- named fe,
              M.member f prog,
              not (S.member f bound) ->
                case vecSpec prog (`S.member` bound) e of
                  Nothing ->
                    [ "vec note: " ++ op ++ " over `" ++ f ++ "` (in " ++ owner
                        ++ ") runs in the GENERIC apply tier -- the element fn is"
                        ++ " not a closed arithmetic/record dual, so no column loop"
                        ++ " specializes this site"
                    ]
                  Just _
                    | not spec ->
                        [ "vec note: " ++ op ++ " over `" ++ f ++ "` (in " ++ owner
                            ++ ") runs in the GENERIC apply tier -- a column loop"
                            ++ " accepts this site, but the specialization tier is"
                            ++ " OFF on this target (x64: SysV has no s6+ callee-saved"
                            ++ " registers); rv64/a64 builds specialize it"
                        ]
                    | otherwise -> []
          _ -> []
        named (CVar f) = Just f
        named (CApp (CVar f) _) = Just f
        named _ = Nothing

-- run fusion to a FIXPOINT: a 3+ chain's outer pair fuses in round 1,
-- the composite-over-inner pair in round 2, and so on until no pair is
-- left.  Each round's composites get a round-tagged name so rounds
-- never collide; the plan-level machinery already composes through
-- composites (soaDualMap0 recognizes the f(g el) body shape
-- recursively), so a fully collapsed chain still dualizes.  The bound
-- is a backstop, not a budget: a chain of length n needs n-1 rounds
-- and real programs stop far short of it.
fuseVecFix :: Prog -> Prog
fuseVecFix = go (0 :: Int)
  where
    go r p
      | r >= 16 = p
      | otherwise =
          let p' = fuseVec r p
           in if M.size p' == M.size p then p' else go (r + 1) p'

fuseVec :: Int -> Prog -> Prog
fuseVec round' prog0 = M.union extras (M.map (\(ps, b) -> (ps, rewrite b)) prog0)
  where
    arity f = length . fst <$> M.lookup f prog0

    -- a Vec.map spine's element-fn form: plain 1-ary global, or a
    -- 2-ary global with exactly one capture applied
    data' e = case spineOf e of
      (CVar "Vec.map", [fe, v]) -> case fe of
        CVar f | arity f == Just 1 -> Just ((f, Nothing), v)
        CApp (CVar f) capE | arity f == Just 2 -> Just ((f, Just capE), v)
        _ -> Nothing
      _ -> Nothing

    -- fusable outer/inner pair at this node (after seeing through the
    -- adjacent single-use let): key + the surviving capture + source vec
    fusedAt e = do
      ((f, capF), ve) <- data' e
      ((g, capG), v) <- data' ve
      (side, cap) <- case (capF, capG) of
        (Nothing, Nothing) -> Just (0 :: Int, Nothing)
        (Just c, Nothing) -> Just (1, Just c)
        (Nothing, Just c) -> Just (2, Just c)
        _ -> Nothing -- both captured: composite would need two captures
      pure ((f, g, side), cap, v)

    pairs = S.toList (S.unions [walk b | (_, (_, b)) <- M.toList prog0])
      where
        -- walk the SAME tree rewrite walks: seeLet first, THEN recurse
        -- into the transformed node.  Recursing into the original
        -- children instead missed pairs that only exist after the
        -- let-pipeline substitution (a pipeline whose fn pair appears
        -- nowhere as a nested spine), and rewrite then hit synth with
        -- an unregistered key.
        walk e0 =
          let e = seeLet e0
              here = maybe S.empty (\(k, _, _) -> S.singleton k) (fusedAt e)
           in here `S.union` kids e
        kids e = case e of
          CApp a b -> walk a `S.union` walk b
          CLet _ a b -> walk a `S.union` walk b
          CIf c t f -> S.unions [walk c, walk t, walk f]
          CMk _ _ fs -> S.unions (map walk fs)
          CTagEq _ _ x -> walk x
          CProj _ x -> walk x
          CLam _ b -> walk b
          _ -> S.empty

    synth = M.fromList [(k, "_vfuse_" ++ show round' ++ "_" ++ show (i :: Int)) | (i, k) <- zip [0 ..] pairs]
    extras =
      M.fromList
        [ (nm, comp k) | (k, nm) <- M.toList synth ]
      where
        comp (f, g, 0) = (["$fe"], CApp (CVar f) (CApp (CVar g) (CVar "$fe")))
        comp (f, g, 1) = (["$fc", "$fe"], CApp (CApp (CVar f) (CVar "$fc")) (CApp (CVar g) (CVar "$fe")))
        comp (f, g, _) = (["$fc", "$fe"], CApp (CVar f) (CApp (CApp (CVar g) (CVar "$fc")) (CVar "$fe")))

    rewrite e0 =
      let e = seeLet e0
       in case fusedAt e of
            Just (k, cap, v) ->
              let fe = maybe (CVar (synth M.! k)) (CApp (CVar (synth M.! k)) . rewrite) cap
               in CApp (CApp (CVar "Vec.map") fe) (rewrite v)
            Nothing -> case e of
              CApp a b -> CApp (rewrite a) (rewrite b)
              CLet x a b -> CLet x (rewrite a) (rewrite b)
              CIf c t f -> CIf (rewrite c) (rewrite t) (rewrite f)
              CMk t v fs -> CMk t v (map rewrite fs)
              CTagEq t v x -> CTagEq t v (rewrite x)
              CProj k x -> CProj k (rewrite x)
              CLam ps b -> CLam ps (rewrite b)
              other -> other

    -- the pipeline spelling: substitute a let-bound map into the
    -- IMMEDIATELY following map's vector position when that is the
    -- name's only use -- nothing runs between the two passes, so
    -- effect order (fuel, panics, allocation) is preserved exactly
    seeLet (CLet x ve b)
      | Just _ <- data' ve = case b of
          _ | isNextUse b -> seeLet (subst b)
          CLet y inner rest
            | isNextUse inner, occurs x rest == 0 -> seeLet (CLet y (subst inner) rest)
          _ -> CLet x ve b
      where
        isNextUse m = case data' m of
          Just ((_, mcap), CVar v') ->
            v' == x && maybe 0 (occurs x) mcap == 0
          _ -> False
        subst m = case spineOf m of
          (CVar "Vec.map", [fe, CVar _]) -> CApp (CApp (CVar "Vec.map") fe) ve
          _ -> m
    seeLet e = e

    occurs x = go
      where
        go (CVar n) = if n == x then 1 else 0 :: Int
        go (CApp a b) = go a + go b
        go (CLet y a b) = go a + (if y == x then 0 else go b)
        go (CIf c t f) = go c + go t + go f
        go (CMk _ _ fs) = sum (map go fs)
        go (CTagEq _ _ e') = go e'
        go (CProj _ e') = go e'
        go (CLam ps b) = if x `elem` ps then 0 else go b
        go _ = 0

vecSpec :: Prog -> (String -> Bool) -> Core -> Maybe (SpecPlan, [Core])
vecSpec prog isLocal e = case spineOf e of
  (CVar "Vec.map", [fe, v])
    | (CVar f, [capE]) <- spineOf fe,
      okOp "Vec.map",
      okFn f 2,
      Just mp <- soaDualMap prog f -> do
        cl <- arithClosure prog [fn | (_, (_, b)) <- mvFields mp, fn <- S.toList (calleesOf prog b)]
        Just (SpecPlan "mvmap" f False cl Nothing Nothing (Just mp) Nothing, [capE, v])
  (CVar "Vec.map", [CVar f, v])
    | okOp "Vec.map",
      okFn f 1,
      Just mp <- soaDualMap0 prog f -> do
        cl <- arithClosure prog [fn | (_, (_, b)) <- mvFields mp, fn <- S.toList (calleesOf prog b)]
        -- capture-free record->record map: same in-place column loop,
        -- with a dead capture slot (a0 = tagged 0, never dereferenced:
        -- ms is empty for every field, so nothing loads off s8)
        Just (SpecPlan "mvmap" f False cl Nothing Nothing (Just mp) Nothing, [CInt 0, v])
  (CVar "Vec.map", [CVar f, v]) | okOp "Vec.map", okFn f 1 -> plan "map" f [v]
  (CVar "Vec.filter", [CVar f, v]) | okOp "Vec.filter", okFn f 1 -> plan "filter" f [v]
  -- WRITE-BACK FOLD: Vec.fold f z (Vec.map g v) fuses into ONE pass
  -- that stores g(el) back into the column AND folds f over it -- the
  -- map's writes stay program-visible through the returned vector, so
  -- this is the fusion the map/map rewrite could never express (VEC.md
  -- open item 1).  Scalar int tier only in v1; anything else falls
  -- through to the plain fold plan below, whose map argument then
  -- specializes on its own.
  (CVar "Vec.fold", [CVar f, z, me])
    | (CVar "Vec.map", [CVar g, v]) <- spineOf me,
      okOp "Vec.fold",
      not (isLocal "Vec.map"),
      okFn f 2,
      okFn g 1,
      Just clf <- arithClosure prog [f],
      Just clg <- arithClosure prog [g],
      floatWidthOf prog clf == Nothing,
      floatWidthOf prog clg == Nothing ->
        Just (SpecPlan ("wfold@" ++ g) f True (clf `S.union` clg) Nothing Nothing Nothing Nothing, [z, v])
  (CVar "Vec.fold", [CVar f, z, v]) | okOp "Vec.fold", okFn f 2 -> plan "fold" f [z, v]
  _ -> Nothing
  where
    okOp h = not (isLocal h) && M.notMember h prog
    okFn f n = not (isLocal f) && maybe False ((== n) . length . fst) (M.lookup f prog)
    plan op f args = (,args) <$> planSpec prog op f

calleesOf :: Prog -> Core -> S.Set String
calleesOf prog = go
  where
    go e = case spineOf e of
      (CVar h, args@(_ : _)) | M.member h prog -> S.insert h (S.unions (map go args))
      _ -> case e of
        CApp a b -> go a `S.union` go b
        CLet _ a b -> go a `S.union` go b
        CIf c t f' -> S.unions [go c, go t, go f']
        CMk _ _ fs -> S.unions (map go fs)
        CTagEq _ _ x -> go x
        CProj _ x -> go x
        _ -> S.empty

planSpec :: Prog -> String -> String -> Maybe SpecPlan
planSpec prog "fold" f =
  let scal = arithClosure prog [f]
      fw = floatWidthOf prog (maybe S.empty id scal)
      soa = soaDual prog f
      rvv = if isSumFn prog f then Just RvvFoldSum else Nothing
   in if scal == Nothing && soa == Nothing
        then Nothing
        else
          Just
            SpecPlan
              { spOp = "fold",
                spFn = f,
                spScalar = scal /= Nothing,
                spClosure = S.unions [maybe S.empty id scal, maybe S.empty (\(_, _, _, _, cl) -> cl) soa],
                spSoa = (\(ks, ps, b, tv, _) -> (ks, ps, b, tv)) <$> soa,
                spRvv = if fw == Nothing then rvv else Nothing,
                spMv = Nothing,
                spFloat = fw
              }
planSpec prog op f = do
  cl <- arithClosure prog [f]
  let rvv = case M.lookup f prog of
        Just ([p], body) | op == "map", Just b <- straightLine [p] body -> Just (RvvMap p b)
        _ -> Nothing
  let fw = floatWidthOf prog cl
   in -- RVV lanes are integer vadd/vmul in this pass, so a float
      -- closure takes the scalar float loop, not the vector one
      Just (SpecPlan op f True cl Nothing (if fw == Nothing then rvv else Nothing) Nothing fw)

-- the closed arithmetic call graph rooted at the given functions;
-- Nothing if anything outside the unboxable fragment is reachable
arithClosure :: Prog -> [String] -> Maybe (S.Set String)
arithClosure prog = go S.empty
  where
    go acc [] = Just acc
    go acc (n : rest)
      | S.member n acc = go acc rest
      | otherwise = do
          (ps, body) <- M.lookup n prog
          calls <- bodyOK prog (S.fromList ps) body
          go (S.insert n acc) (S.toList calls ++ rest)

-- checks one body against the unboxable fragment; returns callees
bodyOK :: Prog -> S.Set String -> Core -> Maybe (S.Set String)
bodyOK prog = ok
  where
    ok env e
      | Just _ <- floatLitBits e = Just S.empty -- a folded float literal
    ok env e = case spineOf e of
      (CVar h, args@(_ : _))
        | h `elem` uPrims || h `elem` fPrims,
          Just 2 <- lookup h primArities,
          length args == 2 ->
            S.unions <$> mapM (ok env) args
        | Just (ps, _) <- M.lookup h prog,
          not (S.member h env),
          length ps == length args ->
            S.insert h . S.unions <$> mapM (ok env) args
      _ -> case e of
        CVar n | S.member n env -> Just S.empty
        CInt _ -> Just S.empty
        CMk 1 _ [] -> Just S.empty -- True/False literals
        CTagEq 1 _ x -> ok env x -- Bool tag test on a raw 0/1
        CIf c t f -> S.unions <$> sequence [ok env c, ok env t, ok env f]
        CLet x a b -> S.union <$> ok env a <*> ok (S.insert x env) b
        CErr _ -> Just S.empty -- dead case arms
        _ -> Nothing

uPrims :: [String]
uPrims = ["+", "-", "*", "/", "==", "!=", "<", ">", "<=", ">="]

-- the same op set at each float width.  An unboxed clone over a FLOAT
-- column gets raw IEEE bits in its integer registers exactly as an Int
-- clone gets raw ints -- identical calling convention, different
-- instructions -- so the whole specialized-loop machinery carries over
-- with only the arithmetic and the rep guard changed.
fPrimsOf :: String -> [String]
fPrimsOf w = [ "F" ++ w ++ "." ++ o | o <- uPrims ]

fPrims :: [String]
fPrims = fPrimsOf "64" ++ fPrimsOf "32"

-- the runtime rep a specialized loop demands: VR_INT (1) normally,
-- VR_FLT (4) when the closure computes in floats (vec.c's enum)
repOf :: SpecPlan -> Int
repOf p = if spFloat p == Nothing then 1 else 4

-- "F64.+" -> ("64", "+")
fSplit :: String -> Maybe (String, String)
fSplit p = case splitAt 4 p of
  ("F64.", o) | o `elem` uPrims -> Just ("64", o)
  ("F32.", o) | o `elem` uPrims -> Just ("32", o)
  _ -> Nothing

-- does this closure compute in floats (and at which width)?  Decided
-- from the bodies, which is also what picks the loop's rep guard.
floatWidthOf :: Prog -> S.Set String -> Maybe String
floatWidthOf prog names =
  case [w | w <- ["64", "32"], any (usesW w) (S.toList names)] of
    (w : _) -> Just w
    [] -> Nothing
  where
    usesW w n = maybe False (goB w . snd) (M.lookup n prog)
    goB w e = case spineOf e of
      (CVar h, args) | h `elem` fPrimsOf w -> True
                     | otherwise -> any (goB w) args
      _ -> case e of
        CIf c t f -> goB w c || goB w t || goB w f
        CLet _ a b -> goB w a || goB w b
        _ -> False

-- a float LITERAL inside an unboxable body: the desugarer emits
-- f64frombits hi lo (or f32frombits bits) with constant arguments, so
-- it folds to one `li` of the bit pattern.  Without this, any body
-- mentioning 2.0 would fail admission and lose its specialized loop.
floatLitBits :: Core -> Maybe Integer
floatLitBits e = case spineOf e of
  (CVar "f64frombits", [CInt hi, CInt lo]) -> Just ((hi * 4294967296) + (lo `mod` 4294967296))
  (CVar "f32frombits", [CInt b]) -> Just b
  _ -> Nothing

-- inline trivial re-lets (the desugarer's  let a = a1_0 in ...)
peel :: Core -> Core
peel (CLet x (CVar y) b) = peel (subst x y b)
peel e = e

subst :: String -> String -> Core -> Core
subst x y = go
  where
    go (CVar n) = CVar (if n == x then y else n)
    go (CApp a b) = CApp (go a) (go b)
    go (CLet n a b) = CLet n (go a) (if n == x then b else go b)
    go (CIf c t f) = CIf (go c) (go t) (go f)
    go (CMk t v fs) = CMk t v (map go fs)
    go (CTagEq t v e) = CTagEq t v (go e)
    go (CProj k e) = CProj k (go e)
    go e = e

-- is f literally \a b -> a + b (mod trivial lets / arg order)?
isSumFn :: Prog -> String -> Bool
isSumFn prog f = case M.lookup f prog of
  Just ([a, b], body) -> case spineOf (peel body) of
    (CVar "+", [CVar x, CVar y]) -> (x == a && y == b) || (x == b && y == a)
    _ -> False
  _ -> False

-- straight-line +/-/* expression over the param: RVV-mappable
straightLine :: [String] -> Core -> Maybe Core
straightLine ps body0 = body0 <$ chk (S.fromList ps) (peel body0)
  where
    chk env e = case spineOf e of
      (CVar h, [a, b]) | h `elem` ["+", "-", "*"] -> chk env a >> chk env b
      _ -> case e of
        CVar n | S.member n env -> Just ()
        CInt _ -> Just ()
        CLet x a b -> chk env a >> chk (S.insert x env) b
        _ -> Nothing

-- fold-over-SoA dualization: rewrite  CProj k (CVar el)  to a fresh
-- column variable; the loop feeds those from per-column cursors and the
-- tuple is never built.  Returns (used columns, ufn params, body, extra
-- arithmetic closure needed by calls inside the body).
soaDual :: Prog -> String -> Maybe ([Int], [String], Core, (Int, Int), S.Set String)
soaDual prog f = do
  ([acc, el], body0) <- M.lookup f prog
  -- the desugarer re-lets params and the case scrutinee; peelDeep
  -- exposes projections as CProj k (CVar el) and the shape test as
  -- CTagEq tid var (CVar el)
  (body', (ks, tvs)) <- runDual el (peelDeep body0)
  tv <- case S.toList (S.fromList tvs) of
    [one] -> Just one -- exactly one shape test: the required eltid/elvar
    -- NO shape test but real column reads: projField bound each field
    -- against a UNIQUE candidate shape and emitted a bare CProj, no
    -- CTagEq -- the generic body is exactly as unchecked, so the dual
    -- may run guarded only by ncols/kinds ((-1,-1) = skip the
    -- eltid/elvar compare).  This is what un-declines NAMED record
    -- folds: their row-polymorphic bodies never carry a dispatch chain.
    [] | not (null ks) -> Just (-1, -1)
    _ -> Nothing -- conflicting shape tests: bail
  if null ks || any (>= 8) ks || acc == el
    then Nothing
    else do
      let cols = S.toAscList (S.fromList ks)
          cvars = ["$c" ++ show k | k <- cols]
      calls <- bodyOK prog (S.fromList (acc : cvars)) body'
      cl <- arithClosure prog (S.toList calls)
      Just (cols, acc : cvars, body', tv, cl)
  where
    -- peel trivial alias-lets at every depth (not just the spine)
    peelDeep e = case peel e of
      CApp a b -> CApp (peelDeep a) (peelDeep b)
      CLet x a b -> CLet x (peelDeep a) (peelDeep b)
      CIf c t f' -> CIf (peelDeep c) (peelDeep t) (peelDeep f')
      CMk t v fs -> CMk t v (map peelDeep fs)
      CTagEq t v x -> CTagEq t v (peelDeep x)
      CProj k x -> CProj k (peelDeep x)
      e' -> e'
    runDual el = go
      where
        go (CProj k (CVar v)) | v == el = Just (CVar ("$c" ++ show k), ([k], []))
        -- a shape test on the element: statically true under the spec
        -- guard (which checks the vector's eltid/elvar), so it rewrites
        -- to True -- and RECORDS the tid/var the guard must check
        go (CTagEq t v (CVar x)) | x == el = Just (CMk 1 1 [], ([], [(t, v)]))
        go (CVar n) | n == el = Nothing -- el escapes: cannot dualize
        go e@(CVar _) = Just (e, mempty)
        go e@(CInt _) = Just (e, mempty)
        go e@(CStr _) = Just (e, mempty)
        go (CApp a b) = app2 CApp a b
        go (CLet x a b) | x /= el = app2 (CLet x) a b
        go (CIf c t f') = do (c', k1) <- go c; (t', k2) <- go t; (f'', k3) <- go f'; Just (CIf c' t' f'', k1 <> k2 <> k3)
        go (CTagEq t v e) = do (e', ks') <- go e; Just (CTagEq t v e', ks')
        go e@(CErr _) = Just (e, mempty)
        go (CMk t v fs) = do rs <- mapM go fs; Just (CMk t v (map fst rs), mconcat (map snd rs))
        go _ = Nothing
        app2 c a b = do (a', k1) <- go a; (b', k2) <- go b; Just (c a' b', k1 <> k2)

-- map-over-SoA with one captured record: dualize
--   f cap el = <inline everything> = Mk etid evar [e0..e_{n-1}]
-- into one unboxed fn PER OUTPUT FIELD whose params are the used
-- captured-record fields ($m<j>) then the used element columns
-- ($c<k>).  The loop runs IN PLACE: same shape in and out, results
-- buffered per element before the stores.
-- capture-free variant: a 1-ary record->record map runs through the
-- SAME dual with a phantom capture name nothing can reference (the
-- desugarer never emits "$"-prefixed user names), so ms comes back
-- empty for every field and the emitter's capture loads vanish.
soaDualMap0 :: Prog -> String -> Maybe MvPlan
soaDualMap0 prog h = do
  ([el], body0) <- M.lookup h prog
  case body0 of
    -- a fuseVec composite: h el = f (g el).  Compose the two duals
    -- directly -- g's output field k IS f's input column k (records
    -- construct and project in the same sorted-field order), so f's
    -- $c_k references substitute with g's field-k dual bodies.  No
    -- normalization of the inlined mess, no emitter change.
    CApp (CVar f) (CApp (CVar g) (CVar e')) | e' == el ->
      composePlans <$> soaDualMap0 prog g <*> soaDualMap0 prog f
    _ -> soaDualMapOn prog h "$nocap" el body0

soaDualMap :: Prog -> String -> Maybe MvPlan
soaDualMap prog h = do
  ([cap, el], body0) <- M.lookup h prog
  case body0 of
    -- captured composites (one side only, by fuseVec construction):
    -- outer-captured  h c el = f c (g el)
    CApp (CApp (CVar f) (CVar c')) (CApp (CVar g) (CVar e'))
      | c' == cap, e' == el ->
          composePlans <$> soaDualMap0 prog g <*> soaDualMap prog f
    -- inner-captured  h c el = f (g c el)
    CApp (CVar f) (CApp (CApp (CVar g) (CVar c')) (CVar e'))
      | c' == cap, e' == el ->
          composePlans <$> soaDualMap prog g <*> soaDualMap0 prog f
    _ -> soaDualMapOn prog h cap el body0

-- compose per-field duals: for each of f's output fields, replace its
-- element-column reads ($c_k) with g's field-k body.  Placeholder
-- rename first so g's own $c/$m names never collide with the ones
-- being replaced.  Exactly one side carries $m captures (fuseVec
-- skips both-captured), so the merged capture set is that side's.
composePlans :: MvPlan -> MvPlan -> MvPlan
composePlans gp fp =
  MvPlan (mvTid gp) (length fields') fields'
  where
    gduals = mvFields gp
    fields' =
      [ composed | ((fms, fks), (_, fbody)) <- mvFields fp,
        let renamed = foldr (\k b -> substE ("$c" ++ show k) (CVar ("$X" ++ show k)) b) fbody fks
            plugged = foldr plug renamed fks
            plug k b
              | k < length gduals, ((_, _), (_, gb)) <- gduals !! k =
                  substE ("$X" ++ show k) gb b
              | otherwise = substE ("$X" ++ show k) (CVar ("$c" ++ show k)) b
            ms' = S.toAscList (S.fromList (fms ++ concat [gms | k <- fks, k < length gduals, let ((gms, _), _) = gduals !! k]))
            ks' = S.toAscList (S.fromList (concat [gks | k <- fks, k < length gduals, let ((_, gks), _) = gduals !! k]))
            ps' = ["$m" ++ show j | j <- ms'] ++ ["$c" ++ show k | k <- ks']
            composed = ((ms', ks'), (ps', plugged))
      ]

soaDualMapOn :: Prog -> String -> String -> String -> Core -> Maybe MvPlan
soaDualMapOn prog f cap el body0 = do
  let body1 = inlineSat (8 :: Int) (peelDeepC body0)
  (tv, fs) <- strip cap el Nothing body1
  let n = length fs
  if n == 0 || n > 4 then Nothing else Just ()
  duals <- mapM (dualField cap el) fs
  Just (MvPlan tv n duals)
  where
    inlineSat 0 e = e
    inlineSat d e = case spineOf e of
      (CVar h, args@(_ : _))
        | h /= f,
          Just (ps, hb) <- M.lookup h prog,
          length ps == length args ->
            inlineSat (d - 1) (foldr (\(p, a) acc -> substE p a acc) hb (zip ps args))
      _ -> case e of
        CApp a b -> CApp (inlineSat d a) (inlineSat d b)
        CLet x a b -> CLet x (inlineSat d a) (inlineSat d b)
        CIf c t e' -> CIf (inlineSat d c) (inlineSat d t) (inlineSat d e')
        CMk t v xs -> CMk t v (map (inlineSat d) xs)
        CTagEq t v x -> CTagEq t v (inlineSat d x)
        CProj k x -> CProj k (inlineSat d x)
        other -> other
    -- walk down to the record construction, consuming shape tests
    strip cap el tv e = case e of
      CIf (CTagEq t v (CVar x)) th _
        | x == el -> strip cap el (tv `orKeep` Just (t, v)) th
        | x == cap -> strip cap el tv th -- statically true: typed Mat4
      CLet x a b -> strip cap el tv (substE x a b)
      CMk t v fs' -> do
        (et, ev) <- tv `orKeep` Just (t, v) -- untested el: require Mk matches nothing... use Mk's own only if tested
        if (et, ev) == (t, v) then Just ((et, ev), fs') else Nothing
      _ -> Nothing
    orKeep (Just x) _ = Just x
    orKeep Nothing y = y
    dualField cap el e0 = do
      (e1, (ms, ks)) <- go e0
      let ms' = S.toAscList (S.fromList ms)
          ks' = S.toAscList (S.fromList ks)
          ps = ["$m" ++ show j | j <- ms'] ++ ["$c" ++ show k | k <- ks']
      if length ps > 8 then Nothing else Just ()
      _ <- bodyOK prog (S.fromList ps) e1
      Just ((ms', ks'), (ps, e1))
      where
        go e = case e of
          CProj k (CVar v)
            | v == el -> Just (CVar ("$c" ++ show k), ([], [k]))
            | v == cap -> Just (CVar ("$m" ++ show k), ([k], []))
          CVar v | v == el || v == cap -> Nothing -- escapes
          CTagEq t v (CVar x) | x == el || x == cap -> Just (CMk 1 1 [], ([], []))
          CApp a b -> ap2 CApp a b
          CLet x a b | x /= el, x /= cap -> ap2 (CLet x) a b
          CIf c t e' -> do (c', k1) <- go c; (t', k2) <- go t; (e'', k3) <- go e'; Just (CIf c' t' e'', k1 <> k2 <> k3)
          CTagEq t v x -> do (x', ks') <- go x; Just (CTagEq t v x', ks')
          CMk {} -> Nothing -- nested construction inside a field: bail
          e'@(CVar _) -> Just (e', mempty)
          e'@(CInt _) -> Just (e', mempty)
          e'@(CStr _) -> Just (e', mempty)
          e'@(CErr _) -> Just (e', mempty)
          _ -> Nothing
        ap2 c a b = do (a', k1) <- go a; (b', k2) <- go b; Just (c a' b', k1 <> k2)

-- capture-naive expression substitution: sound here because the
-- desugarer's names are globally fresh
substE :: String -> Core -> Core -> Core
substE x v = go
  where
    go (CVar n) = if n == x then v else CVar n
    go (CApp a b) = CApp (go a) (go b)
    go (CLet n a b) = CLet n (go a) (if n == x then b else go b)
    go (CIf c t f') = CIf (go c) (go t) (go f')
    go (CMk t v' fs) = CMk t v' (map go fs)
    go (CTagEq t v' e) = CTagEq t v' (go e)
    go (CProj k e) = CProj k (go e)
    go e = e

peelDeepC :: Core -> Core
peelDeepC e = case peel e of
  CApp a b -> CApp (peelDeepC a) (peelDeepC b)
  CLet x a b -> CLet x (peelDeepC a) (peelDeepC b)
  CIf c t f' -> CIf (peelDeepC c) (peelDeepC t) (peelDeepC f')
  CMk t v fs -> CMk t v (map peelDeepC fs)
  CTagEq t v x -> CTagEq t v (peelDeepC x)
  CProj k x -> CProj k (peelDeepC x)
  e' -> e'

requestSpec :: SpecPlan -> G String
requestSpec p = do
  let sym = case wfoldG p of
        Just g -> "fpr_vspec_wfold_" ++ mangle (spFn p) ++ "_" ++ mangle g
        Nothing -> "fpr_vspec_" ++ spOp p ++ "_" ++ mangle (spFn p)
  modify (\s -> s {cgSpecs = M.insert (spOp p, spFn p) (sym, p) (cgSpecs s)})
  pure sym

-- a write-back fold plan carries its map fn inside the op key (the
-- cgSpecs key stays (op, foldFn), unique per (f, g) pair)
wfoldG :: SpecPlan -> Maybe String
wfoldG p = case splitAt 6 (spOp p) of
  ("wfold@", g) -> Just g
  _ -> Nothing

--------------------------------------------------------------------------------
-- genU: the unboxed twin of gen.  Same frame/slot discipline, same TCO,
-- same fuel safepoint -- but every value is a RAW machine integer, so
-- arithmetic is one instruction and comparisons produce raw 0/1 (which
-- CIf and CTagEq-on-Bool consume directly).  Only bodies blessed by
-- bodyOK ever get here.
--------------------------------------------------------------------------------

compileUFn :: Target -> Prog -> S.Set String -> String -> ([String], Core) -> G [String]
compileUFn tgt prog uset label (params, body) = do
  ext <- gets cgExt
  let w = tgtW tgt
      nslots = length params + slotsNeeded ext prog (S.fromList params) body + 2
      frame = ((2 * w + w * nslots + 15) `div` 16) * 16
      env0 = M.fromList (zip params [0 ..])
  bodyLines <- genU tgt prog uset env0 (length params) Tail body
  fuelOk <- freshL "ufuel"
  pure $
    [ "# unboxed clone (raw ints, native arithmetic)",
      "    .globl " ++ label,
      label ++ ":" ]
      ++ framePro tgt frame
      ++ concat [stSlot tgt ("a" ++ show i) i | (i, _) <- zip [0 :: Int ..] params]
      ++ [ "    mv t0, tp", -- per-hart fuel: 0(tp) is fpr_hart_t.fuel
           "    " ++ tgtLd tgt ++ " t1, 0(t0)",
           "    addi t1, t1, -1",
           "    " ++ tgtSt tgt ++ " t1, 0(t0)",
           "    bgtz t1, " ++ fuelOk,
           "    call fpr_fuel_exhausted",
           fuelOk ++ ":"
         ]
      ++ bodyLines
      ++ [ "    " ++ tgtLd tgt ++ " ra, " ++ show (-w) ++ "(s0)",
           "    mv t0, s0",
           "    " ++ tgtLd tgt ++ " s0, " ++ show (-2 * w) ++ "(s0)",
           "    mv sp, t0",
           "    ret",
           ""
         ]

genU :: Target -> Prog -> S.Set String -> M.Map String Int -> Int -> Pos -> Core -> G [String]
genU tgt prog uset = go
  where
    ld = tgtLd tgt
    st = tgtSt tgt
    w = tgtW tgt
    go _ _ _ e
      | Just bits <- floatLitBits e = pure ["    li a0, " ++ show bits]
    go env nxt pos e
      | (CVar h, [a, b]) <- spineOf e, h `elem` uPrims || h `elem` fPrims = do
          lines1 <- stage env nxt [a, b]
          pure (lines1 ++ op2 h)
    go env nxt pos e
      | (CVar h, args@(_ : _)) <- spineOf e,
        S.member h uset,
        not (M.member h env) = do
          lines1 <- stage env nxt args
          let target = "fpr_ufn_" ++ mangle h
          pure $
            lines1 ++ case pos of
              NonTail -> ["    call " ++ target]
              Tail ->
                [ "    " ++ ld ++ " ra, " ++ show (-w) ++ "(s0)",
                  "    mv t0, s0",
                  "    " ++ ld ++ " s0, " ++ show (-2 * w) ++ "(s0)",
                  "    mv sp, t0",
                  "    j " ++ target
                ]
    go env nxt pos (CIf c t f) = do
      cl <- go env nxt NonTail c
      lElse <- freshL "uelse"
      lEnd <- freshL "uend"
      tl <- go env nxt pos t
      fl <- go env nxt pos f
      pure (cl ++ ["    beqz a0, " ++ lElse] ++ tl ++ ["    j " ++ lEnd, lElse ++ ":"] ++ fl ++ [lEnd ++ ":"])
    go env nxt pos (CTagEq 1 v x) = do
      xl <- go env nxt NonTail x
      pure (xl ++ ["    xori a0, a0, 1" | v == 0])
    go env nxt pos (CLet x a b) = do
      al <- go env nxt NonTail a
      bl <- go (M.insert x nxt env) (nxt + 1) pos b
      pure (al ++ stSlot tgt "a0" nxt ++ bl)
    go env _ _ (CVar n)
      | Just k <- M.lookup n env = pure (ldSlot tgt "a0" k)
    go _ _ _ (CInt i) = pure ["    li a0, " ++ show i]
    go _ _ _ (CMk 1 v []) = pure ["    li a0, " ++ show v]
    go _ _ _ (CErr msg) = do
      l <- strLabel msg
      pure ["    la a0, " ++ l, "    call fpr_panic"]
    go _ _ _ e = error ("internal: genU: unboxable guard let through " ++ show (spineHead e))
      where
        spineHead = fst . spineOf
    -- stage args into consecutive slots, then load a0..an (knownCall's discipline)
    stage env nxt args = do
      argLines <-
        concat
          <$> sequence
            [ (++ stSlot tgt "a0" (nxt + i)) <$> go env (nxt + i + 1) NonTail a
              | (i, a) <- zip [0 :: Int ..] args
            ]
      pure (argLines ++ concat [ldSlot tgt ("a" ++ show i) (nxt + i) | i <- [0 .. length args - 1]])
    op2 = \case
      "+" -> ["    add a0, a0, a1"]
      "-" -> ["    sub a0, a0, a1"]
      "*" -> ["    mul a0, a0, a1"]
      "/" -> ["    div a0, a0, a1"]
      "==" -> ["    xor t0, a0, a1", "    seqz a0, t0"]
      "!=" -> ["    xor t0, a0, a1", "    snez a0, t0"]
      "<" -> ["    slt a0, a0, a1"]
      ">" -> ["    slt a0, a1, a0"]
      "<=" -> ["    slt a0, a1, a0", "    xori a0, a0, 1"]
      ">=" -> ["    slt a0, a0, a1", "    xori a0, a0, 1"]
      -- floats: the raw word IS the bit pattern, so move it into an f
      -- register, operate, move the result back.  Values stay in
      -- integer registers/slots between ops, which is what keeps the
      -- frame, TCO and argspill discipline of the int clones intact.
      p | Just (w, o) <- fSplit p ->
            let sfx = if w == "64" then ".d" else ".s"
                mvx = if w == "64" then "fmv.d.x" else "fmv.w.x"
                mvi = if w == "64" then "fmv.x.d" else "fmv.x.w"
                bin i = [mvx ++ " ft0, a0", mvx ++ " ft1, a1", i ++ sfx ++ " ft0, ft0, ft1", mvi ++ " a0, ft0"]
                cmp i = [mvx ++ " ft0, a0", mvx ++ " ft1, a1", i ++ sfx ++ " a0, ft0, ft1"]
                cmpn i = [mvx ++ " ft0, a0", mvx ++ " ft1, a1", i ++ sfx ++ " a0, ft0, ft1", "xori a0, a0, 1"]
             in map ("    " ++) $ case o of
                  "+" -> bin "fadd"
                  "-" -> bin "fsub"
                  "*" -> bin "fmul"
                  "/" -> bin "fdiv"
                  "<" -> cmp "flt"
                  "<=" -> cmp "fle"
                  ">" -> [mvx ++ " ft0, a0", mvx ++ " ft1, a1", "flt" ++ sfx ++ " a0, ft1, ft0"]
                  ">=" -> [mvx ++ " ft0, a0", mvx ++ " ft1, a1", "fle" ++ sfx ++ " a0, ft1, ft0"]
                  "==" -> cmp "feq"
                  _ -> cmpn "feq" -- != : IEEE feq then invert (NaN != NaN holds)
      p -> error ("internal: genU prim " ++ p)

--------------------------------------------------------------------------------
-- specialized loop emission
--------------------------------------------------------------------------------

emitSpecs :: Prog -> G [String]
emitSpecs prog = do
  specs <- M.elems <$> gets cgSpecs
  if null specs
    then pure []
    else do
      tgt <- gets cgTgt
      rvv <- gets cgRvv
      let uset = S.unions (map (spClosure . snd) specs)
          soas = [(spFn p, soa) | (_, p) <- specs, Just soa <- [spSoa p]]
      ufns <-
        concat
          <$> mapM
            (\n -> compileUFn tgt prog uset ("fpr_ufn_" ++ mangle n) (prog M.! n))
            (S.toList uset)
      soafns <-
        concat
          <$> mapM
            (\(f, (_, ps, b, _)) -> compileUFn tgt prog uset ("fpr_ufn_soa_" ++ mangle f) (ps, b))
            soas
      let mvs = [(spFn p, mp) | (_, p) <- specs, Just mp <- [spMv p]]
      mvfns <-
        concat
          <$> mapM
            ( \(f, mp) ->
                concat
                  <$> mapM
                    (\(i, (_, (ps, b))) -> compileUFn tgt prog uset ("fpr_ufn_mv_" ++ mangle f ++ "_" ++ show i) (ps, b))
                    (zip [0 :: Int ..] (mvFields mp))
            )
            mvs
      loops <- concat <$> mapM (emitSpec tgt rvv) specs
      pure (["# ---- Vec specializations (see the essay above vecSpec) ----", ""] ++ ufns ++ soafns ++ mvfns ++ loops)

-- save regs above `slots` sp-relative scratch words; sp is FIXED inside
-- the spec body (no s0 frame chaining needed -- callees restore sp)
specFrame :: Target -> [String] -> Int -> (Int, [String], [String])
specFrame tgt regs slots = (frame, pro, epi)
  where
    w = tgtW tgt
    frame = ((w * length regs + w * slots + 15) `div` 16) * 16
    at i = show (frame - w * (i + 1)) ++ "(sp)"
    pro = ("    addi sp, sp, -" ++ show frame) : ["    " ++ tgtSt tgt ++ " " ++ r ++ ", " ++ at i | (i, r) <- zip [0 ..] regs]
    epi = ["    " ++ tgtLd tgt ++ " " ++ r ++ ", " ++ at i | (i, r) <- zip [0 ..] regs] ++ ["    addi sp, sp, " ++ show frame]

specFuel :: Target -> G [String]
specFuel tgt = do
  ok <- freshL "vfuel"
  pure
    [ "    mv t0, tp", -- per-hart fuel: 0(tp) is fpr_hart_t.fuel
      "    " ++ tgtLd tgt ++ " t1, 0(t0)",
      "    addi t1, t1, -1",
      "    " ++ tgtSt tgt ++ " t1, 0(t0)",
      "    bgtz t1, " ++ ok,
      "    call fpr_fuel_exhausted",
      ok ++ ":"
    ]

-- shared: contiguous column -- read cursor s5 = base + done*W, chunk
-- s6 = everything remaining (the outer loop's "next block" arm never
-- fires; it stays only as the loop's exit-recheck path).  s3 (the old
-- block index) is dead but the emitters still zero it: one register,
-- zero cost, and the loop shape stays identical across all five.
specBlock :: Target -> G [String]
specBlock tgt =
  pure
    [ "    " ++ tgtLd tgt ++ " s5, " ++ show (colBlk0 tgt) ++ "(s4)",
      "    slli t0, s2, " ++ show (logW tgt),
      "    add s5, s5, t0",
      "    sub s6, s1, s2"
    ]

-- entry guard: a<reg> must be an object with tid T_VEC; leaves reps in t0
vecGuard :: Target -> String -> String -> [String]
vecGuard _ reg fb =
  [ "    andi t0, " ++ reg ++ ", 1",
    "    bnez t0, " ++ fb,
    "    lw t0, 0(" ++ reg ++ ")",
    "    li t1, 9006",
    "    bne t0, t1, " ++ fb,
    "    lw t0, " ++ show vRep ++ "(" ++ reg ++ ")"
  ]

emitSpec :: Target -> Bool -> (String, SpecPlan) -> G [String]
emitSpec tgt rvv (sym, p) = case spOp p of
  "map" -> emitMapSpec tgt rvv sym p
  "mvmap" -> emitMvMapSpec tgt sym p
  "filter" -> emitFilterSpec tgt sym p
  _ | Just g <- wfoldG p -> emitWFoldSpec tgt sym p g
  _ -> emitFoldSpec tgt rvv sym p

-- RVV strip-mine wrapper: load -> body -> store, bump by vl
rvvE :: Target -> String
rvvE tgt = if tgtW tgt == 8 then "64" else "32"

emitMapSpec :: Target -> Bool -> String -> SpecPlan -> G [String]
emitMapSpec tgt rvv sym p = do
  let f = spFn p
      ld = tgtLd tgt
      st = tgtSt tgt
      (frame, pro, epi) = specFrame tgt ["ra", "s0", "s1", "s2", "s3", "s4", "s5", "s6"] 0
  ~[fb, louter, linner, lnextb, ldone] <- mapM freshL ["vfb", "vouter", "vinner", "vnextb", "vdone"]
  fuel <- specFuel tgt
  blk <- specBlock tgt
  vinner <- case spRvv p of
    Just (RvvMap prm body) | rvv -> pure (rvvMapInner tgt prm body linner lnextb)
    _ -> pure Nothing
  let inner = case vinner of
        Just ls -> ls
        Nothing ->
          [ linner ++ ":",
            "    beqz s6, " ++ lnextb,
            "    " ++ ld ++ " a0, 0(s5)",
            "    call fpr_ufn_" ++ mangle f,
            "    " ++ st ++ " a0, 0(s5)",
            "    addi s5, s5, " ++ show (tgtW tgt),
            "    addi s2, s2, 1",
            "    addi s6, s6, -1",
            "    j " ++ linner
          ]
  pure $
    [ "# Vec.map specialized on " ++ f ++ (if vinner /= Nothing then "  [RVV]" else ""),
      "    .globl " ++ sym,
      sym ++ ":"
    ]
      ++ vecGuard tgt "a0" fb
      ++ [ "    li t1, " ++ show (repOf p),
           "    bne t0, t1, " ++ fb -- scalar rep only (Int or float)
         ]
      ++ pro
      ++ [ "    mv s0, a0",
           "    " ++ ld ++ " s1, " ++ show vLen ++ "(s0)",
           "    li s2, 0",
           "    li s3, 0",
           "    " ++ ld ++ " s4, " ++ show (vCols0 tgt) ++ "(s0)"
         ]
      ++ [louter ++ ":", "    bgeu s2, s1, " ++ ldone]
      ++ fuel
      ++ blk
      ++ inner
      ++ [lnextb ++ ":", "    addi s3, s3, 1", "    j " ++ louter]
      ++ [ldone ++ ":", "    mv a0, s0"]
      ++ epi
      ++ [ "    ret",
           fb ++ ":",
           "    mv a1, a0",
           "    la a0, fpr_obj_" ++ mangle f,
           "    j fpr_vec_map",
           ""
         ]

rvvMapInner :: Target -> String -> Core -> String -> String -> Maybe [String]
rvvMapInner tgt prm body linner lnextb = do
  (lines1, res) <- compileV (M.fromList [(prm, VR 8)]) (9, 2) body
  let e = rvvE tgt
      resReg = case res of
        VR n -> "v" ++ show n
        SR t -> "v9" -- materialized below
      mat = case res of
        SR t -> ["    vmv.v.x v9, t" ++ show t] -- constant body
        _ -> []
  Just $
    [ linner ++ ":",
      "    beqz s6, " ++ lnextb,
      "    vsetvli t0, s6, e" ++ e ++ ", m1, ta, ma",
      "    vle" ++ e ++ ".v v8, (s5)"
    ]
      ++ lines1
      ++ mat
      ++ [ "    vse" ++ e ++ ".v " ++ resReg ++ ", (s5)",
           "    sub s6, s6, t0",
           "    slli t1, t0, " ++ show (logW tgt),
           "    add s5, s5, t1",
           "    add s2, s2, t0",
           "    j " ++ linner
         ]

-- vector-expression compiler for straight-line +/-/* bodies.
-- v8 holds the loaded lane data; results allocate v9..v15 and t2..t6.
data VOp = VR Int | SR Int deriving (Eq)

compileV :: M.Map String VOp -> (Int, Int) -> Core -> Maybe ([String], VOp)
compileV env0 c0 e0 = do
  (ls, r, _) <- go env0 c0 (peel e0)
  Just (ls, r)
  where
    go env c e
      | (CVar op, [a, b]) <- spineOf e,
        op `elem` ["+", "-", "*"] = do
          (la, va, c1) <- go env c (peel a)
          (lb, vb, c2) <- go env c1 (peel b)
          (lc, vr, c3) <- combine op va vb c2
          Just (la ++ lb ++ lc, vr, c3)
    go env c (CVar x) = do v <- M.lookup x env; Just ([], v, c)
    go env (vn, tn) (CInt i)
      | tn <= 6 = Just (["    li t" ++ show tn ++ ", " ++ show i], SR tn, (vn, tn + 1))
    go env c (CLet x a b) = do
      (la, va, c1) <- go env c (peel a)
      (lb, vb, c2) <- go (M.insert x va env) c1 (peel b)
      Just (la ++ lb, vb, c2)
    go _ _ _ = Nothing
    vop op suf d x y = "    v" ++ vName op ++ "." ++ suf ++ " v" ++ show d ++ ", v" ++ show x ++ ", " ++ y
    vName "+" = "add"
    vName "-" = "sub"
    vName _ = "mul"
    sName "+" = "add"
    sName "-" = "sub"
    sName _ = "mul"
    combine op (VR x) (VR y) (vn, tn)
      | vn <= 15 = Just ([vop op "vv" vn x ("v" ++ show y)], VR vn, (vn + 1, tn))
    combine op (VR x) (SR t) (vn, tn)
      | vn <= 15 = Just ([vop op "vx" vn x ("t" ++ show t)], VR vn, (vn + 1, tn))
    combine op (SR t) (VR y) (vn, tn)
      | vn <= 15 = case op of
          "-" -> Just (["    vrsub.vx v" ++ show vn ++ ", v" ++ show y ++ ", t" ++ show t], VR vn, (vn + 1, tn))
          _ -> Just ([vop op "vx" vn y ("t" ++ show t)], VR vn, (vn + 1, tn))
    combine op (SR a) (SR b) (vn, tn)
      | tn <= 6 =
          Just (["    " ++ sName op ++ " t" ++ show tn ++ ", t" ++ show a ++ ", t" ++ show b], SR tn, (vn, tn + 1))
    combine _ _ _ _ = Nothing

emitFilterSpec :: Target -> String -> SpecPlan -> G [String]
emitFilterSpec tgt sym p = do
  let f = spFn p
      ld = tgtLd tgt
      st = tgtSt tgt
      w = tgtW tgt
      regs = ["ra"] ++ ["s" ++ show i | i <- [0 .. 11 :: Int]]
      (_, pro, epi) = specFrame tgt regs 0
  ~[fb, louter, linner, lskip, lwadv, lnextb, ldone] <-
    mapM freshL ["vfb", "vouter", "vinner", "vskip", "vwadv", "vnextb", "vdone"]
  fuel <- specFuel tgt
  blk <- specBlock tgt
  pure $
    [ "# Vec.filter specialized on " ++ f ++ "  (in place: linearity licenses it)",
      "    .globl " ++ sym,
      sym ++ ":"
    ]
      ++ vecGuard tgt "a0" fb
      ++ ["    li t1, " ++ show (repOf p), "    bne t0, t1, " ++ fb]
      ++ pro
      ++ [ "    mv s0, a0",
           "    " ++ ld ++ " s1, " ++ show vLen ++ "(s0)",
           "    li s2, 0",
           "    li s3, 0",
           "    " ++ ld ++ " s4, " ++ show (vCols0 tgt) ++ "(s0)",
           "    li s10, 0", -- kept count
           "    beqz s1, " ++ ldone, -- empty: base may not exist
           "    " ++ ld ++ " s8, " ++ show (colBlk0 tgt) ++ "(s4)" -- write ptr = base
         ]
      ++ [louter ++ ":", "    bgeu s2, s1, " ++ ldone]
      ++ fuel
      ++ blk
      ++ [ linner ++ ":",
           "    beqz s6, " ++ lnextb,
           "    " ++ ld ++ " s11, 0(s5)",
           "    mv a0, s11",
           "    call fpr_ufn_" ++ mangle f, -- raw 0/1
           "    beqz a0, " ++ lskip,
           -- contiguous column: the write cursor never runs out (kept
           -- count can't exceed len), so it just advances
           "    " ++ st ++ " s11, 0(s8)",
           "    addi s8, s8, " ++ show w,
           "    addi s10, s10, 1",
           lskip ++ ":",
           "    addi s5, s5, " ++ show w,
           "    addi s2, s2, 1",
           "    addi s6, s6, -1",
           "    j " ++ linner
         ]
      ++ [lnextb ++ ":", "    addi s3, s3, 1", "    j " ++ louter]
      ++ [ ldone ++ ":",
           "    " ++ st ++ " s10, " ++ show vLen ++ "(s0)", -- len = kept
           "    mv a0, s0"
         ]
      ++ epi
      ++ [ "    ret",
           fb ++ ":",
           "    mv a1, a0",
           "    la a0, fpr_obj_" ++ mangle f,
           "    j fpr_vec_filter",
           ""
         ]

-- Vec.map (f cap) v, matvec-specialized: in-place SoA loop, one tiny
-- unboxed call per OUTPUT column per element, captured-record fields
-- loaded straight off the boxed record (a0), results buffered then
-- stored so later columns still read this element's ORIGINAL values.
emitMvMapSpec :: Target -> String -> SpecPlan -> G [String]
emitMvMapSpec tgt sym p = do
  let f = spFn p
      Just mp = spMv p
      (etid, evar) = mvTid mp
      n = mvN mp
      ld = tgtLd tgt
      st = tgtSt tgt
      w = tgtW tgt
      slots = 2 * n -- n cursors then n result temps
      -- s4/s5 belong to the shared specBlock idiom (s4 = column-0
      -- directory, s5 = its current block): both must be SAVED, and s4
      -- LOADED in setup.  This loop had shipped without either -- and
      -- was never caught because its elvar guard never passed until
      -- records carried their arity: emitted, grepped for, never run.
      regs = ["ra", "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s8"]
      (_, pro, epi) = specFrame tgt regs slots
      needCols = n
      usedMask = sum [2 ^ k | k <- [0 .. n - 1]] :: Integer
  ~[fb, ldis, lo, li, lnb, ldone] <- mapM freshL ["mvfb", "mvdis", "mvo", "mvi", "mvnb", "mvdone"]
  fuel <- specFuel tgt
  blk <- specBlock tgt
  let guards =
        vecGuard tgt "a1" fb
          ++ [ "    li t1, 3",
               "    bne t0, t1, " ++ fb, -- SoA rep only
               "    " ++ ld ++ " t0, " ++ show (8 + w) ++ "(a1)", -- eltid
               "    li t1, " ++ show etid,
               "    bne t0, t1, " ++ fb,
               "    " ++ ld ++ " t0, " ++ show (8 + 2 * w) ++ "(a1)", -- elvar
               "    li t1, " ++ show evar,
               "    bne t0, t1, " ++ fb,
               "    " ++ ld ++ " t0, " ++ show (vNcols tgt) ++ "(a1)",
               "    li t1, " ++ show needCols,
               "    bltu t0, t1, " ++ fb,
               "    " ++ ld ++ " t0, " ++ show (vKinds tgt) ++ "(a1)",
               "    li t1, " ++ show usedMask,
               "    and t2, t0, t1",
               "    bne t2, t1, " ++ fb,
               "    j " ++ ldis
             ]
      setup =
        [ldis ++ ":"]
          ++ pro
          ++ [ "    mv s8, a0", -- captured record (boxed)
               "    mv s0, a1", -- the vector
               "    " ++ ld ++ " s1, " ++ show vLen ++ "(s0)",
               "    " ++ ld ++ " s4, " ++ show (vCols0 tgt) ++ "(s0)",
               "    li s2, 0",
               "    li s3, 0"
             ]
      cursorLoads =
        concat
          [ [ "    " ++ ld ++ " t0, " ++ show (vCols0 tgt + k * w) ++ "(s0)",
              "    " ++ ld ++ " t0, " ++ show (colBlk0 tgt) ++ "(t0)", -- base
              "    slli t1, s2, " ++ show (logW tgt),
              "    add t0, t0, t1", -- + done elements
              "    " ++ st ++ " t0, " ++ show (k * w) ++ "(sp)"
            ]
            | k <- [0 .. n - 1]
          ]
      fieldCalls =
        concat
          [ concat
              [ concat
                  [ [ "    " ++ ld ++ " a" ++ show q ++ ", " ++ show (8 + w * j) ++ "(s8)",
                      -- the capture is a BOXED record: its fields are
                      -- TAGGED ints, but the unboxed field fns speak
                      -- raw words (same contract as the kinds-guarded
                      -- element columns) -- untag on the way in
                      "    srai a" ++ show q ++ ", a" ++ show q ++ ", 1"
                    ]
                    | (q, j) <- zip [0 :: Int ..] ms
                  ],
                concat
                  [ [ "    " ++ ld ++ " t0, " ++ show (k * w) ++ "(sp)",
                      "    " ++ ld ++ " a" ++ show (length ms + q) ++ ", 0(t0)"
                    ]
                    | (q, k) <- zip [0 :: Int ..] ks
                  ],
                [ "    call fpr_ufn_mv_" ++ mangle f ++ "_" ++ show i,
                  "    " ++ st ++ " a0, " ++ show ((n + i) * w) ++ "(sp)"
                ]
              ]
            | (i, ((ms, ks), _)) <- zip [0 :: Int ..] (mvFields mp)
          ]
      stores =
        concat
          [ [ "    " ++ ld ++ " t0, " ++ show (i * w) ++ "(sp)",
              "    " ++ ld ++ " t1, " ++ show ((n + i) * w) ++ "(sp)",
              "    " ++ st ++ " t1, 0(t0)",
              "    addi t0, t0, " ++ show w,
              "    " ++ st ++ " t0, " ++ show (i * w) ++ "(sp)"
            ]
            | i <- [0 .. n - 1]
          ]
      loop =
        [lo ++ ":", "    bgeu s2, s1, " ++ ldone]
          ++ fuel
          ++ blk
          ++ cursorLoads
          ++ [li ++ ":", "    beqz s6, " ++ lnb]
          ++ fieldCalls
          ++ stores
          ++ [ "    addi s2, s2, 1",
               "    addi s6, s6, -1",
               "    j " ++ li
             ]
          ++ [lnb ++ ":", "    addi s3, s3, 1", "    j " ++ lo]
      finish = [ldone ++ ":", "    mv a0, s0"] ++ epi ++ ["    ret"]
      fallback =
        [ fb ++ ":",
          -- build (f cap) as a real closure, then the generic C tier
          "    addi sp, sp, -" ++ show (2 * w),
          "    " ++ st ++ " ra, 0(sp)",
          "    " ++ st ++ " a1, " ++ show w ++ "(sp)",
          "    mv a1, a0",
          "    la a0, fpr_obj_" ++ mangle f,
          "    call fpr_apply",
          "    " ++ ld ++ " a1, " ++ show w ++ "(sp)",
          "    " ++ ld ++ " ra, 0(sp)",
          "    addi sp, sp, " ++ show (2 * w),
          "    j fpr_vec_map",
          ""
        ]
  pure $
    [ "# Vec.map matvec-specialized on " ++ f ++ "  [SoA in-place, " ++ show n ++ " cols, axpb-shaped field fns]",
      "    .globl " ++ sym,
      sym ++ ":"
    ]
      ++ guards
      ++ setup
      ++ loop
      ++ finish
      ++ fallback

emitFoldSpec :: Target -> Bool -> String -> SpecPlan -> G [String]
emitFoldSpec tgt rvv sym p = do
  let f = spFn p
      ld = tgtLd tgt
      st = tgtSt tgt
      w = tgtW tgt
      usedCols = maybe [] (\(ks, _, _, _) -> ks) (spSoa p)
      nSlots = length usedCols
      regs = ["ra"] ++ ["s" ++ show i | i <- [0 .. 7 :: Int]]
      (_, pro, epi) = specFrame tgt regs nSlots
      doRvvSum = rvv && spRvv p == Just RvvFoldSum && spScalar p
      doGpuPairSum = isGpuPairSum p
      e = rvvE tgt
  ~[fb, ldis, lscal, lsoa, ldone] <- mapM freshL ["vfb", "vdis", "vscal", "vsoa", "vdone"]
  -- scalar loop labels
  ~[so, si, snb, ssd] <- mapM freshL ["vso", "vsi", "vsnb", "vssd"]
  -- soa loop labels
  ~[ao, ai, anb] <- mapM freshL ["vao", "vai", "vanb"]
  fuel1 <- specFuel tgt
  blk1 <- specBlock tgt
  fuel2 <- specFuel tgt
  blk2 <- specBlock tgt
  let needCols = if null usedCols then 0 else maximum usedCols + 1
      usedMask = sum [2 ^ k | k <- usedCols] :: Integer
      guards =
        vecGuard tgt "a1" fb
          ++ ["    mv t2, t0"] -- rep
          ++ ( if spFloat p == Nothing
                 then [ "    andi t0, a0, 1",
                        "    beqz t0, " ++ fb -- z must be Int (raw acc)
                      ]
                 else [] -- float z: raw bits, no tag to check
             )
          ++ ( if spScalar p
                 then ["    li t1, " ++ show (repOf p), "    beq t2, t1, " ++ ldis]
                 else []
             )
          ++ ( case spSoa p of
                 Nothing -> ["    j " ++ fb]
                 Just (_, _, _, (etid, evar)) ->
                   [ "    li t1, 3",
                     "    bne t2, t1, " ++ fb
                   ]
                   ++ ( if etid < 0
                          then [] -- (-1,-1): body carried no shape test
                          -- (unique-shape projections) -- the dual is
                          -- exactly as shape-checked as the generic
                          -- body, so only ncols/kinds gate below
                          else
                            [ "    " ++ ld ++ " t0, " ++ show (8 + tgtW tgt) ++ "(a1)", -- eltid
                              "    li t1, " ++ show etid,
                              "    bne t0, t1, " ++ fb,
                              "    " ++ ld ++ " t0, " ++ show (8 + 2 * tgtW tgt) ++ "(a1)", -- elvar
                              "    li t1, " ++ show evar,
                              "    bne t0, t1, " ++ fb
                            ]
                      )
                   ++ [ "    " ++ ld ++ " t0, " ++ show (vNcols tgt) ++ "(a1)",
                     "    li t1, " ++ show needCols,
                     "    bltu t0, t1, " ++ fb, -- enough columns
                     "    " ++ ld ++ " t0, " ++ show (vKinds tgt) ++ "(a1)",
                     "    li t1, " ++ show usedMask,
                     "    and t2, t0, t1",
                     "    bne t2, t1, " ++ fb, -- used columns unboxed
                     "    j " ++ ldis
                   ]
             )
      setup =
        [ ldis ++ ":" ]
          ++ pro
          ++ [ "    mv s0, a1",
               ( if spFloat p == Nothing
                   then "    srai s7, a0, 1" -- acc, raw int
                   else "    mv s7, a0" -- acc, raw float bits
               ),
               "    " ++ ld ++ " s1, " ++ show vLen ++ "(s0)",
               "    li s2, 0",
               "    li s3, 0"
             ]
          ++ ( if spScalar p && spSoa p /= Nothing
                 then ["    lw t0, " ++ show vRep ++ "(s0)", "    li t1, " ++ show (repOf p), "    beq t0, t1, " ++ lscal, "    j " ++ lsoa]
                 else if spScalar p then ["    j " ++ lscal] else ["    j " ++ lsoa]
             )
      scalPath
        | not (spScalar p) = []
        | otherwise =
            [ lscal ++ ":",
              "    " ++ ld ++ " s4, " ++ show (vCols0 tgt) ++ "(s0)"
            ]
              ++ ( if doRvvSum
                     then ["    vsetvli t0, x0, e" ++ e ++ ", m1, ta, ma", "    vmv.v.i v1, 0"]
                     else []
                 )
              ++ [so ++ ":", "    bgeu s2, s1, " ++ ssd]
              ++ fuel1
              ++ blk1
              ++ ( if doRvvSum
                     then
                       [ si ++ ":",
                         "    beqz s6, " ++ snb,
                         "    vsetvli t0, s6, e" ++ e ++ ", m1, tu, ma",
                         "    vle" ++ e ++ ".v v8, (s5)",
                         "    vadd.vv v1, v1, v8", -- tu: tail lanes preserved
                         "    sub s6, s6, t0",
                         "    slli t1, t0, " ++ show (logW tgt),
                         "    add s5, s5, t1",
                         "    add s2, s2, t0",
                         "    j " ++ si
                       ]
                     else
                       [ si ++ ":",
                         "    beqz s6, " ++ snb,
                         "    mv a0, s7",
                         "    " ++ ld ++ " a1, 0(s5)",
                         "    call fpr_ufn_" ++ mangle f,
                         "    mv s7, a0",
                         "    addi s5, s5, " ++ show w,
                         "    addi s2, s2, 1",
                         "    addi s6, s6, -1",
                         "    j " ++ si
                       ]
                 )
              ++ [snb ++ ":", "    addi s3, s3, 1", "    j " ++ so]
              ++ [ssd ++ ":"]
              ++ ( if doRvvSum
                     then
                       [ "    vmv.s.x v2, s7", -- seed = acc (incl z)
                         "    vsetvli t0, x0, e" ++ e ++ ", m1, ta, ma",
                         "    vredsum.vs v2, v1, v2",
                         "    vmv.x.s s7, v2"
                       ]
                     else []
                 )
              ++ ["    j " ++ ldone]
      soaPath = case spSoa p of
        Nothing -> []
        Just (ks, _, _, _) ->
          [ lsoa ++ ":",
            -- all columns share block structure; cols[0] drives the count
            "    " ++ ld ++ " s4, " ++ show (vCols0 tgt) ++ "(s0)"
          ]
            ++ (if doGpuPairSum
                  then [ "    " ++ ld ++ " a0, " ++ show (vCols0 tgt) ++ "(s0)",
                         "    " ++ ld ++ " a1, " ++ show (vCols0 tgt + w) ++ "(s0)",
                         "    mv a2, s1",
                         "    mv a3, s7",
                         "    mv a4, sp",
                         "    call fpr_gpu_vec_fold_pair_sum",
                         "    beqz a0, " ++ ao,
                         "    " ++ ld ++ " s7, 0(sp)",
                         "    j " ++ ldone
                       ]
                  else [])
            ++ [ao ++ ":", "    bgeu s2, s1, " ++ ldone]
            ++ fuel2
            ++ blk2' -- like specBlock but per-column cursors, no s5
            ++ [ ai ++ ":",
                 "    beqz s6, " ++ anb
               ]
            ++ concat
              [ [ "    " ++ ld ++ " t0, " ++ show (q * w) ++ "(sp)",
                  "    " ++ ld ++ " a" ++ show (q + 1) ++ ", 0(t0)",
                  "    addi t0, t0, " ++ show w,
                  "    " ++ st ++ " t0, " ++ show (q * w) ++ "(sp)"
                ]
                | (q, _) <- zip [0 :: Int ..] ks
              ]
            ++ [ "    mv a0, s7",
                 "    call fpr_ufn_soa_" ++ mangle f,
                 "    mv s7, a0",
                 "    addi s2, s2, 1",
                 "    addi s6, s6, -1",
                 "    j " ++ ai
               ]
            ++ [anb ++ ":", "    addi s3, s3, 1", "    j " ++ ao]
          where
            blk2' =
              blk2 -- count math; its s5 (cols[0] base) load is simply unused here
                ++ concat
                  [ [ "    " ++ ld ++ " t0, " ++ show (vCols0 tgt + k * w) ++ "(s0)", -- col_t* for column k
                      "    " ++ ld ++ " t0, " ++ show (colBlk0 tgt) ++ "(t0)", -- base
                      "    slli t1, s2, " ++ show (logW tgt),
                      "    add t0, t0, t1", -- + done elements
                      "    " ++ st ++ " t0, " ++ show (q * w) ++ "(sp)" -- cursor slot
                    ]
                    | (q, k) <- zip [0 :: Int ..] ks
                  ]
      finish =
        [ ldone ++ ":",
          "    li a0, " ++ show (8 + 2 * w),
          "    call fpr_alloc",
          "    li t0, 4", -- T_TUP2
          "    sw t0, 0(a0)",
          "    sw zero, 4(a0)"
        ]
          ++ ( if spFloat p == Nothing
                 then [ "    slli t0, s7, 1",
                        "    ori t0, t0, 1" -- tag the acc
                      ]
                 else ["    mv t0, s7"] -- float acc: the bits ARE the value
             )
          ++ [ "    " ++ st ++ " t0, 8(a0)",
          "    " ++ st ++ " s0, " ++ show (8 + w) ++ "(a0)"
        ]
          ++ epi
          ++ [ "    ret",
               fb ++ ":",
               "    mv a2, a1",
               "    mv a1, a0",
               "    la a0, fpr_obj_" ++ mangle f,
               "    j fpr_vec_fold",
               ""
             ]
  pure $
    [ "# Vec.fold specialized on " ++ f
        ++ (if doRvvSum then "  [RVV vredsum]" else "")
      ++ (if doGpuPairSum then "  [GPU pair sum]" else "")
        ++ (if spSoa p /= Nothing then "  [SoA dualized]" else ""),
      "    .globl " ++ sym,
      sym ++ ":"
    ]
      ++ guards
      ++ setup
      ++ scalPath
      ++ soaPath
      ++ finish

-- WRITE-BACK FOLD: one pass that stores g(el) back into the column
-- AND folds f over the stored value -- Vec.fold f z (Vec.map g v)
-- with both writes and the fold visible exactly as the two-pass
-- program left them.  Scalar int rep only (v1); the runtime fallback
-- is the honest two-pass sequence (generic map, then generic fold),
-- so a rep mismatch or an untagged z loses only the fusion, never
-- correctness.
emitWFoldSpec :: Target -> String -> SpecPlan -> String -> G [String]
emitWFoldSpec tgt sym p g = do
  let f = spFn p
      ld = tgtLd tgt
      st = tgtSt tgt
      w = tgtW tgt
      regs = ["ra"] ++ ["s" ++ show i | i <- [0 .. 7 :: Int]]
      (_, pro, epi) = specFrame tgt regs 0
  ~[fb, louter, linner, lnextb, ldone] <- mapM freshL ["wfb", "wouter", "winner", "wnextb", "wdone"]
  fuel <- specFuel tgt
  blk <- specBlock tgt
  pure $
    [ "# write-back fold: Vec.fold " ++ f ++ " z (Vec.map " ++ g ++ " v), one pass",
      "    .globl " ++ sym,
      sym ++ ":"
    ]
      ++ vecGuard tgt "a1" fb
      ++ [ "    li t1, " ++ show (repOf p),
           "    bne t0, t1, " ++ fb, -- int columns only in v1
           "    andi t0, a0, 1",
           "    beqz t0, " ++ fb -- z must be a tagged Int (raw acc)
         ]
      ++ pro
      ++ [ "    mv s0, a1",
           "    srai s7, a0, 1", -- acc, raw int
           "    " ++ ld ++ " s1, " ++ show vLen ++ "(s0)",
           "    li s2, 0",
           "    li s3, 0",
           "    " ++ ld ++ " s4, " ++ show (vCols0 tgt) ++ "(s0)"
         ]
      ++ [louter ++ ":", "    bgeu s2, s1, " ++ ldone]
      ++ fuel
      ++ blk
      ++ [ linner ++ ":",
           "    beqz s6, " ++ lnextb,
           "    " ++ ld ++ " a0, 0(s5)",
           "    call fpr_ufn_" ++ mangle g,
           "    " ++ st ++ " a0, 0(s5)", -- the WRITE BACK: map's store
           "    mv a1, a0",
           "    mv a0, s7",
           "    call fpr_ufn_" ++ mangle f,
           "    mv s7, a0",
           "    addi s5, s5, " ++ show w,
           "    addi s2, s2, 1",
           "    addi s6, s6, -1",
           "    j " ++ linner
         ]
      ++ [lnextb ++ ":", "    addi s3, s3, 1", "    j " ++ louter]
      ++ [ ldone ++ ":", -- (acc, vec), the fold return shape
           "    li a0, " ++ show (8 + 2 * w),
           "    call fpr_alloc",
           "    li t0, 4", -- T_TUP2
           "    sw t0, 0(a0)",
           "    sw zero, 4(a0)",
           "    slli t0, s7, 1",
           "    ori t0, t0, 1",
           "    " ++ st ++ " t0, 8(a0)",
           "    " ++ st ++ " s0, " ++ show (8 + w) ++ "(a0)"
         ]
      ++ epi
      ++ [ "    ret",
           fb ++ ":",
           -- the two-pass truth: generic map, then generic fold.  The
           -- middle call means ra and z must survive it.
           "    addi sp, sp, -16",
           "    " ++ st ++ " ra, 0(sp)",
           "    " ++ st ++ " a0, 8(sp)", -- z
           "    la a0, fpr_obj_" ++ mangle g,
           "    call fpr_vec_map",
           "    mv a2, a0",
           "    " ++ ld ++ " a1, 8(sp)",
           "    " ++ ld ++ " ra, 0(sp)",
           "    addi sp, sp, 16",
           "    la a0, fpr_obj_" ++ mangle f,
           "    j fpr_vec_fold",
           ""
         ]

isGpuPairSum :: SpecPlan -> Bool
isGpuPairSum p = case spSoa p of
  Just ([0, 1], [acc, c0, c1], body, _) ->
    sort (addTerms (strip body)) == sort [acc, c0, c1]
  _ -> False
  where
    strip (CLet x a b) = substGpu x (strip a) (strip b)
    strip (CIf (CMk 1 1 []) t _) = strip t
    strip e = e
    addTerms (CApp (CApp (CVar "+") a) b) = addTerms a ++ addTerms b
    addTerms (CVar x) = [x]
    addTerms _ = ["<not-add>"]
    substGpu x a = go
      where
        go (CVar y) | y == x = a
        go (CApp f y) = CApp (go f) (go y)
        go (CLet y v b) | y /= x = CLet y (go v) (go b)
        go (CIf c t e) = CIf (go c) (go t) (go e)
        go e = e
