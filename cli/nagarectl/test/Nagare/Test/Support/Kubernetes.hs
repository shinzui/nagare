module Nagare.Test.Support.Kubernetes
  ( addProbeAnnotation
  , ops
  , createOperation
  , updateOperation
  , operation
  , scope
  , resource
  , cluster
  , nativeObject
  , nativeBytes
  , nativeText
  , declaration
  , input
  , specs
  , physical
  , absence
  , expectRight
  , ok
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), mkOperationId)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Inventory (Executor (KubernetesExecutor), ManagedResource)
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Test.Tasty.HUnit (assertFailure)

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
    , kubernetesObserveStamped = unstamped $ \_ -> readIORef state
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
