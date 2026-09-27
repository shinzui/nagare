-- | Durable reservation and recovery protocol for a live data target.
-- Provider controls must be implemented by the native adapter before a
-- restore can use this protocol. In particular, a saved writer configuration
-- is not proof that the writer has stopped.
module Nagare.Inventory.DataFence
  ( WriterReleaseState (..)
  , DataFenceControls (..)
  , FenceToken
  , dataFenceIntentDigest
  , acquireDataFence
  , resumeDataFence
  , resumeDataFenceAcquisition
  , beginDataChange
  , verifyDataChange
  , markDataFenceUnresolved
  , recoverDataFence
  , releaseDataFence
  , forwardRecoverDataFenceRelease
  ) where

import Data.Aeson (toJSON)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store
import Nagare.Resource.Types (ContentDigest, PhysicalIdentity, ResourceId)
import Nagare.Resource.Wire (canonicalValue)

-- | A provider may resume writer release only when its observed state proves
-- that no release effect started. A partly restored configuration requires a
-- separate forward-recovery decision; treating it as untouched could replay
-- an uncertain effect.
data WriterReleaseState
  = WritersStillExcluded
  | WritersPartlyReleased
  | WritersFullyReleased
  deriving stock (Eq, Show)

-- | The native implementation must make each observation from the current
-- provider state. A successful request to scale or suspend is not an
-- observation of excluded writers.
data DataFenceControls = DataFenceControls
  { validateFenceInputs :: !(DataFenceRecord -> IO (Either Text ()))
  , stopFenceWriters :: !(DataFenceRecord -> IO (Either Text ()))
  , observeFencePhysical :: !(DataFenceRecord -> IO (Either Text (Map ResourceId PhysicalIdentity)))
  , observeWritersExcluded :: !(DataFenceRecord -> IO (Either Text Bool))
  , verifyRecoveredData :: !(DataFenceRecord -> IO (Either Text Bool))
  , restoreFenceWriters :: !(DataFenceRecord -> IO (Either Text ()))
  , observeWritersReleased :: !(DataFenceRecord -> IO (Either Text WriterReleaseState))
  , forwardRecoverPartlyReleased :: !(Maybe (DataFenceRecord -> IO (Either Text ())))
  }

newtype FenceToken = FenceToken Text

-- | The public review binds every private fence input, including exact
-- physical identities and saved writer configuration, without publishing
-- credentials or the recovery artifact URL.
dataFenceIntentDigest :: DataFenceRecord -> ContentDigest
dataFenceIntentDigest record = contentDigest (either
  (error . T.unpack) id (canonicalValue (toJSON record)))

-- | Write the reservation before touching a writer. Any crash after the
-- conditional write leaves the head fenced until explicit recovery.
acquireDataFence
  :: LockedStore s -> DataFenceControls -> DataFenceRecord
  -> IO (Either Text FenceToken)
acquireDataFence locked controls requested = do
  headResult <- currentHead locked
  case headResult of
    Left reason -> pure (Left reason)
    Right headValue
      | not (validRequest (lockedStore locked) headValue requested) ->
          pure (Left "data fence request differs from the accepted context, lacks exact identities or saved writers, or another operation is active")
      | otherwise -> do
          validated <- validateFenceInputs controls requested
          case validated of
            Left reason -> pure (Left reason)
            Right () -> do
              now <- timestamp
              let record = requested {fencePhase = FenceAcquiring, fenceAcquiredAt = now}
              reserved <- writeHead locked headValue (Just record)
              case reserved of
                Left reason -> pure (Left reason)
                Right () -> advanceAcquisition locked controls record

-- | A new process may reopen only the exact persisted session. The token
-- grants access to state transitions, not authority to claim provider proof.
resumeDataFence :: LockedStore s -> Text -> IO (Either Text FenceToken)
resumeDataFence locked session = do
  current <- currentFence locked
  pure $ case current of
    Right record | fenceSession record == session -> Right (FenceToken session)
    Right _ -> Left "data fence session differs from private history"
    Left reason -> Left reason

