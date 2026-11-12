-- | EP-259 M1: tasks and pre-deploy hooks bind app databases, and any binding
-- may name the one variable that receives the connection URL.
module AppDatabaseTaskSpec (appDatabaseTaskTests) where

import AppDatabaseSpec (acceptedNative, alpha, beta, chServer, known, pgServer, scopeAndNative, secretKeyRefs, snapshotWith, testCluster)
import AppDatabaseSpec qualified as Fixture
import Control.Monad (forM_)
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Generics.Labels ()
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (UTCTime), fromGregorian)
import Data.Vector qualified as V
import Nagare.App.Deploy (RolloutEnv (..))
import Nagare.Deploy (serviceUrl)
import Nagare.Dsl.AppDatabase (Ownership (..), mkRoleName)
import Nagare.Dsl.Application (Application)
import Nagare.Dsl.Application qualified as DslApp
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Prelude
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Task (Task, scheduledTask)
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Dsl.Worker (webWorker)
import Nagare.Inventory.Application (ApplicationScopeInput (..), DatabaseBinding, acceptedAppDatabaseBindings, acceptedAppDatabaseTaskBindings, compileApplicationDeployment, compileStandaloneServiceWithDependencies, compileStandaloneWorkerWithDependencies)
import Nagare.Resource.Inventory
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Static.Release (StaticRelease (..), emptyReleaseLog)
import Nagare.Test.Support.Profiles (hourlyGcsBackup, tnbProfile)
import Test.Tasty
import Test.Tasty.HUnit

