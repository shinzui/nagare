-- | Inventory / Execution. Executable-private CLI boundary.
module Nagare.Cli.Inventory.Execution
  ( inventoryExecutionRegistry
  )
where

import Control.Exception (try)
import Control.Monad (forM, forM_)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Maybe (catMaybes)
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Cli.Inventory.Adapters
  ( acceptedTopicResources
  , inventoryArtifactAdapter
  , inventoryBrokerAdapter
  , inventoryCacheAdapter
  , inventoryCdnAdapter
  , inventoryControllerCollectionAdapter
  , inventoryHelmAdapter
  , inventoryHostAdapter
  , inventoryKubernetesAdapter
  , inventoryPulumiAdapter
  , reviewBaseDnsResources
  )
import Nagare.Cli.Inventory.Foundation
  ( inventoryFoundationAdapter
  )
import Nagare.Cli.Inventory.PruneEvidence
  ( loadReviewedPruneSourceNative
  , verifyReviewedScheduledPruneProvider
  , verifyReviewedScheduledPruneRecovery
  )
import Nagare.Cli.Inventory.SourceEvidence
  ( loadReviewedBackupSourceNative
  , loadReviewedLiveRestoreSourceNative
  , loadReviewedMaintenanceSourceNative
  , loadReviewedScheduledIngestSourceNative
  , loadReviewedVolumeSourceNative
  )
