-- | EP-202 M3 (AC-4 in the interpreter): app-database members provision,
-- resume after every interruption with their original passwords, refuse
-- drift and a credential the user no longer accepts, rotate one user, and
-- retire one app database, against the interpreter world.
module AppDatabaseWorldSpec (appDatabaseWorldTests) where

import AppDatabaseSpec (Server, alpha, beta, chServer, pgServer, scopeAndNative, scopeOf, snapshot, snapshotWith)
import Control.Exception (try)
import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.IORef
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Database.AppDatabase.Catalog (CatalogGrant (..), CatalogSetting (..), exceptionGrantToken)
import Nagare.Database.AppDatabase.Sql (PasswordHash (..))
import Nagare.Dsl.AppDatabase
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.AppDatabase
import Nagare.Inventory.Adapters.AppDatabaseSessions
import Nagare.Inventory.AppDatabase (quiesceAppDatabaseScope, resumeAppDatabaseScope)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (..), mkOperationId)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store (initializeStore, newMemoryStore)
import Nagare.Inventory.Store qualified as Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (RecoveryClass (VerifyBeforeRetry))
import Nagare.Resource.Types
import Nagare.Test.World.Adversary
import Nagare.Test.World.Adversary qualified as Adversary
import Nagare.Test.World.AppDatabase
import Test.Tasty
import Test.Tasty.HUnit

