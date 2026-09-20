-- Supported execution configurations. ISA and operational profile are separate
-- concerns; this table describes implemented builds, not a final library taxonomy.
--
-- BareMetalBuiltin is the minimal unsafe standalone RV64 path. It has no
-- scheduler or implicit prelude. BareMetal preserves the older actor-enabled
-- virt build. QOS is a host for the other native configurations, not a language
-- requirement. HostedBytecode is the Sol VM/transactional configuration.
--
-- --stdcheck checks cost/termination obligations; it is not a memory-safety
-- boundary and cannot make arbitrary-address operations safe.
module Target (Profile (..), profileOf, profileNote) where

data Profile
  = BareMetalBuiltin
  | BareMetal
  | QOSNative
  | QOSPortable
  | HostedBytecode
  deriving (Eq, Show)

profileOf :: String -> Maybe Profile
profileOf s = case s of
  "bare-metal-builtin" -> Just BareMetalBuiltin
  "bare-metal" -> Just BareMetal
  "qos-native" -> Just QOSNative
  "qos-portable" -> Just QOSPortable
  "hosted-bytecode" -> Just HostedBytecode
  _ -> Nothing

profileNote :: Profile -> String
profileNote p = case p of
  BareMetalBuiltin -> "bare-metal-builtin: unsafe standalone RV64, no scheduler or default prelude"
  BareMetal -> "bare-metal: AOT + machine/virt, cooperative-scheduler actors, local addressing"
  QOSNative -> "qos-native: .qa process on the QOS kernel (RISC-V), URL addressing + capabilities"
  QOSPortable -> "qos-portable: .qa process hosted by qosp on Unix through the qos_hal_t table"
  HostedBytecode -> "hosted-bytecode: the sol package — bytecode VM + JIT, transactional semantics"
