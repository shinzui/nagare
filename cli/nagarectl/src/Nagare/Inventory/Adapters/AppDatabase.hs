-- | App-database members (EP-202): users and logical databases inside an
-- accepted server, observed through its catalogs and converged by
-- member-level commands.
--
-- Every execution is a convergence of one member to its declared state: a
-- user is created only when absent, with the password its Secret holds, and
-- an existing user is never given another password; a database is created
-- only when absent; access is then set to the declared state. Re-running an
-- execution is therefore safe, and recovery after a lost acknowledgement
-- re-observes and either proves the member complete or retries. Access that
-- Nagare never grants is drift and refuses, never repaired.
module Nagare.Inventory.Adapters.AppDatabase
  ( ServerRef (..)
  , MemberKind (..)
  , AppDatabaseMember (..)
  , CredentialSecret (..)
  , CatalogCommand (..)
  , AppDatabaseOps (..)
  , appDatabaseMembersFromDeclarations
  , mkAppDatabaseAdapter
  , grantDriftCode
  , credentialMissingCode
  )
where

import Data.Aeson
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List (nub, sort)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Database.AppDatabase.Catalog
import Nagare.Database.AppDatabase.Sql (DatabaseAccess (..), PasswordHash, ReaderAccess (..), hashPassword)
import Nagare.Dsl.AppDatabase (AppDatabaseRole (..), MonitoringRole, ReaderObject (..), UserAccess, UserExtension, UserLimits, grantExceptionToken, logicalDatabaseNameText, monitoringRoleToken, noUserExtension, noUserLimits, parseAppDatabaseRole, relationNameText, schemaNameText)
import Nagare.Dsl.Database (Engine (..), parseEngine)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), OperationId)
import Nagare.Resource.Inventory
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- | The accepted server a member lives in: its StatefulSet and PVC members,
-- whose recorded incarnations every transport call checks first (ADR 27).
data ServerRef = ServerRef
  { engine :: !Engine
  , statefulSet :: !ResourceId
  , persistentVolume :: !ResourceId
  , namespace :: !Name
  , name :: !Name
  , initialDatabase :: !Text
  }
  deriving stock (Generic, Eq, Ord, Show)

data MemberKind
  = -- | role, user, credential Secret namespace and name, and the desired
    -- reviewed access
    UserMember !AppDatabaseRole !Text !Name !Name !UserExtension
  | -- | database, migration user, runtime user, and the tolerated monitoring
    -- roles
    DatabaseMember !Text !Text !Text ![MonitoringRole]
  deriving stock (Eq, Show)

data AppDatabaseMember = AppDatabaseMember
  { declaration :: !ManagedResource
  , server :: !ServerRef
  , kind :: !MemberKind
  , enabled :: !Bool
  , scopeUsers :: ![Text]
  , scopeDatabases :: ![Text]
  , quiesced :: !Bool
  -- ^ a user whose login a reviewed quiesce closed (EP-205)
  , withheld :: ![Text]
  -- ^ a database's quiesced users, whose ClickHouse grants are withheld
  , readers :: ![Text]
  -- ^ a database's declared readers (EP-206)
  }
  deriving stock (Generic, Eq, Show)

-- | What a credential Secret holds for its user: the password and the
-- logical database it opens.
data CredentialSecret = CredentialSecret
  { password :: !Text
  , database :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | The member-level commands, rendered to SQL by the transport.
data CatalogCommand
  = CreateUser !Text !PasswordHash !Text
  | SetUserAccess !AppDatabaseRole !Text !UserLogin !UserAccess
  | -- | EP-206: a reader's login, limits, the objects it is granted (or, when
    -- it may not log in, revoked), the further objects revoked, and on
    -- PostgreSQL the schemas it uses
    SetReaderAccess !ReaderAccess
  | CreateDatabase !Text !Text
  | SetDatabaseAccess !DatabaseAccess
  | SetPassword !Text !PasswordHash
  deriving stock (Eq, Show)

