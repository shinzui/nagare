-- | Shared member binding for reviewed site scopes: one exact native
-- binding per rendered manifest, address checks, and typed Secret
-- dependencies. Production, preview, and protected routes all use these.
module Nagare.Inventory.Site.Member
  ( bindOne
  , checkAddress
  , reviewedBuildReference
  , siteSecretDependency
  )
where

import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (EnvScope (Build), SecretName, secretNameText)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (..), LifecyclePolicy (..), Sensitivity (Private))
import Nagare.Resource.Reference (Dependency)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- Build-only Secret references belong to the accepted OCI publication. A
-- mixed Build/Runtime or Build/Preview scope would place the same value in a
-- workload and needs a separate explicit binding, so it still refuses.
reviewedBuildReference :: Set.Set SecretName -> (SecretName, Set.Set EnvScope) -> Bool
reviewedBuildReference buildSecrets (secret, scopes)
  | Set.member Build scopes = scopes == Set.singleton Build && Set.member secret buildSecrets
  | otherwise = True

siteSecretDependency ::
  ResourceId ->
  T.Text ->
  Map SecretName Declaration ->
  SecretName ->
  Either T.Text ResourceId
siteSecretDependency cluster ns bindings secretName = do
  declaration <-
    maybe
      (Left "site Secret has no typed declaration")
      Right
      (Map.lookup secretName bindings)
  address <- case declaration of
    Managed member -> Right (member ^. #address)
    External _ externalAddress _ _ -> Right externalAddress
    ObservedChild _ _ _ _ _ -> Left "observed child cannot supply a site Secret"
  expected <-
    kubernetesAddress
      cluster
      "v1"
      "Secret"
      (Just ns)
      (secretNameText secretName)
  unless
    (address == expected)
    (Left "site Secret has a different cluster, namespace, or name")
  pure (declarationId declaration)

bindOne ::
  ScopeId ->
  ResourceId ->
  ResourceId ->
  LifecyclePolicy ->
  DataPolicy ->
  [Dependency] ->
  SourceLocation ->
  ByteString ->
  Either (NonEmpty InventoryError) (ManagedResource, ByteString)
bindOne owner cluster resourceId lifecycle policy prerequisites source bytes = do
  let invalid message =
        inventoryError "invalid-site-member" message
          & #sources
          .~ [source]
          & (:| [])
  value <-
    first
      (invalid . T.pack . show)
      (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
  canonical <- first invalid (canonicalValue value)
  (resource, native) <-
    first
      (:| [])
      ( bindKubernetesObject
          KubernetesInput
            { resourceId = resourceId
            , ownerScope = owner
            , clusterId = cluster
            , inputObject = value
            , objectDigest = contentDigest canonical
            , lifecyclePolicy = lifecycle
            , inputDataPolicy = policy
            , inputSensitivity = Private
            , sourceLocation = source
            }
      )
  pure (resource {dependencies = prerequisites}, native)

checkAddress ::
  (T.Text -> NonEmpty InventoryError) ->
  ResourceId ->
  T.Text ->
  T.Text ->
  T.Text ->
  T.Text ->
  (ManagedResource, ByteString) ->
  Either (NonEmpty InventoryError) ()
checkAddress invalid cluster version kind ns name (resource, _) = do
  expected <- first invalid (kubernetesAddress cluster version kind (Just ns) name)
  unless
    (resource ^. #address == expected)
    (Left (invalid "site render has an unexpected native address"))
