-- | Pin the disposable local MinIO transport as a reviewed cluster scope.
module Nagare.Inventory.Components.LocalObjectStore
  ( compileLocalObjectStore
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (Value (..), toJSON)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Nagare.Cluster.GcsJob (MinioRef (..))
import Nagare.Dsl.Prelude
import Nagare.Inventory.Components.Foundation (FoundationInput (..), foundationNamespaceId)
import Nagare.Inventory.Components.Upstream
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (parseKubernetesManifest)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import System.Environment (lookupEnv)
import System.FilePath ((</>))

compileLocalObjectStore ::
  FilePath ->
  FoundationInput ->
  MinioRef ->
  IO
    ( Either
        (NonEmpty InventoryError)
        (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
    )
compileLocalObjectStore root foundation store
  | store ^. #endpoint /= "http://minio.nagare-system.svc.cluster.local:9000"
      || store ^. #bucket /= "nagare-backups"
      || store ^. #secretName /= "nagare-minio-credentials" =
      pure (Left (invalid "local object-store profile differs from the pinned MinIO component" :| []))
  | otherwise = do
      serverImage <- fmap T.pack <$> lookupEnv "NAGARE_LOCAL_MINIO_IMAGE"
      clientImage <- fmap T.pack <$> lookupEnv "NAGARE_LOCAL_MC_IMAGE"
      loaded <- try (BS.readFile (root </> manifestPath)) :: IO (Either IOException ByteString)
      result <- case loaded of
        Left _ -> pure (Left (invalid "pinned MinIO manifest is unavailable" :| []))
        Right bytes
          | contentDigest bytes /= manifestDigest ->
              pure (Left (invalid "pinned MinIO manifest digest changed" :| []))
        Right bytes -> case parseKubernetesManifest
          (SourceLocation "cluster/local/minio/minio.yaml" "local-object-store")
          bytes of
          Left reason -> pure (Left (reason :| []))
          Right objects -> case traverse credentialTemplate objects of
            Left reason -> pure (Left (invalid reason :| []))
            Right templates -> case configureImages serverImage clientImage templates of
              Left reason -> pure (Left (invalid reason :| []))
              Right configured -> compileUpstream input {upstreamGenerated = configured}
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
    dataClaim = address "v1" "PersistentVolumeClaim" (Just "nagare-system") "minio-data"
    service = address "v1" "Service" (Just "nagare-system") "minio"
    bucketJob = address "batch/v1" "Job" (Just "nagare-system") "minio-make-bucket"
    manifestPath = "cluster/local/minio/minio.yaml"
    manifestDigest = known (mkContentDigest "3d6a394b5061f2290cccdb1a87b0a0f08bc70dc902fa667c3a6b611127cc18a9")
    configureImages Nothing Nothing objects = Right objects
    configureImages (Just serverImage) (Just clientImage) objects = do
      unless
        (validImage "nagare-minio" serverImage && validImage "nagare-mc" clientImage)
        (Left "local MinIO image overrides require exact local registry digests")
      let (counts, configured) =
            unzip
              [ ((serverCount, clientCount), (location, clientValue))
              | (location, value) <- objects
              , let (serverCount, serverValue) =
                      replaceImage
                        "quay.io/minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e"
                        serverImage
                        value
              , let (clientCount, clientValue) =
                      replaceImage
                        "quay.io/minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727"
                        clientImage
                        serverValue
              ]
      unless
        (sum (map fst counts) == 1 && sum (map snd counts) == 1)
        (Left "local MinIO manifest lacks unique server and client images")
      pure configured
    configureImages _ _ _ = Left "local MinIO image overrides require both server and client"
    validImage repository image = case T.stripPrefix
      ("k3d-registry.localhost:5000/" <> repository <> "@sha256:")
      image of
      Just digest -> T.length digest == 64 && T.all lowerHex digest
      Nothing -> False
    lowerHex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
    replaceImage :: Text -> Text -> Value -> (Int, Value)
    replaceImage old new = \case
      Object fields ->
        let changed =
              [ ( key
                , if key == "image" && value == String old
                    then (1, String new)
                    else replaceImage old new value
                )
              | (key, value) <- KM.toList fields
              ]
         in ( sum [count | (_, (count, _)) <- changed]
            , Object (KM.fromList [(key, value) | (key, (_, value)) <- changed])
            )
      Array items ->
        let changed = map (replaceImage old new) (V.toList items)
         in (sum (map fst changed), Array (V.fromList (map snd changed)))
      value -> (0, value)
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
              withSource =
                if namespaceName == "personal"
                  then KM.insert "nagare.dev/minio-source-resource-id" (String (resourceIdText credentialId)) annotated
                  else annotated
              updated = KM.insert "annotations" (Object withSource) metadata
          pure
            ( location
            , Object
                ( KM.insert
                    "metadata"
                    (Object updated)
                    (KM.delete "stringData" (KM.delete "data" fields))
                )
            )
    credentialTemplate (location, value) = Right (location, value)
    input =
      UpstreamInput
        { upstreamOwner = owner
        , upstreamCluster = cluster
        , upstreamKey = known (mkLogicalKey "local-object-store")
        , upstreamRoot = root
        , upstreamFiles = []
        , upstreamNamespaces =
            Map.fromList
              [ (known (mkName "nagare-system"), foundationNamespaceId foundation (known (mkName "nagare-system")))
              , (known (mkName "personal"), foundationNamespaceId foundation (known (mkName "personal")))
              ]
        , upstreamTransferred = Set.singleton namespace
        , upstreamConfigMapData = Map.empty
        , upstreamImageOverrides = Map.empty
        , upstreamGenerated = []
        , upstreamAfter =
            Map.fromList
              [ (address "v1" "Secret" (Just "personal") "nagare-minio-credentials", [credential])
              , (deployment, [credential, dataClaim])
              , (service, [deployment])
              , (bucketJob, [credential, deployment, service])
              ]
        , upstreamExternalAfter = Map.empty
        , upstreamOrderDeployments = False
        , upstreamRegistryDelegations = Map.empty
        }
