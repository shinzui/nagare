-- | Load a 'Deployment' from a config-as-program source file.
--
-- The chosen substrate (EP-8) is the native Haskell eDSL: an app ships a
-- @Config.hs@ that binds and emits a 'Deployment' (via
-- 'Nagare.Dsl.Config.emitDeployment'). 'loadDeployment' compiles-and-runs that
-- file with @runghc@, captures the JSON it prints, and decodes it back into a
-- validated 'Deployment'. Every failure mode maps to a precise 'LoadError'.
module Nagare.Dsl.Load
  ( LoadError (..)
  , renderLoadError
  , ConfigTimeout (..)
  , defaultConfigTimeout
  , runConfigWith
  , loadDeployment
  , decodeDeployment
  , loadBroker
  , decodeBroker
  , loadDatabase
  , decodeDatabase
  , loadStaticSite
  , loadStaticSiteWith
  , decodeStaticSite
  , loadServerSite
  , decodeServerSite
  , loadTask
  , decodeTask
  , loadJob
  , decodeJob
  , loadWorker
  , decodeWorker
  , loadApplication
  , decodeApplication
  , SiteConfig (..)
  , loadSite
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (FromJSON (..), eitherDecodeStrict, withObject, (.!=), (.:), (.:?))
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
-- Qualified: 'timeout' is also a record field of both 'ProbeTiming'
-- (Nagare.Dsl.Worker) and 'HealthCheck' (Nagare.Dsl.Types), which are imported
-- unqualified here.

import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Nagare.Dsl.Access
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Broker
import Nagare.Dsl.Build
import Nagare.Dsl.Cdn.Types
import Nagare.Dsl.Database
import Nagare.Resource.Types (mkLogicalKey)
import Nagare.Dsl.Job
import Nagare.Dsl.Prelude
import Nagare.Dsl.Server.Types
import Nagare.Dsl.Static.Types
import Nagare.Dsl.Task
import Nagare.Dsl.Types
import Nagare.Dsl.Worker
  ( ProbeTiming (..)
  , Worker (..)
  , WorkerProbe
  , mkCommand
  , mkExecProbe
  , mkHttpProbe
  , mkProbeTiming
  , mkReplicas
  , mkTcpProbe
  )
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory)
import System.Process (readProcessWithExitCode)
import System.Timeout qualified as Timeout

-- ---------------------------------------------------------------------------
-- LoadError

-- | Every way loading a config-as-program file can fail.
data LoadError
  = -- | the config source file does not exist
    FileNotFound !FilePath
  | -- | the config failed to compile or crashed at run time (carries the GHC
    -- / runtime diagnostic stderr from the subprocess)
    CompileError !FilePath !Text
  | -- | the config compiled and ran but printed nothing — it never called
    -- 'Nagare.Dsl.Config.emitDeployment'
    MissingBinding !FilePath
  | -- | the emitted JSON decoded but a field failed an EP-9 smart constructor
    -- (field name, message)
    MarshalError !Text !Text
  | -- | the config emitted a different @kind@ than the loader expected, e.g. a
    -- config that calls 'Nagare.Dsl.Config.emitDeployment' loaded under
    -- @nagarectl site deploy@, or a @ServerSite@ where a @StaticSite@ was
    -- expected (expected kind, actual kind)
    UnexpectedKind !Text !Text
  | -- | the config was still running when its time budget expired and was
    -- killed (source path, budget in seconds). A config-as-program is ordinary
    -- Haskell, so it can loop or block forever; without a bound that wedges
    -- whichever thread loaded it — for @nagared@, a webhook handler.
    LoadTimedOut !FilePath !Int
  deriving stock (Generic, Eq, Show)

-- | Render a 'LoadError' as a single line (or short block) for the terminal.
renderLoadError :: LoadError -> Text
renderLoadError = \case
  FileNotFound path ->
    "nagare: config file not found: " <> Text.pack path
  CompileError path msg ->
    "nagare: compile error in " <> Text.pack path <> ":\n  " <> msg
  MissingBinding path ->
    "nagare: " <> Text.pack path <> " compiled but did not produce a 'deployment' value"
  MarshalError field msg ->
    "nagare: field '" <> field <> "' failed validation: " <> msg
  UnexpectedKind expected got ->
    "nagare: config emitted a '"
      <> got
      <> "' but '"
      <> expected
      <> "' was expected (did it call the wrong emit* function?)"
  LoadTimedOut path seconds ->
    "nagare: config "
      <> Text.pack path
      <> " timed out after "
      <> Text.pack (show seconds)
      <> "s (does it loop or block?)"

-- ---------------------------------------------------------------------------
-- Execution budget

-- | How long a config-as-program may run before it is killed, in whole seconds.
newtype ConfigTimeout = ConfigTimeout {seconds :: Int}
  deriving stock (Generic, Eq, Show)

-- | The budget every loader uses unless a caller says otherwise: two minutes,
-- comfortably more than a cold @runghc@ compile of a realistic config and far
-- less than "forever".
defaultConfigTimeout :: ConfigTimeout
defaultConfigTimeout = ConfigTimeout 120