import Nagare.Cli.Platform.InfrastructureReview
  ( prepareInfraMutationWithPulumi
  )
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target
  ( activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Cluster.Kubeconfig (kubeconfigPath)
import Nagare.Dsl.Prelude
import Nagare.Inventory.AccessRuntime (accessReviewAdapter)
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
import Nagare.Inventory.Adapters.Host
  ( HostActivationPlan
      ( hostPlanAgeKeyDigest
      , hostPlanAttribute
      , hostPlanConfigurationDigest
      , hostPlanContext
      , hostPlanDestination
      , hostPlanLockDigest
      )
  , HostAdapterOps (hostInspectActivation)
  )
import Nagare.Inventory.Adapters.HostRuntime
  ( HostRuntimeConfig
      ( HostRuntimeConfig
      , runtimeHostAccepted
      , runtimeHostAgeKeyDigest
      , runtimeHostAttribute
      , runtimeHostConfigurationDigest
      , runtimeHostContext
      , runtimeHostDestination
      , runtimeHostEnvironment
      , runtimeHostExecutable
      , runtimeHostInstanceName
      , runtimeHostLockDigest
      , runtimeHostProject
      , runtimeHostZone
      )
  , mkHostRuntimeOps
  )
import Nagare.Inventory.Adapters.KubernetesRuntime
  ( KubernetesRuntimeConfig (KubernetesRuntimeConfig)
  )
import Nagare.Inventory.Artifact qualified as InventoryArtifact
import Nagare.Inventory.Backup (manualBackupSourceProof)
import Nagare.Inventory.Bootstrap
  ( bootstrapScopeVectorDigest
  , verifyBootstrapStampPayload
  )
import Nagare.Inventory.BootstrapRegistryRecovery
  ( mkBootstrapRegistryRecovery
  )
import Nagare.Inventory.BootstrapRegistryTransport
  ( runRegistryUnitTransport
  )
import Nagare.Inventory.Cloud qualified as InventoryCloud
import Nagare.Inventory.Collection.Adapter (controllerCollectionIdentity)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.HelmReview (helmSpecsFromReview)
import Nagare.Inventory.Host qualified as InventoryHost
import Nagare.Inventory.KubernetesReview
  ( kubernetesSpecsFromReview
  )
import Nagare.Inventory.LiveRestoreAdapter (liveRestoreRuntime)
import Nagare.Inventory.LiveRestoreFence
  ( registerLiveRestoreFence
  , selectedLiveRestoreProofs
  )
import Nagare.Inventory.MaintenanceAdapter (maintenanceAdapter)
import Nagare.Inventory.MaintenanceFence
  ( registerMaintenanceFence
  , selectedMaintenanceProofs
  )
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Prune (manualPruneSourceProof)
import Nagare.Inventory.Restore (manualRestoreTargetProof)
import Nagare.Inventory.ScheduledIngest
  ( scheduledIngestSourceProof
  )
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Inventory.Store qualified as InventoryStore
import Nagare.Platform.Status (identityFromPayload)
import Nagare.Platform.Workspace
  ( PlatformWorkspace
  , readPayloadManifest
  , renderWorkspaceError
  )
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire qualified as ResourceWire
import Nagare.Target
  ( ActiveTarget
  , Mode (Cloud, Local)
  , contextNameText
  )
import System.Directory (doesFileExist)
import System.Environment (setEnv)
import System.Exit (ExitCode)
import System.FilePath ((</>))

inventoryExecutionRegistry :: Maybe String -> InventoryStore.InventoryStore -> InventoryPlan.ReviewBundle -> IO InventoryAdapter.AdapterRegistry
inventoryExecutionRegistry mctx store bundle
  | not (null operations)
  , all ((== ResourceInventory.AccessExecutor) . InventoryAdapter.plannedExecutor) operations = do
      active <- activeTarget mctx
      selected <- kubeconfigPath (active ^. #contextName)
      exists <- doesFileExist selected
      unless exists (dieT "reviewed access requires the selected context kubeconfig")
      setEnv "KUBECONFIG" selected
      adapter <-
        accessReviewAdapter
          store
          (InventoryPlan.reviewContextBinding (InventoryPlan.reviewBundleDocument bundle))
          (contextNameText (active ^. #contextName))
          (fmap (fmap (const ())) (guardKubernetesContext active))
          bundle
          >>= either dieT pure
      either dieT pure (InventoryAdapter.mkAdapterRegistry [adapter])
  where
    operations =
      map
        InventoryPlan.reviewPlannedOperation
        (InventoryPlan.reviewOperations (InventoryPlan.reviewBundleDocument bundle))
inventoryExecutionRegistry mctx store bundle = do
  scopes <- traverse (either (dieT . T.pack . show) pure . ResourceWire.decodeScope) (Map.elems (InventoryPlan.reviewBundleScopes bundle))
  let document = InventoryPlan.reviewBundleDocument bundle
      operations =
        map
          InventoryPlan.reviewPlannedOperation
          (InventoryPlan.reviewOperations document)
      selected executor =
        Set.fromList
          [ resource
          | operation <- operations
          , InventoryAdapter.plannedExecutor operation == executor
          , resource <- NE.toList (InventoryAdapter.plannedResources operation)
          ]
      declarations = [declaration | scopeDeclaration <- scopes, resourceBundle <- ResourceInventory.scopeBundles scopeDeclaration, declaration <- ResourceInventory.declarations resourceBundle]
  forM_ (T.stripPrefix "nagare-bootstrap:" (InventoryPlan.reviewPayloadIdentity document)) $ \reviewedPayloadId -> do
    active <- activeTarget mctx
    (paths, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
    manifest <- readPayloadManifest paths >>= either (dieT . renderWorkspaceError) pure
    unless
      ( not (T.null reviewedPayloadId)
          && reviewedPayloadId == manifest ^. #payloadId
          && manifest ^. #payloadId == workspace ^. #payloadId
          && manifest ^. #platformVersion == workspace ^. #platformVersion
          && active ^. #profile . #platformVersion == Just (manifest ^. #platformVersion)
      )
      (dieT "reviewed bootstrap stage requires the selected immutable payload and context pin")
  allRegistrations <- either dieT pure (InventoryCloud.registrationsFromDeclarations declarations)
  let registrations =
        filter
          ( \registration ->
              Set.member
                (InventoryCloud.registrationResource registration)
                (selected ResourceInventory.PulumiExecutor)
          )
          allRegistrations
  allArtifactSpecs <- either dieT pure (InventoryArtifact.artifactExecutionSpecsFromDeclarations declarations)
  let artifactSpecs = Map.restrictKeys allArtifactSpecs (selected ResourceInventory.ArtifactExecutor)
  cacheSpecs <- either dieT pure (cacheSpecsFromDeclarations declarations)
  allTopicSpecs <- either dieT pure (topicSpecsFromDeclarations declarations)
  let topicSpecs = Map.restrictKeys allTopicSpecs (selected ResourceInventory.BrokerExecutor)
  allDnsSpecs <- either dieT pure (dnsSpecsFromDeclarations declarations)
  let dnsSpecs = Map.restrictKeys allDnsSpecs (selected ResourceInventory.CdnExecutor)
  cdnDeclarations <-
    either
      (dieT . T.pack . show)
      pure
      ( ResourceInventory.composedDeclarations
          (Map.fromList [(ResourceInventory.scopeId scope, scope) | scope <- scopes])
      )
  allCloudflareSpecs <- either dieT pure (cloudflareBindingsFromDeclarations cdnDeclarations)
  let cloudflareSpecs = Map.restrictKeys allCloudflareSpecs (selected ResourceInventory.CdnExecutor)
  hostInputs <-
    if Set.null (selected ResourceInventory.HostExecutor)
      then pure Nothing
      else either dieT pure (InventoryHost.hostExecutionInputsFromScopes scopes)
  reviewedKubernetesSpecs <- either dieT pure (kubernetesSpecsFromReview bundle)
  let stampOwner = either (error . T.unpack) (\scope -> scope) (Resource.mkScopeId Resource.Platform "bootstrap-stamp")
      stampId =
        Resource.mintResourceId
          stampOwner
          (either (error . T.unpack) (\key -> key) (Resource.mkLogicalKey "bootstrap"))
          (either (error . T.unpack) (\name -> name) (Resource.mkName "version"))
  forM_ (Map.lookup stampId reviewedKubernetesSpecs) $ \(_, markerBytes) -> do
    active <- activeTarget mctx
    (paths, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
    manifest <- readPayloadManifest paths >>= either (dieT . renderWorkspaceError) pure
    unless
      ( manifest ^. #payloadId == workspace ^. #payloadId
          && manifest ^. #platformVersion == workspace ^. #platformVersion
          && active ^. #profile . #platformVersion == Just (manifest ^. #platformVersion)
      )
      (dieT "reviewed bootstrap marker requires the selected payload and context pin")
    let vectorDigest = bootstrapScopeVectorDigest (InventoryPlan.reviewDesiredRevisions document)
    either
      dieT
      pure
      ( verifyBootstrapStampPayload
          (manifest ^. #payloadId)
          vectorDigest
          (identityFromPayload manifest)
          markerBytes
      )
  helmSpecs <- either dieT pure (helmSpecsFromReview bundle)
  sourceProofs <- forM scopes $ \scopeDeclaration -> do
    backupProof <- either dieT pure (manualBackupSourceProof scopeDeclaration)
    restoreProof <- either dieT pure (manualRestoreTargetProof scopeDeclaration)
    pruneProof <- either dieT pure (manualPruneSourceProof scopeDeclaration)
    scheduledProof <- either dieT pure (scheduledIngestSourceProof scopeDeclaration)
    let jobIds =
          [ member ^. #identity
          | resourceBundle <- ResourceInventory.scopeBundles scopeDeclaration
          , ResourceInventory.Managed member <- ResourceInventory.declarations resourceBundle
          , case member ^. #address of
              Resource.Kubernetes _ "batch" kind _ _ -> Resource.nameText kind == "job"
              _ -> False
          ]
        selectedJob =
          any
            ( \operation ->
                InventoryAdapter.plannedAction operation
                  `elem` [InventoryAdapter.CreateResource, InventoryAdapter.RunDeclaredOperation]
                  && any (`elem` jobIds) (NE.toList (InventoryAdapter.plannedResources operation))
            )
            operations
    pure
      ( if selectedJob
          then
            ( catMaybes [backupProof, restoreProof]
            , maybe [] (: []) pruneProof
            , maybe [] (: []) scheduledProof
            )
          else ([], [], [])
      )
  let backupProofs = concatMap (\(selected, _, _) -> selected) sourceProofs
      pruneProofs = concatMap (\(_, selected, _) -> selected) sourceProofs
      scheduledProofs = concatMap (\(_, _, selected) -> selected) sourceProofs
  maintenanceProofs <- either dieT pure (selectedMaintenanceProofs scopes operations)
  liveRestoreProofs <- either dieT pure (selectedLiveRestoreProofs scopes operations)
  backupSourceNative <-
    loadReviewedBackupSourceNative
      store
      document
      backupProofs
  volumeSourceNative <-
    loadReviewedVolumeSourceNative
      store
      document
      reviewedKubernetesSpecs
  pruneSourceNative <- loadReviewedPruneSourceNative store document pruneProofs
  scheduledSourceNative <- loadReviewedScheduledIngestSourceNative store document scheduledProofs
  (maintenanceSourceNative, maintenanceAcceptedNative) <-
    loadReviewedMaintenanceSourceNative store document maintenanceProofs
  (liveRestoreSourceNative, liveRestoreAcceptedNative) <-
    loadReviewedLiveRestoreSourceNative store document liveRestoreProofs
  let sourceNative =
        Map.unions
          [ backupSourceNative
          , volumeSourceNative
          , pruneSourceNative
          , scheduledSourceNative
          , maintenanceSourceNative
          , liveRestoreSourceNative
          ]
  unless
    ( Map.size sourceNative
        == Map.size backupSourceNative
          + Map.size volumeSourceNative
          + Map.size pruneSourceNative
          + Map.size scheduledSourceNative
          + Map.size maintenanceSourceNative
          + Map.size liveRestoreSourceNative
    )
    (dieT "manual data source native evidence overlaps")
  unless
    ( all
        ( \(resource, member) ->
            maybe True (== member) (Map.lookup resource sourceNative)
        )
        (Map.toAscList reviewedKubernetesSpecs)
    )
    (dieT "manual data source native evidence differs from the saved review")
  let retiredIds =
        Map.keysSet (InventoryPlan.reviewRetentions document)
          `Set.union` Map.keysSet (InventoryPlan.reviewCollections document)
      binding = InventoryPlan.reviewContextBinding document
      activeExecutors =
        Set.fromList
          [InventoryAdapter.plannedExecutor operation | operation <- operations]
      selectedInfra =
        any
          (`Set.member` activeExecutors)
          [ ResourceInventory.PulumiExecutor
          , ResourceInventory.ArtifactExecutor
          , ResourceInventory.HostExecutor
          ]
  (retiringKubernetesSpecs, retiringHelmSpecs) <-
    if Set.null retiredIds
      then pure (Map.empty, Map.empty)
      else do
        history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
        acceptedSnapshot <-
          either
            (dieT . T.pack . show)
            pure
            ( ResourceInventory.mkScopeSnapshot
                binding
                ( Map.map
                    (\(revision, scope) -> (InventoryStore.revisionGeneration revision, scope))
                    (InventoryPlan.historyAccepted history)
                )
                (InventoryPlan.historyReservations history)
            )
        acceptedInventory <-
          either
            (dieT . T.pack . show)
            pure
            (ResourceInventory.composeSnapshot acceptedSnapshot)
        (native, helmNative) <-
          InventoryStatus.loadAcceptedNative store history acceptedInventory
            >>= either dieT pure
        let selectedKubernetes = Map.filterWithKey (\resource _ -> Set.member resource retiredIds) native
            selectedHelm = Map.filterWithKey (\resource _ -> Set.member resource retiredIds) helmNative
        unless
          (Set.union (Map.keysSet selectedKubernetes) (Map.keysSet selectedHelm) == retiredIds)
          (dieT "retirement review lacks accepted immutable native evidence")
        pure (selectedKubernetes, selectedHelm)
  let kubernetesSpecs =
        Map.restrictKeys
          (Map.unions [reviewedKubernetesSpecs, retiringKubernetesSpecs, sourceNative])
          ( Set.union
              (selected ResourceInventory.KubernetesExecutor)
              (Map.keysSet sourceNative `Set.union` Map.keysSet retiringKubernetesSpecs)
          )
      allHelmSpecs =
        Map.restrictKeys
          (Map.union helmSpecs retiringHelmSpecs)
          (selected ResourceInventory.HelmExecutor `Set.union` Map.keysSet retiringHelmSpecs)
  if null registrations && Set.null (selected ResourceInventory.CloudFoundationExecutor) && Set.null (selected ResourceInventory.AccessExecutor) && Map.null artifactSpecs && isNothing hostInputs && Map.null kubernetesSpecs && Map.null cacheSpecs && Map.null topicSpecs && Map.null dnsSpecs && Map.null cloudflareSpecs && Map.null allHelmSpecs
    then either dieT pure (InventoryAdapter.mkAdapterRegistry (map Inventory.executionBlockedAdapterFor [ResourceInventory.KubernetesExecutor, ResourceInventory.PulumiExecutor, ResourceInventory.CloudFoundationExecutor, ResourceInventory.HostExecutor, ResourceInventory.ArtifactExecutor, ResourceInventory.CacheExecutor, ResourceInventory.BrokerExecutor, ResourceInventory.HelmExecutor, ResourceInventory.CdnExecutor, ResourceInventory.AccessExecutor]))
    else do
      let needsWorkspace =
            selectedInfra
              || not (Set.null (selected ResourceInventory.CloudFoundationExecutor))
              || not (Map.null cacheSpecs && Map.null dnsSpecs && Map.null cloudflareSpecs && Map.null allHelmSpecs)
      (active, workspace) <-
        if not selectedInfra
          then do
            active <- activeTarget mctx
            workspace <-
              if not needsWorkspace
                then pure Nothing
                else
                  Just . snd <$> resolvePlatformWorkspace (active ^. #contextName)
            pure (active, workspace)
          else do
            active <- activeTarget mctx
            if null registrations && active ^. #profile . #mode == Local
              then do
                (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
                pure (active, Just workspace)
              else do
                (prepared, workspace) <- prepareInfraMutationWithPulumi (not (null registrations)) mctx
                pure (prepared, Just workspace)
      let withWorkspace :: (PlatformWorkspace -> IO a) -> IO a
          withWorkspace action = maybe (dieT "selected executor requires a platform workspace") action workspace
      when
        ( not (Set.null (selected ResourceInventory.AccessExecutor))
            || ( active ^. #profile . #mode == Local
                   && (not (Map.null kubernetesSpecs) || not (Map.null allHelmSpecs))
               )
        )
        $ do
          selectedKubeconfig <- kubeconfigPath (active ^. #contextName)
          exists <- doesFileExist selectedKubeconfig
          unless exists (dieT "reviewed local context kubeconfig is missing")
          setEnv "KUBECONFIG" selectedKubeconfig
      pulumi <-
        if null registrations
          then pure (Inventory.executionBlockedAdapterFor ResourceInventory.PulumiExecutor)
          else withWorkspace (\root -> inventoryPulumiAdapter active root binding scopes allRegistrations)
      foundation <-
        if Set.null (selected ResourceInventory.CloudFoundationExecutor)
          then pure (Inventory.executionBlockedAdapterFor ResourceInventory.CloudFoundationExecutor)
          else
            withWorkspace
              ( \root ->
                  inventoryFoundationAdapter
                    active
                    root
                    binding
                    declarations
                    (selected ResourceInventory.CloudFoundationExecutor)
              )
      artifact <-
        if Map.null artifactSpecs
          then pure (Inventory.executionBlockedAdapterFor ResourceInventory.ArtifactExecutor)
          else withWorkspace (\root -> inventoryArtifactAdapter active root artifactSpecs)
      host <-
        maybe
          (pure (Inventory.executionBlockedAdapterFor ResourceInventory.HostExecutor))
          (\inputs -> withWorkspace (\root -> inventoryHostAdapter active root False scopes inputs))
          hostInputs
      (cache, cacheKey) <-
        if Map.null cacheSpecs
          then
            pure
              ( Inventory.executionBlockedAdapterFor ResourceInventory.CacheExecutor
              , \_ -> pure (Left "cache output resolver is not installed")
              )
          else withWorkspace (\root -> inventoryCacheAdapter active root binding cacheSpecs)
      acceptedTopics <-
        if Map.null topicSpecs
          then pure Map.empty
          else do
            history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
            pure (acceptedTopicResources history)
      broker <- inventoryBrokerAdapter active binding topicSpecs acceptedTopics
      acceptedDns <-
        if Map.null dnsSpecs && Map.null cloudflareSpecs
          then pure Map.empty
          else do
            reviewBaseDnsResources store bundle
      dns <-
        if Map.null dnsSpecs && Map.null cloudflareSpecs
          then pure (Inventory.executionBlockedAdapterFor ResourceInventory.CdnExecutor)
          else withWorkspace (\root -> inventoryCdnAdapter active root binding dnsSpecs cloudflareSpecs acceptedDns)
      let kubernetesOperations =
            [ op
            | op <- InventoryPlan.reviewOperations (InventoryPlan.reviewBundleDocument bundle)
            , InventoryAdapter.plannedExecutor (InventoryPlan.reviewPlannedOperation op) == ResourceInventory.KubernetesExecutor
            ]
          controllerCollection = any ((== controllerCollectionIdentity) . InventoryPlan.reviewAdapterIdentity) kubernetesOperations
      when
        (controllerCollection && any ((/= controllerCollectionIdentity) . InventoryPlan.reviewAdapterIdentity) kubernetesOperations)
        (dieT "controller collection cannot mix ordinary Kubernetes effects")
      kubernetesNative <-
        if controllerCollection
          then inventoryControllerCollectionAdapter active binding kubernetesSpecs
          else inventoryKubernetesAdapter active binding cacheKey kubernetesSpecs
      let kubernetesBase =
            kubernetesNative
              { InventoryAdapter.adapterPreflight = \operation prepared -> do
                  native <- InventoryAdapter.adapterPreflight kubernetesNative operation prepared
                  case native of
                    Left reason -> pure (Left reason)
                    Right () ->
                      if InventoryAdapter.plannedAction operation /= InventoryAdapter.CreateResource
                        then pure (Right ())
                        else do
                          -- Eligibility belongs to a new effect, including an
                          -- adapter-proved retry. Recovering a historical effect
                          -- must not require its original provider listing.
                          checked <- try $ do
                            let jobs = Set.fromList (NE.toList (InventoryAdapter.plannedResources operation))
                            verifyReviewedScheduledPruneRecovery mctx scopes jobs
                            verifyReviewedScheduledPruneProvider mctx scopes jobs
                          pure $ case (checked :: Either ExitCode ()) of
                            Left _ -> Left "reviewed prune eligibility changed; no new Job was submitted"
                            Right () -> Right ()
              }
      helm <-
        if Map.null allHelmSpecs
          then pure (Inventory.executionBlockedAdapterFor ResourceInventory.HelmExecutor)
          else withWorkspace (\root -> inventoryHelmAdapter active root binding allHelmSpecs)
      context <-
        either
          dieT
          pure
          ( Resource.mkContextId
              (contextNameText (active ^. #contextName))
          )
      access <-
        accessReviewAdapter
          store
          binding
          (contextNameText (active ^. #contextName))
          (fmap (fmap (const ())) (guardKubernetesContext active))
          bundle
          >>= either dieT pure
      let runtime =
            KubernetesRuntimeConfig
              context
              (contextNameText (active ^. #contextName))
              (fmap (fmap (const ())) (guardKubernetesContext active))
          (kubernetes, restoreRecovery, verifyRecovery) =
            liveRestoreRuntime
              runtime
              scopes
              (Map.union liveRestoreAcceptedNative kubernetesSpecs)
              ( maintenanceAdapter
                  runtime
                  scopes
                  (Map.union maintenanceAcceptedNative kubernetesSpecs)
                  kubernetesBase
              )
          adapters = [pulumi, foundation, artifact, host, kubernetes, cache, broker, helm, dns, access]
      registry <- either dieT pure (InventoryAdapter.mkAdapterRegistry adapters)
      withMaintenance <-
        either
          dieT
          pure
          ( registerMaintenanceFence
              runtime
              binding
              (InventoryPlan.reviewDesiredRevisions document)
              scopes
              declarations
              maintenanceAcceptedNative
              registry
          )
      withLiveRestore <-
        either
          dieT
          pure
          ( registerLiveRestoreFence
              runtime
              binding
              (InventoryPlan.reviewDesiredRevisions document)
              scopes
              declarations
              liveRestoreAcceptedNative
              restoreRecovery
              verifyRecovery
              withMaintenance
          )
      if active ^. #profile . #mode == Cloud
        && "nagare-bootstrap:" `T.isPrefixOf` InventoryPlan.reviewPayloadIdentity document
        then
          either
            dieT
            pure
            ( InventoryAdapter.withAdapterRecovery
                withLiveRestore
                (bootstrapRegistryRecovery active store bundle kubernetes)
            )
        else pure withLiveRestore

-- Registry construction installs callbacks without native discovery. Only an
-- explicit bounded recovery may load the completed historical host plan.
bootstrapRegistryRecovery ::
  ActiveTarget ->
  InventoryStore.InventoryStore ->
  InventoryPlan.ReviewBundle ->
  InventoryAdapter.Adapter ->
  InventoryAdapter.AdapterRecovery
bootstrapRegistryRecovery active store bundle kubernetes =
  mkBootstrapRegistryRecovery
    store
    bundle
    (profile ^. #registryHost)
    inspect
    units
    (InventoryAdapter.adapterRecover kubernetes)
  where
    profile = active ^. #profile
    additions = [("NAGARE_CONTEXT", T.unpack (contextNameText (active ^. #contextName)))]
    selectedWorkspace = snd <$> resolvePlatformWorkspace (active ^. #contextName)
    inspect plan = do
      root <- selectedWorkspace
      let config =
            HostRuntimeConfig
              { runtimeHostExecutable = root ^. #scriptsDir </> "inventory-host-transport.sh"
              , runtimeHostEnvironment = additions
              , runtimeHostContext = hostPlanContext plan
              , runtimeHostAttribute = hostPlanAttribute plan
              , runtimeHostProject = profile ^. #project
              , runtimeHostZone = profile ^. #zone
              , runtimeHostInstanceName = profile ^. #instanceName
              , runtimeHostDestination = hostPlanDestination plan
              , runtimeHostConfigurationDigest = hostPlanConfigurationDigest plan
              , runtimeHostLockDigest = hostPlanLockDigest plan
              , runtimeHostAgeKeyDigest = hostPlanAgeKeyDigest plan
              , runtimeHostAccepted = True
              }
      hostInspectActivation (mkHostRuntimeOps config) plan
    units plan deployment saved = do
      root <- selectedWorkspace
      runRegistryUnitTransport
        (root ^. #scriptsDir </> "iap-ssh.sh")
        additions
        (profile ^. #instanceName)
        (profile ^. #registryHost)
        plan
        deployment
        saved
