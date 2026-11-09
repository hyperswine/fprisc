{-# LANGUAGE BangPatterns #-}
-- | std/mutmap's engine in the sketch tier (the native one is runtime/vec.c,
-- the MutMap section; docs/2026-11-10-MUTMAP.md).  The hashes are the
-- native 64-bit ones bit for bit (Strings hashed as their UTF-8 bytes), and
-- the table is the same linear-probing table, so slot order agrees with a
-- 64-bit native build.  The map is linear, so the IORef is never shared.
module Sol.MutMap
  ( intHash64, bytesHash64, strHashV, intHashV,
    newMutMap, mmReserve, mmInsert, mmInsertWith, mmSlot, mmValueAt, mmSetAt,
    mmRemoveAt, mmRemove, mmSize, mmCapacity, mmEntries
  ) where

import Data.Bits (rotateL, shiftR, xor, (.&.), (.|.), shiftL)
import qualified Data.ByteString as BS
import qualified Data.ByteString.UTF8 as BSU
import Data.IORef
import qualified Data.IntMap.Strict as IM
import Data.Word (Word64)
import Sol.Val

intHash64 :: Word64 -> Word64
intHash64 k =
  let z0 = k + 0x9E3779B97F4A7C15
      z1 = (z0 `xor` (z0 `shiftR` 30)) * 0xBF58476D1CE4E5B9
      z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94D049BB133111EB
   in z2 `xor` (z2 `shiftR` 31)

p1, p2, p3, p4, p5 :: Word64
p1 = 0x9E3779B185EBCA87
p2 = 0xC2B2AE3D27D4EB4F
p3 = 0x165667B19E3779F9
p4 = 0x85EBCA77C2B2AE63
p5 = 0x27D4EB2F165667C5

bytesHash64 :: BS.ByteString -> Word64
bytesHash64 bs = avalanche (tailBytes (four (eights (p5 + n) 0)))
  where
    len = BS.length bs
    n = fromIntegral len :: Word64
    word i k = foldr (\b acc -> (acc `shiftL` 8) .|. fromIntegral (BS.index bs (i + b))) 0 [0 .. k - 1]
    eights !h !i
      | i + 8 <= len =
          let w = rotateL (word i 8 * p2) 31 * p1
           in eights (rotateL (h `xor` w) 27 * p1 + p4) (i + 8)
      | otherwise = (h, i)
    four (h, i)
      | i + 4 <= len = (rotateL (h `xor` (word i 4 * p1)) 23 * p2 + p3, i + 4)
      | otherwise = (h, i)
    tailBytes (h, i)
      | i < len = tailBytes (rotateL (h `xor` (fromIntegral (BS.index bs i) * p5)) 11 * p1, i + 1)
      | otherwise = h
    avalanche h0 =
      let h1 = (h0 `xor` (h0 `shiftR` 33)) * p2
          h2 = (h1 `xor` (h1 `shiftR` 29)) * p3
       in h2 `xor` (h2 `shiftR` 32)

top :: Word64
top = 1 `shiftL` 63

strHashV :: String -> Value
strHashV s = VInt (toInteger (bytesHash64 (BSU.fromString s) `shiftR` 2))

intHashV :: Integer -> Value
intHashV k = VInt (toInteger (intHash64 (fromInteger k) `shiftR` 2))

keyHash :: MutMapStore -> Value -> IO Word64
keyHash st k
  | mmStrKeys st = case k of
      VStr s -> pure (bytesHash64 (BSU.fromString s) .|. top)
      _ -> vmFail "MutMap: a String-keyed map got a non-String key"
  | otherwise = case k of
      VInt i -> pure (intHash64 (fromInteger i) .|. top)
      _ -> vmFail "MutMap: an Int-keyed map got a non-Int key"

keyEq :: Value -> Value -> Bool
keyEq (VInt a) (VInt b) = a == b
keyEq (VStr a) (VStr b) = a == b
keyEq _ _ = False

vmFail :: String -> IO a
vmFail msg = ioError (userError ("*** SOL PANIC: " ++ msg ++ " ***"))

minCap :: Int
minCap = 8

capFor :: Int -> Int
capFor n = go minCap where go c = if c - c `div` 4 >= n then c else go (c * 2)

newMutMap :: Bool -> Integer -> IO Value
newMutMap strKeys n = VMutMap <$> newIORef (MutMapStore strKeys (if n > 0 then capFor (fromInteger n) else 0) 0 IM.empty)

-- (the slot holding k, or Nothing; the first empty slot of the probe)
find :: MutMapStore -> Value -> Word64 -> (Maybe Int, Maybe Int)
find st k h
  | cap == 0 = (Nothing, Nothing)
  | otherwise = go (fromIntegral (h .&. fromIntegral (cap - 1))) 0
  where
    cap = mmCap st
    go i n
      | n >= cap = (Nothing, Nothing)
      | otherwise = case IM.lookup i (mmSlots st) of
          Nothing -> (Nothing, Just i)
          Just (h', k', _)
            | h' == h && keyEq k' k -> (Just i, Nothing)
            | otherwise -> go ((i + 1) `mod` cap) (n + 1)