-- | A stop request can return before a controller and its Pods finish
-- draining, or lose its acknowledgement. The durable acquiring phase keeps
-- admission closed while a fresh process validates and reobserves the same
-- reviewed controls. Only native exclusion proof advances to FenceExcluded.
resumeDataFenceAcquisition :: LockedStore s -> DataFenceControls
  -> FenceToken -> IO (Either Text ())
resumeDataFenceAcquisition locked controls token = do
  current <- matchingFence locked token
  case current of
    Left reason -> pure (Left reason)
    Right record | fencePhase record /= FenceAcquiring ->
      pure (Left "data fence is not acquiring")
    Right record -> do
      validated <- validateFenceInputs controls record
      case validated of
        Left reason -> pure (Left reason)
        Right () -> do
          advanced <- advanceAcquisition locked controls record
          pure (() <$ advanced)

advanceAcquisition :: LockedStore s -> DataFenceControls
  -> DataFenceRecord -> IO (Either Text FenceToken)
advanceAcquisition locked controls record = do
  stopped <- stopFenceWriters controls record
  case stopped of
    Left reason -> pure (Left reason)
    Right () -> do
      checked <- exclusionProof controls record
      case checked of
        Left reason -> pure (Left reason)
        Right () -> do
          advanced <- transition locked (FenceToken (fenceSession record))
            [FenceAcquiring] FenceExcluded
          pure (FenceToken (fenceSession record) <$ advanced)

beginDataChange :: LockedStore s -> DataFenceControls -> FenceToken -> IO (Either Text ())
beginDataChange locked controls token = do
  current <- matchingFence locked token
  case current of
    Left reason -> pure (Left reason)
    Right record | fencePhase record /= FenceExcluded ->
      pure (Left "data fence has not proved writer exclusion")
    Right record -> do
      checked <- exclusionProof controls record
      case checked of
        Left reason -> unresolved locked record reason
        Right () -> transition locked token [FenceExcluded] FenceChanging

-- | A caller invokes this only after its native data effect has a known
-- result. The provider must verify both content and engine health.
verifyDataChange :: LockedStore s -> DataFenceControls -> FenceToken -> IO (Either Text ())
verifyDataChange locked controls token = do
  current <- matchingFence locked token
  case current of
    Left reason -> pure (Left reason)
    Right record | fencePhase record /= FenceChanging ->
      pure (Left "data fence has no active data change to verify")
    Right record -> do
      checked <- dataProof controls record
      case checked of
        Left reason -> unresolved locked record reason
        Right () -> transition locked token [FenceChanging] FenceVerifying

markDataFenceUnresolved :: LockedStore s -> FenceToken -> IO (Either Text ())
markDataFenceUnresolved locked token = do
  current <- matchingFence locked token
  case current of
    Left reason -> pure (Left reason)
    Right record | fencePhase record == FenceReleasing ->
      pure (Left "writer release is uncertain; observe release before another effect")
    Right record -> transition locked token [fencePhase record] FenceUnresolved

-- | An uncertain data effect is never replayed. Recovery observes the exact
-- target and verified content, then makes it eligible for explicit release.
recoverDataFence :: LockedStore s -> DataFenceControls -> FenceToken -> IO (Either Text ())
recoverDataFence locked controls token = do
  current <- matchingFence locked token
  case current of
    Left reason -> pure (Left reason)
    Right record | fencePhase record == FenceReleasing ->
      finishRelease locked controls token record
    Right record -> do
      excluded <- exclusionProof controls record
      verified <- dataProof controls record
      case (excluded, verified) of
        (Right (), Right ()) -> transition locked token [fencePhase record] FenceVerifying
        (Left reason, _) -> pure (Left reason)
        (_, Left reason) -> pure (Left reason)

