{-# LANGUAGE ForeignFunctionInterface #-}
module Sol.Digest where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Internal as I
import Data.Word (Word8)
import Foreign.C.Types
import Foreign.ForeignPtr
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (Ptr, castPtr)
import Data.IORef
import qualified Sol.ScriptIO as S

data Context = Context (ForeignPtr Word8) Int

api :: [(String,Int,String)]
api = [("Hex.encode",1,"Bytes -> String"), ("Hex.decode",1,"String -> Result Bytes String")
      ,("Base64.encode",1,"Bytes -> String"), ("Base64.decode",1,"String -> Result Bytes String")
      ,("Sha256.init",1,"Unit -> Sha256"), ("Sha256.update",2,"Bytes -> Sha256 -> Result Sha256 String")
      ,("Sha256.finish",1,"Sha256 -> Bytes"), ("Sha256.bytes",1,"Bytes -> Bytes")
      ,("Sha256.stream",1,"ByteReader -> (Result Bytes String, ByteReader)")]

foreign import ccall unsafe "sol_sha256_size" contextSize :: IO CSize
foreign import ccall unsafe "sol_sha256_init" initialize :: Ptr Word8 -> IO ()
foreign import ccall safe "sol_sha256_update" updateRaw :: Ptr Word8 -> Ptr Word8 -> CSize -> IO CInt
foreign import ccall unsafe "sol_sha256_finish" finishRaw :: Ptr Word8 -> Ptr Word8 -> IO ()
foreign import ccall safe "sol_hex_encode" hexEncode :: Ptr Word8 -> CSize -> Ptr Word8 -> IO ()
foreign import ccall safe "sol_hex_decode" hexDecode :: Ptr Word8 -> CSize -> Ptr Word8 -> IO CLLong
foreign import ccall safe "sol_base64_encode" base64Encode :: Ptr Word8 -> CSize -> Ptr Word8 -> IO ()
foreign import ccall safe "sol_base64_decode" base64Decode :: Ptr Word8 -> CSize -> Ptr Word8 -> IO CLLong

new :: IO Context
new = do
  size <- fromIntegral <$> contextSize
  p <- mallocForeignPtrBytes size
  withForeignPtr p initialize
  pure (Context p size)

copyContext :: Context -> IO Context
copyContext (Context old size) = do
  p <- mallocForeignPtrBytes size
  withForeignPtr old $ \source -> withForeignPtr p $ \target -> copyBytes target source size
  pure (Context p size)

-- Never mutate a context that may still be referenced by an old VM value.
update :: B.ByteString -> Context -> IO (Either String Context)
update bytes old = do
  context@(Context p _) <- copyContext old
  code <- withForeignPtr p $ \ptr -> B.useAsCStringLen bytes $ \(input,n) -> updateRaw ptr (castPtr input) (fromIntegral n)
  pure (if code == 0 then Right context else Left "SHA-256 length exceeds 2^64-1 bits")

finish :: Context -> IO B.ByteString
finish old = do
  Context p _ <- copyContext old
  I.create 32 (\out -> withForeignPtr p (\ptr -> finishRaw ptr out))

hash :: B.ByteString -> IO B.ByteString
hash bytes = do
  state <- new
  result <- update bytes state
  either S.failIO finish result

stream :: S.Runtime -> Int -> IO (Either String B.ByteString)
stream runtime key = do
  state <- new
  let go context = do
        r <- S.readChunk runtime key
        case r of
          Left why -> pure (Left why)
          Right Nothing -> Right <$> finish context
          Right (Just bytes) -> update bytes context >>= either (pure . Left) go
  go state

encode :: Bool -> B.ByteString -> IO String
encode base64 bytes = do
  let n = B.length bytes
      wide = if base64 then ((toInteger n+2) `div` 3)*4 else toInteger n*2
  if wide > toInteger (maxBound :: Int) then S.failIO "encoded output exceeds host length"
  else C.unpack <$> I.create (fromInteger wide) (\out -> B.useAsCString bytes $ \input ->
    (if base64 then base64Encode else hexEncode) (castPtr input) (fromIntegral n) out)

decode :: Bool -> String -> IO (Either String B.ByteString)
decode base64 text = case S.encodeUtf8 text of
  Left why -> pure (Left why)
  Right bytes -> do
    status <- newIORef 0
    result <- I.createAndTrim (B.length bytes) $ \out -> B.useAsCStringLen bytes $ \(input,n) -> do
      size <- (if base64 then base64Decode else hexDecode) (castPtr input) (fromIntegral n) out
      writeIORef status size
      pure (max 0 (fromIntegral size))
    size <- readIORef status
    pure (if size < 0 then Left (if base64 then "invalid base64: require canonical padded RFC 4648 without whitespace" else "invalid hex: require an even number of hexadecimal digits") else Right result)
