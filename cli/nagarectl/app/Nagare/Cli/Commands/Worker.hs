-- | Commands / Worker. Executable-private CLI boundary.
module Nagare.Cli.Commands.Worker
  ( runWorker
  )
where

import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Text qualified as T
import Nagare.App.Deploy
  ( AppDeployParams
      ( AppDeployParams
      , baseDomain
      , configPath
      , contextOverride
      , dockerfileOverride
      , dryRun
      , json
      , source
      , tag
      , targetProfile
      )
  , resolveAppRolloutWithBrokerEnv
  )
import Nagare.Cli.Application.Config (appNamespace)
import Nagare.Cli.Application.Inputs
  ( reviewedStandaloneDatabases
  )
import Nagare.Cli.Inventory.Execution
  ( inventoryExecutionRegistry
  )
import Nagare.Cli.Inventory.Planning
  ( inventoryPlanRegistry
  , inventoryPlanRegistryWithNative
  )
import Nagare.Cli.Options
  ( WorkerCommand (..)
  , WorkerDeployOpts (..)
  )
import Nagare.Cli.Runtime.Config (provisionGhcEnv)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target
  ( activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Dsl.Application (Application (..))
import Nagare.Dsl.Load qualified as Load
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (namespaceText, serviceNameText)
import Nagare.Inventory.Application
  ( acceptedApplicationImage
  , acceptedBrokerBindings
  , acceptedImageBuildSecrets
  , acceptedSecretBindings
  , compileStandaloneWorkerWithDependenciesAndBuild
  , recordReviewedStandaloneOverrides
  , standaloneWorkerVolumeRecoveryBindings
  , workerRetirementScope
  )
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService (acceptedFoundationNamespace)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire qualified as ResourceWire

-- | Dispatch the @worker@ command group (EP-71). Provisions the GHC environment
-- before loading the worker's @Config.hs@ (mirroring @db create --config@), then
-- routes the deployment through the reviewed inventory compiler.
runWorker :: Maybe String -> WorkerCommand -> IO ()
runWorker mctx = \case
  WorkerDeploy o -> runWorkerPlan mctx o (fromMaybe "" (o ^. #savePlan))
  WorkerDelete o -> do
    active <- activeTarget mctx
    snapshot <- Inventory.loadTargetSnapshot active
    owner <-
      either
        dieT
        pure
        ( workerRetirementScope
            (T.pack (o ^. #nameArg))
            (appNamespace (o ^. #namespace))
            (T.pack <$> o ^. #scopeKey)
            snapshot
        )
    (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
    Inventory.planInventoryRetirementWith
      (inventoryPlanRegistry active workspace)
      active
      owner
      (o ^. #savePlan)

runWorkerPlan :: Maybe String -> WorkerDeployOpts -> FilePath -> IO ()
runWorkerPlan mctx options output = do
  when
    (options ^. #dryRun && isJust (options ^. #savePlan))
    (dieT "reviewed worker deploy cannot combine --dry-run with --save-plan")
  when
    ( isJust (options ^. #contextOverride)
        || isJust (options ^. #dockerfileOverride)
    )
    (dieT "reviewed worker deploy requires a prepublished image and no build overrides")
  when
    (isNothing (options ^. #tag))
    (dieT "reviewed worker deploy requires an explicit --tag")
  imageText <-
    maybe
      (dieT "reviewed worker deploy requires --image-resource")
      (pure . T.pack)
      (options ^. #imageResource)
  imageId <- either dieT pure (Resource.mkResourceId imageText)
  provisionGhcEnv (options ^. #ghcEnv)
  worker <-
    Load.loadWorker (options ^. #file)
      >>= either (dieT . Load.renderLoadError) pure
  key <-
    maybe
      (either dieT pure (Resource.mkLogicalKey (serviceNameText (worker ^. #name))))
      pure
      (worker ^. #logicalKey)
  owner <-
    either
      dieT
      pure
      ( Resource.mkScopeId
          Resource.Standalone
          ("worker-" <> Resource.logicalKeyText key)
      )
  recovery <-
    either
      dieT
      pure
      ( standaloneWorkerVolumeRecoveryBindings
          owner
          worker
          (map T.pack (options ^. #volumeRecovery))
      )
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, namespaceId) <-
    either
      dieT
      pure
      (acceptedFoundationNamespace snapshot (namespaceText (worker ^. #namespace)))
  (brokerServices, brokerTopics, _) <-
    either
      dieT
      pure
      ( acceptedBrokerBindings
          snapshot
          cluster
          (namespaceText (worker ^. #namespace))
          (worker ^. #brokers)
      )
  databaseBindings <-
    reviewedStandaloneDatabases
      active
      snapshot
      cluster
      (namespaceText (worker ^. #namespace))
      (worker ^. #databases)
  let app =
        Application
          { name = worker ^. #name
          , logicalKey = Nothing
          , namespace = worker ^. #namespace
          , image = worker ^. #image
          , env = Map.empty
          , databases = []
          , brokers = []
          , access = Nothing
          , service = Nothing
          , workers = [worker]
          , tasks = []
          }
      params =
        AppDeployParams
          { configPath = options ^. #file
          , tag = T.pack <$> options ^. #tag
          , baseDomain = Nothing
          , contextOverride = Nothing
          , dockerfileOverride = Nothing
          , dryRun = False
          , json = False
          , source = Nothing
          , targetProfile = active ^. #profile
          }
  rollout <- resolveAppRolloutWithBrokerEnv params app Map.empty
  either dieT pure (acceptedApplicationImage snapshot imageId (rollout ^. #taggedAppImage))
  buildSecrets <-
    either
      dieT
      pure
      ( acceptedImageBuildSecrets
          snapshot
          imageId
          cluster
          (serviceNameText (worker ^. #name))
          (namespaceText (worker ^. #namespace))
      )
  envIds <-
    traverse
      (either dieT pure . Resource.mkResourceId . T.pack)
      (options ^. #envSecretResources)
  envSecrets <- either dieT pure (acceptedSecretBindings snapshot envIds)
  let source =
        Resource.SourceLocation
          (T.pack (options ^. #file))
          (serviceNameText (worker ^. #name))
  (compiledScope, native) <-
    either
      (dieT . T.pack . show)
      pure
      ( compileStandaloneWorkerWithDependenciesAndBuild
          buildSecrets
          owner
          worker
          rollout
          cluster
          namespaceId
          imageId
          recovery
          envSecrets
          brokerServices
          brokerTopics
          databaseBindings
          source
      )
  scope <-
    either
      (dieT . T.pack . show)
      pure
      ( recordReviewedStandaloneOverrides
          rollout
          imageId
          ( Map.fromList
              ( [("tag", T.pack selected) | selected <- maybe [] pure (options ^. #tag)]
                  <> [("imageResource", imageText)]
              )
          )
          compiledScope
      )
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))
  if options ^. #dryRun
    then BC.putStrLn (ResourceWire.encodeCanonicalScope scope)
    else case options ^. #savePlan of
      Nothing ->
        Inventory.convergeInventoryCandidateWith
          (inventoryPlanRegistryWithNative active workspace native)
          (inventoryExecutionRegistry mctx)
          active
          candidate
      Just _ ->
        Inventory.planInventoryCandidateWith
          (inventoryPlanRegistryWithNative active workspace native)
          active
          candidate
          output
