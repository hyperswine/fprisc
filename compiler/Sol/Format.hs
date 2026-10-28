{-# LANGUAGE BangPatterns #-}
module Sol.Format where

import Control.Monad (unless, when)
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as I
import Data.Char (ord, digitToInt)
import Data.List (foldl')
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (castPtr, plusPtr)
import qualified Sol.ScriptIO as S

api :: [(String,Int,String)]
api = [("Format.json",5,"Int -> Int -> Int -> Int -> String -> Result Unit String")
      ,("Format.csv",6,"Int -> Int -> Int -> Int -> Int -> String -> Result (List (List String)) String")
      ,("Stream.readCsv",4,"Int -> Int -> Int -> ByteReader -> (Result CsvRead String, ByteReader)")
      ,("Stream.foldCsv",6,"(a -> List String -> a) -> a -> Int -> Int -> Int -> ByteReader -> (Result a String, ByteReader)")]

width :: Char -> Either String Int
width c | n >= 0xD800 && n <= 0xDFFF = Left "invalid Unicode surrogate"
        | n < 128 = Right 1
        | n < 2048 = Right 2
        | n < 65536 = Right 3
        | otherwise = Right 4
  where n=ord c

textBudget :: Int -> String -> Either String ()
textBudget limit = go 0
  where go !_ [] = Right ()
        go !n (c:cs) = do
          w <- width c
          if w > limit-n then Left "input UTF-8 byte limit exceeded" else go (n+w) cs

range :: String -> Int -> Int -> Int -> Either String ()
range label lower upper n = unless (n>=lower && n<=upper)
  (Left (label ++ " must be " ++ show lower ++ ".." ++ show upper))

-- Admission scan, before the Sol JSON parser constructs a tree. It tracks
-- container depth/items and decoded UTF-8 string sizes, including escapes.
-- Number/value grammar remains the library parser's authority.
jsonAdmission :: Int -> Int -> Int -> Int -> String -> Either String ()
jsonAdmission input depth items field text = do
  range "JSON input budget" 0 16777216 input
  range "JSON depth budget" 1 256 depth
  range "JSON container item budget" 0 1000000 items
  range "JSON field budget" 0 16777216 field
  textBudget input text
  scan [] text
  where
    scan _ [] = Right () -- incomplete syntax is refused by the JSON parser
    scan stack (c:cs)
      | c `elem` " \t\r\n" = scan stack cs
      | c == ',' = case stack of
          (kind,n,_):rest -> scan ((kind,n,True):rest) cs
          [] -> scan [] cs
      | c `elem` "]}" = case stack of
          (kind,_,_):rest | (kind,c) `elem` [('[' ,']'),('{' ,'}')] -> scan rest cs
          _ -> Left "json: mismatched container"
      | otherwise = do
          entered <- case stack of
            (kind,n,True):rest -> if n>=items then Left "json: container item limit exceeded"
                                  else Right ((kind,n+1,False):rest)
            _ -> Right stack
          if c `elem` "[{" then do
            when (length entered>=depth) (Left "json: nesting depth limit exceeded")
            scan ((c,0,True):entered) cs
          else if c=='"' then string field cs >>= scan entered
          else scan entered cs
    string _ [] = Left "json: unterminated string"
    string left ('"':rest) = Right rest
    string left ('\\':c:rest)
      | c `elem` "\"\\/bfnrt" = consume left 1 rest
      | c=='u' = do
          (n,tail1) <- hex4 rest
          if n>=0xD800 && n<=0xDBFF then case tail1 of
            '\\':'u':tail2 -> do
              (low,tail3) <- hex4 tail2
              if low>=0xDC00 && low<=0xDFFF then consume left 4 tail3
                else Left "json: invalid low surrogate"
            _ -> Left "json: missing low surrogate"
          else if n>=0xDC00 && n<=0xDFFF then Left "json: unpaired low surrogate"
          else consume left (if n<128 then 1 else if n<2048 then 2 else 3) tail1
      | otherwise = Left "json: invalid escape"
    string _ ['\\'] = Left "json: incomplete escape"
    string left (c:rest) = do
      when (ord c<32) (Left "json: raw control in string")
      w <- width c
      consume left w rest
    consume left n rest = if n>left then Left "json: decoded field byte limit exceeded"
                         else string (left-n) rest
    hex4 chars = case splitAt 4 chars of
      (digits,rest) | length digits==4 && all (`elem` "0123456789abcdefABCDEF") digits ->
        Right (foldl' (\n c -> 16*n+digitToInt c) 0 digits,rest)
      _ -> Left "json: invalid Unicode escape"

csvLimits :: Int -> Int -> Int -> Either String ()
csvLimits fields field record = do
  range "CSV field count" 0 65536 fields
  range "CSV decoded field byte budget" 0 16777216 field
  range "CSV record byte budget" 1 16777216 record

-- Framing state: field start, unquoted, quoted, after quote, after CR.
csvStep :: Int -> Word -> Either String (Int,Bool)
csvStep mode byte = case (mode,byte) of
  (2,34) -> Right (3,False)
  (2,_) -> Right (2,False)
  (3,34) -> Right (2,False)
  (4,10) -> Right (0,True)
  (4,_) -> Left "csv: bare CR outside quoted field"
  (0,34) -> Right (2,False)
  (1,34) -> Left "csv: quote inside unquoted field"
  (_,44) -> Right (0,False)
  (_,10) -> Right (0,True)
  (_,13) -> Right (4,False)
  (3,_) -> Left "csv: expected separator after quote"
  _ -> Right (1,False)

recordEnd :: Int -> B.ByteString -> Either String Int
recordEnd limit bytes = go 0 0
  where
    go !i !mode
      | i==B.length bytes = if mode==2 then Left "csv: unterminated quote"
                            else if mode==4 then Left "csv: bare CR outside quoted field" else Right i
      | i>=limit = Left "csv: record byte limit exceeded"
      | otherwise = do
          (next,ended) <- csvStep mode (fromIntegral (B.index bytes i))
          if ended then Right (i+1) else go (i+1) next

parseRecord :: Int -> Int -> B.ByteString -> Either String [String]
parseRecord fields field bytes = do
  text <- S.decodeUtf8 (strip bytes)
  go 0 [] 0 (0,[]) text
  where
    strip b | not (B.null b) && B.last b==10 =
                let a=B.init b in if not (B.null a) && B.last a==13 then B.init a else a
            | otherwise = b
    add mode acc n row c rest = do
      w <- width c
      when (w>field-n) (Left "csv: decoded field byte limit exceeded")
      go mode (c:acc) (n+w) row rest
    finishField acc (count,row) = do
      when (count>=fields) (Left "csv: field count limit exceeded")
      Right (count+1,reverse acc:row)
    go mode acc _ row [] = if mode==2 then Left "csv: unterminated quote"
                          else reverse . snd <$> finishField acc row
    go 2 acc n row ('"':rest) = go 3 acc n row rest
    go 2 acc n row (c:rest) = add 2 acc n row c rest
    go 3 acc n row ('"':rest) = add 2 acc n row '"' rest
    go 0 acc n row ('"':rest) = go 2 acc n row rest
    go _ acc _ row (',':rest) = finishField acc row >>= \r -> go 0 [] 0 r rest
    go 3 _ _ _ _ = Left "csv: expected separator after quote"
    go _ _ _ _ ('"':_) = Left "csv: quote inside unquoted field"
    go _ _ _ _ (c:_) | c=='\r' || c=='\n' = Left "csv: bare record separator"
    go _ acc n row (c:rest) = add 1 acc n row c rest

csv :: Int -> Int -> Int -> Int -> Int -> String -> Either String [[String]]
csv input records fields field record text = do
  range "CSV input budget" 0 16777216 input
  range "CSV record count" 0 1000000 records
  csvLimits fields field record
  textBudget input text
  bytes <- S.encodeUtf8 text
  go 0 [] bytes
  where
    go !_ rows bytes | B.null bytes = Right (reverse rows)
    go !n rows bytes = do
      when (n>=records) (Left "csv: record count limit exceeded")
      size <- recordEnd record bytes
      row <- parseRecord fields field (B.take size bytes)
      go (n+1) (row:rows) (B.drop size bytes)

-- A single admitted mutable buffer holds the current record, even when a
-- quoted field contains millions of tiny physical lines. Reader read-ahead is
-- retained in its existing cell. No whole input/file is retained by iteration.
readCsv :: S.Runtime -> Int -> Int -> Int -> Int -> IO (Either String (Maybe [String]))
readCsv runtime fields field record key = case csvLimits fields field record of
  Left why -> pure (Left why)
  Right () -> S.attempt $ do
    cell <- S.getResource runtime key
    first <- S.readLineCell record cell
    case first of
      Nothing -> pure Nothing
      Just bytes -> do
        (mode,ended) <- either S.failIO pure (B.foldl' advance (Right (0,False)) bytes)
        raw <- if ended || B.last bytes/=10 then do
          when (mode==2) (S.failIO "csv: unterminated quote")
          when (mode==4) (S.failIO "csv: bare CR outside quoted field")
          pure bytes
          else I.createAndTrim record $ \target -> do
            B.useAsCStringLen bytes $ \(source,n) -> copyBytes target (castPtr source) n
            gather cell target (B.length bytes) mode
        either S.failIO (pure . Just) (parseRecord fields field raw)
  where
    gather cell target !size !mode = do
      when (size>=record) (S.failIO "csv: record byte limit exceeded")
      line <- S.readLineCell (record-size) cell
      case line of
        Nothing -> if mode==2 then S.failIO "csv: unterminated quote"
                   else if mode==4 then S.failIO "csv: bare CR outside quoted field" else pure size
        Just bytes -> do
          (next,ended) <- either S.failIO pure (B.foldl' advance (Right (mode,False)) bytes)
          B.useAsCStringLen bytes $ \(source,n) -> copyBytes (target `plusPtr` size) (castPtr source) n
          let total=size+B.length bytes
          if ended then pure total
          else if B.last bytes/=10 then
            if next==2 then S.failIO "csv: unterminated quote"
            else if next==4 then S.failIO "csv: bare CR outside quoted field" else pure total
          else gather cell target total next
    advance previous byte = do
      (mode,ended) <- previous
      if ended then Left "csv: unexpected data after record boundary" else csvStep mode (fromIntegral byte)
