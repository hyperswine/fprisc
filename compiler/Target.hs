-- Target.hs — the profile model of the merged FP-RISC project.
--
-- ONE frontend (FPRISC.hs / Infer / Modules / Struct / Precond) feeds
-- FOUR execution profiles.  A profile = (how guarantees are discharged,
-- which backend runs the code, which library tier is the floor).
--
--   BareMetal       AOT, co-compiled with hal/virt, no OS underneath.
--                   Actors exist iff you link the cooperative scheduler
--                   (hal/core/actors.c) — local in-memory handle
--                   addressing, no URL namespace, no persistence.
--
--   QOSNative       AOT for RISC-V; the program is a .qa PROCESS hosted
--                   by the QOS kernel (qos/native — itself an FP-RISC
--                   program, system.fpr, built separately).  Same send
--                   primitive as BareMetal, enriched: global URL
--                   addressing, capability checks, append-only store.
--
--   QOSPortable     AOT for the host ISA (qx64 / qa64); the program is
--                   a .qa hosted by qosp (qos/portable) on a Unix
--                   machine.  Not an OS: one process, std obligations
--                   satisfied through the qos_hal_t table.  The old
--                   co-compiled `posix` target is GONE — hosting a
--                   program on Unix IS QOSPortable's job.
--
--   HostedBytecode  the `sol` package: bytecode VM + JIT in Haskell,
--                   transactional semantics (one run = one transaction
--                   over host files), `>` top-level eval, .sol files.
--                   The forgiving profile: guarantees discharged by a
--                   runtime rollback net instead of static exclusion.
--
-- The ISA flags (rv32/rv64/a64/x64/...) are a SEPARATE axis: a profile
-- picks a discharge strategy, an ISA picks an instruction set.  The
-- Makefiles pair them; --profile= on fprc resolves the AOT profiles to
-- their default ISA target for this build host.
--
-- std sits ABOVE all four: fp-risc/std is the safe tier, and
-- `fprc --stdcheck` (StdBridge + StdCheck) is the discharge mechanism —
-- bounded recursion via measures or the builtin schemes, contract
-- intervals with dynamic checks where proof fails, symbolic WCET with
-- explicit ω terms where unsafe cost enters.  sol USES std; std does
-- not need sol.
module Target (Profile (..), profileOf, profileNote) where

data Profile
  = BareMetal
  | QOSNative
  | QOSPortable
  | HostedBytecode
  deriving (Eq, Show)

profileOf :: String -> Maybe Profile
profileOf s = case s of
  "bare-metal" -> Just BareMetal
  "qos-native" -> Just QOSNative
  "qos-portable" -> Just QOSPortable
  "hosted-bytecode" -> Just HostedBytecode
  _ -> Nothing

profileNote :: Profile -> String
profileNote p = case p of
  BareMetal -> "bare-metal: AOT + hal/virt, cooperative-scheduler actors, local addressing"
  QOSNative -> "qos-native: .qa process on the QOS kernel (RISC-V), URL addressing + capabilities"
  QOSPortable -> "qos-portable: .qa process hosted by qosp on Unix through the qos_hal_t table"
  HostedBytecode -> "hosted-bytecode: the sol package — bytecode VM + JIT, transactional semantics"
