-- | EP-248: a delegated deployer's and builder's Kubernetes authority. The
-- rules are checked against production-compiled scopes of every delegated
-- kind (D1); the delegation scope carries the identities and empties every
-- rule on revocation (D2); the builder can run exactly what a one-shot Job
-- renders (D3).
module Nagare.Test.DeployerAccess
  ( deployerAccessTests
  )
where

import Control.Monad (forM_)
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime (UTCTime), fromGregorian)
import Data.Yaml qualified as Yaml
import Nagare.Access.Resolve (backendConfigMapName)
import Nagare.App.Deploy (RolloutEnv (..))
import Nagare.Deploy (serviceUrl)
import Nagare.Deploy.Host (HostShape (..))
import Nagare.Dsl.Job (oneShotJob)
import Nagare.Dsl.Job.Render (renderJob)
import Nagare.Dsl.Load (loadApplication)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Server.Types (ServerSite (..), defaultServerRuntime, tanstackStartBuild)
import Nagare.Dsl.Static.Types (mkSiteName)
import Nagare.Dsl.Task (scheduledTask)
import Nagare.Dsl.Task.Render (renderTask)
import Nagare.Dsl.Types (EnvName, EnvVar (EnvSecretRef), ScopedEnvVar, SecretName, defaultPort, imageRefText, mkDomains, mkEnvName, mkImageRef, mkNamespace, mkSecretName, mkServiceName, runtimeScoped, serviceNameText)
import Nagare.Dsl.Worker (webWorker)
import Nagare.Inventory.Application (ApplicationScopeInput (..), compileApplicationDeployment, compileStandaloneWorker)
import Nagare.Inventory.DeployerAccess
import Nagare.Inventory.DeployerDelegation
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Site (compileServerSiteScope)
import Nagare.Inventory.TaskRun (compileTaskRunScope)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced, Retain), Sensitivity (Private))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Server.Deploy qualified as ServerDeploy
import Nagare.Static.Release (StaticRelease (..), emptyReleaseLog)
import Nagare.Test.SiteInventory.Access (SiteFixture (..), protectedSiteFixture)
import Nagare.Test.Support.Profiles (hourlyGcsBackup, initProfile)
import Test.Tasty
import Test.Tasty.HUnit

