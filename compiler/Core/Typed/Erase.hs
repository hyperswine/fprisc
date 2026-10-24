-- Compatibility boundary for the remaining untyped Core passes. Resolve IDs
-- from the lexical environment and reject capture by a display spelling.
module Core.Typed.Erase (eraseFunction) where
import Core.Typed.Syntax
import Core.Typed.Verify (verifyFunction)
import Core.Syntax (Core(..))
import Control.Monad (unless)
import qualified Data.Map.Strict as M

eraseFunction :: TypeContext -> Function -> Either String ([String],Core)
eraseFunction types f = do
  verifyFunction types f
  let ps=functionParameters f
  body <- go (M.fromList [(binderId b,binderName b) | b<-ps])
             (M.fromList [(binderName b,binderId b) | b<-ps]) (functionBody f)
  pure (map binderName ps,body)
  where
    scope b env names = (M.insert (binderId b) (binderName b) env,M.insert (binderName b) (binderId b) names)
    go env names e = case exprNode e of
      Var (Local uid) -> do
        n <- maybe (Left "typed Core erasure: absent local") Right (M.lookup uid env)
        unless (M.lookup n names==Just uid) (Left "typed Core erasure: display spelling would capture a local identity")
        pure (CVar n)
      Var (Global n _) -> do
        unless (M.notMember n names) (Left "typed Core erasure: display spelling would capture a global")
        pure (CVar n)
      IntValue n -> pure (CInt n)
      StringValue s -> pure (CStr s)
      BoolValue b -> pure (CMk 1 (if b then 1 else 0) [])
      Apply a b -> CApp <$> go env names a <*> go env names b
      Lambda ps b -> let (env',names')=foldl (\(e,n) p -> scope p e n) (env,names) ps
                     in CLam (map binderName ps) <$> go env' names' b
      Let p a b -> let (env',names')=scope p env names
                  in CLet (binderName p) <$> go env names a <*> go env' names' b
      If a b c -> CIf <$> go env names a <*> go env names b <*> go env names c
      BoolTest b x -> CTagEq 1 (if b then 1 else 0) <$> go env names x
      Note x -> go env names x
