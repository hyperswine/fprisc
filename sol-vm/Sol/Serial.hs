-- Sol.Serial: serial ports as a Sol resource (compiler/cbits/sol_serial.c).
-- A port is a linear `Serial` at the Sol level: a key into this table, which
-- holds the descriptor and the bytes that arrived but no `expect` has taken
-- yet, so data that comes in the same read as a prompt is not lost to the
-- wait after it (spectre-uart.c's rule). Every operation acts now: these are
-- immediate operations, allowed in `>!` statements only.
module Sol.Serial (openPort, writePort, readPort, expectPort, closePort) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BSU
import Data.IORef
import qualified Data.IntMap.Strict as IM
import Foreign.C.Error (Errno (..), errnoToIOError)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr, castPtr)
import Data.Word (Word8)
import GHC.Clock (getMonotonicTimeNSec)
import System.IO.Unsafe (unsafePerformIO)

foreign import ccall safe "sol_serial_open" c_open :: CString -> CInt -> IO CInt
foreign import ccall safe "sol_serial_write" c_write :: CInt -> Ptr Word8 -> CInt -> CInt -> IO CInt
foreign import ccall safe "sol_serial_read" c_read :: CInt -> Ptr Word8 -> CInt -> CInt -> IO CInt
foreign import ccall safe "sol_serial_close" c_close :: CInt -> IO CInt

data Port = Port {portFd :: CInt, portPending :: BS.ByteString}

{-# NOINLINE ports #-}
ports :: IORef (IM.IntMap Port, Int)
ports = unsafePerformIO (newIORef (IM.empty, 1))

errText :: String -> CInt -> String
errText what e = what ++ ": " ++ show (errnoToIOError what (Errno (negate e)) Nothing Nothing)

openPort :: String -> Int -> IO (Either String Int)
openPort path baud = do
  fd <- withCString path (\p -> c_open p (fromIntegral baud))
  if fd < 0 then pure (Left (errText ("Serial.open " ++ path) fd)) else
    atomicModifyIORef' ports (\(m, k) -> ((IM.insert k (Port fd BS.empty) m, k + 1), Right k))

port :: Int -> IO Port
port k = do
  (m, _) <- readIORef ports
  maybe (ioError (userError ("Serial: closed or forged port " ++ show k))) pure (IM.lookup k m)

update :: Int -> Port -> IO ()
update k p = atomicModifyIORef' ports (\(m, n) -> ((IM.insert k p m, n), ()))

writePort :: Int -> BS.ByteString -> Int -> IO (Either String ())
writePort k bytes timeoutMs = do
  p <- port k
  n <- BSU.unsafeUseAsCStringLen bytes $ \(ptr, len) ->
    c_write (portFd p) (castPtr ptr) (fromIntegral len) (fromIntegral timeoutMs)
  pure $ if n < 0 then Left (errText "Serial.write" n)
    else if fromIntegral n < BS.length bytes then Left ("Serial.write: timed out after " ++ show n ++ " of " ++ show (BS.length bytes) ++ " bytes")
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
  pure $ if r < 0 then Left (errText "Serial.read" r) else Right (r > 0)

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
              then pure (Left ("Serial.expect: timed out with " ++ show (BS.length (portPending p)) ++ " byte(s) pending"))
              else do
                r <- fill k (fromIntegral ((deadline - now) `div` 1000000) + 1)
                either (pure . Left) (const go) r
  go

closePort :: Int -> IO ()
closePort k = do
  p <- port k
  _ <- c_close (portFd p)
  atomicModifyIORef' ports (\(m, n) -> ((IM.delete k m, n), ()))
