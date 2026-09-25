module InventoryApplicationSpec (inventoryApplicationTests) where

import Data.Generics.Labels ()
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Dsl.Database (mkDatabaseName)
import Nagare.Dsl.Load (loadApplication, loadBroker)
import Nagare.Dsl.Task (Task (..), scheduledTask)
import Nagare.Dsl.Task.Render (renderTask)
import Nagare.Dsl.Types (RetentionPolicy (Delete), databaseNameText, mkServiceName, namespaceText)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Application (compileApplicationDatabases, reviewedTaskImages)
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Broker
import Nagare.Inventory.Adapters.BrokerRuntime (parseDescription, parseList)
import Nagare.Inventory.Components.Foundation (FoundationInput (..), compileFoundation)
import Nagare.Inventory.DataService (NativeDataKind (..), acceptedFoundationNamespace, brokerNativeOwned, brokerTopicChangeRequiresReview, compileStandaloneBroker, dataCommandNativeOwned, databaseNativeOwned, standaloneRetirementScope)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (mkOperationId)
import Nagare.Inventory.Environment (acceptedEnvChannelValues, acceptedSecretChannelValues, compileBuildEnvChannel, compileBuildSecretChannel, compilePreviewEnvChannel, compilePreviewSecretChannel, compileRuntimeEnvChannel, compileRuntimeSecretChannel, validateSecretRotation)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.TaskRun (compileTaskRunScope)
import Nagare.Env.Store (ReconcileMode (..), reconcile)
import Nagare.Resource.Application (applicationScopeId)
import Nagare.Resource.Inventory (Declaration (Managed), DesiredSpec (LogicalBrokerTopic, NativeObject), Executor (BrokerExecutor), ManagedResource (..), ResourceBundle (..), mkScopeDeclaration, mkScopeSnapshot, scopeBundles, scopeConfigDigest, scopeId)
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced), RecoveryClass (VerifyBeforeRetry), RecoveryIntent (..), Sensitivity (Private, Secret), mkSecretRef)
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

