-- An explicitly counted source calling interface. A function-valued result
-- does not add physical parameters; the checking owner supplies that count.
module Core.Calling (Calling,calling,callingArguments,callingResult,callingArity) where
import Type.Syntax

data Calling=Calling [Type] Type deriving Show
calling :: Int -> Type -> Maybe Calling
calling count _ | count<0=Nothing
calling 0 ty=Just (Calling [] ty)
calling n (TFn a b)=do Calling as result<-calling (n-1) b;pure (Calling (a:as) result)
calling _ _=Nothing
callingArguments :: Calling -> [Type]
callingArguments (Calling as _)=as
callingResult :: Calling -> Type
callingResult (Calling _ r)=r
callingArity :: Calling -> Int
callingArity=length . callingArguments
