{-# LANGUAGE LambdaCase #-}
-- Static objects have a native owner independent of scalar/kernel rendering.
-- Keep the existing PAP, immortal constructor and module table layouts, and
-- preserve module string interning/order while the text generator is removed.
module Codegen.NativeData (emitStaticData,emitStaticDataWithSymbols) where

import Codegen.IR (Width(..),Name)
import Codegen.Target.Common (ObjectFormat, dataSyntax, mangleName,SymbolPolicy,publicSymbols,visibilityFor,visibilityLines,WeakSpelling(..))
import Core.Syntax (Core(..),Prog)
import Modules (ModExport(..))
import Workers (internalWorker)
import Control.Monad.State.Strict
import Data.List (intercalate)
import Data.Bits (shiftR,(.&.))
import Data.Char (ord)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

emitStaticData :: ObjectFormat -> Width -> Bool -> Bool -> [ModExport] -> S.Set Name -> Prog -> S.Set (Int,Int) -> [String]
emitStaticData fmt width arc weak exports visible=emitStaticDataWithSymbols fmt width arc weak exports (publicSymbols visible)

emitStaticDataWithSymbols :: ObjectFormat -> Width -> Bool -> Bool -> [ModExport] -> SymbolPolicy -> Prog -> S.Set (Int,Int) -> [String]
emitStaticDataWithSymbols fmt width arc weak exports symbols emitted referenced = dataSyntax fmt $
  ["    .section .rodata",""] ++ concatMap object (M.toList emitted)
  ++ ["    .section .rodata" | arc] ++ table
  ++ ["    .section .rodata" | arc,not (null table)]
  ++ concatMap string (M.toList strings)
  ++ ["    .section .rodata" | arc]
  ++ concatMap nullary (S.toList (S.union referenced (S.fromList (concatMap (scan . snd) (M.elems emitted)))))
  where
    dir = if width==W32 then ".word" else ".quad"
    object (n,(ps,_))
      | null ps || internalWorker n = []
      | otherwise =
          ["    .section .rodata.fpr_obj_"++mangleName n++",\"a\",@progbits" | arc]
          ++ ["# static-pap: "++n,"    .balign 8"]
          ++ visibilityLines fmt WeakDirective (visibilityFor weak symbols n) ("fpr_obj_"++mangleName n)
          ++ ["fpr_obj_"++mangleName n++":","    .long 9001","    .long 0",
              "    "++dir++" fpr_fn_"++mangleName n,"    "++dir++" "++show (length ps),"    "++dir++" 0",""]
    (table,(_,strings)) = runState moduleTable (0 :: Int,M.empty)
    intern :: String -> State (Int,M.Map String String) String
    intern s = do
      (next,known) <- get
      case M.lookup s known of
        Just label -> pure label
        Nothing -> do
          let label=".Lstr"++show next
          put (next+1,M.insert s label known)
          pure label
    moduleTable
      | null exports || arc = pure []
      | otherwise = do
          rows <- concat <$> mapM row [e | e<-exports,meArity e>=1]
          root <- intern (case [meHash e | e<-exports,meQual e==meName e || meQual e=="$precond0."++meName e] of h:_->h;[]->"")
          pure $ ["    .balign 8","    .globl fpr_modtab","fpr_modtab:",
                  "    "++dir++" 0x4650524d","    "++dir++" 1","    "++dir++" "++root]
            ++ rows ++ ["    "++dir++" 0",""]
    row e = do
      hash <- intern (meHash e);name <- intern (meName e);interface <- intern (meInterface e)
      pure ["    "++dir++" "++hash,"    "++dir++" "++name,
            "    "++dir++" fpr_obj_"++mangleName (meQual e),"    "++dir++" "++interface]
    string (content,label) =
      let bytes=utf8Bytes content
      in ["    .section .rodata.fpr_str"++filter (/='.') label++",\"a\",@progbits" | arc]
         ++ ["    .balign 8",label++":","    .long 9000","    .long 0","    "++dir++" "++show (length bytes)]
         ++ byteLines bytes ++ [""]
    byteLines []=[]
    byteLines xs=let (a,b)=splitAt 16 xs in ("    .byte "++intercalate ", " (map show a)):byteLines b
    utf8Bytes :: String -> [Int]
    utf8Bytes=concatMap encode
      where
        encode c
          | v<0x100=[v]
          | v<0x800=[0xC0+shiftR v 6,0x80+(v .&. 0x3F)]
          | v<0x10000=[0xE0+shiftR v 12,0x80+(shiftR v 6 .&. 0x3F),0x80+(v .&. 0x3F)]
          | otherwise=[0xF0+shiftR v 18,0x80+(shiftR v 12 .&. 0x3F),0x80+(shiftR v 6 .&. 0x3F),0x80+(v .&. 0x3F)]
          where v=ord c
    nullary (t,v)=["    .balign 8",".Lnul_"++show t++"_"++show v++":","    .long "++show t,"    .long "++show v,""]
    scan = \case
      CMk t v [] -> [(t,v)]
      CMk _ _ fs -> concatMap scan fs
      CApp a b -> scan a++scan b
      CLam _ b -> scan b
      CLet _ a b -> scan a++scan b
      CIf a b c -> scan a++scan b++scan c
      CTagEq _ _ x -> scan x
      CProj _ x -> scan x
      _ -> []
