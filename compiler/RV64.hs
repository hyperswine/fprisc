-- Linux owns tp. Standalone programs use libc TLS; QOS images borrow a
-- host TLS slot because a .qa has no ELF dynamic loader to register TLS.
module RV64 (lowerPosixRV64, lowerQosRV64, rv64HostRev) where

import Data.List (isPrefixOf, isSuffixOf)

rv64HostRev :: Int
rv64HostRev = 3

-- JAL's one-MiB range is too small for Main and cross-unit runtime calls.
-- CALL_PLT also permits interposable destinations in shared libraries.
longTail :: String -> Maybe String
longTail line = case words line of
  ["j", target] | not (".L" `isPrefixOf` target) -> Just ("    tail " ++ target)
  _ -> Nothing

hartRead :: String -> Maybe String
hartRead line = case words line of
  ["mv", rd, "tp"] | "," `isSuffixOf` rd -> Just (init rd)
  _ -> Nothing

lowerPosixRV64 :: Bool -> String -> String
lowerPosixRV64 shared = unlines . ((if shared then ["    .option pic"] else []) ++) . concatMap lower . lines
  where
    lower line | Just rd <- hartRead line =
      if shared then
        [ "    la.tls.ie " ++ rd ++ ", fpr_posix_hart"
        , "    add " ++ rd ++ ", " ++ rd ++ ", tp"
        , "    ld " ++ rd ++ ", 0(" ++ rd ++ ")" ]
      else
        [ "    lui " ++ rd ++ ", %tprel_hi(fpr_posix_hart)"
        , "    add " ++ rd ++ ", " ++ rd ++ ", tp, %tprel_add(fpr_posix_hart)"
        , "    ld " ++ rd ++ ", %tprel_lo(fpr_posix_hart)(" ++ rd ++ ")" ]
    lower line | Just tailCall <- longTail line = [tailCall]
    lower line = [line]

lowerQosRV64 :: String -> String
lowerQosRV64 = unlines . concatMap lower . lines
  where
    lower line | Just rd <- hartRead line =
      [ "    lla " ++ rd ++ ", fpr_g_tlsoff"
      , "    ld " ++ rd ++ ", 0(" ++ rd ++ ")"
      , "    add " ++ rd ++ ", " ++ rd ++ ", tp"
      , "    ld " ++ rd ++ ", 0(" ++ rd ++ ")" ]
    lower line | Just tailCall <- longTail line = [tailCall]
    lower line = [line]
