-- | The observation bytes a reviewed mutation envelope carries, from known,
-- versioned adapters only (EP-181). Apart from
-- "Nagare.Inventory.ObservationNative" so a reader of observation bytes does
-- not link the adapters (MasterPlan 37).
module Nagare.Inventory.ObservationNative.Mutation
  ( observationBytesFromMutation
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Helm
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Adapters.KubernetesStuckPod (PodReplacement)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (operationIdText)
import Nagare.Resource.Types

-- | Extract from known, versioned adapters only. Publication still retains the
-- original envelope; old reviews can materialize these same bytes explicitly.
observationBytesFromMutation ::
  ContextId ->
  Text ->
  Text ->
  PlannedOperation ->
  ByteString ->
  Either Text (Maybe ByteString)
observationBytesFromMutation context identity version operation bytes
  -- Each action names its envelope, with no default, so a new action cannot
  -- reach publication with a format this extraction does not read (EP-181).
  | identity == "kubernetes-conditional-object" && version == "1" = case plannedAction operation of
      MigrateResource _ -> renameMember
      ReplaceStuckPod -> replacementMember
      CreateResource -> mutationMember
      UpdateResource -> mutationMember
      VerifyResource -> mutationMember
      AdoptResource -> mutationMember
      RetireResource -> mutationMember
      RunDeclaredOperation -> mutationMember
      OpenMaintenanceSession -> mutationMember
      RestoreLiveDatabase -> mutationMember
  | identity == "helm-reviewed-render" && version == "1" = do
      mutation <- first T.pack (eitherDecodeStrict' bytes)
      let contract = TE.encodeUtf8 (helmMutationContract mutation)
      unless
        ( helmMutationVersion mutation == 1
            && helmMutationOperation mutation == plannedOperationId operation
            && namesOnly operation (helmMutationResource mutation)
            && helmMutationAction mutation == plannedAction operation
            && helmMutationInputDigest mutation == plannedInputDigest operation
            && helmMutationContractDigest mutation == contentDigest contract
        )
        (Left "observation Helm envelope differs from reviewed operation")
      pure (Just contract)
  | otherwise = Right Nothing
  where
    -- A reviewed migration stage carries a rename bundle. Its observation
    -- member is the destination object the stage creates, bound to the same
    -- operation, resource and stage digest.
    renameMember = do
      value <- first T.pack (eitherDecodeStrict' bytes)
      let field key = case value of
            Object root -> KM.lookup key root
            _ -> Nothing
          text key = case field key of
            Just (String found) -> Right found
            _ -> Left "migration bundle lacks a destination member"
      format <- text "format"
      unless (format == "kubernetes-postgres-rename-v1") (Left "unsupported migration bundle format")
      resource <- text "resource" >>= mkResourceId
      digest <- text "destinationDigest" >>= mkContentDigest
      native <- text "destinationNative"
      reviewedOperation <- text "operation"
      reviewedInput <- text "inputDigest"
      unless
        ( namesOnly operation resource
            && reviewedOperation == operationIdText (plannedOperationId operation)
            && reviewedInput == digestText (plannedInputDigest operation)
        )
        (Left "observation migration bundle differs from reviewed operation")
      Just <$> unstampNative context resource digest native
    -- A stuck-pod replacement writes no member object, so it has no
    -- observation member; its bytes must still be the replacement this
    -- operation reviewed.
    replacementMember = do
      replacement <- first T.pack (eitherDecodeStrict' bytes) :: Either Text PodReplacement
      unless
        ( replacement ^. #version == 1
            && replacement ^. #operation == plannedOperationId operation
            && replacement ^. #inputDigest == plannedInputDigest operation
            && namesOnly operation (replacement ^. #member)
        )
        (Left "observation pod replacement differs from reviewed operation")
      pure Nothing
    mutationMember = do
      mutation <- first T.pack (eitherDecodeStrict' bytes)
      unless
        ( ( mutationVersion mutation == 1
              -- A reviewed field takeover (F37) is a version-1 update with a takeover record.
              || (mutationVersion mutation == 3 && mutationAction mutation == UpdateResource && isJust (mutationTakeover mutation))
          )
            && mutationOperation mutation == plannedOperationId operation
            && namesReviewedResource mutation
            && mutationAction mutation == plannedAction operation
            && mutationInputDigest mutation == plannedInputDigest operation
        )
        (Left "observation Kubernetes envelope differs from reviewed operation")
      Just
        <$> unstampNative
          context
          (mutationResource mutation)
          (mutationNativeDigest mutation)
          (mutationNativeJson mutation)
    -- The envelope supplies its own member's address, so it names the resource
    -- the adapter acts on exactly as 'kubernetesOperationResource' selects it.
    namesReviewedResource mutation =
      kubernetesOperationResource
        (\resource -> if resource == mutationResource mutation then Just (mutationAddress mutation) else Nothing)
        operation
        == Right (mutationResource mutation)
