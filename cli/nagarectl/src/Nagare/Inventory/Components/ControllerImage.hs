-- | Bind the released patched net-certmanager archive to a reviewed OCI
-- publication. The image digest comes from the archive before any registry
-- mutation; the transport rechecks both archive and manifest digests.
module Nagare.Inventory.Components.ControllerImage
  ( compileControllerImage
  , controllerImageDeclaration
  , inspectArchive
  ) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Inventory.Artifact
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)

compileControllerImage
  :: FilePath -> Text
  -> IO (Either (NonEmpty InventoryError) (ScopeDeclaration, Text, ResourceId))
compileControllerImage root registry = do
  let directory = root </> "cluster/bootstrap/net-certmanager"
      archive = directory </> "nagare-net-certmanager-controller.tar.gz"
      reference = directory </> "image-reference"
  referenceBytes <- try (BS.readFile reference) :: IO (Either IOException BS.ByteString)
  archiveExists <- doesFileExist archive
  case referenceBytes of
    Left failure -> pure (Left (single ("patched-controller reference is unavailable: " <> T.pack (show failure))))
    Right bytes | fmap T.strip (TE.decodeUtf8' bytes) /= Right "nagare/net-certmanager-controller:v1.14.0-nagare.1" ->
      pure (Left (single "patched-controller reference differs from the released pin"))
    Right _ | not archiveExists -> pure (Left (single "released patched-controller image archive is unavailable"))
    Right _ -> do
      inspected <- inspectArchive archive
      pure $ do
        (archiveDigest, manifestDigest) <- first (single . ("cannot bind patched-controller archive: " <>)) inspected
        controllerImageDeclaration registry archiveDigest manifestDigest
  where
    single message = inventoryError "invalid-controller-image" message :| []

controllerImageDeclaration
  :: Text -> ContentDigest -> ContentDigest
  -> Either (NonEmpty InventoryError) (ScopeDeclaration, Text, ResourceId)
controllerImageDeclaration registry archiveDigest manifestDigest = do
  unless (not (T.null registry) && not (T.any (<= ' ') registry))
    (Left (inventoryError "invalid-controller-image" "controller registry prefix is malformed" :| []))
  let owner = known (mkScopeId Platform "net-controller-image")
      key = known (mkLogicalKey "net-controller-image")
      role = known (mkName "image")
      publishId = mintResourceId owner key (known (mkName "publish"))
      destination = registry <> "/net-certmanager-controller:v1.14.0-nagare.1"
      image = registry <> "/net-certmanager-controller@sha256:" <> digestText manifestDigest
      spec = ArtifactResourceSpec
        { artifactLogicalKey = key
        , artifactRole = role
        , artifactName = known (mkName "net-certmanager-controller")
        , artifactDestination = destination
        , artifactContentDigest = manifestDigest
        , artifactSpecDigest = archiveDigest
        , artifactKind = OciImageArtifact
        , artifactOwnership = OwnedArtifact
        , artifactLifecycle = Retain
        , artifactDataPolicy = Stateless
        , artifactSensitivity = Private
        , artifactDependencies = []
        , artifactConsumers = ConsumerCompletenessUnknown
        , artifactPublishOperation = True
        , artifactSource = SourceLocation "cluster/bootstrap/net-certmanager/nagare-net-certmanager-controller.tar.gz" "patched-controller-image"
        }
  scope <- compileArtifactScope (ArtifactDeclarationBundle 1 owner (spec :| []))
  pure (scope, image, publishId)
  where
    known = either (error . T.unpack) id

inspectArchive :: FilePath -> IO (Either Text (ContentDigest, ContentDigest))
inspectArchive archive = do
  result <- try (withSystemTempDirectory "nagare-controller-image" (inspect archive))
    :: IO (Either IOException (Either Text (ContentDigest, ContentDigest)))
  pure (first (T.pack . show) result >>= id)
  where
    inspect source temporary = do
      let policy = temporary </> "policy.json"
      BS.writeFile policy "{\"default\":[{\"type\":\"insecureAcceptAnything\"}]}"
      (hashCode, hashOutput, _) <- readProcessWithExitCode "shasum" ["-a", "256", source] ""
      (imageCode, imageOutput, imageError) <- readProcessWithExitCode "skopeo"
        ["--policy", policy, "inspect", "--format", "{{.Digest}}", "docker-archive:" <> source] ""
      pure $ do
        unless (hashCode == ExitSuccess) (Left "archive SHA-256 could not be read")
        unless (imageCode == ExitSuccess)
          (Left ("archive OCI manifest could not be inspected: " <> T.pack imageError))
        archiveDigest <- case words hashOutput of
          firstWord : _ -> mkContentDigest (T.pack firstWord)
          _ -> Left "archive SHA-256 command returned no digest"
        manifestDigest <- case T.stripPrefix "sha256:" (T.strip (T.pack imageOutput)) of
          Just hexadecimal -> mkContentDigest hexadecimal
          Nothing -> Left "archive OCI manifest is not SHA-256"
        pure (archiveDigest, manifestDigest)
