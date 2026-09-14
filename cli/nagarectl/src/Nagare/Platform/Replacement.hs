{-# LANGUAGE OverloadedStrings #-}

-- | Durable state and deadline arithmetic shared by replacement cutovers.
module Nagare.Platform.Replacement
  ( MonotonicTime (..)
  , DowntimeBudget (..)
  , Deadline (..)
  , beginDeadline
  , remainingForwardSeconds
  , deadlineExpired
  , ReplacementState (..)
  , CutoverPhase (..)
  , PhaseStatus (..)
  , PhaseCheckpoint (..)
  , AddressOwner (..)
  , InstancePower (..)
  , HostIdentity (..)
  , RetainedResource (..)
  , Readiness (..)
  , ReplacementTransaction (..)
  , newReplacementTransaction
  , readiness
  , predictedDowntimeSeconds
  , phaseCheckpoint
  , recordPhaseIntent
  , recordPhaseComplete
  , writeReplacementTransaction
  , readReplacementTransaction
  , renderReplacementTransaction
  )
where

import Control.Exception (IOException, bracketOnError, try)
import Data.Aeson ((.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.List (find)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import System.Directory (createDirectoryIfMissing, renameFile)
import System.FilePath (takeDirectory)
import System.IO (hClose, hFlush, openBinaryTempFile)

newtype MonotonicTime = MonotonicTime {monotonicSeconds :: Natural}
  deriving stock (Eq, Ord, Show, Generic)

data DowntimeBudget = DowntimeBudget
  { totalSeconds :: !Natural
  , rollbackReserveSeconds :: !Natural
  , safetyMarginSeconds :: !Natural
  }
  deriving stock (Eq, Show, Generic)

data Deadline = Deadline
  { hardStop :: !MonotonicTime
  , rollbackAt :: !MonotonicTime
  }
  deriving stock (Eq, Show, Generic)

beginDeadline :: MonotonicTime -> DowntimeBudget -> Deadline
beginDeadline (MonotonicTime started) budget =
  Deadline
    { hardStop = MonotonicTime (started + totalSeconds budget)
    , rollbackAt = MonotonicTime (started + forwardWindow)
    }
  where
    reserved = rollbackReserveSeconds budget + safetyMarginSeconds budget
    forwardWindow
      | reserved >= totalSeconds budget = 0
      | otherwise = totalSeconds budget - reserved

remainingForwardSeconds :: MonotonicTime -> Deadline -> Natural
remainingForwardSeconds (MonotonicTime now) (Deadline _ (MonotonicTime cutoff))
  | now >= cutoff = 0
  | otherwise = cutoff - now

deadlineExpired :: MonotonicTime -> Deadline -> Bool
deadlineExpired now deadline = now >= rollbackAt deadline

data ReplacementState
  = Planning
  | Preparing
  | Rehearsing
  | Ready
  | CuttingOver
  | RollingBack
  | RolledBack
  | Committed
  | Finalizing
  | Complete
  | Abandoned
  | ReplacementFailed
  deriving stock (Eq, Ord, Show, Generic)

data CutoverPhase
  = ArmCandidate
  | Revalidate
  | QuiesceOld
  | FinalizeState
  | PrepareCandidateIngress
  | DetachOldAddress
  | AttachCandidateAddress
  | VerifyPublic
  | CommitContext
  | AdmitCandidateWrites
  | StopOld
  | FenceCandidate
  | RestoreOldAddress
  | RestoreOldWorkloads
  | VerifyRollback
  | CleanupFormerActive
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

data PhaseStatus = PhasePending | PhaseIntentPersisted | PhaseObservedComplete
  deriving stock (Eq, Ord, Show, Generic)

data PhaseCheckpoint = PhaseCheckpoint
  { checkpointPhase :: !CutoverPhase
  , checkpointStatus :: !PhaseStatus
  , checkpointAt :: !(Maybe UTCTime)
  , checkpointEvidence :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

data AddressOwner = AddressOnOld | AddressOnCandidate | AddressUnattached | AddressAmbiguous
  deriving stock (Eq, Ord, Show, Generic)

data InstancePower = InstanceRunning | InstanceStopped | InstanceMissing
  deriving stock (Eq, Ord, Show, Generic)

data HostIdentity = HostIdentity
  { hostInstanceName :: !Text
  , hostResourceId :: !Text
  , hostNetworkInterface :: !Text
  , hostAccessConfig :: !Text
  }
  deriving stock (Eq, Show, Generic)

data RetainedResource = RetainedResource
  { retainedResourceId :: !Text
  , retainedRole :: !Text
  , retainedProtected :: !Bool
  }
  deriving stock (Eq, Show, Generic)

data Readiness = Readiness
  { ready :: !Bool
  , predictedForwardSeconds :: !Natural
  , predictedTotalSeconds :: !Natural
  , headroomSeconds :: !Natural
  , blockers :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

data ReplacementTransaction = ReplacementTransaction
  { replacementSchemaVersion :: !Int
  , replacementId :: !Text
  , replacementContext :: !Text
  , replacementProject :: !Text
  , replacementZone :: !Text
  , replacementConfirmation :: !Text
  , replacementState :: !ReplacementState
  , replacementPhase :: !(Maybe CutoverPhase)
  , replacementBudget :: !DowntimeBudget
  , replacementOldHost :: !HostIdentity
  , replacementCandidateHost :: !HostIdentity
  , replacementReservedAddress :: !Text
  , replacementExpectedDriftToken :: !Text
  , replacementObservedDriftToken :: !Text
  , replacementEvidenceValidUntil :: !(Maybe UTCTime)
  , replacementIdentitiesMatch :: !Bool
  , replacementQuiesceContractComplete :: !Bool
  , replacementPredictedStateSeconds :: !Natural
  , replacementPredictedHandoffSeconds :: !Natural
  , replacementPredictedVerificationSeconds :: !Natural
  , replacementAddressOwner :: !AddressOwner
  , replacementOldPower :: !InstancePower
  , replacementCandidateFenced :: !Bool
  , replacementContextCommitted :: !Bool
  , replacementWritesAdmitted :: !Bool
  , replacementDowntimeStartedAt :: !(Maybe UTCTime)
  , replacementDowntimeStartedMonotonic :: !(Maybe MonotonicTime)
  , replacementObservedDowntimeSeconds :: !(Maybe Natural)
  , replacementRollbackEligible :: !Bool
  , replacementSloBreached :: !Bool
  , replacementRetentionUntil :: !(Maybe UTCTime)
  , replacementRetainedResources :: ![RetainedResource]
  , replacementCheckpoints :: ![PhaseCheckpoint]
  , replacementLastError :: !(Maybe Text)
  , replacementUpdatedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

newReplacementTransaction ::
  Text -> Text -> Text -> Text -> DowntimeBudget -> HostIdentity -> HostIdentity -> Text -> UTCTime -> ReplacementTransaction
newReplacementTransaction txId context project zone budget oldHost candidateHost address now =
  ReplacementTransaction
    { replacementSchemaVersion = 1
    , replacementId = txId
    , replacementContext = context
    , replacementProject = project
    , replacementZone = zone
    , replacementConfirmation = context <> "/" <> T.takeEnd 8 txId
    , replacementState = Planning
    , replacementPhase = Nothing
    , replacementBudget = budget
    , replacementOldHost = oldHost
    , replacementCandidateHost = candidateHost
    , replacementReservedAddress = address
    , replacementExpectedDriftToken = ""
    , replacementObservedDriftToken = ""
    , replacementEvidenceValidUntil = Nothing
    , replacementIdentitiesMatch = False
    , replacementQuiesceContractComplete = False
    , replacementPredictedStateSeconds = 0
    , replacementPredictedHandoffSeconds = 0
    , replacementPredictedVerificationSeconds = 0
    , replacementAddressOwner = AddressOnOld
    , replacementOldPower = InstanceRunning
    , replacementCandidateFenced = True
    , replacementContextCommitted = False
    , replacementWritesAdmitted = False
    , replacementDowntimeStartedAt = Nothing
    , replacementDowntimeStartedMonotonic = Nothing
    , replacementObservedDowntimeSeconds = Nothing
    , replacementRollbackEligible = True
    , replacementSloBreached = False
    , replacementRetentionUntil = Nothing
    , replacementRetainedResources = []
    , replacementCheckpoints = map pending [minBound .. maxBound]
    , replacementLastError = Nothing
    , replacementUpdatedAt = now
    }
  where
    pending phase = PhaseCheckpoint phase PhasePending Nothing Nothing

predictedDowntimeSeconds :: ReplacementTransaction -> Natural
predictedDowntimeSeconds tx =
  replacementPredictedStateSeconds tx
    + replacementPredictedHandoffSeconds tx
    + replacementPredictedVerificationSeconds tx

readiness :: UTCTime -> ReplacementTransaction -> Readiness
readiness now tx =
  Readiness
    { ready = null reasons
    , predictedForwardSeconds = forward
    , predictedTotalSeconds = total
    , headroomSeconds = if total >= budget then 0 else budget - total
    , blockers = reasons
    }
  where
    forward = predictedDowntimeSeconds tx
    configured = replacementBudget tx
    budget = totalSeconds configured
    total = forward + rollbackReserveSeconds configured + safetyMarginSeconds configured
    reasons =
      catMaybes
        [ nonEmpty (replacementExpectedDriftToken tx) "missing expected drift token"
        , if replacementExpectedDriftToken tx == replacementObservedDriftToken tx then Nothing else Just "observed drift token does not match the rehearsed inputs"
        , if replacementIdentitiesMatch tx then Nothing else Just "actual project, zone, address, or host identities do not match the transaction"
        , if replacementQuiesceContractComplete tx then Nothing else Just "the production quiesce contract is incomplete"
        , case replacementEvidenceValidUntil tx of
            Nothing -> Just "required rehearsal and state evidence is missing"
            Just expires | expires < now -> Just "required rehearsal or state evidence is stale"
            Just _ -> Nothing
        , if rollbackReserveSeconds configured == 0 then Just "rollback reserve must be nonzero" else Nothing
        , if total <= budget then Nothing else Just ("predicted downtime exceeds the budget by " <> T.pack (show (total - budget)) <> " seconds")
        ]
    nonEmpty value message = if T.null (T.strip value) then Just message else Nothing

phaseCheckpoint :: CutoverPhase -> ReplacementTransaction -> PhaseCheckpoint
phaseCheckpoint wanted tx =
  case find ((== wanted) . checkpointPhase) (replacementCheckpoints tx) of
    Just checkpoint -> checkpoint
    Nothing -> PhaseCheckpoint wanted PhasePending Nothing Nothing

recordPhaseIntent :: UTCTime -> CutoverPhase -> ReplacementTransaction -> ReplacementTransaction
recordPhaseIntent now phase = updateCheckpoint now phase PhaseIntentPersisted Nothing

recordPhaseComplete :: UTCTime -> CutoverPhase -> Text -> ReplacementTransaction -> ReplacementTransaction
recordPhaseComplete now phase evidence = updateCheckpoint now phase PhaseObservedComplete (nonEmpty evidence)
  where
    nonEmpty value = if T.null (T.strip value) then Nothing else Just (T.take 4096 value)

updateCheckpoint :: UTCTime -> CutoverPhase -> PhaseStatus -> Maybe Text -> ReplacementTransaction -> ReplacementTransaction
updateCheckpoint now wanted status evidence tx =
  tx
    { replacementPhase = Just wanted
    , replacementCheckpoints = map update (replacementCheckpoints tx)
    , replacementUpdatedAt = now
    }
  where
    update checkpoint
      | checkpointPhase checkpoint == wanted = PhaseCheckpoint wanted status (Just now) evidence
      | otherwise = checkpoint

writeReplacementTransaction :: FilePath -> ReplacementTransaction -> IO ()
writeReplacementTransaction path tx = do
  createDirectoryIfMissing True (takeDirectory path)
  bracketOnError
    (openBinaryTempFile (takeDirectory path) ".replacement-transaction.tmp")
    (\(temporary, handle) -> hClose handle >> pure temporary)
    (\(temporary, handle) -> do
      LBS.hPut handle (Aeson.encode tx)
      hFlush handle
      hClose handle
      renameFile temporary path)

readReplacementTransaction :: FilePath -> IO (Either Text ReplacementTransaction)
readReplacementTransaction path = do
  result <- try (BS.readFile path)
  pure $ case result of
    Left (err :: IOException) -> Left ("could not read replacement transaction " <> T.pack path <> ": " <> T.pack (show err))
    Right bytes -> case Aeson.eitherDecodeStrict' bytes of
      Left err -> Left ("invalid replacement transaction " <> T.pack path <> ": " <> T.pack err)
      Right tx
        | replacementSchemaVersion tx /= 1 -> Left ("unsupported replacement transaction schema " <> T.pack (show (replacementSchemaVersion tx)) <> "; upgrade nagarectl before retrying")
        | otherwise -> Right tx

renderReplacementTransaction :: UTCTime -> ReplacementTransaction -> Text
renderReplacementTransaction now tx =
  T.unlines
    [ "Replacement " <> replacementId tx <> " (" <> replacementContext tx <> ")"
    , "State: " <> stateToken (replacementState tx)
    , "Phase: " <> maybe "none" phaseToken (replacementPhase tx)
    , "Address: " <> addressOwnerToken (replacementAddressOwner tx)
    , "Rollback eligible: " <> yesNo (replacementRollbackEligible tx)
    , "Predicted downtime: " <> T.pack (show (predictedDowntimeSeconds tx)) <> "s"
    , "Observed downtime: " <> maybe "not started" ((<> "s") . T.pack . show) (replacementObservedDowntimeSeconds tx)
    , "Retention until: " <> maybe "not scheduled" (T.pack . show) (replacementRetentionUntil tx)
    , if null (blockers report) then "Blockers: none" else "Blockers: " <> T.intercalate "; " (blockers report)
    ]
  where
    report = readiness now tx
    yesNo True = "yes"
    yesNo False = "no"

instance Aeson.ToJSON MonotonicTime where toJSON = Aeson.genericToJSON Aeson.defaultOptions
instance Aeson.FromJSON MonotonicTime where parseJSON = Aeson.genericParseJSON Aeson.defaultOptions
instance Aeson.ToJSON DowntimeBudget where toJSON = Aeson.genericToJSON Aeson.defaultOptions
instance Aeson.FromJSON DowntimeBudget where parseJSON = Aeson.genericParseJSON Aeson.defaultOptions
instance Aeson.ToJSON Deadline where toJSON = Aeson.genericToJSON Aeson.defaultOptions
instance Aeson.FromJSON Deadline where parseJSON = Aeson.genericParseJSON Aeson.defaultOptions
instance Aeson.ToJSON PhaseCheckpoint where toJSON = Aeson.genericToJSON Aeson.defaultOptions
instance Aeson.FromJSON PhaseCheckpoint where parseJSON = Aeson.genericParseJSON Aeson.defaultOptions
instance Aeson.ToJSON HostIdentity where toJSON = Aeson.genericToJSON Aeson.defaultOptions
instance Aeson.FromJSON HostIdentity where parseJSON = Aeson.genericParseJSON Aeson.defaultOptions
instance Aeson.ToJSON RetainedResource where toJSON = Aeson.genericToJSON Aeson.defaultOptions
instance Aeson.FromJSON RetainedResource where parseJSON = Aeson.genericParseJSON Aeson.defaultOptions
instance Aeson.ToJSON Readiness where toJSON = Aeson.genericToJSON Aeson.defaultOptions
instance Aeson.FromJSON Readiness where parseJSON = Aeson.genericParseJSON Aeson.defaultOptions
instance Aeson.ToJSON ReplacementTransaction where toJSON = Aeson.genericToJSON Aeson.defaultOptions
instance Aeson.FromJSON ReplacementTransaction where parseJSON = Aeson.genericParseJSON Aeson.defaultOptions

instance Aeson.ToJSON ReplacementState where toJSON = Aeson.String . stateToken
instance Aeson.FromJSON ReplacementState where parseJSON = Aeson.withText "ReplacementState" (parseToken "replacement state" stateTokens)
instance Aeson.ToJSON CutoverPhase where toJSON = Aeson.String . phaseToken
instance Aeson.FromJSON CutoverPhase where parseJSON = Aeson.withText "CutoverPhase" (parseToken "cutover phase" phaseTokens)
instance Aeson.ToJSON PhaseStatus where toJSON = Aeson.String . phaseStatusToken
instance Aeson.FromJSON PhaseStatus where parseJSON = Aeson.withText "PhaseStatus" (parseToken "phase status" phaseStatusTokens)
instance Aeson.ToJSON AddressOwner where toJSON = Aeson.String . addressOwnerToken
instance Aeson.FromJSON AddressOwner where parseJSON = Aeson.withText "AddressOwner" (parseToken "address owner" addressOwnerTokens)
instance Aeson.ToJSON InstancePower where toJSON = Aeson.String . powerToken
instance Aeson.FromJSON InstancePower where parseJSON = Aeson.withText "InstancePower" (parseToken "instance power" powerTokens)

parseToken :: String -> [(Text, a)] -> Text -> Parser a
parseToken label values token =
  maybe (fail ("unknown " <> label <> ": " <> T.unpack token)) pure (lookup token values)

stateTokens :: [(Text, ReplacementState)]
stateTokens =
  [ ("planning", Planning), ("preparing", Preparing), ("rehearsing", Rehearsing)
  , ("ready", Ready), ("cutting-over", CuttingOver), ("rolling-back", RollingBack)
  , ("rolled-back", RolledBack), ("committed", Committed), ("finalizing", Finalizing)
  , ("complete", Complete), ("abandoned", Abandoned), ("failed", ReplacementFailed)
  ]

stateToken :: ReplacementState -> Text
stateToken value = maybe "unknown" fst (find ((== value) . snd) stateTokens)

phaseTokens :: [(Text, CutoverPhase)]
phaseTokens =
  [ ("arm-candidate", ArmCandidate), ("revalidate", Revalidate), ("quiesce-old", QuiesceOld)
  , ("finalize-state", FinalizeState), ("prepare-candidate-ingress", PrepareCandidateIngress)
  , ("detach-old-address", DetachOldAddress), ("attach-candidate-address", AttachCandidateAddress)
  , ("verify-public", VerifyPublic), ("commit-context", CommitContext)
  , ("admit-candidate-writes", AdmitCandidateWrites), ("stop-old", StopOld)
  , ("fence-candidate", FenceCandidate), ("restore-old-address", RestoreOldAddress)
  , ("restore-old-workloads", RestoreOldWorkloads), ("verify-rollback", VerifyRollback)
  , ("cleanup-former-active", CleanupFormerActive)
  ]

phaseToken :: CutoverPhase -> Text
phaseToken value = maybe "unknown" fst (find ((== value) . snd) phaseTokens)

phaseStatusTokens :: [(Text, PhaseStatus)]
phaseStatusTokens = [("pending", PhasePending), ("intent-persisted", PhaseIntentPersisted), ("observed-complete", PhaseObservedComplete)]

phaseStatusToken :: PhaseStatus -> Text
phaseStatusToken value = maybe "unknown" fst (find ((== value) . snd) phaseStatusTokens)

addressOwnerTokens :: [(Text, AddressOwner)]
addressOwnerTokens = [("old", AddressOnOld), ("candidate", AddressOnCandidate), ("unattached", AddressUnattached), ("ambiguous", AddressAmbiguous)]

addressOwnerToken :: AddressOwner -> Text
addressOwnerToken value = maybe "unknown" fst (find ((== value) . snd) addressOwnerTokens)

powerTokens :: [(Text, InstancePower)]
powerTokens = [("running", InstanceRunning), ("stopped", InstanceStopped), ("missing", InstanceMissing)]

powerToken :: InstancePower -> Text
powerToken value = maybe "unknown" fst (find ((== value) . snd) powerTokens)
