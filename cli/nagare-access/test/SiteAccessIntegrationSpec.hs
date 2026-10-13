-- | User and team isolation through the whole path (MasterPlan 27, EP-188 M2):
-- the exact backend map nagarectl composes for two protected sites of two
-- kinds, the exact relationship tuples its reviewed commands write, the real
-- En evaluator over the reviewed schema reading a live tuple set, and the
-- gateway with its decision cache on an injected clock. Signing in, joining an
-- unrelated team, or holding a grant on another host never admits anyone; a
-- removed last path denies within the TTL; an outage and a conditional answer
-- never open an origin; a raw identity header is not a credential.
module SiteAccessIntegrationSpec (siteAccessIntegrationTests) where

import Control.Monad (forM)
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Effectful (IOE, liftIO, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import En.Budget (defaultEvaluationBudget)
import En.Check qualified as EnCheck
import En.Conformance.Kikan qualified as Kikan
import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.TupleStore (TupleStore)
import En.Error (EnError)
import En.Lookup qualified as EnLookup
import En.LookupSubjects qualified as EnLookupSubjects
import En.Schema qualified as EnRaw
import En.Servant.API qualified as EnApi
import En.Servant.Seam (Env (..))
import En.Tuple qualified as EnTuple
import En.Watch (watchUnsupported)
import Nagare.Access.App (appWithRuntime, textResponse)
import Nagare.Access.Auth (AuthFailure (InvalidCredential), AuthenticatedUser (..))
import Nagare.Access.BackendMap (decodeBackendMap)
import Nagare.Access.Credential (Credential (BearerToken))
import Nagare.Access.DecisionCache (AccessDecision (..), AuthorizationResult (..), DecisionCache, newDecisionCache)
import Nagare.Access.En (authorizeWithEn, enClientEnvFromAuthPlane)
import Nagare.Access.Prelude
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types (Status, hAccept, hHost, status200, status401, status403, status502, status503)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (testWithApplication)
import Network.Wai.Test (SResponse (..), defaultRequest, request, runSession, setPath)
import TeamAccessSpec (authConfig, memberTuple, ref, teamActiveSchema, teamViewerTuple)
import Test.Tasty
import Test.Tasty.HUnit
import TestServices (testServices, withHeader)

-- | The backends.json nagarectl composes for a protected StaticSite @a@ and a
-- protected ServerSite @b@ (its "two protected sites of two kinds compose one
-- backend map" case). Nothing else is routed.
composedBackends :: Text
composedBackends = "{\"a.example.test\":\"http://a.personal.svc.cluster.local\",\"b.example.test\":\"http://b.personal.svc.cluster.local\"}"

siteAccessIntegrationTests :: TestTree
siteAccessIntegrationTests =
  testGroup
    "site access integration"
    [ testCase "a signed-in user reaches exactly the hosts granted to them or their teams; an unrouted host has no backend (502)" $
        withWorld 30 initialGrants $ \world -> do
          decisions <- askAll world
          decisions
            @?= [ (("alice", "a.example.test"), status200)
                , (("alice", "b.example.test"), status403)
                , (("bob", "a.example.test"), status403)
                , (("bob", "b.example.test"), status200)
                , (("carol", "a.example.test"), status403)
                , (("carol", "b.example.test"), status403)
                ]
          ask world "alice" "c.example.test" >>= (@?= status502) . simpleStatus
          readIORef (world ^. #reached) >>= (@?= ["a.example.test", "b.example.test"])
    , testCase "a direct grant admits only its host and its revocation removes it; an independent path keeps access" $
        withWorld 0 initialGrants $ \world -> do
          grant world (directViewer "a.example.test" "carol")
          ask world "carol" "a.example.test" >>= (@?= status200) . simpleStatus
          ask world "carol" "b.example.test" >>= (@?= status403) . simpleStatus
          revoke world (directViewer "a.example.test" "carol")
          ask world "carol" "a.example.test" >>= (@?= status403) . simpleStatus
          -- Alice gains a direct grant beside her team; losing the team keeps a.
          grant world (directViewer "a.example.test" "alice")
          revoke world (memberTuple "engineering" "alice")
          ask world "alice" "a.example.test" >>= (@?= status200) . simpleStatus
          revoke world (directViewer "a.example.test" "alice")
          ask world "alice" "a.example.test" >>= (@?= status403) . simpleStatus
          readIORef (world ^. #reached) >>= (@?= ["a.example.test", "a.example.test"])
    , testCase "a revoked last path is served for at most the TTL from the check's start, and not at all with a zero TTL" $
        withWorld 30 initialGrants $ \world -> do
          ask world "bob" "b.example.test" >>= (@?= status200) . simpleStatus
          revoke world (memberTuple "finance" "bob")
          writeIORef (world ^. #clock) 129
          ask world "bob" "b.example.test" >>= (@?= status200) . simpleStatus
          writeIORef (world ^. #clock) 130
          ask world "bob" "b.example.test" >>= (@?= status403) . simpleStatus
          -- A zero TTL: every request is the next fully consistent check.
          uncached <- newDecisionCache 0 (readIORef (world ^. #clock))
          writeIORef (world ^. #cacheRef) uncached
          grant world (memberTuple "finance" "bob")
          ask world "bob" "b.example.test" >>= (@?= status200) . simpleStatus
          revoke world (memberTuple "finance" "bob")
          ask world "bob" "b.example.test" >>= (@?= status403) . simpleStatus
    , testCase "an en outage is 503 with no upstream call and is not cached; service returns on the next request" $
        withWorld 30 initialGrants $ \world -> do
          writeIORef (world ^. #outage) True
          ask world "alice" "a.example.test" >>= (@?= status503) . simpleStatus
          readIORef (world ^. #reached) >>= (@?= [])
          writeIORef (world ^. #outage) False
          ask world "alice" "a.example.test" >>= (@?= status200) . simpleStatus
    , testCase "a conditional answer is refused, and a raw identity header admits nobody" $
        withWorld 0 initialGrants $ \world -> do
          writeIORef (world ^. #conditional) True
          ask world "alice" "a.example.test" >>= (@?= status403) . simpleStatus
          writeIORef (world ^. #conditional) False
          forged <-
            runSession
              (request (withHeader "X-Forwarded-User" "alice" (withHeader hAccept "application/json" (withHeader hHost "a.example.test" (setPath defaultRequest "/api")))))
              (world ^. #gateway)
          simpleStatus forged @?= status401
          readIORef (world ^. #reached) >>= (@?= [])
    ]

-- | Alice is in engineering, which holds a; Bob is in finance, which holds b;
-- Carol belongs to no team. These are the exact tuples the reviewed commands write.
initialGrants :: [EnTuple.Tuple]
initialGrants =
  [ memberTuple "engineering" "alice"
  , memberTuple "finance" "bob"
  , teamViewerTuple "a.example.test" "engineering"
  , teamViewerTuple "b.example.test" "finance"
  ]

data World = World
  { tuples :: !(IORef [EnTuple.Tuple])
  , clock :: !(IORef Int)
  , cacheRef :: !(IORef DecisionCache)
  , outage :: !(IORef Bool)
  , conditional :: !(IORef Bool)
  , reached :: !(IORef [Text])
  , gateway :: !Wai.Application
  }
  deriving stock (Generic)

-- | The gateway over the composed backend map, the real En over @grants@, a
-- decision cache with @ttl@ on an injected clock, and switches that stand in
-- for an En outage and a caveated answer.
withWorld :: Int -> [EnTuple.Tuple] -> (World -> IO ()) -> IO ()
withWorld ttl grants body = do
  tuples <- newIORef grants
  testWithApplication (pure (liveEnApp tuples)) $ \enPort -> do
    manager <- HC.newManager HC.defaultManagerSettings
    clientEnv <- either (assertFailure . Text.unpack) pure =<< enClientEnvFromAuthPlane manager (authConfig enPort)
    backends <- either (assertFailure . Text.unpack) pure (decodeBackendMap (TE.encodeUtf8 composedBackends))
    clock <- newIORef 100
    cacheRef <- newIORef =<< newDecisionCache ttl (readIORef clock)
    outage <- newIORef False
    conditional <- newIORef False
    reached <- newIORef []
    let authorize user host = do
          down <- readIORef outage
          caveated <- readIORef conditional
          if down
            then pure (AuthorizationUnavailable "en is down")
            else
              if caveated
                then pure (AuthorizationDecision AccessConditional)
                else authorizeWithEn clientEnv user host
        gateway req respond = do
          current <- readIORef cacheRef
          let services =
                testServices
                  & #verifyCredential
                  .~ ( \case
                         BearerToken token | Just user <- lookup token tokens -> pure (Right AuthenticatedUser {subject = user})
                         _ -> pure (Left InvalidCredential)
                     )
                  & #authorizeUser
                  .~ authorize
                  & #decisionCache
                  .~ current
                  & #forwardAuthorized
                  .~ (\_ host _ _ -> modifyIORef' reached (<> [host]) >> pure (textResponse status200 "proxied"))
          appWithRuntime backends services req respond
    body World {tuples, clock, cacheRef, outage, conditional, reached, gateway}

tokens :: [(Text, Text)]
tokens = [("alice-token", "alice"), ("bob-token", "bob"), ("carol-token", "carol")]

ask :: World -> Text -> Text -> IO SResponse
ask world user host =
  runSession
    (request (withHeader hHost (TE.encodeUtf8 host) (withHeader "Authorization" ("Bearer " <> TE.encodeUtf8 user <> "-token") (setPath defaultRequest "/"))))
    (world ^. #gateway)

askAll :: World -> IO [((Text, Text), Status)]
askAll world =
  forM [(user, host) | (_, user) <- tokens, host <- ["a.example.test", "b.example.test"]] $ \(user, host) -> do
    response <- ask world user host
    pure ((user, host), simpleStatus response)

-- | An acknowledged write: the next fully consistent check sees it.
grant, revoke :: World -> EnTuple.Tuple -> IO ()
grant world tuple = modifyIORef' (world ^. #tuples) (<> [tuple])
revoke world tuple = modifyIORef' (world ^. #tuples) (filter (/= tuple))

type LiveEffects = '[ConsistencyStore, TupleStore, Error EnError, IOE]

-- | The real En API over the reviewed schema, reading the live tuple set at
-- the start of every request, as a store would after an acknowledged write.
liveEnApp :: IORef [EnTuple.Tuple] -> Wai.Application
liveEnApp tuples =
  EnApi.app env
  where
    env :: Env LiveEffects
    env =
      Env
        { runPorts = \_active action ->
            runEff $
              runErrorNoCallStack @EnError $ do
                current <- liftIO (readIORef tuples)
                Kikan.runTupleStoreInMemory current (Kikan.runConsistencyStoreInMemory action)
        , readActiveSchema = pure teamActiveSchema
        , checkOperation = EnCheck.check
        , grantGenerationOperation = const (pure Nothing)
        , lookupWithDeadlineOperation = EnLookup.lookupWithDeadline
        , lookupSubjectsWithDeadlineOperation = EnLookupSubjects.lookupSubjectsWithDeadline
        , watchOperation = watchUnsupported
        , budget = defaultEvaluationBudget
        , maxBatchSize = 20
        , deadlineDefaultMillis = 3000
        , deadlineMaxMillis = 30000
        , mint = Nothing
        }

-- | @app:<host>#viewer@user:<user>@, as nagarectl's accessTuple writes it.
directViewer :: Text -> Text -> EnTuple.Tuple
directViewer host user =
  EnTuple.Tuple
    { EnTuple.object = ref "app" host
    , EnTuple.relation = EnRaw.RelationName "viewer"
    , EnTuple.subject = EnTuple.SubjectId (ref "user" user)
    , EnTuple.caveat = Nothing
    }
