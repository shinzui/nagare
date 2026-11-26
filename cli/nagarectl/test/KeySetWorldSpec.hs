-- | EP-286 M3: a key set's scope through review, the journal and the model
-- world. The members are the compiled scope's own bytes and edges, executed
-- by the production adapter over the fake API server. The rotator's writes
-- are Update requests by its field manager, as the in-cluster rotator makes
-- them; a re-plan must neither see them as drift nor clear them.
module KeySetWorldSpec (keySetWorldTests) where

import Control.Monad (forM_)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import InventoryTransactionSpec (fixtureBinding)
import KeySetSpec (compileKeySet, rotatorImage, viewGrants)
import Nagare.Database.Secret (b64encode)
import Nagare.Dsl.KeySet
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter (AdapterRegistry, ObservationSet, OperationAction (..), PlannedOperation (..), mkAdapterRegistry, observeWithRegistry)
import Nagare.Inventory.CollectionPolicy (collectionWaves)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (TransactionResult (..), applyReviewed, resumeTransaction)
import Nagare.Inventory.KeySet (keySetScopeId)
import Nagare.Inventory.Lifecycle (decideCollection, decideMemberRetirement)
import Nagare.Inventory.Plan
import Nagare.Inventory.Status (kubernetesMembersForReview)
import Nagare.Inventory.Store
import Nagare.KeySet.Rotator (keySetFieldManager)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (RetirementIntent (RetainResources))
import Nagare.Resource.Types
import Nagare.Test.World.Adversary (Adversary, Boundary (..), Call (MutateCall), Fault (LostAcknowledgement), newAdversary)
import Nagare.Test.World.ApiServer (ObjectKey (..), Outcome (Failed), Stored, patchUpdate)
import Nagare.Test.World.Kubernetes (KubeWorld, newKubeWorld, worldKubernetesAdapter)
import Test.Tasty
import Test.Tasty.HUnit

