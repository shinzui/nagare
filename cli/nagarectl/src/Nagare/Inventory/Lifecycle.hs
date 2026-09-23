-- | Versioned operator proposal inputs. Evidence is checked against a fresh
-- provider observation and the composed declaration, then converted to the
-- opaque decisions consumed by the single inventory planner.
module Nagare.Inventory.Lifecycle
  ( AdoptionInput (..)
  , AdoptionTarget (..)
  , decodeAdoptionInput
  , decideAdoption
  ) where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Plan
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Resource.Wire ()

data AdoptionTarget = AdoptionTarget
  { adoptionResource :: !ResourceId
  , adoptionAddress :: !ProviderAddress
  , adoptionPhysical :: !PhysicalIdentity
  }
  deriving stock (Eq, Show)

data AdoptionInput = AdoptionInput
  { adoptionCandidateDirectory :: !FilePath
  , adoptionBinding :: !ContextBinding
  , adoptionTargets :: ![AdoptionTarget]
  }
  deriving stock (Eq, Show)

decodeAdoptionInput :: ByteString -> Either Text AdoptionInput
decodeAdoptionInput bytes = first (T.pack . show) (eitherDecodeStrict' bytes)

decideAdoption
  :: CompositionCandidate -> InventoryHistory -> ObservationSet -> AdoptionInput
  -> Either (NonEmpty PlanError) LifecycleDecisions
decideAdoption candidate history observations input = do
  unless (null errors) (Left (NE.fromList errors))
  validateLifecycleDecisions candidate history observations
    [ LifecycleProposal resource ApproveAdoption
        (lifecycleObservationDigest (adoptionBinding input) resource fact)
    | target <- adoptionTargets input
    , let resource = adoptionResource target
    , Just fact <- [Map.lookup resource (observationMap observations)]
    ]
  where
    declared = Map.fromList
      [(resource ^. #identity, resource) | Managed resource <- inventoryDeclarations (candidateInventory candidate)]
    issue code message resource = PlanError code message [resource]
    errors =
      [issue "adoption-binding" "proposal belongs to another context or provider target" (adoptionResource target)
      | target <- adoptionTargets input
      , adoptionBinding input /= inventoryBinding (candidateInventory candidate)]
      <> [issue "adoption-declaration" "proposal address differs from the composed declaration" (adoptionResource target)
         | target <- adoptionTargets input
         , maybe True ((/= adoptionAddress target) . (^. #address))
             (Map.lookup (adoptionResource target) declared)]
      <> [issue "adoption-incarnation" "proposal physical identity differs from the fresh unowned observation" (adoptionResource target)
         | target <- adoptionTargets input
         , Map.lookup (adoptionResource target) (observationMap observations)
             /= Just (ObservedUnowned (adoptionPhysical target))]
      <> [issue "duplicate-adoption" "resource appears more than once in the adoption proposal" resource
         | resource <- duplicateIds (map adoptionResource (adoptionTargets input))]
    duplicateIds values = Map.keys (Map.filter (> (1 :: Int))
      (Map.fromListWith (+) [(value, 1 :: Int) | value <- values]))

instance FromJSON AdoptionTarget where
  parseJSON = withObject "AdoptionTarget" $ \o -> do
    unless (all (`elem` ["resource", "address", "physicalIdentity"]) (KM.keys o))
      (fail "unknown adoption target field")
    AdoptionTarget <$> o .: "resource" <*> o .: "address" <*> o .: "physicalIdentity"

instance FromJSON AdoptionInput where
  parseJSON = withObject "AdoptionInput" $ \o -> do
    unless (all (`elem` ["version", "candidate", "binding", "resources"]) (KM.keys o))
      (fail "unknown adoption input field")
    version <- o .: "version"
    unless (version == (1 :: Int)) (fail "unsupported adoption input version")
    candidate <- o .: "candidate"
    when (null (candidate :: FilePath)) (fail "candidate directory is required")
    targets <- o .: "resources"
    when (null (targets :: [AdoptionTarget])) (fail "adoption proposal needs at least one resource")
    AdoptionInput candidate <$> o .: "binding" <*> pure targets
