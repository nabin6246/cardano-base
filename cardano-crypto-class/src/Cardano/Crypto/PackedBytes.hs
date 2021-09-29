{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE UnboxedTuples #-}

module Cardano.Crypto.PackedBytes
  ( PackedBytes(..)
  , packBytes
  , packPinnedBytes
  , unpackBytes
  , unpackPinnedBytes
  , xorPackedBytes
  ) where

import Codec.Serialise (Serialise(..))
import Codec.Serialise.Decoding (decodeBytes)
import Codec.Serialise.Encoding (encodeBytes)
import Control.DeepSeq
import Control.Monad.Primitive
import Data.Bits
import Data.ByteString
import Data.ByteString.Internal as BS (accursedUnutterablePerformIO,
                                       fromForeignPtr, toForeignPtr)
import Data.ByteString.Short.Internal as SBS
import Data.Primitive.ByteArray
import Data.Primitive.PrimArray (PrimArray(..), imapPrimArray, indexPrimArray)
import Data.Typeable
import Foreign.ForeignPtr
import Foreign.Ptr (castPtr)
import Foreign.Storable (Storable(..))
import GHC.Exts
import GHC.ForeignPtr (ForeignPtr(ForeignPtr), ForeignPtrContents(PlainPtr))
import GHC.ST
import GHC.TypeLits
import GHC.Word
import NoThunks.Class

#include "MachDeps.h"


data PackedBytes (n :: Nat) where
  PackedBytes8  :: {-# UNPACK #-} !Word64
                -> PackedBytes 8
  PackedBytes28 :: {-# UNPACK #-} !Word64
                -> {-# UNPACK #-} !Word64
                -> {-# UNPACK #-} !Word64
                -> {-# UNPACK #-} !Word32
                -> PackedBytes 28
  PackedBytes32 :: {-# UNPACK #-} !Word64
                -> {-# UNPACK #-} !Word64
                -> {-# UNPACK #-} !Word64
                -> {-# UNPACK #-} !Word64
                -> PackedBytes 32
  PackedBytes# :: ByteArray# -> PackedBytes n

deriving via OnlyCheckWhnfNamed "PackedBytes" (PackedBytes n) instance NoThunks (PackedBytes n)

instance Eq (PackedBytes n) where
  PackedBytes8 x == PackedBytes8 y = x == y
  PackedBytes28 x0 x1 x2 x3 == PackedBytes28 y0 y1 y2 y3 =
    x0 == y0 && x1 == y1 && x2 == y2 && x3 == y3
  PackedBytes32 x0 x1 x2 x3 == PackedBytes32 y0 y1 y2 y3 =
    x0 == y0 && x1 == y1 && x2 == y2 && x3 == y3
  x1 == x2 = unpackBytes x1 == unpackBytes x2
  {-# INLINE (==) #-}

instance Ord (PackedBytes n) where
  compare (PackedBytes8 x) (PackedBytes8 y) = compare x y
  compare (PackedBytes28 x0 x1 x2 x3) (PackedBytes28 y0 y1 y2 y3) =
    compare x0 y0 <> compare x1 y1 <> compare x2 y2 <> compare x3 y3
  compare (PackedBytes32 x0 x1 x2 x3) (PackedBytes32 y0 y1 y2 y3) =
    compare x0 y0 <> compare x1 y1 <> compare x2 y2 <> compare x3 y3
  compare x1 x2 = compare (unpackBytes x1) (unpackBytes x2)
  {-# INLINE compare #-}

instance NFData (PackedBytes n) where
  rnf PackedBytes8  {} = ()
  rnf PackedBytes28 {} = ()
  rnf PackedBytes32 {} = ()
  rnf PackedBytes#  {} = ()

instance Serialise (PackedBytes n) where
  encode = encodeBytes . unpackPinnedBytes
  decode = packPinnedBytesN <$> decodeBytes

instance KnownNat n => Storable (PackedBytes n) where
  sizeOf _ = fromInteger (natVal (Proxy :: Proxy n))
  {-# INLINE sizeOf #-}
  alignment _ = fromInteger (natVal (Proxy :: Proxy n))
  {-# INLINE alignment #-}
  peek = peekPtrBytes
  {-# INLINE peek #-}
  poke ptr pb =
    case pb of
      PackedBytes8 w64 -> pokeWord64BE ptr 0 w64
      PackedBytes28 x0 x1 x2 x3 -> do
        pokeWord64BE ptr 0  x0
        pokeWord64BE ptr 8  x1
        pokeWord64BE ptr 16 x2
        pokeWord32BE ptr 24 x3
      PackedBytes32 x0 x1 x2 x3 -> do
        pokeWord64BE ptr 0  x0
        pokeWord64BE ptr 8  x1
        pokeWord64BE ptr 16 x2
        pokeWord64BE ptr 24 x3
      PackedBytes# ba# -> do
        copyByteArrayToAddr (castPtr ptr) (ByteArray ba#) 0 (sizeOf pb)
  {-# INLINE poke #-}

xorPackedBytes :: PackedBytes n -> PackedBytes n -> PackedBytes n
xorPackedBytes (PackedBytes8 x) (PackedBytes8 y) = PackedBytes8 (x `xor` y)
xorPackedBytes (PackedBytes28 x0 x1 x2 x3) (PackedBytes28 y0 y1 y2 y3) =
  PackedBytes28 (x0 `xor` y0) (x1 `xor` y1) (x2 `xor` y2) (x3 `xor` y3)
xorPackedBytes (PackedBytes32 x0 x1 x2 x3) (PackedBytes32 y0 y1 y2 y3) =
  PackedBytes32 (x0 `xor` y0) (x1 `xor` y1) (x2 `xor` y2) (x3 `xor` y3)
xorPackedBytes (PackedBytes# ba1#) (PackedBytes# ba2#) =
  let pa1 = PrimArray ba1# :: PrimArray Word8
      pa2 = PrimArray ba2# :: PrimArray Word8
   in case imapPrimArray (xor . indexPrimArray pa1) pa2 of
        PrimArray pa# -> PackedBytes# pa#
xorPackedBytes _ _ =
  error "Impossible case. GHC can't figure out that pattern match is exhaustive."
{-# INLINE xorPackedBytes #-}


withMutableByteArray :: Int -> (forall s . MutableByteArray s -> ST s ()) -> ByteArray
withMutableByteArray n f = do
  runST $ do
    mba <- newByteArray n
    f mba
    unsafeFreezeByteArray mba
{-# INLINE withMutableByteArray #-}

withPinnedMutableByteArray :: Int -> (forall s . MutableByteArray s -> ST s ()) -> ByteArray
withPinnedMutableByteArray n f = do
  runST $ do
    mba <- newPinnedByteArray n
    f mba
    unsafeFreezeByteArray mba
{-# INLINE withPinnedMutableByteArray #-}

unpackBytes :: PackedBytes n -> ShortByteString
unpackBytes = byteArrayToShortByteString . unpackBytesWith withMutableByteArray
{-# INLINE unpackBytes #-}

unpackPinnedBytes :: PackedBytes n -> ByteString
unpackPinnedBytes = byteArrayToByteString . unpackBytesWith withPinnedMutableByteArray
{-# INLINE unpackPinnedBytes #-}


unpackBytesWith ::
     (Int -> (forall s. MutableByteArray s -> ST s ()) -> ByteArray)
  -> PackedBytes n
  -> ByteArray
unpackBytesWith allocate (PackedBytes8 w) =
  allocate 8  $ \mba -> writeWord64BE mba 0 w
unpackBytesWith allocate (PackedBytes28 w0 w1 w2 w3) =
  allocate 28 $ \mba -> do
    writeWord64BE mba 0  w0
    writeWord64BE mba 8  w1
    writeWord64BE mba 16 w2
    writeWord32BE mba 24 w3
unpackBytesWith allocate (PackedBytes32 w0 w1 w2 w3) =
  allocate 32 $ \mba -> do
    writeWord64BE mba 0  w0
    writeWord64BE mba 8  w1
    writeWord64BE mba 16 w2
    writeWord64BE mba 24 w3
unpackBytesWith _ (PackedBytes# ba#) = ByteArray ba#
{-# INLINE unpackBytesWith #-}


packBytes8 :: ShortByteString -> PackedBytes 8
packBytes8 (SBS ba#) =
  let ba = ByteArray ba#
   in PackedBytes8 (indexWord64BE ba 0)
{-# INLINE packBytes8 #-}

packBytes28 :: ShortByteString -> PackedBytes 28
packBytes28 (SBS ba#) =
  let ba = ByteArray ba#
  in PackedBytes28
       (indexWord64BE ba 0)
       (indexWord64BE ba 8)
       (indexWord64BE ba 16)
       (indexWord32BE ba 24)
{-# INLINE packBytes28 #-}

packBytes32 :: ShortByteString -> PackedBytes 32
packBytes32 (SBS ba#) =
  let ba = ByteArray ba#
  in PackedBytes32
       (indexWord64BE ba 0)
       (indexWord64BE ba 8)
       (indexWord64BE ba 16)
       (indexWord64BE ba 24)
{-# INLINE packBytes32 #-}

packBytesN :: ShortByteString -> PackedBytes n
packBytesN (SBS ba#) = PackedBytes# ba#
{-# INLINE packBytesN #-}


packBytes :: forall n . KnownNat n => ShortByteString -> PackedBytes n
packBytes sbs@(SBS ba#) =
  let px = Proxy :: Proxy n
   in case sameNat px (Proxy :: Proxy 8) of
        Just Refl -> packBytes8 sbs
        Nothing -> case sameNat px (Proxy :: Proxy 28) of
          Just Refl -> packBytes28 sbs
          Nothing -> case sameNat px (Proxy :: Proxy 32) of
            Just Refl -> packBytes32 sbs
            Nothing   -> PackedBytes# ba#
{-# INLINE[1] packBytes #-}

{-# RULES
"packBytes8"  packBytes = packBytes8
"packBytes28" packBytes = packBytes28
"packBytes32" packBytes = packBytes32
"packBytesN"  packBytes = packBytesN
  #-}


packPinnedBytes8 :: ByteString -> PackedBytes 8
packPinnedBytes8 bs = unsafeWithByteStringPtr bs peekPtrBytes8
{-# INLINE packPinnedBytes8 #-}

peekPtrBytes8 :: Ptr (PackedBytes 8) -> IO (PackedBytes 8)
peekPtrBytes8 = fmap PackedBytes8 . (`peekWord64BE` 0)
{-# INLINE peekPtrBytes8 #-}


packPinnedBytes28 :: ByteString -> PackedBytes 28
packPinnedBytes28 bs = unsafeWithByteStringPtr bs peekPtrBytes28
{-# INLINE packPinnedBytes28 #-}

peekPtrBytes28 :: Ptr (PackedBytes 28) -> IO (PackedBytes 28)
peekPtrBytes28 ptr =
  PackedBytes28
    <$> peekWord64BE ptr 0
    <*> peekWord64BE ptr 8
    <*> peekWord64BE ptr 16
    <*> peekWord32BE ptr 24
{-# INLINE peekPtrBytes28 #-}


packPinnedBytes32 :: ByteString -> PackedBytes 32
packPinnedBytes32 bs = unsafeWithByteStringPtr bs peekPtrBytes32
{-# INLINE packPinnedBytes32 #-}

peekPtrBytes32 :: Ptr (PackedBytes 32) -> IO (PackedBytes 32)
peekPtrBytes32 ptr =
  PackedBytes32
    <$> peekWord64BE ptr 0
    <*> peekWord64BE ptr 8
    <*> peekWord64BE ptr 16
    <*> peekWord64BE ptr 24
{-# INLINE peekPtrBytes32 #-}


packPinnedBytesN :: ByteString -> PackedBytes n
packPinnedBytesN bs =
  case toShort bs of
    SBS ba# -> PackedBytes# ba#
{-# INLINE packPinnedBytesN #-}

peekPtrBytesN ::
     forall n. KnownNat n
  => Ptr (PackedBytes n)
  -> IO (PackedBytes n)
peekPtrBytesN ptr = do
  SBS ba# <- SBS.packCStringLen (castPtr ptr, fromInteger (natVal (Proxy :: Proxy n)))
  pure $ PackedBytes# ba#
{-# INLINE peekPtrBytesN #-}


packPinnedBytes :: forall n . KnownNat n => ByteString -> PackedBytes n
packPinnedBytes bs =
  let px = Proxy :: Proxy n
   in case sameNat px (Proxy :: Proxy 8) of
        Just Refl -> packPinnedBytes8 bs
        Nothing -> case sameNat px (Proxy :: Proxy 28) of
          Just Refl -> packPinnedBytes28 bs
          Nothing -> case sameNat px (Proxy :: Proxy 32) of
            Just Refl -> packPinnedBytes32 bs
            Nothing   -> packPinnedBytesN bs
{-# INLINE[1] packPinnedBytes #-}

{-# RULES
"packPinnedBytes8"  packPinnedBytes = packPinnedBytes8
"packPinnedBytes28" packPinnedBytes = packPinnedBytes28
"packPinnedBytes32" packPinnedBytes = packPinnedBytes32
"packPinnedBytesN"  packPinnedBytes = packPinnedBytesN
  #-}


peekPtrBytes :: forall n . KnownNat n => Ptr (PackedBytes n) -> IO (PackedBytes n)
peekPtrBytes ptr =
  let px = Proxy :: Proxy n
   in case sameNat px (Proxy :: Proxy 8) of
        Just Refl -> peekPtrBytes8 ptr
        Nothing -> case sameNat px (Proxy :: Proxy 28) of
          Just Refl -> peekPtrBytes28 ptr
          Nothing -> case sameNat px (Proxy :: Proxy 32) of
            Just Refl -> peekPtrBytes32 ptr
            Nothing   -> peekPtrBytesN ptr
{-# INLINE[1] peekPtrBytes #-}

{-# RULES
"peekPtrBytes8"  peekPtrBytes = peekPtrBytes8
"peekPtrBytes28" peekPtrBytes = peekPtrBytes28
"peekPtrBytes32" peekPtrBytes = peekPtrBytes32
"peekPtrBytesN"  peekPtrBytes = peekPtrBytesN
  #-}


--- Primitive architecture agnostic helpers

#if WORD_SIZE_IN_BITS == 64

indexWord64BE :: ByteArray -> Int -> Word64
indexWord64BE (ByteArray ba#) (I# i#) =
#ifdef WORDS_BIGENDIAN
  W64# (indexWord8ArrayAsWord64# ba# i#)
#else
  W64# (byteSwap64# (indexWord8ArrayAsWord64# ba# i#))
#endif
{-# INLINE indexWord64BE #-}

peekWord64BE :: Ptr a -> Int -> IO Word64
peekWord64BE ptr i =
#ifndef WORDS_BIGENDIAN
  byteSwap64 <$>
#endif
  peekByteOff (castPtr ptr) i
{-# INLINE peekWord64BE #-}

pokeWord64BE :: Ptr a -> Int -> Word64 -> IO ()
pokeWord64BE ptr i a =
  pokeByteOff (castPtr ptr) i
#ifdef WORDS_BIGENDIAN
  a
#else
  (byteSwap64 a)
#endif
{-# INLINE pokeWord64BE #-}


writeWord64BE :: MutableByteArray s -> Int -> Word64 -> ST s ()
writeWord64BE (MutableByteArray mba#) (I# i#) (W64# w#) =
  primitive_ (writeWord8ArrayAsWord64# mba# i# wbe#)
  where
#ifdef WORDS_BIGENDIAN
    !wbe# = w#
#else
    !wbe# = byteSwap64# w#
#endif
{-# INLINE writeWord64BE #-}

#elif WORD_SIZE_IN_BITS == 32

indexWord64BE :: ByteArray -> Int -> Word64
indexWord64BE ba i =
  (fromIntegral (indexWord32BE ba i) `shiftL` 32) .|. fromIntegral (indexWord32BE ba (i + 4))
{-# INLINE indexWord64BE #-}

peekWord64BE :: Ptr a -> Int -> IO Word64
peekWord64BE ptr i = do
  u <- peekWord32BE ptr i
  l <- peekWord32BE ptr (i + 4)
  pure ((fromIntegral u `shiftL` 32) .|. fromIntegral l)
{-# INLINE peekWord64BE #-}

pokeWord64BE :: Ptr a -> Int -> Word64 -> IO ()s
pokeWord64BE ptr i w64 = do
  pokeWord32BE ptr i (fromIntegral (w64 `shiftR` 32))
  pokeWord32BE ptr (i + 4) (fromIntegral w64)
{-# INLINE pokeWord64BE #-}

writeWord64BE :: MutableByteArray s -> Int -> Word64 -> ST s ()
writeWord64BE mba i w64 = do
  writeWord32BE mba i (fromIntegral (w64 `shiftR` 32))
  writeWord32BE mba (i + 4) (fromIntegral w64)
{-# INLINE writeWord64BE #-}

#else
#error "Unsupported architecture"
#endif


indexWord32BE :: ByteArray -> Int -> Word32
indexWord32BE (ByteArray ba#) (I# i#) =
#ifdef WORDS_BIGENDIAN
  W32# (indexWord8ArrayAsWord32# ba# i#)
#else
  W32# (narrow32Word# (byteSwap32# (indexWord8ArrayAsWord32# ba# i#)))
#endif
{-# INLINE indexWord32BE #-}

peekWord32BE :: Ptr a -> Int -> IO Word32
peekWord32BE ptr i =
#ifndef WORDS_BIGENDIAN
  byteSwap32 <$>
#endif
  peekByteOff (castPtr ptr) i
{-# INLINE peekWord32BE #-}


pokeWord32BE :: Ptr a -> Int -> Word32 -> IO ()
pokeWord32BE ptr i a =
  pokeByteOff (castPtr ptr) i
#ifdef WORDS_BIGENDIAN
  a
#else
  (byteSwap32 a)
#endif
{-# INLINE pokeWord32BE #-}


writeWord32BE :: MutableByteArray s -> Int -> Word32 -> ST s ()
writeWord32BE (MutableByteArray mba#) (I# i#) (W32# w#) =
  primitive_ (writeWord8ArrayAsWord32# mba# i# wbe#)
  where
#ifdef WORDS_BIGENDIAN
    !wbe# = w#
#else
    !wbe# = narrow32Word# (byteSwap32# w#)
#endif
{-# INLINE writeWord32BE #-}

byteArrayToShortByteString :: ByteArray -> ShortByteString
byteArrayToShortByteString (ByteArray ba#) = SBS ba#
{-# INLINE byteArrayToShortByteString #-}

byteArrayToByteString :: ByteArray -> ByteString
byteArrayToByteString ba
  | isByteArrayPinned ba =
    BS.fromForeignPtr (pinnedByteArrayToForeignPtr ba) 0 (sizeofByteArray ba)
  | otherwise = SBS.fromShort (byteArrayToShortByteString ba)
{-# INLINE byteArrayToByteString #-}

pinnedByteArrayToForeignPtr :: ByteArray -> ForeignPtr a
pinnedByteArrayToForeignPtr (ByteArray ba#) =
  ForeignPtr (byteArrayContents# ba#) (PlainPtr (unsafeCoerce# ba#))
{-# INLINE pinnedByteArrayToForeignPtr #-}

-- Usage of `accursedUnutterablePerformIO` here is safe because we only use it
-- for indexing into an immutable `ByteString`, which is analogous to
-- `Data.ByteString.index`.  Make sure you know what you are doing before using
-- this function.
unsafeWithByteStringPtr :: ByteString -> (Ptr b -> IO a) -> a
unsafeWithByteStringPtr bs f =
  accursedUnutterablePerformIO $
    case toForeignPtr bs of
      (fp, offset, _) ->
        unsafeWithForeignPtr (plusForeignPtr fp offset) f
{-# INLINE unsafeWithByteStringPtr #-}

#if !MIN_VERSION_base(4,15,0)
-- | A compatibility wrapper for 'GHC.ForeignPtr.unsafeWithForeignPtr' provided
-- by GHC 9.0.1 and later.
unsafeWithForeignPtr :: ForeignPtr a -> (Ptr a -> IO b) -> IO b
unsafeWithForeignPtr = withForeignPtr
{-# INLINE unsafeWithForeignPtr #-}
#endif
