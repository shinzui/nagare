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
  , faultCall
  , faultPersistence
  , newAdversary
  , nextFault
  , nextFaultAt
  , noteActed
  , unacted
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
  | StorePutCall
  | StoreGetCall
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
  | -- | From this observation on, the controller updates status (and so
    -- resourceVersion) before every observation of an object with status.
    ChurnAlways
  | -- | An unowned object appears at an address planned for creation.
    ForeignObject
  | -- | The object is deleted and recreated out of band at the same address
    -- with a new UID and the same ownership stamp (an operator's
    -- `kubectl replace --force`, a restore from a manifest).
    Replaced
  | -- | The object is deleted out of band and not recreated (an operator's
    -- `kubectl delete`).
    Deleted
  | -- | One observation cannot be read (an API timeout).
    TransientReadFailure
  | -- | One store write is refused before it lands.
    PutRefused
  | -- | One store write lands but its acknowledgement is lost.
    PutLandedUnacknowledged
  | -- | One store read fails.
    GetFailedOnce
  | -- | EP-177: the executor dies at a store write, before it lands.
    CrashBeforeStorePut
  | -- | EP-177: the executor dies at a store write, after it lands.
    CrashAfterStorePut
  | -- | EP-177: another client takes the executor claim just before this
    -- head write, as a second operator's take-over would.
    ClaimLost
  | -- | EP-182: the written object's controller does not observe this write's
    -- generation until the object is written again; its status, including a
    -- stale @Ready=True@, stays at the previous generation (RES-4 E4, G2).
    ControllerLag
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The provider operation whose boundaries a fault is scheduled at.
faultCall :: Fault -> Call
faultCall fault = case fault of
  ChurnAlways -> ObserveCall
  ForeignObject -> ObserveCall
  TransientReadFailure -> ObserveCall
  Replaced -> ObserveCall
  Deleted -> ObserveCall
  PutRefused -> StorePutCall
  PutLandedUnacknowledged -> StorePutCall
  CrashBeforeStorePut -> StorePutCall
  CrashAfterStorePut -> StorePutCall
  ClaimLost -> StorePutCall
  GetFailedOnce -> StoreGetCall
  _ -> MutateCall

data Persistence
  = Transient
  | Persistent
  deriving stock (Eq, Show)

faultPersistence :: Fault -> Persistence
faultPersistence fault = case fault of
  LandsUnready -> Persistent
  LandsFailed -> Persistent
  ForeignManager -> Persistent
  ChurnAlways -> Persistent
  ForeignObject -> Persistent
  ControllerLag -> Persistent
  Replaced -> Persistent
  Deleted -> Persistent
  _ -> Transient

data Adversary = Adversary
  { schedule :: ![(Boundary, Fault)]
  , counts :: !(Map.Map Call Int)
  , storeArmed :: !Bool
  -- ^ Store calls count only once the run's setup is done.
  , fired :: ![Fault]
  -- ^ Faults that have fired, most recent first.
  , acted :: ![(Boundary, Fault)]
  -- ^ EP-182: faults that changed the world's state or the answer the caller
  -- received, most recent first. A fault can fire and do nothing (a
  -- 'ForeignObject' at an occupied address); a pinned regression needs its
  -- faults to act.
  }
  deriving stock (Eq, Show)

newAdversary :: [(Boundary, Fault)] -> IO (IORef Adversary)
newAdversary faults = newIORef (Adversary faults Map.empty False [] [])

-- | Count one call and return the fault scheduled at its boundary, if any.
nextFault :: IORef Adversary -> Call -> IO (Maybe Fault)
nextFault ref operation = atomicModifyIORef' ref $ \adversary ->
  if operation `elem` [StorePutCall, StoreGetCall] && not (storeArmed adversary)
    then (adversary, Nothing)
    else countCall adversary operation

countCall :: Adversary -> Call -> (Adversary, Maybe Fault)
countCall adversary operation =
  let count = Map.findWithDefault 0 operation (counts adversary) + 1
      boundary = Boundary operation count
      fault = lookup boundary (schedule adversary)
   in ( adversary {counts = Map.insert operation count (counts adversary), fired = maybe id (:) fault (fired adversary)}
      , fault
      )

-- | Like 'nextFault', with the boundary the fault fired at.
nextFaultAt :: IORef Adversary -> Call -> IO (Maybe (Boundary, Fault))
nextFaultAt ref operation = do
  fault <- nextFault ref operation
  count <- Map.findWithDefault 0 operation . counts <$> readIORef ref
  pure ((Boundary operation count,) <$> fault)

-- | Record that a fault changed the world or the caller's answer.
noteActed :: IORef Adversary -> (Boundary, Fault) -> IO ()
noteActed ref placement = modifyIORef' ref (\adversary -> adversary {acted = placement : acted adversary})

-- | Scheduled faults that did not act: never fired, or fired and changed
-- nothing.
unacted :: Adversary -> [(Boundary, Fault)]
unacted adversary = [placement | placement <- schedule adversary, placement `notElem` acted adversary]

-- | What a killed executor looks like to the driver: the call never returns.
data Interrupted = Interrupted
  deriving stock (Show)

instance Exception Interrupted