releaseDataFence :: LockedStore s -> DataFenceControls -> FenceToken -> IO (Either Text ())
releaseDataFence locked controls token = do
  current <- matchingFence locked token
  case current of
    Left reason -> pure (Left reason)
    Right record | fencePhase record == FenceReleasing ->
      finishRelease locked controls token record
    Right record | fencePhase record /= FenceVerifying ->
      pure (Left "data fence requires verified recovery before writer release")
    Right record -> do
      excluded <- exclusionProof controls record
      verified <- dataProof controls record
      case (excluded, verified) of
        (Right (), Right ()) -> do
          prepared <- transition locked token [FenceVerifying] FenceReleasing
          case prepared of
            Left reason -> pure (Left reason)
            Right () -> do
              released <- restoreFenceWriters controls record
              case released of
                Left reason -> pure (Left reason)
                Right () -> finishReleaseObserved False locked controls token record
        (Left reason, _) -> pure (Left reason)
        (_, Left reason) -> pure (Left reason)

-- | A partly released fence needs a separately reviewed forward action. The
-- provider supplies this callback only when it can conditionally finish the
-- observed partial state without replaying an uncertain destructive effect.
-- Recovery never calls it automatically from ordinary release/resume.
forwardRecoverDataFenceRelease :: LockedStore s -> DataFenceControls
  -> FenceToken -> IO (Either Text ())
forwardRecoverDataFenceRelease locked controls token = do
  current <- matchingFence locked token
  case current of
    Left reason -> pure (Left reason)
    Right record | fencePhase record /= FenceReleasing ->
      pure (Left "data fence has no partial writer release to recover")
    Right record -> do
      physical <- observeFencePhysical controls record
      case physical of
        Left reason -> pure (Left reason)
        Right actual | actual /= fencePhysical record ->
          pure (Left "data fence physical identities changed during release")
        Right _ -> do
          observed <- observeWritersReleased controls record
          case observed of
            Left reason -> pure (Left reason)
            Right WritersPartlyReleased -> case forwardRecoverPartlyReleased controls of
              Nothing -> pure (Left "provider has no reviewed partial-release recovery")
              Just forward -> do
                advanced <- forward record
                case advanced of
                  Left reason -> pure (Left reason)
                  Right () -> finishReleaseObserved False locked controls token record
            Right _ -> pure (Left "writer release is not partial")

finishRelease :: LockedStore s -> DataFenceControls -> FenceToken
  -> DataFenceRecord -> IO (Either Text ())
finishRelease = finishReleaseObserved True

finishReleaseObserved :: Bool -> LockedStore s -> DataFenceControls -> FenceToken
  -> DataFenceRecord -> IO (Either Text ())
finishReleaseObserved mayResume locked controls token record = do
  physical <- observeFencePhysical controls record
  case physical of
    Left reason -> pure (Left reason)
    Right actual | actual /= fencePhysical record ->
      pure (Left "data fence physical identities changed during release")
    Right _ -> do
      observed <- observeWritersReleased controls record
      case observed of
        Left reason -> pure (Left reason)
        Right WritersPartlyReleased ->
          pure (Left "writer release is partial; fence remains in releasing phase")
        Right WritersStillExcluded | mayResume -> do
          released <- restoreFenceWriters controls record
          case released of
            Left reason -> pure (Left reason)
            Right () -> finishReleaseObserved False locked controls token record
        Right WritersStillExcluded ->
          pure (Left "writer release was requested but remains unproved; fence stays in releasing phase")
        Right WritersFullyReleased -> do
          headResult <- currentHead locked
          case headResult of
            Right headValue | Just active <- headDataFence headValue
              , fenceSession active == tokenText token
              , fencePhase active == FenceReleasing -> writeHead locked headValue Nothing
            Right _ -> pure (Left "data fence changed during release")
            Left reason -> pure (Left reason)

exclusionProof :: DataFenceControls -> DataFenceRecord -> IO (Either Text ())
exclusionProof controls record = do
  observed <- observeFencePhysical controls record
  case observed of
    Left reason -> pure (Left reason)
    Right physical | physical /= fencePhysical record ->
      pure (Left "data fence physical identities changed")
    Right _ -> do
      excluded <- observeWritersExcluded controls record
      pure $ case excluded of
        Right True -> Right ()
        Right False -> Left "data fence writer exclusion is not proved"
        Left reason -> Left reason

