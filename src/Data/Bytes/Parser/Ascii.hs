{-# language BangPatterns #-}
{-# language BinaryLiterals #-}
{-# language DataKinds #-}
{-# language DeriveFunctor #-}
{-# language DerivingStrategies #-}
{-# language GADTSyntax #-}
{-# language KindSignatures #-}
{-# language LambdaCase #-}
{-# language MagicHash #-}
{-# language MultiWayIf #-}
{-# language PolyKinds #-}
{-# language RankNTypes #-}
{-# language ScopedTypeVariables #-}
{-# language StandaloneDeriving #-}
{-# language TypeApplications #-}
{-# language UnboxedSums #-}
{-# language UnboxedTuples #-}

-- | Parse input as ASCII-encoded text. Some parsers in this module,
-- like 'any' and 'peek' fail if they encounter a byte above @0x7F@.
-- Others, like numeric parsers and skipping parsers, leave the cursor
-- at the position of the offending byte without failing.
module Data.Bytes.Parser.Ascii
  ( -- * Matching
    Latin.char
  , Latin.char2
  , Latin.char3
  , Latin.char4
    -- * Get Character
  , any
  , any#
  , peek
  , opt
    -- * Match Many
  , shortTrailedBy
    -- * Skip
  , Latin.skipDigits
  , Latin.skipDigits1
  , Latin.skipChar
  , Latin.skipChar1
  , skipAlpha
  , skipAlpha1
  , skipTrailedBy
    -- * Numbers
  , Latin.decWord
  , Latin.decWord8
  , Latin.decWord16
  , Latin.decWord32
  ) where

import Prelude hiding (length,any,fail,takeWhile)

import Data.Bytes.Types (Bytes(..))
import Data.Bytes.Parser.Internal (Parser(..),uneffectful,Result#,uneffectful#)
import Data.Bytes.Parser.Internal (InternalResult(..),indexLatinCharArray,upcastUnitSuccess)
import Data.Word (Word8)
import Data.Text.Short (ShortText)
import Control.Monad.ST.Run (runByteArrayST)
import GHC.Exts (Int(I#),Char(C#),Int#,Char#,(-#),(+#),(<#),ord#,indexCharArray#,chr#)

import qualified Data.ByteString.Short.Internal as BSS
import qualified Data.Text.Short.Unsafe as TS
import qualified Data.Bytes as Bytes
import qualified Data.Bytes.Parser.Latin as Latin
import qualified Data.Bytes.Parser.Unsafe as Unsafe
import qualified Data.Primitive as PM

-- | Consume input until the trailer is found. Then, consume
-- the trailer as well. This fails if the trailer is not
-- found or if any non-ASCII characters are encountered.
skipTrailedBy :: e -> Char -> Parser e s ()
skipTrailedBy e !c = do
  let go = do
        !d <- any e
        if d == c
          then pure ()
          else go
  go

-- | Consume input through the next occurrence of the target
-- character and return the consumed input, excluding the
-- target character, as a 'ShortText'. This fails if it
-- encounters any bytes above @0x7F@.
shortTrailedBy :: e -> Char -> Parser e s ShortText
shortTrailedBy e !c = do
  !start <- Unsafe.cursor
  skipTrailedBy e c
  end <- Unsafe.cursor
  src <- Unsafe.expose
  let len = end - start - 1
      !r = runByteArrayST $ do
        marr <- PM.newByteArray len
        PM.copyByteArray marr 0 src start len
        PM.unsafeFreezeByteArray marr
  pure
    $ TS.fromShortByteStringUnsafe
    $ byteArrayToShortByteString
    $ r


-- | Consumes and returns the next character in the input.
any :: e -> Parser e s Char
any e = uneffectful $ \chunk -> if length chunk > 0
  then
    let c = indexLatinCharArray (array chunk) (offset chunk)
     in if c < '\128'
          then InternalSuccess c (offset chunk + 1) (length chunk - 1)
          else InternalFailure e
  else InternalFailure e

-- | Variant of 'any' with unboxed result.
any# :: e -> Parser e s Char#
{-# inline any# #-}
any# e = Parser
  (\(# arr, off, len #) s0 -> case len of
    0# -> (# s0, (# e | #) #)
    _ ->
      let !w = indexCharArray# arr off
       in case ord# w <# 128# of
            1# -> (# s0, (# | (# w, off +# 1#, len -# 1# #) #) #)
            _ -> (# s0, (# e | #) #)
  )

unI :: Int -> Int#
unI (I# w) = w

-- | Examine the next byte without consuming it, interpret it as an
-- ASCII-encoded character. This fails if the byte is above @0x7F@ or
-- if the end of input has been reached.
peek :: e -> Parser e s Char
peek e = uneffectful $ \chunk -> if length chunk > 0
  then
    let w = PM.indexByteArray (array chunk) (offset chunk) :: Word8
     in if w < 128
          then InternalSuccess
                 (C# (chr# (unI (fromIntegral w))))
                 (offset chunk)
                 (length chunk)
          else InternalFailure e
  else InternalFailure e

-- | Consume the next byte, interpreting it as an ASCII-encoded character.
-- Fails if the byte is above @0x7F@. Returns @Nothing@ if the
-- end of the input has been reached.
opt :: e -> Parser e s (Maybe Char)
{-# inline opt #-}
opt e = uneffectful $ \chunk -> if length chunk > 0
  then
    let w = PM.indexByteArray (array chunk) (offset chunk) :: Word8
     in if w < 128
          then InternalSuccess
                 (Just (C# (chr# (unI (fromIntegral w)))))
                 (offset chunk + 1)
                 (length chunk - 1)
          else InternalFailure e
  else InternalSuccess Nothing (offset chunk) (length chunk)

-- | Skip uppercase and lowercase letters until a non-alpha
-- character is encountered.
skipAlpha :: Parser e s ()
skipAlpha = uneffectful# $ \c ->
  upcastUnitSuccess (skipAlphaAsciiLoop c)

-- | Skip uppercase and lowercase letters until a non-alpha
-- character is encountered.
skipAlpha1 :: e -> Parser e s ()
skipAlpha1 e = uneffectful# $ \c ->
  skipAlphaAsciiLoop1Start e c

skipAlphaAsciiLoop ::
     Bytes -- Chunk
  -> (# Int#, Int# #)
skipAlphaAsciiLoop !c = if length c > 0
  then
    let w = indexLatinCharArray (array c) (offset c)
     in if (w >= 'a' && w <= 'z') || (w >= 'A' && w <= 'Z')
          then skipAlphaAsciiLoop (Bytes.unsafeDrop 1 c)
          else (# unI (offset c), unI (length c) #)
  else (# unI (offset c), unI (length c) #)

skipAlphaAsciiLoop1Start ::
     e
  -> Bytes -- chunk
  -> Result# e ()
skipAlphaAsciiLoop1Start e !c = if length c > 0
  then 
    let w = indexLatinCharArray (array c) (offset c)
     in if (w >= 'a' && w <= 'z') || (w >= 'A' && w <= 'Z')
          then upcastUnitSuccess (skipAlphaAsciiLoop (Bytes.unsafeDrop 1 c))
          else (# e | #)
  else (# e | #)

byteArrayToShortByteString :: PM.ByteArray -> BSS.ShortByteString
byteArrayToShortByteString (PM.ByteArray x) = BSS.SBS x

