-- | Team site grants through a real En (MasterPlan 27, EP-187 M1).
--
-- The reviewed bootstrap schema and the exact relationship tuples nagarectl
-- writes (its "team wire pins the exact subject kind" case) are driven through
-- the pinned En evaluator here: the schema parses and compiles, a team's member
-- reaches the team's host and nothing else, and the cost of a check against a
-- flat team is recorded as tuple-store operations, for members and strangers.
-- The team schema, En configuration and tuple fixtures are shared with
-- "SiteAccessIntegrationSpec", which drives the same tuples through the gateway.
module TeamAccessSpec (teamAccessTests, authConfig, memberTuple, ref, teamActiveSchema, teamViewerTuple) where

import Control.Monad (forM)
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpose, send)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import En.Budget (defaultEvaluationBudget)
import En.Caveat.Value (CaveatContext (..))
import En.Check qualified as EnCheck
import En.Conformance.Kikan qualified as Kikan
import En.Decision (CheckDecision (..))
import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.TupleStore (TuplePage, TupleStore (..))
import En.Error (EnError)
import En.Lookup qualified as EnLookup
import En.LookupSubjects qualified as EnLookupSubjects
import En.Reachability (ReachabilityGraph, compileSchema)
import En.Revision (Consistency (FullyConsistent))
import En.Schema qualified as EnRaw
import En.Schema.Parse (parseSchema)
import En.Servant.API qualified as EnApi
import En.Servant.Seam (ActiveSchema (..), Env (..))
import En.Tuple qualified as EnTuple
import En.Watch (watchUnsupported)
import Nagare.Access.App (appWithRuntime, textResponse)
import Nagare.Access.Auth (AuthFailure (InvalidCredential), AuthenticatedUser (..))
import Nagare.Access.BackendMap (backendMapFromList)
import Nagare.Access.Config (AuthPlaneConfig (..))
import Nagare.Access.Credential (Credential (BearerToken))
import Nagare.Access.En (authorizeWithEn, enClientEnvFromAuthPlane)
import Nagare.Access.Prelude
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types (hHost, status200, status403)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (testWithApplication)
import Network.Wai.Test (SResponse (..), defaultRequest, request, runSession, setPath)
import Test.Tasty
import Test.Tasty.HUnit
import TestServices (testServices, withHeader)

