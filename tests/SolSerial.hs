module Main where
-- Sol.Serial against a pseudo-terminal pair: the test writes the "device"
-- side (the master) and the Sol port reads the slave side. Covers reads,
-- expect keeping the bytes after its match, timeouts that keep what arrived,
-- writes reaching the device, closing, and refusals (docs/2026-11-27-SOL-BYTES-AND-SERIAL.md).
-- The baud rate cannot be observed on a pty; a board run covers that.
import Control.Monad (unless)
import qualified Data.ByteString.Char8 as C
import System.Posix.IO (fdWrite, fdRead, closeFd)
import System.Posix.Terminal (openPseudoTerminal, getSlaveTerminalName)
import Sol.Serial

check :: String -> Bool -> IO ()
check label ok = unless ok (error ("sol serial: " ++ label))

main :: IO ()
main = do
  (master, slave) <- openPseudoTerminal
  name <- getSlaveTerminalName master
  opened <- openPort name 115200
  k <- either (error . ("open: " ++)) pure opened
  closeFd slave
  _ <- fdWrite master "boot ok\nprompt> rest"
  r1 <- expectPort k (C.pack "prompt> ") 2000
  check "expect answers through its match" (r1 == Right (C.pack "boot ok\nprompt> "))
  r2 <- readPort k 100 100
  check "the bytes after the match stay for the next read" (r2 == Right (C.pack "rest"))
  r3 <- expectPort k (C.pack "never") 150
  check "a timeout is an error" (either (const True) (const False) r3)
  _ <- fdWrite master "late never!"
  r4 <- expectPort k (C.pack "never") 2000
  check "expect after a timeout still sees what arrives" (r4 == Right (C.pack "late never"))
  r5 <- readPort k 10 100
  check "and keeps the rest" (r5 == Right (C.pack "!"))
  r6 <- readPort k 10 100
  check "nothing pending reads as empty after the timeout" (r6 == Right C.empty)
  w <- writePort k (C.pack "help\n") 2000
  check "write" (w == Right ())
  (got, _) <- fdRead master 64
  check "the device received the bytes" (got == "help\n")
  closePort k
  bad <- openPort "/dev/no-such-serial-port" 115200
  check "a missing port is an error" (either (const True) (const False) bad)
  putStrLn "Sol serial: expect/read buffering, timeouts, writes, refusals on a pty PASS"
