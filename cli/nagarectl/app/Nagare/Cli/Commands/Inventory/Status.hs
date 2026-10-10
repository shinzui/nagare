-- | Commands / Inventory / Status. Executable-private CLI boundary.
module Nagare.Cli.Commands.Inventory.Status
  ( runInventoryStatus
  )
where

import Control.Monad (forM, forM_)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Lazy.Char8 qualified as LBC
import Data.Generics.Labels ()
import Data.List (find)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Access.Reviewed qualified as ReviewedAccess
import Nagare.Cli.Inventory.Adapters
  ( acceptedDnsResources
  , acceptedTopicResources
  , hostScopeAccepted
  , inventoryArtifactAdapter
  , inventoryBrokerAdapter
  , inventoryCacheAdapter
  , inventoryCdnAdapter
  , inventoryHostAdapter
  , inventoryKubernetesAdapter
  , inventoryPulumiAdapter
  )
import Nagare.Cli.Inventory.CdnHistory
import Nagare.Cli.Inventory.Foundation (inventoryFoundationAdapter)
import Nagare.Cli.Inventory.PublicEvidence (publicDataFence)
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Process (currentTimestamp)
import Nagare.Cli.Runtime.Target (activeTarget)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.Adapters.Broker
  ( topicSpecsFromDeclarations
  )
import Nagare.Inventory.Adapters.Cache
  ( cacheSpecsFromDeclarations
  )
import Nagare.Inventory.Adapters.Cdn (dnsSpecsFromDeclarations)
import Nagare.Inventory.Adapters.Cloudflare
  ( cloudflareBindingsFromDeclarations
  )
import Nagare.Inventory.Adapters.Helm
  ( HelmAdapterOps (..)
  , helmStateHealth
  , mkHelmAdapter
  )
import Nagare.Inventory.Adapters.HelmRuntime (helmObservation)
import Nagare.Inventory.Adapters.KubernetesRuntime
  ( KubernetesRuntimeConfig (KubernetesRuntimeConfig)
  , observeKubernetesHealth
  )
import Nagare.Inventory.Artifact qualified as InventoryArtifact
import Nagare.Inventory.BackupRetention (retentionPolicyText, standardRetention)
import Nagare.Inventory.Cloud qualified as InventoryCloud
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Host qualified as InventoryHost
import Nagare.Inventory.ObservationNative qualified as InventoryObservation
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Inventory.Store qualified as InventoryStore
import Nagare.Platform.Paths
  ( renderPlatformPathError
  , resolvePlatformPaths
  )
import Nagare.Platform.Workspace
  ( PlatformWorkspace
  , findPlatformWorkspace
  , renderWorkspaceError
  )
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Reference qualified as ResourceReference
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (contextNameText, nagareStateDir)
import System.Directory (createDirectoryIfMissing, doesPathExist)
import System.FilePath ((</>))

