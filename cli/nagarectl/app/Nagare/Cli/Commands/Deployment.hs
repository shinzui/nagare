-- | Commands / Deployment. Executable-private CLI boundary.
module Nagare.Cli.Commands.Deployment
  ( runDeploy
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Time (getCurrentTime)
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
import Nagare.App.Deployments (appConfigMapName)
import Nagare.Cli.Application.Inputs
  ( reviewedStandaloneDatabases
  , validateInlineReleaseAdoption
  )
import Nagare.Cli.Inventory.Execution
  ( inventoryExecutionRegistry
  )
import Nagare.Cli.Inventory.Planning
  ( inventoryPlanRegistryWithNative
  )
import Nagare.Cli.Options (DeployOpts)
import Nagare.Cli.Runtime.Config (provisionGhcEnv)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target
  ( activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Deploy (serviceUrl)
import Nagare.Dsl.Application (Application (..))
import Nagare.Dsl.Load qualified as Load
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types
  ( imageRefText
  , namespaceText
  , serviceNameText
  )
import Nagare.Inventory.Application
  ( acceptedAccessBinding
  , acceptedApplicationImage
  , acceptedBrokerBindings
  , acceptedImageBuildSecrets
  , acceptedSecretBindings
  , acceptedStandaloneReleaseLog
  , applicationVolumeRecoveryBindings
  , compileStandaloneServiceWithReleaseAndBuild
  , legacyStandaloneReleaseImport
  , recordReviewedStandaloneOverrides
  )
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService (acceptedFoundationNamespace)
import Nagare.Inventory.Lifecycle qualified as InventoryLifecycle
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire qualified as ResourceWire
import Nagare.Static.Release
  ( StaticRelease
      ( StaticRelease
      , createdAt
      , image
      , imageTag
      , namespace
      , releaseId
      , siteName
      , source
      , url
      )
  )

runDeploy :: Maybe String -> DeployOpts -> IO ()
runDeploy mctx dopts =
  runDeployPlan
    mctx
    dopts
    (fromMaybe "" (dopts ^. #savePlan))

runDeployPlan :: Maybe String -> DeployOpts -> FilePath -> IO ()
runDeployPlan mctx options output = do
  case (options ^. #legacyReleaseImport, options ^. #releaseAdoptionInput) of
    (Nothing, Nothing) -> pure ()
    (Just _, Just _) -> pure ()
    _ -> dieT "legacy release import requires both --legacy-release-import and --release-adoption-input"
  when
    (options ^. #dryRun && isJust (options ^. #savePlan))
    (dieT "reviewed deploy cannot combine --dry-run with --save-plan")
  when
    ( isNothing (options ^. #savePlan)
        && ( isJust (options ^. #legacyReleaseImport)
               || isJust (options ^. #releaseAdoptionInput)
           )
    )
    (dieT "legacy release adoption requires --save-plan and a separate reviewed apply")
  when
    ( isJust (options ^. #contextOverride)
        || isJust (options ^. #dockerfileOverride)
    )
    (dieT "reviewed deploy requires a prepublished image and no build overrides")
  when
    (isNothing (options ^. #tag))
    (dieT "reviewed deploy requires an explicit --tag")
  imageText <-
    maybe
      (dieT "reviewed deploy requires --image-resource")
      (pure . T.pack)
      (options ^. #imageResource)
  imageId <- either dieT pure (Resource.mkResourceId imageText)
  provisionGhcEnv (options ^. #ghcEnv)
  service <-
    Load.loadDeployment (options ^. #file)
      >>= either (dieT . Load.renderLoadError) pure
  unless
    (isNothing (service ^. #cdn))
    (dieT "reviewed single-Service deploy requires typed CDN ownership")
  let app =
        Application
          { name = service ^. #name
          , logicalKey = service ^. #logicalKey
          , namespace = service ^. #namespace
          , image = service ^. #image
          , env = Map.empty
          , databases = []
          , brokers = []
          , access = Nothing
          , service = Just service
          , workers = []
          , tasks = []
          }
  (volumeRecovery, workerRecovery) <-
    either
      dieT
      pure
      ( applicationVolumeRecoveryBindings
          app
          (map T.pack (options ^. #serviceVolumeRecovery))
          []
      )
  unless
    (Map.null workerRecovery)
    (dieT "standalone Service review contains worker recovery bindings")
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  let namespaceName = namespaceText (service ^. #namespace)
  (cluster, namespaceId) <-
    either
      dieT
      pure
      (acceptedFoundationNamespace snapshot namespaceName)
  accessBinding <-
    traverse
      ( \_ ->
          either
            dieT
            pure
            (acceptedAccessBinding snapshot cluster)
      )
      (service ^. #access)
  (brokerServices, brokerTopics, _) <-
    either
      dieT
      pure
      (acceptedBrokerBindings snapshot cluster namespaceName (service ^. #brokers))
  databaseBindings <-
    reviewedStandaloneDatabases
      active
      snapshot
      cluster
      namespaceName
      (service ^. #databases)
  let params =
        AppDeployParams
          { configPath = options ^. #file
          , tag = T.pack <$> options ^. #tag
          , baseDomain = T.pack <$> options ^. #baseDomain
          , contextOverride = Nothing
          , dockerfileOverride = Nothing
          , dryRun = False
          , json = False
          , source = T.pack <$> options ^. #source
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
          (serviceNameText (service ^. #name))
          namespaceName
      )
  tlsIds <-
    traverse
      (either dieT pure . Resource.mkResourceId . T.pack)
      (options ^. #tlsSecretResources)
  envIds <-
    traverse
      (either dieT pure . Resource.mkResourceId . T.pack)
      (options ^. #envSecretResources)
  tlsSecrets <- either dieT pure (acceptedSecretBindings snapshot tlsIds)
  envSecrets <- either dieT pure (acceptedSecretBindings snapshot envIds)
  key <-
    maybe
      (either dieT pure (Resource.mkLogicalKey (serviceNameText (service ^. #name))))
      pure
      (service ^. #logicalKey)
  owner <-
    either
      dieT
      pure
      ( Resource.mkScopeId
          Resource.Standalone
          ("service-" <> Resource.logicalKeyText key)
      )
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  acceptedInventory <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot snapshot)
  (acceptedNative, _) <-
    InventoryStatus.loadAcceptedNative store history acceptedInventory
      >>= either dieT pure
  let source =
        Resource.SourceLocation
          (maybe (T.pack (options ^. #file)) T.pack (options ^. #source))
          (serviceNameText (service ^. #name))
      releaseTag = rollout ^. #effectiveTag
  (priorReleases, release, adoption) <- case (options ^. #legacyReleaseImport, options ^. #releaseAdoptionInput) of
    (Nothing, Nothing) -> do
      prior <-
        either
          dieT
          pure
          (acceptedStandaloneReleaseLog snapshot acceptedNative owner service cluster)
      releasedAt <- getCurrentTime
      pure
        ( prior
        , StaticRelease
            { releaseId = releaseTag
            , siteName = serviceNameText (service ^. #name)
            , namespace = namespaceName
            , image = imageRefText (rollout ^. #qualifiedImage)
            , imageTag = releaseTag
            , url = serviceUrl service (rollout ^. #baseDomain)
            , source = T.pack <$> options ^. #source
            , createdAt = releasedAt
            }
        , Nothing
        )
    (Just legacyFile, Just proposalFile) -> do
      legacyBytes <-
        (try (BS.readFile legacyFile) :: IO (Either IOException ByteString))
          >>= either (dieT . T.pack . show) pure
      (prior, currentRelease) <-
        either
          dieT
          pure
          ( legacyStandaloneReleaseImport
              service
              releaseTag
              (imageRefText (rollout ^. #qualifiedImage))
              legacyBytes
          )
      proposalBytes <-
        (try (BS.readFile proposalFile) :: IO (Either IOException ByteString))
          >>= either (dieT . T.pack . show) pure
      proposal <- either dieT pure (InventoryLifecycle.decodeAdoptionInput proposalBytes)
      unless
        (InventoryLifecycle.adoptionCandidateDirectory proposal == ".")
        (dieT "inline Service import requires candidate '.' in its adoption proposal")
      pure (prior, currentRelease, Just proposal)
    _ -> dieT "legacy release import options are incomplete"
  (compiledScope, native) <-
    either
      (dieT . T.pack . show)
      pure
      ( compileStandaloneServiceWithReleaseAndBuild
          buildSecrets
          owner
          service
          rollout
          cluster
          namespaceId
          imageId
          volumeRecovery
          tlsSecrets
          envSecrets
          brokerServices
          brokerTopics
          databaseBindings
          accessBinding
          priorReleases
          release
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
                  <> [("baseDomain", T.pack selected) | selected <- maybe [] pure (options ^. #baseDomain)]
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
  forM_
    adoption
    ( validateInlineReleaseAdoption
        scope
        (appConfigMapName (serviceNameText (service ^. #name)))
    )
  if options ^. #dryRun
    then BC.putStrLn (ResourceWire.encodeCanonicalScope scope)
    else case (adoption, options ^. #savePlan) of
      (Nothing, Nothing) ->
        Inventory.convergeInventoryCandidateWith
          (inventoryPlanRegistryWithNative active workspace native)
          (inventoryExecutionRegistry mctx)
          active
          candidate
      (Nothing, Just _) ->
        Inventory.planInventoryCandidateWith
          (inventoryPlanRegistryWithNative active workspace native)
          active
          candidate
          output
      (Just proposal, Just _) ->
        Inventory.planInventoryCandidateAdoptionWith
          (inventoryPlanRegistryWithNative active workspace native)
          active
          candidate
          proposal
          output
      (Just _, Nothing) -> dieT "legacy release adoption requires --save-plan"
