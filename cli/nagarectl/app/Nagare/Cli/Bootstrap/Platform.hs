-- | Bootstrap / Platform. Executable-private CLI boundary.
module Nagare.Cli.Bootstrap.Platform
  ( buildPlatformCandidate
  )
where

import Control.Monad (forM)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as AesonMap
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Text qualified as T
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Process (currentTimestamp)
import Nagare.Cluster.GcsJob
  ( StoreBackend (GcsBackend, MinioBackend)
  )
import Nagare.Dsl.Prelude
import Nagare.Inventory.Bootstrap
  ( BootstrapInput (BootstrapInput)
  , bootstrapMarkerValue
  , bootstrapPreservedScopeVectorDigest
  , compileBootstrapStamp
  , compileBootstrapWithAuthAndScopes
  , composePlatformChanges
  )
import Nagare.Inventory.Components.Auth
  ( AuthInput (..)
  , AuthMode (..)
  )
import Nagare.Inventory.Components.ControllerImage
  ( compileControllerImage
  )
import Nagare.Inventory.Components.Foundation
  ( FoundationInput (FoundationInput)
  )
import Nagare.Inventory.Components.LocalObjectStore
  ( compileLocalObjectStore
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
  , loadObservabilitySecretObjects
  , readAlertmanagerEnabled
  )
import Nagare.Inventory.Components.PackagedAuth
  ( packagedAuthInputs
  )
import Nagare.Inventory.Components.PackagedCache
  ( compilePackagedCache
  )
import Nagare.Inventory.Components.Upstream
  ( IssuerMode (..)
  , bindHostRegistryCredentials
  , bindNetCertManagerControllerImage
  , configuredUpstreamInputsWithIssuer
  )
import Nagare.Inventory.Database (DatabaseBackupTarget (DatabaseBackupTarget))
import Nagare.Inventory.RegistryCredentials qualified as RegistryCredentials
import Nagare.Platform.Paths (PlatformPaths)
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
  , Mode (Cloud, Local)
  , acmeDirectoryUrl
  , contextNameText
  , parseAcmeDirectory
  , registryPrefix
  , storeBackendFor
  )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

-- Keep payload paths explicit so a fresh context compiles one immutable
-- release against the complete selected inventory snapshot.
buildPlatformCandidate ::
  ActiveTarget ->
  PlatformPaths ->
  PlatformWorkspace ->
  ResourceInventory.ScopeSnapshot ->
  IO
    ( ResourceInventory.CompositionCandidate
    , Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString)
    )
