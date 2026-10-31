-- | The admin API over a recorded store (EP-197 M2): read costs, the
-- representation cache, conditional requests, Relay walks, problems, the
-- request deadline and admission.
module Nagare.Api.Server.Test.Serve
  ( serveTests
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, wait)
import Control.Monad (join)
import Data.Aeson (FromJSON, Value (..), eitherDecode, encode)
import Data.Aeson.Key qualified
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (diffUTCTime, getCurrentTime)
import Nagare.Api.Inventory.Routes qualified as Inventory
import Nagare.Api.Page (PageSize (..))
import Nagare.Api.Response
import Nagare.Api.Routes qualified as Root
import Nagare.Api.Server.App (AppConfig (..), adminApplication)
import Nagare.Api.Server.Serve (Env (..), newEnv)
import Nagare.Api.Server.Test.Fixture
import Nagare.Api.Sites.Routes qualified as Sites
import Nagare.Contract.Prelude
import Nagare.Contract.Problem (ProblemDetails (..))
import Nagare.Contract.Schema (Nullable (..))
import Nagare.Contract.V1
import Nagare.Contract.Versions
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Recorded (defaultRecordedReaderConfig, newRecordedReader)
import Nagare.Inventory.Store (initializeStore, openFilesystemStore, readHead, readObject, scopeKey)
import Nagare.Platform.Versions (VersionSnapshot (..), recordedFact)
import Nagare.Platform.Versions.Assemble (AcceptedMember (..), ProviderFailure (..))
import Nagare.Platform.Versions.Collect (CollectSettings (..), VersionProviders (..), collectVersions)
import Nagare.Platform.Versions.Store (publishVersionSnapshot, versionSnapshotKey)
import Nagare.Platform.Versions.Store qualified as VersionStore
import Nagare.Resource.Inventory (scopeId)
import Nagare.Resource.Types (scopeIdText)
import Nagare.Resource.Wire (encodeCanonicalScope)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (Header, HeaderName, Method, statusCode)
import Network.Wai.Handler.Warp (testWithApplication)
import Relay.Pagination (Connection (..), Direction (..), Edge (..), PageRequest (..), cursorToText)
import Relay.Pagination.Conformance (ConformanceConfig (..), checkConformance, conformancePassed, renderConformanceReport)
import Servant.Client (ClientM, mkClientEnv, parseBaseUrl, runClientM)
import Servant.Client.Generic (AsClientT, genericClient)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

serveTests :: TestTree
serveTests = testGroup "wire" [recordedTests, versionTests]

