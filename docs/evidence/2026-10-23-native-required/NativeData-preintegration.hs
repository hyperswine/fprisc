-- The replacement data owner must preserve complete old native data text,
-- including interning, export scope, ARC sections and native-only nullaries.
import Codegen
import Codegen.NativeData
import Codegen.IR (Width(..))
import Codegen.Policy
import Codegen.Target.Common (noTune)
import Codegen.Target.A64 (ObjectFormat(..),HartAccess(..))
import Codegen.Target.RV (RVHart(..))
import FPRISC (Core(..))
import Modules (ModExport(..))
import Control.Monad (forM_,unless)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

main :: IO ()
main = do
 writeFile "/private/tmp/fpr-native-data-goldens" ""
 let prog=M.fromList [("mk",(["x"],CMk 42 1 [CVar "x"])),("empty",([],CMk 42 0 [])),
                      ("hidden",([],CMk 43 2 [])),("use",(["x"],CVar "hidden")),("idn@123",(["x"],CVar "x"))]
     elided=S.singleton "hidden";emitted=M.delete "hidden" prog;visible=M.keysSet prog
     exports=[ModExport "root-hash" "empty" "empty" 0 "",
              ModExport "root-hash" "mk" "mk" 1 "checked \x3bb \xe9\x00",
              ModExport "unit-hash" "idn" "idn@123" 1 ""]
 forM_ [(ELF,W64,False,DirectRV W64 HartTp),(ELF,W32,False,DirectRV W32 HartTp),
        (MachO,W64,False,DirectA64 MachO HartX28),(ELF,W64,False,DirectX64),
        (ELF,W64,True,DirectRV W64 HartTp)] $ \(fmt,width,arc,backend) ->
  forM_ [False,True] $ \weak -> do
   let policy=if arc then m2Policy {polProfile=BuiltinArc,polFuel=False,polStackCheck=StackStatic}
              else m2Policy {polProfile=if width==W32 then Rv32 else HostedBase}
       mode=NativeMode PerFunction StrictAll "data-owner" (Just backend) False noTune False True
       base=if width==W32 then rv32 else rv64
       target=base {tgtNative=Just mode,tgtPolicy=policy,tgtArc=arc,tgtWeak=weak,
                    tgtScalarFast=False,tgtFieldWorkers=False,tgtScalarWorkers=False,tgtReuse=False}
       old=emitProgramWith target False False exports M.empty visible elided prog
       actual=emitStaticData fmt width arc weak exports visible emitted (S.singleton (43,2))
   unless (null (emFallbacks old)) (error (show (emFallbacks old)))
   unless (emDirectData old==Just actual) $ do
    error ("native data changed: "++show (fmt,width,arc,weak))
   appendFile "/private/tmp/fpr-native-data-goldens" (show (show (fmt,width,arc,weak),maybe [] id (emDirectData old))++"\n")
 putStrLn "Native static data: exact prior text for RV32/RV64/A64 Mach-O/x64/ARC, weak/strong visibility, PAP arity, module schema/strings, UTF-8/raw bytes and elided native nullaries PASS"
