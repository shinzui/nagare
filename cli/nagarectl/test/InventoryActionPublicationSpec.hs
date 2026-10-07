-- | Every operation action publishes to the store and loads back intact.
-- EP-181 found that a review with a new action could not be published:
-- observation-member extraction decoded every Kubernetes envelope as a
-- mutation. The action list here is checked against the type itself, so a
-- new action cannot ship without a publication case.
module InventoryActionPublicationSpec (inventoryActionPublicationTests) where

import Control.Monad (forM_)
import Data.Aeson (Value, object, (.=))
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.IORef (newIORef)
import Data.Kind (Type)
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Proxy (Proxy (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics
import InventoryPostgresRenameSpec (plannedRenameThrough, recordOldIncarnations)
import InventoryStuckPodSpec (acceptedStore, pgBound, planCluster, planId, planOwner, planUid, reviewedPod)
import InventoryTransactionSpec (fixtureBinding)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes (KubernetesAdapterOps (..), KubernetesState (..), kubernetesObserve, mkKubernetesAdapterWithObservations, unstamped)
import Nagare.Inventory.Adapters.KubernetesStuckPod (KubernetesPodOps (..), noPodOps)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Canonical (canonicalValue)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
import Nagare.Resource.Types
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

inventoryActionPublicationTests :: TestTree
inventoryActionPublicationTests =
  testGroup
    "action publication totality"
    [ testCase "every operation action has a publication case" $
        sort (nub (map constructorName publishedActions)) @?= sort (constructorNames (Proxy :: Proxy (Rep OperationAction)))
    , testCase "a review with each Kubernetes action publishes and loads back intact" $
        forM_ publishedActions $ \action -> case kubernetesFixture action of
          Nothing -> pure ()
          Just (resource, state) -> roundTrip action resource state
    , testCase "a review with every migration stage publishes and loads back intact" $
        withSystemTempDirectory "action-publication" $ \root -> do
          probe <- newIORef Nothing
          (store, _, reviewed, _) <- plannedRenameThrough recordOldIncarnations id probe root
          let document = reviewedDocument reviewed
              stages = [constructorName stage | entry <- reviewOperations document, MigrateResource stage <- [plannedAction (reviewPlannedOperation entry)]]
          sort (nub stages) @?= sort (constructorNames (Proxy :: Proxy (Rep MigrationStage)))
          loaded <- loadPublishedReview store (contentDigest (encodeReviewDocument document)) >>= expectRight
          reviewBundleDocument loaded @?= document
    ]

-- | One action of each constructor; every migration stage is published by
-- the rename review.
publishedActions :: [OperationAction]
publishedActions =
  [ CreateResource
  , UpdateResource
  , VerifyResource
  , AdoptResource
  , RetireResource
  , ReplaceStuckPod
  , RunDeclaredOperation
  , OpenMaintenanceSession
  , RestoreLiveDatabase
  , MigrateResource PrepareDestination
  ]

-- | The member and observed state from which the Kubernetes adapter prepares
-- each action. Exhaustive: a new action must say how it is published.
kubernetesFixture :: OperationAction -> Maybe (ResourceId, KubernetesState)
kubernetesFixture = \case
  CreateResource -> Just (configId, KubernetesAbsent (contentDigest "absent"))
  UpdateResource -> Just (planId, KubernetesPresent planUid "1" (Just planId) (contentDigest "before"))
  VerifyResource -> Just (planId, owned planId pgDigest)
  AdoptResource -> Just (configId, KubernetesPresent planUid "1" Nothing configDigest)
  RetireResource -> Just (configId, owned configId configDigest)
  ReplaceStuckPod -> Just (planId, KubernetesNotReady planUid "1" (Just planId) pgDigest)
  RunDeclaredOperation -> Just (jobId, KubernetesAbsent (contentDigest "absent"))
  OpenMaintenanceSession -> Just (planId, owned planId pgDigest)
  RestoreLiveDatabase -> Just (planId, owned planId pgDigest)
  -- The migration adapter prepares a stage's rename bundle; the rename
  -- review covers every stage.
  MigrateResource _ -> Nothing
  where
    owned resource = KubernetesPresent planUid "1" (Just resource)

-- | Prepare @action@ on @resource@ with the real adapter, put it in a
-- published review in place of the base review's operations, and load it
-- back.
roundTrip :: OperationAction -> ResourceId -> KubernetesState -> Assertion
roundTrip action resource state = do
  let (declared, _) = pgBound
      ops = KubernetesAdapterOps fixtureContext (unstamped (\_ -> pure state)) (\_ -> pure AdapterEffectCompleted)
      pods = noPodOps {readStuckPod = \_ -> pure (Right (Just (reviewedPod & #statefulSetUid .~ planUid)))}
      adapter = mkKubernetesAdapterWithObservations specs ops pods (traverse (kubernetesObserve ops)) noReceipt noScratch Nothing
      registry = ok (withAdapterFence (ok (mkAdapterRegistry [adapter])) KubernetesExecutor stubFence)
  (store, candidate, history) <- acceptedStore declared declared
  snapshot <- readStoreSnapshot store >>= expectRight
  let planned = ok (planChanges candidate noLifecycleDecisions history (ok (observationSet [(planId, ObservedDrifted planUid (contentDigest "before"))])))
  base <- case proposalOperations planned of
    [single] -> pure single
    other -> assertFailure ("the base plan has " <> show (length other) <> " operations") >> pure (error "unreachable")
  let operation = base {plannedAction = action, plannedResources = resource :| []}
  bundle <- prepareReview registry snapshot planned {proposalOperations = [operation]} >>= either (\err -> assertFailure (show action <> " did not prepare: " <> show err) >> pure (error "unreachable")) pure
  published <- publishReview store bundle
  either (\err -> assertFailure (show action <> " did not publish: " <> show err)) (const (pure ())) published
  loaded <- loadPublishedReview store (contentDigest (encodeReviewDocument (reviewBundleDocument bundle))) >>= either (\err -> assertFailure (show action <> " did not load: " <> show err) >> pure (error "unreachable")) pure
  map (plannedAction . reviewPlannedOperation) (reviewOperations (reviewBundleDocument loaded)) @?= [action]
  (reviewBundleDocument loaded, reviewBundleNative loaded) @?= (reviewBundleDocument bundle, reviewBundleNative bundle)

-- | A reviewed data fence for the database data operations, which prepare
-- only under one. It is never executed here.
stubFence :: AdapterFence
stubFence =
  AdapterFence
    { fenceCapability = "publication-fence-v1"
    , fenceForOperation = \operation _ ->
        pure . Right $
          if plannedAction operation `elem` [OpenMaintenanceSession, RestoreLiveDatabase]
            then Just (DataFenceRecord fixtureBinding "session" Nothing Map.empty (Map.singleton planId planUid) (Set.singleton planId) Set.empty "recovery" (contentDigest "recovery") Map.empty Nothing FenceAcquiring "2026-10-06T00:00:00Z")
            else Nothing
    , fenceFromReviewedRecord = \_ _ _ -> Left "the publication test never executes a fence"
    , fenceResolveUncertainEffect = Nothing
    , fenceRestoreRecoveryBackup = Nothing
    , fenceVerifyRecoveryBackup = Nothing
    }

specs :: Map.Map ResourceId (ManagedResource, ByteString)
specs = Map.fromList [(planId, pgBound), (configId, configBound), (jobId, jobBound)]

configId, jobId :: ResourceId
configId = mintResourceId planOwner (ok (mkLogicalKey "settings")) (ok (mkName "configmap"))
jobId = mintResourceId planOwner (ok (mkLogicalKey "migrate")) (ok (mkName "job"))

configBound, jobBound :: (ManagedResource, ByteString)
configBound = bound configId DeleteWhenUnreferenced (object ["apiVersion" .= ("v1" :: Text), "kind" .= ("ConfigMap" :: Text), "metadata" .= metadata "settings", "data" .= object ["mode" .= ("on" :: Text)]])
jobBound =
  bound
    jobId
    Retain
    ( object
        [ "apiVersion" .= ("batch/v1" :: Text)
        , "kind" .= ("Job" :: Text)
        , "metadata" .= metadata "migrate"
        , "spec" .= object ["template" .= object ["spec" .= object ["restartPolicy" .= ("Never" :: Text), "containers" .= [object ["name" .= ("migrate" :: Text), "image" .= ("registry.example/migrate:1" :: Text)]]]]]
        ]
    )

metadata :: Text -> Value
metadata name' = object ["name" .= name', "namespace" .= ("personal" :: Text)]

bound :: ResourceId -> LifecyclePolicy -> Value -> (ManagedResource, ByteString)
bound resource lifecycle' value = ok (bindKubernetesObject (KubernetesInput resource planOwner planCluster value (contentDigest (ok (canonicalValue value))) lifecycle' Stateless Private (SourceLocation "test" (resourceIdText resource))))

pgDigest, configDigest :: ContentDigest
pgDigest = contentDigest (snd pgBound)
configDigest = contentDigest (snd configBound)

fixtureContext :: ContextId
fixtureContext = fixtureBinding ^. #identity

noReceipt :: ResourceId -> PhysicalIdentity -> IO (Either Text ByteString)
noReceipt _ _ = pure (Left "no receipt")

noScratch :: ResourceId -> PhysicalIdentity -> IO (Either Text Bool)
noScratch _ _ = pure (Right False)

-- | The constructor names of a type, from its generic representation.
class ConstructorNames (f :: Type -> Type) where
  constructorNames :: Proxy f -> [String]

instance (ConstructorNames f) => ConstructorNames (D1 meta f) where
  constructorNames _ = constructorNames (Proxy :: Proxy f)

instance (ConstructorNames f, ConstructorNames g) => ConstructorNames (f :+: g) where
  constructorNames _ = constructorNames (Proxy :: Proxy f) <> constructorNames (Proxy :: Proxy g)

instance (Constructor meta) => ConstructorNames (C1 meta f) where
  constructorNames _ = [conName (undefined :: C1 meta f ())]

-- | A value's constructor name.
constructorName :: (Show a) => a -> String
constructorName = takeWhile (/= ' ') . show

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> error "unreachable") pure