-- | @/v1/platform/versions@ (EP-236): the snapshot beside the serving build,
-- partial results with reasons, and the shared validators.
versionTests :: TestTree
versionTests =
  testGroup
    "platform versions (EP-236)"
    [ testCase "an older serving build beside a newer installed release is different, and no store object is read" $ withServer 2 defaults $ \server -> do
        offer server (pure (Right (Just (snapshotBytes sampleSnapshot))))
        _ <- readsSince server
        response <- request server "GET" "/v1/platform/versions" []
        statusOf response @?= 200
        readsSince server >>= (@?= 0)
        versions <- decodeBody @PlatformVersions response
        versions ^. #nagare . #comparison . #state @?= ComparisonDifferent
        versions ^. #nagare . #comparison . #installedVersion @?= Nullable (Just "0.13.0")
        versions ^. #nagare . #comparison . #servingVersion @?= Nullable (Just "0.0.0")
        fmap (^. #version) (fromNullable' (versions ^. #nagare . #servingBuild)) @?= Just "0.0.0"
        (versions ^. #snapshot . #available, versions ^. #snapshot . #completedAt) @?= (True, Nullable (Just "2026-10-31T16:00:09Z"))
        (versions ^. #context, versions ^. #project) @?= ("fixture", "project")
        header "Cache-Control" response @?= Just "private, no-cache"
        header "Nagare-Head-Revision" response @?= Nothing
    , testCase "an equal version and revision match; an equal version without serving revision is unknown" $ do
        withServer 2 defaults {servingRevision = Just "0123456789ab"} $ \server -> do
          offer server (pure (Right (Just (snapshotBytes (installedAs "0.0.0")))))
          versions <- request server "GET" "/v1/platform/versions" [] >>= decodeBody @PlatformVersions
          versions ^. #nagare . #comparison . #state @?= ComparisonMatch
        withServer 2 defaults $ \server -> do
          offer server (pure (Right (Just (snapshotBytes (installedAs "0.0.0")))))
          versions <- request server "GET" "/v1/platform/versions" [] >>= decodeBody @PlatformVersions
          versions ^. #nagare . #comparison . #state @?= ComparisonUnknown
    , testCase "a legacy stamp's payload ID is null with not_recorded while the rest is served" $ withServer 2 defaults $ \server -> do
        offer server (pure (Right (Just (snapshotBytes sampleSnapshot))))
        versions <- request server "GET" "/v1/platform/versions" [] >>= decodeBody @PlatformVersions
        installedRelease <- maybe (assertFailure "no installed release" >> fail "installed") pure (fromNullable' (versions ^. #nagare . #installed))
        (installedRelease ^. #payloadId . #value, installedRelease ^. #payloadId . #reason) @?= (Nullable Nothing, Nullable (Just "not_recorded"))
        installedRelease ^. #installedAt . #value @?= Nullable (Just "2026-10-30T09:00:00Z")
        installedRelease ^. #version . #sourceKind @?= SourceRecorded
    , testCase "a mixed rollout keeps both digests in order" $ withServer 2 defaults $ \server -> do
        offer server (pure (Right (Just (snapshotBytes sampleSnapshot))))
        versions <- request server "GET" "/v1/platform/versions" [] >>= decodeBody @PlatformVersions
        [ container ^. #imageDigest . #value
          | component <- versions ^. #components
          , workload <- component ^. #workloads
          , container <- workload ^. #containers
          ]
          @?= [Nullable (Just "sha256:old"), Nullable (Just "sha256:new")]
        map (^. #declaredVersion . #value) (versions ^. #databases) @?= [Nullable (Just "18")]
    , testCase "a missing, corrupt, oversized, foreign or unreadable snapshot is a 200 with its reason and the serving build" $ withServer 2 defaults $ \server -> do
        let foreignBytes = snapshotBytes sampleSnapshot {context = "elsewhere"}
            oversized = BC.replicate 1048577 ' '
        for_'
          [ (pure (Right Nothing), "snapshot_missing")
          , (pure (Right (Just "{not json")), "snapshot_invalid")
          , (pure (Right (Just (snapshotBytes sampleSnapshot {snapshotSchema = 2}))), "snapshot_invalid")
          , (pure (Right (Just oversized)), "snapshot_oversized")
          , (pure (Right (Just foreignBytes)), "snapshot_foreign")
          , (pure (Left "gcs: 403 secret-token-sentinel"), "snapshot_unavailable")
          ]
          $ \(answer, expected) -> do
            offer server answer
            response <- request server "GET" "/v1/platform/versions" []
            statusOf response @?= 200
            assertBool "a store error leaked into the document" (not (BC.isInfixOf "sentinel" (LBS.toStrict (bodyOf response))))
            versions <- decodeBody @PlatformVersions response
            (versions ^. #snapshot . #available, versions ^. #snapshot . #reason) @?= (False, Nullable (Just expected))
            (versions ^. #hosts, versions ^. #hostsReason) @?= ([], Nullable (Just expected))
            (versions ^. #components, versions ^. #databases) @?= ([], [])
            versions ^. #nagare . #comparison . #state @?= ComparisonUnknown
            assertBool "the serving build is missing" (isJust (fromNullable' (versions ^. #nagare . #servingBuild)))
    , testCase "a matching If-None-Match answers 304; HEAD has no body; a new snapshot changes the ETag" $ withServer 2 defaults $ \server -> do
        offer server (pure (Right (Just (snapshotBytes sampleSnapshot))))
        fresh <- request server "GET" "/v1/platform/versions" []
        let tag = fromMaybe "" (header "ETag" fresh)
        unchanged <- request server "GET" "/v1/platform/versions" [("If-None-Match", tag)]
        (statusOf unchanged, bodyOf unchanged, header "ETag" unchanged) @?= (304, "", Just tag)
        headOnly <- request server "HEAD" "/v1/platform/versions" []
        (statusOf headOnly, bodyOf headOnly, header "ETag" headOnly) @?= (200, "", Just tag)
        offer server (pure (Right (Just (snapshotBytes sampleSnapshot {completedAt = "2026-10-31T17:00:00Z"}))))
        refreshed <- request server "GET" "/v1/platform/versions" [("If-None-Match", tag)]
        statusOf refreshed @?= 200
        assertBool "a changed snapshot kept its ETag" (header "ETag" refreshed /= Just tag)
    , testCase "a hung snapshot read answers within the request deadline as snapshot_unavailable" $ withServer 2 defaults {deadline = 200000} $ \server -> do
        offer server (threadDelay 5000000 >> pure (Right Nothing))
        started <- getCurrentTime
        versions <- request server "GET" "/v1/platform/versions" [] >>= decodeBody @PlatformVersions
        finished <- getCurrentTime
        versions ^. #snapshot . #reason @?= Nullable (Just "snapshot_unavailable")
        assertBool "the read was not bounded" (diffUTCTime finished started < 2)
    , testCase "a collected snapshot published to a filesystem store is served with every engine's versions" $ withSystemTempDirectory "versions" $ \directory -> do
        local <- openFilesystemStore directory >>= either (fail . show) pure
        _ <- initializeStore local fixtureBinding "client" >>= either (fail . show) pure
        collected <- collectVersions (CollectSettings "fixture" "project" Nothing 5000000 4) engineProviders >>= either (fail . Text.unpack) pure
        publishVersionSnapshot local collected >>= (@?= Right VersionStore.Published)
        withServer 2 defaults $ \server -> do
          offer server (first (Text.pack . show) <$> readObject local versionSnapshotKey)
          versions <- request server "GET" "/v1/platform/versions" [] >>= decodeBody @PlatformVersions
          [ (database ^. #engine, database ^. #declaredVersion . #value, map (^. #reportedVersion . #value) (database ^. #instances))
            | database <- versions ^. #databases
            ]
            @?= [ ("clickhouse", Nullable (Just "25.8"), [Nullable (Just "25.8.2.29")])
                , ("postgres", Nullable (Just "18"), [Nullable (Just "PostgreSQL 18.1")])
                , ("redis", Nullable (Just "8"), [Nullable (Just "8.2.1")])
                ]
          fmap (^. #version . #value) (fromNullable' (versions ^. #nagare . #installed)) @?= Just (Nullable (Just "0.13.0"))
          versions ^. #nagare . #comparison . #state @?= ComparisonDifferent
    , testCase "the serving build route is unchanged" $ withServer 2 defaults $ \server -> do
        response <- request server "GET" "/v1/platform/version" []
        statusOf response @?= 200
        info <- decodeBody @VersionInfo response
        info ^. #version @?= "0.0.0"
    ]
  where
    offer server answer = writeIORef (snapshotObject server) answer
    installedAs release =
      sampleSnapshot & #installed .~ Nullable (Just (InstalledRelease (stamp release) (stamp "0123456789abcdef") (stamp "nagare-payload") (stamp "2026-10-30T09:00:00Z")))
    stamp present = recordedFact "configmap nagare-system/nagare-platform-version" "2026-10-31T16:00:02Z" (Just present)

-- | Providers of one server per engine, each answering its own version.
engineProviders :: VersionProviders
engineProviders =
  VersionProviders
    { loadAccepted = pure (Right ("rev-1", [server "postgres" "postgres:18", server "clickhouse" "clickhouse/clickhouse-server:25.8", server "redis" "redis:8"]))
    , currentRevision = pure (Right "rev-1")
    , readStamp = pure (Right "{\"data\":{\"version\":\"0.13.0\",\"revision\":\"abc1234\"}}")
    , readHostIdentity = pure (Left ProviderMissing)
    , readNodes = pure (Right "{\"items\":[]}")
    , readPods = \_ -> pure (Right (BC.pack ("{\"items\":[" <> intercalate' "," [pod engine' | engine' <- ["postgres", "clickhouse", "redis"]] <> "]}")))
    , runEngine = \engine' _ _ _ -> pure . Right $ case engine' of
        "postgres" -> "PostgreSQL 18.1\n"
        "clickhouse" -> "25.8.2.29\n"
        _ -> "redis_version:8.2.1\r\n"
    , readPodUid = \_ podName -> pure (Right (Text.replace "-0" "-uid" podName))
    , clock = pure "2026-10-31T16:00:00Z"
    }
  where
    server engine' image =
      KubernetesMember
        ("database:" <> engine')
        ("database:" <> engine' <> "/server/statefulset")
        ( BC.pack
            ( "{\"kind\":\"StatefulSet\",\"metadata\":{\"name\":\""
                <> Text.unpack engine'
                <> "\",\"namespace\":\"db\",\"labels\":{\"nagare.dev/engine\":\""
                <> Text.unpack engine'
                <> "\"}},"
                <> "\"spec\":{\"selector\":{\"matchLabels\":{\"nagare.dev/database\":\""
                <> Text.unpack engine'
                <> "\"}},\"template\":{\"spec\":{\"containers\":[{\"name\":\"db\",\"image\":\""
                <> Text.unpack image
                <> "\"}]}}}}"
            )
        )
    pod engine' =
      "{\"metadata\":{\"name\":\""
        <> engine'
        <> "-0\",\"uid\":\""
        <> engine'
        <> "-uid\",\"labels\":{\"nagare.dev/database\":\""
        <> engine'
        <> "\"}},"
        <> "\"status\":{\"phase\":\"Running\",\"containerStatuses\":[{\"name\":\"db\",\"image\":\""
        <> engine'
        <> "\",\"imageID\":\""
        <> engine'
        <> "@sha256:"
        <> engine'
        <> "\"}]}}"
    intercalate' separator = foldr1 (\left right -> left <> separator <> right)

snapshotBytes :: VersionSnapshot -> ByteString
snapshotBytes = LBS.toStrict . encode

recordedTests :: TestTree
recordedTests =
  testGroup
    "recorded store"
    [ testCase "the head reports open execution state and reads no scope object" $ withServer 12 defaults $ \server -> do
        markMigrated (fixtureOf server)
        _ <- readsSince server
        response <- request server "GET" "/v1/inventory/head" []
        statusOf response @?= 200
        readsSince server >>= (@?= 1)
        summary <- decodeBody @HeadSummary response
        summary ^. #activeTransaction @?= Nullable (Just "tx-open")
        fmap (^. #transaction) (fromNullable' (summary ^. #executorClaim)) @?= Just "tx-open"
        fmap (^. #phase) (fromNullable' (summary ^. #dataFence)) @?= Just "changing"
        fmap (^. #destination) (fromNullable' (summary ^. #migration)) @?= Just "gs://fixture-bucket/nagare/fixture/inventory"
        fmap (^. #target) (fromNullable' (summary ^. #transition)) @?= Just "nagare-0.6.3-source"
        (summary ^. #acceptedScopes, summary ^. #convergedScopes) @?= (15, 14)
        header "Nagare-Head-Revision" response @?= Just (TE.encodeUtf8 (summary ^. #revision))
        header "Cache-Control" response @?= Just "private, no-cache"
        header "Vary" response @?= Just "Authorization, Cookie, Accept"
    , testCase "scope summaries page from the head alone, and a walk skips and repeats nothing" $ withServer 12 defaults $ \server -> do
        expected <- map (^. #scope) <$> allScopes server
        readsSince server >>= (@?= 1)
        report <- checkConformance (ConformanceConfig 4 100 True True) id (scopePage server) expected
        assertBool (Text.unpack (renderConformanceReport report)) (conformancePassed report)
    , testCase "a warm list fetches only the head; churn keeps decodes; a changed scope fetches its member" $ withServer 12 defaults $ \server -> do
        cold <- request server "GET" "/v1/sites?first=100" []
        statusOf cold @?= 200
        readsSince server >>= assertBool "the cold list fetched no scopes" . (> 10)
        warm <- request server "GET" "/v1/sites?first=100" []
        readsSince server >>= (@?= 1)
        bodyOf warm @?= bodyOf cold
        churnHead (fixtureOf server)
        _ <- readsSince server
        churned <- request server "GET" "/v1/sites?first=100" []
        readsSince server >>= (@?= 1)
        header "ETag" churned @?= header "ETag" cold
        assertBool "the snapshot identity did not change" (header "Nagare-Head-Revision" churned /= header "Nagare-Head-Revision" cold)
        replaceScope (fixtureOf server) 2 (siteScope 3 2)
        _ <- readsSince server
        changed <- request server "GET" "/v1/sites?first=100" []
        readsSince server >>= (@?= 2)
        assertBool "a changed scope kept its old representation" (header "ETag" changed /= header "ETag" cold)
    , testCase "a matching If-None-Match answers 304 with validators and no body; HEAD has no body" $ withServer 12 defaults $ \server -> do
        fresh <- request server "GET" "/v1/inventory/publications" []
        let tag = fromMaybe "" (header "ETag" fresh)
        unchanged <- request server "GET" "/v1/inventory/publications" [("If-None-Match", "W/" <> tag <> ", \"other\"")]
        statusOf unchanged @?= 304
        bodyOf unchanged @?= ""
        header "ETag" unchanged @?= Just tag
        assertBool "304 lost the snapshot" (isJust (header "Nagare-Head-Revision" unchanged))
        headOnly <- request server "HEAD" "/v1/inventory/publications" []
        (statusOf headOnly, bodyOf headOnly, header "ETag" headOnly) @?= (200, "", Just tag)
        page <- decodeBody @(Paged Publication) fresh
        case page of
          Paged (Connection [Edge publication _] _) -> publication ^. #usedBy @?= ["application:docs"]
          other -> assertFailure ("unexpected publications " <> show other)
    , testCase "a missing scope is 404 even for If-None-Match: *, and a known one is the head's" $ withServer 12 defaults $ \server -> do
        missing <- request server "GET" "/v1/inventory/scopes/application:nope" [("If-None-Match", "*")]
        statusOf missing @?= 404
        problemCode missing >>= (@?= "unknown_scope")
        header "Cache-Control" missing @?= Just "no-store"
        known <- request server "GET" "/v1/inventory/scopes/standalone:site-s12" []
        state <- decodeBody @ScopeState known
        (state ^. #converged, state ^. #convergedRevision) @?= (False, Nullable Nothing)
    , testCase "bad pages, foreign cursors and malformed parameters are problems before hydration" $ withServer 12 defaults $ \server -> do
        scopesPage <- request server "GET" "/v1/inventory/scopes?first=1" []
        Paged (Connection edges _) <- decodeBody @(Paged ScopeState) scopesPage
        let foreignCursor = maybe "" (TE.encodeUtf8 . cursorToText . (^. #cursor)) (listToMaybe' edges)
        _ <- readsSince server
        for_'
          [ ("/v1/sites?first=101", "invalid_page")
          , ("/v1/sites?first=2&last=2", "invalid_page")
          , ("/v1/sites?after=not-a-cursor", "invalid_cursor")
          , ("/v1/sites?after=" <> foreignCursor, "invalid_cursor")
          , ("/v1/sites?first=lots", "bad_request")
          ]
          $ \(path, code) -> do
            response <- request server "GET" path []
            (statusOf response, header "Content-Type" response) @?= (400, Just "application/problem+json")
            problemCode response >>= (@?= code)
        -- One head read each; the malformed integer never reaches a handler.
        readsSince server >>= (@?= 4)
    , testCase "Servant's own rejections are problems: an unknown route, a wrong method, an unacceptable type" $ withServer 12 defaults $ \server -> do
        unknown <- request server "GET" "/v1/nothing" []
        (statusOf unknown, header "Content-Type" unknown) @?= (404, Just "application/problem+json")
        posted <- request server "POST" "/v1/inventory/head" []
        statusOf posted @?= 405
        problemCode posted >>= (@?= "method_not_allowed")
        html <- request server "GET" "/v1/inventory/head" [("Accept", "text/html")]
        statusOf html @?= 406
        problemCode html >>= (@?= "not_acceptable")
        json <- request server "GET" "/v1/inventory/head" [("Accept", "application/json")]
        statusOf json @?= 200
    , testCase "an unreadable scope breaks only the routes that need it" $ withServer 12 defaults $ \server -> do
        modifyIORef' (lost (fixtureOf server)) (Set.insert (scopeObject server))
        (statusOf <$> request server "GET" "/v1/inventory/head" []) >>= (@?= 200)
        (statusOf <$> request server "GET" "/v1/inventory/scopes" []) >>= (@?= 200)
        broken <- request server "GET" "/v1/sites" []
        statusOf broken @?= 503
        problemCode broken >>= (@?= "store_invalid")
    , testCase "a hung store answers a retryable problem within the deadline and recovers" $ withServer 12 defaults {deadline = 1000000} $ \server -> do
        writeIORef (hang (fixtureOf server)) True
        started <- getCurrentTime
        hung <- request server "GET" "/v1/sites" []
        finished <- getCurrentTime
        statusOf hung @?= 503
        problemCode hung >>= (@?= "store_timeout")
        assertBool "the deadline was not honored" (diffUTCTime finished started < 1.5)
        live <- request server "GET" "/health/live" []
        statusOf live @?= 200
        writeIORef (hang (fixtureOf server)) False
        (statusOf <$> request server "GET" "/v1/sites" []) >>= (@?= 200)
    , testCase "excess concurrent requests are refused at once with server_busy and Retry-After" $ withServer 12 defaults {admit = 1, deadline = 3000000} $ \server -> do
        writeIORef (hang (fixtureOf server)) True
        first' <- async (request server "GET" "/v1/inventory/head" [])
        threadDelay 200000
        busy <- request server "GET" "/v1/inventory/head" []
        (statusOf busy, header "Retry-After" busy) @?= (503, Just "1")
        problemCode busy >>= (@?= "server_busy")
        writeIORef (hang (fixtureOf server)) False
        (statusOf <$> wait first') >>= (@?= 200)
    , testCase "grants are the recorded user and team viewers, including one whose route is gone" $ withServer 12 defaults $ \server -> do
        response <- request server "GET" "/v1/access/grants" []
        Paged (Connection edges _) <- decodeBody @(Paged Grant) response
        [(grant ^. #host, grant ^. #subjectKind, grant ^. #subject, grant ^. #subjectRelation) | Edge grant _ <- edges]
          @?= [ ("gone.example.com", SubjectUser, "user_2", Nullable Nothing)
              , ("s2.example.com", SubjectTeam, "editors", Nullable (Just "member"))
              , ("s1.example.com", SubjectUser, "user_1", Nullable Nothing)
              ]
    , testCase "a cold list over a slow store reads members in parallel, never past eight at once" $ withServer 60 defaults $ \server -> do
        writeIORef (delay (fixtureOf server)) 20000
        cold <- request server "GET" "/v1/sites?first=100" []
        statusOf cold @?= 200
        peak <- readIORef (peakReads (fixtureOf server))
        assertBool ("reads did not overlap (peak " <> show peak <> ")") (peak >= 2)
        assertBool ("more than eight reads at once (peak " <> show peak <> ")") (peak <= 8)
    , testCase "each request but a probe writes one bounded access line" $ withServer 3 defaults $ \server -> do
        _ <- request server "GET" "/health/ready" []
        _ <- request server "GET" "/v1/sites?first=2&namespace=personal" [("Authorization", "Bearer secret-token"), ("User-Agent", "kotei/1")]
        _ <- request server "GET" "/v1/sites?first=2&namespace=personal" []
        lines' <- accessLines server
        length lines' @?= 2
        values <- traverse (either (\failure -> assertFailure failure >> fail "json") pure . eitherDecode . LBS.fromStrict) lines'
        [(field "path" value, field "cache" value, field "status" value) | value <- values]
          @?= [ (Just (String "/v1/sites"), Just (String "miss"), Just (Number 200))
              , (Just (String "/v1/sites"), Just (String "hit"), Just (Number 200))
              ]
        assertBool "a credential or the query string reached the log" (not (any (\line -> "secret-token" `BC.isInfixOf` line || "namespace=" `BC.isInfixOf` line) lines'))
        field "user_agent" (head' values) @?= Just (String "kotei/1")
    , testCase "the client derived from the routes walks the sites of one head" $ withServer 30 defaults $ \server -> do
        expected <- map (^. #resourceId) <$> allSites server
        length expected @?= 30
        report <- checkConformance (ConformanceConfig 7 100 True True) id (sitePage server) expected
        assertBool (Text.unpack (renderConformanceReport report)) (conformancePassed report)
    ]

data Options = Options
  { deadline :: !Int
  , admit :: !Int
  , servingRevision :: !(Maybe Text)
  }

defaults :: Options
defaults = Options {deadline = 10000000, admit = 32, servingRevision = Nothing}

data Server = Server
  { fixtureOf :: !Fixture
  , port :: !Int
  , manager :: !HTTP.Manager
  , accessLines :: !(IO [ByteString])
  , run :: !(forall a. ClientM a -> IO a)
  , snapshotObject :: !(IORef (IO (Either Text (Maybe ByteString))))
  -- ^ What the next platform-versions snapshot read returns.
  }

withServer :: Int -> Options -> (Server -> IO ()) -> IO ()
withServer sites (Options deadlineValue admitValue revisionValue) action = do
  recorded <- fixture sites
  reader <- newRecordedReader defaultRecordedReaderConfig (store recorded) fixtureBinding (readHead (store recorded))
  snapshotRef <- newIORef (pure (Right Nothing))
  env <- newEnv reader "test-build" fixtureBinding (join (readIORef snapshotRef))
  logged <- newIORef []
  application <- adminApplication (AppConfig "fixture" (VersionInfo "0.0.0" "0.0.0" revisionValue Nothing contractVersions) admitValue (\line -> atomicModifyIORef' logged (\lines' -> (line : lines', ())))) env {deadlineMicroseconds = deadlineValue}
  testWithApplication (pure application) $ \portNumber -> do
    httpManager <- HTTP.newManager HTTP.defaultManagerSettings
    base <- parseBaseUrl ("http://127.0.0.1:" <> show portNumber)
    let clientEnv = mkClientEnv httpManager base
    writeIORef (objectReads recorded) 0
    action (Server recorded portNumber httpManager (reverse <$> readIORef logged) (\call -> runClientM call clientEnv >>= either (\failure -> assertFailure (show failure) >> fail "client") pure) snapshotRef)

request :: Server -> Method -> ByteString -> [Header] -> IO (HTTP.Response LBS.ByteString)
request server method path headers = do
  initial <- HTTP.parseRequest ("http://127.0.0.1:" <> show (port server) <> BC.unpack path)
  HTTP.httpLbs initial {HTTP.method = method, HTTP.requestHeaders = headers} (manager server)

statusOf :: HTTP.Response a -> Int
statusOf = statusCode . HTTP.responseStatus

bodyOf :: HTTP.Response LBS.ByteString -> LBS.ByteString
bodyOf = HTTP.responseBody

header :: HeaderName -> HTTP.Response a -> Maybe ByteString
header name = lookup name . HTTP.responseHeaders

decodeBody :: forall a. (FromJSON a) => HTTP.Response LBS.ByteString -> IO a
decodeBody response = either (\failure -> assertFailure failure >> fail "decode") pure (eitherDecode (bodyOf response))

problemCode :: HTTP.Response LBS.ByteString -> IO Text
problemCode response = (^. #code) <$> decodeBody @ProblemDetails response

-- | Object reads since the last call.
readsSince :: Server -> IO Int
readsSince server = atomicModifyIORef' (objectReads (fixtureOf server)) (0,)

client :: Root.AdminApi (AsClientT ClientM)
client = genericClient

allScopes :: Server -> IO [ScopeState]
allScopes server = do
  result <- run server (Inventory.scopes (Root.inventory client) (Just (PageSize 100)) Nothing Nothing Nothing Nothing)
  Paged (Connection edges _) <- decoded result
  pure (map (^. #node) edges)

allSites :: Server -> IO [SiteSummary]
allSites server = do
  result <- run server (Sites.sites (Root.sites client) Nothing Nothing (Just (PageSize 100)) Nothing Nothing Nothing Nothing)
  Paged (Connection edges _) <- decoded result
  pure (map (^. #node) edges)

scopePage :: Server -> PageRequest -> IO (Connection Text)
scopePage server pageRequest = do
  let (firstArg, afterArg, lastArg, beforeArg) = arguments pageRequest
  result <- run server (Inventory.scopes (Root.inventory client) firstArg afterArg lastArg beforeArg Nothing)
  Paged page <- decoded result
  pure (fmap (^. #scope) page)

sitePage :: Server -> PageRequest -> IO (Connection Text)
sitePage server pageRequest = do
  let (firstArg, afterArg, lastArg, beforeArg) = arguments pageRequest
  result <- run server (Sites.sites (Root.sites client) Nothing Nothing firstArg afterArg lastArg beforeArg Nothing)
  Paged page <- decoded result
  pure (fmap (^. #resourceId) page)

arguments :: PageRequest -> (Maybe PageSize, Maybe Text, Maybe PageSize, Maybe Text)
arguments PageRequest {pageSize = size, direction = way, cursor = position} = case way of
  Forward -> (Just (PageSize size), cursorToText <$> position, Nothing, Nothing)
  Backward -> (Nothing, Nothing, Just (PageSize size), cursorToText <$> position)

decoded :: (FromJSON a) => SnapshotResult a -> IO a
decoded = \case
  SnapshotOk value -> either (\failure -> assertFailure failure >> fail "decode") pure (decodeEncoded (value ^. #body))
  other -> assertFailure ("expected 200, got " <> show other) >> fail "status"

-- | The object key of the first site's accepted scope member.
scopeObject :: Server -> Text
scopeObject _ = Text.pack (scopeKey (contentDigest (encodeCanonicalScope (siteScope 1 1))))

fromNullable' :: Nullable a -> Maybe a
fromNullable' (Nullable value) = value

listToMaybe' :: [a] -> Maybe a
listToMaybe' = \case
  [] -> Nothing
  value : _ -> Just value

for_' :: [a] -> (a -> IO ()) -> IO ()
for_' xs action = mapM_ action xs

field :: Text -> Value -> Maybe Value
field name = \case
  Object fields -> KeyMap.lookup (fromText' name) fields
  _ -> Nothing
  where
    fromText' = Data.Aeson.Key.fromText

head' :: [Value] -> Value
head' = \case
  value : _ -> value
  [] -> Null
