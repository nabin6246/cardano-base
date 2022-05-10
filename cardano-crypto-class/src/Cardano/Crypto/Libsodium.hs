module Cardano.Crypto.Libsodium (
  -- * Initialization
  sodiumInit,
  -- * MLocked memory management
  MLockedForeignPtr,
  withMLockedForeignPtr,
  allocMLockedForeignPtr,
  finalizeMLockedForeignPtr,
  traceMLockedForeignPtr,
  -- * MLocked bytes
  MLockedSizedBytes,
  mlsbFromByteString,
  mlsbFromByteStringCheck,
  mlsbToByteString,
  mlsbAsByteString,
  mlsbFinalize,
  mlsbCopy,
  -- * Hashing
  SodiumHashAlgorithm (..),
  digestMLockedStorable,
  digestMLockedBS,
  expandHash,
) where

import Cardano.Crypto.Libsodium.Hash
import Cardano.Crypto.Libsodium.Init
import Cardano.Crypto.Libsodium.Memory
import Cardano.Crypto.Libsodium.MLockedBytes
