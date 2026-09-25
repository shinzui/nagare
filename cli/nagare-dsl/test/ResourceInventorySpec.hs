module ResourceInventorySpec (resourceInventoryTests) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Char8 qualified as BC
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Resource.Inventory hiding (cluster)
import Nagare.Resource.Cache (LogicalCacheInput (..), compileLogicalCache)
import Nagare.Resource.CacheKubernetes
import Nagare.Resource.Helm
import Nagare.Resource.Kubernetes
import Nagare.Resource.Policy
import Nagare.Resource.Reference
import Nagare.Resource.Types
import Nagare.Resource.Wire
import Test.Tasty
import Test.Tasty.HUnit
import Data.Yaml qualified as Yaml

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

n :: Text -> Name
n = ok . mkName

s :: ScopeKind -> Text -> ScopeId
s k = ok . mkScopeId k

rid :: ScopeId -> Text -> ResourceId
rid owner key = mintResourceId owner (ok (mkLogicalKey key)) (n "resource")

p, a :: ScopeId
p = s Platform "foundation"
a = s Application "app"

cluster :: ResourceId
cluster = rid p "cluster"

digest :: ContentDigest
digest = ok (mkContentDigest "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")

binding :: ContextBinding
binding = ContextBinding (ok (mkContextId "context-1")) (n "project")

bundle :: [Declaration] -> ResourceBundle
bundle ds = ResourceBundle ds [] [] [] [] []

scope :: ScopeId -> [Declaration] -> ScopeDeclaration
scope owner ds = ok (mkScopeDeclaration owner [bundle ds])

resource :: ScopeId -> Text -> ProviderAddress -> DesiredSpec -> ManagedResource
resource owner key address spec = ManagedResource (rid owner key) owner KubernetesExecutor address [] spec Retain Stateless Public [] [] (SourceLocation "fixture" key)

service :: ScopeId -> Text -> Text -> Declaration
service owner key name = Managed (resource owner key (Kubernetes cluster "" (n "service") (Just (n "nagare-system")) (n name)) (NativeObject digest))

emptySnapshot :: ScopeSnapshot
emptySnapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)

compileScopes :: [ScopeDeclaration] -> Either (NonEmpty InventoryError) CompositionCandidate
compileScopes scopes = composeInventory emptySnapshot (NE.fromList (map ReplaceScope scopes))

