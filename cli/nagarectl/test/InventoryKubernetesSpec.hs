module InventoryKubernetesSpec (inventoryKubernetesTests) where

import Data.Aeson (Value, object, (.=))
import Data.ByteString (ByteString)
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal
import Nagare.Inventory.Kubernetes
import Nagare.Resource.Inventory hiding (cluster)
import Nagare.Resource.Kubernetes
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Test.Tasty
import Test.Tasty.HUnit

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
    ]

ops :: IORef KubernetesState -> IORef Int -> KubernetesAdapterOps
ops state calls =
  KubernetesAdapterOps
    { kubernetesObserve = \_ -> readIORef state
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
