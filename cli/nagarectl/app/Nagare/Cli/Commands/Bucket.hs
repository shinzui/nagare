-- | The @bucket@ commands (EP-283). Executable-private CLI boundary: each
-- builds reviewed bucket scopes against the accepted inventory and saves or
-- prints their review.
module Nagare.Cli.Commands.Bucket
  ( runBucket
  )
where

import Control.Monad (forM, forM_)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List (nub)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistryWithNative)
import Nagare.Cli.Options.Bucket
import Nagare.Cli.Runtime.Config (provisionGhcEnv)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target (activeTarget, resolvePlatformWorkspace)
import Nagare.Cluster.GcsJob (StoreBackend (..))
import Nagare.Dsl.Load (loadObjectBuckets, renderLoadError)
import Nagare.Dsl.ObjectBucket
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (namespaceText, serviceNameText)
import Nagare.Inventory.BucketCloudAccess (scopeRetiredGrants)
import Nagare.Inventory.BucketCloudScope (CloudBucketInput (..), CloudBucketTarget (..), cloudBucketGoogleNameKey, cloudBucketReviewEffects, compileStandaloneCloudBucket)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Command.Effects (planInventoryCandidateWithEffects)
import Nagare.Inventory.Components.LocalObjectStore (readLocalRegistryDigest, selectLocalMinioImages)
import Nagare.Inventory.DataService (acceptedFoundationNamespace)
import Nagare.Inventory.Kubernetes (kubernetesObjectIdentity)
import Nagare.Inventory.ObjectBucket
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Plan.Types (ReviewEffect)
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (ActiveTarget, contextNameText, storeBackendFor)
import System.Environment (lookupEnv)
import System.IO.Temp (withSystemTempDirectory)

