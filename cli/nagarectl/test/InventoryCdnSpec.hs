module InventoryCdnSpec (inventoryCdnTests) where

import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Char8 qualified as BC
import Data.Either (isLeft)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Cdn
import Nagare.Inventory.Adapters.CdnRuntime (DnsChangeStatus (..), dnsChangeBody, parseDnsChangeStatus, parseExactDnsListing)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (mkOperationId)
import Nagare.Inventory.Plan (LifecycleDecisionKind (ApproveRetirement), LifecycleProposal (..), lifecycleObservationDigest, loadInventoryHistory, planChanges, validateLifecycleDecisions)
import Nagare.Inventory.Store (ScopeRevision (..), headAccepted, headConverged, headGeneration, initializeStore, newMemoryStore, publishIfAbsent, replaceHeadIfGenerationMatches, scopeKey)
import Nagare.Resource.Cdn (compileGoogleDnsRecord)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Resource.Wire (encodeCanonicalScope)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

inventoryCdnTests :: TestTree
inventoryCdnTests = testGroup "reviewed CDN DNS"
  [ testCase "one app owns its domain and DNS record while another app cannot claim the hostname" $ do
      let (platform, app, members) = fixture
          binding = ContextBinding (ok (mkContextId "labs")) (ok (mkName "project"))
          snapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
          candidate = composeInventory snapshot (ReplaceScope platform :| [ReplaceScope app])
      assertBool "paired domain and DNS must compose" (either (const False) (const True) candidate)
      let foreignOwner = ok (mkScopeId Application "other")
          route = members !! 1
          foreignRoute = route {identity = mintResourceId foreignOwner (ok (mkLogicalKey "www.example.test"))
              (ok (mkName "domain-mapping")), owner = foreignOwner}
          foreignScope = ok (mkScopeDeclaration foreignOwner
            [ResourceBundle [Managed foreignRoute] [] [] [] [] []])
      assertBool "foreign route must not share the DNS hostname"
        (isLeft (composeInventory snapshot (ReplaceScope platform :|
          [ReplaceScope app, ReplaceScope foreignScope])))
  , testCase "reviewed app retirement retains its claimed DNS and domain" $ do
      let (platform, app, members) = fixture
          binding = ContextBinding (ok (mkContextId "labs")) (ok (mkName "project"))
          generation = ok (mkScopeGeneration 1)
          revision scope = ScopeRevision generation (contentDigest (encodeCanonicalScope scope))
      store <- newMemoryStore
      initial <- initializeStore store binding "cdn-retirement" >>= either (fail . show) pure
      mapM_ (\scope -> publishIfAbsent store (scopeKey (revisionDigest (revision scope)))
        (encodeCanonicalScope scope) >>= either (fail . show) pure) [platform, app]
      _ <- replaceHeadIfGenerationMatches store (Just (headGeneration initial))
        (initial {headGeneration = headGeneration initial + 1
          ,headAccepted = Map.fromList [(scopeId platform, revision platform), (scopeId app, revision app)]
          ,headConverged = Map.fromList [(scopeId platform, revision platform), (scopeId app, revision app)]})
        >>= either (fail . show) pure
      history <- loadInventoryHistory store >>= either (fail . show) pure
      let snapshot = ok (mkScopeSnapshot binding
            (Map.fromList [(scopeId platform, (generation, platform)), (scopeId app, (generation, app))])
            Map.empty)
          candidate = ok (composeInventory snapshot (RetireScope (scopeId app) RetainResources :| []))
          resourceFacts = [(resource ^. #identity, ObservedPresent
            (ok (mkPhysicalIdentity ("recorded:" <> resourceIdText (resource ^. #identity)))))
            | resource <- drop 1 members]
          observations = ok (observationSet resourceFacts)
          decisions = [LifecycleProposal resource ApproveRetirement
            (lifecycleObservationDigest binding resource fact)
            | (resource, fact) <- resourceFacts]
      approved <- either (fail . show) pure
        (validateLifecycleDecisions candidate history observations decisions)
      _ <- either (fail . show) pure (planChanges candidate approved history observations)
      pure ()
  , testCase "reviewed DNS create and exact-old update bind private mutations" $ do
      let (_, _, members) = fixture
          dns = members !! 2
          resourceId = dns ^. #identity
          specs = ok (dnsSpecsFromDeclarations (map Managed members))
          operation action = PlannedOperation (ok (mkOperationId "op-dns")) action CdnExecutor
            (resourceId :| []) (contentDigest "dns-review") [] VerifyBeforeRetry
          physical = ok (mkPhysicalIdentity "dns:project/zone/www.example.test")
      state <- newIORef DnsMissing
      let ops = DnsAdapterOps
            { dnsInspect = \_ -> readIORef state
            , dnsCreate = \_ -> writeIORef state (DnsPresent physical "203.0.113.4" 300)
                >> pure AdapterEffectCompleted
            , dnsReplace = \_ -> writeIORef state (DnsPresent physical "203.0.113.5" 300)
                >> pure AdapterEffectCompleted
            }
          adapter = mkDnsAdapter Map.empty specs ops
      prepared <- adapterPrepare adapter (operation CreateResource)
        >>= either (fail . show) pure
      adapterPreflight adapter (operation CreateResource) prepared >>= (@?= Right ())
      adapterRecover adapter (operation CreateResource) prepared
        >>= \case RecoveryUnresolved _ -> pure (); other -> assertFailure (show other)
      adapterExecute adapter (operation CreateResource) prepared
        >>= (@?= AdapterEffectCompleted)
      verified <- adapterVerify adapter (operation CreateResource) prepared
      assertBool "new DNS record verifies" (either (const False) (const True) verified)
      let updated = dns & #spec .~ DnsARecord "203.0.113.5" 300
          updatedSpecs = Map.insert resourceId (DnsBinding updated) specs
          updateAdapter = mkDnsAdapter (Map.singleton resourceId dns) updatedSpecs ops
      updatePrepared <- adapterPrepare updateAdapter (operation UpdateResource)
        >>= either (fail . show) pure
      adapterPreflight updateAdapter (operation UpdateResource) updatePrepared >>= (@?= Right ())
      adapterExecute updateAdapter (operation UpdateResource) updatePrepared
        >>= (@?= AdapterEffectCompleted)
      adapterRecover updateAdapter (operation UpdateResource) updatePrepared
        >>= \case RecoveryUnresolved _ -> pure (); other -> assertFailure (show other)
      let body = dnsChangeBody (DnsMutationPlan (ok (mkOperationId "op-dns")) UpdateResource
            (contentDigest "dns-review") resourceId (ok (mkName "project")) (ok (mkName "zone"))
            (ok (mkName "www.example.test")) "203.0.113.5" 300 (Just ("203.0.113.4", 300)))
      case body of
        Object fields -> case KM.lookup "deletions" fields of
          Just (Array values) -> case toList values of
            [Object old] -> do
              KM.lookup "name" old @?= Just (String "www.example.test.")
              KM.lookup "ttl" old @?= Just (Aeson.toJSON (300 :: Int))
              KM.lookup "rrdatas" old @?= Just (Aeson.toJSON (["203.0.113.4"] :: [Text]))
            _ -> assertFailure "DNS change does not delete exactly one old record"
          _ -> assertFailure "DNS change lacks an exact old-record deletion"
        _ -> assertFailure "DNS change is not an object"
  , testCase "only a successful exact single A listing proves a DNS state" $ do
      let host = ok (mkName "www.example.test")
          (_, app, members) = fixture
      assertBool "compiler accepted a non-IPv4 CDN target"
        (isLeft (compileGoogleDnsRecord (scopeId app)
          (ok (mkLogicalKey "www.example.test")) (ok (mkName "project"))
          (ok (mkName "zone")) host "256.0.0.1"
          (members !! 1 ^. #identity) (members !! 0 ^. #identity)
          (SourceLocation "fixture" "dns")))
      assertBool "inventory accepted a forged non-IPv4 DNS declaration"
        (isLeft (mkScopeDeclaration (scopeId app)
          [ResourceBundle [Managed (members !! 2 & #spec .~ DnsARecord "256.0.0.1" 300)]
            [] [] [] [] []]))
      parseExactDnsListing host "[]" @?= Right Nothing
      parseExactDnsListing host (BC.pack
        "[{\"name\":\"www.example.test.\",\"type\":\"A\",\"ttl\":300,\"rrdatas\":[\"203.0.113.4\"]}]")
        @?= Right (Just ("203.0.113.4", 300))
      assertBool "a different hostname must refuse"
        (isLeft (parseExactDnsListing host (BC.pack
          "[{\"name\":\"other.example.test.\",\"type\":\"A\",\"ttl\":300,\"rrdatas\":[\"203.0.113.4\"]}]")))
      parseDnsChangeStatus "{\"status\":\"done\"}" @?= Right DnsChangeDone
      parseDnsChangeStatus "{\"status\":\"pending\",\"id\":\"42\"}"
        @?= Right (DnsChangePending "42")
      assertBool "a pending change without an exact provider ID must refuse"
        (isLeft (parseDnsChangeStatus "{\"status\":\"pending\",\"id\":\"../other\"}"))
  ]


fixture :: (ScopeDeclaration, ScopeDeclaration, [ManagedResource])
fixture = (platformScope, appScope, [backend, domain, dns])
  where
    platformOwner = ok (mkScopeId Platform "cdn")
    appOwner = ok (mkScopeId Application "demo")
    cluster = mintResourceId platformOwner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
    backendId = mintResourceId platformOwner (ok (mkLogicalKey "backend")) (ok (mkName "backend"))
    domainId = mintResourceId appOwner (ok (mkLogicalKey "www.example.test")) (ok (mkName "domain-mapping"))
    host = ok (mkName "www.example.test")
    source = SourceLocation "fixture" "cdn"
    backend = ManagedResource backendId platformOwner PulumiExecutor
      (PulumiUrn "urn:pulumi:stack::project::gcp:compute/backendService:BackendService::backend")
      [] (NativeObject (contentDigest "backend")) Retain Stateless Private [] [] source
    domain = ManagedResource domainId appOwner KubernetesExecutor
      (ok (kubernetesAddress cluster "serving.knative.dev/v1" "DomainMapping"
        (Just "nagare-system") "www.example.test"))
      [Hostname host] (NativeObject (contentDigest "domain")) Retain Stateless Private [] [] source
    dnsBundle = ok (compileGoogleDnsRecord appOwner (ok (mkLogicalKey "www.example.test"))
      (ok (mkName "project")) (ok (mkName "zone")) host "203.0.113.4"
      domainId backendId source)
    dns = case declarations dnsBundle of
      [Managed resource] -> resource
      _ -> error "DNS fixture has unexpected membership"
    platformScope = ok (mkScopeDeclaration platformOwner
      [ResourceBundle [Managed backend] [] [] [] [] []])
    appScope = ok (mkScopeDeclaration appOwner
      [ResourceBundle [Managed domain] [] [] [] [] [], dnsBundle])

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
