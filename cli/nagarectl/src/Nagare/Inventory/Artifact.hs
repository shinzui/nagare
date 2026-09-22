-- | Typed artifacts, publication intent, and consumer-completeness metadata.
module Nagare.Inventory.Artifact
  ( ArtifactKind (..)
  , ArtifactOwnership (..)
  , ConsumerCoverage (..)
  , ArtifactResourceSpec (..)
  , ArtifactExecutionSpec (..)
  , ArtifactDeclarationBundle (..)
  , compileArtifactScope
  , artifactSpecsById
  , artifactExecutionSpecs
  , artifactExecutionSpecsFromDeclarations
  )
where

import Data.Aeson (FromJSON (parseJSON), ToJSON (toJSON), defaultOptions, genericParseJSON, genericToJSON)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference
import Nagare.Resource.Types

data ArtifactKind
  = OciImageArtifact
  | GcsImageObjectArtifact
  | GceImageArtifact
  | BuildJobArtifact
  | TemporaryBuilderArtifact
  | ReleasePayloadArtifact
  | ControlMetadataArtifact
  deriving stock (Eq, Ord, Show, Generic)

instance ToJSON ArtifactKind where toJSON = genericToJSON defaultOptions

instance FromJSON ArtifactKind where parseJSON = genericParseJSON defaultOptions

data ArtifactOwnership = OwnedArtifact | ExternalArtifact deriving stock (Eq, Ord, Show, Generic)

data ConsumerCoverage
  = KnownConsumers ![ContextId]
  | ConsumerCompletenessUnknown
  deriving stock (Eq, Ord, Show, Generic)

data ArtifactResourceSpec = ArtifactResourceSpec
  { artifactLogicalKey :: !LogicalKey
  , artifactRole :: !Name
  , artifactName :: !Name
  , artifactDestination :: !Text
  , artifactContentDigest :: !ContentDigest
  , artifactSpecDigest :: !ContentDigest
  , artifactKind :: !ArtifactKind
  , artifactOwnership :: !ArtifactOwnership
  , artifactLifecycle :: !LifecyclePolicy
  , artifactDataPolicy :: !DataPolicy
  , artifactSensitivity :: !Sensitivity
  , artifactDependencies :: ![Dependency]
  , artifactConsumers :: !ConsumerCoverage
  , artifactPublishOperation :: !Bool
  , artifactSource :: !SourceLocation
  }
  deriving stock (Eq, Ord, Show, Generic)

data ArtifactExecutionSpec = ArtifactExecutionSpec
  { executionArtifactKind :: !ArtifactKind
  , executionArtifactDestination :: !Text
  , executionArtifactContentDigest :: !ContentDigest
  , executionArtifactSpecDigest :: !ContentDigest
  , executionArtifactConsumersComplete :: !Bool
  }
  deriving stock (Eq, Ord, Show, Generic)

data ArtifactDeclarationBundle = ArtifactDeclarationBundle
  { artifactBundleVersion :: !Int
  , artifactScope :: !ScopeId
  , artifactResources :: !(NonEmpty ArtifactResourceSpec)
  }
  deriving stock (Eq, Show, Generic)

artifactSpecsById :: ArtifactDeclarationBundle -> Map ResourceId ArtifactResourceSpec
artifactSpecsById bundle = Map.fromList [(resourceId resource, resource) | resource <- NE.toList (artifactResources bundle)]
  where
    resourceId resource = mintResourceId (artifactScope bundle) (artifactLogicalKey resource) (artifactRole resource)

artifactExecutionSpecs :: ArtifactDeclarationBundle -> Map ResourceId ArtifactExecutionSpec
artifactExecutionSpecs bundle = fmap executionSpec (artifactSpecsById bundle)

