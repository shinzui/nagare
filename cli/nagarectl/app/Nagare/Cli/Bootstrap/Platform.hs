-- | Bootstrap / Platform. Executable-private CLI boundary.
module Nagare.Cli.Bootstrap.Platform
  ( buildPlatformCandidate
  )
where

import Control.Monad (forM, forM_)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as AesonMap
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Text qualified as T
import Nagare.Cli.Move.Carry (withGrantedMovedRoutes)
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Posture (ActivePosture)
import Nagare.Cli.Runtime.Process (currentTimestamp)
import Nagare.Cluster.GcsJob
  ( StoreBackend (GcsBackend, MinioBackend)
  )
import Nagare.Context.Posture (publishesConnector)
import Nagare.Contract.ReleaseImages (ReleaseImageKey (..), ReleaseImages, releaseImageKeyText)
import Nagare.Dsl.Prelude
import Nagare.Inventory.BackendMap (issuerPortalRefusal)
import Nagare.Inventory.Bootstrap
  ( BootstrapInput (BootstrapInput)
  , bootstrapMarkerFor
  , bootstrapPreservedScopeVectorDigest
  , changedPlatformScopes
  , compileBootstrapStamp
  , compileBootstrapWithAuthAndScopes
  , composePlatformChanges
  , withLeadingDependencies
  )
import Nagare.Inventory.Components.AdminApi
import Nagare.Inventory.Components.Auth
  ( AuthInput (..)
  , AuthMode (..)
  )
import Nagare.Inventory.Components.AuthTenants (EnTenant (EnTenant), retiredEnTenants)
import Nagare.Inventory.Components.CloudflareTunnel
  ( CloudflareTunnelInput (..)
  , cloudflareTunnelTokenSecretFile
  , compileCloudflareTunnel
  )
import Nagare.Inventory.Components.ControllerImage
  ( compileControllerImage
  )
import Nagare.Inventory.Components.Foundation
  ( FoundationInput (FoundationInput)
  )
import Nagare.Inventory.Components.LifecycleEvents
  ( LifecycleEventsInput (..)
  , LifecycleStore (..)
  , compileLifecycleEvents
  , lifecycleWorkerSecretFile
  , signingSecretNames
  )
import Nagare.Inventory.Components.LocalObjectStore
  ( LocalMinioImages
  , compileLocalObjectStore
  , readLocalRegistryDigest
  , selectLocalMinioImages
  )
import Nagare.Inventory.Components.Observability
  ( PackagedHelmInput (..)
  , compilePinnedObservability
  , pinnedObservabilityInputs
  )
import Nagare.Inventory.Components.ObservabilityExtras
  ( compileObservabilityExtras
  )
import Nagare.Inventory.Components.ObservabilitySecrets
  ( compileObservabilitySecrets
  , loadContextSecretObject
  , loadObservabilitySecretObjects
  , readAlertmanagerEnabled
  )
import Nagare.Inventory.Components.PackagedAuth
  ( packagedAuthInputsWithTenants
  )
import Nagare.Inventory.Components.PackagedCache
  ( compilePackagedCache
  )
import Nagare.Inventory.Components.ReleaseImage (compileReleaseImages)
import Nagare.Inventory.Components.Upstream
  ( IssuerMode (..)
  , bindHostRegistryCredentials
  , bindNetCertManagerControllerImage
  , configuredUpstreamInputsWithIssuer
  , postureUpstreamInputs
  )
import Nagare.Inventory.Database (DatabaseBackupTarget (DatabaseBackupTarget))
import Nagare.Inventory.RegistryCredentials qualified as RegistryCredentials
import Nagare.Platform.Paths (PlatformPaths)
import Nagare.Platform.ReleaseImages (ImageSource (ReleaseSource), renderImageSelectionError, selectImage)
import Nagare.Platform.Status
  ( ReleaseIdentity
  , identityFromPayload
  )
