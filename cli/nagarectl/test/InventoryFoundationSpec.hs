module InventoryFoundationSpec (inventoryFoundationTests) where

import Control.Monad (forM_)
import Data.Generics.Labels ()
import Data.Aeson (eitherDecodeStrict, object, (.=))
import Data.ByteString.Char8 qualified as BC
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Bootstrap (bootstrapCandidateScopeVectorDigest, bootstrapMarkerValue, bootstrapPreservedScopeVectorDigest, bootstrapScopeVectorDigest, compileBootstrapStamp, verifyBootstrapStampPayload)
import Nagare.Inventory.Adapter (Adapter (..), AdapterExecution (AdapterEffectCompleted), OperationAction (CreateResource), PlannedOperation (..), PreparedNative (..), RecoveryDecision (RecoveryProvedComplete))
import Nagare.Inventory.Adapters.Foundation (FoundationAdapterOps (..), FoundationNativePlan (..), FoundationObservation (..), FoundationTarget (..), foundationTargetDigest, mkFoundationAdapter)
import Nagare.Inventory.Adapters.FoundationRuntime (GcloudRunner (..), mkFoundationRuntimeOps)
import Nagare.Inventory.Components.Foundation
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Foundation (FoundationDeclarationBundle (..), FoundationResource (..), compileFoundationScope, foundationTargetsFromDeclarations, validateFoundationMember)
import Nagare.Inventory.Journal (mkOperationId)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.KubernetesSources (validateSuppliedKubernetesMembers)
import Nagare.Inventory.Store (ScopeRevision (..))
import Nagare.Platform.Status (ReleaseIdentity (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes
import Nagare.Resource.Policy (RecoveryClass (Idempotent), LifecyclePolicy (Protect, Retain), DataPolicy (Stateless), Sensitivity (Public))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue, encodeCanonicalScope)
import Test.Tasty
import Test.Tasty.HUnit
import System.FilePath ((</>))

inventoryFoundationTests :: TestTree
inventoryFoundationTests = testGroup "cluster foundation inventory"
  [ testCase "backend member applies only to the Pulumi bucket" $ do
      validateFoundationMember (Just "serviceAccount:deployer@acme-prod.iam.gserviceaccount.com") @?= Right ()
      assertBool "multiline IAM member was accepted" (either (const True) (const False)
        (validateFoundationMember (Just "serviceAccount:one\nother")))
      let owner = ok (mkScopeId Platform "cloud-foundation")
          project = known "acme-prod"
          location = known "us-west1"
          backend = known "acme-prod-pulumi"
          journal = known "acme-prod-inventory"
          member = "serviceAccount:deployer@acme-prod.iam.gserviceaccount.com"
          resource key bucket target = FoundationResource (ok (mkLogicalKey key)) bucket
            (GlobalBucket bucket) (foundationTargetDigest target)
            Protect Stateless Public [] (SourceLocation "target" key)
          backendResource = resource "backend" backend
            (FoundationBucket project backend location (Just member))
          journalResource = resource "journal" journal
            (FoundationBucket project journal location Nothing)
          stack = known "fresh"
          stackAddress = CloudStack project stack
          stackTarget = FoundationStack project stack "file:///tmp/state" "/tmp/program"
            "/tmp/home" Nothing [("nagare:manageProjectApis", "false")]
          stackResource = FoundationResource (ok (mkLogicalKey "pulumi-stack")) stack
            stackAddress (foundationTargetDigest stackTarget) Protect Stateless Public []
            (SourceLocation "target" "pulumi-stack")
          scope = ok (compileFoundationScope (FoundationDeclarationBundle 1 owner project
            (backendResource :| [journalResource, stackResource])))
          declarations = concatMap (^. #declarations) (scopeBundles scope)
      targets <- expectRight (foundationTargetsFromDeclarations project location
        (Just backend) (Just member) (Just (stackAddress, stackTarget)) declarations)
      Map.lookup (mintResourceId owner (foundationLogicalKey backendResource)
        (foundationRole backendResource)) targets
        @?= Just (FoundationBucket project backend location (Just member))
      Map.lookup (mintResourceId owner (foundationLogicalKey journalResource)
        (foundationRole journalResource)) targets
        @?= Just (FoundationBucket project journal location Nothing)
      Map.lookup (mintResourceId owner (foundationLogicalKey stackResource)
        (foundationRole stackResource)) targets @?= Just stackTarget
      assertBool "changed member was accepted" (either (const True) (const False)
        (foundationTargetsFromDeclarations project location (Just backend)
          (Just "serviceAccount:other@acme-prod.iam.gserviceaccount.com")
          (Just (stackAddress, stackTarget)) declarations))
      assertBool "changed stack config was accepted" (either (const True) (const False)
        (foundationTargetsFromDeclarations project location (Just backend) (Just member)
          (Just (stackAddress, FoundationStack project stack "file:///tmp/state"
            "/tmp/program" "/tmp/home" Nothing [("nagare:manageProjectApis", "true")]))
          declarations))
  , testCase "cloud foundation composes before a cluster exists and preserves unrelated scopes" $ do
      let owner = ok (mkScopeId Platform "cloud-foundation")
          unrelatedOwners =
            [ ok (mkScopeId Application "unrelated-app")
            , ok (mkScopeId Standalone "unrelated-job")
            , ok (mkScopeId Publication "unrelated-release")
            ]
          project = known "acme-prod"
          api = FoundationResource (ok (mkLogicalKey "storage-api")) (known "service")
            (CloudService project (known "storage.googleapis.com")) (contentDigest "storage-api")
            Retain Stateless Public [] (SourceLocation "target" "storage-api")
          apiId = mintResourceId owner (foundationLogicalKey api) (foundationRole api)
          bucket = FoundationResource (ok (mkLogicalKey "state")) (known "bucket")
            (GlobalBucket (known "acme-prod-nagare-state")) (contentDigest "state-bucket")
            Protect Stateless Public [OrderedAfter apiId] (SourceLocation "target" "state-bucket")
          bundle = FoundationDeclarationBundle 1 owner project (api :| [bucket])
          binding = ContextBinding (ok (mkContextId "fixture")) project
          unrelated = Map.fromList
            [(scopeOwner, (ok (mkScopeGeneration generation),
                ok (mkScopeDeclaration scopeOwner [ResourceBundle [] [] [] [] [] []])))
            | (scopeOwner, generation) <- zip unrelatedOwners [4, 7, 11]]
          snapshot = ok (mkScopeSnapshot binding
            unrelated Map.empty)
      foundationScope <- expectRight (compileFoundationScope bundle)
      let candidate = ok (composeInventory snapshot (ReplaceScope foundationScope :| []))
          members = [resource | Managed resource <- inventoryDeclarations (candidateInventory candidate)]
      length members @?= 2
      all ((== CloudFoundationExecutor) . (^. #executor)) members @?= True
      forM_ (Map.toList unrelated) $ \(scopeOwner, (generation, scope)) -> do
        candidateGenerations candidate Map.! scopeOwner @?= generation
        inventoryScopes (candidateInventory candidate) Map.! scopeOwner @?= scope
      let wrongProject = bundle {foundationResources = api
            {foundationAddress = CloudService (known "other-project") (known "storage.googleapis.com")} :| [bucket]}
      assertBool "foreign-project API was accepted" (either (const True) (const False)
        (compileFoundationScope wrongProject))
  , testCase "foundation review retains exact gcloud intent and recovers a proved write" $ do
      let owner = ok (mkScopeId Platform "cloud-foundation")
          resource = mintResourceId owner (ok (mkLogicalKey "state")) (known "bucket")
          target = FoundationBucket (known "acme-prod") (known "acme-prod-nagare-state")
            (known "us-west1") Nothing
          operation = PlannedOperation (ok (mkOperationId "op-state-create"))
            CreateResource CloudFoundationExecutor (resource :| []) (contentDigest "review-input") []
            Idempotent
          physical = ok (mkPhysicalIdentity "gs://acme-prod-nagare-state")
      state <- newIORef (FoundationAbsent (contentDigest "absence"))
      calls <- newIORef (0 :: Int)
      let ops = FoundationAdapterOps
            { foundationInspect = \_ -> readIORef state
            , foundationMutate = \_ -> do
                writeIORef calls 1
                writeIORef state (FoundationPresent physical (foundationTargetDigest target))
                pure AdapterEffectCompleted
            }
          adapter = mkFoundationAdapter (Map.singleton resource target) ops
      prepared <- adapterPrepare adapter operation >>= expectRight
      plan <- expectRight (eitherDecodeStrict (preparedNativeBytes prepared))
      foundationPlanCommands (plan :: FoundationNativePlan) @?=
        [["gcloud", "storage", "buckets", "create", "gs://acme-prod-nagare-state",
          "--project=acme-prod", "--location=us-west1", "--uniform-bucket-level-access",
          "--public-access-prevention"],
         ["gcloud", "storage", "buckets", "update", "gs://acme-prod-nagare-state",
          "--versioning", "--uniform-bucket-level-access", "--public-access-prevention"]]
      adapterPreflight adapter operation prepared >>= (@?= Right ())
      adapterExecute adapter operation prepared >>= (@?= AdapterEffectCompleted)
      readIORef calls >>= (@?= 1)
      recovery <- adapterRecover adapter operation prepared
      case recovery of
        RecoveryProvedComplete _ -> pure ()
        other -> assertFailure ("unproved foundation write: " <> show other)
      adapterExecute adapter operation prepared >>= (@?= AdapterEffectCompleted)
      readIORef calls >>= (@?= 1)
      writeIORef state (FoundationForeign physical "wrong project")
      assertBool "foreign bucket passed preflight" . either (const True) (const False)
        =<< adapterPreflight adapter operation prepared
  , testCase "cloud bucket observation distinguishes absence, foreign ownership, and failure" $ do
      let target = FoundationBucket (known "acme-prod") (known "acme-prod-nagare-state")
            (known "us-west1") Nothing
          projectNumber = Right "12345"
          bucketList = Right "[]"
          runner listResult describedResult = GcloudRunner
            { gcloudCapture = \args -> pure $ case args of
                ["projects", "describe", _, _] -> projectNumber
                ["storage", "buckets", "list", _, _] -> listResult
                ["storage", "buckets", "describe", _, "--raw", "--format=json"] -> describedResult
                _ -> Left "unexpected gcloud observation"
            , gcloudEffect = \_ -> pure (Left "mutation was not expected")
            , pulumiCapture = \_ _ -> pure (Left "Pulumi was not expected")
            , pulumiEffect = \_ _ -> pure (Left "Pulumi was not expected")
            }
          inspect selected = foundationInspect (mkFoundationRuntimeOps selected) target
          listed = Right "[{\"name\":\"acme-prod-nagare-state\"}]"
          bucket owner = Right (BC.pack ("{\"projectNumber\":\"" <> owner
            <> "\",\"location\":\"US-WEST1\",\"versioning\":{\"enabled\":true},"
            <> "\"iamConfiguration\":{\"uniformBucketLevelAccess\":{\"enabled\":true},"
            <> "\"publicAccessPrevention\":\"enforced\"}}"))
      inspect (runner bucketList (Left "no describe")) >>= \case
        FoundationAbsent _ -> pure ()
        other -> assertFailure ("confirmed absence was lost: " <> show other)
      inspect (runner listed (bucket "99999")) >>= \case
        FoundationForeign _ _ -> pure ()
        other -> assertFailure ("foreign bucket was accepted: " <> show other)
      inspect (runner (Left "permission denied") (Left "no describe")) >>= \case
        FoundationUnavailable _ -> pure ()
        other -> assertFailure ("unknown observation became absence: " <> show other)
      inspect (runner listed (bucket "12345")) >>= \case
        FoundationPresent _ digest -> digest @?= foundationTargetDigest target
        other -> assertFailure ("matching bucket did not converge: " <> show other)
      let unversioned = Right "{\"projectNumber\":\"12345\",\"location\":\"US-WEST1\",\"iamConfiguration\":{\"uniformBucketLevelAccess\":{\"enabled\":true},\"publicAccessPrevention\":\"enforced\"}}"
      inspect (runner listed unversioned) >>= \case
        FoundationPresent _ digest -> assertBool "unversioned bucket was treated as converged"
          (digest /= foundationTargetDigest target)
        other -> assertFailure ("unversioned bucket could not be reviewed for update: " <> show other)
  , testCase "platform namespaces and personal Job quota form one bound bundle" $ do
      (bundle, native) <- compileFoundation foundationInput >>= expectRight
      length (declarations bundle) @?= 3
      Map.size native @?= 3
      let resources = [member | Managed member <- declarations bundle]
      _ <- expectRight (validateSuppliedKubernetesMembers resources native)
      let quota = [member | member <- resources, member ^. #address == Kubernetes fixtureCluster "" (known "resourcequota") (Just (known "personal")) (known "nagare-terminating-jobs")]
      length quota @?= 1
      case [member | member <- resources, member ^. #address == Kubernetes fixtureCluster "" (known "namespace") Nothing (known "personal")] of
        [personal] -> do
          let changed = object ["apiVersion" .= ("v1" :: Text), "kind" .= ("Namespace" :: Text),
                "metadata" .= object ["name" .= ("personal" :: Text), "labels" .= object ["nagare.dev/app-namespace" .= ("false" :: Text)]]]
              changedBytes = ok (canonicalValue changed)
              changedInput = KubernetesInput (personal ^. #identity) fixtureOwner fixtureCluster changed
                (contentDigest changedBytes) (personal ^. #lifecycle) (personal ^. #dataPolicy)
                (personal ^. #sensitivity) (personal ^. #source)
          (changedDeclaration, _) <- expectRight (bindKubernetesObject changedInput)
          assertBool "namespace label change did not change desired specification"
            (changedDeclaration ^. #spec /= personal ^. #spec)
        _ -> assertFailure "personal Namespace declaration missing"
      let binding = ContextBinding (ok (mkContextId "fixture")) (known "project")
          scope = ok (mkScopeDeclaration fixtureOwner [bundle])
          snapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
      assertBool "foundation scope failed claim validation" (either (const False) (const True)
        (composeInventory snapshot (ReplaceScope scope :| [])))
  , testCase "missing quota source refuses before any native mutation" $ do
      result <- compileFoundation (foundationInput {foundationQuotaPath = "../../cluster/bootstrap/missing-quota.yaml"})
      assertBool "missing quota was accepted" (either (const True) (const False) result)
  , testCase "reviewed bootstrap marker is bound to the selected payload identity" $ do
      let identity = ReleaseIdentity (Just "0.4.0") (Just "source-a") (Just 2)
          vectorDigest = contentDigest "accepted-scope-vector"
          bytes = ok (canonicalValue (bootstrapMarkerValue "payload-a" vectorDigest identity "2026-09-26T00:00:00Z"))
      verifyBootstrapStampPayload "payload-a" vectorDigest identity bytes @?= Right ()
      assertBool "changed source revision was accepted"
        (either (const True) (const False)
          (verifyBootstrapStampPayload "payload-a" vectorDigest (identity {revision = Just "source-b"}) bytes))
      assertBool "changed payload ID was accepted"
        (either (const True) (const False) (verifyBootstrapStampPayload "payload-b" vectorDigest identity bytes))
      assertBool "changed accepted scope vector was accepted"
        (either (const True) (const False)
          (verifyBootstrapStampPayload "payload-a" (contentDigest "other-vector") identity bytes))
      assertBool "missing marker identity was accepted"
        (either (const True) (const False) (verifyBootstrapStampPayload "payload-a" vectorDigest identity "{}"))
  , testCase "reviewed release marker waits for every foundation resource and operation" $ do
      (foundationBundle, _) <- compileFoundation foundationInput >>= expectRight
      let quotaId = case [member ^. #identity | Managed member <- declarations foundationBundle,
            member ^. #address == Kubernetes fixtureCluster "" (known "resourcequota")
              (Just (known "personal")) (known "nagare-terminating-jobs")] of
            [resource] -> resource
            _ -> error "foundation quota is missing"
          operationId = mintResourceId fixtureOwner (ok (mkLogicalKey "bootstrap")) (known "proof")
          proof = DeclaredOperation operationId (quotaId :| []) [] Idempotent PublishRelease
          baseScope = ok (mkScopeDeclaration fixtureOwner [foundationBundle {operations = [proof]}])
          binding = ContextBinding (ok (mkContextId "fixture")) (known "project")
          snapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
          base = ok (composeInventory snapshot (ReplaceScope baseScope :| []))
          marker = object ["apiVersion" .= ("v1" :: Text), "kind" .= ("ConfigMap" :: Text),
            "metadata" .= object ["name" .= ("nagare-platform-version" :: Text),
              "namespace" .= ("nagare-system" :: Text)],
            "data" .= object ["version" .= ("0.4.0" :: Text),
              "installedAt" .= ("2026-09-22T00:00:00Z" :: Text)]]
      vectorDigest <- expectRight (bootstrapCandidateScopeVectorDigest base)
      let revisions = Map.fromList
            [(fixtureOwner, ScopeRevision (candidateGenerations base Map.! fixtureOwner)
              (contentDigest (encodeCanonicalScope baseScope)))]
      bootstrapScopeVectorDigest revisions @?= vectorDigest
      let appOwner = ok (mkScopeId Application "unrelated")
      bootstrapScopeVectorDigest (Map.insert appOwner
        (ScopeRevision (ok (mkScopeGeneration 7)) (contentDigest "unrelated-app")) revisions)
        @?= vectorDigest
      assertBool "changed scope generation retained the marker vector digest"
        (bootstrapScopeVectorDigest (Map.adjust
          (\revision -> revision {revisionGeneration = ok (mkScopeGeneration 2)}) fixtureOwner revisions)
          /= vectorDigest)
      (stampScope, native) <- expectRight (compileBootstrapStamp fixtureCluster marker base)
      bootstrapScopeVectorDigest (Map.insert (scopeId stampScope)
        (ScopeRevision (ok (mkScopeGeneration 1)) (contentDigest (encodeCanonicalScope stampScope)))
        revisions) @?= vectorDigest
      let stampMembers = [resource | bundle <- scopeBundles stampScope,
            Managed resource <- declarations bundle]
      case stampMembers of
        [stamp] -> do
          let required = [resource ^. #identity | Managed resource <- inventoryDeclarations (candidateInventory base)]
          all (\resource -> OrderedAfter resource `elem` stamp ^. #dependencies) (operationId : required)
            @?= True
          Map.member (stamp ^. #identity) native @?= True
        _ -> assertFailure "bootstrap has no unique marker"
      _ <- expectRight (composeInventory snapshot (candidateChanges base <> (ReplaceScope stampScope :| [])))
      let accepted = ok (mkScopeSnapshot binding (Map.fromList
            [(fixtureOwner, (ok (mkScopeGeneration 1), baseScope)),
             (scopeId stampScope, (ok (mkScopeGeneration 1), stampScope))]) Map.empty)
          rerun = ok (composeInventory accepted (ReplaceScope baseScope :| []))
      bootstrapPreservedScopeVectorDigest accepted rerun @?= Right vectorDigest
      (nextStamp, _) <- expectRight (compileBootstrapStamp fixtureCluster marker rerun)
      _ <- expectRight (composeInventory accepted (candidateChanges rerun <> (ReplaceScope nextStamp :| [])))
      pure ()
  , testCase "granted namespace contributions materialize once for shared callers" $ do
      let appA = ok (mkScopeId Application "a")
          appB = ok (mkScopeId Application "b")
          input = foundationInput {foundationGrantedScopes = [appA, appB]}
          request = RegisterNamespace fixtureOwner fixtureCluster (known "sandbox") (ok (mkLogicalKey "sandbox"))
          consumer scopeId = ok (mkScopeDeclaration scopeId [ResourceBundle [] [] [] [request] [] []])
          binding = ContextBinding (ok (mkContextId "fixture")) (known "project")
          snapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
      (bundle, _) <- compileFoundation input >>= expectRight
      let platformScope = ok (mkScopeDeclaration fixtureOwner [bundle])
          candidate = ok (composeInventory snapshot (ReplaceScope platformScope :| [ReplaceScope (consumer appA), ReplaceScope (consumer appB)]))
          declarations = inventoryDeclarations (candidateInventory candidate)
      native <- expectRight (compileContributedNamespaces declarations)
      Map.size native @?= 1
      let resources = [member | Managed member <- declarations, member ^. #executor == KubernetesExecutor]
      _ <- expectRight (validateSuppliedKubernetesMembers resources native)
      pure ()
  ]

foundationInput :: FoundationInput
foundationInput = FoundationInput fixtureOwner fixtureCluster ("../../cluster/bootstrap/job-runs" </> "resourcequota.yaml") []

fixtureOwner :: ScopeId
fixtureOwner = ok (mkScopeId Platform "foundation")

fixtureCluster :: ResourceId
fixtureCluster = mintResourceId fixtureOwner (ok (mkLogicalKey "cluster")) (known "cluster")

known :: Text -> Name
known = ok . mkName

ok :: Show e => Either e a -> a
ok = either (error . show) id

expectRight :: Show e => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> pure (error "unreachable")) pure
