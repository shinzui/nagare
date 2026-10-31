-- | Collect a platform-versions snapshot through injected providers
-- (EP-236). The CLI supplies kubectl and store providers; tests supply
-- adversarial fakes.
--
-- The accepted head is captured before any probe and read again after the
-- last: observations taken while the head changed are discarded and
-- collected once more, then published as @inventory_changed@ rather than
-- attributed to the wrong declarations. At most @concurrency@ reads run at
-- once, each inside what remains of the budget; a read that cannot start or
-- finish in time is @collection_deadline@. A failed probe never cancels
-- another, and cancellation of the collector itself is never swallowed.
module Nagare.Platform.Versions.Collect
  ( VersionProviders (..)
  , CollectSettings (..)
  , collectVersions
  , unavailableFacts
  )
where

import Control.Concurrent.Async (Concurrently (..), mapConcurrently)
import Control.Concurrent.QSem (newQSem, signalQSem, waitQSem)
import Control.Exception (SomeAsyncException, SomeException, bracket_, fromException, throwIO, try)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import GHC.Clock (getMonotonicTimeNSec)
import Nagare.Contract.Schema (Nullable (..))
import Nagare.Contract.Versions
import Nagare.Dsl.Prelude
import Nagare.Platform.Versions
import Nagare.Platform.Versions.Assemble
import System.Timeout (timeout)

-- | Everything a collection reads. @loadAccepted@ returns the accepted
-- head's revision and its platform and database members; @currentRevision@
-- reads the head's revision again. Provider reads report a failure class,
-- never error text.
data VersionProviders = VersionProviders
  { loadAccepted :: !(IO (Either Text (Text, [AcceptedMember])))
  , currentRevision :: !(IO (Either Text Text))
  , readStamp :: !(IO (Either ProviderFailure ByteString))
  , readHostIdentity :: !(IO (Either ProviderFailure ByteString))
  , readNodes :: !(IO (Either ProviderFailure ByteString))
  , readPods :: !(Text -> IO (Either ProviderFailure ByteString))
  , runEngine :: !(Text -> Text -> Text -> [String] -> IO (Either ProviderFailure Text))
  -- ^ Engine, namespace, pod and the fixed probe command.
  , readPodUid :: !(Text -> Text -> IO (Either ProviderFailure Text))
  , clock :: !(IO Text)
  }

data CollectSettings = CollectSettings
  { context :: !Text
  , project :: !Text
  , pins :: !(Maybe Pins)
  , budgetMicroseconds :: !Int
  , concurrency :: !Int
  }
  deriving stock (Generic)