-- | The provider boundary: the context-guarded kubectl transport, or an
-- interpreter world in tests. A 'Left' from 'runCommand' means the statement
-- may or may not have taken effect.
data AppDatabaseOps = AppDatabaseOps
  { observeCatalog :: !(ServerRef -> [Text] -> [Text] -> IO (Either Text Catalog))
  , passwordMatches :: !(ServerRef -> Text -> Text -> IO (Either Text Bool))
  , readCredential :: !(Name -> Name -> IO (Either Text (Maybe CredentialSecret)))
  , runCommand :: !(ServerRef -> CatalogCommand -> IO (Either Text ()))
  , rewriteCredential :: !(Name -> Name -> Text -> IO (Either Text ()))
  -- ^ replace the Secret's password, and its URL's, under a
  -- resourceVersion precondition; the other keys keep their values
  , freshSalt :: !(IO ByteString)
  , freshPassword :: !(IO Text)
  , observeDrain :: !(ServerRef -> [Text] -> [Text] -> IO (Either Text DrainObservation))
  -- ^ EP-205: the blocked users' running work, the app's unfinished
  -- mutations and the server's engine identity
  , terminateSessions :: !(ServerRef -> [Text] -> IO (Either Text ()))
  , observeActiveRuns :: !(Name -> Name -> IO (Either Text Int))
  -- ^ the Jobs a CronJob (namespace, name) still runs
  , observeServerPod :: !(ServerRef -> IO (Either Text (Text, Text)))
  -- ^ the server Pod's UID and its container's start time
  , pause :: !(IO ())
  -- ^ one poll interval of a drain
  }

isReaderRole :: AppDatabaseRole -> Bool
isReaderRole = \case
  ReaderRole _ -> True
  _ -> False