artifactExecutionSpecsFromDeclarations :: [Declaration] -> Either Text (Map ResourceId ArtifactExecutionSpec)
artifactExecutionSpecsFromDeclarations declarations = Map.fromList <$> traverse fromDeclaration managedArtifacts
  where
    managedArtifacts = [resource | Managed resource <- declarations, resource ^. #executor == ArtifactExecutor]
    fromDeclaration resource = case (resource ^. #address, resource ^. #spec) of
      (Artifact _ contentDigest, ArtifactPublication kind destination specDigest hasCompleteConsumers) -> do
        artifactKind <- kindFromName kind
        pure
          ( resource ^. #identity
          , ArtifactExecutionSpec artifactKind destination contentDigest specDigest hasCompleteConsumers
          )
      _ -> Left ("artifact declaration lacks its typed publication specification: " <> resourceIdText (resource ^. #identity))

compileArtifactScope :: ArtifactDeclarationBundle -> Either (NonEmpty InventoryError) ScopeDeclaration
compileArtifactScope bundle
  | artifactBundleVersion bundle /= 1 = Left (inventoryError "artifact-wire-version" "unsupported artifact declaration bundle version" :| [])
  | otherwise = mkScopeDeclaration (artifactScope bundle) [resourceBundle]
  where
    resources = NE.toList (artifactResources bundle)
    resourceId resource = mintResourceId (artifactScope bundle) (artifactLogicalKey resource) (artifactRole resource)
    resourceBundle =
      ResourceBundle
        { declarations = map declaration resources
        , exports = []
        , conditions = []
        , contributions = []
        , operations = map publication [resource | resource <- resources, artifactOwnership resource == OwnedArtifact, artifactPublishOperation resource]
        , grants = []
        }
    declaration resource = case artifactOwnership resource of
      ExternalArtifact -> External (resourceId resource) (address resource) (artifactDependencies resource) (artifactSource resource)
      OwnedArtifact ->
        Managed
          ManagedResource
            { identity = resourceId resource
            , owner = artifactScope bundle
            , executor = ArtifactExecutor
            , address = address resource
            , aliases = []
            , spec =
                ArtifactPublication
                  (kindName (artifactKind resource))
                  (artifactDestination resource)
                  (artifactSpecDigest resource)
                  (consumersComplete (artifactConsumers resource))
            , lifecycle = artifactLifecycle resource
            , dataPolicy = artifactDataPolicy resource
            , sensitivity = artifactSensitivity resource
            , dependencies = artifactDependencies resource
            , delegations = []
            , source = artifactSource resource
            }
    address resource = Artifact (artifactName resource) (artifactContentDigest resource)
    publication resource =
      DeclaredOperation
        { identity = mintResourceId (artifactScope bundle) (artifactLogicalKey resource) (knownName "publish")
        , affects = resourceId resource :| []
        , inputs = [ContentInput (artifactContentDigest resource)]
        , recovery = VerifyBeforeRetry
        , operationKind = PublishRelease
        }

knownName :: Text -> Name
knownName = either (error . show) id . mkName

executionSpec :: ArtifactResourceSpec -> ArtifactExecutionSpec
executionSpec resource =
  ArtifactExecutionSpec
    { executionArtifactKind = artifactKind resource
    , executionArtifactDestination = artifactDestination resource
    , executionArtifactContentDigest = artifactContentDigest resource
    , executionArtifactSpecDigest = artifactSpecDigest resource
    , executionArtifactConsumersComplete = consumersComplete (artifactConsumers resource)
    }

consumersComplete :: ConsumerCoverage -> Bool
consumersComplete KnownConsumers {} = True
consumersComplete ConsumerCompletenessUnknown = False

kindName :: ArtifactKind -> Name
kindName =
  knownName . \case
    OciImageArtifact -> "oci-image"
    GcsImageObjectArtifact -> "gcs-image-object"
    GceImageArtifact -> "gce-image"
    BuildJobArtifact -> "build-job"
    TemporaryBuilderArtifact -> "temporary-builder"
    ReleasePayloadArtifact -> "release-payload"
    ControlMetadataArtifact -> "control-metadata"

kindFromName :: Name -> Either Text ArtifactKind
kindFromName value = case nameText value of
  "oci-image" -> Right OciImageArtifact
  "gcs-image-object" -> Right GcsImageObjectArtifact
  "gce-image" -> Right GceImageArtifact
  "build-job" -> Right BuildJobArtifact
  "temporary-builder" -> Right TemporaryBuilderArtifact
  "release-payload" -> Right ReleasePayloadArtifact
  "control-metadata" -> Right ControlMetadataArtifact
  token -> Left ("unsupported artifact kind " <> token)