deployerAccessTests :: TestTree
deployerAccessTests =
  testGroup
    "Deployer"
    [ testCase "D1: each delegated kind's rules are exactly what its compiled scopes write and read" $ do
        compiled <- kindFixtures
        forM_ compiled $ \(kind, scopes) -> do
          let derived = Set.fromList (concatMap delegatedAccess scopes)
              granted = Set.fromList [(group, resource, writes) | rule <- deployerRules (kind :| []), group <- rule ^. #apiGroups, resource <- rule ^. #resources, let writes = "create" `elem` rule ^. #verbs]
          assertEqual (T.unpack (delegatedKindText kind)) derived granted
    , testCase "D1: every nagare-system object a delegated scope writes or reads is granted, and nothing else there" $ do
        compiled <- kindFixtures
        let needed = Set.fromList (concatMap (concatMap systemAccess . snd) compiled)
            granted = Set.fromList [(resource, name', verb) | rule <- systemRules, resource <- rule ^. #resources, name' <- namesOf rule, verb <- rule ^. #verbs]
            namesOf rule = if null (rule ^. #resourceNames) then [""] else rule ^. #resourceNames
            covered (resource, name', verb) = any (\(r, n, v) -> r == resource && (n == "" || n == name') && v == verb) (Set.toList granted)
        [miss | miss <- Set.toList needed, not (covered miss)] @?= []
        -- Nothing is granted there that no delegated scope touches.
        let touched = Set.fromList [(resource, name') | (resource, name', _) <- Set.toList needed]
        [(resource, name') | (resource, name', _) <- Set.toList granted, name' /= "", (resource, name') `Set.notMember` touched] @?= []
        sort (nub [resource | (resource, "", _) <- Set.toList granted]) @?= sort (nub [resource | (resource, name', _) <- Set.toList needed, resource == "domainmappings", name' /= ""])
    , testCase "D2: an active delegation compiles the deployer's identity with the derived rules, all Retain" $ do
        (scope, native) <- expectRight (compileDelegationScope fixtureCluster systemNamespace Nothing teamDelegation)
        let objects = identityOf scope native
        sort [(kind, ns, name') | (kind, ns, name', _) <- objects]
          @?= sort
            [ ("clusterrole", "", "nagare-deployer-kotei")
            , ("clusterrolebinding", "", "nagare-deployer-kotei")
            , ("role", "nagare-system", "nagare-deployer-kotei")
            , ("role", "team-a", "nagare-deployer-kotei")
            , ("role", "team-b", "nagare-deployer-kotei")
            , ("role", "team-build", "nagare-builder-kotei")
            , ("rolebinding", "nagare-system", "nagare-deployer-kotei")
            , ("rolebinding", "team-a", "nagare-deployer-kotei")
            , ("rolebinding", "team-b", "nagare-deployer-kotei")
            , ("rolebinding", "team-build", "nagare-builder-kotei")
            , ("serviceaccount", "nagare-system", "nagare-deployer-kotei")
            , ("serviceaccount", "team-build", "nagare-builder-kotei")
            ]
        all ((== Retain) . (^. #lifecycle)) [resource | bundle <- scopeBundles scope, Managed resource <- bundle ^. #declarations] @? "every member is Retain"
        let rulesOf kind ns = [rules | (kind', ns', _, rules) <- objects, kind' == kind, ns' == ns]
        rulesOf "role" "team-a" @?= [map ruleJson (deployerRules (teamDelegation ^. #kinds))]
        rulesOf "role" "nagare-system" @?= [map ruleJson (systemRules)]
        rulesOf "clusterrole" "" @?= [map ruleJson clusterReadRules]
        rulesOf "role" "team-build" @?= [map ruleJson builderRules]
        -- Every binding names its own role and its own identity.
        [subject | ("rolebinding", ns, _, _) <- objects, subject <- subjectsOf scope native "rolebinding" ns] @?= ["nagare-system/nagare-deployer-kotei", "nagare-system/nagare-deployer-kotei", "nagare-system/nagare-deployer-kotei", "team-build/nagare-builder-kotei"]
    , testCase "D7: revoking keeps every identity object and empties every Role; the read-only ClusterRole stays" $ do
        (active, _) <- expectRight (compileDelegationScope fixtureCluster systemNamespace Nothing teamDelegation)
        (revoked, native) <- expectRight (compileDelegationScope fixtureCluster systemNamespace Nothing (teamDelegation & #state .~ DelegationRevoked))
        let objects = identityOf revoked native
            identities scope = sort [resourceIdText (resource ^. #identity) | bundle <- scopeBundles scope, Managed resource <- bundle ^. #declarations]
        identities revoked @?= identities active
        [rules | ("role", _, _, rules) <- objects] @?= replicate 4 []
        -- No rules key at all: the API server stores an empty list as null.
        [() | (resource, bytes) <- Map.elems native, Kubernetes _ _ kind _ _ <- [resource ^. #address], nameText kind == "role", "\"rules\"" `BS.isInfixOf` bytes] @?= []
        [rules | ("clusterrole", _, _, rules) <- objects] @?= [map ruleJson clusterReadRules]
    , testCase "D3: the builder can create every object a one-shot Job renders, and nothing more" $ do
        job <- either fail pure (oneShotJob "build" "registry.example.test/team/build")
        let rendered = [kindOf bytes | bytes <- renderJob job "v1"]
            kindOf bytes = case Yaml.decodeEither' bytes of
              Right (Object root) | Just (String kind) <- KM.lookup "kind" root -> T.toLower kind
              _ -> "unreadable"
            creatable = sort [resource | rule <- builderRules, "create" `elem` rule ^. #verbs, resource <- rule ^. #resources]
        sort (map pluralOf rendered) @?= creatable
        sort (nub (concat [rule ^. #verbs | rule <- builderRules])) @?= ["create", "delete", "get", "list", "watch"]
        [resource | rule <- builderRules, resource <- rule ^. #resources, resource `elem` ["secrets", "pods/exec", "deployments"]] @?= []
    ]

-- | (API group, resource, written) for each Kubernetes object a delegated
-- scope writes or reads in a delegated namespace. Members the delegation
-- bounds refuse never reach Kubernetes and are left out.
delegatedAccess :: ScopeDeclaration -> [(Text, Text, Bool)]
delegatedAccess scope =
  [ (group, pluralOf kind, written)
  | (written, group, kind, ns, _) <- kubernetesObjects scope
  , ns /= Just "nagare-system"
  , (group, kind) `elem` allowedKubernetesKinds
  ]

-- | (resource, name, verb) for each object in @nagare-system@ a delegated
-- scope writes (a protected route, the regenerated backend map) or reads.
systemAccess :: ScopeDeclaration -> [(Text, Text, Text)]
systemAccess scope =
  [ (pluralOf kind, name', verb)
  | (written, _, kind, Just "nagare-system", name') <- kubernetesObjects scope
  , verb <- if written then lifecycleVerbs else ["get"]
  ]
    <> [ ("configmaps", backendConfigMapName, verb)
       | not (null [() | bundle <- scopeBundles scope, RegisterBackend {} <- bundle ^. #contributions])
       , verb <- ["get", "patch", "update"]
       ]

kubernetesObjects :: ScopeDeclaration -> [(Bool, Text, Text, Maybe Text, Text)]
kubernetesObjects scope =
  [ (written, group, nameText kind, nameText <$> ns, nameText name')
  | bundle <- scopeBundles scope
  , declaration <- bundle ^. #declarations
  , (written, address) <- case declaration of
      Managed resource -> [(True, resource ^. #address)]
      External _ address _ _ -> [(False, address)]
      _ -> []
  , Kubernetes _ group kind ns name' <- [address]
  ]

-- | One production-compiled set of scopes per delegated kind, each as rich as
-- a delegation admits: a web app with workers, a hook and a scheduled task;
-- a standalone worker; a manual task run; a protected static site; and a
-- server site.
kindFixtures :: IO [(DelegatedKind, [ScopeDeclaration])]
kindFixtures = do
  webApp <- webAppScopes
  site <- protectedSite <$> protectedSiteFixture
  pure
    [ (DelegatedWebApp, webApp)
    , (DelegatedWorker, [workerScope])
    , (DelegatedTask, [taskScope])
    , (DelegatedStaticSite, [site])
    , (DelegatedServerSite, [serverScope])
    ]

webAppScopes :: IO [ScopeDeclaration]
webAppScopes = do
  loaded <- loadApplication "test/fixtures/app/kizashi/Config.hs" >>= either (fail . show) pure
  let app = loaded & #databases .~ [] & #workers %~ map (#databases .~ []) & #env .~ secretEnv
      hooks = [serviceNameText (hook ^. #name) | hook <- app ^. #tasks]
  service <- maybe (assertFailure "the fixture has no web Service") pure (app ^. #service)
  let appRelease = StaticRelease "v1" (serviceNameText (service ^. #name)) "personal" (imageRefText (rollout "kizashi" ^. #qualifiedImage)) "v1" (serviceUrl service "example.com") (Just "fixture") (UTCTime (fromGregorian 2026 11 11) 0)
      input =
        ApplicationScopeInput
          { scopeApplication = app
          , scopeRollout = rollout "kizashi" & #appEnv .~ app ^. #env
          , scopeCluster = fixtureCluster
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
          , scopeEnvSecrets = secretBindings
          , scopeBuildSecrets = Set.empty
          , scopeWorkerVolumeRecovery = Map.empty
          , scopeDatabaseBackup = hourlyGcsBackup
          , scopeRelease = (emptyReleaseLog, appRelease)
          , scopeHookEffects = Map.fromList [(hook, []) | hook <- hooks]
          , scopeTaskDatabaseBindings = Map.empty
          , scopeInputOverrides = Map.fromList ([("tag", "v1"), ("baseDomain", "example.com"), ("imageResource", resourceIdText imageId)] <> [("hook/" <> hook, "") | hook <- hooks])
          , scopeSource = SourceLocation "test" "application"
          }
  fst <$> expectRight (compileApplicationDeployment input)

workerScope :: ScopeDeclaration
workerScope =
  let worker = ok (webWorker "ticker" "registry.example.test/team/ticker") & #env .~ secretEnv
   in fst (ok (compileStandaloneWorker (ok (mkScopeId Standalone "worker-ticker")) worker (rollout "ticker") fixtureCluster namespaceId imageId Map.empty secretBindings Map.empty (SourceLocation "test" "worker")))

-- | A runtime environment reference to a Secret the scope does not own.
secretEnv :: Map.Map EnvName ScopedEnvVar
secretEnv = Map.singleton (ok (mkEnvName "PRIVATE_TOKEN")) (runtimeScoped (EnvSecretRef (ok (mkSecretName "external-token"))))

secretBindings :: Map.Map SecretName Declaration
secretBindings =
  Map.singleton
    (ok (mkSecretName "external-token"))
    (External (mintResourceId foundationOwner (ok (mkLogicalKey "external-token")) (ok (mkName "secret"))) (Kubernetes fixtureCluster "" (ok (mkName "secret")) (Just (ok (mkName "personal"))) (ok (mkName "external-token"))) [] (SourceLocation "test" "secret"))

taskScope :: ScopeDeclaration
taskScope =
  let task = ok (scheduledTask "cleanup" "0 2 * * *" "example.test/demo" "cleanup") & #app .~ Just (ok (mkServiceName "demo"))
      bytes = renderTask task
      value = ok (Yaml.decodeEither' bytes)
      owner = ok (mkScopeId Application "demo")
      cronId = mintResourceId owner (ok (mkLogicalKey "cleanup")) (ok (mkName "cronjob"))
      source = SourceLocation "fixture" "task-run/r1"
      (cronJob, _) = ok (bindKubernetesObject (KubernetesInput cronId owner fixtureCluster value (contentDigest (ok (canonicalValue value))) DeleteWhenUnreferenced Stateless Private source))
   in fst (ok (compileTaskRunScope (Just "demo") cronJob bytes "r1" source))

serverScope :: ScopeDeclaration
serverScope =
  let site =
        ServerSite
          { name = ok (mkSiteName "demo")
          , namespace = ok (mkNamespace "personal")
          , image = ok (mkImageRef "registry.example.test/team/demo")
          , build = tanstackStartBuild
          , runtime = defaultServerRuntime
          , port = defaultPort
          , env = secretEnv
          , resources = Nothing
          , scale = Nothing
          , domains = ok (mkDomains [("demo.example.com", True)])
          , volumes = []
          , cdn = Nothing
          , access = Nothing
          }
      inputs = ServerDeploy.ServerDeployInputs site "v1" "example.com" "." True initProfile
      siteRelease = StaticRelease "v1" "demo" "personal" "registry.example.test/team/demo" "v1" (ServerDeploy.serverUrl site "example.com") Nothing (UTCTime (fromGregorian 2026 11 11) 0)
   in fst (ok (compileServerSiteScope inputs fixtureCluster namespaceId imageId Map.empty secretBindings Map.empty emptyReleaseLog siteRelease (SourceLocation "fixture" "server-site")))

rollout :: Text -> RolloutEnv
rollout app =
  RolloutEnv
    { appName = app
    , qualifiedImage = ok (mkImageRef ("registry.example.test/team/" <> app))
    , imageTag = "v1"
    , effectiveTag = "v1"
    , taggedAppImage = "registry.example.test/team/" <> app <> ":v1"
    , appEnv = Map.empty
    , namespace = "personal"
    , baseDomain = "example.com"
    , targetProfile = initProfile
    }

-- ---------------------------------------------------------------------------
-- The delegation scope's identity objects.

teamDelegation :: DeployerDelegation
teamDelegation =
  DeployerDelegation
    { name = "kotei"
    , state = DelegationActive
    , namespaces = "team-a" :| ["team-b"]
    , hostSuffixes = ["-docs"]
    , kinds = DelegatedWebApp :| [DelegatedStaticSite]
    , imageRepository = "registry.example.test/project/nagare/team"
    , team = "engineering"
    , buildNamespace = Just "team-build"
    , quota = defaultQuota
    , baseDomain = "example.com"
    , hostShape = NestedHosts
    }

-- | (kind, namespace, name, rules) of each RBAC object and ServiceAccount.
identityOf :: ScopeDeclaration -> Map.Map ResourceId (ManagedResource, ByteString) -> [(Text, Text, Text, [Value])]
identityOf scope native =
  [ (nameText kind, maybe "" nameText ns, nameText name', rulesIn bytes)
  | bundle <- scopeBundles scope
  , Managed resource <- bundle ^. #declarations
  , Kubernetes _ _ kind ns name' <- [resource ^. #address]
  , nameText kind `elem` ["serviceaccount", "role", "rolebinding", "clusterrole", "clusterrolebinding"]
  , Just (_, bytes) <- [Map.lookup (resource ^. #identity) native]
  ]
  where
    rulesIn bytes = case eitherDecodeStrict bytes of
      Right (Object root) | Just (Array rules) <- KM.lookup "rules" root -> toList rules
      _ -> []

subjectsOf :: ScopeDeclaration -> Map.Map ResourceId (ManagedResource, ByteString) -> Text -> Text -> [Text]
subjectsOf scope native kind ns =
  [ subjectNs <> "/" <> subjectName
  | bundle <- scopeBundles scope
  , Managed resource <- bundle ^. #declarations
  , Kubernetes _ _ kind' (Just ns') _ <- [resource ^. #address]
  , nameText kind' == kind
  , nameText ns' == ns
  , Just (_, bytes) <- [Map.lookup (resource ^. #identity) native]
  , Right (Object root) <- [eitherDecodeStrict bytes]
  , Just (Array subjects) <- [KM.lookup "subjects" root]
  , Object subject <- toList subjects
  , Just (String subjectNs) <- [KM.lookup "namespace" subject]
  , Just (String subjectName) <- [KM.lookup "name" subject]
  ]

ruleJson :: KubernetesRule -> Value
ruleJson rule = case Yaml.decodeEither' (Yaml.encode (rulePairs rule)) of
  Right value -> value
  Left _ -> Null
  where
    rulePairs r = Map.fromList ([("apiGroups", r ^. #apiGroups), ("resources", r ^. #resources), ("verbs", r ^. #verbs)] <> [("resourceNames", r ^. #resourceNames) | not (null (r ^. #resourceNames))]) :: Map.Map Text [Text]

-- ---------------------------------------------------------------------------
-- Fixtures.

foundationOwner, clusterOwner :: ScopeId
foundationOwner = ok (mkScopeId Platform "foundation")
clusterOwner = ok (mkScopeId Platform "cluster")

fixtureCluster, systemNamespace, namespaceId, imageId :: ResourceId
fixtureCluster = mintResourceId clusterOwner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
systemNamespace = mintResourceId foundationOwner (ok (mkLogicalKey "foundation")) (ok (mkName "namespace-nagare-system"))
namespaceId = mintResourceId foundationOwner (ok (mkLogicalKey "foundation")) (ok (mkName "namespace-personal"))
imageId = mintResourceId foundationOwner (ok (mkLogicalKey "image")) (ok (mkName "publication"))

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (assertFailure . show) pure

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
