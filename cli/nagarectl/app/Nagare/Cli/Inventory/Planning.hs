-- | Inventory / Planning. Executable-private CLI boundary.
module Nagare.Cli.Inventory.Planning
  ( inventoryPlanRegistry
  , inventoryPlanRegistryWithNative
  , inventoryPlanRegistryWithTakeover
  , inventoryControllerCollectionRegistry
  )
where

import Control.Monad (forM)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Access.Reviewed qualified as ReviewedAccess
import Nagare.Cli.Inventory.Adapters
  ( acceptedDnsResources
  , acceptedTopicResources
  , hostScopeAccepted
  , inventoryArtifactAdapter
  , inventoryBrokerAdapter
  , inventoryCacheAdapter
  , inventoryCdnAdapter
  , inventoryControllerCollectionAdapter
  , inventoryHelmAdapter
  , inventoryHostAdapter
  , inventoryKubernetesAdapterWith
  , inventoryPulumiAdapterWithCollections
  )
import Nagare.Cli.Inventory.CdnHistory
import Nagare.Cli.Inventory.CdnPurge (cdnPurgeRuntime)
import Nagare.Cli.Inventory.CloudHistory
import Nagare.Cli.Inventory.Foundation
  ( inventoryFoundationAdapter
  )
import Nagare.Cli.Inventory.ImagePrune (imagePruneRuntime)
import Nagare.Cli.Inventory.VmPower (vmPowerRuntime)
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cluster.Kubeconfig (kubeconfigPath)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.Adapters.ArtifactRuntime
  ( observeKubeconfigProjectionAt
  )
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
import Nagare.Inventory.Adapters.KubernetesRuntime
  ( KubernetesRuntimeConfig (KubernetesRuntimeConfig)
  )
import Nagare.Inventory.Artifact qualified as InventoryArtifact
import Nagare.Inventory.BackendMap
  ( compileContributedBackendMaps
  , compileContributedShomeiSettings
  )
import Nagare.Inventory.Cloud qualified as InventoryCloud
import Nagare.Inventory.CollectionPolicy (requiresControllerCollection)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Components.Foundation
  ( compileContributedNamespaces
  )
import Nagare.Inventory.Host qualified as InventoryHost
import Nagare.Inventory.KubernetesSources
  ( validateSuppliedKubernetesMembers
  )
import Nagare.Inventory.LiveRestoreAdapter (liveRestoreRuntime)
import Nagare.Inventory.LiveRestoreFence
  ( registerLiveRestoreFence
  )
import Nagare.Inventory.MaintenanceAdapter (maintenanceAdapter)
import Nagare.Inventory.MaintenanceFence
  ( registerMaintenanceFence
  )
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Inventory.Store qualified as InventoryStore
import Nagare.Platform.Workspace (PlatformWorkspace)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (ActiveTarget, contextNameText)

inventoryPlanRegistry :: ActiveTarget -> PlatformWorkspace -> ResourceInventory.CompositionCandidate -> InventoryPlan.InventoryHistory -> IO InventoryAdapter.AdapterRegistry
inventoryPlanRegistry active workspace = inventoryPlanRegistryWithNative active workspace Map.empty

inventoryPlanRegistryWithNative :: ActiveTarget -> PlatformWorkspace -> Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString) -> ResourceInventory.CompositionCandidate -> InventoryPlan.InventoryHistory -> IO InventoryAdapter.AdapterRegistry
inventoryPlanRegistryWithNative = inventoryPlanRegistryWithTakeover False

-- | The flag is the operator's explicit reviewed field-takeover opt-in (F37).
inventoryPlanRegistryWithTakeover :: Bool -> ActiveTarget -> PlatformWorkspace -> Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString) -> ResourceInventory.CompositionCandidate -> InventoryPlan.InventoryHistory -> IO InventoryAdapter.AdapterRegistry
inventoryPlanRegistryWithTakeover = inventoryPlanRegistryWithMode False

inventoryControllerCollectionRegistry :: ActiveTarget -> PlatformWorkspace -> ResourceInventory.CompositionCandidate -> InventoryPlan.InventoryHistory -> IO InventoryAdapter.AdapterRegistry
inventoryControllerCollectionRegistry active workspace = inventoryPlanRegistryWithMode True False active workspace Map.empty

