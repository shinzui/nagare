-- | Pin the disposable local MinIO transport as a reviewed cluster scope.
--
-- EP-183 M1: the MinIO images are the ones
-- @scripts/publish-local-minio-images.sh@ builds from digest-checked upstream
-- release binaries and publishes to the context's k3d registry. A bootstrap
-- binds them by default, by the exact digests their release tags name there;
-- @NAGARE_LOCAL_MINIO_IMAGE@ and @NAGARE_LOCAL_MC_IMAGE@ override both. The
-- former @quay.io/minio@ pins answer 401 and are refused.
module Nagare.Inventory.Components.LocalObjectStore
  ( LocalMinioImages (..)
  , compileLocalObjectStore
  , selectLocalMinioImages
  , readLocalRegistryDigest
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
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

-- | Exact local-registry references of the MinIO server and client images.
data LocalMinioImages = LocalMinioImages
  { server :: !Text
  , client :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | The images a local bootstrap binds: both overrides, or by default the
-- images the publish script pushed, looked up by their release tags for the
-- context's target platform. The lookup answers a manifest digest, or
-- 'Nothing' when the tag is absent.
selectLocalMinioImages ::
  (Text -> Text -> IO (Either Text (Maybe Text))) ->
  Text ->
  Maybe Text ->
  Maybe Text ->
  IO (Either Text LocalMinioImages)
selectLocalMinioImages lookupDigest platform serverOverride clientOverride = case (serverOverride, clientOverride) of
  (Just serverImage, Just clientImage) -> pure (validated serverImage clientImage)
  (Nothing, Nothing) -> case T.stripPrefix "linux/" platform of
    Just arch | arch `elem` ["arm64", "amd64"] -> do
      serverDigest <- lookupDigest "nagare-minio" ("release-2025-09-07-" <> arch)
      clientDigest <- lookupDigest "nagare-mc" ("release-2025-08-13-" <> arch)
      pure $ case (serverDigest, clientDigest) of
        (Left reason, _) -> Left ("cannot read the published MinIO server image: " <> reason)
        (_, Left reason) -> Left ("cannot read the published MinIO client image: " <> reason)
        (Right (Just serverAt), Right (Just clientAt)) ->
          validated (registry <> "/nagare-minio@" <> serverAt) (registry <> "/nagare-mc@" <> clientAt)
        _ ->
          Left
            ( "the local registry has no MinIO images for linux/"
                <> arch
                <> "; publish them with scripts/publish-local-minio-images.sh"
            )
    _ -> pure (Left ("local MinIO images support linux/arm64 or linux/amd64, not " <> platform))
  _ -> pure (Left "local MinIO image overrides require both NAGARE_LOCAL_MINIO_IMAGE and NAGARE_LOCAL_MC_IMAGE")
  where
    registry = "k3d-registry.localhost:5000"
    validated serverImage clientImage
      | any ("quay.io/minio/" `T.isPrefixOf`) [serverImage, clientImage] =
          Left "the quay.io/minio images answer 401; publish local images with scripts/publish-local-minio-images.sh"
      | not (exactImage "nagare-minio" serverImage && exactImage "nagare-mc" clientImage) =
          Left "local MinIO images must be exact local registry digests, as scripts/publish-local-minio-images.sh prints them"
      | otherwise = Right (LocalMinioImages serverImage clientImage)
    exactImage repository image = case T.stripPrefix (registry <> "/" <> repository <> "@sha256:") image of
      Just digest -> T.length digest == 64 && T.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) digest
      Nothing -> False

-- | A tag's manifest digest in the k3d registry, read through the registry
-- container because macOS AirPlay can own the host's port 5000 (as
-- @scripts/lib/local-registry.sh@ does). An absent tag is 'Nothing'.
readLocalRegistryDigest :: Text -> Text -> IO (Either Text (Maybe Text))
readLocalRegistryDigest repository tag = do
  answer <-
    try
      ( readProcessWithExitCode
          "docker"
          [ "exec"
          , "k3d-registry.localhost"
          , "wget"
          , "-S"
          , "-O"
          , "/dev/null"
          , "--header=Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"
          , "http://localhost:5000/v2/" <> T.unpack repository <> "/manifests/" <> T.unpack tag
          ]
          ""
      ) ::
      IO (Either IOException (ExitCode, String, String))
  pure $ case answer of
    Left failure -> Left ("docker is unavailable: " <> T.pack (show failure))
    Right (code, _, err)
      | "404 Not Found" `T.isInfixOf` T.pack err -> Right Nothing
      | code /= ExitSuccess -> Left (T.strip (T.pack err))
      | otherwise -> case [ T.strip value
                          | line <- T.lines (T.pack err)
                          , Just value <- [T.stripPrefix "docker-content-digest:" (T.toLower (T.strip line))]
                          ] of
          digest : _ | "sha256:" `T.isPrefixOf` digest && T.length digest == 71 -> Right (Just digest)
          _ -> Left "the local registry returned no manifest digest"

compileLocalObjectStore ::
  FilePath ->
  FoundationInput ->
  MinioRef ->
  LocalMinioImages ->
  IO
    ( Either
        (NonEmpty InventoryError)
        (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
    )
compileLocalObjectStore root foundation store images
  | store ^. #endpoint /= "http://minio.nagare-system.svc.cluster.local:9000"
      || store ^. #bucket /= "nagare-backups"
      || store ^. #secretName /= "nagare-minio-credentials" =
      pure (Left (invalid "local object-store profile differs from the pinned MinIO component" :| []))
  | otherwise = do
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
            Right templates -> case configureImages templates of
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
    manifestDigest = known (mkContentDigest "fa4fc7998952f3e767aff28848efc8323a3b62a4cc588843a1897a4cd418d8a3")
    configureImages objects = do
      let (counts, configured) =
            unzip
              [ ((serverCount, clientCount), (location, clientValue))
              | (location, value) <- objects
              , let (serverCount, serverValue) = replaceImage "k3d-registry.localhost:5000/nagare-minio" (images ^. #server) value
              , let (clientCount, clientValue) = replaceImage "k3d-registry.localhost:5000/nagare-mc" (images ^. #client) serverValue
              ]
      unless
        (sum (map fst counts) == 1 && sum (map snd counts) == 1)
        (Left "local MinIO manifest lacks unique server and client images")
      pure configured
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
