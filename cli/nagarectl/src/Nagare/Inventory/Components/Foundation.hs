-- | Direct cluster foundation objects owned by the platform. Namespace
-- labels are composed here so consumers cannot patch shared labels directly.
module Nagare.Inventory.Components.Foundation
  ( FoundationInput (..)
  , foundationNamespaceId
  , compileFoundation
  , compileContributedNamespaces
  ) where

import Control.Exception (IOException, try)
import Data.Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data FoundationInput = FoundationInput
  { foundationOwner :: !ScopeId
  , foundationCluster :: !ResourceId
  , foundationQuotaPath :: !FilePath
  , foundationGrantedScopes :: ![ScopeId]
  }

compileFoundation
  :: FoundationInput
  -> IO (Either (NonEmpty InventoryError) (ResourceBundle, Map ResourceId (ManagedResource, ByteString)))
compileFoundation input = do
  quotaFile <- try (BS.readFile (foundationQuotaPath input)) :: IO (Either IOException ByteString)
  pure $ do
    bytes <- first (single . invalid . ("could not read packaged Job quota: " <>) . T.pack . show) quotaFile
    quotaMembers <- first single (parseKubernetesManifest source bytes)
    quotaValue <- case quotaMembers of
      [(_, value)] -> Right value
      _ -> Left (single (invalid "Job quota source must contain one ResourceQuota"))
    namespaceMembers <- traverse namespace ["cert-manager", "knative-serving", "kourier-system", "personal", "nagare-system"]
    quotaMember <- compileMember "job-quota" quotaValue [OrderedAfter (identityFor "namespace-personal")]
    let (quotaResource, _, _) = quotaMember
    unless (quotaResource ^. #address == Kubernetes (foundationCluster input) "" (known "resourcequota")
        (Just (known "personal")) (known "nagare-terminating-jobs"))
      (Left (single (invalid "Job quota has an unexpected Kubernetes address")))
    let members = namespaceMembers <> [quotaMember]
        bundle = ResourceBundle (map (Managed . fst3) members) [] [] [] []
          [NamespaceGrant scope (foundationCluster input) | scope <- foundationGrantedScopes input]
    pure (bundle, Map.fromList [(resource ^. #identity, (resource, native)) | (resource, native, _) <- members])
  where
    source = SourceLocation (T.pack (foundationQuotaPath input)) "foundation"
    known = either (error . T.unpack) id . mkName
    identityFor role = mintResourceId (foundationOwner input) (either (error . T.unpack) id (mkLogicalKey "foundation")) (known role)
    invalid message = inventoryError "invalid-foundation" message
      & #scopes .~ [foundationOwner input]
      & #sources .~ [source]
    single err = err :| []
    fst3 (a, _, _) = a
    namespace name = compileMember ("namespace-" <> name) (object
      [ "apiVersion" .= ("v1" :: Text)
      , "kind" .= ("Namespace" :: Text)
      , "metadata" .= object
          [ "name" .= (name :: Text)
          , "labels" .= object
              (["app.kubernetes.io/part-of" .= ("nagare" :: Text)]
                <> ["nagare.dev/app-namespace" .= ("true" :: Text) | name == "personal"])
          ]
      ]) []
    compileMember role value dependencies = do
      native <- first (single . invalid) (canonicalValue value)
      let resourceId = identityFor role
      (resource, bound) <- first single (bindKubernetesObject KubernetesInput
        { resourceId = resourceId
        , ownerScope = foundationOwner input
        , clusterId = foundationCluster input
        , inputObject = value
        , objectDigest = contentDigest native
        , lifecyclePolicy = Retain
        , inputDataPolicy = Stateless
        , inputSensitivity = Private
        , sourceLocation = source
        })
      unless (bound == native) (Left (single (invalid "foundation native bytes changed during binding")))
      pure (resource {dependencies = dependencies}, bound, value)

foundationNamespaceId :: FoundationInput -> Name -> ResourceId
foundationNamespaceId input namespaceName =
  mintResourceId (foundationOwner input)
    (either (error . T.unpack) id (mkLogicalKey "foundation"))
    (either (error . T.unpack) id (mkName ("namespace-" <> nameText namespaceName)))

-- | Materialize only the closed namespace contribution shape emitted by the
-- pure inventory composer. Its owner has already granted the contributor.
compileContributedNamespaces
  :: [Declaration]
  -> Either Text (Map ResourceId (ManagedResource, ByteString))
compileContributedNamespaces declarations = Map.fromList <$> traverse compileOne contributed
  where
    contributed =
      [resource | Managed resource <- declarations,
        resource ^. #spec == NamespaceSpec Nothing,
        resource ^. #source . #file == "contribution"]
    compileOne resource = do
      (cluster, namespaceName) <- case resource ^. #address of
        Kubernetes target "" kind Nothing name | nameText kind == "namespace" -> Right (target, name)
        _ -> Left "contributed namespace has an unexpected address"
      let value = object
            [ "apiVersion" .= ("v1" :: Text)
            , "kind" .= ("Namespace" :: Text)
            , "metadata" .= object
                [ "name" .= nameText namespaceName
                , "labels" .= object ["nagare.dev/app-namespace" .= ("true" :: Text)]
                ]
            ]
      bytes <- canonicalValue value
      (compiled, bound) <- first (T.pack . show) (bindKubernetesObject KubernetesInput
        { resourceId = resource ^. #identity
        , ownerScope = resource ^. #owner
        , clusterId = cluster
        , inputObject = value
        , objectDigest = contentDigest bytes
        , lifecyclePolicy = resource ^. #lifecycle
        , inputDataPolicy = resource ^. #dataPolicy
        , inputSensitivity = resource ^. #sensitivity
        , sourceLocation = resource ^. #source
        })
      unless (compiled {spec = NamespaceSpec Nothing, dependencies = resource ^. #dependencies} == resource
          && bound == bytes)
        (Left "contributed namespace native object differs from its typed declaration")
      pure (resource ^. #identity, (resource, bound))