import Nagare.Platform.Workspace
  ( PlatformWorkspace
  , readPayloadManifest
  , renderWorkspaceError
  )
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Reference qualified as ResourceReference
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire qualified as ResourceWire
import Nagare.Target
  ( ActiveTarget
  , IngressMode (IngressCloudflareTunnel)
  , InventoryStoreKind (InventoryStoreGcs)
  , Mode (Cloud, Local)
  , TargetProfile
  , acmeDirectoryUrl
  , contextFilePath
  , contextNameText
  , defaultGcsInventoryStoreUrl
  , effectiveInventoryStore
  , parseAcmeDirectory
  , registryPrefix
  , storeBackendFor
  )
import Nagare.Target.AuthIssuer (authIssuerText)
import Nagare.Target.EnTenants (readEnTenantSchema)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

-- Keep payload paths explicit so a fresh context compiles one immutable
-- release against the complete selected inventory snapshot.
buildPlatformCandidate ::
  ActivePosture ->
  ActiveTarget ->
  PlatformPaths ->
  PlatformWorkspace ->
  ResourceInventory.ScopeSnapshot ->
  IO
    ( ResourceInventory.CompositionCandidate
    , Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString)
    )
buildPlatformCandidate current active paths workspace snapshot = do
  manifest <- readPayloadManifest paths >>= either (dieT . renderWorkspaceError) pure
  unless
    ( manifest ^. #payloadId == workspace ^. #payloadId
        && manifest ^. #platformVersion == workspace ^. #platformVersion
    )
    (dieT "platform candidate payload and retained workspace identities disagree")
  unless
    (active ^. #profile . #platformVersion == Just (manifest ^. #platformVersion))
    (dieT "platform bootstrap requires a context pin matching the selected payload; in-place platform version changes require a separate reviewed transition")
  kubeVersion <- readBootstrapKubeVersion active
  let ingress = current ^. #posture
  let root = workspace ^. #root
      profile = active ^. #profile
      knownName value = either (error . T.unpack) (\name -> name) (Resource.mkName value)
      knownKey value = either (error . T.unpack) (\key -> key) (Resource.mkLogicalKey value)
      foundationOwner = either (error . T.unpack) (\scope -> scope) (Resource.mkScopeId Resource.Platform "foundation")
      clusterOwner = either (error . T.unpack) (\scope -> scope) (Resource.mkScopeId Resource.Platform "cluster")
      cluster = Resource.mintResourceId clusterOwner (knownKey "cluster") (knownName "cluster")
      observabilityInputs = pinnedObservabilityInputs cluster root kubeVersion
      granted = map packagedOwner observabilityInputs
      foundation =
        FoundationInput
          foundationOwner
          cluster
          (root </> "cluster/bootstrap/job-runs/resourcequota.yaml")
          granted
      -- EP-243: an open move turns on the connector, flat names and a closed kourier one step at a time.
      connectorMode = publishesConnector ingress (Map.member tunnelOwner (ResourceInventory.snapshotScopes snapshot))
      tunnelOwner = either (error . T.unpack) (\scope -> scope) (Resource.mkScopeId Resource.Platform "cloudflare-tunnel")
      issuer = case profile ^. #mode of
        Local -> LocalIssuer
        Cloud ->
          CloudIssuer
            (either (error . T.unpack) (acmeDirectoryUrl) (parseAcmeDirectory (profile ^. #acmeDirectory)))
            (profile ^. #acmeEmail)
            (profile ^. #project)
            (profile ^. #externalDomainTlsEnabled)
  when
    (profile ^. #mode == Cloud && T.null (profile ^. #acmeEmail))
    (dieT "bootstrap requires the selected context's ACME contact")
  when
    (profile ^. #mode == Local && profile ^. #nixCacheEnabled)
    (dieT "Attic cache is available only in cloud bootstrap mode")
  when
    (profile ^. #mode == Local && profile ^. #externalDomainTlsEnabled)
    (dieT "external domain TLS belongs to cloud bootstrap; local TLS is enabled by its own issuer")
  rawUpstream <-
    postureUpstreamInputs ingress
      <$> ( configuredUpstreamInputsWithIssuer
              cluster
              root
              (profile ^. #baseDomain)
              (profile ^. #registryHost)
              issuer
              >>= either dieT pure
          )
  credentialUpstream <- case profile ^. #mode of
    Local -> pure rawUpstream
    Cloud -> do
      host <- either dieT pure (RegistryCredentials.registryCredentialHost snapshot cluster)
      maybe
        (pure rawUpstream)
        (\controller -> either dieT pure (bindHostRegistryCredentials controller cluster rawUpstream))
        host
  (controllerImageScope, controllerImage, controllerPublish) <-
    compileControllerImage root (contextImageRegistry profile) >>= either (dieT . T.pack . show) pure
  upstream <-
    either
      dieT
      pure
      (bindNetCertManagerControllerImage cluster controllerImage controllerPublish credentialUpstream)
  metricsInput <- case observabilityInputs of
    firstRelease : _
      | Resource.nameText (packagedName firstRelease) == "vmks" ->
          pure firstRelease
    _ -> dieT "pinned observability components have no metrics release"
  alertmanagerEnabled <-
    readAlertmanagerEnabled
      (packagedValues metricsInput)
      (packagedValuesDigest metricsInput)
      >>= either dieT pure
  secretObjects <-
    loadObservabilitySecretObjects
      root
      (contextNameText (active ^. #contextName))
      alertmanagerEnabled
      >>= either dieT pure
  (secretScope, secretNative, secretIds) <-
    compileObservabilitySecrets foundation secretObjects
      >>= either (dieT . T.pack . show) pure
  let orderedObservability = case observabilityInputs of
        firstRelease : rest ->
          firstRelease
            { packagedDependencies =
                map ResourceReference.OrderedAfter secretIds
                  <> packagedDependencies firstRelease
            }
            : rest
        [] -> []
  (observabilityScopes, observabilityNative) <-
    compilePinnedObservability foundationOwner orderedObservability
      >>= either (dieT . T.pack . show) pure
  let metricsRelease = packagedReleaseId metricsInput
  (observabilityExtra, extraNative) <-
    compileObservabilityExtras root foundation metricsRelease
      >>= either (dieT . T.pack . show) pure
  cacheComponent <-
    if profile ^. #nixCacheEnabled
      then
        Just
          <$> ( compilePackagedCache
                  root
                  foundation
                  (profile ^. #project)
                  (registryPrefix profile)
                  (profile ^. #backupBucket)
                  (profile ^. #backupRecoveryPoint)
                  (profile ^. #nixCacheBucket)
                  (profile ^. #nixCacheNarSizeThreshold)
                  >>= either (dieT . T.pack . show) pure
              )
      else pure Nothing
  -- EP-237: an explicit override, else the target payload's release image.
  authImages <- fmap Map.fromList $
    forM [EnImage, ShomeiImage, AccessImage] $
      \key -> do
        selection <- selectImage (contextImageRegistry profile) (manifest ^. #releaseImages) key >>= either (dieT . renderImageSelectionError) pure
        pure (releaseImageKeyText key, selection)
  -- EP-237: a payload that names images publishes the context's enabled ones.
  releaseImages <-
    either
      (dieT . T.pack . show)
      pure
      ( traverse
          (compileReleaseImages (contextImageRegistry profile) ([EnImage, ShomeiImage, AccessImage] <> [AdminApiImage | profile ^. #adminApiEnabled || profile ^. #lifecycleEventsEnabled] <> [CloudflaredImage | connectorMode]))
          (manifest ^. #releaseImages)
      )
  let releaseImagePublications = maybe Map.empty snd releaseImages
      authImagePublications' =
        Map.fromList
          [ (releaseImageKeyText key, publication)
          | (key, publication) <- Map.toList releaseImagePublications
          , Just selection <- [Map.lookup (releaseImageKeyText key) authImages]
          , selection ^. #source == ReleaseSource
          ]
  backupBackend <- either dieT pure (storeBackendFor profile (profile ^. #backupBucket))
  minioImages <- case backupBackend of
    MinioBackend _ -> do
      serverImage <- fmap T.pack <$> lookupEnv "NAGARE_LOCAL_MINIO_IMAGE"
      clientImage <- fmap T.pack <$> lookupEnv "NAGARE_LOCAL_MC_IMAGE"
      Just
        <$> ( selectLocalMinioImages readLocalRegistryDigest (profile ^. #targetPlatform) serverImage clientImage
                >>= either dieT pure
            )
    GcsBackend {} -> pure Nothing
  localStore <- case (backupBackend, minioImages) of
    (MinioBackend store, Just images) ->
      Just
        <$> ( compileLocalObjectStore root foundation store images
                >>= either (dieT . T.pack . show) pure
            )
    _ -> pure Nothing
  let authMode = if profile ^. #mode == Local then LocalAuth else CloudAuth
  -- EP-262: the operator's En tenants, each with its schema file's bytes. A
  -- tenant the accepted auth scope holds stays declared.
  contextFile <- contextFilePath (active ^. #contextName)
  enTenants <- forM (profile ^. #enTenants) $ \tenant ->
    EnTenant (tenant ^. #name) <$> (readEnTenantSchema contextFile tenant >>= either dieT pure)
  let authOwner = either (error . T.unpack) (\scope -> scope) (Resource.mkScopeId Resource.Platform "auth")
  forM_ (Map.lookup authOwner (ResourceInventory.snapshotScopes snapshot)) $ \(_, accepted) ->
    case retiredEnTenants accepted (map (\(EnTenant name _) -> name) enTenants) of
      [] -> pure ()
      removed : _ ->
        dieT ("En tenant " <> removed <> " is no longer in NAGARE_EN_TENANTS; its database and keys are protected, so removing a tenant is refused. Declare it again.")
  (packagedAuth, authDatabases) <-
    either
      (dieT . T.pack . show)
      pure
      ( packagedAuthInputsWithTenants
          root
          foundation
          authMode
          (profile ^. #baseDomain)
          authImages
          (DatabaseBackupTarget backupBackend (profile ^. #backupRecoveryPoint))
          enTenants
      )
  -- EP-264: the issuer is the registered portal's origin, so the plan that
  -- turns OIDC on is refused until the accepted inventory has that portal.
  forM_ (profile ^. #authIssuer) $ \_ -> do
    accepted <- either (dieT . T.pack . show) (pure . ResourceInventory.inventoryDeclarations) (ResourceInventory.composeSnapshot snapshot)
    forM_ (issuerPortalRefusal True (profile ^. #authIssuer) accepted) dieT
  let rawAuth =
        packagedAuth
          { authProxiedCacheControl =
              if connectorMode then Just "private, no-store, no-transform" else Nothing
          , authIssuer = authIssuerText <$> profile ^. #authIssuer
          }
  localPrerequisites <- case localStore of
    Nothing -> pure []
    Just (_, members) -> case [ resource ^. #identity
                              | (resource, _) <- Map.elems members
                              , case resource ^. #address of
                                  Resource.Kubernetes _ "batch" kind _ name ->
                                    Resource.nameText kind == "job" && Resource.nameText name == "minio-make-bucket"
                                  _ -> False
                              ] of
      [bucketJob] -> pure [bucketJob]
      _ -> dieT "local object store has no unique bucket preparation Job"
  let auth = rawAuth {authExtraPrerequisites = localPrerequisites, authImagePublications = authImagePublications'}
  -- The accepted completion marker depends on the previous resource set. Build
  -- the new set without that marker, then replace the marker in the final
  -- composition against the unmodified snapshot.
  let stampOwner =
        either
          (error . T.unpack)
          (\scope -> scope)
          (Resource.mkScopeId Resource.Platform "bootstrap-stamp")
      unstampedSnapshot =
        either
          (error . show)
          (\loaded -> loaded)
          ( ResourceInventory.mkScopeSnapshot
              (ResourceInventory.snapshotBinding snapshot)
              (Map.delete stampOwner (ResourceInventory.snapshotScopes snapshot))
              (ResourceInventory.snapshotReservations snapshot)
          )
  (base, baseNative) <-
    compileBootstrapWithAuthAndScopes
      unstampedSnapshot
      (BootstrapInput foundation Nothing upstream (controllerImageScope : maybe [] (pure . fst) releaseImages))
      auth
      authDatabases
      (maybe [] (pure . fst) localStore)
      >>= either (dieT . T.pack . show) pure
  let certManagerOwner = either (error . T.unpack) (\scope -> scope) (Resource.mkScopeId Resource.Platform "cert-manager")
      certManagerIds =
        [ resource ^. #identity
        | ResourceInventory.Managed resource <- ResourceInventory.inventoryDeclarations (ResourceInventory.candidateInventory base)
        , resource ^. #owner == certManagerOwner
        ]
      orderHelm resource
        | resource ^. #executor == ResourceInventory.HelmExecutor =
            resource
              { ResourceInventory.dependencies =
                  map ResourceReference.OrderedAfter certManagerIds
                    <> resource ^. #dependencies
              }
        | otherwise = resource
      orderDeclaration = \case
        ResourceInventory.Managed resource -> ResourceInventory.Managed (orderHelm resource)
        other -> other
      orderScope scope =
        ResourceInventory.mkScopeDeclaration
          (ResourceInventory.scopeId scope)
          [ bundle {ResourceInventory.declarations = map orderDeclaration (ResourceInventory.declarations bundle)}
          | bundle <- ResourceInventory.scopeBundles scope
          ]
  orderedObservabilityScopes <-
    either
      (dieT . T.pack . show)
      pure
      (traverse orderScope observabilityScopes)
  let orderedObservabilityNative = Map.map (\(resource, bytes) -> (orderHelm resource, bytes)) observabilityNative
      (cacheScopes, cacheNative) = case cacheComponent of
        Nothing -> ([], Map.empty)
        Just (imageScope, cacheScope, native) -> ([imageScope, cacheScope], native)
      localNative = maybe Map.empty snd localStore
  adminApi <-
    if profile ^. #adminApiEnabled
      then
        Just
          <$> compilePlatformAdminApi
            active
            (manifest ^. #releaseImages)
            (Map.lookup AdminApiImage releaseImagePublications)
            root
            foundation
            (ResourceInventory.inventoryDeclarations (ResourceInventory.candidateInventory base))
      else pure Nothing
  let (adminApiScopes, adminApiNative) = maybe ([], Map.empty) (\(scope, members) -> ([scope], members)) adminApi
  lifecycleEvents <-
    if profile ^. #lifecycleEventsEnabled
      then
        Just
          <$> compilePlatformLifecycleEvents
            active
            (manifest ^. #releaseImages)
            (Map.lookup AdminApiImage releaseImagePublications)
            root
            foundation
            backupBackend
            minioImages
            snapshot
      else pure Nothing
  let (lifecycleScopes, lifecycleNative) = maybe ([], Map.empty) (\(scope, members) -> ([scope], members)) lifecycleEvents
  tunnel <-
    if connectorMode
      then
        Just
          <$> compilePlatformCloudflareTunnel
            active
            (manifest ^. #releaseImages)
            (Map.lookup CloudflaredImage releaseImagePublications)
            root
            foundation
            metricsRelease
      else pure Nothing
  let (tunnelScopes, tunnelNative) = maybe ([], Map.empty) (\(scope, members) -> ([scope], members)) tunnel
      nativeMaps = [baseNative, orderedObservabilityNative, extraNative, secretNative, cacheNative, localNative, adminApiNative, lifecycleNative, tunnelNative]
      native = Map.unions nativeMaps
  unless
    (Map.size native == sum (map Map.size nativeMaps))
    (dieT "bootstrap component native members share an identity")
  -- EP-246 D5: during a move to a new base, the admin API keeps its old route while grants name it.
  carriedAdminApi <- traverse (\scope -> withGrantedMovedRoutes active snapshot (scope, Map.empty)) adminApiScopes
  let carriedAdminApiScopes = map fst carriedAdminApi
      nativeWithRoutes = Map.union native (Map.unions (map snd carriedAdminApi))
  extra <- case orderedObservabilityScopes <> [observabilityExtra, secretScope] <> cacheScopes <> carriedAdminApiScopes <> lifecycleScopes <> tunnelScopes of
    firstScope : remaining -> pure (ResourceInventory.ReplaceScope firstScope NE.:| map ResourceInventory.ReplaceScope remaining)
    [] -> dieT "pinned bootstrap component set is empty"
  let kubeconfigEdges =
        let owner = either (error . T.unpack) (\scope -> scope) (Resource.mkScopeId Resource.Platform "kubeconfig")
            key = knownKey "context-kubeconfig"
            role = knownName (contextNameText (active ^. #contextName))
         in [ResourceReference.OrderedAfter (Resource.mintResourceId owner key role)]
      orderCluster resource
        | resource ^. #executor `elem` [ResourceInventory.KubernetesExecutor, ResourceInventory.HelmExecutor] =
            withLeadingDependencies kubeconfigEdges resource
        | otherwise = resource
      orderClusterDeclaration = \case
        ResourceInventory.Managed resource -> ResourceInventory.Managed (orderCluster resource)
        other -> other
      orderClusterScope scope =
        ResourceInventory.mkScopeDeclaration
          (ResourceInventory.scopeId scope)
          [ bundle {ResourceInventory.declarations = map orderClusterDeclaration (ResourceInventory.declarations bundle)}
          | bundle <- ResourceInventory.scopeBundles scope
          ]
      orderClusterChange = \case
        ResourceInventory.ReplaceScope scope -> ResourceInventory.ReplaceScope <$> orderClusterScope scope
        other -> Right other
  linkedChanges <-
    either
      (dieT . T.pack . show)
      pure
      (traverse orderClusterChange (ResourceInventory.candidateChanges base <> extra))
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeInventory unstampedSnapshot linkedChanges)
  vectorDigest <- either dieT pure (bootstrapPreservedScopeVectorDigest snapshot candidate)
  marker <-
    acceptedBootstrapMarker
      active
      snapshot
      cluster
      (manifest ^. #payloadId)
      vectorDigest
      (identityFromPayload manifest)
      candidate
  (stampScope, stampNative) <-
    either
      (dieT . T.pack . show)
      pure
      (compileBootstrapStamp cluster marker candidate)
  -- EP-225: a scope whose deployment meaning is accepted stays accepted, its
  -- revision and bytes unchanged, whatever workspace this release compiled from.
  let changedScopes = changedPlatformScopes snapshot (NE.toList (ResourceInventory.candidateChanges candidate))
  stamped <-
    either
      (dieT . T.pack . show)
      pure
      ( composePlatformChanges
          snapshot
          (NE.fromList (changedScopes <> [ResourceInventory.ReplaceScope stampScope]))
      )
  let linkedNative = Map.map (\(resource, bytes) -> (orderCluster resource, bytes)) nativeWithRoutes
      composedMembers =
        Map.fromList
          [ (resource ^. #identity, resource)
          | ResourceInventory.Managed resource <-
              ResourceInventory.inventoryDeclarations
                (ResourceInventory.candidateInventory stamped)
          ]
      completeNative =
        Map.mapWithKey
          ( \resourceId (resource, bytes) ->
              (Map.findWithDefault resource resourceId composedMembers, bytes)
          )
          (Map.union linkedNative stampNative)
  unless
    (Map.size completeNative == Map.size nativeWithRoutes + Map.size stampNative)
    (dieT "bootstrap completion marker shares a native identity")
  pure (stamped, completeNative)

-- The marker this plan declares ('bootstrapMarkerFor'): the live one, kept
-- when no platform scope moved (MasterPlan 37 D1), or this payload's. A
-- changed live marker that reconstructs nothing remains visible as drift to
-- the inventory planner.
acceptedBootstrapMarker ::
  ActiveTarget ->
  ResourceInventory.ScopeSnapshot ->
  Resource.ResourceId ->
  Text ->
  Resource.ContentDigest ->
  ReleaseIdentity ->
  ResourceInventory.CompositionCandidate ->
  IO Aeson.Value
acceptedBootstrapMarker active snapshot cluster payloadId vectorDigest identity candidate = do
  now <- currentTimestamp
  let owner =
        either
          (error . T.unpack)
          (\scope -> scope)
          (Resource.mkScopeId Resource.Platform "bootstrap-stamp")
      acceptedStamp = snd <$> Map.lookup owner (ResourceInventory.snapshotScopes snapshot)
  live <- case acceptedStamp of
    Nothing -> pure Nothing
    Just _ -> do
      (code, output, err) <-
        readProcessWithExitCode
          "kubectl"
          [ "--context"
          , T.unpack (contextNameText (active ^. #contextName))
          , "-n"
          , "nagare-system"
          , "get"
          , "configmap"
          , "nagare-platform-version"
          , "-o"
          , "json"
          , "--ignore-not-found"
          ]
          ""
      unless
        (code == ExitSuccess)
        (dieT ("could not inspect accepted bootstrap marker: " <> T.pack err))
      pure (Just (BC.pack output))
  pure (bootstrapMarkerFor cluster candidate acceptedStamp live payloadId vectorDigest identity now)

readBootstrapKubeVersion :: ActiveTarget -> IO Text
readBootstrapKubeVersion active = do
  guardKubernetesContext active >>= either dieT pure
  (code, output, err) <-
    readProcessWithExitCode
      "kubectl"
      ["--context", T.unpack (contextNameText (active ^. #contextName)), "version", "-o", "json"]
      ""
  unless (code == ExitSuccess) (dieT ("could not inspect selected Kubernetes version: " <> T.pack err))
  value <- either (dieT . T.pack) pure (Aeson.eitherDecodeStrict' (BC.pack output) :: Either String Aeson.Value)
  case value of
    Aeson.Object root -> case AesonMap.lookup "serverVersion" root of
      Just (Aeson.Object server) -> case AesonMap.lookup "gitVersion" server of
        Just (Aeson.String version) | not (T.null version) -> pure version
        _ -> dieT "Kubernetes server version has no gitVersion"
      _ -> dieT "Kubernetes version response has no serverVersion"
    _ -> dieT "Kubernetes version response is not an object"

-- | The registry prefix a context's own published images live under: the
-- patched controller's and the release images' (EP-237).
contextImageRegistry :: TargetProfile -> Text
contextImageRegistry profile
  | profile ^. #mode == Local = profile ^. #registryHost
  | otherwise = registryPrefix profile

-- | The opt-in admin API scope (EP-198). Its image is the payload's release
-- image unless NAGARE_ADMIN_API_IMAGE overrides it (EP-237). A cloud context serves its GCS inventory through the
-- reader Secret in its cluster-secrets directory; a cloud context whose store
-- is still on a workstation must migrate it first, and a local context reads
-- the store its substrate mounts.
compilePlatformCloudflareTunnel ::
  ActiveTarget ->
  Maybe ReleaseImages ->
  Maybe Resource.ResourceId ->
  FilePath ->
  FoundationInput ->
  Resource.ResourceId ->
  IO (ResourceInventory.ScopeDeclaration, Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, BC.ByteString))
compilePlatformCloudflareTunnel active releaseImages publication root foundation metricsRelease = do
  image <- selectImage (contextImageRegistry (active ^. #profile)) releaseImages CloudflaredImage >>= either (dieT . renderImageSelectionError) pure
  token <-
    loadContextSecretObject root (contextNameText (active ^. #contextName)) "Cloudflare tunnel token" cloudflareTunnelTokenSecretFile
      >>= either (\reason -> dieT (reason <> "\nrun `nagarectl tunnel token` to save it, then plan again")) pure
  compileCloudflareTunnel
    CloudflareTunnelInput
      { root = root
      , foundation = foundation
      , image = image
      , imagePublication = publication
      , tokenSecret = token
      , metricsRelease = metricsRelease
      }
    >>= either (dieT . T.pack . show) pure

compilePlatformAdminApi ::
  ActiveTarget ->
  Maybe ReleaseImages ->
  Maybe Resource.ResourceId ->
  FilePath ->
  FoundationInput ->
  [ResourceInventory.Declaration] ->
  IO (ResourceInventory.ScopeDeclaration, Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString))
compilePlatformAdminApi active releaseImages publication root foundation declarations = do
  let profile = active ^. #profile
      context = contextNameText (active ^. #contextName)
  image <- selectImage (contextImageRegistry profile) releaseImages AdminApiImage >>= either (dieT . renderImageSelectionError) pure
  store <- case profile ^. #mode of
    Local -> pure LocalMountedStore
    Cloud -> do
      unless
        (effectiveInventoryStore profile == InventoryStoreGcs)
        (dieT "the admin API serves a cloud context's GCS inventory; migrate this context's workstation store with `nagarectl inventory store migrate` first")
      reader <-
        loadContextSecretObject root context "admin API reader" adminApiReaderSecretFile
          >>= either dieT pure
      let url =
            if T.null (profile ^. #inventoryStoreUrl)
              then defaultGcsInventoryStoreUrl context profile
              else profile ^. #inventoryStoreUrl
      pure (CloudReaderStore url (profile ^. #projectNumber) reader)
  compileAdminApi
    AdminApiInput
      { root = root
      , foundation = foundation
      , baseDomain = profile ^. #baseDomain
      , context = context
      , project = profile ^. #project
      , image = image
      , imagePublication = publication
      , store = store
      }
    declarations
    >>= either (dieT . T.pack . show) pure

-- | The opt-in lifecycle event worker scope (EP-235). Its image is the admin
-- API's: the worker is a second executable of the same package. A local
-- context reads the in-cluster object store through a read-only user the
-- store's client image grants; a cloud context reads its GCS inventory and
-- backup bucket through the worker key Secret in its cluster-secrets
-- directory, and one whose store is still on a workstation must migrate it
-- first. The worker may read the signing Secrets of the accepted schedules
-- and subscriptions, and sends only when the context enables delivery.
compilePlatformLifecycleEvents ::
  ActiveTarget ->
  Maybe ReleaseImages ->
  Maybe Resource.ResourceId ->
  FilePath ->
  FoundationInput ->
  StoreBackend ->
  Maybe LocalMinioImages ->
  ResourceInventory.ScopeSnapshot ->
  IO (ResourceInventory.ScopeDeclaration, Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString))
compilePlatformLifecycleEvents active releaseImages publication root foundation backupBackend minioImages snapshot = do
  let profile = active ^. #profile
      context = contextNameText (active ^. #contextName)
  image <- selectImage (contextImageRegistry profile) releaseImages AdminApiImage >>= either (dieT . renderImageSelectionError) pure
  store <- case (profile ^. #mode, backupBackend, minioImages) of
    (Local, MinioBackend ref, Just images) -> pure (LocalLifecycle (ref ^. #endpoint) (ref ^. #bucket) (images ^. #client))
    (Local, _, _) -> dieT "the lifecycle event worker in a local context reads the in-cluster object store; set NAGARE_LOCAL_OBJECT_STORE"
    (Cloud, _, _) -> do
      unless
        (effectiveInventoryStore profile == InventoryStoreGcs)
        (dieT "the lifecycle event worker reads a cloud context's GCS inventory; migrate this context's workstation store with `nagarectl inventory store migrate` first")
      worker <-
        loadContextSecretObject root context "lifecycle worker key" lifecycleWorkerSecretFile
          >>= either dieT pure
      let url =
            if T.null (profile ^. #inventoryStoreUrl)
              then defaultGcsInventoryStoreUrl context profile
              else profile ^. #inventoryStoreUrl
      pure (CloudLifecycle url (profile ^. #projectNumber) (profile ^. #backupBucket) worker)
  compileLifecycleEvents
    LifecycleEventsInput
      { root = root
      , foundation = foundation
      , context = context
      , project = profile ^. #project
      , image = image
      , imagePublication = publication
      , store = store
      , delivery = profile ^. #lifecycleDelivery
      , signingSecrets = signingSecretNames snapshot
      }
    >>= either (dieT . T.pack . show) pure
