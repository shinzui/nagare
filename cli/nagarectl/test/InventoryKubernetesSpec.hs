module InventoryKubernetesSpec (inventoryKubernetesTests) where

import Control.Exception (finally)
import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Database.Backup (renderDbBackupCronJob)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Database (Database (Database), Engine (..), defaultEngineVersion, engineVersionText, mkDatabaseName)
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Adapters.KubernetesRuntime (KubernetesRuntimeConfig (..), cacheClientDataMatches, certificateReady, confirmInventoryFieldOwnership, confirmInventoryFieldOwnershipFor, crdEstablished, credentialDataMatches, deploymentAvailable, desiredFieldsMatch, generatedCredentialTemplate, jobCompleted, knativeReady, materializeCacheKey, materializeCredential, mkKubernetesRuntimeOps, observeCacheClientOutput, supportedUpdateAddress, withoutCacheClientData)
import Nagare.Inventory.Database (compileDatabaseForBackend, compileDatabaseNative, compileDatabaseNativeWithBackup)
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute (TransactionResult (..), applyReviewed, resumeTransaction)
import Nagare.Inventory.Journal
import Nagare.Inventory.Kubernetes
import Nagare.Inventory.KubernetesSources (loadKubernetesSources)
import Nagare.Inventory.KubernetesReview (kubernetesSpecsFromReview)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory hiding (cluster)
import Nagare.Resource.Database (DatabaseDirectInput (..), databaseResourceId)
import Nagare.Resource.Kubernetes
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Test.Tasty
import Test.Tasty.HUnit
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.Process (readProcessWithExitCode)

