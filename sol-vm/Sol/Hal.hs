{-# LANGUAGE LambdaCase #-}

-- Sol.Hal -- the Sol VM's HAL primitive table (prims, BStr ref table,
-- transactional filesystem/process/git/archive/HTTP/digest/format ops).
-- Split out of Sol.VM so the interpreter loop, actor shim, and JIT/Vec
-- dispatch stay separate from the host primitive surface.
module Sol.Hal
  ( BStrTable, globalBst, bstInsert, bstLookup, bstDelete, veqIO,
    mtimeT, vmPanic, mkHal, recordStatementResult
  ) where

import Control.Monad (unless, when)
import Data.Array ((!))
import Data.Bits (complement, shiftL, shiftR, xor, (.&.), (.|.))
import Data.Word (Word32)
import qualified Data.ByteString as BS
import qualified Data.ByteString.UTF8 as BSU
import Data.Int (Int64)
import qualified Data.IntMap.Strict as IM
import Data.IORef
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import GHC.Clock (getMonotonicTime)
import GHC.Float (castDoubleToWord64, castWord32ToFloat, castWord64ToDouble)
import Control.Concurrent (threadDelay)
import System.IO (hFlush, hPutStrLn, stderr, stdout)
import System.IO.Error (ioeGetFileName)
import qualified Sol.Serial as Serial
import qualified Sol.FMath as FMath
import System.IO.Unsafe (unsafePerformIO)

import qualified Sol.Digest as Digest
import qualified Sol.Format as Format
import qualified Sol.Http as Http
import Sol.Lang (Name)
import qualified Sol.MutMap as MM
import Sol.Native
import qualified Sol.Process as Process
import qualified Sol.ScriptIO as ScriptIO
import Sol.Txn
import Sol.Val

vmPanic :: String -> IO a
vmPanic m = ioError (userError ("*** SOL PANIC: " ++ m ++ " ***"))

mtimeT :: Int
mtimeT = 9977 -- runtime-range tid for the actor shim's mtime handle

-- The BStr ref table, process-global.
--
-- BStr values are `VData bstrT 0 [VInt key]` at the Sol level -- the same
-- bridge Handle uses, because an IORef cannot live in a VData field. The
-- table maps keys to buffers. It is global rather than threaded because
-- `arith` (where == lands) is reached from the VM loop without the HAL
-- environment in scope, and the table has exactly one instance per process
-- anyway.
type BStrTable = IORef (IM.IntMap (IORef BStrStore))

