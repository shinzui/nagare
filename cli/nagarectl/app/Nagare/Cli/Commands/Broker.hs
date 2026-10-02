-- | Commands / Broker. Executable-private CLI boundary.
module Nagare.Cli.Commands.Broker
  ( runBroker
  )
where

import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Text qualified as T
import Nagare.Broker.Create
  ( BrokerCreateParams (..)
  , resolveBroker
  , runBrokerCreateWithGuard
  )
import Nagare.Broker.Get (runBrokerGet)
import Nagare.Broker.List (runBrokerList)
import Nagare.Broker.Restart (runBrokerRestart)
import Nagare.Cli.Data.Lifecycle
  ( runDataRestart
  , runStandaloneRetirePlan
  )
import Nagare.Cli.Inventory.Execution
  ( inventoryExecutionRegistry
  )
import Nagare.Cli.Inventory.Planning
  ( inventoryPlanRegistryWithNative
  )
import Nagare.Cli.Options (BrokerCommand (..))
import Nagare.Cli.Runtime.Config (provisionGhcEnv)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Ownership
  ( ownedHistoryResources
  , withAcceptedInventoryHistory
  )
import Nagare.Cli.Runtime.Target
  ( activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Dsl.Broker (BrokerProvider (..), brokerNameText)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (namespaceText)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService
  ( NativeDataKind (BrokerObjects)
  , acceptedFoundationNamespace
  , brokerNativeOwned
  , brokerTopicChangeRequiresReview
  , compileStandaloneBroker
  )
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Policy (RecoveryIntent (..), mkSecretRef)
import Nagare.Resource.Types qualified as Resource

-- | Dispatch the @broker@ subcommands (MasterPlan 15, EP-78). The namespace
-- defaults to @personal@.
runBroker :: Maybe String -> BrokerCommand -> IO ()
runBroker mctx = \case
  BrokerList o -> runBrokerList (nsOf (o ^. #namespace))
  BrokerCreate provider name o -> do
    when (isJust (o ^. #config)) (provisionGhcEnv Nothing)
    let params =
          BrokerCreateParams
            { namespace = nsOf (o ^. #namespace)
            , version = T.pack <$> o ^. #version
            , size = T.pack <$> o ^. #size
            , cpu = T.pack <$> o ^. #cpu
            , memory = T.pack <$> o ^. #memory
            , config = o ^. #config
            , dryRun = o ^. #dryRun
            , redpandaSmp = o ^. #redpandaSmp
            , redpandaMemory = T.pack <$> o ^. #redpandaMemory
            , topics = map T.pack (o ^. #topics)
            , topicPartitions = o ^. #topicPartitions
            , topicRetentionMs = o ^. #topicRetentionMs
            }
    if o ^. #dryRun
      then do
        when (isJust (o ^. #savePlan)) (dieT "broker create --dry-run cannot save a review")
        runBrokerCreateWithGuard provider (T.pack name) params $ \broker ->
          withAcceptedInventoryHistory mctx "broker create" $ \history ->
            when
              (brokerNativeOwned broker (ownedHistoryResources history))
              (dieT "broker objects are owned by accepted or retained inventory history; direct create is refused")
      else
        runBrokerCreatePlan
          mctx
          provider
          (T.pack name)
          params
          (o ^. #recoveryBackup)
          (o ^. #recoveryKey)
          (o ^. #recoveryKeyVersion)
          (o ^. #savePlan)
  BrokerGet o -> runBrokerGet (nsOf (o ^. #namespace)) (T.pack (o ^. #name))
  BrokerRestart o dryRun output ->
    runDataRestart
      mctx
      BrokerObjects
      (T.pack (o ^. #name))
      (nsOf (o ^. #namespace))
      dryRun
      output
      (runBrokerRestart (nsOf (o ^. #namespace)) (T.pack (o ^. #name)) dryRun)
  BrokerDelete o ->
    runStandaloneRetirePlan
      mctx
      "broker"
      (T.pack (o ^. #name))
      (nsOf (o ^. #namespace))
      (T.pack <$> o ^. #scopeKey)
      (o ^. #savePlan)
  BrokerRetire o ->
    runStandaloneRetirePlan
      mctx
      "broker"
      (T.pack (o ^. #name))
      (nsOf (o ^. #namespace))
      (T.pack <$> o ^. #scopeKey)
      (o ^. #savePlan)
  where
    nsOf = maybe "personal" T.pack

runBrokerCreatePlan ::
  Maybe String ->
  BrokerProvider ->
  Text ->
  BrokerCreateParams ->
  Maybe String ->
  Maybe String ->
  Maybe String ->
  Maybe FilePath ->
  IO ()
runBrokerCreatePlan mctx provider name params backupName keyName keyVersion output = do
  broker <- resolveBroker provider name params
  let brokerName = brokerNameText (broker ^. #name)
      namespaceName = namespaceText (broker ^. #namespace)
      scopeName = maybe brokerName Resource.logicalKeyText (broker ^. #logicalKey)
  unless
    (brokerName == name && broker ^. #provider == provider)
    (dieT "reviewed broker config must match the command's provider and name")
  owner <- either dieT pure (Resource.mkScopeId Resource.Standalone ("broker-" <> scopeName))
  backup <- maybe (dieT "reviewed broker create requires --recovery-backup") (either dieT pure . Resource.mkName . T.pack) backupName
  key <- maybe (dieT "reviewed broker create requires --recovery-key") (either dieT pure . Resource.mkName . T.pack) keyName
  version <- maybe (dieT "reviewed broker create requires --recovery-key-version") (either dieT pure . Resource.mkName . T.pack) keyVersion
  let recovery = RecoveryIntent backup (mkSecretRef key version NE.:| [])
      source =
        Resource.SourceLocation
          (maybe "broker create" T.pack (params ^. #config))
          brokerName
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, namespaceId) <- either dieT pure (acceptedFoundationNamespace snapshot namespaceName)
  (scope, native) <-
    either
      (dieT . T.pack . show)
      pure
      (compileStandaloneBroker broker owner cluster namespaceId recovery source)
  when
    ( isNothing output
        && maybe
          False
          (brokerTopicChangeRequiresReview scope . snd)
          (Map.lookup owner (ResourceInventory.snapshotScopes snapshot))
    )
    (dieT "changing an accepted broker topic requires --save-plan and a separate reviewed inventory apply")
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))
  case output of
    Nothing ->
      Inventory.convergeInventoryCandidateWith
        (inventoryPlanRegistryWithNative active workspace native)
        (inventoryExecutionRegistry mctx)
        active
        candidate
    Just directory ->
      Inventory.planInventoryCandidateWith
        (inventoryPlanRegistryWithNative active workspace native)
        active
        candidate
        directory
