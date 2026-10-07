-- | EP-180 M9: every Kubernetes recovery answer is observed by a test. An
-- answer the driver acts on differently is pinned; an answer that changed
-- nothing the driver or settlement does was deleted, and its case is pinned
-- here by what settlement (ADR 26's close by proof) still concludes.
module InventoryKubernetesRecoverySpec (inventoryKubernetesRecoveryTests) where

import Control.Monad (forM_)
import Data.Aeson (Value, object, (.=))
import Data.ByteString (ByteString)
import Data.IORef
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Digest
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Inventory (ManagedResource)
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.Support.Kubernetes qualified as K
import Test.Tasty
import Test.Tasty.HUnit

inventoryKubernetesRecoveryTests :: TestTree
inventoryKubernetesRecoveryTests =
  testGroup
    "Kubernetes recovery answers (M9)"
    [ testCase "a verification whose target moved only in resourceVersion is proved complete; one whose target changed stops (F57a's deleted answer)" $ do
        -- A verification's guard is the UID, this member's ownership and the
        -- reviewed digest; status writes never move it, so resume completes
        -- the verification without re-running it.
        (adapter, state) <- adapterAt K.specs (KubernetesPresent K.physical "4" (Just K.resource) native)
        prepared <- adapterPrepare adapter verifyOperation >>= K.expectRight
        writeIORef state (KubernetesPresent K.physical "5" (Just K.resource) native)
        adapterRecover adapter verifyOperation prepared >>= \case
          RecoveryProvedComplete _ -> pure ()
          other -> assertFailure ("a status write stopped the verification: " <> show other)
        -- A changed target fails the same guard a re-run would check, so
        -- recovery leaves it unresolved and resume stops.
        writeIORef state (KubernetesPresent K.physical "6" (Just K.resource) (contentDigest "edited"))
        adapterRecover adapter verifyOperation prepared >>= \case
          RecoveryUnresolved _ -> pure ()
          other -> assertFailure ("a changed verification target was answered " <> show other)
    , testCase "an update whose target was replaced settles as target gone (F56's deleted answer)" $ do
        (adapter, state) <- adapterAt K.specs (KubernetesPresent K.physical "4" (Just K.resource) (contentDigest "old"))
        prepared <- adapterPrepare adapter K.updateOperation >>= K.expectRight
        writeIORef state (KubernetesPresent replacement "1" (Just K.resource) native)
        settle adapter K.updateOperation prepared >>= (@?= SettledTargetGone (Just replacement))
    , testCase "an owned update target deleted outside review settles as target gone (F64's deleted answer)" $ do
        (adapter, state) <- adapterAt K.specs (KubernetesPresent K.physical "4" (Just K.resource) (contentDigest "old"))
        prepared <- adapterPrepare adapter K.updateOperation >>= K.expectRight
        writeIORef state (KubernetesAbsent K.absence)
        settle adapter K.updateOperation prepared >>= (@?= SettledTargetGone Nothing)
    , testCase "a created StatefulSet that is not yet ready settles as landed (F59's deleted answer)" $ do
        (adapter, state) <- adapterAt statefulSetSpecs (KubernetesAbsent K.absence)
        prepared <- adapterPrepare adapter K.createOperation >>= K.expectRight
        writeIORef state (KubernetesNotReady K.physical "2" (Just K.resource) statefulSetDigest)
        settle adapter K.createOperation prepared >>= (@?= SettledLanded K.physical)
    , testCase "an unready update is landed only with the reviewed digest, on the reviewed object, as this member's (item 6)" $ do
        -- RES-4 U3: the reviewed digest is observed only while the desired
        -- fields match and the stamp is the reviewed one.
        (adapter, state) <- adapterAt K.specs (KubernetesPresent K.physical "4" (Just K.resource) (contentDigest "old"))
        prepared <- adapterPrepare adapter K.updateOperation >>= K.expectRight
        writeIORef state (KubernetesNotReady K.physical "5" (Just K.resource) native)
        settle adapter K.updateOperation prepared >>= (@?= SettledLanded K.physical)
        -- Another digest, or the reviewed object no longer stamped as this
        -- member, is not this update landed.
        forM_
          [ KubernetesNotReady K.physical "6" (Just K.resource) (contentDigest "another-review")
          , KubernetesNotReady K.physical "6" Nothing native
          ]
          $ \observed -> do
            writeIORef state observed
            settle adapter K.updateOperation prepared >>= \case
              SettledLanded _ -> assertFailure ("settled as landed: " <> show observed)
              _ -> pure ()
        -- Another object with the reviewed digest is the target gone.
        writeIORef state (KubernetesNotReady replacement "1" (Just K.resource) native)
        settle adapter K.updateOperation prepared >>= (@?= SettledTargetGone (Just replacement))
    ]

native :: ContentDigest
native = contentDigest K.nativeBytes

replacement :: PhysicalIdentity
replacement = K.ok (mkPhysicalIdentity "replacement-uid")

verifyOperation :: PlannedOperation
verifyOperation = K.operation VerifyResource

-- | The adapter over a state the test controls.
adapterAt :: Map.Map ResourceId (ManagedResource, ByteString) -> KubernetesState -> IO (Adapter, IORef KubernetesState)
adapterAt specs initial = do
  state <- newIORef initial
  calls <- newIORef (0 :: Int)
  pure (mkKubernetesAdapter specs (K.ops state calls), state)

settle :: Adapter -> PlannedOperation -> PreparedNative -> IO Settlement
settle adapter operation prepared = case adapterSettle adapter of
  Nothing -> assertFailure "the Kubernetes adapter does not settle" >> pure (error "unreachable")
  Just settleWith -> settleWith operation prepared

statefulSet :: Value
statefulSet =
  object
    [ "apiVersion" .= ("apps/v1" :: Text)
    , "kind" .= ("StatefulSet" :: Text)
    , "metadata" .= object ["name" .= ("pg" :: Text), "namespace" .= ("personal" :: Text)]
    , "spec"
        .= object
          [ "serviceName" .= ("pg" :: Text)
          , "replicas" .= (1 :: Int)
          , "selector" .= object ["matchLabels" .= object ["app" .= ("pg" :: Text)]]
          , "template" .= object ["metadata" .= object ["labels" .= object ["app" .= ("pg" :: Text)]], "spec" .= object ["containers" .= [object ["name" .= ("pg" :: Text), "image" .= ("postgres:18" :: Text)]]]]
          ]
    ]

statefulSetDigest :: ContentDigest
statefulSetDigest = contentDigest (K.ok (canonicalValue statefulSet))

statefulSetSpecs :: Map.Map ResourceId (ManagedResource, ByteString)
statefulSetSpecs = Map.singleton K.resource (K.ok (bindKubernetesObject (K.input {inputObject = statefulSet, objectDigest = statefulSetDigest})))
