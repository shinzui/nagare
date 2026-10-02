-- | Commands / Application. Executable-private CLI boundary.
module Nagare.Cli.Commands.Application
  ( runAppDelete
  , runAppDeploy
  , runAppGet
  , runAppList
  , runAppLogs
  , runAppRestart
  , runAppStop
  , runDeploymentsList
  , runDeploymentsLogs
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Maybe (catMaybes)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Nagare.App
  ( AppSummary (..)
  , LogTarget (..)
  , formatAppList
  , getAppSummary
  , listAppSummaries
  , streamServiceLogs
  )
import Nagare.App.Deploy
  ( AppDeployParams (..)
  , resolveAppRolloutWithBrokerEnv
  )
import Nagare.App.Deployments
  ( appConfigMapName
  , formatDeploymentsTable
  , readDeployments
  , resolveRevisionForTag
  )
import Nagare.Cdn.Provision (GcpStackRefs (globalIp))
import Nagare.Cli.Application.Cdn (reviewedCdnBinding)
import Nagare.Cli.Application.Config (appNamespace)
import Nagare.Cli.Application.Inputs
  ( parseHookEffects
  , validateInlineReleaseAdoption
  )
import Nagare.Cli.Inventory.Execution
  ( inventoryExecutionRegistry
  )
import Nagare.Cli.Inventory.Planning
  ( inventoryPlanRegistry
  , inventoryPlanRegistryWithNative
  )
import Nagare.Cli.Options
  ( AppDeleteOpts
  , AppDeployOpts
  , AppGetOpts
  , AppListOpts
  , AppLogsOpts
  , AppNameOpts
  , DepListOpts
  , DepLogsOpts
  )
import Nagare.Cli.Runtime.Config (provisionGhcEnv)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target
  ( activeProfile
  , activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Deploy (serviceUrl)
import Nagare.Dsl.Build (resolveImageTag)
import Nagare.Dsl.Load qualified as Load
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types
  ( domainText
  , imageRefText
  , namespaceText
  , quantityText
  , serviceNameText
  )
import Nagare.Image (computeTag)
import Nagare.Inventory.Application
  ( ApplicationScopeInput
      ( ApplicationScopeInput
      , scopeAccessBinding
      , scopeApplication
      , scopeBackupBackend
      , scopeBrokerServices
      , scopeBrokerTopics
      , scopeBuildSecrets
      , scopeCdnBinding
      , scopeCluster
      , scopeDatabaseRecovery
      , scopeEnvSecrets
      , scopeHookEffects
      , scopeImage
      , scopeInputOverrides
      , scopeNamespace
      , scopeNamespaceContributionOwner
      , scopeRelease
      , scopeRollout
      , scopeServiceVolumeRecovery
      , scopeSource
      , scopeTlsSecrets
      , scopeWorkerVolumeRecovery
      )
  , CloudflareCdnBinding (cloudflareCdnOriginIp, cloudflareCdnZone)
  , GoogleCdnBinding (googleCdnBackend, googleCdnRefs)
  , ReviewedCdnBinding (CloudflareCdnBindingFor, GoogleCdnBindingFor)
  , ServiceAction (..)
  , acceptedAccessBinding
  , acceptedApplicationImage
  , acceptedApplicationReleaseLog
  , acceptedBrokerBindings
  , acceptedImageBuildSecrets
  , acceptedSecretBindings
  , applicationRetirementScope
  , applicationVolumeRecoveryBindings
  , compileApplicationDeployment
  , compileServiceActionScope
  , databaseRecoveryBindings
  , legacyApplicationReleaseImport
  , reviewedTaskImages
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
import Nagare.Target (TargetProfile, storeBackendFor)
import System.Directory (doesFileExist)

-- | @app list@: print a table of apps in a namespace (Nagare-managed unless
-- @--all@). An empty managed list prints a hint to try @--all@.
-- | Convert the executable's option record into the library deploy params
-- (MasterPlan 14, EP-2), so the library never depends on the option type.
runAppDeployPlan :: Maybe String -> AppDeployParams -> AppDeployOpts -> FilePath -> IO ()
runAppDeployPlan mctx params appOptions output = do
  case (appOptions ^. #legacyReleaseImport, appOptions ^. #releaseAdoptionInput) of
    (Nothing, Nothing) -> pure ()
    (Just _, Just _) -> pure ()
    _ -> dieT "legacy release import requires both --legacy-release-import and --release-adoption-input"
  when
    (appOptions ^. #dryRun && isJust (appOptions ^. #savePlan))
    (dieT "--save-plan cannot be combined with --dry-run")
  when
    ( isNothing (appOptions ^. #savePlan)
        && ( isJust (appOptions ^. #legacyReleaseImport)
               || isJust (appOptions ^. #releaseAdoptionInput)
           )
    )
    (dieT "legacy release adoption requires --save-plan and a separate reviewed apply")
  when
    (appOptions ^. #json && not (appOptions ^. #dryRun))
    (dieT "--json requires --dry-run for reviewed application output")
  when
    (isJust (appOptions ^. #contextOverride) || isJust (appOptions ^. #dockerfileOverride))
    (dieT "reviewed app deploy requires a prepublished image; build overrides are unsupported")
  when
    (isNothing (appOptions ^. #tag))
    (dieT "reviewed app deploy requires an explicit --tag")
  imageText <-
    maybe
      (dieT "reviewed app deploy requires --image-resource")
      (pure . T.pack)
      (appOptions ^. #imageResource)
  imageId <- either dieT pure (Resource.mkResourceId imageText)
  app <-
    Load.loadApplication (params ^. #configPath)
      >>= either (dieT . Load.renderLoadError) pure
  hookEffects <-
    either
      dieT
      pure
      ( parseHookEffects
          app
          (appOptions ^. #hookAffects)
          (appOptions ^. #hookNoDataEffects)
      )
  let builds =
        maybe [] (pure . (^. #build)) (app ^. #service)
          <> map (^. #build) (app ^. #workers)
  databaseRecovery <-
    either
      dieT
      pure
      (databaseRecoveryBindings app (map T.pack (appOptions ^. #databaseRecovery)))
  (serviceVolumeRecovery, workerVolumeRecovery) <-
    either
      dieT
      pure
      ( applicationVolumeRecoveryBindings
          app
          (map T.pack (appOptions ^. #serviceVolumeRecovery))
          (map T.pack (appOptions ^. #workerVolumeRecovery))
      )
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  cdnBinding <-
    reviewedCdnBinding
      active
      workspace
      snapshot
      (app ^. #service >>= (^. #cdn))
      (appOptions ^. #cdnBackendResource)
  let appNamespaceName = namespaceText (app ^. #namespace)
  (cluster, namespaceId, namespaceOwner) <-
    if appOptions ^. #requestNamespace
      then do
        (foundationCluster, _) <-
          either
            dieT
            pure
            (acceptedFoundationNamespace snapshot "personal")
        foundation <- either dieT pure (Resource.mkScopeId Resource.Platform "foundation")
        namespaceName <- either dieT pure (Resource.mkName appNamespaceName)
        namespaceKey <- either dieT pure (Resource.mkLogicalKey appNamespaceName)
        case acceptedFoundationNamespace snapshot appNamespaceName of
          Right _ -> dieT "requested namespace is already accepted by the platform foundation"
          Left _ -> pure ()
        let request =
              ResourceInventory.RegisterNamespace
                foundation
                foundationCluster
                namespaceName
                namespaceKey
        pure (foundationCluster, ResourceInventory.contributionResourceId request, Just foundation)
      else do
        (foundationCluster, acceptedNamespace) <-
          either
            dieT
            pure
            (acceptedFoundationNamespace snapshot appNamespaceName)
        pure (foundationCluster, acceptedNamespace, Nothing)
  let accessPolicy = (app ^. #access) <|> (app ^. #service >>= (^. #access))
  accessBinding <-
    traverse
      ( \_ ->
          either
            dieT
            pure
            (acceptedAccessBinding snapshot cluster)
      )
      accessPolicy
  (appBrokerServices, appBrokerTopics, brokerEnv) <-
    either
      dieT
      pure
      (acceptedBrokerBindings snapshot cluster appNamespaceName (app ^. #brokers))
  workloadBrokers <-
    either
      dieT
      pure
      ( traverse
          (acceptedBrokerBindings snapshot cluster appNamespaceName)
          ( maybe [] (pure . (^. #brokers)) (app ^. #service)
              <> map (^. #brokers) (app ^. #workers)
          )
      )
  let brokerServices = Map.unions (appBrokerServices : [services | (services, _, _) <- workloadBrokers])
      brokerTopics =
        Map.unionsWith
          Map.union
          (appBrokerTopics : [topics | (_, topics, _) <- workloadBrokers])
  rollout <- resolveAppRolloutWithBrokerEnv params app brokerEnv
  unless
    ( all
        ( \build ->
            resolveImageTag build (rollout ^. #imageTag)
              == rollout ^. #effectiveTag
        )
        builds
    )
    (dieT "application workloads resolve to different prepublished image tags")
  either dieT pure (acceptedApplicationImage snapshot imageId (rollout ^. #taggedAppImage))
  either
    dieT
    pure
    ( reviewedTaskImages
        (app ^. #tasks)
        (rollout ^. #taggedAppImage)
        (rollout ^. #effectiveTag)
    )
  buildSecrets <-
    either
      dieT
      pure
      ( acceptedImageBuildSecrets
          snapshot
          imageId
          cluster
          (serviceNameText (app ^. #name))
          appNamespaceName
      )
  tlsIds <-
    traverse
      (either dieT pure . Resource.mkResourceId . T.pack)
      (appOptions ^. #tlsSecretResources)
  envIds <-
    traverse
      (either dieT pure . Resource.mkResourceId . T.pack)
      (appOptions ^. #envSecretResources)
  tlsSecrets <- either dieT pure (acceptedSecretBindings snapshot tlsIds)
  envSecrets <- either dieT pure (acceptedSecretBindings snapshot envIds)
  backend <-
    either
      dieT
      pure
      ( storeBackendFor
          (active ^. #profile)
          (active ^. #profile . #backupBucket)
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
          (maybe (T.pack (params ^. #configPath)) T.pack (appOptions ^. #source))
          (serviceNameText (app ^. #name))
      releaseTag = rollout ^. #effectiveTag
      releaseSubject =
        maybe
          (serviceNameText (app ^. #name))
          (serviceNameText . (^. #name))
          (app ^. #service)
  (priorReleases, release, adoption) <- case (appOptions ^. #legacyReleaseImport, appOptions ^. #releaseAdoptionInput) of
    (Nothing, Nothing) -> do
      prior <-
        either
          dieT
          pure
          (acceptedApplicationReleaseLog snapshot acceptedNative app cluster)
      releasedAt <- getCurrentTime
      pure
        ( prior
        , StaticRelease
            { releaseId = releaseTag
            , siteName = releaseSubject
            , namespace = appNamespaceName
            , image = imageRefText (rollout ^. #qualifiedImage)
            , imageTag = releaseTag
            , url =
                maybe
                  ""
                  (\service -> serviceUrl service (rollout ^. #baseDomain))
                  (app ^. #service)
            , source = T.pack <$> appOptions ^. #source
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
          ( legacyApplicationReleaseImport
              app
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
        (dieT "inline application import requires candidate '.' in its adoption proposal")
      pure (prior, currentRelease, Just proposal)
    _ -> dieT "legacy release import options are incomplete"
  let input =
        ApplicationScopeInput
          { scopeApplication = app
          , scopeRollout = rollout
          , scopeCluster = cluster
          , scopeNamespace = namespaceId
          , scopeNamespaceContributionOwner = namespaceOwner
          , scopeImage = imageId
          , scopeBrokerServices = brokerServices
          , scopeBrokerTopics = brokerTopics
          , scopeAccessBinding = accessBinding
          , scopeCdnBinding = cdnBinding
          , scopeDatabaseRecovery = databaseRecovery
          , scopeServiceVolumeRecovery = serviceVolumeRecovery
          , scopeTlsSecrets = tlsSecrets
          , scopeEnvSecrets = envSecrets
          , scopeBuildSecrets = buildSecrets
          , scopeWorkerVolumeRecovery = workerVolumeRecovery
          , scopeBackupBackend = backend
          , scopeRelease = (priorReleases, release)
          , scopeHookEffects = hookEffects
          , scopeInputOverrides =
              Map.fromList
                ( [("tag", T.pack selected) | selected <- maybe [] pure (appOptions ^. #tag)]
                    <> [("baseDomain", T.pack selected) | selected <- maybe [] pure (appOptions ^. #baseDomain)]
                    <> [("imageResource", T.pack selected) | selected <- maybe [] pure (appOptions ^. #imageResource)]
                    <> [ ("cdnBackendResource", Resource.resourceIdText (ResourceInventory.declarationId (googleCdnBackend selected)))
                       | GoogleCdnBindingFor selected <- maybe [] pure cdnBinding
                       ]
                    <> [ ("cdnTarget", globalIp (googleCdnRefs selected))
                       | GoogleCdnBindingFor selected <- maybe [] pure cdnBinding
                       ]
                    <> [ ("cdnZone", Resource.nameText (cloudflareCdnZone selected))
                       | CloudflareCdnBindingFor selected <- maybe [] pure cdnBinding
                       ]
                    <> [ ("cdnOriginIp", cloudflareCdnOriginIp selected)
                       | CloudflareCdnBindingFor selected <- maybe [] pure cdnBinding
                       ]
                    <> [("requestNamespace", "true") | appOptions ^. #requestNamespace]
                    <> [ ("hook/" <> name, T.intercalate "," (map Resource.resourceIdText affected))
                       | (name, affected) <- Map.toList hookEffects
                       ]
                )
          , scopeSource = source
          }
  (scopes, native) <-
    either
      (dieT . T.pack . show)
      pure
      (compileApplicationDeployment input)
  (scope, hookScopes) <- case scopes of
    appScope : hooks -> pure (appScope, hooks)
    [] -> dieT "reviewed application compiler produced no scope"
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      ( ResourceInventory.composeInventory
          snapshot
          ( ResourceInventory.ReplaceScope scope
              NE.:| map ResourceInventory.ReplaceScope hookScopes
          )
      )
  forM_ adoption (validateInlineReleaseAdoption scope (appConfigMapName releaseSubject))
  if appOptions ^. #dryRun
    then
      if appOptions ^. #json
        then
          if null hookScopes
            then BC.putStrLn (ResourceWire.encodeCanonicalScope scope)
            else
              either
                dieT
                BC.putStrLn
                ( ResourceWire.canonicalValue
                    ( Aeson.object
                        [ "application" Aeson..= ResourceWire.scopeValue scope
                        , "hooks" Aeson..= map ResourceWire.scopeValue hookScopes
                        ]
                    )
                )
        else do
          forM_ scopes $ \compiled -> do
            TIO.putStrLn
              ( "Application review scope "
                  <> T.pack (show (ResourceInventory.scopeId compiled))
              )
            forM_ (ResourceInventory.scopeBundles compiled) $ \bundle -> do
              forM_ (ResourceInventory.declarations bundle) $ \declaration ->
                let address = case declaration of
                      ResourceInventory.Managed member -> member ^. #address
                      ResourceInventory.External _ location _ _ -> location
                      ResourceInventory.ObservedChild _ _ location _ _ -> location
                 in TIO.putStrLn
                      ( "  "
                          <> Resource.resourceIdText
                            (ResourceInventory.declarationId declaration)
                          <> "  "
                          <> T.pack (show address)
                      )
              forM_ (ResourceInventory.operations bundle) $ \operation ->
                TIO.putStrLn
                  ( "  operation "
                      <> Resource.resourceIdText (operation ^. #identity)
                  )
    else case (adoption, appOptions ^. #savePlan) of
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

toAppDeployParams :: TargetProfile -> AppDeployOpts -> AppDeployParams
toAppDeployParams tp o =
  AppDeployParams
    { configPath = o ^. #file
    , tag = T.pack <$> o ^. #tag
    , baseDomain = T.pack <$> o ^. #baseDomain
    , contextOverride = o ^. #contextOverride
    , dockerfileOverride = o ^. #dockerfileOverride
    , dryRun = o ^. #dryRun
    , json = o ^. #json
    , source = T.pack <$> o ^. #source
    , targetProfile = tp
    }

runAppList :: AppListOpts -> IO ()
runAppList o = do
  let ns = appNamespace (o ^. #namespace)
  esummaries <- listAppSummaries ns (o ^. #allApps)
  case esummaries of
    Left err -> dieT err
    Right [] ->
      if o ^. #allApps
        then TIO.putStrLn "(no Knative Services in this namespace)"
        else TIO.putStrLn "(no Nagare-managed apps; pass --all to list every Knative Service)"
    Right summaries -> TIO.putStr (formatAppList summaries)

-- | @app get NAME@: print one app's live state, enriched with the config's
-- declared domains/health check/limits when a readable config is present.
runAppGet :: AppGetOpts -> IO ()
runAppGet o = do
  let ns = appNamespace (o ^. #namespace)
      name = T.pack (o ^. #nameArg)
  esummary <- getAppSummary ns name
  case esummary of
    Left err -> dieT err
    Right s -> do
      printAppSummary s
      enrichFromConfig (o ^. #file) (o ^. #ghcEnv)

-- | Print the aligned @app get@ field block.
printAppSummary :: AppSummary -> IO ()
printAppSummary s = do
  TIO.putStrLn ("Name:     " <> s ^. #name)
  TIO.putStrLn ("Ready:    " <> maybe "?" boolText (s ^. #ready))
  TIO.putStrLn ("URL:      " <> fromMaybe "-" (s ^. #url))
  TIO.putStrLn ("Revision: " <> fromMaybe "-" (s ^. #latestRevision))
  TIO.putStrLn ("Image:    " <> fromMaybe "-" (s ^. #image))
  where
    boolText True = "True"
    boolText False = "False"

-- | When @file@ exists and loads as a 'Deployment', print its configured
-- domains, health check, and resource limits (EP-29's richer model). Any
-- absence or load failure is silently skipped — @app get@ works without a config.
enrichFromConfig :: FilePath -> Maybe FilePath -> IO ()
enrichFromConfig file ghc = do
  exists <- doesFileExist file
  when exists $ do
    provisionGhcEnv ghc
    edep <- Load.loadDeployment file
    case edep of
      Left _ -> pure ()
      Right dep -> do
        let doms = dep ^. #domains
        unless (null doms) $
          TIO.putStrLn ("Domains:  " <> T.intercalate ", " (map domainLabel doms))
        forM_ (dep ^. #healthCheck) $ \hc ->
          TIO.putStrLn ("Health:   " <> (hc ^. #path) <> " (" <> T.pack (show (hc ^. #scheme)) <> ")")
        forM_ (dep ^. #resources) $ \res ->
          let lims =
                catMaybes
                  [ ("cpu " <>) . quantityText <$> (res ^. #cpuLimit)
                  , ("memory " <>) . quantityText <$> (res ^. #memoryLimit)
                  ]
           in unless (null lims) $ TIO.putStrLn ("Limits:   " <> T.intercalate ", " lims)
  where
    domainLabel d =
      domainText (d ^. #domain) <> if d ^. #canonical then " (canonical)" else ""

-- | @app logs NAME [--follow] [--tail N]@: stream the app's user-container logs.
runAppLogs :: AppLogsOpts -> IO ()
runAppLogs o = do
  let ns = appNamespace (o ^. #namespace)
      name = T.pack (o ^. #nameArg)
      following = o ^. #follow
      target =
        LogTarget
          { namespace = ns
          , service = name
          , revision = Nothing
          , follow = following
          , tail = if following then Nothing else Just (fromMaybe 200 (o ^. #tailN))
          }
  streamServiceLogs target

-- | @app restart NAME@: review a fresh revision, clearing a stopped override.
runAppRestart :: Maybe String -> AppNameOpts -> IO ()
runAppRestart mctx o = do
  let ns = appNamespace (o ^. #namespace)
      name = T.pack (o ^. #nameArg)
  stamp <- computeTag
  runReviewedServiceAction mctx name ns (RestartService stamp)
  TIO.putStrLn ("Restarted: " <> name)

-- | @app stop NAME@: take the app offline recoverably.
runAppStop :: Maybe String -> AppNameOpts -> IO ()
runAppStop mctx o = do
  let ns = appNamespace (o ^. #namespace)
      name = T.pack (o ^. #nameArg)
  runReviewedServiceAction mctx name ns StopService
  TIO.putStrLn
    ( "Stopped "
        <> name
        <> " (run an explicit reviewed deploy or 'nagarectl app restart "
        <> name
        <> "' to restore public serving)"
    )

runReviewedServiceAction :: Maybe String -> Text -> Text -> ServiceAction -> IO ()
runReviewedServiceAction mctx name namespaceName serviceAction = do
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  let selected =
        [ scope
        | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
        , bundle <- ResourceInventory.scopeBundles scope
        , ResourceInventory.Managed resource <- ResourceInventory.declarations bundle
        , case resource ^. #address of
            Resource.Kubernetes _ "serving.knative.dev" kind (Just ns) nativeName ->
              Resource.nameText kind == "service"
                && Resource.nameText ns == namespaceName
                && Resource.nameText nativeName == name
            _ -> False
        ]
  scope <- case selected of
    [single] -> pure single
    _ -> dieT "reviewed service action requires one accepted Service scope"
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
  (revised, native) <-
    either
      (dieT . T.pack . show)
      pure
      (compileServiceActionScope name namespaceName serviceAction scope acceptedNative)
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      ( ResourceInventory.composeInventory
          snapshot
          (ResourceInventory.ReplaceScope revised NE.:| [])
      )
  Inventory.convergeInventoryCandidateWith
    (inventoryPlanRegistryWithNative active workspace native)
    (inventoryExecutionRegistry mctx)
    active
    candidate

-- | @app delete NAME@: save retirement of the accepted application scope.
runAppDelete :: Maybe String -> AppDeleteOpts -> IO ()
runAppDelete mctx o = do
  output <-
    maybe
      (dieT "app delete requires --save-plan for reviewed retirement")
      pure
      (o ^. #savePlan)
  let ns = appNamespace (o ^. #namespace)
      name = T.pack (o ^. #nameArg)
  active <- activeTarget mctx
  snapshot <- Inventory.loadTargetSnapshot active
  owner <-
    either
      dieT
      pure
      ( applicationRetirementScope
          name
          ns
          (T.pack <$> o ^. #scopeKey)
          snapshot
      )
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  Inventory.planInventoryRetirementWith
    (inventoryPlanRegistry active workspace)
    active
    owner
    output

-- ---------------------------------------------------------------------------
-- deployments handlers (EP-31)

-- | @deployments list NAME@: print the app's deployment history newest-first,
-- the live deployment starred.
runDeploymentsList :: DepListOpts -> IO ()
runDeploymentsList o = do
  let ns = appNamespace (o ^. #namespace)
      name = T.pack (o ^. #nameArg)
  elog <- readDeployments name ns
  case elog of
    Left err -> dieT err
    Right logv -> TIO.putStr (formatDeploymentsTable logv)

-- | @deployments logs NAME [DEPLOYMENT_ID]@: stream the live revision's logs, or
-- (with an id) the revision that deployment produced — mapped via its image tag.
-- A non-existent revision for an old id is a clear error.
runDeploymentsLogs :: DepLogsOpts -> IO ()
runDeploymentsLogs o = do
  let ns = appNamespace (o ^. #namespace)
      name = T.pack (o ^. #nameArg)
      following = o ^. #follow
      tailLines = if following then Nothing else Just (fromMaybe 200 (o ^. #tailN))
      mkTarget rev =
        LogTarget
          { namespace = ns
          , service = name
          , revision = rev
          , follow = following
          , tail = tailLines
          }
  case o ^. #depId of
    Nothing -> streamServiceLogs (mkTarget Nothing)
    Just idStr -> do
      let did = T.pack idStr
      mrev <- resolveRevisionForTag ns name did
      case mrev of
        Just rev -> streamServiceLogs (mkTarget (Just rev))
        Nothing ->
          dieT
            ( "no live revision for deployment "
                <> did
                <> " (its pods may have been garbage-collected; try 'nagarectl deployments logs "
                <> name
                <> "' for the live deployment)"
            )

runAppDeploy :: Maybe String -> AppDeployOpts -> IO ()
runAppDeploy mctx options = do
  provisionGhcEnv (options ^. #ghcEnv)
  profile <- activeProfile mctx
  runAppDeployPlan
    mctx
    (toAppDeployParams profile options)
    options
    (fromMaybe "" (options ^. #savePlan))
