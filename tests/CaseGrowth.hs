module Main where
import FPRISC
import Control.Monad (unless)
import Control.Monad.State.Strict (runState)
import qualified Data.Map.Strict as M

nodes :: Core -> Int
nodes expr = 1 + case expr of
  CApp f x -> nodes f + nodes x
  CLam _ b -> nodes b
  CLet _ a b -> nodes a + nodes b
  CIf c t e -> nodes c + nodes t + nodes e
  CMk _ _ fs -> sum (map nodes fs)
  CTagEq _ _ e -> nodes e
  CProj _ e -> nodes e
  _ -> 0

size n = do
  let arms = [(PTup [PInt i, PInt i], SInt i) | i <- [1..n]] ++ [(PWild, SInt (-1))]
      tops = [TBind "pick" [PVar "p"] [] (SCase (SVar "p") arms)]
      (prog, _) = runState (compileTop tops >>= liftFix) (DEnv 0 builtinCons M.empty [])
      count = sum [nodes b | (_, b) <- M.elems prog]
  pure count

main = check 0 0 [4,8,16,32,64]
  where
    check _ _ [] = pure ()
    check previousSize previousCount (n:ns) = do
      count <- size n
      putStrLn (show n ++ " arms: " ++ show count ++ " Core nodes")
      unless (previousSize == 0 || count <= 2 * previousCount + 100) $
        error "nested-pattern Core growth is not linear"
      check n count ns