dataProof :: DataFenceControls -> DataFenceRecord -> IO (Either Text ())
dataProof controls record = do
  physical <- observeFencePhysical controls record
  case physical of
    Left reason -> pure (Left reason)
    Right observed | observed /= fencePhysical record ->
      pure (Left "data fence target incarnation changed")
    Right _ -> do
      verified <- verifyRecoveredData controls record
      pure $ case verified of
        Right True -> Right ()
        Right False -> Left "restored data and health are not verified"
        Left reason -> Left reason

unresolved :: LockedStore s -> DataFenceRecord -> Text -> IO (Either Text a)
unresolved locked record reason = do
  marked <- transition locked (FenceToken (fenceSession record))
    [FenceAcquiring, FenceChanging, FenceVerifying] FenceUnresolved
  pure (case marked of Left failure -> Left (reason <> "; " <> failure); Right () -> Left reason)

transition :: LockedStore s -> FenceToken -> [DataFencePhase]
  -> DataFencePhase -> IO (Either Text ())
transition locked token allowed next = do
  headResult <- currentHead locked
  case headResult of
    Right headValue | Just record <- headDataFence headValue
      , fenceSession record == tokenText token
      , fencePhase record `elem` allowed ->
        writeHead locked headValue (Just record {fencePhase = next})
    Right _ -> pure (Left "data fence session or phase changed")
    Left reason -> pure (Left reason)

matchingFence :: LockedStore s -> FenceToken -> IO (Either Text DataFenceRecord)
matchingFence locked token = do
  current <- currentFence locked
  pure $ case current of
    Right record | fenceSession record == tokenText token -> Right record
    Right _ -> Left "data fence session differs from private history"
    Left reason -> Left reason

currentFence :: LockedStore s -> IO (Either Text DataFenceRecord)
currentFence locked = do
  headResult <- currentHead locked
  pure $ headResult >>= maybe (Left "no active data fence") Right . headDataFence

currentHead :: LockedStore s -> IO (Either Text HeadManifest)
currentHead locked = do
  result <- readHead (lockedStore locked)
  pure $ case result of
    Left err -> Left (T.pack (show err))
    Right Nothing -> Left "inventory store is not initialized"
    Right (Just headValue) -> Right headValue

writeHead :: LockedStore s -> HeadManifest -> Maybe DataFenceRecord
  -> IO (Either Text ())
writeHead locked headValue fence = do
  let replacement = headValue
        { headGeneration = headGeneration headValue + 1
        , headDataFence = fence
        }
  result <- replaceHeadIfGenerationMatches (lockedStore locked)
    (Just (headGeneration headValue)) replacement
  pure $ either (Left . T.pack . show) Right result

validRequest :: InventoryStore -> HeadManifest -> DataFenceRecord -> Bool
validRequest store headValue requested =
  headDataFence headValue == Nothing
    && (case fenceTransaction requested of
      Nothing -> headActiveTransaction headValue == Nothing
        && headExecutorClaim headValue == Nothing
      Just transaction -> headActiveTransaction headValue == Just transaction
        && maybe False (\claim -> claimTransaction claim == transaction
          && claimClientIdentity claim == maybe (headClientIdentity headValue) id
            (storeClientIdentity store)) (headExecutorClaim headValue))
    && fenceContext requested == headBinding headValue
    && fenceAccepted requested == headAccepted headValue
    && not (T.null (fenceSession requested))
    && not (T.null (fenceRecoveryArtifact requested))
    && not (Map.null (fencePhysical requested))
    && not (Set.null (fenceTargets requested))
    && Set.union (fenceTargets requested) (fenceAffected requested)
      `Set.isSubsetOf` Map.keysSet (fencePhysical requested)
    && Map.keysSet (fenceSavedWriters requested) == fenceAffected requested

tokenText :: FenceToken -> Text
tokenText (FenceToken session) = session

timestamp :: IO Text
timestamp = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" <$> getCurrentTime
