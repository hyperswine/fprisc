-- Command-line syntax and host/target resolution. Environment modes have a
-- separate typed owner in Compiler.Options; Compile consumes both products.
module Compiler.CommandLine (CompileArguments(..), parseCompileArguments) where
import Codegen (Target,rv32,rv64,tgtName)
import Data.List (isPrefixOf)
import qualified System.Info

data CompileArguments = CompileArguments
  { oTarget :: Target,
    oTargetFlag :: Bool, -- a --target= was given (so a host may not quietly replace it)
    oBuiltin :: Bool,
    oBase :: Bool, -- the posix SYSTEM: a hosted executable on this machine (machine/posix); the ISA is the build host's
    oSystem :: Maybe String, -- --system=bare-metal|qos-native|qos-portable|posix (docs/2026-09-19-PROFILES.md)
    oHost :: Maybe String, -- the posix system's HOST: Nothing is this machine (unix); Just "esp-idf" an ESP32 board (--host=)
    oProfileFlag :: Maybe String, -- --profile=builtin|base|extbase|sol, when the file does not say
    oArc :: Bool,
    oRaw :: Bool, -- a RAW unit: allocation-free, no ownership instrumentation (Arc.lowerRaw)
    oLib :: Bool, -- a LIBRARY unit: the file is compiled as an imported module (names qualified), no main, weak shared stubs
    oExports :: [(String, String)], -- C-callable trampolines: (fpr function, C symbol)
    oHardFloat :: Bool, -- exports follow the lp64d ABI (floats in fa0..); default lp64, soft
    oA64 :: Bool, -- select the direct typed AArch64 backend
    oA64Mac :: Bool, -- AArch64 with Mach-O syntax (macOS): _sym, @PAGE, TLV
    oX64 :: Bool, -- select the direct typed x86-64 backend (SysV)
    oX64Mac :: Bool, -- x86-64 with Mach-O syntax (macOS): _sym, L locals, TLV cells
    oQosApp :: Bool, -- qx64: QOS-x86_64 app image (plain-global cells, no TLS)
    oQosSingle :: Bool, -- qa64single: global hart cell for hosts without TP-relative TLS
    oPlugin :: Bool, -- emit root binds in fpr_modtab for a loadable plugin
    oRvv :: Bool,
    oStdCheck :: Bool, -- run the std proof pass (StdBridge + StdCheck) and stop
    oSol :: Bool, -- the HostedBytecode/sol VIEW of the one grammar: `>` top-level eval accepted (auto-on for .sol input)
    oPrelude :: Maybe FilePath,
    oNoSafety :: Bool,
    oFiles :: [FilePath],
    oForeign :: [FilePath], -- --foreign=FILE: the SYSTEM's primitive declarations (signatures only)
    oNoInline :: Bool, -- --no-inline / FPR_NO_INLINE=1: base code keeps every call (debugging, WCET comparison)
    oCost :: Bool, -- --cost: print every root function's work/alloc equations (Cost.hs), then continue
    oCheckOnly :: Bool, -- check libraries/modules without an executable entry point
    oManifest :: Maybe FilePath, -- --manifest=FILE: judge the root functions against a target manifest (Manifest.hs)
    oRemarks :: Maybe String -- advisory reporting; validated separately, never a codegen/cache option
  }