{-# NOINLINE globalBst #-}
globalBst :: BStrTable
globalBst = unsafePerformIO (newIORef IM.empty)

bstInsert :: BStrTable -> IORef BStrStore -> IO Int
bstInsert tbl ref = atomicModifyIORef' tbl $ \m ->
  let k = if IM.null m then 1 else fst (IM.findMax m) + 1
   in (IM.insert k ref m, k)

bstLookup :: BStrTable -> Int -> IO (IORef BStrStore)
bstLookup tbl k = do
  m <- readIORef tbl
  case IM.lookup k m of
    Just r -> pure r
    Nothing -> ioError (userError ("BStr: stale ref " ++ show k ++ " (linearity violation?)"))

bstDelete :: BStrTable -> Int -> IO (IORef BStrStore)
bstDelete tbl k = do
  r <- bstLookup tbl k
  atomicModifyIORef' tbl (\m -> (IM.delete k m, ()))
  pure r

-- IO-capable equality: needed for VBStr comparisons.
veqIO :: BStrTable -> Value -> Value -> IO Bool
veqIO bst a b = do
  sa <- strOf a
  sb <- strOf b
  case (sa, sb) of
    (Just x, Just y) -> pure (x == y)
    _ -> pure (veq a b)
  where
    strOf (VStr s) = pure (Just s)
    strOf (VData _ 0 [VInt k]) = do
      m <- readIORef bst
      case IM.lookup (fromIntegral k) m of
        Just r -> Just <$> bsContent r
        Nothing -> pure Nothing
    strOf _ = pure Nothing

-- ---- the HAL: prims + transactional file IO -------------------------------
--
-- Every entry here is what an fpr_g_* symbol is on the metal: the ONLY
-- surface generated code can reach the outside world through. Path/Handle
-- tids are passed in because the front-end assigns user-type ids in
-- declaration order (prelude declares them first).
-- Bytes readers and writers: (width in bytes, big-endian)
byteWidths, byteWriters :: [(String, (Int, Bool))]
byteWidths = [("Bytes." ++ n, wb) | (n, wb) <- byteForms]
byteWriters = [("Bytes.put" ++ toUpperFirst n, wb) | (n, wb) <- byteForms]
  where toUpperFirst (c : cs) = toEnum (fromEnum c - 32) : cs
        toUpperFirst [] = []
byteForms :: [(String, (Int, Bool))]
byteForms = [("u8", (1, False)), ("u16le", (2, False)), ("u16be", (2, True)), ("u32le", (4, False)),
             ("u32be", (4, True)), ("u64le", (8, False)), ("u64be", (8, True))]

-- CRC-32 (IEEE 802.3, zlib's): reflected polynomial 0xEDB88320, init and
-- final xor 0xFFFFFFFF
crc32 :: BS.ByteString -> Word32
crc32 = complement . BS.foldl' step 0xFFFFFFFF
  where
    step c x = let c0 = c `xor` fromIntegral x in iterate bit c0 !! 8
    bit c = if c .&. 1 /= 0 then (c `shiftR` 1) `xor` 0xEDB88320 else c `shiftR` 1

-- The committed result of each statement, by statement index: `x = > e.`
-- reads its slot through Stmt.result (docs/2026-11-27-SOL-STATEMENT-RESULTS.md).
-- One script runs per process; the run loop writes a slot only after its
-- statement commits, so a retried or aborted statement leaves nothing.
{-# NOINLINE statementResults #-}
statementResults :: IORef (IM.IntMap Value)
statementResults = unsafePerformIO (newIORef IM.empty)

recordStatementResult :: Int -> Value -> IO ()
recordStatementResult i v = modifyIORef' statementResults (IM.insert i v)

mkHal :: M.Map Name (Int, Int, Int) -> [String] -> IORef TxState -> IORef Int -> RtCounts -> M.Map Name (Int, [Value] -> IO Value)
mkHal cons scriptArgs tx preempts rt =
  M.fromList $
    [ ("str", (1, \[v] -> pure (VStr (render v)))),
      -- the committed value of statement i; the thunk exists only for typing
      ("Stmt.result", (2, \[VInt i, _] -> do
          m <- readIORef statementResults
          case IM.lookup (fromIntegral i) m of
            Just v -> pure v
            Nothing -> vmPanic ("statement result " ++ show i ++ " read before its statement committed"))),
      -- Strings retain lazy sequential text and share an on-demand character index.
      ("strcat", (2, \[a, b] -> fmap VStr (liftA2 (++) (vsStr a) (vsStr b)))),
      -- byte order, -1 / 0 / 1 (runtime.c g_strCompare; std/order's String comparison): UTF-8 keeps
      -- code point order, so comparing the characters answers what comparing the bytes does
      ("strCompare", (2, \[a, b] -> (\x y -> VInt (case compare x y of LT -> -1; EQ -> 0; GT -> 1)) <$> vsStr a <*> vsStr b)),
      ("String.len", (1, \[v] -> case stringLength v of Just n -> pure (VInt (fromIntegral n)); Nothing -> vmPanic "strlen: not a String")),
      ("strlen", (1, \[v] -> case stringLength v of Just n -> pure (VInt (fromIntegral n)); Nothing -> vmPanic "strlen: not a String")),
      -- MutMap's hashes (Sol.MutMap; the native 64-bit values, Strings as UTF-8)
      ("strHash", (1, \[v] -> MM.strHashV <$> vsStr v)),
      ("intHash", (1, \[v] -> case v of VInt i -> pure (MM.intHashV i); _ -> vmPanic "intHash: not an Int")),
      -- deprecated compatibility bounds fixed at the old 64-bit small-Int range
      ("intMax", (1, \[_] -> pure (VInt (2 ^ (62 :: Int) - 1)))),
      ("intMin", (1, \[_] -> pure (VInt (negate (2 ^ (62 :: Int)))))),
      ("charAt", (2, charAtH)),
      -- std/string's byte scans (runtime.c g_strFindByte/g_strFindSpace/g_strDigits):
      -- charFrom, wordEnd and digitsGo's loops, a charAt a step
      ("strFindByte", (4, findByteH)),
      ("strFindSpace", (3, findSpaceH)),
      ("strDigits", (3, digitsH)),
      ("substr", (3, substrH)),
      -- the O(n) string tier: one pass each, no re-slicing of the rest
      -- (Str.split / indexOf / replace / upper / lower / trim / join in
      -- the preamble dispatch here; semantics are the preamble's own:
      -- split "" = [], a trailing separator ends the list, indexOf is
      -- 0-based with -1 = miss and "" never found, replace is leftmost
      -- non-overlapping, case folding is ASCII, trim strips 32/9/10/13)
      ("strSplit", (2, \[VInt c, sv] -> vsStr sv >>= \s -> pure (strList (splitCodes (toEnum (fromIntegral c)) s)))),
      -- the first match at or after a 0-based position; -1 = none (runtime.c g_strIndexFrom)
      ("strIndexFrom", (3, \[pv, sv, iv] -> case iv of
          VInt i0 -> liftA2 (\p s ->
            let from = max 0 (fromIntegral i0) :: Int
                rest = drop from s
                hit = indexOfStr p rest
             in VInt (fromIntegral (if from > length s then -1 else if null p then from else if hit < 0 then -1 else hit + from))) (vsStr pv) (vsStr sv)
          _ -> pure (VInt (-1)))),
      ("strIndexOf", (2, \[pv, sv] -> liftA2 (\p s -> VInt (fromIntegral (indexOfStr p s))) (vsStr pv) (vsStr sv))),
      ("strReplace", (3, \[ov, nv, sv] -> do o <- vsStr ov; n <- vsStr nv; s <- vsStr sv; pure (VStr (replaceStr o n s)))),
      ("strUpper", (1, \[v] -> VStr . map (\ch -> if ch >= 'a' && ch <= 'z' then toEnum (fromEnum ch - 32) else ch) <$> vsStr v)),
      ("strLower", (1, \[v] -> VStr . map (\ch -> if ch >= 'A' && ch <= 'Z' then toEnum (fromEnum ch + 32) else ch) <$> vsStr v)),
      ("strTrim", (1, \[v] -> VStr . trimStr <$> vsStr v)),
      ("strJoin", (2, \[sepv, lv] -> do sep <- vsStr sepv; xs <- mapM vsStr (listItems lv); pure (VStr (intercalate sep xs)))),
      -- Str.cmp: -1 / 0 / 1 by code (the sort comparator the prelude's
      -- Int-only < could not be); Str.codes: the characters as a list of
      -- codes, one pass -- a scanner walks that instead of charAt s i
      ("strCmp", (2, \[av, bv] -> liftA2 (\a b -> VInt (case compare a b of LT -> -1; EQ -> 0; GT -> 1)) (vsStr av) (vsStr bv))),
      ("strCodes", (1, \[v] -> vsStr v >>= \s -> pure (foldr (\ch acc -> VData listT 1 [VInt (fromIntegral (fromEnum ch)), acc]) (VData listT 0 []) s))),
      ("chr", (1, \[VInt c] -> pure (VStr [toEnum (fromIntegral c)]))),
      -- ---- BStr ops: the fast byte-buffer string tier ----
      -- At the Sol level, BStr looks like `BStr Int` (the Int is a ref-table
      -- key). The HAL dispatches via mkBStr/withBStr/consumeBStr.
      ("BStr.new", (1, \[_] -> newIORef (BStrStore initialBsCap 0 (BS.replicate initialBsCap 0)) >>= mkBStr)),
      ("BStr.fromStr", (1, \[v] -> vsStr v >>= \s -> do r <- newIORef =<< (let bs = BSU.fromString s; n = BS.length bs; cap = max initialBsCap (n * 2) in pure (BStrStore cap n (bs <> BS.replicate (max 0 (cap - n)) 0))); mkBStr r)),
      ("BStr.toStr", (1, \[v] -> withBStr v (\r -> VStr <$> bsContent r) >>= \res -> consumeBStr v >> pure res)),
      ("BStr.append", (2, \[sv, bv] -> withBStr bv (\r -> vsStr sv >>= bsAppendStr r) >> pure bv)),
      ("BStr.cat", (2, \[a, b] -> do
          sa <- case a of VStr s -> pure s; _ -> withBStr a bsContent
          sb <- case b of VStr s -> pure s; _ -> withBStr b bsContent
          let bs = BSU.fromString (sa ++ sb); n = BS.length bs; cap = max initialBsCap (n * 2)
          r <- newIORef (BStrStore cap n (bs <> BS.replicate (max 0 (cap - n)) 0))
          mkBStr r)),
      ("BStr.len", (1, \[v] -> withBStr v (\r -> do n <- bsCpLen r; pure (VData 4 0 [VInt (fromIntegral n), v])))),
      ("BStr.at", (2, \[v, VInt i] -> withBStr v (\r -> do c <- bsCpAt r (fromIntegral i); pure (VData 4 0 [VInt (fromIntegral c), v])))),
      ("BStr.sub", (3, \[v, VInt i, VInt j] -> withBStr v (\r -> do
          s <- bsContent r
          let lo = fromIntegral i; hi = fromIntegral j
          if lo < 0 || hi > length s || lo > hi
            then vmPanic "BStr.sub: index out of range"
            else do let bs = BSU.fromString (take (hi - lo) (drop lo s)); n = BS.length bs; cap = max initialBsCap (n * 2)
                    r2 <- newIORef (BStrStore cap n (bs <> BS.replicate (max 0 (cap - n)) 0))
                    sl <- mkBStr r2
                    pure (VData 4 0 [sl, v])))),
      ("BStr.free", (1, \[v] -> consumeBStr v >> pure vUnit)),
      ("Serial.open", (2, \[VStr path, VInt baud] -> do
          markEscape "Serial.open" ("opens " ++ path ++ " now")
          r <- Serial.openPort path (fromIntegral baud)
          pure (resultV serialV r))),
      ("Serial.write", (2, \[VBytes b, s] -> do
          k <- serialKey s
          r <- Serial.writePort k b 10000
          pure (tupleV (resultV (const vUnit) r) s))),
      ("Serial.read", (3, \[VInt cap, VInt ms, s] -> do
          k <- serialKey s
          r <- Serial.readPort k (fromIntegral cap) (fromIntegral ms)
          pure (tupleV (resultV VBytes r) s))),
      ("Serial.expect", (3, \[VStr text, VInt ms, s] -> do
          k <- serialKey s
          needle <- either vmPanic pure (ScriptIO.encodeUtf8 text)
          r <- Serial.expectPort k needle (fromIntegral ms)
          pure (tupleV (resultV VBytes r) s))),
      ("Serial.close", (1, \[s] -> serialKey s >>= Serial.closePort >> pure vUnit)),
      ("error", (1, \[v] -> vmPanic (render v))),
      -- ---- the Ok/Err tier: fallible work returns Result, chained with |>? --
      ("Try.parseInt", (1, tryParseIntH)),
      ("Try.parseNum", (1, tryParseNumH)),
      ("Try.readPath", (1, tryReadPathH)),
      ("Try.ls", (1, tryLsH)),
      ("Try.stat", (1, tryStatH)),
      ("Try.exists", (1, tryExistsH)),
      ("Try.lstat", (1, tryLstatH)),
      ("Try.statKind", (1, tryStatKindH)),
      ("Try.walk", (4, tryWalkH)),
      ("Try.tempDir", (1, tryTempDirH)),
      ("Try.tempFile", (1, tryTempFileH)),
      ("Try.sh", (1, tryShH)),
      ("NativeGit.afterCommit", (5, gitAfterCommitH)),
      ("NativeGit.query", (3, gitQueryH)),
      ("NativeGit.push", (4, gitPushH)),
      ("NativeArchive.afterCommit", (4, archiveAfterCommitH)),
      ("Host.snapshot", (1, hostSnapshotH)),
      ("Proc.later", (1, procLaterH)),
      ("Deferred.out", (1, projectH Out)),
      ("Deferred.trim", (1, projectH Trim)),
      ("Deferred.line", (2, deferredLineH)),
      ("Deferred.field", (3, deferredFieldH)),
      ("logTo", (2, logToH)),
      ("NativeGit.headLater", (2, gitHeadLaterH)),
      ("NativeGit.tagAt", (4, gitTagAtH)),
      ("NativeGit.pushLater", (4, gitPushLaterH)),
      ("NativeGit.commitNow", (5, gitCommitNowH)),
      ("Proc.query", (1, procQueryH)),
      ("Proc.queryReplayable", (1, \args -> txReplayableScope tx (procQueryH args))),
      ("Proc.afterCommit", (1, procAfterCommitH)),
      ("Proc.runNow", (1, procRunNowH)),
      ("Proc.streamNow", (1, procDirectH "Proc.streamNow" StreamIO)),
      ("Proc.inheritNow", (1, procDirectH "Proc.inheritNow" InheritIO)),
      ("args", (1, \[_] -> pure (strList scriptArgs))),
      ("f64frombits", (2, \[VInt hi, VInt lo] ->
          pure (VNum (castWord64ToDouble
                       ((fromIntegral hi `shiftL` 32)
                          .|. (fromIntegral lo .&. 0xFFFFFFFF)))))),
      ("f32frombits", (1, \[VInt b] ->
          pure (VNum (realToFrac (castWord32ToFloat (fromIntegral b)))))),
      ("Num.div", (2, \[a, b] -> numDivH a b)),
      ("Num.sqrt", (1, \[a] -> numSqrtH a)),
      ("Num.floor", (1, \[a] -> pure (VInt (floor (toD a))))),
      ("Num.round", (1, \[a] -> pure (VInt (round (toD a))))),
      ("Num.sin", (1, \[a] -> pure (VNum (FMath.fsin (toD a))))),
      ("Num.cos", (1, \[a] -> pure (VNum (FMath.fcos (toD a))))),
      ("Num.tan", (1, \[a] -> pure (VNum (FMath.ftan (toD a))))),
      ("Num.asin", (1, \[a] -> pure (VNum (FMath.fasin (toD a))))),
      ("Num.acos", (1, \[a] -> pure (VNum (FMath.facos (toD a))))),
      ("Num.atan", (1, \[a] -> pure (VNum (FMath.fatan (toD a))))),
      ("Num.exp", (1, \[a] -> pure (VNum (FMath.fexp (toD a))))),
      ("Num.log", (1, \[a] -> pure (VNum (FMath.flog (toD a))))),
      ("Num.log2", (1, \[a] -> pure (VNum (FMath.flog2 (toD a))))),
      ("Num.pow", (2, \[a, b] -> pure (VNum (FMath.fpow (toD a) (toD b))))),
      ("Num.atan2", (2, \[a, b] -> pure (VNum (FMath.fatan2 (toD a) (toD b))))),
      ("Num.bits", (1, \[a] -> pure (VInt (fromIntegral (fromIntegral (castDoubleToWord64 (toD a)) :: Int64))))),
      ("!", (2, indexH)),
      ("open", (1, openH)),
      ("readAll", (1, readH)),
      ("writeAll", (2, writeH)),
      ("close", (1, closeH)),
      ("read", (1, \[v] -> readIoH v)),
      ("write", (2, \[pv, v] -> writeIoH pv v))
    ]
    ++ [(name, (arity, scriptHal name)) | (name, arity, _) <- ScriptIO.api]
    ++ [(name, (arity, processHal name)) | (name, arity, _) <- Process.api]
    ++ [(name, (arity, digestHal name)) | (name, arity, _) <- Digest.api]
    ++ [(name, (arity, formatHal name)) | (name, arity, _) <- Format.api]
    ++ [(name, (arity, httpHal name)) | (name, arity, _) <- Http.api]
  where
    resultV convert = either vErr (vOk . convert)
    tupleV a b = VData 4 0 [a,b]
    unitResult = resultV (const vUnit)
    httpHal "Http.backend" [_] = httpResult VStr <$> Http.backend
    httpHal "Http.request" [opts,request] = do
      options <- httpOptions opts
      req <- httpRequest request
      blocked <- guardImmediate "Http.request"
      case blocked of
        Just why -> pure (vErrV (httpError (Http.Failure 1 0 why)))
        Nothing -> httpResult httpResponse <$> Http.request options req
    httpHal "Http.download" [opts,request,VStr target,replace] = do
      options <- httpOptions opts
      req <- httpRequest request
      blocked <- guardImmediate "Http.download"
      case blocked of
        Just why -> pure (vErrV (httpError (Http.Failure 1 0 why)))
        Nothing -> do
          result <- Http.download options req target (isTrueV replace)
          case result of Right _ -> txForget tx target >> pure (); _ -> pure ()
          pure (httpResult httpInfo result)
    httpHal name _ = vmPanic (name ++ ": invalid arguments")
    httpOptions (VData t v [VInt deadline,VInt body,VInt headers,redirects,VStr ca,routes]) | isCon "HttpOptions" t v = do
      policy <- case redirects of
        VData a b [] | isCon "NoRedirect" a b -> pure Http.NoRedirect
        VData a b [VInt n] | isCon "RedirectHttps" a b -> pure (Http.HttpsRedirect (httpBudget 20 n))
        VData a b [VInt n] | isCon "RedirectHttp" a b -> pure (Http.HttpRedirect (httpBudget 20 n))
        _ -> vmPanic "invalid HTTP redirect policy"
      mapped <- listVals routes >>= mapM httpRoute
      pure (Http.Options (httpBudget 86400000 deadline) body (httpBudget 1048576 headers) policy ca mapped)
    httpOptions _ = vmPanic "expected HttpOptions"
    httpRoute (VData t v [VStr host,VInt port,VStr address]) | isCon "HttpRoute" t v =
      pure (host,httpBudget 65535 port,address)
    httpRoute _ = vmPanic "expected HttpRoute"
    httpRequest (VData t v [VStr method,VStr url,headers,VBytes body]) | isCon "HttpRequest" t v =
      Http.Request url method <$> envValues headers <*> pure body
    httpRequest _ = vmPanic "expected HttpRequest"
    httpBudget cap n = if n>=0 && n<=cap then fromInteger n else -2
    httpError (Http.Failure reason code message) =
      let kinds=["HttpInvalid","HttpUnavailable","HttpTls","HttpTimeout","HttpLimit","HttpRedirect","HttpTransport","HttpIo","HttpStatus"]
          kind=if reason>=1 && reason<=length kinds then kinds !! (reason-1) else "HttpTransport"
          (rt,rv)=conTV kind
          (et,ev)=conTV "HttpError"
      in VData et ev [VData rt rv [],VInt (fromIntegral code),VStr message]
    httpResult convert = either (vErrV . httpError) (vOk . convert)
    httpHeaders = foldr (\(key,value) xs -> VData listT 1 [tupleV (VStr key) (VStr value),xs]) (VData listT 0 [])
    httpResponse (Http.Response (Http.Info status headers _) bytes) =
      let (t,v)=conTV "HttpResponse" in VData t v [VInt (fromIntegral status),httpHeaders headers,VBytes bytes]
    httpInfo (Http.Info status headers bytes) =
      let (t,v)=conTV "HttpInfo" in VData t v [VInt (fromIntegral status),httpHeaders headers,VInt bytes]
    formatHal "Format.json" [VInt input,VInt depth,VInt items,VInt field,VStr text] =
      pure (unitResult (Format.jsonAdmission (formatBudget input) (formatBudget depth) (formatBudget items) (formatBudget field) text))
    formatHal "Format.csv" [VInt input,VInt records,VInt fields,VInt field,VInt record,VStr text] =
      pure (resultV (foldr (\row rows -> VData listT 1 [strList row,rows]) (VData listT 0 []))
        (Format.csv (formatBudget input) (formatBudget records) (formatBudget fields) (formatBudget field) (formatBudget record) text))
    formatHal "Stream.readCsv" [VInt fields,VInt field,VInt record,reader] = do
      io <- runtime
      key <- streamKey io True reader
      blocked <- guardImmediate "Stream.readCsv"
      r <- case blocked of
        Just why -> pure (Left why)
        Nothing -> Format.readCsv io (formatBudget fields) (formatBudget field) (formatBudget record) key
      let csvRead Nothing = let (t,v)=conTV "EndCsv" in VData t v []
          csvRead (Just row) = let (t,v)=conTV "CsvRow" in VData t v [strList row]
      pure (tupleV (resultV csvRead r) reader)
    formatHal name _ = vmPanic (name ++ ": invalid arguments")
    formatBudget n = if n>=0 && n<=16777216 then fromInteger n else -1
    digestHal name [VBytes bytes] | name `elem` ["Hex.encode","Base64.encode"] =
      VStr <$> Digest.encode (name == "Base64.encode") bytes
    digestHal name [VStr text] | name `elem` ["Hex.decode","Base64.decode"] =
      resultV VBytes <$> Digest.decode (name == "Base64.decode") text
    digestHal "Sha256.init" [_] = VSha256 <$> Digest.new
    digestHal "Sha256.update" [VBytes bytes,VSha256 state] = resultV VSha256 <$> Digest.update bytes state
    digestHal "Sha256.finish" [VSha256 state] = VBytes <$> Digest.finish state
    digestHal "Sha256.bytes" [VBytes bytes] = VBytes <$> Digest.hash bytes
    digestHal "Sha256.stream" [reader] = do
      io <- runtime
      key <- streamKey io True reader
      blocked <- guardImmediate "Sha256.stream"
      r <- case blocked of Just why -> pure (Left why); Nothing -> Digest.stream io key
      pure (tupleV (resultV VBytes r) reader)
    digestHal name _ = vmPanic (name ++ ": invalid arguments or forged SHA-256 context")
    runtime = txRuntime tx
    bytesRead Nothing = let (t,v) = conTV "EndBytes" in VData t v []
    bytesRead (Just b) = let (t,v) = conTV "ChunkBytes" in VData t v [VBytes b]
    streamKey io reader value = case value of
      VByteReader owner key | reader && owner == ScriptIO.identity io -> pure key
      VByteWriter owner key | not reader && owner == ScriptIO.identity io -> pure key
      _ -> vmPanic "closed, forged or foreign stream capability"
    guardImmediate name = do
      pending <- txPendingBrief tx
      if null pending then markEscape name "immediate I/O is not a snapshot; guarded retry stops on a later conflict" >> pure Nothing
      else pure (Just (pendingOrderMsg name "" pending))
    direct name action = do
      blocked <- guardImmediate name
      case blocked of Just why -> pure (vErr why); Nothing -> action
    scriptHal "Bytes.empty" [_] = pure (VBytes BS.empty)
    scriptHal "Bytes.fromList" [xs] = do
      values <- listVals xs
      pure $ case traverse byteValue values of Left why -> vErr why; Right bs -> vOk (VBytes (BS.pack bs))
    scriptHal "Bytes.toList" [VBytes b] = pure (foldr (\x xs -> VData listT 1 [VInt (fromIntegral x), xs]) (VData listT 0 []) (BS.unpack b))
    scriptHal "Bytes.len" [VBytes b] = pure (VInt (fromIntegral (BS.length b)))
    scriptHal "Bytes.at" [VInt i, VBytes b] = pure $
      if i < 0 || i >= fromIntegral (BS.length b) then vErr "byte index out of range"
      else vOk (VInt (fromIntegral (BS.index b (fromInteger i))))
    scriptHal "Bytes.slice" [VInt start, VInt count, VBytes b] = pure $
      if start < 0 || count < 0 || start + count > fromIntegral (BS.length b) then vErr "byte slice out of range"
      else vOk (VBytes (BS.copy (BS.take (fromInteger count) (BS.drop (fromInteger start) b))))
    scriptHal "Bytes.concat" [xs] = do
      values <- listVals xs
      chunks <- mapM (\v -> case v of VBytes b -> pure b; _ -> vmPanic "Bytes.concat expects Bytes") values
      pure (VBytes (BS.concat chunks))
    scriptHal "Bytes.contains" [VBytes needle, VBytes haystack] = pure (vBool (BS.isInfixOf needle haystack))
    -- fixed-width unsigned integers (std/binary's names; a read past the end is None)
    scriptHal name [VInt at, VBytes b] | Just (w, big) <- lookup name byteWidths = pure $
      if at < 0 || at + fromIntegral w > fromIntegral (BS.length b) then VData 7 0 []
      else let bs = [fromIntegral (BS.index b (fromInteger at + k)) | k <- [0 .. w - 1]] :: [Integer]
               ordered = if big then bs else reverse bs
            in VData 7 1 [VInt (foldl (\acc x -> acc * 256 + x) 0 ordered)]
    -- the low bits of the Int, negatives as two's complement (std/binary's writers)
    scriptHal name [VInt v] | Just (w, big) <- lookup name byteWriters = pure $
      let m = v `mod` (256 ^ w)
          le = [fromIntegral ((m `div` (256 ^ k)) `mod` 256) | k <- [0 .. w - 1]]
       in VBytes (BS.pack (if big then reverse le else le))
    scriptHal "Bytes.set" [VInt i, VInt v, VBytes b] = pure $
      if i < 0 || i >= fromIntegral (BS.length b) then vErr "byte index out of range"
      else if v < 0 || v > 255 then vErr ("not a byte: " ++ show v)
      else vOk (VBytes (BS.concat [BS.take (fromInteger i) b, BS.singleton (fromInteger v), BS.drop (fromInteger i + 1) b]))
    scriptHal "Bytes.patch" [VInt at, VBytes new, VBytes b] = pure $
      if at < 0 || at + fromIntegral (BS.length new) > fromIntegral (BS.length b) then vErr "byte patch out of range"
      else vOk (VBytes (BS.concat [BS.take (fromInteger at) b, new, BS.drop (fromInteger at + BS.length new) b]))
    scriptHal "Bytes.crc32" [VBytes b] = pure (VInt (fromIntegral (crc32 b)))
    -- transactional binary files: a snapshot read and a queued whole-file write
    scriptHal "readBytes" [VStr p] = resultV VBytes <$> txReadBytesE tx p
    scriptHal "writeBytes" [VStr p, VBytes b] = txWriteBytes tx p b >> pure vUnit
    scriptHal "Utf8.encode" [VStr s] = pure (resultV VBytes (ScriptIO.encodeUtf8 s))
    scriptHal "Utf8.decode" [VBytes b] = pure (resultV VStr (ScriptIO.decodeUtf8 b))
    scriptHal "Utf8.decodeReplace" [VBytes b] = pure (VStr (ScriptIO.decodeReplace b))
    scriptHal name [VBytes carry, VBytes chunk, final] | name `elem` ["Utf8.decodeChunk", "Utf8.decodeChunkReplace"] =
      pure (resultV (\(s,b) -> tupleV (VStr s) (VBytes b)) (ScriptIO.utf8Chunk (name == "Utf8.decodeChunkReplace") carry chunk (isTrueV final)))
    scriptHal "Stream.openRead" [VStr path, VInt cap] = direct "Stream.openRead" $ do
      io <- runtime
      fmap (resultV (VByteReader (ScriptIO.identity io))) (ScriptIO.openReader io path (boundedCap cap))
    scriptHal "Stream.openWrite" [VStr path, VInt cap] = direct "Stream.openWrite" $ do
      io <- runtime
      fmap (resultV (VByteWriter (ScriptIO.identity io))) (ScriptIO.openWriter io path (boundedCap cap))
    scriptHal "Stream.stdin" [VInt cap] = direct "Stream.stdin" $ do
      io <- runtime
      fmap (resultV (VByteReader (ScriptIO.identity io))) (ScriptIO.standardReader io (boundedCap cap))
    scriptHal name [VInt cap] | name `elem` ["Stream.stdout", "Stream.stderr"] = do
      io <- runtime
      fmap (resultV (VByteWriter (ScriptIO.identity io))) (ScriptIO.standardWriter io (if name == "Stream.stdout" then stdout else stderr) (boundedCap cap))
    scriptHal "Stream.readChunk" [reader] = do
      io <- runtime; key <- streamKey io True reader
      blocked <- guardImmediate "Stream.readChunk"
      r <- case blocked of Just why -> pure (Left why); Nothing -> ScriptIO.readChunk io key
      pure (tupleV (resultV bytesRead r) reader)
    scriptHal "Stream.readLine" [VInt limit, reader] = do
      io <- runtime; key <- streamKey io True reader
      blocked <- guardImmediate "Stream.readLine"
      r <- case blocked of Just why -> pure (Left why); Nothing -> ScriptIO.readLineBytes io (boundedCap limit) key
      pure (tupleV (resultV bytesRead r) reader)
    scriptHal "Stream.writeChunk" [VBytes b, writer] = do
      io <- runtime; key <- streamKey io False writer
      blocked <- guardImmediate "Stream.writeChunk"
      r <- case blocked of Just why -> pure (Left why); Nothing -> ScriptIO.writeChunk io b key
      pure (tupleV (unitResult r) writer)
    scriptHal name [value] | name `elem` ["Stream.closeRead", "Stream.closeWrite"] = do
      io <- runtime; key <- streamKey io (name == "Stream.closeRead") value
      unitResult <$> ScriptIO.closeStream io key
    scriptHal name [VBytes b] | name `elem` ["IO.stdout", "IO.stderr"] = do
      txMarkExternal tx name
      unitResult <$> ScriptIO.writeExact (if name == "IO.stdout" then stdout else stderr) b
    scriptHal name [VStr s] | name `elem` ["IO.stdoutText", "IO.stderrText"] = case ScriptIO.encodeUtf8 s of
      Left why -> pure (vErr why)
      Right b -> do
        txMarkExternal tx name
        unitResult <$> ScriptIO.writeExact (if name == "IO.stdoutText" then stdout else stderr) b
    scriptHal "IO.readLine" [VInt limit] = direct "IO.readLine" $ do
      io <- runtime
      r <- ScriptIO.readTextLine io (boundedCap limit)
      pure (resultV textRead r)
    scriptHal "IO.cwd" [_] = resultV VStr <$> ScriptIO.cwd
    scriptHal "Env.get" [VStr key] = resultV envValue <$> ScriptIO.environmentGet key
    scriptHal "Env.set" [VStr key, VStr value] = direct "Env.set" $ do
      io <- runtime; unitResult <$> ScriptIO.environmentSet io key (Just value)
    scriptHal "Env.unset" [VStr key] = direct "Env.unset" $ do
      io <- runtime; unitResult <$> ScriptIO.environmentSet io key Nothing
    scriptHal "Script.exit" [VInt code] = ScriptIO.requestExit (if code >= 0 && code <= 255 then fromInteger code else -1)
    scriptHal "Script.abort" [VInt code] = ScriptIO.requestAbort (if code >= 1 && code <= 255 then fromInteger code else -1)
    scriptHal "Fs.copyNow" [VStr source, VStr target, VInt cap] = fileImmediate "Fs.copyNow" "copy" target $ do
      r <- ScriptIO.copyNow source target (boundedCap cap)
      case r of Right _ -> txForget tx target >> pure (); _ -> pure ()
      pure (fmap (VInt . fromIntegral) r)
    scriptHal "Fs.copyPublishNow" [VStr source, VStr target, VInt cap, replace] = fileImmediate "Fs.copyPublishNow" "copyPublish" target $ do
      r <- ScriptIO.copyPublishNow source target (boundedCap cap) (isTrueV replace)
      case r of Right _ -> txForget tx target >> pure (); _ -> pure ()
      pure (fmap (VInt . fromIntegral) r)
    scriptHal "Fs.renameNow" [VStr source, VStr target, replace] = fileImmediate "Fs.renameNow" "rename" target $ do
      r <- ScriptIO.renameNow source target (isTrueV replace)
      case r of Right _ -> txForget tx source >> txForget tx target >> pure (); _ -> pure ()
      pure (fmap (const vUnit) r)
    scriptHal name _ = vmPanic (name ++ ": invalid arguments")
    fileImmediate name op target action = do
      blocked <- guardImmediate name
      case blocked of
        Just why -> pure (vErrV (fsErrV (FsErr op target WhyOther why "")))
        Nothing -> do
          r <- action
          pure (either (\e -> vErrV (fsErrV (classifyIO op (maybe target id (ioeGetFileName e)) e))) vOk r)
    boundedCap cap = if cap >= 1 && cap <= 16777216 then fromInteger cap else 0
    byteValue (VInt i) | i >= 0 && i <= 255 = Right (fromInteger i)
    byteValue _ = Left "byte values must be integers in 0..255"
    listVals (VData t 0 []) | t == listT = pure []
    listVals (VData t 1 [x,xs]) | t == listT = (x :) <$> listVals xs
    listVals _ = vmPanic "expected a list"
    textRead Nothing = let (t,v) = conTV "EndText" in VData t v []
    textRead (Just s) = let (t,v) = conTV "LineText" in VData t v [VStr s]
    envValue Nothing = let (t,v) = conTV "EnvMissing" in VData t v []
    envValue (Just s) = let (t,v) = conTV "EnvText" in VData t v [VStr s]
    markEscape name why = txMarkPivot tx >> txMarkExternal tx name >> noteEscape rt name why
    bst = globalBst
    (pathT, handleT) = (tidOf "Path", tidOf "Handle")
    bstrT = tidOf "BStr"
    processSpecT = tidOf "ProcessSpec"
    processResultT = tidOf "ProcessResult"
    mkBStr r = do k <- bstInsert bst r; pure (VData bstrT 0 [VInt (fromIntegral k)])
    withBStr (VData t 0 [VInt k]) f | t == bstrT = bstLookup bst (fromIntegral k) >>= f
    withBStr v _ = vmPanic ("BStr op: not a BStr: " ++ render v)
    consumeBStr (VData t 0 [VInt k]) | t == bstrT = bstDelete bst (fromIntegral k)
    consumeBStr v = vmPanic ("BStr.free: not a BStr: " ++ render v)
    tidOf n = maybe (-1) (\(t, _, _) -> t) (M.lookup n cons)
    serialV k = let (t, v) = conTV "SerialPort" in VData t v [VInt (fromIntegral k)]
    serialKey (VData t _ [VInt k]) | t == tidOf "Serial" = pure (fromIntegral k)
    serialKey v = vmPanic ("Serial: not a port: " ++ render v)
    conTV n = maybe (-1, -1) (\(t, v, _) -> (t, v)) (M.lookup n cons)
    isCon n t g = conTV n == (t, g)

    readIoH v
      | Just p <- unPath v = case p of
          "/dev/in" -> VStr <$> txInput
          "/dev/fuel" -> VInt . fromIntegral <$> readIORef preempts
          _ -> VStr <$> txReadWhole p
    readIoH (VData t g [q])
      | isCon "Ls" t g = withP q (\p -> strList <$> txLs tx p)
      | isCon "Exists" t g = withP q (\p -> vBool <$> txExists tx p)
      | isCon "IsDir" t g = withP q (\p -> vBool <$> txIsDir tx p)
      | isCon "Stat" t g = withP q (\p -> do
          (e, sz, mt) <- txStat tx p
          pure (VData 5 0 [vBool e, VInt (fromIntegral sz), VInt (fromIntegral mt)]))
      | isCon "Sh" t g = withS q (\c -> do
          txMarkExternal tx "sh"
          (code, out) <- txSh c
          pure (VData 4 0 [VInt (fromIntegral code), VStr out]))
      | isCon "Now" t g = withP q (\p -> do
          markEscape "readNow"
            ("re-reads " ++ p ++ " from disk; not snapshotted, so this value "
              ++ "is not validated at commit (transactional: readPath)")
          VStr . maybe "" id <$> rtRead p)
      | isCon "NowSh" t g = withS q (\c -> do
          markEscape "shNow"
            ("streams `" ++ c ++ "` live; guarded retry stops on a later conflict "
              ++ "(transactional: shq, which runs once inside the commit)")
          pending <- txPendingBrief tx
          unless (null pending) $
            hPutStrLn stderr ("[sol] ORDER: " ++ pendingOrderBrief ("shNow `" ++ c ++ "`") "shq" pending)
          VInt . fromIntegral <$> rtShell c)
    readIoH (VData t 0 []) | t == mtimeT = VInt . round . (* 1e7) <$> getMonotonicTime
    readIoH (VData t g [])
      | isCon "NowLine" t g = do
          markEscape "readLineNow"
            "reads one line of stdin now; guarded retry stops on a later conflict (snapshot: input)"
          VStr <$> rtLine
    readIoH v = vmPanic ("read: cannot decode " ++ render v)

    writeIoH pv v = case unPath pv of
      Just "/dev/out" -> txMarkExternal tx "print" >> putStrLn (render v) >> hFlush stdout >> pure vUnit
      Just "/dev/log" -> txLog tx (render v) >> pure vUnit
      Just "/dev/sh" -> withS v (\c -> txShq tx c >> pure vUnit)
      Just "/dev/clock" -> case v of
        VInt ms -> threadDelay (fromIntegral ms * 1000) >> pure vUnit
        bad -> vmPanic ("write /dev/clock: expected ms Int, got " ++ render bad)
      Just p -> case v of
        VStr s -> txWriteWhole p s
        VData t g []
          | isCon "Dir" t g -> txMkdirp tx p >> pure vUnit
          | isCon "Rm" t g -> do
              isD <- txIsDir tx p
              if isD
                then vmPanic ("rm: " ++ p ++ " is a directory — use rmdir")
                else txRm tx p >> pure vUnit
          | isCon "RmDir" t g -> txRmdir tx p >> pure vUnit
        VData t g [sv]
          | isCon "NowSet" t g -> rtOut p sv "writeNow" rtWrite
          | isCon "NowAdd" t g -> rtOut p sv "appendNow" rtAppend
        bad -> vmPanic ("write " ++ p ++ ": cannot decode " ++ render bad)
      Nothing -> vmPanic ("write: expected a path or string, got " ++ render pv)

    rtOut p sv kind op = do
      let s = case sv of VStr x -> x; other -> render other
      markEscape kind
        ("writes " ++ p ++ " immediately; it is on disk before commit and "
          ++ "stays there if the transaction rolls back (transactional: writePath)")
      dropped <- op tx p s
      when dropped $
        hPutStrLn stderr
          ("[sol] REALTIME: " ++ p ++ " was already read in this transaction — "
            ++ "dropping it from the read set; the transaction no longer "
            ++ "guarantees anything about that path")
      pure vUnit

    toD (VInt i) = fromIntegral i
    toD (VNum d) = d
    toD v = unsafePerformIO (vmPanic ("Numeric op: not a number: " ++ render v))

    numDivH a b =
      let (x, y) = (toD a, toD b)
       in if y == 0 then vmPanic "Num.div: division by zero" else pure (VNum (x / y))
    numSqrtH a =
      let x = toD a
       in if x < 0 then vmPanic "Num.sqrt: negative" else pure (VNum (sqrt x))

    txReadWhole p = do
      h <- txOpen tx p
      s <- txHRead tx h
      txClose tx h
      pure s
    txWriteWhole p s = do
      h <- txOpen tx p
      txHWrite tx h s
      txClose tx h
      pure vUnit
    unPath (VData t 0 [VStr p]) | t == pathT = Just p
    unPath (VStr p) = Just p
    unPath _ = Nothing

    withP (VData t 0 [VStr p]) k | t == pathT = k p
    withP (VStr p) k = k p
    withP bad _ = vmPanic ("expected a path or string, got " ++ render bad)

    withS (VStr c) k = k c
    withS bad _ = vmPanic ("expected a command string, got " ++ render bad)

    strList = foldr (\x acc -> VData listT 1 [VStr x, acc]) (VData listT 0 [])
    unHandle (VData t 0 [VInt h]) | t == handleT = Just (fromIntegral h)
    unHandle _ = Nothing
    mkHandle h = VData handleT 0 [VInt (fromIntegral h)]

    openH [v] = case unPath v of
      Just p -> mkHandle <$> txOpen tx p
      Nothing -> vmPanic ("open: not a Path: " ++ render v)
    openH _ = vmPanic "open: arity"

    readH [v] = case unHandle v of
      Just h -> do
        s <- txHRead tx h
        pure (VData 4 0 [VStr s, v])
      Nothing -> vmPanic ("readAll: not a Handle: " ++ render v)
    readH _ = vmPanic "readAll: arity"

    writeH [v, VStr s] = case unHandle v of
      Just h -> txHWrite tx h s >> pure v
      Nothing -> vmPanic ("writeAll: not a Handle: " ++ render v)
    writeH _ = vmPanic "writeAll: bad args"

    closeH [v] = case unHandle v of
      Just h -> txClose tx h >> pure vUnit
      Nothing -> vmPanic ("close: not a Handle: " ++ render v)
    closeH _ = vmPanic "close: arity"

    vOk v = VData 3 0 [v]
    vErr m = VData 3 1 [VStr m]
    vErrV v = VData 3 1 [v]

    tryShH [v] = withS v $ \c -> do
      txMarkExternal tx "sh"
      r <- txShFull c
      let (tE, _) = conTV "ShError"
          shErr code out err = vErrV (VData tE 0 [VStr c, VInt (fromIntegral code), VStr out, VStr err])
      pure $ case r of
        Right (0, out, _) -> vOk (VStr out)
        Right (code, out, err) -> shErr code out err
        Left why -> shErr (-1 :: Int) "" why
    tryShH _ = vmPanic "Try.sh: arity"

    tryParseIntH [v] = do
      s <- vsStr v
      case reads (dropWhile (== ' ') s) :: [(Integer, String)] of
        [(n, rest)] | all (`elem` " \n\t") rest -> pure (vOk (VInt n))
        _ -> pure (vErr ("parseInt: not an integer: " ++ show s))
    tryParseIntH _ = vmPanic "Try.parseInt: arity"

    tryParseNumH [v] = do
      s <- vsStr v
      let t = dropWhile (== ' ') s
          tail' = all (`elem` " \n\t")
      case reads t :: [(Integer, String)] of
        [(n, rest)] | tail' rest -> pure (vOk (VInt n))
        _ -> case reads t :: [(Double, String)] of
          [(d, rest)] | tail' rest -> pure (vOk (VNum d))
          _ -> pure (vErr ("parseNum: not a number: " ++ show s))
    tryParseNumH _ = vmPanic "Try.parseNum: arity"

    tryReadPathH [v] = withP v $ \p -> do
      r <- txTryRead tx p
      pure $ case r of
        TxText s -> vOk (VStr s)
        TxMissing -> vErr ("readPath: no such file: " ++ p)
        TxNonText -> vErr ("readPath: not a UTF-8 text file: " ++ p)
        TxReadError e -> vErr ("readPath: " ++ p ++ ": " ++ e)
    tryReadPathH _ = vmPanic "Try.readPath: arity"

    fsErrV (FsErr op p why msg _) =
      VData tErr 0 [VData tOp vOp [], VStr p, VData tWhy vWhy [], VStr msg]
      where
        (tErr, _) = conTV "FsError"
        (tOp, vOp) = conTV (opCon op)
        (tWhy, vWhy) = conTV (fsWhyName why)
        opCon "ls" = "OpLs"
        opCon "stat" = "OpStat"
        opCon "lstat" = "OpLstat"
        opCon "walk" = "OpWalk"
        opCon "tempDir" = "OpTempDir"
        opCon "tempFile" = "OpTempFile"
        opCon "statKind" = "OpStatKind"
        opCon "copy" = "OpCopy"
        opCon "copyPublish" = "OpCopyPublish"
        opCon "rename" = "OpRename"
        opCon _ = "OpExists"
    kindV k = VData tK vK []
      where
        (tK, vK) = conTV (kNameOf k)
        kNameOf 0 = "KFile"
        kNameOf 1 = "KDir"
        kNameOf 2 = "KLink"
        kNameOf _ = "KOther"
    tryLsH [v] = withP v $ \p -> do
      r <- txLsE tx p
      pure $ case r of
        Left fe -> vErrV (fsErrV fe)
        Right names -> vOk (strList names)
    tryLsH _ = vmPanic "Try.ls: arity"
    tryStatH [v] = withP v $ \p -> do
      r <- txStatE tx p
      pure $ case r of
        Left fe -> vErrV (fsErrV fe)
        Right (_, sz, mt) -> vOk (VData 4 0 [VInt (fromIntegral sz), VInt (fromIntegral mt)])
    tryStatH _ = vmPanic "Try.stat: arity"
    tryExistsH [v] = withP v $ \p -> do
      r <- txExistsE tx p
      pure $ either (vErrV . fsErrV) (vOk . vBool) r
    tryExistsH _ = vmPanic "Try.exists: arity"
    tryLstatH [v] = withP v $ \p -> do
      r <- txLstatE tx p
      pure $ either (vErrV . fsErrV) (vOk . kindV) r
    tryLstatH _ = vmPanic "Try.lstat: arity"
    tryStatKindH [v] = withP v $ \p -> do
      r <- txStatKindE tx p
      pure $ either (vErrV . fsErrV) (vOk . kindV) r
    tryStatKindH _ = vmPanic "Try.statKind: arity"
    tryWalkH [v, VInt d, VInt n, f] = withP v $ \p -> do
      r <- if d < 1 || d > 4096 || n < 1 || n > 10000000
        then pure (Left (FsErr "walk" p WhyLimit "depth must be 1..4096 and entries 1..10000000" ""))
        else txWalkE tx p (fromIntegral d) (fromIntegral n) (isTrueV f)
      pure $ case r of
        Left fe -> vErrV (fsErrV fe)
        Right es ->
          let (tW, _) = conTV "WalkEntry"
              (_, vW) = conTV "WalkEntry"
              walkEntryV (p', k, dep) = VData tW vW [VStr p', kindV k, VInt (fromIntegral dep)]
           in vOk (foldr (\x xs -> VData listT 1 [x, xs]) (VData listT 0 []) (map walkEntryV es))
    tryWalkH _ = vmPanic "Try.walk: path depth(1..4096) entries(1..10000000) follow"
    tryTempDirH [v] = withP v $ \p -> do
      r <- txTempDir tx p
      pure $ either (vErrV . fsErrV) (vOk . VStr) r
    tryTempDirH _ = vmPanic "Try.tempDir: arity"
    tryTempFileH [v] = withP v $ \p -> do
      r <- txTempFile tx p
      pure $ either (vErrV . fsErrV) (vOk . VStr) r
    tryTempFileH _ = vmPanic "Try.tempFile: arity"
    isTrueV (VData 1 1 []) = True
    isTrueV _ = False

    hostSnapshotH [VInt limit] | limit > 0 && limit <= 1000000 = do
      result <- nativeHost (fromInteger limit)
      date <- formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" <$> getCurrentTime
      pure $ case result of
        Left why -> vErr why
        Right rows ->
          let hosts = [(host,os) | (0,_,_,host,os) <- rows]
              uptime = sum [n | (1,n,_,_,_) <- rows]
              tuple fields = VData (if length fields == 3 then 5 else 12) 0 fields
              disks = listValue [tuple [VStr path,VInt total,VInt available] | (2,total,available,path,_) <- rows]
              processes = listValue [tuple [VInt pid,VInt ppid,VStr name] | (3,pid,ppid,name,_) <- rows]
          in case hosts of
            [(host,os)] -> vOk (tuple [VStr date,VStr host,VStr os,VInt uptime,disks,processes])
            _ -> vErr "missing native host facts"
    hostSnapshotH _ = pure (vErr "host observation limit must be 1..1000000")
    listValue = foldr (\x xs -> VData listT 1 [x,xs]) (VData listT 0 [])

    gitOp (VData t op fields) | t == tidOf "GitInit" = do
      (arg, paths) <- case fields of
        [] -> pure ("", [])
        [VStr a] -> pure (a, [])
        [VStr a, ps] -> (\xs -> (a,xs)) <$> stringValues "Git paths" ps
        [VInt n] | n >= 0 && n <= 100000 -> pure (show n, [])
        _ -> vmPanic "invalid native Git fields or log count (0..100000)"
      pure (op,arg,paths)
    gitOp _ = vmPanic "expected GitOperation"
    gitAfterCommitH [VInt limit,VStr path,VStr name,VStr email,v] = do
      (op,arg,paths) <- gitOp v
      if op >= 10 then vmPanic "only Git mutations may be deferred" else
        pushEffect tx (EGit (GitRequest path op arg name email paths limit)) >> pure vUnit
    gitAfterCommitH _ = vmPanic "NativeGit.afterCommit: arguments"
    gitQueryH [VInt limit,VStr path,v] = do
      (op,arg,paths) <- gitOp v
      if op < 10 || op > 14 then pure (vErr "Git query requires a read operation") else
        nativeGit (GitRequest path op arg "" "" paths limit) >>= pure . either vErr (vOk . VStr)
    gitQueryH _ = vmPanic "NativeGit.query: arguments"
    gitPushH [VInt limit,VStr path,VStr remote,VStr branch] = do
      pending <- txPendingBrief tx
      if not (null pending) then pure (vErr (pendingOrderMsg "Git.push" "Git.commit in a separate run" pending)) else do
        markEscape "Git.push" "publishes immediately through libgit2; survives rollback; guarded retry stops on a later conflict"
        nativeGit (GitRequest path 15 remote "" "" [branch] limit) >>= pure . either vErr (vOk . VStr)
    gitPushH _ = vmPanic "NativeGit.push: arguments"
    archiveAfterCommitH [VStr source,VStr target,VInt entries,VInt bytes]
      | entries > 0 && entries <= toInteger (maxBound :: Int64)
      , bytes > 0 && bytes <= toInteger (maxBound :: Int64) =
          pushEffect tx (EArchive source target entries bytes) >> pure vUnit
    archiveAfterCommitH _ = vmPanic "archive limits must be positive signed 64-bit integers"

    deferredValue step = do
      (owner,ref) <- txLater tx step
      pure (VDeferred owner ref)
    deferredRef (VDeferred owner ref) = do
      identity <- txIdentity <$> readIORef tx
      if identity == Just owner then pure ref else vmPanic "Deferred belongs to another transaction attempt"
    deferredRef _ = vmPanic "expected an opaque Deferred value"
    projectH projection [v] = do
      ref <- deferredRef v
      case (v,ref) of
        (VDeferred owner _,DeferredRef i ps) -> pure (VDeferred owner (DeferredRef i (ps ++ [projection])))
        _ -> vmPanic "invalid Deferred projection"
    projectH _ _ = vmPanic "Deferred projection arity"
    deferredLineH [VInt n,v] | n > 0 && n <= toInteger (maxBound :: Int) = projectH (Line (fromInteger n)) [v]
    deferredLineH _ = vmPanic "Deferred.line index must be a positive host-sized integer (one-based)"
    deferredFieldH [VStr separator,VInt n,v]
      | not (null separator), n > 0 && n <= toInteger (maxBound :: Int) = projectH (Field separator (fromInteger n)) [v]
    deferredFieldH _ = vmPanic "Deferred.field needs a nonempty separator and positive one-based index"
    logToH [VStr path,value] = txLogTo tx path (render value) >> pure vUnit
    logToH _ = vmPanic "logTo: expected path and value"
    procLaterH [VData t 0 [argvV,VStr cwdV,envV,VStr stdinV,VInt timeoutV]] | t == processSpecT = do
      argv <- argumentValues argvV
      envPairs <- envValues envV
      deferredValue (PlannedProcess argv (ProcessSpec [] (if null cwdV then Nothing else Just cwdV) envPairs stdinV
        (if timeoutV <= 0 then Nothing else Just (fromInteger (min timeoutV (toInteger (maxBound :: Int)))))))
    procLaterH _ = vmPanic "Proc.later: expected ProcessSpec Arg"
    argumentValues (VData t 0 []) | t == listT = pure []
    argumentValues (VData t 1 [arg,rest]) | t == listT = do
      decoded <- case arg of
        VData a variant [VStr text] | isCon "Lit" a variant -> pure (LiteralArg text)
        VData a variant [value] | isCon "From" a variant -> FromArg <$> deferredRef value
        _ -> vmPanic "Proc.later argv needs Lit String or From (Deferred String)"
      (decoded:) <$> argumentValues rest
    argumentValues _ = vmPanic "Proc.later: expected List Arg"
    gitHeadLaterH [VInt limit,VStr path] = deferredValue (PlannedGit (GitRequest path 14 "" "" "" [] limit))
    gitHeadLaterH _ = vmPanic "NativeGit.headLater: arguments"
    gitTagAtH [VInt limit,VStr path,VStr name,value] = do
      ref <- deferredRef value
      _ <- txLater tx (PlannedTag path name ref limit)
      pure vUnit
    gitTagAtH _ = vmPanic "NativeGit.tagAt: arguments"
    gitPushLaterH [VInt limit,VStr path,VStr remote,VStr branch] = do
      _ <- txLater tx (PlannedGit (GitRequest path 15 remote "" "" [branch] limit))
      pure vUnit
    gitPushLaterH _ = vmPanic "NativeGit.pushLater: arguments"
    gitCommitNowH [VInt limit,VStr path,VStr name,VStr email,VStr message] = do
      result <- txGitCommitNow tx limit path name email message
      case result of
        Left why -> pure (vErr why)
        Right sha -> do
          noteEscape rt "Git.commitNow" "publishes a commit now; abort/retry uses a journaled reference CAS inverse (not isolation)"
          pure (vOk (VStr sha))
    gitCommitNowH _ = vmPanic "NativeGit.commitNow: arguments"

    processHal name [value] | name `elem` ["Proc.pipeline", "Proc.start"] = do
      spec <- decodePipeline value
      blocked <- guardImmediate name
      case blocked of
        Just why -> pure (vErrV (processError (Process.Failure why 0 "ordering" 0)))
        Nothing -> if name == "Proc.pipeline"
          then processResult <$> Process.run spec
          else do
            io <- txProcessRuntime tx
            key <- Process.start io spec
            pure (vOk (VProcessJob (Process.identity io) key))
    processHal "Proc.wait" [value] = do
      (io,key) <- processJob value
      processResult <$> Process.wait io key
    processHal "Proc.cancel" [value] = do
      (io,key) <- processJob value
      either (vErrV . processError) (const (vOk vUnit)) <$> Process.cancel io key
    processHal "Proc.poll" [value] = do
      (io,key) <- processJob value
      r <- Process.poll io key
      pure (tupleV (either (vErrV . processError) (vOk . vBool) r) value)
    processHal name _ = vmPanic (name ++ ": invalid arguments")
    processJob (VProcessJob owner key) = do
      io <- txProcessRuntime tx
      if owner == Process.identity io then pure (io,key) else vmPanic "process job belongs to another attempt"
    processJob _ = vmPanic "expected an opaque process job"
    processError (Process.Failure reason stage channel cap) =
      let (t,v) = conTV "ProcessError" in VData t v [VStr reason,VInt (fromIntegral stage),VStr channel,VInt (fromIntegral cap)]
    processResult (Left e) = vErrV (processError e)
    processResult (Right (Process.Result status stages out errs)) =
      let (t,v) = conTV "PipelineResult" in vOk (VData t v [VInt (fromIntegral status),
            intList stages,VBytes out,foldr (\b xs -> VData listT 1 [VBytes b,xs]) (VData listT 0 []) errs])
    intList = foldr (\n xs -> VData listT 1 [VInt (fromIntegral n),xs]) (VData listT 0 [])
    decodePipeline (VData t v [stages,input,output,errors,VInt ms,policy]) | isCon "PipelineSpec" t v = do
      specs <- listVals stages >>= mapM decodeProcessSpec
      source <- case input of
        VData a b [VBytes bytes] | isCon "PipeBytes" a b -> pure (Process.InputBytes bytes)
        VData a b [VStr path] | isCon "PipeFile" a b -> pure (Process.InputFile path)
        VData a b [] | isCon "PipeInputInherit" a b -> pure Process.InputInherit
        _ -> vmPanic "invalid pipe input"
      sink <- decodeSink output
      err <- decodeSink errors
      aggregate <- case policy of
        VData a b [] | isCon "PipeLast" a b -> pure Process.LastStage
        VData a b [] | isCon "PipeFail" a b -> pure Process.PipeFail
        _ -> vmPanic "invalid pipe failure policy"
      pure (Process.Pipeline specs source sink err (if ms >= 0 && ms <= 86400000 then fromInteger ms else -1) aggregate)
    decodePipeline _ = vmPanic "expected PipelineSpec"
    decodeSink (VData a b [VInt cap]) | isCon "PipeCapture" a b =
      pure (Process.Capture (if cap >= 0 && cap <= 16777216 then fromInteger cap else -1))
    decodeSink (VData a b [VStr path]) | isCon "PipeFileNew" a b = pure (Process.FileNew path)
    decodeSink (VData a b [VStr path,replace]) | isCon "PipePublish" a b = pure (Process.Publish path (isTrueV replace))
    decodeSink (VData a b []) | isCon "PipeOutputInherit" a b = pure Process.OutputInherit
    decodeSink (VData a b []) | isCon "PipeDiscard" a b = pure Process.Discard
    decodeSink _ = vmPanic "invalid pipe output"

    procQueryH [v] = txMarkExternal tx "Proc.query" >> (decodeProcessSpec v >>= runProcessH)
    procQueryH _ = vmPanic "Proc.query: arity"

    procAfterCommitH [v] = do
      spec <- decodeProcessSpec v
      txProcessAfterCommit tx spec
      pure vUnit
    procAfterCommitH _ = vmPanic "Proc.afterCommit: arity"

    procRunNowH [v] = do
      spec <- decodeProcessSpec v
      pending <- txPendingBrief tx
      if not (null pending)
        then pure (vErr (pendingOrderMsg ("Proc.runNow " ++ displayProcess spec) "Proc.afterCommit" pending))
        else do
          markEscape "Proc.runNow"
            ("runs " ++ displayProcess spec ++ " immediately; it survives rollback; "
              ++ "guarded retry stops on a later conflict (deferred: Proc.afterCommit)")
          runProcessH spec
    procRunNowH _ = vmPanic "Proc.runNow: arity"

    procDirectH name mode [v] = do
      spec <- decodeProcessSpec v
      pending <- txPendingBrief tx
      if not (null pending)
        then pure (vErr (pendingOrderMsg (name ++ " " ++ displayProcess spec) "Proc.afterCommit" pending))
        else do
          hFlush stdout
          hFlush stderr
          markEscape name ("runs " ++ displayProcess spec ++ " with live I/O; survives rollback; guarded retry stops on a later conflict")
          result <- runProcessMode mode spec
          pure $ case result of
            Left err -> vErr ("process " ++ displayProcess spec ++ ": " ++ err)
            Right (code, _, _) -> vOk (VInt (fromIntegral code))
    procDirectH name _ _ = vmPanic (name ++ ": arity")

    runProcessH spec = do
      result <- runProcessSpec spec
      pure $ case result of
        Left err -> vErr ("process " ++ displayProcess spec ++ ": " ++ err)
        Right (code, out, err) ->
          vOk (VData processResultT 0 [VInt (fromIntegral code), VStr out, VStr err])

    decodeProcessSpec (VData t 0 [argvV, VStr cwdV, envV, VStr stdinV, VInt timeoutV])
      | t == processSpecT = do
          argv <- stringValues "argv" argvV
          envPairs <- envValues envV
          pure ProcessSpec
            { psArgv = argv,
              psCwd = if null cwdV then Nothing else Just cwdV,
              psEnv = envPairs,
              psStdin = stdinV,
              psTimeoutMs = if timeoutV <= 0 then Nothing else Just (fromInteger (min timeoutV (toInteger (maxBound :: Int))))
            }
    decodeProcessSpec bad = vmPanic ("process: expected ProcessSpec, got " ++ render bad)

    stringValues label = go
      where
        go (VData t 1 [VStr x, rest]) | t == listT = (x :) <$> go rest
        go (VData t 0 []) | t == listT = pure []
        go bad = vmPanic ("process " ++ label ++ ": expected List String, got " ++ render bad)

    envValues = go
      where
        go (VData t 1 [VData 4 0 [VStr key, VStr value], rest]) | t == listT =
          ((key, value) :) <$> go rest
        go (VData t 0 []) | t == listT = pure []
        go bad = vmPanic ("process env: expected List (String, String), got " ++ render bad)

    charAtH [sv, VInt i]
      | Just a <- stringIndex sv, Just n <- stringLength sv =
          if i >= 0 && i < fromIntegral n
            then pure (VInt (fromIntegral (fromEnum (a ! fromInteger (i + 1)))))
            else vmPanic "charAt: index out of range"
    charAtH _ = vmPanic "charAt: bad args"
    codeAt sv k = charAtH [sv, VInt k] >>= \case VInt c -> pure c; _ -> vmPanic "charAt: bad args"
    findByteH [sv, VInt c, VInt i, VInt n] = go i
      where go k | k >= n = pure (VInt (-1))
                 | otherwise = codeAt sv k >>= \b -> if b == c then pure (VInt k) else go (k + 1)
    findByteH _ = vmPanic "strFindByte: bad args"
    findSpaceH [sv, VInt pos, VInt n] = go pos
      where go k | k >= n = pure (VInt n)
                 | otherwise = codeAt sv k >>= \b -> if b == 32 || (b >= 9 && b <= 13) then pure (VInt k) else go (k + 1)
    findSpaceH _ = vmPanic "strFindSpace: bad args"
    digitsH [sv, VInt i, VInt n] = go i 0
      where lo = negate (2 ^ (62 :: Int))
            go k acc
              | k >= n = pure (VInt acc)
              | otherwise = codeAt sv k >>= \c ->
                  let d = c - 48
                      next = go (k + 1) (acc * 10 - d)
                   in if c < 48 || c > 57 then pure (VInt 1)
                      else if acc > lo `quot` 10 then (if acc <= 0 then next else pure (VInt 2))
                      else if acc > 0 then pure (VInt 2)
                      else if acc < (lo + d) `quot` 10 then pure (VInt 2)
                      else next
    digitsH _ = vmPanic "strDigits: bad args"
    substrH [sv, VInt o0, VInt l0]
      | Just a <- stringIndex sv, Just size <- stringLength sv = do
          let n = fromIntegral size :: Integer
              o = max 0 o0
              count = max 0 (min (l0 + min 0 o0) (n - o))
          pure (VStr [a ! fromInteger (i + 1) | i <- [o .. o + count - 1]])
    substrH _ = vmPanic "substr: bad args"
    listItems :: Value -> [Value]
    listItems (VData t 1 [x, r]) | t == listT = x : listItems r
    listItems _ = []
    splitCodes :: Char -> String -> [String]
    splitCodes _ "" = []
    splitCodes c s = case break (== c) s of
      (pre, []) -> [pre]
      (pre, _ : rest) -> pre : splitCodes c rest
    indexOfStr :: String -> String -> Int
    indexOfStr "" _ = -1
    indexOfStr p s = go 0 s
      where
        go _ [] = -1
        go i t@(_ : r) = if startsWithStr p t then i else go (i + 1) r
    startsWithStr :: String -> String -> Bool
    startsWithStr [] _ = True
    startsWithStr _ [] = False
    startsWithStr (a : as) (b : bs) = a == b && startsWithStr as bs
    replaceStr :: String -> String -> String -> String
    replaceStr "" _ s = s
    replaceStr o n s = go s
      where
        go [] = []
        go t@(ch : r) = if startsWithStr o t then n ++ go (drop (length o) t) else ch : go r
    trimStr :: String -> String
    trimStr = dropWhileEnd' isSp . dropWhile isSp
      where
        isSp ch = ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r'
        dropWhileEnd' f = reverse . dropWhile f . reverse

    indexH [xs, VInt i] = idx xs i
      where
        idx (VVec r) k = getVec r (fromIntegral k)
        idx (VData t 1 [x, _]) 0 | t == listT = pure x
        idx (VData t 1 [_, r]) k | t == listT = idx r (k - 1)
        idx _ _ = vmPanic "!: index out of range"
    indexH _ = vmPanic "!: bad args"
