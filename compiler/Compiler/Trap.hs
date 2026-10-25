-- Checked plans for generated failures. Delays are part of the language's
-- eager evaluation contract; the final failure is an intrinsic, not a name.
module Compiler.Trap
  (TrapOrigin(..), TrapPlan, anonymousTrap, constructorTrap, trapArguments,
   trapResult, trapMessage, trapOrigin) where
import Type.Syntax

data TrapOrigin=AnonymousHole | ConstructorHole String deriving (Eq,Show)
data TrapPlan=TrapPlan TrapOrigin [Type] Type deriving (Show)
trapOrigin :: TrapPlan -> TrapOrigin
trapOrigin (TrapPlan origin _ _)=origin
trapArguments :: TrapPlan -> [Type]
trapArguments (TrapPlan _ args _)=args
trapResult :: TrapPlan -> Type
trapResult (TrapPlan _ _ result)=result
trapMessage :: TrapOrigin -> String
trapMessage AnonymousHole="typed hole ?? (unimplemented)"
trapMessage (ConstructorHole name)="typed hole ?? in constructor "++name++" (unimplemented)"

-- A functional expression hole consumes just its first argument. Even if
-- the remaining result is another function, applying once must trap.
anonymousTrap :: Type -> TrapPlan
anonymousTrap (TFn arg result)=TrapPlan AnonymousHole [arg] result
anonymousTrap ty=TrapPlan AnonymousHole [] ty

-- Constructor wrappers are curried one argument at a time. Partial use is
-- a value; the final constructor argument triggers the failure.
constructorTrap :: String -> Int -> Type -> Either String TrapPlan
constructorTrap name arity ty
  | arity<=0=Left "constructor trap requires a positive field count"
  | otherwise=do
      (args,result)<-peel arity ty
      pure (TrapPlan (ConstructorHole name) args result)
  where
    peel 0 result=Right ([],result)
    peel n (TFn arg rest)=do (args,result)<-peel (n-1) rest; pure (arg:args,result)
    peel _ _=Left "constructor trap arity disagrees with its checked type"
