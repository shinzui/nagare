module InventoryImagePruneSpec (inventoryImagePruneTests) where

import Data.Aeson (toJSON)
import Data.Either (isLeft)
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Command (executionBlockedAdapterFor)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.ImagePrune
import Nagare.Inventory.ImagePruneAdapter
import Nagare.Inventory.Journal (mkOperationId)
import Nagare.Resource.Inventory hiding (address, owner)
import Nagare.Resource.Policy hiding (operations)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Test.Tasty
import Test.Tasty.HUnit

inventoryImagePruneTests :: TestTree
inventoryImagePruneTests =
  testGroup
    "reviewed host image cleanup"
    [ testCase "all aliases, pins and stopped-container references protect complete IDs" $ do
        unusedCacheImages (ImageCacheSnapshot "123" [cached, CachedImage other ["used:one", "used:two"] False] [other]) @?= Right [image]
        unusedCacheImages (ImageCacheSnapshot "123" [cached {imagePinned = True}] []) @?= Right []
        assertBool "ambiguous alias refused" (isLeft (unusedCacheImages (ImageCacheSnapshot "123" [cached, CachedImage other (imageAliases cached) True] [])))
        assertBool "short IDs refused" (isLeft (unusedCacheImages (ImageCacheSnapshot "123" [cached {imageId = "sha256:abc"}] [])))
    , testCase "lost removal acknowledgement recovers and never prunes a later re-pull" $ do
        (adapter, current, writes) <- fixture True True
        native <- adapterPrepare adapter operation >>= right
        adapterExecute adapter operation native >>= \case
          AdapterEffectAmbiguous _ -> pure ()
          value -> assertFailure (show value)
        proof <- adapterVerify adapter operation native >>= right
        writeIORef current initial
        repeated <- adapterPrepare adapter operation >>= right
        preparedNativeBytes repeated @?= preparedNativeBytes native
        adapterExecute adapter operation repeated >>= (@?= AdapterEffectCompleted)
        adapterRecover adapter operation repeated >>= (@?= RecoveryProvedComplete proof)
        readIORef current >>= (@?= initial)
        readIORef writes >>= (@?= 1)
    , testCase "ambiguous still-present deletion is observed without resending" $ do
        (adapter, _, writes) <- fixture True False
        native <- adapterPrepare adapter operation >>= right
        void (adapterExecute adapter operation native)
        adapterRecover adapter operation native >>= \case
          RecoveryUnresolved _ -> pure ()
          value -> assertFailure (show value)
        readIORef writes >>= (@?= 1)
    , testCase "VM replacement, new usage, pin and alias changes refuse before mutation" $
        mapM_
          ( \changed -> do
              (adapter, current, writes) <- fixture False True
              native <- adapterPrepare adapter operation >>= right
              writeIORef current changed
              adapterExecute adapter operation native >>= \case
                AdapterEffectFailed _ -> pure ()
                value -> assertFailure (show value)
              readIORef writes >>= (@?= 0)
          )
          [ initial {cacheInstanceId = "456"}
          , initial {cacheUsedIds = [image]}
          , initial {cacheImages = [cached {imagePinned = True}]}
          , initial {cacheImages = [cached {imageAliases = ["changed:tag"]}]}
          ]
    , testCase "already absent image records completion without removing another ID" $ do
        (adapter, current, writes) <- fixture False True
        writeIORef current (initial {cacheImages = [CachedImage other [] False]})
        native <- adapterPrepare adapter operation >>= right
        adapterExecute adapter operation native >>= (@?= AdapterEffectCompleted)
        void (adapterVerify adapter operation native >>= right)
        readIORef writes >>= (@?= 0)
    , testCase "request identity binds the exact image set and preserves declarations" $ do
        revised <- right (compileImagePrune (snapshot baseScope) address "fixture" [image, other])
        map declarations (scopeBundles revised) @?= map declarations (scopeBundles baseScope)
        imagePruneRequestTargets (snapshot revised) address "fixture" @?= Right (Just [image, other])
        compileImagePrune (snapshot revised) address "fixture" [other, image] @?= Right revised
        assertBool "request set immutable" (isLeft (compileImagePrune (snapshot revised) address "fixture" [image]))
        bindings <- right (imagePruneBindings address [revised])
        Map.size bindings @?= 2
    ]

fixture lost removed = do
  current <- newIORef initial
  writes <- newIORef (0 :: Int)
  receipts <- newIORef Map.empty
  let ops =
        ImagePruneOps
          (\selected -> (selected @?= address) >> (Right <$> readIORef current))
          ( \selected plan -> do
              selected @?= address
              pruneImageId plan @?= image
              modifyIORef' writes (+ 1)
              when removed (modifyIORef' current (\s -> s {cacheImages = filter ((/= image) . imageId) (cacheImages s)}))
              pure (if lost then Left "lost acknowledgement" else Right ())
          )
          (\key -> Right . Map.lookup key <$> readIORef receipts)
          ( \key bytes -> do
              previous <- Map.lookup key <$> readIORef receipts
              case previous of
                Just old | old /= bytes -> pure (Left "immutable receipt changed")
                _ -> modifyIORef' receipts (Map.insert key bytes) >> pure (Right ())
          )
      bindings = ok (imagePruneBindings address [scope])
  pure (withImagePrune bindings ops (executionBlockedAdapterFor PulumiExecutor), current, writes)

image, other :: Text
image = "sha256:" <> T.replicate 64 "a"
other = "sha256:" <> T.replicate 64 "b"

cached :: CachedImage
cached = CachedImage image ["fixture:first", "fixture:second"] False

initial :: ImageCacheSnapshot
initial = ImageCacheSnapshot "123" [cached] []

owner :: ScopeId
owner = ok (mkScopeId Platform "cloud")

resource :: ResourceId
resource = mintResourceId owner (ok (mkLogicalKey "vm")) (name "instance")

address :: ProviderAddress
address = CloudInstance (name "project") (name "us-west1-a") (name "fixture-vm")

baseScope :: ScopeDeclaration
baseScope =
  ok
    ( mkScopeDeclaration
        owner
        [ ResourceBundle
            [ Managed
                ( ManagedResource
                    resource
                    owner
                    PulumiExecutor
                    (PulumiUrn "urn:pulumi:fixture::nagare::gcp:compute/instance:Instance::fixture-vm")
                    []
                    (NativeObject (contentDigest "vm"))
                    Protect
                    Stateless
                    Private
                    []
                    []
                    (SourceLocation "fixture" "vm")
                )
            ]
            []
            []
            []
            []
            []
        ]
    )

snapshot :: ScopeDeclaration -> ScopeSnapshot
snapshot value =
  ok
    ( mkScopeSnapshot
        (ContextBinding (ok (mkContextId "fixture")) (name "project"))
        (Map.singleton owner (ok (mkScopeGeneration 1), value))
        Map.empty
    )

scope :: ScopeDeclaration
scope = ok (compileImagePrune (snapshot baseScope) address "fixture" [image])

operation :: PlannedOperation
operation =
  PlannedOperation
    (ok (mkOperationId "op-prune"))
    RunDeclaredOperation
    PulumiExecutor
    (resource :| [])
    (contentDigest (ok (canonicalValue (toJSON (head (concatMap operations (scopeBundles scope)))))))
    []
    OperatorRecovery

name :: Text -> Name
name = ok . mkName

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> error "unreachable") pure
