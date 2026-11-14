-- | EP-262 M3: the operator's En tenants in the auth scope. Each declared
-- tenant gets its own direct database @en-<name>-db@ (compiled with the auth
-- databases), a migration Job copied from @en-migrate@ and pointed at that
-- database, a generated key Secret, its schema as the @en-schema@ key
-- @tenant-<name>.en@, and its @EN_TENANT_<NAME>_*@ environment on the one en
-- Deployment. Nagare's own tenant @nagare@ stays first in @EN_TENANTS@.
module Nagare.Inventory.Components.AuthTenants
  ( EnTenant (..)
  , enTenantService
  , enTenantDatabase
  , enTenantKeySecret
  , enTenantSchemaKey
  , withEnTenantWorkloads
  , withEnTenantSchemas
  , retiredEnTenants
  , tenantKeyBinding
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Traversable (for)
import Data.Vector qualified as V
import Nagare.Database.Secret (b64decode)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Target.EnTenants (EnTenantName, enTenantEnvName, enTenantNameText)

-- | One declared tenant and its schema file's bytes.
data EnTenant = EnTenant
  { name :: !EnTenantName
  , schema :: !ByteString
  }
  deriving stock (Generic, Eq, Show)

-- | The tenant's service name among the auth databases: @en-<name>@.
enTenantService :: EnTenantName -> Text
enTenantService tenant = "en-" <> enTenantNameText tenant

enTenantDatabase :: EnTenantName -> Text
enTenantDatabase tenant = enTenantService tenant <> "-db"

enTenantKeySecret :: EnTenantName -> Text
enTenantKeySecret tenant = "nagare-en-tenant-" <> enTenantNameText tenant <> "-keys"

-- | Not @<name>.en@: a tenant named @app@ would replace Nagare's @app.en@.
enTenantSchemaKey :: EnTenantName -> Text
enTenantSchemaKey tenant = "tenant-" <> enTenantNameText tenant <> ".en"

-- | Before templates render: copy @en-migrate@ once per tenant, pointed at
-- the tenant's database, and give the en Deployment each tenant's
-- environment. No tenant leaves every object as it was.
withEnTenantWorkloads :: [EnTenant] -> [(SourceLocation, Value)] -> Either Text [(SourceLocation, Value)]
withEnTenantWorkloads [] objects = Right objects
withEnTenantWorkloads tenants objects = concat <$> traverse revise objects
  where
    names = map (^. #name) tenants
    revise (location, value)
      | named "Job" "en-migrate" value = Right ((location, value) : [(location, tenantJob tenant value) | tenant <- names])
      | named "Deployment" "en" value = pure . (location,) <$> deployment value
      | otherwise = Right [(location, value)]
    tenantJob tenant =
      replaceStrings
        ( Map.fromList
            [ ("en-migrate", enTenantService tenant <> "-migrate")
            , ("en-db.nagare-system.svc.cluster.local", enTenantDatabase tenant <> ".nagare-system.svc.cluster.local")
            , ("nagare-db-en-db", "nagare-db-" <> enTenantDatabase tenant)
            ]
        )
    deployment value = case value of
      Object root -> do
        spec <- field "spec" root
        template <- field "template" spec
        podSpec <- field "spec" template
        containers <- case KM.lookup "containers" podSpec of
          Just (Array items) -> Right (toList items)
          _ -> Left "en Deployment has no containers"
        revised <- traverse container containers
        let podSpec' = KM.insert "containers" (Array (V.fromList revised)) podSpec
            template' = KM.insert "spec" (Object podSpec') template
            spec' = KM.insert "template" (Object template') spec
        pure (Object (KM.insert "spec" (Object spec') root))
      _ -> Left "en Deployment is malformed"
    container (Object fields) | KM.lookup "name" fields == Just (String "en") = do
      env <- case KM.lookup "env" fields of
        Just (Array items) -> Right (toList items)
        _ -> Left "en container has no env"
      unless (length [() | Object v <- env, KM.lookup "name" v == Just (String "EN_TENANTS")] == 1) (Left "en container must set EN_TENANTS once")
      let listed = Object (KM.fromList ["name" .= ("EN_TENANTS" :: Text), "value" .= T.intercalate "," ("nagare" : map enTenantNameText names)])
          env' = map (\case Object v | KM.lookup "name" v == Just (String "EN_TENANTS") -> listed; other -> other) env
      resources <- withTenantMemory (length names) fields
      pure (Object (KM.insert "resources" resources (KM.insert "env" (Array (V.fromList (env' <> concatMap tenantEnv names))) fields)))
    container other = Right other
    field key fields = case KM.lookup key fields of
      Just (Object inner) -> Right inner
      _ -> Left "en Deployment lacks an expected field"

-- | Each tenant has its own two caches of the configured sizes (En ADR 9);
-- they are what took Nagare's own tenant from 256Mi to 384Mi, so each
-- operator tenant adds that allowance to the limit. Idle, a tenant adds
-- nothing measurable (EP-262 M3: 20Mi before and after tenant demo).
tenantMemoryMi :: Int
tenantMemoryMi = 128

withTenantMemory :: Int -> KM.KeyMap Value -> Either Text Value
withTenantMemory tenants fields = case KM.lookup "resources" fields of
  Just (Object resources)
    | Just (Object limits) <- KM.lookup "limits" resources
    , Just (String memory) <- KM.lookup "memory" limits
    , Just base <- T.stripSuffix "Mi" memory
    , [(mebibytes, "")] <- reads (T.unpack base) ->
        let raised = String (T.pack (show (mebibytes + tenants * tenantMemoryMi :: Int)) <> "Mi")
         in Right (Object (KM.insert "limits" (Object (KM.insert "memory" raised limits)) resources))
  _ -> Left "en container has no memory limit in Mi"

-- | A tenant's variables. The raw secrets and database credentials are
-- @NAGARE_EN_<NAME>_*@, which En does not read; En refuses any unknown
-- @EN_TENANT_@ variable.
tenantEnv :: EnTenantName -> [Value]
tenantEnv tenant =
  [ secretVar (raw "PGUSER") ("nagare-db-" <> enTenantDatabase tenant) "POSTGRES_USER"
  , secretVar (raw "PGPASSWORD") ("nagare-db-" <> enTenantDatabase tenant) "POSTGRES_PASSWORD"
  , secretVar (raw "PGDATABASE") ("nagare-db-" <> enTenantDatabase tenant) "POSTGRES_DB"
  , plain
      (en "DATABASE_URL")
      ( "host="
          <> enTenantDatabase tenant
          <> ".nagare-system.svc.cluster.local port=5432 dbname=$("
          <> raw "PGDATABASE"
          <> ") user=$("
          <> raw "PGUSER"
          <> ") password=$("
          <> raw "PGPASSWORD"
          <> ")"
      )
  , plain (en "SCHEMA_PATH") ("/etc/en/schema/" <> enTenantSchemaKey tenant)
  , secretVar (raw "KEY_READ_WRITE") (enTenantKeySecret tenant) "read-write"
  , secretVar (raw "KEY_READ_ONLY") (enTenantKeySecret tenant) "read-only"
  , plain (en "API_KEYS_READ_WRITE") (enTenantNameText tenant <> "-write:$(" <> raw "KEY_READ_WRITE" <> ")")
  , plain (en "API_KEYS_READ_ONLY") (enTenantNameText tenant <> "-read:$(" <> raw "KEY_READ_ONLY" <> ")")
  ]
  where
    raw setting = "NAGARE_EN_" <> enTenantEnvName tenant <> "_" <> setting
    en setting = "EN_TENANT_" <> enTenantEnvName tenant <> "_" <> setting
    plain variable value = object ["name" .= variable, "value" .= value]
    secretVar variable secret key =
      object
        [ "name" .= variable
        , "valueFrom" .= object ["secretKeyRef" .= object ["name" .= secret, "key" .= (key :: Text)]]
        ]

-- | After templates render: each tenant's schema as its own @en-schema@ key.
-- The schema text is data, never a template.
withEnTenantSchemas :: [EnTenant] -> [(SourceLocation, Value)] -> Either Text [(SourceLocation, Value)]
withEnTenantSchemas [] objects = Right objects
withEnTenantSchemas tenants objects = traverse revise objects
  where
    revise (location, value@(Object root))
      | named "ConfigMap" "en-schema" value = do
          entries <- case KM.lookup "data" root of
            Just (Object fields) -> Right fields
            _ -> Left "en-schema has no data"
          added <- for tenants $ \tenant -> do
            text <- first (const ("En tenant " <> enTenantNameText (tenant ^. #name) <> "'s schema is not UTF-8")) (TE.decodeUtf8' (tenant ^. #schema))
            pure (enTenantSchemaKey (tenant ^. #name), String text)
          pure (location, Object (KM.insert "data" (Object (entries <> KM.fromList [(Key.fromText key, text) | (key, text) <- added])) root))
    revise other = Right other

named :: Text -> Text -> Value -> Bool
named kind objectName = \case
  Object root
    | KM.lookup "kind" root == Just (String kind)
    , Just (Object metadata) <- KM.lookup "metadata" root ->
        KM.lookup "name" metadata == Just (String objectName)
  _ -> False

replaceStrings :: Map.Map Text Text -> Value -> Value
replaceStrings replacements = \case
  String text -> String (Map.findWithDefault text text replacements)
  Object fields -> Object (replaceStrings replacements <$> fields)
  Array items -> Array (replaceStrings replacements <$> items)
  other -> other

-- | The tenants whose database the accepted auth scope holds and the context
-- no longer declares. Removing a tenant is refused: its database and keys are
-- protected, and a reviewed retirement is not part of EP-262.
retiredEnTenants :: ScopeDeclaration -> [EnTenantName] -> [Text]
retiredEnTenants accepted declared =
  [ T.dropEnd 3 (T.drop 3 database)
  | bundle <- scopeBundles accepted
  , Managed resource <- bundle ^. #declarations
  , Kubernetes _ "apps" kind (Just namespace) objectName <- [resource ^. #address]
  , nameText kind == "statefulset"
  , nameText namespace == "nagare-system"
  , let database = nameText objectName
  , "en-" `T.isPrefixOf` database
  , "-db" `T.isSuffixOf` database
  , database /= "en-db"
  , database `notElem` map enTenantDatabase declared
  ]

-- | EP-262 M4: the runtime Secret keys @nagarectl en-tenant bind@ writes,
-- from the tenant's key Secret as kubectl returns it: the read-write key under
-- one variable, the read-only key under another, at least one of them.
tenantKeyBinding :: EnTenantName -> Value -> Maybe Text -> Maybe Text -> Either Text (Map.Map Text Text)
tenantKeyBinding tenant secret readWriteAs readOnlyAs = do
  when (isNothing readWriteAs && isNothing readOnlyAs) (Left "name a variable with --read-write-as, --read-only-as, or both")
  when (readWriteAs == readOnlyAs) (Left "--read-write-as and --read-only-as must name different variables")
  entries <- case secret of
    Object root
      | Just (Object metadata) <- KM.lookup "metadata" root
      , KM.lookup "name" metadata == Just (String (enTenantKeySecret tenant))
      , KM.lookup "namespace" metadata == Just (String "nagare-system")
      , Just (Object fields) <- KM.lookup "data" root ->
          Right fields
    _ -> Left (enTenantKeySecret tenant <> " is not the tenant's key Secret")
  let key name' = case KM.lookup name' entries of
        Just (String encoded) | Right decoded <- b64decode encoded, not (T.null decoded) -> Right decoded
        _ -> Left (enTenantKeySecret tenant <> " has no usable " <> Key.toText name' <> " key")
  pairs <-
    sequence
      ( [(variable,) <$> key "read-write" | Just variable <- [readWriteAs]]
          <> [(variable,) <$> key "read-only" | Just variable <- [readOnlyAs]]
      )
  pure (Map.fromList pairs)
