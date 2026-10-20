-- | The drain and resume steps of an app database's maintenance window
-- (EP-205), as declared operations of its scope. Both affect the runtime
-- user and are selected by their input digest, as VM power is, so every
-- other declared operation of the app-database adapter stays a rotation.
--
-- The drain ends the quiesced users' work after a grace period, waits out a
-- scheduled run and the app's mutations, and proves the app database idle on
-- the server it observed at review; the resume proves the reopened users log
-- in on that same server. Each step's private plan records the server
-- identity it was reviewed against, which the evidence reads back.
module Nagare.Inventory.Adapters.AppDatabaseSessions
  ( SessionStep (..)
  , SessionBinding (..)
  , SessionPlan (..)
  , sessionBindings
  , withAppDatabaseSessions
  , drainGraceTicks
  , drainTimeoutTicks
  )
where

import Data.Aeson
import Data.Generics.Labels ()
import Data.List (sort)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text qualified as T
import Nagare.Database.AppDatabase.Catalog (DrainObservation (..), LoginState (..), comparedIdentity)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.AppDatabase
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), OperationId)
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data SessionStep = DrainStep | ResumeStep
  deriving stock (Eq, Show, Generic)

instance ToJSON SessionStep where
  toJSON DrainStep = String "drain"
  toJSON ResumeStep = String "resume"

instance FromJSON SessionStep where
  parseJSON = withText "session step" $ \case
    "drain" -> pure DrainStep
    "resume" -> pure ResumeStep
    other -> fail ("unknown session step " <> T.unpack other)

-- | One declared drain or resume: the runtime user it affects, and the
-- scope's backup CronJob (namespace, name), whose running Job a drain waits
-- out.
data SessionBinding = SessionBinding
  { step :: !SessionStep
  , member :: !ResourceId
  , schedule :: !(Maybe (Name, Name))
  }
  deriving stock (Generic, Eq, Show)

-- | The private plan of a step, published with the review: the users and
-- databases it covers and the server identity observed when it was prepared.
data SessionPlan = SessionPlan
  { version :: !Int
  , operation :: !OperationId
  , step :: !SessionStep
  , inputDigest :: !ContentDigest
  , resource :: !ResourceId
  , appDatabase :: !Text
  , users :: ![Text]
  , databases :: ![Text]
  , identity :: !(Map Text Text)
  }
  deriving stock (Generic, Eq, Show)

