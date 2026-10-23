-- The replacement data owner must preserve complete old native data text,
-- including interning, export scope, ARC sections and native-only nullaries.
import Codegen.NativeData
import Codegen.IR (Width(..))
import Codegen.Target.Common (ObjectFormat(..))
import FPRISC (Core(..))
import Modules (ModExport(..))
import Control.Monad (forM_,unless)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

main :: IO ()
main = do
 golden <- M.fromList . map read . lines <$> readFile "tests/typed_ir/native_data.golden"
 let prog=M.fromList [("mk",(["x"],CMk 42 1 [CVar "x"])),("empty",([],CMk 42 0 [])),
                      ("hidden",([],CMk 43 2 [])),("use",(["x"],CVar "hidden")),("idn@123",(["x"],CVar "x"))]
     emitted=M.delete "hidden" prog;visible=M.keysSet prog
     exports=[ModExport "root-hash" "empty" "empty" 0 "",
              ModExport "root-hash" "mk" "mk" 1 "checked \x3bb \xe9\x00",
              ModExport "unit-hash" "idn" "idn@123" 1 ""]
 -- These complete objects were frozen from the preceding generator before
 -- integration. Keep this independent of Codegen.emitProgramWith.
 forM_ [(ELF,W64,False),(ELF,W32,False),(MachO,W64,False),(ELF,W64,True)] $ \(fmt,width,arc) ->
  forM_ [False,True] $ \weak -> do
   let key=show (fmt,width,arc,weak)
       actual=emitStaticData fmt width arc weak exports visible emitted (S.singleton (43,2))
   unless (M.lookup key golden==Just actual) $
    error ("native static data differs from predecessor snapshot: "++key)
 putStrLn "Native static data: exact prior text for RV32/RV64/A64 Mach-O/x64/ARC, weak/strong visibility, PAP arity, module schema/strings, UTF-8/raw bytes and elided native nullaries PASS"
