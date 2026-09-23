-- | Reconstruct Helm execution inputs from the immutable private review.
module Nagare.Inventory.HelmReview (helmSpecsFromReview) where

import Data.Aeson (eitherDecodeStrict')
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Helm
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Plan
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Resource.Wire (decodeScope)

helmSpecsFromReview :: ReviewBundle -> Either Text (Map ResourceId (ManagedResource, ByteString))
helmSpecsFromReview bundle = do
  scopes <- traverse (first (T.pack . show) . decodeScope) (Map.elems (reviewBundleScopes bundle))
  let declarationsById = Map.fromList
        [(resource ^. #identity, resource) | scope <- scopes, resourceBundle <- scopeBundles scope,
          Managed resource <- declarations resourceBundle, resource ^. #executor == HelmExecutor]
      operations = [operation | operation <- reviewOperations (reviewBundleDocument bundle),
        plannedExecutor (reviewPlannedOperation operation) == HelmExecutor]
  entries <- traverse (reconstruct declarationsById) operations
  let grouped = Map.fromListWith (<>) [(resource, [member]) | (resource, member) <- entries]
  traverse agree grouped
  where
    agree (member : rest)
      | all (== member) rest = Right member
      | otherwise = Left "review has conflicting Helm native contracts for one release"
    agree [] = Left "review has an empty Helm native contract group"
    reconstruct declarationsById reviewOperation = do
      let operation = reviewPlannedOperation reviewOperation
      resource <- case NE.toList (plannedResources operation) of
        [single] -> Right single
        _ -> Left "reviewed Helm operation does not name one release"
      declaration <- maybe (Left "reviewed Helm release is absent from desired scopes") Right
        (Map.lookup resource declarationsById)
      memberDigest <- maybe (Left "reviewed Helm operation has no private native member") Right
        (reviewNativeDigest reviewOperation)
      bytes <- maybe (Left "reviewed Helm private native member is missing") Right
        (Map.lookup memberDigest (reviewBundleNative bundle))
      unless (contentDigest bytes == memberDigest) (Left "reviewed Helm private native member digest differs")
      mutation <- first T.pack (eitherDecodeStrict' bytes)
      let contract = TE.encodeUtf8 (helmMutationContract mutation)
      unless (helmMutationVersion mutation == 1
          && helmMutationOperation mutation == plannedOperationId operation
          && helmMutationAction mutation == plannedAction operation
          && helmMutationInputDigest mutation == plannedInputDigest operation
          && helmMutationResource mutation == resource
          && helmMutationAddress mutation == declaration ^. #address
          && helmMutationContractDigest mutation == contentDigest contract)
        (Left "reviewed Helm mutation differs from its operation")
      case declaration ^. #spec of
        HelmRelease _ digest | digest == contentDigest contract -> pure ()
        _ -> Left "reviewed Helm native contract differs from the typed release"
      pure (resource, (declaration, contract))
