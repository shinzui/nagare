-- | EP-283 M3: an app object bucket's scope through review, the journal and
-- the model world. The members are the compiled scope's own bytes and edges,
-- executed by the production adapter over the fake API server, which fills
-- the credential templates as the real runtime does.
module ObjectBucketWorldSpec (objectBucketWorldTests) where

import Control.Monad (forM_)
import Data.Aeson (Value (..))
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
import Nagare.Database.Secret (b64decode)
import Nagare.Dsl.ObjectBucket
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (AdapterRegistry, OperationAction (..), PlannedOperation (..), mkAdapterRegistry, observeWithRegistry)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (TransactionResult (..), applyReviewed, resumeTransaction)
import Nagare.Inventory.Lifecycle (decideMemberRetirement)
import Nagare.Inventory.ObjectBucket (bucketUser)
import Nagare.Inventory.Plan
import Nagare.Inventory.Status (kubernetesMembersForReview)
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Test.World.Adversary (Adversary, Boundary (..), Call (MutateCall), Fault (LostAcknowledgement), newAdversary)
import Nagare.Test.World.ApiServer (ObjectKey (..), Outcome (Failed), Stored)
import Nagare.Test.World.Kubernetes (KubeWorld, newKubeWorld, worldKubernetesAdapter)
import ObjectBucketSpec (apiGrant, compile, gatewayGrant, located, member, publications, values)
import Test.Tasty
import Test.Tasty.HUnit

