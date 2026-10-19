-- | EP-202 M3 (AC-4 in the interpreter): app-database members provision,
-- resume after every interruption with their original passwords, refuse
-- drift and a credential the user no longer accepts, rotate one user, and
-- retire one app database, against the interpreter world.
module AppDatabaseWorldSpec (appDatabaseWorldTests) where

import AppDatabaseSpec (Server, alpha, beta, chServer, pgServer, scopeOf)
import Control.Exception (try)
import Control.Monad (forM_)
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.AppDatabase
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (..), mkOperationId)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (RecoveryClass (VerifyBeforeRetry))
import Nagare.Resource.Types
import Nagare.Test.World.Adversary
import Nagare.Test.World.AppDatabase
import Test.Tasty
import Test.Tasty.HUnit

appDatabaseWorldTests :: TestTree
appDatabaseWorldTests =
  testGroup
    "AppDatabase world"
    [ testGroup
        (show engine')
        [ testCase "a first apply converges and an unchanged re-plan has no operations" $ do
            (world, ops, members) <- setup engine' []
            converge ops members >>= expectRight
            replan ops members >>= (@?= [])
            assertPasswordsOriginal world ops members
        , testCase "every interruption resumes to the declared state with the original password" $ do
            (_, ops, members) <- setup engine' []
            converge ops members >>= expectRight
            calls <- countMutations engine'
            assertBool "the apply makes mutation calls" (calls > 0)
            forM_ [(n, fault) | n <- [1 .. calls], fault <- [RefusedBeforeEffect, LostAcknowledgement, Interrupt]] $ \(n, fault) -> do
              (world', ops', members', adversary) <- setupWith engine' [] [(Boundary MutateCall n, fault)]
              result <- converge ops' members'
              either (\reason -> assertFailure (show (n, fault) <> ": " <> T.unpack reason)) pure result
              replan ops' members' >>= (@?= [])
              assertPasswordsOriginal world' ops' members'
              left <- unacted <$> readIORef adversary
              assertEqual ("fault placement fired " <> show (n, fault)) [] left
        , testCase "a failed catalog read refuses nothing and the re-plan converges" $ do
            (_, ops, members, adversary) <- setupWith engine' [] [(Boundary ObserveCall 1, TransientReadFailure)]
            converge ops members >>= expectRight
            unacted <$> readIORef adversary >>= (@?= [])
        , testCase "access Nagare never grants refuses as drift" $ do
            (world, ops, members) <- setup engine' []
            converge ops members >>= expectRight
            modifyIORef' world (seedDrift engine')
            refusals <- observeAll ops members
            assertBool (show refusals) (any (T.isPrefixOf grantDriftCode) refusals)
        , testCase "a Secret the user no longer accepts refuses until rotation" $ do
            (world, ops, members) <- setup engine' []
            converge ops members >>= expectRight
            modifyIORef' world (#secrets %~ Map.map (#password .~ "replaced-out-of-band"))
            refusals <- observeAll ops members
            assertBool (show refusals) (any (T.isPrefixOf credentialMissingCode) refusals)
        , testCase "rotation changes only the selected user of the selected app database" $ do
            (world, ops, members) <- setup engine' []
            converge ops members >>= expectRight
            before <- readIORef world
            let runtime = userMember members "alpha" "runtime"
            rotate ops members runtime >>= expectRight
            after <- readIORef world
            let changedSecrets = Map.keys (Map.differenceWith (\a b -> if a == b then Nothing else Just a) (after ^. #secrets) (before ^. #secrets))
                changedUsers = Map.keys (Map.differenceWith (\a b -> if a == b then Nothing else Just a) (after ^. #users) (before ^. #users))
            changedSecrets @?= ["personal/alpha-" <> suffix engine' <> "-runtime"]
            changedUsers @?= ["alpha_" <> suffix engine' <> "_runtime"]
            after ^. #databases @?= before ^. #databases
            assertPasswordsCurrent ops members
        , testCase "retiring alpha turns its access off and leaves beta byte-identical" $ do
            (world, ops, members) <- setup engine' []
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
        , testCase "after a server rebuild a re-apply recreates the declared catalog with the retained passwords (M6)" $ do
            (world, ops, members) <- setup engine' []
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
    ]
  where
    expectRight = either (assertFailure . T.unpack) pure

suffix :: Engine -> Text
suffix Postgres = "pg"
suffix _ = "ch"

-- Fixtures ------------------------------------------------------------------

type Members = Map ResourceId AppDatabaseMember

setup :: Engine -> [(Boundary, Fault)] -> IO (IORef World, AppDatabaseOps, Members)
setup engine' faults = do
  (world, ops, members, _) <- setupWith engine' [] faults
  pure (world, ops, members)

-- | alpha and beta on one server, their Secrets already created (the
-- Kubernetes adapter creates them before the users, which depend on them).
setupWith :: Engine -> [()] -> [(Boundary, Fault)] -> IO (IORef World, AppDatabaseOps, Members, IORef Adversary)
setupWith engine' _ faults = do
  let server' = serverOf engine'
      declarations = concat [declarationsOf scope | scope <- fst server' : map (scopeOf server') [alpha engine', beta engine']]
  members <- either (assertFailure . T.unpack) pure (appDatabaseMembersFromDeclarations declarations)
  let secrets' =
        Map.fromList
          [ (secretKey namespace' secretName, CredentialSecret ("pw-" <> user) (firstDatabase member))
          | member <- Map.elems members
          , UserMember _ user namespace' secretName <- [member ^. #kind]
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
    , UserMember _ user _ _ <- [member ^. #kind]
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
adapterFor ops members = mkAppDatabaseAdapter (Map.map (^. #declaration) members) members ops

-- | Observe each member, act as the planner would, and recover after an
-- ambiguous effect or a killed executor as a resume would.
converge :: AppDatabaseOps -> Members -> IO (Either Text ())
converge ops members = go (ordered members)
  where
    adapter = adapterFor ops members
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
replan ops members = do
  observed <- adapterObserve (adapterFor ops members) (Map.keys members)
  case observationMap <$> observed of
    Right facts -> pure [r | (r, fact) <- Map.toList facts, not (isPresent fact)]
    Left reason -> assertFailure (T.unpack reason)
  where
    isPresent = \case
      ObservedPresent _ -> True
      _ -> False

observeAll :: AppDatabaseOps -> Members -> IO [Text]
observeAll ops members = do
  observed <- adapterObserve (adapterFor ops members) (Map.keys members)
  pure [reason | Right facts <- [observationMap <$> observed], ObservationUnavailable reason <- Map.elems facts]

countMutations :: Engine -> IO Int
countMutations engine' = do
  (_, ops, members, adversary) <- setupWith engine' [] []
  _ <- converge ops members
  Map.findWithDefault 0 MutateCall . counts <$> readIORef adversary

-- | Every user accepts its Secret's password, and the Secrets still hold the
-- passwords they were created with.
assertPasswordsOriginal :: IORef World -> AppDatabaseOps -> Members -> Assertion
assertPasswordsOriginal world ops members = do
  current <- readIORef world
  forM_ [(user, namespace', secretName) | m <- Map.elems members, UserMember _ user namespace' secretName <- [m ^. #kind]] $ \(user, namespace', secretName) ->
    (^. #password) <$> Map.lookup (secretKey namespace' secretName) (current ^. #secrets) @?= Just ("pw-" <> user)
  assertPasswordsCurrent ops members

assertPasswordsCurrent :: AppDatabaseOps -> Members -> Assertion
assertPasswordsCurrent ops members =
  forM_ [(m, user, namespace', secretName) | m <- Map.elems members, UserMember _ user namespace' secretName <- [m ^. #kind]] $ \(m, user, namespace', secretName) -> do
    secret <- readCredential ops namespace' secretName
    case secret of
      Right (Just credential) -> passwordMatches ops (m ^. #server) user (credential ^. #password) >>= (@?= Right True)
      other -> assertFailure ("credential unreadable: " <> show other)
