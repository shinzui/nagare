-- | Runtime proof that a restore scratch StatefulSet's pod failed, so a
-- restore-only review can be abandoned instead of wedging the store.
module Nagare.Inventory.Adapters.RestoreScratch
  ( restoreScratchPodFailed
  , restoreScratchFailureFromPodList
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Nagare.Dsl.Prelude
import Nagare.Inventory.KubernetesTransport (KubernetesRuntimeConfig (..), invokeKubectl)
import Nagare.Resource.Inventory (ManagedResource (..))
import Nagare.Resource.Types
import System.Exit (ExitCode (ExitSuccess))

-- | Prove that a restore scratch StatefulSet's pod failed. Only a
-- StatefulSet whose bound object carries the @nagare.dev/restore-scratch@
-- label qualifies; pods are read by that label and must be controlled by the
-- exact StatefulSet UID.
restoreScratchPodFailed ::
  KubernetesRuntimeConfig ->
  Map ResourceId (ManagedResource, ByteString) ->
  ResourceId ->
  PhysicalIdentity ->
  IO (Either Text Bool)
restoreScratchPodFailed config specs resource physical =
  case Map.lookup resource specs of
    Just (declaration, native) -> case (address declaration, scratchLabel native) of
      (Kubernetes _ "apps" kind (Just namespace) _, Just scratch)
        | nameText kind == "statefulset" -> do
            guarded <- runtimeGuard config
            case guarded of
              Left reason -> pure (Left ("cluster guard refused restore scratch Pod read: " <> reason))
              Right () -> do
                result <-
                  invokeKubectl
                    config
                    [ "get"
                    , "pods"
                    , "--namespace"
                    , T.unpack (nameText namespace)
                    , "-l"
                    , "nagare.dev/restore-scratch=" <> T.unpack scratch
                    , "-o"
                    , "json"
                    ]
                    ""
                pure $ do
                  (code, output, _) <- result
                  unless (code == ExitSuccess) (Left "Kubernetes restore scratch Pod read failed")
                  pods <- first T.pack (eitherDecodeStrict' (TE.encodeUtf8 (T.pack output)))
                  restoreScratchFailureFromPodList physical pods
      _ -> pure (Left "resource is not a restore scratch StatefulSet")
    Nothing -> pure (Left "restore scratch StatefulSet lacks its bound native object")
  where
    scratchLabel bytes = case eitherDecodeStrict' bytes of
      Right (Object root)
        | Just (Object metadata) <- KM.lookup "metadata" root
        , Just (Object labels) <- KM.lookup "labels" metadata
        , Just (String value) <- KM.lookup "nagare.dev/restore-scratch" labels ->
            Just value
      _ -> Nothing

-- | True when a Pod controlled by the StatefulSet has an init or main container
-- that terminated with a non-zero exit code, either now or before a restart.
restoreScratchFailureFromPodList :: PhysicalIdentity -> Value -> Either Text Bool
restoreScratchFailureFromPodList physical (Object root) = case KM.lookup "items" root of
  Just (Array items) -> Right (any failedOwnedPod (V.toList items))
  _ -> Left "Kubernetes Pod list lacks items"
  where
    failedOwnedPod (Object pod)
      | Just (Object metadata) <- KM.lookup "metadata" pod
      , Just (Array owners) <- KM.lookup "ownerReferences" metadata
      , any controlledByStatefulSet (V.toList owners)
      , Just (Object status) <- KM.lookup "status" pod =
          any failedContainer (statuses "initContainerStatuses" status <> statuses "containerStatuses" status)
    failedOwnedPod _ = False
    statuses key status = case KM.lookup key status of
      Just (Array values) -> V.toList values
      _ -> []
    failedContainer (Object container) =
      nonZero (KM.lookup "state" container)
        || (restarted container && nonZero (KM.lookup "lastState" container))
    failedContainer _ = False
    restarted container = case KM.lookup "restartCount" container of
      Just (Number count) -> count >= 1
      _ -> False
    nonZero (Just (Object state))
      | Just (Object terminated) <- KM.lookup "terminated" state
      , Just (Number code) <- KM.lookup "exitCode" terminated =
          code /= 0
    nonZero _ = False
    controlledByStatefulSet (Object owner) =
      KM.lookup "kind" owner == Just (String "StatefulSet")
        && KM.lookup "uid" owner == Just (String (physicalIdentityText physical))
        && KM.lookup "controller" owner == Just (Bool True)
    controlledByStatefulSet _ = False
restoreScratchFailureFromPodList _ _ = Left "Kubernetes Pod list is not an object"
