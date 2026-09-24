-- | Compile application-owned databases from the full typed Application.
-- Every direct object, credential template, and retained backup joins the
-- application's scope; the caller later adds workload and contribution bundles.
module Nagare.Inventory.Application
  ( compileApplicationDatabases
  , compileApplicationService
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
import Nagare.App.Deploy (RolloutEnv, renderServiceObjects)
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Database (Database (..))
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (DatabaseName, databaseNameText)
import Nagare.Inventory.Database (compileDatabaseForBackend)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Application (applicationScopeId, deploymentResourceId)
import Nagare.Resource.Database (DatabaseDirectInput (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced), Sensitivity (Private))
import Nagare.Resource.Policy (RecoveryIntent)
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- | The service member of an application scope. Volume claims and domain
-- mappings remain separate members; refuse them until their typed builders
-- exist rather than returning a scope that silently omits those resources.
compileApplicationService
  :: Application -> RolloutEnv -> ResourceId -> ResourceId -> ResourceId
  -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
compileApplicationService app rollout cluster namespaceId imageId source = do
  owner <- first invalid (applicationScopeId app)
  service <- maybe (Left (invalid "application has no web service")) Right (app ^. #service)
  unless (null (service ^. #volumes) && null (service ^. #domains))
    (Left (invalid "service volumes and domains require their own typed members"))
  resource <- first invalid (deploymentResourceId owner (known "service") service)
  rendered <- first invalid (renderServiceObjects rollout service)
  bytes <- case rendered of
    [("service", manifest)] -> Right manifest
    _ -> Left (invalid "application service renderer produced unexpected members")
  value <- first (invalid . T.pack . show) (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
  canonical <- first invalid (canonicalValue value)
  (declaration, native) <- first single (bindKubernetesObject KubernetesInput
    { resourceId = resource
    , ownerScope = owner
    , clusterId = cluster
    , inputObject = value
    , objectDigest = contentDigest canonical
    , lifecyclePolicy = DeleteWhenUnreferenced
    , inputDataPolicy = Stateless
    , inputSensitivity = Private
    , sourceLocation = source
    })
  let guarded = declaration {dependencies = [OrderedAfter namespaceId, OrderedAfter imageId]}
  pure (ResourceBundle [Managed guarded] [] [] [] [] [], Map.singleton resource (guarded, native))
  where
    known = either (error . T.unpack) id . mkName
    invalid message = single (inventoryError "invalid-application-service" message
      & #sources .~ [source])
    single errorValue = errorValue :| []

compileApplicationDatabases
  :: Application
  -> ResourceId
  -> Maybe ResourceId
  -> Map DatabaseName RecoveryIntent
  -> StoreBackend
  -> SourceLocation
  -> Either (NonEmpty InventoryError)
       ([ResourceBundle], Map ResourceId (ManagedResource, ByteString))
compileApplicationDatabases app cluster namespaceId recoveryByDatabase backend source = do
  _ <- first invalidApp (mkApplication app)
  owner <- first invalidApp (applicationScopeId app)
  compiled <- traverse (compileOne owner) (app ^. #databases)
  let bundles = map fst compiled
      native = Map.unions (map snd compiled)
  -- Validate the combined member set, including duplicate logical keys that
  -- individual database builders cannot see across separate databases.
  _ <- mkScopeDeclaration owner bundles
  unless (Map.size native == sum (map (Map.size . snd) compiled))
    (Left (single (inventoryError "duplicate-app-database" "database native members share an identity"
      & #scopes .~ [owner] & #sources .~ [source])))
  pure (bundles, native)
  where
    invalidApp message = single (inventoryError "invalid-application" message
      & #sources .~ [source])
    single errorValue = errorValue :| []
    compileOne owner database = do
      recovery <- maybe
        (Left (single (inventoryError "missing-database-recovery" "application database has no recovery intent"
          & #scopes .~ [owner]
          & #sources .~ [source])))
        Right (Map.lookup (database ^. #name) recoveryByDatabase)
      let databaseSource = source
            {path = path source <> "/database/" <> databaseNameText (database ^. #name)}
          input = DatabaseDirectInput database owner cluster namespaceId recovery databaseSource
      compileDatabaseForBackend input backend
