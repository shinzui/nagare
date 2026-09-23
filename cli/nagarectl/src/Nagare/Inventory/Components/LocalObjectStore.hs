-- | Pin the disposable local MinIO transport as a reviewed cluster scope.
module Nagare.Inventory.Components.LocalObjectStore
  ( compileLocalObjectStore
  ) where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Cluster.GcsJob (MinioRef (..))
import Nagare.Dsl.Prelude
import Nagare.Inventory.Components.Foundation (FoundationInput (..), foundationNamespaceId)
import Nagare.Inventory.Components.Upstream
import Nagare.Resource.Inventory
import Nagare.Resource.Types

compileLocalObjectStore
  :: FilePath -> FoundationInput -> MinioRef
  -> IO (Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString)))
compileLocalObjectStore root foundation store
  | store ^. #endpoint /= "http://minio.nagare-system.svc.cluster.local:9000"
    || store ^. #bucket /= "nagare-backups"
    || store ^. #secretName /= "nagare-minio-credentials" =
      pure (Left (invalid "local object-store profile differs from the pinned MinIO component" :| []))
  | otherwise = do
      result <- compileUpstream input
      pure $ do
        (bundle, native) <- result
        scope <- mkScopeDeclaration owner [bundle]
        pure (scope, native)
  where
    owner = known (mkScopeId Platform "local-object-store")
    cluster = foundationCluster foundation
    known = either (error . T.unpack) id
    invalid = inventoryError "invalid-local-object-store"
    address api kind namespace name = known (kubernetesAddress cluster api kind namespace name)
    namespace = address "v1" "Namespace" Nothing "nagare-system"
    credential = address "v1" "Secret" (Just "nagare-system") "nagare-minio-credentials"
    deployment = address "apps/v1" "Deployment" (Just "nagare-system") "minio"
    service = address "v1" "Service" (Just "nagare-system") "minio"
    bucketJob = address "batch/v1" "Job" (Just "nagare-system") "minio-make-bucket"
    input = UpstreamInput
      { upstreamOwner = owner
      , upstreamCluster = cluster
      , upstreamKey = known (mkLogicalKey "local-object-store")
      , upstreamRoot = root
      , upstreamFiles = [("cluster/local/minio/minio.yaml",
          known (mkContentDigest "579ff670df8f6162d7cde330f3504d3ea2cf72ba9f7a8b778dc1e0fcc6ca44bd"))]
      , upstreamNamespaces = Map.fromList
          [(known (mkName "nagare-system"), foundationNamespaceId foundation (known (mkName "nagare-system")))
          ,(known (mkName "personal"), foundationNamespaceId foundation (known (mkName "personal")))]
      , upstreamTransferred = Set.singleton namespace
      , upstreamConfigMapData = Map.empty
      , upstreamGenerated = []
      , upstreamAfter = Map.fromList
          [(deployment, [credential]), (service, [deployment]), (bucketJob, [credential, deployment, service])]
      , upstreamOrderDeployments = False
      }