appDatabaseWorldTests :: TestTree
appDatabaseWorldTests =
  testGroup "AppDatabase world" $
    [ testGroup
        (show engine' <> variant)
        [ testCase "a first apply converges and an unchanged re-plan has no operations" $ do
            (world, ops, members) <- setup engine' declare []
            converge ops members >>= expectRight
            replan ops members >>= (@?= [])
            assertPasswordsOriginal world ops members
        , testCase "every interruption resumes to the declared state with the original password" $ do
            (_, ops, members) <- setup engine' declare []
            converge ops members >>= expectRight
            calls <- countMutations engine' declare
            assertBool "the apply makes mutation calls" (calls > 0)
            forM_ [(n, fault) | n <- [1 .. calls], fault <- [RefusedBeforeEffect, LostAcknowledgement, Interrupt]] $ \(n, fault) -> do
              (world', ops', members', adversary) <- setupWith engine' declare [(Boundary MutateCall n, fault)]
              result <- converge ops' members'
              either (\reason -> assertFailure (show (n, fault) <> ": " <> T.unpack reason)) pure result
              replan ops' members' >>= (@?= [])
              assertPasswordsOriginal world' ops' members'
              left <- unacted <$> readIORef adversary
              assertEqual ("fault placement fired " <> show (n, fault)) [] left
        , testCase "a failed catalog read refuses nothing and the re-plan converges" $ do
            (_, ops, members, adversary) <- setupWith engine' declare [(Boundary ObserveCall 1, TransientReadFailure)]
            converge ops members >>= expectRight
            unacted <$> readIORef adversary >>= (@?= [])
        , testCase "access Nagare never grants refuses as drift" $ do
            (world, ops, members) <- setup engine' declare []
            converge ops members >>= expectRight
            modifyIORef' world (seedDrift engine')
            refusals <- observeAll ops members
            assertBool (show refusals) (any (T.isPrefixOf grantDriftCode) refusals)
        , testCase "a Secret the user no longer accepts refuses until rotation" $ do
            (world, ops, members) <- setup engine' declare []
            converge ops members >>= expectRight
            modifyIORef' world (#secrets %~ Map.map (#password .~ "replaced-out-of-band"))
            refusals <- observeAll ops members
            assertBool (show refusals) (any (T.isPrefixOf credentialMissingCode) refusals)
        , testCase "rotation changes only the selected user of the selected app database" $ do
            (world, ops, members) <- setup engine' declare []
            converge ops members >>= expectRight
            before <- readIORef world
            let runtime = userMember members "alpha" "runtime"
            rotate ops members runtime >>= expectRight
            after <- readIORef world
            let changedSecrets = Map.keys (Map.differenceWith (\a b -> if a == b then Nothing else Just a) (after ^. #secrets) (before ^. #secrets))
                changedUsers = Map.keys (Map.differenceWith (\a b -> if a == b then Nothing else Just a) (after ^. #users) (before ^. #users))
            changedSecrets @?= ["personal/alpha-" <> suffix engine' <> "-runtime"]
            changedUsers @?= ["alpha_" <> suffix engine' <> "_runtime"]
            let unchanged u = u & #password .~ PostgresVerifier ""
            Map.map unchanged (after ^. #users) @?= Map.map unchanged (before ^. #users)
            after ^. #databases @?= before ^. #databases
            assertPasswordsCurrent ops members
        , testCase "retiring alpha turns its access off and leaves beta byte-identical" $ do
            (world, ops, members) <- setup engine' declare []
            converge ops members >>= expectRight
            before <- readIORef world
            let retired = Map.map (\member -> if isAlpha member then retire member else member) members
            converge ops retired >>= expectRight
            replan ops retired >>= (@?= [])
            after <- readIORef world
            let betaOnly = Map.filterWithKey (\name _ -> "beta" `T.isPrefixOf` name)
            betaOnly (after ^. #users) @?= betaOnly (before ^. #users)
            betaOnly (after ^. #databases) @?= betaOnly (before ^. #databases)
            [u ^. #login | (name, u) <- Map.toList (after ^. #users), "alpha" `T.isPrefixOf` name] @?= [False, False]
            after ^. #secrets @?= before ^. #secrets
            -- Retirement revokes the exceptions; the limits stay declared.
            [g | (name, u) <- Map.toList (after ^. #users), "alpha" `T.isPrefixOf` name, g <- u ^. #serverGrants, g `elem` exceptionTokens] @?= []
            Map.map limitsOf (Map.filterWithKey (\name _ -> "alpha" `T.isPrefixOf` name) (after ^. #users))
              @?= Map.map limitsOf (Map.filterWithKey (\name _ -> "alpha" `T.isPrefixOf` name) (before ^. #users))
        , testCase "after a server rebuild a re-apply recreates the declared catalog with the retained passwords (M6)" $ do
            (world, ops, members) <- setup engine' declare []
            converge ops members >>= expectRight
            before <- readIORef world
            modifyIORef' world (\w -> w & #users .~ Map.empty & #databases .~ Map.empty & #publicSystemAccess .~ (engine' == Postgres))
            converge ops members >>= expectRight
            replan ops members >>= (@?= [])
            after <- readIORef world
            Map.keys (after ^. #users) @?= Map.keys (before ^. #users)
            Map.map (^. #grants) (after ^. #databases) @?= Map.map (^. #grants) (before ^. #databases)
            assertPasswordsOriginal world ops members
        ]
    | engine' <- [Postgres, ClickHouse]
    , (variant, declare) <- [("", id), (" with declared access", declaredAccess engine')]
    ]
      <> [testGroup (show engine' <> " reviewed access (EP-204)") (accessTests engine') | engine' <- [Postgres, ClickHouse]]
      <> [testGroup (show engine' <> " quiesce (EP-205)") (quiesceTests engine') | engine' <- [Postgres, ClickHouse]]
  where
    expectRight = either (assertFailure . T.unpack) pure

-- EP-204 ------------------------------------------------------------------

-- | alpha's reviewed access: exceptions and ceilings on ClickHouse, limits
-- and a tolerated pg_monitor on PostgreSQL.
declaredAccess :: Engine -> AppDatabase -> AppDatabase
declaredAccess Postgres db =
  db
    & #access
    . #monitoring
    .~ [PgMonitor]
    & #access
    . #runtime
    . #limits
    .~ (noUserLimits & #connectionLimit ?~ 3 & #statementTimeoutSeconds ?~ 30)
    & #access
    . #migration
    . #limits
    .~ (noUserLimits & #connectionLimit ?~ 5)
declaredAccess _ db =
  db
    & #access
    . #runtime
    .~ UserAccess [SystemParts, SystemStoragePolicies, ArbitraryTemporaryTables] (ceilings 268435456 5 2)
    & #access
    . #migration
    .~ UserAccess [SystemDisks] (ceilings 1073741824 600 4)
  where
    ceilings memory seconds queries = noUserLimits & #maxMemoryBytes ?~ memory & #maxExecutionSeconds ?~ seconds & #maxConcurrentQueries ?~ queries

-- | A declaration change under review: a ceiling changed, an exception and
-- the statement timeout removed.
changedAccess :: Engine -> AppDatabase -> AppDatabase
changedAccess Postgres db =
  declaredAccess Postgres db & #access . #runtime . #limits .~ (noUserLimits & #connectionLimit ?~ 4)
changedAccess engine' db =
  declaredAccess engine' db
    & #access
    . #runtime
    . #exceptions
    .~ [SystemStoragePolicies, ArbitraryTemporaryTables]
    & #access
    . #runtime
    . #limits
    . #maxExecutionSeconds
    ?~ 9

exceptionTokens :: [Text]
exceptionTokens = map exceptionGrantToken [minBound .. maxBound]

limitsOf :: WorldUser -> ([CatalogSetting], [Text], Int, [Text])
limitsOf u = (u ^. #settings, u ^. #inheritedProfiles, u ^. #connectionLimit, u ^. #roleSettings)

user' :: Engine -> Text -> Text -> Text
user' engine' app role = app <> "_" <> suffix engine' <> "_" <> role

-- | What PGMQ's install leaves in alpha's database when its migration user
-- runs it (M1): a schema it owns, read by pg_monitor.
seedPgmq :: World -> World
seedPgmq world = world & #databases %~ Map.adjust pgmq "alpha"
  where
    migration = user' Postgres "alpha" "migration"
    runtime = user' Postgres "alpha" "runtime"
    pgmq db =
      db
        & #otherSchemas
        %~ Map.insert "pgmq" migration
        & #grants
        %~ Set.union
          ( Set.fromList
              [ CatalogGrant migration "schema:pgmq" "USAGE"
              , CatalogGrant migration "schema:pgmq" "CREATE"
              , CatalogGrant runtime "schema:pgmq" "USAGE"
              , CatalogGrant "pg_monitor" "schema:pgmq" "USAGE"
              , CatalogGrant "pg_monitor" "default-tables" "SELECT"
              , CatalogGrant "pg_monitor" "default-sequences" "SELECT"
              ]
          )

-- | Hand changes outside both declarations: each is drift.
handDrift :: Engine -> [(String, World -> World)]
handDrift Postgres =
  [ ("CONNECTION LIMIT 10 on alpha's runtime", onUser (user' Postgres "alpha" "runtime") (#connectionLimit .~ 10))
  , ("SET statement_timeout = 0 on alpha's runtime", onUser (user' Postgres "alpha" "runtime") (#roleSettings .~ ["statement_timeout=0"]))
  , ("CONNECTION LIMIT 4 on beta's runtime", onUser (user' Postgres "beta" "runtime") (#connectionLimit .~ 4))
  , ("SET work_mem on beta's migration", onUser (user' Postgres "beta" "migration") (#roleSettings .~ ["work_mem=1GB"]))
  ]
handDrift engine' =
  [ ("SETTINGS max_memory_usage = 0 on alpha's runtime", onUser (user' engine' "alpha" "runtime") (#settings .~ [CatalogSetting "max_memory_usage" (Just "0") Nothing Nothing Nothing]))
  , ("SETTINGS PROFILE default on alpha's runtime", onUser (user' engine' "alpha" "runtime") (#inheritedProfiles .~ ["default"]))
  , ("GRANT SELECT ON system.mutations to alpha's migration", onUser (user' engine' "alpha" "migration") (#serverGrants %~ ("SELECT ON system.mutations" :)))
  , ("GRANT SELECT ON system.parts to beta's runtime", onUser (user' engine' "beta" "runtime") (#serverGrants %~ ("SELECT ON system.parts" :)))
  , ("SETTINGS max_memory_usage on beta's runtime", onUser (user' engine' "beta" "runtime") (#settings .~ [CatalogSetting "max_memory_usage" (Just "1") (Just "1") (Just "1") Nothing]))
  ]

-- | Hand removals of declared items: the next plan restores each.
handRemoval :: Engine -> [(String, World -> World)]
handRemoval Postgres =
  [ ("CONNECTION LIMIT -1 on alpha's runtime", onUser (user' Postgres "alpha" "runtime") (#connectionLimit .~ (-1)))
  , ("RESET statement_timeout on alpha's runtime", onUser (user' Postgres "alpha" "runtime") (#roleSettings .~ []))
  ]
handRemoval engine' =
  [ ("SETTINGS NONE on alpha's runtime", onUser (user' engine' "alpha" "runtime") (#settings .~ []))
  , ("REVOKE SELECT ON system.parts from alpha's runtime", onUser (user' engine' "alpha" "runtime") (#serverGrants %~ filter (/= "SELECT ON system.parts")))
  , ("REVOKE SELECT ON system.disks from alpha's migration", onUser (user' engine' "alpha" "migration") (#serverGrants %~ filter (/= "SELECT ON system.disks")))
  ]

onUser :: Text -> (WorldUser -> WorldUser) -> World -> World
onUser name f = #users %~ Map.adjust f name

accessTests :: Engine -> [TestTree]
accessTests engine' =
  [ testCase "a hand change outside the declaration refuses as drift (IR-32 AC-4)" $ do
      (world, ops, members) <- setup engine' (declaredAccess engine') []
      converge ops members >>= expectRight
      converged <- readIORef world
      forM_ (handDrift engine') $ \(label, change) -> do
        writeIORef world (change converged)
        refusals <- observeAll ops members
        assertBool (label <> ": " <> show refusals) (any (T.isPrefixOf grantDriftCode) refusals)
  , testCase "a hand removal is restored by the next plan (IR-32 AC-4)" $ do
      (world, ops, members) <- setup engine' (declaredAccess engine') []
      converge ops members >>= expectRight
      converged <- readIORef world
      forM_ (handRemoval engine') $ \(label, change) -> do
        writeIORef world (change converged)
        planned' <- replan ops members
        assertBool (label <> ": the re-plan updates the user") (not (null planned'))
        converge ops members >>= expectRight
        replan ops members >>= (@?= [])
        after <- readIORef world
        assertEqual label (converged ^. #users) (after ^. #users)
  , testCase "the reviewed operation names each declared exception and limit (IR-30 AC-1)" $ do
      members <- membersFor engine' (declaredAccess engine')
      (_, ops, _) <- setup engine' (declaredAccess engine') []
      let runtime = userMember members "alpha" "runtime"
      prepared <- adapterPrepare (adapterFor ops members) (planned UpdateResource runtime)
      summary <- either (assertFailure . show) (pure . preparedPublicSummary) prepared
      let expected =
            if engine' == Postgres
              then ["limits connectionLimit 3, statementTimeoutSeconds 30"]
              else ["exceptions system-parts, system-storage-policies, arbitrary-temporary-tables", "maxMemoryBytes 268435456", "maxExecutionSeconds 5", "maxConcurrentQueries 2"]
      forM_ expected $ \needle -> assertBool (T.unpack summary) (needle `T.isInfixOf` summary)
  , testCase "a changed ceiling or a removed exception plans an update that resets or revokes it (IR-30 AC-5)" $ do
      (world, ops, before) <- setup engine' (declaredAccess engine') []
      converge ops before >>= expectRight
      after <- membersFor engine' (changedAccess engine')
      let runtime = userMember after "alpha" "runtime"
      replanAgainst before ops after >>= (@?= [runtime])
      -- Without the accepted declaration the old values are access Nagare
      -- never reviewed, so they refuse rather than converge.
      refusals <- observeAll ops after
      assertBool (show refusals) (any (T.isPrefixOf grantDriftCode) refusals)
      convergeAgainst before ops after >>= expectRight
      replan ops after >>= (@?= [])
      u <- (Map.! user' engine' "alpha" "runtime") . (^. #users) <$> readIORef world
      if engine' == Postgres
        then (u ^. #connectionLimit, u ^. #roleSettings) @?= (4, [])
        else do
          assertBool "system.parts is revoked" ("SELECT ON system.parts" `notElem` u ^. #serverGrants)
          [(s ^. #name, s ^. #value) | s <- u ^. #settings, s ^. #name == "max_execution_time"] @?= [("max_execution_time", Just "9")]
  ]
    <> [ testCase "PGMQ's grants to a declared pg_monitor are not drift, survive rotation, retirement and a rebuild; undeclared they refuse (IR-30 AC-4)" $ do
           (world, ops, members) <- setup engine' (declaredAccess engine') []
           converge ops members >>= expectRight
           modifyIORef' world seedPgmq
           replan ops members >>= (@?= [])
           rotate ops members (userMember members "alpha" "runtime") >>= expectRight
           replan ops members >>= (@?= [])
           plain <- membersFor engine' id
           refusals <- observeAll ops plain
           assertBool (show refusals) (any (\r -> grantDriftCode `T.isPrefixOf` r && "pg_monitor" `T.isInfixOf` r) refusals)
           let retired = Map.map (\member -> if isAlpha member then retire member else member) members
           converge ops retired >>= expectRight
           replan ops retired >>= (@?= [])
           -- A rebuilt server: re-apply, then the dump brings the grants back.
           modifyIORef' world (\w -> w & #users .~ Map.empty & #databases .~ Map.empty & #publicSystemAccess .~ True)
           converge ops members >>= expectRight
           modifyIORef' world seedPgmq
           replan ops members >>= (@?= [])
       | engine' == Postgres
       ]
    <> [ testCase "a plan refusal names the drift and the undeclared grant; other providers stay redacted (IR-30 AC-4)" $ do
           (world, ops, declared) <- setup engine' (declaredAccess engine') []
           converge ops declared >>= expectRight
           modifyIORef' world seedPgmq
           plain <- membersFor engine' id
           store <- newMemoryStore
           let accepted = snapshot [pgServer]
               candidate = either (error . show) id (composeInventory accepted (ReplaceScope (scopeOf pgServer (alpha engine')) :| []))
           initializeStore store (inventoryBinding (candidateInventory candidate)) "app-database" >>= either (assertFailure . show) (const (pure ()))
           seedInventoryHistory store candidate >>= either (assertFailure . show) (const (pure ()))
           planning <- loadInventoryPlanningHistory store candidate >>= either (assertFailure . show) pure
           let byExecutor = requirementsByExecutor (observationRequirements candidate planning)
           ours <- adapterObserve (adapterFor ops plain) (Map.findWithDefault [] AppDatabaseExecutor byExecutor) >>= either (assertFailure . T.unpack) pure
           let others = [(r, ObservationUnavailable "private provider stderr") | (executor', rs) <- Map.toList byExecutor, executor' /= AppDatabaseExecutor, r <- rs]
               observed = either (error . T.unpack) id (observationSet (Map.toList (observationMap ours) <> others))
           case planChanges candidate noLifecycleDecisions planning observed of
             Right _ -> assertFailure "undeclared pg_monitor grants were planned"
             Left errors -> do
               let rendered = renderPlanErrors errors
               assertBool (T.unpack rendered) (grantDriftCode `T.isInfixOf` rendered && "pg_monitor" `T.isInfixOf` rendered)
               assertBool (T.unpack rendered) (not ("private provider stderr" `T.isInfixOf` rendered))
       | engine' == Postgres
       ]
  where
    expectRight = either (assertFailure . T.unpack) pure

-- EP-205 ------------------------------------------------------------------

-- | One quiesce or resume under review: the members before and after, and
-- the session step's binding and planned operation.
data SessionReview = SessionReview
  { before :: !Members
  , after :: !Members
  , bindings :: !(Map ContentDigest SessionBinding)
  , operation :: !PlannedOperation
  }
  deriving stock (Generic)

-- | The members a review resolves, as the CLI does: accepted history first,
-- then the review's own declarations of the server, alpha and beta.
membersOfScope :: Engine -> Members -> ScopeDeclaration -> IO Members
membersOfScope engine' accepted alphaScope =
  either (assertFailure . T.unpack) pure $
    appDatabaseMembersFromDeclarations
      ( map (Managed . (^. #declaration)) (Map.elems accepted)
          <> concat [declarationsOf scope | scope <- [fst (serverOf engine'), alphaScope, scopeOf (serverOf engine') (beta engine')]]
      )

sessionAdapter :: AppDatabaseOps -> SessionReview -> Adapter
sessionAdapter ops review = withAppDatabaseSessions (review ^. #bindings) (review ^. #after) ops (adapterAgainst (review ^. #before) ops (review ^. #after))

-- | Apply a reviewed quiesce or resume: the member changes, then the step.
applySession :: AppDatabaseOps -> SessionReview -> IO (Either Text ())
applySession ops review = do
  changed <- convergeAgainst (review ^. #before) ops (review ^. #after)
  case changed of
    Left reason -> pure (Left reason)
    Right () -> effect (sessionAdapter ops review) (review ^. #operation)

-- | alpha's scope and accepted native bytes, quiesced with the given users.
quiesceAlpha :: Engine -> [Text] -> IO (ScopeDeclaration, Map ResourceId (ManagedResource, BS.ByteString), ScopeDeclaration, Map ResourceId (ManagedResource, BS.ByteString))
quiesceAlpha engine' roles = do
  let (scope, native) = scopeAndNative (serverOf engine') (alpha engine')
  (quiesced, paused) <- either (assertFailure . show) pure (quiesceAppDatabaseScope native scope roles "t1")
  pure (scope, native, quiesced, Map.union paused native)

-- | Quiesce alpha's runtime user, drain, then resume: the world after each.
quiesceCycle :: Engine -> IORef World -> AppDatabaseOps -> Members -> IO (Either Text (World, World))
quiesceCycle engine' world ops open = do
  (_, _, quiesced, nativeQuiesced) <- quiesceAlpha engine' ["runtime"]
  drain <- sessionReviewFor engine' open quiesced DrainStep
  drained <- applySession ops drain
  case drained of
    Left reason -> pure (Left reason)
    Right () -> do
      during <- readIORef world
      (resumed, _) <- either (assertFailure . show) pure (resumeAppDatabaseScope nativeQuiesced quiesced "t2")
      resume <- sessionReviewFor engine' (drain ^. #after) resumed ResumeStep
      resumedResult <- applySession ops resume
      afterResume <- readIORef world
      pure ((during, afterResume) <$ resumedResult)

sessionReviewFor :: Engine -> Members -> ScopeDeclaration -> SessionStep -> IO SessionReview
sessionReviewFor engine' before' revised step' = do
  after' <- membersOfScope engine' before' revised
  bindings' <- either (assertFailure . T.unpack) pure (sessionBindings [revised])
  (digest, binding) <- case [(d, b) | (d, b) <- Map.toList bindings', b ^. #step == step'] of
    [single] -> pure single
    other -> assertFailure ("expected one session step: " <> show other) >> fail "step"
  pure (SessionReview before' after' (Map.singleton digest binding) (PlannedOperation (either (error . T.unpack) id (mkOperationId "op-session")) RunDeclaredOperation AppDatabaseExecutor (binding ^. #member :| []) digest [] VerifyBeforeRetry))

-- | The catalog state a quiesce must give back: logins, grants, settings
-- and limits of every user, and every database's grants.
catalogAccess :: World -> (Map Text (Bool, [Text], [CatalogSetting], Int, [Text]), Map Text (Set.Set CatalogGrant))
catalogAccess world =
  ( Map.map (\u -> (u ^. #login, sort (u ^. #serverGrants), u ^. #settings, u ^. #connectionLimit, u ^. #roleSettings)) (world ^. #users)
  , Map.map (^. #grants) (world ^. #databases)
  )

quiesceTests :: Engine -> [TestTree]
quiesceTests engine' =
  [ testCase "quiesce ends alpha's work and blocks its logins; beta, the server and the grants come back unchanged (IR-31 AC-1, AC-2)" $ do
      (world, ops, open) <- setup engine' id []
      converge ops open >>= expectRight
      let alphaRuntime = user' engine' "alpha" "runtime"
          betaRuntime = user' engine' "beta" "runtime"
      modifyIORef' world (#sessions .~ Map.fromList [(alphaRuntime, 2), (betaRuntime, 1)])
      before' <- readIORef world
      result <- quiesceCycle engine' world ops open
      (during, after') <- either (assertFailure . T.unpack) pure result
      Map.lookup alphaRuntime (during ^. #sessions) @?= Just 0
      Map.lookup betaRuntime (during ^. #sessions) @?= Just 1
      (^. #login) <$> Map.lookup alphaRuntime (during ^. #users) @?= Just False
      (^. #login) <$> Map.lookup (user' engine' "alpha" "migration") (during ^. #users) @?= Just True
      during ^. #server @?= before' ^. #server
      let betaOnly = Map.filterWithKey (\name _ -> "beta" `T.isPrefixOf` name)
      betaOnly (during ^. #users) @?= betaOnly (before' ^. #users)
      betaOnly (during ^. #databases) @?= betaOnly (before' ^. #databases)
      let grantsOf who w = sort [g | db <- Map.elems (w ^. #databases), g <- Set.toList (db ^. #grants), g ^. #grantee == who]
      if engine' == ClickHouse
        then do
          -- An open native session outlives a login change, not a grant change.
          grantsOf alphaRuntime during @?= []
          grantsOf (user' engine' "alpha" "migration") during @?= grantsOf (user' engine' "alpha" "migration") before'
        else grantsOf alphaRuntime during @?= grantsOf alphaRuntime before'
      catalogAccess after' @?= catalogAccess before'
  , testCase "the drain waits out a scheduled run in flight and times out on one that never ends (IR-31 AC-4)" $ do
      (world, ops, open) <- setup engine' id []
      converge ops open >>= expectRight
      modifyIORef' world (#activeRuns .~ 5)
      quiesceCycle engine' world ops open >>= expectRight . fmap (const ())
      (^. #activeRuns) <$> readIORef world >>= (@?= 0)
      (world', ops', open') <- setup engine' id []
      converge ops' open' >>= expectRight
      modifyIORef' world' (#activeRuns .~ (drainTimeoutTicks + 10))
      result <- quiesceCycle engine' world' ops' open'
      case result of
        Left reason -> assertBool (T.unpack reason) ("timed out" `T.isInfixOf` reason && "scheduled backup run" `T.isInfixOf` reason)
        Right _ -> assertFailure "a drain finished with a scheduled run still in flight"
  , testCase "a server restarted after review fails the drain's preflight" $ do
      (world, ops, open) <- setup engine' id []
      converge ops open >>= expectRight
      (_, _, quiesced, _) <- quiesceAlpha engine' ["runtime"]
      drain <- sessionReviewFor engine' open quiesced DrainStep
      convergeAgainst open ops (drain ^. #after) >>= expectRight
      let adapter = sessionAdapter ops drain
      prepared <- adapterPrepare adapter (drain ^. #operation) >>= either (assertFailure . show) pure
      modifyIORef' world (#server %~ Map.insert "podStarted" "2026-10-19T01:00:00Z")
      adapterPreflight adapter (drain ^. #operation) prepared >>= \case
        Left reason -> assertBool (T.unpack reason) ("server identity differs" `T.isInfixOf` reason)
        Right () -> assertFailure "a restarted server passed the drain's preflight"
  , testCase "every fault during quiesce, drain and resume ends in the same state" $ do
      (world, ops, open, adversary) <- setupWith engine' id []
      converge ops open >>= expectRight
      start <- readIORef world
      before' <- counts <$> readIORef adversary
      modifyIORef' world (#sessions .~ Map.fromList [(user' engine' "alpha" "runtime", 1)])
      expected <- quiesceCycle engine' world ops open >>= either (assertFailure . T.unpack) pure
      calls <- (\after' -> Map.findWithDefault 0 MutateCall after' - Map.findWithDefault 0 MutateCall before') . counts <$> readIORef adversary
      assertBool "the cycle makes mutation calls" (calls > 0)
      forM_ [(n, fault) | n <- [1 .. calls], fault <- [RefusedBeforeEffect, LostAcknowledgement, Interrupt]] $ \(n, fault) -> do
        (world', ops', open', adversary') <- setupWith engine' id []
        converge ops' open' >>= expectRight
        used <- Map.findWithDefault 0 MutateCall . counts <$> readIORef adversary'
        modifyIORef' adversary' (\a -> a {Adversary.schedule = [(Boundary MutateCall (used + n), fault)]})
        modifyIORef' world' (#sessions .~ Map.fromList [(user' engine' "alpha" "runtime", 1)])
        got <- quiesceCycle engine' world' ops' open'
        either (\reason -> assertFailure (show (n, fault) <> ": " <> T.unpack reason)) (\(_, final) -> catalogAccess final @?= catalogAccess (snd expected)) got
        left <- unacted <$> readIORef adversary'
        assertEqual ("fault placement fired " <> show (n, fault)) [] left
        catalogAccess (snd expected) @?= catalogAccess start
  ]
    <> [ testCase "the reviewed drain is ordered after the schedule's suspension (IR-31 AC-4)" $ do
           (world, ops, open) <- setup engine' id []
           converge ops open >>= expectRight
           _ <- readIORef world
           (_, _, quiesced, _) <- quiesceAlpha engine' ["runtime"]
           drain <- sessionReviewFor engine' open quiesced DrainStep
           store <- newMemoryStore
           let ok' :: (Show e) => Either e a -> a
               ok' = either (error . show) id
               accepted0 = snapshotWith [serverOf engine'] [scopeOf (serverOf engine') (alpha engine')]
               -- The seed accepts the snapshot's scopes as they are.
               openCandidate = ok' (composeInventory accepted0 (ReplaceScope (ok' (mkScopeDeclaration (ok' (mkScopeId Standalone "dummy")) [])) :| []))
           initializeStore store (inventoryBinding (candidateInventory openCandidate)) "app-database" >>= either (assertFailure . show) (const (pure ()))
           seedInventoryHistory store openCandidate >>= either (assertFailure . show) (const (pure ()))
           history <- loadInventoryHistory store >>= either (assertFailure . show) pure
           let accepted1 = ok' (mkScopeSnapshot (inventoryBinding (candidateInventory openCandidate)) (Map.map (\(revision, declared) -> (Store.revisionGeneration revision, declared)) (historyAccepted history)) (historyReservations history))
               candidate = ok' (composeInventory accepted1 (ReplaceScope quiesced :| []))
           planning <- loadInventoryPlanningHistory store candidate >>= either (assertFailure . show) pure
           let byExecutor = requirementsByExecutor (observationRequirements candidate planning)
           ours <- adapterObserve (sessionAdapter ops drain) (Map.findWithDefault [] AppDatabaseExecutor byExecutor) >>= either (assertFailure . T.unpack) pure
           let others = [(r, ObservedPresent (ok' (mkPhysicalIdentity ("uid-" <> T.filter (`elem` ['a' .. 'z']) (resourceIdText r))))) | (executor', rs) <- Map.toList byExecutor, executor' /= AppDatabaseExecutor, r <- rs]
               observed = ok' (observationSet (Map.toList (observationMap ours) <> others))
           proposal <- either (assertFailure . show) pure (planChanges candidate noLifecycleDecisions planning observed)
           let operations' = proposalOperations proposal
               cron = [plannedOperationId o | o <- operations', any (\r -> "/backup" `T.isSuffixOf` resourceIdText r) (NE.toList (plannedResources o))]
               drains = [o | o <- operations', plannedAction o == RunDeclaredOperation]
           assertBool ("the schedule's suspension is planned: " <> show (map plannedResources operations')) (not (null cron))
           case drains of
             [drained] -> assertBool "the drain waits for the suspension" (all (`elem` plannedDependencies drained) cron)
             other -> assertFailure ("expected one drain: " <> show (length other))
       ]
    <> [ testCase "the drain waits for the app's mutations and refuses a failed one by name (IR-31 AC-3)" $ do
           (world, ops, open) <- setup engine' id []
           converge ops open >>= expectRight
           modifyIORef' world (#mutations .~ [WorldMutation "alpha" "t" "mutation_1.txt" 3 Nothing, WorldMutation "beta" "t" "mutation_1.txt" 1000 Nothing])
           quiesceCycle engine' world ops open >>= expectRight . fmap (const ())
           (world', ops', open') <- setup engine' id []
           converge ops' open' >>= expectRight
           modifyIORef' world' (#mutations .~ [WorldMutation "alpha_ledger" "l" "mutation_2.txt" 0 (Just "Code: 395. failing")])
           result <- quiesceCycle engine' world' ops' open'
           case result of
             Left reason -> assertBool (T.unpack reason) ("alpha_ledger.l mutation_2.txt: Code: 395" `T.isInfixOf` reason)
             Right _ -> assertFailure "a drain finished over a failed mutation"
       | engine' == ClickHouse
       ]
  where
    expectRight = either (assertFailure . T.unpack) pure

suffix :: Engine -> Text
suffix Postgres = "pg"
suffix _ = "ch"

-- Fixtures ------------------------------------------------------------------

type Members = Map ResourceId AppDatabaseMember

setup :: Engine -> (AppDatabase -> AppDatabase) -> [(Boundary, Fault)] -> IO (IORef World, AppDatabaseOps, Members)
setup engine' declare faults = do
  (world, ops, members, _) <- setupWith engine' declare faults
  pure (world, ops, members)

-- | The resolved members of alpha, declared with the given access, and beta.
membersFor :: Engine -> (AppDatabase -> AppDatabase) -> IO Members
membersFor engine' declare = do
  let server' = serverOf engine'
      declarations = concat [declarationsOf scope | scope <- fst server' : map (scopeOf server') [declare (alpha engine'), beta engine']]
  either (assertFailure . T.unpack) pure (appDatabaseMembersFromDeclarations declarations)

-- | alpha, declared with the given access, and beta on one server, their
-- Secrets already created (the Kubernetes adapter creates them before the
-- users, which depend on them).
setupWith :: Engine -> (AppDatabase -> AppDatabase) -> [(Boundary, Fault)] -> IO (IORef World, AppDatabaseOps, Members, IORef Adversary)
setupWith engine' declare faults = do
  members <- membersFor engine' declare
  let secrets' =
        Map.fromList
          [ (secretKey namespace' secretName, CredentialSecret ("pw-" <> user) (firstDatabase member))
          | member <- Map.elems members
          , UserMember _ user namespace' secretName _ <- [member ^. #kind]
          ]
  world <- newWorld engine' secrets'
  adversary <- newAdversary faults
  pure (world, worldOps world adversary, members, adversary)
  where
    firstDatabase member = case member ^. #scopeDatabases of
      db : _ -> db
      [] -> ""

serverOf :: Engine -> Server
serverOf Postgres = pgServer
serverOf _ = chServer

declarationsOf :: ScopeDeclaration -> [Declaration]
declarationsOf scope = [declaration | bundle <- scopeBundles scope, declaration <- declarations bundle]

isAlpha :: AppDatabaseMember -> Bool
isAlpha member = "appdb-alpha" `T.isPrefixOf` nameText (scopeName (member ^. #declaration . #owner))

retire :: AppDatabaseMember -> AppDatabaseMember
retire member = member & #enabled .~ False

userMember :: Members -> Text -> Text -> ResourceId
userMember members app role =
  head
    [ resource
    | (resource, member) <- Map.toList members
    , UserMember _ user _ _ _ <- [member ^. #kind]
    , (app <> "_") `T.isPrefixOf` user
    , ("_" <> role) `T.isSuffixOf` user
    ]

seedDrift :: Engine -> World -> World
seedDrift Postgres world = world & #users %~ Map.adjust (#elevated .~ ["SUPERUSER"]) "alpha_pg_runtime"
seedDrift _ world = world & #users %~ Map.adjust (#serverGrants %~ ("SELECT" :)) "alpha_ch_runtime"

-- Driver --------------------------------------------------------------------

-- | Users before databases, as their dependencies order them.
ordered :: Members -> [ResourceId]
ordered members = [r | (r, m) <- Map.toList members, isUser m] <> [r | (r, m) <- Map.toList members, not (isUser m)]
  where
    isUser m = case m ^. #kind of
      UserMember {} -> True
      _ -> False

adapterFor :: AppDatabaseOps -> Members -> Adapter
adapterFor ops members = adapterAgainst members ops members

-- | The adapter for the desired members with accepted history from another
-- set of members: a declaration change under review.
adapterAgainst :: Members -> AppDatabaseOps -> Members -> Adapter
adapterAgainst accepted ops members = mkAppDatabaseAdapter (Map.map (^. #declaration) accepted) members ops

-- | Observe each member, act as the planner would, and recover after an
-- ambiguous effect or a killed executor as a resume would.
converge :: AppDatabaseOps -> Members -> IO (Either Text ())
converge ops members = convergeAgainst members ops members

convergeAgainst :: Members -> AppDatabaseOps -> Members -> IO (Either Text ())
convergeAgainst accepted ops members = go (ordered members)
  where
    adapter = adapterAgainst accepted ops members
    go [] = pure (Right ())
    go (resource : rest) = do
      fact <- observeOne adapter resource (3 :: Int)
      step <- case fact of
        Left reason -> pure (Left reason)
        Right (ConfirmedAbsent _) -> effect adapter (planned CreateResource resource)
        Right (ObservedDrifted _ _) -> effect adapter (planned UpdateResource resource)
        Right (ObservedPresent _) -> pure (Right ())
        Right other -> pure (Left ("unexpected observation " <> T.pack (show other)))
      either (pure . Left) (const (go rest)) step

rotate :: AppDatabaseOps -> Members -> ResourceId -> IO (Either Text ())
rotate ops members resource = effect (adapterFor ops members) (planned RunDeclaredOperation resource)

observeOne :: Adapter -> ResourceId -> Int -> IO (Either Text ResourceObservation)
observeOne adapter resource attempts = do
  observed <- adapterObserve adapter [resource]
  case observationMap <$> observed of
    Right facts
      | Just (ObservationUnavailable reason) <- Map.lookup resource facts
      , "injected" `T.isPrefixOf` reason
      , attempts > 1 ->
          observeOne adapter resource (attempts - 1)
      | Just (ObservationUnavailable reason) <- Map.lookup resource facts -> pure (Left reason)
      | Just fact <- Map.lookup resource facts -> pure (Right fact)
    Right _ -> pure (Left "member was not observed")
    Left reason -> pure (Left reason)

effect :: Adapter -> PlannedOperation -> IO (Either Text ())
effect adapter operation = do
  prepared <- adapterPrepare adapter operation
  case prepared of
    Left err -> pure (Left (T.pack (show err)))
    Right native -> do
      preflight <- adapterPreflight adapter operation native
      case preflight of
        Left reason -> pure (Left reason)
        Right () -> attempt native (5 :: Int)
  where
    attempt native remaining = do
      result <- try (adapterExecute adapter operation native)
      case result of
        Right AdapterEffectCompleted -> verified native
        Right (AdapterEffectIdentified _ inner) -> settle native remaining inner
        Right (AdapterEffectFailed (KnownNoEffect reason)) -> pure (Left reason)
        Right other -> settle native remaining other
        Left Interrupted -> recover native remaining
    settle native remaining = \case
      AdapterEffectCompleted -> verified native
      AdapterEffectFailed (KnownNoEffect reason) -> pure (Left reason)
      _ -> recover native remaining
    recover native remaining = do
      decision <- adapterRecover adapter operation native
      case decision of
        RecoveryProvedComplete _ -> pure (Right ())
        RecoverySafeToRetry | remaining > 0 -> attempt native (remaining - 1)
        other -> pure (Left ("recovery did not settle: " <> T.pack (show other)))
    verified native = either Left (const (Right ())) <$> adapterVerify adapter operation native

planned :: OperationAction -> ResourceId -> PlannedOperation
planned action resource =
  PlannedOperation
    (either (error . T.unpack) id (mkOperationId ("op-" <> T.pack (show (fromEnum' action)) <> "-" <> T.filter (`elem` ['a' .. 'z']) (resourceIdText resource))))
    action
    AppDatabaseExecutor
    (resource :| [])
    (contentDigest "app-database-world")
    []
    VerifyBeforeRetry
  where
    fromEnum' = \case
      CreateResource -> 1 :: Int
      UpdateResource -> 2
      RunDeclaredOperation -> 3
      _ -> 4

-- | The operations a re-plan would carry: anything not observed present.
replan :: AppDatabaseOps -> Members -> IO [ResourceId]
replan ops members = replanAgainst members ops members

replanAgainst :: Members -> AppDatabaseOps -> Members -> IO [ResourceId]
replanAgainst accepted ops members = do
  observed <- adapterObserve (adapterAgainst accepted ops members) (Map.keys members)
  case observationMap <$> observed of
    Right facts -> pure [r | (r, fact) <- Map.toList facts, not (isPresent fact)]
    Left reason -> assertFailure (T.unpack reason)
  where
    isPresent = \case
      ObservedPresent _ -> True
      _ -> False

observeAll :: AppDatabaseOps -> Members -> IO [Text]
observeAll ops members = observeAllAgainst members ops members

observeAllAgainst :: Members -> AppDatabaseOps -> Members -> IO [Text]
observeAllAgainst accepted ops members = do
  observed <- adapterObserve (adapterAgainst accepted ops members) (Map.keys members)
  pure [reason | Right facts <- [observationMap <$> observed], ObservationUnavailable reason <- Map.elems facts]

countMutations :: Engine -> (AppDatabase -> AppDatabase) -> IO Int
countMutations engine' declare = do
  (_, ops, members, adversary) <- setupWith engine' declare []
  _ <- converge ops members
  Map.findWithDefault 0 MutateCall . counts <$> readIORef adversary

-- | Every user accepts its Secret's password, and the Secrets still hold the
-- passwords they were created with.
assertPasswordsOriginal :: IORef World -> AppDatabaseOps -> Members -> Assertion
assertPasswordsOriginal world ops members = do
  current <- readIORef world
  forM_ [(user, namespace', secretName) | m <- Map.elems members, UserMember _ user namespace' secretName _ <- [m ^. #kind]] $ \(user, namespace', secretName) ->
    (^. #password) <$> Map.lookup (secretKey namespace' secretName) (current ^. #secrets) @?= Just ("pw-" <> user)
  assertPasswordsCurrent ops members

assertPasswordsCurrent :: AppDatabaseOps -> Members -> Assertion
assertPasswordsCurrent ops members =
  forM_ [(m, user, namespace', secretName) | m <- Map.elems members, UserMember _ user namespace' secretName _ <- [m ^. #kind]] $ \(m, user, namespace', secretName) -> do
    secret <- readCredential ops namespace' secretName
    case secret of
      Right (Just credential) -> passwordMatches ops (m ^. #server) user (credential ^. #password) >>= (@?= Right True)
      other -> assertFailure ("credential unreadable: " <> show other)
