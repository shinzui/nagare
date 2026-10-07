-- | EP-181 (RES-4 G3): the pod that blocks a member StatefulSet's rollout.
-- The fixtures follow RES-4's experiments E6e and E6f
-- (docs/audits/k8s-semantics-2026-10-06/experiments/e6e.out).
module InventoryStuckPodSpec
  ( inventoryStuckPodTests
  , acceptedStore
  , pgBound
  , planId
  , planOwner
  , planCluster
  , planUid
  , reviewedPod
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import InventoryTransactionSpec (fixtureBinding, recordingRegistryWith)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes (KubernetesState (..), kubernetesObserve, mkKubernetesAdapterWithObservations)
import Nagare.Inventory.Adapters.KubernetesRuntime (mkKubernetesRuntimeOpsAndBatchWithCacheKey)
import Nagare.Inventory.Adapters.KubernetesStuckPod
import Nagare.Inventory.DataService (NativeDataKind (DatabaseObjects), compileStatefulSetRestart)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect))
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.KubernetesTransport (KubectlRequest (..), KubernetesRuntimeConfig (..), runKubectlWith, withKubectlInterpreter)
import Nagare.Inventory.Plan
import Nagare.Inventory.Status qualified as Status
import Nagare.Inventory.Store
import Nagare.Ops.Probe (Probe (..), ProbeStatus (..))
import Nagare.Ops.StuckRollout (parseStuckRollouts)
import Nagare.Resource.Canonical (canonicalValue)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Test.Model.Fixtures (databaseNative, databaseScope, ok, statefulId)
import Nagare.Test.Support.Kubernetes qualified as K
import System.Exit (ExitCode (..))
import Test.Tasty
import Test.Tasty.HUnit

