module InventoryKubernetesSpec (inventoryKubernetesTests) where

import Control.Exception (finally)
import Data.Aeson (Value, eitherDecodeStrict, object, (.=))
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
import Nagare.Inventory.Adapters.KubernetesRuntime (KubernetesRuntimeConfig (..), confirmInventoryFieldOwnership, desiredFieldsMatch, mkKubernetesRuntimeOps)
import Nagare.Inventory.Database (compileDatabaseForBackend, compileDatabaseNative, compileDatabaseNativeWithBackup)
import Nagare.Inventory.Digest
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
            direct = DatabaseDirectInput db scope cluster recovery (SourceLocation "database" "postgres")
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
            direct = DatabaseDirectInput db scope cluster recovery (SourceLocation "database" "postgres")
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
                AdapterEffectAmbiguous {} -> pure ()
                other -> assertFailure ("stale or foreign update changed the object: " <> show other)
              foreignPrepared <- adapterPrepare finalAdapter updateOperation >>= expectRight
              let foreignMutation = ok (eitherDecodeStrict (preparedNativeBytes foreignPrepared)) :: KubernetesMutation
              foreignResult <- kubernetesMutateConditional finalOps foreignMutation
              case foreignResult of
                AdapterEffectAmbiguous {} -> pure ()
                other -> assertFailure ("foreign field manager was overridden: " <> show other)
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
    , testCase "disposable cluster creates a database credential and reviewed backup CronJob" $ do
        selected <- lookupEnv "NAGARE_EP147_TEST_CONTEXT"
        case selected of
          Nothing -> pure ()
          Just selectedContext -> do
            assertBool "refusing a non-disposable Kubernetes context" ("k3d-nagare-inventory-" `T.isPrefixOf` T.pack selectedContext)
            let db = Database (ok (mkDatabaseName "ep147-credential")) Nothing Postgres (defaultEngineVersion Postgres)
                  (ok (Dsl.mkNamespace "default")) (ok (Dsl.mkQuantity "1Gi")) Nothing Dsl.Retain
                recovery = RecoveryIntent (ok (mkName "backup")) (mkSecretRef (ok (mkName "db-password")) (ok (mkName "v1")) :| [])
                (bundle, bound) = ok (compileDatabaseForBackend (DatabaseDirectInput db scope cluster recovery (SourceLocation "database" "postgres")) (GcsBackend "project" "bucket"))
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
    ]

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