keySetWorldTests :: TestTree
keySetWorldTests =
  testGroup
    "key set scope in the model world"
    [ testCase "a key set converges with its first-run Job complete and no key in any reviewed byte" $ do
        run <- newRun []
        (native, review, result) <- plan run Map.empty rotatorImage viewGrants
        converged result
        Map.size <$> live run "job" >>= (@?= 1)
        Map.size <$> live run "cronjob" >>= (@?= 1)
        rotate run
        let reviewed = BS.concat (encodeReviewDocument (reviewBundleDocument review) : Map.elems (reviewBundleScopes review) <> Map.elems (reviewBundleNative review) <> map snd (Map.elems native))
        assertBool "the review holds the rotator's private key" (not (TE.encodeUtf8 privateKey `BS.isInfixOf` reviewed))
    , testCase "after the rotator writes both key files a re-plan changes nothing and keeps them" $ do
        run <- newRun []
        (native, _, result) <- plan run Map.empty rotatorImage viewGrants
        converged result
        rotate run
        (_, proposal', again) <- planned run native rotatorImage viewGrants
        converged again
        changing proposal' @?= []
        dataOf run secretKey >>= (@?= Map.fromList [("private.json", String (b64 privateKey))])
        dataOf run publicKey >>= (@?= Map.fromList [("policy.json", String policy60), ("public.json", String publicFile)])
    , testCase "a policy change updates only the ConfigMap's policy and keeps the rotator's public file" $ do
        run <- newRun []
        (native, _, result) <- plan run Map.empty rotatorImage viewGrants
        converged result
        rotate run
        let slower = viewGrants & #rotation .~ ok (mkRotationPolicy (ok (mkMinutes 120)) (ok (mkMinutes 10)))
        (_, proposal', result') <- planned run native rotatorImage slower
        converged result'
        changing proposal' @?= [UpdateResource]
        configMap <- dataOf run publicKey
        Map.lookup "public.json" configMap @?= Just (String publicFile)
        Map.lookup "policy.json" configMap @?= Just (String "{\"overlapMinutes\":10,\"periodMinutes\":120}")
        dataOf run secretKey >>= (@?= Map.fromList [("private.json", String (b64 privateKey))])
    , testCase "a third writer of the public file stops the policy update, which leaves the ConfigMap as it was" $ do
        run <- newRun []
        (native, _, result) <- plan run Map.empty rotatorImage viewGrants
        converged result
        rotate run
        write run "kubectl-edit" publicKey (object ["data" .= object ["public.json" .= ("{\"keys\":[]}" :: Text)]])
        let slower = viewGrants & #rotation .~ ok (mkRotationPolicy (ok (mkMinutes 120)) (ok (mkMinutes 10)))
        (_, _, result') <- planned run native rotatorImage slower
        case result' of
          Converged _ -> assertFailure "an update over a third writer's field converged"
          _ -> pure ()
        Map.lookup "policy.json" <$> dataOf run publicKey >>= (@?= Just (String policy60))
    , testCase "a first-run Job that fails stops the review with the objects and the grant in place" $ do
        run <- newRun []
        (_, native) <- expectRight (compileKeySet rotatorImage viewGrants)
        modifyIORef' (world run) (#server . #outcomes %~ Map.union (Map.fromList [(digestText (contentDigest bytes), Failed) | (resource, bytes) <- Map.elems native, isJob resource]))
        (_, _, result) <- plan run Map.empty rotatorImage viewGrants
        case result of
          Converged _ -> assertFailure "a failed first-run Job converged"
          _ -> pure ()
        Map.member secretKey <$> live run "secret" >>= (@?= True)
        Map.size <$> live run "rolebinding" >>= (@?= 1)
    , testCase "a lost acknowledgement at any write resumes to one set of objects" $
        forM_ [1 .. 7] $ \ordinal -> do
          run <- newRun [(Boundary MutateCall ordinal, LostAcknowledgement)]
          (_, _, registry, result) <- reviewedPlan run Map.empty rotatorImage viewGrants
          settled <- case result of
            Converged _ -> pure result
            StoppedAmbiguous transaction _ _ -> resumeTransaction (store run) registry transaction >>= expectRight
            StoppedFailed transaction _ _ -> resumeTransaction (store run) registry transaction >>= expectRight
            other -> assertFailure ("write " <> show ordinal <> ": " <> show other) >> pure other
          case settled of
            Converged _ -> pure ()
            other -> assertFailure ("write " <> show ordinal <> " did not resume: " <> show other)
          forM_ ["secret", "configmap", "serviceaccount", "role", "rolebinding", "cronjob", "job"] $ \kind ->
            Map.size <$> live run kind >>= (@?= 1)
    , testCase "a new image replaces the first-run Job in one review and keeps the keys" $ do
        run <- newRun []
        (native, _, result) <- plan run Map.empty rotatorImage viewGrants
        converged result
        rotate run
        (_, proposal', result') <- planned run native ("k3d-registry.localhost:5000/nagare-admin-api@sha256:" <> T.replicate 64 "d") viewGrants
        converged result'
        assertBool "the new Job is created" (CreateResource `elem` changing proposal')
        assertBool "the CronJob is updated" (UpdateResource `elem` changing proposal')
        Map.size <$> live run "job" >>= (@?= 2)
        dataOf run secretKey >>= (@?= Map.fromList [("private.json", String (b64 privateKey))])
    , testCase "a retired key set keeps its objects, and collecting it deletes all seven, its private keys included" $ do
        run <- newRun []
        (native, _, result) <- plan run Map.empty rotatorImage viewGrants
        converged result
        rotate run
        let owner = ok (keySetScopeId viewGrants)
            members = Map.keys native
        retired <- changed run native (RetireScope owner RetainResources NE.:| []) (decideMemberRetirement members)
        converged retired
        Map.member secretKey <$> live run "secret" >>= (@?= True)
        -- One collect review per wave, leaves first: a member is refused while a retained member depends on it.
        let waves = collectionWaves (map fst (Map.elems native))
        length waves @?= 3
        forM_ waves $ \wave -> changed run native (NE.fromList (map CollectRetained wave)) decideCollection >>= converged
        forM_ ["secret", "configmap", "serviceaccount", "role", "rolebinding", "cronjob", "job"] $ \kind ->
          Map.size <$> live run kind >>= (@?= 0)
    ]
  where
    secretKey = ObjectKey "" "secret" (Just "personal") "nagare-keyset-view-grants"
    publicKey = ObjectKey "" "configmap" (Just "personal") "nagare-keyset-view-grants-public"
    policy60 = "{\"overlapMinutes\":10,\"periodMinutes\":60}"
    privateKey = "{\"keys\":[{\"d\":\"c2VjcmV0\",\"kid\":\"k1\"}]}"
    publicFile = "{\"keys\":[{\"kid\":\"k1\"}]}"
    -- The rotator's two writes, the ConfigMap first.
    rotate run = do
      write run keySetFieldManager publicKey (object ["data" .= object ["public.json" .= publicFile]])
      write run keySetFieldManager secretKey (object ["data" .= object ["private.json" .= b64 privateKey]])
    isJob resource = case resource ^. #address of
      Kubernetes _ "batch" kind _ _ -> nameText kind == "job"
      _ -> False

type Members = Map ResourceId (ManagedResource, ByteString)

data Run = Run
  { store :: !InventoryStore
  , world :: !(IORef KubeWorld)
  , adversary :: !(IORef Adversary)
  }

newRun :: [(Boundary, Fault)] -> IO Run
newRun faults = do
  store' <- newMemoryStore
  _ <- initializeStore store' fixtureBinding "key-set" >>= expectRight
  Run store' <$> newKubeWorld Set.empty <*> newAdversary faults

-- | An Update request by one field manager, as the rotator or a person makes it.
write :: Run -> Text -> ObjectKey -> Value -> IO ()
write run manager key patch = modifyIORef' (world run) (#server %~ \server -> either (error . show) fst (patchUpdate manager key patch server))

dataOf :: Run -> ObjectKey -> IO (Map Text Value)
dataOf run key = do
  found <- Map.lookup key <$> live run (key ^. #kind)
  pure $ case (^. #content) <$> found of
    Just (Object root) | Just (Object fields) <- KM.lookup "data" root -> Map.fromList [(Key.toText k, v) | (k, v) <- KM.toList fields]
    _ -> Map.empty

changing :: ChangeProposal -> [OperationAction]
changing proposal' = [plannedAction operation | operation <- proposalOperations proposal', plannedAction operation /= VerifyResource]

b64 :: Text -> Text
b64 = b64encode

-- | Keep the scope's members and their edges to one another; drop the edges
-- to the foundation's namespace, which this world does not hold.
forWorld :: (ScopeDeclaration, Members) -> (ScopeDeclaration, Members)
forWorld (scope, native) = (rebuilt, Map.map (first keepEdges) native)
  where
    keepEdges resource = resource & #dependencies %~ filter ((`Map.member` native) . dependencyProducer)
    rebuilt =
      withScopeOverrides (scopeOverrides scope) . either (error . show) id $
        mkScopeDeclaration (scopeId scope) [ResourceBundle [Managed (keepEdges resource) | bundle <- scopeBundles scope, Managed resource <- declarations bundle] [] [] [] [] []]

plan :: Run -> Members -> Text -> KeySet -> IO (Members, ReviewBundle, TransactionResult)
plan run previous image' declared = (\(native, review, _, result) -> (native, review, result)) <$> reviewedPlan run previous image' declared

planned :: Run -> Members -> Text -> KeySet -> IO (Members, ChangeProposal, TransactionResult)
planned run previous image' declared = do
  (native, proposal', _, _, result) <- reviewedProposal run previous image' declared
  pure (native, proposal', result)

reviewedPlan :: Run -> Members -> Text -> KeySet -> IO (Members, ReviewBundle, AdapterRegistry, TransactionResult)
reviewedPlan run previous image' declared = (\(native, _, review, registry, result) -> (native, review, registry, result)) <$> reviewedProposal run previous image' declared

-- | Compile, prepare a fresh review that retires the members leaving the
-- scope, and apply it, as @keyset plan --save-plan@ then @inventory apply@ do.
reviewedProposal :: Run -> Members -> Text -> KeySet -> IO (Members, ChangeProposal, ReviewBundle, AdapterRegistry, TransactionResult)
reviewedProposal run previous image' declared = do
  (scope, members) <- forWorld <$> expectRight (compileKeySet image' declared)
  history <- loadInventoryHistory (store run) >>= expectRight
  let base = Map.map (\(revision, accepted) -> (revisionGeneration revision, accepted)) (historyAccepted history)
      candidate = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding base (historyReservations history))) (ReplaceScope scope NE.:| []))
      leaving = [resource ^. #identity | (_, accepted) <- Map.elems base, bundle <- scopeBundles accepted, Managed resource <- declarations bundle, Map.notMember (resource ^. #identity) members]
  planning <- loadInventoryPlanningHistory (store run) candidate >>= expectRight
  adapter <- worldKubernetesAdapter (fixtureBinding ^. #identity) (Map.union members previous) (world run) (adversary run)
  let registry' = ok (mkAdapterRegistry [adapter])
  observations <- observeWithRegistry registry' (requirementsByExecutor (observationRequirements candidate planning)) >>= expectRight
  before <- readStoreSnapshot (store run) >>= expectRight
  let decisions = ok (decideMemberRetirement leaving candidate planning observations)
      proposal' = ok (planChanges candidate decisions planning observations)
  review <- prepareReview registry' before proposal' >>= expectRight
  _ <- publishReview (store run) review >>= expectRight
  snapshot <- readStoreSnapshot (store run) >>= expectRight
  reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview snapshot review)
  reviewMembers <- kubernetesMembersForReview (store run) review (Map.restrictKeys previous (Set.fromList leaving)) >>= expectRight
  executor <- worldKubernetesAdapter (fixtureBinding ^. #identity) reviewMembers (world run) (adversary run)
  let executing = ok (mkAdapterRegistry [executor])
  result <- applyReviewed (store run) executing reviewed >>= expectRight
  pure (members, proposal', review, executing, result)

-- | Review and apply one inventory change against the accepted state, with
-- the lifecycle decisions it needs, as @keyset retire@ or @inventory collect@
-- then @inventory apply@ do. The members are bound from their accepted bytes.
changed :: Run -> Members -> NE.NonEmpty ScopeChange -> (CompositionCandidate -> InventoryHistory -> ObservationSet -> Either (NE.NonEmpty PlanError) LifecycleDecisions) -> IO TransactionResult
changed run accepted changes decide = do
  history <- loadInventoryHistory (store run) >>= expectRight
  let base = Map.map (\(revision, scope) -> (revisionGeneration revision, scope)) (historyAccepted history)
      candidate = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding base (historyReservations history))) changes)
  planning <- loadInventoryPlanningHistory (store run) candidate >>= expectRight
  adapter <- worldKubernetesAdapter (fixtureBinding ^. #identity) accepted (world run) (adversary run)
  let registry' = ok (mkAdapterRegistry [adapter])
  observations <- observeWithRegistry registry' (requirementsByExecutor (observationRequirements candidate planning)) >>= expectRight
  before <- readStoreSnapshot (store run) >>= expectRight
  let proposal' = ok (planChanges candidate (ok (decide candidate planning observations)) planning observations)
  review <- prepareReview registry' before proposal' >>= expectRight
  _ <- publishReview (store run) review >>= expectRight
  snapshot <- readStoreSnapshot (store run) >>= expectRight
  reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview snapshot review)
  reviewMembers <- kubernetesMembersForReview (store run) review accepted >>= expectRight
  executor <- worldKubernetesAdapter (fixtureBinding ^. #identity) reviewMembers (world run) (adversary run)
  applyReviewed (store run) (ok (mkAdapterRegistry [executor])) reviewed >>= expectRight

converged :: TransactionResult -> Assertion
converged = \case
  Converged _ -> pure ()
  other -> assertFailure ("the review did not converge: " <> show other)

live :: Run -> Text -> IO (Map ObjectKey Stored)
live run kind = Map.filterWithKey (\key _ -> key ^. #kind == kind) . (^. #server . #objects) <$> readIORef (world run)

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (assertFailure . show) pure

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
