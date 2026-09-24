-- | A standalone database is an independently replaceable scope. Its native
-- members come from the complete typed database builder, including credentials
-- and the scheduled backup for retained data.
module Nagare.Inventory.DataService
  ( compileStandaloneDatabase
  , compileStandaloneBroker
  ) where

import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (StoreBackend)
import Nagare.Dsl.Broker (Broker (..), BrokerProvider (Redpanda), brokerNameText)
import Nagare.Dsl.Broker.Render (brokerPvcName, renderBroker)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (namespaceText)
import Nagare.Inventory.Database (compileDatabaseForBackend)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Broker (brokerResourceId)
import Nagare.Resource.Database (DatabaseDirectInput (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (..), LifecyclePolicy (..), RecoveryIntent, Sensitivity (Private))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

compileStandaloneDatabase
  :: DatabaseDirectInput
  -> StoreBackend
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStandaloneDatabase input backend
  | scopeKind owner /= Standalone =
      Left (inventoryError "wrong-data-scope" "standalone database requires a standalone scope"
        & #scopes .~ [owner]
        & #sources .~ [directSourceLocation input]
        & (:| []))
  | otherwise = do
      (bundle, native) <- compileDatabaseForBackend input backend
      scope <- mkScopeDeclaration owner [bundle]
      pure (scope, native)
  where
    owner = directOwnerScope input

-- | Redpanda's three direct objects form one standalone data scope. The PVC
-- requires a recovery policy. Kafka topics are logical operations and cannot
-- silently disappear from a broker review.
compileStandaloneBroker
  :: Broker -> ScopeId -> ResourceId -> ResourceId -> RecoveryIntent -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStandaloneBroker broker owner cluster namespaceId recovery source = do
  unless (scopeKind owner == Standalone)
    (Left (invalid "broker requires a standalone scope"))
  unless (broker ^. #provider == Redpanda)
    (Left (invalid "broker provider has no native renderer"))
  unless (null (broker ^. #topics))
    (Left (invalid "broker topics require typed logical operations"))
  members <- traverse bindOne (zip ["pvc", "service", "statefulset"] (renderBroker broker))
  let bundle = ResourceBundle (map (Managed . fst) members) [] [] [] [] []
      native = Map.fromList [(member ^. #identity, pair) | pair@(member, _) <- members]
  scope <- mkScopeDeclaration owner [bundle]
  unless (Map.size native == length members)
    (Left (invalid "broker members share an identity"))
  pure (scope, native)
  where
    invalid message = inventoryError "invalid-standalone-broker" message
      & #scopes .~ [owner]
      & #sources .~ [source]
      & (:| [])
    bindOne (roleText, bytes) = do
      role <- first invalid (mkName roleText)
      resource <- first invalid (brokerResourceId owner role broker)
      value <- first (invalid . T.pack . show) (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
      canonical <- first invalid (canonicalValue value)
      (declaration, native) <- first (:| []) (bindKubernetesObject KubernetesInput
        { resourceId = resource
        , ownerScope = owner
        , clusterId = cluster
        , inputObject = value
        , objectDigest = contentDigest canonical
        , lifecyclePolicy = if roleText == "pvc" then Retain else DeleteWhenUnreferenced
        , inputDataPolicy = if roleText == "pvc" then Durable recovery else Stateless
        , inputSensitivity = Private
        , sourceLocation = source {path = path source <> "/broker/" <> roleText}
        })
      prerequisites <- if roleText == "statefulset"
        then traverse (\dependencyRole -> do
          name <- first invalid (mkName dependencyRole)
          first invalid (brokerResourceId owner name broker)) ["pvc", "service"]
        else Right []
      let expectedKind = case roleText of
            "pvc" -> "PersistentVolumeClaim"
            "service" -> "Service"
            _ -> "StatefulSet"
          expectedApi = if roleText == "statefulset" then "apps/v1" else "v1"
          brokerName = brokerNameText (broker ^. #name)
          expectedName = if roleText == "pvc" then brokerPvcName brokerName else brokerName
      expected <- first invalid (kubernetesAddress cluster expectedApi expectedKind
        (Just (namespaceText (broker ^. #namespace))) expectedName)
      unless (declaration ^. #address == expected)
        (Left (invalid "broker render has an unexpected native address"))
      pure (declaration {dependencies = map OrderedAfter (namespaceId : prerequisites)}, native)