buildPlatformCandidate active paths workspace snapshot = do
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
    configuredUpstreamInputsWithIssuer
      cluster
      root
      (profile ^. #baseDomain)
      (profile ^. #registryHost)
      issuer
      >>= either dieT pure
  credentialUpstream <- case profile ^. #mode of
    Local -> pure rawUpstream
    Cloud -> do
      host <- either dieT pure (RegistryCredentials.registryCredentialHost snapshot cluster)
      maybe
        (pure rawUpstream)
        (\controller -> either dieT pure (bindHostRegistryCredentials controller cluster rawUpstream))
        host
  let controllerRegistry =
        if profile ^. #mode == Local
          then profile ^. #registryHost
          else registryPrefix profile
  (controllerImageScope, controllerImage, controllerPublish) <-
    compileControllerImage root controllerRegistry >>= either (dieT . T.pack . show) pure
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
                  >>= either (dieT . T.pack . show) pure
              )
      else pure Nothing
  authImages <- fmap Map.fromList
    $ forM
      [ ("en", "NAGARE_AUTH_EN_IMAGE")
      , ("shomei", "NAGARE_AUTH_SHOMEI_IMAGE")
      , ("nagare-access", "NAGARE_AUTH_ACCESS_IMAGE")
      ]
    $ \(service, variable) -> do
      value <- lookupEnv variable >>= maybe (dieT ("bootstrap requires " <> T.pack variable <> " as an immutable image reference")) pure
      pure (service, T.pack value)
  backupBackend <- either dieT pure (storeBackendFor profile (profile ^. #backupBucket))
  localStore <- case backupBackend of
    MinioBackend store -> do
      serverImage <- fmap T.pack <$> lookupEnv "NAGARE_LOCAL_MINIO_IMAGE"
      clientImage <- fmap T.pack <$> lookupEnv "NAGARE_LOCAL_MC_IMAGE"
      images <-
        selectLocalMinioImages readLocalRegistryDigest (profile ^. #targetPlatform) serverImage clientImage
          >>= either dieT pure
      Just
        <$> ( compileLocalObjectStore root foundation store images
                >>= either (dieT . T.pack . show) pure
            )
    GcsBackend {} -> pure Nothing
  let authMode = if profile ^. #mode == Local then LocalAuth else CloudAuth
  (rawAuth, authDatabases) <-
    either
      (dieT . T.pack . show)
      pure
      ( packagedAuthInputs
          root
          foundation
          authMode
          (profile ^. #baseDomain)
          authImages
          (DatabaseBackupTarget backupBackend (profile ^. #backupRecoveryPoint))
      )
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
  let auth = rawAuth {authExtraPrerequisites = localPrerequisites}
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
      (BootstrapInput foundation Nothing upstream [controllerImageScope])
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
      nativeMaps = [baseNative, orderedObservabilityNative, extraNative, secretNative, cacheNative, localNative]
      native = Map.unions nativeMaps
  unless
    (Map.size native == sum (map Map.size nativeMaps))
    (dieT "bootstrap component native members share an identity")
  extra <- case orderedObservabilityScopes <> [observabilityExtra, secretScope] <> cacheScopes of
    firstScope : remaining -> pure (ResourceInventory.ReplaceScope firstScope NE.:| map ResourceInventory.ReplaceScope remaining)
    [] -> dieT "pinned bootstrap component set is empty"
  let kubeconfigEdges =
        let owner = either (error . T.unpack) (\scope -> scope) (Resource.mkScopeId Resource.Platform "kubeconfig")
            key = knownKey "context-kubeconfig"
            role = knownName (contextNameText (active ^. #contextName))
         in [ResourceReference.OrderedAfter (Resource.mintResourceId owner key role)]
      orderCluster resource
        | resource ^. #executor `elem` [ResourceInventory.KubernetesExecutor, ResourceInventory.HelmExecutor] =
            resource {ResourceInventory.dependencies = kubeconfigEdges <> resource ^. #dependencies}
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
  installedAt <-
    acceptedBootstrapInstalledAt
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
      (compileBootstrapStamp cluster (bootstrapMarkerValue (manifest ^. #payloadId) vectorDigest (identityFromPayload manifest) installedAt) candidate)
  let differsFromAccepted = \case
        ResourceInventory.ReplaceScope scope -> case Map.lookup
          (ResourceInventory.scopeId scope)
          (ResourceInventory.snapshotScopes snapshot) of
          Just (_, prior) ->
            ResourceWire.encodeCanonicalScope prior
              /= ResourceWire.encodeCanonicalScope scope
          Nothing -> True
        _ -> True
      changedScopes =
        filter
          differsFromAccepted
          (NE.toList (ResourceInventory.candidateChanges candidate))
  stamped <-
    either
      (dieT . T.pack . show)
      pure
      ( composePlatformChanges
          snapshot
          (NE.fromList (changedScopes <> [ResourceInventory.ReplaceScope stampScope]))
      )
  let linkedNative = Map.map (\(resource, bytes) -> (orderCluster resource, bytes)) native
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
    (Map.size completeNative == Map.size native + Map.size stampNative)
    (dieT "bootstrap completion marker shares a native identity")
  pure (stamped, completeNative)

-- Reuse the recorded install time only when it reconstructs the accepted
-- marker's exact desired specification. A changed payload gets a new time;
-- a changed live marker remains visible as drift to the inventory planner.
acceptedBootstrapInstalledAt ::
  ActiveTarget ->
  ResourceInventory.ScopeSnapshot ->
  Resource.ResourceId ->
  Text ->
  Resource.ContentDigest ->
  ReleaseIdentity ->
  ResourceInventory.CompositionCandidate ->
  IO Text
acceptedBootstrapInstalledAt active snapshot cluster payloadId vectorDigest identity candidate = do
  now <- currentTimestamp
  let owner =
        either
          (error . T.unpack)
          (\scope -> scope)
          (Resource.mkScopeId Resource.Platform "bootstrap-stamp")
      acceptedSpecs =
        [ resource ^. #spec
        | Just (_, scope) <- [Map.lookup owner (ResourceInventory.snapshotScopes snapshot)]
        , bundle <- ResourceInventory.scopeBundles scope
        , ResourceInventory.Managed resource <- ResourceInventory.declarations bundle
        ]
  case acceptedSpecs of
    [acceptedSpec] -> do
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
      case Aeson.eitherDecodeStrict' (BC.pack output) :: Either String Aeson.Value of
        Right (Aeson.Object live) -> case AesonMap.lookup "data" live of
          Just (Aeson.Object fields) -> case AesonMap.lookup "installedAt" fields of
            Just (Aeson.String installedAt) | not (T.null installedAt) -> do
              let expected =
                    compileBootstrapStamp
                      cluster
                      (bootstrapMarkerValue payloadId vectorDigest identity installedAt)
                      candidate
              pure $ case expected of
                Right (_, native) | any ((== acceptedSpec) . (^. #spec) . fst) (Map.elems native) -> installedAt
                _ -> now
            _ -> pure now
          _ -> pure now
        _ -> pure now
    _ -> pure now

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
