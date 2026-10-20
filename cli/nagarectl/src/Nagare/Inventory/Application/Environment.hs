-- | Environment responsibilities; internal implementation behind Nagare.Inventory.Application.
module Nagare.Inventory.Application.Environment
  ( databaseDependencies
  , declaredConnectionEnv
  , reviewedTaskImages
  , runtimeSecretNames
  , runtimeSecretNamesWithBuild
  , secretDependency
  , standaloneBrokerEnvironment
  , standaloneDatabaseEnvironment
  , workloadDatabaseNames
  , appDatabaseReaderKey
  , stripBuildSecretEnv
  , stripBuildSecretRefs
  , stripBuildSecretRollout
  )
where

import Control.Monad (forM_)
import Data.Generics.Labels ()
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.App.Deploy (RolloutEnv)
import Nagare.Broker.Connection
  ( BrokerConn (..)
  , brokerConnectionEnv
  , mergeBrokerConnectionEnvs
  )
import Nagare.Database.Connection
  ( ConnIdentity (..)
  , connectionEnv
  , mergeConnectionEnvs
  )
import Nagare.Dsl.Application (Application)
import Nagare.Dsl.Broker
  ( BrokerBinding
  , BrokerName
  , BrokerProvider (Redpanda)
  , TopicName
  , brokerNameText
  )
import Nagare.Dsl.Database (Engine (..), dbSecretName)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Task (Task)
import Nagare.Dsl.Types
  ( AppDatabaseName
  , AppDatabaseReaderRef
  , DatabaseName
  , EnvScope (Build, Runtime)
  , EnvVar (EnvLiteral, EnvSecretRef)
  , Namespace
  , ScopedEnvVar
  , SecretName
  , appDatabaseNameText
  , databaseNameText
  , mkDatabaseName
  , mkEnvName
  , mkSecretName
  , namespaceText
  , readerNameText
  , runtimeScoped
  , secretNameText
  )
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Application.Bindings (appDatabaseReaderKey, brokerEvidenceIds)
import Nagare.Inventory.Application.Types (AppDatabaseBound (..), DatabaseBinding (..), ServerBinding (..))
import Nagare.Resource.Database (databaseResourceId)
import Nagare.Resource.Inventory (Declaration (..), declarationId)
import Nagare.Resource.Types
  ( InventoryError
  , ProviderAddress (Kubernetes)
  , ResourceId
  , ScopeId
  , ScopeKind (Standalone)
  , kubernetesAddress
  , mkName
  , nameText
  , scopeKind
  )
import Nagare.Task.Resolve (resolveTaskImage)

-- | A scheduled CronJob may join a reviewed application rollout only when
-- its resolved image is the publication already accepted for that rollout.
-- Explicit task images can otherwise bypass the image dependency in the
-- compiled declaration.
reviewedTaskImages :: [Task] -> T.Text -> T.Text -> Either T.Text ()
reviewedTaskImages tasks taggedImage effectiveTag =
  forM_ tasks $ \task ->
    unless
      (resolveTaskImage taggedImage effectiveTag task == taggedImage)
      (Left "scheduled task resolves to an image outside the accepted application publication")

