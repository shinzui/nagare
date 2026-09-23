-- | Read-only findings over an accepted, validated inventory and provider facts.
module Nagare.Inventory.Status
  ( DriftCategory (..)
  , DriftFinding (..)
  , classifyDrift
  , loadAcceptedNative
  ) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.HelmReview (helmSpecsFromReview)
import Nagare.Inventory.KubernetesReview (kubernetesSpecsFromReview)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Resource.Wire ()

-- | Recover exact accepted native members from immutable private reviews.
-- Reviews for newer, unaccepted revisions never become status evidence.
loadAcceptedNative
  :: InventoryStore -> InventoryHistory -> ValidatedInventory
  -> IO (Either Text (Map ResourceId (ManagedResource, ByteString),
                      Map ResourceId (ManagedResource, ByteString)))
loadAcceptedNative store history inventory = do
  snapshot <- readStoreSnapshot store
  case snapshot of
    Left failure -> pure (Left (T.pack (show failure)))
    Right state -> do
      loaded <- traverse (loadPublishedReview store) (Set.toAscList (storeSnapshotReviewDigests state))
      pure $ do
        retained <- first (T.pack . show) (sequence loaded)
        entries <- traverse collect retained
        kubernetes <- agree (concatMap fst entries)
        helm <- agree (concatMap snd entries)
        pure (kubernetes, helm)
  where
    accepted = fmap fst (historyAccepted history)
    desired = Map.fromList
      [ (resource ^. #identity, resource)
      | Managed resource <- inventoryDeclarations inventory
      ]
    collect bundle = do
      let revisions = reviewDesiredRevisions (reviewBundleDocument bundle)
          current member =
            Map.lookup (member ^. #owner) revisions == Map.lookup (member ^. #owner) accepted
              && case Map.lookup (member ^. #identity) desired of
                   Just resource -> resource ^. #address == member ^. #address
                     && resource ^. #spec == member ^. #spec
                   Nothing -> False
      kubernetes <- kubernetesSpecsFromReview bundle
      helm <- helmSpecsFromReview bundle
      pure
        ([(resource, native) | (resource, native@(member, _)) <- Map.toList kubernetes, current member]
        ,[(resource, native) | (resource, native@(member, _)) <- Map.toList helm, current member])
    agree entries = traverse one (Map.fromListWith (<>)
      [(resource, [native]) | (resource, native) <- entries])
    one [] = Left "accepted resource has an empty native evidence group"
    one values@(firstValue : _)
      | all (== firstValue) values = Right firstValue
      | otherwise = Left "accepted reviews disagree on a resource's native bytes"

data DriftCategory
  = Converged
  | ConfigurationDrift
  | MissingResource
  | UnownedResource
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
            Just (ObservedUnowned uid) ->
              (UnownedResource, Just uid, Nothing, Just "observed object has no inventory owner")
            Just (ConfirmedAbsent _) ->
              (MissingResource, Nothing, Nothing, Just "provider confirmed absence")
            Just (ObservationUnavailable _) ->
              (UnknownObservation, Nothing, Nothing, Just "provider observation is unavailable")
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
    UnownedResource -> "unowned"
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