inventoryStuckPodTests :: TestTree
inventoryStuckPodTests =
  testGroup
    "stuck pod"
    [ testCase "observation: E6f's final state (a correction landed over a pod that is not Ready) is stuck" $ do
        found <- expectRight (stuckPod (statefulSet 3 (Just 3) (Just "pg-d9d6d")) (pods [pgPod "pg-0" "pg-9d647" False]))
        fmap (^. #pod) found @?= Just "pg-0"
        fmap (^. #podRevision) found @?= Just "pg-9d647"
        fmap (^. #updateRevision) found @?= Just "pg-d9d6d"
        fmap (^. #podResourceVersion) found @?= Just "rv-pg-0"
        fmap (^. #statefulSetUid) found @?= Just (uidOf "sts-uid")
    , testCase "observation: the same pod, once Ready, is not stuck" $
        stuckPod (statefulSet 3 (Just 3) (Just "pg-d9d6d")) (pods [pgPod "pg-0" "pg-9d647" True]) @?= Right Nothing
    , testCase "observation: nothing is stuck while the controller has not observed the latest spec" $ do
        stuckPod (statefulSet 3 (Just 2) (Just "pg-9d647")) (pods [pgPod "pg-0" "pg-9d647" False]) @?= Right Nothing
        -- A pod stuck behind an earlier correction, under a newer spec the
        -- controller has not yet observed: wait for the controller.
        stuckPod (statefulSet 4 (Just 3) (Just "pg-d9d6d")) (pods [pgPod "pg-0" "pg-9d647" False]) @?= Right Nothing
    , testCase "observation: a broken create (E6e: the pod is at the update revision) is not stuck" $
        stuckPod (statefulSet 1 (Just 1) (Just "pg-9dc98")) (pods [pgPod "pg-0" "pg-9dc98" False]) @?= Right Nothing
    , testCase "observation: a pod being deleted is not stuck" $
        stuckPod (statefulSet 3 (Just 3) (Just "pg-d9d6d")) (pods [terminating (pgPod "pg-0" "pg-9d647" False)]) @?= Right Nothing
    , testCase "observation: a pod the StatefulSet does not control is not stuck" $
        stuckPod (statefulSet 3 (Just 3) (Just "pg-d9d6d")) (pods [podWith "other-uid" "pg-0" (Just "pg-9d647") False False]) @?= Right Nothing
    , testCase "observation: the lowest ordinal is the stuck pod" $ do
        found <- expectRight (stuckPod (statefulSet 3 (Just 3) (Just "pg-d9d6d")) (pods [pgPod "pg-1" "pg-9d647" False, pgPod "pg-0" "pg-9d647" False]))
        fmap (^. #pod) found @?= Just "pg-0"
    , testCase "observation: an observed StatefulSet without updateRevision is an error, not 'not stuck'" $
        assertLeft (stuckPod (statefulSet 3 (Just 3) Nothing) (pods [pgPod "pg-0" "pg-9d647" False]))
    , testCase "observation: a controlled pod without a revision label is an error, not 'not stuck'" $
        assertLeft (stuckPod (statefulSet 3 (Just 3) (Just "pg-d9d6d")) (pods [podWith "sts-uid" "pg-0" Nothing False False]))
    , testCase "observation: without pod access nothing is ever stuck" $
        readStuckPod noPodOps (error "noPodOps reads no resource") >>= (@?= Right Nothing)
    , testCase "runtime: a Ready StatefulSet costs one read and no pod list" $ do
        (found, requests) <- runtimeRead (Right ()) (readyStatefulSet, pods [])
        found @?= Right Nothing
        map (take 2) requests @?= [["get", "statefulset.apps"]]
    , testCase "runtime: a StatefulSet that is not Ready lists its pods by its selector" $ do
        (found, requests) <- runtimeRead (Right ()) (statefulSet 3 (Just 3) (Just "pg-d9d6d"), pods [pgPod "pg-0" "pg-9d647" False])
        fmap (fmap (^. #pod)) found @?= Right (Just "pg-0")
        requests @?= [["get", "statefulset.apps", "pg", "--namespace", "personal", "-o", "json", "--ignore-not-found"], ["get", "pods", "--namespace", "personal", "-l", "app=pg", "-o", "json"]]
    , testCase "runtime: a refusing cluster guard reads nothing" $ do
        (found, requests) <- runtimeRead (Left "wrong cluster") (readyStatefulSet, pods [])
        either (const (pure ())) (\value -> assertFailure ("read past the guard: " <> show value)) found
        requests @?= []
    , testCase "plan: an unchanged member whose rollout is stuck plans exactly one replacement" $ do
        planned <- planAccepted (planMember "v1") (planMember "v1") (ObservedPresent planUid) blocked
        map (\operation -> (plannedAction operation, plannedResources operation, plannedRecovery operation)) planned
          @?= [(ReplaceStuckPod, planId :| [], VerifyBeforeRetry)]
    , testCase "plan: a member that is not stuck plans no replacement" $ do
        planned <- planAccepted (planMember "v1") (planMember "v1") (ObservedPresent planUid) Map.empty
        assertBool (show planned) (ReplaceStuckPod `notElem` map plannedAction planned)
    , testCase "plan: a member both drifted and stuck plans only its update" $ do
        planned <- planAccepted (planMember "v1") (planMember "v1") (ObservedDrifted planUid (contentDigest "edited")) blocked
        map plannedAction planned @?= [UpdateResource]
    , testCase "plan: a corrected declaration over a stuck member plans only its update" $ do
        planned <- planAccepted (planMember "v1") (planMember "v2") (ObservedPresent planUid) blocked
        map plannedAction planned @?= [UpdateResource]
    , testCase "status: a stuck member is a stuck rollout that names the operation" $ do
        let inventory = candidateInventory (ok (composeInventory (ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty)) (ReplaceScope (planScope (planMember "v1")) :| [])))
            classify stuck = Status.classifyDriftWith (Map.singleton planId planUid) inventory (withStuckRollouts stuck (ok (observationSet [(planId, ObservedPresent planUid)])))
        map (\finding -> (Status.findingCategory finding, Status.findingReason finding)) (classify blocked)
          @?= [(Status.StuckRollout, Just "rollout is stuck: pg-0 at revision pg-9d647 is not Ready and blocks the rollout to pg-d9d6d; the next inventory plan proposes replace-stuck-pod")]
        map Status.findingCategory (classify Map.empty) @?= [Status.Converged]
    , testCase "end to end: a stuck pod read by the runtime is planned, reviewed and reported by status" $ do
        let (declared, _) = pgBound
        (store, candidate, history) <- acceptedStore declared declared
        (registry, asked) <- runtimeRegistry
        -- Planning, as the operator CLI does it.
        observations <- observeWithRegistry registry (requirementsByExecutor (observationRequirements candidate history)) >>= expectRight
        let proposal = ok (planChanges candidate noLifecycleDecisions history observations)
        map (\operation -> (plannedAction operation, plannedResources operation)) (proposalOperations proposal) @?= [(ReplaceStuckPod, planId :| [])]
        snapshot <- readStoreSnapshot store >>= expectRight
        bundle <- prepareReview registry snapshot proposal >>= expectRight
        map reviewPublicSummary (reviewOperations (reviewBundleDocument bundle))
          @?= ["replace-stuck-pod  statefulset personal/pg  pod pg-0 (uid uid-pg-0…, revision 9d647, not Ready) blocks rollout to revision d9d6d"]
        -- Status, as the operator CLI does it.
        kubernetes <- expectRight (lookupAdapter registry KubernetesExecutor)
        (facts, stuck) <- Status.statusFacts "adapter omitted this resource" [planId] <$> adapterObserve kubernetes [planId]
        map Status.findingCategory (Status.classifyDriftWith (Map.singleton planId planUid) (candidateInventory candidate) (withStuckRollouts stuck (ok (observationSet facts))))
          @?= [Status.StuckRollout]
        -- Every pod read went through kubectl: plan, prepare and status.
        readIORef asked >>= \requests -> length [() | "get" : "pods" : _ <- requests] @?= 3
    , testCase "observe: a member StatefulSet that is not Ready reports its stuck pod" $ do
        (observed, podReads) <- observeDatabase (notReady statefulDigest) (pure (Right (Just reviewedPod)))
        fmap observationStuck observed @?= Right (Map.singleton statefulId "pg-0 at revision pg-9d647 is not Ready and blocks the rollout to pg-d9d6d")
        fmap (Map.lookup statefulId . observationMap) observed @?= Right (Just (ObservedPresent K.physical))
        podReads @?= [statefulId]
    , testCase "observe: a Ready or drifted member reads no pods" $ do
        (ready, readyReads) <- observeDatabase (KubernetesPresent K.physical "1" (Just statefulId) statefulDigest) (pure (Right (Just reviewedPod)))
        (drifted, driftedReads) <- observeDatabase (notReady (contentDigest "edited")) (pure (Right (Just reviewedPod)))
        (fmap observationStuck ready, fmap observationStuck drifted) @?= (Right Map.empty, Right Map.empty)
        (readyReads, driftedReads) @?= ([], [])
    , testCase "observe: a failed pod read makes the member unavailable, never 'not stuck'" $ do
        (observed, _) <- observeDatabase (notReady statefulDigest) (pure (Left "forbidden"))
        fmap (Map.lookup statefulId . observationMap) observed @?= Right (Just (ObservationUnavailable "the StatefulSet's pods could not be read: forbidden"))
    , testCase "prepare: the reviewed bytes decode back to the observed pod" $ do
        adapter <- databaseAdapter (pure (Right (Just reviewedPod)))
        prepared <- adapterPrepare adapter replaceOperation >>= expectRight
        replacement <- expectRight (eitherDecodeStrict' (preparedNativeBytes prepared) :: Either String PodReplacement)
        replacement ^. #stuck @?= reviewedPod
        (replacement ^. #member, replacement ^. #operation) @?= (statefulId, plannedOperationId replaceOperation)
        preparedPublicSummary prepared @?= "replace-stuck-pod  statefulset personal/pg  pod pg-0 (uid uid-pg-0…, revision 9d647, not Ready) blocks rollout to revision d9d6d"
    , testCase "prepare: a member no longer stuck refuses as stale" $ do
        adapter <- databaseAdapter (pure (Right Nothing))
        prepared <- adapterPrepare adapter replaceOperation
        case prepared of
          Left (PrepareRefused _ reason) -> assertBool (T.unpack reason) ("stale" `T.isInfixOf` reason)
          other -> assertFailure ("prepared a member that is not stuck: " <> show other)
    , testCase "execute: a pod still stuck as reviewed is deleted once, at its fresh resourceVersion" $ do
        (outcome, replaced, checked) <- executeAfter (Right (Just (reviewedPod & #podResourceVersion .~ "rv-fresh")))
        (outcome, replaced, checked) @?= (AdapterEffectCompleted, [(reviewedPod, "rv-fresh")], Right ())
    , testCase "execute: a pod Ready by then is not deleted, with no effect" $ do
        (outcome, replaced, checked) <- executeAfter (Right Nothing)
        (outcome, replaced) @?= (AdapterEffectFailed (KnownNoEffect "the reviewed pod no longer blocks the rollout; replan"), [])
        assertBool "preflight passed a pod that is no longer stuck" (isLeft checked)
    , testCase "execute: a pod replaced by then is not deleted" $ do
        (outcome, replaced, _) <- executeAfter (Right (Just (reviewedPod & #podUid .~ uidOf "uid-pg-0-new")))
        (outcome, replaced) @?= (AdapterEffectFailed (KnownNoEffect "another pod blocks the rollout since review; replan"), [])
    , testCase "execute: a StatefulSet whose update revision moved, or that was replaced, is not touched" $ do
        (moved, movedReplaced, _) <- executeAfter (Right (Just (reviewedPod & #updateRevision .~ "pg-0aaaa")))
        (other, otherReplaced, _) <- executeAfter (Right (Just (reviewedPod & #statefulSetUid .~ uidOf "sts-uid-2")))
        (moved, other) @?= (AdapterEffectFailed (KnownNoEffect "the StatefulSet's update revision moved since review; replan"), AdapterEffectFailed (KnownNoEffect "the StatefulSet was replaced since review; replan"))
        (movedReplaced, otherReplaced) @?= ([], [])
    , testCase "execute: a failed re-read writes nothing" $ do
        (outcome, replaced, _) <- executeAfter (Left "forbidden")
        (outcome, replaced) @?= (AdapterEffectFailed (KnownNoEffect "the StatefulSet's pods could not be re-read: forbidden"), [])
    , testCase "runtime: the delete carries the reviewed UID and the fresh resourceVersion, then waits for the rollout" $ do
        (outcome, asked) <- runtimeReplace (Right ()) (const (Right (ExitSuccess, "", "")))
        outcome @?= AdapterEffectCompleted
        asked
          @?= [ (["delete", "--raw", "/api/v1/namespaces/personal/pods/pg-0", "-f", "-"], "{\"apiVersion\":\"meta.k8s.io/v1\",\"kind\":\"DeleteOptions\",\"preconditions\":{\"resourceVersion\":\"rv-fresh\",\"uid\":\"uid-pg-0\"}}")
              , (["rollout", "status", "statefulset/pg", "--namespace", "personal", "--timeout=300s"], "")
              ]
    , testCase "runtime: a 409 refusal had no effect and waits for nothing" $ do
        (outcome, asked) <- runtimeReplace (Right ()) (const (Right (ExitFailure 1, "", "Error from server (Conflict): Operation cannot be fulfilled on Pod \"pg-0\": the ResourceVersion in the precondition (rv-fresh) does not match the ResourceVersion in record (rv-later)\n")))
        outcome @?= AdapterEffectFailed (KnownNoEffect "Error from server (Conflict): Operation cannot be fulfilled on Pod \"pg-0\": the ResourceVersion in the precondition (rv-fresh) does not match the ResourceVersion in record (rv-later)")
        length asked @?= 1
    , testCase "runtime: a timed-out delete is ambiguous" $ do
        (outcome, _) <- runtimeReplace (Right ()) (const (Left "kubectl timed out"))
        outcome @?= AdapterEffectAmbiguous "the stuck pod's DELETE did not return success; reobserve before retry"
    , testCase "runtime: a rollout that does not become Ready after the delete is ambiguous" $ do
        (outcome, _) <- runtimeReplace (Right ()) (\arguments -> if take 1 arguments == ["rollout"] then Right (ExitFailure 1, "", "timed out waiting for the condition") else Right (ExitSuccess, "", ""))
        outcome @?= AdapterEffectAmbiguous "the StatefulSet did not prove readiness after its stuck pod was deleted; reobserve before retry"
    , testCase "runtime: a refusing cluster guard deletes nothing" $ do
        (outcome, asked) <- runtimeReplace (Left "wrong cluster") (const (Right (ExitSuccess, "", "")))
        (outcome, asked) @?= (AdapterEffectFailed (KnownNoEffect "cluster guard refused the pod replacement: wrong cluster"), [])
    , testCase "settle and recover: every row of the class table" $ do
        let observed setRead pod' = Right (ReplacementObservation setRead pod')
            proof = ok (replacementProof replacementFixture)
            classify observation = (recoverReplacement replacementFixture observation, settleReplacement replacementFixture observation)
        -- A delete answered 409, 422 or 404 is journalled as a refusal (see
        -- "runtime: a 409 refusal had no effect"); close classes it no effect.
        classify (observed (Just (planUid, False)) ReviewedPodLive) @?= (RecoverySafeToRetry, SettledNoEffect "the reviewed pod is live and was never deleted")
        classify (observed (Just (planUid, False)) ReviewedPodTerminating) @?= (RecoveryLandedUnready planUid, SettledLanded planUid)
        classify (observed (Just (planUid, True)) ReviewedPodGone) @?= (RecoveryProvedComplete proof, SettledUnknown "the effect is proved complete" "inventory resume")
        classify (observed (Just (planUid, False)) ReviewedPodGone) @?= (RecoveryLandedUnready planUid, SettledLanded planUid)
        classify (observed (Just (uidOf "sts-uid-2", True)) ReviewedPodGone) @?= (RecoveryTargetReplaced (uidOf "sts-uid-2"), SettledTargetGone (Just (uidOf "sts-uid-2")))
        classify (observed Nothing ReviewedPodGone) @?= (RecoveryUnresolved "the reviewed StatefulSet is gone", SettledTargetGone Nothing)
        classify (Left "forbidden") @?= (RecoveryUnresolved "forbidden", SettledUnknown "forbidden" "a provider observation that proves the effect")
    , testCase "settle and recover: a Ready StatefulSet with the reviewed pod still live is no effect, never complete" $
        recoverReplacement replacementFixture (Right (ReplacementObservation (Just (planUid, True)) ReviewedPodLive)) @?= RecoverySafeToRetry
    , testCase "runtime: the replacement is observed by the StatefulSet's UID and readiness at the reviewed revision, and the pod by name and UID" $ do
        let ready = statefulSet 3 (Just 3) (Just "pg-d9d6d") & atStatus .~ object ["observedGeneration" .= (3 :: Int), "replicas" .= (1 :: Int), "readyReplicas" .= (1 :: Int), "updatedReplicas" .= (1 :: Int), "updateRevision" .= ("pg-d9d6d" :: Text)]
            readyElsewhere = statefulSet 3 (Just 3) (Just "pg-0aaaa") & atStatus .~ object ["observedGeneration" .= (3 :: Int), "replicas" .= (1 :: Int), "readyReplicas" .= (1 :: Int), "updatedReplicas" .= (1 :: Int), "updateRevision" .= ("pg-0aaaa" :: Text)]
        (live, asked) <- runtimeObserve (Just (statefulSet 3 (Just 3) (Just "pg-d9d6d"))) (Just (pgPod "pg-0" "pg-9d647" False))
        live @?= Right (ReplacementObservation (Just (uidOf "sts-uid", False)) ReviewedPodLive)
        map (take 3) asked @?= [["get", "statefulset.apps", "pg"], ["get", "pod", "pg-0"]]
        runtimeObserve (Just ready) (Just (terminating (pgPod "pg-0" "pg-9d647" False))) >>= (@?= Right (ReplacementObservation (Just (uidOf "sts-uid", True)) ReviewedPodTerminating)) . fst
        runtimeObserve (Just ready) (Just (podWith "sts-uid" "pg-0" (Just "pg-d9d6d") True False & atUid .~ "uid-pg-0-new")) >>= (@?= Right (ReplacementObservation (Just (uidOf "sts-uid", True)) ReviewedPodGone)) . fst
        runtimeObserve (Just readyElsewhere) Nothing >>= (@?= Right (ReplacementObservation (Just (uidOf "sts-uid", False)) ReviewedPodGone)) . fst
        runtimeObserve Nothing Nothing >>= (@?= Right (ReplacementObservation Nothing ReviewedPodGone)) . fst
    , testCase "verify: a completed replacement is proved by the same table" $ do
        let verifyAfter observation = do
              current <- newIORef (Right (Just reviewedPod))
              calls <- newIORef 0
              state <- newIORef (notReady statefulDigest)
              let ops = K.ops state calls
                  podOps = noPodOps {readStuckPod = \_ -> readIORef current, observeReplacement = \_ -> pure observation}
                  adapter = mkKubernetesAdapterWithObservations databaseNative ops podOps (traverse (kubernetesObserve ops)) noReceipt noScratch Nothing Nothing
              prepared <- adapterPrepare adapter replaceOperation >>= expectRight
              adapterVerify adapter replaceOperation prepared
        verifyAfter (Right (ReplacementObservation (Just (uidOf "sts-uid", True)) ReviewedPodGone)) >>= (@?= replacementProof replacementFixture)
        verifyAfter (Right (ReplacementObservation (Just (uidOf "sts-uid", False)) ReviewedPodGone)) >>= assertBool "a replacement whose StatefulSet is not Ready verified" . isLeft
    , testCase "apply: a replacement whose StatefulSet becomes Ready converges" $ do
        (_, _, _, applied) <- applyReplacement AdapterEffectCompleted (ReplacementObservation (Just (planUid, True)) ReviewedPodGone)
        case applied of
          Converged _ -> pure ()
          other -> assertFailure ("the replacement did not converge: " <> show other)
    , testCase "close: a landed replacement keeps the scope's desired revision" $ do
        (store, registry, reviewed, applied) <-
          applyReplacement
            (AdapterEffectAmbiguous "the StatefulSet did not prove readiness after its stuck pod was deleted; reobserve before retry")
            (ReplacementObservation (Just (planUid, False)) ReviewedPodGone)
        transaction <- case applied of
          StoppedAmbiguous tx _ -> pure tx
          other -> assertFailure ("the replacement did not stop: " <> show other) >> pure (error "unreachable")
        record <- closeTransaction store registry (CloseInput transaction (contentDigest (encodeReviewDocument (reviewedDocument reviewed))) False Nothing) >>= expectRight
        Map.elems (closedClasses record) @?= [ClassLanded planUid]
        Map.elems (closedScopes record) @?= [KeepDesired]
        after <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> pure (error "unreachable")) pure
        headActiveTransaction after @?= Nothing
        Map.lookup planOwner (headAccepted after) @?= Map.lookup planOwner (reviewDesiredRevisions (reviewedDocument reviewed))
    , testCase "doctor: a stamped StatefulSet whose rollout is stuck fails its probe; an unstamped or Ready one does not" $ do
        let stamped = statefulSet 3 (Just 3) (Just "pg-d9d6d") & atAnnotations .~ object ["nagare.dev/resource-id" .= resourceIdText statefulId]
            encoded = BL.toStrict . encode
        parseStuckRollouts (encoded (pods [stamped])) (encoded (pods [pgPod "pg-0" "pg-9d647" False]))
          @?= Just [Probe "stuck rollout personal/pg" StatusFail "pg-0 at revision 9d647 is not Ready and blocks the rollout to d9d6d"]
        parseStuckRollouts (encoded (pods [statefulSet 3 (Just 3) (Just "pg-d9d6d")])) (encoded (pods [pgPod "pg-0" "pg-9d647" False]))
          @?= Just [Probe "stuck rollouts" StatusOk "none"]
        parseStuckRollouts (encoded (pods [stamped])) (encoded (pods [pgPod "pg-0" "pg-9d647" True]))
          @?= Just [Probe "stuck rollouts" StatusOk "none"]
        parseStuckRollouts (encoded (pods [stamped & atStatus .~ object ["observedGeneration" .= (3 :: Int)]])) (encoded (pods []))
          @?= Just [Probe "stuck rollout personal/pg" StatusUnknown "Error in $: key \"updateRevision\" not found"]
    , testCase "db restart: a stuck StatefulSet submits its accepted scope unchanged, and the plan replaces the stuck pod" $ do
        (revised, native, note) <- expectRight (compileStatefulSetRestart (Just reviewedPod) DatabaseObjects "pg" "personal" "2026-10-06T00:00:00Z" databaseScope databaseNative)
        (revised, native) @?= (databaseScope, databaseNative)
        note @?= Just "rollout stuck on pod pg-0 at revision pg-9d647; proposing replace-stuck-pod instead of a restart token"
        planned <- planDatabase revised (Map.singleton statefulId "pg-0 at revision pg-9d647 is not Ready and blocks the rollout to pg-d9d6d")
        map (\operation -> (plannedAction operation, plannedResources operation)) planned @?= [(ReplaceStuckPod, statefulId :| [])]
    , testCase "db restart: a StatefulSet that is not stuck stamps a new restart token, as before" $ do
        (revised, _, note) <- expectRight (compileStatefulSetRestart Nothing DatabaseObjects "pg" "personal" "2026-10-06T00:00:00Z" databaseScope databaseNative)
        note @?= Nothing
        assertBool "the restart did not change the scope" (revised /= databaseScope)
        planned <- planDatabase revised Map.empty
        map (\operation -> (plannedAction operation, plannedResources operation)) planned @?= [(UpdateResource, statefulId :| [])]
    , testCase "prepare: a member that is not a StatefulSet refuses" $ do
        calls <- newIORef 0
        state <- newIORef (KubernetesNotReady K.physical "1" (Just K.resource) (contentDigest K.nativeBytes))
        let adapter = mkKubernetesAdapterWithObservations K.specs (K.ops state calls) (noPodOps {readStuckPod = \_ -> pure (Right (Just reviewedPod))}) (traverse (kubernetesObserve (K.ops state calls))) noReceipt noScratch Nothing Nothing
        prepared <- adapterPrepare adapter (K.operation ReplaceStuckPod)
        case prepared of
          Left (PrepareRefused _ reason) -> reason @?= "a stuck pod is replaced only for an apps/StatefulSet"
          other -> assertFailure ("prepared a replacement for a Service: " <> show other)
    ]

-- * Planning

-- | A blocked rollout, as the Kubernetes adapter reports it.
blocked :: Map ResourceId Text
blocked = Map.singleton planId "pg-0 at revision pg-9d647 is not Ready and blocks the rollout to pg-d9d6d"

planOwner :: ScopeId
planOwner = ok (mkScopeId Platform "stuck")

planId :: ResourceId
planId = mintResourceId planOwner (ok (mkLogicalKey "pg")) (ok (mkName "statefulset"))

planCluster :: ResourceId
planCluster = mintResourceId planOwner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))

planUid :: PhysicalIdentity
planUid = uidOf "sts-uid"

-- | A member StatefulSet whose declaration is the given template.
planMember :: Text -> ManagedResource
planMember template =
  ManagedResource
    { identity = planId
    , owner = planOwner
    , executor = KubernetesExecutor
    , address = Kubernetes planCluster "apps" (ok (mkName "statefulset")) (Just (ok (mkName "personal"))) (ok (mkName "pg"))
    , aliases = []
    , spec = StatefulSet 1 [] (contentDigest (TE.encodeUtf8 template))
    , lifecycle = Retain
    , dataPolicy = Stateless
    , sensitivity = Public
    , dependencies = []
    , delegations = []
    , source = SourceLocation "test" "pg"
    }

planScope :: ManagedResource -> ScopeDeclaration
planScope member' = ok (mkScopeDeclaration planOwner [ResourceBundle [Managed member'] [] [] [] [] []])

-- | Accept and apply @accepted@, then plan @desired@ against this observation.
planAccepted :: ManagedResource -> ManagedResource -> ResourceObservation -> Map ResourceId Text -> IO [PlannedOperation]
planAccepted accepted desired fact stuck = do
  (_, candidate, history) <- acceptedStore accepted desired
  pure (proposalOperations (ok (planChanges candidate noLifecycleDecisions history (withStuckRollouts stuck (ok (observationSet [(planId, fact)]))))))

-- | Accept and apply the database fixture's scope, then plan @desired@
-- against every member observed unchanged, with these stuck rollouts.
planDatabase :: ScopeDeclaration -> Map ResourceId Text -> IO [PlannedOperation]
planDatabase desired stuck = do
  (_, candidate, history) <- acceptedScopes databaseScope desired
  let required = requirementsByExecutor (observationRequirements candidate history)
      facts = [(resource, ObservedPresent (uidOf ("uid-" <> resourceIdText resource))) | resources <- Map.elems required, resource <- resources]
  pure (proposalOperations (ok (planChanges candidate noLifecycleDecisions history (withStuckRollouts stuck (ok (observationSet facts))))))

-- | A store that accepted and applied @accepted@, with the candidate and
-- planning history for @desired@.
acceptedStore :: ManagedResource -> ManagedResource -> IO (InventoryStore, CompositionCandidate, InventoryHistory)
acceptedStore accepted desired = acceptedScopes (planScope accepted) (planScope desired)

-- | A store that accepted and applied @accepted@, with the candidate and
-- planning history for @desired@.
acceptedScopes :: ScopeDeclaration -> ScopeDeclaration -> IO (InventoryStore, CompositionCandidate, InventoryHistory)
acceptedScopes accepted desired = do
  store <- newMemoryStore
  _ <- initializeStore store fixtureBinding "stuck-pod-plan" >>= expectRight
  let registry = recordingRegistryWith (\_ _ -> pure (Right ())) (\_ _ -> pure AdapterEffectCompleted) (\_ _ -> pure RecoverySafeToRetry)
      candidateFor scope' = do
        history <- loadInventoryHistory store >>= expectRight
        let base = Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)
            candidate = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding base Map.empty)) (ReplaceScope scope' :| []))
        planning <- loadInventoryPlanningHistory store candidate >>= expectRight
        pure (candidate, planning)
  (initial, empty') <- candidateFor accepted
  snapshot <- readStoreSnapshot store >>= expectRight
  let absent = [(resource, ConfirmedAbsent (contentDigest "absent")) | resources <- Map.elems (requirementsByExecutor (observationRequirements initial empty')), resource <- resources]
  bundle <- prepareReview registry snapshot (ok (planChanges initial noLifecycleDecisions empty' (ok (observationSet absent)))) >>= expectRight
  _ <- publishReview store bundle >>= expectRight
  published <- readStoreSnapshot store >>= expectRight
  reviewed <- expectRight (verifyReview published bundle)
  _ <- applyReviewed store registry reviewed >>= expectRight
  (candidate, history) <- candidateFor desired
  pure (store, candidate, history)

-- * The production-shaped adapter over a stubbed kubectl

-- | The member StatefulSet, bound as the compiler binds it.
pgBound :: (ManagedResource, ByteString)
pgBound = ok (bindKubernetesObject (KubernetesInput planId planOwner planCluster pgDesired (contentDigest (ok (canonicalValue pgDesired))) Retain Stateless Private (SourceLocation "test" "pg")))

pgDesired :: Value
pgDesired =
  object
    [ "apiVersion" .= ("apps/v1" :: Text)
    , "kind" .= ("StatefulSet" :: Text)
    , "metadata" .= object ["name" .= ("pg" :: Text), "namespace" .= ("personal" :: Text)]
    , "spec" .= pgSpec
    ]

pgSpec :: Value
pgSpec =
  object
    [ "replicas" .= (1 :: Int)
    , "serviceName" .= ("pg" :: Text)
    , "selector" .= object ["matchLabels" .= object ["app" .= ("pg" :: Text)]]
    , "template" .= object ["metadata" .= object ["labels" .= object ["app" .= ("pg" :: Text)]], "spec" .= object ["containers" .= [object ["name" .= ("pg" :: Text), "image" .= ("postgres:18" :: Text)]]]]
    ]

-- | E6f's final state: the corrected template landed (generation 3, observed)
-- and the pod at the broken revision is not Ready.
pgLive :: Value
pgLive =
  object
    [ "apiVersion" .= ("apps/v1" :: Text)
    , "kind" .= ("StatefulSet" :: Text)
    , "metadata"
        .= object
          [ "name" .= ("pg" :: Text)
          , "namespace" .= ("personal" :: Text)
          , "uid" .= ("sts-uid" :: Text)
          , "resourceVersion" .= ("7" :: Text)
          , "generation" .= (3 :: Int)
          , "annotations"
              .= object
                [ "nagare.dev/context-id" .= contextIdText (fixtureBinding ^. #identity)
                , "nagare.dev/resource-id" .= resourceIdText planId
                , "nagare.dev/spec-digest" .= digestText (contentDigest (snd pgBound))
                ]
          ]
    , "spec" .= pgSpec
    , "status" .= object ["observedGeneration" .= (3 :: Int), "replicas" .= (1 :: Int), "readyReplicas" .= (0 :: Int), "updatedReplicas" .= (0 :: Int), "currentRevision" .= ("pg-9d647" :: Text), "updateRevision" .= ("pg-d9d6d" :: Text)]
    ]

-- | The adapter production installs, over a kubectl that answers with E6f's
-- StatefulSet and its stuck pod, and the requests it was asked.
runtimeRegistry :: IO (AdapterRegistry, IORef [[String]])
runtimeRegistry = do
  asked <- newIORef []
  let answer request = do
        modifyIORef' asked (<> [request ^. #arguments])
        pure $ case request ^. #arguments of
          "get" : "statefulset.apps" : _ -> Right (ExitSuccess, BLC.unpack (encode pgLive), "")
          "get" : "pods" : _ -> Right (ExitSuccess, BLC.unpack (encode (pods [pgPod "pg-0" "pg-9d647" False])), "")
          other -> Left ("unexpected kubectl call " <> T.pack (show other))
      config = withKubectlInterpreter (runKubectlWith answer) (KubernetesRuntimeConfig (fixtureBinding ^. #identity) "stuck-pod" (pure (Right ())))
      specs = Map.singleton planId pgBound
      (ops, batch) = mkKubernetesRuntimeOpsAndBatchWithCacheKey config (\_ -> pure (Left "no cache output")) specs
  pure (ok (mkAdapterRegistry [mkKubernetesAdapterWithObservations specs ops (runtimePodOps config specs) batch noReceipt noScratch Nothing Nothing]), asked)

-- * The adapter over the database fixture

reviewedPod :: StuckPod
reviewedPod = StuckPod "pg-0" "personal" (uidOf "uid-pg-0") "rv-pg-0" "pg-9d647" (uidOf "sts-uid") "pg-d9d6d"

statefulDigest :: ContentDigest
statefulDigest = maybe (error "the database has no StatefulSet") (contentDigest . snd) (Map.lookup statefulId databaseNative)

notReady :: ContentDigest -> KubernetesState
notReady = KubernetesNotReady K.physical "1" (Just statefulId)

replaceOperation :: PlannedOperation
replaceOperation = (K.operation ReplaceStuckPod) {plannedResources = statefulId :| []}

-- | The database's Kubernetes adapter over a StatefulSet that is not Ready,
-- with its pod reads answered by @answer@.
databaseAdapter :: IO (Either Text (Maybe StuckPod)) -> IO Adapter
databaseAdapter answer = do
  calls <- newIORef 0
  current <- newIORef (notReady statefulDigest)
  let ops = K.ops current calls
  pure (mkKubernetesAdapterWithObservations databaseNative ops (noPodOps {readStuckPod = \_ -> answer}) (traverse (kubernetesObserve ops)) noReceipt noScratch Nothing Nothing)

-- | Prepare the replacement of 'reviewedPod', then preflight and execute it
-- once the fresh read answers @fresh@. Replacements are recorded, not run.
executeAfter :: Either Text (Maybe StuckPod) -> IO (AdapterExecution, [(StuckPod, Text)], Either Text ())
executeAfter fresh = do
  current <- newIORef (Right (Just reviewedPod))
  replaced <- newIORef []
  calls <- newIORef 0
  state <- newIORef (notReady statefulDigest)
  let ops = K.ops state calls
      podOps =
        noPodOps
          { readStuckPod = \_ -> readIORef current
          , replaceStuckPod = \replacement revision -> modifyIORef' replaced (<> [(replacement ^. #stuck, revision)]) >> pure AdapterEffectCompleted
          }
      adapter = mkKubernetesAdapterWithObservations databaseNative ops podOps (traverse (kubernetesObserve ops)) noReceipt noScratch Nothing Nothing
  prepared <- adapterPrepare adapter replaceOperation >>= expectRight
  writeIORef current fresh
  checked <- adapterPreflight adapter replaceOperation prepared
  outcome <- adapterExecute adapter replaceOperation prepared
  (outcome,,checked) <$> readIORef replaced

-- | Replace 'reviewedPod' at resourceVersion @rv-fresh@ through the runtime,
-- over a kubectl that answers with @respond@; the requests and their input.
runtimeReplace :: Either Text () -> ([String] -> Either Text (ExitCode, String, String)) -> IO (AdapterExecution, [([String], String)])
runtimeReplace guard' respond = do
  asked <- newIORef []
  let answer request = do
        modifyIORef' asked (<> [(request ^. #arguments, request ^. #input)])
        pure (respond (request ^. #arguments))
      config = withKubectlInterpreter (runKubectlWith answer) (KubernetesRuntimeConfig (fixtureBinding ^. #identity) "stuck-pod" (pure guard'))
      target = maybe (error "the database has no StatefulSet") ((^. #address) . fst) (Map.lookup statefulId databaseNative)
      replacement = PodReplacement 1 (plannedOperationId replaceOperation) (plannedInputDigest replaceOperation) statefulId target reviewedPod
  outcome <- replaceStuckPod (runtimePodOps config databaseNative) replacement "rv-fresh"
  (outcome,) <$> readIORef asked

-- | Plan, review and apply the planning member's stuck-pod replacement,
-- whose delete answers @executed@ and whose fresh observation is @observed@.
applyReplacement :: AdapterExecution -> ReplacementObservation -> IO (InventoryStore, AdapterRegistry, ReviewedPlan, TransactionResult)
applyReplacement executed observed = do
  let (declared, _) = pgBound
  (store, candidate, history) <- acceptedStore declared declared
  calls <- newIORef 0
  state <- newIORef (KubernetesNotReady planUid "7" (Just planId) (contentDigest (snd pgBound)))
  let ops = K.ops state calls
      specs = Map.singleton planId pgBound
      podOps =
        noPodOps
          { readStuckPod = \_ -> pure (Right (Just (reviewedPod & #statefulSetUid .~ planUid)))
          , replaceStuckPod = \_ _ -> pure executed
          , observeReplacement = \_ -> pure (Right observed)
          }
      registry = ok (mkAdapterRegistry [mkKubernetesAdapterWithObservations specs ops podOps (traverse (kubernetesObserve ops)) noReceipt noScratch Nothing Nothing])
  observations <- observeWithRegistry registry (requirementsByExecutor (observationRequirements candidate history)) >>= expectRight
  snapshot <- readStoreSnapshot store >>= expectRight
  bundle <- prepareReview registry snapshot (ok (planChanges candidate noLifecycleDecisions history observations)) >>= expectRight
  _ <- publishReview store bundle >>= expectRight
  published <- readStoreSnapshot store >>= expectRight
  reviewed <- expectRight (verifyReview published bundle)
  applied <- applyReviewed store registry reviewed >>= expectRight
  pure (store, registry, reviewed, applied)

-- | The replacement of 'reviewedPod' on the planning member.
replacementFixture :: PodReplacement
replacementFixture = PodReplacement 1 (plannedOperationId replaceOperation) (plannedInputDigest replaceOperation) planId (fst pgBound ^. #address) (reviewedPod & #statefulSetUid .~ planUid)

-- | Observe 'replacementFixture' through the runtime, over a kubectl that
-- answers with this StatefulSet and pod (or none); the requests it was asked.
runtimeObserve :: Maybe Value -> Maybe Value -> IO (Either Text ReplacementObservation, [[String]])
runtimeObserve setRead pod' = do
  asked <- newIORef []
  let answer request = do
        modifyIORef' asked (<> [request ^. #arguments])
        pure $ case request ^. #arguments of
          "get" : "statefulset.apps" : _ -> Right (ExitSuccess, maybe "" (BLC.unpack . encode) setRead, "")
          "get" : "pod" : _ -> Right (ExitSuccess, maybe "" (BLC.unpack . encode) pod', "")
          other -> Left ("unexpected kubectl call " <> T.pack (show other))
      config = withKubectlInterpreter (runKubectlWith answer) (KubernetesRuntimeConfig (fixtureBinding ^. #identity) "stuck-pod" (pure (Right ())))
  observed <- observeReplacement (runtimePodOps config (Map.singleton planId pgBound)) replacementFixture
  (observed,) <$> readIORef asked

-- | A Kubernetes object's status.
atStatus :: Traversal' Value Value
atStatus f = \case
  Object root -> Object <$> KM.alterF (fmap Just . f . fromMaybe Null) "status" root
  other -> pure other

-- | A Kubernetes object's metadata.annotations.
atAnnotations :: Traversal' Value Value
atAnnotations f = \case
  Object root
    | Just (Object metadata) <- KM.lookup "metadata" root ->
        (\new -> Object (KM.insert "metadata" (Object (KM.insert "annotations" new metadata)) root)) <$> f (fromMaybe Null (KM.lookup "annotations" metadata))
  other -> pure other

-- | A Kubernetes object's metadata.uid.
atUid :: Traversal' Value Text
atUid f = \case
  Object root
    | Just (Object metadata) <- KM.lookup "metadata" root
    , Just (String uid') <- KM.lookup "uid" metadata ->
        (\new -> Object (KM.insert "metadata" (Object (KM.insert "uid" (String new) metadata)) root)) <$> f uid'
  other -> pure other

-- | Observe the database over one StatefulSet state, recording pod reads.
observeDatabase :: KubernetesState -> IO (Either Text (Maybe StuckPod)) -> IO (Either Text ObservationSet, [ResourceId])
observeDatabase state answer = do
  podReads <- newIORef []
  calls <- newIORef 0
  current <- newIORef state
  let ops = K.ops current calls
      podOps = noPodOps {readStuckPod = \resource -> modifyIORef' podReads (<> [resource]) >> answer}
      adapter = mkKubernetesAdapterWithObservations databaseNative ops podOps (traverse (kubernetesObserve ops)) noReceipt noScratch Nothing Nothing
  observed <- adapterObserve adapter (Map.keys databaseNative)
  (observed,) <$> readIORef podReads

noReceipt :: ResourceId -> PhysicalIdentity -> IO (Either Text ByteString)
noReceipt _ _ = pure (Left "no receipt")

noScratch :: ResourceId -> PhysicalIdentity -> IO (Either Text Bool)
noScratch _ _ = pure (Right False)

-- | Read the database fixture's stuck pod through a stubbed kubectl that
-- answers with these objects, and return what was asked.
runtimeRead :: Either Text () -> (Value, Value) -> IO (Either Text (Maybe StuckPod), [[String]])
runtimeRead guard' (statefulSet', listed) = do
  asked <- newIORef []
  let answer request = do
        modifyIORef' asked (<> [request ^. #arguments])
        pure $ case request ^. #arguments of
          "get" : "statefulset.apps" : _ -> Right (ExitSuccess, BLC.unpack (encode statefulSet'), "")
          "get" : "pods" : _ -> Right (ExitSuccess, BLC.unpack (encode listed), "")
          other -> Left ("unexpected kubectl call " <> T.pack (show other))
      config = withKubectlInterpreter (runKubectlWith answer) (KubernetesRuntimeConfig (fixtureBinding ^. #identity) "stuck-pod" (pure guard'))
  found <- readStuckPod (runtimePodOps config databaseNative) statefulId
  (found,) <$> readIORef asked

readyStatefulSet :: Value
readyStatefulSet =
  object
    [ "apiVersion" .= ("apps/v1" :: Text)
    , "kind" .= ("StatefulSet" :: Text)
    , "metadata" .= object ["name" .= ("pg" :: Text), "namespace" .= ("personal" :: Text), "uid" .= ("sts-uid" :: Text), "generation" .= (2 :: Int)]
    , "spec" .= object ["replicas" .= (1 :: Int), "selector" .= object ["matchLabels" .= object ["app" .= ("pg" :: Text)]]]
    , "status" .= object ["observedGeneration" .= (2 :: Int), "replicas" .= (1 :: Int), "readyReplicas" .= (1 :: Int), "updatedReplicas" .= (1 :: Int), "updateRevision" .= ("pg-d9d6d" :: Text), "currentRevision" .= ("pg-d9d6d" :: Text)]
    ]

statefulSet :: Integer -> Maybe Integer -> Maybe Text -> Value
statefulSet generation observed revision =
  object
    [ "apiVersion" .= ("apps/v1" :: Text)
    , "kind" .= ("StatefulSet" :: Text)
    , "metadata" .= object ["name" .= ("pg" :: Text), "namespace" .= ("personal" :: Text), "uid" .= ("sts-uid" :: Text), "generation" .= generation]
    , "spec" .= object ["replicas" .= (1 :: Int), "selector" .= object ["matchLabels" .= object ["app" .= ("pg" :: Text)]]]
    , "status" .= object (["observedGeneration" .= value | Just value <- [observed]] <> ["updateRevision" .= value | Just value <- [revision]] <> ["replicas" .= (1 :: Int)])
    ]

pods :: [Value] -> Value
pods items = object ["apiVersion" .= ("v1" :: Text), "kind" .= ("List" :: Text), "items" .= items]

pgPod :: Text -> Text -> Bool -> Value
pgPod name revision ready = podWith "sts-uid" name (Just revision) ready False

terminating :: Value -> Value
terminating _ = podWith "sts-uid" "pg-0" (Just "pg-9d647") False True

podWith :: Text -> Text -> Maybe Text -> Bool -> Bool -> Value
podWith owner name revision ready deleting =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("Pod" :: Text)
    , "metadata"
        .= object
          ( [ "name" .= name
            , "namespace" .= ("personal" :: Text)
            , "uid" .= ("uid-" <> name)
            , "resourceVersion" .= ("rv-" <> name)
            , "labels" .= object (["app" .= ("pg" :: Text)] <> ["controller-revision-hash" .= value | Just value <- [revision]])
            , "ownerReferences" .= [object ["apiVersion" .= ("apps/v1" :: Text), "kind" .= ("StatefulSet" :: Text), "name" .= ("pg" :: Text), "uid" .= owner, "controller" .= True]]
            ]
              <> ["deletionTimestamp" .= ("2026-10-06T00:00:00Z" :: Text) | deleting]
          )
    , "status" .= object ["phase" .= ("Running" :: Text), "conditions" .= [object ["type" .= ("Ready" :: Text), "status" .= (if ready then "True" else "False" :: Text)]]]
    ]

uidOf :: Text -> PhysicalIdentity
uidOf = either (error . show) id . mkPhysicalIdentity

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> error "unreachable") pure

assertLeft :: (Show a) => Either e a -> Assertion
assertLeft = either (const (pure ())) (\found -> assertFailure ("expected an error, got " <> show found))
