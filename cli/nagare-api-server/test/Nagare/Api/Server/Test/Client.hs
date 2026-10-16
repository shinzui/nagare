{-# LANGUAGE DataKinds #-}

-- | The client derived from the same route types decodes a head, a Relay
-- page of sites and a problem, and sees the validators and the 304 (EP-197
-- M1). The server here answers fixtures; the recorded-state handlers have
-- their own tests.
module Nagare.Api.Server.Test.Client
  ( clientTests
  )
where

import Data.Aeson (ToJSON, encode)
import Data.Generics.Labels ()
import Data.Time (UTCTime (..), fromGregorian)
import Nagare.Api.Access.Routes qualified as Access
import Nagare.Api.Inventory.Routes qualified as Inventory
import Nagare.Api.Platform.Routes qualified as Platform
import Nagare.Api.Response
import Nagare.Api.Routes qualified as Root
import Nagare.Api.Sites.Routes qualified as Sites
import Nagare.Contract.Prelude
import Nagare.Contract.Problem (ProblemDetails (..), problemFor, unknownScope)
import Nagare.Contract.Schema (Nullable (..))
import Nagare.Contract.V1
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
    { Root.platform = Platform.PlatformRoutes {Platform.version = \_ -> pure (BuildOk (BuildBody (encoded sampleVersion) (validatorsFor "version")))}
    , Root.inventory =
        Inventory.InventoryRoutes
          { Inventory.head = \match -> pure (conditional match (encoded sampleHead))
          , Inventory.scopes = \_ _ _ _ _ -> pure (conditional Nothing (encoded (Paged (Connection [] emptyPage) :: Paged ScopeState)))
          , Inventory.scope = \_ _ -> pure (SnapshotNotFound missingScope)
          , Inventory.publications = \_ _ _ _ _ -> pure (conditional Nothing (encoded (Paged (Connection [] emptyPage) :: Paged Publication)))
          }
    , Root.sites = Sites.SitesRoutes {Sites.sites = \_ _ _ _ _ _ match -> pure (conditional match (encoded (Paged samplePage)))}
    , Root.access = Access.AccessRoutes {Access.grants = \_ _ _ _ _ -> pure (conditional Nothing (encoded (Paged (Connection [] emptyPage) :: Paged Grant)))}
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

sampleVersion :: VersionInfo
sampleVersion = VersionInfo "0.6.3" "0.6.3" Nothing Nothing contractVersions

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
