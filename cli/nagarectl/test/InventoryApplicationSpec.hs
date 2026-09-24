module InventoryApplicationSpec (inventoryApplicationTests) where

import Data.Generics.Labels ()
import Data.ByteString.Char8 qualified as BC
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Dsl.Database (mkDatabaseName)
import Nagare.Dsl.Load (loadApplication, loadBroker)
import Nagare.Dsl.Task (Task (..), scheduledTask)
import Nagare.Dsl.Types (mkServiceName)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Application (compileApplicationDatabases, reviewedTaskImages)
import Nagare.Inventory.Components.Foundation (FoundationInput (..), compileFoundation)
import Nagare.Inventory.DataService (acceptedFoundationNamespace, brokerNativeOwned, compileStandaloneBroker, databaseNativeOwned, standaloneRetirementScope)
import Nagare.Inventory.Environment (compileBuildEnvChannel, compileBuildSecretChannel, compilePreviewEnvChannel, compilePreviewSecretChannel, compileRuntimeEnvChannel, compileRuntimeSecretChannel, validateSecretRotation)
import Nagare.Resource.Application (applicationScopeId)
import Nagare.Resource.Inventory (Declaration (Managed), ManagedResource (..), ResourceBundle (..), mkScopeDeclaration, mkScopeSnapshot, scopeBundles, scopeId)
import Nagare.Resource.Policy (RecoveryIntent (..), Sensitivity (Secret), mkSecretRef)
import Nagare.Resource.Types
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

