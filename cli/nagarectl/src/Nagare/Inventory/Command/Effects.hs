-- | Planning a review that lists what it removes (EP-283).
module Nagare.Inventory.Command.Effects
  ( planInventoryCandidateWithEffects
  , planInventoryCollectionWithEffects
  , collectionEffects
  )
where

import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (AdapterRegistry)
import Nagare.Inventory.Command (dieText, loadTargetSnapshot, openCandidateInventory, tryReviewInventoryCandidateLoaded, writePlannedReview)
import Nagare.Inventory.Lifecycle (decideCollection, decideMemberRetirement)
import Nagare.Inventory.Plan (InventoryHistory (..), ReviewEffect (ReviewEffect), publishReview, withReviewEffects)
import Nagare.Resource.Inventory (CompositionCandidate, ManagedResource, ScopeChange (CollectRetained), composeInventory)
import Nagare.Resource.Types (ProviderAddress (Hostname, Kubernetes), ResourceId, nameText)
import Nagare.Target (ActiveTarget)

-- | Plan a candidate that drops the named members from their scopes, each
-- retained by its own retirement decision, and record what the review takes
-- away. The effects are set before the review is published, so they are
-- under its digest. Saves the review and prints it.
planInventoryCandidateWithEffects ::
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  ActiveTarget ->
  CompositionCandidate ->
  [ResourceId] ->
  [ReviewEffect] ->
  FilePath ->
  IO ()
planInventoryCandidateWithEffects registryFor target candidate retired effects output = do
  opened <- openCandidateInventory target candidate
  (store, bundle) <-
    tryReviewInventoryCandidateLoaded registryFor (decideMemberRetirement retired candidate) "operator-cli" target opened candidate
      >>= either dieText pure
  let reviewed = withReviewEffects effects bundle
  digest <- publishReview store reviewed >>= either (dieText . T.pack . show) pure
  writePlannedReview output reviewed digest

-- | Plan the collection of retained members, as @inventory collect@ does,
-- and record what each deletion takes away (EP-285, EP-286): a content
-- route's hosts stop being served, and its certificate's private key is
-- deleted with it.
planInventoryCollectionWithEffects ::
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  ActiveTarget ->
  NonEmpty ResourceId ->
  FilePath ->
  IO ()
planInventoryCollectionWithEffects registryFor target resources output = do
  when
    (Set.size (Set.fromList (NE.toList resources)) /= length resources)
    (dieText "collection resource IDs must be distinct")
  snapshot <- loadTargetSnapshot target
  candidate <- either (dieText . T.pack . show . NE.toList) pure (composeInventory snapshot (fmap CollectRetained resources))
  opened <- openCandidateInventory target candidate
  let retained = [member | resource <- NE.toList resources, Just (_, member) <- [Map.lookup resource (historyRetained (opened ^. #loadedHistory))]]
  (store, bundle) <-
    tryReviewInventoryCandidateLoaded registryFor (decideCollection candidate) "operator-cli" target opened candidate
      >>= either dieText pure
  let reviewed = withReviewEffects (collectionEffects retained) bundle
  digest <- publishReview store reviewed >>= either (dieText . T.pack . show) pure
  writePlannedReview output reviewed digest

-- | What collecting each member removes, for the kinds whose deletion is not
-- self-evident: a content route's Ingress and Certificate.
collectionEffects :: [ManagedResource] -> [ReviewEffect]
collectionEffects = concatMap effect
  where
    effect member = case member ^. #address of
      Kubernetes _ "networking.internal.knative.dev" kind namespace name
        | nameText kind == "ingress" ->
            [ ReviewEffect (member ^. #identity) ("*." <> apex <> " and " <> apex <> " stop being served (Ingress " <> located namespace name <> ")")
            | Hostname host <- member ^. #aliases
            , let apex = nameText host
            ]
      Kubernetes _ "cert-manager.io" kind namespace name
        | nameText kind == "certificate" ->
            [ReviewEffect (member ^. #identity) ("the certificate " <> located namespace name <> " and the Secret holding its private key are deleted")]
      Kubernetes _ "" kind namespace name
        | nameText kind == "secret"
        , Just keySet <- T.stripPrefix "nagare-keyset-" (nameText name) ->
            [ReviewEffect (member ^. #identity) ("the private keys of key set " <> keySet <> " in " <> maybe "" nameText namespace <> " are destroyed; every signature made with them stops verifying")]
      _ -> []
    located namespace name = maybe "" ((<> "/") . nameText) namespace <> nameText name
