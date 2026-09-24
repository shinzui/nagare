-- | A standalone database is an independently replaceable scope. Its native
-- members come from the complete typed database builder, including credentials
-- and the scheduled backup for retained data.
module Nagare.Inventory.DataService
  ( compileStandaloneDatabase
  ) where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Nagare.Cluster.GcsJob (StoreBackend)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Database (compileDatabaseForBackend)
import Nagare.Resource.Database (DatabaseDirectInput (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Types

compileStandaloneDatabase
  :: DatabaseDirectInput
  -> StoreBackend
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStandaloneDatabase input backend
  | scopeKind owner /= Standalone =
      Left (inventoryError "wrong-data-scope" "standalone database requires a standalone scope"
        & #scopes .~ [owner]
        & #sources .~ [directSourceLocation input]
        & (:| []))
  | otherwise = do
      (bundle, native) <- compileDatabaseForBackend input backend
      scope <- mkScopeDeclaration owner [bundle]
      pure (scope, native)
  where
    owner = directOwnerScope input
