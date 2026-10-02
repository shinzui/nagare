-- | Opt-in reviewed Knative controller collection. Its distinct adapter identity
-- prevents an older/ordinary runtime from executing a cascade review as Orphan.
module Nagare.Inventory.Collection.Adapter (controllerCollectionAdapter, controllerCollectionIdentity) where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Adapters.KubernetesRuntime (mkKubernetesRuntimeOps)
import Nagare.Inventory.Collection.Authority qualified as C
import Nagare.Inventory.Collection.Runtime
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect))
import Nagare.Inventory.KubernetesTransport
import Nagare.Resource.Inventory (ManagedResource)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import System.Exit (ExitCode (..))

controllerCollectionIdentity :: Text
controllerCollectionIdentity = "kubernetes-reviewed-controller-collection"

controllerCollectionAdapter :: KubernetesRuntimeConfig -> Map.Map ResourceId (ManagedResource, ByteString) -> Adapter
controllerCollectionAdapter config specs =
  base
    { adapterIdentity = controllerCollectionIdentity
    , adapterPrepare = prepare
    , adapterPreflight = preflight
    , adapterExecute = execute
    , adapterVerify = verify
    , adapterRecover = recover
    }
  where
    base = mkKubernetesAdapter specs (mkKubernetesRuntimeOps config specs)
    prepare operation = do
      initial <- adapterPrepare base operation
      case initial of
        Left err -> pure (Left err)
        Right prepared -> case decodeBase operation prepared of
          Left reason -> pure (Left (PrepareRefused (plannedOperationId operation) reason))
          Right mutation -> do
            snapshot <- observeCollectionNamespace config (namespaceOf mutation)
            pure $ first (PrepareRefused (plannedOperationId operation)) $ do
              (apis, nodes) <- snapshot
              (expectedUid, expectedVersion) <- identityOf mutation
              parent <- case [n | n <- nodes, C.token n == "services.serving.knative.dev", C.name n == nameOf mutation] of
                [one] | C.uid one == expectedUid && C.version one == expectedVersion -> Right one
                _ -> Left "parent identity changed during collection review"
              authority <- C.authorizeCollection parent apis nodes
              value <- first T.pack (eitherDecodeStrict (preparedNativeBytes prepared))
              bytes <- canonicalValue $ case value of
                Object fields -> Object (KM.insert "controllerCollection" (toJSON authority) fields)
                _ -> value
              pure
                ( PreparedNative
                    bytes
                    ( preparedPublicSummary prepared
                        <> "; Background garbage collection of exclusive controller descendants (including later-created descendants); observed "
                        <> T.pack (show (length (C.descendants authority)))
                        <> "; preserve inventoried neighbors"
                    )
                )
    decodeBase operation prepared = do
      mutation <- first T.pack (eitherDecodeStrict (preparedNativeBytes prepared))
      unless
        ( plannedAction operation == RetireResource
            && mutationAction mutation == RetireResource
            && mutationVersion mutation == 1
            && mutationOperation mutation == plannedOperationId operation
        )
        (Left "controller collection only accepts a reviewed RetireResource mutation")
      case mutationAddress mutation of
        Kubernetes _ "serving.knative.dev" kind (Just _) _ | nameText kind == "service" -> pure ()
        _ -> Left "controller collection only supports a namespaced Knative Service"
      pure mutation
    decode operation prepared = do
      mutation <- decodeBase operation prepared
      value <- first T.pack (eitherDecodeStrict (preparedNativeBytes prepared))
      authority <- first T.pack (parseEither (withObject "collection mutation" (.: "controllerCollection")) value)
      (expectedUid, expectedVersion) <- identityOf mutation
      let parent = C.parent authority
      unless
        ( C.namespace parent == namespaceOf mutation
            && C.name parent == nameOf mutation
            && C.uid parent == expectedUid
            && C.version parent == expectedVersion
        )
        (Left "collection authority differs from reviewed parent")
      checked <-
        C.authorizeCollection
          parent
          (C.apiResources authority)
          (parent : C.descendants authority <> C.protected authority)
      unless (checked == authority) (Left "collection authority graph is invalid or noncanonical")
      pure (mutation, authority)
    preflight operation prepared = do
      original <- adapterPreflight base operation prepared
      case original >> decode operation prepared of
        Left reason -> pure (Left reason)
        Right (mutation, authority) -> do
          current <- observeCollectionNamespace config (namespaceOf mutation)
          pure (current >>= uncurry (C.checkCollectionBefore authority))
    execute operation prepared = do
      guarded <- preflight operation prepared
      case guarded >> decode operation prepared of
        Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
        Right (mutation, authority) -> do
          let root = C.parent authority
              path = "/apis/serving.knative.dev/v1/namespaces/" <> C.namespace root <> "/services/" <> C.name root
              body =
                canonicalValue
                  ( object
                      [ "apiVersion" .= ("meta.k8s.io/v1" :: Text)
                      , "kind" .= ("DeleteOptions" :: Text)
                      , "preconditions" .= object ["uid" .= C.uid root, "resourceVersion" .= C.version root]
                      , "propagationPolicy" .= ("Background" :: Text)
                      ]
                  )
          case body of
            Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
            Right bytes -> do
              result <- invokeKubectl config ["delete", "--raw", T.unpack path, "-f", "-"] (T.unpack (TE.decodeUtf8 bytes))
              case result of
                Right (ExitSuccess, _, _) -> do
                  _ <-
                    invokeKubectl
                      config
                      [ "wait"
                      , "--for=delete"
                      , "service.serving.knative.dev/" <> T.unpack (nameOf mutation)
                      , "--timeout=30s"
                      , "--namespace"
                      , T.unpack (namespaceOf mutation)
                      ]
                      ""
                  completion <- verify operation prepared
                  pure (either AdapterEffectAmbiguous (const AdapterEffectCompleted) completion)
                _ -> pure (AdapterEffectAmbiguous "controller DELETE outcome unknown; resume the original review")
    verify operation prepared = do
      original <- adapterVerify base operation prepared
      case original >> decode operation prepared of
        Left reason -> pure (Left reason)
        Right (mutation, authority) -> do
          current <- observeCollectionNamespace config (namespaceOf mutation)
          pure $ do
            (apis, nodes) <- current
            C.checkCollectionComplete authority apis nodes
            canonicalValue (object ["authority" .= authority, "removed" .= True]) >>= pure . contentDigest
    recover operation prepared = case decode operation prepared of
      Left reason -> pure (RecoveryUnresolved reason)
      Right _ -> do
        original <- adapterRecover base operation prepared
        case original of
          RecoveryProvedComplete _ -> either RecoveryUnresolved RecoveryProvedComplete <$> verify operation prepared
          RecoverySafeToRetry -> either RecoveryUnresolved (const RecoverySafeToRetry) <$> preflight operation prepared
          other -> pure other

identityOf :: KubernetesMutation -> Either Text (Text, Text)
identityOf mutation = case mutationBefore mutation of
  KubernetesPresent uid version _ _ -> Right (physicalIdentityText uid, version)
  _ -> Left "controller collection needs a ready present reviewed parent"

namespaceOf :: KubernetesMutation -> Text
namespaceOf mutation = case mutationAddress mutation of
  Kubernetes _ _ _ (Just namespace) _ -> nameText namespace
  _ -> ""

nameOf :: KubernetesMutation -> Text
nameOf mutation = case mutationAddress mutation of
  Kubernetes _ _ _ _ name -> nameText name
  _ -> ""
