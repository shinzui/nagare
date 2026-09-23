-- | A Helm release claims its release identity and every directly rendered
-- Kubernetes member. The caller must capture the native post-renderer bytes
-- and derive the member addresses from those same bytes.
module Nagare.Resource.Helm
  ( HelmInput (..)
  , compileHelmRelease
  ) where

import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Generics.Labels ()
import Data.Set qualified as Set
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency)
import Nagare.Resource.Types

data HelmInput = HelmInput
  { helmResourceId :: !ResourceId
  , helmOwner :: !ScopeId
  , helmCluster :: !ResourceId
  , helmNamespace :: !Name
  , helmName :: !Name
  , helmMembers :: !(NonEmpty ProviderAddress)
  , helmNativeDigest :: !ContentDigest
  , helmDependencies :: ![Dependency]
  , helmSource :: !SourceLocation
  }

compileHelmRelease :: HelmInput -> Either InventoryError ManagedResource
compileHelmRelease input = do
  unless (all validMember members) (Left (invalid "Helm member is not a Kubernetes object in the release cluster"))
  unless (Set.size (Set.fromList (map canonicalClaim members)) == length members)
    (Left (invalid "Helm render repeats a direct Kubernetes member"))
  pure ManagedResource
    { identity = helmResourceId input
    , owner = helmOwner input
    , executor = HelmExecutor
    , address = Helm (helmCluster input) (helmNamespace input) (helmName input)
    , aliases = []
    , spec = HelmRelease (helmMembers input) (helmNativeDigest input)
    , lifecycle = Retain
    , dataPolicy = Stateless
    , sensitivity = Private
    , dependencies = helmDependencies input
    , delegations = []
    , source = helmSource input
    }
  where
    members = NE.toList (helmMembers input)
    validMember (Kubernetes cluster _ _ _ _) = cluster == helmCluster input
    validMember _ = False
    invalid message = inventoryError "invalid-helm-release" message
      & #scopes .~ [helmOwner input]
      & #resources .~ [helmResourceId input]
      & #sources .~ [helmSource input]