appDatabaseTaskTests :: TestTree
appDatabaseTaskTests =
  testGroup
    "AppDatabase task and named bindings (EP-259)"
    [ testCase "a name-only binding renders the objects and dependencies 931c1d83 rendered before EP-259" $ do
        -- The worker binds alpha-pg and alpha-ch, the Deployment alpha-pg, each by name only.
        let compiled = [scopeAndNative pgServer (alpha Postgres), scopeAndNative chServer (alpha ClickHouse)]
            accepted' = snapshotWith [pgServer, chServer] (map fst compiled)
            native' = Map.unions (acceptedNative [pgServer, chServer] : map snd compiled)
            names = [db "alpha-pg", db "alpha-ch"]
        workerBindings <- expectRight (acceptedAppDatabaseBindings accepted' native' testCluster "personal" (workerName "alpha") names)
        (_, workerNative) <- expectRight (Fixture.compileWorker "alpha" (Just names) workerBindings)
        serviceBindings <- expectRight (acceptedAppDatabaseBindings accepted' native' testCluster "personal" (workloadName "alpha") (take 1 names))
        let service = known (webService "alpha" "registry.example.com/alpha") & #appDatabases .~ map Dsl.appDatabaseBinding (take 1 names)
        (_, serviceNative) <- expectRight (compileStandaloneServiceWithDependencies (known (mkScopeId Standalone "service-alpha")) service (rollout "alpha" Map.empty & #baseDomain .~ "apps.example.com") testCluster namespaceId imageId Map.empty Map.empty Map.empty Map.empty Map.empty (Map.singleton (workloadName "alpha") serviceBindings) Nothing (SourceLocation "test" "service"))
        before <- BS.readFile "test/fixtures/app-database/v0.19.2/name-only-bindings.txt"
        BS.concat [TE.encodeUtf8 (resourceIdText (member ^. #identity)) <> "\n" <> BS8.pack (show (member ^. #dependencies)) <> "\n" <> bytes <> "\n" | (member, bytes) <- Map.elems (Map.union workerNative serviceNative)] @?= before
    , testCase "a named binding injects exactly its variable from the Secret's URL key, so two PostgreSQL bindings coexist" $ do
        let bindings = [named "alpha-pg" "ALPHA_DATABASE_URL", named "beta-pg" "BETA_DATABASE_URL"]
        resolved <- expectRight (acceptedAppDatabaseBindings accepted native testCluster "personal" (workerName "alpha") (map (^. #name) bindings))
        (scope, workerNative) <- expectRight (compileWorker "alpha" bindings Map.empty resolved)
        concatMap (secretEnv . snd) (Map.elems workerNative)
          @?= [("ALPHA_DATABASE_URL", "alpha-pg-runtime", "DATABASE_URL"), ("BETA_DATABASE_URL", "beta-pg-runtime", "DATABASE_URL")]
        assertBool "a named binding injected the fixed set" (not (any (BS.isInfixOf "POSTGRES_HOST" . snd) (Map.elems workerNative)))
        assertBool "the worker is not ordered after its app databases" (all (`elem` dependenciesOf scope) (map OrderedAfter (membersOf "appdb-alpha" <> membersOf "appdb-beta")))
        -- The same app database under the fixed set and a name gives both.
        both <- expectRight (acceptedAppDatabaseBindings accepted native testCluster "personal" (workerName "alpha") [db "alpha-pg"])
        (_, bothNative) <- expectRight (compileWorker "alpha" [Dsl.appDatabaseBinding (db "alpha-pg"), named "alpha-pg" "ALPHA_DATABASE_URL"] Map.empty both)
        sort (map fst3 (concatMap (secretEnv . snd) (Map.elems bothNative))) @?= ["ALPHA_DATABASE_URL", "DATABASE_URL", "POSTGRES_DB", "POSTGRES_PASSWORD", "POSTGRES_USER"]
    , testCase "a urlVariable the env defines, or that another binding's fixed set injects, is refused" $ do
        resolved <- expectRight (acceptedAppDatabaseBindings accepted native testCluster "personal" (workerName "alpha") [db "alpha-pg", db "beta-pg"])
        refused "already defined" (compileWorker "alpha" [named "alpha-pg" "ALPHA_DATABASE_URL"] (Map.singleton (envName "ALPHA_DATABASE_URL") (Dsl.runtimeScoped (Dsl.EnvLiteral "x"))) (Map.delete (databaseKey "beta-pg") resolved))
        refused "DATABASE_URL" (compileWorker "alpha" [Dsl.appDatabaseBinding (db "alpha-pg"), named "beta-pg" "DATABASE_URL"] Map.empty resolved)
    , testCase "a Deployment's task receives only its own app database's Secret: migration when named in owners, runtime otherwise" $ do
        let migrate = hookTask "alpha-migrate" [named "alpha-pg" "MIGRATE_DATABASE_URL"]
            report = hookTask "alpha-report" [Dsl.appDatabaseBinding (db "beta-pg")]
            service = known (webService "alpha" "registry.example.com/alpha") & #tasks .~ [migrate, report]
        consumers <- traverse (\task -> (task ^. #name,) <$> expectRight (acceptedAppDatabaseBindings ownedAccepted ownedNative testCluster "personal" (task ^. #name) (map (^. #name) (task ^. #appDatabases)))) [migrate, report]
        (scope, serviceNative) <- expectRight (compileStandaloneServiceWithDependencies (known (mkScopeId Standalone "service-alpha")) service (rollout "alpha" Map.empty) testCluster namespaceId imageId Map.empty Map.empty Map.empty Map.empty Map.empty (Map.fromList consumers) Nothing (SourceLocation "test" "service"))
        let byName name' = [bytes | (member, bytes) <- Map.elems serviceNative, Kubernetes _ _ _ _ n <- [member ^. #address], nameText n == name']
        concatMap secretEnv (byName "nagare-task-alpha-migrate") @?= [("MIGRATE_DATABASE_URL", "alpha-pg-migration", "DATABASE_URL")]
        nub (sort (concatMap secretKeyRefs (byName "nagare-task-alpha-report"))) @?= ["beta-pg-runtime"]
        assertBool "the web Service references an app database Secret" (not (any (\bytes -> any (`BS.isInfixOf` bytes) ["alpha-pg-", "beta-pg-"]) (byName "alpha")))
        let migrateDependencies = concat [member ^. #dependencies | bundle <- scopeBundles scope, Managed member <- declarations bundle, Kubernetes _ _ _ _ n <- [member ^. #address], nameText n == "nagare-task-alpha-migrate"]
        assertBool "the task is not ordered after its Secret and its app database" (all (`elem` migrateDependencies) (map OrderedAfter (secretOf ownedScopes "alpha-pg-migration" : membersIn ownedScopes "appdb-alpha")))
        -- A task that binds an app database cannot share its Deployment's name.
        refused "name other than" (compileStandaloneServiceWithDependencies (known (mkScopeId Standalone "service-alpha")) (service & #tasks .~ [hookTask "alpha" [Dsl.appDatabaseBinding (db "beta-pg")]]) (rollout "alpha" Map.empty) testCluster namespaceId imageId Map.empty Map.empty Map.empty Map.empty Map.empty Map.empty Nothing (SourceLocation "test" "service"))
    , testCase "a pre-deploy hook binds an app database under its variable, its Job ordered after the Secret; the service and workers still may not" $ do
        let hook = hookTask "alpha-migrate" [named "alpha-pg" "KOTEI_RELEASE_MAINTENANCE_DATABASE_URL"]
            service = known (webService "alpha" "registry.example.com/alpha")
            worker = either error id (webWorker "alpha-worker" "registry.example.com/alpha")
            app = DslApp.Application (workloadName "alpha") Nothing personal (known (Dsl.mkImageRef "registry.example.com/alpha")) Map.empty [] [] Nothing (Just service) [worker] [hook]
        hookBindings <- expectRight (acceptedAppDatabaseBindings accepted native testCluster "personal" (hook ^. #name) [db "alpha-pg"])
        (scopes, appNative) <- expectRight (compileApplicationDeployment (applicationInput app (Map.singleton (hook ^. #name) hookBindings)))
        let jobs = [(member, bytes) | (member, bytes) <- Map.elems appNative, Kubernetes _ "batch" kind _ _ <- [member ^. #address], nameText kind == "job"]
        map (secretEnv . snd) jobs @?= [[("KOTEI_RELEASE_MAINTENANCE_DATABASE_URL", "alpha-pg-runtime", "DATABASE_URL")]]
        let jobDependencies = concat [member ^. #dependencies | scope <- scopes, bundle <- scopeBundles scope, Managed member <- declarations bundle, Kubernetes _ "batch" kind _ _ <- [member ^. #address], nameText kind == "job"]
        assertBool "the hook Job is not ordered after the bound Secret" (all (`elem` jobDependencies) (map OrderedAfter (secretOf appScopes "alpha-pg-runtime" : membersIn appScopes "appdb-alpha")))
        let workloads = [bytes | (member, bytes) <- Map.elems appNative, Kubernetes _ group _ _ _ <- [member ^. #address], group `elem` ["serving.knative.dev", "apps"]]
        assertBool "a long-running Pod references the hook's Secret" (not (null workloads) && not (any (BS.isInfixOf "alpha-pg-runtime") workloads))
        -- The service, its tasks and the workers keep the EP-202 refusal.
        let bound = [Dsl.appDatabaseBinding (db "alpha-pg")]
        forM_ [app & #service %~ fmap (#appDatabases .~ bound), app & #workers %~ map (#appDatabases .~ bound), app & #service %~ fmap (#tasks .~ [hookTask "alpha-report" bound])] $ \refusedApp ->
          case compileApplicationDeployment (applicationInput refusedApp Map.empty) of
            Left errors -> assertBool (show errors) (any ((== "app-database-not-bindable-from-application") . (^. #code)) (NE.toList errors))
            Right _ -> assertFailure "an application workload bound an app database"
    , testCase "EP-259 M2: a hook named in an app-owned database's owners receives only the owner credential; no web or worker Pod references it" $ do
        let hook = hookTask "alpha-migrate" [named "alpha-pg" "KOTEI_RELEASE_MAINTENANCE_DATABASE_URL"]
            service = known (webService "alpha" "registry.example.com/alpha")
            worker = either error id (webWorker "alpha-worker" "registry.example.com/alpha")
            app = DslApp.Application (workloadName "alpha") Nothing personal (known (Dsl.mkImageRef "registry.example.com/alpha")) Map.empty [] [] Nothing (Just service) [worker] [hook]
        hookBindings <- expectRight (acceptedAppDatabaseTaskBindings appOwnedAccepted appOwnedNative testCluster "personal" (hook ^. #name) [db "alpha-pg"])
        (scopes, appNative) <- expectRight (compileApplicationDeployment (applicationInput app (Map.singleton (hook ^. #name) hookBindings)))
        let jobs = [(member, bytes) | (member, bytes) <- Map.elems appNative, Kubernetes _ "batch" kind _ _ <- [member ^. #address], nameText kind == "job"]
        map (secretEnv . snd) jobs @?= [[("KOTEI_RELEASE_MAINTENANCE_DATABASE_URL", "alpha-pg-owner", "DATABASE_URL")]]
        let jobDependencies = concat [member ^. #dependencies | scope <- scopes, bundle <- scopeBundles scope, Managed member <- declarations bundle, Kubernetes _ "batch" kind _ _ <- [member ^. #address], nameText kind == "job"]
        assertBool "the hook Job is ordered after the owner Secret and the app database" (all (`elem` jobDependencies) (map OrderedAfter (secretOf appOwnedScopes "alpha-pg-owner" : membersIn appOwnedScopes "appdb-alpha")))
        let workloads = [bytes | (member, bytes) <- Map.elems appNative, Kubernetes _ group _ _ _ <- [member ^. #address], group `elem` ["serving.knative.dev", "apps"]]
        assertBool "a long-running Pod references the owner Secret" (not (null workloads) && not (any (BS.isInfixOf "alpha-pg-owner") workloads))
        -- A task not in owners, and any long-running workload, is refused.
        case acceptedAppDatabaseTaskBindings appOwnedAccepted appOwnedNative testCluster "personal" (workloadName "alpha-report") [db "alpha-pg"] of
          Left reason -> assertBool (T.unpack reason) ("not among app database alpha-pg's owners" `T.isInfixOf` reason)
          Right _ -> assertFailure "a task outside owners bound the owner credential"
        case acceptedAppDatabaseBindings appOwnedAccepted appOwnedNative testCluster "personal" (workloadName "alpha-migrate") [db "alpha-pg"] of
          Left reason -> assertBool (T.unpack reason) ("is app-owned" `T.isInfixOf` reason)
          Right _ -> assertFailure "a long-running workload bound an app-owned database"
    ]
  where
    appOwned' = alpha Postgres & #ownership .~ AppOwned (Just (known (mkRoleName "kotei_maintenance"))) & #access . #owners .~ [workloadName "alpha-migrate"]
    appOwnedScopes = [fst (scopeAndNative pgServer appOwned'), fst (scopeAndNative pgServer (beta Postgres))]
    appOwnedAccepted = snapshotWith [pgServer] appOwnedScopes
    appOwnedNative = Map.unions (acceptedNative [pgServer] : [snd (scopeAndNative pgServer d) | d <- [appOwned', beta Postgres]])
    appScopes = [fst (scopeAndNative pgServer (alpha Postgres)), fst (scopeAndNative pgServer (beta Postgres))]
    accepted = snapshotWith [pgServer] appScopes
    native = Map.unions (acceptedNative [pgServer] : [snd (scopeAndNative pgServer d) | d <- [alpha Postgres, beta Postgres]])
    owned = alpha Postgres & #access . #owners .~ [workloadName "alpha-migrate"]
    ownedScopes = [fst (scopeAndNative pgServer owned), fst (scopeAndNative pgServer (beta Postgres))]
    ownedAccepted = snapshotWith [pgServer] ownedScopes
    ownedNative = Map.unions (acceptedNative [pgServer] : [snd (scopeAndNative pgServer d) | d <- [owned, beta Postgres]])
    membersOf prefix = membersIn appScopes prefix
    refused needle = \case
      Left errors -> assertBool (show errors) (any ((needle `T.isInfixOf`) . (^. #message)) (NE.toList errors))
      Right _ -> assertFailure ("compiled; expected a refusal mentioning " <> T.unpack needle)

-- | The users and databases an app database's scope declares.
membersIn :: [ScopeDeclaration] -> Text -> [ResourceId]
membersIn scopes prefix =
  [ member ^. #identity
  | scope <- scopes
  , prefix `T.isPrefixOf` nameText (scopeName (scopeId scope))
  , bundle <- scopeBundles scope
  , Managed member <- declarations bundle
  , member ^. #executor == AppDatabaseExecutor
  ]

-- | The identity of the credential Secret with the given name.
secretOf :: [ScopeDeclaration] -> Text -> ResourceId
secretOf scopes name' =
  case [member ^. #identity | scope <- scopes, bundle <- scopeBundles scope, Managed member <- declarations bundle, Kubernetes _ "" kind _ n <- [member ^. #address], nameText kind == "secret", nameText n == name'] of
    [found] -> found
    _ -> error ("no unique Secret " <> T.unpack name')

dependenciesOf :: ScopeDeclaration -> [Dependency]
dependenciesOf scope = concat [member ^. #dependencies | bundle <- scopeBundles scope, Managed member <- declarations bundle]

-- | Every env entry a render takes from a Secret: its name, Secret and key.
secretEnv :: ByteString -> [(Text, Text, Text)]
secretEnv bytes = either (const []) collect (eitherDecodeStrict bytes)
  where
    collect = \case
      Object fields ->
        [ (name', secret, key')
        | Just (String name') <- [KM.lookup "name" fields]
        , Just (Object from) <- [KM.lookup "valueFrom" fields]
        , Just (Object ref) <- [KM.lookup "secretKeyRef" from]
        , Just (String secret) <- [KM.lookup "name" ref]
        , Just (String key') <- [KM.lookup "key" ref]
        ]
          <> concatMap collect (KM.elems fields)
      Array items -> concatMap collect (V.toList items)
      _ -> []

fst3 :: (a, b, c) -> a
fst3 (a, _, _) = a

compileWorker ::
  Text ->
  [Dsl.AppDatabaseBinding] ->
  Map.Map Dsl.EnvName Dsl.ScopedEnvVar ->
  Map.Map Dsl.DatabaseName DatabaseBinding ->
  Either (NonEmpty InventoryError) (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
compileWorker app bindings env' resolved =
  compileStandaloneWorkerWithDependencies
    (known (mkScopeId Standalone ("worker-" <> app <> "-probe")))
    (either error id (webWorker (app <> "-probe") "registry.example.com/probe") & #appDatabases .~ bindings & #env .~ env')
    (rollout (app <> "-probe") Map.empty & #qualifiedImage .~ known (Dsl.mkImageRef "registry.example.com/probe") & #taggedAppImage .~ "registry.example.com/probe:v1")
    testCluster
    namespaceId
    imageId
    Map.empty
    Map.empty
    Map.empty
    Map.empty
    resolved
    (SourceLocation "test" "worker")

-- | A task of the @alpha@ app that inherits its image.
hookTask :: Text -> [Dsl.AppDatabaseBinding] -> Task
hookTask name' bindings = known (scheduledTask name' "0 3 * * *" "registry.example.com/alpha" "migrate") & #image .~ Nothing & #app .~ Just (workloadName "alpha") & #appDatabases .~ bindings

applicationInput :: Application -> Map.Map Dsl.ServiceName (Map.Map Dsl.DatabaseName DatabaseBinding) -> ApplicationScopeInput
applicationInput app taskBindings =
  ApplicationScopeInput
    { scopeApplication = app
    , scopeRollout = rollout "alpha" Map.empty
    , scopeCluster = testCluster
    , scopeNamespace = namespaceId
    , scopeNamespaceContributionOwner = Nothing
    , scopeImage = imageId
    , scopeBrokerServices = Map.empty
    , scopeBrokerTopics = Map.empty
    , scopeAccessBinding = Nothing
    , scopeCdnBinding = Nothing
    , scopeDatabaseRecovery = Map.empty
    , scopeServiceVolumeRecovery = Map.empty
    , scopeTlsSecrets = Map.empty
    , scopeEnvSecrets = Map.empty
    , scopeBuildSecrets = Set.empty
    , scopeWorkerVolumeRecovery = Map.empty
    , scopeDatabaseBackup = hourlyGcsBackup
    , scopeRelease = (emptyReleaseLog, StaticRelease "v1" "alpha" "personal" "registry.example.com/alpha" "v1" (maybe "" (`serviceUrl` "example.com") (app ^. #service)) (Just "fixture") (UTCTime (fromGregorian 2026 11 11) 0))
    , scopeHookEffects = Map.fromList [(Dsl.serviceNameText (hook ^. #name), []) | hook <- app ^. #tasks]
    , scopeTaskDatabaseBindings = taskBindings
    , scopeInputOverrides = Map.fromList ([("tag", "v1"), ("baseDomain", "example.com"), ("imageResource", resourceIdText imageId)] <> [("hook/" <> Dsl.serviceNameText (hook ^. #name), "") | hook <- app ^. #tasks])
    , scopeSource = SourceLocation "test" "application"
    }

rollout :: Text -> Map.Map Dsl.EnvName Dsl.ScopedEnvVar -> RolloutEnv
rollout app appEnv' =
  RolloutEnv
    { appName = app
    , qualifiedImage = known (Dsl.mkImageRef "registry.example.com/alpha")
    , imageTag = "v1"
    , effectiveTag = "v1"
    , taggedAppImage = "registry.example.com/alpha:v1"
    , appEnv = appEnv'
    , namespace = "personal"
    , baseDomain = "example.com"
    , targetProfile = tnbProfile
    }

namespaceId, imageId :: ResourceId
namespaceId = mintResourceId (known (mkScopeId Platform "foundation")) (known (mkLogicalKey "foundation")) (known (mkName "namespace-personal"))
imageId = mintResourceId (known (mkScopeId Platform "foundation")) (known (mkLogicalKey "image")) (known (mkName "publication"))

personal :: Dsl.Namespace
personal = known (Dsl.mkNamespace "personal")

db :: Text -> Dsl.AppDatabaseName
db = known . Dsl.mkAppDatabaseName

databaseKey :: Text -> Dsl.DatabaseName
databaseKey = known . Dsl.mkDatabaseName

envName :: Text -> Dsl.EnvName
envName = known . Dsl.mkEnvName

named :: Text -> Text -> Dsl.AppDatabaseBinding
named name' variable = Dsl.AppDatabaseBinding (db name') (Just (envName variable))

workloadName :: Text -> Dsl.ServiceName
workloadName = known . Dsl.mkServiceName

workerName :: Text -> Dsl.ServiceName
workerName app = workloadName (app <> "-probe")

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (assertFailure . show) pure
