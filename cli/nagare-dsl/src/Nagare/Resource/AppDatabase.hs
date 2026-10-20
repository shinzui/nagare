-- | Inventory members of an app database (EP-202). An app database is its own
-- standalone scope, @appdb-\<key\>@, holding typed references to an accepted
-- server's StatefulSet: two data-free credential templates, a runtime and a
-- migration user, and one logical database per declared name. The users and
-- databases are claimed in the server's own collision domain, so two app
-- databases cannot claim one name on one server.
module Nagare.Resource.AppDatabase
  ( appDatabaseResourceId
  , appDatabaseScopeKey
  , AppDatabaseInput (..)
  , appDatabaseCredentialTemplate
  , compileAppDatabase
  )
where

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Nagare.Dsl.AppDatabase
import Nagare.Dsl.Database (engineToken)
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (databaseNameText, namespaceText)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types

-- | The logical key of the app database's scope and member identities: the
-- pinned key, or the app-database name.
appDatabaseScopeKey :: AppDatabase -> Either Text LogicalKey
appDatabaseScopeKey db = maybe (mkLogicalKey (appDatabaseNameText (db ^. #name))) Right (db ^. #logicalKey)

appDatabaseResourceId :: ScopeId -> Name -> AppDatabase -> Either Text ResourceId
appDatabaseResourceId owner role db = mintResourceId owner <$> appDatabaseScopeKey db <*> pure role

-- | The accepted server the app database lives in, resolved by the caller
-- from inventory history, and the reviewed context of this scope.
data AppDatabaseInput = AppDatabaseInput
  { appDatabase :: !AppDatabase
  , owner :: !ScopeId
  , cluster :: !ResourceId
  , namespaceResource :: !(Maybe ResourceId)
  , server :: !ResourceId
  , recovery :: !RecoveryIntent
  , source :: !SourceLocation
  , backupSchedule :: !(Maybe Value)
  -- ^ the scheduled backup CronJob rendered by the caller's storage backend
  }
  deriving stock (Generic, Eq, Show)

-- | A create-only Secret with no data at review time. At the guarded mutation
-- the runtime fills the user's password, its database and connection URL;
-- the annotations name the user and database so it never derives them again.
appDatabaseCredentialTemplate :: AppDatabase -> AppDatabaseRole -> Value
appDatabaseCredentialTemplate db role =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("Secret" :: Text)
    , "type" .= ("Opaque" :: Text)
    , "metadata"
        .= object
          [ "name" .= appDatabaseSecretName (db ^. #name) role
          , "namespace" .= namespaceText (db ^. #namespace)
          , "labels"
              .= object
                [ "nagare.dev/managed-by" .= ("nagarectl" :: Text)
                , "nagare.dev/app-database" .= appDatabaseNameText (db ^. #name)
                , "nagare.dev/app-database-server" .= databaseNameText (db ^. #server)
                , "nagare.dev/app-database-role" .= appDatabaseRoleToken role
                , "nagare.dev/engine" .= engineToken (db ^. #engine)
                ]
          , "annotations"
              .= object
                [ "nagare.dev/credential-template" .= ("app-database-v1" :: Text)
                , "nagare.dev/app-database-user" .= appDatabaseUser (db ^. #name) role
                , "nagare.dev/app-database-db" .= logicalDatabaseNameText (NE.head (db ^. #logicalDatabases))
                ]
          ]
    ]

-- | Compile the members. The digest callback is supplied by nagarectl, which
-- owns content hashing; the returned objects are the native credential
-- templates.
compileAppDatabase ::
  (Value -> Either Text ContentDigest) ->
  AppDatabaseInput ->
  Either (NonEmpty InventoryError) (ResourceBundle, [(ResourceId, Value)])
compileAppDatabase digestOf input = do
  _ <- first invalid (validateAppDatabase db)
  credentials <- traverse credential [RuntimeRole, MigrationRole]
  users <- traverse user [RuntimeRole, MigrationRole]
  databases <- traverse logicalDatabase (NE.toList (db ^. #logicalDatabases))
  backup <- maybe (pure []) (backupBundle (map (^. #identity) databases)) (input ^. #backupSchedule)
  pure
    ( ResourceBundle (map (Managed . fst) (credentials <> backup) <> map Managed (users <> databases)) [] [] [] [] []
    , [(resource ^. #identity, value) | (resource, value) <- credentials <> backup]
    )
  where
    db = input ^. #appDatabase
    engine = db ^. #engine
    stateful = input ^. #server
    monitoring = db ^. #access . #monitoring
    namespaceDependency = map OrderedAfter (maybe [] pure (input ^. #namespaceResource))
    memberId roleText = do
      role <- first invalid (mkName roleText)
      first invalid (appDatabaseResourceId (input ^. #owner) role db)
    roleId role suffix = memberId (appDatabaseRoleToken role <> suffix)
    sourceAt suffix = (input ^. #source) & #path %~ (<> ("/app-database/" <> suffix))
    credential role = do
      resource <- roleId role "-credential"
      let value = appDatabaseCredentialTemplate db role
      digest <- first invalid (digestOf value)
      declaration <-
        first (:| []) $
          compileKubernetesObject
            KubernetesInput
              { resourceId = resource
              , ownerScope = input ^. #owner
              , clusterId = input ^. #cluster
              , inputObject = value
              , objectDigest = digest
              , lifecyclePolicy = Retain
              , inputDataPolicy = Durable (input ^. #recovery)
              , inputSensitivity = Secret
              , sourceLocation = sourceAt (appDatabaseRoleToken role <> "-credential")
              }
      pure (declaration {dependencies = namespaceDependency}, value)
    user role = do
      let userAccess = appDatabaseUserAccess db role
      resource <- roleId role "-user"
      credentialId <- roleId role "-credential"
      userName <- first invalid (mkName (appDatabaseUser (db ^. #name) role))
      digest <-
        first invalid $
          digestOf
            ( object $
                [ "engine" .= engineToken engine
                , "role" .= appDatabaseRoleToken role
                , "attributes" .= appDatabaseAttributes engine role
                , "serverGrants" .= map grantJSON (appDatabaseServerGrants engine role)
                ]
                  -- Only when declared, so an unchanged user keeps its v0.7 digest.
                  <> ["access" .= userAccess | userAccess /= noUserAccess]
            )
      pure
        ManagedResource
          { identity = resource
          , owner = input ^. #owner
          , executor = AppDatabaseExecutor
          , address = DatabaseUser stateful userName
          , aliases = []
          , spec = DatabaseUserSpec (engineToken engine) (appDatabaseRoleToken role) LoginOpen digest userAccess
          , lifecycle = Retain
          , dataPolicy = Stateless
          , sensitivity = Private
          , dependencies = [OrderedAfter stateful, OrderedAfter credentialId]
          , delegations = []
          , source = sourceAt (appDatabaseRoleToken role <> "-user")
          }
    logicalDatabase logical = do
      let databaseText = logicalDatabaseNameText logical
      resource <- memberId ("database-" <> databaseText)
      runtimeId <- roleId RuntimeRole "-user"
      migrationId <- roleId MigrationRole "-user"
      databaseName <- first invalid (mkName databaseText)
      runtimeUser <- first invalid (mkName (appDatabaseUser (db ^. #name) RuntimeRole))
      migrationUser <- first invalid (mkName (appDatabaseUser (db ^. #name) MigrationRole))
      digest <-
        first invalid $
          digestOf
            ( object $
                [ "engine" .= engineToken engine
                , "database" .= databaseText
                , "grants"
                    .= object
                      [ "runtime" .= map grantJSON (appDatabaseDatabaseGrants engine RuntimeRole)
                      , "migration" .= map grantJSON (appDatabaseDatabaseGrants engine MigrationRole)
                      ]
                ]
                  <> ["monitoring" .= monitoring | not (null monitoring)]
            )
      pure
        ManagedResource
          { identity = resource
          , owner = input ^. #owner
          , executor = AppDatabaseExecutor
          , address = DatabaseName stateful databaseName
          , aliases = []
          , spec = LogicalDatabase (engineToken engine) migrationUser runtimeUser True digest monitoring
          , lifecycle = Retain
          , dataPolicy = Durable (input ^. #recovery)
          , sensitivity = Private
          , dependencies = [OrderedAfter stateful, OrderedAfter migrationId, OrderedAfter runtimeId]
          , delegations = []
          , source = sourceAt ("database/" <> databaseText)
          }
    -- The schedule dumps with the migration credential, reads only the
    -- server's StatefulSet and PVC, and signs its receipts with its own key.
    backupBundle databaseIds cron = do
      let schedule = "nagare-appdb-" <> appDatabaseNameText (db ^. #name)
          namespaceName = namespaceText (db ^. #namespace)
          serverName = databaseNameText (db ^. #server)
          metadata = object ["name" .= schedule, "namespace" .= namespaceName]
          account = object ["apiVersion" .= ("v1" :: Text), "kind" .= ("ServiceAccount" :: Text), "metadata" .= metadata]
          role =
            object
              [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: Text)
              , "kind" .= ("Role" :: Text)
              , "metadata" .= metadata
              , "rules"
                  .= [ object ["apiGroups" .= (["apps"] :: [Text]), "resources" .= (["statefulsets"] :: [Text]), "resourceNames" .= [serverName], "verbs" .= (["get"] :: [Text])]
                     , object ["apiGroups" .= ([""] :: [Text]), "resources" .= (["persistentvolumeclaims"] :: [Text]), "resourceNames" .= [dbPvcName serverName], "verbs" .= (["get"] :: [Text])]
                     ]
              ]
          binding =
            object
              [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: Text)
              , "kind" .= ("RoleBinding" :: Text)
              , "metadata" .= metadata
              , "subjects" .= [object ["kind" .= ("ServiceAccount" :: Text), "name" .= schedule, "namespace" .= namespaceName]]
              , "roleRef" .= object ["apiGroup" .= ("rbac.authorization.k8s.io" :: Text), "kind" .= ("Role" :: Text), "name" .= schedule]
              ]
          signing =
            object
              [ "apiVersion" .= ("v1" :: Text)
              , "kind" .= ("Secret" :: Text)
              , "type" .= ("Opaque" :: Text)
              , "metadata"
                  .= object
                    [ "name" .= (schedule <> "-signing")
                    , "namespace" .= namespaceName
                    , "labels" .= object ["nagare.dev/app-database" .= appDatabaseNameText (db ^. #name)]
                    , "annotations" .= object ["nagare.dev/backup-signing-template" .= ("v1" :: Text)]
                    ]
              ]
      migrationCredential <- roleId MigrationRole "-credential"
      accountMember <- companion "backup-account" account Stateless DeleteWhenUnreferenced Private []
      roleMember <- companion "backup-read-role" role Stateless DeleteWhenUnreferenced Private []
      bindingMember <- companion "backup-read-binding" binding Stateless DeleteWhenUnreferenced Private [fst accountMember ^. #identity, fst roleMember ^. #identity]
      signingMember <- companion "backup-signing-key" signing (Durable (input ^. #recovery)) Retain Secret []
      cronMember <-
        companion "backup" cron Stateless DeleteWhenUnreferenced Private $
          [stateful, migrationCredential, fst bindingMember ^. #identity, fst signingMember ^. #identity] <> databaseIds
      expected <- first invalid (mkName schedule)
      expectedNamespace <- first invalid (mkName namespaceName)
      unless
        (fst cronMember ^. #address == Kubernetes (input ^. #cluster) "batch" (known "cronjob") (Just expectedNamespace) expected)
        (Left (invalid "app-database backup CronJob has an unexpected address"))
      pure [accountMember, roleMember, bindingMember, signingMember, cronMember]
    companion roleText value policy lifecycle' sensitivity' predecessors = do
      resource <- memberId roleText
      digest <- first invalid (digestOf value)
      declaration <-
        first (:| []) $
          compileKubernetesObject
            KubernetesInput
              { resourceId = resource
              , ownerScope = input ^. #owner
              , clusterId = input ^. #cluster
              , inputObject = value
              , objectDigest = digest
              , lifecyclePolicy = lifecycle'
              , inputDataPolicy = policy
              , inputSensitivity = sensitivity'
              , sourceLocation = sourceAt roleText
              }
      pure (declaration {dependencies = namespaceDependency <> map OrderedAfter predecessors}, value)
    known value = either (error . show) id (mkName value)
    invalid message =
      inventoryError "invalid-app-database" message
        & #scopes
        .~ [input ^. #owner]
        & #sources
        .~ [input ^. #source]
        & (:| [])

grantJSON :: Grant -> Value
grantJSON g = object ["class" .= (g ^. #objectClass), "privileges" .= toJSON (g ^. #privileges)]
