-- | EP-261 M2: a reviewed Application deploy whose workloads opt out of the
-- managed store names only its own keys, and an Application's worker that does
-- not opt out inherits the Application's store.
module ManagedEnvScopeSpec (managedEnvScopeTests) where

import AppDatabaseSpec (known, testCluster)
import Control.Monad (forM_)
import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (UTCTime), fromGregorian)
import Data.Vector qualified as V
import Data.Yaml qualified as Yaml
import Nagare.App.Deploy (RolloutEnv (..))
import Nagare.Deploy (serviceUrl)
import Nagare.Dsl.Application qualified as DslApp
import Nagare.Dsl.Prelude
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Task (scheduledTask)
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Dsl.Worker (webWorker)
import Nagare.Inventory.Application (ApplicationScopeInput (..), compileApplicationDeployment)
import Nagare.Resource.Inventory
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Static.Release (StaticRelease (..), emptyReleaseLog)
import Nagare.Test.Support.Profiles (hourlyGcsBackup, tnbProfile)
import Test.Tasty
import Test.Tasty.HUnit

managedEnvScopeTests :: TestTree
managedEnvScopeTests =
  testGroup
    "Application managed store scope (EP-261)"
    [ testCase "an all-opted-out Application names only its own keys and depends on the one runtime Secret" $ do
        (scopes, native) <- either (assertFailure . show) pure (compileApplicationDeployment (input (scopedApp Dsl.NoManagedEnv)))
        let objects = workloadObjects scopes native
        sort (map (\(kind, _, _) -> kind) objects) @?= ["cronjob", "deployment", "job", "service"]
        forM_ objects $ \(kind, member, bytes) -> do
          assertBool (T.unpack kind <> " carries envFrom") (not (BS.isInfixOf "envFrom" bytes))
          assertBool (T.unpack kind <> " names the managed ConfigMap") (not (BS.isInfixOf "nagare-env-scoped-runtime" bytes))
          filter (not . ("NAGARE_" `T.isPrefixOf`)) (envNames bytes) @?= declared kind
          -- The hook Job is ordered after its CronJob, which carries the Secret.
          let ordered = member ^. #dependencies <> concat [cron ^. #dependencies | kind == "job", ("cronjob", cron, _) <- objects, OrderedAfter (cron ^. #identity) `elem` member ^. #dependencies]
          assertBool (T.unpack kind <> " is not ordered after the runtime Secret") (OrderedAfter runtimeSecretId `elem` ordered)
        -- The hook's Pod runs as a task, so it keeps Nagare's own variables.
        forM_ [bytes | (kind, _, bytes) <- objects, kind `elem` ["cronjob", "job"]] $ \bytes ->
          assertBool "task lost NAGARE_TASK_NAME" ("NAGARE_TASK_NAME" `elem` envNames bytes)
    , testCase "a reference to the runtime Secret is refused unless it is an accepted resource" $
        case compileApplicationDeployment ((input (scopedApp Dsl.NoManagedEnv)) {scopeEnvSecrets = Map.empty}) of
          Left errors -> assertBool (show errors) (any (("runtime Secret environment" `T.isInfixOf`) . (^. #message)) errors)
          Right _ -> assertFailure "an unreviewed runtime Secret reference compiled"
    , testCase "an Application's service and worker that do not opt out inherit the Application's store" $ do
        let inheriting = scopedApp Dsl.InheritManagedEnv & #service %~ fmap (#managedEnv .~ Dsl.InheritManagedEnv)
        (scopes, native) <- either (assertFailure . show) pure (compileApplicationDeployment (input inheriting))
        let stores = [(kind, envFromNames bytes) | (kind, _, bytes) <- workloadObjects scopes native, kind `elem` ["service", "deployment"]]
        sort stores @?= [(kind, ["nagare-env-scoped-runtime", "nagare-secret-scoped-runtime"]) | kind <- ["deployment", "service"]]
    ]

-- | The names each opted-out workload's configuration declares.
declared :: Text -> [Text]
declared = \case
  "service" -> ["SHARED_KEY", "WEB_TOKEN"]
  "deployment" -> ["SHARED_KEY", "WORKER_TOKEN"]
  _ -> ["MIGRATION_URL"]

-- | A web service, a worker and a pre-deploy hook reading different keys of the
-- one runtime Secret. The service and hook opt out; the worker as given.
scopedApp :: Dsl.ManagedEnv -> DslApp.Application
scopedApp workerManagedEnv =
  DslApp.Application
    { name = scoped
    , logicalKey = Nothing
    , namespace = known (Dsl.mkNamespace "personal")
    , image = known (Dsl.mkImageRef image')
    , env = Map.empty
    , databases = []
    , brokers = []
    , access = Nothing
    , service = Just (known (webService "scoped-web" image') & #env .~ keys ["WEB_TOKEN", "SHARED_KEY"] & #managedEnv .~ Dsl.NoManagedEnv)
    , workers = [either error id (webWorker "scoped-worker" image') & #env .~ keys ["WORKER_TOKEN", "SHARED_KEY"] & #managedEnv .~ workerManagedEnv]
    , tasks =
        [ known (scheduledTask "scoped-migrate" "0 3 * * *" image' "migrate")
            & #image
            .~ Nothing
            & #app
            .~ Just scoped
            & #env
            .~ keys ["MIGRATION_URL"]
            & #managedEnv
            .~ Dsl.NoManagedEnv
        ]
    }
  where
    image' = "registry.example.com/scoped"
    scoped = known (Dsl.mkServiceName "scoped")
    keys names = Map.fromList [(known (Dsl.mkEnvName key'), Dsl.runtimeScoped (Dsl.EnvSecretRef runtimeSecretName)) | key' <- names]

runtimeSecretName :: Dsl.SecretName
runtimeSecretName = known (Dsl.mkSecretName "nagare-secret-scoped-runtime")

runtimeSecretId :: ResourceId
runtimeSecretId = mintResourceId foundation (known (mkLogicalKey "scoped-runtime")) (known (mkName "secret"))

foundation :: ScopeId
foundation = known (mkScopeId Platform "foundation")

input :: DslApp.Application -> ApplicationScopeInput
input app =
  ApplicationScopeInput
    { scopeApplication = app
    , scopeRollout =
        RolloutEnv
          { appName = "scoped"
          , qualifiedImage = known (Dsl.mkImageRef "registry.example.com/scoped")
          , imageTag = "v1"
          , effectiveTag = "v1"
          , taggedAppImage = "registry.example.com/scoped:v1"
          , appEnv = Map.empty
          , namespace = "personal"
          , baseDomain = "example.com"
          , targetProfile = tnbProfile
          }
    , scopeCluster = testCluster
    , scopeNamespace = mintResourceId foundation (known (mkLogicalKey "foundation")) (known (mkName "namespace-personal"))
    , scopeNamespaceContributionOwner = Nothing
    , scopeImage = imageId
    , scopeBrokerServices = Map.empty
    , scopeBrokerTopics = Map.empty
    , scopeAccessBinding = Nothing
    , scopeCdnBinding = Nothing
    , scopeDatabaseRecovery = Map.empty
    , scopeServiceVolumeRecovery = Map.empty
    , scopeTlsSecrets = Map.empty
    , scopeEnvSecrets =
        Map.singleton
          runtimeSecretName
          ( External
              runtimeSecretId
              (Kubernetes testCluster "" (known (mkName "secret")) (Just (known (mkName "personal"))) (known (mkName "nagare-secret-scoped-runtime")))
              []
              source
          )
    , scopeBuildSecrets = Set.empty
    , scopeWorkerVolumeRecovery = Map.empty
    , scopeDatabaseBackup = hourlyGcsBackup
    , scopeRelease = (emptyReleaseLog, StaticRelease "v1" "scoped-web" "personal" "registry.example.com/scoped" "v1" (maybe "" (`serviceUrl` "example.com") (app ^. #service)) (Just "fixture") (UTCTime (fromGregorian 2026 11 12) 0))
    , scopeHookEffects = Map.fromList [(Dsl.serviceNameText (hook ^. #name), []) | hook <- app ^. #tasks]
    , scopeTaskDatabaseBindings = Map.empty
    , scopeInputOverrides = Map.fromList ([("tag", "v1"), ("baseDomain", "example.com"), ("imageResource", resourceIdText imageId)] <> [("hook/" <> Dsl.serviceNameText (hook ^. #name), "") | hook <- app ^. #tasks])
    , scopeSource = source
    }
  where
    imageId = mintResourceId foundation (known (mkLogicalKey "image")) (known (mkName "publication"))
    source = SourceLocation "test" "application"

-- | The compiled Knative Service, worker Deployment, CronJob and hook Job, each
-- with its declared member (for dependencies) and its native manifest.
workloadObjects :: [ScopeDeclaration] -> Map.Map ResourceId (ManagedResource, ByteString) -> [(Text, ManagedResource, ByteString)]
workloadObjects scopes native =
  [ (nameText kind, member, bytes)
  | scope <- scopes
  , bundle <- scopeBundles scope
  , Managed member <- declarations bundle
  , Kubernetes _ group kind _ _ <- [member ^. #address]
  , (group, nameText kind) `elem` [("serving.knative.dev", "service"), ("apps", "deployment"), ("batch", "cronjob"), ("batch", "job")]
  , Just (_, bytes) <- [Map.lookup (member ^. #identity) native]
  ]

-- | The @env@ names of every container in a manifest, sorted.
envNames :: ByteString -> [Text]
envNames bytes = sort [name' | container <- containers bytes, Just (Array entries) <- [KM.lookup "env" container], Object entry <- V.toList entries, Just (String name') <- [KM.lookup "name" entry]]

-- | The ConfigMap and Secret names of every container's @envFrom@, sorted.
envFromNames :: ByteString -> [Text]
envFromNames bytes =
  sort
    [ name'
    | container <- containers bytes
    , Just (Array entries) <- [KM.lookup "envFrom" container]
    , Object entry <- V.toList entries
    , Object ref <- KM.elems entry
    , Just (String name') <- [KM.lookup "name" ref]
    ]

containers :: ByteString -> [KM.KeyMap Value]
containers bytes = either (const []) collect (Yaml.decodeEither' bytes)
  where
    collect = \case
      Object fields ->
        [container | Just (Array items) <- [KM.lookup "containers" fields], Object container <- V.toList items]
          <> concatMap collect (KM.elems fields)
      Array items -> concatMap collect (V.toList items)
      _ -> []