parseCompileArguments :: [String] -> CompileArguments
parseCompileArguments = resolveHost . foldl step defaults
  where
    defaults = CompileArguments
      { oTarget=rv64, oTargetFlag=False, oBuiltin=False, oBase=False,
        oSystem=Nothing, oHost=Nothing, oProfileFlag=Nothing,
        oArc=False, oRaw=False, oLib=False, oExports=[], oHardFloat=False,
        oA64=False, oA64Mac=False, oX64=False, oX64Mac=False,
        oQosApp=False, oQosSingle=False, oPlugin=False, oRvv=False,
        oStdCheck=False, oSol=False, oPrelude=Nothing, oNoSafety=False,
        oFiles=[], oForeign=[], oNoInline=False, oCost=False,
        oCheckOnly=False, oManifest=Nothing, oRemarks=Nothing }
    -- profile aliases (Target.hs): the AOT profiles resolved to their
    -- default ISA for this build.  bare-metal -> rv64 (QEMU virt);
    -- qos-native -> rv64 .qa is built by tools, so the alias maps the
    -- codegen the same way; qos-portable -> qx64 (x86-64 build host).
    -- hosted-bytecode is NOT an fprc target: that profile is the sol
    -- executable (fp-risc/sol).
    -- the SYSTEM: where the program runs (docs/2026-09-19-PROFILES.md).  bare-metal
    -- and qos-native are rv64 (QEMU virt, the board); qos-portable is
    -- an x86-64 QOS app image; posix is an executable for the host this
    -- compiler was built on; native selection uses that host's ISA.
    step o "--system=bare-metal" = o {oTarget = rv64, oSystem = Just "bare-metal"}
    step o "--system=qos-native" = o {oTarget = rv64, oSystem = Just "qos-native"}
    step o "--system=qos-portable" = o {oTarget = rv64, oX64 = if oTargetFlag o then oX64 o else True, oQosApp = True, oSystem = Just "qos-portable"}
    -- posix runs on more than one kind of HOST (docs/2026-09-19-PROFILES.md): this
    -- machine (--host=unix, the default: the ISA is the build host's), or an
    -- ESP-IDF board (--host=esp-idf: rv32imafc code around which
    -- machine/esp-idf/build.sh builds an IDF project).  The host decides the
    -- ISA and the lowering, so it is resolved once every flag is read
    -- (resolveHost): --system= and --host= may come in either order.
    step o "--system=posix" = o {oSystem = Just "posix"}
    -- the 1.x spelling of --system=posix --host=esp-idf, kept
    step o "--system=esp-idf" = o {oSystem = Just "posix", oHost = Just "esp-idf"}
    -- the PROFILE: what the program is written against.  The file says
    -- it (`profile base.`); the flag is for files that do not.
    step o "--profile=builtin" = o {oProfileFlag = Just "builtin"}
    step o "--profile=base" = o {oProfileFlag = Just "base"}
    step o "--profile=extbase" = o {oProfileFlag = Just "extbase"}
    step o "--profile=sol" = o {oProfileFlag = Just "sol"}
    -- the 1.x spellings, kept: a system and (for builtin) a profile at once
    step o "--profile=bare-metal-builtin" = (step o "--system=bare-metal") {oProfileFlag = Just "builtin"}
    step o "--profile=bare-metal" = step o "--system=bare-metal"
    step o "--profile=qos-native" = step o "--system=qos-native"
    step o "--profile=qos-portable" = step o "--system=qos-portable"
    step o "--arc" = o {oArc = True}
    step o "--cost" = o {oCost = True}
    step o "--remarks" = o {oRemarks = Just "hot"}
    step o a | "--remarks=" `isPrefixOf` a = o {oRemarks = Just (drop (length "--remarks=") a)}
    step o "--lib" = o {oLib = True}
    step o "--raw" = o {oRaw = True}
    step o "--float-abi=hard" = o {oHardFloat = True}
    step o "--float-abi=soft" = o {oHardFloat = False}
    step o "--stdcheck" = o {oStdCheck = True}
    step o "--check-only" = o {oCheckOnly = True}
    step o "--sol" = o {oSol = True}
    step o "--target=rv32" = o {oTarget = rv32, oTargetFlag = True}
    step o "--target=rv64" = o {oTarget = rv64, oTargetFlag = True}
    step o "--target=a64" = o {oTarget = rv64, oA64 = True, oTargetFlag = True} -- direct typed ELF output
    step o "--target=a64mac" = o {oTarget = rv64, oA64 = True, oA64Mac = True, oTargetFlag = True} -- direct typed Mach-O output
    step o "--target=x64" = o {oTarget = rv64, oX64 = True, oX64Mac = False, oTargetFlag = True} -- likewise
    step o "--target=x64mac" = o {oTarget = rv64, oX64 = True, oX64Mac = True, oTargetFlag = True} -- Mach-O x86-64 (an Intel Mac, or Rosetta)
    step o "--target=qx64" = o {oTarget = rv64, oX64 = True, oX64Mac = False, oQosApp = True, oTargetFlag = True} -- QOS-x86_64
    step o "--target=qrv64" = o {oTarget = rv64, oA64 = False, oA64Mac = False, oX64 = False, oQosApp = True, oTargetFlag = True} -- Linux QOS-RISC-V
    step o "--target=qa64" = o {oTarget = rv64, oA64 = True, oQosApp = True, oTargetFlag = True} -- QOS-aarch64
    step o "--target=qa64single" = o {oTarget = rv64, oA64 = True, oQosApp = True, oQosSingle = True, oTargetFlag = True} -- QOS-aarch64, global hart cell
    step o "--target=qa64mac" = o {oTarget = rv64, oA64 = True, oA64Mac = True, oQosApp = True, oTargetFlag = True} -- QOS app, Apple Silicon
    step o "--plugin" = o {oPlugin = True}
    step o "--rvv" = o {oRvv = True}
    step o a
      | "--prelude=" `isPrefixOf` a = o {oPrelude = Just (drop (length "--prelude=") a)}
      | "--manifest=" `isPrefixOf` a = o {oManifest = Just (drop (length "--manifest=") a), oCost = True}
      | "--foreign=" `isPrefixOf` a = o {oForeign = oForeign o ++ [drop (length "--foreign=") a]}
      | "--host=" `isPrefixOf` a = let h = drop (length "--host=") a in o {oHost = if h == "unix" then Nothing else Just h}
      | "--export=" `isPrefixOf` a = o {oExports = oExports o ++ exportSpecs (drop (length "--export=") a)}
      | a == "--no-safety" = o {oNoSafety = True}
      | a == "--no-inline" = o {oNoInline = True}
      | otherwise = o {oFiles = oFiles o ++ [a]}

-- the posix system's host decides the ISA and the lowering: this machine's
-- native x64/a64/rv64 selection, or rv32 for an ESP-IDF
-- board.  A --host= with no --system= means posix; a host the tree does not
-- have, or one asked for with another system, is refused in compileMain,
-- as is a --target= the esp-idf host cannot be (it is left as given here).
resolveHost :: CompileArguments -> CompileArguments
resolveHost o
  | oSystem o == Nothing && oHost o /= Nothing = resolveHost o {oSystem = Just "posix"}
  | oSystem o /= Just "posix" = o
  | oHost o == Just "esp-idf" = if oTargetFlag o then o else o {oTarget = rv32}
  | oHost o /= Nothing = o
  -- an explicit hosted target (--target=a64 | x64) is a CROSS build: it wins over
  -- this machine's lowering, so a Mac can emit ELF for a Linux server
  | oTargetFlag o && (oA64 o || oX64 o || tgtName (oTarget o) == "rv64") =
      o {oBase = True, oHardFloat = oHardFloat o || not (oA64 o || oX64 o)}
  | oTargetFlag o = o
  | otherwise = case (System.Info.os, System.Info.arch) of
      ("darwin", "aarch64") -> o {oTarget = rv64, oBase = True, oA64 = True, oA64Mac = True}
      (_, "aarch64") -> o {oTarget = rv64, oBase = True, oA64 = True}
      ("darwin", "x86_64") -> o {oTarget = rv64, oBase = True, oX64 = True, oX64Mac = True}
      (_, "x86_64") -> o {oTarget = rv64, oBase = True, oX64 = True}
      ("linux", "riscv64") -> o {oTarget = rv64, oBase = True, oHardFloat = True}
      (os', arch') -> error ("--system=posix: no hosted lowering for " ++ os' ++ "/" ++ arch' ++ " (x86_64, aarch64 and Linux riscv64 are supported)")

-- `--export=name,name:c_symbol,...`: an fpr function and the C symbol it
-- is callable as (default: the same name)
exportSpecs :: String -> [(String, String)]
exportSpecs = map one . filter (not . null) . splitOn ','
  where
    one spec = case break (== ':') spec of
      (n, ':' : c) -> (n, c)
      (n, _) -> (n, n)
    splitOn c str = case break (== c) str of
      (a, _ : rest) -> a : splitOn c rest
      (a, []) -> [a]

