-- | Read-only native evidence, separate from the private mutation envelope.
-- Accepted declarations supply authority; digest-addressed bytes supply data.
-- This type cannot be admitted as a review or used to authorize an operation.
-- Extracting these bytes from a mutation is
-- "Nagare.Inventory.ObservationNative.Mutation", so a reader of them does
-- not link the adapters (MasterPlan 37).
module Nagare.Inventory.ObservationNative
  ( ObservationNative
  , observationKubernetes
  , observationHelm
  , loadObservationNative
  , ObservationNativeError (..)
  , loadObservationNativeChecked
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.BackendMap
import Nagare.Inventory.Components.Foundation (compileContributedNamespaces)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Store
import Nagare.Inventory.TunnelRoute (reboundAliases)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes
import Nagare.Resource.Types

-- The constructor stays private. Neither map contains a stamped mutation.
data ObservationNative = ObservationNative
  { observationKubernetes :: !(Map ResourceId (ManagedResource, ByteString))
  , observationHelm :: !(Map ResourceId (ManagedResource, ByteString))
  }
  deriving stock (Eq, Show)

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
  -- One concurrent read of every member, each with its own result (EP-218).
  fetched <- readImmutableObjectsEach store [objectKeyFor "native" digest | digest <- Map.keys digests]
  let loaded = Map.mapWithKey (\digest _ -> checked digest (Map.findWithDefault (Right Nothing) (objectKeyFor "native" digest) fetched)) digests
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
    checked digest result = do
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
                  { aliases = reboundAliases member compiled
                  , dependencies = member ^. #dependencies
                  , delegations = member ^. #delegations
                  , spec = case nativeDigest (member ^. #spec) of
                      Nothing -> member ^. #spec
                      Just _ -> compiled ^. #spec
                  }
          unless
            (bound == member && rebound == bytes)
            (Left ("observation Kubernetes bytes differ from typed declaration: " <> resourceIdText (member ^. #identity)))
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
