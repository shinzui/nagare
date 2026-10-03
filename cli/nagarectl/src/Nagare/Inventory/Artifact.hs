-- | Typed artifacts, publication intent, and consumer-completeness metadata.
module Nagare.Inventory.Artifact
  ( ArtifactKind (..)
  , ArtifactOwnership (..)
  , ConsumerCoverage (..)
  , ArtifactResourceSpec (..)
  , ArtifactExecutionSpec (..)
  , ArtifactDeclarationBundle (..)
  , compileArtifactScope
  , sameKubeconfigProjection
  , artifactSpecsById
  , artifactExecutionSpecs
  , artifactExecutionSpecsFromDeclarations
  , ociArchiveSource
  )
where

import Data.Aeson (FromJSON (parseJSON), ToJSON (toJSON), defaultOptions, genericParseJSON, genericToJSON)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference
import Nagare.Resource.Types

data ArtifactKind
  = OciImageArtifact
  | GcsImageObjectArtifact
  | GceImageArtifact
  | KubeconfigArtifact
  | BuildJobArtifact
  | LocalRegistryArtifact
  | LocalClusterArtifact
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
  , executionArtifactArchive :: !(Maybe FilePath)
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
          , ArtifactExecutionSpec
              artifactKind
              destination
              contentDigest
              specDigest
              hasCompleteConsumers
              (artifactLocalSource (resource ^. #source))
          )
      _ -> Left ("artifact declaration lacks its typed publication specification: " <> resourceIdText (resource ^. #identity))

-- | A workstation projection may relocate an accepted kubeconfig's two local
-- paths, but never its identity, bytes, producer, policies or operation envelope.
-- This comparison does not rewrite the accepted declaration or retained review.
sameKubeconfigProjection :: ScopeDeclaration -> ScopeDeclaration -> Bool
sameKubeconfigProjection left right =
  scopeId left == scopeId right
    && scopeIdText (scopeId left) == "platform:kubeconfig"
    && scopeConfigDigest left == scopeConfigDigest right
    && scopeOverrides left == scopeOverrides right
    && case (normalize left, normalize right) of
      (Just a, Just b) -> a == b
      _ -> False
  where
    normalize scope = case scopeBundles scope of
      [bundle] | null (bundle ^. #operations) -> case bundle ^. #declarations of
        [Managed resource] -> case resource ^. #spec of
          ArtifactPublication kind _ digest complete
            | kind == kindName KubeconfigArtifact
            , resource ^. #executor == ArtifactExecutor
            , resource ^. #source . #path == "kubeconfig-prepared-v1" ->
                Just
                  ( bundle
                      & #declarations
                      .~ [ Managed
                             ( resource
                                 & #spec
                                 .~ ArtifactPublication kind "current-context" digest complete
                                 & #source
                                 . #file
                                 .~ "current-context"
                             )
                         ]
                  )
          _ -> Nothing
        _ -> Nothing
      _ -> Nothing

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
    , executionArtifactArchive = artifactLocalSource (artifactSource resource)
    }

-- | Only an explicit archive source marker enables the generic OCI transport.
-- Platform images retain their dedicated publication scripts and source rules.
ociArchiveSource :: SourceLocation -> Maybe FilePath
ociArchiveSource source
  | path source == "oci-archive-v1" = Just (T.unpack (file source))
  | otherwise = Nothing

artifactLocalSource :: SourceLocation -> Maybe FilePath
artifactLocalSource source
  | path source == "kubeconfig-prepared-v1" = Just (T.unpack (file source))
  | path source == "local-substrate-v1" = Just (T.unpack (file source))
  | otherwise = ociArchiveSource source

consumersComplete :: ConsumerCoverage -> Bool
consumersComplete KnownConsumers {} = True
consumersComplete ConsumerCompletenessUnknown = False

kindName :: ArtifactKind -> Name
kindName =
  knownName . \case
    OciImageArtifact -> "oci-image"
    GcsImageObjectArtifact -> "gcs-image-object"
    GceImageArtifact -> "gce-image"
    KubeconfigArtifact -> "kubeconfig"
    BuildJobArtifact -> "build-job"
    LocalRegistryArtifact -> "local-registry"
    LocalClusterArtifact -> "local-cluster"
    TemporaryBuilderArtifact -> "temporary-builder"
    ReleasePayloadArtifact -> "release-payload"
    ControlMetadataArtifact -> "control-metadata"

kindFromName :: Name -> Either Text ArtifactKind
kindFromName value = case nameText value of
  "oci-image" -> Right OciImageArtifact
  "gcs-image-object" -> Right GcsImageObjectArtifact
  "gce-image" -> Right GceImageArtifact
  "kubeconfig" -> Right KubeconfigArtifact
  "build-job" -> Right BuildJobArtifact
  "local-registry" -> Right LocalRegistryArtifact
  "local-cluster" -> Right LocalClusterArtifact
  "temporary-builder" -> Right TemporaryBuilderArtifact
  "release-payload" -> Right ReleasePayloadArtifact
  "control-metadata" -> Right ControlMetadataArtifact
  token -> Left ("unsupported artifact kind " <> token)