firstEmpty :: Int -> IM.IntMap a -> Word64 -> Int
firstEmpty cap slots h = go (fromIntegral (h .&. fromIntegral (cap - 1)))
  where go i = if IM.member i slots then go ((i + 1) `mod` cap) else i

rehash :: Int -> MutMapStore -> MutMapStore
rehash ncap st = st {mmCap = ncap, mmSlots = foldl place IM.empty (IM.elems (mmSlots st))}
  where place acc e@(h, _, _) = IM.insert (firstEmpty ncap acc h) e acc

mmReserve :: Integer -> IORef MutMapStore -> IO ()
mmReserve n r
  | n <= 0 = pure ()
  | otherwise = modifyIORef' r (\st -> let c = capFor (fromInteger n) in if c > mmCap st then rehash c st else st)

placeNew :: MutMapStore -> Value -> Word64 -> Value -> Maybe Int -> MutMapStore
placeNew st0 k h v empty =
  let cap = mmCap st0
      grow = cap == 0 || mmCount st0 + 1 > cap - cap `div` 4 || empty == Nothing
      st = if grow then rehash (if cap == 0 then minCap else cap * 2) st0 else st0
      slot = case (grow, empty) of
        (False, Just e) -> e
        _ -> firstEmpty (mmCap st) (mmSlots st) h
   in st {mmCount = mmCount st + 1, mmSlots = IM.insert slot (h, k, v) (mmSlots st)}

mmInsert :: Value -> Value -> IORef MutMapStore -> IO ()
mmInsert k v r = do
  st <- readIORef r
  h <- keyHash st k
  writeIORef r $! case find st k h of
    (Just i, _) -> st {mmSlots = IM.adjust (\(h', k', _) -> (h', k', v)) i (mmSlots st)}
    (Nothing, e) -> placeNew st k h v e

mmInsertWith :: (Value -> Value -> IO Value) -> Value -> Value -> IORef MutMapStore -> IO ()
mmInsertWith f k v r = do
  st <- readIORef r
  h <- keyHash st k
  case find st k h of
    (Just i, _) -> do
      let (h', k', old) = mmSlots st IM.! i
      new <- f old v
      writeIORef r $! st {mmSlots = IM.insert i (h', k', new) (mmSlots st)}
    (Nothing, e) -> writeIORef r $! placeNew st k h v e

mmSlot :: Value -> IORef MutMapStore -> IO Integer
mmSlot k r = do
  st <- readIORef r
  h <- keyHash st k
  pure (maybe (-1) toInteger (fst (find st k h)))

occupied :: MutMapStore -> Integer -> IO (Word64, Value, Value)
occupied st i = case IM.lookup (fromInteger i) (mmSlots st) of
  Just e | i >= 0 && i < toInteger (mmCap st) -> pure e
  _ -> vmFail "MutMap: not an occupied slot"

mmValueAt :: Integer -> IORef MutMapStore -> IO Value
mmValueAt i r = do
  st <- readIORef r
  (_, _, v) <- occupied st i
  pure v

mmSetAt :: Integer -> Value -> IORef MutMapStore -> IO ()
mmSetAt i v r = do
  st <- readIORef r
  (h, k, _) <- occupied st i
  writeIORef r $! st {mmSlots = IM.insert (fromInteger i) (h, k, v) (mmSlots st)}

-- backward shift, as vec.c mm_delete
delete :: Int -> MutMapStore -> MutMapStore
delete i0 st = st {mmCount = mmCount st - 1, mmSlots = go i0 i0 (mmSlots st)}
  where
    cap = mmCap st
    mask = fromIntegral (cap - 1) :: Word64
    go i j slots =
      let j' = (j + 1) `mod` cap
       in case IM.lookup j' slots of
            Nothing -> IM.delete i slots
            Just e@(h, _, _) ->
              let home = fromIntegral (h .&. mask)
                  inside = if i <= j' then home > i && home <= j' else home > i || home <= j'
               in if inside then go i j' slots else go j' j' (IM.insert i e slots)

mmRemoveAt :: Integer -> IORef MutMapStore -> IO ()
mmRemoveAt i r = do
  st <- readIORef r
  _ <- occupied st i
  writeIORef r $! delete (fromInteger i) st

mmRemove :: Value -> IORef MutMapStore -> IO ()
mmRemove k r = do
  st <- readIORef r
  h <- keyHash st k
  case fst (find st k h) of
    Just i -> writeIORef r $! delete i st
    Nothing -> pure ()

mmSize, mmCapacity :: IORef MutMapStore -> IO Integer
mmSize r = toInteger . mmCount <$> readIORef r
mmCapacity r = (\st -> toInteger (mmCap st - mmCap st `div` 4)) <$> readIORef r

-- (key, value) in slot order
mmEntries :: IORef MutMapStore -> IO [(Value, Value)]
mmEntries r = map (\(_, k, v) -> (k, v)) . IM.elems . mmSlots <$> readIORef r