-- ---------------------------------------------------------------------------
-- JSON intermediate (mirrors Nagare.Dsl.Config's emitted shape)

data JsonEnvEntry = JsonEnvEntry
  { varName :: !Text
  , kind :: !Text
  , value :: !(Maybe Text)
  , secretName :: !(Maybe Text)
  , scopes :: !(Maybe [Text])
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonEnvEntry where
  parseJSON = withObject "EnvEntry" $ \o ->
    JsonEnvEntry
      <$> o .: "varName"
      <*> o .: "kind"
      <*> o .:? "value"
      <*> o .:? "secretName"
      <*> o .:? "scopes"

-- | One entry of the @volumes@ array (mirrors 'Nagare.Dsl.Config'). Every
-- accessor is optional except the three required fields so a partial object is
-- reported as a precise 'MarshalError' rather than an aeson parse error; the
-- defaults mirror 'Nagare.Dsl.Presets.attachVolume' (RWO, not read-only,
-- Retain).
data JsonVolume = JsonVolume
  { name :: !Text
  , logicalKey :: !(Maybe Text)
  , size :: !Text
  , mountPath :: !Text
  , accessMode :: !(Maybe Text)
  , readOnly :: !Bool
  , retention :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonVolume where
  parseJSON = withObject "Volume" $ \o ->
    JsonVolume
      <$> o .: "name"
      <*> o .:? "logicalKey"
      <*> o .: "size"
      <*> o .: "mountPath"
      <*> o .:? "accessMode"
      <*> o .:? "readOnly" .!= False
      <*> o .:? "retention"

-- | The @build@ sub-object: a @"kind"@ discriminator plus the per-kind fields.
-- A 'PrebuiltImage' carries @tag@; a @DockerfileBuild@ carries
-- @dockerfile@/@context@/@buildArgs@; a @NixpacksBuild@ carries
-- @context@/@buildArgs@. All field accessors are optional so a precise
-- 'MarshalError' (rather than an aeson parse error) is produced when a required
-- field for a given kind is missing.
data JsonBuildSpec = JsonBuildSpec
  { kind :: !Text
  , tag :: !(Maybe Text)
  , dockerfile :: !(Maybe Text)
  , context :: !(Maybe Text)
  , buildArgs :: !(Map.Map Text Text)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonBuildSpec where
  parseJSON = withObject "BuildSpec" $ \o ->
    JsonBuildSpec
      <$> o .: "kind"
      <*> o .:? "tag"
      <*> o .:? "dockerfile"
      <*> o .:? "context"
      <*> o .:? "buildArgs" .!= mempty

-- | One entry of the @domains@ array: a hostname and its canonical marker.
-- @canonical@ defaults to 'False' when absent (an old single-domain config that
-- has been migrated, or hand-written JSON).
data JsonDomainTls = JsonDomainTls
  { mode :: !Text
  , secretName :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonDomainTls where
  parseJSON = withObject "DomainTls" $ \o ->
    JsonDomainTls
      <$> o .: "mode"
      <*> o .:? "secretName"

data JsonDomainSpec = JsonDomainSpec
  { domain :: !Text
  , canonical :: !Bool
  , tls :: !(Maybe JsonDomainTls)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonDomainSpec where
  parseJSON = withObject "DomainSpec" $ \o ->
    JsonDomainSpec
      <$> o .: "domain"
      <*> o .:? "canonical" .!= False
      <*> o .:? "tls"

data JsonDomainEntry
  = JsonDomainObject !JsonDomainSpec
  | JsonDomainString !Text
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonDomainEntry where
  parseJSON value =
    (JsonDomainObject <$> parseJSON value)
      <|> (JsonDomainString <$> parseJSON value)

-- | Decode either the shared object representation or a complete legacy
-- string array. Legacy arrays preserve their historical first-entry canonical
-- behavior; mixed arrays are rejected so their canonical semantics cannot be
-- ambiguous.
toDomainSpecs :: Text -> [JsonDomainEntry] -> Either LoadError [DomainSpec]
toDomainSpecs _ [] = Right []
toDomainSpecs field entries
  | Just hosts <- traverse legacyHost entries =
      first (MarshalError field) $ mkDomains (zipWith (\i host -> (host, i == (0 :: Int))) [0 ..] hosts)
  | Just specs <- traverse objectSpec entries = do
      domains' <-
        first (MarshalError field) $
          mkDomains [(host, isCanonical) | JsonDomainSpec host isCanonical _ <- specs]
      traverse applyTls (zip specs domains')
  | otherwise = Left (MarshalError field "domain entries must be either all strings or all objects")
  where
    legacyHost (JsonDomainString host) = Just host
    legacyHost _ = Nothing
    objectSpec (JsonDomainObject spec) = Just spec
    objectSpec _ = Nothing

    applyTls (JsonDomainSpec _ _ Nothing, spec) = Right spec
    applyTls (JsonDomainSpec _ _ (Just (JsonDomainTls "automatic" Nothing)), spec) = Right spec
    applyTls (JsonDomainSpec _ _ (Just (JsonDomainTls "automatic" (Just _))), _) =
      Left (MarshalError field "automatic TLS must not name a supplied secret")
    applyTls (JsonDomainSpec _ _ (Just (JsonDomainTls "supplied-secret" Nothing)), _) =
      Left (MarshalError field "supplied-secret TLS requires secretName")
    applyTls (JsonDomainSpec _ _ (Just (JsonDomainTls "supplied-secret" (Just rawSecret))), spec) = do
      secret <- first (MarshalError field) (mkSecretName rawSecret)
      Right (withTlsSecret secret spec)
    applyTls (JsonDomainSpec _ _ (Just (JsonDomainTls unknownMode _)), _) =
      Left (MarshalError field ("unknown domain TLS mode: " <> unknownMode))

-- | The @healthCheck@ sub-object (see 'Nagare.Dsl.Config'). Every field is
-- optional so a partial object is reported as a precise 'MarshalError' by
-- 'mkHealthCheck' rather than an aeson parse error; the defaults mirror
-- 'httpHealthCheck'.
data JsonHealthCheck = JsonHealthCheck
  { path :: !Text
  , checkPort :: !(Maybe Int)
  , scheme :: !Text
  , expectedStatus :: !Int
  , initialDelay :: !Int
  , period :: !Int
  , timeout :: !Int
  , failureThreshold :: !Int
  , asLiveness :: !Bool
  , asStartup :: !Bool
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonHealthCheck where
  parseJSON = withObject "HealthCheck" $ \o ->
    JsonHealthCheck
      <$> o .: "path"
      <*> o .:? "checkPort"
      <*> o .:? "scheme" .!= "HTTP"
      <*> o .:? "expectedStatus" .!= 200
      <*> o .:? "initialDelay" .!= 0
      <*> o .:? "period" .!= 10
      <*> o .:? "timeout" .!= 1
      <*> o .:? "failureThreshold" .!= 3
      <*> o .:? "asLiveness" .!= False
      <*> o .:? "asStartup" .!= False

data JsonDeployment = JsonDeployment
  { name :: !Text
  , logicalKey :: !(Maybe Text)
  , namespace :: !Text
  , image :: !Text
  , build :: !(Maybe JsonBuildSpec)
  , domains :: ![JsonDomainEntry]
  , port :: !Int
  , env :: ![JsonEnvEntry]
  , cpuRequest :: !(Maybe Text)
  , memoryRequest :: !(Maybe Text)
  , cpuLimit :: !(Maybe Text)
  , memoryLimit :: !(Maybe Text)
  , scaleMin :: !(Maybe Int)
  , scaleMax :: !(Maybe Int)
  , healthCheck :: !(Maybe JsonHealthCheck)
  , volumes :: ![JsonVolume]
  , databases :: ![Text]
  , brokers :: ![JsonBrokerBinding]
  , access :: !(Maybe JsonAccessPolicy)
  , tasks :: ![JsonTask]
  , cdn :: !(Maybe JsonCdn)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonDeployment where
  parseJSON = withObject "Deployment" $ \o ->
    JsonDeployment
      <$> o .: "name"
      <*> o .:? "logicalKey"
      <*> o .: "namespace"
      <*> o .: "image"
      <*> o .:? "build"
      <*> o .:? "domains" .!= []
      <*> o .: "port"
      <*> o .: "env"
      <*> o .:? "cpuRequest"
      <*> o .:? "memoryRequest"
      <*> o .:? "cpuLimit"
      <*> o .:? "memoryLimit"
      <*> o .:? "scaleMin"
      <*> o .:? "scaleMax"
      <*> o .:? "healthCheck"
      <*> o .:? "volumes" .!= []
      <*> o .:? "databases" .!= []
      <*> o .:? "brokers" .!= []
      <*> o .:? "access"
      <*> o .:? "tasks" .!= []
      <*> o .:? "cdn"

-- ---------------------------------------------------------------------------
-- Marshalling JsonDeployment -> Deployment (re-runs EP-9 smart constructors)

toDeployment :: JsonDeployment -> Either LoadError Deployment
toDeployment jd = do
  name' <- first (MarshalError "name") $ mkServiceName (jd ^. #name)
  logicalKey' <- traverse (first (MarshalError "logicalKey") . mkLogicalKey) (jd ^. #logicalKey)
  ns' <- first (MarshalError "namespace") $ mkNamespace (jd ^. #namespace)
  img' <- first (MarshalError "image") $ mkImageRef (jd ^. #image)
  build' <- case jd ^. #build of
    Nothing -> first (MarshalError "build") defaultBuild
    Just jb -> toBuildSpec jb
  domains' <- toDomainSpecs "domains" (jd ^. #domains)
  port' <- first (MarshalError "port") $ mkPort (jd ^. #port)
  env' <- mapM toEnvEntry (jd ^. #env)
  res' <- toResources jd
  hc' <- toHealthCheck (jd ^. #healthCheck)
  vols' <- toVolumes (jd ^. #volumes)
  dbRefs' <- traverse (first (MarshalError "databases") . mkDatabaseName) (jd ^. #databases)
  brokerRefs' <- traverse (toBrokerBinding "brokers") (jd ^. #brokers)
  access' <- traverse toAccessPolicy (jd ^. #access)
  -- MasterPlan 10 / EP-52: re-validate each co-located task (re-runs every smart
  -- constructor, including EP-50's inherit-image-requires-an-app invariant), then
  -- enforce the two deploy-level cross-task invariants.
  tasks' <- mapM toTask (jd ^. #tasks)
  -- Invariant 1: no two co-located tasks share a name.
  case firstDuplicate (map (serviceNameText . (^. #name)) tasks') of
    Just dup -> Left (MarshalError "tasks" ("duplicate task name: " <> dup))
    Nothing -> Right ()
  -- Invariant 2: a co-located task that names an app must name THIS app.
  let thisApp = serviceNameText name'
  mapM_ (checkTaskApp thisApp) tasks'
  scale' <- case (jd ^. #scaleMin, jd ^. #scaleMax) of
    (Nothing, Nothing) -> Right Nothing
    (Just mn, Just mx) -> fmap Just . first (MarshalError "scale") $ mkScale mn mx
    _ ->
      Left
        ( MarshalError
            "scale"
            "scaleMin and scaleMax must both be present or both absent"
        )
  cdn' <- traverse toCdn (jd ^. #cdn)
  Right
    Deployment
      { name = name'
      , logicalKey = logicalKey'
      , namespace = ns'
      , image = img'
      , build = build'
      , domains = domains'
      , port = port'
      , env = Map.fromList env'
      , resources = res'
      , scale = scale'
      , healthCheck = hc'
      , volumes = vols'
      , databases = dbRefs'
      , brokers = brokerRefs'
      , access = access'
      , tasks = tasks'
      , cdn = cdn'
      }

data JsonAccessPolicy = JsonAccessPolicy
  { audience :: !(Maybe Text)
  , permission :: !Text
  , role :: !Text
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonAccessPolicy where
  parseJSON = withObject "AccessPolicy" $ \o ->
    JsonAccessPolicy
      <$> o .:? "audience"
      <*> o .:? "permission" .!= "access"
      <*> o .:? "role" .!= "protected"

toAccessPolicy :: JsonAccessPolicy -> Either LoadError AccessPolicy
toAccessPolicy j = do
  audience' <- traverse (first (MarshalError "access.audience") . mkAudience) (j ^. #audience)
  permission' <- first (MarshalError "access.permission") $ mkAccessPermission (j ^. #permission)
  role' <- case j ^. #role of
    "protected" -> Right ProtectedSite
    "portal" -> Right AuthPortal
    other -> Left (MarshalError "access.role" ("unknown access role: " <> other))
  Right AccessPolicy {audience = audience', permission = permission', role = role'}

-- | Re-validate a decoded @build@ sub-object back into a 'BuildSpec', dispatching
-- on its @kind@ and re-running the smart constructors. A missing per-kind field
-- or an unknown kind is reported as a precise 'MarshalError' (mirroring
-- 'toStaticBuild').
toBuildSpec :: JsonBuildSpec -> Either LoadError BuildSpec
toBuildSpec jb = case jb ^. #kind of
  "PrebuiltImage" -> do
    tag <-
      maybe (Left (MarshalError "build" "PrebuiltImage entry missing 'tag' field")) Right $
        jb ^. #tag
    fmap PrebuiltImage . first (MarshalError "build.tag") $ mkTag tag
  "DockerfileBuild" -> do
    df <-
      maybe (Left (MarshalError "build" "DockerfileBuild entry missing 'dockerfile' field")) Right $
        jb ^. #dockerfile
    ctx <-
      maybe (Left (MarshalError "build" "DockerfileBuild entry missing 'context' field")) Right $
        jb ^. #context
    df' <- first (MarshalError "build.dockerfile") $ mkFilePathText df
    ctx' <- first (MarshalError "build.context") $ mkFilePathText ctx
    Right (DockerfileBuild {dockerfile = df', context = ctx', buildArgs = jb ^. #buildArgs})
  "NixpacksBuild" -> do
    ctx <-
      maybe (Left (MarshalError "build" "NixpacksBuild entry missing 'context' field")) Right $
        jb ^. #context
    ctx' <- first (MarshalError "build.context") $ mkFilePathText ctx
    Right (NixpacksBuild {context = ctx', buildArgs = jb ^. #buildArgs})
  other -> Left (MarshalError "build.kind" ("unknown build kind: " <> other))

-- | Decode a single scope token, rejecting any unknown value with a precise
-- 'MarshalError'. The tokens are the capitalized 'Show' 'EnvScope' names.
parseScope :: Text -> Text -> Either LoadError EnvScope
parseScope var t = case t of
  "Runtime" -> Right Runtime
  "Build" -> Right Build
  "Preview" -> Right Preview
  other -> Left (MarshalError ("env." <> var <> ".scopes") ("unknown env scope: " <> other))

toEnvEntry :: JsonEnvEntry -> Either LoadError (EnvName, ScopedEnvVar)
toEnvEntry e = do
  n <- first (MarshalError "env.varName") $ mkEnvName (e ^. #varName)
  v <- case e ^. #kind of
    "Literal" -> case e ^. #value of
      Nothing -> Left (MarshalError ("env." <> e ^. #varName) "Literal entry missing 'value' field")
      Just lit -> Right (EnvLiteral lit)
    "SecretRef" -> case e ^. #secretName of
      Nothing -> Left (MarshalError ("env." <> e ^. #varName) "SecretRef entry missing 'secretName' field")
      Just sec ->
        fmap EnvSecretRef
          . first (MarshalError ("env." <> e ^. #varName <> ".secretRef"))
          $ mkSecretName sec
    other -> Left (MarshalError ("env." <> e ^. #varName <> ".kind") ("unknown env kind: " <> other))
  scopeList <- traverse (parseScope (e ^. #varName)) (fromMaybe [] (e ^. #scopes))
  let scopeSet = Set.fromList scopeList
      finalScopes = if Set.null scopeSet then Set.singleton Runtime else scopeSet
  sev <- first (MarshalError ("env." <> e ^. #varName <> ".scopes")) (scopedEnv finalScopes v)
  Right (n, sev)

toResources :: JsonDeployment -> Either LoadError (Maybe Resources)
toResources jd =
  case (jd ^. #cpuRequest, jd ^. #memoryRequest, jd ^. #cpuLimit, jd ^. #memoryLimit) of
    (Nothing, Nothing, Nothing, Nothing) -> Right Nothing
    (c, m, cl, ml) -> do
      c' <- traverse (first (MarshalError "cpuRequest") . mkQuantity) c
      m' <- traverse (first (MarshalError "memoryRequest") . mkQuantity) m
      cl' <- traverse (first (MarshalError "cpuLimit") . mkQuantity) cl
      ml' <- traverse (first (MarshalError "memoryLimit") . mkQuantity) ml
      Right (Just Resources {cpu = c', memory = m', cpuLimit = cl', memoryLimit = ml'})

-- | Re-validate a decoded @healthCheck@ sub-object back into a 'HealthCheck'.
-- The scheme string and probe port go through their constructors; the assembled
-- record is then re-checked by 'mkHealthCheck'. Any failure is a precise
-- 'MarshalError "healthCheck"'.
toHealthCheck :: Maybe JsonHealthCheck -> Either LoadError (Maybe HealthCheck)
toHealthCheck Nothing = Right Nothing
toHealthCheck (Just jhc) = do
  scheme' <- case jhc ^. #scheme of
    "HTTP" -> Right HTTP
    "HTTPS" -> Right HTTPS
    other -> Left (MarshalError "healthCheck.scheme" ("unknown scheme: " <> other))
  checkPort' <- traverse (first (MarshalError "healthCheck.checkPort") . mkPort) (jhc ^. #checkPort)
  fmap Just . first (MarshalError "healthCheck") $
    mkHealthCheck
      HealthCheck
        { path = jhc ^. #path
        , checkPort = checkPort'
        , scheme = scheme'
        , expectedStatus = jhc ^. #expectedStatus
        , initialDelay = jhc ^. #initialDelay
        , period = jhc ^. #period
        , timeout = jhc ^. #timeout
        , failureThreshold = jhc ^. #failureThreshold
        , asLiveness = jhc ^. #asLiveness
        , asStartup = jhc ^. #asStartup
        }

-- | The first element that appears more than once in the list, in order, or
-- 'Nothing' when all elements are unique. Used to reject duplicate co-located
-- task names (MasterPlan 10 / EP-52).
firstDuplicate :: (Ord a) => [a] -> Maybe a
firstDuplicate = go Set.empty
  where
    go _ [] = Nothing
    go seen (x : xs)
      | x `Set.member` seen = Just x
      | otherwise = go (Set.insert x seen) xs

-- | Deploy-level invariant (MasterPlan 10 / EP-52): a co-located task that names
-- an app via @app@ must name the enclosing app, not some other app.
checkTaskApp :: Text -> Task -> Either LoadError ()
checkTaskApp thisApp tk =
  case tk ^. #app of
    Just a
      | serviceNameText a /= thisApp ->
          Left
            ( MarshalError
                "tasks"
                ( "task '"
                    <> serviceNameText (tk ^. #name)
                    <> "' references app '"
                    <> serviceNameText a
                    <> "' but is co-located under app '"
                    <> thisApp
                    <> "'"
                )
            )
    _ -> Right ()

-- | Re-validate one decoded @volumes@ entry back into a 'Volume', re-running the
-- leaf smart constructors and decoding the access-mode / retention enums. Any
-- failure is a precise 'MarshalError' keyed by the sub-field.
toVolume :: JsonVolume -> Either LoadError Volume
toVolume jv = do
  vn <- first (MarshalError "volumes.name") $ mkVolumeName (jv ^. #name)
  logicalKey' <- traverse (first (MarshalError "volumes.logicalKey") . mkLogicalKey) (jv ^. #logicalKey)
  sz <- first (MarshalError "volumes.size") $ mkQuantity (jv ^. #size)
  mp <- first (MarshalError "volumes.mountPath") $ mkMountPath (jv ^. #mountPath)
  am <- case fromMaybe "ReadWriteOnce" (jv ^. #accessMode) of
    "ReadWriteOnce" -> Right ReadWriteOnce
    other -> Left (MarshalError "volumes.accessMode" ("unknown access mode: " <> other))
  rp <- case fromMaybe "Retain" (jv ^. #retention) of
    "Retain" -> Right Retain
    "Delete" -> Right Delete
    other -> Left (MarshalError "volumes.retention" ("unknown retention policy: " <> other))
  Right
    Volume
      { name = vn
      , logicalKey = logicalKey'
      , size = sz
      , mountPath = mp
      , accessMode = am
      , readOnly = jv ^. #readOnly
      , retention = rp
      }

-- | Re-validate the @volumes@ array and enforce the two cross-field uniqueness
-- invariants (no duplicate volume name, no duplicate mount path) that the pure
-- 'Volume' constructor cannot — producing a precise 'MarshalError "volumes"' on
-- a clash. This is the load-time check 'Nagare.Dsl.Presets.attachVolume' defers.
toVolumes :: [JsonVolume] -> Either LoadError [Volume]
toVolumes jvs = do
  vols <- traverse toVolume jvs
  let names = map (volumeNameText . (^. #name)) vols
      paths = map (mountPathText . (^. #mountPath)) vols
  ensureUnique "duplicate volume name" names
  ensureUnique "duplicate mount path" paths
  Right vols
  where
    ensureUnique msg xs =
      case firstDup xs of
        Nothing -> Right ()
        Just d -> Left (MarshalError "volumes" (msg <> ": " <> d))
    firstDup = go Set.empty
      where
        go _ [] = Nothing
        go seen (x : xs)
          | Set.member x seen = Just x
          | otherwise = go (Set.insert x seen) xs

-- ---------------------------------------------------------------------------
-- Decoding and loading

-- | Decode the JSON a config program emits (via
-- 'Nagare.Dsl.Config.emitDeployment') into a validated 'Deployment', re-running
-- EP-9's smart constructors. Exposed so the marshalling / 'MarshalError' path
-- can be unit-tested without spawning a subprocess.
decodeDeployment :: ByteString -> Either LoadError Deployment
decodeDeployment bs =
  case eitherDecodeStrict bs of
    Left perr ->
      Left (MarshalError "json" ("could not decode config output: " <> Text.pack perr))
    Right (JsonKindEnvelope envelopeKind) -> case envelopeKind of
      -- A Deployment carries no top-level "kind"; any kinded object (Database,
      -- StaticSite, ServerSite) loaded under `nagarectl deploy` fails precisely.
      Nothing -> case eitherDecodeStrict bs of
        Left perr ->
          Left (MarshalError "json" ("could not decode deployment: " <> Text.pack perr))
        Right jd -> toDeployment jd
      Just other -> Left (UnexpectedKind "Deployment" other)

-- ---------------------------------------------------------------------------
-- JSON intermediate for brokers (mirrors Nagare.Dsl.Config's emitted shape)

data JsonBrokerTopic = JsonBrokerTopic
  { name :: !Text
  , partitions :: !Int
  , replicationFactor :: !Int
  , retentionMs :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonBrokerTopic where
  parseJSON = withObject "BrokerTopic" $ \o ->
    JsonBrokerTopic
      <$> o .: "name"
      <*> o .:? "partitions" .!= 1
      <*> o .:? "replicationFactor" .!= 1
      <*> o .:? "retentionMs"

data JsonBrokerBinding = JsonBrokerBinding
  { name :: !Text
  , topics :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonBrokerBinding where
  parseJSON = withObject "BrokerBinding" $ \o ->
    JsonBrokerBinding
      <$> o .: "name"
      <*> o .:? "topics" .!= []

data JsonBroker = JsonBroker
  { name :: !Text
  , logicalKey :: !(Maybe Text)
  , provider :: !Text
  , version :: !Text
  , namespace :: !Text
  , storageSize :: !Text
  , cpuRequest :: !(Maybe Text)
  , memoryRequest :: !(Maybe Text)
  , cpuLimit :: !(Maybe Text)
  , memoryLimit :: !(Maybe Text)
  , redpandaSmp :: !(Maybe Int)
  , redpandaMemory :: !(Maybe Text)
  , topics :: ![JsonBrokerTopic]
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonBroker where
  parseJSON = withObject "Broker" $ \o ->
    JsonBroker
      <$> o .: "name"
      <*> o .:? "logicalKey"
      <*> o .: "provider"
      <*> o .: "version"
      <*> o .: "namespace"
      <*> o .: "storageSize"
      <*> o .:? "cpuRequest"
      <*> o .:? "memoryRequest"
      <*> o .:? "cpuLimit"
      <*> o .:? "memoryLimit"
      <*> o .:? "redpandaSmp"
      <*> o .:? "redpandaMemory"
      <*> o .:? "topics" .!= []

toBroker :: JsonBroker -> Either LoadError Broker
toBroker j = do
  name' <- first (MarshalError "name") $ mkBrokerName (j ^. #name)
  logicalKey' <- traverse (first (MarshalError "logicalKey") . mkLogicalKey) (j ^. #logicalKey)
  provider' <- case parseBrokerProvider (j ^. #provider) of
    Just p -> Right p
    Nothing -> Left (MarshalError "provider" ("unknown broker provider: " <> j ^. #provider))
  version' <- first (MarshalError "version") $ mkBrokerVersion provider' (j ^. #version)
  namespace' <- first (MarshalError "namespace") $ mkNamespace (j ^. #namespace)
  storageSize' <- first (MarshalError "storageSize") $ mkQuantity (j ^. #storageSize)
  resources' <- toBrokerResources j
  redpandaMemory' <- traverse (first (MarshalError "redpandaMemory") . mkQuantity) (j ^. #redpandaMemory)
  sizing' <- first (MarshalError "sizing") $ mkBrokerSizing (Just storageSize') resources' (j ^. #redpandaSmp) redpandaMemory'
  topics' <- traverse toBrokerTopic (j ^. #topics)
  Right
    Broker
      { name = name'
      , logicalKey = logicalKey'
      , provider = provider'
      , version = version'
      , namespace = namespace'
      , storageSize = storageSize'
      , sizing = sizing'
      , topics = topics'
      }

toBrokerTopic :: JsonBrokerTopic -> Either LoadError BrokerTopic
toBrokerTopic j = do
  name' <- first (MarshalError "topics.name") $ mkTopicName (j ^. #name)
  first (MarshalError "topics") $
    mkBrokerTopic name' (j ^. #partitions) (j ^. #replicationFactor) (j ^. #retentionMs)

toBrokerBinding :: Text -> JsonBrokerBinding -> Either LoadError BrokerBinding
toBrokerBinding path (JsonBrokerBinding rawName rawTopics) = do
  name' <- first (MarshalError (path <> ".name")) $ mkBrokerName rawName
  topics' <- traverse (first (MarshalError (path <> ".topics")) . mkTopicName) rawTopics
  Right BrokerBinding {name = name', topics = topics'}

toBrokerResources :: JsonBroker -> Either LoadError (Maybe Resources)
toBrokerResources j =
  case (j ^. #cpuRequest, j ^. #memoryRequest, j ^. #cpuLimit, j ^. #memoryLimit) of
    (Nothing, Nothing, Nothing, Nothing) -> Right Nothing
    (c, m, cl, ml) -> do
      c' <- traverse (first (MarshalError "cpuRequest") . mkQuantity) c
      m' <- traverse (first (MarshalError "memoryRequest") . mkQuantity) m
      cl' <- traverse (first (MarshalError "cpuLimit") . mkQuantity) cl
      ml' <- traverse (first (MarshalError "memoryLimit") . mkQuantity) ml
      Right (Just Resources {cpu = c', memory = m', cpuLimit = cl', memoryLimit = ml'})

decodeBroker :: ByteString -> Either LoadError Broker
decodeBroker bs =
  case eitherDecodeStrict bs of
    Left perr ->
      Left (MarshalError "json" ("could not decode config output: " <> Text.pack perr))
    Right (JsonKindEnvelope envelopeKind) -> case envelopeKind of
      Just "Broker" -> case eitherDecodeStrict bs of
        Left perr ->
          Left (MarshalError "json" ("could not decode broker: " <> Text.pack perr))
        Right jb -> toBroker jb
      Just other -> Left (UnexpectedKind "Broker" other)
      Nothing -> Left (UnexpectedKind "Broker" "<none>")

-- ---------------------------------------------------------------------------
-- JSON intermediate for databases (mirrors Nagare.Dsl.Config's emitted shape)

data JsonDatabase = JsonDatabase
  { name :: !Text
  , logicalKey :: !(Maybe Text)
  , engine :: !Text
  , version :: !Text
  , namespace :: !Text
  , size :: !Text
  , cpuRequest :: !(Maybe Text)
  , memoryRequest :: !(Maybe Text)
  , cpuLimit :: !(Maybe Text)
  , memoryLimit :: !(Maybe Text)
  , retention :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonDatabase where
  parseJSON = withObject "Database" $ \o ->
    JsonDatabase
      <$> o .: "name"
      <*> o .:? "logicalKey"
      <*> o .: "engine"
      <*> o .: "version"
      <*> o .: "namespace"
      <*> o .: "size"
      <*> o .:? "cpuRequest"
      <*> o .:? "memoryRequest"
      <*> o .:? "cpuLimit"
      <*> o .:? "memoryLimit"
      <*> o .:? "retention"

toDatabase :: JsonDatabase -> Either LoadError Database
toDatabase j = do
  name' <- first (MarshalError "name") $ mkDatabaseName (j ^. #name)
  key' <- traverse (first (MarshalError "logicalKey") . mkLogicalKey) (j ^. #logicalKey)
  eng' <- case parseEngine (j ^. #engine) of
    Just e -> Right e
    Nothing -> Left (MarshalError "engine" ("unknown engine: " <> j ^. #engine))
  ver' <- first (MarshalError "version") $ mkEngineVersion eng' (j ^. #version)
  ns' <- first (MarshalError "namespace") $ mkNamespace (j ^. #namespace)
  size' <- first (MarshalError "size") $ mkQuantity (j ^. #size)
  res' <- toDbResources j
  ret' <- case fromMaybe "Retain" (j ^. #retention) of
    "Retain" -> Right Retain
    "Delete" -> Right Delete
    other -> Left (MarshalError "retention" ("unknown retention policy: " <> other))
  Right
    Database
      { name = name'
      , logicalKey = key'
      , engine = eng'
      , version = ver'
      , namespace = ns'
      , size = size'
      , resources = res'
      , retention = ret'
      }

toDbResources :: JsonDatabase -> Either LoadError (Maybe Resources)
toDbResources j =
  case (j ^. #cpuRequest, j ^. #memoryRequest, j ^. #cpuLimit, j ^. #memoryLimit) of
    (Nothing, Nothing, Nothing, Nothing) -> Right Nothing
    (c, m, cl, ml) -> do
      c' <- traverse (first (MarshalError "cpuRequest") . mkQuantity) c
      m' <- traverse (first (MarshalError "memoryRequest") . mkQuantity) m
      cl' <- traverse (first (MarshalError "cpuLimit") . mkQuantity) cl
      ml' <- traverse (first (MarshalError "memoryLimit") . mkQuantity) ml
      Right (Just Resources {cpu = c', memory = m', cpuLimit = cl', memoryLimit = ml'})

-- | Decode the JSON a database config emits (via
-- 'Nagare.Dsl.Config.emitDatabase') into a validated 'Database'. The top-level
-- @kind@ is checked first: a missing or non-@Database@ kind is 'UnexpectedKind'.
decodeDatabase :: ByteString -> Either LoadError Database
decodeDatabase bs =
  case eitherDecodeStrict bs of
    Left perr ->
      Left (MarshalError "json" ("could not decode config output: " <> Text.pack perr))
    Right (JsonKindEnvelope envelopeKind) -> case envelopeKind of
      Just "Database" -> case eitherDecodeStrict bs of
        Left perr ->
          Left (MarshalError "json" ("could not decode database: " <> Text.pack perr))
        Right jdb -> toDatabase jdb
      Just other -> Left (UnexpectedKind "Database" other)
      Nothing -> Left (UnexpectedKind "Database" "<none>")

-- ---------------------------------------------------------------------------
-- JSON intermediate for tasks (mirrors Nagare.Dsl.Config's emitted shape)

-- | The intermediate decode shape for a 'Task' (mirrors 'Nagare.Dsl.Config'\'s
-- @taskJSON@). Optional fields carry their model defaults so a partial object
-- is a precise 'MarshalError', not an aeson parse error.
data JsonTask = JsonTask
  { name :: !Text
  , namespace :: !Text
  , schedule :: !Text
  , image :: !(Maybe Text)
  , app :: !(Maybe Text)
  , command :: ![Text]
  , args :: ![Text]
  , env :: ![JsonEnvEntry]
  , cpuRequest :: !(Maybe Text)
  , memoryRequest :: !(Maybe Text)
  , cpuLimit :: !(Maybe Text)
  , memoryLimit :: !(Maybe Text)
  , timeoutSeconds :: !(Maybe Int)
  , concurrencyPolicy :: !(Maybe Text)
  , restartPolicy :: !(Maybe Text)
  , backoffLimit :: !(Maybe Int)
  , successfulJobsHistoryLimit :: !(Maybe Int)
  , failedJobsHistoryLimit :: !(Maybe Int)
  , startingDeadlineSeconds :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonTask where
  parseJSON = withObject "Task" $ \o ->
    JsonTask
      <$> o .: "name"
      <*> o .: "namespace"
      <*> o .: "schedule"
      <*> o .:? "image"
      <*> o .:? "app"
      <*> o .:? "command" .!= []
      <*> o .:? "args" .!= []
      <*> o .:? "env" .!= []
      <*> o .:? "cpuRequest"
      <*> o .:? "memoryRequest"
      <*> o .:? "cpuLimit"
      <*> o .:? "memoryLimit"
      <*> o .:? "timeoutSeconds"
      <*> o .:? "concurrencyPolicy"
      <*> o .:? "restartPolicy"
      <*> o .:? "backoffLimit"
      <*> o .:? "successfulJobsHistoryLimit"
      <*> o .:? "failedJobsHistoryLimit"
      <*> o .:? "startingDeadlineSeconds"

-- | Re-validate a decoded task: re-run every smart constructor, decode the
-- enum tokens, default the numeric fields, and finally re-check the assembled
-- record with 'mkTask' (which enforces the bounds and the command-or-app
-- cross-field invariant). Any failure is a precise 'MarshalError' keyed by the
-- field.
toTask :: JsonTask -> Either LoadError Task
toTask j = do
  name' <- first (MarshalError "name") $ mkServiceName (j ^. #name)
  ns' <- first (MarshalError "namespace") $ mkNamespace (j ^. #namespace)
  sched' <- first (MarshalError "schedule") $ mkSchedule (j ^. #schedule)
  img' <- traverse (first (MarshalError "image") . mkImageRef) (j ^. #image)
  app' <- traverse (first (MarshalError "app") . mkServiceName) (j ^. #app)
  env' <- mapM toEnvEntry (j ^. #env)
  res' <- toTaskResources j
  cp' <- case parseConcurrencyPolicy (fromMaybe "Forbid" (j ^. #concurrencyPolicy)) of
    Just p -> Right p
    Nothing ->
      Left
        ( MarshalError
            "concurrencyPolicy"
            ("unknown concurrency policy: " <> fromMaybe "" (j ^. #concurrencyPolicy))
        )
  rp' <- case parseRestartPolicy (fromMaybe "Never" (j ^. #restartPolicy)) of
    Just p -> Right p
    Nothing ->
      Left
        ( MarshalError
            "restartPolicy"
            ("unknown restart policy: " <> fromMaybe "" (j ^. #restartPolicy))
        )
  first (MarshalError "task") $
    mkTask
      Task
        { name = name'
        , namespace = ns'
        , schedule = sched'
        , image = img'
        , app = app'
        , command = j ^. #command
        , args = j ^. #args
        , env = Map.fromList env'
        , resources = res'
        , timeoutSeconds = j ^. #timeoutSeconds
        , concurrencyPolicy = cp'
        , restartPolicy = rp'
        , backoffLimit = fromMaybe 0 (j ^. #backoffLimit)
        , successfulJobsHistoryLimit = fromMaybe 3 (j ^. #successfulJobsHistoryLimit)
        , failedJobsHistoryLimit = fromMaybe 1 (j ^. #failedJobsHistoryLimit)
        , startingDeadlineSeconds = j ^. #startingDeadlineSeconds
        }

toTaskResources :: JsonTask -> Either LoadError (Maybe Resources)
toTaskResources j =
  case (j ^. #cpuRequest, j ^. #memoryRequest, j ^. #cpuLimit, j ^. #memoryLimit) of
    (Nothing, Nothing, Nothing, Nothing) -> Right Nothing
    (c, m, cl, ml) -> do
      c' <- traverse (first (MarshalError "cpuRequest") . mkQuantity) c
      m' <- traverse (first (MarshalError "memoryRequest") . mkQuantity) m
      cl' <- traverse (first (MarshalError "cpuLimit") . mkQuantity) cl
      ml' <- traverse (first (MarshalError "memoryLimit") . mkQuantity) ml
      Right (Just Resources {cpu = c', memory = m', cpuLimit = cl', memoryLimit = ml'})

-- | Decode the JSON a task config emits (via 'Nagare.Dsl.Config.emitTask') into
-- a validated 'Task'. The top-level @kind@ is checked first: a missing or
-- non-@Task@ kind is 'UnexpectedKind'.
decodeTask :: ByteString -> Either LoadError Task
decodeTask bs =
  case eitherDecodeStrict bs of
    Left perr ->
      Left (MarshalError "json" ("could not decode config output: " <> Text.pack perr))
    Right (JsonKindEnvelope envelopeKind) -> case envelopeKind of
      Just "Task" -> case eitherDecodeStrict bs of
        Left perr ->
          Left (MarshalError "json" ("could not decode task: " <> Text.pack perr))
        Right jt -> toTask jt
      Just other -> Left (UnexpectedKind "Task" other)
      Nothing -> Left (UnexpectedKind "Task" "<none>")

-- | Load a 'Task' from a Haskell config-as-program source file. The config must
-- print its JSON via 'Nagare.Dsl.Config.emitTask'. A config that emits a
-- different shape is reported as 'UnexpectedKind'. Used by EP-51's @task@ CLI.
loadTask :: FilePath -> IO (Either LoadError Task)
loadTask path = fmap (>>= decodeTask) (runConfig path)

-- ---------------------------------------------------------------------------
-- JSON intermediate for one-shot Jobs (mirrors Nagare.Dsl.Config.jobJSON)

data JsonJob = JsonJob
  { name :: !Text
  , namespace :: !Text
  , image :: !Text
  , build :: !(Maybe JsonBuildSpec)
  , command :: !(Maybe [Text])
  , env :: ![JsonEnvEntry]
  , cpuRequest :: !(Maybe Text)
  , memoryRequest :: !(Maybe Text)
  , cpuLimit :: !(Maybe Text)
  , memoryLimit :: !(Maybe Text)
  , backoffLimit :: !Int
  , activeDeadlineSeconds :: !(Maybe Int)
  , ttlSecondsAfterFinished :: !(Maybe Int)
  , scratchSize :: !Text
  , nixConfigMap :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonJob where
  parseJSON = withObject "Job" $ \o ->
    JsonJob
      <$> o .: "name"
      <*> o .: "namespace"
      <*> o .: "image"
      <*> o .:? "build"
      <*> o .:? "command"
      <*> o .:? "env" .!= []
      <*> o .:? "cpuRequest"
      <*> o .:? "memoryRequest"
      <*> o .:? "cpuLimit"
      <*> o .:? "memoryLimit"
      <*> o .:? "backoffLimit" .!= 0
      <*> o .:? "activeDeadlineSeconds"
      <*> o .:? "ttlSecondsAfterFinished"
      <*> o .: "scratchSize"
      <*> o .:? "nixConfigMap"

toJob :: JsonJob -> Either LoadError Job
toJob j = do
  name' <- first (MarshalError "name") $ mkServiceName (j ^. #name)
  namespace' <- first (MarshalError "namespace") $ mkNamespace (j ^. #namespace)
  image' <- first (MarshalError "image") $ mkImageRef (j ^. #image)
  build' <- case j ^. #build of
    Nothing -> first (MarshalError "build") defaultBuild
    Just build -> toBuildSpec build
  command' <- traverse (first (MarshalError "command") . mkCommand) (j ^. #command)
  env' <- mapM toEnvEntry (j ^. #env)
  resources' <- toJobResources j
  scratch' <- first (MarshalError "scratchSize") $ mkQuantity (j ^. #scratchSize)
  nixConfigMap' <- traverse (first (MarshalError "nixConfigMap") . mkConfigMapName) (j ^. #nixConfigMap)
  first (MarshalError "job") $
    mkJob
      Job
        { name = name'
        , namespace = namespace'
        , image = image'
        , build = build'
        , command = command'
        , env = Map.fromList env'
        , resources = resources'
        , backoffLimit = j ^. #backoffLimit
        , activeDeadlineSeconds = j ^. #activeDeadlineSeconds
        , ttlSecondsAfterFinished = j ^. #ttlSecondsAfterFinished
        , scratchSize = scratch'
        , nixConfigMap = nixConfigMap'
        }

toJobResources :: JsonJob -> Either LoadError (Maybe Resources)
toJobResources j =
  case (j ^. #cpuRequest, j ^. #memoryRequest, j ^. #cpuLimit, j ^. #memoryLimit) of
    (Nothing, Nothing, Nothing, Nothing) -> Right Nothing
    (cpuRequest, memoryRequest, cpuLimit', memoryLimit') -> do
      cpuRequest' <- traverse (first (MarshalError "cpuRequest") . mkQuantity) cpuRequest
      memoryRequest' <- traverse (first (MarshalError "memoryRequest") . mkQuantity) memoryRequest
      cpuLimit'' <- traverse (first (MarshalError "cpuLimit") . mkQuantity) cpuLimit'
      memoryLimit'' <- traverse (first (MarshalError "memoryLimit") . mkQuantity) memoryLimit'
      Right
        ( Just
            Resources
              { cpu = cpuRequest'
              , memory = memoryRequest'
              , cpuLimit = cpuLimit''
              , memoryLimit = memoryLimit''
              }
        )

-- | Decode and revalidate the JSON emitted by 'Nagare.Dsl.Config.emitJob'.
decodeJob :: ByteString -> Either LoadError Job
decodeJob bs =
  case eitherDecodeStrict bs of
    Left perr ->
      Left (MarshalError "json" ("could not decode config output: " <> Text.pack perr))
    Right (JsonKindEnvelope envelopeKind) -> case envelopeKind of
      Just "Job" -> case eitherDecodeStrict bs of
        Left perr -> Left (MarshalError "json" ("could not decode job: " <> Text.pack perr))
        Right job -> toJob job
      Just other -> Left (UnexpectedKind "Job" other)
      Nothing -> Left (UnexpectedKind "Job" "<none>")

-- | Load a Job from a Haskell config-as-program that calls @emitJob@.
loadJob :: FilePath -> IO (Either LoadError Job)
loadJob path = fmap (>>= decodeJob) (runConfig path)

-- ---------------------------------------------------------------------------
-- JSON intermediate for workers (mirrors Nagare.Dsl.Config's emitted shape)

-- | The intermediate decode shape for a 'Worker' (mirrors
-- 'Nagare.Dsl.Config'\'s @workerJSON@). Optional fields carry model defaults so a
-- partial object is a precise 'MarshalError', not an aeson parse error: @build@
-- defaults to the historical Dockerfile build, @replicas@ to @1@, @command@ to
-- absent (run the image entrypoint).
data JsonWorker = JsonWorker
  { name :: !Text
  , logicalKey :: !(Maybe Text)
  , namespace :: !Text
  , image :: !Text
  , build :: !(Maybe JsonBuildSpec)
  , command :: !(Maybe [Text])
  , replicas :: !Int
  , env :: ![JsonEnvEntry]
  , cpuRequest :: !(Maybe Text)
  , memoryRequest :: !(Maybe Text)
  , cpuLimit :: !(Maybe Text)
  , memoryLimit :: !(Maybe Text)
  , volumes :: ![JsonVolume]
  , databases :: ![Text]
  , brokers :: ![JsonBrokerBinding]
  , liveness :: !(Maybe JsonWorkerProbe)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonWorker where
  parseJSON = withObject "Worker" $ \o ->
    JsonWorker
      <$> o .: "name"
      <*> o .:? "logicalKey"
      <*> o .: "namespace"
      <*> o .: "image"
      <*> o .:? "build"
      <*> o .:? "command"
      <*> o .:? "replicas" .!= 1
      <*> o .:? "env" .!= []
      <*> o .:? "cpuRequest"
      <*> o .:? "memoryRequest"
      <*> o .:? "cpuLimit"
      <*> o .:? "memoryLimit"
      <*> o .:? "volumes" .!= []
      <*> o .:? "databases" .!= []
      <*> o .:? "brokers" .!= []
      <*> o .:? "liveness"

-- | The intermediate decode shape for a 'WorkerProbe' (mirrors
-- 'Nagare.Dsl.Config'\'s @workerProbeJSON@). The @kind@ selects the mechanism;
-- the per-kind fields are optional so a missing one is a precise 'MarshalError'.
-- The timing fields carry the model defaults (mirroring 'defaultProbeTiming').
data JsonWorkerProbe = JsonWorkerProbe
  { kind :: !Text
  , command :: !(Maybe [Text])
  , port :: !(Maybe Int)
  , path :: !(Maybe Text)
  , checkPort :: !(Maybe Int)
  , scheme :: !(Maybe Text)
  , initialDelay :: !Int
  , period :: !Int
  , timeout :: !Int
  , failureThreshold :: !Int
  , asStartup :: !Bool
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonWorkerProbe where
  parseJSON = withObject "WorkerProbe" $ \o ->
    JsonWorkerProbe
      <$> o .: "kind"
      <*> o .:? "command"
      <*> o .:? "port"
      <*> o .:? "path"
      <*> o .:? "checkPort"
      <*> o .:? "scheme"
      <*> o .:? "initialDelay" .!= 0
      <*> o .:? "period" .!= 10
      <*> o .:? "timeout" .!= 1
      <*> o .:? "failureThreshold" .!= 3
      <*> o .:? "asStartup" .!= False

-- | Re-validate a decoded liveness probe, dispatching on the @kind@ and re-running
-- the relevant smart constructor (and 'mkProbeTiming' / 'mkPort'). A missing
-- per-kind field or unknown kind/scheme is a precise 'MarshalError "liveness*"'.
toWorkerProbe :: JsonWorkerProbe -> Either LoadError WorkerProbe
toWorkerProbe j =
  case j ^. #kind of
    "Exec" -> do
      argv <-
        maybe (Left (MarshalError "liveness" "Exec probe missing 'command' field")) Right (j ^. #command)
      first (MarshalError "liveness") (mkExecProbe argv timing)
    "Tcp" -> do
      p <- maybe (Left (MarshalError "liveness" "Tcp probe missing 'port' field")) Right (j ^. #port)
      port <- first (MarshalError "liveness.port") (mkPort p)
      t <- first (MarshalError "liveness") (mkProbeTiming timing)
      Right (mkTcpProbe port t)
    "Http" -> do
      path <-
        maybe (Left (MarshalError "liveness" "Http probe missing 'path' field")) Right (j ^. #path)
      mport <- traverse (first (MarshalError "liveness.checkPort") . mkPort) (j ^. #checkPort)
      scheme <- case fromMaybe "HTTP" (j ^. #scheme) of
        "HTTP" -> Right HTTP
        "HTTPS" -> Right HTTPS
        other -> Left (MarshalError "liveness.scheme" ("unknown scheme: " <> other))
      first (MarshalError "liveness") (mkHttpProbe path mport scheme timing)
    other -> Left (MarshalError "liveness.kind" ("unknown probe kind: " <> other))
  where
    timing =
      ProbeTiming
        { initialDelay = j ^. #initialDelay
        , period = j ^. #period
        , timeout = j ^. #timeout
        , failureThreshold = j ^. #failureThreshold
        , asStartup = j ^. #asStartup
        }

-- | Re-validate a decoded worker: re-run every smart constructor
-- ('mkServiceName', 'mkNamespace', 'mkImageRef', 'mkReplicas', 'mkCommand', the
-- shared build/env/resources/volume marshallers, and 'mkDatabaseName'). Volume
-- name / mount-path uniqueness is enforced by the reused 'toVolumes', exactly as
-- 'toDeployment' enforces it. Any failure is a precise 'MarshalError'.
toWorker :: JsonWorker -> Either LoadError Worker
toWorker j = do
  name' <- first (MarshalError "name") $ mkServiceName (j ^. #name)
  logicalKey' <- traverse (first (MarshalError "logicalKey") . mkLogicalKey) (j ^. #logicalKey)
  ns' <- first (MarshalError "namespace") $ mkNamespace (j ^. #namespace)
  img' <- first (MarshalError "image") $ mkImageRef (j ^. #image)
  build' <- case j ^. #build of
    Nothing -> first (MarshalError "build") defaultBuild
    Just jb -> toBuildSpec jb
  command' <- traverse (first (MarshalError "command") . mkCommand) (j ^. #command)
  replicas' <- first (MarshalError "replicas") $ mkReplicas (j ^. #replicas)
  env' <- mapM toEnvEntry (j ^. #env)
  res' <- toWorkerResources j
  vols' <- toVolumes (j ^. #volumes)
  dbRefs' <- traverse (first (MarshalError "databases") . mkDatabaseName) (j ^. #databases)
  brokerRefs' <- traverse (toBrokerBinding "brokers") (j ^. #brokers)
  liveness' <- traverse toWorkerProbe (j ^. #liveness)
  Right
    Worker
      { name = name'
      , logicalKey = logicalKey'
      , namespace = ns'
      , image = img'
      , build = build'
      , command = command'
      , replicas = replicas'
      , env = Map.fromList env'
      , resources = res'
      , volumes = vols'
      , databases = dbRefs'
      , brokers = brokerRefs'
      , liveness = liveness'
      }

toWorkerResources :: JsonWorker -> Either LoadError (Maybe Resources)
toWorkerResources j =
  case (j ^. #cpuRequest, j ^. #memoryRequest, j ^. #cpuLimit, j ^. #memoryLimit) of
    (Nothing, Nothing, Nothing, Nothing) -> Right Nothing
    (c, m, cl, ml) -> do
      c' <- traverse (first (MarshalError "cpuRequest") . mkQuantity) c
      m' <- traverse (first (MarshalError "memoryRequest") . mkQuantity) m
      cl' <- traverse (first (MarshalError "cpuLimit") . mkQuantity) cl
      ml' <- traverse (first (MarshalError "memoryLimit") . mkQuantity) ml
      Right (Just Resources {cpu = c', memory = m', cpuLimit = cl', memoryLimit = ml'})

-- | Decode the JSON a worker config emits (via 'Nagare.Dsl.Config.emitWorker')
-- into a validated 'Worker'. The top-level @kind@ is checked first: a missing or
-- non-@Worker@ kind is 'UnexpectedKind'.
decodeWorker :: ByteString -> Either LoadError Worker
decodeWorker bs =
  case eitherDecodeStrict bs of
    Left perr ->
      Left (MarshalError "json" ("could not decode config output: " <> Text.pack perr))
    Right (JsonKindEnvelope envelopeKind) -> case envelopeKind of
      Just "Worker" -> case eitherDecodeStrict bs of
        Left perr ->
          Left (MarshalError "json" ("could not decode worker: " <> Text.pack perr))
        Right jw -> toWorker jw
      Just other -> Left (UnexpectedKind "Worker" other)
      Nothing -> Left (UnexpectedKind "Worker" "<none>")

-- | Load a 'Worker' from a Haskell config-as-program source file (EP-71). The
-- config must print its JSON via 'Nagare.Dsl.Config.emitWorker'. A config that
-- instead emits a 'Deployment' or another kind is reported as 'UnexpectedKind'.
-- Used by @nagarectl worker deploy@.
loadWorker :: FilePath -> IO (Either LoadError Worker)
loadWorker path = fmap (>>= decodeWorker) (runConfig path)

-- ---------------------------------------------------------------------------
-- JSON intermediate for the multi-workload Application aggregate (MasterPlan 14,
-- EP-1; mirrors Nagare.Dsl.Config's applicationJSON)

-- | The intermediate decode shape for an 'Application' (mirrors
-- 'Nagare.Dsl.Config'\'s @applicationJSON@). Each embedded workload reuses the
-- existing per-kind intermediate ('JsonDeployment' / 'JsonWorker' /
-- 'JsonDatabase' / 'JsonTask'), so the embedded objects decode exactly as they
-- do standalone. Optional fields default to empty so a partial object is a
-- precise 'MarshalError', not an aeson parse error.
data JsonApplication = JsonApplication
  { name :: !Text
  , logicalKey :: !(Maybe Text)
  , namespace :: !Text
  , image :: !Text
  , env :: ![JsonEnvEntry]
  , databases :: ![JsonDatabase]
  , brokers :: ![JsonBrokerBinding]
  , access :: !(Maybe JsonAccessPolicy)
  , service :: !(Maybe JsonDeployment)
  , workers :: ![JsonWorker]
  , tasks :: ![JsonTask]
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonApplication where
  parseJSON = withObject "Application" $ \o ->
    JsonApplication
      <$> o .: "name"
      <*> o .:? "logicalKey"
      <*> o .: "namespace"
      <*> o .: "image"
      <*> o .:? "env" .!= []
      <*> o .:? "databases" .!= []
      <*> o .:? "brokers" .!= []
      <*> o .:? "access"
      <*> o .:? "service"
      <*> o .:? "workers" .!= []
      <*> o .:? "tasks" .!= []

-- | Re-validate a decoded application: re-run every leaf smart constructor for
-- the shared bindings, marshal each embedded workload with the EXISTING
-- 'toDeployment' / 'toWorker' / 'toDatabase' / 'toTask' (which re-run all their
-- own invariants), then enforce the cross-workload invariants by calling
-- 'mkApplication' on the assembled record — so the validation lives in one place
-- (defence in depth: a hand-written or tampered JSON that violates an invariant
-- is rejected as a precise @MarshalError "application"@).
toApplication :: JsonApplication -> Either LoadError Application
toApplication j = do
  name' <- first (MarshalError "name") $ mkServiceName (j ^. #name)
  logicalKey' <- traverse (first (MarshalError "logicalKey") . mkLogicalKey) (j ^. #logicalKey)
  ns' <- first (MarshalError "namespace") $ mkNamespace (j ^. #namespace)
  img' <- first (MarshalError "image") $ mkImageRef (j ^. #image)
  env' <- mapM toEnvEntry (j ^. #env)
  dbs' <- traverse toDatabase (j ^. #databases)
  brokerRefs' <- traverse (toBrokerBinding "brokers") (j ^. #brokers)
  access' <- traverse toAccessPolicy (j ^. #access)
  svc' <- traverse toDeployment (j ^. #service)
  wks' <- traverse toWorker (j ^. #workers)
  tks' <- traverse toTask (j ^. #tasks)
  let assembled =
        Application
          { name = name'
          , logicalKey = logicalKey'
          , namespace = ns'
          , image = img'
          , env = Map.fromList env'
          , databases = dbs'
          , brokers = brokerRefs'
          , access = access'
          , service = svc'
          , workers = wks'
          , tasks = tks'
          }
  first (MarshalError "application") (mkApplication assembled)

-- | Decode the JSON an application config emits (via
-- 'Nagare.Dsl.Config.emitApplication') into a validated 'Application'. The
-- top-level @kind@ is checked first: a missing kind (a bare 'Deployment') or a
-- non-@Application@ kind is 'UnexpectedKind'.
decodeApplication :: ByteString -> Either LoadError Application
decodeApplication bs =
  case eitherDecodeStrict bs of
    Left perr ->
      Left (MarshalError "json" ("could not decode config output: " <> Text.pack perr))
    Right (JsonKindEnvelope envelopeKind) -> case envelopeKind of
      Just "Application" -> case eitherDecodeStrict bs of
        Left perr ->
          Left (MarshalError "json" ("could not decode application: " <> Text.pack perr))
        Right ja -> toApplication ja
      Just other -> Left (UnexpectedKind "Application" other)
      Nothing -> Left (UnexpectedKind "Application" "<none>")

-- | Load an 'Application' from a Haskell config-as-program source file (MasterPlan
-- 14, EP-1). The config must print its JSON via
-- 'Nagare.Dsl.Config.emitApplication'. A config that instead emits a single
-- workload (or another kind) is reported as 'UnexpectedKind'. Used by
-- @nagarectl app deploy@ (EP-2).
loadApplication :: FilePath -> IO (Either LoadError Application)
loadApplication path = fmap (>>= decodeApplication) (runConfig path)

-- ---------------------------------------------------------------------------
-- JSON intermediate for the optional CDN block (mirrors Nagare.Dsl.Config.cdnJSON)

-- | One entry of the @cdn.cacheRules@ array. @edgeTtlSeconds@ is read with
-- @.:?@ so a missing key is 'Nothing'; the encoder always writes the key (as
-- @null@ for the never-cache case), so the round-trip preserves 'Nothing'.
data JsonCdnCacheRule = JsonCdnCacheRule
  { pathPrefix :: !Text
  , edgeTtlSeconds :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonCdnCacheRule where
  parseJSON = withObject "CdnCacheRule" $ \o ->
    JsonCdnCacheRule <$> o .: "pathPrefix" <*> o .:? "edgeTtlSeconds"

-- | The decoded @"cdn"@ object. @cacheStaticAssets@ defaults to 'True' and
-- @cacheRules@ to @[]@ so a hand-written partial object is forgiving, mirroring
-- how 'JsonVolume'/'JsonHealthCheck' default their optional fields.
data JsonCdn = JsonCdn
  { provider :: !Text
  , defaultTtlSeconds :: !(Maybe Int)
  , cacheStaticAssets :: !Bool
  , cacheRules :: ![JsonCdnCacheRule]
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonCdn where
  parseJSON = withObject "Cdn" $ \o ->
    JsonCdn
      <$> o .: "provider"
      <*> o .:? "defaultTtlSeconds"
      <*> o .:? "cacheStaticAssets" .!= True
      <*> o .:? "cacheRules" .!= []

-- | Re-validate a decoded @"cdn"@ object back into a 'Cdn', re-running the
-- per-path smart constructor and decoding the provider token. The provider
-- tokens are the wire contract fixed by EP-55 (@"Cloudflare"@ / @"GcpCloudCdn"@);
-- a negative @defaultTtlSeconds@ is rejected here because neither the encoder
-- nor 'Nagare.Dsl.Cdn.Types.withDefaultTtl' can catch a hand-written value.
toCdn :: JsonCdn -> Either LoadError Cdn
toCdn j = do
  prov <- case j ^. #provider of
    "Cloudflare" -> Right CloudflareCdn
    "GcpCloudCdn" -> Right GcpCloudCdn
    other -> Left (MarshalError "cdn.provider" ("unknown cdn provider: " <> other))
  case j ^. #defaultTtlSeconds of
    Just n
      | n < 0 ->
          Left (MarshalError "cdn.defaultTtlSeconds" ("must be >= 0, got: " <> Text.pack (show n)))
    _ -> Right ()
  rules <- traverse toCdnCacheRule (j ^. #cacheRules)
  Right
    Cdn
      { provider = prov
      , defaultTtlSeconds = j ^. #defaultTtlSeconds
      , cacheStaticAssets = j ^. #cacheStaticAssets
      , cacheRules = rules
      }
  where
    toCdnCacheRule r =
      first (MarshalError "cdn.cacheRules") $
        mkCdnCacheRule (r ^. #pathPrefix) (r ^. #edgeTtlSeconds)

-- ---------------------------------------------------------------------------
-- JSON intermediate for static sites (mirrors Nagare.Dsl.Config's emitted shape)

-- | A minimal envelope used to read the top-level @kind@ discriminator before
-- committing to a full decode.
newtype JsonKindEnvelope = JsonKindEnvelope {kind :: Maybe Text}
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonKindEnvelope where
  parseJSON = withObject "kinded" $ \o -> JsonKindEnvelope <$> o .:? "kind"

data JsonStaticBuild = JsonStaticBuild
  { kind :: !Text
  , directory :: !(Maybe Text)
  , command :: !(Maybe Text)
  , outputDirectory :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonStaticBuild where
  parseJSON = withObject "StaticBuild" $ \o ->
    JsonStaticBuild
      <$> o .: "kind"
      <*> o .:? "directory"
      <*> o .:? "command"
      <*> o .:? "outputDirectory"

data JsonRedirect = JsonRedirect
  { from :: !Text
  , to :: !Text
  , status :: !Int
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonRedirect where
  parseJSON = withObject "RedirectRule" $ \o ->
    JsonRedirect <$> o .: "from" <*> o .: "to" <*> o .: "status"

data JsonHeader = JsonHeader
  { path :: !Text
  , name :: !Text
  , value :: !Text
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonHeader where
  parseJSON = withObject "HeaderRule" $ \o ->
    JsonHeader <$> o .: "path" <*> o .: "name" <*> o .: "value"

data JsonCache = JsonCache
  { immutableAssets :: !Bool
  , defaultMaxAge :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonCache where
  parseJSON = withObject "CachePolicy" $ \o ->
    JsonCache <$> o .: "immutableAssets" <*> o .:? "defaultMaxAge"

data JsonStaticSite = JsonStaticSite
  { name :: !Text
  , namespace :: !Text
  , image :: !Text
  , build :: !JsonStaticBuild
  , domains :: ![JsonDomainEntry]
  , redirects :: ![JsonRedirect]
  , headers :: ![JsonHeader]
  , cache :: !JsonCache
  , notFound :: !(Maybe Text)
  , cdn :: !(Maybe JsonCdn)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonStaticSite where
  parseJSON = withObject "StaticSite" $ \o ->
    JsonStaticSite
      <$> o .: "name"
      <*> o .: "namespace"
      <*> o .: "image"
      <*> o .: "build"
      <*> o .: "domains"
      <*> o .: "redirects"
      <*> o .: "headers"
      <*> o .: "cache"
      <*> o .:? "notFound"
      <*> o .:? "cdn"

-- ---------------------------------------------------------------------------
-- Marshalling JsonStaticSite -> StaticSite (re-runs the smart constructors)

toStaticSite :: JsonStaticSite -> Either LoadError StaticSite
toStaticSite j = do
  name' <- first (MarshalError "name") $ mkSiteName (j ^. #name)
  ns' <- first (MarshalError "namespace") $ mkNamespace (j ^. #namespace)
  img' <- first (MarshalError "image") $ mkImageRef (j ^. #image)
  build' <- toStaticBuild (j ^. #build)
  domains' <- toDomainSpecs "domains" (j ^. #domains)
  redirects' <- traverse toRedirect (j ^. #redirects)
  headers' <- traverse toHeader (j ^. #headers)
  cache' <-
    first (MarshalError "cache") $
      mkCachePolicy (cacheJ ^. #immutableAssets) (cacheJ ^. #defaultMaxAge)
  notFound' <- traverse (first (MarshalError "notFound") . mkFilePathText) (j ^. #notFound)
  cdn' <- traverse toCdn (j ^. #cdn)
  Right
    StaticSite
      { name = name'
      , namespace = ns'
      , image = img'
      , build = build'
      , domains = domains'
      , redirects = redirects'
      , headers = headers'
      , cache = cache'
      , notFound = notFound'
      , cdn = cdn'
      }
  where
    cacheJ = j ^. #cache

toStaticBuild :: JsonStaticBuild -> Either LoadError StaticBuild
toStaticBuild jb = case jb ^. #kind of
  "NoBuild" -> case jb ^. #directory of
    Nothing -> Left (MarshalError "build" "NoBuild entry missing 'directory' field")
    Just d -> fmap NoBuild . first (MarshalError "build.directory") $ mkFilePathText d
  "BuildCommand" -> do
    cmd <-
      maybe (Left (MarshalError "build" "BuildCommand entry missing 'command' field")) Right $
        jb ^. #command
    outD <-
      maybe (Left (MarshalError "build" "BuildCommand entry missing 'outputDirectory' field")) Right $
        jb ^. #outputDirectory
    outD' <- first (MarshalError "build.outputDirectory") $ mkFilePathText outD
    Right (BuildCommand {command = cmd, outputDirectory = outD'})
  other -> Left (MarshalError "build.kind" ("unknown build kind: " <> other))

toRedirect :: JsonRedirect -> Either LoadError RedirectRule
toRedirect jr =
  first (MarshalError "redirect") $ mkRedirectRule (jr ^. #from) (jr ^. #to) (jr ^. #status)

toHeader :: JsonHeader -> Either LoadError HeaderRule
toHeader jh =
  first (MarshalError "header") $ mkHeaderRule (jh ^. #path) (jh ^. #name) (jh ^. #value)

-- | Decode the JSON a config program emits (via
-- 'Nagare.Dsl.Config.emitStaticSite') into a validated 'StaticSite', re-running
-- the smart constructors. The top-level @kind@ is checked first: a missing or
-- non-@StaticSite@ kind is reported as 'UnexpectedKind' (so a config that emits
-- a 'Deployment' under @nagarectl site deploy@ fails precisely rather than being
-- misread). Exposed so the marshalling path can be unit-tested without spawning
-- a subprocess.
decodeStaticSite :: ByteString -> Either LoadError StaticSite
decodeStaticSite bs =
  case eitherDecodeStrict bs of
    Left perr ->
      Left (MarshalError "json" ("could not decode config output: " <> Text.pack perr))
    Right (JsonKindEnvelope envelopeKind) -> case envelopeKind of
      Just "StaticSite" -> case eitherDecodeStrict bs of
        Left perr ->
          Left (MarshalError "json" ("could not decode static site: " <> Text.pack perr))
        Right jss -> toStaticSite jss
      Just other -> Left (UnexpectedKind "StaticSite" other)
      Nothing -> Left (UnexpectedKind "StaticSite" "<none>")

-- | Compile-and-run a config-as-program source file with @runghc@ and capture
-- the JSON it prints on stdout, mapping every failure mode to a 'LoadError'.
--
-- The file is run with @runghc@ (the house @GHC2024@ edition, the exact
-- @nagare-dsl@ package exposed by the caller's GHC environment, and the
-- config's directory on the include path). Do not add a name-only @-package
-- nagare-dsl@ flag here: it can expose a second installed version alongside the
-- package-id selected by @GHC_ENVIRONMENT@.
-- The config must print its JSON via one of the @Nagare.Dsl.Config.emit*@
-- helpers; empty output means it never called one ('MissingBinding'). The
-- decoder that reads the captured bytes is chosen by the caller
-- ('decodeDeployment' or 'decodeStaticSite').
--
-- The run is bounded by 'defaultConfigTimeout'; use 'runConfigWith' to choose a
-- different budget.
runConfig :: FilePath -> IO (Either LoadError ByteString)
runConfig = runConfigWith defaultConfigTimeout

-- | 'runConfig' with an explicit time budget. A config that has not finished
-- when the budget expires is killed and reported as 'LoadTimedOut' rather than
-- blocking the caller forever.
--
-- 'readProcessWithExitCode' is built on @withCreateProcess@, whose cleanup
-- terminates the child when the waiting thread is interrupted — which is exactly
-- what 'System.Timeout.timeout' does — so the @runghc@ process dies with the
-- budget rather than being orphaned.
runConfigWith :: ConfigTimeout -> FilePath -> IO (Either LoadError ByteString)
runConfigWith budget path = do
  exists <- doesFileExist path
  if not exists
    then pure (Left (FileNotFound path))
    else do
      let configDir = takeDirectory path
          seconds' = budget ^. #seconds
      result <-
        Timeout.timeout (seconds' * 1_000_000) . try @IOException $
          readProcessWithExitCode
            "runghc"
            ["--ghc-arg=-XGHC2024", "-i" <> configDir, path]
            ""
      pure $ case result of
        Nothing -> Left (LoadTimedOut path seconds')
        Just (Left ioErr) -> Left (CompileError path (Text.pack (show ioErr)))
        Just (Right (ExitFailure _, _out, err)) -> Left (CompileError path (Text.pack err))
        Just (Right (ExitSuccess, out, _err))
          | null out -> Left (MissingBinding path)
          | otherwise -> Right (BC.pack out)

-- | Load a 'Deployment' from a Haskell config-as-program source file. The config
-- must print its JSON via 'Nagare.Dsl.Config.emitDeployment'. See 'runConfig'
-- for the compile-and-run contract; see this plan's Decision Log for the
-- production-provisioning note handed to EP-12.
loadDeployment :: FilePath -> IO (Either LoadError Deployment)
loadDeployment path = fmap (>>= decodeDeployment) (runConfig path)

-- | Load a 'Broker' from a Haskell config-as-program source file. The config
-- must print its JSON via 'Nagare.Dsl.Config.emitBroker'. A config that instead
-- emits any other kind is reported as 'UnexpectedKind'.
loadBroker :: FilePath -> IO (Either LoadError Broker)
loadBroker path = fmap (>>= decodeBroker) (runConfig path)

-- | Load a 'Database' from a Haskell config-as-program source file (MasterPlan 9,
-- EP-44/EP-45). The config must print its JSON via
-- 'Nagare.Dsl.Config.emitDatabase'. A config that instead emits a 'Deployment' or
-- a site is reported as 'UnexpectedKind'. Used by @nagarectl db create --config@.
loadDatabase :: FilePath -> IO (Either LoadError Database)
loadDatabase path = fmap (>>= decodeDatabase) (runConfig path)

-- | Load a 'StaticSite' from a Haskell config-as-program source file. The config
-- must print its JSON via 'Nagare.Dsl.Config.emitStaticSite'. A config that
-- instead emits a 'Deployment' (or a future @ServerSite@) is reported as
-- 'UnexpectedKind', not silently misread.
loadStaticSite :: FilePath -> IO (Either LoadError StaticSite)
loadStaticSite = loadStaticSiteWith defaultConfigTimeout

-- | 'loadStaticSite' with an explicit time budget. @nagared@ uses this so a
-- pushed config that loops cannot wedge a webhook handler thread forever.
loadStaticSiteWith :: ConfigTimeout -> FilePath -> IO (Either LoadError StaticSite)
loadStaticSiteWith budget path = fmap (>>= decodeStaticSite) (runConfigWith budget path)

-- | Load a 'ServerSite' from a Haskell config-as-program source file (EP-18). The
-- config must print its JSON via 'Nagare.Dsl.Config.emitServerSite'. A config
-- that emits a different shape is reported as 'UnexpectedKind'.
loadServerSite :: FilePath -> IO (Either LoadError ServerSite)
loadServerSite path = fmap (>>= decodeServerSite) (runConfig path)

-- | The two site shapes @nagarectl site deploy@ can deploy.
data SiteConfig
  = SiteStatic !StaticSite
  | SiteServer !ServerSite
  deriving stock (Generic, Eq, Show)

-- | Load whichever site a config emits, dispatching on the top-level @kind@
-- (EP-18). This is the single loader @nagarectl site deploy@ calls: a
-- @"StaticSite"@ runs the Nginx path, a @"ServerSite"@ runs the Node path, and a
-- @Deployment@-shaped config (no @kind@) or an unknown kind is reported as
-- 'UnexpectedKind' so the user is told to use the right command.
loadSite :: FilePath -> IO (Either LoadError SiteConfig)
loadSite path = fmap (>>= decodeSite) (runConfig path)

decodeSite :: ByteString -> Either LoadError SiteConfig
decodeSite bs =
  case eitherDecodeStrict bs of
    Left perr ->
      Left (MarshalError "json" ("could not decode config output: " <> Text.pack perr))
    Right (JsonKindEnvelope envelopeKind) -> case envelopeKind of
      Just "StaticSite" -> SiteStatic <$> decodeStaticSite bs
      Just "ServerSite" -> SiteServer <$> decodeServerSite bs
      Just other -> Left (UnexpectedKind "StaticSite or ServerSite" other)
      Nothing -> Left (UnexpectedKind "StaticSite or ServerSite" "<none>")

-- ---------------------------------------------------------------------------
-- JSON intermediate for server sites (mirrors Nagare.Dsl.Config's emitted shape)

data JsonServerBuild = JsonServerBuild
  { command :: !Text
  , outputDirs :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonServerBuild where
  parseJSON = withObject "ServerBuild" $ \o ->
    JsonServerBuild <$> o .: "command" <*> o .: "outputDirs"

data JsonServerRuntime = JsonServerRuntime
  { baseImage :: !Text
  , startCommand :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonServerRuntime where
  parseJSON = withObject "ServerRuntime" $ \o ->
    JsonServerRuntime <$> o .: "baseImage" <*> o .: "startCommand"

data JsonServerSite = JsonServerSite
  { name :: !Text
  , namespace :: !Text
  , image :: !Text
  , build :: !JsonServerBuild
  , runtime :: !JsonServerRuntime
  , port :: !Int
  , env :: ![JsonEnvEntry]
  , cpuRequest :: !(Maybe Text)
  , memoryRequest :: !(Maybe Text)
  , scaleMin :: !(Maybe Int)
  , scaleMax :: !(Maybe Int)
  , domains :: ![JsonDomainEntry]
  , volumes :: ![JsonVolume]
  , cdn :: !(Maybe JsonCdn)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonServerSite where
  parseJSON = withObject "ServerSite" $ \o ->
    JsonServerSite
      <$> o .: "name"
      <*> o .: "namespace"
      <*> o .: "image"
      <*> o .: "build"
      <*> o .: "runtime"
      <*> o .: "port"
      <*> o .:? "env" .!= []
      <*> o .:? "cpuRequest"
      <*> o .:? "memoryRequest"
      <*> o .:? "scaleMin"
      <*> o .:? "scaleMax"
      <*> o .:? "domains" .!= []
      <*> o .:? "volumes" .!= []
      <*> o .:? "cdn"

-- ---------------------------------------------------------------------------
-- Marshalling JsonServerSite -> ServerSite (re-runs the smart constructors)

toServerSite :: JsonServerSite -> Either LoadError ServerSite
toServerSite j = do
  name' <- first (MarshalError "name") $ mkSiteName (j ^. #name)
  ns' <- first (MarshalError "namespace") $ mkNamespace (j ^. #namespace)
  img' <- first (MarshalError "image") $ mkImageRef (j ^. #image)
  build' <- toServerBuild (j ^. #build)
  runtime' <- toServerRuntime (j ^. #runtime)
  port' <- first (MarshalError "port") $ mkPort (j ^. #port)
  env' <- mapM toEnvEntry (j ^. #env)
  res' <- toServerResources (j ^. #cpuRequest) (j ^. #memoryRequest)
  scale' <- case (j ^. #scaleMin, j ^. #scaleMax) of
    (Nothing, Nothing) -> Right Nothing
    (Just mn, Just mx) -> fmap Just . first (MarshalError "scale") $ mkScale mn mx
    _ -> Left (MarshalError "scale" "scaleMin and scaleMax must both be present or both absent")
  domains' <- toDomainSpecs "domains" (j ^. #domains)
  vols' <- toVolumes (j ^. #volumes)
  cdn' <- traverse toCdn (j ^. #cdn)
  Right
    ServerSite
      { name = name'
      , namespace = ns'
      , image = img'
      , build = build'
      , runtime = runtime'
      , port = port'
      , env = Map.fromList env'
      , resources = res'
      , scale = scale'
      , domains = domains'
      , volumes = vols'
      , cdn = cdn'
      }

toServerBuild :: JsonServerBuild -> Either LoadError ServerBuild
toServerBuild jb = do
  dirs <- traverse (first (MarshalError "build.outputDirs") . mkFilePathText) (jb ^. #outputDirs)
  neDirs <- maybe (Left (MarshalError "build.outputDirs" "outputDirs must be non-empty")) Right (NE.nonEmpty dirs)
  Right (ServerBuild {command = jb ^. #command, outputDirs = neDirs})

toServerRuntime :: JsonServerRuntime -> Either LoadError ServerRuntime
toServerRuntime jr = do
  base <- first (MarshalError "runtime.baseImage") $ mkRuntimeImage (jr ^. #baseImage)
  neCmd <- maybe (Left (MarshalError "runtime.startCommand" "startCommand must be non-empty")) Right (NE.nonEmpty (jr ^. #startCommand))
  Right (ServerRuntime {baseImage = base, startCommand = neCmd})

toServerResources :: Maybe Text -> Maybe Text -> Either LoadError (Maybe Resources)
toServerResources mc mm =
  case (mc, mm) of
    (Nothing, Nothing) -> Right Nothing
    (c, m) -> do
      c' <- traverse (first (MarshalError "cpuRequest") . mkQuantity) c
      m' <- traverse (first (MarshalError "memoryRequest") . mkQuantity) m
      Right (Just Resources {cpu = c', memory = m', cpuLimit = Nothing, memoryLimit = Nothing})

-- | Decode the JSON a config emits (via 'Nagare.Dsl.Config.emitServerSite') into
-- a validated 'ServerSite', re-running the smart constructors. The top-level
-- @kind@ is checked first; a missing or non-@ServerSite@ kind is 'UnexpectedKind'.
decodeServerSite :: ByteString -> Either LoadError ServerSite
decodeServerSite bs =
  case eitherDecodeStrict bs of
    Left perr ->
      Left (MarshalError "json" ("could not decode config output: " <> Text.pack perr))
    Right (JsonKindEnvelope envelopeKind) -> case envelopeKind of
      Just "ServerSite" -> case eitherDecodeStrict bs of
        Left perr ->
          Left (MarshalError "json" ("could not decode server site: " <> Text.pack perr))
        Right jss -> toServerSite jss
      Just other -> Left (UnexpectedKind "ServerSite" other)
      Nothing -> Left (UnexpectedKind "ServerSite" "<none>")