objectBucketWorldTests :: TestTree
objectBucketWorldTests =
  testGroup
    "bucket scope in the model world"
    [ testCase "a bucket converges: three Jobs ran, and each workload holds its own user's key" $ do
        run <- newRun []
        (native, review, result) <- plan run Map.empty publications
        converged result
        Map.size <$> live run "job" >>= (@?= 3)
        api <- keys run apiUser "content-app"
        gateway <- keys run gatewayUser "content-gateway"
        assertBool "the two workloads hold different keys" (api /= gateway)
        -- No reviewed byte holds either key.
        let reviewed = BS.concat (encodeReviewDocument (reviewBundleDocument review) : Map.elems (reviewBundleScopes review) <> Map.elems (reviewBundleNative review) <> map snd (Map.elems native))
        forM_ [api, gateway] $ \secret -> assertBool "a key is in the review" (not (TE.encodeUtf8 secret `BS.isInfixOf` reviewed))
    , testCase "a second identical plan changes nothing and keeps every key" $ do
        run <- newRun []
        (native, _, result) <- plan run Map.empty publications
        converged result
        before <- (,) <$> keys run apiUser "content-app" <*> keys run gatewayUser "content-gateway"
        secrets <- live run "secret"
        (_, proposal', again) <- planned run native publications
        converged again
        [plannedAction operation | operation <- proposalOperations proposal', plannedAction operation /= VerifyResource] @?= []
        after <- (,) <$> keys run apiUser "content-app" <*> keys run gatewayUser "content-gateway"
        after @?= before
        fmap (^. #uid) <$> live run "secret" >>= (@?= fmap (^. #uid) secrets)
    , testCase "a grant Job that fails stops the review with the bucket made and its user's Secrets in place" $ do
        run <- newRun []
        (_, native) <- expectRight (compile [] publications)
        let failing = [bytes | (resource, bytes) <- Map.elems native, located resource == located (member ("grant-" <> T.drop 14 gatewayUser) native)]
        modifyIORef' (world run) (#server . #outcomes %~ Map.union (Map.fromList [(digestText (contentDigest bytes), Failed) | bytes <- failing]))
        (_, _, result) <- plan run Map.empty publications
        case result of
          Converged _ -> assertFailure "a failed grant Job converged"
          _ -> pure ()
        jobs <- Map.keys <$> live run "job"
        assertBool "the bucket Job ran" (any (("nagare-bucket-publications-make-" `T.isPrefixOf`) . (^. #name)) jobs)
        secrets <- Map.keys <$> live run "secret"
        assertBool "the user's Secret, which the Job reads, was created first" (ObjectKey "" "secret" (Just "nagare-system") gatewayUser `elem` secrets)
    , testCase "a lost acknowledgement at any write resumes to the same keys, written once" $
        forM_ [1 .. 7] $ \ordinal -> do
          run <- newRun [(Boundary MutateCall ordinal, LostAcknowledgement)]
          (_, _, registry, result) <- reviewedPlan run Map.empty publications
          settled <- case result of
            Converged _ -> pure result
            StoppedAmbiguous transaction _ _ -> resumeTransaction (store run) registry transaction >>= expectRight
            StoppedFailed transaction _ _ -> resumeTransaction (store run) registry transaction >>= expectRight
            other -> assertFailure ("write " <> show ordinal <> ": " <> show other) >> pure other
          case settled of
            Converged _ -> pure ()
            other -> assertFailure ("write " <> show ordinal <> " did not resume: " <> show other)
          Map.size <$> live run "job" >>= (@?= 3)
          Map.size <$> live run "secret" >>= (@?= 4)
          _ <- keys run apiUser "content-app"
          _ <- keys run gatewayUser "content-gateway"
          pure ()
    , testCase "a dropped grant is retired in the review that adds its revoke Job, and the next plan changes nothing" $ do
        run <- newRun []
        (native, _, result) <- plan run Map.empty publications
        converged result
        let onlyApi = publications & #grants .~ [apiGrant]
        (dropped, _, review, _, result') <- reviewedProposal run native onlyApi
        converged result'
        -- The grant Job and both Secrets of the dropped workload are retained, each by its own decision.
        Map.size (reviewRetentions (reviewBundleDocument review)) + Map.size (reviewAbsences (reviewBundleDocument review)) @?= 3
        jobs <- map (^. #name) . Map.keys <$> live run "job"
        assertBool "the revoke Job ran" (any ((gatewayUser <> "-revoke-") `T.isPrefixOf`) jobs)
        -- Retirement deletes nothing: the dropped workload's objects stay until collected.
        Map.size <$> live run "secret" >>= (@?= 4)
        (_, again, result'') <- planned run dropped onlyApi
        converged result''
        [plannedAction operation | operation <- proposalOperations again, plannedAction operation /= VerifyResource] @?= []
    , testCase "an added grant creates only that workload's members" $ do
        run <- newRun []
        (native, _, result) <- plan run Map.empty (publications & #grants .~ [apiGrant])
        converged result
        (_, proposal', result') <- planned run native publications
        converged result'
        length [() | operation <- proposalOperations proposal', plannedAction operation == CreateResource] @?= 3
        _ <- keys run gatewayUser "content-gateway"
        Map.size <$> live run "job" >>= (@?= 3)
    ]
  where
    apiUser = bucketUser (publications ^. #name) (apiGrant ^. #namespace) (apiGrant ^. #workload)
    gatewayUser = bucketUser (publications ^. #name) (gatewayGrant ^. #namespace) (gatewayGrant ^. #workload)

type Members = Map ResourceId (ManagedResource, ByteString)

data Run = Run
  { store :: !InventoryStore
  , world :: !(IORef KubeWorld)
  , adversary :: !(IORef Adversary)
  }

newRun :: [(Boundary, Fault)] -> IO Run
newRun faults = do
  store' <- newMemoryStore
  _ <- initializeStore store' fixtureBinding "object-bucket" >>= expectRight
  Run store' <$> newKubeWorld Set.empty <*> newAdversary faults

-- | Keep the scope's members and their edges to one another; drop the edges
-- to the foundation's and the object store's objects, which this world does
-- not hold.
forWorld :: (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString)) -> (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
forWorld (scope, native) = (rebuilt, Map.map (first keepEdges) native)
  where
    keepEdges resource = resource & #dependencies %~ filter ((`Map.member` native) . dependencyProducer)
    rebuilt =
      withScopeOverrides (scopeOverrides scope) . either (error . show) id $
        mkScopeDeclaration (scopeId scope) [ResourceBundle [Managed (keepEdges resource) | bundle <- scopeBundles scope, Managed resource <- declarations bundle] [] [] [] [] []]

plan :: Run -> Members -> ObjectBucket -> IO (Members, ReviewBundle, TransactionResult)
plan run previous declared = (\(native, review, _, result) -> (native, review, result)) <$> reviewedPlan run previous declared

planned :: Run -> Members -> ObjectBucket -> IO (Members, ChangeProposal, TransactionResult)
planned run previous declared = do
  (native, proposal', _, _, result) <- reviewedProposal run previous declared
  pure (native, proposal', result)

reviewedPlan :: Run -> Members -> ObjectBucket -> IO (Members, ReviewBundle, AdapterRegistry, TransactionResult)
reviewedPlan run previous declared = (\(native, _, review, registry, result) -> (native, review, registry, result)) <$> reviewedProposal run previous declared

-- | Compile against the accepted native objects, prepare a fresh review that
-- retires the members leaving the scope, and apply it, as @bucket plan
-- --save-plan@ then @inventory apply@ do.
reviewedProposal :: Run -> Members -> ObjectBucket -> IO (Members, ChangeProposal, ReviewBundle, AdapterRegistry, TransactionResult)
reviewedProposal run previous declared = do
  (scope, members) <- forWorld <$> expectRight (compile (values previous) declared)
  history <- loadInventoryHistory (store run) >>= expectRight
  let base = Map.map (\(revision, accepted) -> (revisionGeneration revision, accepted)) (historyAccepted history)
      candidate = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding base (historyReservations history))) (ReplaceScope scope NE.:| []))
      leaving = [resource ^. #identity | (_, accepted) <- Map.elems base, bundle <- scopeBundles accepted, Managed resource <- declarations bundle, Map.notMember (resource ^. #identity) members]
  planning <- loadInventoryPlanningHistory (store run) candidate >>= expectRight
  -- The members leaving the scope are observed from their accepted bytes.
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
  -- As inventory apply does, bind the review's own members and the accepted bytes of those it retires.
  reviewMembers <- kubernetesMembersForReview (store run) review (Map.restrictKeys previous (Set.fromList leaving)) >>= expectRight
  executor <- worldKubernetesAdapter (fixtureBinding ^. #identity) reviewMembers (world run) (adversary run)
  let executing = ok (mkAdapterRegistry [executor])
  result <- applyReviewed (store run) executing reviewed >>= expectRight
  pure (members, proposal', review, executing, result)

converged :: TransactionResult -> Assertion
converged = \case
  Converged _ -> pure ()
  other -> assertFailure ("the review did not converge: " <> show other)

-- | The live objects of one kind.
live :: Run -> Text -> IO (Map ObjectKey Stored)
live run kind = Map.filterWithKey (\key _ -> key ^. #kind == kind) . (^. #server . #objects) <$> readIORef (world run)

-- | The key a workload's Secret holds, which must be its store user's own:
-- the same access key (the user name) and the same secret key.
keys :: Run -> Text -> Text -> IO Text
keys run user workload' = do
  secrets <- live run "secret"
  let dataOf key = case (^. #content) <$> Map.lookup key secrets of
        Just (Object root) | Just (Object fields) <- KM.lookup "data" root -> Map.fromList [(k, decoded) | (k, String encoded) <- KM.toList fields, Right decoded <- [b64decode encoded]]
        _ -> Map.empty
      source = dataOf (ObjectKey "" "secret" (Just "nagare-system") user)
      copy = dataOf (ObjectKey "" "secret" (Just "personal") ("nagare-bucket-publications-" <> workload'))
  Map.lookup "AWS_ACCESS_KEY_ID" source @?= Just user
  assertBool ("the user " <> T.unpack user <> " has a key") (maybe False ((== 64) . T.length) (Map.lookup "AWS_SECRET_ACCESS_KEY" source))
  copy @?= source
  maybe (assertFailure "no secret key" >> pure "") pure (Map.lookup "AWS_SECRET_ACCESS_KEY" source)

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (assertFailure . show) pure

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
