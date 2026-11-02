-- | Publish a release's service images into a context's own registry (EP-237,
-- IR-39). Each image is one reviewed artifact bound to the digest the payload's
-- @release.json@ names. Planning reads only that file, so it fetches nothing;
-- the transport fetches the OCI layout from the binary cache only when the
-- registry lacks the image, and checks it against this digest before any
-- registry mutation.
--
-- Each image keeps one identity across releases and its digest moves
-- ('requiresMigration' allows exactly this), so a release may return to an
-- earlier digest, history does not grow per release, and a workload's dependency
-- on its publication never changes. A superseded image stays in the registry
-- under its digest tag for any reference still naming it.
module Nagare.Inventory.Components.ReleaseImage
  ( compileReleaseImages
  , releaseImagesOwner
  , releaseImageTag
  )
where

import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..), nonEmpty)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Contract.ReleaseImages
  ( ReleaseImageKey
  , ReleaseImages
  , lookupReleaseImage
  , releaseImageKeyText
  )
import Nagare.Dsl.Prelude
import Nagare.Inventory.Artifact
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types

releaseImagesOwner :: ScopeId
releaseImagesOwner = known (mkScopeId Platform "release-images")

-- | The tag each image is published under. It is named after the digest, so
-- it never moves and a registry's untagged-image cleanup cannot collect it.
releaseImageTag :: ContentDigest -> Text
releaseImageTag digest = "sha256-" <> digestText digest

-- | The artifact scope for the context's enabled images, and each image's
-- publication for the workloads that must wait for it.
compileReleaseImages ::
  Text ->
  [ReleaseImageKey] ->
  ReleaseImages ->
  Either (NonEmpty InventoryError) (ScopeDeclaration, Map ReleaseImageKey ResourceId)
compileReleaseImages registry keys release = do
  unless
    (not (T.null registry) && not (T.any (<= ' ') registry))
    (Left (single "release image registry prefix is malformed"))
  entries <- traverse entry keys
  resources <- maybe (Left (single "a context always runs at least one release image")) Right (nonEmpty (map fst entries))
  scope <- compileArtifactScope (ArtifactDeclarationBundle 1 releaseImagesOwner resources)
  pure (scope, Map.fromList (map snd entries))
  where
    single message = inventoryError "invalid-release-image" message :| []
    entry key = do
      let name = releaseImageKeyText key
      image <- maybe (Left (single ("this release names no image for " <> name))) Right (lookupReleaseImage key release)
      hexadecimal <- maybe (Left (single (name <> " digest is not SHA-256"))) Right (T.stripPrefix "sha256:" (image ^. #digest))
      digest <- first (const (single (name <> " digest is not SHA-256"))) (mkContentDigest hexadecimal)
      logical <- first (const (single (name <> " has no valid artifact key"))) (mkLogicalKey name)
      artifactName' <- first (const (single (name <> " has no valid artifact name"))) (mkName name)
      let spec =
            ArtifactResourceSpec
              { artifactLogicalKey = logical
              , artifactRole = known (mkName "image")
              , artifactName = artifactName'
              , artifactDestination = registry <> "/" <> name <> ":" <> releaseImageTag digest
              , artifactContentDigest = digest
              , artifactSpecDigest = digest
              , artifactKind = OciImageArtifact
              , artifactOwnership = OwnedArtifact
              , artifactLifecycle = Retain
              , artifactDataPolicy = Stateless
              , artifactSensitivity = Private
              , artifactDependencies = []
              , artifactConsumers = ConsumerCompletenessUnknown
              , artifactPublishOperation = True
              , artifactSource = SourceLocation (image ^. #storePath) ociLayoutSourceMarker
              }
      pure (spec, (key, mintResourceId releaseImagesOwner logical (known (mkName "publish"))))

known :: Either Text a -> a
known = either (error . T.unpack) id
