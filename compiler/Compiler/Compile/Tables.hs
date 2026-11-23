-- Compiler.Compile.Tables -- root-image static metadata tables emitted into
-- the root assembly: constructor names (fpr_contab), constructor/record field
-- counts (fpr_layout_table), and raw F64/F32/I64 field masks (fpr_layout_raw).
module Compiler.Compile.Tables (renderRootTables) where

import Data.Char (ord)
import Data.List (intercalate)
import qualified Data.Map.Strict as M

-- Render the root-image metadata tables (constructor names, layout counts,
-- and raw-field masks) for inclusion in the root assembly unit.
renderRootTables
  :: Bool -- ^ builtin profile
  -> Bool -- ^ library unit (--lib)
  -> Bool -- ^ plugin/module unit (--plugin)
  -> String -- ^ word directive (".word" or ".quad")
  -> M.Map String (Int, Int, Int) -- ^ consAll: name -> (tid, variant, arity)
  -> M.Map [String] Int -- ^ shapes: sorted field names -> shape id
  -> M.Map (Int, Int) (Integer, Integer, Integer) -- ^ rawAll: (tid, var) -> (raw, f32, i64)
  -> [String]
renderRootTables isBuiltin isLib isPlugin dir consAll shapes rawAll =
  lines conTab ++ lines layoutTab ++ lines layoutRawTab
  where
    conRows =
      [ (tid, var, ar, reverse (takeWhile (/= '.') (reverse (takeWhile (/= '@') c))))
        | (c, (tid, var, ar)) <- M.toList consAll, tid >= 0x20000000
      ]
      ++ [ (sid, 0, length fs, intercalate "," fs) | (fs, sid) <- M.toList shapes ]

    conTab
      | isBuiltin || isLib || isPlugin = ""
      | otherwise = unlines $
          [ "", "# constructor names, for render", "    .section .rodata", "    .balign 8" ]
            ++ concat
              [ [ ".Lfprcon" ++ show i ++ ":", "    .byte " ++ intercalate ", " (map (show . ord) nm ++ ["0"]) ]
                | (i, (_, _, _, nm)) <- zip [0 :: Int ..] conRows
              ]
            ++ [ "    .balign 8", "    .globl fpr_contab", "fpr_contab:" ]
            ++ concat
              [ [ "    " ++ dir ++ " " ++ show tid, "    " ++ dir ++ " " ++ show var,
                  "    " ++ dir ++ " " ++ show ar, "    " ++ dir ++ " .Lfprcon" ++ show i ]
                | (i, (tid, var, ar, _)) <- zip [0 :: Int ..] conRows
              ]
            ++ [ "    " ++ dir ++ " 0", "    " ++ dir ++ " 0", "    " ++ dir ++ " 0", "    " ++ dir ++ " 0", "" ]

    layoutRows = M.toList (M.fromList
      ( [ ((tid, var), ar) | (_, (tid, var, ar)) <- M.toList consAll, tid >= 0 ]
        ++ concat [ [ ((sid, length fs), length fs), ((sid, 0), length fs) ]
                  | (fs, sid) <- M.toList shapes ] ))

    layoutTab
      | isBuiltin || isLib = ""
      | otherwise = unlines $
          [ "", "# constructor layout: count, then (tid, variant, fields) triples",
            "    .balign 8", "    .globl fpr_layout_table", "fpr_layout_table:", ".Lfpr_layout_table:" ]
            ++ [ "    " ++ dir ++ " " ++ show (length layoutRows) ]
            ++ concat
              [ [ "    " ++ dir ++ " " ++ show tid, "    " ++ dir ++ " " ++ show var, "    " ++ dir ++ " " ++ show ar ]
                | ((tid, var), ar) <- layoutRows
              ]

    rawRows = [ (k, m) | (k, m) <- M.toList rawAll, k `M.member` M.fromList layoutRows ]

    layoutRawTab
      | isBuiltin || isLib || isPlugin || dir /= ".quad" = ""
      | otherwise = unlines $
          [ "", "# raw constructor fields: count, then (tid, variant, raw mask, F32 mask, I64 mask) rows",
            "    .balign 8", "    .globl fpr_layout_raw", "fpr_layout_raw:" ]
            ++ [ "    " ++ dir ++ " " ++ show (length rawRows) ]
            ++ concat
              [ [ "    " ++ dir ++ " " ++ show tid, "    " ++ dir ++ " " ++ show var,
                  "    " ++ dir ++ " " ++ show m, "    " ++ dir ++ " " ++ show f32, "    " ++ dir ++ " " ++ show i64 ]
                | ((tid, var), (m, f32, i64)) <- rawRows
              ]
