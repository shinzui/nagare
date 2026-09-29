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
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.BackendMap
import Nagare.Inventory.Components.Foundation (compileContributedNamespaces)
import Nagare.Inventory.Digest (contentDigest)
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
  | identity == "kubernetes-conditional-object" && version == "1" = do
      mutation <- first T.pack (eitherDecodeStrict' bytes)
      unless
        ( mutationVersion mutation == 1
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
