-- | F37: configuration drift written by another field manager is repaired only
-- through an explicit reviewed takeover. Planning records the exact foreign
-- managed-field entries; the real transport forces Nagare's fields only while
-- the live object still has exactly those foreign owners, and the same UID and
-- resourceVersion.
module InventoryKubernetesFieldTakeoverSpec (kubernetesFieldTakeoverTests) where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft, isRight)
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.IORef
import Data.List (isPrefixOf)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Adapters.KubernetesRuntime (mkKubernetesRuntimeOps)
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect))
import Nagare.Inventory.Kubernetes
import Nagare.Inventory.KubernetesConfiguration
import Nagare.Inventory.KubernetesTransport
import Nagare.Inventory.ObservationNative (observationBytesFromMutation)
import Nagare.Resource.Inventory (ManagedResource)
import Nagare.Resource.Kubernetes
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.Support.Kubernetes qualified as K
import System.Exit (ExitCode (..))
import Test.Tasty
import Test.Tasty.HUnit

kubernetesFieldTakeoverTests :: TestTree
kubernetesFieldTakeoverTests =
  testGroup
    "reviewed Kubernetes field takeover (F37)"
    [ testCase "without the opt-in the review stays strict and apply refuses the foreign manager" $ do
        mutation <- prepared Nothing
        mutationVersion mutation @?= 1
        mutationTakeover mutation @?= Nothing
        (result, applies) <- transport mutation (live "kubernetes-uid-1" "4" [own, patch "t2"]) Nothing
        assertKnownNoEffect "another writer: kubectl-patch" result
        applies @?= 0
    , testCase "a reviewed takeover records the foreign entries and forces only while they are unchanged" $ do
        mutation <- prepared (Just (\_ -> pure (Right (live "kubernetes-uid-1" "4" [own, patch "t1"]))))
        mutationVersion mutation @?= 3
        mutationTakeover mutation @?= Just (FieldTakeover K.physical "4" [untimed (patch "t1")])
        -- Review readers accept the takeover envelope.
        observationBytesFromMutation (ok (mkContextId "test")) "kubernetes-conditional-object" "1" K.updateOperation (BL.toStrict (encode mutation))
          @?= Right (Just bytes)
        -- A later write by the same manager to the same fields changes only its timestamp.
        (result, applies) <- transport mutation (live "kubernetes-uid-1" "4" [own, patch "t2"]) (Just (live "kubernetes-uid-1" "5" [own]))
        result @?= AdapterEffectCompleted
        applies @?= 1
    , testCase "a new foreign manager after review refuses before any write" $ do
        mutation <- prepared (Just (\_ -> pure (Right (live "kubernetes-uid-1" "4" [own, patch "t1"]))))
        (result, applies) <- transport mutation (live "kubernetes-uid-1" "4" [own, patch "t1", edit]) Nothing
        assertKnownNoEffect "another writer: kubectl-edit" result
        applies @?= 0
        -- The same manager owning different fields is a different entry.
        assertBool
          "changed foreign fields accepted"
          (isLeft (confirmReviewedFieldTakeover Nothing [untimed (patch "t1")] K.physical "4" (live "kubernetes-uid-1" "4" [own, patchFields "t1" extraField])))
    , testCase "a changed UID or resourceVersion refuses the reviewed takeover" $ do
        state <- newIORef drifted
        calls <- newIORef (0 :: Int)
        let adapter = takeoverAdapter state calls (\_ -> pure (Right (live "kubernetes-uid-1" "4" [own, patch "t1"])))
        native <- adapterPrepare adapter K.updateOperation >>= K.expectRight
        mutation <- K.expectRight (eitherDecodeStrict' (preparedNativeBytes native))
        writeIORef state (KubernetesPresent (ok (mkPhysicalIdentity "replacement")) "4" (Just K.resource) (contentDigest "drifted"))
        adapterPreflight adapter K.updateOperation native >>= assertBool "replaced object accepted" . isLeft
        (replaced, replacedApplies) <- transport mutation (live "replacement" "4" [own, patch "t1"]) Nothing
        assertKnownNoEffect "changed after the reviewed observation" replaced
        (moved, movedApplies) <- transport mutation (live "kubernetes-uid-1" "5" [own, patch "t1"]) Nothing
        assertKnownNoEffect "changed after the reviewed observation" moved
        (replacedApplies, movedApplies) @?= (0, 0)
        readIORef calls >>= (@?= 0)
    , testCase "a takeover that leaves foreign fields is not reported complete" $ do
        mutation <- prepared (Just (\_ -> pure (Right (live "kubernetes-uid-1" "4" [own, patch "t1"]))))
        (result, applies) <- transport mutation (live "kubernetes-uid-1" "4" [own, patch "t1"]) (Just (live "kubernetes-uid-1" "5" [own, patchFields "t3" extraField]))
        case result of
          AdapterEffectAmbiguous reason -> assertBool (T.unpack reason) ("another writer" `T.isInfixOf` reason)
          other -> assertFailure (show other)
        applies @?= 1
    , testCase "planning refuses when the object moves between its observation and managed-field read" $ do
        state <- newIORef drifted
        calls <- newIORef (0 :: Int)
        let adapter = takeoverAdapter state calls (\_ -> pure (Right (live "kubernetes-uid-1" "5" [own, patch "t1"])))
        adapterPrepare adapter K.updateOperation >>= assertBool "moved object prepared" . isLeft
    , testCase "an update is proved only on the object it wrote, not a same-stamp replacement (ADR 27, N9)" $ do
        state <- newIORef drifted
        calls <- newIORef (0 :: Int)
        let runtime = K.ops state calls
            adapter = mkKubernetesAdapterWithConfigurationObservation bound runtime (traverse (kubernetesObserve runtime)) (kubernetesObserve runtime) noReceipt noScratch (\_ -> pure (Left "no live object reader"))
        native <- adapterPrepare adapter K.updateOperation >>= K.expectRight
        mutation <- K.expectRight (eitherDecodeStrict' (preparedNativeBytes native)) :: IO KubernetesMutation
        writeIORef state (KubernetesPresent K.physical "5" (Just K.resource) (mutationNativeDigest mutation))
        adapterVerify adapter K.updateOperation native >>= assertBool "the written object was not proved" . isRight
        writeIORef state (KubernetesPresent (ok (mkPhysicalIdentity "replacement-uid")) "1" (Just K.resource) (mutationNativeDigest mutation))
        adapterVerify adapter K.updateOperation native >>= assertBool "a same-stamp replacement proved the update" . isLeft
    , testCase "only an exactly bound version-3 update may carry a takeover" $ do
        state <- newIORef drifted
        calls <- newIORef (0 :: Int)
        let adapter = takeoverAdapter state calls (\_ -> pure (Right (live "kubernetes-uid-1" "4" [own, patch "t1"])))
        native <- adapterPrepare adapter K.updateOperation >>= K.expectRight
        mutation <- K.expectRight (eitherDecodeStrict' (preparedNativeBytes native))
        let tampered changed = native {preparedNativeBytes = BL.toStrict (encode changed)}
            unbound = FieldTakeover (ok (mkPhysicalIdentity "other")) "4" [untimed (patch "t1")]
        adapterPreflight adapter K.updateOperation native >>= K.expectRight
        adapterPreflight adapter K.updateOperation (tampered mutation {mutationVersion = 1}) >>= assertBool "version 1 takeover accepted" . isLeft
        adapterPreflight adapter K.updateOperation (tampered mutation {mutationTakeover = Just unbound}) >>= assertBool "unbound takeover accepted" . isLeft
        adapterPreflight adapter K.updateOperation (tampered mutation {mutationTakeover = Nothing}) >>= assertBool "version 3 without takeover accepted" . isLeft
    ]

-- | The live object as kubectl returns it with managed fields.
live :: Text -> Text -> [Value] -> Value
live uid revision entries =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("ConfigMap" :: Text)
    , "metadata" .= object ["name" .= ("settings" :: Text), "namespace" .= ("personal" :: Text), "uid" .= uid, "resourceVersion" .= revision, "managedFields" .= entries]
    , "data" .= object ["mode" .= ("edited" :: Text)]
    ]

own, edit :: Value
own = entry "nagare-inventory" "Apply" "t0" modeField
edit = entry "kubectl-edit" "Update" "t4" modeField

patch :: Text -> Value
patch time = patchFields time modeField

patchFields :: Text -> Value -> Value
patchFields = entry "kubectl-patch" "Update"

modeField, extraField :: Value
modeField = object ["f:data" .= object ["f:mode" .= object []]]
extraField = object ["f:data" .= object ["f:extra" .= object []]]

entry :: Text -> Text -> Text -> Value -> Value
entry manager operation time fields =
  object ["manager" .= manager, "operation" .= operation, "apiVersion" .= ("v1" :: Text), "fieldsType" .= ("FieldsV1" :: Text), "fieldsV1" .= fields, "time" .= time]

untimed :: Value -> Value
untimed (Object fields) = Object (KM.delete "time" fields)
untimed other = other

desired :: Value
desired =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("ConfigMap" :: Text)
    , "metadata" .= object ["name" .= ("settings" :: Text), "namespace" .= ("personal" :: Text)]
    , "data" .= object ["mode" .= ("reviewed" :: Text)]
    ]

bytes :: ByteString
bytes = ok (canonicalValue desired)

bound :: Map.Map ResourceId (ManagedResource, ByteString)
bound = Map.singleton K.resource (ok (bindKubernetesObject (K.input {inputObject = desired, objectDigest = contentDigest bytes})))

drifted :: KubernetesState
drifted = KubernetesPresent K.physical "4" (Just K.resource) (contentDigest "drifted")

takeoverAdapter :: IORef KubernetesState -> IORef Int -> (ProviderAddress -> IO (Either Text Value)) -> Adapter
takeoverAdapter state calls reader =
  mkKubernetesAdapterWithFieldTakeover bound runtime (traverse (kubernetesObserve runtime)) (kubernetesObserve runtime) noReceipt noScratch reader
  where
    runtime = K.ops state calls

prepared :: Maybe (ProviderAddress -> IO (Either Text Value)) -> IO KubernetesMutation
prepared reader = do
  state <- newIORef drifted
  calls <- newIORef (0 :: Int)
  let runtime = K.ops state calls
      adapter = case reader of
        Nothing -> mkKubernetesAdapterWithConfigurationObservation bound runtime (traverse (kubernetesObserve runtime)) (kubernetesObserve runtime) noReceipt noScratch (\_ -> pure (Left "no live object reader"))
        Just selected -> takeoverAdapter state calls selected
  native <- adapterPrepare adapter K.updateOperation >>= K.expectRight
  K.expectRight (eitherDecodeStrict' (preparedNativeBytes native))

-- | Runs the production transport against a modelled API server. A get
-- returns the live object; an apply records the write and, when given,
-- replaces the live object with the post-write state.
transport :: KubernetesMutation -> Value -> Maybe Value -> IO (AdapterExecution, Int)
transport mutation initial afterApply = do
  world <- newIORef initial
  applies <- newIORef (0 :: Int)
  let handle request = case request ^. #arguments of
        "get" : _ -> Right . (ExitSuccess,,"") . T.unpack . TE.decodeUtf8 . BL.toStrict . encode <$> readIORef world
        arguments@("apply" : _) -> do
          assertBool "apply was not a forced server-side apply" (["--server-side", "--force-conflicts"] `isPrefixOf` drop 1 arguments)
          modifyIORef' applies (+ 1)
          traverse_ (writeIORef world) afterApply
          pure (Right (ExitSuccess, "", ""))
        other -> assertFailure ("unmodelled kubectl request: " <> show other) >> pure (Left "unmodelled")
      config = withKubectlInterpreter (runKubectlWith handle) (KubernetesRuntimeConfig (ok (mkContextId "test")) "test" (pure (Right ())))
  result <- kubernetesMutateConditional (mkKubernetesRuntimeOps config bound) mutation
  (result,) <$> readIORef applies

assertKnownNoEffect :: Text -> AdapterExecution -> Assertion
assertKnownNoEffect expected result = case result of
  AdapterEffectFailed (KnownNoEffect reason) -> assertBool (T.unpack reason) (expected `T.isInfixOf` reason)
  other -> assertFailure ("expected a known no-effect refusal, got " <> show other)

noReceipt :: ResourceId -> PhysicalIdentity -> IO (Either Text ByteString)
noReceipt _ _ = pure (Left "not a backup")

noScratch :: ResourceId -> PhysicalIdentity -> IO (Either Text Bool)
noScratch _ _ = pure (Right False)

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
