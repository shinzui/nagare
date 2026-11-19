-- | EP-243 D3, D4 and D5: what each observation and wait step of a move decides from the facts, and
-- which review the commit plans next. The production interpreter only gathers the facts.
module Nagare.Test.ContextMoveChecks
  ( contextMoveChecksTests
  )
where

import Data.Either (isLeft, isRight)
import Data.Generics.Labels ()
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, addUTCTime, nominalDay)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Nagare.Context.Move (StepOutcome (..))
import Nagare.Context.MoveChecks
import Nagare.Context.MoveCommit
import Nagare.Context.MoveHosts
import Nagare.Context.MoveRoutes (carryOldRoutes, otherBase, routesToCarry, servesOtherBase, withoutOriginTls)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (OperationAction (..))
import Nagare.Inventory.Cloud
import Nagare.Inventory.Components.CloudflareZone (CloudflareZoneInput (..), compileCloudflareZone)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store.Manifest (ScopeRevision (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (..))
import Nagare.Resource.Types
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

contextMoveChecksTests :: TestTree
contextMoveChecksTests =
  testGroup
    "context move checks (EP-243)"
    [ testCase "dig output parses into records, skipping comments and blank lines" $
        parseDigRecords
          ( T.unlines
              [ "; <<>> DiG 9.20 <<>> NS example.com"
              , ""
              , "example.com.\t\t172800\tIN\tNS\tA.IANA-SERVERS.NET."
              , "example.com. 3600 IN DS 2371 13 2 1F987CC6583E92DF0890718C42"
              ]
          )
          @?= [ DigRecord "example.com" 172800 "NS" "A.IANA-SERVERS.NET."
              , DigRecord "example.com" 3600 "DS" "2371 13 2 1F987CC6583E92DF0890718C42"
              ]
    , testCase "a move starts only when the zone is the base, the parent has no DS and no certificate renews soon (D3, D4)" $ do
        let zone = Just (ZoneStatus "Example.com." "pending" ["ada.ns.cloudflare.com"] Nothing)
            later = Just (addUTCTime (15 * nominalDay) now)
        preconditions now "example.com" zone False [("apps/site", later)] @?= StepCompleted
        waiting (preconditions now "example.com" Nothing False [])
        refused "not example.com" (preconditions now "example.com" (Just (ZoneStatus "other.com" "active" [] Nothing)) False [])
        refused "DS record" (preconditions now "example.com" zone True [])
        refused "apps/site renews" (preconditions now "example.com" zone False [("apps/site", Just (addUTCTime (13 * nominalDay) now))])
        refused "no renewal time" (preconditions now "example.com" zone False [("apps/site", Nothing)])
    , testCase "the move waits for Cloudflare to activate the zone, naming its name servers" $ do
        nameServersActive (ZoneStatus "example.com" "active" [] (Just now)) @?= StepCompleted
        case nameServersActive (ZoneStatus "example.com" "pending" ["ada.ns.cloudflare.com", "bob.ns.cloudflare.com"] Nothing) of
          StepWaiting reason -> assertBool "names both servers" (all (`T.isInfixOf` reason) ["ada.ns.cloudflare.com", "bob.ns.cloudflare.com"])
          other -> assertFailure (show other)
    , testCase "DNSSEC completes once active, hands over the DS while pending, and must lose its DS before rollback (D3, D5)" $ do
        dnssecReady (DnssecStatus "active" Nothing) @?= StepCompleted
        case dnssecReady (DnssecStatus "pending" (Just "example.com. 3600 IN DS 2371 13 2 ABC")) of
          StepWaiting reason -> assertBool "the DS record" ("2371 13 2 ABC" `T.isInfixOf` reason)
          other -> assertFailure (show other)
        waiting (dnssecReady (DnssecStatus "disabled" Nothing))
        waiting (dnssecRemoved True)
        dnssecRemoved False @?= StepCompleted
    , testCase "direct and edge probes refuse what does not answer" $ do
        directAnswers "example.com" True @?= StepCompleted
        refused "does not answer" (directAnswers "example.com" False)
        edgeAnswers [("example.com", Just True), ("a.example.com", Just True)] @?= StepCompleted
        refused "a.example.com" (edgeAnswers [("example.com", Just True), ("a.example.com", Just False)])
        waiting (edgeAnswers [("example.com", Nothing), ("a.example.com", Just True)])
        refused "no hostname" (edgeAnswers [])
    , testCase "the firewall waits for the old delegation, a Cloud DNS answer and a mirror answer to expire (D3)" $ do
        let activated = Just (addUTCTime (-1000) now)
            switched = Just (addUTCTime (-100) now)
        -- Parent TTL 172800 after activation is far in the future.
        waiting (oldAnswersExpired now 300 activated 172800 switched)
        -- A short parent TTL has expired, but the mirror record switched 100 s ago has not.
        waiting (oldAnswersExpired now 300 activated 300 switched)
        oldAnswersExpired now 300 activated 300 (Just (addUTCTime (-301) now)) @?= StepCompleted
        refused "activation time" (oldAnswersExpired now 300 Nothing 300 switched)
        refused "modification time" (oldAnswersExpired now 300 activated 300 Nothing)
    , testCase "rollback keeps the connector and carried names until edge answers have expired (D5)" $ do
        waiting (edgeCachesExpired now 300 False (Just now))
        waiting (edgeCachesExpired now 300 True (Just (addUTCTime (-10) now)))
        edgeCachesExpired now 300 True (Just (addUTCTime (-301) now)) @?= StepCompleted
        refused "modification time" (edgeCachesExpired now 300 True Nothing)
    , testCase "rollback keeps the mirror until the parent and public resolvers name Cloud DNS again (D5)" $ do
        let cloudDns = ["ns-cloud-a1.googledomains.com.", "ns-cloud-a2.googledomains.com."]
            cloudflare = ["ada.ns.cloudflare.com"]
            normalised = ["NS-CLOUD-A2.googledomains.com", "ns-cloud-a1.googledomains.com"]
        waiting (nameServersReturned cloudDns cloudflare [cloudDns])
        waiting (nameServersReturned cloudDns normalised [cloudDns, cloudflare])
        nameServersReturned cloudDns normalised [cloudDns, normalised] @?= StepCompleted
    , testCase "the commit lets the web rules be deleted, retires them, collects each, then writes the profile (D6)" $ do
        -- The bucket orders after a web rule, as the Pulumi catalog orders cloud members (ep246d, 2026-11-19).
        let plain = cloudScopeWith Retain
            ruleIds = [m ^. #identity | m <- members plain, isTunnelWebRule m]
            orderAfterRules = \case
              Managed m | not (isTunnelWebRule m) -> Managed (m & #dependencies %~ (<> map OrderedAfter (take 1 ruleIds)))
              other -> other
            accepted = ok (mkScopeDeclaration (scopeId plain) [b & #declarations %~ map orderAfterRules | b <- scopeBundles plain])
        policy <- expectRight (commitAction webRuleSet (Just accepted) [])
        policyScope <- case policy of
          CommitPolicy revised -> pure revised
          other -> assertFailure ("expected the policy review: " <> show other) >> pure accepted
        [m ^. #lifecycle | m <- members policyScope, isTunnelWebRule m] @?= replicate 3 DeleteWhenUnreferenced
        [m | m <- members policyScope, not (isTunnelWebRule m)] @?= [m | m <- members accepted, not (isTunnelWebRule m)]
        retire <- expectRight (commitAction webRuleSet (Just policyScope) [])
        case retire of
          CommitRetire revised retired -> do
            filter isTunnelWebRule (members revised) @?= []
            length (members revised) @?= 1
            length retired @?= 3
            [d | m <- members revised, OrderedAfter d <- m ^. #dependencies, d `elem` retired] @?= []
            -- The bootstrap stamp orders after every platform member: the retirement drops its edges to the
            -- retired rules, or its composition leaves them dangling (ep246d's commit-move, 2026-11-19).
            let stampOwner = ok (mkScopeId Platform "bootstrap-stamp")
                stampMember =
                  ManagedResource
                    { identity = mintResourceId stampOwner (ok (mkLogicalKey "bootstrap")) (ok (mkName "version"))
                    , owner = stampOwner
                    , executor = KubernetesExecutor
                    , address = Kubernetes (ok (mkResourceId "platform:cluster/cluster/local")) "" (ok (mkName "configmap")) (Just (ok (mkName "nagare-system"))) (ok (mkName "nagare-platform-version"))
                    , aliases = []
                    , spec = NativeObject (contentDigest "stamp")
                    , lifecycle = Retain
                    , dataPolicy = Stateless
                    , sensitivity = Public
                    , dependencies = [OrderedAfter (m ^. #identity) | m <- members policyScope]
                    , delegations = []
                    , source = SourceLocation "generated:bootstrap" "platform-version"
                    }
                stamp = ok (mkScopeDeclaration stampOwner [ResourceBundle [Managed stampMember] [] [] [] [] []])
                snapshot' = ok (mkScopeSnapshot (ContextBinding (ok (mkContextId "dev")) (ok (mkName "example-project"))) (Map.fromList [(scopeId policyScope, (ok (mkScopeGeneration 1), policyScope)), (stampOwner, (ok (mkScopeGeneration 1), stamp))]) Map.empty)
            assertBool "the retirement alone left the stamp's edges dangling" (isLeft (composeInventory snapshot' (ReplaceScope revised :| [])))
            case stampWithout retired snapshot' of
              Just change -> assertBool "the retirement with the revised stamp does not compose" (isRight (composeInventory snapshot' (ReplaceScope revised :| [change])))
              Nothing -> assertFailure "no stamp revision"
          other -> assertFailure ("expected the retirement: " <> show other)
        case [m | m <- members accepted, isTunnelWebRule m] of
          retained : _ -> commitAction webRuleSet (Just cloudScopeWithout) [retained] @?= Right (CommitCollect (retained ^. #identity))
          [] -> assertFailure "the scope has no web rule"
        commitAction webRuleSet (Just cloudScopeWithout) [] @?= Right CommitProfile
        assertBool "no cloud scope" (isLeft (commitAction webRuleSet Nothing []))
    , testCase "retiring the kept Cloud DNS set deletes records before the zone and only retires the solver's grants (D2)" $ do
        let dnsKeys = cloudDnsSet ^. #keys
            accepted = ok (compileCloudScope (cloudBundle (bucket : map (rule Retain) dnsKeys)))
            inSet m = any (\key -> ("::" <> key) `T.isSuffixOf` urnOf m) dnsKeys
        policy <- expectRight (commitAction cloudDnsSet (Just accepted) [])
        policyScope <- case policy of
          CommitPolicy revised -> pure revised
          other -> assertFailure ("expected the policy review: " <> show other) >> pure accepted
        sort [(keyOf m, m ^. #lifecycle) | m <- members policyScope, inSet m]
          @?= [ (key, if key `elem` cloudDnsSet ^. #collected then DeleteWhenUnreferenced else Retain)
              | key <- sort dnsKeys
              ]
        case commitAction cloudDnsSet (Just policyScope) [] of
          Right (CommitRetire revised retired) -> do
            filter inSet (members revised) @?= []
            length retired @?= 5
          other -> assertFailure ("expected the retirement: " <> show other)
        let retained = filter inSet (members policyScope)
            byKey key = head [m | m <- retained, keyOf m == key]
        commitAction cloudDnsSet (Just cloudScopeWithout) retained @?= Right (CommitCollect (byKey "nagare-wildcard" ^. #identity))
        commitAction cloudDnsSet (Just cloudScopeWithout) (filter ((/= "nagare-wildcard") . keyOf) retained)
          @?= Right (CommitCollect (byKey "nagare-apex" ^. #identity))
        commitAction cloudDnsSet (Just cloudScopeWithout) [byKey "nagare-zone", byKey "nagare-iam-dns-read"]
          @?= Right (CommitCollect (byKey "nagare-zone" ^. #identity))
        commitAction cloudDnsSet (Just cloudScopeWithout) [byKey "nagare-iam-dns-zone", byKey "nagare-iam-dns-read"] @?= Right CommitProfile
    , testCase "a step's review is settled when it only verifies and every scope keeps its accepted digest" $ do
        let scope = ok (mkScopeId Platform "upstream")
            revision generation digest = ScopeRevision (ok (mkScopeGeneration generation)) (contentDigest digest)
            accepted = Map.fromList [(scope, revision 3 "a")]
        reviewSettled [VerifyResource, VerifyResource] (Map.fromList [(scope, revision 4 "a")]) accepted @?= True
        reviewSettled [] Map.empty accepted @?= True
        reviewSettled [VerifyResource] (Map.fromList [(scope, revision 4 "b")]) accepted @?= False
        reviewSettled [UpdateResource] (Map.fromList [(scope, revision 4 "a")]) accepted @?= False
        reviewSettled [VerifyResource] (Map.fromList [(ok (mkScopeId Platform "cloudflare-tunnel"), revision 1 "a")]) accepted @?= False
    , testCase "the move lists every URL it changes and blocks what it cannot carry (D11)" $ do
        let service ns name' = kube "service" (Just ns) name'
            mapping host = kube "domainmapping" (Just "apps") host
            changes =
              hostChanges
                "example.com"
                ( appScope
                    [ service "apps" "site"
                    , service "apps" "wiki"
                    , mapping "wiki.apps.example.com"
                    , mapping "docs.example.com"
                    , mapping "a.b.example.com"
                    , service "nagare-system" "nagare-access"
                    ]
                )
        changes
          @?= [ DefaultRenamed "site.apps.example.com" "site-apps.example.com"
              , ProtectedRenamed "wiki.apps.example.com" "wiki-apps.example.com"
              , NeedsAdvancedCertificate "a.b.example.com"
              ]
        map blocksMove changes @?= [False, True, True]
        hostChanges "example.com" (appScope [service "apps" "site"]) @?= [DefaultRenamed "site.apps.example.com" "site-apps.example.com"]
    , testCase "a redeploy during a base move keeps every route it dropped until retirement, granted or not, without origin TLS (EP-246 D5)" $ do
        let accepted = routeScope [("docs.old.example", True), ("auth.old.example", False)]
            redeployed = routeScope [("docs.new.example", True), ("auth.new.example", False)]
            hostsOf scope = sort [nameText h | b <- scopeBundles scope, RegisterBackend {host = h} <- b ^. #contributions]
            mappingsOf scope = sort [nameText n | m <- members scope, Kubernetes _ _ k _ n <- [m ^. #address], nameText k == "domainmapping"]
            mappingBytes host' = TE.encodeUtf8 ("{\"apiVersion\":\"serving.knative.dev/v1beta1\",\"kind\":\"DomainMapping\",\"metadata\":{\"name\":\"" <> host' <> "\",\"namespace\":\"apps\"},\"spec\":{}}")
            bytesOf scope = Map.fromList [(m ^. #identity, mappingBytes (nameText n)) | m <- members scope, Kubernetes _ _ _ _ n <- [m ^. #address]]
            oldRoutes scope = [m | m <- members scope, m ^. #address `elem` [kube "domainmapping" (Just "apps") h | h <- ["docs.old.example", "auth.old.example"]]]
        routesToCarry "old.example" (Just accepted) redeployed @?= Set.fromList (map (^. #identity) (oldRoutes accepted))
        (carried, native) <- either (assertFailure . T.unpack) pure (carryOldRoutes "old.example" (bytesOf accepted) (Just accepted) redeployed)
        (hostsOf carried, mappingsOf carried)
          @?= (["docs.new.example", "docs.old.example"], ["auth.new.example", "auth.old.example", "docs.new.example", "docs.old.example"])
        -- A carried route is the accepted one with Knative's TLS opt-out: same identity and address, so its grants stay bound.
        optOut <- either (assertFailure . T.unpack) pure (withoutOriginTls (mappingBytes "docs.old.example"))
        assertBool "the opt-out annotation" ("\"networking.knative.dev/disable-external-domain-tls\":\"true\"" `T.isInfixOf` TE.decodeUtf8 optOut)
        withoutOriginTls optOut @?= Right optOut
        map (#spec .~ NativeObject (contentDigest "")) (oldRoutes carried) @?= map (#spec .~ NativeObject (contentDigest "")) (oldRoutes accepted)
        [(m ^. #spec, snd <$> Map.lookup (m ^. #identity) native) | m <- oldRoutes carried, m ^. #address == kube "domainmapping" (Just "apps") "docs.old.example"]
          @?= [(NativeObject (contentDigest optOut), Just optOut)]
        Map.keysSet native @?= routesToCarry "old.example" (Just accepted) redeployed
        assertBool "a carried route needs its accepted bytes" (isLeft (carryOldRoutes "old.example" Map.empty (Just accepted) redeployed))
        -- The old portal's mapping is carried, its portal registration is not: a context has one portal.
        let asPortal scope = ok (mkScopeDeclaration (scopeId scope) [b & #contributions %~ map (\c -> c {role = PortalBackend}) | b <- scopeBundles scope])
            portalAccepted = asPortal (routeScope [("auth.old.example", True)])
        (portal, _) <- either (assertFailure . T.unpack) pure (carryOldRoutes "old.example" (bytesOf portalAccepted) (Just portalAccepted) (asPortal (routeScope [("auth.new.example", True)])))
        (hostsOf portal, mappingsOf portal) @?= (["auth.new.example"], ["auth.new.example", "auth.old.example"])
        carryOldRoutes "old.example" Map.empty Nothing redeployed @?= Right (redeployed, Map.empty)
        carryOldRoutes "old.example" Map.empty (Just redeployed) redeployed @?= Right (redeployed, Map.empty)
        -- Only the other base's routes are carried: a dropped custom domain asks for its retirement.
        let withCustom = routeScope [("docs.old.example", True), ("shop.custom.test", False)]
        routesToCarry "old.example" (Just withCustom) redeployed @?= Set.fromList [m ^. #identity | m <- members withCustom, m ^. #address == kube "domainmapping" (Just "apps") "docs.old.example"]
    , testCase "a rolled-back move's kept zone keeps the redeployed sites carrying its routes (EP-246 D5)" $ do
        let zoneFor served = either (error . show) id (compileCloudflareZone (CloudflareZoneInput (ok (mkName "zone-id")) served "dev" Nothing))
        servesOtherBase "old.example" [routeScope [("docs.old.example", True)], zoneFor "new.example"] @?= True
        servesOtherBase "new.example" [zoneFor "new.example"] @?= False
        servesOtherBase "old.example" [routeScope [("docs.old.example", True)]] @?= False
        -- The base a redeploy carries: during a move the one the profile is not on, after a commit the
        -- retained old base, after a rollback the kept zone's.
        otherBase "new.example" "" (Just ("old.example", "new.example")) [] @?= Just "old.example"
        otherBase "old.example" "" (Just ("old.example", "new.example")) [] @?= Just "new.example"
        otherBase "new.example" "old.example" Nothing [] @?= Just "old.example"
        otherBase "old.example" "" Nothing [zoneFor "new.example"] @?= Just "new.example"
        otherBase "old.example" "" Nothing [zoneFor "old.example"] @?= Nothing
    ]

now :: UTCTime
now = fromMaybe (error "time") (iso8601ParseM "2026-11-16T12:00:00Z")

waiting :: StepOutcome -> IO ()
waiting = \case
  StepWaiting _ -> pure ()
  other -> assertFailure ("expected a wait: " <> show other)

refused :: Text -> StepOutcome -> IO ()
refused fragment = \case
  StepRefused reason -> assertBool (T.unpack (fragment <> " in: " <> reason)) (fragment `T.isInfixOf` reason)
  other -> assertFailure ("expected a refusal: " <> show other)

members :: ScopeDeclaration -> [ManagedResource]
members scope = [m | b <- scopeBundles scope, Managed m <- declarations b]

-- | A cloud scope with the three web rules at @lifecycle@, beside a bucket that must not change.
cloudScopeWith :: LifecyclePolicy -> ScopeDeclaration
cloudScopeWith lifecycle = ok (compileCloudScope (cloudBundle (bucket : map (rule lifecycle) tunnelWebRuleKeys)))

cloudScopeWithout :: ScopeDeclaration
cloudScopeWithout = ok (compileCloudScope (cloudBundle [bucket]))

cloudBundle :: [CloudResource] -> CloudDeclarationBundle
cloudBundle resources =
  CloudDeclarationBundle
    { cloudBundleVersion = 1
    , cloudContext = ok (mkContextId "dev")
    , cloudProject = ok (mkName "example-project")
    , cloudStack = ok (mkName "dev")
    , cloudScope = ok (mkScopeId Platform "cloud")
    , cloudResources = resources
    }

bucket :: CloudResource
bucket =
  (rule Protect "nagare-images")
    { cloudLogicalKey = ok (mkLogicalKey "image-bucket")
    , cloudRole = ok (mkName "bucket")
    , cloudAddress = BucketAddress (ok (mkName "example-project-images"))
    , cloudNativeType = "gcp:storage/bucket:Bucket"
    , cloudNativeUrn = "urn:pulumi:dev::nagare::gcp:storage/bucket:Bucket::nagare-images"
    }

rule :: LifecyclePolicy -> Text -> CloudResource
rule lifecycle key =
  CloudResource
    { cloudLogicalKey = ok (mkLogicalKey key)
    , cloudRole = ok (mkName "firewall")
    , cloudAddress = PulumiAddress urn
    , cloudAliases = []
    , cloudSpecDigest = contentDigest (TE.encodeUtf8 key)
    , cloudLifecycle = lifecycle
    , cloudDataPolicy = Stateless
    , cloudSensitivity = Private
    , cloudDependencies = []
    , cloudSource = SourceLocation "infra/pulumi/src/components/NagareNetwork.ts" key
    , cloudNativeType = "gcp:compute/firewall:Firewall"
    , cloudNativeName = ok (mkName key)
    , cloudNativeUrn = urn
    , cloudRegistrationClass = ManagedRegistration
    }
  where
    urn = "urn:pulumi:dev::nagare::nagare:env:NagarePerimeter$nagare:net:NagareNetwork$gcp:compute/firewall:Firewall::" <> key

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\e -> assertFailure (show e) >> error "unreachable") pure

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

urnOf :: ManagedResource -> Text
urnOf m = case [urn | PulumiUrn urn <- m ^. #address : m ^. #aliases] of
  urn : _ -> urn
  [] -> ""

keyOf :: ManagedResource -> Text
keyOf = snd . T.breakOnEnd "::" . urnOf

-- | An application scope's members holding these Kubernetes objects.
appScope :: [ProviderAddress] -> [ManagedResource]
appScope addresses = zipWith member [0 :: Int ..] addresses
  where
    owner = ok (mkScopeId Application "apps")
    member index address =
      ManagedResource
        { identity = ok (mkResourceId ("application:apps/member-" <> T.pack (show index) <> "/object"))
        , owner = owner
        , executor = KubernetesExecutor
        , address = address
        , aliases = []
        , spec = NativeObject (contentDigest (TE.encodeUtf8 (T.pack (show index))))
        , lifecycle = Retain
        , dataPolicy = Stateless
        , sensitivity = Private
        , dependencies = []
        , delegations = []
        , source = SourceLocation "test" "member"
        }

kube :: Text -> Maybe Text -> Text -> ProviderAddress
kube kind namespace name' = Kubernetes cluster "serving.knative.dev" (ok (mkName kind)) (ok . mkName <$> namespace) (ok (mkName name'))
  where
    cluster = ok (mkResourceId "platform:cluster/cluster/local")

-- | An application scope with one DomainMapping per host and, for a protected host, its backend
-- registration with the auth owner.
routeScope :: [(Text, Bool)] -> ScopeDeclaration
routeScope hosts =
  ok
    ( mkScopeDeclaration
        owner
        [ ResourceBundle
            [Managed (mapping host')]
            []
            []
            [ RegisterBackend
                (ok (mkScopeId Platform "auth"))
                (ok (mkResourceId "platform:cluster/cluster/local"))
                (ok (mkName host'))
                "http://docs.apps.svc.cluster.local"
                ProtectedBackend
                (ok (mkLogicalKey host'))
                Nothing
            | protected
            ]
            []
            []
        | (host', protected) <- hosts
        ]
    )
  where
    owner = ok (mkScopeId Application "apps")
    mapping host' =
      ManagedResource
        { identity = ok (mkResourceId ("application:apps/" <> T.replace "." "-" host' <> "/domainmapping"))
        , owner = owner
        , executor = KubernetesExecutor
        , address = kube "domainmapping" (Just "apps") host'
        , aliases = [Hostname (ok (mkName host'))]
        , spec = NativeObject (contentDigest (TE.encodeUtf8 host'))
        , lifecycle = Retain
        , dataPolicy = Stateless
        , sensitivity = Private
        , dependencies = []
        , delegations = []
        , source = SourceLocation "test" "route"
        }
