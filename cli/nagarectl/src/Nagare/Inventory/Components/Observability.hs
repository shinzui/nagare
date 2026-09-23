-- | Compile the exact Helm post-renderer input into a release claim. Chart
-- archives and values are packaged inputs; the captured render is private.
module Nagare.Inventory.Components.Observability
  ( ObservabilityReleaseInput (..)
  , compileRenderedRelease
  ) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Helm
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes
import Nagare.Resource.Reference (Dependency)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data ObservabilityReleaseInput = ObservabilityReleaseInput
  { releaseId :: !ResourceId
  , releaseOwner :: !ScopeId
  , releaseCluster :: !ResourceId
  , releaseNamespace :: !Name
  , releaseName :: !Name
  , releaseChartPath :: !FilePath
  , releaseChartBytes :: !ByteString
  , releaseValuesPath :: !FilePath
  , releaseValuesBytes :: !ByteString
  , releaseRenderedBytes :: !ByteString
  , releaseCrdsBytes :: !(Maybe ByteString)
  , releaseKubeVersion :: !Text
  , releaseApiVersions :: ![Text]
  , releaseDependencies :: ![Dependency]
  }

-- | The digest binds chart, values, capabilities, CRDs and the post-renderer
-- bytes. A native adapter must recheck the packaged paths and render digest.
compileRenderedRelease
  :: ObservabilityReleaseInput
  -> Either InventoryError (ManagedResource, ByteString)
compileRenderedRelease input = do
  rendered <- parseKubernetesManifest source (releaseRenderedBytes input)
  crds <- maybe (Right []) (parseKubernetesManifest (source {path = "crds"})) (releaseCrdsBytes input)
  members <- traverse memberAddress (rendered <> crds)
  addresses <- case members of
    [] -> Left (invalid "Helm render contains no Kubernetes members")
    firstAddress : rest -> Right (firstAddress :| rest)
  contract <- first invalid $ canonicalValue $ object
    [ "chartPath" .= releaseChartPath input
    , "chartDigest" .= digestText (contentDigest (releaseChartBytes input))
    , "valuesPath" .= releaseValuesPath input
    , "valuesDigest" .= digestText (contentDigest (releaseValuesBytes input))
    , "renderDigest" .= digestText (contentDigest (releaseRenderedBytes input))
    , "crdsDigest" .= fmap (digestText . contentDigest) (releaseCrdsBytes input)
    , "kubeVersion" .= releaseKubeVersion input
    , "apiVersions" .= releaseApiVersions input
    , "hookPolicy" .= ("include-rendered-hooks" :: Text)
    , "crdPolicy" .= ("conditional-direct-apply-and-helm-skip-crds" :: Text)
    ]
  release <- compileHelmRelease HelmInput
    { helmResourceId = releaseId input
    , helmOwner = releaseOwner input
    , helmCluster = releaseCluster input
    , helmNamespace = releaseNamespace input
    , helmName = releaseName input
    , helmMembers = addresses
    , helmNativeDigest = contentDigest contract
    , helmDependencies = releaseDependencies input
    , helmSource = source
    }
  pure (release, contract)
  where
    source = SourceLocation (T.pack (releaseChartPath input)) (nameText (releaseName input))
    invalid message = inventoryError "invalid-helm-release" message
      & #scopes .~ [releaseOwner input]
      & #resources .~ [releaseId input]
      & #sources .~ [source]
    memberAddress (_, value) = do
      root <- case value of
        Object fields -> Right fields
        _ -> Left (invalid "rendered Helm document must be an object")
      api <- stringField "apiVersion" root
      kind <- stringField "kind" root
      metadata <- case KM.lookup "metadata" root of
        Just (Object fields) -> Right fields
        _ -> Left (invalid "rendered Helm member has no metadata")
      name <- stringField "name" metadata
      namespace <- case KM.lookup "namespace" metadata of
        Just (String namespace) -> Right (Just namespace)
        Nothing | clusterScoped kind -> Right Nothing
        Nothing -> Right (Just (nameText (releaseNamespace input)))
        _ -> Left (invalid "rendered Helm namespace is malformed")
      first invalid (kubernetesAddress (releaseCluster input) api kind namespace name)
    stringField key fields = case KM.lookup key fields of
      Just (String value) -> Right value
      _ -> Left (invalid ("rendered Helm member has no " <> T.pack (show key)))
    clusterScoped kind = kind `elem`
      [ "APIService", "CertificateSigningRequest", "ClusterRole", "ClusterRoleBinding"
      , "CustomResourceDefinition", "CSIDriver", "CSINode", "IngressClass"
      , "MutatingWebhookConfiguration", "Namespace", "Node", "PersistentVolume"
      , "PodSecurityPolicy", "PriorityClass", "RuntimeClass", "StorageClass"
      , "ValidatingWebhookConfiguration", "VolumeAttachment", "ClusterIssuer"
      ]
