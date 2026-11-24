{-# LANGUAGE ForeignFunctionInterface #-}
-- Native mechanisms for hosted automation. No subprocess fallback.
module Sol.Native (GitRequest(..), nativeGit, nativeArchive, nativeHost) where
import Foreign
import Foreign.C
import Control.Exception (IOException, try, bracket, mask_, finally)
import Data.IORef
import System.Directory (canonicalizePath, doesDirectoryExist)
import System.FilePath (addTrailingPathSeparator, takeDirectory, takeFileName, (</>))
import Data.List (isPrefixOf)
import qualified Data.ByteString.UTF8 as U
import qualified Data.ByteString as B

data GitRequest = GitRequest FilePath Int String String String [String] Integer deriving (Read,Show)
foreign import ccall safe "fpr_native_git" cGit :: CString -> CInt -> CString -> CString -> CString -> Ptr CString -> CSize -> CSize -> Ptr CString -> IO CInt
foreign import ccall safe "fpr_native_archive" cArchive :: CString -> CString -> CLLong -> CLLong -> Ptr CString -> IO CInt
withUtf8 :: String -> (CString -> IO a) -> IO a
withUtf8 s = B.useAsCString (U.fromString s)
readUtf8 :: CString -> IO String
readUtf8 p = U.toString <$> B.packCString p
nativeResult :: (Ptr CString -> IO CInt) -> IO (Either String String)
nativeResult f = mask_ $ alloca $ \out -> do
  code <- f out
  p <- peek out
  text <- if p == nullPtr then pure "native allocation failed" else readUtf8 p `finally` free p
  pure (if code==0 && p /= nullPtr then Right text else Left text)
withStrings :: [String] -> ([CString] -> IO a) -> IO a
withStrings [] f = f []
withStrings (s:ss) f = withUtf8 s $ \p -> withStrings ss (f . (p:))
nativeGit :: GitRequest -> IO (Either String String)
nativeGit (GitRequest path op arg name email paths limit)
  | limit < 1 || limit > toInteger (maxBound :: Int) = pure (Left "native Git output limit must be a positive host-sized integer")
  | any (elem '\0') (path:arg:name:email:paths) = pure (Left "native Git input contains NUL")
  | otherwise = withUtf8 path $ \p -> withUtf8 arg $ \a -> withUtf8 name $ \n -> withUtf8 email $ \e ->
      withStrings paths $ \ps -> withArray ps $ \arr -> nativeResult (cGit p (fromIntegral op) a n e arr (fromIntegral (length ps)) (fromIntegral limit))
-- This is a deferred live-source operation, like the previous tar call. It
-- sees earlier committed file effects. It never follows source symlinks.
nativeArchive :: FilePath -> FilePath -> Integer -> Integer -> IO (Either String String)
nativeArchive source target entries bytes
  | any (elem '\0') [source,target] = pure (Left "archive input contains NUL")
  | otherwise = do
      checked <- try $ do
        src <- canonicalizePath source
        parent <- canonicalizePath (takeDirectory target)
        dst <- canonicalizePath (parent </> takeFileName target)
        dir <- doesDirectoryExist source
        pure (src==dst || (dir && addTrailingPathSeparator src `isPrefixOf` dst))
      case checked :: Either IOException Bool of
        Left e -> pure (Left (show e))
        Right True -> pure (Left "archive target must be outside its source")
        Right False -> withUtf8 source $ \s -> withUtf8 target $ \t -> nativeResult (cArchive s t (fromIntegral entries) (fromIntegral bytes))

type Observer = CInt -> CLLong -> CLLong -> CString -> CString -> IO ()
foreign import ccall "wrapper" wrapObserver :: Observer -> IO (FunPtr Observer)
foreign import ccall safe "fpr_native_host" cHost :: CInt -> FunPtr Observer -> Ptr CString -> IO CInt
nativeHost :: Int -> IO (Either String [(Int,Integer,Integer,String,String)])
nativeHost limit = do
  observations <- newIORef []
  let observe kind a b text text2 = do
        s <- readUtf8 text; s2 <- readUtf8 text2
        modifyIORef' observations ((fromIntegral kind,fromIntegral a,fromIntegral b,s,s2):)
  bracket (wrapObserver observe) freeHaskellFunPtr $ \callback -> do
    result <- nativeResult (cHost (fromIntegral limit) callback)
    case result of
      Left why -> pure (Left why)
      Right _ -> Right . reverse <$> readIORef observations