runInventoryStatus :: Maybe String -> Maybe String -> Bool -> Maybe FilePath -> IO ()
runInventoryStatus mctx requested json gcOutput = do
  active <- activeTarget mctx
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
  project <- either dieT pure (Resource.mkName (active ^. #profile . #project))
  let targetBinding = Resource.ContextBinding context project
  unless
    (InventoryStore.headBinding (InventoryPlan.historyHead history) == targetBinding)
    (dieT "accepted inventory belongs to a different context or project")
  snapshot <-
    either
      (dieT . T.pack . show)
      pure
      ( ResourceInventory.mkScopeSnapshot
          targetBinding
          ( Map.map
              (\(revision, scope) -> (InventoryStore.revisionGeneration revision, scope))
              (InventoryPlan.historyAccepted history)
          )
          (InventoryPlan.historyReservations history)
      )
  inventory <- either (dieT . T.pack . show) pure (ResourceInventory.composeSnapshot snapshot)
  selected <- traverse (either dieT pure . Resource.mkResourceId . T.pack) requested
  let allManaged = [resource | ResourceInventory.Managed resource <- ResourceInventory.inventoryDeclarations inventory]
      byId = Map.fromList [(resource ^. #identity, resource) | resource <- allManaged]
      wanted resource = maybe True (== resource) selected
      retainedMembers = Map.filterWithKey (\resource _ -> wanted resource) (InventoryPlan.historyRetained history)
  forM_ selected $ \resource ->
    unless
      ( Map.member resource byId
          || Map.member resource retainedMembers
          || Map.member resource (InventoryStore.headCollected (InventoryPlan.historyHead history))
      )
      (dieT "resource is absent from accepted and historical inventory")
  let binding = ResourceInventory.inventoryBinding inventory
      declarations = filter (wanted . ResourceInventory.declarationId) (ResourceInventory.inventoryDeclarations inventory)
      scopes = Map.elems (ResourceInventory.inventoryScopes inventory)
      managed = filter (\resource -> wanted (resource ^. #identity)) allManaged
  native <- InventoryObservation.loadObservationNative store managed >>= either dieT pure
  retainedNative <-
    InventoryObservation.loadObservationNative store (map snd (Map.elems retainedMembers))
      >>= either dieT pure
  let kubernetesNative = InventoryObservation.observationKubernetes native
      helmNative = InventoryObservation.observationHelm native
      retainedKubernetesNative = InventoryObservation.observationKubernetes retainedNative
      retainedHelmNative = InventoryObservation.observationHelm retainedNative
      needsWorkspace =
        any
          ( \resource ->
              resource ^. #executor
                `elem` [ ResourceInventory.PulumiExecutor
                       , ResourceInventory.CloudFoundationExecutor
                       , ResourceInventory.ArtifactExecutor
                       , ResourceInventory.HostExecutor
                       , ResourceInventory.CacheExecutor
                       , ResourceInventory.CdnExecutor
                       ]
          )
          (managed <> map snd (Map.elems retainedMembers))
  workspace <-
    if not needsWorkspace
      then pure Nothing
      else do
        paths <- resolvePlatformPaths Nothing >>= either (dieT . renderPlatformPathError) pure
        stateRoot <- nagareStateDir
        Just
          <$> ( findPlatformWorkspace stateRoot (active ^. #contextName) paths
                  >>= either (dieT . renderWorkspaceError) pure
              )
  let withWorkspace :: (PlatformWorkspace -> IO a) -> IO a
      withWorkspace action = maybe (dieT "selected provider requires a platform workspace") action workspace
      scheduledBackups = InventoryStatus.signedScheduledBackups allManaged managed
      ids executor = [resource ^. #identity | resource <- managed, resource ^. #executor == executor]
      retainedIds executor =
        [ resource
        | (resource, (_, declaration)) <- Map.toAscList retainedMembers
        , declaration ^. #executor == executor
        ]
  registrations <- either dieT pure (InventoryCloud.registrationsFromDeclarations declarations)
  artifactSpecs <- either dieT pure (InventoryArtifact.artifactExecutionSpecsFromDeclarations declarations)
  cacheSpecs <- either dieT pure (cacheSpecsFromDeclarations declarations)
  topicSpecs <-
    either
      dieT
      pure
      ( topicSpecsFromDeclarations
          ( declarations
              <> [ResourceInventory.Managed resource | (_, resource) <- Map.elems retainedMembers]
          )
      )
  allDns <- either dieT pure (dnsSpecsFromDeclarations (ResourceInventory.inventoryDeclarations inventory))
  allCloudflare <- either dieT pure (cloudflareBindingsFromDeclarations (ResourceInventory.inventoryDeclarations inventory))
  let retainedCdn = Map.filterWithKey (\resource _ -> wanted resource) (retainedCdnResources history)
      dnsSpecs = Map.union (Map.filterWithKey (\resource _ -> wanted resource) allDns) (historicalDnsBindings retainedCdn)
      cloudflareSpecs = Map.union (Map.filterWithKey (\resource _ -> wanted resource) allCloudflare) (historicalCloudflareBindings retainedCdn)
  hostInputs <-
    if null (ids ResourceInventory.HostExecutor)
      then pure Nothing
      else either dieT pure (InventoryHost.hostExecutionInputsFromScopes scopes)
  observationStartedAt <- currentTimestamp
  pulumi <-
    if null registrations
      then pure (Inventory.executionBlockedAdapterFor ResourceInventory.PulumiExecutor)
      else withWorkspace (\root -> inventoryPulumiAdapter active root binding scopes registrations)
  artifact <-
    if Map.null artifactSpecs
      then pure (Inventory.executionBlockedAdapterFor ResourceInventory.ArtifactExecutor)
      else withWorkspace (\root -> inventoryArtifactAdapter active root artifactSpecs)
  host <-
    maybe
      (pure (Inventory.executionBlockedAdapterFor ResourceInventory.HostExecutor))
      (\inputs -> withWorkspace (\root -> inventoryHostAdapter active root (hostScopeAccepted history) scopes inputs))
      hostInputs
  (cache, cacheKey) <-
    if Map.null cacheSpecs
      then
        pure
          ( Inventory.executionBlockedAdapterFor ResourceInventory.CacheExecutor
          , \_ -> pure (Left "cache output resolver is not installed for observation")
          )
      else withWorkspace (\root -> inventoryCacheAdapter active root binding cacheSpecs)
  broker <-
    inventoryBrokerAdapter
      active
      binding
      topicSpecs
      ( Map.union
          (acceptedTopicResources history)
          ( Map.fromList
              [ (resource, declaration)
              | (resource, (_, declaration)) <- Map.toAscList retainedMembers
              , declaration ^. #executor == ResourceInventory.BrokerExecutor
              ]
          )
      )
  acceptedCdn <-
    if null (ids ResourceInventory.CdnExecutor) && Map.null retainedCdn
      then pure Map.empty
      else Map.union retainedCdn <$> either dieT pure (acceptedDnsResources history)
  cdn <-
    if Map.null dnsSpecs && Map.null cloudflareSpecs
      then pure (Inventory.executionBlockedAdapterFor ResourceInventory.CdnExecutor)
      else withWorkspace (\root -> inventoryCdnAdapter active root binding dnsSpecs cloudflareSpecs acceptedCdn)
  kubernetes <-
    inventoryKubernetesAdapter
      active
      binding
      cacheKey
      kubernetesNative
  let observeHelm specs =
        helmObservation
          (contextNameText (active ^. #contextName))
          (binding ^. #identity)
          (Map.map fst specs)
          (fmap (fmap (const ())) (guardKubernetesContext active))
      readOnlyHelm specs =
        mkHelmAdapter
          specs
          HelmAdapterOps
            { helmObserve = observeHelm specs
            , helmMutateConditional = \_ -> pure (InventoryAdapter.AdapterEffectAmbiguous "observation cannot mutate")
            }
      helm = readOnlyHelm helmNative
  retainedKubernetes <- inventoryKubernetesAdapter active binding cacheKey retainedKubernetesNative
  let retainedHelm = readOnlyHelm retainedHelmNative
  -- The facts, and the members whose rollout is stuck (EP-181).
  let inspectWithStuck adapter executor = do
        let requestedIds = ids executor
        if null requestedIds
          then pure ([], Map.empty)
          else InventoryStatus.statusFacts "adapter omitted this resource" requestedIds <$> InventoryAdapter.adapterObserve adapter requestedIds
      inspect adapter executor = fst <$> inspectWithStuck adapter executor
  (kubeFacts, kubeStuck) <- inspectWithStuck kubernetes ResourceInventory.KubernetesExecutor
  helmFacts <- inspect helm ResourceInventory.HelmExecutor
  pulumiFacts <- inspect pulumi ResourceInventory.PulumiExecutor
  artifactFacts <- inspect artifact ResourceInventory.ArtifactExecutor
  hostFacts <- inspect host ResourceInventory.HostExecutor
  cacheFacts <- inspect cache ResourceInventory.CacheExecutor
  brokerFacts <- inspect broker ResourceInventory.BrokerExecutor
  cdnFacts <- inspect cdn ResourceInventory.CdnExecutor
  -- Cloud foundation buckets and the Pulumi stack are observed read-only
  -- through the same guarded adapter that plans them (F44).
  foundation <-
    if null (ids ResourceInventory.CloudFoundationExecutor)
      then pure (Inventory.executionBlockedAdapterFor ResourceInventory.CloudFoundationExecutor)
      else
        withWorkspace
          ( \root ->
              inventoryFoundationAdapter
                active
                root
                binding
                (ResourceInventory.inventoryDeclarations inventory)
                (Set.fromList (ids ResourceInventory.CloudFoundationExecutor))
          )
  foundationFacts <- inspect foundation ResourceInventory.CloudFoundationExecutor
  access <-
    ReviewedAccess.accessAdapter
      active
      (fmap (fmap (const ())) (guardKubernetesContext active))
      (ResourceInventory.inventoryDeclarations inventory)
      history
  accessFacts <- inspect access ResourceInventory.AccessExecutor
  case InventoryStatus.missingStatusObservers
    [ InventoryAdapter.adapterExecutor adapter
    | adapter <- [kubernetes, helm, pulumi, foundation, artifact, host, cache, broker, cdn, access]
    ] of
    [] -> pure ()
    missing -> dieT ("inventory status has no observer for " <> T.intercalate ", " (map (T.pack . show) missing))
  let inspectRetained adapter executor = do
        let requestedIds = retainedIds executor
        if null requestedIds
          then pure []
          else fst . InventoryStatus.statusFacts "adapter omitted this retained resource" requestedIds <$> InventoryAdapter.adapterObserve adapter requestedIds
  retainedKubeFacts <- inspectRetained retainedKubernetes ResourceInventory.KubernetesExecutor
  retainedHelmFacts <- inspectRetained retainedHelm ResourceInventory.HelmExecutor
  retainedBrokerFacts <- inspectRetained broker ResourceInventory.BrokerExecutor
  retainedCdnFacts <- inspectRetained cdn ResourceInventory.CdnExecutor
  let helmObserved = Map.fromList helmFacts
      helmObservedPhysical = \case
        InventoryAdapter.ObservedPresent _ -> True
        InventoryAdapter.ObservedDrifted _ _ -> True
        InventoryAdapter.ObservedReplacementRequired _ _ -> True
        _ -> False
  helmHealthPairs <- forM (ids ResourceInventory.HelmExecutor) $ \resourceId -> do
    health <- case Map.lookup resourceId helmObserved of
      Just fact | helmObservedPhysical fact -> do
        state <- observeHelm helmNative resourceId
        pure (helmStateHealth resourceId fact state)
      _ -> pure Nothing
    pure (resourceId, health)
  let retainedHelmObserved = Map.fromList retainedHelmFacts
  retainedHelmHealthPairs <- forM (retainedIds ResourceInventory.HelmExecutor) $ \resourceId -> do
    health <- case Map.lookup resourceId retainedHelmObserved of
      Just fact | helmObservedPhysical fact -> do
        state <- observeHelm retainedHelmNative resourceId
        pure (helmStateHealth resourceId fact state)
      _ -> pure Nothing
    pure (resourceId, health)
  let healthConfig =
        KubernetesRuntimeConfig
          context
          (contextNameText (active ^. #contextName))
          (fmap (fmap (const ())) (guardKubernetesContext active))
      kubeObserved = Map.fromList kubeFacts
  healthPairs <- forM managed $ \resource -> do
    let resourceId = resource ^. #identity
        physical = case Map.lookup resourceId kubeObserved of
          Just (InventoryAdapter.ObservedPresent uid) -> Just uid
          Just (InventoryAdapter.ObservedDrifted uid _) -> Just uid
          Just (InventoryAdapter.ObservedReplacementRequired uid _) -> Just uid
          _ -> Nothing
    health <- case (resource ^. #executor, physical) of
      (ResourceInventory.KubernetesExecutor, Just uid) ->
        observeKubernetesHealth healthConfig (resource ^. #address) uid
      _ -> pure Nothing
    pure (resourceId, health)
  let kubernetesObservations =
        either
          (error . T.unpack)
          (\value -> value)
          (InventoryAdapter.observationSet retainedKubeFacts)
  retainedHealthPairs <- forM (InventoryStatus.retainedHealthTargets history kubernetesObservations) $ \(resourceId, address, physical) -> do
    health <- observeKubernetesHealth healthConfig address physical
    pure (resourceId, health)
  transactionStatus <-
    InventoryStatus.loadActiveTransactionStatus store (InventoryPlan.historyHead history)
      >>= either dieT pure
  incarnations <-
    InventoryStatus.statusIncarnations store (InventoryPlan.historyHead history)
      >>= either dieT pure
  finalHead <- InventoryStore.readHead store >>= either (dieT . T.pack . show) pure
  unless
    (finalHead == Just (InventoryPlan.historyHead history))
    (dieT "accepted inventory changed during status; retry against the new head")
  let allFacts = kubeFacts <> helmFacts <> pulumiFacts <> foundationFacts <> artifactFacts <> hostFacts <> cacheFacts <> brokerFacts <> cdnFacts <> accessFacts
      knownFacts = Map.fromList allFacts
      remaining =
        [ ( resource ^. #identity
          , InventoryAdapter.ObservationUnavailable
              "provider status adapter is not yet registered"
          )
        | resource <- managed
        , Map.notMember (resource ^. #identity) knownFacts
        ]
      observations =
        either
          (error . T.unpack)
          (\value -> value)
          (InventoryAdapter.withStuckRollouts kubeStuck <$> InventoryAdapter.observationSet (allFacts <> remaining))
      retainedObservations =
        either
          (error . T.unpack)
          (\value -> value)
          (InventoryAdapter.observationSet (retainedKubeFacts <> retainedHelmFacts <> retainedBrokerFacts <> retainedCdnFacts))
      healthById = Map.fromList (healthPairs <> helmHealthPairs)
      findings =
        [ finding
            { InventoryStatus.findingHealth = case Map.lookup (InventoryStatus.findingResource finding) healthById of
                Just (Just True) -> InventoryStatus.HealthReady
                Just (Just False) -> InventoryStatus.HealthNotReady
                _ -> InventoryStatus.findingHealth finding
            }
        | finding <- InventoryStatus.classifyDriftWith incarnations inventory observations
        , wanted (InventoryStatus.findingResource finding)
        ]
      retainedHealthById = Map.fromList (retainedHealthPairs <> retainedHelmHealthPairs)
      retainedFindings =
        [ finding
            { InventoryStatus.retainedHealth = case Map.lookup (InventoryStatus.retainedResource finding) retainedHealthById of
                Just (Just True) -> InventoryStatus.HealthReady
                Just (Just False) -> InventoryStatus.HealthNotReady
                _ -> InventoryStatus.retainedHealth finding
            }
        | finding <- InventoryStatus.retainedFindings history retainedObservations
        , wanted (InventoryStatus.retainedResource finding)
        ]
      collectionAssessments =
        filter
          (wanted . InventoryStatus.collectionResource)
          (InventoryStatus.assessCollections history inventory retainedObservations)
      collectedEntries = filter (wanted . fst) (Map.toAscList (InventoryStore.headCollected (InventoryPlan.historyHead history)))
      unavailable =
        Set.toAscList
          ( Set.fromList
              ( [ InventoryStatus.findingExecutor finding
                | finding <- findings
                , InventoryStatus.findingCategory finding == InventoryStatus.UnknownObservation
                ]
                  <> [ InventoryStatus.retainedExecutor finding
                     | finding <- retainedFindings
                     , InventoryStatus.retainedObservation finding `elem` ["unknown", "unavailable"]
                     ]
              )
          )
      missingScopes =
        Set.toAscList
          ( Set.fromList
              ( [ (InventoryStatus.findingOwner finding, InventoryStatus.findingExecutor finding)
                | finding <- findings
                , InventoryStatus.findingCategory finding == InventoryStatus.UnknownObservation
                ]
                  <> [ (InventoryStatus.retainedScope finding, InventoryStatus.retainedExecutor finding)
                     | finding <- retainedFindings
                     , InventoryStatus.retainedObservation finding `elem` ["unknown", "unavailable"]
                     ]
              )
          )
      providers =
        [ Aeson.object
            [ "executor" Aeson..= InventoryAdapter.adapterExecutor adapter
            , "identity" Aeson..= InventoryAdapter.adapterIdentity adapter
            , "version" Aeson..= InventoryAdapter.adapterVersion adapter
            ]
        | adapter <- [kubernetes, helm, pulumi, foundation, artifact, host, cache, broker]
        ]
      revisions values =
        [ Aeson.object ["scope" Aeson..= scope, "revision" Aeson..= revision]
        | (scope, revision) <- Map.toAscList values
        ]
  observedAt <- currentTimestamp
  case gcOutput of
    Nothing -> pure ()
    Just output -> do
      exists <- doesPathExist output
      when exists (dieT "collection plan output already exists")
      let report =
            Aeson.object
              [ "version" Aeson..= (1 :: Int)
              , "context" Aeson..= binding
              , "observationStartedAt" Aeson..= observationStartedAt
              , "observedAt" Aeson..= observedAt
              , "deletionAuthorized" Aeson..= False
              , "assessments" Aeson..= collectionAssessments
              ]
      createDirectoryIfMissing True output
      LBS.writeFile (output </> "collection-plan.json") (Aeson.encode report)
      TIO.putStrLn ("Wrote read-only collection assessment: " <> T.pack (output </> "collection-plan.json"))
  let baseFields =
        [ "context" Aeson..= ResourceInventory.inventoryBinding inventory
        , "observationStartedAt" Aeson..= observationStartedAt
        , "observedAt" Aeson..= observedAt
        , "accepted" Aeson..= revisions (fmap fst (InventoryPlan.historyAccepted history))
        , "converged" Aeson..= revisions (InventoryPlan.historyConverged history)
        , "activeTransaction" Aeson..= InventoryStore.headActiveTransaction (InventoryPlan.historyHead history)
        , "dataFence" Aeson..= fmap publicDataFence (InventoryStore.headDataFence (InventoryPlan.historyHead history))
        , "transactionStatus" Aeson..= transactionStatus
        , "missingProviders" Aeson..= unavailable
        , "missingProviderScopes"
            Aeson..= [ Aeson.object ["scope" Aeson..= scope, "executor" Aeson..= executor]
                     | (scope, executor) <- missingScopes
                     ]
        , "providers" Aeson..= providers
        , "scheduledRetention"
            Aeson..= [ Aeson.object
                         [ "schedule" Aeson..= resource
                         , "policy" Aeson..= retentionPolicyText standardRetention
                         , "prune" Aeson..= ("reviewed" :: Text)
                         ]
                     | resource <- scheduledBackups
                     ]
        , "retained" Aeson..= retainedFindings
        , "collectionAssessments" Aeson..= collectionAssessments
        , "collected"
            Aeson..= [ Aeson.object ["resource" Aeson..= resource, "tombstone" Aeson..= tombstone]
                     | (resource, tombstone) <- collectedEntries
                     ]
        ]
  case (gcOutput, requested) of
    (Just _, _) -> pure ()
    (Nothing, Nothing) -> do
      let report =
            Aeson.object
              ( baseFields
                  <> ["observationComplete" Aeson..= null unavailable, "findings" Aeson..= findings]
              )
      if json
        then LBC.putStrLn (Aeson.encode report)
        else
          TIO.putStrLn
            ( "Inventory status: "
                <> T.pack (show (length findings))
                <> " resources; retained: "
                <> T.pack (show (length retainedFindings))
                <> "; collected: "
                <> T.pack (show (length collectedEntries))
                <> "; data fence: "
                <> maybe
                  "none"
                  (T.pack . show . InventoryStore.fencePhase)
                  (InventoryStore.headDataFence (InventoryPlan.historyHead history))
                <> ( if null scheduledBackups
                       then ""
                       else
                         "; scheduled backup retention: " <> retentionPolicyText standardRetention <> " (reviewed prune)"
                   )
                <> "; unavailable providers: "
                <> T.pack (show unavailable)
            )
    (Nothing, Just raw) -> do
      resourceId <- either dieT pure (Resource.mkResourceId (T.pack raw))
      (explanation, summary) <- case Map.lookup resourceId byId of
        Just resource -> do
          finding <-
            maybe
              (dieT "resource finding is absent")
              pure
              (find ((== resourceId) . InventoryStatus.findingResource) findings)
          pure
            ( Aeson.object
                ( baseFields
                    <> [ "finding" Aeson..= finding
                       , "dependencies" Aeson..= (resource ^. #dependencies)
                       , "dependencyTrace" Aeson..= InventoryStatus.traceDependencies inventory resourceId
                       , "consumers" Aeson..= InventoryStatus.consumersOf history inventory resourceId
                       , "addressAliases" Aeson..= (resource ^. #aliases)
                       , "requiredConditions"
                           Aeson..= [reference | ResourceReference.ReadyAfter reference <- resource ^. #dependencies]
                       , "lifecycle" Aeson..= (resource ^. #lifecycle)
                       , "dataPolicy" Aeson..= (resource ^. #dataPolicy)
                       , "sensitivity" Aeson..= (resource ^. #sensitivity)
                       , "delegations" Aeson..= (resource ^. #delegations)
                       , "source" Aeson..= (resource ^. #source)
                       ]
                )
            , T.pack (show finding)
            )
        Nothing -> case Map.lookup resourceId retainedMembers of
          Just (_, resource) -> do
            let retainedFinding = find ((== resourceId) . InventoryStatus.retainedResource) retainedFindings
            finding <- maybe (dieT "retained resource finding is absent") pure retainedFinding
            pure
              ( Aeson.object
                  ( baseFields
                      <> [ "finding" Aeson..= finding
                         , "dependencies" Aeson..= (resource ^. #dependencies)
                         , "dependencyTrace" Aeson..= InventoryStatus.traceRetainedDependencies history inventory resourceId
                         , "consumers" Aeson..= InventoryStatus.consumersOf history inventory resourceId
                         , "addressAliases" Aeson..= (resource ^. #aliases)
                         , "requiredConditions"
                             Aeson..= [reference | ResourceReference.ReadyAfter reference <- resource ^. #dependencies]
                         , "lifecycle" Aeson..= (resource ^. #lifecycle)
                         , "dataPolicy" Aeson..= (resource ^. #dataPolicy)
                         , "sensitivity" Aeson..= (resource ^. #sensitivity)
                         , "delegations" Aeson..= (resource ^. #delegations)
                         , "source" Aeson..= (resource ^. #source)
                         , "collectionAssessment"
                             Aeson..= find
                               ((== resourceId) . InventoryStatus.collectionResource)
                               collectionAssessments
                         , "recoveryReason" Aeson..= ("retained incarnation requires explicit collection or recovery review" :: Text)
                         ]
                  )
              , "Retained resource " <> Resource.resourceIdText resourceId
              )
          Nothing -> case Map.lookup resourceId (InventoryStore.headCollected (InventoryPlan.historyHead history)) of
            Just tombstone ->
              pure
                ( Aeson.object
                    ( baseFields
                        <> [ "finding"
                               Aeson..= Aeson.object
                                 [ "resource" Aeson..= resourceId
                                 , "category" Aeson..= ("collected" :: Text)
                                 , "tombstone" Aeson..= tombstone
                                 ]
                           ]
                    )
                , "Collected resource " <> Resource.resourceIdText resourceId
                )
            Nothing -> dieT "resource is absent from accepted and historical inventory"
      if json
        then LBC.putStrLn (Aeson.encode explanation)
        else TIO.putStrLn summary
