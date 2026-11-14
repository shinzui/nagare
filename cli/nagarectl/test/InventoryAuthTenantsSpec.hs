-- | EP-262 M3: operator-declared En tenants, from the context to the auth
-- scope's members. Each tenant gets its database, migration Job, key Secret,
-- schema key and En environment, and the en Deployment waits for them.
module InventoryAuthTenantsSpec
  ( inventoryAuthTenantsTests
  )
where

import Control.Monad (forM_)
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Database.Secret (b64encode)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.CredentialTemplate (materializeCredential)
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective (HourlyRecoveryPoint))
import Nagare.Inventory.Components.Auth (AuthMode (CloudAuth), EnTenant (..), compileAuthComponent)
import Nagare.Inventory.Components.AuthTenants (retiredEnTenants, tenantKeyBinding)
import Nagare.Inventory.Components.Foundation (FoundationInput (..))
import Nagare.Inventory.Components.PackagedAuth (packagedAuthInputsWithTenants)
import Nagare.Inventory.Database (DatabaseBackupTarget (DatabaseBackupTarget))
import Nagare.Platform.ReleaseImages (explicitSelection)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (LifecyclePolicy (Protect))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Target (profileFromContextMap)
import Nagare.Target.EnTenants (EnTenantDeclaration (..), EnTenantName, mkEnTenantName, parseEnTenantDeclarations)
import Test.Tasty
import Test.Tasty.HUnit

