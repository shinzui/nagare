module InventoryKubernetesConfigurationSpec (kubernetesConfigurationTests) where

import Control.Monad (forM_)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.IORef
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect))
import Nagare.Inventory.Kubernetes
import Nagare.Inventory.KubernetesConfiguration
import Nagare.Inventory.ObservationNative (observationBytesFromMutation)
import Nagare.Resource.Inventory (ManagedResource)
import Nagare.Resource.Kubernetes
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.Support.Kubernetes qualified as K
import Test.Tasty
import Test.Tasty.HUnit

kubernetesConfigurationTests :: TestTree
kubernetesConfigurationTests =
  testGroup
    "versioned Kubernetes configuration"
    [ testCase "status and observation revisions do not change configuration authority" $ do
        let base = observed "4" "False" "old-time"
            progressed = observed "5" "True" "new-time"
        configurationDigest base @?= configurationDigest progressed
        forM_ ["uid", "generation", "labels", "annotations", "finalizers", "ownerReferences"] $ \key -> do
          let altered = metadataField key (String "changed") base
          assertBool "configuration change ignored" (configurationDigest altered /= configurationDigest base)
        fields <- case base of
          Object object' -> pure object'
          other -> assertFailure ("fixture: expected an object, got " <> show other)
        assertBool "spec change ignored" (configurationDigest (Object (KM.insert "spec" (object ["image" .= ("changed" :: Text)]) fields)) /= configurationDigest base)
        assertBool "terminating object accepted" (isLeft (configurationDigest (metadataField "deletionTimestamp" (String "now") base)))
        assertBool "missing ownership accepted" (isLeft (configurationDigest (metadataField "managedFields" Null base)))
    , testCase "v2 refreshes only a matching configuration's conditional revision and v1 remains strict" $ do
        let value =
              object
                [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
                , "kind" .= ("Service" :: Text)
                , "metadata" .= object ["name" .= ("web" :: Text), "namespace" .= ("personal" :: Text)]
                ]
            bytes = K.ok (canonicalValue value)
            bound = Map.singleton K.resource (K.ok (bindKubernetesObject (K.input {inputObject = value, objectDigest = contentDigest bytes})))
            before = KubernetesNotReady K.physical "4" (Just K.resource) (contentDigest "old-configuration")
        state <- newIORef before
        calls <- newIORef (0 :: Int)
        let runtime = K.ops state calls
            legacy = mkKubernetesAdapter bound runtime
            adapter =
              mkKubernetesAdapterWithConfigurationObservation
                bound
                runtime
                (traverse (kubernetesObserve runtime))
                (kubernetesObserveStamped runtime)
                (\_ _ -> pure (Left "not a backup"))
                (\_ _ -> pure (Right False))
                (\_ -> pure (Left "no live object reader"))
        oldReview <- adapterPrepare legacy K.updateOperation >>= K.expectRight
        reviewed <- adapterPrepare adapter K.updateOperation >>= K.expectRight
        mutation <- K.expectRight (eitherDecodeStrict' (preparedNativeBytes reviewed))
        mutationVersion mutation @?= 2
        let extract operation native =
              observationBytesFromMutation
                (kubernetesContext runtime)
                "kubernetes-conditional-object"
                "1"
                operation
                native
        extract K.updateOperation (preparedNativeBytes reviewed) @?= Right (Just bytes)
        extract K.updateOperation (preparedNativeBytes oldReview) @?= Right (Just bytes)
        assertBool
          "version 2 non-update observation accepted"
          (isLeft (extract K.createOperation (BL.toStrict (encode (mutation {mutationAction = CreateResource})))))
        writeIORef state (KubernetesNotReady K.physical "5" (Just K.resource) (contentDigest "old-configuration"))
        adapterPreflight legacy K.updateOperation oldReview >>= assertBool "legacy review changed semantics" . isLeft
        adapterPreflight legacy K.updateOperation reviewed >>= assertBool "v2 ran without its observation capability" . isLeft
        adapterPreflight adapter K.updateOperation reviewed >>= K.expectRight
        forM_
          [ KubernetesNotReady (K.ok (mkPhysicalIdentity "replacement")) "5" (Just K.resource) (contentDigest "old-configuration")
          , KubernetesNotReady K.physical "5" Nothing (contentDigest "old-configuration")
          , KubernetesNotReady K.physical "5" (Just K.resource) (contentDigest "changed-configuration")
          ]
          $ \changed -> do
            writeIORef state changed
            adapterPreflight adapter K.updateOperation reviewed >>= assertBool "changed authority accepted" . isLeft
        readIORef calls >>= (@?= 0)
        writeIORef state (KubernetesNotReady K.physical "6" (Just K.resource) (contentDigest "old-configuration"))
        adapterExecute adapter K.updateOperation reviewed >>= (@?= AdapterEffectCompleted)
        _ <- adapterVerify adapter K.updateOperation reviewed >>= K.expectRight
        adapterRecover adapter K.updateOperation reviewed >>= \case
          RecoveryProvedComplete _ -> pure ()
          other -> assertFailure (show other)
        readIORef calls >>= (@?= 1)
    , testCase "a Knative Service update awaits readiness only while its own write is live (F73)" $ do
        -- RES-4 U3: the reviewed digest is observed only while the stamp and
        -- the desired fields both match, so it is the proof our write is live.
        state <- newIORef (KubernetesNotReady K.physical "4" (Just K.resource) (contentDigest "old-configuration"))
        calls <- newIORef (0 :: Int)
        let adapter = mkKubernetesAdapter knativeBound (K.ops state calls)
        reviewed <- adapterPrepare adapter K.updateOperation >>= K.expectRight
        mutation <- K.expectRight (eitherDecodeStrict' (preparedNativeBytes reviewed))
        writeIORef state (KubernetesNotReady K.physical "5" (Just K.resource) (mutationNativeDigest mutation))
        adapterRecover adapter K.updateOperation reviewed >>= (@?= RecoveryAwaitingReadiness K.physical)
        -- Another write of this member's left the object unready: ours is not live.
        writeIORef state (KubernetesNotReady K.physical "6" (Just K.resource) (contentDigest "another-review"))
        adapterRecover adapter K.updateOperation reviewed >>= \case
          RecoveryUnresolved _ -> pure ()
          other -> assertFailure ("another write was awaited as ours: " <> show other)
        case adapterSettle adapter of
          Nothing -> assertFailure "the Kubernetes adapter does not settle"
          Just settle ->
            settle K.updateOperation reviewed >>= \case
              SettledLanded _ -> assertFailure "another write settled as our landed update"
              _ -> pure ()
    , testCase "status race refuses the conditional write and only unchanged configuration can retry" $ do
        let value =
              object
                [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
                , "kind" .= ("Service" :: Text)
                , "metadata" .= object ["name" .= ("web" :: Text), "namespace" .= ("personal" :: Text)]
                ]
            bytes = K.ok (canonicalValue value)
            bound = Map.singleton K.resource (K.ok (bindKubernetesObject (K.input {inputObject = value, objectDigest = contentDigest bytes})))
            before revision digest = KubernetesNotReady K.physical revision (Just K.resource) (contentDigest digest)
        state <- newIORef (before "4" "old-configuration")
        calls <- newIORef (0 :: Int)
        race <- newIORef True
        let base = K.ops state calls
            runtime =
              base
                { kubernetesMutateConditional = \mutation -> do
                    racing <- readIORef race
                    when racing (writeIORef state (before "5" "old-configuration"))
                    kubernetesMutateConditional base mutation
                }
            adapter =
              mkKubernetesAdapterWithConfigurationObservation
                bound
                runtime
                (traverse (kubernetesObserve runtime))
                (kubernetesObserveStamped runtime)
                (\_ _ -> pure (Left "not a backup"))
                (\_ _ -> pure (Right False))
                (\_ -> pure (Left "no live object reader"))
        reviewed <- adapterPrepare adapter K.updateOperation >>= K.expectRight
        adapterExecute adapter K.updateOperation reviewed >>= \case
          AdapterEffectFailed (KnownNoEffect _) -> pure ()
          other -> assertFailure (show other)
        readIORef calls >>= (@?= 0)
        adapterRecover adapter K.updateOperation reviewed >>= (@?= RecoverySafeToRetry)
        writeIORef state (before "6" "changed-configuration")
        adapterRecover adapter K.updateOperation reviewed >>= \case
          RecoveryUnresolved _ -> pure ()
          other -> assertFailure (show other)
        writeIORef race False
        writeIORef state (before "7" "old-configuration")
        adapterExecute adapter K.updateOperation reviewed >>= (@?= AdapterEffectCompleted)
        readIORef calls >>= (@?= 1)
    ]

observed :: Text -> Text -> Text -> Value
observed revision ready timestamp =
  object
    [ "metadata"
        .= object
          [ "uid" .= ("uid-1" :: Text)
          , "resourceVersion" .= revision
          , "generation" .= (1 :: Int)
          , "labels" .= object ["app" .= ("web" :: Text)]
          , "annotations" .= object ["owner" .= ("accepted" :: Text)]
          , "managedFields"
              .= [ object ["manager" .= ("nagare-inventory" :: Text), "time" .= timestamp, "fieldsV1" .= object ["f:spec" .= object []]]
                 , object ["manager" .= ("controller" :: Text), "subresource" .= ("status" :: Text), "time" .= timestamp, "fieldsV1" .= object ["f:status" .= object []]]
                 ]
          ]
    , "spec" .= object ["image" .= ("old" :: Text)]
    , "status" .= object ["ready" .= ready]
    ]

metadataField :: Key -> Value -> Value -> Value
metadataField key value (Object root) = case KM.lookup "metadata" root of
  Just (Object metadata) -> Object (KM.insert "metadata" (Object (KM.insert key value metadata)) root)
  _ -> error "fixture metadata missing"
metadataField _ _ _ = error "fixture object missing"

-- | A bound Knative Service.
knativeBound :: Map.Map ResourceId (ManagedResource, ByteString)
knativeBound =
  Map.singleton K.resource (K.ok (bindKubernetesObject (K.input {inputObject = value, objectDigest = contentDigest (K.ok (canonicalValue value))})))
  where
    value =
      object
        [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
        , "kind" .= ("Service" :: Text)
        , "metadata" .= object ["name" .= ("web" :: Text), "namespace" .= ("personal" :: Text)]
        ]
