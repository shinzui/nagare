-- | Shared checks for restore compilers: an accepted member must match its
-- private native evidence exactly, and restore members share one cluster.
module Nagare.Inventory.RestoreNative
  ( acceptedValue
  , sameCluster
  )
where

import Data.Aeson (Value, eitherDecodeStrict)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

sameCluster :: ResourceId -> ManagedResource -> Bool
sameCluster cluster member = case member ^. #address of
  Kubernetes selected _ _ _ _ -> selected == cluster
  _ -> False

acceptedValue ::
  (T.Text -> NonEmpty InventoryError) ->
  Map ResourceId (ManagedResource, ByteString) ->
  ManagedResource ->
  Either (NonEmpty InventoryError) Value
acceptedValue invalid native member = do
  (bound, bytes) <-
    maybe
      (Left (invalid "restore member lacks accepted private native evidence"))
      Right
      (Map.lookup (member ^. #identity) native)
  unless
    (bound == member)
    (Left (invalid "restore member differs from accepted private native evidence"))
  value <- first (invalid . T.pack) (eitherDecodeStrict bytes)
  canonical <- first invalid (canonicalValue value)
  let expected = case member ^. #spec of
        StatefulSet _ _ digest -> Just digest
        NativeObject digest -> Just digest
        _ -> Nothing
  unless
    (expected == Just (contentDigest canonical))
    (Left (invalid "restore native digest differs from accepted declaration"))
  pure value
