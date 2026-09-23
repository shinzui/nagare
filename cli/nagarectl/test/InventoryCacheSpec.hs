module InventoryCacheSpec (inventoryCacheTests) where

import Control.Monad (forM_, when)
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Dsl.Database (Database (Database), Engine (Postgres), defaultEngineVersion, mkDatabaseName)
import Nagare.Dsl.Types qualified as Dsl
import Data.ByteString.Char8 qualified as BC
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Cache
import Nagare.Inventory.Adapters.CacheRuntime
import Nagare.Inventory.Cache
import Nagare.Inventory.Bootstrap (BootstrapInput (..), compileBootstrapCandidate, compilePinnedBootstrap)
import Nagare.Inventory.Components.Foundation (FoundationInput (..), compileFoundation, foundationNamespaceId)
import Nagare.Inventory.Components.PackagedCache (compilePackagedCache)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), mkOperationId)
import Nagare.Inventory.KubernetesSources (validateSuppliedKubernetesMembers)
import Nagare.Resource.Cache
import Nagare.Resource.Database (DatabaseDirectInput (..), databaseResourceId)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Test.Tasty
import Test.Tasty.HUnit
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist, listDirectory)

inventoryCacheTests :: TestTree
inventoryCacheTests = testGroup "cache inventory adapter"
  [ testCase "packaged Attic image publication orders the complete cache scope" $
      withSystemTempDirectory "nagare-cache-payload" $ \root -> do
        let source = "../../cluster/bootstrap/nix-cache"
            destination = root </> "cluster/bootstrap/nix-cache"
        createDirectoryIfMissing True destination
        names <- listDirectory source
        forM_ names $ \name -> do
          present <- doesFileExist (source </> name)
          when present (copyFile (source </> name) (destination </> name))
        BC.writeFile (destination </> "attic-pin.json")
          "{\"sourceCommit\":\"abcdef123456\",\"linuxAmd64Digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}"
        BC.writeFile (destination </> "attic-server-image.tar.gz") "fixture-archive"
        let foundation = FoundationInput (ok (mkScopeId Platform "foundation")) fixtureCluster
              "../../cluster/bootstrap/job-runs/resourcequota.yaml" []
        (imageScope, cacheScope, native) <- compilePackagedCache root foundation "project"
          "registry.example/project/nagare" "backups" "nix-cache-bucket" >>= expectRight
        assertBool "packaged cache native members are incomplete" (Map.size native >= 15)
        (foundationBundle, _) <- compileFoundation foundation >>= expectRight
        foundationScope <- expectRight (mkScopeDeclaration (foundationOwner foundation) [foundationBundle])
        let binding = ContextBinding (ok (mkContextId "cache-payload")) (ok (mkName "project"))
            snapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
        _ <- expectRight (composeInventory snapshot (ReplaceScope foundationScope :|
          [ReplaceScope imageScope, ReplaceScope cacheScope]))
        pure ()
  , testCase "packaged cache templates bind nine exact native members" $ do
      (compiled, native) <- compileCacheNative renderInput >>= expectRight
      length (declarations compiled) @?= 9
      Map.size native @?= 9
      length (compiled ^. #operations) @?= 1
      assertBool "image substitution missing" (any (BC.isInfixOf "@sha256:") [bytes | (_, bytes) <- Map.elems native])
      assertBool "unresolved template escaped review" (all (not . BC.isInfixOf "${") [bytes | (_, bytes) <- Map.elems native])
      refused <- compileCacheNative (renderInput {renderImage = "registry.example/cache:latest"})
      assertBool "mutable image was accepted" (either (const True) (const False) refused)
      unsafeBucket <- compileCacheNative (renderInput {renderBucket = "bucket\"\n[storage]"})
      assertBool "unsafe bucket was accepted" (either (const True) (const False) unsafeBucket)
      missingTemplate <- compileCacheNative (renderInput {renderTemplateRoot = "../../cluster/bootstrap/missing-cache-assets"})
      assertBool "missing packaged templates were accepted" (either (const True) (const False) missingTemplate)
  , testCase "database, migration, workload, and logical cache compose as one scope" $ do
      let databaseSpec = Database (ok (mkDatabaseName "nix-cache-db")) Nothing Postgres (defaultEngineVersion Postgres)
            (ok (Dsl.mkNamespace "nagare-system")) (ok (Dsl.mkQuantity "5Gi")) Nothing Dsl.Retain
          recovery = RecoveryIntent (ok (mkName "backup")) (mkSecretRef (ok (mkName "db-password")) (ok (mkName "v1")) :| [])
          databaseInput = DatabaseDirectInput databaseSpec cacheOwner fixtureCluster Nothing recovery (SourceLocation "test" "database")
          databaseId role = ok (databaseResourceId cacheOwner (ok (mkName role)) databaseSpec)
          cacheInput = renderInput {renderDatabase = databaseId "statefulset", renderCredential = databaseId "credential"}
          binding = ContextBinding (ok (mkContextId "test")) (ok (mkName "project"))
      (scope, native) <- compileCacheComponent databaseInput (GcsBackend "project" "bucket") cacheInput >>= expectRight
      length (concatMap declarations (scopeBundles scope)) @?= 16
      Map.size native @?= 15
      let snapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
      (candidate, candidateNative) <- compileCacheCandidate snapshot databaseInput (GcsBackend "project" "bucket") cacheInput >>= expectRight
      Map.size candidateNative @?= Map.size native
      Map.size (inventoryScopes (candidateInventory candidate)) @?= 1
      let members = [member | Managed member <- inventoryDeclarations (candidateInventory candidate), member ^. #executor == KubernetesExecutor]
      _ <- expectRight (validateSuppliedKubernetesMembers members candidateNative)
      case Map.toList candidateNative of
        (memberId, (declaration, _)) : _ ->
          assertBool "changed generated native bytes were accepted" (either (const True) (const False)
            (validateSuppliedKubernetesMembers members (Map.insert memberId (declaration, "{}") candidateNative)))
        [] -> assertFailure "cache candidate has no native members"
      let renamed = databaseInput {directDatabase = databaseSpec & #name .~ ok (mkDatabaseName "other-db")}
      refused <- compileCacheComponent renamed (GcsBackend "project" "bucket") cacheInput
      assertBool "cache transport's fixed database address was not validated" (either (const True) (const False) refused)
  , testCase "lost cache creation acknowledgement recovers from the public key and configuration" $ do
      state <- newIORef CacheMissing
      creates <- newIORef (0 :: Int)
      let ops = CacheAdapterOps
            { cacheObserveResources = \_ -> pure (Left "not used")
            , cacheInspect = \_ -> readIORef state
            , cacheCreate = \plan -> do
                modifyIORef' creates (+ 1)
                writeIORef state (CachePresent physical (cachePlanConfigurationDigest plan) "cache.example:public-key")
                pure (AdapterEffectAmbiguous "lost acknowledgement")
            , cacheConfigure = \_ -> pure (AdapterEffectFailed (KnownNoEffect "configuration should already match"))
            }
          adapter = mkCacheAdapter specs ops
      prepared <- adapterPrepare adapter createOperation >>= expectRight
      adapterPreflight adapter createOperation prepared >>= expectRight
      adapterExecute adapter createOperation prepared >>= (@?= AdapterEffectAmbiguous "lost acknowledgement")
      recovered <- adapterRecover adapter createOperation prepared
      case recovered of
        RecoveryProvedComplete _ -> pure ()
        other -> assertFailure (show other)
      _ <- adapterVerify adapter createOperation prepared >>= expectRight
      readIORef creates >>= (@?= 1)
  , testCase "database and cache wait for their foundation namespace" $ do
      let fixtureFoundationOwner = ok (mkScopeId Platform "foundation")
          foundationInput = FoundationInput fixtureFoundationOwner fixtureCluster
            "../../cluster/bootstrap/job-runs/resourcequota.yaml" []
          namespaceId = foundationNamespaceId foundationInput (ok (mkName "nagare-system"))
          databaseSpec = Database (ok (mkDatabaseName "nix-cache-db")) Nothing Postgres (defaultEngineVersion Postgres)
            (ok (Dsl.mkNamespace "nagare-system")) (ok (Dsl.mkQuantity "5Gi")) Nothing Dsl.Retain
          recovery = RecoveryIntent (ok (mkName "backup")) (mkSecretRef (ok (mkName "db-password")) (ok (mkName "v1")) :| [])
          databaseInput = DatabaseDirectInput databaseSpec cacheOwner fixtureCluster (Just namespaceId) recovery (SourceLocation "test" "database")
          databaseId role = ok (databaseResourceId cacheOwner (ok (mkName role)) databaseSpec)
          cacheInput = renderInput {renderDatabase = databaseId "statefulset", renderCredential = databaseId "credential", renderNamespaceId = Just namespaceId}
          binding = ContextBinding (ok (mkContextId "test")) (ok (mkName "project"))
      (foundationBundle, _) <- compileFoundation foundationInput >>= expectRight
      (cacheScope, _) <- compileCacheComponent databaseInput (GcsBackend "project" "bucket") cacheInput >>= expectRight
      let foundationScope = ok (mkScopeDeclaration fixtureFoundationOwner [foundationBundle])
          candidate = composeInventory (ok (mkScopeSnapshot binding Map.empty Map.empty))
            (ReplaceScope foundationScope :| [ReplaceScope cacheScope])
      assertBool "foundation and cache scopes failed composition" (either (const False) (const True) candidate)
      let nativeMembers = [member | bundle <- scopeBundles cacheScope, Managed member <- declarations bundle,
            member ^. #executor == KubernetesExecutor]
      assertBool "namespaced cache member lacks foundation dependency"
        (all (elem (OrderedAfter namespaceId) . (^. #dependencies)) nativeMembers)
      let snapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
      (bootstrap, bootstrapNative) <- compileBootstrapCandidate snapshot
        (BootstrapInput foundationInput (Just (databaseInput, GcsBackend "project" "bucket", cacheInput)) [] []) >>= expectRight
      Map.size (inventoryScopes (candidateInventory bootstrap)) @?= 2
      Map.size bootstrapNative @?= 18
      (fullBootstrap, fullNative) <- compilePinnedBootstrap snapshot foundationInput
        (Just (databaseInput, GcsBackend "project" "bucket", cacheInput)) "../.." >>= expectRight
      Map.size (inventoryScopes (candidateInventory fullBootstrap)) @?= 6
      assertBool "full cache and upstream bootstrap dropped native members"
        (Map.size fullNative > Map.size bootstrapNative + 100)
      (withoutCache, foundationOnly) <- compileBootstrapCandidate snapshot
        (BootstrapInput foundationInput Nothing [] []) >>= expectRight
      Map.size (inventoryScopes (candidateInventory withoutCache)) @?= 1
      Map.size foundationOnly @?= 3
  , testCase "foreign and unavailable cache state never authorizes creation" $ do
      state <- newIORef (CacheForeign "owned elsewhere")
      calls <- newIORef (0 :: Int)
      let ops = CacheAdapterOps
            { cacheObserveResources = \_ -> pure (Left "not used")
            , cacheInspect = \_ -> readIORef state
            , cacheCreate = \_ -> modifyIORef' calls (+ 1) >> pure AdapterEffectCompleted
            , cacheConfigure = \_ -> modifyIORef' calls (+ 1) >> pure AdapterEffectCompleted
            }
          adapter = mkCacheAdapter specs ops
      prepared <- adapterPrepare adapter createOperation >>= expectRight
      result <- adapterPreflight adapter createOperation prepared
      assertBool "foreign cache was accepted" (either (const True) (const False) result)
      adapterExecute adapter createOperation prepared >>= (@?= AdapterEffectFailed (KnownNoEffect "owned elsewhere"))
      writeIORef state (CacheUnavailable "observation failed")
      adapterExecute adapter createOperation prepared >>= (@?= AdapterEffectAmbiguous "observation failed")
      readIORef calls >>= (@?= 0)
  , testCase "cache subprocess transport binds observation and generated key" $
      withSystemTempDirectory "cache-transport" $ \root -> do
        let executable = root </> "transport"
            statePath = root </> "state.json"
            cacheJson = "{\"kind\":\"present\",\"cache\":{\"is_public\":true,\"retention_period\":{\"Period\":2592000},\"substituter_endpoint\":\"http://nix-cache-internal.nagare-system.svc.cluster.local:8080/nagare-cache\",\"api_endpoint\":\"http://127.0.0.1:18080/\",\"public_key\":\"cache:AAAA=\"}}"
            script = unlines
              [ "#!/bin/sh"
              , "set -eu"
              , "request=$(cat)"
              , "printf '%s' \"$request\" | grep -F 'k3d-cache-test' >/dev/null"
              , "case \"$1\" in"
              , "  observe) cat '" <> statePath <> "' ;;"
              , "  create|configure) printf '%s' '" <> cacheJson <> "' > '" <> statePath <> "'; cat '" <> statePath <> "' ;;"
              , "esac"
              ]
            config = CacheRuntimeConfig executable "k3d-cache-test" (ok (mkContextId "test")) (pure (Right ())) specs
            adapter = mkCacheAdapter specs (mkCacheRuntimeOps config)
        writeFile executable script
        setFileMode executable 0o700
        writeFile statePath "{\"kind\":\"missing\"}"
        prepared <- adapterPrepare adapter createOperation >>= expectRight
        adapterPreflight adapter createOperation prepared >>= expectRight
        adapterExecute adapter createOperation prepared >>= (@?= AdapterEffectCompleted)
        _ <- adapterVerify adapter createOperation prepared >>= expectRight
        publicKey <- cachePublicKeyFromObservation (mkCacheRuntimeOps config) (CacheMutationPlan 1
          (plannedOperationId createOperation) CreateResource (plannedInputDigest createOperation)
          resource fixtureCluster (ok (mkName "nagare-cache")) logicalConfigurationDigest) >>= expectRight
        publicKey @?= "cache:AAAA="
  ]

specs :: Map.Map ResourceId ManagedResource
specs = either (error . show) id (cacheSpecsFromDeclarations (declarations bundle))

bundle :: ResourceBundle
bundle = compileLogicalCache (LogicalCacheInput cacheOwner fixtureCluster (ok (mkLogicalKey "cache")) (ok (mkName "nagare-cache")) logicalConfigurationDigest database workload (SourceLocation "test" "cache"))

renderInput :: CacheRenderInput
renderInput = CacheRenderInput cacheOwner fixtureCluster (ok (mkLogicalKey "cache")) database workload
  ("registry.example/cache@sha256:" <> "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
  "example-cache-bucket" "../../cluster/bootstrap/nix-cache" Nothing

createOperation :: PlannedOperation
createOperation = PlannedOperation (ok (mkOperationId "op-cache-create")) CreateResource CacheExecutor (resource :| []) (contentDigest "declaration") [] Idempotent

resource :: ResourceId
resource = case declarations bundle of
  [Managed value] -> value ^. #identity
  _ -> error "cache declaration missing"

cacheOwner :: ScopeId
cacheOwner = ok (mkScopeId Platform "cache")

fixtureCluster, database, workload :: ResourceId
fixtureCluster = mintResourceId cacheOwner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
database = mintResourceId cacheOwner (ok (mkLogicalKey "database")) (ok (mkName "database"))
workload = mintResourceId cacheOwner (ok (mkLogicalKey "workload")) (ok (mkName "workload"))

physical :: PhysicalIdentity
physical = ok (mkPhysicalIdentity "attic://cache")

ok :: Show e => Either e a -> a
ok = either (error . show) id

expectRight :: Show e => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> pure (error "unreachable")) pure