inventoryPlanRegistryWithMode :: Bool -> Bool -> ActiveTarget -> PlatformWorkspace -> Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString) -> ResourceInventory.CompositionCandidate -> InventoryPlan.InventoryHistory -> IO InventoryAdapter.AdapterRegistry
inventoryPlanRegistryWithMode controllerCollection takeover active workspace suppliedNative candidate history = do
  let inventory = ResourceInventory.candidateInventory candidate
      declarations = ResourceInventory.inventoryDeclarations inventory
      scopes = Map.elems (ResourceInventory.inventoryScopes inventory)
      required =
        InventoryPlan.requirementsByExecutor
          (InventoryPlan.observationRequirements candidate history)
      selected executor = Set.fromList (Map.findWithDefault [] executor required)
      selectedKubernetes =
        Set.fromList
          (Map.findWithDefault [] ResourceInventory.KubernetesExecutor required)
      selectedHelm =
        Set.fromList
          (Map.findWithDefault [] ResourceInventory.HelmExecutor required)
      historical =
        [ declaration
        | (_, (_, scope)) <- Map.toAscList (InventoryPlan.historyAccepted history)
        , bundle <- ResourceInventory.scopeBundles scope
        , declaration <- ResourceInventory.declarations bundle
        ]
  cloudHistory <-
    if Set.null (selected ResourceInventory.PulumiExecutor)
      then pure (CloudHistory [] Map.empty [] Map.empty)
      else do
        store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
        let currentIds = Set.fromList (map ResourceInventory.declarationId declarations)
            requested =
              Map.fromList
                [ (member ^. #identity, (owner, revision))
                | (owner, (revision, scope)) <- Map.toList (InventoryPlan.historyAccepted history)
                , bundle <- ResourceInventory.scopeBundles scope
                , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
                , Set.member (member ^. #identity) (selected ResourceInventory.PulumiExecutor)
                , Set.notMember (member ^. #identity) currentIds
                ]
            collecting =
              Set.fromList
                [ resource
                | ResourceInventory.CollectRetained resource <- NE.toList (ResourceInventory.candidateChanges candidate)
                , Set.member resource (selected ResourceInventory.PulumiExecutor)
                ]
        loadCloudHistory
          store
          (InventoryPlan.historyHead history)
          (scopes <> map (snd . snd) (Map.toList (InventoryPlan.historyAccepted history)))
          requested
          collecting
  let cloudDeclarations =
        Map.elems
          ( Map.union
              (Map.fromList [(ResourceInventory.declarationId member, member) | member <- declarations])
              (Map.map ResourceInventory.Managed (cloudHistoricalMembers cloudHistory))
          )
      pulumiScopes = scopes <> cloudHistoricalScopes cloudHistory
  allRegistrations <- either dieT pure (InventoryCloud.registrationsFromDeclarations cloudDeclarations)
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
  allTopicSpecs <- either dieT pure (topicSpecsFromDeclarations (historical <> declarations))
  let topicSpecs = Map.restrictKeys allTopicSpecs (selected ResourceInventory.BrokerExecutor)
  desiredDnsSpecs <- either dieT pure (dnsSpecsFromDeclarations declarations)
  historicalDnsSpecs <- either dieT pure (dnsSpecsFromDeclarations historical)
  let dnsSpecs =
        Map.restrictKeys
          (Map.unions [desiredDnsSpecs, historicalDnsSpecs, historicalDnsBindings (retainedCdnResources history)])
          (selected ResourceInventory.CdnExecutor)
  desiredCloudflareSpecs <- either dieT pure (cloudflareBindingsFromDeclarations declarations)
  historicalComposed <-
    either
      (dieT . T.pack . show)
      pure
      ( ResourceInventory.composedDeclarations
          (Map.map snd (InventoryPlan.historyAccepted history))
      )
  historicalCloudflareSpecs <- either dieT pure (cloudflareBindingsFromDeclarations historicalComposed)
  let cloudflareSpecs =
        Map.restrictKeys
          (Map.unions [desiredCloudflareSpecs, historicalCloudflareSpecs, historicalCloudflareBindings (retainedCdnResources history)])
          (selected ResourceInventory.CdnExecutor)
  hostInputs <-
    if Set.null (selected ResourceInventory.HostExecutor)
      then pure Nothing
      else either dieT pure (InventoryHost.hostExecutionInputsFromScopes scopes)
  let kubernetesResources = [resource | ResourceInventory.Managed resource <- declarations, resource ^. #executor == ResourceInventory.KubernetesExecutor]
      helmResources = [resource | ResourceInventory.Managed resource <- declarations, resource ^. #executor == ResourceInventory.HelmExecutor]
  namespaceNative <- either dieT pure (compileContributedNamespaces declarations)
  backendNative <- either dieT pure (compileContributedBackendMaps declarations)
  shomeiNative <- either dieT pure (compileContributedShomeiSettings declarations)
  let generatedNative = Map.unions [namespaceNative, backendNative, shomeiNative]
  unless
    ( Map.size generatedNative == Map.size namespaceNative + Map.size backendNative + Map.size shomeiNative
        && Map.null (Map.intersection suppliedNative generatedNative)
    )
    (dieT "generated native members overlap a supplied or contributed resource")
  let allSuppliedNative = Map.union suppliedNative generatedNative
      kubernetesSuppliedNative = Map.filter ((== ResourceInventory.KubernetesExecutor) . (^. #executor) . fst) allSuppliedNative
      helmSuppliedNative = Map.filter ((== ResourceInventory.HelmExecutor) . (^. #executor) . fst) allSuppliedNative
      suppliedIds = Map.keysSet kubernetesSuppliedNative
      declaredIds = Set.fromList (map (^. #identity) kubernetesResources)
      helmSuppliedIds = Map.keysSet helmSuppliedNative
      declaredHelmIds = Set.fromList (map (^. #identity) helmResources)
  unless (suppliedIds `Set.isSubsetOf` declaredIds) (dieT "generated native members include an undeclared Kubernetes resource")
  unless
    ( helmSuppliedIds `Set.isSubsetOf` declaredHelmIds
        && (selectedHelm `Set.intersection` declaredHelmIds) `Set.isSubsetOf` helmSuppliedIds
    )
    (dieT "selected Helm release lacks a captured native contract")
  either dieT pure (validateSuppliedKubernetesMembers kubernetesResources kubernetesSuppliedNative)
  let fileBacked =
        filter
          ( \resource ->
              Set.member (resource ^. #identity) selectedKubernetes
                && Set.notMember (resource ^. #identity) suppliedIds
          )
          kubernetesResources
  -- A packaged member comes from the workspace; an accepted application or
  -- database member, unchanged, from its accepted native evidence (F80).
  loaded <-
    if null fileBacked
      then pure Map.empty
      else do
        store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
        InventoryStatus.loadKubernetesMembers (workspace ^. #root) store history fileBacked >>= either dieT pure
  let desiredIds = Set.fromList (map ResourceInventory.declarationId declarations)
      retiringIds executor =
        Set.fromList
          [ resource ^. #identity
          | ResourceInventory.Managed resource <- historicalComposed
          , resource ^. #executor == executor
          , Set.notMember (resource ^. #identity) desiredIds
          ]
      collectingIds =
        Set.fromList
          [ resource
          | ResourceInventory.CollectRetained resource <- NE.toList (ResourceInventory.candidateChanges candidate)
          , Just (_, retained) <- [Map.lookup resource (InventoryPlan.historyRetained history)]
          , retained ^. #executor == ResourceInventory.KubernetesExecutor
          ]
      historicalKubernetesIds = Set.union (retiringIds ResourceInventory.KubernetesExecutor) collectingIds
      historicalHelmIds = retiringIds ResourceInventory.HelmExecutor
      historicalIds = Set.union historicalKubernetesIds historicalHelmIds
  (retiringNative, retiringHelmNative) <-
    if Set.null historicalIds
      then pure (Map.empty, Map.empty)
      else do
        store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
        acceptedSnapshot <-
          either
            (dieT . T.pack . show)
            pure
            ( ResourceInventory.mkScopeSnapshot
                (ResourceInventory.inventoryBinding inventory)
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
          InventoryStatus.loadAcceptedNativeSelected historicalIds store history acceptedInventory
            >>= either dieT pure
        let selectedRetiringKubernetes =
              Map.filterWithKey
                (\resource _ -> Set.member resource historicalKubernetesIds)
                native
            selectedRetiringHelm =
              Map.filterWithKey
                (\resource _ -> Set.member resource historicalHelmIds)
                helmNative
        unless
          ( Map.keysSet selectedRetiringKubernetes == historicalKubernetesIds
              && Map.keysSet selectedRetiringHelm == historicalHelmIds
          )
          (dieT "retained or retiring resource lacks immutable native evidence")
        pure (selectedRetiringKubernetes, selectedRetiringHelm)
  let kubernetesSpecs =
        Map.restrictKeys
          (Map.unions [kubernetesSuppliedNative, loaded, retiringNative])
          selectedKubernetes
      helmSpecs =
        Map.restrictKeys
          (Map.union helmSuppliedNative retiringHelmNative)
          selectedHelm
  pulumiBase <-
    if null registrations
      then pure (Inventory.manifestAdapterFor history ResourceInventory.PulumiExecutor)
      else inventoryPulumiAdapterWithCollections (cloudOmittedUrns cloudHistory) (cloudCollectingPhysical cloudHistory) active workspace (ResourceInventory.inventoryBinding inventory) pulumiScopes allRegistrations
  pulumiPower <- vmPowerRuntime (Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure) active scopes pulumiBase
  pulumi <- imagePruneRuntime (Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure) active workspace scopes pulumiPower
  foundation <-
    inventoryFoundationAdapter
      active
      workspace
      (ResourceInventory.inventoryBinding inventory)
      declarations
      (selected ResourceInventory.CloudFoundationExecutor)
  artifact <-
    if Map.null artifactSpecs
      then pure (Inventory.manifestAdapterFor history ResourceInventory.ArtifactExecutor)
      else do
        original <- inventoryArtifactAdapter active workspace artifactSpecs
        -- Accepted credentials have workstation-local projections. Only the
        -- read-only plan observer may use the validated current-root file;
        -- native preparation and every effect retain their reviewed paths.
        let owner = either (error . T.unpack) (\scope -> scope) (Resource.mkScopeId Resource.Platform "kubeconfig")
            eligible = case ( Map.lookup owner (InventoryPlan.historyAccepted history)
                            , Map.lookup owner (ResourceInventory.inventoryScopes inventory)
                            ) of
              (Just (_, prior), Just desired)
                | prior == desired
                , InventoryArtifact.sameKubeconfigProjection prior desired ->
                    Map.restrictKeys
                      artifactSpecs
                      ( Set.fromList
                          [ resource ^. #identity
                          | bundle <- ResourceInventory.scopeBundles prior
                          , ResourceInventory.Managed resource <- ResourceInventory.declarations bundle
                          ]
                      )
              _ -> Map.empty
        destination <- kubeconfigPath (active ^. #contextName)
        pure
          original
            { InventoryAdapter.adapterObserve = \requested -> do
                ordinary <-
                  InventoryAdapter.adapterObserve
                    original
                    (filter (`Map.notMember` eligible) requested)
                projected <- forM [resource | resource <- requested, Map.member resource eligible] $ \resource -> do
                  fact <- observeKubeconfigProjectionAt destination (eligible Map.! resource)
                  pure ((resource,) <$> fact)
                pure $ do
                  base <- ordinary
                  facts <- sequence projected
                  InventoryAdapter.withStuckRollouts (InventoryAdapter.observationStuck base)
                    <$> InventoryAdapter.observationSet (Map.toAscList (InventoryAdapter.observationMap base) <> facts)
            }
  host <-
    maybe
      (pure (Inventory.manifestAdapterFor history ResourceInventory.HostExecutor))
      (inventoryHostAdapter active workspace (hostScopeAccepted history) scopes)
      hostInputs
  (cache, cacheKey) <-
    if Map.null cacheSpecs
      then pure (Inventory.manifestAdapterFor history ResourceInventory.CacheExecutor, \_ -> pure (Left "cache output resolver is not installed"))
      else inventoryCacheAdapter active workspace (ResourceInventory.inventoryBinding inventory) cacheSpecs
  broker <-
    inventoryBrokerAdapter
      active
      (ResourceInventory.inventoryBinding inventory)
      topicSpecs
      (acceptedTopicResources history)
  acceptedCdn <- Map.union (retainedCdnResources history) <$> either dieT pure (acceptedDnsResources history)
  dnsBase <-
    inventoryCdnAdapter
      active
      workspace
      (ResourceInventory.inventoryBinding inventory)
      dnsSpecs
      cloudflareSpecs
      acceptedCdn
  dns <-
    if null
      [ op
      | scope <- scopes
      , bundle <- ResourceInventory.scopeBundles scope
      , op <- ResourceInventory.operations bundle
      , ResourceInventory.operationKind op `elem` [ResourceInventory.PurgeCdnCache, ResourceInventory.PurgeCdnZone]
      ]
      then pure dnsBase
      else do
        purgeStore <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
        cdnPurgeRuntime purgeStore scopes acceptedCdn dnsBase
  kubernetesBase <-
    if Map.null kubernetesSpecs
      then pure (Inventory.manifestAdapterFor history ResourceInventory.KubernetesExecutor)
      else
        if controllerCollection
          then inventoryControllerCollectionAdapter active (ResourceInventory.inventoryBinding inventory) kubernetesSpecs
          else refuseOrphanDomainMapping kubernetesSpecs <$> inventoryKubernetesAdapterWith takeover active (ResourceInventory.inventoryBinding inventory) cacheKey kubernetesSpecs
  helm <-
    if Map.null helmSpecs
      then pure (Inventory.manifestAdapterFor history ResourceInventory.HelmExecutor)
      else inventoryHelmAdapter active workspace (ResourceInventory.inventoryBinding inventory) helmSpecs
  context <-
    either
      dieT
      pure
      ( Resource.mkContextId
          (contextNameText (active ^. #contextName))
      )
  access <-
    ReviewedAccess.accessAdapter
      active
      (fmap (fmap (const ())) (guardKubernetesContext active))
      declarations
      history
  let runtime =
        KubernetesRuntimeConfig
          context
          (contextNameText (active ^. #contextName))
          (fmap (fmap (const ())) (guardKubernetesContext active))
      maintenanceNative =
        Map.unions
          [allSuppliedNative, loaded, retiringNative]
      (kubernetes, restoreRecovery, verifyRecovery) =
        liveRestoreRuntime
          runtime
          scopes
          maintenanceNative
          (maintenanceAdapter runtime scopes maintenanceNative kubernetesBase)
      adapters = [pulumi, foundation, artifact, host, kubernetes, cache, broker, helm, dns, access]
  registry <- either dieT pure (InventoryAdapter.mkAdapterRegistry adapters)
  withMaintenance <-
    either
      dieT
      pure
      ( registerMaintenanceFence
          runtime
          (ResourceInventory.inventoryBinding inventory)
          (InventoryPlan.candidateDesiredRevisions candidate)
          scopes
          declarations
          maintenanceNative
          registry
      )
  either
    dieT
    pure
    ( registerLiveRestoreFence
        runtime
        (ResourceInventory.inventoryBinding inventory)
        (InventoryPlan.candidateDesiredRevisions candidate)
        scopes
        declarations
        maintenanceNative
        restoreRecovery
        verifyRecovery
        withMaintenance
    )

-- An ordinary review would delete a DomainMapping with Orphan propagation and
-- strand its gateway KIngress (F34); refuse before any native preparation.
refuseOrphanDomainMapping :: Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString) -> InventoryAdapter.Adapter -> InventoryAdapter.Adapter
refuseOrphanDomainMapping specs adapter =
  adapter
    { InventoryAdapter.adapterPrepare = \operation ->
        if InventoryAdapter.plannedAction operation == InventoryAdapter.RetireResource
          && any
            (maybe False (requiresControllerCollection . fst) . (`Map.lookup` specs))
            (NE.toList (InventoryAdapter.plannedResources operation))
          then
            pure
              ( Left
                  ( InventoryAdapter.PrepareRefused
                      (InventoryAdapter.plannedOperationId operation)
                      "a DomainMapping is collected with its controller descendants; use inventory collect --controller-descendants"
                  )
              )
          else InventoryAdapter.adapterPrepare adapter operation
    }
