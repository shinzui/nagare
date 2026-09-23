-- | Versioned operator proposal inputs. Evidence is checked against a fresh
-- provider observation and the composed declaration, then converted to the
-- opaque decisions consumed by the single inventory planner.
module Nagare.Inventory.Lifecycle
  ( AdoptionInput (..)
  , AdoptionTarget (..)
  , decodeAdoptionInput
  , decideAdoption
  , decideRetirement
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
import Nagare.Resource.Policy (RetirementIntent (..))
import Nagare.Resource.Types
import Nagare.Resource.Wire ()

data AdoptionTarget = AdoptionTarget
  { adoptionResource :: !ResourceId
  , adoptionAddress :: !ProviderAddress
  , adoptionPhysical :: !PhysicalIdentity
  , adoptionPreviousOwner :: !(Maybe ScopeId)
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
    [ LifecycleProposal resource (maybe ApproveAdoption (const ApproveTransfer)
        (adoptionPreviousOwner target))
        (lifecycleObservationDigest (adoptionBinding input) resource fact)
    | target <- adoptionTargets input
    , let resource = adoptionResource target
    , Just fact <- [Map.lookup resource (observationMap observations)]
    ]
  where
    declared = Map.fromList
      [(resource ^. #identity, resource) | Managed resource <- inventoryDeclarations (candidateInventory candidate)]
    historical = Map.fromList
      [(resource ^. #identity, resource) | (_, scope) <- Map.elems (historyAccepted history)
        , bundle <- scopeBundles scope, Managed resource <- declarations bundle]
    issue code message resource = PlanError code message [resource]
    errors =
      [issue "adoption-binding" "proposal belongs to another context or provider target" (adoptionResource target)
      | target <- adoptionTargets input
      , adoptionBinding input /= inventoryBinding (candidateInventory candidate)]
      <> [issue "adoption-declaration" "proposal address differs from the composed declaration" (adoptionResource target)
         | target <- adoptionTargets input
         , maybe True ((/= adoptionAddress target) . (^. #address))
             (Map.lookup (adoptionResource target) declared)]
      <> [issue "adoption-incarnation" "proposal physical identity or prior owner differs from the fresh observation" (adoptionResource target)
         | target <- adoptionTargets input
         , let observed = Map.lookup (adoptionResource target) (observationMap observations)
               expected = case adoptionPreviousOwner target of
                 Nothing -> Just (ObservedUnowned (adoptionPhysical target))
                 Just prior -> if maybe False ((== prior) . (^. #owner))
                   (Map.lookup (adoptionResource target) historical)
                   then Just (ObservedPresent (adoptionPhysical target)) else Nothing
         , observed /= expected]
      <> [issue "duplicate-adoption" "resource appears more than once in the adoption proposal" resource
         | resource <- duplicateIds (map adoptionResource (adoptionTargets input))]
    duplicateIds values = Map.keys (Map.filter (> (1 :: Int))
      (Map.fromListWith (+) [(value, 1 :: Int) | value <- values]))

-- | A scope retirement retains every directly managed incarnation. Deletion
-- is a separate reviewed collection path and remains unavailable here.
decideRetirement
  :: CompositionCandidate -> InventoryHistory -> ObservationSet
  -> Either (NonEmpty PlanError) LifecycleDecisions
decideRetirement candidate history observations =
  validateLifecycleDecisions candidate history observations
    [ LifecycleProposal resourceId ApproveRetirement
        (lifecycleObservationDigest binding resourceId fact)
    | RetireScope owner RetainResources <- NE.toList (candidateChanges candidate)
    , Just (_, scope) <- [Map.lookup owner (historyAccepted history)]
    , bundle <- scopeBundles scope
    , Managed resource <- bundle ^. #declarations
    , let resourceId = resource ^. #identity
    , Just fact <- [Map.lookup resourceId (observationMap observations)]
    ]
  where
    binding = inventoryBinding (candidateInventory candidate)

instance FromJSON AdoptionTarget where
  parseJSON = withObject "AdoptionTarget" $ \o -> do
    unless (all (`elem` ["resource", "address", "physicalIdentity", "previousOwner"]) (KM.keys o))
      (fail "unknown adoption target field")
    AdoptionTarget <$> o .: "resource" <*> o .: "address" <*> o .: "physicalIdentity"
      <*> o .:? "previousOwner"

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
