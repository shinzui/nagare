-- | EP-173: scheduled provider faults for the recovery model. A fault fires at
-- one boundary, the n-th call of one provider operation. A transient fault
-- clears after it fires; a persistent fault leaves the world changed for the
-- rest of the run (for example a revision that never becomes Ready).
module Nagare.Test.World.Adversary
  ( Adversary (..)
  , Boundary (..)
  , Call (..)
  , Fault (..)
  , Interrupted (..)
  , Persistence (..)
  , faultPersistence
  , newAdversary
  , nextFault
  )
where

import Control.Exception (Exception)
import Data.IORef
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude

-- | The provider operation a boundary counts.
data Call
  = MutateCall
  | ObserveCall
  deriving stock (Eq, Ord, Show)

-- | The n-th call (from 1) of one provider operation.
data Boundary = Boundary
  { call :: !Call
  , ordinal :: !Int
  }
  deriving stock (Eq, Ord, Show)

data Fault
  = -- | The write lands, then the transport loses its acknowledgement.
    LostAcknowledgement
  | -- | The provider refuses before any effect.
    RefusedBeforeEffect
  | -- | The written revision never becomes Ready.
    LandsUnready
  | -- | The written revision fails.
    LandsFailed
  | -- | A controller bumps resourceVersion just before the write.
    StatusChurn
  | -- | Another writer owns a reviewed field of the object.
    ForeignManager
  | -- | The executor process dies right after the write lands.
    Interrupt
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data Persistence
  = Transient
  | Persistent
  deriving stock (Eq, Show)

faultPersistence :: Fault -> Persistence
faultPersistence fault = case fault of
  LandsUnready -> Persistent
  LandsFailed -> Persistent
  ForeignManager -> Persistent
  _ -> Transient

data Adversary = Adversary
  { schedule :: ![(Boundary, Fault)]
  , counts :: !(Map.Map Call Int)
  }
  deriving stock (Eq, Show)

newAdversary :: [(Boundary, Fault)] -> IO (IORef Adversary)
newAdversary faults = newIORef (Adversary faults Map.empty)

-- | Count one call and return the fault scheduled at its boundary, if any.
nextFault :: IORef Adversary -> Call -> IO (Maybe Fault)
nextFault ref operation = atomicModifyIORef' ref $ \adversary ->
  let count = Map.findWithDefault 0 operation (counts adversary) + 1
      boundary = Boundary operation count
   in ( adversary {counts = Map.insert operation count (counts adversary)}
      , lookup boundary (schedule adversary)
      )

-- | What a killed executor looks like to the driver: the call never returns.
data Interrupted = Interrupted
  deriving stock (Show)

instance Exception Interrupted
