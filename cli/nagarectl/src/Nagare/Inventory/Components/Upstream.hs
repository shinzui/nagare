-- | Compile digest-pinned upstream release manifests to typed direct members.
-- The original YAML stays in the payload; review retains canonical native JSON.
module Nagare.Inventory.Components.Upstream
  ( UpstreamInput (..)
  , pinnedUpstreamInputs
  , configuredUpstreamInputs
  , compileUpstream
  ) where

import Control.Exception (IOException, try)
import Data.Aeson (Value (..), toJSON)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Yaml qualified as Yaml
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List (foldl')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import System.FilePath ((</>))

data UpstreamInput = UpstreamInput
  { upstreamOwner :: !ScopeId
  , upstreamCluster :: !ResourceId
  , upstreamKey :: !LogicalKey
  , upstreamRoot :: !FilePath
  , upstreamFiles :: ![(FilePath, ContentDigest)]
  , upstreamNamespaces :: !(Map Name ResourceId)
  , upstreamTransferred :: !(Set ProviderAddress)
  , upstreamConfigMapData :: !(Map ProviderAddress (Map Text (Maybe Text)))
  }

-- | The packaged release order is part of the bootstrap contract. A later
-- scope may contain custom resources served by an earlier release.
pinnedUpstreamInputs :: ResourceId -> FilePath -> [UpstreamInput]
pinnedUpstreamInputs cluster root =
  [ component "cert-manager"
      [("cluster/bootstrap/vendor/cert-manager-v1.20.2.yaml", "1ce11cae912adecc69e6bb623435fafc9ed21505f9efff98bd71d7b80f01db1f")]
      Set.empty
  , component "serving"
      [ ("cluster/bootstrap/vendor/serving-crds-v1.22.0.yaml", "b7876869026e571fe41cef6c7345f37f8190a80f6a23b45010981347f97f97bc")
      , ("cluster/bootstrap/vendor/serving-core-v1.22.0.yaml", "86049684cb235763fc230763f2a0ca740f47ed47119b7851fab2da96cec1bf6e")
      ]
      (Set.singleton (either (error . T.unpack) id
        (kubernetesAddress cluster "v1" "ConfigMap" (Just "knative-serving") "config-certmanager")))
  , component "kourier"
      [("cluster/bootstrap/vendor/kourier-v1.22.0.yaml", "6f050d6149020164e83aef96a4d9388534830b9c2943abdbbed816220fe8126c")]
      Set.empty
  , component "net-certmanager"
      [("cluster/bootstrap/vendor/net-certmanager-v1.14.0.yaml", "145ef639165b86a8ce8aa8eb62473961119374687633d05cfd1f52273ca6e702")]
      Set.empty
  ]
  where
    component name assets transferred = UpstreamInput
      { upstreamOwner = either (error . T.unpack) id (mkScopeId Platform name)
      , upstreamCluster = cluster
      , upstreamKey = either (error . T.unpack) id (mkLogicalKey name)
      , upstreamRoot = root
      , upstreamFiles = [(path, either (error . T.unpack) id (mkContentDigest digest)) | (path, digest) <- assets]
      , upstreamNamespaces = Map.empty
      , upstreamTransferred = transferred
      , upstreamConfigMapData = Map.empty
      }

-- | Bind the context's Knative policy into the reviewed release members.
-- Patch bodies are packaged policy inputs; they are parsed before any native
-- object is observed or changed. The caller supplies a resolved domain,
-- registry, and the correct cloud/local certificate patch.
configuredUpstreamInputs
  :: ResourceId -> FilePath -> Text -> Text -> FilePath
  -> IO (Either Text [UpstreamInput])
configuredUpstreamInputs cluster root baseDomain registryHost certificatePatch = do
  let allowedCertificatePatches =
        [ "cluster/bootstrap/knative-serving/config-certmanager.yaml"
        , "cluster/bootstrap/local-tls/config-certmanager-local.yaml"
        ]
  if certificatePatch `notElem` allowedCertificatePatches
    then pure (Left "Knative certificate patch is not a packaged cloud/local policy input")
    else do
      network <- readPatch "cluster/bootstrap/knative-serving/config-network.yaml"
      features <- readPatch "cluster/bootstrap/knative-serving/config-features.yaml"
      certificate <- readPatch certificatePatch
      pure $ do
        networkData <- network
        featureData <- features
        certificateData <- certificate
        unless (validHost baseDomain && baseDomain /= "svc.cluster.local")
          (Left "Knative base domain is empty or malformed")
        unless (validHost registryHost)
          (Left "Knative registry host is empty or malformed")
        case pinnedUpstreamInputs cluster root of
          [certManager, serving, kourier, net] -> Right
            [ certManager
            , serving {upstreamConfigMapData = Map.fromList
                [ (config "config-network", networkData)
                , (config "config-features", featureData)
                , (config "config-domain", Map.fromList [(baseDomain, Just ""), ("svc.cluster.local", Nothing)])
                , (config "config-deployment", Map.singleton "registriesSkippingTagResolving"
                    (Just ("kind.local,ko.local,dev.local," <> registryHost)))
                ]}
            , kourier
            , net {upstreamConfigMapData = Map.singleton (config "config-certmanager") certificateData}
            ]
          _ -> Left "pinned upstream release set is incomplete"
  where
    config name = either (error . T.unpack) id
      (kubernetesAddress cluster "v1" "ConfigMap" (Just "knative-serving") name)
    readPatch relative = do
      loaded <- try (BS.readFile (root </> relative)) :: IO (Either IOException ByteString)
      pure $ do
        bytes <- first (T.pack . show) loaded
        value <- first (T.pack . show) (Yaml.decodeEither' bytes)
        case value of
          Object top -> case KM.lookup "data" top of
            Just (Object entries) -> Map.fromList <$> traverse parseEntry (KM.toList entries)
            _ -> Left "Knative patch has no data object"
          _ -> Left "Knative patch is not an object"
    parseEntry (key, String value) = Right (Key.toText key, Just value)
    parseEntry _ = Left "Knative patch data must contain only strings"
    validHost value = not (T.null value)
      && T.all (\char -> char `elem` (['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'] <> ".-:")) value
      && not (T.isPrefixOf "." value || T.isSuffixOf "." value)

compileUpstream
  :: UpstreamInput
  -> IO (Either (NonEmpty InventoryError) (ResourceBundle, Map ResourceId (ManagedResource, ByteString)))
compileUpstream input = do
  loaded <- traverse loadOne (upstreamFiles input)
  pure $ do
    assets <- sequence loaded
    members <- concat <$> traverse compileAsset assets
    deduplicated <- foldl' keepIdentical (Right Map.empty) members
    let uniqueMembers = Map.elems deduplicated
        transferred = [resource ^. #address | (resource, _) <- uniqueMembers,
          Set.member (resource ^. #address) (upstreamTransferred input)]
        configured = [resource ^. #address | (resource, _) <- uniqueMembers,
          Map.member (resource ^. #address) (upstreamConfigMapData input)]
    unless (Set.fromList transferred == upstreamTransferred input)
      (Left (single (invalid "transferred upstream object is absent from the pinned release")))
    unless (Set.fromList configured == Map.keysSet (upstreamConfigMapData input))
      (Left (single (invalid "configured ConfigMap is absent from the pinned release")))
    let retained = filter (\(resource, _) -> Set.notMember (resource ^. #address) (upstreamTransferred input)) uniqueMembers
        namespaceIds = Map.fromList
          [(name, resource ^. #identity) | (resource, _) <- retained,
            Kubernetes _ "" kind Nothing name <- [resource ^. #address], nameText kind == "namespace"]
        dependencies = Map.union namespaceIds (upstreamNamespaces input)
        crdIds = [resource ^. #identity | (resource, _) <- retained, isCrd resource]
        prerequisites = [resource ^. #identity | (resource, _) <- retained,
          not (isCrd resource || isDeployment resource)]
        ordered = map (addDependencies dependencies crdIds prerequisites) retained
    let bundle = ResourceBundle (map (Managed . fst) ordered) [] [] [] [] []
    pure (bundle, Map.fromList [(resource ^. #identity, (resource, bytes)) | (resource, bytes) <- ordered])
  where
    invalid message = inventoryError "invalid-upstream-manifest" message
      & #scopes .~ [upstreamOwner input]
    single err = err :| []
    loadOne (relative, digest) = do
      readResult <- try (BS.readFile (upstreamRoot input </> relative)) :: IO (Either IOException ByteString)
      pure $ do
        bytes <- first (single . invalid . ("cannot read packaged upstream manifest: " <>) . T.pack . show) readResult
        unless (contentDigest bytes == digest)
          (Left (single (invalid "packaged upstream manifest differs from its pinned digest")))
        pure (relative, bytes)
    compileAsset (relative, bytes) = do
      objects <- first single (parseKubernetesManifest (SourceLocation (T.pack relative) "") bytes)
      traverse compileOne objects
    compileOne (location, value) = do
      sourceBytes <- first (single . invalid) (canonicalValue value)
      let temporary = mintResourceId (upstreamOwner input) (upstreamKey input) (known "probe")
          template = KubernetesInput temporary (upstreamOwner input) (upstreamCluster input)
            value (contentDigest sourceBytes) Retain Stateless (sensitivityOf value) location
      probed <- first single (compileKubernetesObject template)
      configured <- case Map.lookup (probed ^. #address) (upstreamConfigMapData input) of
        Nothing -> Right value
        Just entries -> first (single . invalid) (mergeConfigMapData entries value)
      native <- first (single . invalid) (canonicalValue configured)
      addressBytes <- first (single . invalid) (canonicalValue (toJSON (probed ^. #address)))
      let role = known ("object-" <> T.take 40 (digestText (contentDigest addressBytes)))
          identity = mintResourceId (upstreamOwner input) (upstreamKey input) role
          actual = template {resourceId = identity, inputObject = configured, objectDigest = contentDigest native}
      (resource, bound) <- first single (bindKubernetesObject actual)
      unless (bound == native) (Left (single (invalid "upstream native bytes changed during binding")))
      pure (resource, bound)
    known = either (error . T.unpack) id . mkName
    keepIdentical accumulated (resource, bytes) = do
      existing <- accumulated
      case Map.lookup (resource ^. #identity) existing of
        Nothing -> Right (Map.insert (resource ^. #identity) (resource, bytes) existing)
        Just (prior, priorBytes)
          | priorBytes == bytes
          , prior {source = resource ^. #source} == resource -> Right existing
          | otherwise -> Left (single (invalid ("upstream assets give different content to "
              <> resourceIdText (resource ^. #identity))))
    addDependencies dependencies crdIds prerequisites (resource, bound) =
      let namespaceEdges = case resource ^. #address of
            Kubernetes _ _ _ (Just namespaceName) _ ->
              maybe [] (pure . OrderedAfter) (Map.lookup namespaceName dependencies)
            _ -> []
          crdEdges = if isCrd resource then [] else map OrderedAfter crdIds
          prerequisiteEdges = if isDeployment resource then map OrderedAfter prerequisites else []
          own = resource ^. #identity
          edges = filter (/= OrderedAfter own) (namespaceEdges <> crdEdges <> prerequisiteEdges)
       in (resource {dependencies = Set.toList (Set.fromList edges <> Set.fromList (resource ^. #dependencies))}, bound)

isCrd :: ManagedResource -> Bool
isCrd resource = case resource ^. #address of
  Kubernetes _ "apiextensions.k8s.io" kind Nothing _ -> nameText kind == "customresourcedefinition"
  _ -> False

isDeployment :: ManagedResource -> Bool
isDeployment resource = case resource ^. #address of
  Kubernetes _ "apps" kind (Just _) _ -> nameText kind == "deployment"
  _ -> False

sensitivityOf :: Value -> Sensitivity
sensitivityOf (Object root) | KM.lookup "kind" root == Just (String "Secret") = Secret
sensitivityOf _ = Private

mergeConfigMapData :: Map Text (Maybe Text) -> Value -> Either Text Value
mergeConfigMapData entries (Object root)
  | KM.lookup "kind" root == Just (String "ConfigMap") = do
      current <- case KM.lookup "data" root of
        Just (Object dataFields) -> Right dataFields
        _ -> Left "configured upstream ConfigMap has no data object"
      let changed = foldl' (\fields (key, value) -> case value of
            Just textValue -> KM.insert (Key.fromText key) (String textValue) fields
            Nothing -> KM.delete (Key.fromText key) fields)
            current (Map.toAscList entries)
      pure (Object (KM.insert "data" (Object changed) root))
mergeConfigMapData _ _ = Left "upstream data overlay targets a non-ConfigMap object"
