-- | Compile the exact Helm post-renderer input into a release claim. Chart
-- archives and values are packaged inputs; the captured render is private.
module Nagare.Inventory.Components.Observability
  ( ObservabilityReleaseInput (..)
  , PackagedHelmInput (..)
  , capturePackagedRelease
  , compileRenderedRelease
  , pinnedObservabilityInputs
  , compilePinnedObservability
  ) where

import Control.Exception (IOException, try)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Helm
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes
import Nagare.Resource.Policy (LifecyclePolicy (Protect), DataPolicy (Stateless), Sensitivity (Private))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import System.Directory (createDirectory, createDirectoryLink, makeAbsolute)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode)

pinnedObservabilityInputs :: ResourceId -> FilePath -> Text -> [PackagedHelmInput]
pinnedObservabilityInputs cluster root kubeVersion =
  [ pinned "vmks" "monitoring" "victoria-metrics-k8s-stack-0.81.0.tgz"
      "34e2dfafb05dfdcf85aac05c8e61fa5e2f2dd33672422d4e09c066e09b664c13"
      "victoria-metrics/values.yaml" "5d71af726d8edf01571ee98b182f6ba4fd8eba7088b35d16e71b6460f82f3e57"
  , pinned "victoria-logs" "logging" "victoria-logs-single-0.13.5.tgz"
      "b08975ef8b9f47e707df41e81cc55621baee9073a49de75a480bb98345502f61"
      "victoria-logs/values.yaml" "a4d2847c50a84b7d50cb4e7df85bec50b2edc716e07716a6c30a6f0830b97a59"
  , pinned "victoria-logs-collector" "logging" "victoria-logs-collector-0.3.4.tgz"
      "2196ce5622722268fc1efb430393e9993f42905a85a4451d8e3465343ff0dc6c"
      "victoria-logs/collector-values.yaml" "5c5d7e7fe34be9a73e77674ca351c79906ce2b031b2e0641c752a2fdd967ec6e"
  , pinned "victoria-traces" "tracing" "victoria-traces-single-0.1.6.tgz"
      "3fd7b2e2625590d4ffcbfe358a9f74fc9fc860c9d9485974ac162d4cd196fc74"
      "victoria-traces/values.yaml" "73a59e064b60912d44c14bdb59aa35e5c17aecb8ceb4a7ceeb3749d9d5d32dda"
  , pinned "otel-collector" "tracing" "opentelemetry-collector-0.158.0.tgz"
      "b0c8f6b8f3eff6bc14af492a8f30df3353a685eae28aca3855559c6d20d76d39"
      "opentelemetry-collector/values.yaml" "ebd92c3ae2b0f6e224b04bfa3be201f1c799e59a61f0a52856c5a4492c1054d5"
  ]
  where
    checked constructor value = either (error . T.unpack) id (constructor value)
    pinned release namespace archive archiveDigest values valuesDigest =
      let owner = checked (mkScopeId Platform) ("observability-" <> release)
          name = checked mkName release
      in PackagedHelmInput
        { packagedReleaseId = mintResourceId owner (checked mkLogicalKey "observability") (checked mkName "release")
        , packagedOwner = owner
        , packagedCluster = cluster
        , packagedNamespace = checked mkName namespace
        , packagedName = name
        , packagedChart = root </> "cluster/observability/vendor" </> archive
        , packagedChartDigest = checked mkContentDigest archiveDigest
        , packagedValues = root </> "cluster/observability" </> values
        , packagedValuesDigest = checked mkContentDigest valuesDigest
        , packagedPlugin = root </> "cluster/observability/helm-review/capture"
        , packagedKubeVersion = kubeVersion
        , packagedApiVersions = []
        , packagedDependencies = []
        }

compilePinnedObservability
  :: ScopeId
  -> [PackagedHelmInput]
  -> IO (Either (NonEmpty InventoryError) ([ScopeDeclaration], Map ResourceId (ManagedResource, ByteString)))
