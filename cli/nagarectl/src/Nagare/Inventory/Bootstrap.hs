-- | Compose cluster bootstrap components before observation or mutation.
-- Generated native members stay in memory until the review retains them.
module Nagare.Inventory.Bootstrap
  ( BootstrapInput (..)
  , compileBootstrapCandidate
  , compilePinnedBootstrap
  , compileConfiguredBootstrap
  ) where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Nagare.Dsl.Prelude
import Nagare.Cluster.GcsJob (StoreBackend)
import Nagare.Inventory.Cache
import Nagare.Inventory.Components.Foundation
import Nagare.Inventory.Components.Upstream
import Nagare.Resource.Database (DatabaseDirectInput (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types

data BootstrapInput = BootstrapInput
  { bootstrapFoundation :: !FoundationInput
  , bootstrapCache :: !(Maybe (DatabaseDirectInput, StoreBackend, CacheRenderInput))
  , bootstrapUpstream :: ![UpstreamInput]
  }

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
    (pinnedUpstreamInputs (foundationCluster foundation) root))

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
    Right upstream -> compileBootstrapCandidate snapshot (BootstrapInput foundation cache upstream)

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
    let changes = ReplaceScope ownerScope :| (cacheChanges <> map ReplaceScope upstreamScopes)
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
    orderUpstreamPhases = go []
      where
        go _ [] = []
        go prior ((bundle, native) : remaining) =
          let attach resource = resource
                {dependencies = map OrderedAfter prior <> resource ^. #dependencies}
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
