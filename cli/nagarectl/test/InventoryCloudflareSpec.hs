module InventoryCloudflareSpec (inventoryCloudflareTests) where

import Control.Exception (finally)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Foldable (forM_, toList)
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Cdn
import Nagare.Inventory.Adapters.CdnCombined (combineCdnAdapters)
import Nagare.Inventory.Adapters.CdnRuntime (DnsChangeStatus (..), DnsRuntimeConfig (..), dnsChangeBody, dnsRuntimeOps, parseDnsChangeStatus, parseExactDnsListing)
import Nagare.Inventory.Adapters.Cloudflare
import Nagare.Inventory.Adapters.CloudflareRuntime
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Environment (compilePreviewEnvChannel, compileRuntimeSecretChannel)
import Nagare.Inventory.Execute (applyReviewed)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), mkOperationId)
import Nagare.Inventory.Plan (LifecycleDecisionKind (ApproveRetirement), LifecycleProposal (..), historyAccepted, lifecycleObservationDigest, loadInventoryHistory, noLifecycleDecisions, observationRequirements, planChanges, prepareReview, proposalOperations, publishReview, requiredResources, validateLifecycleDecisions, verifyReview)
import Nagare.Inventory.Store (ScopeRevision (..), headAccepted, headConverged, headGeneration, initializeStore, newMemoryStore, publishIfAbsent, readStoreSnapshot, replaceHeadIfGenerationMatches, scopeKey)
import Nagare.Resource.Cdn (compileCdnDisable, compileCdnPurge, compileCloudflareDnsRecord, compileGoogleDnsRecord)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (encodeCanonicalScope)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