instance ToJSON SessionPlan where
  toJSON plan =
    object
      [ "version" .= (plan ^. #version)
      , "operation" .= (plan ^. #operation)
      , "step" .= (plan ^. #step)
      , "inputDigest" .= (plan ^. #inputDigest)
      , "resource" .= (plan ^. #resource)
      , "appDatabase" .= (plan ^. #appDatabase)
      , "users" .= (plan ^. #users)
      , "databases" .= (plan ^. #databases)
      , "identity" .= (plan ^. #identity)
      ]

instance FromJSON SessionPlan where
  parseJSON = withObject "app-database session plan" $ \o ->
    SessionPlan
      <$> o .: "version"
      <*> o .: "operation"
      <*> o .: "step"
      <*> o .: "inputDigest"
      <*> o .: "resource"
      <*> o .: "appDatabase"
      <*> o .: "users"
      <*> o .: "databases"
      <*> o .: "identity"

-- | A drain waits up to 30 polls for the blocked users' work to end before
-- terminating it, and up to 300 for a scheduled run and the app's mutations.
drainGraceTicks, drainTimeoutTicks :: Int
drainGraceTicks = 30
drainTimeoutTicks = 300

-- | The declared drain and resume operations of the given scopes, keyed by
-- the digest the planner gives them.
sessionBindings :: [ScopeDeclaration] -> Either Text (Map ContentDigest SessionBinding)
sessionBindings scopes =
  Map.fromList
    <$> sequence
      [ bind scope intent step'
      | scope <- scopes
      , bundle <- scopeBundles scope
      , intent <- bundle ^. #operations
      , Just step' <- [stepOf (intent ^. #operationKind)]
      ]
  where
    stepOf = \case
      DrainSessions -> Just DrainStep
      ResumeSessions -> Just ResumeStep
      _ -> Nothing
    bind scope intent step' = do
      let members = [resource' | bundle <- scopeBundles scope, Managed resource' <- bundle ^. #declarations]
      target <- case NE.toList (intent ^. #affects) of
        [single] -> Right single
        _ -> Left "an app-database drain or resume affects exactly the runtime user"
      unless
        (or [resource' ^. #identity == target | resource' <- members, DatabaseUserSpec _ "runtime" _ _ _ <- [resource' ^. #spec]])
        (Left "an app-database drain or resume affects its own scope's runtime user")
      let schedules = [(ns, name) | resource' <- members, Kubernetes _ "batch" kind' (Just ns) name <- [resource' ^. #address], nameText kind' == "cronjob"]
      digest <- contentDigest <$> canonicalValue (toJSON intent)
      pure (digest, SessionBinding step' target (listToMaybe schedules))

withAppDatabaseSessions :: Map ContentDigest SessionBinding -> Map ResourceId AppDatabaseMember -> AppDatabaseOps -> Adapter -> Adapter
withAppDatabaseSessions bindings members ops base =
  base
    { adapterPrepare = \planned -> if selected planned then prepare planned else adapterPrepare base planned
    , adapterPreflight = \planned native -> if selected planned then withPlan planned native (pure . Left) preflight else adapterPreflight base planned native
    , adapterExecute = \planned native -> if selected planned then withPlan planned native (pure . AdapterEffectFailed . KnownNoEffect) execute else adapterExecute base planned native
    , adapterVerify = \planned native -> if selected planned then withPlan planned native (pure . Left) verify else adapterVerify base planned native
    , adapterRecover = \planned native ->
        if selected planned
          then withPlan planned native (pure . RecoveryUnresolved) $ \binding plan ->
            -- A drain repeated once login is closed ends nothing new, and a
            -- resume changes nothing, so both retry until proved.
            either (const RecoverySafeToRetry) RecoveryProvedComplete <$> verify binding plan
          else adapterRecover base planned native
    }
  where
    selected planned = plannedAction planned == RunDeclaredOperation && Map.member (plannedInputDigest planned) bindings
    bindingOf planned = maybe (Left "app-database session step is not declared in the review") Right (Map.lookup (plannedInputDigest planned) bindings)
    runtimeOf binding = maybe (Left "app-database session step's runtime user is absent from the reviewed declarations") Right (Map.lookup (binding ^. #member) members)
    -- Drain covers the quiesced users; resume the users it reopened.
    usersOf binding runtime =
      sort
        [ user
        | other <- Map.elems members
        , other ^. #declaration . #owner == runtime ^. #declaration . #owner
        , UserMember _ user _ _ _ <- [other ^. #kind]
        , case binding ^. #step of
            DrainStep -> other ^. #quiesced
            ResumeStep -> other ^. #enabled
        ]
    appDatabaseOf runtime = fromMaybe (nameText (scopeName owner)) (T.stripPrefix "appdb-" (nameText (scopeName owner)))
      where
        owner = runtime ^. #declaration . #owner
    prepare planned = do
      result <- case (,) <$> bindingOf planned <*> (bindingOf planned >>= runtimeOf) of
        Left reason -> pure (Left reason)
        Right (binding, runtime) -> do
          let users' = usersOf binding runtime
              server' = runtime ^. #server
          if null users'
            then pure (Left "an app-database drain or resume covers no user")
            else do
              observed <- identityOf server' users' (runtime ^. #scopeDatabases)
              pure $ do
                identity' <- observed
                let plan = SessionPlan 1 (plannedOperationId planned) (binding ^. #step) (plannedInputDigest planned) (binding ^. #member) (appDatabaseOf runtime) users' (runtime ^. #scopeDatabases) identity'
                bytes <- canonicalValue (toJSON plan)
                pure (PreparedNative bytes (summary plan (server' ^. #name)))
      pure (first (PrepareRefused (plannedOperationId planned)) result)
    withPlan :: PlannedOperation -> PreparedNative -> (Text -> IO a) -> (SessionBinding -> SessionPlan -> IO a) -> IO a
    withPlan planned native refuse continue = case decoded of
      Left reason -> refuse reason
      Right (binding, plan) -> continue binding plan
      where
        decoded = do
          plan <- first T.pack (eitherDecodeStrict (preparedNativeBytes native))
          binding <- bindingOf planned
          unless
            (plan ^. #operation == plannedOperationId planned && plan ^. #inputDigest == plannedInputDigest planned && plan ^. #resource == binding ^. #member && plan ^. #step == binding ^. #step)
            (Left "private app-database session plan differs from the reviewed operation")
          pure (binding, plan)
    serverOf plan = (^. #server) <$> runtimeOf' plan
    runtimeOf' plan = maybe (Left "app-database session step's runtime user is absent from the reviewed declarations") Right (Map.lookup (plan ^. #resource) members)
    identityOf server' users' databases' = do
      pod <- observeServerPod ops server'
      drained <- observeDrain ops server' users' databases'
      pure $ do
        (uid, started) <- pod
        observation <- drained
        pure (Map.insert "podUID" uid (Map.insert "podStarted" started (observation ^. #identity)))
    sameServer plan observed = comparedIdentity observed == comparedIdentity (plan ^. #identity)
    preflight _ plan = case serverOf plan of
      Left reason -> pure (Left reason)
      Right server' -> do
        observed <- identityOf server' (plan ^. #users) (plan ^. #databases)
        pure $ case observed of
          Left reason -> Left reason
          Right identity'
            | sameServer plan identity' -> Right ()
            | otherwise -> Left "app-database server identity differs from the reviewed one; the server was restarted or replaced"
    execute binding plan = case (binding ^. #step, serverOf plan) of
      (_, Left reason) -> pure (AdapterEffectFailed (KnownNoEffect reason))
      (ResumeStep, Right _) -> pure AdapterEffectCompleted
      (DrainStep, Right server') -> do
        graced <- waitGrace server' plan drainGraceTicks
        case graced of
          Left reason -> pure (AdapterEffectAmbiguous reason)
          Right () -> do
            ended <- terminateSessions ops server' (plan ^. #users)
            case ended of
              Left reason -> pure (AdapterEffectAmbiguous reason)
              Right () -> waitIdle binding server' plan drainTimeoutTicks
    -- The users' own work may end within the grace period.
    waitGrace server' plan remaining = do
      observed <- observeDrain ops server' (plan ^. #users) (plan ^. #databases)
      case observed of
        Left reason -> pure (Left reason)
        Right observation
          | observation ^. #sessions == 0 || remaining <= 0 -> pure (Right ())
          | otherwise -> pause ops >> waitGrace server' plan (remaining - 1)
    waitIdle binding server' plan remaining = do
      state <- idleState binding server' plan
      case state of
        Left reason -> pure (AdapterEffectAmbiguous reason)
        Right (observation, runs)
          | not (null (observation ^. #failed)) ->
              pure (AdapterEffectFailed (KnownNoEffect ("app-database drain refused: a mutation failed: " <> T.intercalate "; " (observation ^. #failed))))
          | idle observation runs -> pure AdapterEffectCompleted
          | remaining <= 0 -> pure (AdapterEffectFailed (KnownNoEffect ("app-database drain timed out: " <> describeBusy observation runs)))
          | otherwise -> do
              pause ops
              -- A session that slipped in before login closed is ended too.
              when (observation ^. #sessions > 0) (void (terminateSessions ops server' (plan ^. #users)))
              waitIdle binding server' plan (remaining - 1)
    idleState binding server' plan = do
      observed <- observeDrain ops server' (plan ^. #users) (plan ^. #databases)
      runs <- maybe (pure (Right 0)) (uncurry (observeActiveRuns ops)) (binding ^. #schedule)
      pure ((,) <$> observed <*> runs)
    idle observation runs = observation ^. #sessions == 0 && runs == 0 && null (observation ^. #unfinished)
    describeBusy observation runs =
      T.intercalate
        "; "
        ( [T.show (observation ^. #sessions) <> " session(s) of " <> "the blocked users" | observation ^. #sessions > 0]
            <> [T.show runs <> " scheduled backup run(s) in flight" | runs > 0]
            <> ["unfinished mutations " <> T.intercalate ", " (observation ^. #unfinished) | not (null (observation ^. #unfinished))]
        )
    verify binding plan = case serverOf plan of
      Left reason -> pure (Left reason)
      Right server' -> do
        pod <- observeServerPod ops server'
        state <- idleState binding server' plan
        logins <- case binding ^. #step of
          DrainStep -> pure (Right [])
          ResumeStep -> do
            catalog <- observeCatalog ops server' (plan ^. #users) (plan ^. #databases)
            pure (catalog <&> \observed -> [user | user <- plan ^. #users, maybe True ((/= LoginOn) . (^. #login)) (Map.lookup user (observed ^. #users))])
        pure $ do
          (uid, started) <- pod
          (observation, runs) <- state
          closed <- logins
          let identity' = Map.insert "podUID" uid (Map.insert "podStarted" started (observation ^. #identity))
          unless (sameServer plan identity') (Left "app-database server identity differs from the reviewed one; the server was restarted or replaced")
          case binding ^. #step of
            DrainStep -> unless (idle observation runs) (Left ("app-database drain is not complete: " <> describeBusy observation runs))
            ResumeStep -> unless (null closed) (Left ("app-database users still cannot log in after resume: " <> T.intercalate ", " closed))
          proof <-
            canonicalValue
              ( object
                  [ "plan" .= plan
                  , "observed" .= object ["sessions" .= (observation ^. #sessions), "activeRuns" .= runs, "unfinishedMutations" .= (observation ^. #unfinished), "identity" .= identity']
                  ]
              )
          pure (contentDigest proof)
    summary plan server' = case plan ^. #step of
      DrainStep ->
        "drain app-database "
          <> plan ^. #appDatabase
          <> " on "
          <> nameText server'
          <> ": end the work of "
          <> T.intercalate ", " (plan ^. #users)
          <> " after "
          <> T.show drainGraceTicks
          <> " s, then wait up to "
          <> T.show drainTimeoutTicks
          <> " s for its scheduled run and mutations; server pod "
          <> Map.findWithDefault "?" "podUID" (plan ^. #identity)
      ResumeStep ->
        "resume app-database "
          <> plan ^. #appDatabase
          <> " on "
          <> nameText server'
          <> ": prove "
          <> T.intercalate ", " (plan ^. #users)
          <> " log in on server pod "
          <> Map.findWithDefault "?" "podUID" (plan ^. #identity)