-- | Resolve every app-database member against the declarations in view
-- (desired and accepted): its server StatefulSet and PVC, and, for a user,
-- its credential Secret.
appDatabaseMembersFromDeclarations :: [Declaration] -> Either Text (Map ResourceId AppDatabaseMember)
appDatabaseMembersFromDeclarations declarations = Map.fromList <$> traverse bind members
  where
    -- Accepted history comes first and the review's own declarations last,
    -- so the latter win; a sibling read from both would see a stale login.
    byId = Map.fromList [(declarationId d, d) | d <- declarations]
    members = [resource | Managed resource <- Map.elems byId, resource ^. #executor == AppDatabaseExecutor]
    siblings owner = [resource | resource <- members, resource ^. #owner == owner]
    bind resource = do
      (stateful, engineText, kind', login) <- case (resource ^. #address, resource ^. #spec) of
        (DatabaseUser target user, DatabaseUserSpec engineText roleText login _ access) -> do
          role' <- maybe (Left "app-database user has an unknown role") Right (parseAppDatabaseRole roleText)
          (secretNamespace, secretName) <- credentialOf resource
          pure (target, engineText, UserMember role' (nameText user) secretNamespace secretName access, login)
        (DatabaseName target db, LogicalDatabase engineText migration runtime on _ monitoring) ->
          pure (target, engineText, DatabaseMember (nameText db) (nameText migration) (nameText runtime) monitoring, if on then LoginOpen else LoginClosed)
        _ -> Left "app-database member has an invalid address or specification"
      engine' <- maybe (Left "app-database member has an unknown engine") Right (parseEngine engineText)
      unless (OrderedAfter stateful `elem` resource ^. #dependencies) (Left "app-database member is not ordered after its server")
      serverRef <- serverOf engine' stateful
      let scope = siblings (resource ^. #owner)
      pure
        ( resource ^. #identity
        , AppDatabaseMember
            resource
            serverRef
            kind'
            (login == LoginOpen)
            (sort [nameText user | member <- scope, DatabaseUser _ user <- [member ^. #address]])
            (sort [nameText db | member <- scope, DatabaseName _ db <- [member ^. #address]])
            (login == LoginQuiesced)
            ( case kind' of
                DatabaseMember {} -> sort [nameText user | member <- scope, DatabaseUser _ user <- [member ^. #address], DatabaseUserSpec _ _ LoginQuiesced _ _ <- [member ^. #spec]]
                UserMember {} -> []
            )
            ( case kind' of
                DatabaseMember {} -> sort [nameText user | member <- scope, DatabaseUser _ user <- [member ^. #address], DatabaseUserSpec _ role _ _ _ <- [member ^. #spec], maybe False isReaderRole (parseAppDatabaseRole role)]
                UserMember {} -> []
            )
        )
    serverOf engine' stateful = case Map.lookup stateful byId of
      Just (Managed target)
        | Kubernetes _ "apps" kind' (Just ns) nativeName <- target ^. #address
        , nameText kind' == "statefulset"
        , Just prefix <- T.stripSuffix "/statefulset" (resourceIdText stateful) -> do
            let pvcs = [declarationId d | d@(Managed member) <- declarations, member ^. #owner == target ^. #owner, resourceIdText (declarationId d) == prefix <> "/pvc"]
            pvc <- case nub pvcs of
              [found] -> Right found
              _ -> Left "app-database server has no unique PVC member"
            pure (ServerRef engine' stateful pvc ns nativeName (T.replace "-" "_" (nameText nativeName)))
      _ -> Left "app-database server StatefulSet is absent from the inventory"
    credentialOf resource =
      case [ (ns, secretName)
           | OrderedAfter dependency <- resource ^. #dependencies
           , Just (Managed secret) <- [Map.lookup dependency byId]
           , secret ^. #owner == resource ^. #owner
           , Kubernetes _ "" kind' (Just ns) secretName <- [secret ^. #address]
           , nameText kind' == "secret"
           ] of
        [found] -> Right found
        _ -> Left "app-database user has no unique credential Secret in its scope"

data MemberPlan = MemberPlan
  { version :: !Int
  , operation :: !OperationId
  , action :: !Text
  , inputDigest :: !ContentDigest
  , resource :: !ResourceId
  }
  deriving stock (Generic, Eq, Show)

instance ToJSON MemberPlan where
  toJSON plan =
    object
      [ "version" .= (plan ^. #version)
      , "operation" .= (plan ^. #operation)
      , "action" .= (plan ^. #action)
      , "inputDigest" .= (plan ^. #inputDigest)
      , "resource" .= (plan ^. #resource)
      ]

instance FromJSON MemberPlan where
  parseJSON = withObject "app-database member plan" $ \o ->
    MemberPlan <$> o .: "version" <*> o .: "operation" <*> o .: "action" <*> o .: "inputDigest" <*> o .: "resource"

-- | The adapter. @accepted@ holds the members of accepted history; a present
-- member outside it is reported unowned, so it is never adopted silently.
mkAppDatabaseAdapter :: Map ResourceId ManagedResource -> Map ResourceId AppDatabaseMember -> AppDatabaseOps -> Adapter
mkAppDatabaseAdapter accepted members ops =
  Adapter
    { adapterExecutor = AppDatabaseExecutor
    , adapterIdentity = "reviewed-app-database"
    , adapterVersion = "1"
    , adapterObserve = \resources -> do
        entries <- traverse observeOne resources
        pure $ do
          observed <- sequence entries
          set' <- observationSet [(resource', observation) | (resource', _, observation) <- observed]
          pure (withObservationNotes (Map.fromList [(resource', note) | (resource', Just note, _) <- observed]) set')
    , adapterPrepare = \operation' -> pure $ do
        plan <- first (PrepareRefused (plannedOperationId operation')) (planFor operation')
        bytes <- first (PrepareRefused (plannedOperationId operation')) (canonicalValue (toJSON plan))
        member <- first (PrepareRefused (plannedOperationId operation')) (memberOf (plan ^. #resource))
        pure (PreparedNative bytes (summary (plan ^. #action) member))
    , adapterPreflight = \operation' prepared -> withPlan operation' prepared (pure . Left) $ \plan member -> do
        state <- stateOf member
        pure $ case (plan ^. #action, state) of
          (_, Left reason) -> Left reason
          ("create", Right MemberAbsent) -> Right ()
          ("update", Right (MemberIncomplete _ _)) -> Right ()
          ("update", Right (MemberComplete _)) -> Right ()
          ("verify", Right (MemberComplete _)) -> Right ()
          ("rotate", Right (MemberComplete _)) -> Right ()
          ("rotate", Right (MemberIncomplete _ _)) -> Right ()
          (_, Right (MemberDrift reason)) -> Left (grantDriftCode <> ": " <> reason)
          (_, Right (MemberRefused code reason)) -> Left (code <> ": " <> reason)
          _ -> Left "app-database member observation differs from the reviewed action"
    , adapterExecute = \operation' prepared -> withPlan operation' prepared (pure . AdapterEffectFailed . KnownNoEffect) $ \plan member ->
        case plan ^. #action of
          "verify" -> pure AdapterEffectCompleted
          "rotate" -> rotate member
          _ -> converge member
    , adapterVerify = \operation' prepared -> withPlan operation' prepared (pure . Left) $ \plan member -> do
        (state, credential) <- stateAndCredential member
        pure $ case (state, credential) of
          (Right (MemberComplete physical), Right True) -> Right (proof plan physical)
          (Right (MemberComplete _), Right False) -> Left "app-database user does not accept its Secret's password"
          (_, Left reason) -> Left reason
          (Right other, _) -> Left ("app-database member is not complete after execution: " <> describe other)
          (Left reason, _) -> Left reason
    , adapterSettle = Nothing
    , adapterRecover = \operation' prepared -> withPlan operation' prepared (pure . RecoveryUnresolved) $ \plan member -> do
        (state, credential) <- stateAndCredential member
        pure $ case (state, credential) of
          -- A rotation repeated writes yet another password to the Secret and
          -- the user follows it, so it ends matched whatever step was lost.
          (Right (MemberDrift reason), _) | plan ^. #action == "rotate" -> RecoveryUnresolved (grantDriftCode <> ": " <> reason)
          (Right MemberAbsent, _) | plan ^. #action == "rotate" -> RecoveryUnresolved "the rotated app-database user is absent"
          (Right _, _) | plan ^. #action == "rotate" -> RecoverySafeToRetry
          (Right (MemberComplete physical), Right True) -> RecoveryProvedComplete (proof plan physical)
          (Right MemberAbsent, _) -> RecoverySafeToRetry
          (Right (MemberIncomplete _ _), Right True) -> RecoverySafeToRetry
          (Right (MemberDrift reason), _) -> RecoveryUnresolved (grantDriftCode <> ": " <> reason)
          (Right (MemberRefused code reason), _) -> RecoveryUnresolved (code <> ": " <> reason)
          (Right _, Right False) -> RecoveryUnresolved "app-database user exists with a password other than its Secret's; rotate it"
          (_, Left reason) -> RecoveryUnresolved reason
          (Left reason, _) -> RecoveryUnresolved reason
    }
  where
    memberOf resource' = maybe (Left "app-database member is absent from the reviewed declarations") Right (Map.lookup resource' members)
    planFor operation' = do
      resource' <- case NE.toList (plannedResources operation') of
        [single] -> Right single
        _ -> Left "app-database operation must affect exactly one member"
      member <- memberOf resource'
      actionText <- case plannedAction operation' of
        CreateResource -> Right "create"
        UpdateResource -> Right "update"
        VerifyResource -> Right "verify"
        RunDeclaredOperation -> Right "rotate"
        _ -> Left "app-database members are only created, converged and verified; retire disables them and keeps their data, and they are never adopted or collected"
      case (actionText, member ^. #kind) of
        ("rotate", DatabaseMember {}) -> Left "only an app-database user's credential is rotated"
        _ -> pure ()
      pure (MemberPlan 1 (plannedOperationId operation') actionText (plannedInputDigest operation') resource')
    withPlan :: PlannedOperation -> PreparedNative -> (Text -> IO a) -> (MemberPlan -> AppDatabaseMember -> IO a) -> IO a
    withPlan operation' prepared refuse continue = case decodePlan operation' (preparedNativeBytes prepared) of
      Left reason -> refuse reason
      Right plan -> either refuse (continue plan) (memberOf (plan ^. #resource))
    decodePlan operation' bytes = do
      plan <- first T.pack (eitherDecodeStrict bytes)
      expected <- planFor operation'
      unless (plan == expected) (Left "private app-database plan differs from the reviewed operation")
      pure plan
    catalogFor member = observeCatalog ops (member ^. #server) (member ^. #scopeUsers) (member ^. #scopeDatabases)
    classify member catalog = fst (classifyWithPending member catalog)
    -- A reader's pending objects ride beside its state (EP-206).
    classifyWithPending member catalog = case member ^. #kind of
      UserMember (ReaderRole _) user _ _ desired ->
        classifyReader (member ^. #server . #engine) (readerDeclaration member desired) user catalog
      UserMember role user _ _ desired ->
        (classifyUser (member ^. #server . #engine) (UserDeclaration role (member ^. #enabled) (desired ^. #access) (acceptedAccess member ^. #access)) user (member ^. #scopeDatabases) catalog, [])
      DatabaseMember db migration runtime monitoring -> (classifyDatabase (accessOf member db migration runtime monitoring) catalog, [])
    accessOf member db migration runtime monitoring =
      DatabaseAccess (member ^. #server . #engine) (member ^. #server . #initialDatabase) db migration runtime (member ^. #enabled) monitoring (member ^. #withheld) (member ^. #readers)
    readerSpec extension = (\grant -> ReaderSpec (NE.toList (grant ^. #objects)) (extension ^. #access . #limits)) <$> extension ^. #reader
    readerDeclaration member desired =
      ReaderDeclaration (member ^. #enabled) (fromMaybe (ReaderSpec [] noUserLimits) (readerSpec desired)) (readerSpec (acceptedAccess member))
    -- The access the last reviewed plan declared; an item only it names is
    -- revoked or reset by review rather than refused as drift.
    acceptedAccess member = case (^. #spec) <$> Map.lookup (member ^. #declaration . #identity) accepted of
      Just (DatabaseUserSpec _ _ _ _ extension) -> extension
      _ -> noUserExtension
    stateOf member = fmap (classify member) <$> catalogFor member
    -- The member's state and whether its user accepts its Secret's password.
    stateAndCredential member = do
      catalog <- catalogFor member
      case catalog of
        Left reason -> pure (Left reason, Right True)
        Right observed -> (Right (classify member observed),) <$> credentialMatches member observed
    -- A user's password must be the one its Secret holds; a database has no
    -- credential of its own. A ClickHouse user that cannot log in cannot prove
    -- its password, so it is checked again once its login is back on.
    credentialMatches member observed = case member ^. #kind of
      DatabaseMember {} -> pure (Right True)
      UserMember _ user _ _ _
        | loginOff user observed && member ^. #server . #engine == ClickHouse -> pure (Right True)
      UserMember _ user secretNamespace secretName _ -> do
        secret <- readCredential ops secretNamespace secretName
        case secret of
          Left reason -> pure (Left reason)
          -- The credential member itself reports an absent Secret, and its
          -- reviewed exit is inventory rebuild.
          Right Nothing -> pure (Right True)
          Right (Just credential) -> passwordMatches ops (member ^. #server) user (credential ^. #password)
    observeOne resource' = case Map.lookup resource' members of
      Nothing -> pure (Left "app-database resource is absent from the reviewed declarations")
      Just member -> do
        catalog <- catalogFor member
        let classified = classifyWithPending member <$> catalog
            state = fst <$> classified
            -- A reader's objects the app's migrations have not created yet.
            note = case classified of
              Right (_, pending@(_ : _)) -> Just ("pending: " <> T.intercalate ", " [fromMaybe (o ^. #database) (o ^. #schema) <> "." <> o ^. #relation | o <- pending])
              _ -> Nothing
        credential <- case (state, catalog) of
          (Right MemberAbsent, _) -> pure (Right True)
          (Right (MemberDrift _), _) -> pure (Right True)
          (Right (MemberRefused _ _), _) -> pure (Right True)
          (_, Right observed) | Map.member resource' accepted -> credentialMatches member observed
          _ -> pure (Right True)
        pure . Right . (resource',note,) $ case (state, credential) of
          (Left reason, _) -> ObservationUnavailable reason
          (Right (MemberDrift reason), _) -> ObservationUnavailable (grantDriftCode <> ": " <> reason)
          (Right (MemberRefused code reason), _) -> ObservationUnavailable (code <> ": " <> reason)
          (Right MemberAbsent, _) -> ConfirmedAbsent (contentDigest (TE.encodeUtf8 (resourceIdText resource' <> ":absent")))
          (_, Left reason) -> ObservationUnavailable reason
          (_, Right False) ->
            ObservationUnavailable (credentialMissingCode <> ": the user does not accept its Secret's password; the reviewed exit is db app-database rotate")
          (Right (MemberComplete physical), _)
            | Map.notMember resource' accepted -> ObservedUnowned (identity physical)
            | otherwise -> ObservedPresent (identity physical)
          (Right (MemberIncomplete physical reason), _)
            | Map.notMember resource' accepted -> ObservedUnowned (identity physical)
            | otherwise -> ObservedDrifted (identity physical) (contentDigest (TE.encodeUtf8 reason))
    loginOf member
      | member ^. #quiesced = LoginQuiesced
      | member ^. #enabled = LoginOpen
      | otherwise = LoginClosed
    -- A reader's grants are its resolved objects; what only the accepted
    -- declaration named is revoked (drift never reaches here).
    accessCommand member observed role user desired = case role of
      ReaderRole _ ->
        let engine' = member ^. #server . #engine
            spec = fromMaybe (ReaderSpec [] noUserLimits) (readerSpec desired)
            (present, _) = resolveReaderObjects engine' (spec ^. #objects) observed
            held = readerHeldSelects engine' user observed
            databases' = if engine' == ClickHouse then [] else readerDatabases (spec ^. #objects)
            schemas = readerSchemas engine' (spec ^. #objects) observed
            -- What the reader holds beyond its declaration now: only the
            -- accepted declaration named it, or the classification refused.
            heldDatabases = [db | engine' /= ClickHouse, (db, cdb) <- Map.toList (observed ^. #databases), g <- cdb ^. #grants, g ^. #grantee == user, g ^. #target == "database"]
            heldSchemas = [(db, T.drop 7 (g ^. #target)) | engine' /= ClickHouse, (db, cdb) <- Map.toList (observed ^. #databases), g <- cdb ^. #grants, g ^. #grantee == user, "schema:" `T.isPrefixOf` (g ^. #target)]
         in if member ^. #enabled
              then SetReaderAccess (ReaderAccess user LoginOpen (spec ^. #limits) present (filter (`notElem` present) held) databases' (filter (`notElem` databases') heldDatabases) schemas (filter (`notElem` schemas) heldSchemas))
              else SetReaderAccess (ReaderAccess user (loginOf member) (spec ^. #limits) (nub (present <> held)) [] [] (nub (databases' <> heldDatabases)) [] (nub (schemas <> heldSchemas)))
      _ -> SetUserAccess role user (loginOf member) (desired ^. #access)
    loginOff user observed = maybe False ((== LoginOff) . (^. #login)) (Map.lookup user (observed ^. #users))
    identity physical = either (error . T.unpack) id (mkPhysicalIdentity physical)
    converge member = do
      catalog <- catalogFor member
      case catalog of
        Left reason -> pure (AdapterEffectAmbiguous reason)
        Right observed -> case (classify member observed, member ^. #kind) of
          (MemberDrift reason, _) -> pure (AdapterEffectFailed (KnownNoEffect (grantDriftCode <> ": " <> reason)))
          (MemberRefused code reason, _) -> pure (AdapterEffectFailed (KnownNoEffect (code <> ": " <> reason)))
          (state, UserMember role user secretNamespace secretName desired) -> do
            secret <- readCredential ops secretNamespace secretName
            case secret of
              Left reason -> pure (AdapterEffectAmbiguous reason)
              Right Nothing -> pure (AdapterEffectFailed (KnownNoEffect (credentialMissingCode <> ": Secret " <> nameText secretName <> " is absent")))
              Right (Just credential) -> do
                created <- case state of
                  MemberAbsent -> do
                    salt <- freshSalt ops
                    run member (CreateUser user (hashPassword (member ^. #server . #engine) salt (credential ^. #password)) (credential ^. #database))
                  _ | loginOff user observed && member ^. #server . #engine == ClickHouse -> pure Nothing
                  _ -> do
                    matches <- passwordMatches ops (member ^. #server) user (credential ^. #password)
                    pure $ case matches of
                      Right True -> Nothing
                      Right False -> Just (AdapterEffectFailed (KnownNoEffect "app-database user exists with a password other than its Secret's; rotate it"))
                      Left reason -> Just (AdapterEffectAmbiguous reason)
                maybe (finish (run member (accessCommand member observed role user desired))) pure created
          (state, DatabaseMember db migration runtime monitoring) -> do
            created <- case state of
              MemberAbsent -> run member (CreateDatabase db migration)
              _ -> pure Nothing
            maybe (finish (run member (SetDatabaseAccess (accessOf member db migration runtime monitoring)))) pure created
    -- Rotation: the Secret takes the new password first, then the user
    -- follows it, so a lost step never leaves a password nobody holds.
    rotate member = case member ^. #kind of
      DatabaseMember {} -> pure (AdapterEffectFailed (KnownNoEffect "only an app-database user's credential is rotated"))
      UserMember _ user secretNamespace secretName _ -> do
        secret <- readCredential ops secretNamespace secretName
        case secret of
          Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
          Right Nothing -> pure (AdapterEffectFailed (KnownNoEffect ("Secret " <> nameText secretName <> " is absent; rebuild it with inventory rebuild before rotating")))
          Right (Just _) -> do
            password' <- freshPassword ops
            written <- rewriteCredential ops secretNamespace secretName password'
            case written of
              Left reason -> pure (AdapterEffectAmbiguous reason)
              Right () -> do
                salt <- freshSalt ops
                finish (run member (SetPassword user (hashPassword (member ^. #server . #engine) salt password')))
    run member command = do
      result <- runCommand ops (member ^. #server) command
      pure (either (Just . AdapterEffectAmbiguous) (const Nothing) result)
    finish step = fromMaybe AdapterEffectCompleted <$> step
    proof plan physical = contentDigest (either (error . T.unpack) id (canonicalValue (object ["plan" .= plan, "physical" .= physical])))
    describe = \case
      MemberAbsent -> "absent"
      MemberComplete _ -> "complete"
      MemberIncomplete _ reason -> reason
      MemberDrift reason -> reason
      MemberRefused code reason -> code <> ": " <> reason
    summary actionText member =
      actionText
        <> " app-database "
        <> (if actionText == "rotate" then "credential of " else "")
        <> case member ^. #kind of
          UserMember _ user _ _ _ -> "user " <> user
          DatabaseMember db _ _ _ -> "database " <> db
        <> " on "
        <> nameText (member ^. #server . #name)
        <> (if member ^. #quiesced then " (quiesced: login off)" else if member ^. #enabled then "" else " (retired: access off)")
        <> case member ^. #kind of
          UserMember _ _ _ _ extension | actionText /= "rotate" -> describeReader (extension ^. #reader) <> describeAccess (extension ^. #access)
          DatabaseMember _ _ _ monitoring@(_ : _) -> "; tolerates grants to " <> T.intercalate ", " (map monitoringRoleToken monitoring)
          _ -> ""
    -- A reader's objects (IR-33 AC-1).
    describeReader = \case
      Nothing -> ""
      Just grant -> "; objects " <> T.intercalate ", " (map describeObject (NE.toList (grant ^. #objects)))
    describeObject = \case
      ReaderRelation db schema' relation' -> logicalDatabaseNameText db <> "." <> maybe "" ((<> ".") . schemaNameText) schema' <> relationNameText relation'
      ReaderSchemaViews db schema' -> logicalDatabaseNameText db <> "." <> schemaNameText schema' <> ".* (views)"
    -- The saved plan names each declared exception and limit (IR-30 AC-1).
    describeAccess access =
      mconcat
        [ "; exceptions " <> T.intercalate ", " (map grantExceptionToken (access ^. #exceptions))
        | not (null (access ^. #exceptions))
        ]
        <> mconcat
          [ "; limits " <> T.intercalate ", " [key <> " " <> T.show value | (key, Just value) <- limitList]
          | let limits' = access ^. #limits
                limitList =
                  [ ("maxMemoryBytes", limits' ^. #maxMemoryBytes)
                  , ("maxExecutionSeconds", limits' ^. #maxExecutionSeconds)
                  , ("maxConcurrentQueries", limits' ^. #maxConcurrentQueries)
                  , ("connectionLimit", limits' ^. #connectionLimit)
                  , ("statementTimeoutSeconds", limits' ^. #statementTimeoutSeconds)
                  , ("maxResultRows", limits' ^. #maxResultRows)
                  , ("maxResultBytes", limits' ^. #maxResultBytes)
                  , ("maxThreads", limits' ^. #maxThreads)
                  ]
          , any (isJust . snd) limitList
          ]