teamAccessTests :: TestTree
teamAccessTests =
  testGroup
    "team access"
    [ testCase "the reviewed bootstrap schema parses and compiles with the pinned En" $ do
        schema <- either (assertFailure . show) pure (parseSchema teamSchemaSource)
        _ <- either (assertFailure . show) pure (compileSchema schema)
        pure ()
    , testCase "a team's member reaches the team's host and nothing else; a stranger reaches nothing" $
        testWithApplication (pure (teamEnApp sites)) $ \enPort -> do
          manager <- HC.newManager HC.defaultManagerSettings
          clientEnv <- either (assertFailure . Text.unpack) pure =<< enClientEnvFromAuthPlane manager (authConfig enPort)
          backends <- either (assertFailure . Text.unpack) pure (backendMapFromList [(host, "http://" <> host <> ".svc") | host <- ["a.example.test", "b.example.test"]])
          reached <- newIORef ([] :: [Text])
          let services =
                testServices
                  & #verifyCredential
                  .~ ( \case
                         BearerToken token | Just user <- lookup token tokens -> pure (Right AuthenticatedUser {subject = user})
                         _ -> pure (Left InvalidCredential)
                     )
                  & #authorizeUser
                  .~ authorizeWithEn clientEnv
                  & #forwardAuthorized
                  .~ (\_ host _ _ -> modifyIORef' reached (<> [host]) >> pure (textResponse status200 "proxied"))
              ask token host = runSession (request (withHeader hHost (TE.encodeUtf8 host) (withHeader "Authorization" ("Bearer " <> TE.encodeUtf8 token) (setPath defaultRequest "/")))) (appWithRuntime backends services)
          expectations <- forM [(token, host) | token <- map fst tokens, host <- ["a.example.test", "b.example.test"]] $ \(token, host) -> do
            response <- ask token host
            pure ((token, host), simpleStatus response)
          expectations
            @?= [ (("alice-token", "a.example.test"), status200)
                , (("alice-token", "b.example.test"), status403)
                , (("bob-token", "a.example.test"), status403)
                , (("bob-token", "b.example.test"), status200)
                , (("carol-token", "a.example.test"), status403)
                , (("carol-token", "b.example.test"), status403)
                ]
          readIORef reached >>= (@?= ["a.example.test", "b.example.test"])
    , -- Removing the membership is the next fully consistent check's answer:
      -- the same tuples minus one, and the member is a stranger.
      testCase "a removed membership denies on the next check" $
        testWithApplication (pure (teamEnApp (filter (/= memberTuple "engineering" "alice") sites))) $ \enPort -> do
          manager <- HC.newManager HC.defaultManagerSettings
          clientEnv <- either (assertFailure . Text.unpack) pure =<< enClientEnvFromAuthPlane manager (authConfig enPort)
          decision <- authorizeWithEn clientEnv AuthenticatedUser {subject = "alice"} "a.example.test"
          show decision @?= "AuthorizationDecision AccessDenied"
    , -- The cost of a flat-team check, in tuple-store operations and rows,
      -- for the one shape the CLI creates: a host granted to teams, each with
      -- flat user membership. Measured at the pinned En: a member costs three
      -- point probes whatever the team size; a stranger costs a fixed number
      -- of operations per attached team but reads every member of every
      -- attached team once (rows = members x teams + teams). Small teams keep
      -- that cheap, and En's caches plus the gateway TTL bound repeats; the
      -- member drain on a miss is the concrete upstream improvement EP-187
      -- records, not something Nagare works around.
      testCase "a member's check is three point probes; a stranger's reads each attached team's members once" $ do
        measured <- forM [(members, teams) | members <- [10, 100, 1000], teams <- [1, 10]] $ \(members, teams) -> do
          let tuples = flatTeams "a.example.test" teams members
          allowed <- countedCheck tuples "a.example.test" (memberName 1 1)
          stranger <- countedCheck tuples "a.example.test" "stranger"
          pure ((members, teams), allowed, stranger)
        let table = unlines [show shape <> " member=" <> show member <> " stranger=" <> show stranger | (shape, member, stranger) <- measured]
        assertBool table (all (\(_, (allowed, _, _), (denied, _, _)) -> allowed == Allowed && denied == Denied) measured)
        -- A member: three operations, one userset edge per attached team plus the probe hit.
        assertBool ("member cost changed:\n" <> table) (all (\((_, teams), (_, ops, rows), _) -> ops == 3 && rows == teams + 1) measured)
        -- A stranger: operations fixed per attached team, rows every member once.
        assertBool ("stranger rows changed:\n" <> table) (all (\((members, teams), _, (_, _, rows)) -> rows == members * teams + teams) measured)
        let strangerOps teams = [ops | ((_, t), _, (_, ops, _)) <- measured, t == teams]
        assertBool ("stranger operations grew with team size:\n" <> table) (all (== 5) (strangerOps 1) && all (== 23) (strangerOps 10))
    ]
  where
    tokens = [("alice-token", "alice"), ("bob-token", "bob"), ("carol-token", "carol")]
    -- Alice is in engineering, which holds A; Bob is in finance, which holds
    -- B; Carol belongs to no team. These are the exact tuples nagarectl's
    -- reviewed membership and team grant write.
    sites =
      [ memberTuple "engineering" "alice"
      , memberTuple "finance" "bob"
      , teamViewerTuple "a.example.test" "engineering"
      , teamViewerTuple "b.example.test" "finance"
      ]

-- | The bootstrap schema text, verbatim from @cluster/bootstrap/en/configmap.yaml@.
teamSchemaSource :: Text
teamSchemaSource =
  Text.unlines
    [ "object user {}"
    , ""
    , "object group {"
    , "  relation member: user"
    , "}"
    , ""
    , "object app {"
    , "  relation viewer: user, group#member"
    , "  permission access = viewer"
    , "}"
    ]

teamGraph :: ReachabilityGraph
teamGraph = either (error . show) id (parseSchema teamSchemaSource >>= compileSchema)

teamActiveSchema :: ActiveSchema
teamActiveSchema =
  ActiveSchema
    { graph = teamGraph
    , source = teamSchemaSource
    , origin = "nagare-team-test"
    , loadedAt = UTCTime (fromGregorian 2026 10 12) 0
    }

type TeamEffects = '[ConsistencyStore, TupleStore, Error EnError, IOE]

teamEnApp :: [EnTuple.Tuple] -> Wai.Application
teamEnApp tuples =
  EnApi.app env
  where
    env :: Env TeamEffects
    env =
      Env
        { runPorts =
            \_active ->
              runEff
                . runErrorNoCallStack @EnError
                . Kikan.runTupleStoreInMemory tuples
                . Kikan.runConsistencyStoreInMemory
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

authConfig :: Int -> AuthPlaneConfig
authConfig enPort =
  AuthPlaneConfig
    { shomeiUrl = "http://127.0.0.1:1"
    , shomeiIssuer = "shomei"
    , shomeiAudience = "shomei-clients"
    , enUrl = Text.pack ("http://127.0.0.1:" <> show enPort)
    , enApiKey = Nothing
    , cookieDomain = ".example.test"
    , cookieKey = Nothing
    }

-- | @group:<team>#member@user:<user>@, as nagarectl's teamMemberTuple writes it.
memberTuple :: Text -> Text -> EnTuple.Tuple
memberTuple team user =
  EnTuple.Tuple
    { EnTuple.object = ref "group" team
    , EnTuple.relation = EnRaw.RelationName "member"
    , EnTuple.subject = EnTuple.SubjectId (ref "user" user)
    , EnTuple.caveat = Nothing
    }

-- | @app:<host>#viewer@group:<team>#member@, as nagarectl's teamAccessTuple writes it.
teamViewerTuple :: Text -> Text -> EnTuple.Tuple
teamViewerTuple host team =
  EnTuple.Tuple
    { EnTuple.object = ref "app" host
    , EnTuple.relation = EnRaw.RelationName "viewer"
    , EnTuple.subject = EnTuple.SubjectSet (ref "group" team) (EnRaw.RelationName "member")
    , EnTuple.caveat = Nothing
    }

ref :: Text -> Text -> EnTuple.ObjectRef
ref objectType objectId =
  EnTuple.ObjectRef {EnTuple.objectType = EnRaw.ObjectType objectType, EnTuple.objectId = objectId}

memberName :: Int -> Int -> Text
memberName team member = "user-" <> Text.pack (show team) <> "-" <> Text.pack (show member)

-- | @teams@ teams of @members@ users each, every team granted on @host@.
flatTeams :: Text -> Int -> Int -> [EnTuple.Tuple]
flatTeams host teams members =
  [teamViewerTuple host (teamName team) | team <- [1 .. teams]]
    <> [memberTuple (teamName team) (memberName team member) | team <- [1 .. teams], member <- [1 .. members]]
  where
    teamName team = "team-" <> Text.pack (show team)

-- | One fully consistent check of @user@ for @access@ on @host@, with the
-- tuple-store operations and rows it read.
countedCheck :: [EnTuple.Tuple] -> Text -> Text -> IO (CheckDecision, Int, Int)
countedCheck tuples host user = do
  counter <- newIORef (0, 0)
  outcome <-
    runEff
      . runErrorNoCallStack @EnError
      . Kikan.runTupleStoreInMemory tuples
      . Kikan.runConsistencyStoreInMemory
      . countingTupleStore counter
      $ EnCheck.check teamGraph FullyConsistent (CaveatContext mempty) (EnTuple.SubjectId (ref "user" user)) (EnRaw.RelationName "access") (ref "app" host)
  (ops, rows) <- readIORef counter
  case outcome of
    Left err -> assertFailure ("check failed: " <> show err)
    Right result -> pure (result ^. #decision, ops, rows)

-- | Count every tuple-store operation the evaluator issues, and the rows the
-- reads returned, without changing any answer. Each operation is re-sent to
-- the underlying store as the same request.
countingTupleStore :: forall es a. (TupleStore :> es, IOE :> es) => IORef (Int, Int) -> Eff es a -> Eff es a
countingTupleStore counter = interpose $ \_ -> \case
  ReadObjectRelation revision object relation limit cursor -> paged (ReadObjectRelation revision object relation limit cursor)
  ReadStartingWithUser revision query -> paged (ReadStartingWithUser revision query)
  ReadAllTuples revision limit cursor -> paged (ReadAllTuples revision limit cursor)
  ReadRelationships revision filter' limit cursor -> paged (ReadRelationships revision filter' limit cursor)
  ProbeTuples revision object relation subjects -> do
    found <- send (ProbeTuples revision object relation subjects)
    count (length found)
    pure found
  ApplyTupleWrites request' -> counted (ApplyTupleWrites request')
  ReadRelationshipPage revision token filter' page -> counted (ReadRelationshipPage revision token filter' page)
  CountRelationships revision filter' -> counted (CountRelationships revision filter')
  DeleteRelationships filter' -> counted (DeleteRelationships filter')
  ReadChanges from to filter' limit cursor -> counted (ReadChanges from to filter' limit cursor)
  HeadRevision -> counted HeadRevision
  OptimizedRevision -> counted OptimizedRevision
  OldestRetainedXid -> counted OldestRetainedXid
  AdvanceGcHorizon -> counted AdvanceGcHorizon
  ReapDeletedTuples horizon -> counted (ReapDeletedTuples horizon)
  where
    count :: Int -> Eff es ()
    count rows = liftIO (modifyIORef' counter (\(ops, total) -> (ops + 1, total + rows)))
    paged :: TupleStore (Eff es) TuplePage -> Eff es TuplePage
    paged op = do
      page <- send op
      count (length (page ^. #rows))
      pure page
    counted :: TupleStore (Eff es) r -> Eff es r
    counted op = do
      result <- send op
      count 0
      pure result