inventoryApplicationTests :: TestTree
inventoryApplicationTests = testGroup "application inventory compilation"
  [ testCase "manual task Job compiles from an exact accepted CronJob template" $ do
      let checked :: Show e => Either e a -> a
          checked = either (error . show) id
          task = checked (scheduledTask "cleanup" "0 2 * * *" "example.test/demo" "cleanup")
            & #app .~ Just (checked (mkServiceName "demo"))
          cronBytes = renderTask task
          cronValue = checked (Yaml.decodeEither' cronBytes)
          cronCanonical = checked (canonicalValue cronValue)
          foundation = checked (mkScopeId Platform "foundation")
          cluster = mintResourceId foundation (checked (mkLogicalKey "cluster"))
            (checked (mkName "cluster"))
          owner = checked (mkScopeId Application "demo")
          cronId = mintResourceId owner (checked (mkLogicalKey "cleanup"))
            (checked (mkName "cronjob"))
          source = SourceLocation "fixture" "task-run/r1"
          input = KubernetesInput cronId owner cluster cronValue
            (contentDigest cronCanonical) DeleteWhenUnreferenced Stateless Private source
          (cronJob, _) = checked (bindKubernetesObject input)
      (scope, native) <- either (fail . show) pure
        (compileTaskRunScope (Just "demo") cronJob cronBytes "r1" source)
      scopeId scope @?= checked (mkScopeId Standalone "task-run-personal-r1-nagare-task-cleanup")
      scopeConfigDigest scope @?= Just (contentDigest cronCanonical)
      Map.size native @?= 1
      let jobs = [resource | bundle <- scopeBundles scope,
            Managed resource <- declarations bundle]
      case jobs of
        [job] -> do
          job ^. #address @?= checked (kubernetesAddress cluster "batch/v1" "Job"
            (Just "personal") "nagare-task-cleanup-manual-r1")
          job ^. #dependencies @?= [OrderedAfter cronId]
          let jobBytes = snd (native Map.! (job ^. #identity))
          BS.isInfixOf "backoffLimit" jobBytes @?= True
          BS.isInfixOf "example.test/demo" jobBytes @?= True
        _ -> assertFailure "manual task review lacks exactly one Job"
      compileTaskRunScope (Just "demo") cronJob cronBytes "r1" source @?= Right (scope, native)
      case compileTaskRunScope (Just "demo") (cronJob & #spec .~ NativeObject (contentDigest "other"))
          cronBytes "r2" source of
        Left _ -> pure ()
        Right _ -> assertFailure "manual task accepted a different CronJob template digest"
      case compileTaskRunScope (Just "other") cronJob cronBytes "r2" source of
        Left _ -> pure ()
        Right _ -> assertFailure "manual task accepted another app's CronJob"
      case compileTaskRunScope (Just "demo") cronJob cronBytes "bad.id" source of
        Left _ -> pure ()
        Right _ -> assertFailure "manual task accepted an invalid Kubernetes run ID"
      case compileTaskRunScope Nothing cronJob cronBytes "r2" source of
        Left _ -> pure ()
        Right _ -> assertFailure "manual app-less run accepted an app-owned task"
      let longRunId = T.replicate 48 "a"
          jobAddress run = do
            (jobScope, _) <- compileTaskRunScope (Just "demo") cronJob cronBytes run source
            case [resource ^. #address | bundle <- scopeBundles jobScope,
                  Managed resource <- declarations bundle] of
              [address] -> Right address
              _ -> error "manual run scope has no unique Job"
          firstAddress = checked (jobAddress longRunId)
          secondAddress = checked (jobAddress (longRunId <> "b"))
      case firstAddress of
        Kubernetes _ _ _ _ name -> assertBool "manual Job name exceeds Kubernetes limit"
          (T.length (nameText name) <= 63)
        _ -> assertFailure "manual task run is not a Kubernetes Job"
      firstAddress @?= checked (jobAddress longRunId)
      assertBool "long run IDs collided after name shortening" (firstAddress /= secondAddress)
  , testCase "manual app-less Job uses an accepted unlabeled CronJob" $ do
      let checked :: Show e => Either e a -> a
          checked = either (error . show) id
          task = checked (scheduledTask "cleanup" "0 2 * * *" "example.test/demo" "cleanup")
          cronBytes = renderTask task
          cronValue = checked (Yaml.decodeEither' cronBytes)
          cronCanonical = checked (canonicalValue cronValue)
          foundation = checked (mkScopeId Platform "foundation")
          cluster = mintResourceId foundation (checked (mkLogicalKey "cluster"))
            (checked (mkName "cluster"))
          owner = checked (mkScopeId Standalone "tasks")
          cronId = mintResourceId owner (checked (mkLogicalKey "cleanup"))
            (checked (mkName "cronjob"))
          source = SourceLocation "fixture" "task-run/app-less"
          input = KubernetesInput cronId owner cluster cronValue
            (contentDigest cronCanonical) DeleteWhenUnreferenced Stateless Private source
          (cronJob, _) = checked (bindKubernetesObject input)
      (scope, native) <- either (fail . show) pure
        (compileTaskRunScope Nothing cronJob cronBytes "r1" source)
      Map.size native @?= 1
      scopeId scope @?= checked (mkScopeId Standalone "task-run-personal-r1-nagare-task-cleanup")
      case compileTaskRunScope (Just "demo") cronJob cronBytes "r2" source of
        Left _ -> pure ()
        Right _ -> assertFailure "manual app run accepted an unlabeled task"
  , testCase "reviewed scheduled tasks use the accepted application image" $ do
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
      let binding = ContextBinding (checked (mkContextId "env-merge")) (checked (mkName "project"))
          snapshot = either (error . show) id (mkScopeSnapshot binding
            (Map.singleton (scopeId scope) (checked (mkScopeGeneration 1), scope)) Map.empty)
      acceptedEnvChannelValues snapshot native scope @?= Right values
      let added = Map.singleton "MODE" "merged"
      (reconcile Merge <$> acceptedEnvChannelValues snapshot native scope
        <*> pure added) @?= Right (Map.fromList [("MODE", "merged"), ("TIMEOUT", "30")])
      acceptedEnvChannelValues snapshot Map.empty scope @?=
        Left "accepted environment channel has no private native member"
      case [resource | bundle <- scopeBundles scope, Managed resource <- declarations bundle] of
        [resource] -> do
          resource ^. #address @?= checked (kubernetesAddress cluster "v1" "ConfigMap"
            (Just "personal") "nagare-env-kizashi-runtime")
          let changedAddress = resource & #address .~ checked (kubernetesAddress cluster "v1"
                "ConfigMap" (Just "personal") "another-channel")
              wrongChannel = either (error . show) id (mkScopeDeclaration (scopeId scope)
                [ResourceBundle [Managed changedAddress] [] [] [] [] []])
          acceptedEnvChannelValues snapshot native wrongChannel @?=
            Left "accepted environment channel identity or address differs from requested channel"
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
      acceptedSecretChannelValues snapshot native scope @?= Right values
      acceptedSecretChannelValues snapshot Map.empty scope @?=
        Left "accepted Secret channel has no private native member"
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
        [database] -> do
          map (databaseNativeOwned database . pure . fst) (Map.elems native)
            @?= replicate 5 True
          let claims = [resource | (resource, _) <- Map.elems native,
                case resource ^. #address of
                  Kubernetes _ "" kind _ _ -> nameText kind == "persistentvolumeclaim"
                  _ -> False]
              name = databaseNameText (database ^. #name)
              ns = namespaceText (database ^. #namespace)
          length claims @?= 1
          dataCommandNativeOwned DatabaseObjects name ns claims @?= True
          dataCommandNativeOwned DatabaseObjects "other" ns claims @?= False
          let retainedBackups = [resource | (resource, _) <- Map.elems native,
                case resource ^. #address of
                  Kubernetes _ "batch" kind _ _ -> nameText kind == "cronjob"
                  _ -> False]
          length retainedBackups @?= 1
          databaseNativeOwned (database & #retention .~ Delete) retainedBackups @?= True
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
  , testCase "standalone broker binds native members and logical topics" $ do
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
      (scope, native) <- either (fail . show) pure
        (compileStandaloneBroker broker owner cluster namespaceId recovery source)
      length (scopeBundles scope) @?= 1
      Map.size native @?= 3
      [resource ^. #owner | bundle <- scopeBundles scope, Managed resource <- bundle ^. #declarations]
        @?= replicate 4 owner
      let topics = [resource | bundle <- scopeBundles scope, Managed resource <- bundle ^. #declarations,
            resource ^. #executor == BrokerExecutor]
      length topics @?= 1
      specs <- either (fail . show) pure (topicSpecsFromDeclarations (concatMap declarations (scopeBundles scope)))
      Map.size specs @?= 1
      let topicId = either (error . show) id (case topics of
            [single] -> Right (single ^. #identity)
            _ -> Left ("expected one topic" :: Text))
          physical = either (error . show) id (mkPhysicalIdentity "broker-statefulset://uid/topic/jobs")
          operation = PlannedOperation (either (error . show) id (mkOperationId "op-topic-create"))
            CreateResource BrokerExecutor (topicId :| []) (contentDigest "topic-input") [] VerifyBeforeRetry
      topicState <- newIORef TopicMissing
      let ops = TopicAdapterOps
            { topicInspect = \_ -> readIORef topicState
            , topicCreate = \_ -> do
                writeIORef topicState (TopicPresent physical 1 1 (Just 86400000))
                pure AdapterEffectCompleted
            , topicAlterRetention = \_ -> do
                writeIORef topicState (TopicPresent physical 1 1 (Just 43200000))
                pure AdapterEffectCompleted
            }
          adapter = mkTopicAdapter Map.empty specs ops
      before <- adapterObserve adapter [topicId] >>= either (fail . show) pure
      case Map.lookup topicId (observationMap before) of
        Just (ConfirmedAbsent _) -> pure ()
        other -> assertFailure ("topic absence was not proved: " <> show other)
      prepared <- adapterPrepare adapter operation >>= either (fail . show) pure
      adapterPreflight adapter operation prepared >>= either (fail . show) pure
      case Aeson.eitherDecodeStrict (preparedNativeBytes prepared) of
        Right (Aeson.Object fields) -> do
          legacyBytes <- either (fail . show) pure
            (canonicalValue (Aeson.Object (KeyMap.delete "previousRetentionMs" fields)))
          let legacyPrepared = prepared {preparedNativeBytes = legacyBytes}
          adapterPreflight adapter operation legacyPrepared >>= either (fail . show) pure
        _ -> assertFailure "topic private plan is not a JSON object"
      executed <- adapterExecute adapter operation prepared
      executed @?= AdapterEffectCompleted
      _ <- adapterVerify adapter operation prepared >>= either (fail . show) pure
      after <- adapterObserve adapter [topicId] >>= either (fail . show) pure
      Map.lookup topicId (observationMap after) @?= Just (ObservedUnowned physical)
      preflightResult <- adapterPreflight adapter operation prepared
      case preflightResult of
        Left _ -> pure ()
        Right _ -> assertFailure "existing unowned topic passed creation preflight"
      recovered <- adapterRecover adapter operation prepared
      case recovered of
        RecoveryUnresolved _ -> pure ()
        _ -> assertFailure "topic with unknown creation incarnation recovered automatically"
      oldTopic <- case topics of
        [single] -> pure single
        _ -> assertFailure "fixture does not contain exactly one topic" >> fail "missing topic"
      let newTopic = oldTopic & #spec .~ LogicalBrokerTopic 1 1 (Just 43200000)
          updatedSpecs = Map.adjust (\binding -> binding {topicDeclaration = newTopic}) topicId specs
          updateAdapter = mkTopicAdapter (Map.singleton topicId oldTopic) updatedSpecs ops
          updateOperation = PlannedOperation (either (error . show) id (mkOperationId "op-topic-update"))
            UpdateResource BrokerExecutor (topicId :| []) (contentDigest "retention-update") [] VerifyBeforeRetry
      updatedScope <- case scopeBundles scope of
        [bundle] -> either (fail . show) pure (mkScopeDeclaration owner
          [bundle {declarations = map (\case
            Managed resource | resource ^. #identity == topicId -> Managed newTopic
            declaration -> declaration) (declarations bundle)}])
        _ -> assertFailure "broker fixture does not have one resource bundle" >> fail "missing bundle"
      brokerTopicChangeRequiresReview scope scope @?= False
      brokerTopicChangeRequiresReview updatedScope scope @?= True
      updatePrepared <- adapterPrepare updateAdapter updateOperation >>= either (fail . show) pure
      preparedPublicSummary updatePrepared @?= "change broker topic jobs retention.ms from 86400000 to 43200000"
      adapterPreflight updateAdapter updateOperation updatePrepared >>= either (fail . show) pure
      adapterExecute updateAdapter updateOperation updatePrepared >>= (@?= AdapterEffectCompleted)
      _ <- adapterVerify updateAdapter updateOperation updatePrepared >>= either (fail . show) pure
      updateRecovery <- adapterRecover updateAdapter updateOperation updatePrepared
      case updateRecovery of
        RecoveryUnresolved _ -> pure ()
        _ -> assertFailure "ambiguous retention update recovered without an incarnation proof"
      writeIORef topicState (TopicPresent physical 1 1 (Just 123))
      refused <- adapterPreflight updateAdapter updateOperation updatePrepared
      case refused of
        Left _ -> pure ()
        Right _ -> assertFailure "topic retention drift passed update preflight"
      let topicBinding = updatedSpecs Map.! topicId
          unsupported = Map.insert topicId (topicBinding {topicDeclaration = newTopic & #spec .~ LogicalBrokerTopic 2 1 (Just 43200000)}) updatedSpecs
          unsafeAdapter = mkTopicAdapter (Map.singleton topicId oldTopic) unsupported ops
      unsafePrepared <- adapterPrepare unsafeAdapter updateOperation
      case unsafePrepared of
        Left _ -> pure ()
        Right _ -> assertFailure "partition change passed the retention-only update capability"
      let topicName = either (error . show) id (mkName "jobs")
      parseList topicName "[{\"name\":\"jobs\",\"partitions\":0,\"replicas\":0}]" @?= Right False
      parseList topicName "[{\"name\":\"jobs\",\"partitions\":1,\"replicas\":1}]" @?= Right True
      parseDescription topicName
        "[{\"summary\":{\"name\":\"jobs\",\"partitions\":1,\"replicas\":1},\"configs\":[{\"key\":\"retention.ms\",\"value\":\"86400000\",\"source\":\"DYNAMIC_TOPIC_CONFIG\"}]}]"
        @?= Right (1, 1, Just 86400000)
      map (brokerNativeOwned broker . pure . fst) (Map.elems native)
        @?= replicate 3 True
      let brokerServices = [resource | (resource, _) <- Map.elems native,
            case resource ^. #address of
              Kubernetes _ "" kind _ _ -> nameText kind == "service"
              _ -> False]
      length brokerServices @?= 1
      dataCommandNativeOwned BrokerObjects "events" "personal" brokerServices @?= True
      dataCommandNativeOwned BrokerObjects "events" "other" brokerServices @?= False
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
