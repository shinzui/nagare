-- | Read-only findings over an accepted, validated inventory and provider facts.
module Nagare.Inventory.Status
  ( DriftCategory (..)
  , DriftFinding (..)
  , classifyDrift
  ) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Resource.Wire ()

data DriftCategory
  = Converged
  | ConfigurationDrift
  | MissingResource
  | ForeignOwner
  | UnknownObservation
  deriving stock (Eq, Ord, Show)

data DriftFinding = DriftFinding
  { findingResource :: !ResourceId
  , findingOwner :: !ScopeId
  , findingExecutor :: !Executor
  , findingAddress :: !ProviderAddress
  , findingCategory :: !DriftCategory
  , findingPhysical :: !(Maybe PhysicalIdentity)
  , findingObservedDigest :: !(Maybe ContentDigest)
  , findingReason :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

classifyDrift :: ValidatedInventory -> ObservationSet -> [DriftFinding]
classifyDrift inventory observations =
  [ classify resource (Map.lookup (resource ^. #identity) observed)
  | Managed resource <- inventoryDeclarations inventory
  ]
  where
    observed = observationMap observations
    classify resource fact =
      let (category, physical, digest, reason) = case fact of
            Just (ObservedPresent uid) -> (Converged, Just uid, Nothing, Nothing)
            Just (ObservedDrifted uid changed) ->
              (ConfigurationDrift, Just uid, Just changed, Nothing)
            Just (ObservedForeign uid) ->
              (ForeignOwner, Just uid, Nothing, Just "observed object has a different owner")
            Just (ConfirmedAbsent _) ->
              (MissingResource, Nothing, Nothing, Just "provider confirmed absence")
            Just (ObservationUnavailable message) ->
              (UnknownObservation, Nothing, Nothing, Just message)
            Nothing ->
              (UnknownObservation, Nothing, Nothing, Just "provider did not report this resource")
       in DriftFinding
            (resource ^. #identity)
            (resource ^. #owner)
            (resource ^. #executor)
            (resource ^. #address)
            category physical digest reason

instance ToJSON DriftCategory where
  toJSON category = toJSON $ case category of
    Converged -> ("converged" :: Text)
    ConfigurationDrift -> "configuration-drift"
    MissingResource -> "missing"
    ForeignOwner -> "foreign-owner"
    UnknownObservation -> "unknown"

instance ToJSON DriftFinding where
  toJSON finding = object
    [ "resource" .= findingResource finding
    , "owner" .= findingOwner finding
    , "executor" .= findingExecutor finding
    , "address" .= findingAddress finding
    , "category" .= findingCategory finding
    , "physical" .= findingPhysical finding
    , "observedDigest" .= findingObservedDigest finding
    , "reason" .= findingReason finding
    ]
