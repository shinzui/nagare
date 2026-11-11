-- | A deployer's review, prepared and admitted inside its delegation
-- (EP-247 D3–D6). Every review is prepared through one path; this module is
-- what that path adds for a deployer context: the scope stamp, the bounds
-- before anything is published, and the actor and source on the review.
module Nagare.Inventory.DelegatedPlanning
  ( profileActor
  , delegatedCandidate
  , attributeReview
  )
where

import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Actor (Actor (..), ReviewSource, actorFromNames)
import Nagare.Inventory.DeployerDelegation
import Nagare.Inventory.Plan.Types (InventoryHistory (..), ReviewBundle (..), ReviewDocument (..), historyReservations)
import Nagare.Inventory.Store (ScopeRevision (revisionGeneration))
import Nagare.Resource.Inventory
import Nagare.Resource.Types (ResourceId, ScopeId)
import Nagare.Target (TargetProfile)

profileActor :: TargetProfile -> Either Text Actor
profileActor profile = actorFromNames (profile ^. #deployer) (profile ^. #operatorName)

-- | An operator's candidate is unchanged. A deployer's replaced scopes are
-- stamped with its name and recomposed against the accepted history, then
-- checked against its delegation before any store write.
delegatedCandidate :: Actor -> InventoryHistory -> CompositionCandidate -> Either Text CompositionCandidate
delegatedCandidate (OperatorActor _) _ candidate = Right candidate
delegatedCandidate (DeployerActor deployer) history candidate = do
  snapshot <-
    first
      (T.pack . show)
      ( mkScopeSnapshot
          (inventoryBinding (candidateInventory candidate))
          (Map.map (\(revision, declaration) -> (revisionGeneration revision, declaration)) (historyAccepted history))
          (historyReservations history)
      )
  let stamp = \case
        ReplaceScope scope -> ReplaceScope (stampDeployerScope deployer scope)
        other -> other
  restamped <- first (T.pack . show) (composeInventory snapshot (fmap stamp (candidateChanges candidate)))
  unless (candidateBase restamped == candidateBase candidate) (Left "the deployer's candidate was composed against another accepted head")
  let changes = toList' (candidateChanges restamped)
  first
    renderViolations
    ( checkDelegatedProposal
        DelegationCheck
          { deployer = deployer
          , delegations = acceptedDelegations accepted
          , replaced = [scope | ReplaceScope scope <- changes]
          , retired = [owner | RetireScope owner _ <- changes]
          , collected = [resource | CollectRetained resource <- changes]
          , accepted = accepted
          }
    )
  pure restamped
  where
    accepted = fmap snd (historyAccepted history)
    toList' = foldr (:) []

attributeReview :: Actor -> Maybe ReviewSource -> ReviewBundle -> ReviewBundle
attributeReview actor source bundle =
  bundle {bundleDocument = (bundleDocument bundle) {reviewActor = actor, reviewSource = source}}
