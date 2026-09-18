-- Sol/Infer.hs — the HostedBytecode profile's inference SURFACE.
--
-- The engine is Infer.hs (inferTopsWith) — one unifier, one row
-- machinery, one operator-site resolver for every profile.  This
-- module is only what genuinely differs for sol:
--
--   * the primitive table below (the Txn Io doors `read`/`write` are
--     maximally generic here where the AOT tiers type them as MMIO;
--     Num.* is sol's numeric spelling; the float-literal splices
--     f64frombits/f32frombits land on Int -- tInt IS Numeric, so the
--     engine's width sites resolve to plain ops and every float
--     literal spells "the inexact side, please".  Vec/BStr/Handle are
--     typed by the injected prelude's signatures, not this table.)
--   * the profile flags: `> expr.` tops are inferred and rewritten
--     here (the AOT driver owns TEval itself); @paths type as URL
--     strings (the AOT tiers expand them structurally first); the
--     Mat4/Vec4 `*` elaboration stays off (sol's prelude has no
--     mulMM/mulMV).
--
-- This file was a ~1,000-line fork of Infer.hs; the un-forking is
-- docs/MEMORY-V2-PLAN.md's "de-fork the frontend" item made real.
module Sol.Infer (inferTops) where

import Infer (IProf (..), TEnv, Type (..), inferTopsWith, mono, scheme, sv, tBool, tInt, tList, tStr, tUnit, tcon)
import qualified Data.Map.Strict as M
import FPRISC (Name, STop)
import Struct (Sigs, Structs)

solProf :: IProf
solProf =
  IProf
    { ipBuiltins = solBuiltins,
      ipTopEvals = True,
      ipPathStr = True,
      ipMat4 = False
    }

-- the profile API Sol/Main.hs consumes: the engine's result minus the
-- inferred linearity shapes (sol's checker takes the declared-sig path)
inferTops :: Sigs -> Structs -> [STop] -> ([String], [(Name, String)], [(String, String)], [STop])
inferTops sigs structs tops =
  let (errs, notes, holes, _linsigs, tops') = inferTopsWith solProf sigs structs tops
   in (errs, notes, holes, tops')

solBuiltins :: TEnv
solBuiltins =
  M.fromList
    [ ("str", scheme [0] (TFn (sv 0) tStr)),
      ("strcat", mono (TFn tStr (TFn tStr tStr))),
      ("strlen", mono (TFn tStr tInt)),
      ("String.len", mono (TFn tStr tInt)),
      ("error", scheme [0] (TFn tStr (sv 0))),
      -- the Ok/Err tier: fallible primitives return Result, chained
      -- with |>?; the panicking spellings (parseInt, readPath) are
      -- PRELUDE sugar over these and type by inference
      ("Try.parseInt", mono (TFn tStr (tcon "Result" [tInt, tStr]))),
      ("Try.parseNum", mono (TFn tStr (tcon "Result" [tInt, tStr]))),
      ("Try.readPath", mono (TFn tStr (tcon "Result" [tStr, tStr]))),
      ("charAt", mono (TFn tStr (TFn tInt tInt))), -- returns the char CODE
      ("substr", mono (TFn tStr (TFn tInt (TFn tInt tStr)))),
      -- the O(n) string tier (VM.hs): what Str.split / indexOf / replace /
      -- upper / lower / trim / join dispatch to -- the preamble versions
      -- re-sliced the rest of the string per separator, which made
      -- Str.lines of a 100 KB file a minute's work
      ("strSplit", mono (TFn tInt (TFn tStr (tList tStr)))),
      ("strIndexOf", mono (TFn tStr (TFn tStr tInt))),
      ("strReplace", mono (TFn tStr (TFn tStr (TFn tStr tStr)))),
      ("strUpper", mono (TFn tStr tStr)),
      ("strLower", mono (TFn tStr tStr)),
      ("strTrim", mono (TFn tStr tStr)),
      ("strJoin", mono (TFn tStr (TFn (tList tStr) tStr))),
      ("strCmp", mono (TFn tStr (TFn tStr tInt))),
      ("strCodes", mono (TFn tStr (tList tInt))),
      ("chr", mono (TFn tInt tStr)),
      -- read/write: THE two HAL doors. What comes back (read) or is
      -- accepted (write) depends on the path/query value the HAL decodes,
      -- so both are maximally generic — the same stance `stat` already took.
      ("read", scheme [0, 1] (TFn (sv 0) (sv 1))),
      ("write", scheme [0, 1] (TFn (sv 0) (TFn (sv 1) tUnit))),
      -- the actor shim (VM.hs): same schemes as the AOT tier's table
      ("send", scheme [0] (TFn tInt (TFn (sv 0) (tcon "Result" [tUnit, tStr])))),
      ("sendLinear", scheme [0] (TFn tInt (TFn (sv 0) (tcon "Result" [tUnit, tStr])))),
      ("sendArc", scheme [0] (TFn tInt (TFn (sv 0) (tcon "Result" [tUnit, tStr])))),
      ("receive", scheme [0] (TFn tInt (sv 0))),
      ("receiveFrom", scheme [0] (TFn tInt (TFn tInt (sv 0)))),
      ("spawn", scheme [0] (TFn (TFn tInt (sv 0)) tInt)),
      -- the mailbox policy (spawnCap) and placement are accepted and
      -- ignored here: the shim's actors are Haskell threads with
      -- unbounded queues (docs/MAILBOX.md)
      ("spawnCap", scheme [0] (TFn tInt (TFn tInt (TFn (TFn tInt (sv 0)) tInt)))),
      ("spawnCapOn", scheme [0] (TFn tInt (TFn tInt (TFn tInt (TFn (TFn tInt (sv 0)) tInt))))),
      ("spawnOn", scheme [0] (TFn tInt (TFn (TFn tInt (sv 0)) tInt))),
      ("Sys.spawnApp", scheme [0] (TFn (TFn tInt (sv 0)) tInt)),
      ("timeNow", scheme [0] (TFn (sv 0) tInt)),
      ("Sys.memInfo", mono (TFn tInt (tList tInt))),
      ("myself", mono (TFn tInt tInt)),
      ("yield", scheme [0] (TFn tInt (sv 0))),
      ("kill", mono (TFn tInt tUnit)),
      ("drop", scheme [0] (TFn (sv 0) tUnit)),
      ("keep", scheme [0] (TFn (sv 0) (sv 0))),
      ("device", scheme [0] (TFn tStr (sv 0))),
      ("reg32", scheme [0, 1] (TFn (sv 0) (TFn tInt (sv 1)))),
      ("Sys.poolReset", scheme [0] (TFn tInt (sv 0))),
      ("Sys.sleepUs", mono (TFn tInt tUnit)),
      ("Sys.logAt", scheme [0] (TFn tInt (TFn tStr tUnit))),
      ("Sys.memStats", scheme [0] (TFn tInt (sv 0))),
      ("Num.div", mono (TFn tInt (TFn tInt tInt))), -- tInt IS the Numeric type
      ("Num.sqrt", mono (TFn tInt tInt)),
      ("Num.floor", mono (TFn tInt tInt)),
      ("Num.round", mono (TFn tInt tInt)),
      -- the float-literal splices: Int-is-Numeric, no width vocabulary
      ("f64frombits", mono (TFn tInt (TFn tInt tInt))),
      ("f32frombits", mono (TFn tInt tInt)),
      ("!", scheme [0, 1] (TFn (sv 0) (TFn tInt (sv 1)))), -- indexing; builtin-overloaded List/Vector — candidate for an Index sig
      ("map", scheme [0, 1] (TFn (TFn (sv 0) (sv 1)) (TFn (tList (sv 0)) (tList (sv 1))))),
      ("filter", scheme [0] (TFn (TFn (sv 0) tBool) (TFn (tList (sv 0)) (tList (sv 0))))),
      ("foldl", scheme [0, 1] (TFn (TFn (sv 1) (TFn (sv 0) (sv 1))) (TFn (sv 1) (TFn (tList (sv 0)) (sv 1)))))
    ]
