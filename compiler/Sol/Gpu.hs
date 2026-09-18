-- Sol/Gpu.hs — the GPU tier of the Vec dispatch lattice.
--
-- POLICY, not optimism: this tier fires only when EVERY gate passes,
-- and each gate is checked at dispatch time, per call —
--
--   1. availability   solgpu_init probed once (SOL_GPU=0 kills the tier)
--   2. safety         the helper's Core is in the same pure arithmetic
--                     fragment the JIT accepts — no effects possible by
--                     construction (glslOfFn returns Nothing otherwise)
--   3. exactness      f64 element columns only, ops {+,-,*,/,sqrt}:
--                     GLSL 4.30 doubles are the SAME IEEE arithmetic
--                     the JIT emits, so results stay bit-identical.
--                     Int columns are REFUSED (integer `/` semantics
--                     and 2^53 products would silently diverge) — they
--                     belong to the JIT tier.
--   4. size           n >= SOL_GPU_MIN (default 65536): below that the
--                     SSBO round trip loses to the JIT; the threshold
--                     is the measured crossover's order of magnitude,
--                     tunable per machine.
--
-- Anything failing any gate falls to the JIT, which falls to the
-- interpreter: three tiers, one contract, richer discharge upward.
module Sol.Gpu (GpuCtx, initGPU, gpuMinLen, glslOfFn, gpuMapF64) where

import Data.IORef
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CLong (..))
import qualified Foreign.C.Types as C
import Foreign.Marshal.Array (peekArray, withArray)
import Foreign.Ptr (Ptr)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Storable (peekElemOff)
import Sol.Lang (Core (..), Prog, Name)
import Sol.Bytecode (cmpNames)
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)

foreign import ccall unsafe "solgpu_init" c_init :: IO C.CInt
foreign import ccall unsafe "solgpu_map_f64" c_map :: CString -> Ptr Double -> CLong -> Ptr Double -> Ptr Double -> CLong -> IO C.CInt

newtype GpuCtx = GpuCtx ()

initGPU :: IO (Maybe GpuCtx)
initGPU = do
  flag <- lookupEnv "SOL_GPU"
  if flag == Just "0"
    then pure Nothing
    else do
      ok <- c_init
      pure (if ok == 1 then Just (GpuCtx ()) else Nothing)

gpuMinLen :: Int
gpuMinLen = unsafePerformIO $ do
  e <- lookupEnv "SOL_GPU_MIN"
  pure (maybe 65536 read e)
{-# NOINLINE gpuMinLen #-}

-- ---- Core -> GLSL: the translatable fragment ---------------------------
-- The helper's LAST param is the element; any earlier params are
-- CAPTURED f64 SCALARS delivered as double uniforms (u0, u1, ...) so a
-- gradient-descent loop whose parameters change every epoch reuses ONE
-- cached program -- the values ride the uniform slots, never the source.
-- Body over: the params, double literals via CInt, {+,-,*,/},
-- Num.sqrt/Num.div, let, if over comparisons.  Everything else ->
-- Nothing -> the JIT tier's problem.  This is deliberately the same
-- SHAPE of check as JIT.jittable: the guard is the safety proof.
glslOfFn :: Prog -> Name -> Int -> Maybe String
glslOfFn prog g nCap = do
  (ps, body) <- M.lookup g prog
  (caps, [p]) <- if length ps == nCap + 1 then Just (splitAt nCap ps) else Nothing
  let env0 = M.fromList ((p, "x0") : zip caps ["u" ++ show i | i <- [0 :: Int ..]])
  e <- expr env0 body
  pure (shader e)
  where
    shader e =
      unlines $
        [ "#version 430",
          "layout(local_size_x = 64) in;",
          "layout(std430, binding = 0) buffer A { double xs[]; };",
          "layout(std430, binding = 1) buffer B { double outv[]; };"
        ]
          ++ ["uniform double u" ++ show i ++ ";" | i <- [0 .. nCap - 1]]
          ++ [ "void main() {",
               "  uint gid = gl_GlobalInvocationID.x;",
               "  if (gid >= xs.length()) return;",
               "  double x0 = xs[gid];",
               "  outv[gid] = " ++ e ++ ";",
               "}"
             ]
    expr = go
      where
        go env c = case c of
          CVar v | Just s <- M.lookup v env -> Just s
          CInt k -> Just ("double(" ++ show k ++ ")")
          CApp (CApp (CVar op) a) b
            | op `elem` ["+", "-", "*", "/"] -> bin env op a b
            | op == "Num.div" -> bin env "/" a b
          CApp (CVar "Num.sqrt") a -> (\x -> "sqrt(" ++ x ++ ")") <$> go env a
          CIf (CApp (CApp (CVar cmp) a) b) t f
            | Just gl <- lookup cmp cmps -> do
                a' <- go env a; b' <- go env b; t' <- go env t; f' <- go env f
                pure ("((" ++ a' ++ " " ++ gl ++ " " ++ b' ++ ") ? (" ++ t' ++ ") : (" ++ f' ++ "))")
          -- let: bind the value's GLSL text (parenthesized) in the env
          CLet x v b -> do
            v' <- go env v
            go (M.insert x ("(" ++ v' ++ ")") env) b
          _ -> Nothing
        bin env op a b = do
          a' <- go env a; b' <- go env b
          pure ("(" ++ a' ++ " " ++ op ++ " " ++ b' ++ ")")
        -- the ONE vocabulary (Bytecode.arithOps); GLSL's spellings for
        -- every comparison coincide with sol's, != included
        cmps = [(n, n) | n <- cmpNames]

-- run one map over doubles (captured scalars as uniforms); Nothing on
-- any backend failure (caller falls to the JIT — the tier never fails
-- loudly, it declines)
gpuMapF64 :: GpuCtx -> String -> [Double] -> [Double] -> IO (Maybe [Double])
gpuMapF64 _ src us xs = do
  let n = length xs
  withCString src $ \csrc ->
    withArray (us ++ [0]) $ \pus -> -- pad so the array is never empty; C reads only nu
      withArray xs $ \pin ->
        allocaBytes (n * 8) $ \pout -> do
          r <- c_map csrc pus (fromIntegral (length us)) pin pout (fromIntegral n)
          if r /= 0
            then pure Nothing
            else Just <$> peekArray n pout
