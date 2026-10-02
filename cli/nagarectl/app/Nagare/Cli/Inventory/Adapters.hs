-- | Inventory / Adapters. Executable-private CLI boundary.
module Nagare.Cli.Inventory.Adapters
  ( acceptedDnsResources
  , acceptedTopicResources
  , hostScopeAccepted
  , inventoryArtifactAdapter
  , inventoryBrokerAdapter
  , inventoryCacheAdapter
  , inventoryCdnAdapter
  , inventoryHelmAdapter
  , inventoryHostAdapter
  , inventoryKubernetesAdapter
  , inventoryControllerCollectionAdapter
  , inventoryPulumiAdapter
  , reviewBaseDnsResources
  )
where

import Control.Monad (forM)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List (delete)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Cdn.Cloudflare (cfRequestWithStatus)
import Nagare.Cdn.Provision (verifyGcpDnsReference)
import Nagare.Cli.Application.Cdn (gatherGcpStackRefs)
import Nagare.Cli.Inventory.CloudCatalog (loadCloudCatalog)
import Nagare.Cli.Inventory.Foundation (foundationImageLink)
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.ProjectGuard (projectGuardInputsFor)
import Nagare.Dsl.Prelude
import Nagare.Host.Config (hostConfigDir, readContextHostName)
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.Adapters.Artifact (mkArtifactAdapter)
import Nagare.Inventory.Adapters.ArtifactRuntime
  ( ArtifactRuntimeConfig
      ( ArtifactRuntimeConfig
      , runtimeArtifactEnvironment
      , runtimeArtifactExecutable
      , runtimeArtifactSpecs
      )
  , mkArtifactRuntimeOps
  )
import Nagare.Inventory.Adapters.Broker
  ( TopicBinding
  , mkTopicAdapter
  )
import Nagare.Inventory.Adapters.BrokerRuntime qualified as BrokerRuntime
import Nagare.Inventory.Adapters.Cache (mkCacheAdapter)
import Nagare.Inventory.Adapters.CacheRuntime qualified as CacheRuntime
import Nagare.Inventory.Adapters.Cdn
  ( DnsBinding (dnsDeclaration)
  , mkDnsAdapter
  )
import Nagare.Inventory.Adapters.CdnCombined (combineCdnAdapters)
import Nagare.Inventory.Adapters.CdnRuntime qualified as CdnRuntime
import Nagare.Inventory.Adapters.Cloudflare
  ( CloudflareBinding (CloudflareBinding)
  , mkCloudflareAdapter
  )
import Nagare.Inventory.Adapters.CloudflareRuntime qualified as CloudflareRuntime
import Nagare.Inventory.Adapters.Helm (mkHelmAdapter)
import Nagare.Inventory.Adapters.HelmRuntime
  ( HelmRuntimeConfig (..)
  , helmRuntimeOps
  )
import Nagare.Inventory.Adapters.Host (mkHostAdapter)
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
import Nagare.Inventory.Adapters.Kubernetes
  ( mkKubernetesAdapterWithBackupReceiptAndBatch
  )
import Nagare.Inventory.Adapters.KubernetesRuntime
  ( KubernetesRuntimeConfig (KubernetesRuntimeConfig)
  , mkKubernetesRuntimeOpsAndBatchWithCacheKey
  , readBackupReceiptFromCompletedPod
  )
import Nagare.Inventory.Adapters.Pulumi (mkPulumiAdapter)
import Nagare.Inventory.Adapters.PulumiRuntime
  ( PulumiRuntimeConfig
      ( PulumiRuntimeConfig
      , runtimeBackend
      , runtimeContext
      , runtimeDeclarationBundle
      , runtimePayloadDigest
      , runtimePayloadId
      , runtimeProject
      , runtimePulumiDirectory
      , runtimePulumiExecutable
      , runtimeRegistrations
      , runtimeStack
      , runtimeStackConfig
      )
  , mkPulumiRuntimeOps
  )
