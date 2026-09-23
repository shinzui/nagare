-- | Compile digest-pinned upstream release manifests to typed direct members.
-- The original YAML stays in the payload; review retains canonical native JSON.
module Nagare.Inventory.Components.Upstream
  ( UpstreamInput (..)
  , compileUpstream
  ) where

import Control.Exception (IOException, try)
import Data.Aeson (Value (..), toJSON)
import Data.Aeson.KeyMap qualified as KM
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
  }

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
    unless (Set.fromList transferred == upstreamTransferred input)
      (Left (single (invalid "transferred upstream object is absent from the pinned release")))
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
      native <- first (single . invalid) (canonicalValue value)
      let temporary = mintResourceId (upstreamOwner input) (upstreamKey input) (known "probe")
          template = KubernetesInput temporary (upstreamOwner input) (upstreamCluster input)
            value (contentDigest native) Retain Stateless (sensitivityOf value) location
      probed <- first single (compileKubernetesObject template)
      addressBytes <- first (single . invalid) (canonicalValue (toJSON (probed ^. #address)))
      let role = known ("object-" <> T.take 40 (digestText (contentDigest addressBytes)))
          identity = mintResourceId (upstreamOwner input) (upstreamKey input) role
          actual = template {resourceId = identity}
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
