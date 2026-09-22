module InventoryCacheSpec (inventoryCacheTests) where

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
import Nagare.Inventory.Cache
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), mkOperationId)
import Nagare.Resource.Cache
import Nagare.Resource.Database (DatabaseDirectInput (..), databaseResourceId)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Test.Tasty
import Test.Tasty.HUnit

inventoryCacheTests :: TestTree
inventoryCacheTests = testGroup "cache inventory adapter"
  [ testCase "packaged cache templates bind nine exact native members" $ do
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
          databaseInput = DatabaseDirectInput databaseSpec cacheOwner fixtureCluster recovery (SourceLocation "test" "database")
          databaseId role = ok (databaseResourceId cacheOwner (ok (mkName role)) databaseSpec)
          cacheInput = renderInput {renderDatabase = databaseId "statefulset", renderCredential = databaseId "credential"}
          binding = ContextBinding (ok (mkContextId "test")) (ok (mkName "project"))
      (scope, native) <- compileCacheComponent databaseInput (GcsBackend "project" "bucket") cacheInput >>= expectRight
      length (concatMap declarations (scopeBundles scope)) @?= 15
      Map.size native @?= 14
      let candidate = composeInventory (ok (mkScopeSnapshot binding Map.empty Map.empty)) (ReplaceScope scope :| [])
      assertBool "complete cache scope failed inventory validation" (either (const False) (const True) candidate)
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
  ]

specs :: Map.Map ResourceId ManagedResource
specs = either (error . show) id (cacheSpecsFromDeclarations (declarations bundle))

bundle :: ResourceBundle
bundle = compileLogicalCache (LogicalCacheInput cacheOwner fixtureCluster (ok (mkLogicalKey "cache")) (ok (mkName "cache")) (contentDigest "configuration") database workload (SourceLocation "test" "cache"))

renderInput :: CacheRenderInput
renderInput = CacheRenderInput cacheOwner fixtureCluster (ok (mkLogicalKey "cache")) database workload
  ("registry.example/cache@sha256:" <> "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
  "example-cache-bucket" "../../cluster/bootstrap/nix-cache"

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