inventoryAuthTenantsTests :: TestTree
inventoryAuthTenantsTests =
  testGroup
    "En tenants in the auth scope (EP-262 M3)"
    [ testCase "the context declares tenants in order, each with its schema path, and parsing never reads the file" $ do
        let ctx = Map.fromList [("NAGARE_EN_TENANTS", "demo, team-a"), ("NAGARE_EN_TENANT_DEMO_SCHEMA", "schemas/absent.en"), ("NAGARE_EN_TENANT_TEAM_A_SCHEMA", "/abs/team-a.en")]
        parseEnTenantDeclarations ctx @?= Right [EnTenantDeclaration (tenant "demo") "schemas/absent.en", EnTenantDeclaration (tenant "team-a") "/abs/team-a.en"]
        (profileFromContextMap ctx ^. #enTenants) @?= [EnTenantDeclaration (tenant "demo") "schemas/absent.en", EnTenantDeclaration (tenant "team-a") "/abs/team-a.en"]
        parseEnTenantDeclarations Map.empty @?= Right []
    , testCase "an invalid or reserved name, a missing schema, and a stray schema variable are refused" $ do
        let refused ctx = assertBool (show ctx) (isLeft' (parseEnTenantDeclarations (Map.fromList ctx)))
        refused [("NAGARE_EN_TENANTS", "Demo"), ("NAGARE_EN_TENANT_DEMO_SCHEMA", "d.en")]
        refused [("NAGARE_EN_TENANTS", "9demo")]
        refused [("NAGARE_EN_TENANTS", T.replicate 32 "a")]
        refused [("NAGARE_EN_TENANTS", "nagare"), ("NAGARE_EN_TENANT_NAGARE_SCHEMA", "n.en")]
        refused [("NAGARE_EN_TENANTS", "demo")]
        refused [("NAGARE_EN_TENANTS", "demo,demo"), ("NAGARE_EN_TENANT_DEMO_SCHEMA", "d.en")]
        refused [("NAGARE_EN_TENANTS", "demo"), ("NAGARE_EN_TENANT_DEMO_SCHEMA", "d.en"), ("NAGARE_EN_TENANT_OTHER_SCHEMA", "o.en")]
        refused [("NAGARE_EN_TENANT_DEMO_SCHEMA", "d.en")]
    , testCase "tenant demo yields its database, migration Job, key Secret, schema key and environment, and the en Deployment waits for them" $ do
        (scope, native) <- compiled [EnTenant (tenant "demo") demoSchema]
        let members = [resource | bundle <- scopeBundles scope, Managed resource <- bundle ^. #declarations]
            named kind name = [resource | resource <- members, Kubernetes _ _ k _ n <- [resource ^. #address], nameText k == kind, name n]
            exactly value n = nameText n == value
        statefulSet <- single (named "statefulset" (exactly "en-demo-db"))
        demoJob <- single (named "job" (T.isPrefixOf "en-demo-migrate-" . nameText))
        enJob <- single (named "job" (T.isPrefixOf "en-migrate-" . nameText))
        keys <- single (named "secret" (exactly "nagare-en-tenant-demo-keys"))
        en <- single (named "deployment" (exactly "en"))
        let after resource = [dependency | OrderedAfter dependency <- resource ^. #dependencies]
            proofOf job = [operation ^. #identity | operation <- concatMap (^. #operations) (scopeBundles scope), job ^. #identity `elem` toList (operation ^. #affects)]
        demoProof <- single (proofOf demoJob)
        enProof <- single (proofOf enJob)
        keys ^. #lifecycle @?= Protect
        assertBool "en-demo-migrate does not wait for en-demo-db" ((statefulSet ^. #identity) `elem` after demoJob)
        assertBool "en-demo-migrate waits for en-db" (all (`notElem` after demoJob) [r ^. #identity | r <- named "statefulset" (exactly "en-db")])
        assertBool "en-migrate waits for en-demo-db" ((statefulSet ^. #identity) `notElem` after enJob)
        forM_ [statefulSet ^. #identity, demoProof, enProof, demoJob ^. #identity, keys ^. #identity] $ \dependency ->
          assertBool ("the en Deployment does not wait for " <> show dependency) (dependency `elem` after en)
        deployment <- object' (snd (native Map.! (en ^. #identity)))
        let env = enEnv deployment
        lookup "EN_TENANTS" env @?= Just "nagare,demo"
        lookup "EN_TENANT_DEMO_SCHEMA_PATH" env @?= Just "/etc/en/schema/tenant-demo.en"
        lookup "EN_TENANT_DEMO_API_KEYS_READ_WRITE" env @?= Just "demo-write:$(NAGARE_EN_DEMO_KEY_READ_WRITE)"
        lookup "EN_TENANT_DEMO_API_KEYS_READ_ONLY" env @?= Just "demo-read:$(NAGARE_EN_DEMO_KEY_READ_ONLY)"
        assertBool "the demo database URL does not name en-demo-db" (maybe False ("host=en-demo-db.nagare-system.svc.cluster.local " `T.isPrefixOf`) (lookup "EN_TENANT_DEMO_DATABASE_URL" env))
        lookup "EN_TENANT_NAGARE_SCHEMA_PATH" env @?= Just "/etc/en/schema/app.en"
        job <- object' (snd (native Map.! (demoJob ^. #identity)))
        assertBool "en-demo-migrate reaches another database" ("en-demo-db.nagare-system.svc.cluster.local" `T.isInfixOf` encodeText job && not ("\"nagare-db-en-db\"" `T.isInfixOf` encodeText job))
        schemas <- schemaData native
        Map.lookup "tenant-demo.en" schemas @?= Just (TE.decodeUtf8 demoSchema)
    , testCase "a tenant's key Secret is generated with a read-write and a read-only key" $ do
        (_, native) <- compiled [EnTenant (tenant "demo") demoSchema]
        keys <- single [bytes | (resource, bytes) <- Map.elems native, Kubernetes _ "" kind _ name <- [resource ^. #address], nameText kind == "secret", nameText name == "nagare-en-tenant-demo-keys"]
        filled <- materializeCredential (TE.decodeUtf8 keys) >>= either (assertFailure . T.unpack) pure
        value <- object' (TE.encodeUtf8 filled)
        case value of
          Object root | Just (Object entries) <- KM.lookup "data" root -> sort (map Key.toText (KM.keys entries)) @?= ["read-only", "read-write"]
          _ -> assertFailure "the tenant key Secret has no data"
    , testCase "a tenant named app leaves app.en holding Nagare's schema, and a tenant's schema change rolls En" $ do
        (_, native) <- compiled [EnTenant (tenant "app") demoSchema]
        schemas <- schemaData native
        assertBool "app.en was replaced" (maybe False ("object app" `T.isInfixOf`) (Map.lookup "app.en" schemas) && Map.lookup "app.en" schemas /= Just (TE.decodeUtf8 demoSchema))
        Map.lookup "tenant-app.en" schemas @?= Just (TE.decodeUtf8 demoSchema)
        (_, changed) <- compiled [EnTenant (tenant "app") (demoSchema <> "\nobject folder {}\n")]
        assertBool "a tenant's schema change left the en Deployment's schema digest" (schemaDigest native /= schemaDigest changed)
    , testCase "no tenant compiles the auth scope as before: two databases and the nagare tenant only" $ do
        (scope, native) <- compiled []
        length [() | bundle <- scopeBundles scope, Managed resource <- bundle ^. #declarations, Kubernetes _ "apps" kind _ _ <- [resource ^. #address], nameText kind == "statefulset"] @?= 2
        schemas <- schemaData native
        Map.keys schemas @?= ["app.en"]
    , testCase "bind takes the tenant's keys under the named runtime variables, only from its own Secret" $ do
        let secret name' namespace' =
              Aeson.object
                [ "metadata" Aeson..= Aeson.object ["name" Aeson..= (name' :: Text), "namespace" Aeson..= (namespace' :: Text)]
                , "data" Aeson..= Aeson.object ["read-write" Aeson..= b64encode "rw-secret", "read-only" Aeson..= b64encode "ro-secret"]
                ]
            demoKeys = secret "nagare-en-tenant-demo-keys" "nagare-system"
        tenantKeyBinding (tenant "demo") demoKeys Nothing (Just "EN_KEY") @?= Right (Map.fromList [("EN_KEY", "ro-secret")])
        tenantKeyBinding (tenant "demo") demoKeys (Just "EN_WRITE") (Just "EN_READ") @?= Right (Map.fromList [("EN_WRITE", "rw-secret"), ("EN_READ", "ro-secret")])
        assertBool "no variable was accepted" (isLeft' (tenantKeyBinding (tenant "demo") demoKeys Nothing Nothing))
        assertBool "one variable for both keys was accepted" (isLeft' (tenantKeyBinding (tenant "demo") demoKeys (Just "K") (Just "K")))
        assertBool "another tenant's Secret was accepted" (isLeft' (tenantKeyBinding (tenant "demo") (secret "nagare-en-tenant-other-keys" "nagare-system") Nothing (Just "K")))
        assertBool "a Secret outside nagare-system was accepted" (isLeft' (tenantKeyBinding (tenant "demo") (secret "nagare-en-tenant-demo-keys" "personal") Nothing (Just "K")))
    , testCase "a tenant the accepted auth scope holds and the context dropped is refused" $ do
        (accepted, _) <- compiled [EnTenant (tenant "demo") demoSchema, EnTenant (tenant "team-a") demoSchema]
        retiredEnTenants accepted [tenant "demo", tenant "team-a"] @?= []
        retiredEnTenants accepted [tenant "team-a"] @?= ["demo"]
        retiredEnTenants accepted [] @?= ["demo", "team-a"]
    ]

demoSchema :: ByteString
demoSchema = "object user {}\n\nobject doc {\n  relation viewer: user\n}\n"

tenant :: Text -> EnTenantName
tenant = either (error . T.unpack) id . mkEnTenantName

compiled :: [EnTenant] -> IO (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
compiled tenants = do
  (auth, databases) <-
    either (assertFailure . show) pure $
      packagedAuthInputsWithTenants
        "../.."
        foundation
        CloudAuth
        "example.test"
        images
        (DatabaseBackupTarget (GcsBackend "project" "bucket") HourlyRecoveryPoint)
        tenants
  compileAuthComponent auth databases >>= either (assertFailure . show) pure
  where
    foundation = FoundationInput (known (mkScopeId Platform "foundation")) cluster "../../cluster/bootstrap/job-runs/resourcequota.yaml" []
    cluster = mintResourceId (known (mkScopeId Platform "cluster")) (known (mkLogicalKey "cluster")) (known (mkName "cluster"))
    images =
      Map.fromList
        [ (service, explicitSelection ("registry.example.test/" <> service <> "@sha256:" <> T.replicate 64 "a"))
        | service <- ["en", "shomei", "nagare-access"]
        ]

single :: (Show a) => [a] -> IO a
single = \case
  [one] -> pure one
  other -> assertFailure ("expected exactly one, got " <> show other)

object' :: ByteString -> IO Value
object' = either fail pure . eitherDecodeStrict

encodeText :: Value -> Text
encodeText = T.pack . show

-- | The en container's literal variables.
enEnv :: Value -> [(Text, Text)]
enEnv value =
  [ (variable, text)
  | Object root <- [value]
  , Just (Object spec) <- [KM.lookup "spec" root]
  , Just (Object template) <- [KM.lookup "template" spec]
  , Just (Object podSpec) <- [KM.lookup "spec" template]
  , Just (Array containers) <- [KM.lookup "containers" podSpec]
  , Object container <- toList containers
  , KM.lookup "name" container == Just (String "en")
  , Just (Array env) <- [KM.lookup "env" container]
  , Object entry <- toList env
  , Just (String variable) <- [KM.lookup "name" entry]
  , Just (String text) <- [KM.lookup "value" entry]
  ]

schemaData :: Map.Map ResourceId (ManagedResource, ByteString) -> IO (Map.Map Text Text)
schemaData native = do
  values <- traverse (object' . snd) (Map.elems native)
  single
    [ Map.fromList [(keyText key, text) | (key, String text) <- KM.toList payload]
    | Object root <- values
    , KM.lookup "kind" root == Just (String "ConfigMap")
    , Just (Object metadata) <- [KM.lookup "metadata" root]
    , KM.lookup "name" metadata == Just (String "en-schema")
    , Just (Object payload) <- [KM.lookup "data" root]
    ]
  where
    keyText = Key.toText

schemaDigest :: Map.Map ResourceId (ManagedResource, ByteString) -> [Text]
schemaDigest native =
  [ TE.decodeUtf8 bytes
  | (resource, bytes) <- Map.elems native
  , Kubernetes _ "apps" kind _ name <- [resource ^. #address]
  , nameText kind == "deployment"
  , nameText name == "en"
  ]

isLeft' :: Either a b -> Bool
isLeft' = either (const True) (const False)

known :: Either Text a -> a
known = either (error . T.unpack) id