runBucket :: Maybe String -> BucketCommand -> IO ()
runBucket mctx = \case
  BucketPlan o -> do
    provisionGhcEnv Nothing
    buckets <- loadObjectBuckets (o ^. #file) >>= either (dieT . renderLoadError) pure
    active <- activeTarget mctx
    snapshot <- Inventory.loadTargetSnapshot active
    planBuckets active snapshot (T.pack (o ^. #file)) buckets (o ^. #savePlan)
  BucketRetire name output -> do
    active <- activeTarget mctx
    snapshot <- Inventory.loadTargetSnapshot active
    (scope, declared) <- maybe (dieT ("no accepted bucket is named " <> T.pack name)) pure (lookup (T.pack name) (acceptedBuckets snapshot))
    when (null (declared ^. #grants)) (dieT ("bucket " <> T.pack name <> " is already retired: no workload has access"))
    case boundBy snapshot scope of
      [] -> pure ()
      consumers -> dieT ("bucket-still-bound: bucket " <> T.pack name <> " is bound by " <> T.intercalate ", " (map Resource.resourceIdText consumers) <> "; remove the binding and deploy first")
    planBuckets active snapshot "bucket retire" [retiredBucket declared] (Just output)
  BucketStatus selected -> do
    active <- activeTarget mctx
    snapshot <- Inventory.loadTargetSnapshotReadOnly active
    let accepted = [(scope, declared) | (name, (scope, declared)) <- acceptedBuckets snapshot, maybe True ((== name) . T.pack) selected]
    when (null accepted) (dieT (maybe "no accepted bucket" (\name -> "no accepted bucket is named " <> T.pack name) selected))
    forM_ accepted $ \(scope, declared) ->
      TIO.putStrLn
        ( T.intercalate
            "  "
            [ bucketNameText (declared ^. #name)
            , Map.findWithDefault "s3" bucketBackendKey (ResourceInventory.scopeOverrides scope)
            , Map.findWithDefault (storeBucketName (declared ^. #name)) cloudBucketGoogleNameKey (ResourceInventory.scopeOverrides scope)
            , case declared ^. #grants of
                [] -> "retired"
                grants -> T.unwords [serviceNameText (grant ^. #workload) <> "=" <> bucketAccessToken (grant ^. #access) | grant <- grants]
            ]
        )

-- | The accepted bucket scopes by bucket name.
acceptedBuckets :: ResourceInventory.ScopeSnapshot -> [(Text, (ResourceInventory.ScopeDeclaration, ObjectBucket))]
acceptedBuckets snapshot =
  [ (bucketNameText (declared ^. #name), (scope, declared))
  | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
  , Just declared <- [scopeBucket scope]
  ]

-- | Every bucket becomes its own scope, composed into one candidate. Members
-- that leave a scope are retired in the same review, which lists the access
-- each workload loses.
planBuckets :: ActiveTarget -> ResourceInventory.ScopeSnapshot -> Text -> [ObjectBucket] -> Maybe FilePath -> IO ()
planBuckets active snapshot source buckets output = do
  let profile = active ^. #profile
  accepted <- loadAcceptedNative active snapshot
  backend <- either dieT pure (storeBackendFor profile (profile ^. #backupBucket))
  case backend of
    GcsBackend _ _ -> planCloudBuckets active snapshot source buckets output accepted
    MinioBackend _ -> planLocalBuckets active snapshot source buckets output accepted

-- | EP-284: on a cloud context a bucket's scope holds each grant's Kubernetes account and
-- credential configuration; the bucket and its Google accounts are the cloud review's.
planCloudBuckets :: ActiveTarget -> ResourceInventory.ScopeSnapshot -> Text -> [ObjectBucket] -> Maybe FilePath -> Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString) -> IO ()
planCloudBuckets active snapshot source buckets output accepted = do
  let profile = active ^. #profile
  when (T.null (profile ^. #projectNumber)) (dieT "an app bucket on a cloud context needs the project's number: set NAGARE_PROJECT_NUMBER in the context")
  (cluster, _) <- either dieT pure (acceptedFoundationNamespace snapshot "nagare-system")
  compiled <- forM buckets $ \declared -> do
    namespaces <- fmap Map.fromList . forM (nub [namespaceText (grant ^. #namespace) | grant <- declared ^. #grants]) $ \ns ->
      (ns,) . snd <$> either dieT pure (acceptedFoundationNamespace snapshot ns)
    either (dieT . renderErrors) pure $
      compileStandaloneCloudBucket
        CloudBucketInput
          { bucket = declared
          , target = CloudBucketTarget (profile ^. #project) (contextNameText (active ^. #contextName)) (profile ^. #projectNumber)
          , cluster = cluster
          , namespaces = namespaces
          , source = Resource.SourceLocation source (bucketNameText (declared ^. #name))
          , kept = maybe [] (scopeRetiredGrants . fst) (lookup (bucketNameText (declared ^. #name)) (acceptedBuckets snapshot))
          }
  finishBucketPlan cloudBucketReviewEffects active snapshot compiled output accepted

planLocalBuckets :: ActiveTarget -> ResourceInventory.ScopeSnapshot -> Text -> [ObjectBucket] -> Maybe FilePath -> Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString) -> IO ()
planLocalBuckets active snapshot source buckets output accepted = do
  let profile = active ^. #profile
  backend <- either dieT pure (storeBackendFor profile (profile ^. #backupBucket))
  serverImage <- fmap T.pack <$> lookupEnv "NAGARE_LOCAL_MINIO_IMAGE"
  clientImage <- fmap T.pack <$> lookupEnv "NAGARE_LOCAL_MC_IMAGE"
  -- The backend is checked first, so a cloud context refuses before any image is resolved.
  _ <- either (dieT . renderError) pure (bucketStoreFor backend "")
  images <- selectLocalMinioImages readLocalRegistryDigest (profile ^. #targetPlatform) serverImage clientImage >>= either dieT pure
  store <- either (dieT . renderError) pure (bucketStoreFor backend (images ^. #client))
  (cluster, systemNamespace) <- either dieT pure (acceptedFoundationNamespace snapshot "nagare-system")
  storeReady <- either dieT pure $ do
    owner <- Resource.mkScopeId Resource.Platform "local-object-store"
    key <- Resource.mkLogicalKey "local-object-store"
    address <- Resource.kubernetesAddress cluster "batch/v1" "Job" (Just "nagare-system") "minio-make-bucket"
    kubernetesObjectIdentity owner key address
  compiled <- forM buckets $ \declared -> do
    owner <- either dieT pure (bucketScopeId declared)
    namespaces <- fmap Map.fromList . forM (nub [namespaceText (grant ^. #namespace) | grant <- declared ^. #grants]) $ \ns ->
      (ns,) . snd <$> either dieT pure (acceptedFoundationNamespace snapshot ns)
    either (dieT . renderErrors) pure $
      compileStandaloneBucket
        BucketInput
          { bucket = declared
          , store = store
          , cluster = cluster
          , systemNamespace = systemNamespace
          , namespaces = namespaces
          , storeReady = storeReady
          , previous = scopeNativeObjects owner accepted
          , source = Resource.SourceLocation source (bucketNameText (declared ^. #name))
          }
  finishBucketPlan bucketReviewEffects active snapshot compiled output accepted

-- | Compose the compiled bucket scopes and save or print their review; members that leave
-- a scope are retired in the same review, which lists the access each workload loses.
finishBucketPlan :: (ResourceInventory.ScopeSnapshot -> ResourceInventory.ScopeDeclaration -> [ReviewEffect]) -> ActiveTarget -> ResourceInventory.ScopeSnapshot -> [(ResourceInventory.ScopeDeclaration, Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString))] -> Maybe FilePath -> Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString) -> IO ()
finishBucketPlan reviewEffects active snapshot compiled output accepted = do
  changes <- maybe (dieT "no bucket to plan") pure (NE.nonEmpty (map (ResourceInventory.ReplaceScope . fst) compiled))
  candidate <- either (dieT . renderErrors) pure (ResourceInventory.composeInventory snapshot changes)
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  let native = Map.unions (map snd compiled)
      owners = Set.fromList (map (ResourceInventory.scopeId . fst) compiled)
      leaving = [resource ^. #identity | (resource, _) <- Map.elems accepted, Set.member (resource ^. #owner) owners, Map.notMember (resource ^. #identity) native]
      effects = concat [reviewEffects snapshot scope | (scope, _) <- compiled]
      registry = inventoryPlanRegistryWithNative active workspace native
  case output of
    Just directory -> planInventoryCandidateWithEffects registry active candidate leaving effects directory
    Nothing
      | null leaving -> withSystemTempDirectory "nagare-bucket-plan" $ \root -> do
          (bundle, _) <- Inventory.planInventoryCandidateQuiet registry active candidate (root <> "/review")
          case InventoryPlan.reviewOperations (InventoryPlan.reviewBundleDocument bundle) of
            [] -> TIO.putStrLn "no operations"
            operations -> mapM_ (TIO.putStrLn . InventoryPlan.reviewPublicSummary) operations
      | otherwise -> dieT "this plan removes members from a bucket scope; save it with --save-plan to review what is removed"

loadAcceptedNative :: ActiveTarget -> ResourceInventory.ScopeSnapshot -> IO (Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString))
loadAcceptedNative active snapshot = do
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  inventory <- either (dieT . T.pack . show) pure (ResourceInventory.composeSnapshot snapshot)
  fst <$> (InventoryStatus.loadAcceptedNative store history inventory >>= either dieT pure)

renderErrors :: NE.NonEmpty Resource.InventoryError -> Text
renderErrors = T.intercalate "; " . map renderError . NE.toList

renderError :: Resource.InventoryError -> Text
renderError err = err ^. #code <> ": " <> err ^. #message <> named (err ^. #resources)
  where
    named [] = ""
    named ids = " (" <> T.intercalate ", " (map Resource.resourceIdText ids) <> ")"
