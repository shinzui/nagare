-- | Compose cluster bootstrap components before observation or mutation.
-- Generated native members stay in memory until the review retains them.
module Nagare.Inventory.Bootstrap
  ( BootstrapInput (..)
  , compileBootstrapCandidate
  , compilePinnedBootstrap
  , compileConfiguredBootstrap
  , compileIssuerBootstrap
  , compileBootstrapWithAuth
  , compileBootstrapWithAuthAndScopes
  , compileBootstrapStamp
  ) where

import Data.ByteString (ByteString)
import Data.Aeson (Value)
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Nagare.Dsl.Prelude
import Nagare.Cluster.GcsJob (StoreBackend)
import Nagare.Inventory.Cache
import Nagare.Inventory.Components.Auth
import Nagare.Inventory.Components.Foundation
import Nagare.Inventory.Components.Upstream
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Database (DatabaseDirectInput (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (Retain), Sensitivity (Public))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data BootstrapInput = BootstrapInput
  { bootstrapFoundation :: !FoundationInput
  , bootstrapCache :: !(Maybe (DatabaseDirectInput, StoreBackend, CacheRenderInput))
  , bootstrapUpstream :: ![UpstreamInput]
  , bootstrapAdditionalScopes :: ![ScopeDeclaration]
  }

-- | The release marker is a reviewed direct object whose creation waits for
-- every bootstrap resource and declared operation to verify. Its timestamp is
-- captured at plan time in the retained native member.
compileBootstrapStamp
  :: ResourceId -> Value -> CompositionCandidate
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileBootstrapStamp cluster marker candidate = do
  bytes <- first single (canonicalValue marker)
  let owner = knownScope "bootstrap-stamp"
      resourceId = mintResourceId owner (knownKey "bootstrap") (knownName "version")
      source = SourceLocation "generated:bootstrap" "platform-version"
      input = KubernetesInput resourceId owner cluster marker (contentDigest bytes)
        Retain Stateless Public source
      resources = [resource ^. #identity | Managed resource <- inventoryDeclarations
        (candidateInventory candidate), resource ^. #identity /= resourceId]
      operations = [operation ^. #identity | scope <- Map.elems (inventoryScopes
        (candidateInventory candidate)), bundle <- scopeBundles scope,
        operation <- bundle ^. #operations]
  (compiled, bound) <- first (:| []) (bindKubernetesObject input)
  unless (compiled ^. #address == Kubernetes cluster "" (knownName "configmap")
      (Just (knownName "nagare-system")) (knownName "nagare-platform-version")
      && bound == bytes)
    (Left (single "release marker has an unexpected Kubernetes address or bytes"))
  let resource = compiled {dependencies = sortOn show (map OrderedAfter (resources <> operations))}
  scope <- mkScopeDeclaration owner [ResourceBundle [Managed resource] [] [] [] [] []]
  pure (scope, Map.singleton resourceId (resource, bound))
  where
    single message = inventoryError "invalid-bootstrap-stamp" message :| []
    knownScope = either (error . show) id . mkScopeId Platform
    knownKey = either (error . show) id . mkLogicalKey
    knownName = either (error . show) id . mkName

-- | Compile the payload's complete pinned operator release set with the
-- foundation and optional cache. Other context-specific components join this
-- input before the public bootstrap command can replace the legacy recipe.
compilePinnedBootstrap
  :: ScopeSnapshot
  -> FoundationInput
  -> Maybe (DatabaseDirectInput, StoreBackend, CacheRenderInput)
  -> FilePath
  -> IO (Either (NonEmpty InventoryError)
       (CompositionCandidate, Map ResourceId (ManagedResource, ByteString)))
compilePinnedBootstrap snapshot foundation cache root =
  compileBootstrapCandidate snapshot (BootstrapInput foundation cache
    (pinnedUpstreamInputs (foundationCluster foundation) root) [])

compileConfiguredBootstrap
  :: ScopeSnapshot
  -> FoundationInput
  -> Maybe (DatabaseDirectInput, StoreBackend, CacheRenderInput)
  -> FilePath
  -> Text
  -> Text
  -> FilePath
  -> IO (Either (NonEmpty InventoryError)
       (CompositionCandidate, Map ResourceId (ManagedResource, ByteString)))
compileConfiguredBootstrap snapshot foundation cache root domain registry certificatePatch = do
  configured <- configuredUpstreamInputs (foundationCluster foundation) root domain registry certificatePatch
  case configured of
    Left message -> pure (Left (inventoryError "invalid-upstream-policy" message :| []))
    Right upstream -> compileBootstrapCandidate snapshot (BootstrapInput foundation cache upstream [])

compileIssuerBootstrap
  :: ScopeSnapshot
  -> FoundationInput
  -> Maybe (DatabaseDirectInput, StoreBackend, CacheRenderInput)
  -> FilePath
  -> Text
  -> Text
  -> IssuerMode
  -> IO (Either (NonEmpty InventoryError)
       (CompositionCandidate, Map ResourceId (ManagedResource, ByteString)))
compileIssuerBootstrap snapshot foundation cache root domain registry mode = do
  configured <- configuredUpstreamInputsWithIssuer (foundationCluster foundation) root domain registry mode
  case configured of
    Left message -> pure (Left (inventoryError "invalid-issuer-policy" message :| []))
    Right upstream -> compileBootstrapCandidate snapshot (BootstrapInput foundation cache upstream [])

compileBootstrapWithAuth
  :: ScopeSnapshot
  -> BootstrapInput
  -> AuthInput
  -> [(Text, DatabaseDirectInput, StoreBackend)]
  -> IO (Either (NonEmpty InventoryError)
       (CompositionCandidate, Map ResourceId (ManagedResource, ByteString)))
compileBootstrapWithAuth snapshot bootstrap auth databases = do
  compileBootstrapWithAuthAndScopes snapshot bootstrap auth databases []

compileBootstrapWithAuthAndScopes
  :: ScopeSnapshot
  -> BootstrapInput
  -> AuthInput
  -> [(Text, DatabaseDirectInput, StoreBackend)]
  -> [ScopeDeclaration]
  -> IO (Either (NonEmpty InventoryError)
       (CompositionCandidate, Map ResourceId (ManagedResource, ByteString)))
compileBootstrapWithAuthAndScopes snapshot bootstrap auth databases extras = do
  baseResult <- compileBootstrapCandidate snapshot bootstrap
  authResult <- compileAuthComponent auth databases
  pure $ do
    (base, baseNative) <- baseResult
    (authScope, authNative) <- authResult
    unless (authCluster auth == foundationCluster (bootstrapFoundation bootstrap)
        && authNamespace auth == foundationNamespaceId (bootstrapFoundation bootstrap) (known "nagare-system"))
      (Left (single (invalid "auth component must depend on the foundation cluster and Namespace")))
    unless (Map.null (Map.intersection baseNative authNative))
      (Left (single (invalid "auth and bootstrap native members share an identity")))
    let upstreamOwners = map upstreamOwner (bootstrapUpstream bootstrap)
        upstreamIds = [resource ^. #identity
          | Managed resource <- inventoryDeclarations (candidateInventory base),
            resource ^. #owner `elem` upstreamOwners]
        orderResource resource = resource
          {dependencies = map OrderedAfter (upstreamIds <> authExtraPrerequisites auth)
            <> resource ^. #dependencies}
        orderedBundles =
          [bundle {declarations = map (\case
              Managed resource -> Managed (orderResource resource)
              other -> other) (declarations bundle)}
          | bundle <- scopeBundles authScope]
        orderedNative = Map.map (\(resource, bytes) -> (orderResource resource, bytes)) authNative
    orderedScope <- mkScopeDeclaration (authOwner auth) orderedBundles
    candidate <- composeInventory snapshot (candidateChanges base
      <> (ReplaceScope orderedScope :| map ReplaceScope extras))
    pure (candidate, Map.union baseNative orderedNative)
  where
    known = either (error . show) id . mkName
    invalid message = inventoryError "invalid-bootstrap-component" message
    single err = err :| []

compileBootstrapCandidate
  :: ScopeSnapshot
  -> BootstrapInput
  -> IO (Either (NonEmpty InventoryError)
       (CompositionCandidate, Map ResourceId (ManagedResource, ByteString)))
compileBootstrapCandidate snapshot input = do
  foundationResult <- compileFoundation (bootstrapFoundation input)
  cacheResult <- case bootstrapCache input of
    Nothing -> pure (Right Nothing)
    Just (databaseInput, backend, cacheInput) ->
      fmap Just <$> compileCacheComponent databaseInput backend cacheInput
  upstreamResults <- traverse compileUpstream (bootstrapUpstream input)
  pure $ do
    (foundationBundle, foundationNative) <- foundationResult
    let foundation = bootstrapFoundation input
    ownerScope <- mkScopeDeclaration (foundationOwner foundation) [foundationBundle]
    cacheComponent <- cacheResult
    (cacheChanges, cacheNative) <- case cacheComponent of
      Nothing -> Right ([], Map.empty)
      Just (cacheScope, cacheNative) -> do
        unless (Map.null (Map.intersection foundationNative cacheNative))
          (Left (single (invalid "foundation and cache native members share an identity")))
        let expectedNamespace = foundationNamespaceId foundation (known "nagare-system")
        case bootstrapCache input of
          Nothing -> Left (single (invalid "cache component input disappeared"))
          Just (databaseInput, _, cacheInput) ->
            unless (directNamespaceId databaseInput == Just expectedNamespace
                && renderNamespaceId cacheInput == Just expectedNamespace
                && directClusterId databaseInput == foundationCluster foundation)
              (Left (single (invalid "cache component must depend on the foundation nagare-system Namespace")))
        Right ([ReplaceScope cacheScope], cacheNative)
    rawUpstream <- sequence upstreamResults
    let namespaceIds = Map.fromList
          [((cluster, name), resource ^. #identity)
          | bundle <- foundationBundle : map fst rawUpstream, Managed resource <- declarations bundle,
            Kubernetes cluster "" kind Nothing name <- [resource ^. #address], nameText kind == "namespace"]
        upstreamComponents = orderUpstreamPhases (map (orderNamespaces namespaceIds) rawUpstream)
    upstreamScopes <- traverse (uncurry mkScopeDeclaration)
      [(upstreamOwner upstreamInput, [bundle]) | (upstreamInput, (bundle, _)) <- zip (bootstrapUpstream input) upstreamComponents]
    let nativeMaps = foundationNative : cacheNative : map snd upstreamComponents
        native = Map.unions nativeMaps
        suppliedCount = sum (map Map.size nativeMaps)
    unless (Map.size native == suppliedCount)
      (Left (single (invalid "bootstrap components share a native logical identity")))
    let changes = ReplaceScope ownerScope :|
          (cacheChanges <> map ReplaceScope upstreamScopes
            <> map ReplaceScope (bootstrapAdditionalScopes input))
    candidate <- composeInventory snapshot changes
    pure (candidate, native)
  where
    known = either (error . show) id . mkName
    invalid message = inventoryError "invalid-bootstrap-component" message
    single err = err :| []
    orderNamespaces namespaces (bundle, native) =
      let declarationsById = Map.fromList
            [(resource ^. #identity, updated) | Managed resource <- declarations bundle,
              let updated = attach resource]
          attach resource = case resource ^. #address of
            Kubernetes cluster _ _ (Just name) _ -> case Map.lookup (cluster, name) namespaces of
              Just namespaceId | OrderedAfter namespaceId `notElem` resource ^. #dependencies ->
                resource {dependencies = OrderedAfter namespaceId : resource ^. #dependencies}
              _ -> resource
            _ -> resource
          update (Managed resource) = Managed (Map.findWithDefault resource (resource ^. #identity) declarationsById)
          update declaration = declaration
          updatedBundle = bundle {declarations = map update (declarations bundle)}
          updatedNative = Map.mapWithKey (\resource (original, bytes) ->
            (Map.findWithDefault original resource declarationsById, bytes)) native
       in (updatedBundle, updatedNative)
    -- The input order is the reviewed installation order of pinned operator
    -- releases. Later releases may include CRs whose CRDs and webhooks live in
    -- earlier scopes, so readiness of every earlier direct member is required.
    orderUpstreamPhases components = go [] components
      where
        servingCertificateIds =
          [resource ^. #identity
          | (bundle, _) <- components
          , Managed resource <- declarations bundle
          , isServingCertificate resource]
        netControllerIds =
          [resource ^. #identity
          | (bundle, _) <- components
          , Managed resource <- declarations bundle
          , resource ^. #owner == knownNetCertManager
          , case resource ^. #address of
              Kubernetes _ "apps" kind (Just _) _ -> nameText kind == "deployment"
              _ -> False]
        netCertificateIssuerIds =
          [resource ^. #identity
          | (bundle, _) <- components
          , Managed resource <- declarations bundle
          , resource ^. #owner == knownNetCertManager
          , case resource ^. #address of
              Kubernetes _ "cert-manager.io" kind Nothing name ->
                nameText kind == "clusterissuer" && nameText name == "knative-selfsigned-issuer"
              _ -> False]
        certificateConfigIds =
          [resource ^. #identity
          | (bundle, _) <- components
          , Managed resource <- declarations bundle
          , isCertificateConfig resource]
        isCertificateConfig resource = case resource ^. #address of
          Kubernetes _ "" kind (Just namespaceName) name ->
            nameText kind == "configmap" && nameText namespaceName == "knative-serving"
              && nameText name == "config-certmanager"
          _ -> False
        isServingDeployment resource = resource ^. #owner == knownServing
          && case resource ^. #address of
            Kubernetes _ "apps" kind (Just _) _ -> nameText kind == "deployment"
            _ -> False
        knownServing = either (error . show) id (mkScopeId Platform "serving")
        knownNetCertManager = either (error . show) id (mkScopeId Platform "net-certmanager")
        isServingCertificate resource = resource ^. #owner == knownServing
          && case resource ^. #address of
            Kubernetes _ "networking.internal.knative.dev" kind (Just _) _ ->
              nameText kind == "certificate"
            _ -> False
        go _ [] = []
        go prior ((bundle, native) : remaining) =
          let attach resource = resource
                {dependencies = map OrderedAfter
                  ((if isCertificateConfig resource then []
                      else filter (`notElem` servingCertificateIds) prior)
                    <> (if isServingDeployment resource then certificateConfigIds else [])
                    <> (if isServingCertificate resource
                          then netControllerIds <> netCertificateIssuerIds else []))
                  <> resource ^. #dependencies}
              revised = [(resource ^. #identity, attach resource)
                | Managed resource <- declarations bundle]
              byId = Map.fromList revised
              update (Managed resource) = Managed (Map.findWithDefault resource (resource ^. #identity) byId)
              update declaration = declaration
              updatedBundle = bundle {declarations = map update (declarations bundle)}
              updatedNative = Map.mapWithKey (\resource (original, bytes) ->
                (Map.findWithDefault original resource byId, bytes)) native
              current = map fst revised
           in (updatedBundle, updatedNative) : go (prior <> current) remaining
