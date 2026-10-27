module Main where
import Compiler.Options
import Compiler.CommandLine
import Codegen (tgtName)
import Control.Monad (forM_,unless)

require :: Bool -> String -> IO ()
require ok message=unless ok (error message)
options :: [(String,String)] -> CompilerOptions
options values=either (error . show) id (parseCompilerOptions (`lookup` values))
identity :: [(String,String)] -> String
identity=codegenCacheIdentity . codegenOptions . options
main :: IO ()
main=do
  let baseline=identity []
  forM_ [[],[("FPR_TYPED_IR_BACKEND","")],[("FPR_TYPED_IR_BACKEND","mixed")],
         [("FPR_NO_RECEIVE_TURNS","0")],[("FPR_NO_INLINE","unexpected")],
         [("FPR_TYPED_IR_SELF_LOOPS","1")]] $ \values ->
    require (identity values==baseline) ("default alias changes codegen identity: "++show values)
  forM_ ["legacy","0","off"] $ \value -> require
    (parseCompilerOptions (\n -> if n=="FPR_TYPED_IR_BACKEND" then Just value else Nothing)==Left RetiredBackend)
    ("retired backend accepted: "++value)
  require (parseCompilerOptions (\n -> if n=="FPR_TYPED_IR_BACKEND" then Just "typo" else Nothing)==Left (UnknownBackend "typo")) "unknown backend accepted"
  -- Every code-affecting environment control must distinguish an executable
  -- cache entry. The receive-turn control was absent from Build's old list.
  forM_ ([ ("FPR_NO_"++name,"1") | name<-
    ["PIPELINE_INLINE","REUSE","VEC_FUSE","VEC_SIMD","SCALAR_WORKERS","FIELD_WORKERS",
     "F64_INLINE","INLINE","VEC_PEEK","VEC_FAST","SPEC","INDEXED_MEMORY","RECEIVE_TURNS","LOOP_REGIONS","CALL_REGIONS"]]
    ++ [("FPR_TYPED_IR_"++name,value) | (name,value)<-
      [("BACKEND","1"),("STRICT","all"),("SELF_LOOPS","0"),("FP_POOL","0"),
       ("SHALLOW_STACK","1"),("FORWARD_PARAMS","1"),("ENTRY_ARGS","1"),
       ("SPLIT_ENTRY","1"),("SHRINK_WRAP","1"),("LINK_PAIRS","0"),("LOOP_MOTION","1")]]) $ \value ->
    require (identity [value]/=baseline) ("missing cache control: "++show value)
  forM_ ["FPR_TYPED_IR","FPR_RECEIVE_NOTES","FPRC_APPLY","FPR_PRECOND_NOTES",
         "FPR_UNSAFE_SUGGEST","FPR_DUMP_CORE","FPRC_NATIVE_INSNS"] $ \name ->
    require (identity [(name,"1")]==baseline) ("diagnostic alters codegen identity: "++name)
  let defaults=options []
      native=nativeOptions (codegenOptions defaults)
  require (nativeOptionFlags True native=="mixed-fpregs" && nativeOptionFlags False native=="mixed") "default unit native tag changed"
  require (optimizationFlags (codegenOptions defaults)=="" && vectorOptionFlags (codegenOptions defaults)=="") "default optimization tag changed"
  require (nativeStrict (nativeOptions (codegenOptions (options [("FPR_TYPED_IR_STRICT",",f,,g,")])) )==StrictNames ["f","g"]) "strict names parsing"
  require (not (cgInline (codegenOptions (disableInlining True defaults)))) "CLI inline disable ignored"
  require (not (cgInline (codegenOptions (disableInlining False (options [("FPR_NO_INLINE","1")]))))) "CLI re-enabled disabled inlining"
  require (driverForeign (driverOptions (options [("FPR_FOREIGN",":one::two:")]))==["one","two"]) "foreign path normalization"
  let cli=parseCompileArguments ["--check-only","--lib","--no-inline","module.fpr","/dev/null"]
  require (oCheckOnly cli && oLib cli && oNoInline cli && oFiles cli==["module.fpr","/dev/null"]) "typed CLI product lost module/check-only/inline flags"
  forM_ [("--remarks","hot"),("--remarks=all","all"),("--remarks=json","json")] $ \(flag,mode)->do
    let reported=parseCompileArguments [flag,"module.fpr","out.s"]
    require (oRemarks reported==Just mode && oFiles reported==["module.fpr","out.s"]) "remark flag became an input file"
  forM_ [["--host=esp-idf","--system=posix"],["--system=posix","--host=esp-idf"]] $ \args -> do
    let host=parseCompileArguments args
    require (oSystem host==Just "posix" && oHost host==Just "esp-idf" && tgtName (oTarget host)=="rv32") "host flags depend on order"
  let cross=parseCompileArguments ["--system=posix","--target=x64mac"]
      explicit=parseCompileArguments ["--host=esp-idf","--target=rv64"]
  require (oBase cross && oX64 cross && oX64Mac cross && oTargetFlag cross) "explicit hosted cross target replaced"
  require (tgtName (oTarget explicit)=="rv64") "host resolution swallowed an explicit target before its diagnostic"
  require (oExports (parseCompileArguments ["--export=f,g:c,,"])==[("f","f"),("g","c")]) "export syntax changed"
  putStrLn "Compiler options: canonical aliases, refusal boundaries, codegen/cache controls, diagnostic independence and CLI precedence passed"
