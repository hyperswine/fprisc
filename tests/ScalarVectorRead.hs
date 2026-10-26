module Main where
import qualified Core.VectorRead as Read
import Core.Syntax
import Codegen.IR
import Codegen.Policy
import Codegen.Lower (lowerProgram,Prim(..))
import Codegen.Verify (verifyProgramWidth)
import Codegen.Eval
import Codegen.Target.Common (mangleName)
import Compiler.VectorABI
import Control.Monad (unless,forM_)
import Control.Exception (bracket)
import Foreign.Ptr (Ptr,nullPtr)
import Foreign.Storable (sizeOf)
import System.Directory (getTemporaryDirectory,removeFile,doesFileExist)
import System.IO (openTempFile,hPutStr,hClose)
import System.Process (readProcessWithExitCode)
import System.Exit (ExitCode(..))
import qualified Data.Map.Strict as M

check label ok=unless ok (error ("scalar vector reads: "++label))
right=either error id
app n=foldl CApp (CVar n)
hal=M.fromList [(Read.peekName op,Prim arity (Just ("fpr_g_"++mangleName (Read.peekName op)++"_call"++show arity)) Nothing)
              | op<-Read.reads,let arity=Read.indexArity op+1]
source=M.fromList [(show op,(if op==Read.Length then ["v"] else ["i","v"],
  app (Read.peekName op) (map CVar (if op==Read.Length then ["v"] else ["i","v"])))) | op<-Read.reads]
operations fn=[op | b<-fnBlocks fn,Instr _ op<-bInstrs b]
memory fn=any (\op->case op of OLoad {}->True;OLoadByte {}->True;_->False) (operations fn)
lower policy whole emitted entries=let (ir,failures)=lowerProgram policy M.empty whole emitted M.empty entries
  in if null failures then ir else error (show failures)

main=do
  let fast=lower m2Policy source source hal
      slow=lower (m2Policy {polVectorFast=False}) source source hal
  check "fast CFGs verify" (verifyProgramWidth W64 fast==Right ())
  check "fallback CFGs verify" (verifyProgramWidth W64 slow==Right ())
  check "all three reads use memory" (all memory (M.elems fast))
  check "disabled reads keep their C path" (all (not . memory) (M.elems slow))
  forM_ Read.reads $ \op->do
    let fn=fast M.! show op
        calls=[c | OCall c _<-operations fn]
    check ("one original C fallback for "++show op) (map calleeName calls==[Read.peekName op])
    check "fallback answers through a join" (any (not . null . bParams) [b | b<-fnBlocks fn,bId b/=fnEntry fn])
  let builtin=m2Policy {polProfile=Builtin,polFuel=False,polStackCheck=StackStatic}
  check "unsupported profiles keep C" (all (not . memory) (M.elems (lower builtin source source hal)))
  check "RV32 keeps its boxed-float C ABI" (all (not . memory) (M.elems (lower (m2Policy {polProfile=Rv32}) source source hal)))
  let override=M.adjust (\p->p {primEntry=Just "custom_peek"}) "$vec.at" hal
  check "custom runtime entry is not reinterpreted" (not (memory (lower m2Policy source source override M.! "At")))
  let shadow=M.insert "$vec.at" (["i","v"],CInt 99) source
  check "source function shadows the primitive" (not (memory (lower m2Policy shadow source hal M.! "At")))
  let trapped=M.singleton "trap" ([],app "$vec.at" [CErr "index first",CInt 0])
      ir=lower m2Policy trapped trapped hal
  check "index effects precede every memory guard" (ocResult (evalProgram ir "trap" [])==Left (Trap "index first"))
  let handle=M.singleton "trap" ([],app "$vec.at" [CMk 1 0 [],CErr "handle evaluation first"])
      handleIR=lower m2Policy handle handle hal
  check "both operands evaluate before index validation" (ocResult (evalProgram handleIR "trap" [])==Left (Trap "handle evaluation first"))
  abi
  putStrLn "Scalar vector reads: verified CFGs, C fallback/control/profile/shadowing boundaries, operand/trap order and native C layout contract PASS"

abi=do
  directory<-getTemporaryDirectory
  bracket (openTempFile directory "fpr-vector-abi") (\(path,_)->forM_ [path,path++".o"] $ \p->doesFileExist p >>= \exists->if exists then removeFile p else pure ()) $ \(path,h)->do
    let w=sizeOf (nullPtr::Ptr ())
        assertion expr n="_Static_assert("++expr++" == "++show n++", \""++expr++"\");\n"
        fields=[("offsetof(vec_t,len)",lengthOffset w),("offsetof(vec_t,ncols)",columnCountOffset w),
                ("offsetof(vec_t,kinds)",kindsOffset w),("offsetof(vec_t,cols)",columnsOffset w),
                ("offsetof(col_t,base)",columnBaseOffset w),("T_VEC",vectorTypeId),("VR_INT",intRep),("VR_FLT",floatRep)]
    hPutStr h ("#include \"fpr.h\"\n#include \"vec_layout.h\"\n"++concatMap (uncurry assertion) fields
      ++assertion "VK_INT" intKind++assertion "VK_F64" f64Kind++assertion "VK_F32" f32Kind)
    hClose h
    (code,_,err)<-readProcessWithExitCode "cc" ["-x","c","-std=c11","-I","runtime","-c",path,"-o",path++".o"] ""
    check ("runtime ABI agrees with the compiler: "++err) (code==ExitSuccess)