inventoryKubernetesTests :: TestTree
inventoryKubernetesTests =
  testGroup
    "Kubernetes inventory adapter"
    [ testCase "reviewed create uses the retained native object and proves completion" $ do
        state <- newIORef (KubernetesAbsent absence)
        calls <- newIORef (0 :: Int)
        let adapter = mkKubernetesAdapter specs (ops state calls)
        prepared <- adapterPrepare adapter createOperation >>= expectRight
        assertBool "public summary omits manifest bytes" (not (nativeText `T.isInfixOf` preparedPublicSummary prepared))
        assertBool "private native bundle binds context" ("nagare.dev/context-id" `T.isInfixOf` TE.decodeUtf8 (preparedNativeBytes prepared))
        let mutation = ok (eitherDecodeStrict (preparedNativeBytes prepared)) :: KubernetesMutation
        unstampNative (ok (mkContextId "test")) resource (contentDigest nativeBytes) (mutationNativeJson mutation) @?= Right nativeBytes
        adapterPreflight adapter createOperation prepared >>= expectRight
        adapterExecute adapter createOperation prepared >>= (@?= AdapterEffectCompleted)
        readIORef calls >>= (@?= 1)
        proof <- adapterVerify adapter createOperation prepared >>= expectRight
        adapterRecover adapter createOperation prepared >>= (@?= RecoveryProvedComplete proof)
    , testCase "declared Job verification can be reviewed before Job creation" $ do
        let value = object
              [ "apiVersion" .= ("batch/v1" :: Text)
              , "kind" .= ("Job" :: Text)
              , "metadata" .= object ["name" .= ("migration" :: Text), "namespace" .= ("default" :: Text)]
              , "spec" .= object ["template" .= object ["spec" .= object
                  ["restartPolicy" .= ("Never" :: Text), "containers" .= [object ["name" .= ("job" :: Text), "image" .= ("example@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" :: Text)]]]]]
              ]
            jobBytes = ok (canonicalValue value)
            native = ok (bindKubernetesObject (input {inputObject = value, objectDigest = contentDigest jobBytes}))
            bound = Map.singleton resource native
            declaredOperation = (operation RunDeclaredOperation) {plannedResources = resource :| []}
        state <- newIORef (KubernetesAbsent (contentDigest "absent"))
        calls <- newIORef 0
        let adapter = mkKubernetesAdapter bound (ops state calls)
        prepared <- adapterPrepare adapter declaredOperation >>= expectRight
        writeIORef state (KubernetesPresent physical "4" (Just resource) (contentDigest jobBytes))
        adapterPreflight adapter declaredOperation prepared >>= expectRight
        adapterExecute adapter declaredOperation prepared >>= (@?= AdapterEffectCompleted)
        _ <- adapterVerify adapter declaredOperation prepared >>= expectRight
        readIORef calls >>= (@?= 0)
    , testCase "foreign present object refuses review without mutation" $ do
        state <- newIORef (KubernetesPresent physical "4" Nothing (contentDigest "foreign"))
        calls <- newIORef (0 :: Int)
        let adapter = mkKubernetesAdapter specs (ops state calls)
        result <- adapterPrepare adapter createOperation
        case result of
          Left PrepareRefused {} -> pure ()
          other -> assertFailure ("foreign object accepted: " <> show other)
        readIORef calls >>= (@?= 0)
    , testCase "resourceVersion change after review refuses before transport" $ do
        state <- newIORef (KubernetesPresent physical "4" (Just resource) (contentDigest "old"))
        calls <- newIORef (0 :: Int)
        let adapter = mkKubernetesAdapter specs (ops state calls)
        prepared <- adapterPrepare adapter updateOperation >>= expectRight
        writeIORef state (KubernetesPresent physical "5" (Just resource) (contentDigest "old"))
        result <- adapterPreflight adapter updateOperation prepared
        assertBool "stale review accepted" (either (const True) (const False) result)
        effect <- adapterExecute adapter updateOperation prepared
        case effect of AdapterEffectFailed {} -> pure (); other -> assertFailure ("stale mutation reached transport: " <> show other)
        readIORef calls >>= (@?= 0)
    , testCase "unknown observations and changed native bytes refuse" $ do
        state <- newIORef (KubernetesUnknown "API unavailable")
        calls <- newIORef (0 :: Int)
        let adapter = mkKubernetesAdapter specs (ops state calls)
            badSpecs = Map.singleton resource (declaration, "{}")
            badAdapter = mkKubernetesAdapter badSpecs (ops state calls)
        result <- adapterPrepare adapter createOperation
        case result of Left PrepareRefused {} -> pure (); other -> assertFailure ("unknown read accepted: " <> show other)
        writeIORef state (KubernetesAbsent absence)
        bad <- adapterPrepare badAdapter createOperation
        case bad of Left PrepareRefused {} -> pure (); other -> assertFailure ("unbound native bytes accepted: " <> show other)
        readIORef calls >>= (@?= 0)
    , testCase "native address cannot be changed behind a matching digest" $ do
        state <- newIORef (KubernetesAbsent absence)
        calls <- newIORef (0 :: Int)
        let wrong = declaration {address = Kubernetes cluster "" (ok (mkName "service")) (Just (ok (mkName "personal"))) (ok (mkName "other"))}
            adapter = mkKubernetesAdapter (Map.singleton resource (wrong, nativeBytes)) (ops state calls)
        result <- adapterPrepare adapter createOperation
        case result of Left PrepareRefused {} -> pure (); other -> assertFailure ("mismatched native address accepted: " <> show other)
        readIORef calls >>= (@?= 0)
    , testCase "source object cannot preclaim inventory annotations" $ do
        state <- newIORef (KubernetesAbsent absence)
        calls <- newIORef (0 :: Int)
        let value = object
              [ "apiVersion" .= ("v1" :: Text)
              , "kind" .= ("Service" :: Text)
              , "metadata" .= object
                  [ "name" .= ("cache" :: Text)
                  , "namespace" .= ("personal" :: Text)
                  , "annotations" .= object ["nagare.dev/resource-id" .= ("foreign" :: Text)]
                  ]
              ]
            bytes = ok (canonicalValue value)
            native = ok (bindKubernetesObject (input {inputObject = value, objectDigest = contentDigest bytes}))
            adapter = mkKubernetesAdapter (Map.singleton resource native) (ops state calls)
        result <- adapterPrepare adapter createOperation
        case result of Left PrepareRefused {} -> pure (); other -> assertFailure ("reserved annotation accepted: " <> show other)
        readIORef calls >>= (@?= 0)
    , testCase "database direct bundle retains canonical native members" $ do
        let db = Database (ok (mkDatabaseName "pg-main")) Nothing Postgres (defaultEngineVersion Postgres)
              (ok (Dsl.mkNamespace "personal")) (ok (Dsl.mkQuantity "10Gi")) Nothing Dsl.Retain
            recovery = RecoveryIntent (ok (mkName "backup")) (mkSecretRef (ok (mkName "db-password")) (ok (mkName "v1")) :| [])
            direct = DatabaseDirectInput db scope cluster Nothing recovery (SourceLocation "database" "postgres")
            (bundle, bound) = ok (compileDatabaseNative direct)
        length (declarations bundle) @?= 4
        Map.size bound @?= 4
        mapM_ (\(decl, bytes) -> case spec decl of
          NativeObject digest -> digest @?= contentDigest bytes
          StatefulSet _ _ digest -> digest @?= contentDigest bytes
          other -> assertFailure ("unexpected database spec: " <> show other)) (Map.elems bound)
    , testCase "database backup bundle binds the real CronJob renderer" $ do
        let db = Database (ok (mkDatabaseName "pg-main")) Nothing Postgres (defaultEngineVersion Postgres)
              (ok (Dsl.mkNamespace "personal")) (ok (Dsl.mkQuantity "10Gi")) Nothing Dsl.Retain
            recovery = RecoveryIntent (ok (mkName "backup")) (mkSecretRef (ok (mkName "db-password")) (ok (mkName "v1")) :| [])
            direct = DatabaseDirectInput db scope cluster Nothing recovery (SourceLocation "database" "postgres")
            rendered = renderDbBackupCronJob "personal" "pg-main" Postgres (engineVersionText (defaultEngineVersion Postgres)) (GcsBackend "project" "bucket") 7
            backup = ok (Yaml.decodeEither' rendered)
            (bundle, bound) = ok (compileDatabaseNativeWithBackup direct backup)
            compiledFromBackend = ok (compileDatabaseForBackend direct (GcsBackend "project" "bucket"))
        length (declarations bundle) @?= 5
        Map.size bound @?= 5
        compiledFromBackend @?= (bundle, bound)
        assertBool "backup native member omitted" (any (\(member, _) -> case address member of
          Kubernetes _ "batch" kind _ _ -> nameText kind == "cronjob"
          _ -> False) (Map.elems bound))
    , testCase "desired projection ignores server fields but detects changed desired data" $ do
        let desired = object
              [ "metadata" .= object ["name" .= ("config" :: Text)]
              , "data" .= object ["key" .= ("reviewed" :: Text)]
              ]
            observed value = object
              [ "metadata" .= object ["name" .= ("config" :: Text), "resourceVersion" .= ("17" :: Text)]
              , "data" .= object ["key" .= (value :: Text), "extra" .= ("unmanaged" :: Text)]
              , "status" .= object []
              ]
        assertBool "server extras should not drift" (desiredFieldsMatch desired (observed "reviewed"))
        assertBool "desired data change must drift" (not (desiredFieldsMatch desired (observed "changed")))
    , testCase "Job completion requires the controller Complete condition" $ do
        let job conditions = object ["kind" .= ("Job" :: Text), "status" .= object ["conditions" .= conditions]]
            condition kind state = object ["type" .= (kind :: Text), "status" .= (state :: Text)]
        assertBool "running Job proved complete" (not (jobCompleted (job [condition "Complete" "False"])))
        assertBool "failed Job proved complete" (not (jobCompleted (job [condition "Failed" "True"])))
        assertBool "completed Job was not recognized" (jobCompleted (job [condition "Complete" "True"]))
    , testCase "CRD and Deployment verification requires current controller readiness" $ do
        let condition kind state = object ["type" .= (kind :: Text), "status" .= (state :: Text)]
            crd state = object ["status" .= object ["conditions" .= [condition "Established" state]]]
            deployment observedGeneration = object
              [ "metadata" .= object ["generation" .= (3 :: Int)]
              , "status" .= object
                  [ "observedGeneration" .= (observedGeneration :: Int)
                  , "conditions" .= [condition "Available" "True"]
                  ]
              ]
        assertBool "unestablished CRD was accepted" (not (crdEstablished (crd "False")))
        assertBool "established CRD was rejected" (crdEstablished (crd "True"))
        assertBool "unready certificate was accepted" (not (certificateReady
          (object ["status" .= object ["conditions" .= [condition "Ready" "False"]]])))
        assertBool "ready certificate was rejected" (certificateReady
          (object ["status" .= object ["conditions" .= [condition "Ready" "True"]]]))
        assertBool "unready Knative Service was accepted" (not (knativeReady
          (object ["status" .= object ["conditions" .= [condition "Ready" "False"]]])))
        assertBool "stale Deployment availability was accepted" (not (deploymentAvailable (deployment 2)))
        assertBool "current Deployment availability was rejected" (deploymentAvailable (deployment 3))
    , testCase "auth credential data is generated only from a closed Secret template" $ do
        let template name = object
              [ "apiVersion" .= ("v1" :: Text)
              , "kind" .= ("Secret" :: Text)
              , "metadata" .= object
                  [ "name" .= (name :: Text)
                  , "namespace" .= ("nagare-system" :: Text)
                  , "annotations" .= object ["nagare.dev/auth-credential-template" .= ("v1" :: Text)]
                  ]
              , "type" .= ("Opaque" :: Text)
              ]
            enTemplate = template "nagare-en-api-keys"
            reviewed = TE.decodeUtf8 (ok (canonicalValue enTemplate))
        generatedCredentialTemplate reviewed @?= Right True
        generated <- materializeCredential reviewed >>= expectRight
        observed <- either (assertFailure . show) pure (eitherDecodeStrict (TE.encodeUtf8 generated))
        assertBool "auth credential did not produce the required private data" (credentialDataMatches enTemplate observed)
        refused <- materializeCredential (TE.decodeUtf8 (ok (canonicalValue (template "unexpected"))))
        assertBool "unknown auth credential template was accepted" (either (const True) (const False) refused)
    , testCase "cache client fills only the typed generated-key slot after review" $ do
        let template = object
              [ "apiVersion" .= ("v1" :: Text)
              , "kind" .= ("ConfigMap" :: Text)
              , "metadata" .= object
                  [ "name" .= ("nagare-nix-cache-client" :: Text)
                  , "namespace" .= ("personal" :: Text)
                  , "annotations" .= object
                      [ "nagare.dev/cache-client-template" .= ("v1" :: Text)
                      , "nagare.dev/cache-key-producer" .= resourceIdText resource
                      ]
                  ]
              , "data" .= object ["nix.conf" .= ("trusted-public-keys = ${ATTIC_PUBLIC_KEY} cache.nixos.org-1:example" :: Text)]
              ]
            native = TE.decodeUtf8 (ok (canonicalValue template))
            resolver producer
              | producer == resource = pure (Right "nagare-cache:AAAA=")
              | otherwise = pure (Left "unexpected cache output producer")
        filled <- materializeCacheKey resolver native >>= expectRight
        let observed = ok (eitherDecodeStrict (TE.encodeUtf8 filled))
        assertBool "generated key did not fill client config" ("nagare-cache:AAAA=" `T.isInfixOf` filled)
        assertBool "template placeholder escaped execution" (not ("${ATTIC_PUBLIC_KEY}" `T.isInfixOf` filled))
        assertBool "generated key was not verified as delegated data" (cacheClientDataMatches template observed)
        assertBool "client metadata projection changed" (desiredFieldsMatch (withoutCacheClientData template) observed)
        let observedState = KubernetesPresent physical "4" (Just resource) (contentDigest (TE.encodeUtf8 native))
        observeCacheClientOutput resolver (TE.encodeUtf8 native) filled observedState >>= (@?= observedState)
        wrongKey <- observeCacheClientOutput (\_ -> pure (Right "nagare-cache:BBBB=")) (TE.encodeUtf8 native) filled observedState
        assertBool "a different cache output was accepted as current" (wrongKey /= observedState)
        missing <- materializeCacheKey (\_ -> pure (Left "cache key unavailable")) native
        assertBool "missing generated key was accepted" (either (const True) (const False) missing)
    , testCase "update ownership refuses a foreign field manager" $ do
        let metadata fields = object
              [ "metadata" .= object
                  [ "uid" .= ("kubernetes-uid-1" :: Text)
                  , "resourceVersion" .= ("4" :: Text)
                  , "managedFields" .= fields
                  ]
              ]
            entry manager fields = object
              [ "manager" .= (manager :: Text)
              , "fieldsV1" .= fields
              ]
            own = entry "nagare-inventory" (object ["f:data" .= object []])
            foreignEntry = entry "another-writer" (object ["f:data" .= object []])
            status = entry "controller" (object ["f:status" .= object []])
        confirmInventoryFieldOwnership physical "4" (metadata [own, status]) @?= Right ()
        assertBool "foreign field owner accepted" (either (const True) (const False) (confirmInventoryFieldOwnership physical "4" (metadata [own, foreignEntry])))
        assertBool "stale version accepted" (either (const True) (const False) (confirmInventoryFieldOwnership physical "5" (metadata [own])))
        assertBool "missing inventory field owner accepted" (either (const True) (const False) (confirmInventoryFieldOwnership physical "4" (metadata [status])))
    , testCase "unproved Kubernetes update kind refuses before invoking kubectl" $ do
        let context = ok (mkContextId "unsupported-update")
            config = KubernetesRuntimeConfig context "missing-test-context" (pure (Right ()))
            address = Kubernetes cluster "batch" (ok (mkName "job"))
              (Just (ok (mkName "default"))) (ok (mkName "unproved"))
            digest = contentDigest "{}"
            mutation = KubernetesMutation 1 (ok (mkOperationId "op-unproved-update")) digest
              UpdateResource resource address "{}" digest
              (KubernetesPresent physical "4" (Just resource) digest)
        assertBool "unproved Job update was admitted" (not (supportedUpdateAddress address))
        result <- kubernetesMutateConditional (mkKubernetesRuntimeOps config Map.empty) mutation
        case result of
          AdapterEffectFailed (KnownNoEffect _) -> pure ()
          other -> assertFailure ("unproved update was not a known no-effect refusal: " <> show other)
    , testCase "PVC controller annotation exception is exact and kind-specific" $ do
        let address = Kubernetes cluster "" (ok (mkName "persistentvolumeclaim")) (Just (ok (mkName "default"))) (ok (mkName "data"))
            otherAddress = Kubernetes cluster "" (ok (mkName "configmap")) (Just (ok (mkName "default"))) (ok (mkName "data"))
            entry manager fields = object ["manager" .= (manager :: Text), "fieldsV1" .= fields]
            own = entry "nagare-inventory" (object ["f:spec" .= object ["f:resources" .= object []]])
            provisioner = entry "k3s" (object ["f:metadata" .= object ["f:annotations" .= object
              ["f:volume.kubernetes.io/storage-provisioner" .= object []]]])
            foreignFields = entry "k3s" (object ["f:metadata" .= object ["f:annotations" .= object
              ["f:nagare.dev/spec-digest" .= object []]]])
            observed members = object ["metadata" .= object
              ["uid" .= ("kubernetes-uid-1" :: Text), "resourceVersion" .= ("4" :: Text), "managedFields" .= members]]
        confirmInventoryFieldOwnershipFor (Just address) physical "4" (observed [own, provisioner]) @?= Right ()
        assertBool "controller-owned inventory stamp was accepted" (either (const True) (const False)
          (confirmInventoryFieldOwnershipFor (Just address) physical "4" (observed [own, foreignFields])))
        assertBool "PVC exception applied to ConfigMap" (either (const True) (const False)
          (confirmInventoryFieldOwnershipFor (Just otherAddress) physical "4" (observed [own, provisioner])))
    , testCase "Deployment controller annotation exception is exact and kind-specific" $ do
        let address = Kubernetes cluster "apps" (ok (mkName "deployment"))
              (Just (ok (mkName "default"))) (ok (mkName "deployment"))
            otherAddress = Kubernetes cluster "apps" (ok (mkName "statefulset"))
              (Just (ok (mkName "default"))) (ok (mkName "deployment"))
            entry manager fields = object ["manager" .= (manager :: Text), "fieldsV1" .= fields]
            own = entry "nagare-inventory" (object ["f:spec" .= object ["f:replicas" .= object []]])
            controllerFields = object
              [ "f:metadata" .= object ["f:annotations" .= object
                  [ "." .= object []
                  , "f:deployment.kubernetes.io/revision" .= object []
                  ]]
              , "f:status" .= object ["f:observedGeneration" .= object []]
              ]
            controller = entry "k3s" controllerFields
            foreignFields = entry "k3s" (object ["f:metadata" .= object ["f:annotations" .= object
              ["f:nagare.dev/spec-digest" .= object []]]])
            observed members = object ["metadata" .= object
              ["uid" .= ("kubernetes-uid-1" :: Text), "resourceVersion" .= ("4" :: Text), "managedFields" .= members]]
        confirmInventoryFieldOwnershipFor (Just address) physical "4" (observed [own, controller]) @?= Right ()
        assertBool "controller-owned inventory stamp was accepted" (either (const True) (const False)
          (confirmInventoryFieldOwnershipFor (Just address) physical "4" (observed [own, controller, foreignFields])))
        assertBool "Deployment exception applied to StatefulSet" (either (const True) (const False)
          (confirmInventoryFieldOwnershipFor (Just otherAddress) physical "4" (observed [own, controller])))
    , testCase "packaged source is bound once and changed source refuses review" $
        withSystemTempDirectory "nagare-kubernetes-source" $ \root -> do
          let source = SourceLocation "object.json" "#document[0]"
              sourceInput = input {sourceLocation = source}
              sourceDeclaration = fst (ok (bindKubernetesObject sourceInput))
          BS.writeFile (root </> "object.json") nativeBytes
          loaded <- loadKubernetesSources root [sourceDeclaration]
          fmap (Map.lookup resource) loaded @?= Right (Just (sourceDeclaration, nativeBytes))
          BS.writeFile (root </> "object.json") "{}"
          changed <- loadKubernetesSources root [sourceDeclaration]
          assertBool "changed packaged source accepted" (either (const True) (const False) changed)
    , testCase "private review reconstructs the native member without source files" $ do
        state <- newIORef (KubernetesAbsent absence)
        calls <- newIORef (0 :: Int)
        let binding = ContextBinding (ok (mkContextId "test")) (ok (mkName "project"))
            scopeDeclaration = ok (mkScopeDeclaration scope [ResourceBundle [Managed declaration] [] [] [] [] []])
            snapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
            candidate = ok (composeInventory snapshot (ReplaceScope scopeDeclaration :| []))
            adapter = mkKubernetesAdapter specs (ops state calls)
            registry = ok (mkAdapterRegistry [adapter])
            observations = ok (observationSet [(resource, ConfirmedAbsent absence)])
        store <- newMemoryStore
        _ <- initializeStore store binding "client-test" >>= expectRight
        history <- loadInventoryHistory store >>= expectRight
        let proposal = ok (planChanges candidate noLifecycleDecisions history observations)
        snapshotBefore <- readStoreSnapshot store >>= expectRight
        bundle <- prepareReview registry snapshotBefore proposal >>= expectRight
        kubernetesSpecsFromReview bundle @?= Right specs
    , testCase "private review deduplicates the same Job for create and migration proof" $ do
        let job = object
              [ "apiVersion" .= ("batch/v1" :: Text)
              , "kind" .= ("Job" :: Text)
              , "metadata" .= object ["name" .= ("migration" :: Text), "namespace" .= ("default" :: Text)]
              , "spec" .= object ["template" .= object ["spec" .= object
                  ["restartPolicy" .= ("Never" :: Text), "containers" .= [object ["name" .= ("job" :: Text), "image" .= ("example@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" :: Text)]]]]]
              ]
            bytes = ok (canonicalValue job)
            (jobDeclaration, _) = ok (bindKubernetesObject (input {inputObject = job, objectDigest = contentDigest bytes}))
            bound = Map.singleton resource (jobDeclaration, bytes)
            migrationId = mintResourceId scope (ok (mkLogicalKey "migration")) (ok (mkName "operation"))
            migration = DeclaredOperation migrationId (resource :| []) [] VerifyBeforeRetry SchemaMigration
            binding = ContextBinding (ok (mkContextId "test")) (ok (mkName "project"))
            scopeDeclaration = ok (mkScopeDeclaration scope [ResourceBundle [Managed jobDeclaration] [] [] [] [migration] []])
            candidate = ok (composeInventory (ok (mkScopeSnapshot binding Map.empty Map.empty)) (ReplaceScope scopeDeclaration :| []))
            observations = ok (observationSet [(resource, ConfirmedAbsent absence)])
        state <- newIORef (KubernetesAbsent absence)
        calls <- newIORef (0 :: Int)
        let registry = ok (mkAdapterRegistry [mkKubernetesAdapter bound (ops state calls)])
        store <- newMemoryStore
        _ <- initializeStore store binding "job-review-test" >>= expectRight
        history <- loadInventoryHistory store >>= expectRight
        let proposal = ok (planChanges candidate noLifecycleDecisions history observations)
        snapshotBefore <- readStoreSnapshot store >>= expectRight
        reviewed <- prepareReview registry snapshotBefore proposal >>= expectRight
        kubernetesSpecsFromReview reviewed @?= Right bound
        _ <- publishReview store reviewed >>= expectRight
        snapshotAfter <- readStoreSnapshot store >>= expectRight
        verified <- expectRight (verifyReview snapshotAfter reviewed)
        let applyOps = (ops state calls)
              { kubernetesMutateConditional = \mutation -> do
                  modifyIORef' calls (+ 1)
                  writeIORef state (KubernetesPresent physical "4" (Just resource) (mutationNativeDigest mutation))
                  pure AdapterEffectCompleted
              }
            fromReview = ok (mkAdapterRegistry [mkKubernetesAdapter (ok (kubernetesSpecsFromReview reviewed)) applyOps])
        result <- applyReviewed store fromReview verified >>= expectRight
        case result of Converged _ -> pure (); other -> assertFailure (show other)
        readIORef calls >>= (@?= 1)
    , testCase "disposable cluster creates and conditionally updates a reviewed object" $ do
        selected <- lookupEnv "NAGARE_EP147_TEST_CONTEXT"
        case selected of
          Nothing -> pure ()
          Just selectedContext -> do
            assertBool "refusing a non-disposable Kubernetes context" ("k3d-nagare-inventory-" `T.isPrefixOf` T.pack selectedContext)
            let value = object
                  [ "apiVersion" .= ("v1" :: Text)
                  , "kind" .= ("ConfigMap" :: Text)
                  , "metadata" .= object ["name" .= ("nagare-ep147-runtime" :: Text), "namespace" .= ("default" :: Text)]
                  , "data" .= object ["message" .= ("reviewed" :: Text)]
                  ]
                bytes = ok (canonicalValue value)
                native = ok (bindKubernetesObject (input {inputObject = value, objectDigest = contentDigest bytes}))
                bound = Map.singleton resource native
                config = KubernetesRuntimeConfig (ok (mkContextId "test")) (T.pack selectedContext) (pure (Right ()))
                adapter = mkKubernetesAdapter bound (mkKubernetesRuntimeOps config bound)
                changedValue = object
                  [ "apiVersion" .= ("v1" :: Text)
                  , "kind" .= ("ConfigMap" :: Text)
                  , "metadata" .= object ["name" .= ("nagare-ep147-runtime" :: Text), "namespace" .= ("default" :: Text)]
                  , "data" .= object ["message" .= ("updated" :: Text)]
                  ]
                changedBytes = ok (canonicalValue changedValue)
                changedNative = ok (bindKubernetesObject (input {inputObject = changedValue, objectDigest = contentDigest changedBytes}))
                changedBound = Map.singleton resource changedNative
                changedAdapter = mkKubernetesAdapter changedBound (mkKubernetesRuntimeOps config changedBound)
                finalValue = object
                  [ "apiVersion" .= ("v1" :: Text)
                  , "kind" .= ("ConfigMap" :: Text)
                  , "metadata" .= object ["name" .= ("nagare-ep147-runtime" :: Text), "namespace" .= ("default" :: Text)]
                  , "data" .= object ["message" .= ("final" :: Text)]
                  ]
                finalBytes = ok (canonicalValue finalValue)
                finalNative = ok (bindKubernetesObject (input {inputObject = finalValue, objectDigest = contentDigest finalBytes}))
                finalBound = Map.singleton resource finalNative
                finalOps = mkKubernetesRuntimeOps config finalBound
                finalAdapter = mkKubernetesAdapter finalBound finalOps
                cleanup = do
                  _ <- readProcessWithExitCode "kubectl" ["--context", selectedContext, "delete", "configmap", "nagare-ep147-runtime", "--namespace", "default", "--ignore-not-found"] ""
                  pure ()
            cleanup
            (do
              prepared <- adapterPrepare adapter createOperation >>= expectRight
              adapterPreflight adapter createOperation prepared >>= expectRight
              adapterExecute adapter createOperation prepared >>= (@?= AdapterEffectCompleted)
              _ <- adapterVerify adapter createOperation prepared >>= expectRight
              updatePrepared <- adapterPrepare changedAdapter updateOperation >>= expectRight
              adapterPreflight changedAdapter updateOperation updatePrepared >>= expectRight
              adapterExecute changedAdapter updateOperation updatePrepared >>= (@?= AdapterEffectCompleted)
              _ <- adapterVerify changedAdapter updateOperation updatePrepared >>= expectRight
              stalePrepared <- adapterPrepare finalAdapter updateOperation >>= expectRight
              let staleMutation = ok (eitherDecodeStrict (preparedNativeBytes stalePrepared)) :: KubernetesMutation
              (annotateCode, _, _) <- readProcessWithExitCode "kubectl"
                ["--context", selectedContext, "annotate", "configmap", "nagare-ep147-runtime", "--namespace", "default", "probe=foreign", "--field-manager=foreign-probe"] ""
              annotateCode @?= ExitSuccess
              staleResult <- kubernetesMutateConditional finalOps staleMutation
              case staleResult of
                AdapterEffectFailed (KnownNoEffect _) -> pure ()
                other -> assertFailure ("stale or foreign update changed the object: " <> show other)
              foreignPrepared <- adapterPrepare finalAdapter updateOperation >>= expectRight
              let foreignMutation = ok (eitherDecodeStrict (preparedNativeBytes foreignPrepared)) :: KubernetesMutation
              foreignResult <- kubernetesMutateConditional finalOps foreignMutation
              case foreignResult of
                AdapterEffectFailed (KnownNoEffect _) -> pure ()
                other -> assertFailure ("foreign field manager was overridden: " <> show other)
              pure ()) `finally` cleanup
    , testCase "disposable reviewed transaction refuses a foreign create after publication" $ do
        selected <- lookupEnv "NAGARE_EP147_TEST_CONTEXT"
        case selected of
          Nothing -> pure ()
          Just selectedContext -> do
            assertBool "refusing a non-disposable Kubernetes context"
              ("k3d-nagare-inventory-" `T.isPrefixOf` T.pack selectedContext)
            let targetObject = object
                  [ "apiVersion" .= ("v1" :: Text)
                  , "kind" .= ("ConfigMap" :: Text)
                  , "metadata" .= object ["name" .= ("nagare-ep147-foreign" :: Text),
                      "namespace" .= ("default" :: Text)]
                  , "data" .= object ["message" .= ("reviewed" :: Text)]
                  ]
                boundBytes = ok (canonicalValue targetObject)
                bound = Map.singleton resource (ok (bindKubernetesObject
                  (input {inputObject = targetObject, objectDigest = contentDigest boundBytes})))
                target = ok (mkScopeDeclaration scope
                  [ResourceBundle [Managed (fst (bound Map.! resource))] [] [] [] [] []])
                binding = ContextBinding (ok (mkContextId "test")) (ok (mkName "project"))
                snapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
                candidate = ok (composeInventory snapshot (ReplaceScope target :| []))
                config = KubernetesRuntimeConfig (ok (mkContextId "test"))
                  (T.pack selectedContext) (pure (Right ()))
                registry = ok (mkAdapterRegistry
                  [mkKubernetesAdapter bound (mkKubernetesRuntimeOps config bound)])
                cleanup = do
                  _ <- readProcessWithExitCode "kubectl"
                    ["--context", selectedContext, "delete", "configmap", "nagare-ep147-foreign",
                     "--namespace", "default", "--ignore-not-found"] ""
                  pure ()
            cleanup
            (do
              store <- newMemoryStore
              _ <- initializeStore store binding "client-test" >>= expectRight
              history <- loadInventoryHistory store >>= expectRight
              observed <- observeWithRegistry registry
                (requirementsByExecutor (observationRequirements candidate history)) >>= expectRight
              let proposal = ok (planChanges candidate noLifecycleDecisions history observed)
              before <- readStoreSnapshot store >>= expectRight
              reviewBundle <- prepareReview registry before proposal >>= expectRight
              _ <- publishReview store reviewBundle >>= expectRight
              (created, _, _) <- readProcessWithExitCode "kubectl"
                ["--context", selectedContext, "create", "configmap", "nagare-ep147-foreign",
                 "--namespace", "default", "--from-literal=message=foreign"] ""
              created @?= ExitSuccess
              afterPublication <- readStoreSnapshot store >>= expectRight
              reviewed <- expectRight (verifyReview afterPublication reviewBundle)
              result <- applyReviewed store registry reviewed
              case result of
                Left errors | any ((== "preflight") . (^. #admissionErrorCode)) errors -> pure ()
                other -> assertFailure ("foreign object was accepted: " <> show other)
              (readCode, live, _) <- readProcessWithExitCode "kubectl"
                ["--context", selectedContext, "get", "configmap", "nagare-ep147-foreign",
                 "--namespace", "default", "-o", "jsonpath={.data.message}"] ""
              readCode @?= ExitSuccess
              live @?= "foreign") `finally` cleanup
    , testCase "disposable reviewed transaction refuses a stale update after publication" $ do
        selected <- lookupEnv "NAGARE_EP147_TEST_CONTEXT"
        case selected of
          Nothing -> pure ()
          Just selectedContext -> do
            assertBool "refusing a non-disposable Kubernetes context"
              ("k3d-nagare-inventory-" `T.isPrefixOf` T.pack selectedContext)
            let configMap message = object
                  [ "apiVersion" .= ("v1" :: Text)
                  , "kind" .= ("ConfigMap" :: Text)
                  , "metadata" .= object ["name" .= ("nagare-ep147-stale" :: Text),
                      "namespace" .= ("default" :: Text)]
                  , "data" .= object ["message" .= (message :: Text)]
                  ]
                bound message = let value = configMap message
                                    bytes = ok (canonicalValue value)
                                 in Map.singleton resource (ok (bindKubernetesObject
                                      (input {inputObject = value, objectDigest = contentDigest bytes})))
                target members = ok (mkScopeDeclaration scope
                  [ResourceBundle [Managed (fst (members Map.! resource))] [] [] [] [] []])
                binding = ContextBinding (ok (mkContextId "test")) (ok (mkName "project"))
                config = KubernetesRuntimeConfig (ok (mkContextId "test"))
                  (T.pack selectedContext) (pure (Right ()))
                registry members = ok (mkAdapterRegistry
                  [mkKubernetesAdapter members (mkKubernetesRuntimeOps config members)])
                cleanup = do
                  _ <- readProcessWithExitCode "kubectl"
                    ["--context", selectedContext, "delete", "configmap", "nagare-ep147-stale",
                     "--namespace", "default", "--ignore-not-found"] ""
                  pure ()
            cleanup
            (do
              store <- newMemoryStore
              _ <- initializeStore store binding "client-test" >>= expectRight
              let initial = bound "initial"
                  initialCandidate = ok (composeInventory
                    (ok (mkScopeSnapshot binding Map.empty Map.empty)) (ReplaceScope (target initial) :| []))
              initialHistory <- loadInventoryHistory store >>= expectRight
              initialObservation <- observeWithRegistry (registry initial)
                (requirementsByExecutor (observationRequirements initialCandidate initialHistory)) >>= expectRight
              let initialProposal = ok (planChanges initialCandidate noLifecycleDecisions initialHistory initialObservation)
              initialSnapshot <- readStoreSnapshot store >>= expectRight
              initialReview <- prepareReview (registry initial) initialSnapshot initialProposal >>= expectRight
              _ <- publishReview store initialReview >>= expectRight
              createdSnapshot <- readStoreSnapshot store >>= expectRight
              createdReview <- expectRight (verifyReview createdSnapshot initialReview)
              _ <- applyReviewed store (registry initial) createdReview >>= expectRight
              history <- loadInventoryHistory store >>= expectRight
              let accepted = Map.map (\(revision, scoped) -> (revisionGeneration revision, scoped))
                    (historyAccepted history)
                  next = bound "updated"
                  nextCandidate = ok (composeInventory
                    (ok (mkScopeSnapshot binding accepted Map.empty)) (ReplaceScope (target next) :| []))
              observed <- observeWithRegistry (registry next)
                (requirementsByExecutor (observationRequirements nextCandidate history)) >>= expectRight
              let proposal = ok (planChanges nextCandidate noLifecycleDecisions history observed)
              before <- readStoreSnapshot store >>= expectRight
              reviewBundle <- prepareReview (registry next) before proposal >>= expectRight
              _ <- publishReview store reviewBundle >>= expectRight
              (changed, _, _) <- readProcessWithExitCode "kubectl"
                ["--context", selectedContext, "annotate", "configmap", "nagare-ep147-stale",
                 "--namespace", "default", "probe=concurrent", "--field-manager=nagare-inventory"] ""
              changed @?= ExitSuccess
              afterPublication <- readStoreSnapshot store >>= expectRight
              reviewed <- expectRight (verifyReview afterPublication reviewBundle)
              result <- applyReviewed store (registry next) reviewed
              case result of
                Left errors | any ((== "preflight") . (^. #admissionErrorCode)) errors -> pure ()
                other -> assertFailure ("stale update was accepted: " <> show other)
              (readCode, live, _) <- readProcessWithExitCode "kubectl"
                ["--context", selectedContext, "get", "configmap", "nagare-ep147-stale",
                 "--namespace", "default", "-o", "jsonpath={.data.message}:{.metadata.annotations.probe}"] ""
              readCode @?= ExitSuccess
              live @?= "initial:concurrent") `finally` cleanup
    , testCase "disposable cluster updates a reviewed Namespace label" $ do
        selected <- lookupEnv "NAGARE_EP147_TEST_CONTEXT"
        case selected of
          Nothing -> pure ()
          Just selectedContext -> do
            assertBool "refusing a non-disposable Kubernetes context" ("k3d-nagare-inventory-" `T.isPrefixOf` T.pack selectedContext)
            let namespaceValue label = object
                  [ "apiVersion" .= ("v1" :: Text)
                  , "kind" .= ("Namespace" :: Text)
                  , "metadata" .= object
                      [ "name" .= ("nagare-ep147-foundation" :: Text)
                      , "labels" .= object ["nagare.dev/app-namespace" .= (label :: Text)]
                      ]
                  ]
                config = KubernetesRuntimeConfig (ok (mkContextId "test")) (T.pack selectedContext) (pure (Right ()))
                bound label = let value = namespaceValue label
                                  bytes = ok (canonicalValue value)
                               in Map.singleton resource (ok (bindKubernetesObject
                                    (input {inputObject = value, objectDigest = contentDigest bytes})))
                initial = bound "false"
                changed = bound "true"
                createAdapter = mkKubernetesAdapter initial (mkKubernetesRuntimeOps config initial)
                updateAdapter = mkKubernetesAdapter changed (mkKubernetesRuntimeOps config changed)
                cleanup = do
                  _ <- readProcessWithExitCode "kubectl" ["--context", selectedContext,
                    "delete", "namespace", "nagare-ep147-foundation", "--ignore-not-found", "--wait=true"] ""
                  pure ()
            cleanup
            (do
              prepared <- adapterPrepare createAdapter createOperation >>= expectRight
              adapterPreflight createAdapter createOperation prepared >>= expectRight
              adapterExecute createAdapter createOperation prepared >>= (@?= AdapterEffectCompleted)
              _ <- adapterVerify createAdapter createOperation prepared >>= expectRight
              changedPrepared <- adapterPrepare updateAdapter updateOperation >>= expectRight
              adapterPreflight updateAdapter updateOperation changedPrepared >>= expectRight
              adapterExecute updateAdapter updateOperation changedPrepared >>= (@?= AdapterEffectCompleted)
              _ <- adapterVerify updateAdapter updateOperation changedPrepared >>= expectRight
              pure ()) `finally` cleanup
    , testCase "disposable cluster updates a reviewed Service selector and unnamed port" $ do
        selected <- lookupEnv "NAGARE_EP147_TEST_CONTEXT"
        case selected of
          Nothing -> pure ()
          Just selectedContext -> do
            assertBool "refusing a non-disposable Kubernetes context" ("k3d-nagare-inventory-" `T.isPrefixOf` T.pack selectedContext)
            let service selectorValue port = object
                  [ "apiVersion" .= ("v1" :: Text)
                  , "kind" .= ("Service" :: Text)
                  , "metadata" .= object ["name" .= ("nagare-ep147-service" :: Text), "namespace" .= ("default" :: Text)]
                  , "spec" .= object ["ports" .= [object ["port" .= (port :: Int), "targetPort" .= (8080 :: Int)]], "selector" .= object ["app" .= (selectorValue :: Text)]]
                  ]
                mkBound selectorValue port =
                  let value = service selectorValue port
                      bytes = ok (canonicalValue value)
                   in Map.singleton resource (ok (bindKubernetesObject (input {inputObject = value, objectDigest = contentDigest bytes})))
                config = KubernetesRuntimeConfig (ok (mkContextId "test")) (T.pack selectedContext) (pure (Right ()))
                adapter selectorValue port = let bound = mkBound selectorValue port in mkKubernetesAdapter bound (mkKubernetesRuntimeOps config bound)
                cleanup = do
                  _ <- readProcessWithExitCode "kubectl" ["--context", selectedContext, "delete", "service", "nagare-ep147-service", "--namespace", "default", "--ignore-not-found"] ""
                  pure ()
            cleanup
            (do
              let initial = adapter "ep147" 8080
                  changed = adapter "ep147-next" 8080
                  portChanged = adapter "ep147-next" 8081
              created <- adapterPrepare initial createOperation >>= expectRight
              adapterExecute initial createOperation created >>= (@?= AdapterEffectCompleted)
              _ <- adapterVerify initial createOperation created >>= expectRight
              updated <- adapterPrepare changed updateOperation >>= expectRight
              adapterExecute changed updateOperation updated >>= (@?= AdapterEffectCompleted)
              _ <- adapterVerify changed updateOperation updated >>= expectRight
              portPrepared <- adapterPrepare portChanged updateOperation >>= expectRight
              adapterExecute portChanged updateOperation portPrepared >>= (@?= AdapterEffectCompleted)
              _ <- adapterVerify portChanged updateOperation portPrepared >>= expectRight
              pure ()) `finally` cleanup
    , testCase "disposable cluster conditionally updates a reviewed Deployment" $ do
        selected <- lookupEnv "NAGARE_EP147_TEST_CONTEXT"
        case selected of
          Nothing -> pure ()
          Just selectedContext -> do
            assertBool "refusing a non-disposable Kubernetes context"
              ("k3d-nagare-inventory-" `T.isPrefixOf` T.pack selectedContext)
            let deployment revision = object
                  [ "apiVersion" .= ("apps/v1" :: Text)
                  , "kind" .= ("Deployment" :: Text)
                  , "metadata" .= object
                      [ "name" .= ("nagare-ep147-deployment" :: Text)
                      , "namespace" .= ("default" :: Text)
                      , "annotations" .= object ["nagare.dev/test-revision" .= (revision :: Text)]
                      ]
                  , "spec" .= object
                      [ "replicas" .= (0 :: Int)
                      , "selector" .= object ["matchLabels" .= object ["app" .= ("nagare-ep147-deployment" :: Text)]]
                      , "template" .= object
                          [ "metadata" .= object ["labels" .= object ["app" .= ("nagare-ep147-deployment" :: Text)]]
                          , "spec" .= object ["containers" .= [object
                              [ "name" .= ("pause" :: Text)
                              , "image" .= ("registry.k8s.io/pause:3.9" :: Text)
                              ]]]
                          ]
                      ]
                  ]
                mkBound revision = let value = deployment revision
                                       bytes = ok (canonicalValue value)
                                    in Map.singleton resource (ok (bindKubernetesObject
                                         (input {inputObject = value, objectDigest = contentDigest bytes})))
                config = KubernetesRuntimeConfig (ok (mkContextId "test")) (T.pack selectedContext) (pure (Right ()))
                adapter revision = let bound = mkBound revision in mkKubernetesAdapter bound (mkKubernetesRuntimeOps config bound)
                cleanup = do
                  _ <- readProcessWithExitCode "kubectl" ["--context", selectedContext,
                    "delete", "deployment", "nagare-ep147-deployment", "--namespace", "default", "--ignore-not-found"] ""
                  pure ()
            cleanup
            (do
              let initial = adapter "initial"
                  changed = adapter "changed"
              created <- adapterPrepare initial createOperation >>= expectRight
              adapterExecute initial createOperation created >>= (@?= AdapterEffectCompleted)
              _ <- adapterVerify initial createOperation created >>= expectRight
              updated <- adapterPrepare changed updateOperation >>= expectRight
              adapterPreflight changed updateOperation updated >>= expectRight
              adapterExecute changed updateOperation updated >>= (@?= AdapterEffectCompleted)
              _ <- adapterVerify changed updateOperation updated >>= expectRight
              pure ()) `finally` cleanup
    , testCase "disposable cluster conditionally updates a reviewed Secret" $ do
        selected <- lookupEnv "NAGARE_EP147_TEST_CONTEXT"
        case selected of
          Nothing -> pure ()
          Just selectedContext -> do
            assertBool "refusing a non-disposable Kubernetes context"
              ("k3d-nagare-inventory-" `T.isPrefixOf` T.pack selectedContext)
            let secret payload = object
                  [ "apiVersion" .= ("v1" :: Text)
                  , "kind" .= ("Secret" :: Text)
                  , "metadata" .= object ["name" .= ("nagare-ep147-secret" :: Text),
                      "namespace" .= ("default" :: Text)]
                  , "type" .= ("Opaque" :: Text)
                  , "data" .= object ["value" .= (payload :: Text)]
                  ]
                mkBound payload = let value = secret payload
                                      bytes = ok (canonicalValue value)
                                   in Map.singleton resource (ok (bindKubernetesObject
                                        (input {inputObject = value, objectDigest = contentDigest bytes,
                                          inputSensitivity = Secret})))
                config = KubernetesRuntimeConfig (ok (mkContextId "test")) (T.pack selectedContext) (pure (Right ()))
                adapter payload = let bound = mkBound payload in mkKubernetesAdapter bound (mkKubernetesRuntimeOps config bound)
                cleanup = do
                  _ <- readProcessWithExitCode "kubectl" ["--context", selectedContext,
                    "delete", "secret", "nagare-ep147-secret", "--namespace", "default", "--ignore-not-found"] ""
                  pure ()
            cleanup
            (do
              let initial = adapter "aGVsbG8="
                  changed = adapter "d29ybGQ="
              created <- adapterPrepare initial createOperation >>= expectRight
              adapterExecute initial createOperation created >>= (@?= AdapterEffectCompleted)
              _ <- adapterVerify initial createOperation created >>= expectRight
              updated <- adapterPrepare changed updateOperation >>= expectRight
              adapterPreflight changed updateOperation updated >>= expectRight
              adapterExecute changed updateOperation updated >>= (@?= AdapterEffectCompleted)
              _ <- adapterVerify changed updateOperation updated >>= expectRight
              (readCode, live, _) <- readProcessWithExitCode "kubectl"
                ["--context", selectedContext, "get", "secret", "nagare-ep147-secret",
                 "--namespace", "default", "-o", "jsonpath={.data.value}"] ""
              readCode @?= ExitSuccess
              live @?= "d29ybGQ=") `finally` cleanup
    , testCase "disposable cluster creates a database credential and reviewed backup CronJob" $ do
        selected <- lookupEnv "NAGARE_EP147_TEST_CONTEXT"
        case selected of
          Nothing -> pure ()
          Just selectedContext -> do
            assertBool "refusing a non-disposable Kubernetes context" ("k3d-nagare-inventory-" `T.isPrefixOf` T.pack selectedContext)
            let db = Database (ok (mkDatabaseName "ep147-credential")) Nothing Postgres (defaultEngineVersion Postgres)
                  (ok (Dsl.mkNamespace "default")) (ok (Dsl.mkQuantity "1Gi")) Nothing Dsl.Retain
                recovery = RecoveryIntent (ok (mkName "backup")) (mkSecretRef (ok (mkName "db-password")) (ok (mkName "v1")) :| [])
                (bundle, bound) = ok (compileDatabaseForBackend (DatabaseDirectInput db scope cluster Nothing recovery (SourceLocation "database" "postgres")) (GcsBackend "project" "bucket"))
                credentialId = ok (databaseResourceId scope (ok (mkName "credential")) db)
                backupId = ok (databaseResourceId scope (ok (mkName "backup")) db)
                credential = maybe (error "database bundle lacks credential") id (Map.lookup credentialId bound)
                backup = maybe (error "database bundle lacks backup CronJob") id (Map.lookup backupId bound)
                onlyCredential = Map.singleton credentialId credential
                onlyBackup = Map.singleton backupId backup
                config = KubernetesRuntimeConfig (ok (mkContextId "test")) (T.pack selectedContext) (pure (Right ()))
                adapter = mkKubernetesAdapter onlyCredential (mkKubernetesRuntimeOps config onlyCredential)
                backupAdapter = mkKubernetesAdapter onlyBackup (mkKubernetesRuntimeOps config onlyBackup)
                createCredential = createOperation {plannedResources = credentialId :| []}
                createBackup = createOperation {plannedResources = backupId :| []}
                cleanup = do
                  _ <- readProcessWithExitCode "kubectl" ["--context", selectedContext, "delete", "secret", "nagare-db-ep147-credential", "--namespace", "default", "--ignore-not-found"] ""
                  _ <- readProcessWithExitCode "kubectl" ["--context", selectedContext, "delete", "cronjob", "nagare-dbbackup-ep147-credential", "--namespace", "default", "--ignore-not-found"] ""
                  pure ()
            assertBool "credential declaration absent" (any (\case Managed member -> member ^. #identity == credentialId; _ -> False) (declarations bundle))
            cleanup
            (do
              prepared <- adapterPrepare adapter createCredential >>= expectRight
              assertBool "credential material appeared in public summary" (not ("POSTGRES_PASSWORD" `T.isInfixOf` preparedPublicSummary prepared))
              adapterExecute adapter createCredential prepared >>= (@?= AdapterEffectCompleted)
              _ <- adapterVerify adapter createCredential prepared >>= expectRight
              backupPrepared <- adapterPrepare backupAdapter createBackup >>= expectRight
              adapterExecute backupAdapter createBackup backupPrepared >>= (@?= AdapterEffectCompleted)
              _ <- adapterVerify backupAdapter createBackup backupPrepared >>= expectRight
              pure ()) `finally` cleanup
    , testCase "disposable cluster applies the complete reviewed database bundle" $ do
        selected <- lookupEnv "NAGARE_EP147_TEST_CONTEXT"
        case selected of
          Nothing -> pure ()
          Just selectedContext -> do
            assertBool "refusing a non-disposable Kubernetes context" ("k3d-nagare-inventory-" `T.isPrefixOf` T.pack selectedContext)
            let db = Database (ok (mkDatabaseName "ep147-full")) Nothing Postgres (defaultEngineVersion Postgres)
                  (ok (Dsl.mkNamespace "default")) (ok (Dsl.mkQuantity "1Gi")) Nothing Dsl.Retain
                recovery = RecoveryIntent (ok (mkName "backup")) (mkSecretRef (ok (mkName "db-password")) (ok (mkName "v1")) :| [])
                (bundle, bound) = ok (compileDatabaseForBackend (DatabaseDirectInput db scope cluster Nothing recovery (SourceLocation "database" "postgres")) (GcsBackend "project" "bucket"))
                binding = ContextBinding (ok (mkContextId "test")) (ok (mkName "project"))
                scopeDeclaration = ok (mkScopeDeclaration scope [bundle])
                candidate = ok (composeInventory (ok (mkScopeSnapshot binding Map.empty Map.empty)) (ReplaceScope scopeDeclaration :| []))
                config = KubernetesRuntimeConfig (ok (mkContextId "test")) (T.pack selectedContext) (pure (Right ()))
                credentialId = ok (databaseResourceId scope (ok (mkName "credential")) db)
                statefulId = ok (databaseResourceId scope (ok (mkName "statefulset")) db)
                cleanup = do
                  mapM_ (\(kind, name) -> do
                    _ <- readProcessWithExitCode "kubectl" ["--context", selectedContext, "delete", kind, name, "--namespace", "default", "--ignore-not-found", "--wait=false"] ""
                    pure ())
                    [ ("statefulset", "ep147-full")
                    , ("service", "ep147-full")
                    , ("pvc", "nagare-db-ep147-full-data")
                    , ("secret", "nagare-db-ep147-full")
                    , ("cronjob", "nagare-dbbackup-ep147-full")
                    ]
            cleanup
            (do
              calls <- newIORef Map.empty
              interrupted <- newIORef False
              let makeRegistry retained =
                    let nativeOps = mkKubernetesRuntimeOps config retained
                        guardedOps = nativeOps
                          { kubernetesMutateConditional = \mutation -> do
                              modifyIORef' calls (Map.insertWith (+) (mutationResource mutation) (1 :: Int))
                              effect <- kubernetesMutateConditional nativeOps mutation
                              alreadyInterrupted <- readIORef interrupted
                              if mutationResource mutation == statefulId && effect == AdapterEffectCompleted && not alreadyInterrupted
                                then writeIORef interrupted True >> pure (AdapterEffectAmbiguous "simulated lost acknowledgement")
                                else pure effect
                          }
                     in ok (mkAdapterRegistry [mkKubernetesAdapter retained guardedOps])
                  registry = makeRegistry bound
              store <- newMemoryStore
              _ <- initializeStore store binding "client-test" >>= expectRight
              history <- loadInventoryHistory store >>= expectRight
              let requirements = observationRequirements candidate history
              observed <- observeWithRegistry registry (requirementsByExecutor requirements) >>= expectRight
              let proposal = ok (planChanges candidate noLifecycleDecisions history observed)
              snapshotBefore <- readStoreSnapshot store >>= expectRight
              reviewBundle <- prepareReview registry snapshotBefore proposal >>= expectRight
              kubernetesSpecsFromReview reviewBundle @?= Right bound
              let registryFromReview = makeRegistry (ok (kubernetesSpecsFromReview reviewBundle))
              _ <- publishReview store reviewBundle >>= expectRight
              snapshotAfter <- readStoreSnapshot store >>= expectRight
              reviewed <- expectRight (verifyReview snapshotAfter reviewBundle)
              result <- applyReviewed store registryFromReview reviewed >>= expectRight
              transaction <- case result of
                StoppedAmbiguous token _ -> pure token
                other -> assertFailure ("database component did not pause after the lost acknowledgement: " <> show other)
              resumed <- resumeTransaction store registryFromReview transaction >>= expectRight
              resumed @?= Converged transaction
              counts <- readIORef calls
              Map.lookup credentialId counts @?= Just 1
              Map.lookup statefulId counts @?= Just 1
              let (statefulDeclaration, statefulBytes) = maybe (error "database bundle lacks StatefulSet") id (Map.lookup statefulId bound)
                  annotated = addProbeAnnotation (ok (eitherDecodeStrict statefulBytes))
                  annotatedBytes = ok (canonicalValue annotated)
                  annotatedInput = KubernetesInput statefulId scope cluster annotated (contentDigest annotatedBytes)
                    (statefulDeclaration ^. #lifecycle) (statefulDeclaration ^. #dataPolicy)
                    (statefulDeclaration ^. #sensitivity) (statefulDeclaration ^. #source)
                  annotatedBound = Map.singleton statefulId (ok (bindKubernetesObject annotatedInput))
                  annotatedAdapter = mkKubernetesAdapter annotatedBound (mkKubernetesRuntimeOps config annotatedBound)
                  statefulUpdate = updateOperation {plannedResources = statefulId :| []}
              updatePrepared <- adapterPrepare annotatedAdapter statefulUpdate >>= expectRight
              adapterExecute annotatedAdapter statefulUpdate updatePrepared >>= (@?= AdapterEffectCompleted)
              _ <- adapterVerify annotatedAdapter statefulUpdate updatePrepared >>= expectRight
              mapM_ (\role -> do
                let memberId = ok (databaseResourceId scope (ok (mkName role)) db)
                    (memberDeclaration, memberBytes) = maybe (error "database bundle lacks update member") id (Map.lookup memberId bound)
                    updatedValue = addProbeAnnotation (ok (eitherDecodeStrict memberBytes))
                    updatedBytes = ok (canonicalValue updatedValue)
                    updatedInput = KubernetesInput memberId scope cluster updatedValue (contentDigest updatedBytes)
                      (memberDeclaration ^. #lifecycle) (memberDeclaration ^. #dataPolicy)
                      (memberDeclaration ^. #sensitivity) (memberDeclaration ^. #source)
                    updatedBound = Map.singleton memberId (ok (bindKubernetesObject updatedInput))
                    updatedAdapter = mkKubernetesAdapter updatedBound (mkKubernetesRuntimeOps config updatedBound)
                    memberUpdate = updateOperation {plannedResources = memberId :| []}
                prepared <- adapterPrepare updatedAdapter memberUpdate >>= expectRight
                adapterExecute updatedAdapter memberUpdate prepared >>= (@?= AdapterEffectCompleted)
                _ <- adapterVerify updatedAdapter memberUpdate prepared >>= expectRight
                pure ()) ["pvc", "backup"]
              pure ()
              ) `finally` cleanup
    ]

addProbeAnnotation :: Value -> Value
addProbeAnnotation (Object root) = case KM.lookup "metadata" root of
  Just (Object metadata) ->
    let annotations = case KM.lookup "annotations" metadata of
          Just (Object existing) -> existing
          _ -> KM.empty
        updated = Object (KM.insert "annotations" (Object (KM.insert "nagare.dev/ep147-probe" (String "updated") annotations)) metadata)
     in Object (KM.insert "metadata" updated root)
  _ -> error "StatefulSet has no metadata"
addProbeAnnotation _ = error "StatefulSet is not an object"

ops :: IORef KubernetesState -> IORef Int -> KubernetesAdapterOps
ops state calls =
  KubernetesAdapterOps
    { kubernetesContext = ok (mkContextId "test")
    , kubernetesObserve = \_ -> readIORef state
    , kubernetesMutateConditional = \mutation -> do
        current <- readIORef state
        if current /= mutationBefore mutation
          then pure (AdapterEffectFailed (KnownNoEffect "conditional write conflict"))
          else do
            modifyIORef' calls (+ 1)
            writeIORef state (KubernetesPresent physical "5" (Just resource) (mutationNativeDigest mutation))
            pure AdapterEffectCompleted
    }

createOperation, updateOperation :: PlannedOperation
createOperation = operation CreateResource
updateOperation = operation UpdateResource

operation :: OperationAction -> PlannedOperation
operation action =
  PlannedOperation
    { plannedOperationId = ok (mkOperationId (if action == CreateResource then "op-kubernetes-create" else "op-kubernetes-update"))
    , plannedAction = action
    , plannedExecutor = KubernetesExecutor
    , plannedResources = resource :| []
    , plannedInputDigest = contentDigest "declaration"
    , plannedDependencies = []
    , plannedRecovery = VerifyBeforeRetry
    }

scope :: ScopeId
scope = ok (mkScopeId Platform "foundation")

resource, cluster :: ResourceId
resource = mintResourceId scope (ok (mkLogicalKey "service")) (ok (mkName "resource"))
cluster = mintResourceId scope (ok (mkLogicalKey "cluster")) (ok (mkName "resource"))

nativeObject :: Value
nativeObject =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("Service" :: Text)
    , "metadata" .= object ["name" .= ("cache" :: Text), "namespace" .= ("personal" :: Text)]
    ]

nativeBytes :: ByteString
nativeBytes = ok (canonicalValue nativeObject)

nativeText :: Text
nativeText = TE.decodeUtf8 nativeBytes

declaration :: ManagedResource
declaration = fst (ok (bindKubernetesObject input))

input :: KubernetesInput
input = KubernetesInput resource scope cluster nativeObject (contentDigest nativeBytes) Retain Stateless Private (SourceLocation "fixture.yaml" "document[0]")

specs :: Map.Map ResourceId (ManagedResource, ByteString)
specs = Map.singleton resource (ok (bindKubernetesObject input))

physical :: PhysicalIdentity
physical = ok (mkPhysicalIdentity "kubernetes-uid-1")

absence :: ContentDigest
absence = contentDigest "absence"

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (assertFailure . show) pure

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
