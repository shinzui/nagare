-- | Read-only native evidence, separate from the private mutation envelope.
-- Accepted declarations supply authority; digest-addressed bytes supply data.
-- This type cannot be admitted as a review or used to authorize an operation.
module Nagare.Inventory.ObservationNative
  ( ObservationNative
  , observationKubernetes
  , observationHelm
  , loadObservationNative
  , ObservationNativeError (..)
  , loadObservationNativeChecked
  , observationBytesFromMutation
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.KeyMap qualified as KM
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
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Adapters.KubernetesStuckPod (PodReplacement)
import Nagare.Inventory.BackendMap
import Nagare.Inventory.Components.Foundation (compileContributedNamespaces)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (operationIdText)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes
import Nagare.Resource.Types

-- The constructor stays private. Neither map contains a stamped mutation.
data ObservationNative = ObservationNative
  { observationKubernetes :: !(Map ResourceId (ManagedResource, ByteString))
  , observationHelm :: !(Map ResourceId (ManagedResource, ByteString))
  }
  deriving stock (Eq, Show)

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
            && [helmMutationResource mutation] == NE.toList (plannedResources operation)
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
        ( [resource] == NE.toList (plannedResources operation)
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
            && [replacement ^. #member] == NE.toList (plannedResources operation)
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
            && [mutationResource mutation] == NE.toList (plannedResources operation)
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

-- | Only supplied declarations are read. No listing, review scan, head read,
-- provider call, or packaged source lookup occurs here, including on a miss.
data ObservationNativeError
  = ObservationNativeMissing !ContentDigest
  | ObservationNativeInvalid !Text
  deriving stock (Eq, Show)

loadObservationNative :: InventoryStore -> [ManagedResource] -> IO (Either Text ObservationNative)
loadObservationNative store declarations = do
  loaded <- loadObservationNativeChecked store declarations
  pure $ first renderError loaded
  where
    renderError (ObservationNativeInvalid reason) = reason
    renderError (ObservationNativeMissing digest) =
      "observation native bytes are missing for "
        <> digestText digest
        <> "; run inventory store materialize-native to extract historical review evidence"

-- | A typed miss lets execution retain compatibility with old publishers.
-- Invalid bytes never trigger archive fallback. This still supplies data only;
-- the original complete review remains execution authority.
loadObservationNativeChecked ::
  InventoryStore -> [ManagedResource] -> IO (Either ObservationNativeError ObservationNative)
loadObservationNativeChecked store declarations = do
  let native =
        [ member
        | member <- declarations
        , member ^. #executor `elem` [KubernetesExecutor, HelmExecutor]
        ]
      digests =
        Map.fromList
          [ (digest, ())
          | member <- native
          , Just digest <- [nativeDigest (member ^. #spec)]
          ]
  loaded <- traverseWithKeyRead digests
  pure $ do
    -- A missing member must not hide corruption in another selected member.
    case [reason | Left (ObservationNativeInvalid reason) <- Map.elems loaded] of
      reason : _ -> Left (ObservationNativeInvalid reason)
      [] -> pure ()
    members <- sequence loaded
    entries <- first ObservationNativeInvalid (traverse (validate members) native)
    pure
      ( ObservationNative
          ( Map.fromList
              [ (member ^. #identity, (member, bytes))
              | (member, bytes) <- entries
              , member ^. #executor == KubernetesExecutor
              ]
          )
          ( Map.fromList
              [ (member ^. #identity, (member, bytes))
              | (member, bytes) <- entries
              , member ^. #executor == HelmExecutor
              ]
          )
      )
  where
    traverseWithKeyRead = Map.traverseWithKey $ \digest _ -> do
      result <- readObject store (objectKeyFor "native" digest)
      pure $ do
        bytes <-
          first (ObservationNativeInvalid . T.pack . show) result
            >>= maybe (Left (ObservationNativeMissing digest)) Right
        unless
          (contentDigest bytes == digest)
          (Left (ObservationNativeInvalid "observation native digest mismatch"))
        pure bytes
    validate members member = do
      bytes <- case nativeDigest (member ^. #spec) of
        Just digest -> maybe (Left "selected observation bytes are absent") Right (Map.lookup digest members)
        Nothing -> do
          namespaces <- compileContributedNamespaces [Managed member]
          backends <- compileContributedBackendMaps [Managed member]
          settings <- compileContributedShomeiSettings [Managed member]
          maybe
            (Left "selected native declaration has no digest or supported exact reconstruction")
            (Right . snd)
            (Map.lookup (member ^. #identity) (namespaces <> backends <> settings))
      case member ^. #executor of
        HelmExecutor -> case (member ^. #address, member ^. #spec) of
          (Helm {}, HelmRelease _ digest) | digest == contentDigest bytes -> pure ()
          _ -> Left "observation Helm contract differs from typed release"
        KubernetesExecutor -> do
          value <- first T.pack (eitherDecodeStrict' bytes)
          cluster <- case member ^. #address of
            Kubernetes target _ _ _ _ -> Right target
            _ -> Left "observation declaration has no Kubernetes address"
          (compiled, rebound) <-
            first
              (T.pack . show)
              ( bindKubernetesObject
                  KubernetesInput
                    { resourceId = member ^. #identity
                    , ownerScope = member ^. #owner
                    , clusterId = cluster
                    , inputObject = value
                    , objectDigest = contentDigest bytes
                    , lifecyclePolicy = member ^. #lifecycle
                    , inputDataPolicy = member ^. #dataPolicy
                    , inputSensitivity = member ^. #sensitivity
                    , sourceLocation = member ^. #source
                    }
              )
          let bound =
                compiled
                  { dependencies = member ^. #dependencies
                  , delegations = member ^. #delegations
                  , spec = case nativeDigest (member ^. #spec) of
                      Nothing -> member ^. #spec
                      Just _ -> compiled ^. #spec
                  }
          unless
            (bound == member && rebound == bytes)
            (Left "observation Kubernetes bytes differ from typed declaration")
        _ -> Left "unsupported native observation executor"
      pure (member, bytes)

nativeDigest :: DesiredSpec -> Maybe ContentDigest
nativeDigest = \case
  NativeObject digest -> Just digest
  KnativeService digest -> Just digest
  Certificate _ digest -> Just digest
  StatefulSet _ _ digest -> Just digest
  NamespaceSpec (Just digest) -> Just digest
  HelmRelease _ digest -> Just digest
  _ -> Nothing