compilePinnedObservability foundationOwner inputs = do
  compiled <- traverse one inputs
  pure $ do
    entries <- sequence compiled
    pure (map fst entries, Map.unions (map snd entries))
  where
    one input = do
      captured <- capturePackagedRelease input
      pure $ do
        render <- first (single . invalid input) captured
        (release, native) <- first single (compileRenderedRelease render)
        crds <- first single (compileCrds render)
        let namespaceContribution = RegisterNamespace foundationOwner (packagedCluster input)
              (packagedNamespace input) (knownKey "namespace")
            namespaceId = mintResourceId foundationOwner
              (knownKey (nameText (packagedNamespace input))) (knownName "namespace")
            orderedRelease = release {dependencies = map (OrderedAfter . (^. #identity) . fst) crds
              <> [OrderedAfter namespaceId] <> release ^. #dependencies}
            bundle = ResourceBundle (map (Managed . fst) crds <> [Managed orderedRelease])
              [] [] [namespaceContribution] [] []
        scope <- mkScopeDeclaration (packagedOwner input) [bundle]
        pure (scope, Map.fromList ([(resource ^. #identity, (resource, bytes)) | (resource, bytes) <- crds]
          <> [(orderedRelease ^. #identity, (orderedRelease, native))]))
    invalid input message = inventoryError "invalid-observability-release" message
      & #scopes .~ [packagedOwner input]
      & #resources .~ [packagedReleaseId input]
    single err = err :| []
    knownKey value = either (error . T.unpack) id (mkLogicalKey value)
    knownName value = either (error . T.unpack) id (mkName value)

data PackagedHelmInput = PackagedHelmInput
  { packagedReleaseId :: !ResourceId
  , packagedOwner :: !ScopeId
  , packagedCluster :: !ResourceId
  , packagedNamespace :: !Name
  , packagedName :: !Name
  , packagedChart :: !FilePath
  , packagedChartDigest :: !ContentDigest
  , packagedValues :: !FilePath
  , packagedValuesDigest :: !ContentDigest
  , packagedPlugin :: !FilePath
  , packagedKubeVersion :: !Text
  , packagedApiVersions :: ![Text]
  , packagedDependencies :: ![Dependency]
  }

-- | Capture the exact Helm 4 post-renderer input. Helm emits chart CRDs
-- outside that boundary, so `helm show crds` supplies their separate claim.
capturePackagedRelease :: PackagedHelmInput -> IO (Either Text ObservabilityReleaseInput)
capturePackagedRelease input = do
  chart <- try (BS.readFile (packagedChart input)) :: IO (Either IOException ByteString)
  values <- try (BS.readFile (packagedValues input)) :: IO (Either IOException ByteString)
  case (chart, values) of
    (Left failure, _) -> pure (Left (T.pack (show failure)))
    (_, Left failure) -> pure (Left (T.pack (show failure)))
    (Right chartBytes, Right valuesBytes)
      | contentDigest chartBytes /= packagedChartDigest input -> pure (Left "packaged Helm chart digest differs")
      | contentDigest valuesBytes /= packagedValuesDigest input -> pure (Left "packaged Helm values digest differs")
      | T.null (packagedKubeVersion input) -> pure (Left "Helm Kubernetes capability version is empty")
      | otherwise -> do
          attempted <- try (withSystemTempDirectory "nagare-helm-capture" $ \temporary -> do
            let plugins = temporary </> "plugins"
                capture = temporary </> "capture.yaml"
            createDirectory plugins
            pluginPath <- makeAbsolute (packagedPlugin input)
            createDirectoryLink pluginPath (plugins </> "nagare-capture-manifests")
            environment <- getEnvironment
            let clean = filter (\(key, _) -> key `notElem` ["HELM_PLUGINS", "NAGARE_HELM_CAPTURE_PATH"]) environment
                chartPath = packagedChart input
                valuesPath = packagedValues input
                release = T.unpack (nameText (packagedName input))
                base = ["template", release, chartPath, "--namespace", T.unpack (nameText (packagedNamespace input))
                  , "--values", valuesPath, "--kube-version", T.unpack (packagedKubeVersion input)
                  , "--skip-crds", "--post-renderer", "nagare-capture-manifests"]
                arguments = base <> concatMap (\version -> ["--api-versions", T.unpack version]) (packagedApiVersions input)
            (renderCode, _, renderError) <- readCreateProcessWithExitCode
              ((proc "helm" arguments) {env = Just (("HELM_PLUGINS", plugins) : ("NAGARE_HELM_CAPTURE_PATH", capture) : clean)}) ""
            case renderCode of
              ExitFailure _ -> pure (Left ("Helm render refused: " <> T.pack renderError))
              ExitSuccess -> do
                rendered <- BS.readFile capture
                (crdCode, crdOutput, crdError) <- readCreateProcessWithExitCode
                  (proc "helm" ["show", "crds", chartPath]) ""
                pure $ case crdCode of
                  ExitFailure _ -> Left ("Helm CRD inspection refused: " <> T.pack crdError)
                  ExitSuccess -> Right ObservabilityReleaseInput
                    { releaseId = packagedReleaseId input
                    , releaseOwner = packagedOwner input
                    , releaseCluster = packagedCluster input
                    , releaseNamespace = packagedNamespace input
                    , releaseName = packagedName input
                    , releaseChartPath = chartPath
                    , releaseChartBytes = chartBytes
                    , releaseValuesPath = valuesPath
                    , releaseValuesBytes = valuesBytes
                    , releaseRenderedBytes = rendered
                    , releaseCrdsBytes = if null crdOutput then Nothing else Just (TE.encodeUtf8 (T.pack crdOutput))
                    , releaseKubeVersion = packagedKubeVersion input
                    , releaseApiVersions = packagedApiVersions input
                    , releaseDependencies = packagedDependencies input
                    }) :: IO (Either IOException (Either Text ObservabilityReleaseInput))
          pure (either (Left . T.pack . show) id attempted)

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
  members <- traverse memberAddress rendered
  crdDocuments <- maybe (Right []) (parseKubernetesManifest (source {path = "crds"})) (releaseCrdsBytes input)
  crdAddresses <- traverse memberAddress crdDocuments
  unless (null [address | address <- crdAddresses, address `elem` members])
    (Left (invalid "Helm render repeats an independently managed chart CRD"))
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

compileCrds :: ObservabilityReleaseInput -> Either InventoryError [(ManagedResource, ByteString)]
compileCrds input = do
  crds <- maybe (Right []) (parseKubernetesManifest source) (releaseCrdsBytes input)
  traverse one crds
  where
    source = SourceLocation (T.pack (releaseChartPath input)) "crds"
    invalid message = inventoryError "invalid-helm-crd" message
      & #scopes .~ [releaseOwner input]
      & #sources .~ [source]
    one (location, value) = do
      root <- case value of
        Object fields -> Right fields
        _ -> Left (invalid "Helm CRD source contains a non-object")
      unless (KM.lookup "kind" root == Just (String "CustomResourceDefinition"))
        (Left (invalid "Helm CRD source contains another kind"))
      metadata <- case KM.lookup "metadata" root of
        Just (Object fields) -> Right fields
        _ -> Left (invalid "Helm CRD has no metadata")
      name <- case KM.lookup "name" metadata of
        Just (String value) -> first invalid (mkName value)
        _ -> Left (invalid "Helm CRD has no name")
      native <- first invalid (canonicalValue value)
      bindKubernetesObject KubernetesInput
        { resourceId = mintResourceId (releaseOwner input) (knownKey "chart-crds") name
        , ownerScope = releaseOwner input
        , clusterId = releaseCluster input
        , inputObject = value
        , objectDigest = contentDigest native
        , lifecyclePolicy = Protect
        , inputDataPolicy = Stateless
        , inputSensitivity = Private
        , sourceLocation = location
        }
    knownKey value = either (error . T.unpack) id (mkLogicalKey value)
