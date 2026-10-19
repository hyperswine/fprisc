-- raGuard (X64.hs): frames whose saved-ra word is not the x64 return
-- address are refused at lowering time (tests/check_vector_fallback_frames.py).
import X64 (lowerX64)
import Control.Exception (ErrorCall (..), evaluate, try)
import Control.Monad (unless)
import Data.List (isInfixOf)

lowered :: [String] -> IO (Either String Int)
lowered body = do
  r <- try (evaluate (length (lowerX64 (unlines ("    .text" : "f:" : map indent body)))))
  pure (either (\(ErrorCall m) -> Left m) Right r)
  where indent l = if last l == ':' then l else "    " ++ l -- labels stay at column 0

accepts, refuses :: String -> String -> [String] -> IO ()
accepts name _ body = lowered body >>= either (\m -> error (name ++ ": refused: " ++ m)) (const (pure ()))
refuses name needle body = lowered body >>= \r -> case r of
  Left m -> unless (needle `isInfixOf` m) (error (name ++ ": wrong refusal: " ++ m))
  Right _ -> error (name ++ ": accepted")

main :: IO ()
main = do
  -- the shapes Codegen emits
  accepts "ra at the top word" "" ["addi sp, sp, -48", "sd ra, 40(sp)", "sd a0, 8(sp)", "sd a1, 32(sp)", "call g", "ld ra, 40(sp)", "addi sp, sp, 48", "ret"]
  accepts "fallback frame after the fix" "" ["addi sp, sp, -32", "sd ra, 24(sp)", "sd a0, 8(sp)", "sd a1, 16(sp)", "la a0, fpr_obj_g", "call fpr_apply", "ld ra, 24(sp)", "addi sp, sp, 32", "j fpr_vec_map"]
  accepts "staging frame without ra" "" ["addi sp, sp, -16", "sd a0, 8(sp)", "sd a1, 0(sp)", "addi sp, sp, 16", "ret"]
  accepts "frame forgotten at a label" "" ["addi sp, sp, -32", "sd ra, 24(sp)", "beqz a0, .L1", "ret", ".L1:", "sd a0, 24(sp)", "ret"]
  -- the pre-fix fallback frames
  refuses "ra at the bottom word" "ra must be saved at the frame's top word" ["addi sp, sp, -32", "sd ra, 0(sp)", "sd a0, 8(sp)", "sd a1, 16(sp)", "sd a2, 24(sp)"]
  refuses "argument over the saved ra" "overwrites the saved-ra word" ["addi sp, sp, -32", "sd ra, 24(sp)", "sd a2, 24(sp)"]
  refuses "narrow store over the saved ra" "overwrites the saved-ra word" ["addi sp, sp, -32", "sd ra, 24(sp)", "sw a2, 28(sp)"]
  putStrLn "x64 raGuard: top-word ra frames accepted; misplaced or overwritten ra refused: PASS"