import Nagare.Inventory.Artifact qualified as InventoryArtifact
import Nagare.Inventory.Cloud qualified as InventoryCloud
import Nagare.Inventory.Collection.Adapter (controllerCollectionAdapter)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Digest qualified as InventoryDigest
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Store qualified as InventoryStore
import Nagare.Ops.ContextGuard (projectGuardVerdict)
import Nagare.Ops.Pulumi (stackOutput)
import Nagare.Platform.StackConfig (contextStackConfigPath)
import Nagare.Platform.Workspace (PlatformWorkspace)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire qualified as ResourceWire
import Nagare.Target
  ( ActiveTarget
  , Mode (Cloud)
  , contextNameText
  , nagareStateDir
  , pulumiEnvFor
  )
import System.Environment (lookupEnv)
import System.FilePath ((</>))

inventoryKubernetesAdapter :: ActiveTarget -> Resource.ContextBinding -> (Resource.ResourceId -> IO (Either Text Text)) -> Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString) -> IO InventoryAdapter.Adapter
inventoryKubernetesAdapter active binding cacheKey specs
  | Map.null specs = pure (Inventory.executionBlockedAdapterFor ResourceInventory.KubernetesExecutor)
  | otherwise = do
      context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
      unless (context == binding ^. #identity) (dieT "Kubernetes inventory review belongs to a different context")
      let config = KubernetesRuntimeConfig context (contextNameText (active ^. #contextName)) (fmap (fmap (const ())) (guardKubernetesContext active))
          (ops, observeBatch) = mkKubernetesRuntimeOpsAndBatchWithCacheKey config cacheKey specs
      pure
        ( mkKubernetesAdapterWithBackupReceiptAndBatch
            specs
            ops
            observeBatch
            (readBackupReceiptFromCompletedPod config specs)
        )

inventoryControllerCollectionAdapter :: ActiveTarget -> Resource.ContextBinding -> Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString) -> IO InventoryAdapter.Adapter
inventoryControllerCollectionAdapter active binding specs = do
  context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
  unless (context == binding ^. #identity) (dieT "controller collection review belongs to a different context")
  let config =
        KubernetesRuntimeConfig
          context
          (contextNameText (active ^. #contextName))
          (fmap (fmap (const ())) (guardKubernetesContext active))
  pure (controllerCollectionAdapter config specs)

inventoryHelmAdapter :: ActiveTarget -> PlatformWorkspace -> Resource.ContextBinding -> Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString) -> IO InventoryAdapter.Adapter
inventoryHelmAdapter active workspace binding specs
  | Map.null specs = pure (Inventory.executionBlockedAdapterFor ResourceInventory.HelmExecutor)
  | otherwise = do
      context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
      unless (context == binding ^. #identity) (dieT "Helm inventory review belongs to a different context")
      pure (mkHelmAdapter specs (helmRuntimeOps (inventoryHelmRuntimeConfig active workspace binding specs)))

inventoryHelmRuntimeConfig :: ActiveTarget -> PlatformWorkspace -> Resource.ContextBinding -> Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString) -> HelmRuntimeConfig
inventoryHelmRuntimeConfig active workspace binding specs =
  HelmRuntimeConfig
    { helmKubeContext = contextNameText (active ^. #contextName)
    , helmContextId = binding ^. #identity
    , helmVerifyPlugin = workspace ^. #root </> "cluster/observability/helm-review"
    , helmDeclarations = Map.map fst specs
    , helmRuntimeGuard = fmap (fmap (const ())) (guardKubernetesContext active)
    }

inventoryCacheAdapter :: ActiveTarget -> PlatformWorkspace -> Resource.ContextBinding -> Map.Map Resource.ResourceId ResourceInventory.ManagedResource -> IO (InventoryAdapter.Adapter, Resource.ResourceId -> IO (Either Text Text))
inventoryCacheAdapter active workspace binding specs
  | Map.null specs = pure (Inventory.executionBlockedAdapterFor ResourceInventory.CacheExecutor, \_ -> pure (Left "cache output resolver is not installed"))
  | otherwise = do
      context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
      unless (context == binding ^. #identity) (dieT "cache inventory review belongs to a different context")
      let config =
            CacheRuntime.CacheRuntimeConfig
              { CacheRuntime.runtimeCacheExecutable = workspace ^. #scriptsDir </> "inventory-cache-transport.sh"
              , CacheRuntime.runtimeCacheKubectlContext = contextNameText (active ^. #contextName)
              , CacheRuntime.runtimeCacheContextId = context
              , CacheRuntime.runtimeCacheGuard = fmap (fmap (const ())) (guardKubernetesContext active)
              , CacheRuntime.runtimeCacheSpecs = specs
              }
      pure (mkCacheAdapter specs (CacheRuntime.mkCacheRuntimeOps config), CacheRuntime.cachePublicKeyForResource config)

acceptedTopicResources :: InventoryPlan.InventoryHistory -> Map.Map Resource.ResourceId ResourceInventory.ManagedResource
acceptedTopicResources history =
  Map.fromList
    [ (resource ^. #identity, resource)
    | (_, (_, scope)) <- Map.toAscList (InventoryPlan.historyAccepted history)
    , bundle <- ResourceInventory.scopeBundles scope
    , ResourceInventory.Managed resource <- ResourceInventory.declarations bundle
    , resource ^. #executor == ResourceInventory.BrokerExecutor
    ]

acceptedDnsResources ::
  InventoryPlan.InventoryHistory ->
  Either Text (Map.Map Resource.ResourceId ResourceInventory.ManagedResource)
acceptedDnsResources history = do
  declarations <-
    first
      (T.pack . show)
      ( ResourceInventory.composedDeclarations
          (Map.map snd (InventoryPlan.historyAccepted history))
      )
  pure (cdnResourceMap declarations)

cdnResourceMap ::
  [ResourceInventory.Declaration] ->
  Map.Map Resource.ResourceId ResourceInventory.ManagedResource
cdnResourceMap declarations =
  Map.fromList
    [ (resource ^. #identity, resource)
    | ResourceInventory.Managed resource <- declarations
    , resource ^. #executor == ResourceInventory.CdnExecutor
    ]

reviewBaseDnsResources ::
  InventoryStore.InventoryStore ->
  InventoryPlan.ReviewBundle ->
  IO (Map.Map Resource.ResourceId ResourceInventory.ManagedResource)
reviewBaseDnsResources store bundle = do
  scopes <- forM (Map.toAscList (InventoryPlan.reviewBaseRevisions document)) $ \(owner, revision) -> do
    loaded <-
      InventoryStore.readObject store (InventoryStore.scopeKey (InventoryStore.revisionDigest revision))
        >>= either (dieT . T.pack . show) pure
    bytes <- maybe (dieT "reviewed DNS base scope is missing from immutable history") pure loaded
    unless
      (InventoryDigest.contentDigest bytes == InventoryStore.revisionDigest revision)
      (dieT "reviewed DNS base scope digest differs from immutable history")
    scope <- either (dieT . T.pack . show) pure (ResourceWire.decodeScope bytes)
    unless
      (ResourceInventory.scopeId scope == owner)
      (dieT "reviewed DNS base scope owner differs from immutable history")
    pure scope
  declarations <-
    either
      (dieT . T.pack . show)
      pure
      ( ResourceInventory.composedDeclarations
          (Map.fromList [(ResourceInventory.scopeId scope, scope) | scope <- scopes])
      )
  pure (cdnResourceMap declarations)
  where
    document = InventoryPlan.reviewBundleDocument bundle

inventoryDnsAdapter ::
  ActiveTarget ->
  PlatformWorkspace ->
  Resource.ContextBinding ->
  Map.Map Resource.ResourceId DnsBinding ->
  Map.Map Resource.ResourceId ResourceInventory.ManagedResource ->
  IO InventoryAdapter.Adapter
inventoryDnsAdapter active workspace binding specs accepted
  | Map.null specs = pure (Inventory.executionBlockedAdapterFor ResourceInventory.CdnExecutor)
  | otherwise = do
      context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
      unless
        (context == binding ^. #identity)
        (dieT "DNS inventory review belongs to a different context")
      project <- either dieT pure (Resource.mkName (active ^. #profile . #project))
      let config =
            CdnRuntime.DnsRuntimeConfig
              { CdnRuntime.dnsRuntimeProject = project
              , CdnRuntime.dnsRuntimeGuard = \resource -> do
                  inputs <- projectGuardInputsFor (active ^. #contextName) (active ^. #profile) workspace
                  case projectGuardVerdict inputs of
                    Left reason -> pure (Left reason)
                    Right () -> case Map.lookup resource specs of
                      Nothing -> pure (Left "DNS resource is absent from the active context binding")
                      Just dnsBinding -> do
                        refs <- gatherGcpStackRefs (workspace ^. #pulumiDir) (active ^. #profile)
                        origin <- stackOutput (workspace ^. #pulumiDir) "publicIp"
                        let expected = case ( dnsDeclaration dnsBinding ^. #address
                                            , dnsDeclaration dnsBinding ^. #spec
                                            ) of
                              (Resource.DnsRecord account zone _, ResourceInventory.DnsARecord target _)
                                | Resource.nameText account == refs ^. #project
                                , Resource.nameText zone == refs ^. #dnsZone
                                , target == refs ^. #globalIp
                                    || (Just target == origin && Map.member resource accepted) ->
                                    Right ()
                              _ -> Left "reviewed DNS account, zone, or target differs from the platform outputs"
                        case expected of
                          Left reason -> pure (Left reason)
                          Right () ->
                            verifyGcpDnsReference
                              refs
                              (active ^. #profile . #baseDomain)
                              (refs ^. #globalIp)
              , CdnRuntime.dnsRuntimeSpecs = specs
              }
      pure (mkDnsAdapter accepted specs (CdnRuntime.dnsRuntimeOps config))

inventoryCdnAdapter ::
  ActiveTarget ->
  PlatformWorkspace ->
  Resource.ContextBinding ->
  Map.Map Resource.ResourceId DnsBinding ->
  Map.Map Resource.ResourceId CloudflareBinding ->
  Map.Map Resource.ResourceId ResourceInventory.ManagedResource ->
  IO InventoryAdapter.Adapter
inventoryCdnAdapter active workspace binding googleSpecs cloudflareSpecs accepted
  | Map.null googleSpecs && Map.null cloudflareSpecs =
      pure (Inventory.executionBlockedAdapterFor ResourceInventory.CdnExecutor)
  | otherwise = do
      google <- inventoryDnsAdapter active workspace binding googleSpecs accepted
      cloudflare <- inventoryCloudflareAdapter active binding cloudflareSpecs accepted
      pure (combineCdnAdapters googleSpecs google cloudflareSpecs cloudflare)

inventoryCloudflareAdapter ::
  ActiveTarget ->
  Resource.ContextBinding ->
  Map.Map Resource.ResourceId CloudflareBinding ->
  Map.Map Resource.ResourceId ResourceInventory.ManagedResource ->
  IO InventoryAdapter.Adapter
inventoryCloudflareAdapter active binding specs accepted
  | Map.null specs = pure (Inventory.executionBlockedAdapterFor ResourceInventory.CdnExecutor)
  | otherwise = do
      context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
      unless
        (context == binding ^. #identity)
        (dieT "Cloudflare inventory review belongs to a different context")
      let zones =
            Set.fromList
              [ zone
              | CloudflareBinding declaration <- Map.elems specs
              , zone <- case declaration ^. #address of
                  Resource.CloudflareDnsRecord selected _ -> [selected]
                  Resource.CloudflareRuleset selected -> [selected]
                  Resource.CloudflareTlsSetting selected -> [selected]
                  _ -> []
              ]
      case Set.toList zones of
        [zone] -> do
          account <- fmap (maybe "" T.pack) (lookupEnv "CF_ACCOUNT_ID")
          let config =
                CloudflareRuntime.CloudflareRuntimeConfig
                  { CloudflareRuntime.cloudflareRuntimeZone = zone
                  , CloudflareRuntime.cloudflareRuntimeAccount = account
                  , CloudflareRuntime.cloudflareRuntimeGuard = \resource -> do
                      currentZone <- lookupEnv "CF_ZONE_ID"
                      currentAccount <- lookupEnv "CF_ACCOUNT_ID"
                      pure $
                        if currentZone == Just (T.unpack (Resource.nameText zone))
                          && currentAccount == Just (T.unpack account)
                          && not (T.null account)
                          && Map.member resource specs
                          then Right ()
                          else Left "Cloudflare zone/account credentials differ from this reviewed context binding"
                  , CloudflareRuntime.cloudflareRuntimeSpecs = specs
                  , CloudflareRuntime.cloudflareRuntimeRequest = \method path body -> do
                      token <- lookupEnv "CF_API_TOKEN"
                      case token of
                        Just apiToken | not (null apiToken) -> cfRequestWithStatus (T.pack apiToken) method path body
                        _ -> pure (Left "CF_API_TOKEN is not set")
                  }
          pure (mkCloudflareAdapter accepted specs (CloudflareRuntime.cloudflareRuntimeOps config))
        _ -> pure (Inventory.executionBlockedAdapterFor ResourceInventory.CdnExecutor)

inventoryBrokerAdapter ::
  ActiveTarget ->
  Resource.ContextBinding ->
  Map.Map Resource.ResourceId TopicBinding ->
  Map.Map Resource.ResourceId ResourceInventory.ManagedResource ->
  IO InventoryAdapter.Adapter
inventoryBrokerAdapter active binding specs accepted
  | Map.null specs = pure (Inventory.executionBlockedAdapterFor ResourceInventory.BrokerExecutor)
  | otherwise = do
      context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
      unless
        (context == binding ^. #identity)
        (dieT "broker topic inventory review belongs to a different context")
      let config =
            BrokerRuntime.TopicRuntimeConfig
              { BrokerRuntime.topicKubectlContext = contextNameText (active ^. #contextName)
              , BrokerRuntime.topicContextGuard = fmap (fmap (const ())) (guardKubernetesContext active)
              , BrokerRuntime.topicRuntimeSpecs = specs
              }
      pure (mkTopicAdapter accepted specs (BrokerRuntime.topicRuntimeOps config))

inventoryArtifactAdapter :: ActiveTarget -> PlatformWorkspace -> Map.Map Resource.ResourceId InventoryArtifact.ArtifactExecutionSpec -> IO InventoryAdapter.Adapter
inventoryArtifactAdapter active workspace specs = do
  hostRoot <- hostConfigDir (active ^. #contextName)
  let config =
        ArtifactRuntimeConfig
          { runtimeArtifactExecutable = workspace ^. #scriptsDir </> "inventory-artifact-transport.sh"
          , runtimeArtifactEnvironment =
              [ ("NAGARE_CONTEXT", T.unpack (contextNameText (active ^. #contextName)))
              , ("NAGARE_HOST_FLAKE", hostRoot)
              ]
          , runtimeArtifactSpecs = specs
          }
  pure (mkArtifactAdapter specs (mkArtifactRuntimeOps config))

hostScopeAccepted :: InventoryPlan.InventoryHistory -> Bool
hostScopeAccepted history = Map.member owner (InventoryPlan.historyAccepted history)
  where
    owner =
      either
        (error . T.unpack)
        (\scope -> scope)
        (Resource.mkScopeId Resource.Platform "host")

inventoryHostAdapter :: ActiveTarget -> PlatformWorkspace -> Bool -> [ResourceInventory.ScopeDeclaration] -> [Resource.ContentDigest] -> IO InventoryAdapter.Adapter
inventoryHostAdapter active workspace accepted _ reviewedDigests = do
  hostName <- readContextHostName (active ^. #contextName) >>= either dieT pure
  hostRoot <- hostConfigDir (active ^. #contextName)
  flake <- BS.readFile (hostRoot </> "flake.nix")
  hostModule <- BS.readFile (hostRoot </> "host.nix")
  lock <- BS.readFile (hostRoot </> "flake.lock")
  let configurationDigest = InventoryDigest.contentDigest (flake <> hostModule)
      lockDigest = InventoryDigest.contentDigest lock
      withoutConfiguration = delete configurationDigest reviewedDigests
      remaining = delete lockDigest withoutConfiguration
  unless
    ( length reviewedDigests `elem` [2, 3]
        && length withoutConfiguration == length reviewedDigests - 1
        && length remaining == length reviewedDigests - 2
    )
    (dieT "reviewed host inputs differ from the selected configuration or lock")
  ageKeyDigest <- case remaining of
    [] -> pure Nothing
    [digest] -> pure (Just digest)
    _ -> dieT "reviewed host inputs have more than one credential digest"
  ageKeyPath <- lookupEnv "NAGARE_HOST_AGE_KEY_FILE"
  context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
  attribute <- either dieT pure (Resource.mkName hostName)
  let profile = active ^. #profile
      config =
        HostRuntimeConfig
          { runtimeHostExecutable = workspace ^. #scriptsDir </> "inventory-host-transport.sh"
          , runtimeHostEnvironment =
              [ ("NAGARE_CONTEXT", T.unpack (contextNameText (active ^. #contextName)))
              , ("NAGARE_HOST_FLAKE", hostRoot)
              ]
                <> maybe [] (\path -> [("NAGARE_HOST_AGE_KEY_FILE", path)]) ageKeyPath
          , runtimeHostContext = context
          , runtimeHostAttribute = attribute
          , runtimeHostProject = profile ^. #project
          , runtimeHostZone = profile ^. #zone
          , runtimeHostInstanceName = profile ^. #instanceName
          , runtimeHostDestination = "deploy@" <> hostName
          , runtimeHostConfigurationDigest = configurationDigest
          , runtimeHostLockDigest = lockDigest
          , runtimeHostAgeKeyDigest = ageKeyDigest
          , runtimeHostAccepted = accepted
          }
  pure (mkHostAdapter (mkHostRuntimeOps config))

inventoryPulumiAdapter :: ActiveTarget -> PlatformWorkspace -> Resource.ContextBinding -> [ResourceInventory.ScopeDeclaration] -> [InventoryCloud.NativeRegistration] -> IO InventoryAdapter.Adapter
inventoryPulumiAdapter active workspace binding scopes registrations = do
  stateRoot <- nagareStateDir
  stackConfig <- contextStackConfigPath (active ^. #contextName)
  stackName <- either dieT pure (Resource.mkName (contextNameText (active ^. #contextName)))
  payloadDigest <- either dieT pure (Resource.mkContentDigest (workspace ^. #digest))
  let profile = active ^. #profile
      context = contextNameText (active ^. #contextName)
      pulumiEnvironment = pulumiEnvFor stateRoot context profile
      cloudOwner =
        either
          (error . T.unpack)
          (\owner -> owner)
          (Resource.mkScopeId Resource.Platform "cloud")
      hasCloudScope = any ((== cloudOwner) . ResourceInventory.scopeId) scopes
  allRegistrations <-
    if profile ^. #mode == Cloud && hasCloudScope
      then do
        (catalogBytes, rawCatalog) <- loadCloudCatalog workspace
        imageLink <-
          foundationImageLink
            active
            (concatMap ResourceInventory.declarations (concatMap ResourceInventory.scopeBundles scopes))
        let catalog =
              InventoryCloud.withCloudInstanceName
                (either (error . T.unpack) (\name -> name) (Resource.mkName (profile ^. #instanceName)))
                rawCatalog
        bookkeeping <-
          either
            dieT
            pure
            ( InventoryCloud.cloudBookkeepingRegistrations
                stackName
                (profile ^. #nixCacheEnabled)
                (isJust imageLink)
                catalog
                (InventoryDigest.contentDigest catalogBytes)
                registrations
            )
        pure (registrations <> bookkeeping)
      else pure registrations
  let declarationBundle =
        InventoryCloud.encodeRegistrationBundle
          (binding ^. #identity)
          (binding ^. #project)
          stackName
          (map ResourceInventory.scopeId scopes)
          allRegistrations
      config =
        PulumiRuntimeConfig
          { runtimeContext = context
          , runtimeProject = profile ^. #project
          , runtimeStack = pulumiEnvironment ^. #stack
          , runtimeBackend = pulumiEnvironment ^. #backendUrl
          , runtimePayloadId = workspace ^. #payloadId
          , runtimePayloadDigest = payloadDigest
          , runtimePulumiExecutable = "pulumi"
          , runtimePulumiDirectory = workspace ^. #pulumiDir
          , runtimeStackConfig = stackConfig
          , runtimeDeclarationBundle = declarationBundle
          , runtimeRegistrations = allRegistrations
          }
  pure (mkPulumiAdapter allRegistrations (mkPulumiRuntimeOps config))
