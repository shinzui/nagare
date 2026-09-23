-- | Compose cluster bootstrap components before observation or mutation.
-- Generated native members stay in memory until the review retains them.
module Nagare.Inventory.Bootstrap
  ( BootstrapInput (..)
  , compileBootstrapCandidate
  ) where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
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
        upstreamComponents = map (orderNamespaces namespaceIds) rawUpstream
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