inventoryApplicationTests :: TestTree
inventoryApplicationTests = testGroup "application inventory compilation"
  [ testCase "reviewed scheduled tasks use the accepted application image" $ do
      let checked = either (error . show) id
          sameImage = checked (scheduledTask "cleanup" "0 2 * * *" "registry/app" "cleanup")
          otherImage = checked (scheduledTask "cleanup" "0 2 * * *" "registry/other" "cleanup")
          inherited = sameImage & #image .~ Nothing
            & #app .~ Just (checked (mkServiceName "app"))
      reviewedTaskImages [sameImage, inherited] "registry/app:v1" "v1" @?= Right ()
      case reviewedTaskImages [otherImage] "registry/app:v1" "v1" of
        Left _ -> pure ()
        Right _ -> assertFailure "task referenced a second unreviewed image"
  , testCase "Build env intent has a separate accepted ConfigMap channel" $ do
      let checked = either (error . show) id
          foundation = checked (mkScopeId Platform "foundation")
          cluster = mintResourceId foundation (checked (mkLogicalKey "cluster"))
            (checked (mkName "cluster"))
          namespaceId = mintResourceId foundation (checked (mkLogicalKey "foundation"))
            (checked (mkName "namespace-personal"))
          values = Map.singleton "BUILD_MODE" "release"
          source = SourceLocation "env" "build-env"
      (buildScope, buildNative) <- either (fail . show) pure
        (compileBuildEnvChannel "kizashi" "personal" cluster namespaceId values source)
      (runtimeScope, _) <- either (fail . show) pure
        (compileRuntimeEnvChannel "kizashi" "personal" cluster namespaceId values source)
      scopeId buildScope @?= checked (mkScopeId Application "env-kizashi-build")
      case [resource | bundle <- scopeBundles buildScope, Managed resource <- declarations bundle] of
        [resource] -> do
          resource ^. #address @?= checked (kubernetesAddress cluster "v1" "ConfigMap"
            (Just "personal") "nagare-env-kizashi-build")
          Map.size buildNative @?= 1
          case [runtime | bundle <- scopeBundles runtimeScope, Managed runtime <- declarations bundle] of
            [runtime] -> resource ^. #identity == runtime ^. #identity @?= False
            _ -> assertFailure "Runtime channel has unexpected membership"
        _ -> assertFailure "Build channel has unexpected membership"
      (previewScope, previewNative) <- either (fail . show) pure
        (compilePreviewEnvChannel "kizashi" "personal" cluster namespaceId values source)
      scopeId previewScope @?= checked (mkScopeId Application "env-kizashi-preview")
      case [resource | bundle <- scopeBundles previewScope, Managed resource <- declarations bundle] of
        [resource] -> do
          resource ^. #address @?= checked (kubernetesAddress cluster "v1" "ConfigMap"
            (Just "personal") "nagare-env-kizashi-preview")
          Map.size previewNative @?= 1
        _ -> assertFailure "Preview env channel has unexpected membership"
  , testCase "Runtime env intent compiles into an independent exact ConfigMap channel" $ do
      let checked = either (error . show) id
          foundation = checked (mkScopeId Platform "foundation")
          cluster = mintResourceId foundation (checked (mkLogicalKey "cluster"))
            (checked (mkName "cluster"))
          namespaceId = mintResourceId foundation (checked (mkLogicalKey "foundation"))
            (checked (mkName "namespace-personal"))
          values = Map.fromList [("MODE", "reviewed"), ("TIMEOUT", "30")]
      (scope, native) <- either (fail . show) pure (compileRuntimeEnvChannel
        "kizashi" "personal" cluster namespaceId values (SourceLocation "env" "runtime-env"))
      scopeId scope @?= checked (mkScopeId Application "env-kizashi-runtime")
      case [resource | bundle <- scopeBundles scope, Managed resource <- declarations bundle] of
        [resource] -> do
          resource ^. #address @?= checked (kubernetesAddress cluster "v1" "ConfigMap"
            (Just "personal") "nagare-env-kizashi-runtime")
          case Map.lookup (resource ^. #identity) native of
            Just (_, bytes) -> do
              BC.isInfixOf "reviewed" bytes @?= True
              BC.isInfixOf "TIMEOUT" bytes @?= True
            Nothing -> assertFailure "env channel lost its native ConfigMap"
        _ -> assertFailure "env channel has unexpected declarations"
  , testCase "Runtime Secret intent has an independent private native channel" $ do
      let checked = either (error . show) id
          foundation = checked (mkScopeId Platform "foundation")
          cluster = mintResourceId foundation (checked (mkLogicalKey "cluster"))
            (checked (mkName "cluster"))
          namespaceId = mintResourceId foundation (checked (mkLogicalKey "foundation"))
            (checked (mkName "namespace-personal"))
          values = Map.singleton "TOKEN" "secret-canary-value"
      (scope, native) <- either (fail . show) pure (compileRuntimeSecretChannel
        "kizashi" "personal" cluster namespaceId (checked (mkName "v2")) values
        (SourceLocation "secret-file" "runtime-secret"))
      scopeId scope @?= checked (mkScopeId Application "secret-kizashi-runtime")
      case [resource | bundle <- scopeBundles scope, Managed resource <- declarations bundle] of
        [resource] -> do
          resource ^. #address @?= checked (kubernetesAddress cluster "v1" "Secret"
            (Just "personal") "nagare-secret-kizashi-runtime")
          resource ^. #sensitivity @?= Secret
          resource ^. #source @?= SourceLocation "secret-file" "runtime-secret/v2"
          BC.isInfixOf "secret-canary-value" (BC.pack (show resource)) @?= False
          case Map.lookup (resource ^. #identity) native of
            Just (_, bytes) -> do
              BC.isInfixOf "TOKEN" bytes @?= True
              BC.isInfixOf "secret-canary-value" bytes @?= False
            Nothing -> assertFailure "secret channel lost its native Secret"
        _ -> assertFailure "secret channel has unexpected declarations"
      let binding = ContextBinding (checked (mkContextId "fixture")) (checked (mkName "project"))
          source = SourceLocation "secret-file" "runtime-secret"
      snapshot <- either (fail . show) pure (mkScopeSnapshot binding
        (Map.singleton (scopeId scope) (checked (mkScopeGeneration 1), scope)) Map.empty)
      (changed, _) <- either (fail . show) pure (compileRuntimeSecretChannel
        "kizashi" "personal" cluster namespaceId (checked (mkName "v2"))
        (Map.singleton "TOKEN" "different-value") source)
      case validateSecretRotation snapshot changed of
        Left _ -> pure ()
        Right _ -> assertFailure "one rotation version accepted different Secret bytes"
      (rotated, _) <- either (fail . show) pure (compileRuntimeSecretChannel
        "kizashi" "personal" cluster namespaceId (checked (mkName "v3"))
        (Map.singleton "TOKEN" "different-value") source)
      validateSecretRotation snapshot rotated @?= Right ()
      (buildScope, buildNative) <- either (fail . show) pure
        (compileBuildSecretChannel "kizashi" "personal" cluster namespaceId
          (checked (mkName "v2")) values source)
      scopeId buildScope @?= checked (mkScopeId Application "secret-kizashi-build")
      case [resource | bundle <- scopeBundles buildScope, Managed resource <- declarations bundle] of
        [resource] -> do
          resource ^. #address @?= checked (kubernetesAddress cluster "v1" "Secret"
            (Just "personal") "nagare-secret-kizashi-build")
          resource ^. #sensitivity @?= Secret
          resource ^. #source @?= SourceLocation "secret-file" "build-secret/v2"
          Map.size buildNative @?= 1
        _ -> assertFailure "Build Secret channel has unexpected membership"
      validateSecretRotation snapshot buildScope @?= Right ()
      buildSnapshot <- either (fail . show) pure (mkScopeSnapshot binding
        (Map.singleton (scopeId buildScope) (checked (mkScopeGeneration 1), buildScope)) Map.empty)
      (changedBuild, _) <- either (fail . show) pure
        (compileBuildSecretChannel "kizashi" "personal" cluster namespaceId
          (checked (mkName "v2")) (Map.singleton "TOKEN" "changed-build-value") source)
      case validateSecretRotation buildSnapshot changedBuild of
        Left _ -> pure ()
        Right _ -> assertFailure "Build Secret reused a version with changed content"
      (previewScope, previewNative) <- either (fail . show) pure
        (compilePreviewSecretChannel "kizashi" "personal" cluster namespaceId
          (checked (mkName "v2")) values source)
      scopeId previewScope @?= checked (mkScopeId Application "secret-kizashi-preview")
      case [resource | bundle <- scopeBundles previewScope, Managed resource <- declarations bundle] of
        [resource] -> do
          resource ^. #address @?= checked (kubernetesAddress cluster "v1" "Secret"
            (Just "personal") "nagare-secret-kizashi-preview")
          resource ^. #source @?= SourceLocation "secret-file" "preview-secret/v2"
          Map.size previewNative @?= 1
        _ -> assertFailure "Preview Secret channel has unexpected membership"
      validateSecretRotation buildSnapshot previewScope @?= Right ()
  , testCase "standalone data planning requires the accepted platform Namespace" $ do
      let checked = either (error . show) id
          owner = checked (mkScopeId Platform "foundation")
          cluster = mintResourceId owner (checked (mkLogicalKey "cluster"))
            (checked (mkName "cluster"))
          binding = ContextBinding (checked (mkContextId "fixture")) (checked (mkName "project"))
          empty = either (error . show) id (mkScopeSnapshot binding Map.empty Map.empty)
      case acceptedFoundationNamespace empty "personal" of
        Left _ -> pure ()
        Right _ -> assertFailure "standalone planning accepted an absent foundation"
      (bundle, _) <- compileFoundation (FoundationInput owner cluster
        "../../cluster/bootstrap/job-runs/resourcequota.yaml" []) >>= either (fail . show) pure
      scope <- either (fail . show) pure (mkScopeDeclaration owner [bundle])
      snapshot <- either (fail . show) pure (mkScopeSnapshot binding
        (Map.singleton owner (checked (mkScopeGeneration 1), scope)) Map.empty)
      let namespaceId = mintResourceId owner (checked (mkLogicalKey "foundation"))
            (checked (mkName "namespace-personal"))
      acceptedFoundationNamespace snapshot "personal" @?= Right (cluster, namespaceId)
      case acceptedFoundationNamespace snapshot "other" of
        Left _ -> pure ()
        Right _ -> assertFailure "standalone planning accepted an unowned Namespace"
  , testCase "complete typed database members join the application scope" $ do
      loaded <- loadApplication "test/fixtures/app/kizashi/Config.hs"
      app <- either (fail . show) pure loaded
      owner <- either (fail . show) pure (applicationScopeId app)
      let clusterOwner = either (error . show) id (mkScopeId Platform "foundation")
          cluster = mintResourceId clusterOwner
            (either (error . show) id (mkLogicalKey "cluster"))
            (either (error . show) id (mkName "resource"))
          recovery = RecoveryIntent (either (error . show) id (mkName "backup"))
            (mkSecretRef (either (error . show) id (mkName "db-password"))
              (either (error . show) id (mkName "v1")) :| [])
          recoveryByDatabase = Map.fromList
            [(database ^. #name, recovery) | database <- app ^. #databases]
          source = SourceLocation "test" "application"
          backend = GcsBackend "project" "bucket"
      (bundles, native) <- either (fail . show) pure
        (compileApplicationDatabases app cluster Nothing recoveryByDatabase backend source)
      length bundles @?= 1
      Map.size native @?= 5
      [resource ^. #owner | bundle <- bundles, Managed resource <- bundle ^. #declarations]
        @?= replicate 5 owner
      case app ^. #databases of
        [database] ->
          map (databaseNativeOwned database . pure . fst) (Map.elems native)
            @?= replicate 5 True
        _ -> assertFailure "fixture did not contain exactly one database"
      case compileApplicationDatabases app cluster Nothing Map.empty backend source of
        Left (err :| _) -> code err @?= "missing-database-recovery"
        Right _ -> assertFailure "database without recovery intent was accepted"
      case app ^. #databases of
        [database] -> do
          let key = either (error . show) id (mkLogicalKey "shared-database")
              renamedName = either (error . show) id (mkDatabaseName "kizashi-db-new")
              firstDatabase = database & #logicalKey .~ Just key
              secondDatabase = database & #name .~ renamedName & #logicalKey .~ Just key
              collisionApp = app & #databases .~ [firstDatabase, secondDatabase]
              bothRecovery = Map.fromList
                [(firstDatabase ^. #name, recovery), (secondDatabase ^. #name, recovery)]
          case compileApplicationDatabases collisionApp cluster Nothing bothRecovery backend source of
            Left (err :| _) -> code err @?= "duplicate-id"
            Right _ -> assertFailure "two databases with one logical key were accepted"
        _ -> assertFailure "fixture did not contain exactly one database"
  , testCase "standalone broker binds its PVC, Service, and StatefulSet" $ do
      loaded <- loadBroker "../nagare-dsl/test/fixtures/broker/redpanda/nagare/Config.hs"
      broker <- either (fail . show) pure loaded
      let owner = either (error . show) id (mkScopeId Standalone "broker-events")
          clusterOwner = either (error . show) id (mkScopeId Platform "foundation")
          cluster = mintResourceId clusterOwner
            (either (error . show) id (mkLogicalKey "cluster"))
            (either (error . show) id (mkName "resource"))
          namespaceId = mintResourceId clusterOwner
            (either (error . show) id (mkLogicalKey "foundation"))
            (either (error . show) id (mkName "namespace-personal"))
          recovery = RecoveryIntent (either (error . show) id (mkName "backup"))
            (mkSecretRef (either (error . show) id (mkName "broker-key"))
              (either (error . show) id (mkName "v1")) :| [])
          source = SourceLocation "test" "broker"
      case compileStandaloneBroker broker owner cluster namespaceId recovery source of
        Left (err :| _) -> code err @?= "invalid-standalone-broker"
        Right _ -> assertFailure "broker topics disappeared from inventory review"
      let withoutTopics = broker & #topics .~ []
      (scope, native) <- either (fail . show) pure
        (compileStandaloneBroker withoutTopics owner cluster namespaceId recovery source)
      length (scopeBundles scope) @?= 1
      Map.size native @?= 3
      [resource ^. #owner | bundle <- scopeBundles scope, Managed resource <- bundle ^. #declarations]
        @?= replicate 3 owner
      map (brokerNativeOwned withoutTopics . pure . fst) (Map.elems native)
        @?= replicate 3 True
      let checked = either (error . show) id
          binding = ContextBinding (checked (mkContextId "fixture")) (checked (mkName "project"))
          snapshot = either (error . show) id (mkScopeSnapshot binding
            (Map.singleton owner (checked (mkScopeGeneration 1), scope)) Map.empty)
      standaloneRetirementScope "broker" "events" "personal" Nothing snapshot @?= Right owner
      case standaloneRetirementScope "broker" "events" "other" Nothing snapshot of
        Left _ -> pure ()
        Right _ -> assertFailure "retirement accepted a different namespace"
      case standaloneRetirementScope "database" "events" "personal" Nothing snapshot of
        Left _ -> pure ()
        Right _ -> assertFailure "retirement selected a different data kind"
      case standaloneRetirementScope "broker" "other" "personal" (Just "events") snapshot of
        Left _ -> pure ()
        Right _ -> assertFailure "retirement selected a mismatched native name"
  ]
