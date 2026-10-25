-- The replacement data owner must preserve complete old native data text,
-- including interning, export scope, ARC sections and native-only nullaries.
import Codegen.NativeData
import Codegen.IR (Width(..))
import Codegen.Target.Common (ObjectFormat(..),symbolPolicy,visibilityFor,Visibility(..))
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
 let policy=either error id (symbolPolicy (S.singleton "mk") (S.singleton "idn@123"))
     hidden fmt=emitStaticDataWithSymbols fmt W64 False True [] policy prog S.empty
 unless (visibilityFor True policy "mk"==WeakSymbol && visibilityFor True policy "idn@123"==HiddenSymbol
   && visibilityFor False policy "empty"==UnitLocal
   && "    .globl fpr_obj_idn_x40123" `elem` hidden ELF
   && "    .hidden fpr_obj_idn_x40123" `elem` hidden ELF
   && "    .globl _fpr_obj_idn_x40123" `elem` hidden MachO
   && "    .private_extern _fpr_obj_idn_x40123" `elem` hidden MachO) $
   error "private static PAP visibility disagrees with its code contract"
 case symbolPolicy (S.singleton "mk") (S.singleton "mk") of
  Left _->pure ()
  Right _->error "overlapping public/private visibility accepted"
 putStrLn "Native symbol policy: disjoint public/private authority, strong hidden PAPs, ELF visibility and Mach-O private extern spelling PASS"