rejects :: Text -> Either (NonEmpty InventoryError) a -> Assertion
rejects code result = case result of
  Left es -> assertBool (show es) (code `elem` map (^. #code) (NE.toList es))
  Right _ -> assertFailure "unexpected acceptance"

resourceInventoryTests :: TestTree
resourceInventoryTests =
  testGroup
    "resource inventories"
    [ testCase "smart identities reject separators, empty IDs, and invalid generations" $ do
        assertBool "empty context" (either (const True) (const False) (mkContextId ""))
        assertBool "separators" (either (const True) (const False) (mkLogicalKey "a/b"))
        assertBool "zero" (either (const True) (const False) (mkScopeGeneration 0))
    , testCase "stable key survives provider rename" $ do
        let Managed x = service a "stable" "old"; Managed y = service a "stable" "new"
        x ^. #identity @?= y ^. #identity
    , testCase "collection candidate requires a retained exact claim" $ do
        let resourceId = rid p "old"
            address = Kubernetes cluster "" (n "configmap") (Just (n "nagare-system")) (n "old")
            claim = canonicalClaim address
            holder = ClaimHolder p resourceId (ok (mkPhysicalIdentity "old-uid")) RetainedIncarnation
            snapshot = ok (mkScopeSnapshot binding Map.empty (Map.singleton claim holder))
            candidate = ok (composeInventory snapshot (CollectRetained resourceId :| []))
            encoded = ok (canonicalValue (candidateInputValue (CandidateInput snapshot (CollectRetained resourceId :| []))))
        candidateChanges candidate @?= (CollectRetained resourceId :| [])
        decodeCandidateInput encoded @?= Right (CandidateInput snapshot (CollectRetained resourceId :| []))
        rejects "unknown-collection" (composeInventory emptySnapshot (CollectRetained resourceId :| []))
    , testCase "exact nix-cache Service collision reports both owners" $ do
        let result = compileScopes [scope p [service p "cache" "nix-cache"], scope a [service a "database" "nix-cache"]]
        rejects "claim-conflict" result
        case result of Left es -> assertBool "both owners" (any (\e -> all (`elem` (e ^. #scopes)) [p, a]) es); _ -> pure ()
    , testCase "an external platform database reserves its provider address" $ do
        let address = Kubernetes cluster "apps" (n "statefulset") (Just (n "ns")) (n "db")
            external = External (rid p "external-db") address [] (SourceLocation "fixture" "platform-db")
            application = Managed (resource a "database" address (StatefulSet 1 [] digest))
        rejects "claim-conflict" (compileScopes [scope p [external], scope a [application]])
    , testCase "Helm release reserves each rendered object against another scope" $ do
        let member = Kubernetes cluster "" (n "service") (Just (n "nagare-system")) (n "same")
            release = ok (compileHelmRelease (HelmInput (rid p "helm") p cluster (n "nagare-system")
              (n "metrics") (member :| []) digest [] (SourceLocation "chart" "metrics")))
        rejects "claim-conflict" (compileScopes [scope p [Managed release], scope a [service a "db" "same"]])
    , testCase "Helm release refuses duplicate rendered members" $ do
        let member = Kubernetes cluster "" (n "service") (Just (n "nagare-system")) (n "same")
            input = HelmInput (rid p "helm") p cluster (n "nagare-system") (n "metrics")
              (member :| [member]) digest [] (SourceLocation "chart" "metrics")
        case compileHelmRelease input of
          Left err -> err ^. #code @?= "invalid-helm-release"
          Right _ -> assertFailure "duplicate member was accepted"
    , testCase "Knative child Service conflicts with database Service" $ do
        let app = Managed (resource a "app" (Kubernetes cluster "serving.knative.dev" (n "service") (Just (n "nagare-system")) (n "same")) (KnativeService digest))
        rejects "claim-conflict" (compileScopes [scope p [service p "db" "same"], scope a [app]])
    , testCase "database renderer Service collides with a same-name Knative Service" $ do
        bytes <- BC.readFile "test/golden/db-postgres.service.yaml"
        let dbObject = ok (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
            knativeObject = object
              [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
              , "kind" .= ("Service" :: Text)
              , "metadata" .= object ["name" .= ("pg-main" :: Text), "namespace" .= ("personal" :: Text)]
              ]
            compiled owner key value = Managed (ok (compileKubernetesObject (KubernetesInput (rid owner key) owner cluster value digest Retain Stateless Public (SourceLocation "fixture" key))))
        rejects "claim-conflict" (compileScopes [scope p [compiled p "database" dbObject], scope a [compiled a "application" knativeObject]])
    , testCase "DomainMapping reserves its hostname from native identity" $ do
        let domainObject = object
              [ "apiVersion" .= ("serving.knative.dev/v1beta1" :: Text)
              , "kind" .= ("DomainMapping" :: Text)
              , "metadata" .= object
                  ["name" .= ("app.example.com" :: Text), "namespace" .= ("personal" :: Text)]
              ]
            domainMember = ok (compileKubernetesObject (KubernetesInput (rid a "domain") a cluster
              domainObject digest Retain Stateless Public (SourceLocation "fixture" "domain")))
        domainMember ^. #aliases @?= [Hostname (n "app.example.com")]
        rejects "claim-conflict" (compileScopes
          [scope p [External (rid p "hostname") (Hostname (n "app.example.com")) []
            (SourceLocation "fixture" "hostname")], scope a [Managed domainMember]])
    , testCase "malformed Certificate cannot evade its Secret reservation" $ do
        let cert = object
              [ "apiVersion" .= ("cert-manager.io/v1" :: Text)
              , "kind" .= ("Certificate" :: Text)
              , "metadata" .= object ["name" .= ("tls" :: Text), "namespace" .= ("personal" :: Text)]
              , "spec" .= object []
              ]
        case compileKubernetesObject (KubernetesInput (rid p "certificate") p cluster cert digest Retain Stateless Public (SourceLocation "fixture" "certificate")) of
          Left e -> e ^. #code @?= "invalid-kubernetes-object"
          Right _ -> assertFailure "Certificate without secretName was accepted"
    , testCase "Kubernetes Lists expand before claim validation and retain member paths" $ do
        let item name = object
              [ "apiVersion" .= ("v1" :: Text)
              , "kind" .= ("Service" :: Text)
              , "metadata" .= object ["name" .= name, "namespace" .= ("personal" :: Text)]
              ]
            list = object ["kind" .= ("List" :: Text), "items" .= [item ("same" :: Text), item ("same" :: Text)]]
            source = SourceLocation "fixture.yaml" "document[0]"
            expanded = ok (expandKubernetesList source list)
            compiled (ordinal, (location, value)) =
              Managed (ok (compileKubernetesObject (KubernetesInput (rid p ("item-" <> Text.pack (show ordinal))) p cluster value digest Retain Stateless Public location)))
        map (path . fst) expanded @?= ["document[0][0]", "document[0][1]"]
        rejects "claim-conflict" (compileScopes [scope p (map compiled (zip [0 :: Int ..] expanded))])
        case compileKubernetesObject (KubernetesInput (rid p "list") p cluster list digest Retain Stateless Public source) of
          Left e -> e ^. #code @?= "invalid-kubernetes-object"
          Right _ -> assertFailure "List envelope was accepted as a resource"
    , testCase "malformed Kubernetes List cannot hide a missing object" $ do
        let source = SourceLocation "fixture.yaml" "document[1]"
            malformed = object ["kind" .= ("List" :: Text), "items" .= [item]]
            item = object ["kind" .= ("List" :: Text), "items" .= ([] :: [Value])]
        case expandKubernetesList source malformed of
          Left e -> do
            e ^. #code @?= "invalid-kubernetes-object"
            e ^. #sources @?= [SourceLocation "fixture.yaml" "document[1][0]"]
          Right _ -> assertFailure "empty nested List was accepted"
    , testCase "multi-document YAML expands all resources before collision checks" $ do
        let manifest = BC.pack "apiVersion: v1\nkind: List\nitems:\n  - apiVersion: v1\n    kind: Service\n    metadata: {name: same, namespace: personal}\n---\napiVersion: v1\nkind: Service\nmetadata: {name: same, namespace: personal}\n"
            parsed = ok (parseKubernetesManifest (SourceLocation "fixture.yaml" "cache") manifest)
            compiled (ordinal, (location, value)) =
              Managed (ok (compileKubernetesObject (KubernetesInput (rid p ("yaml-" <> Text.pack (show ordinal))) p cluster value digest Retain Stateless Public location)))
        map (path . fst) parsed @?= ["cache#document[0][0]", "cache#document[1]"]
        rejects "claim-conflict" (compileScopes [scope p (map compiled (zip [0 :: Int ..] parsed))])
    , testCase "trailing YAML separator is empty, but a middle null document refuses" $ do
        let source = SourceLocation "fixture.yaml" "release"
            namespace = "apiVersion: v1\nkind: Namespace\nmetadata: {name: personal}\n"
        length (ok (parseKubernetesManifest source (namespace <> "---\n"))) @?= 1
        case parseKubernetesManifest source (namespace <> "---\nnull\n---\n") of
          Left issue -> issue ^. #code @?= "invalid-kubernetes-object"
          Right _ -> assertFailure "middle null document was accepted"
    , testCase "controller spec cannot omit derived claims" $ do
        let app = Managed (resource a "app" (Kubernetes cluster "serving.knative.dev" (n "service") (Just (n "ns")) (n "same")) (NativeObject digest))
        rejects "invalid-declaration" (mkScopeDeclaration a [bundle [app]])
    , testCase "global buckets collide across scopes" $ do
        let bucket owner = Managed (resource owner "bucket" (GlobalBucket (n "shared")) (NativeObject digest) & #executor .~ PulumiExecutor)
        rejects "claim-conflict" (compileScopes [scope p [bucket p], scope a [bucket a]])
    , testCase "duplicate logical IDs fail before map construction" $
        rejects "duplicate-id" (mkScopeDeclaration a [bundle [service a "same" "first", service a "same" "second"]])
    , testCase "unselected platform bytes and generation remain identical" $ do
        let platform = scope p [service p "cache" "cache"]
            snapshot = ok (mkScopeSnapshot binding (Map.singleton p (ok (mkScopeGeneration 7), platform)) Map.empty)
            result = ok (composeInventory snapshot (ReplaceScope (scope a [service a "app" "app"]) :| []))
        fmap encodeCanonicalScope (Map.lookup p (inventoryScopes (candidateInventory result))) @?= Just (encodeCanonicalScope platform)
        fmap generationNumber (Map.lookup p (candidateGenerations result)) @?= Just 7
        fmap generationNumber (Map.lookup a (candidateGenerations result)) @?= Just 1
    , testCase "retained physical incarnation reserves its address" $ do
        let d@(Managed r) = service a "new" "retained"
            reservation = ClaimHolder p (rid p "old") (ok (mkPhysicalIdentity "uid-1")) RetainedIncarnation
            snapshot = ok (mkScopeSnapshot binding Map.empty (Map.singleton (canonicalClaim (r ^. #address)) reservation))
        rejects "reserved-claim" (composeInventory snapshot (ReplaceScope (scope a [d]) :| []))
    , testCase "scope omission is preserved and retirement is explicit" $ do
        let platform = scope p [service p "cache" "cache"]
            snapshot = ok (mkScopeSnapshot binding (Map.singleton p (ok (mkScopeGeneration 1), platform)) Map.empty)
        Map.size (inventoryScopes (candidateInventory (ok (composeInventory snapshot (ReplaceScope (scope a []) :| []))))) @?= 2
        Map.size (inventoryScopes (candidateInventory (ok (composeInventory snapshot (RetireScope p RetainResources :| []))))) @?= 0
        rejects "unknown-retirement" (composeInventory emptySnapshot (RetireScope p RetainResources :| []))
    , testCase "typed unresolved output matches export; capability mismatch refuses" $ do
        let db = service p "db" "db"
            ref = outputRef DatabaseConnectionW (declarationId db) (n "connection") [NonEmptyOutput] Secret
            bad = outputRef OciImageW (declarationId db) (n "connection") [NonEmptyOutput] Secret
            producer = ok (mkScopeDeclaration p [bundle [db] & #exports .~ [SomeExport ref]])
            consumer r = let Managed x = service a "app" "app" in scope a [Managed (x & #dependencies .~ [Consumes r])]
        assertBool "good unresolved reference" (either (const False) (const True) (compileScopes [producer, consumer (SomeRef ref)]))
        rejects "reference-mismatch" (compileScopes [producer, consumer (SomeRef bad)])
    , testCase "cache public key is a distinct typed output" $ do
        let cache = service p "cache" "cache"
            key = outputRef NixCachePublicKeyW (declarationId cache) (n "public-key") [NonEmptyOutput] Public
            wrong = outputRef DatabaseConnectionW (declarationId cache) (n "public-key") [NonEmptyOutput] Public
            cacheOperation = DeclaredOperation (rid p "configure-cache") (declarationId cache :| []) [] VerifyBeforeRetry CreateLogicalCache
            producer = ok (mkScopeDeclaration p [bundle [cache] & #exports .~ [SomeExport key] & #operations .~ [cacheOperation]])
            missingOperation = ok (mkScopeDeclaration p [bundle [cache] & #exports .~ [SomeExport key]])
            consumer ref = let Managed x = service a "client" "client" in scope a [Managed (x & #dependencies .~ [Consumes ref])]
        assertBool "cache key reference did not compose" (either (const False) (const True) (compileScopes [producer, consumer (SomeRef key)]))
        rejects "output-operation" (compileScopes [missingOperation, consumer (SomeRef key)])
        rejects "reference-mismatch" (compileScopes [producer, consumer (SomeRef wrong)])
        decodeScope (encodeCanonicalScope producer) @?= Right producer
    , testCase "optional config digest survives scope wire and changes revision bytes" $ do
        let base = scope a [service a "app" "app"]
            tagged = withScopeConfigDigest digest base
        scopeConfigDigest base @?= Nothing
        scopeConfigDigest tagged @?= Just digest
        decodeScope (encodeCanonicalScope tagged) @?= Right tagged
        assertBool "config digest did not change canonical scope bytes"
          (encodeCanonicalScope tagged /= encodeCanonicalScope base)
    , testCase "logical Attic cache has its own executor and claim" $ do
        let Managed first = service p "logical-cache" "cache"
            Managed second = service a "other-cache" "cache"
            logical member = Managed (member {address = AtticCache cluster (n "nagare-cache"), executor = CacheExecutor, spec = LogicalCache digest})
            ownerScope = scope p [logical first]
        decodeScope (encodeCanonicalScope ownerScope) @?= Right ownerScope
        rejects "claim-conflict" (compileScopes [ownerScope, scope a [logical second]])
        rejects "invalid-declaration" (mkScopeDeclaration p [bundle [Managed (first {address = AtticCache cluster (n "nagare-cache"), executor = CacheExecutor})]])
    , testCase "logical cache exports its generated public key after database and workload" $ do
        let database = service p "nix-cache-db" "nix-cache-db"
            workload = service p "nix-cache-workload" "nix-cache"
            cacheBundle = compileLogicalCache (LogicalCacheInput p cluster (ok (mkLogicalKey "nix-cache")) (n "nagare-cache") digest
              (declarationId database) (declarationId workload) (SourceLocation "cache" "logical"))
            fullScope = ok (mkScopeDeclaration p [bundle [database, workload], cacheBundle])
        length (exports cacheBundle) @?= 1
        case cacheBundle ^. #operations of
          [operation] -> do
            operationKind operation @?= CreateLogicalCache
            recovery operation @?= VerifyBeforeRetry
            affects operation @?= mintResourceId p (ok (mkLogicalKey "nix-cache")) (n "logical-cache") :| []
          _ -> assertFailure "logical cache configuration operation missing"
        case exports cacheBundle of
          [value] -> let (_, _, capability, constraints, sensitivity) = exportSignature value in do
            capability @?= NixCachePublicKey
            constraints @?= [NonEmptyOutput]
            sensitivity @?= Public
          _ -> assertFailure "logical cache public key export missing"
        assertBool "logical cache dependencies did not compose" (either (const False) (const True) (compileScopes [fullScope]))
    , testCase "cache core binds every direct workload address and refuses the database Service collision" $ do
        let source = SourceLocation "cluster/bootstrap/nix-cache" "cache-core"
            readObjects file = do
              bytes <- BS.readFile ("../../cluster/bootstrap/nix-cache/" <> file)
              pure (map snd (ok (parseKubernetesManifest source bytes)))
        workloadObjects <- readObjects "workloads.yaml.tmpl"
        policyObjects <- readObjects "networkpolicies.yaml"
        checkObjects <- readObjects "config-check-job.yaml.tmpl"
        migrationObjects <- readObjects "migration-job.yaml.tmpl"
        let serverConfig = object
              [ "apiVersion" .= ("v1" :: Text)
              , "kind" .= ("ConfigMap" :: Text)
              , "metadata" .= object ["name" .= ("nagare-nix-cache-server" :: Text), "namespace" .= ("nagare-system" :: Text)]
              ]
            prerequisite role = mintResourceId p (ok (mkLogicalKey role)) (n role)
            renameJob name (Object root) = case KM.lookup "metadata" root of
              Just (Object metadata) -> Object (KM.insert "metadata" (Object (KM.insert "name" (String name) metadata)) root)
              _ -> error "cache Job has no metadata"
            renameJob _ _ = error "cache Job is not an object"
            makeInput checkJob migrationJob deployment publicService internalService gc serverPolicy clientPolicy = CacheCoreInput
              p cluster (ok (mkLogicalKey "nix-cache")) (prerequisite "database") (prerequisite "credential")
              digest serverConfig (renameJob "nix-cache-config-check-aaaaaaaaaaaa" checkJob)
              (renameJob "nix-cache-migrate-aaaaaaaaaaaa" migrationJob)
              deployment publicService internalService gc serverPolicy clientPolicy source
        case (checkObjects, migrationObjects, workloadObjects, policyObjects) of
          ([checkJob], [migrationJob], [deployment, publicService, internalService, gc], [serverPolicy, clientPolicy]) -> do
            let input = makeInput checkJob migrationJob deployment publicService internalService gc serverPolicy clientPolicy
                result = compileCacheCore (const (Right digest)) input
            (cacheBundle, native) <- either (assertFailure . show) pure result
            length (declarations cacheBundle) @?= 9
            length native @?= 9
            length (cacheBundle ^. #operations) @?= 1
            let Managed database = service p "database-prerequisite" "database-prerequisite"
                Managed credential = service p "credential-prerequisite" "credential-prerequisite"
                prerequisites = bundle
                  [ Managed (database {identity = prerequisite "database"})
                  , Managed (credential {identity = prerequisite "credential"})
                  ]
                completeScope = ok (mkScopeDeclaration p [prerequisites, cacheBundle])
            assertBool "cache migration and workload dependencies did not compose"
              (either (const False) (const True) (compileScopes [completeScope]))
            let collision = ok (mkScopeDeclaration p [cacheBundle, bundle [service p "database-service" "nix-cache"]])
            rejects "claim-conflict" (compileScopes [collision])
            case compileCacheCore (const (Right digest)) (makeInput checkJob migrationJob deployment internalService publicService gc serverPolicy clientPolicy) of
              Left errors -> assertBool "wrong Service address was accepted" (any ((== "invalid-cache-core") . (^. #code)) (NE.toList errors))
              Right _ -> assertFailure "cache Services with swapped addresses were accepted"
          _ -> assertFailure "cache template object counts changed"
    , testCase "dependency cycles and dangling references refuse" $ do
        let Managed x = service a "x" "x"; Managed y = service a "y" "y"
        rejects "dependency-cycle" (compileScopes [scope a [Managed (x & #dependencies .~ [OrderedAfter (y ^. #identity)]), Managed (y & #dependencies .~ [OrderedAfter (x ^. #identity)])]])
        rejects "dangling-reference" (compileScopes [scope a [Managed (x & #dependencies .~ [OrderedAfter (y ^. #identity)])]])
    , testCase "resource can wait for a declared migration; reverse dependency cycles refuse" $ do
        let database = service a "database" "database"
            Managed workload = service a "workload" "workload"
            migrationId = rid a "migration"
            migration affected = DeclaredOperation migrationId (affected :| []) [] VerifyBeforeRetry SchemaMigration
            waiting = Managed (workload & #dependencies .~ [OrderedAfter migrationId])
            good = ok (mkScopeDeclaration a [ResourceBundle [database, waiting] [] [] [] [migration (declarationId database)] []])
            cyclic = ok (mkScopeDeclaration a [ResourceBundle [database, waiting] [] [] [] [migration (workload ^. #identity)] []])
        assertBool "migration dependency did not compose" (either (const False) (const True) (compileScopes [good]))
        rejects "dependency-cycle" (compileScopes [cyclic])
    , testCase "delegated fields cannot overlap" $ do
        let Managed x = service a "app" "app"
            del = Delegation cluster (n "spec" :| []) (ReconcileChildren :| [])
        rejects "invalid-declaration" (mkScopeDeclaration a [bundle [Managed (x & #delegations .~ [del, del])]])
    , testCase "durable data cannot silently request deletion" $ do
        let Managed x = service a "db" "db"
            recovery = RecoveryIntent (n "restore") (mkSecretRef (n "credential") (n "v1") :| [])
        rejects "invalid-declaration" (mkScopeDeclaration a [bundle [Managed (x & #dataPolicy .~ Durable recovery & #lifecycle .~ DeleteWhenUnreferenced)]])
    , testCase "authorized namespace contributions coalesce under the platform owner" $ do
        let other = s Application "other"
            contribution = RegisterNamespace p cluster (n "same") (ok (mkLogicalKey "namespace"))
            owner = ok (mkScopeDeclaration p [bundle [] & #grants .~ [NamespaceGrant a cluster, NamespaceGrant other cluster]])
            consumer who = ok (mkScopeDeclaration who [bundle [] & #contributions .~ [contribution]])
        rejects "unauthorized-contribution" (compileScopes [scope p [], consumer a])
        let one = candidateInventory (ok (compileScopes [owner, consumer a]))
            shared = candidateInventory (ok (compileScopes [owner, consumer a, consumer other]))
        length (inventoryDeclarations one) @?= 1
        inventoryDeclarations one @?= inventoryDeclarations shared
        contributionDependents shared @?= Map.singleton
          (mintResourceId p (ok (mkLogicalKey "same")) (n "namespace")) (Set.fromList [a, other])
        let direct = Managed (resource p "direct-namespace"
              (Kubernetes cluster "" (n "namespace") Nothing (n "same")) (NamespaceSpec Nothing))
        let ownerWithDirect = ok (mkScopeDeclaration p [bundle [direct] & #grants .~ [NamespaceGrant a cluster]])
        rejects "claim-conflict" (compileScopes [ownerWithDirect, consumer a])
        let reserved = ok (mkScopeDeclaration a [bundle [] & #contributions .~
              [RegisterNamespace p cluster (n "kube-system") (ok (mkLogicalKey "system"))]])
        rejects "reserved-namespace-contribution" (compileScopes [owner, reserved])
    , testCase "backend contributions compose one authorized owner map" $ do
        let authOwner = s Platform "auth"
            other = s Application "other"
            grant = BackendMapGrant cluster
            owner = ok (mkScopeDeclaration authOwner [bundle [] & #grants .~ [grant]])
            route hostName target role = RegisterBackend authOwner cluster (n hostName) target role
              (ok (mkLogicalKey "route"))
            consumer who contribution = ok (mkScopeDeclaration who
              [bundle [] & #contributions .~ [contribution]])
            protected = route "app.example.test" "http://app.personal.svc.cluster.local" ProtectedBackend
            portal = route "login.example.test" "http://shomei.nagare-system.svc.cluster.local" PortalBackend
            composed scopes = inventoryDeclarations (candidateInventory (ok (compileScopes scopes)))
        rejects "unauthorized-contribution" (compileScopes [scope p [], consumer a protected])
        rejects "conflicting-backend" (compileScopes
          [owner, consumer a protected, consumer other protected])
        let [Managed emptyMap] = composed [owner]
        emptyMap ^. #spec @?= BackendMapSpec []
        let [Managed completeMap] = composed [owner, consumer a protected, consumer other portal]
        completeMap ^. #spec @?= BackendMapSpec
          [(n "app.example.test", "http://app.personal.svc.cluster.local", ProtectedBackend)
          , (n "login.example.test", "http://shomei.nagare-system.svc.cluster.local", PortalBackend)]
        contributionDependents (candidateInventory (ok (compileScopes
          [owner, consumer a protected, consumer other portal]))) @?=
          Map.singleton (backendMapResourceId authOwner) (Set.fromList [a, other])
        fmap encodeCanonicalScope (decodeScope (encodeCanonicalScope (consumer a protected)))
          @?= Right (encodeCanonicalScope (consumer a protected))
        fmap encodeCanonicalScope (decodeScope (encodeCanonicalScope owner))
          @?= Right (encodeCanonicalScope owner)
        rejects "multiple-portals" (compileScopes [owner, consumer a portal,
          consumer other (route "other.example.test" "https://other.example.test" PortalBackend)])
        let standalone = s Standalone "web"
            standaloneRoute = route "web.example.test" "http://web.personal.svc.cluster.local" ProtectedBackend
            [Managed standaloneMap] = composed [owner, consumer standalone standaloneRoute]
        standaloneMap ^. #spec @?= BackendMapSpec
          [(n "web.example.test", "http://web.personal.svc.cluster.local", ProtectedBackend)]
    , testCase "portal contribution composes owned Shomei settings with the backend map" $ do
        let authOwner = s Platform "auth"
            grant = ShomeiSettingsGrant cluster (n "example.test")
            owner = ok (mkScopeDeclaration authOwner [bundle [] & #grants .~ [BackendMapGrant cluster, grant]])
            portal = RegisterBackend authOwner cluster (n "login.example.test")
              "http://shomei.nagare-system.svc.cluster.local" PortalBackend (ok (mkLogicalKey "portal"))
            app = ok (mkScopeDeclaration a [bundle [] & #contributions .~ [portal]])
            composed scopes = inventoryDeclarations (candidateInventory (ok (compileScopes scopes)))
            setting resources = [resource | Managed resource <- resources,
              ShomeiSettingsSpec {} <- [resource ^. #spec]]
        let [base] = setting (composed [owner])
        base ^. #spec @?= ShomeiSettingsSpec (n "example.test") Nothing
        let [withPortal] = setting (composed [owner, app])
        withPortal ^. #spec @?= ShomeiSettingsSpec (n "example.test") (Just (n "login.example.test"))
        withPortal ^. #identity @?= base ^. #identity
        fmap encodeCanonicalScope (decodeScope (encodeCanonicalScope owner)) @?= Right (encodeCanonicalScope owner)
        rejects "invalid-shomei-owner" (compileScopes
          [ok (mkScopeDeclaration authOwner [bundle [] & #grants .~ [grant]])])
    , testCase "canonical scope ignores declaration order and roundtrips" $ do
        let x = service a "x" "x"
            y = service a "y" "y"
            firstScope = scope a [x, y]
            secondScope = scope a [y, x]
        encodeCanonicalScope firstScope @?= encodeCanonicalScope secondScope
        fmap encodeCanonicalScope (decodeScope (encodeCanonicalScope firstScope)) @?= Right (encodeCanonicalScope firstScope)
    , testCase "canonical empty scope golden bytes" $
        encodeCanonicalScope (ok (mkScopeDeclaration a [])) @?= "{\"bundles\":[],\"scope\":{\"kind\":\"Application\",\"name\":\"app\"},\"version\":1}"
    , testCase "public scope overrides are canonical and survive saved review" $ do
        let overrides = Map.fromList [("tag", "v1"), ("baseDomain", "example.test")]
            declared = withScopeOverrides overrides (ok (mkScopeDeclaration a []))
        scopeOverrides declared @?= overrides
        fmap scopeOverrides (decodeScope (encodeCanonicalScope declared)) @?= Right overrides
        assertBool "overrides do not change old empty scope bytes"
          (encodeCanonicalScope declared /= encodeCanonicalScope (ok (mkScopeDeclaration a [])))
    , testCase "unknown fields and schema versions refuse" $ do
        rejects "wire" (decodeScope "{\"version\":2,\"scope\":{},\"bundles\":[]}")
        rejects "wire" (decodeScope "{\"version\":1,\"scope\":{\"kind\":\"Application\",\"name\":\"app\"},\"bundles\":[],\"delete\":true}")
    , testCase "duplicate JSON keys and decimal tokens refuse before normalization" $ do
        rejects "wire" (decodeScope "{\"version\":1,\"version\":2,\"scope\":{\"kind\":\"Application\",\"name\":\"app\"},\"bundles\":[]}")
        rejects "wire" (decodeScope "{\"version\":1.0,\"scope\":{\"kind\":\"Application\",\"name\":\"app\"},\"bundles\":[]}")
    , testCase "API versions normalize to one collision domain" $ do
        let v1 = ok (kubernetesAddress cluster "apps/v1" "Deployment" (Just "ns") "same")
            beta = ok (kubernetesAddress cluster "apps/v1beta1" "Deployment" (Just "ns") "same")
        canonicalClaim v1 @?= canonicalClaim beta
        rejects "claim-conflict" (compileScopes [scope p [Managed (resource p "v1" v1 (NativeObject digest))], scope a [Managed (resource a "beta" beta (NativeObject digest))]])
    , testCase "Kubernetes RBAC names retain colons without loosening scope names" $ do
        let address = ok (kubernetesAddress cluster "rbac.authorization.k8s.io/v1" "ClusterRole" Nothing "system:cert-manager:controller")
            declaration = Managed (resource p "rbac" address (NativeObject digest))
            sourceScope = scope p [declaration]
        assertBool "colon was accepted in a general name" (either (const True) (const False) (mkName "system:controller"))
        fmap encodeCanonicalScope (decodeScope (encodeCanonicalScope sourceScope)) @?= Right (encodeCanonicalScope sourceScope)
    , testCase "certificate and StatefulSet reserve controller children" $ do
        let cert = Managed (resource p "certificate" (Kubernetes cluster "cert-manager.io" (n "certificate") (Just (n "ns")) (n "tls")) (Certificate (n "tls-secret") digest))
            secret = Managed (resource a "secret" (Kubernetes cluster "" (n "secret") (Just (n "ns")) (n "tls-secret")) (NativeObject digest))
            stateful = Managed (resource p "database" (Kubernetes cluster "apps" (n "statefulset") (Just (n "ns")) (n "db")) (StatefulSet 1 [n "data"] digest))
            volume = Managed (resource a "volume" (Kubernetes cluster "" (n "persistentvolumeclaim") (Just (n "ns")) (n "data-db-0")) (NativeObject digest))
        rejects "claim-conflict" (compileScopes [scope p [cert], scope a [secret]])
        rejects "claim-conflict" (compileScopes [scope p [stateful], scope a [volume]])
    , testCase "observed children require exact parent reservations" $ do
        let parent = Managed (resource p "app" (Kubernetes cluster "serving.knative.dev" (n "service") (Just (n "ns")) (n "web")) (KnativeService digest))
            child name = ObservedChild (rid p "child") (declarationId parent) (Kubernetes cluster "" (n "service") (Just (n "ns")) (n name)) (ok (mkPhysicalIdentity "uid")) (SourceLocation "fixture" "child")
        assertBool "reserved child accepted" (either (const False) (const True) (compileScopes [scope p [parent, child "web"]]))
        rejects "unreserved-child" (compileScopes [scope p [parent, child "different"]])
    , testCase "fixture snapshot must contain every base scope" $ do
        let bytes = ok (canonicalValue (object ["version" .= (1 :: Int), "context" .= binding, "base" .= [object ["scope" .= p, "generation" .= (1 :: Int)]], "snapshot" .= ([] :: [Int]), "reservations" .= ([] :: [Int]), "changes" .= [object ["replace" .= scopeValue (scope a [])]]]))
        rejects "wire" (decodeCandidateInput bytes)
    ]
