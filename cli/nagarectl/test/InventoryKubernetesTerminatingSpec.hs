-- | EP-180 M6 (G5): a terminating object, one whose DELETE the API server
-- accepted while finalizers hold it (RES-4 U6), keeps its UID and gains a
-- deletion timestamp. It is classified as terminating, never read as present.
module InventoryKubernetesTerminatingSpec (inventoryKubernetesTerminatingTests) where

import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Adapters.KubernetesProof (completionProof, requireWriteTarget)
import Nagare.Inventory.Adapters.KubernetesRuntime (KubernetesRuntimeConfig (..), parseObserved)
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal (mkOperationId)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.Support.Kubernetes qualified as K
import Test.Tasty
import Test.Tasty.HUnit

inventoryKubernetesTerminatingTests :: TestTree
inventoryKubernetesTerminatingTests =
  testGroup
    "terminating Kubernetes objects (G5)"
    [ testCase "an object with a deletion timestamp is observed as terminating, with its UID and stamp" $ do
        let config = KubernetesRuntimeConfig (K.ok (mkContextId "test")) "test" (pure (Right ()))
            observe value = parseObserved config K.resource K.nativeBytes (TE.decodeUtf8 (K.ok (canonicalValue value)))
        observe (live False) @?= Right (KubernetesPresent K.physical "7" (Just K.resource) reviewed)
        observe (live True) @?= Right (KubernetesTerminating K.physical "7" (Just K.resource) reviewed)
    , testCase "settlement: a create or update whose target is being deleted is target gone; a retire's own delete is landed" $ do
        -- RES-4 §3: whatever its stamp says, an object being deleted outside
        -- review is no longer the target a create or update wrote.
        let terminating = KubernetesTerminating K.physical "9" (Just K.resource) reviewed
            settle mutation stamp = settleMutation mutation terminating terminating stamp (RecoveryUnresolved "Kubernetes object changed since review; replan before mutation")
        settle created (Just reviewed) @?= SettledTargetGone (Just K.physical)
        settle updated (Just reviewed) @?= SettledTargetGone (Just K.physical)
        settle updated (Just stampBefore) @?= SettledTargetGone (Just K.physical)
        -- A retire's DELETE was accepted; finalizers hold the reviewed object.
        settle retired (Just reviewed) @?= SettledLanded K.physical
        -- Another object being deleted is not the retire's reviewed object.
        let other = KubernetesTerminating (K.ok (mkPhysicalIdentity "other-uid")) "2" (Just K.resource) reviewed
        case settleMutation retired other other Nothing (RecoveryUnresolved "changed") of
          SettledLanded _ -> assertFailure "another object's deletion settled the retire as landed"
          _ -> pure ()
    , testCase "no write targets a terminating object, and none completes on one" $ do
        let terminating = KubernetesTerminating K.physical "9" (Just K.resource) reviewed
        assertBool "an update wrote to a terminating object" (isLeft (requireWriteTarget updated terminating (Just stampBefore)))
        assertBool "a retire deleted a terminating object again" (isLeft (requireWriteTarget retired terminating Nothing))
        assertBool "an update completed on a terminating object" (isLeft (completionProof updated terminating))
        assertBool "a retire completed on a terminating object" (isLeft (completionProof retired terminating))
    , testCase "planning never reads a terminating member as present" $ do
        state <- newIORef (KubernetesTerminating K.physical "9" (Just K.resource) (contentDigest K.nativeBytes))
        calls <- newIORef (0 :: Int)
        observed <- adapterObserve (mkKubernetesAdapter K.specs (K.ops state calls)) [K.resource] >>= K.expectRight
        case Map.lookup K.resource (observationMap observed) of
          Just (ObservationUnavailable reason) -> assertBool "the reason does not name the deletion" ("being deleted" `T.isInfixOf` reason)
          other -> assertFailure ("a terminating member was observed as " <> show other)
    ]

reviewed, stampBefore :: ContentDigest
reviewed = contentDigest K.nativeBytes
stampBefore = contentDigest "before"

-- | The reviewed Service as the API server returns it, stamped as this
-- member, optionally with its DELETE accepted and a finalizer holding it.
live :: Bool -> Value
live deleting = case K.nativeObject of
  Object root
    | Just (Object metadata) <- KM.lookup "metadata" root ->
        Object (KM.insert "metadata" (Object (KM.union (KM.fromList fields) metadata)) root)
  other -> other
  where
    fields =
      [ ("uid", String "kubernetes-uid-1")
      , ("resourceVersion", String "7")
      , ("annotations", object ["nagare.dev/context-id" .= ("test" :: Text), "nagare.dev/resource-id" .= resourceIdText K.resource, "nagare.dev/spec-digest" .= digestText reviewed])
      ]
        <> [("deletionTimestamp", String "2026-10-06T12:00:00Z") | deleting]
        <> [("finalizers", toJSON ["example.com/hold" :: Text]) | deleting]

reviewedAs :: OperationAction -> KubernetesState -> Maybe ContentDigest -> KubernetesMutation
reviewedAs action before stamp = KubernetesMutation 1 (K.ok (mkOperationId "op-terminating")) reviewed action K.resource (K.declaration ^. #address) K.nativeText reviewed before Nothing stamp

created, updated, retired :: KubernetesMutation
created = reviewedAs CreateResource (KubernetesAbsent K.absence) Nothing
updated = reviewedAs UpdateResource (KubernetesPresent K.physical "4" (Just K.resource) (contentDigest "whole-object-before")) (Just stampBefore)
retired = reviewedAs RetireResource (KubernetesPresent K.physical "4" (Just K.resource) reviewed) Nothing
