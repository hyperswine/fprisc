-- Allocation-free, non-reentrant interrupt entry contract, checked transitively
-- on lifted Core before ownership instrumentation. Raw memory remains unsafe:
-- the programmer must not touch the allocator, ARC objects or reserved stacks.
module Interrupt (checkInterrupt) where
import FPRISC (Core(..), Prog)
import Representation (primitiveShape)
import Control.Monad (foldM, unless)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

checkInterrupt :: Prog -> Either String ()
checkInterrupt prog
  | M.notMember "machineInterrupt" prog = Right ()
  | otherwise = () <$ visit S.empty "machineInterrupt"
  where
    bad msg = Left ("automatic ARC: interrupt contract: " ++ msg)
    visit seen n
      | S.member n seen = Right seen
      | otherwise = case M.lookup n prog of
          Just (ps,b) -> do
            unless (length ps <= 8) $ bad (n ++ " exceeds the register-only argument ABI")
            walk (S.insert n seen) b
          Nothing -> if allowed n then Right seen else bad ("call to " ++ n ++ " may allocate or alter interrupt control")
    allowed n = primitiveShape n /= Nothing && n `notElem`
      ["str","print","strcat","String.len","error","F64.str","F32.str",
       "Mem.alloc","Mem.realloc","Mem.free","Mem.liveAllocations",
       "CPU.csrWrite","CPU.irqEnable","CPU.irqRestore","CPU.wait"]
    walk seen e = case e of
      CStr _ -> bad "string values are not admitted in handlers"
      CMk _ _ (_:_) -> bad "heap construction in handler"
      CProj {} -> bad "managed field projection in handler"
      CLam {} -> bad "lambda survived lifting"
      CErr _ -> Right seen -- static diagnostic and non-returning, allocation-free panic
      CVar n | M.member n prog -> visit seen n
      CApp {} -> let (f,as)=spine e in case f of
        CVar n -> do s <- visit seen n; foldM walk s as
        _ -> bad "indirect application in handler"
      CLet _ a b -> walk seen a >>= (`walk` b)
      CIf c t f -> walk seen c >>= (`walk` t) >>= (`walk` f)
      CTagEq _ _ x -> walk seen x
      _ -> Right seen
    spine = go [] where
      go as (CApp f x) = go (x:as) f
      go as f = (f,as)
