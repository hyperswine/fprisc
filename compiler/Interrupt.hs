-- Allocation-free, non-reentrant interrupt entry contract, checked transitively
-- on lifted Core before ownership instrumentation. Raw memory remains unsafe:
-- the programmer must not touch the allocator, ARC objects or reserved stacks.
module Interrupt (checkInterrupt, checkRawUnit) where
import FPRISC (Core(..), Prog)
import Representation (primitiveShape)
import Control.Monad (foldM, unless)
import Data.List (isPrefixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

checkInterrupt :: Prog -> Either String ()
checkInterrupt prog
  | M.notMember "machineInterrupt" prog = Right ()
  | otherwise = checkFrom "interrupt contract" handlerPrim prog ["machineInterrupt"]
  where
    -- a handler may not touch the allocator or interrupt control
    handlerPrim n = n `notElem`
      ["str","print","strcat","String.len","error","F64.str","F32.str",
       "Mem.alloc","Mem.realloc","Mem.free","Mem.liveAllocations",
       "CPU.csrWrite","CPU.irqEnable","CPU.irqRestore","CPU.wait"]

-- A RAW UNIT (--raw): every function is held to the allocation-free
-- contract, so ownership instrumentation can be left out entirely --
-- the unit's only values are raw words, addresses, floats, tagged Ints
-- and the immortal Bool/Unit, and retain/release of those are no-ops.
-- This is what lets the allocator itself be written in FP-RISC: an
-- instrumented allocator would call fpr_builtin_retain on its own Int
-- temporaries, which is the allocator, which ... (the first heap.fpr
-- image died exactly that way).  Unlike a handler, a raw unit may touch
-- CSRs and interrupt control: drivers live here.
checkRawUnit :: Prog -> Either String ()
checkRawUnit prog = checkFrom "raw unit" rawPrim prog [n | (n,(ps,b)) <- M.toList prog, not (isStub ps b)]
  where
    -- the constructor stubs the compiler puts in every unit (Cons, Tup2,
    -- ...) ARE heap construction; defining them is fine, CALLING one is
    -- what the walk refuses
    isStub ps (CMk _ _ fs) = fs == map CVar ps
    isStub _ _ = False
    rawPrim n = n `notElem`
      ["str","print","strcat","String.len","error","F64.str","F32.str",
       "Mem.alloc","Mem.realloc","Mem.free","Mem.liveAllocations"]

checkFrom :: String -> (String -> Bool) -> Prog -> [String] -> Either String ()
checkFrom what allowedPrim prog roots = () <$ foldM visit S.empty roots
  where
    bad msg = Left ("automatic ARC: " ++ what ++ ": " ++ msg)
    visit seen n
      | S.member n seen = Right seen
      | otherwise = case M.lookup n prog of
          Just (ps,b) -> do
            unless (length ps <= 8) $ bad (n ++ " exceeds the register-only argument ABI")
            either (Left . (++ " (in " ++ n ++ ")")) Right (walk (S.insert n seen) b)
          Nothing -> if allowed n || "$sym." `isPrefixOf` n then Right seen else bad ("call to " ++ n ++ " may allocate or alter interrupt control")
    allowed n = primitiveShape n /= Nothing && allowedPrim n
    walk seen e = case e of
      -- `error "literal"`: a static, non-returning panic through a rodata
      -- string -- no allocation, so it is admitted where nothing else
      -- string-shaped is
      CApp (CVar "error") (CStr _) -> Right seen
      CStr _ -> bad "string values are not admitted here"
      CMk _ _ (_:_) -> bad "heap construction is not admitted here"
      CProj {} -> bad "managed field projection is not admitted here"
      CLam {} -> bad "lambda survived lifting"
      CErr _ -> Right seen -- static diagnostic and non-returning, allocation-free panic
      CVar n | M.member n prog -> visit seen n
      CApp {} -> let (f,as)=spine e in case f of
        CVar n -> do s <- visit seen n; foldM walk s as
        _ -> bad "indirect application is not admitted here"
      CLet _ a b -> walk seen a >>= (`walk` b)
      CIf c t f -> walk seen c >>= (`walk` t) >>= (`walk` f)
      CTagEq _ _ x -> walk seen x
      _ -> Right seen
    spine = go [] where
      go as (CApp f x) = go (x:as) f
      go as f = (f,as)
