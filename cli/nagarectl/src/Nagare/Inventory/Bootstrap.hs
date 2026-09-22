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
import Nagare.Resource.Database (DatabaseDirectInput (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Types

data BootstrapInput = BootstrapInput
  { bootstrapFoundation :: !FoundationInput
  , bootstrapCache :: !(Maybe (DatabaseDirectInput, StoreBackend, CacheRenderInput))
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
  pure $ do
    (foundationBundle, foundationNative) <- foundationResult
    let foundation = bootstrapFoundation input
    ownerScope <- mkScopeDeclaration (foundationOwner foundation) [foundationBundle]
    cacheComponent <- cacheResult
    (changes, native) <- case cacheComponent of
      Nothing -> Right (ReplaceScope ownerScope :| [], foundationNative)
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
        Right (ReplaceScope ownerScope :| [ReplaceScope cacheScope], Map.union foundationNative cacheNative)
    candidate <- composeInventory snapshot changes
    pure (candidate, native)
  where
    known = either (error . show) id . mkName
    invalid message = inventoryError "invalid-bootstrap-component" message
    single err = err :| []
