-- | Pin the disposable local MinIO transport as a reviewed cluster scope.
module Nagare.Inventory.Components.LocalObjectStore
  ( compileLocalObjectStore
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Aeson (Value (..), toJSON)
import Data.Aeson.KeyMap qualified as KM
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
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (parseKubernetesManifest)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import System.FilePath ((</>))
import Control.Exception (IOException, try)

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
      loaded <- try (BS.readFile (root </> manifestPath)) :: IO (Either IOException ByteString)
      result <- case loaded of
        Left _ -> pure (Left (invalid "pinned MinIO manifest is unavailable" :| []))
        Right bytes | contentDigest bytes /= manifestDigest ->
          pure (Left (invalid "pinned MinIO manifest digest changed" :| []))
        Right bytes -> case parseKubernetesManifest
          (SourceLocation "cluster/local/minio/minio.yaml" "local-object-store") bytes of
          Left reason -> pure (Left (reason :| []))
          Right objects -> case traverse credentialTemplate objects of
            Left reason -> pure (Left (invalid reason :| []))
            Right templates -> compileUpstream input {upstreamGenerated = templates}
      pure $ do
        (bundle, native) <- result
        scope <- mkScopeDeclaration owner [bundle]
        pure (scope, native)
  where
    owner = known (mkScopeId Platform "local-object-store")
    cluster = foundationCluster foundation
    known = either (error . T.unpack) id
    invalid = inventoryError "invalid-local-object-store"
    address api kind scopeNamespace name = known (kubernetesAddress cluster api kind scopeNamespace name)
    namespace = address "v1" "Namespace" Nothing "nagare-system"
    credential = address "v1" "Secret" (Just "nagare-system") "nagare-minio-credentials"
    credentialAddressBytes = known (canonicalValue (toJSON credential))
    credentialRole = known (mkName ("object-" <> T.take 40 (digestText (contentDigest credentialAddressBytes))))
    credentialId = mintResourceId owner (known (mkLogicalKey "local-object-store")) credentialRole
    deployment = address "apps/v1" "Deployment" (Just "nagare-system") "minio"
    service = address "v1" "Service" (Just "nagare-system") "minio"
    bucketJob = address "batch/v1" "Job" (Just "nagare-system") "minio-make-bucket"
    manifestPath = "cluster/local/minio/minio.yaml"
    manifestDigest = known (mkContentDigest "579ff670df8f6162d7cde330f3504d3ea2cf72ba9f7a8b778dc1e0fcc6ca44bd")
    credentialTemplate (location, Object fields)
      | KM.lookup "kind" fields == Just (String "Secret") = do
          metadata <- case KM.lookup "metadata" fields of
            Just (Object metadataFields) -> Right metadataFields
            _ -> Left "MinIO Secret has no metadata"
          namespaceName <- case KM.lookup "namespace" metadata of
            Just (String value) -> Right value
            _ -> Left "MinIO Secret has no namespace"
          annotation <- case namespaceName of
            "nagare-system" -> Right "nagare.dev/minio-credential-template"
            "personal" -> Right "nagare.dev/minio-credential-copy"
            _ -> Left "MinIO Secret has an unexpected namespace"
          let annotations = case KM.lookup "annotations" metadata of
                Just (Object values) -> values
                _ -> KM.empty
              annotated = KM.insert annotation (String "v1") annotations
              withSource = if namespaceName == "personal"
                then KM.insert "nagare.dev/minio-source-resource-id" (String (resourceIdText credentialId)) annotated
                else annotated
              updated = KM.insert "annotations" (Object withSource) metadata
          pure (location, Object (KM.insert "metadata" (Object updated)
            (KM.delete "stringData" (KM.delete "data" fields))))
    credentialTemplate (location, value) = Right (location, value)
    input = UpstreamInput
      { upstreamOwner = owner
      , upstreamCluster = cluster
      , upstreamKey = known (mkLogicalKey "local-object-store")
      , upstreamRoot = root
      , upstreamFiles = []
      , upstreamNamespaces = Map.fromList
          [(known (mkName "nagare-system"), foundationNamespaceId foundation (known (mkName "nagare-system")))
          ,(known (mkName "personal"), foundationNamespaceId foundation (known (mkName "personal")))]
      , upstreamTransferred = Set.singleton namespace
      , upstreamConfigMapData = Map.empty
      , upstreamImageOverrides = Map.empty
      , upstreamGenerated = []
      , upstreamAfter = Map.fromList
          [(address "v1" "Secret" (Just "personal") "nagare-minio-credentials", [credential])
          ,(deployment, [credential]), (service, [deployment]), (bucketJob, [credential, deployment, service])]
      , upstreamExternalAfter = Map.empty
      , upstreamOrderDeployments = False
      }
