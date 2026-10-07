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
import Nagare.Inventory.Adapters.KubernetesProof (requireWriteTarget)
import Nagare.Inventory.Adapters.KubernetesRuntime (mkKubernetesRuntimeOps)
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect))
import Nagare.Inventory.Kubernetes
import Nagare.Inventory.KubernetesConfiguration
import Nagare.Inventory.KubernetesTransport
import Nagare.Inventory.ObservationNative (observationBytesFromMutation)
import Nagare.Resource.Inventory (ManagedResource)
import Nagare.Resource.Kubernetes
import Nagare.Resource.Policy (LifecyclePolicy (DeleteWhenUnreferenced))
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
        assertKnownNoEffect "replaced after the reviewed observation" replaced
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
            adapter = mkKubernetesAdapterWithRecoveryProbes bound runtime (traverse (kubernetesObserve runtime)) noReceipt noScratch
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
    , testCase "an update the API server refuses with a 4xx is a known no effect; a lost connection stays ambiguous (G4)" $ do
        mutation <- prepared Nothing
        refusingTransport mutation "Error from server (Conflict): Operation cannot be fulfilled on configmaps \"settings\": the object has been modified"
          >>= assertKnownNoEffect "Error from server (Conflict)"
        lost <- refusingTransport mutation "Unable to connect to the server: dial tcp 10.0.0.1:6443: i/o timeout"
        case lost of
          AdapterEffectAmbiguous _ -> pure ()
          other -> assertFailure ("a lost connection was classed " <> show other)
    , testCase "an update guarded by UID, stamp and field owners writes with the fresh resourceVersion (G6)" $ do
        mutation <- stampedUpdate
        -- RES-4 U10: a status write moved resourceVersion; the guard does not compare it.
        (churned, churnedBodies) <- scriptedTransport mutation (stampedLive "5" stampBefore [own, status]) [Nothing]
        churned @?= AdapterEffectIdentified K.physical AdapterEffectCompleted
        map bodyRevision churnedBodies @?= [Just "5"]
        -- A foreign writer that changed a non-status field (E13 d, e).
        (foreign', foreignBodies) <- scriptedTransport mutation (stampedLive "5" stampBefore [own, edit, status]) [Nothing]
        assertKnownNoEffect "another writer" foreign'
        foreignBodies @?= []
        -- The stamp moved: another write of Nagare's is live, not the reviewed before-state.
        (moved, movedBodies) <- scriptedTransport mutation (stampedLive "5" (contentDigest "another") [own, status]) [Nothing]
        assertKnownNoEffect "stamp" moved
        movedBodies @?= []
    , testCase "a write the object outran is re-read and retried at most three times before the refusal stands (G6, G4)" $ do
        mutation <- stampedUpdate
        let modified = Just "Error from server (Conflict): Operation cannot be fulfilled on configmaps \"settings\": the object has been modified; please apply your changes to the latest version and try again"
        (recovered, recoveredBodies) <- scriptedTransport mutation (stampedLive "5" stampBefore [own, status]) [modified, modified, Nothing]
        recovered @?= AdapterEffectIdentified K.physical AdapterEffectCompleted
        length recoveredBodies @?= 3
        (refused, refusedBodies) <- scriptedTransport mutation (stampedLive "5" stampBefore [own, status]) [modified, modified, modified, Nothing]
        assertKnownNoEffect "the object has been modified" refused
        length refusedBodies @?= 3
    , testCase "the adapter guards an update by UID, owner and stamp, not by resourceVersion (G6)" $ do
        -- An update: a status write moved resourceVersion and the whole-object digest.
        (update, updateWrites, updateState) <- stampedAdapter (KubernetesPresent K.physical "4" (Just K.resource) (contentDigest "before"), Just stampBefore)
        updateNative <- adapterPrepare update K.updateOperation >>= K.expectRight
        writeIORef updateState (KubernetesNotReady K.physical "5" (Just K.resource) (contentDigest "churned"), Just stampBefore)
        adapterPreflight update K.updateOperation updateNative >>= (@?= Right ())
        _ <- adapterExecute update K.updateOperation updateNative
        -- The transport takes the write's resourceVersion from its own live read.
        readIORef updateWrites >>= (@?= [KubernetesPresent K.physical "4" (Just K.resource) (contentDigest "before")])
        -- Another stamp is another write of Nagare's: refused before any write.
        writeIORef updateState (KubernetesNotReady K.physical "6" (Just K.resource) (contentDigest "churned"), Just (contentDigest "another"))
        adapterPreflight update K.updateOperation updateNative >>= assertBool "a changed stamp passed preflight" . isLeft
        adapterExecute update K.updateOperation updateNative >>= assertKnownNoEffect "stamp"
        length <$> readIORef updateWrites >>= (@?= 1)
        -- A drift repair's before stamp already is the reviewed digest: the exact before-state guards it.
        repair <- (\pending -> pending {mutationBeforeStamp = Just (mutationNativeDigest pending)}) <$> stampedUpdate
        assertBool "a drift repair passed on its stamp" (isLeft (requireWriteTarget repair (KubernetesPresent K.physical "5" (Just K.resource) (contentDigest "drifted")) (Just (mutationNativeDigest repair))))
    , testCase "a retire is guarded by UID, owner and digest, deletes with the fresh resourceVersion, and never deletes twice (G6, G5)" $ do
        let reviewed = contentDigest (snd (bound Map.! K.resource))
            retireOperation = K.operation RetireResource
        (retire, writes, state) <- stampedAdapterFor deletable (KubernetesPresent K.physical "4" (Just K.resource) reviewed, Nothing)
        native <- adapterPrepare retire retireOperation >>= K.expectRight
        -- A controller write moved resourceVersion; the object is as reviewed.
        writeIORef state (KubernetesPresent K.physical "5" (Just K.resource) reviewed, Nothing)
        adapterPreflight retire retireOperation native >>= (@?= Right ())
        _ <- adapterExecute retire retireOperation native
        readIORef writes >>= (@?= [KubernetesPresent K.physical "5" (Just K.resource) reviewed])
        -- RES-4 U6: a DELETE that finalizers hold leaves the object terminating
        -- with its UID; the retire's effect landed and is not repeated.
        writeIORef state (KubernetesTerminating K.physical "6" (Just K.resource) reviewed, Nothing)
        adapterExecute retire retireOperation native >>= assertKnownNoEffect "changed since review"
        -- Another object, or the reviewed one changed, is not the retire's target.
        writeIORef state (KubernetesPresent (ok (mkPhysicalIdentity "replacement")) "1" (Just K.resource) reviewed, Nothing)
        adapterExecute retire retireOperation native >>= assertKnownNoEffect "changed since review"
        writeIORef state (KubernetesPresent K.physical "7" (Just K.resource) (contentDigest "edited"), Nothing)
        adapterExecute retire retireOperation native >>= assertKnownNoEffect "changed since review"
        length <$> readIORef writes >>= (@?= 1)
    , testCase "an object Nagare created and then updated is Nagare's under both its managed-field entries (E13)" $ do
        -- kubectl create records nagare-inventory as an Update manager; later
        -- applies record it as Apply. Both are Nagare's own.
        mutation <- stampedUpdate
        (updated, bodies) <- scriptedTransport mutation (stampedLive "5" stampBefore [created, own, status]) [Nothing]
        updated @?= AdapterEffectIdentified K.physical AdapterEffectCompleted
        length bodies @?= 1
    , testCase "a corrective update of an unready object reaches the API server (F63, M1)" $ do
        -- The fresh precondition of a correction is the unready object itself.
        mutation <- (\update -> update {mutationBefore = KubernetesNotReady K.physical "5" (Just K.resource) (contentDigest "unready")}) <$> stampedUpdate
        (corrected, bodies) <- scriptedTransport mutation (stampedLive "5" stampBefore [own, status]) [Nothing]
        corrected @?= AdapterEffectIdentified K.physical AdapterEffectCompleted
        map bodyRevision bodies @?= [Just "5"]
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

own, created, edit :: Value
own = entry "nagare-inventory" "Apply" "t0" modeField
created = entry "nagare-inventory" "Update" "t0" modeField
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

-- | The same object, bound for collection when it is no longer declared.
deletable :: Map.Map ResourceId (ManagedResource, ByteString)
deletable = Map.singleton K.resource (ok (bindKubernetesObject (K.input {inputObject = desired, objectDigest = contentDigest bytes, lifecyclePolicy = DeleteWhenUnreferenced})))

drifted :: KubernetesState
drifted = KubernetesPresent K.physical "4" (Just K.resource) (contentDigest "drifted")

takeoverAdapter :: IORef KubernetesState -> IORef Int -> (ProviderAddress -> IO (Either Text Value)) -> Adapter
takeoverAdapter state calls reader =
  mkKubernetesAdapterWithFieldTakeover bound runtime (traverse (kubernetesObserve runtime)) noReceipt noScratch reader
  where
    runtime = K.ops state calls

prepared :: Maybe (ProviderAddress -> IO (Either Text Value)) -> IO KubernetesMutation
prepared reader = do
  state <- newIORef drifted
  calls <- newIORef (0 :: Int)
  let runtime = K.ops state calls
      adapter = case reader of
        Nothing -> mkKubernetesAdapterWithRecoveryProbes bound runtime (traverse (kubernetesObserve runtime)) noReceipt noScratch
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

-- | The transport against a writable object, whose apply fails with the given
-- kubectl error output.
refusingTransport :: KubernetesMutation -> String -> IO AdapterExecution
refusingTransport mutation errors = do
  let handle request = case request ^. #arguments of
        "get" : _ -> pure (Right (ExitSuccess, T.unpack (TE.decodeUtf8 (BL.toStrict (encode (live "kubernetes-uid-1" "4" [own])))), ""))
        "apply" : _ -> pure (Right (ExitFailure 1, "", errors))
        other -> assertFailure ("unmodelled kubectl request: " <> show other) >> pure (Left "unmodelled")
      config = withKubectlInterpreter (runKubectlWith handle) (KubernetesRuntimeConfig (ok (mkContextId "test")) "test" (pure (Right ())))
  kubernetesMutateConditional (mkKubernetesRuntimeOps config bound) mutation

stampBefore :: ContentDigest
stampBefore = contentDigest "before"

-- | A prepared update that recorded its before-state stamp.
stampedUpdate :: IO KubernetesMutation
stampedUpdate = (\mutation -> mutation {mutationBeforeStamp = Just stampBefore}) <$> prepared Nothing

status :: Value
status = object ["manager" .= ("k3s" :: Text), "operation" .= ("Update" :: Text), "subresource" .= ("status" :: Text), "fieldsV1" .= object ["f:status" .= object []]]

-- | The live object at a resourceVersion, carrying a spec-digest stamp.
stampedLive :: Text -> ContentDigest -> [Value] -> Value
stampedLive revision stamp entries = case live "kubernetes-uid-1" revision entries of
  Object root
    | Just (Object metadata) <- KM.lookup "metadata" root ->
        Object (KM.insert "metadata" (Object (KM.insert "annotations" (object ["nagare.dev/spec-digest" .= digestText stamp]) metadata)) root)
  other -> other

-- | The transport against a modelled API server whose successive applies
-- fail with the given error output (Nothing succeeds), returning the apply
-- bodies it was sent.
scriptedTransport :: KubernetesMutation -> Value -> [Maybe String] -> IO (AdapterExecution, [Text])
scriptedTransport mutation object' answers = do
  remaining <- newIORef answers
  bodies <- newIORef []
  let handle request = case request ^. #arguments of
        "get" : _ -> pure (Right (ExitSuccess, T.unpack (TE.decodeUtf8 (BL.toStrict (encode object'))), ""))
        "apply" : _ -> do
          modifyIORef' bodies (<> [T.pack (request ^. #input)])
          next <- atomicModifyIORef' remaining (\case [] -> ([], Nothing); answer : rest -> (rest, answer))
          pure (Right (maybe (ExitSuccess, T.unpack (TE.decodeUtf8 (BL.toStrict (encode object'))), "") (ExitFailure 1,"",) next))
        other -> assertFailure ("unmodelled kubectl request: " <> show other) >> pure (Left "unmodelled")
      config = withKubectlInterpreter (runKubectlWith handle) (KubernetesRuntimeConfig (ok (mkContextId "test")) "test" (pure (Right ())))
  result <- kubernetesMutateConditional (mkKubernetesRuntimeOps config bound) mutation
  (result,) <$> readIORef bodies

-- | The resourceVersion an apply body carried as its precondition.
bodyRevision :: Text -> Maybe Text
bodyRevision body = case eitherDecodeStrict' (TE.encodeUtf8 body) of
  Right (Object root)
    | Just (Object metadata) <- KM.lookup "metadata" root
    , Just (String revision) <- KM.lookup "resourceVersion" metadata ->
        Just revision
  _ -> Nothing

-- | An adapter over a stamped observation the test controls, whose transport
-- records the precondition each write was given.
stampedAdapter :: (KubernetesState, Maybe ContentDigest) -> IO (Adapter, IORef [KubernetesState], IORef (KubernetesState, Maybe ContentDigest))
stampedAdapter = stampedAdapterFor bound

stampedAdapterFor :: Map.Map ResourceId (ManagedResource, ByteString) -> (KubernetesState, Maybe ContentDigest) -> IO (Adapter, IORef [KubernetesState], IORef (KubernetesState, Maybe ContentDigest))
stampedAdapterFor specs initial = do
  state <- newIORef initial
  writes <- newIORef []
  let ops =
        KubernetesAdapterOps
          { kubernetesContext = ok (mkContextId "test")
          , kubernetesObserveStamped = \_ -> readIORef state
          , kubernetesMutateConditional = \mutation -> modifyIORef' writes (<> [mutationBefore mutation]) >> pure AdapterEffectCompleted
          }
  pure (mkKubernetesAdapter specs ops, writes, state)

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
