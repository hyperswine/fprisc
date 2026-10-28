module Main where
import Core.Syntax
import Codegen.IR
import Codegen.Policy
import Codegen.Lower (lowerProgram,Prim(..))
import Codegen.Verify (verifyProgramWidth)
import Codegen.Eval
import Control.Monad (unless,forM_)
import Control.Exception (bracket)
import Foreign.Ptr (Ptr,nullPtr)
import Foreign.Storable (sizeOf)
import System.Directory (getTemporaryDirectory,removeFile,doesFileExist)
import System.IO (openTempFile,hPutStr,hClose)
import System.Process (readProcessWithExitCode)
import System.Exit (ExitCode(..))
import qualified Data.Map.Strict as M

check label ok=unless ok (error ("string reads: "++label))
right=either error id
app n=foldl CApp (CVar n)
hal=M.fromList [("strlen",Prim 1 (Just "fpr_g_strlen_call1") Nothing),
                ("charAt",Prim 2 (Just "fpr_g_charAt_call2") Nothing)]
source=M.fromList [("Length",(["s"],app "strlen" [CVar "s"])),
                   ("At",(["s","i"],app "charAt" [CVar "s",CVar "i"]))]
operations fn=[op | b<-fnBlocks fn,Instr _ op<-bInstrs b]
memory fn=any (\op->case op of OLoad {}->True;OLoadByte {}->True;_->False) (operations fn)
lower policy whole emitted entries=let (ir,failures)=lowerProgram policy M.empty whole emitted M.empty entries
  in if null failures then ir else error (show failures)

main=do
  let fast=lower m2Policy source source hal
      slow=lower (m2Policy {polStringFast=False}) source source hal
  check "fast CFGs verify" (verifyProgramWidth W64 fast==Right ())
  check "fallback CFGs verify" (verifyProgramWidth W64 slow==Right ())
  check "both reads use memory" (all memory (M.elems fast))
  check "disabled reads keep their C path" (all (not . memory) (M.elems slow))
  forM_ ["strlen","charAt"] $ \name->do
    let fn=fast M.! (if name=="strlen" then "Length" else "At")
        calls=[c | OCall c _<-operations fn]
    check ("one original C fallback for "++name) (map calleeName calls==[name])
    check "fallback answers through a join" (any (not . null . bParams) [b | b<-fnBlocks fn,bId b/=fnEntry fn])
  let builtin=m2Policy {polProfile=Builtin,polFuel=False,polStackCheck=StackStatic}
  check "unsupported profiles keep C" (all (not . memory) (M.elems (lower builtin source source hal)))
  check "RV32 keeps its managed-word contract" (all (not . memory) (M.elems (lower (m2Policy {polProfile=Rv32}) source source hal)))
  let override=M.adjust (\p->p {primEntry=Just "custom_strlen"}) "strlen" hal
  check "custom runtime entry is not reinterpreted" (not (memory (lower m2Policy source source override M.! "Length")))
  let shadow=M.insert "strlen" (["s"],CInt 99) source
  check "source function shadows the primitive" (not (memory (lower m2Policy shadow source hal M.! "Length")))
  let trapped=M.singleton "trap" ([],app "strlen" [CErr "string first"])
      ir=lower m2Policy trapped trapped hal
  check "string effects precede every memory guard" (ocResult (evalProgram ir "trap" [])==Left (Trap "string first"))
  let order=M.singleton "trap" ([],app "charAt" [CMk 1 0 [],CErr "index second"])
      orderIR=lower m2Policy order order hal
  check "both operands evaluate before the bounds guards" (ocResult (evalProgram orderIR "trap" [])==Left (Trap "index second"))
  abi
  putStrLn "String reads: verified CFGs, C fallback/control/profile/shadowing boundaries, operand/trap order and native C layout contract PASS"

abi=do
  directory<-getTemporaryDirectory
  bracket (openTempFile directory "fpr-string-abi") (\(path,_)->forM_ [path,path++".o"] $ \p->doesFileExist p >>= \exists->if exists then removeFile p else pure ()) $ \(path,h)->do
    let w=sizeOf (nullPtr::Ptr ())
        assertion expr n="_Static_assert("++expr++" == "++show n++", \""++expr++"\");\n"
        fields=[("offsetof(str_t,len)",8),("offsetof(str_t,bytes)",8+w),("T_STR",9000)]
    hPutStr h ("#include <stddef.h>\n#include \"fpr.h\"\n"++concatMap (uncurry assertion) fields)
    hClose h
    (code,_,err)<-readProcessWithExitCode "cc" ["-x","c","-std=c11","-I","runtime","-c",path,"-o",path++".o"] ""
    check ("runtime ABI agrees with the compiler: "++err) (code==ExitSuccess)
