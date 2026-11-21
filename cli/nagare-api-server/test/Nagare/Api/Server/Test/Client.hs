{-# LANGUAGE DataKinds #-}

-- | The client derived from the same route types decodes a head, a Relay
-- page of sites and a problem, and sees the validators and the 304 (EP-197
-- M1). The server here answers fixtures; the recorded-state handlers have
-- their own tests.
module Nagare.Api.Server.Test.Client
  ( clientTests
  )
where

import Data.Aeson (ToJSON, encode, object)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Time (UTCTime (..), fromGregorian)
import Nagare.Api.Access.Routes qualified as Access
import Nagare.Api.Events.Routes qualified as Events
import Nagare.Api.Inventory.Routes qualified as Inventory
import Nagare.Api.Page (PageSize (..))
import Nagare.Api.Platform.Routes qualified as Platform
import Nagare.Api.Response
import Nagare.Api.Routes qualified as Root
import Nagare.Api.Sites.Routes qualified as Sites
import Nagare.Contract.Delivery (Delivery, DeliverySubscription)
import Nagare.Contract.Events
import Nagare.Contract.Prelude
import Nagare.Contract.Problem (ProblemDetails (..), problemFor, unknownDelivery, unknownEvent, unknownScope)
import Nagare.Contract.Schema (Nullable (..))
import Nagare.Contract.V1
import Nagare.Contract.Versions (ServingBuild (..))
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Network.Wai.Handler.Warp (testWithApplication)
import Relay.Pagination (Connection (..), CursorPayload (..), Edge (..), KeyValue (..), PageInfo (..), cursorVersion, encodeCursor)
import Servant.Client (ClientM, mkClientEnv, parseBaseUrl, runClientM)
import Servant.Client.Generic (AsClientT, genericClient)
import Servant.Health (ProbeVerdict (..), healthServer)
import Servant.Server (Handler, serve)
import Servant.Server.Generic (AsServerT)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

clientTests :: TestTree
clientTests =
  testGroup
    "generated client"
    [ testCase "decodes a head with its validators and snapshot, then a 304" $ withClient $ \run -> do
        fresh <- run (Inventory.head (Root.inventory client) Nothing)
        body <- case fresh of
          SnapshotOk value -> pure value
          other -> assertFailure ("expected 200, got " <> show other) >> fail "status"
        decodeEncoded (body ^. #body) @?= Right sampleHead
        body ^. #headRevision @?= sampleHead ^. #revision
        unchanged <- run (Inventory.head (Root.inventory client) (Just (body ^. #validators . #etag)))
        unchanged @?= SnapshotNotModified (SnapshotUnchanged (body ^. #validators) (body ^. #headRevision))
    , testCase "decodes a Relay page of sites" $ withClient $ \run -> do
        result <- run (Sites.sites (Root.sites client) (Just "personal") Nothing Nothing Nothing Nothing Nothing Nothing)
        case result of
          SnapshotOk value -> decodeEncoded (value ^. #body) @?= Right (Paged samplePage)
          other -> assertFailure ("expected 200, got " <> show other)
    , testCase "decodes a Relay page of lifecycle events and an unknown event (EP-231)" $ withClient $ \run -> do
        listed <- run (Events.list (Root.events client) (Just (PageSize 1)) Nothing Nothing Nothing False ["app.deployed"] Nothing Nothing Nothing)
        case listed of
          SnapshotOk value -> decodeEncoded (value ^. #body) @?= Right sampleEvents
          other -> assertFailure ("expected 200, got " <> show other)
        noDelivery <- run (Events.delivery (Root.events client) "dl-00000000000000000000000000000000" Nothing)
        case noDelivery of
          SnapshotNotFound problem -> problem ^. #code @?= "unknown_delivery"
          _ -> assertFailure "expected unknown_delivery"
        listedDeliveries <- run (Events.deliveries (Root.events client) Nothing Nothing Nothing Nothing "deploys" Nothing)
        case listedDeliveries of
          SnapshotOk _ -> pure ()
          _ -> assertFailure "expected a page of deliveries (EP-234)"
        missing <- run (Events.event (Root.events client) "ev-00000000000000000000000000000000" Nothing)
        case missing of
          SnapshotNotFound problem -> problem ^. #code @?= "unknown_event"
          other -> assertFailure ("expected 404, got " <> show other)
    , testCase "decodes a missing scope as a 404 problem" $ withClient $ \run -> do
        result <- run (Inventory.scope (Root.inventory client) "application:nope" Nothing)
        result @?= SnapshotNotFound missingScope
    ]

client :: Root.AdminApi (AsClientT ClientM)
client = genericClient

withClient :: ((forall a. ClientM a -> IO a) -> IO ()) -> IO ()
withClient action =
  testWithApplication (pure (serve Root.adminApi fixtureServer)) $ \port -> do
    manager <- newManager defaultManagerSettings
    base <- parseBaseUrl ("http://127.0.0.1:" <> show port)
    let env = mkClientEnv manager base
    action (\call -> runClientM call env >>= either (\failure -> assertFailure (show failure) >> fail "client") pure)

fixtureServer :: Root.AdminApi (AsServerT Handler)
fixtureServer =
  Root.AdminApi
    { Root.platform = Platform.PlatformRoutes {Platform.version = \_ -> pure (BuildOk (BuildBody (encoded sampleVersion) (validatorsFor "version"))), Platform.versions = \_ -> pure (BuildNotModified (validatorsFor "versions"))}
    , Root.inventory =
        Inventory.InventoryRoutes
          { Inventory.head = \match -> pure (conditional match (encoded sampleHead))
          , Inventory.scopes = \_ _ _ _ _ -> pure (conditional Nothing (encoded (Paged (Connection [] emptyPage) :: Paged ScopeState)))
          , Inventory.scope = \_ _ -> pure (SnapshotNotFound missingScope)
          , Inventory.publications = \_ _ _ _ _ -> pure (conditional Nothing (encoded (Paged (Connection [] emptyPage) :: Paged Publication)))
          }
    , Root.sites = Sites.SitesRoutes {Sites.sites = \_ _ _ _ _ _ match -> pure (conditional match (encoded (Paged samplePage)))}
    , Root.access = Access.AccessRoutes {Access.grants = \_ _ _ _ _ -> pure (conditional Nothing (encoded (Paged (Connection [] emptyPage) :: Paged Grant)))}
    , Root.events =
        Events.EventsRoutes
          { Events.list = \_ _ _ _ _ _ _ _ _ -> pure (conditional Nothing (encoded sampleEvents))
          , Events.subscriptions = \_ -> pure (conditional Nothing (encoded ([] :: [DeliverySubscription])))
          , Events.deliveries = \_ _ _ _ _ _ -> pure (conditional Nothing (encoded (Paged (Connection [] emptyPage) :: Paged Delivery)))
          , Events.delivery = \_ _ -> pure (SnapshotNotFound (problemFor unknownDelivery "dl-00000000000000000000000000000000 is not a delivery of this context"))
          , Events.event = \_ _ -> pure (SnapshotNotFound (problemFor unknownEvent "ev-00000000000000000000000000000000 is not a published event"))
          }
    , Root.openapi = \_ -> pure (BuildNotModified (validatorsFor "openapi"))
    , Root.health = healthServer (pure Healthy) (pure (Unhealthy "store" (UTCTime (fromGregorian 2026 10 16) 0)))
    }
  where
    conditional :: Maybe Text -> Encoded a -> SnapshotResult a
    conditional match bytes
      | match == Just (validatorsFor "fixture" ^. #etag) = SnapshotNotModified (SnapshotUnchanged (validatorsFor "fixture") (sampleHead ^. #revision))
      | otherwise = SnapshotOk (SnapshotBody bytes (validatorsFor "fixture") (sampleHead ^. #revision))

encoded :: (ToJSON a) => a -> Encoded a
encoded value = Encoded (encode value)

validatorsFor :: Text -> Validators
validatorsFor tag = Validators ("\"" <> tag <> "\"") "private, no-cache" "Authorization, Cookie, Accept"

missingScope :: ProblemDetails
missingScope = problemFor unknownScope "application:nope is not an accepted scope"

emptyPage :: PageInfo
emptyPage = PageInfo False False Nothing Nothing

sampleHead :: HeadSummary
sampleHead =
  HeadSummary
    { context = ContextRef "intranet" "example-project"
    , generation = 12
    , journalSequence = 40
    , revision = "3f1c"
    , acceptedScopes = 2
    , convergedScopes = 1
    , activeTransaction = Nullable (Just "tx-open")
    , executorClaim = Nullable Nothing
    , dataFence = Nullable Nothing
    , migration = Nullable Nothing
    , transition = Nullable (Just (TransitionSummary "0.6.2" "nagare-0.6.3-source" "2026-10-16T12:00:00Z"))
    }

sampleVersion :: ServingBuild
sampleVersion = ServingBuild (Nullable (Just "registry.example/nagare/nagare-admin-api@sha256:serving")) contractVersions "2026-10-16T12:00:00Z"

samplePage :: Connection SiteSummary
samplePage =
  Connection
    [Edge site cursor]
    (PageInfo False False (Just cursor) (Just cursor))
  where
    cursor = encodeCursor (CursorPayload cursorVersion 7 [KvText "standalone:site-docs/site/service"])
    site =
      SiteSummary
        { scope = "standalone:site-docs"
        , resourceId = "standalone:site-docs/site/service"
        , kind = SiteKindSite
        , state = RecordConverged
        , name = "docs"
        , namespace = "personal"
        , hostnames = ["docs.example.com"]
        , acceptedRevision = Revision 3 "a1"
        , convergedRevision = Nullable (Just (Revision 3 "a1"))
        , lastConverged = Nullable (Just (SiteService "docs" "personal" ["docs.example.com"]))
        }

-- | One lifecycle event page, as the feed serves it (EP-231).
sampleEvents :: Paged LifecycleFeedEntry
sampleEvents =
  Paged
    ( Connection
        [Edge (LifecycleFeedEntry 0 event) cursor]
        (PageInfo False False (Just cursor) (Just cursor))
    )
  where
    cursor = encodeCursor (CursorPayload cursorVersion 1 [KvText "0"])
    event =
      LifecycleEvent
        { schemaVersion = 1
        , eventId = "ev-0123456789abcdef0123456789abcdef"
        , eventType = "app.deployed"
        , context = "fixture"
        , resource = LifecycleResource (LifecycleScope "application" "notes") (Nullable Nothing) (Nullable (Just "personal")) (Nullable Nothing)
        , occurredAt = "2026-11-17T10:00:00Z"
        , observedAt = "2026-11-17T10:00:05Z"
        , publishedAt = "2026-11-17T10:00:07Z"
        , evidence = [LifecycleEvidence "review" "0000000000000000000000000000000000000000000000000000000000000000"]
        , eventData = object ["release" Aeson..= ("notes-1" :: Text)]
        }
