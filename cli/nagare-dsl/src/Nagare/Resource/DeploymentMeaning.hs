-- | EP-225: what a scope declaration means to a deployment, apart from where
-- it was compiled from. Two releases built from different workspaces declare
-- the same scope with different source locations; when nothing else differs,
-- the accepted scope and its revision stay as they are.
--
-- The projection is typed and explicit. Every field of every declaration,
-- bundle and scope stays significant except a source location that is only
-- provenance. A source location is significant when code reads it as data:
-- a generated or packaged record, a contribution, or an artifact whose local
-- input the source names. Every other source location is diagnostic. No JSON
-- key is deleted by name, so workload fields called @source@, @version@ or
-- @path@ keep their meaning.
module Nagare.Resource.DeploymentMeaning
  ( deploymentMeaningVersion
  , DeploymentMeaning
  , deploymentMeaning
  , sameDeploymentMeaning
  , sameDeclarationsModuloSources
  , significantSource
  )
where

import Data.Generics.Labels ()
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory
import Nagare.Resource.Types (ContentDigest, ScopeId, SourceLocation (..))

-- | The comparison's version: a review that relies on it records this value,
-- and a change to the classification below increments it.
deploymentMeaningVersion :: Int
deploymentMeaningVersion = 1

data DeploymentMeaning = DeploymentMeaning !ScopeId !(Maybe ContentDigest) !(Map Text Text) ![ResourceBundle]
  deriving stock (Eq, Show)

-- | The scope with each diagnostic source location replaced by one fixed
-- value. Bundles are compared as the set 'mkScopeDeclaration' already sorts
-- them into; declarations keep their order.
deploymentMeaning :: ScopeDeclaration -> DeploymentMeaning
deploymentMeaning = projected significantSource

-- | Compare with the given sources kept and every other one replaced.
projected :: (SourceLocation -> Bool) -> ScopeDeclaration -> DeploymentMeaning
projected keep scope =
  DeploymentMeaning
    (scopeId scope)
    (scopeConfigDigest scope)
    (scopeOverrides scope)
    (sort [bundle & #declarations %~ map declaration | bundle <- scopeBundles scope])
  where
    declaration = \case
      Managed resource -> Managed (resource & #source %~ located)
      External identity address dependencies source -> External identity address dependencies (located source)
      ObservedChild identity parent address physical source -> ObservedChild identity parent address physical (located source)
    located source
      | keep source = source
      | otherwise = SourceLocation "provenance" ""

sameDeploymentMeaning :: ScopeDeclaration -> ScopeDeclaration -> Bool
sameDeploymentMeaning left right = deploymentMeaning left == deploymentMeaning right

-- | Equality with every source location ignored, significant or not: for a
-- caller that re-accepts the new declaration, so its new locations replace
-- the old ones (the local substrate's artifact inputs).
sameDeclarationsModuloSources :: ScopeDeclaration -> ScopeDeclaration -> Bool
sameDeclarationsModuloSources left right = projected (const False) left == projected (const False) right

-- | A source location code reads as data. Generated and packaged records and
-- contributions are recognized by their file; an artifact's local input
-- (an OCI archive, a prepared kubeconfig, a local substrate) by its path.
significantSource :: SourceLocation -> Bool
significantSource (SourceLocation file path) =
  any (`T.isPrefixOf` file) ["generated:", "packaged:"]
    || file == "contribution"
    || path `elem` ["oci-archive-v1", "kubeconfig-prepared-v1", "local-substrate-v1"]