secretDependency :: ResourceId -> T.Text -> Map SecretName Declaration -> SecretName -> Either T.Text ResourceId
secretDependency cluster namespaceName bindings secretName = do
  secret <-
    maybe
      (Left "Secret reference has no typed declaration")
      Right
      (Map.lookup secretName bindings)
  secretAddress <- case secret of
    Managed managed -> Right (managed ^. #address)
    External _ address _ _ -> Right address
    ObservedChild _ _ _ _ _ -> Left "observed child cannot supply a Secret dependency"
  expected <-
    kubernetesAddress
      cluster
      "v1"
      "Secret"
      (Just namespaceName)
      (secretNameText secretName)
  unless
    (secretAddress == expected)
    (Left "Secret dependency has a different cluster, namespace, or name")
  pure (declarationId secret)

runtimeSecretNames :: [ScopedEnvVar] -> Either T.Text [SecretName]
runtimeSecretNames = runtimeSecretNamesWithBuild Set.empty

runtimeSecretNamesWithBuild ::
  Set.Set SecretName -> [ScopedEnvVar] -> Either T.Text [SecretName]
runtimeSecretNamesWithBuild buildSecrets entries =
  Set.toList . Set.fromList . concat <$> traverse one entries
  where
    one entry = case entry ^. #value of
      EnvLiteral _ -> Right []
      EnvSecretRef secret
        | entry ^. #scopes == Set.singleton Runtime -> Right [secret]
        | entry ^. #scopes == Set.singleton Build
            && Set.member secret buildSecrets ->
            Right []
        | otherwise -> Left "Secret-backed build or preview environment requires a separate reviewed input channel"

-- Build-only Secret references belong to the image publication. Removing
-- them from the runtime render input preserves the original typed config
-- digest while keeping their names out of workload manifests.
stripBuildSecretRefs :: Application -> Application
stripBuildSecretRefs app =
  app
    & #env
    %~ stripBuildSecretEnv
    & #service
    %~ fmap
      ( \service ->
          service
            & #env
            %~ stripBuildSecretEnv
            & #tasks
            %~ map stripTask
      )
    & #workers
    %~ map (\worker -> worker & #env %~ stripBuildSecretEnv)
    & #tasks
    %~ map stripTask
  where
    stripTask task = task & #env %~ stripBuildSecretEnv

stripBuildSecretEnv :: Map Dsl.EnvName ScopedEnvVar -> Map Dsl.EnvName ScopedEnvVar
stripBuildSecretEnv =
  Map.filter
    ( \entry -> case entry ^. #value of
        EnvSecretRef _ -> entry ^. #scopes /= Set.singleton Build
        _ -> True
    )

stripBuildSecretRollout :: RolloutEnv -> RolloutEnv
stripBuildSecretRollout rollout = rollout & #appEnv %~ stripBuildSecretEnv

-- | A reviewed workload can derive non-secret connection fields from its typed
-- database and reference generated credential fields by Secret key. No live
-- Secret read or password value enters compilation or the public review.
declaredConnectionEnv :: Application -> [DatabaseName] -> Either T.Text (Map Dsl.EnvName ScopedEnvVar)
declaredConnectionEnv app names = do
  maps <- traverse one names
  mergeConnectionEnvs maps
  where
    one databaseName = do
      database <-
        maybe
          (Left "workload references an undeclared database")
          Right
          (find ((== databaseName) . (^. #name)) (app ^. #databases))
      databaseConnectionEnv (database ^. #engine) databaseName (app ^. #namespace)

databaseConnectionEnv ::
  Engine ->
  DatabaseName ->
  Namespace ->
  Either T.Text (Map Dsl.EnvName ScopedEnvVar)
databaseConnectionEnv engine databaseName namespace = do
  let secretText = dbSecretName (databaseNameText databaseName)
      base = connectionEnv engine databaseName namespace (ConnIdentity Nothing Nothing)
      extra = case engine of
        Postgres -> ["POSTGRES_USER", "POSTGRES_DB"]
        Redis -> []
        ClickHouse -> ["CLICKHOUSE_USER"]
  secret <- mkSecretName secretText
  fields <-
    traverse
      ( \name -> do
          key <- mkEnvName name
          pure (key, runtimeScoped (EnvSecretRef secret))
      )
      extra
  pure (Map.union (Map.fromList fields) base)

-- | The binding keys of a workload: the servers it binds directly, the app
-- databases it names (EP-202) and the readers it binds (EP-206, as
-- @\<appdb\>-reader-\<name\>@), which share one key space.
workloadDatabaseNames :: [DatabaseName] -> [AppDatabaseName] -> [AppDatabaseReaderRef] -> Either T.Text [DatabaseName]
workloadDatabaseNames direct apps readers = do
  appKeys <- traverse (mkDatabaseName . appDatabaseNameText) apps
  readerKeys <- traverse (mkDatabaseName . appDatabaseReaderKey) readers
  let keys = direct <> appKeys <> readerKeys
  unless (length keys == Set.size (Set.fromList keys)) (Left "a workload names one database twice across databases and appDatabases")
  pure keys

-- | Supply generated connection fields and exact resource dependencies for
-- separately owned databases. The binding witness can only come from accepted
-- scope history and the original private native credential template.
standaloneDatabaseEnvironment ::
  ResourceId ->
  Namespace ->
  [DatabaseName] ->
  Map DatabaseName DatabaseBinding ->
  (T.Text -> NonEmpty InventoryError) ->
  Either
    (NonEmpty InventoryError)
    (Map Dsl.EnvName ScopedEnvVar, [ResourceId], Map SecretName Declaration)
standaloneDatabaseEnvironment cluster namespace names bindings invalid = do
  unless
    ( length names == Map.size bindings
        && Map.keysSet bindings == Set.fromList names
    )
    (Left (invalid "database dependencies must cover exactly the workload bindings"))
  rows <- traverse one names
  env <- first invalid (mergeConnectionEnvs [fields | (fields, _, _) <- rows])
  pure
    ( env
    , concat [resources | (_, resources, _) <- rows]
    , Map.fromList [secret | (_, _, secret) <- rows]
    )
  where
    namespaceName = namespaceText namespace
    one name = do
      binding <-
        maybe
          (Left (invalid "database has no accepted binding"))
          Right
          (Map.lookup name bindings)
      case binding of
        ServerDatabaseBinding server -> direct name server
        AppDatabaseBinding app -> appDatabase app
    -- EP-202: the runtime credential is the only Secret; host and port are
    -- the shared server's, and the workload waits for the users and databases.
    appDatabase app = do
      let service = appService app
          credential = appRuntimeCredential app
      expectedCredential <- first invalid (kubernetesAddress cluster "v1" "Secret" (Just namespaceName) (appCredentialName app))
      host <- case service ^. #address of
        Kubernetes _ "" kind (Just serviceNamespace) serviceName
          | nameText kind == "service" -> Right (nameText serviceName <> "." <> nameText serviceNamespace <> ".svc.cluster.local")
        _ -> Left (invalid "app database binding has no server Service address")
      unless
        (credential ^. #address == expectedCredential && scopeKind (credential ^. #owner) == Standalone)
        (Left (invalid "app database binding has a different runtime credential"))
      secretName <- first invalid (mkSecretName (appCredentialName app))
      let lit key value = (,runtimeScoped (EnvLiteral value)) <$> mkEnvName key
          ref key = (,runtimeScoped (EnvSecretRef secretName)) <$> mkEnvName key
      fields <-
        first invalid . fmap Map.fromList . sequence $ case appEngine app of
          ClickHouse -> [lit "CLICKHOUSE_HOST" host, lit "CLICKHOUSE_PORT" "9000"] <> map ref ["CLICKHOUSE_USER", "CLICKHOUSE_PASSWORD", "CLICKHOUSE_DB", "CLICKHOUSE_URL"]
          _ -> [lit "POSTGRES_HOST" host, lit "POSTGRES_PORT" "5432"] <> map ref ["POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB", "DATABASE_URL"]
      pure (fields, map (^. #identity) (appMembers app), (secretName, Managed credential))
    direct name server = do
      let binding = server
          service = boundService binding
          stateful = boundStatefulSet binding
          credential = boundCredential binding
          dbName = databaseNameText name
          owners = map (^. #owner) [service, stateful, credential]
      expectedService <-
        first
          invalid
          ( kubernetesAddress
              cluster
              "v1"
              "Service"
              (Just namespaceName)
              dbName
          )
      expectedStateful <-
        first
          invalid
          ( kubernetesAddress
              cluster
              "apps/v1"
              "StatefulSet"
              (Just namespaceName)
              dbName
          )
      expectedCredential <-
        first
          invalid
          ( kubernetesAddress
              cluster
              "v1"
              "Secret"
              (Just namespaceName)
              (dbSecretName dbName)
          )
      unless
        ( map (^. #address) [service, stateful, credential]
            == [expectedService, expectedStateful, expectedCredential]
            && all (== service ^. #owner) owners
            && scopeKind (service ^. #owner) == Standalone
        )
        (Left (invalid "database binding has a different owner or native address"))
      secretName <- first invalid (mkSecretName (dbSecretName dbName))
      fields <- first invalid (databaseConnectionEnv (boundEngine binding) name namespace)
      pure (fields, [stateful ^. #identity], (secretName, Managed credential))

-- | A workload may refer only to databases declared in this application.
-- Ordering it after the StatefulSet records the typed lifecycle edge, while
-- the database builder owns the lower-level credential and PVC prerequisites.
databaseDependencies ::
  Application ->
  ScopeId ->
  [DatabaseName] ->
  (T.Text -> NonEmpty InventoryError) ->
  Either (NonEmpty InventoryError) [ResourceId]
databaseDependencies app owner names invalid = traverse resolve names
  where
    resolve dbName = do
      database <-
        maybe
          (Left (invalid ("undeclared application database: " <> databaseNameText dbName)))
          Right
          (find ((== dbName) . (^. #name)) (app ^. #databases))
      role <- first invalid (mkName "statefulset")
      first invalid (databaseResourceId owner role database)

standaloneBrokerEnvironment ::
  ResourceId ->
  T.Text ->
  [BrokerBinding] ->
  Map BrokerName Declaration ->
  Map BrokerName (Map TopicName Declaration) ->
  (T.Text -> NonEmpty InventoryError) ->
  Either (NonEmpty InventoryError) (Map Dsl.EnvName ScopedEnvVar, [ResourceId])
standaloneBrokerEnvironment cluster namespaceName bindings brokerServices brokerTopics invalid = do
  unless
    ( Map.keysSet brokerServices == Set.fromList (map (^. #name) bindings)
        && length bindings == Map.size brokerServices
        && Map.keysSet brokerTopics `Set.isSubsetOf` Map.keysSet brokerServices
    )
    (Left (invalid "broker dependencies must cover exactly the workload bindings"))
  ids <-
    traverse
      ( first invalid
          . ( \binding ->
                brokerEvidenceIds
                  cluster
                  namespaceName
                  binding
                  brokerServices
                  brokerTopics
            )
      )
      bindings
  brokerEnvs <-
    traverse
      ( \binding -> do
          first
            invalid
            ( brokerConnectionEnv
                binding
                BrokerConn
                  { provider = Redpanda
                  , bootstrapServers =
                      brokerNameText (binding ^. #name)
                        <> "."
                        <> namespaceName
                        <> ".svc.cluster.local:9092"
                  , topics = binding ^. #topics
                  }
            )
      )
      bindings
  env <- first invalid (mergeBrokerConnectionEnvs brokerEnvs)
  pure (env, Set.toList (Set.fromList (concat ids)))