inventoryCloudflareTests :: TestTree
inventoryCloudflareTests =
  testGroup
    "reviewed Cloudflare"
    [ testCase "Cloudflare HTTP binding, exact record write, and stale version refusal stay offline" $ do
        let zone = ok (mkName "0123456789abcdef0123456789abcdef")
            host = ok (mkName "a.example.test")
            owner = ok (mkScopeId Application "cloudflare-runtime")
            resource =
              ManagedResource
                (mintResourceId owner (ok (mkLogicalKey "dns")) (ok (mkName "record")))
                owner
                CdnExecutor
                (CloudflareDnsRecord zone host)
                [Hostname host]
                (CloudflareProxiedARecord "203.0.113.4")
                Retain
                Stateless
                Private
                []
                []
                (SourceLocation "fixture" "cloudflare-http")
            resourceId = resource ^. #identity
            zonePath = "/zones/" <> nameText zone
            physical = ok (mkPhysicalIdentity ("cloudflare:zone/" <> nameText zone <> "/dns/record1"))
            target address = CloudflareDnsTarget host address True 1
            mutation action address previous boundPhysical version =
              CloudflareMutationPlan
                (ok (mkOperationId "op-cf-http"))
                action
                (contentDigest "cf-http-review")
                resourceId
                zone
                (target address)
                previous
                boundPhysical
                version
            envelope result = LBS.toStrict (Aeson.encode (object ["success" .= True, "result" .= result]))
        recordState <- newIORef (Nothing :: Maybe (Text, Text))
        writes <- newIORef ([] :: [(Text, Text)])
        let request method path body
              | method == "GET" && path == zonePath =
                  pure
                    ( Right
                        ( 200
                        , envelope
                            (object ["id" .= nameText zone, "account" .= object ["id" .= ("account-1" :: Text)]])
                        )
                    )
              | method == "GET" && path == zonePath <> "/dns_records?type=A&name.exact=a.example.test&per_page=2" = do
                  current <- readIORef recordState
                  let records = case current of
                        Nothing -> [] :: [Value]
                        Just (address, version) ->
                          [ object
                              [ "id" .= ("record1" :: Text)
                              , "type" .= ("A" :: Text)
                              , "name" .= ("a.example.test" :: Text)
                              , "content" .= address
                              , "proxied" .= True
                              , "ttl" .= (1 :: Int)
                              , "modified_on" .= version
                              ]
                          ]
                  pure
                    ( Right
                        ( 200
                        , LBS.toStrict
                            ( Aeson.encode
                                ( object
                                    [ "success" .= True
                                    , "result" .= records
                                    , "result_info" .= object ["count" .= length records, "page" .= (1 :: Int)]
                                    ]
                                )
                            )
                        )
                    )
              | method == "POST"
                  && path == zonePath <> "/dns_records"
                  && body
                    == Just
                      ( object
                          [ "type" .= ("A" :: Text)
                          , "name" .= nameText host
                          , "content" .= ("203.0.113.4" :: Text)
                          , "proxied" .= True
                          , "ttl" .= (1 :: Int)
                          ]
                      ) = do
                  writeIORef recordState (Just ("203.0.113.4", "v1"))
                  modifyIORef' writes (<> [(method, path)])
                  pure (Right (200, envelope (object ["id" .= ("record1" :: Text)])))
              | method == "PUT"
                  && path == zonePath <> "/dns_records/record1"
                  && body
                    == Just
                      ( object
                          [ "type" .= ("A" :: Text)
                          , "name" .= nameText host
                          , "content" .= ("203.0.113.5" :: Text)
                          , "proxied" .= True
                          , "ttl" .= (1 :: Int)
                          ]
                      ) = do
                  writeIORef recordState (Just ("203.0.113.5", "v2"))
                  modifyIORef' writes (<> [(method, path)])
                  pure (Right (200, envelope (object ["id" .= ("record1" :: Text)])))
              | otherwise = pure (Left "unexpected Cloudflare request")
            config =
              CloudflareRuntimeConfig
                zone
                "account-1"
                (\_ -> pure (Right ()))
                (Map.singleton resourceId (CloudflareBinding resource))
                request
            ops = cloudflareRuntimeOps config
        cloudflareInspect ops resourceId >>= (@?= CloudflareMissing)
        cloudflareCreate ops (mutation CreateResource "203.0.113.4" Nothing Nothing Nothing)
          >>= (@?= AdapterEffectCompleted)
        cloudflareInspect ops resourceId >>= (@?= CloudflarePresent physical (Just "v1") (target "203.0.113.4"))
        let update =
              mutation
                UpdateResource
                "203.0.113.5"
                (Just (target "203.0.113.4"))
                (Just physical)
                (Just "v1")
        cloudflareReplace ops update >>= (@?= AdapterEffectCompleted)
        cloudflareInspect ops resourceId >>= (@?= CloudflarePresent physical (Just "v2") (target "203.0.113.5"))
        cloudflareReplace ops update >>= \case
          AdapterEffectFailed _ -> pure ()
          other -> assertFailure ("stale Cloudflare version caused a write: " <> show other)
        readIORef writes
          >>= ( @?=
                  [ ("POST", zonePath <> "/dns_records")
                  , ("PUT", zonePath <> "/dns_records/record1")
                  ]
              )
        let wrongAccount = cloudflareRuntimeOps (config {cloudflareRuntimeAccount = "account-2"})
        cloudflareInspect wrongAccount resourceId >>= \case
          CloudflareUnavailable _ -> pure ()
          other -> assertFailure ("foreign Cloudflare account was accepted: " <> show other)
        assertBool
          "zone binding accepted another account"
          ( isLeft
              ( parseCloudflareZone
                  zone
                  "account-2"
                  ( 200
                  , envelope
                      (object ["id" .= nameText zone, "account" .= object ["id" .= ("account-1" :: Text)]])
                  )
              )
          )
    , testCase "Cloudflare ruleset observation preserves full behavior and rejects unknown rules" $ do
        let zone = ok (mkName "0123456789abcdef0123456789abcdef")
            owner = ok (mkScopeId Platform "cloudflare")
            resource =
              ManagedResource
                (cloudflareRulesResourceId owner zone)
                owner
                CdnExecutor
                (CloudflareRuleset zone)
                []
                (CloudflareRulesSpec [])
                Retain
                Stateless
                Private
                []
                []
                (SourceLocation "fixture" "rules")
            rule =
              object
                [ "action" .= ("set_cache_settings" :: Text)
                , "expression" .= ("(http.host eq \"a.example.test\")" :: Text)
                , "action_parameters" .= object ["cache" .= False]
                ]
            wrapped rules =
              ( 200
              , LBS.toStrict
                  ( Aeson.encode
                      ( object
                          [ "success" .= True
                          , "result"
                              .= object
                                [ "id" .= ("ruleset-1" :: Text)
                                , "kind" .= ("zone" :: Text)
                                , "phase" .= ("http_request_cache_settings" :: Text)
                                , "version" .= ("7" :: Text)
                                , "rules" .= rules
                                ]
                          ]
                      )
                  )
              )
            providerRule =
              object
                [ "id" .= ("rule-1" :: Text)
                , "version" .= ("2" :: Text)
                , "enabled" .= True
                , "action" .= ("set_cache_settings" :: Text)
                , "expression" .= ("(http.host eq \"a.example.test\")" :: Text)
                , "action_parameters" .= object ["cache" .= False]
                ]
        case parseCloudflareResource resource (wrapped [providerRule]) of
          Right (CloudflarePresent _ (Just "7") (CloudflareRulesTarget normalized)) ->
            normalized @?= object ["rules" .= [rule]]
          other -> assertFailure ("ruleset did not normalize exactly: " <> show other)
        assertBool
          "unknown rule behavior was discarded"
          ( isLeft
              ( parseCloudflareResource
                  resource
                  ( wrapped
                      [ case providerRule of
                          Object fields -> Object (KM.insert "logging" (Bool True) fields)
                          other -> other
                      ]
                  )
              )
          )
    , testCase "offline Cloudflare owner review binds complete rules and independent host records" $ do
        let zone = ok (mkName "0123456789abcdef0123456789abcdef")
            platformOwner = ok (mkScopeId Platform "cloudflare")
            appA = ok (mkScopeId Application "site-a")
            appB = ok (mkScopeId Application "site-b")
            source = SourceLocation "fixture" "cloudflare"
            cluster = mintResourceId platformOwner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            rulesId = cloudflareRulesResourceId platformOwner zone
            tlsId = cloudflareTlsResourceId platformOwner zone
            platformScope =
              ok
                ( mkScopeDeclaration
                    platformOwner
                    [ResourceBundle [] [] [] [] [] [CloudflareZoneGrant zone CloudflareFlexible]]
                )
            hostScope owner hostname ttl =
              let host = ok (mkName hostname)
                  routeId = mintResourceId owner (ok (mkLogicalKey hostname)) (ok (mkName "domain-mapping"))
                  route =
                    ManagedResource
                      routeId
                      owner
                      KubernetesExecutor
                      ( ok
                          ( kubernetesAddress
                              cluster
                              "serving.knative.dev/v1"
                              "DomainMapping"
                              (Just "personal")
                              hostname
                          )
                      )
                      [Hostname host]
                      (NativeObject (contentDigest "route"))
                      Retain
                      Stateless
                      Private
                      []
                      []
                      source
                  intent = CloudflareCacheIntent host (Just ttl) False [("/api/", Nothing)]
                  dns =
                    ok
                      ( compileCloudflareDnsRecord
                          owner
                          (ok (mkLogicalKey hostname))
                          zone
                          host
                          "203.0.113.4"
                          routeId
                          rulesId
                          source
                      )
               in ok
                    ( mkScopeDeclaration
                        owner
                        [ ResourceBundle
                            [Managed route]
                            []
                            []
                            [RegisterCloudflareCache platformOwner zone intent routeId]
                            []
                            []
                        , dns
                        ]
                    )
            firstScope = hostScope appA "a.example.test" 300
            secondScope = hostScope appB "b.example.test" 600
            binding = ContextBinding (ok (mkContextId "labs")) (ok (mkName "project"))
            emptySnapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
            oldInventory =
              candidateInventory
                ( ok
                    ( composeInventory
                        emptySnapshot
                        (ReplaceScope platformScope :| [ReplaceScope firstScope, ReplaceScope secondScope])
                    )
                )
            oldDeclarations = inventoryDeclarations oldInventory
            oldResources =
              Map.fromList
                [ (member ^. #identity, member)
                | Managed member <- oldDeclarations
                , member ^. #executor == CdnExecutor
                ]
            oldBindings = ok (cloudflareBindingsFromDeclarations oldDeclarations)
            generation = ok (mkScopeGeneration 1)
            acceptedSnapshot =
              ok
                ( mkScopeSnapshot
                    binding
                    ( Map.fromList
                        [ (platformOwner, (generation, platformScope))
                        , (appA, (generation, firstScope))
                        , (appB, (generation, secondScope))
                        ]
                    )
                    Map.empty
                )
            changedScope = hostScope appA "a.example.test" 900
            newInventory =
              candidateInventory
                ( ok
                    ( composeInventory
                        acceptedSnapshot
                        (ReplaceScope changedScope :| [])
                    )
                )
            newBindings = ok (cloudflareBindingsFromDeclarations (inventoryDeclarations newInventory))
            operation name action resource =
              PlannedOperation
                (ok (mkOperationId name))
                action
                CdnExecutor
                (resource :| [])
                (contentDigest "cloudflare-review")
                []
                VerifyBeforeRetry
            physical resource = ok (mkPhysicalIdentity ("cloudflare:" <> resourceIdText resource))
        let purged = ok (compileCdnPurge acceptedSnapshot "a.example.test" "release-1" ["/b", "/a", "/b"])
            purgeCandidate = ok (composeInventory acceptedSnapshot (ReplaceScope purged :| []))
            purgeInventory = candidateInventory purgeCandidate
            purgeSnapshot =
              ok
                ( mkScopeSnapshot
                    binding
                    (Map.insert appA (generation, purged) (snapshotScopes acceptedSnapshot))
                    Map.empty
                )
        scopeConfigDigest purged @?= scopeConfigDigest firstScope
        scopeOverrides purged @?= scopeOverrides firstScope
        Map.lookup appB (inventoryScopes purgeInventory) @?= Just secondScope
        Map.lookup platformOwner (inventoryScopes purgeInventory) @?= Just platformScope
        inventoryDeclarations purgeInventory @?= inventoryDeclarations oldInventory
        compileCdnPurge purgeSnapshot "a.example.test" "release-1" ["/a", "/b"] @?= Right purged
        assertBool "changed purge ID intent must refuse" (isLeft (compileCdnPurge purgeSnapshot "a.example.test" "release-1" []))
        assertBool "foreign host must refuse purge" (isLeft (compileCdnPurge acceptedSnapshot "foreign.example.test" "release-1" []))
        assertBool "URL must not escape host through path input" (isLeft (compileCdnPurge acceptedSnapshot "a.example.test" "release-1" ["https://foreign.test/"]))
        let disabled = ok (compileCdnDisable acceptedSnapshot "a.example.test" "203.0.113.4")
            disabledCandidate = ok (composeInventory acceptedSnapshot (ReplaceScope disabled :| []))
            disabledInventory = candidateInventory disabledCandidate
            disabledDeclarations = inventoryDeclarations disabledInventory
            disabledBindings = ok (cloudflareBindingsFromDeclarations disabledDeclarations)
        Map.lookup appB (inventoryScopes disabledInventory) @?= Just secondScope
        Map.lookup platformOwner (inventoryScopes disabledInventory) @?= Just platformScope
        [map cacheHost intents | Managed member <- disabledDeclarations, CloudflareRulesSpec intents <- [member ^. #spec]]
          @?= [[ok (mkName "b.example.test")]]
        [member ^. #spec | Managed member <- disabledDeclarations, member ^. #owner == appA, CloudflareDnsRecord {} <- [member ^. #address]]
          @?= [CloudflareDnsOnlyARecord "203.0.113.4"]
        Map.size disabledBindings @?= 4
        assertBool "changed origin must refuse" (isLeft (compileCdnDisable acceptedSnapshot "a.example.test" "203.0.113.9"))
        Map.size oldBindings @?= 4
        historyStore <- newMemoryStore
        initialHead <-
          initializeStore historyStore binding "cloudflare-isolation"
            >>= either (fail . show) pure
        let revision scope = ScopeRevision generation (contentDigest (encodeCanonicalScope scope))
            acceptedScopes = [platformScope, firstScope, secondScope]
        forM_ acceptedScopes $ \scope ->
          publishIfAbsent
            historyStore
            (scopeKey (revisionDigest (revision scope)))
            (encodeCanonicalScope scope)
            >>= either (fail . show) pure
        _ <-
          replaceHeadIfGenerationMatches
            historyStore
            (Just (headGeneration initialHead))
            ( initialHead
                { headGeneration = headGeneration initialHead + 1
                , headAccepted = Map.fromList [(scopeId scope, revision scope) | scope <- acceptedScopes]
                , headConverged = Map.fromList [(scopeId scope, revision scope) | scope <- acceptedScopes]
                }
            )
            >>= either (fail . show) pure
        history <- loadInventoryHistory historyStore >>= either (fail . show) pure
        let changedCandidate = ok (composeInventory acceptedSnapshot (ReplaceScope changedScope :| []))
            selected = requiredResources (observationRequirements changedCandidate history)
            unrelated =
              [ member ^. #identity
              | Managed member <- oldDeclarations
              , member ^. #owner == appB
              ]
        assertBool "app A cache update did not select its shared ruleset" (Set.member rulesId selected)
        assertBool
          "app A cache update selected app B or unchanged platform TLS"
          (all (`Set.notMember` selected) (tlsId : unrelated))
        assertBool
          "orphan DNS cannot enter the Cloudflare adapter"
          ( isLeft
              ( cloudflareBindingsFromDeclarations
                  [ declaration
                  | declaration@(Managed member) <- oldDeclarations
                  , CloudflareDnsRecord _ _ <- [member ^. #address]
                  ]
              )
          )
        state <- newIORef Map.empty
        writes <- newIORef ([] :: [ResourceId])
        let inspect resource = Map.findWithDefault CloudflareMissing resource <$> readIORef state
            write plan = do
              let resource = cloudflarePlanResource plan
              modifyIORef'
                state
                ( Map.insert
                    resource
                    (CloudflarePresent (physical resource) (Just "1") (cloudflarePlanTarget plan))
                )
              modifyIORef' writes (<> [resource])
              pure AdapterEffectCompleted
            ops = CloudflareAdapterOps inspect write write (\_ -> fail "unexpected deletion")
            initial = mkCloudflareAdapter Map.empty oldBindings ops
        forM_ (zip [0 :: Int ..] (Map.keys oldBindings)) $ \(position, resource) -> do
          let create = operation ("op-create-" <> T.pack (show position)) CreateResource resource
          prepared <- adapterPrepare initial create >>= either (fail . show) pure
          adapterPreflight initial create prepared >>= (@?= Right ())
          adapterExecute initial create prepared >>= (@?= AdapterEffectCompleted)
          result <- adapterVerify initial create prepared
          assertBool "Cloudflare create did not verify" (either (const False) (const True) result)
          adapterRecover initial create prepared >>= \case
            RecoveryUnresolved _ -> pure ()
            other -> assertFailure ("Cloudflare create was recovered without a provider receipt: " <> show other)
        let adoptTls = operation "op-adopt-tls" AdoptResource tlsId
        observed <- adapterObserve initial [tlsId] >>= either (fail . T.unpack) pure
        Map.lookup tlsId (observationMap observed) @?= Just (ObservedUnowned (physical tlsId))
        unownedVerify <- adapterPrepare initial (operation "op-verify-unowned" VerifyResource tlsId)
        assertBool "verification must not adopt an unowned setting" (isLeft unownedVerify)
        adoption <- adapterPrepare initial adoptTls >>= either (fail . show) pure
        adapterPreflight initial adoptTls adoption >>= (@?= Right ())
        adapterExecute initial adoptTls adoption >>= (@?= AdapterEffectCompleted)
        adoptionProof <- adapterVerify initial adoptTls adoption
        assertBool "matching TLS setting could not be adopted" (either (const False) (const True) adoptionProof)
        adapterRecover initial adoptTls adoption >>= \case
          RecoveryProvedComplete _ -> pure ()
          other -> assertFailure ("read-only Cloudflare adoption did not recover: " <> show other)
        firstDns <- case [ resource
                         | (resource, member) <- Map.toAscList oldResources
                         , CloudflareDnsRecord _ host <- [member ^. #address]
                         , host == ok (mkName "a.example.test")
                         ] of
          [resource] -> pure resource
          other ->
            assertFailure ("expected one Cloudflare A record: " <> show other)
              >> fail "missing A record"
        disabledState <- readIORef state >>= newIORef
        disabledWrites <- newIORef ([] :: [ResourceId])
        let disableWrite plan = do
              modifyIORef'
                disabledState
                ( Map.insert
                    (cloudflarePlanResource plan)
                    (CloudflarePresent (physical (cloudflarePlanResource plan)) (Just "2") (cloudflarePlanTarget plan))
                )
              modifyIORef' disabledWrites (<> [cloudflarePlanResource plan])
              pure AdapterEffectCompleted
            disableOps =
              CloudflareAdapterOps
                (\resource -> Map.findWithDefault CloudflareMissing resource <$> readIORef disabledState)
                disableWrite
                disableWrite
                (\_ -> fail "unexpected deletion")
            disableAdapter = mkCloudflareAdapter oldResources disabledBindings disableOps
        forM_ [rulesId, firstDns] $ \resource -> do
          let change = operation "op-disable-host" UpdateResource resource
          preparedDisable <- adapterPrepare disableAdapter change >>= either (fail . show) pure
          adapterExecute disableAdapter change preparedDisable >>= (@?= AdapterEffectCompleted)
          verifiedDisable <- adapterVerify disableAdapter change preparedDisable
          assertBool "disabled host must verify its exact DNS/rules target" (not (isLeft verifiedDisable))
          adapterRecover disableAdapter change preparedDisable >>= \case
            RecoveryUnresolved _ -> pure ()
            other -> assertFailure ("lost response must not replay disable: " <> show other)
        readIORef disabledWrites >>= (@?= [rulesId, firstDns])
        beforeDisable <- readIORef state
        afterDisable <- readIORef disabledState
        Map.delete rulesId (Map.delete firstDns afterDisable)
          @?= Map.delete rulesId (Map.delete firstDns beforeDisable)
        let adoptDns = operation "op-adopt-dns" AdoptResource firstDns
        modifyIORef'
          state
          ( Map.adjust
              ( \case
                  CloudflarePresent physicalId version (CloudflareDnsTarget host address _ ttl) ->
                    CloudflarePresent physicalId version (CloudflareDnsTarget host address False ttl)
                  other -> other
              )
              firstDns
          )
        rejected <- adapterPrepare initial adoptDns
        assertBool "unproxied A record must not be adopted as a proxied record" (isLeft rejected)
        modifyIORef'
          state
          ( Map.adjust
              ( \case
                  CloudflarePresent physicalId version (CloudflareDnsTarget host address _ ttl) ->
                    CloudflarePresent physicalId version (CloudflareDnsTarget host address True ttl)
                  other -> other
              )
              firstDns
          )
        let changed = mkCloudflareAdapter oldResources newBindings ops
            update = operation "op-update-rules" UpdateResource rulesId
        cdnFacts <- adapterObserve changed [rulesId, firstDns] >>= either (fail . T.unpack) pure
        routeId <- case [ member ^. #identity
                        | Managed member <- oldDeclarations
                        , member ^. #owner == appA
                        , Kubernetes _ "serving.knative.dev" kind _ _ <- [member ^. #address]
                        , nameText kind == "domainmapping"
                        ] of
          [resource] -> pure resource
          other -> assertFailure ("expected one app A route: " <> show other) >> fail "missing route"
        facts <-
          either
            (fail . T.unpack)
            pure
            ( observationSet
                ( Map.toList (observationMap cdnFacts)
                    <> [(routeId, ObservedPresent (physical routeId))]
                )
            )
        proposal <-
          either
            (fail . show)
            pure
            ( planChanges
                changedCandidate
                noLifecycleDecisions
                history
                facts
            )
        assertBool
          "app A cache update did not plan one complete ruleset change"
          ( any
              ( \planned ->
                  plannedAction planned == UpdateResource
                    && rulesId `elem` NE.toList (plannedResources planned)
              )
              (proposalOperations proposal)
          )
        assertBool
          "app A cache update planned an app B mutation"
          ( all
              (all (`notElem` unrelated) . NE.toList . plannedResources)
              (proposalOperations proposal)
          )
        prepared <- adapterPrepare changed update >>= either (fail . show) pure
        modifyIORef'
          state
          ( Map.adjust
              ( \case
                  CloudflarePresent _ version target -> CloudflarePresent (ok (mkPhysicalIdentity "cloudflare:foreign")) version target
                  other -> other
              )
              rulesId
          )
        assertBool "ruleset version or ID change must refuse" . isLeft
          =<< adapterPreflight changed update prepared
        modifyIORef'
          state
          ( Map.adjust
              ( \case
                  CloudflarePresent _ version target -> CloudflarePresent (physical rulesId) version target
                  other -> other
              )
              rulesId
          )
        adapterPreflight changed update prepared >>= (@?= Right ())
        let kubeAdapter =
              Adapter
                { adapterExecutor = KubernetesExecutor
                , adapterIdentity = "recording-cloudflare-route"
                , adapterVersion = "1"
                , adapterObserve = \resources ->
                    pure
                      ( observationSet
                          [(resource, ObservedPresent (physical resource)) | resource <- resources]
                      )
                , adapterPrepare = \_ -> pure (Right (PreparedNative "recorded-route" "verify existing route"))
                , adapterPreflight = \_ _ -> pure (Right ())
                , adapterExecute = \_ _ -> pure AdapterEffectCompleted
                , adapterVerify = \_ _ -> pure (Right (contentDigest "recorded-route"))
                , adapterRecover = \_ _ -> pure (RecoveryProvedComplete (contentDigest "recorded-route"))
                }
            registry = ok (mkAdapterRegistry [kubeAdapter, changed])
        reviewBase <- readStoreSnapshot historyStore >>= either (fail . show) pure
        preparedReview <- prepareReview registry reviewBase proposal >>= either (fail . show) pure
        _ <- publishReview historyStore preparedReview >>= either (fail . show) pure
        published <- readStoreSnapshot historyStore >>= either (fail . show) pure
        admitted <- either (fail . show) pure (verifyReview published preparedReview)
        _ <- applyReviewed historyStore registry admitted >>= either (fail . show) pure
        result <- adapterVerify changed update prepared
        assertBool "complete ruleset update did not verify" (either (const False) (const True) result)
        let initialWrites = Map.keys oldBindings
        actualWrites <- readIORef writes
        actualWrites @?= initialWrites <> [rulesId]
        acceptedAfter <- loadInventoryHistory historyStore >>= either (fail . show) pure
        fmap (revisionGeneration . fst) (Map.lookup platformOwner (historyAccepted acceptedAfter))
          @?= Just generation
        fmap (revisionGeneration . fst) (Map.lookup appB (historyAccepted acceptedAfter))
          @?= Just generation
        fmap (revisionGeneration . fst) (Map.lookup appA (historyAccepted acceptedAfter))
          @?= Just (ok (mkScopeGeneration 2))
        adapterRecover changed update prepared >>= \case
          RecoveryUnresolved _ -> pure ()
          other -> assertFailure ("Cloudflare update was recovered without a provider receipt: " <> show other)
        let strictPlatform =
              ok
                ( mkScopeDeclaration
                    platformOwner
                    [ResourceBundle [] [] [] [] [] [CloudflareZoneGrant zone CloudflareFullStrict]]
                )
            strictInventory =
              candidateInventory
                ( ok
                    ( composeInventory
                        acceptedSnapshot
                        (ReplaceScope strictPlatform :| [])
                    )
                )
            strictBindings =
              ok
                ( cloudflareBindingsFromDeclarations
                    (inventoryDeclarations strictInventory)
                )
            tlsAdapter = mkCloudflareAdapter oldResources strictBindings ops
            tlsUpdate = operation "op-update-tls" UpdateResource tlsId
        tlsPrepared <- adapterPrepare tlsAdapter tlsUpdate >>= either (fail . show) pure
        adapterPreflight tlsAdapter tlsUpdate tlsPrepared >>= (@?= Right ())
        adapterExecute tlsAdapter tlsUpdate tlsPrepared >>= (@?= AdapterEffectCompleted)
        tlsResult <- adapterVerify tlsAdapter tlsUpdate tlsPrepared
        assertBool "origin TLS update did not verify" (either (const False) (const True) tlsResult)
        finalWrites <- readIORef writes
        finalWrites @?= initialWrites <> [rulesId, tlsId]
    ]

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
