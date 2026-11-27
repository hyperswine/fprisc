-- Sol.Serial: serial ports as a Sol resource (compiler/cbits/sol_serial.c).
-- A port is a linear `Serial` at the Sol level: a key into this table, which
-- holds the descriptor and the bytes that arrived but no `expect` has taken
-- yet, so data that comes in the same read as a prompt is not lost to the
-- wait after it (spectre-uart.c's rule). Every operation acts now: these are
-- immediate operations, allowed in `>!` statements only.
--
-- A child process (Child.open) is the same kind of link: its stdin and stdout
-- are pipes served by the same poll-based read and write, with the same
-- pending bytes and `expect`, so a script talks to QEMU's serial console the
-- way it talks to a board's.
module Sol.Serial (openPort, writePort, readPort, expectPort, closePort,
                   spawnChild, waitChild, killChild, endAllLinks) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BSU
import Data.IORef
import Data.List (isPrefixOf)
import qualified Data.IntMap.Strict as IM
import Foreign.C.Error (Errno (..), errnoToIOError)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Marshal.Array (withArray0)
import Foreign.Ptr (nullPtr)
import Foreign.Storable (peek)
import Control.Exception (SomeException, bracket, try)
import Foreign.C.String (newCString)
import Foreign.Marshal.Alloc (free)
import Foreign.Ptr (Ptr, castPtr)
import Data.Word (Word8)
import GHC.Clock (getMonotonicTimeNSec)
import System.IO.Unsafe (unsafePerformIO)

foreign import ccall safe "sol_serial_open" c_open :: CString -> CInt -> IO CInt
foreign import ccall safe "sol_serial_write" c_write :: CInt -> Ptr Word8 -> CInt -> CInt -> IO CInt
foreign import ccall safe "sol_serial_read" c_read :: CInt -> Ptr Word8 -> CInt -> CInt -> IO CInt
foreign import ccall safe "sol_serial_close" c_close :: CInt -> IO CInt
foreign import ccall safe "sol_proc_spawn" c_spawn :: Ptr CString -> Ptr CInt -> Ptr CInt -> IO CInt
foreign import ccall safe "sol_proc_wait" c_wait :: CInt -> CInt -> IO CInt
foreign import ccall safe "sol_proc_signal" c_signal :: CInt -> CInt -> IO CInt

-- portFd is read from, portOut written to (the same descriptor for a port);
-- portPid is the child of a Child.open link
data Port = Port {portFd :: CInt, portOut :: CInt, portPid :: Maybe CInt, portName :: String, portPending :: BS.ByteString}

{-# NOINLINE ports #-}
ports :: IORef (IM.IntMap Port, Int)
ports = unsafePerformIO (newIORef (IM.empty, 1))

errText :: String -> CInt -> String
errText what e = what ++ ": " ++ dropPrefix (show (errnoToIOError what (Errno (negate e)) Nothing Nothing))
  where dropPrefix t = if (what ++ ": ") `isPrefixOf` t then drop (length what + 2) t else t

openPort :: String -> Int -> IO (Either String Int)
openPort path baud = do
  fd <- withCString path (\p -> c_open p (fromIntegral baud))
  if fd < 0 then pure (Left (errText ("Serial.open " ++ path) fd)) else
    atomicModifyIORef' ports (\(m, k) -> ((IM.insert k (Port fd fd Nothing "Serial" BS.empty) m, k + 1), Right k))

port :: Int -> IO Port
port k = do
  (m, _) <- readIORef ports
  maybe (ioError (userError ("Serial/Proc: closed or forged link " ++ show k))) pure (IM.lookup k m)

update :: Int -> Port -> IO ()
update k p = atomicModifyIORef' ports (\(m, n) -> ((IM.insert k p m, n), ()))

writePort :: Int -> BS.ByteString -> Int -> IO (Either String ())
writePort k bytes timeoutMs = do
  p <- port k
  n <- BSU.unsafeUseAsCStringLen bytes $ \(ptr, len) ->
    c_write (portOut p) (castPtr ptr) (fromIntegral len) (fromIntegral timeoutMs)
  pure $ if n < 0 then Left (errText (portName p ++ ".write") n)
    else if fromIntegral n < BS.length bytes then Left (portName p ++ ".write: timed out after " ++ show n ++ " of " ++ show (BS.length bytes) ++ " bytes")
    else Right ()

-- one read from the device into the pending bytes; False when nothing came
fill :: Int -> Int -> IO (Either String Bool)
fill k timeoutMs = do
  p <- port k
  r <- allocaBytes 4096 $ \buf -> do
    n <- c_read (portFd p) buf 4096 (fromIntegral (max 0 timeoutMs))
    if n <= 0 then pure n else do
      chunk <- BS.packCStringLen (castPtr buf, fromIntegral n)
      update k p {portPending = portPending p <> chunk}
      pure n
  pure $ if r < 0 && portPid p /= Nothing && r == -5 then Left (portName p ++ ".read: the process closed its output")
    else if r < 0 then Left (errText (portName p ++ ".read") r) else Right (r > 0)

-- what is pending, else what arrives within the timeout (possibly nothing)
readPort :: Int -> Int -> Int -> IO (Either String BS.ByteString)
readPort k cap timeoutMs = do
  p0 <- port k
  filled <- if BS.null (portPending p0) then fill k timeoutMs else pure (Right True)
  case filled of
    Left e -> pure (Left e)
    Right _ -> do
      p <- port k
      let (taken, rest) = BS.splitAt (max 0 cap) (portPending p)
      update k p {portPending = rest}
      pure (Right taken)

-- everything up to and including the first `needle`, waiting up to the
-- timeout; the bytes after it stay for the next call. On a timeout what
-- arrived also stays, and the error says how much.
expectPort :: Int -> BS.ByteString -> Int -> IO (Either String BS.ByteString)
expectPort k needle timeoutMs = do
  start <- getMonotonicTimeNSec
  let deadline = start + fromIntegral (max 0 timeoutMs) * 1000000
      go = do
        p <- port k
        let (before, after) = BS.breakSubstring needle (portPending p)
        if not (BS.null needle) && not (BS.null after) || BS.null needle
          then do
            let cut = BS.length before + BS.length needle
            update k p {portPending = BS.drop cut (portPending p)}
            pure (Right (BS.take cut (portPending p)))
          else do
            now <- getMonotonicTimeNSec
            if now >= deadline
              then pure (Left (portName p ++ ".expect: timed out with " ++ show (BS.length (portPending p)) ++ " byte(s) pending"))
              else do
                r <- fill k (fromIntegral ((deadline - now) `div` 1000000) + 1)
                either (pure . Left) (const go) r
  go

closePort :: Int -> IO ()
closePort k = do
  p <- port k
  _ <- c_close (portFd p)
  _ <- if portOut p /= portFd p then c_close (portOut p) else pure 0
  atomicModifyIORef' ports (\(m, n) -> ((IM.delete k m, n), ()))

-- start argv with its stdin and stdout on pipes (stderr inherited)
spawnChild :: [String] -> IO (Either String Int)
spawnChild [] = pure (Left "Child.open: an empty command")
spawnChild argv@(prog : _) =
  bracket (mapM newCString argv) (mapM_ free) $ \cs ->
    withArray0 nullPtr cs $ \cargv ->
      alloca $ \toChild -> alloca $ \fromChild -> do
        pid <- c_spawn cargv toChild fromChild
        if pid < 0 then pure (Left (errText ("Child.open " ++ prog) pid)) else do
          w <- peek toChild
          r <- peek fromChild
          atomicModifyIORef' ports (\(m, k) -> ((IM.insert k (Port r w (Just pid) "Child" BS.empty) m, k + 1), Right k))

-- close the child's stdin, wait up to the timeout for it to end, and kill
-- its process group if it has not; its exit status (128+signal when a signal
-- ended it). The link is gone either way.
waitChild :: Int -> Int -> IO (Either String Int)
waitChild k timeoutMs = do
  p <- port k
  _ <- c_close (portOut p)
  let pid = maybe 0 id (portPid p)
  r <- c_wait pid (fromIntegral (max 0 timeoutMs))
  r2 <- if r == -60 || r == -110 -- ETIMEDOUT (macOS 60, Linux 110)
    then c_signal pid 15 >> c_wait pid 2000 >>= \r1 ->
      if r1 >= 0 then pure (Left ("Child.wait: still running after " ++ show timeoutMs ++ " ms; terminated"))
      else c_signal pid 9 >> c_wait pid 2000 >> pure (Left ("Child.wait: still running after " ++ show timeoutMs ++ " ms; killed"))
    else pure (if r < 0 then Left (errText "Child.wait" r) else Right (fromIntegral r))
  _ <- c_close (portFd p)
  atomicModifyIORef' ports (\(m, n) -> ((IM.delete k m, n), ()))
  pure r2

-- end the child now: SIGTERM to its process group, SIGKILL if it lingers
killChild :: Int -> IO ()
killChild k = do
  p <- port k
  let pid = maybe 0 id (portPid p)
  _ <- c_signal pid 15
  r <- c_wait pid 1000
  _ <- if r < 0 then c_signal pid 9 >> c_wait pid 2000 else pure r
  _ <- c_close (portOut p)
  _ <- c_close (portFd p)
  atomicModifyIORef' ports (\(m, n) -> ((IM.delete k m, n), ()))

-- a run that ends abnormally (a panic, a refused retry, a non-zero exit) ends
-- every link it still holds: children are killed as Child.kill does, ports
-- closed. Without this a Child outlives the script and keeps its caller's
-- pipes open (sol-live waited out its 300 s limit that way).
endAllLinks :: IO ()
endAllLinks = do
  (m, _) <- readIORef ports
  mapM_ end (IM.toList m)
  where
    end (k, p) = do
      _ <- try (case portPid p of
                  Just _ -> killChild k
                  Nothing -> closePort k) :: IO (Either SomeException ())
      pure ()
