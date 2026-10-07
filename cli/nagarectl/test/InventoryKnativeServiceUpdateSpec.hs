-- | EP-180 G6: a Knative Service update is an ordinary version-1 review. Its
-- write is guarded by the reviewed UID, this member's ownership and the
-- before-state stamp (RES-4 U3, U10), so a status write by the controller,
-- which moves resourceVersion and the whole-object digest, never refuses it.
module InventoryKnativeServiceUpdateSpec (knativeServiceUpdateTests) where

import Control.Monad (forM_, when)
import Data.Aeson
import Data.ByteString (ByteString)
import Data.Either (isLeft)
import Data.IORef
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect))
import Nagare.Inventory.Kubernetes
import Nagare.Inventory.ObservationNative (observationBytesFromMutation)
import Nagare.Resource.Inventory (ManagedResource)
import Nagare.Resource.Kubernetes
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.Support.Kubernetes qualified as K
import Test.Tasty
import Test.Tasty.HUnit

knativeServiceUpdateTests :: TestTree
knativeServiceUpdateTests =
  testGroup
    "Knative Service updates (G6)"
    [ testCase "a Knative Service update is a version-1 review guarded by its UID, owner and stamp (M5b)" $ do
        (adapter, state, calls, _) <- knativeAdapter (before "4" "old-configuration", Just stampBefore)
        reviewed <- adapterPrepare adapter K.updateOperation >>= K.expectRight
        mutation <- K.expectRight (eitherDecodeStrict' (preparedNativeBytes reviewed))
        mutationVersion mutation @?= 1
        mutationBeforeStamp mutation @?= Just stampBefore
        observationBytesFromMutation (K.ok (mkContextId "test")) "kubernetes-conditional-object" "1" K.updateOperation (preparedNativeBytes reviewed)
          @?= Right (Just knativeBytes)
        -- A status write moved resourceVersion and the whole-object digest.
        writeIORef state (before "5" "churned", Just stampBefore)
        adapterPreflight adapter K.updateOperation reviewed >>= K.expectRight
        forM_
          [ (KubernetesNotReady (K.ok (mkPhysicalIdentity "replacement")) "5" (Just K.resource) (contentDigest "churned"), Just stampBefore)
          , (KubernetesNotReady K.physical "5" Nothing (contentDigest "churned"), Just stampBefore)
          , (before "5" "churned", Just (contentDigest "another-review"))
          ]
          $ \changed -> do
            writeIORef state changed
            adapterPreflight adapter K.updateOperation reviewed >>= assertBool "a changed target passed preflight" . isLeft
        readIORef calls >>= (@?= 0)
        writeIORef state (before "6" "churned", Just stampBefore)
        adapterExecute adapter K.updateOperation reviewed >>= (@?= AdapterEffectCompleted)
        _ <- adapterVerify adapter K.updateOperation reviewed >>= K.expectRight
        adapterRecover adapter K.updateOperation reviewed >>= \case
          RecoveryProvedComplete _ -> pure ()
          other -> assertFailure (show other)
        readIORef calls >>= (@?= 1)
    , testCase "a status write racing the update does not refuse it; another write of this member's does" $ do
        -- RES-4 U10: the transport guards the write with its own live read of
        -- the UID, stamp and field owners, and writes with that read's
        -- resourceVersion, so a status write in between changes nothing.
        (adapter, state, calls, race) <- knativeAdapter (before "4" "old-configuration", Just stampBefore)
        writeIORef race True
        reviewed <- adapterPrepare adapter K.updateOperation >>= K.expectRight
        adapterExecute adapter K.updateOperation reviewed >>= (@?= AdapterEffectCompleted)
        readIORef calls >>= (@?= 1)
        -- Another write of this member's is live (F73): refused, and not ours
        -- to retry or await.
        writeIORef state (before "6" "another-review", Just (contentDigest "another-review"))
        adapterExecute adapter K.updateOperation reviewed >>= \case
          AdapterEffectFailed (KnownNoEffect _) -> pure ()
          other -> assertFailure (show other)
        adapterRecover adapter K.updateOperation reviewed >>= \case
          RecoveryUnresolved _ -> pure ()
          other -> assertFailure (show other)
        readIORef calls >>= (@?= 1)
    , testCase "a Knative Service update awaits readiness only while its own write is live (F73)" $ do
        -- RES-4 U3: the reviewed digest is observed only while the stamp and
        -- the desired fields both match, so it is the proof our write is live.
        (adapter, state, _, _) <- knativeAdapter (before "4" "old-configuration", Nothing)
        reviewed <- adapterPrepare adapter K.updateOperation >>= K.expectRight
        mutation <- K.expectRight (eitherDecodeStrict' (preparedNativeBytes reviewed))
        writeIORef state (KubernetesNotReady K.physical "5" (Just K.resource) (mutationNativeDigest mutation), Nothing)
        adapterRecover adapter K.updateOperation reviewed >>= (@?= RecoveryAwaitingReadiness K.physical)
        -- Another write of this member's left the object unready: ours is not live.
        writeIORef state (before "6" "another-review", Nothing)
        adapterRecover adapter K.updateOperation reviewed >>= \case
          RecoveryUnresolved _ -> pure ()
          other -> assertFailure ("another write was awaited as ours: " <> show other)
        case adapterSettle adapter of
          Nothing -> assertFailure "the Kubernetes adapter does not settle"
          Just settle ->
            settle K.updateOperation reviewed >>= \case
              SettledLanded _ -> assertFailure "another write settled as our landed update"
              _ -> pure ()
    ]

stampBefore :: ContentDigest
stampBefore = contentDigest "old-configuration"

-- | The reviewed Knative Service, owned and unready, at a resourceVersion and
-- whole-object digest.
before :: Text -> ByteString -> KubernetesState
before revision digest = KubernetesNotReady K.physical revision (Just K.resource) (contentDigest digest)

knativeValue :: Value
knativeValue =
  object
    [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
    , "kind" .= ("Service" :: Text)
    , "metadata" .= object ["name" .= ("web" :: Text), "namespace" .= ("personal" :: Text)]
    ]

knativeBytes :: ByteString
knativeBytes = K.ok (canonicalValue knativeValue)

knativeBound :: Map.Map ResourceId (ManagedResource, ByteString)
knativeBound = Map.singleton K.resource (K.ok (bindKubernetesObject (K.input {inputObject = knativeValue, objectDigest = contentDigest knativeBytes})))

-- | The adapter over a stamped observation the test controls. Its write is
-- guarded as the runtime's is: by the reviewed UID, this member's ownership
-- and the before-state stamp, read live, never by resourceVersion. It lands
-- the reviewed digest and stamp. While the race flag is set, a status write
-- moves the object to resourceVersion 5, keeping its stamp, just before each
-- write.
knativeAdapter :: (KubernetesState, Maybe ContentDigest) -> IO (Adapter, IORef (KubernetesState, Maybe ContentDigest), IORef Int, IORef Bool)
knativeAdapter initial = do
  state <- newIORef initial
  calls <- newIORef (0 :: Int)
  race <- newIORef False
  let ops =
        KubernetesAdapterOps
          { kubernetesContext = K.ok (mkContextId "test")
          , kubernetesObserveStamped = \_ -> readIORef state
          , kubernetesMutateConditional = \mutation -> do
              racing <- readIORef race
              when racing (modifyIORef' state (\(_, stamp) -> (before "5" "old-configuration", stamp)))
              (current, stamp) <- readIORef state
              if identity current /= identity (mutationBefore mutation) || stamp /= mutationBeforeStamp mutation
                then pure (AdapterEffectFailed (KnownNoEffect "conditional write conflict"))
                else do
                  modifyIORef' calls (+ 1)
                  writeIORef state (KubernetesPresent K.physical "8" (Just K.resource) (mutationNativeDigest mutation), Just (mutationNativeDigest mutation))
                  pure AdapterEffectCompleted
          }
      adapter = mkKubernetesAdapterWithConfigurationObservation knativeBound ops (traverse (kubernetesObserve ops)) noReceipt noScratch (\_ -> pure (Left "no live object reader"))
  pure (adapter, state, calls, race)
  where
    noReceipt _ _ = pure (Left "not a backup")
    noScratch _ _ = pure (Right False)
    identity = \case
      KubernetesPresent uid _ owner _ -> Just (uid, owner)
      KubernetesNotReady uid _ owner _ -> Just (uid, owner)
      _ -> Nothing