-- | Collect one snapshot. 'Left' means no snapshot can be published (the
-- accepted inventory could not be read); every provider failure is a
-- reason inside the snapshot instead.
collectVersions :: CollectSettings -> VersionProviders -> IO (Either Text VersionSnapshot)
collectVersions settings providers = do
  started <- getMonotonicTimeNSec
  let deadline = started + fromIntegral (max 0 (settings ^. #budgetMicroseconds)) * 1000
  slots <- newQSem (max 1 (settings ^. #concurrency))
  let probe :: IO (Either ProviderFailure a) -> IO (Reading a)
      probe action = bracket_ (waitQSem slots) (signalQSem slots) $ do
        attemptedAt <- clock providers
        now <- getMonotonicTimeNSec
        let remaining = if now >= deadline then 0 else fromIntegral ((deadline - now) `div` 1000)
        if remaining <= 0
          then pure (Reading attemptedAt (Left ProviderDeadline))
          else do
            outcome <- try (timeout remaining action)
            case outcome of
              Right (Just value) -> pure (Reading attemptedAt value)
              Right Nothing -> pure (Reading attemptedAt (Left ProviderDeadline))
              Left (failure :: SomeException)
                | Just (_ :: SomeAsyncException) <- fromException failure -> throwIO failure
                | otherwise -> pure (Reading attemptedAt (Left ProviderUnreadable))
      attempt :: Int -> IO (Either Text VersionSnapshot)
      attempt round' = do
        collectedAt <- clock providers
        accepted <- loadAccepted providers
        case accepted of
          Left failure -> pure (Left failure)
          Right (revision, members) -> do
            observed <- observe probe members collectedAt
            after <- currentRevision providers
            completedAt <- clock providers
            case after of
              Left failure -> pure (Left failure)
              Right current
                | current == revision -> pure (Right (observed (snapshotOf collectedAt completedAt revision)))
                | round' < 2 -> attempt (round' + 1)
                | otherwise -> pure (Right (changed (snapshotOf collectedAt completedAt revision)))
  attempt 1
  where
    snapshotOf collectedAt completedAt revision =
      VersionSnapshot
        { snapshotSchema = snapshotSchemaVersion
        , context = settings ^. #context
        , project = settings ^. #project
        , collectedAt = collectedAt
        , completedAt = completedAt
        , inventoryRevision = Nullable (Just revision)
        , reason = Nullable Nothing
        , installed = Nullable Nothing
        , pins = Nullable (settings ^. #pins)
        , hosts = []
        , hostsReason = Nullable Nothing
        , components = []
        , componentsReason = Nullable Nothing
        , databases = []
        , databasesReason = Nullable Nothing
        }
    changed snapshot =
      snapshot
        { reason = Nullable (Just reasonInventoryChanged)
        , pins = Nullable Nothing
        , hostsReason = Nullable (Just reasonInventoryChanged)
        , componentsReason = Nullable (Just reasonInventoryChanged)
        , databasesReason = Nullable (Just reasonInventoryChanged)
        }
    observe :: (forall a. IO (Either ProviderFailure a) -> IO (Reading a)) -> [AcceptedMember] -> Text -> IO (VersionSnapshot -> VersionSnapshot)
    observe probe members collectedAt = do
      let workloads = declaredWorkloads members
          namespaces = nub (sort [workload ^. #namespace | workload <- workloads])
      (stamp, identity, nodes, podLists) <-
        runConcurrently $
          (,,,)
            <$> Concurrently (probe (readStamp providers))
            <*> Concurrently (probe (readHostIdentity providers))
            <*> Concurrently (probe (readNodes providers))
            <*> Concurrently (mapConcurrently (\namespaceText -> (namespaceText,) <$> probe (readPods providers namespaceText)) namespaces)
      let podsByNamespace = Map.fromList [(namespaceText, parsed reading) | (namespaceText, reading) <- podLists]
          parsed reading = reading {result = result reading >>= maybe (Left ProviderUnreadable) Right . parsePods}
      readings <-
        mapConcurrently
          ( \(engineText, namespaceText, pod) -> do
              reading <- case engineProbe engineText of
                Nothing -> (\at' -> EngineReading (Reading at' (Left ProviderUnsupported)) (Reading at' (Left ProviderUnsupported))) <$> clock providers
                Just (command, _) -> do
                  answered <- probe (failedProbe <$> runEngine providers engineText namespaceText (pod ^. #name) command)
                  uidNow <- probe (readPodUid providers namespaceText (pod ^. #name))
                  pure (EngineReading answered uidNow)
              pure ((namespaceText, pod ^. #name), reading)
          )
          (databaseTargets workloads podsByNamespace)
      let (hostList, hostGap) = hostsSection nodes identity
      pure $ \snapshot ->
        snapshot
          { installed = Nullable (Just (installedSection stamp))
          , hosts = hostList
          , hostsReason = Nullable hostGap
          , components = componentsSection workloads podsByNamespace collectedAt
          , databases = databasesSection workloads podsByNamespace (Map.fromList readings) collectedAt
          }
    -- An engine that answered with an error is a failed probe, not an
    -- unreadable source.
    failedProbe = first (\failure -> if failure == ProviderUnreadable then ProviderProbeFailed else failure)

-- | How many facts in a snapshot have no value, for the refresh summary.
unavailableFacts :: VersionSnapshot -> (Int, Int)
unavailableFacts snapshot = (length (filter isNothing values), length values)
  where
    values = map (\fact -> fromNullable' (fact ^. #value)) (facts snapshot)
    fromNullable' (Nullable value) = value
    facts stored =
      maybe [] (\release -> [release ^. #version, release ^. #revision, release ^. #payloadId, release ^. #installedAt]) (fromNullable'' (stored ^. #installed))
        <> concat
          [ [host ^. #osImage, host ^. #kernel, host ^. #kubernetes, host ^. #nixos . #release, host ^. #nixos . #codename, host ^. #nixos . #version, host ^. #nixos . #nixpkgsRevision]
          | host <- stored ^. #hosts
          ]
        <> concat
          [ [component ^. #declaredVersion]
              <> map (^. #image) (component ^. #declaredImages)
              <> concat [[container ^. #image, container ^. #imageDigest] | workload <- component ^. #workloads, container <- workload ^. #containers]
          | component <- stored ^. #components
          ]
        <> concat
          [ [database ^. #declaredVersion, database ^. #declaredImage]
              <> concat [[instance' ^. #image, instance' ^. #imageDigest, instance' ^. #reportedVersion] | instance' <- database ^. #instances]
          | database <- stored ^. #databases
          ]
    fromNullable'' (Nullable value) = value
