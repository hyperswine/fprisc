module EmitRVFrames (main) where

-- Direct IR entry/return oracle. Large objects keep every input-derived value
-- live until allocation; no text generator or source optimization is involved.
import qualified Codegen.IR as I
import Codegen.Policy
import Codegen.Target.RV
import Codegen.Target.Common (nfLines)
import Codegen.Verify (verifyProgramWidth)
import Control.Monad (forM_)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import System.Environment

main :: IO ()
main = do
  [bits,loopMode,out] <- getArgs
  let width = if bits=="32" then I.W32 else I.W64
      policy = m2Policy {polProfile=if bits=="32" then Rv32 else HostedBase}
      cfg = RVConfig width policy HartTp (S.fromList ["large","tailLarge","loopLarge"]) False (loopMode=="1")
      params = [(I.VId n,I.TVal) | n<-[0..63]]
      fn name count tailing looping =
        let idn n = I.VId n
            result = 64+3*count
            call = I.Callee "oracle_id" (I.Foreign "oracle_id") [I.TVal,I.TVal] I.TVal
            entry = [I.Instr Nothing I.OStackCheck,I.Instr Nothing I.OSafepoint]
            values = concat [[I.Instr (Just (idn (64+3*n),I.TInt)) (I.OConstInt (fromIntegral n)),
                              I.Instr (Just (idn (65+3*n),I.TVal)) (I.OTag (idn (64+3*n))),
                              I.Instr (Just (idn (66+3*n),I.TVal)) (I.OCall call [idn (n `mod` 64),idn (65+3*n)])]
                              | n<-[0..count-1]]
            object = I.Instr (Just (idn result,I.TVal)) (I.OMake 42 count [idn (66+3*n) | n<-[0..count-1]])
            extra = [I.Instr (Just (idn (result+1),I.TInt)) (I.OUntag (idn 0)),
                     I.Instr (Just (idn (result+2),I.TInt)) (I.OConstInt 0),
                     I.Instr (Just (idn (result+3),I.TInt)) (I.OConstInt 1),
                     I.Instr (Just (idn (result+4),I.TPred)) (I.OCmp I.Gt (idn (result+1)) (idn (result+2)))]
            term | looping = I.TCondBr (idn (result+4)) (I.BId 1) [] (I.BId 2) []
                 | tailing = I.TTailCall (I.Callee "oracle_tail" (I.Foreign "oracle_tail") [I.TVal] I.TVal) [idn result]
                 | otherwise = I.TRet (idn result)
            branches = if not looping then [] else
              [I.Block (I.BId 1) []
                [I.Instr (Just (idn (result+5),I.TInt)) (I.OKernelArith I.Sub (idn (result+1)) (idn (result+3))),
                 I.Instr (Just (idn (result+6),I.TVal)) (I.OTag (idn (result+5)))]
                (I.TTailCall (I.Callee name I.Local (replicate 64 I.TVal) I.TVal) (idn (result+6):map idn [1..63])),
               I.Block (I.BId 2) [] [] (I.TRet (idn result))]
        in I.Fn name (map (("p"++).show) [0..63::Int]) I.TVal (I.BId 0)
          (I.Block (I.BId 0) params (entry++values++[object]++if looping then extra else []) term:branches)
      fns = [fn "large" 9000 False False,fn "tailLarge" 512 True False,fn "loopLarge" 512 False True]
  either error pure (verifyProgramWidth width (M.fromList [(I.fnName f,f)|f<-fns]))
  chosen <- mapM (either error pure . emitFnRV cfg) fns
  forM_ chosen $ \f -> putStrLn (head (nfLines f))
  -- the ticks' register-saving slow path, as Codegen emits it once per unit
  writeFile out (unlines (".text":concatMap nfLines chosen ++ fuelSaveWrapper (cfgWidth cfg)))
