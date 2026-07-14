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
  , loadDeployment
  , decodeDeployment
  , loadBroker
  , decodeBroker
  , loadDatabase
  , decodeDatabase
  , loadStaticSite
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
import "generic-lens" Data.Generics.Labels ()

-- ---------------------------------------------------------------------------
-- LoadError

-- | Every way loading a config-as-program file can fail.
data LoadError
  = -- | the config source file does not exist
    FileNotFound !FilePath
  | -- | the config failed to compile or crashed at run time (carries the GHC
    -- / runtime diagnostic from stderr)
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

-- ---------------------------------------------------------------------------
-- JSON intermediate (mirrors Nagare.Dsl.Config's emitted shape)

data JsonEnvEntry = JsonEnvEntry
  { jeVarName :: !Text
  , jeKind :: !Text
  , jeValue :: !(Maybe Text)
  , jeSecretName :: !(Maybe Text)
  , jeScopes :: !(Maybe [Text])
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
  { jvName :: !Text
  , jvSize :: !Text
  , jvMountPath :: !Text
  , jvAccessMode :: !(Maybe Text)
  , jvReadOnly :: !Bool
  , jvRetention :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonVolume where
  parseJSON = withObject "Volume" $ \o ->
    JsonVolume
      <$> o .: "name"
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
  { jbKind :: !Text
  , jbTag :: !(Maybe Text)
  , jbDockerfile :: !(Maybe Text)
  , jbContext :: !(Maybe Text)
  , jbBuildArgs :: !(Map.Map Text Text)
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
data JsonDomainSpec = JsonDomainSpec
  { jdsDomain :: !Text
  , jdsCanonical :: !Bool
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonDomainSpec where
  parseJSON = withObject "DomainSpec" $ \o ->
    JsonDomainSpec
      <$> o .: "domain"
      <*> o .:? "canonical" .!= False

-- | The @healthCheck@ sub-object (see 'Nagare.Dsl.Config'). Every field is
-- optional so a partial object is reported as a precise 'MarshalError' by
-- 'mkHealthCheck' rather than an aeson parse error; the defaults mirror
-- 'httpHealthCheck'.
data JsonHealthCheck = JsonHealthCheck
  { jhcPath :: !Text
  , jhcCheckPort :: !(Maybe Int)
  , jhcScheme :: !Text
  , jhcExpectedStatus :: !Int
  , jhcInitialDelay :: !Int
  , jhcPeriod :: !Int
  , jhcTimeout :: !Int
  , jhcFailureThreshold :: !Int
  , jhcAsLiveness :: !Bool
  , jhcAsStartup :: !Bool
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
  { jdName :: !Text
  , jdNamespace :: !Text
  , jdImage :: !Text
  , jdBuild :: !(Maybe JsonBuildSpec)
  , jdDomains :: ![JsonDomainSpec]
  , jdPort :: !Int
  , jdEnv :: ![JsonEnvEntry]
  , jdCpuRequest :: !(Maybe Text)
  , jdMemoryRequest :: !(Maybe Text)
  , jdCpuLimit :: !(Maybe Text)
  , jdMemoryLimit :: !(Maybe Text)
  , jdScaleMin :: !(Maybe Int)
  , jdScaleMax :: !(Maybe Int)
  , jdHealthCheck :: !(Maybe JsonHealthCheck)
  , jdVolumes :: ![JsonVolume]
  , jdDatabases :: ![Text]
  , jdBrokers :: ![JsonBrokerBinding]
  , jdAccess :: !(Maybe JsonAccessPolicy)
  , jdTasks :: ![JsonTask]
  , jdCdn :: !(Maybe JsonCdn)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonDeployment where
  parseJSON = withObject "Deployment" $ \o ->
    JsonDeployment
      <$> o .: "name"
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
  name' <- first (MarshalError "name") $ mkServiceName (jdName jd)
  ns' <- first (MarshalError "namespace") $ mkNamespace (jdNamespace jd)
  img' <- first (MarshalError "image") $ mkImageRef (jdImage jd)
  build' <- case jdBuild jd of
    Nothing -> first (MarshalError "build") defaultBuild
    Just jb -> toBuildSpec jb
  domains' <-
    first (MarshalError "domains") $
      mkDomains [(jdsDomain ds, jdsCanonical ds) | ds <- jdDomains jd]
  port' <- first (MarshalError "port") $ mkPort (jdPort jd)
  env' <- mapM toEnvEntry (jdEnv jd)
  res' <- toResources jd
  hc' <- toHealthCheck (jdHealthCheck jd)
  vols' <- toVolumes (jdVolumes jd)
  dbRefs' <- traverse (first (MarshalError "databases") . mkDatabaseName) (jdDatabases jd)
  brokerRefs' <- traverse (toBrokerBinding "brokers") (jdBrokers jd)
  access' <- traverse toAccessPolicy (jdAccess jd)
  -- MasterPlan 10 / EP-52: re-validate each co-located task (re-runs every smart
  -- constructor, including EP-50's inherit-image-requires-an-app invariant), then
  -- enforce the two deploy-level cross-task invariants.
  tasks' <- mapM toTask (jdTasks jd)
  -- Invariant 1: no two co-located tasks share a name.
  case firstDuplicate (map (serviceNameText . taskName) tasks') of
    Just dup -> Left (MarshalError "tasks" ("duplicate task name: " <> dup))
    Nothing -> Right ()
  -- Invariant 2: a co-located task that names an app must name THIS app.
  let thisApp = serviceNameText name'
  mapM_ (checkTaskApp thisApp) tasks'
  scale' <- case (jdScaleMin jd, jdScaleMax jd) of
    (Nothing, Nothing) -> Right Nothing
    (Just mn, Just mx) -> fmap Just . first (MarshalError "scale") $ mkScale mn mx
    _ ->
      Left
        ( MarshalError
            "scale"
            "scaleMin and scaleMax must both be present or both absent"
        )
  cdn' <- traverse toCdn (jdCdn jd)
  Right
    Deployment
      { name = name'
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
  { japAudience :: !(Maybe Text)
  , japPermission :: !Text
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonAccessPolicy where
  parseJSON = withObject "AccessPolicy" $ \o ->
    JsonAccessPolicy
      <$> o .:? "audience"
      <*> o .:? "permission" .!= "access"

toAccessPolicy :: JsonAccessPolicy -> Either LoadError AccessPolicy
toAccessPolicy j = do
  audience' <- traverse (first (MarshalError "access.audience") . mkAudience) (japAudience j)
  permission' <- first (MarshalError "access.permission") $ mkAccessPermission (japPermission j)
  Right AccessPolicy {audience = audience', permission = permission'}

-- | Re-validate a decoded @build@ sub-object back into a 'BuildSpec', dispatching
-- on its @kind@ and re-running the smart constructors. A missing per-kind field
-- or an unknown kind is reported as a precise 'MarshalError' (mirroring
-- 'toStaticBuild').
toBuildSpec :: JsonBuildSpec -> Either LoadError BuildSpec
toBuildSpec jb = case jbKind jb of
  "PrebuiltImage" -> do
    tag <-
      maybe (Left (MarshalError "build" "PrebuiltImage entry missing 'tag' field")) Right $
        jbTag jb
    fmap PrebuiltImage . first (MarshalError "build.tag") $ mkTag tag
  "DockerfileBuild" -> do
    df <-
      maybe (Left (MarshalError "build" "DockerfileBuild entry missing 'dockerfile' field")) Right $
        jbDockerfile jb
    ctx <-
      maybe (Left (MarshalError "build" "DockerfileBuild entry missing 'context' field")) Right $
        jbContext jb
    df' <- first (MarshalError "build.dockerfile") $ mkFilePathText df
    ctx' <- first (MarshalError "build.context") $ mkFilePathText ctx
    Right (DockerfileBuild {dockerfile = df', context = ctx', buildArgs = jbBuildArgs jb})
  "NixpacksBuild" -> do
    ctx <-
      maybe (Left (MarshalError "build" "NixpacksBuild entry missing 'context' field")) Right $
        jbContext jb
    ctx' <- first (MarshalError "build.context") $ mkFilePathText ctx
    Right (NixpacksBuild {context = ctx', buildArgs = jbBuildArgs jb})
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
  n <- first (MarshalError "env.varName") $ mkEnvName (jeVarName e)
  v <- case jeKind e of
    "Literal" -> case jeValue e of
      Nothing -> Left (MarshalError ("env." <> jeVarName e) "Literal entry missing 'value' field")
      Just lit -> Right (EnvLiteral lit)
    "SecretRef" -> case jeSecretName e of
      Nothing -> Left (MarshalError ("env." <> jeVarName e) "SecretRef entry missing 'secretName' field")
      Just sec ->
        fmap EnvSecretRef
          . first (MarshalError ("env." <> jeVarName e <> ".secretRef"))
          $ mkSecretName sec
    other -> Left (MarshalError ("env." <> jeVarName e <> ".kind") ("unknown env kind: " <> other))
  scopeList <- traverse (parseScope (jeVarName e)) (fromMaybe [] (jeScopes e))
  let scopeSet = Set.fromList scopeList
      finalScopes = if Set.null scopeSet then Set.singleton Runtime else scopeSet
  sev <- first (MarshalError ("env." <> jeVarName e <> ".scopes")) (scopedEnv finalScopes v)
  Right (n, sev)

toResources :: JsonDeployment -> Either LoadError (Maybe Resources)
toResources jd =
  case (jdCpuRequest jd, jdMemoryRequest jd, jdCpuLimit jd, jdMemoryLimit jd) of
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
  scheme' <- case jhcScheme jhc of
    "HTTP" -> Right HTTP
    "HTTPS" -> Right HTTPS
    other -> Left (MarshalError "healthCheck.scheme" ("unknown scheme: " <> other))
  checkPort' <- traverse (first (MarshalError "healthCheck.checkPort") . mkPort) (jhcCheckPort jhc)
  fmap Just . first (MarshalError "healthCheck") $
    mkHealthCheck
      HealthCheck
        { path = jhcPath jhc
        , checkPort = checkPort'
        , scheme = scheme'
        , expectedStatus = jhcExpectedStatus jhc
        , initialDelay = jhcInitialDelay jhc
        , period = jhcPeriod jhc
        , timeout = jhcTimeout jhc
        , failureThreshold = jhcFailureThreshold jhc
        , asLiveness = jhcAsLiveness jhc
        , asStartup = jhcAsStartup jhc
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
-- an app via @taskApp@ must name the enclosing app, not some other app.
checkTaskApp :: Text -> Task -> Either LoadError ()
checkTaskApp thisApp tk =
  case taskApp tk of
    Just a
      | serviceNameText a /= thisApp ->
          Left
            ( MarshalError
                "tasks"
                ( "task '"
                    <> serviceNameText (taskName tk)
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
  vn <- first (MarshalError "volumes.name") $ mkVolumeName (jvName jv)
  sz <- first (MarshalError "volumes.size") $ mkQuantity (jvSize jv)
  mp <- first (MarshalError "volumes.mountPath") $ mkMountPath (jvMountPath jv)
  am <- case fromMaybe "ReadWriteOnce" (jvAccessMode jv) of
    "ReadWriteOnce" -> Right ReadWriteOnce
    other -> Left (MarshalError "volumes.accessMode" ("unknown access mode: " <> other))
  rp <- case fromMaybe "Retain" (jvRetention jv) of
    "Retain" -> Right Retain
    "Delete" -> Right Delete
    other -> Left (MarshalError "volumes.retention" ("unknown retention policy: " <> other))
  Right
    Volume
      { volName = vn
      , size = sz
      , mountPath = mp
      , accessMode = am
      , readOnly = jvReadOnly jv
      , retention = rp
      }

-- | Re-validate the @volumes@ array and enforce the two cross-field uniqueness
-- invariants (no duplicate volume name, no duplicate mount path) that the pure
-- 'Volume' constructor cannot — producing a precise 'MarshalError "volumes"' on
-- a clash. This is the load-time check 'Nagare.Dsl.Presets.attachVolume' defers.
toVolumes :: [JsonVolume] -> Either LoadError [Volume]
toVolumes jvs = do
  vols <- traverse toVolume jvs
  let names = map (volumeNameText . volName) vols
      paths = map (mountPathText . mountPath) vols
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
    Right envelope -> case jkeKind envelope of
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
    Right envelope -> case jkeKind envelope of
      Just "Broker" -> case eitherDecodeStrict bs of
        Left perr ->
          Left (MarshalError "json" ("could not decode broker: " <> Text.pack perr))
        Right jb -> toBroker jb
      Just other -> Left (UnexpectedKind "Broker" other)
      Nothing -> Left (UnexpectedKind "Broker" "<none>")

-- ---------------------------------------------------------------------------
-- JSON intermediate for databases (mirrors Nagare.Dsl.Config's emitted shape)

data JsonDatabase = JsonDatabase
  { jdbName :: !Text
  , jdbEngine :: !Text
  , jdbVersion :: !Text
  , jdbNamespace :: !Text
  , jdbSize :: !Text
  , jdbCpuRequest :: !(Maybe Text)
  , jdbMemoryRequest :: !(Maybe Text)
  , jdbCpuLimit :: !(Maybe Text)
  , jdbMemoryLimit :: !(Maybe Text)
  , jdbRetention :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonDatabase where
  parseJSON = withObject "Database" $ \o ->
    JsonDatabase
      <$> o .: "name"
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
  name' <- first (MarshalError "name") $ mkDatabaseName (jdbName j)
  eng' <- case parseEngine (jdbEngine j) of
    Just e -> Right e
    Nothing -> Left (MarshalError "engine" ("unknown engine: " <> jdbEngine j))
  ver' <- first (MarshalError "version") $ mkEngineVersion eng' (jdbVersion j)
  ns' <- first (MarshalError "namespace") $ mkNamespace (jdbNamespace j)
  size' <- first (MarshalError "size") $ mkQuantity (jdbSize j)
  res' <- toDbResources j
  ret' <- case fromMaybe "Retain" (jdbRetention j) of
    "Retain" -> Right Retain
    "Delete" -> Right Delete
    other -> Left (MarshalError "retention" ("unknown retention policy: " <> other))
  Right
    Database
      { dbName = name'
      , engine = eng'
      , version = ver'
      , namespace = ns'
      , size = size'
      , resources = res'
      , retention = ret'
      }

toDbResources :: JsonDatabase -> Either LoadError (Maybe Resources)
toDbResources j =
  case (jdbCpuRequest j, jdbMemoryRequest j, jdbCpuLimit j, jdbMemoryLimit j) of
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
    Right envelope -> case jkeKind envelope of
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
  { jtName :: !Text
  , jtNamespace :: !Text
  , jtSchedule :: !Text
  , jtImage :: !(Maybe Text)
  , jtApp :: !(Maybe Text)
  , jtCommand :: ![Text]
  , jtArgs :: ![Text]
  , jtEnv :: ![JsonEnvEntry]
  , jtCpuRequest :: !(Maybe Text)
  , jtMemoryRequest :: !(Maybe Text)
  , jtCpuLimit :: !(Maybe Text)
  , jtMemoryLimit :: !(Maybe Text)
  , jtTimeoutSeconds :: !(Maybe Int)
  , jtConcurrencyPolicy :: !(Maybe Text)
  , jtRestartPolicy :: !(Maybe Text)
  , jtBackoffLimit :: !(Maybe Int)
  , jtSuccessfulJobsHistoryLimit :: !(Maybe Int)
  , jtFailedJobsHistoryLimit :: !(Maybe Int)
  , jtStartingDeadlineSeconds :: !(Maybe Int)
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
  name' <- first (MarshalError "name") $ mkServiceName (jtName j)
  ns' <- first (MarshalError "namespace") $ mkNamespace (jtNamespace j)
  sched' <- first (MarshalError "schedule") $ mkSchedule (jtSchedule j)
  img' <- traverse (first (MarshalError "image") . mkImageRef) (jtImage j)
  app' <- traverse (first (MarshalError "app") . mkServiceName) (jtApp j)
  env' <- mapM toEnvEntry (jtEnv j)
  res' <- toTaskResources j
  cp' <- case parseConcurrencyPolicy (fromMaybe "Forbid" (jtConcurrencyPolicy j)) of
    Just p -> Right p
    Nothing ->
      Left
        ( MarshalError
            "concurrencyPolicy"
            ("unknown concurrency policy: " <> fromMaybe "" (jtConcurrencyPolicy j))
        )
  rp' <- case parseRestartPolicy (fromMaybe "Never" (jtRestartPolicy j)) of
    Just p -> Right p
    Nothing ->
      Left
        ( MarshalError
            "restartPolicy"
            ("unknown restart policy: " <> fromMaybe "" (jtRestartPolicy j))
        )
  first (MarshalError "task") $
    mkTask
      Task
        { taskName = name'
        , taskNamespace = ns'
        , taskSchedule = sched'
        , taskImage = img'
        , taskApp = app'
        , taskCommand = jtCommand j
        , taskArgs = jtArgs j
        , taskEnv = Map.fromList env'
        , taskResources = res'
        , taskTimeoutSeconds = jtTimeoutSeconds j
        , taskConcurrencyPolicy = cp'
        , taskRestartPolicy = rp'
        , taskBackoffLimit = fromMaybe 0 (jtBackoffLimit j)
        , taskSuccessfulJobsHistoryLimit = fromMaybe 3 (jtSuccessfulJobsHistoryLimit j)
        , taskFailedJobsHistoryLimit = fromMaybe 1 (jtFailedJobsHistoryLimit j)
        , taskStartingDeadlineSeconds = jtStartingDeadlineSeconds j
        }

toTaskResources :: JsonTask -> Either LoadError (Maybe Resources)
toTaskResources j =
  case (jtCpuRequest j, jtMemoryRequest j, jtCpuLimit j, jtMemoryLimit j) of
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
    Right envelope -> case jkeKind envelope of
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
  { jjName :: !Text
  , jjNamespace :: !Text
  , jjImage :: !Text
  , jjBuild :: !(Maybe JsonBuildSpec)
  , jjCommand :: !(Maybe [Text])
  , jjEnv :: ![JsonEnvEntry]
  , jjCpuRequest :: !(Maybe Text)
  , jjMemoryRequest :: !(Maybe Text)
  , jjCpuLimit :: !(Maybe Text)
  , jjMemoryLimit :: !(Maybe Text)
  , jjBackoffLimit :: !Int
  , jjActiveDeadlineSeconds :: !(Maybe Int)
  , jjTtlSecondsAfterFinished :: !(Maybe Int)
  , jjScratchSize :: !Text
  , jjNixConfigMap :: !(Maybe Text)
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
  name' <- first (MarshalError "name") $ mkServiceName (jjName j)
  namespace' <- first (MarshalError "namespace") $ mkNamespace (jjNamespace j)
  image' <- first (MarshalError "image") $ mkImageRef (jjImage j)
  build' <- case jjBuild j of
    Nothing -> first (MarshalError "build") defaultBuild
    Just build -> toBuildSpec build
  command' <- traverse (first (MarshalError "command") . mkCommand) (jjCommand j)
  env' <- mapM toEnvEntry (jjEnv j)
  resources' <- toJobResources j
  scratch' <- first (MarshalError "scratchSize") $ mkQuantity (jjScratchSize j)
  nixConfigMap' <- traverse (first (MarshalError "nixConfigMap") . mkConfigMapName) (jjNixConfigMap j)
  first (MarshalError "job") $
    mkJob
      Job
        { jobName = name'
        , jobNamespace = namespace'
        , jobImage = image'
        , jobBuild = build'
        , jobCommand = command'
        , jobEnv = Map.fromList env'
        , jobResources = resources'
        , jobBackoffLimit = jjBackoffLimit j
        , jobActiveDeadlineSeconds = jjActiveDeadlineSeconds j
        , jobTtlSecondsAfterFinished = jjTtlSecondsAfterFinished j
        , jobScratchSize = scratch'
        , jobNixConfigMap = nixConfigMap'
        }

toJobResources :: JsonJob -> Either LoadError (Maybe Resources)
toJobResources j =
  case (jjCpuRequest j, jjMemoryRequest j, jjCpuLimit j, jjMemoryLimit j) of
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
    Right envelope -> case jkeKind envelope of
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
  { jwName :: !Text
  , jwNamespace :: !Text
  , jwImage :: !Text
  , jwBuild :: !(Maybe JsonBuildSpec)
  , jwCommand :: !(Maybe [Text])
  , jwReplicas :: !Int
  , jwEnv :: ![JsonEnvEntry]
  , jwCpuRequest :: !(Maybe Text)
  , jwMemoryRequest :: !(Maybe Text)
  , jwCpuLimit :: !(Maybe Text)
  , jwMemoryLimit :: !(Maybe Text)
  , jwVolumes :: ![JsonVolume]
  , jwDatabases :: ![Text]
  , jwBrokers :: ![JsonBrokerBinding]
  , jwLiveness :: !(Maybe JsonWorkerProbe)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonWorker where
  parseJSON = withObject "Worker" $ \o ->
    JsonWorker
      <$> o .: "name"
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
  { jwpKind :: !Text
  , jwpCommand :: !(Maybe [Text])
  , jwpPort :: !(Maybe Int)
  , jwpPath :: !(Maybe Text)
  , jwpCheckPort :: !(Maybe Int)
  , jwpScheme :: !(Maybe Text)
  , jwpInitialDelay :: !Int
  , jwpPeriod :: !Int
  , jwpTimeout :: !Int
  , jwpFailureThreshold :: !Int
  , jwpAsStartup :: !Bool
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
  case jwpKind j of
    "Exec" -> do
      argv <-
        maybe (Left (MarshalError "liveness" "Exec probe missing 'command' field")) Right (jwpCommand j)
      first (MarshalError "liveness") (mkExecProbe argv timing)
    "Tcp" -> do
      p <- maybe (Left (MarshalError "liveness" "Tcp probe missing 'port' field")) Right (jwpPort j)
      port <- first (MarshalError "liveness.port") (mkPort p)
      t <- first (MarshalError "liveness") (mkProbeTiming timing)
      Right (mkTcpProbe port t)
    "Http" -> do
      path <-
        maybe (Left (MarshalError "liveness" "Http probe missing 'path' field")) Right (jwpPath j)
      mport <- traverse (first (MarshalError "liveness.checkPort") . mkPort) (jwpCheckPort j)
      scheme <- case fromMaybe "HTTP" (jwpScheme j) of
        "HTTP" -> Right HTTP
        "HTTPS" -> Right HTTPS
        other -> Left (MarshalError "liveness.scheme" ("unknown scheme: " <> other))
      first (MarshalError "liveness") (mkHttpProbe path mport scheme timing)
    other -> Left (MarshalError "liveness.kind" ("unknown probe kind: " <> other))
  where
    timing =
      ProbeTiming
        { initialDelay = jwpInitialDelay j
        , period = jwpPeriod j
        , timeout = jwpTimeout j
        , failureThreshold = jwpFailureThreshold j
        , asStartup = jwpAsStartup j
        }

-- | Re-validate a decoded worker: re-run every smart constructor
-- ('mkServiceName', 'mkNamespace', 'mkImageRef', 'mkReplicas', 'mkCommand', the
-- shared build/env/resources/volume marshallers, and 'mkDatabaseName'). Volume
-- name / mount-path uniqueness is enforced by the reused 'toVolumes', exactly as
-- 'toDeployment' enforces it. Any failure is a precise 'MarshalError'.
toWorker :: JsonWorker -> Either LoadError Worker
toWorker j = do
  name' <- first (MarshalError "name") $ mkServiceName (jwName j)
  ns' <- first (MarshalError "namespace") $ mkNamespace (jwNamespace j)
  img' <- first (MarshalError "image") $ mkImageRef (jwImage j)
  build' <- case jwBuild j of
    Nothing -> first (MarshalError "build") defaultBuild
    Just jb -> toBuildSpec jb
  command' <- traverse (first (MarshalError "command") . mkCommand) (jwCommand j)
  replicas' <- first (MarshalError "replicas") $ mkReplicas (jwReplicas j)
  env' <- mapM toEnvEntry (jwEnv j)
  res' <- toWorkerResources j
  vols' <- toVolumes (jwVolumes j)
  dbRefs' <- traverse (first (MarshalError "databases") . mkDatabaseName) (jwDatabases j)
  brokerRefs' <- traverse (toBrokerBinding "brokers") (jwBrokers j)
  liveness' <- traverse toWorkerProbe (jwLiveness j)
  Right
    Worker
      { name = name'
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
  case (jwCpuRequest j, jwMemoryRequest j, jwCpuLimit j, jwMemoryLimit j) of
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
    Right envelope -> case jkeKind envelope of
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
  { jaName :: !Text
  , jaNamespace :: !Text
  , jaImage :: !Text
  , jaEnv :: ![JsonEnvEntry]
  , jaDatabases :: ![JsonDatabase]
  , jaBrokers :: ![JsonBrokerBinding]
  , jaAccess :: !(Maybe JsonAccessPolicy)
  , jaService :: !(Maybe JsonDeployment)
  , jaWorkers :: ![JsonWorker]
  , jaTasks :: ![JsonTask]
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonApplication where
  parseJSON = withObject "Application" $ \o ->
    JsonApplication
      <$> o .: "name"
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
  name' <- first (MarshalError "name") $ mkServiceName (jaName j)
  ns' <- first (MarshalError "namespace") $ mkNamespace (jaNamespace j)
  img' <- first (MarshalError "image") $ mkImageRef (jaImage j)
  env' <- mapM toEnvEntry (jaEnv j)
  dbs' <- traverse toDatabase (jaDatabases j)
  brokerRefs' <- traverse (toBrokerBinding "brokers") (jaBrokers j)
  access' <- traverse toAccessPolicy (jaAccess j)
  svc' <- traverse toDeployment (jaService j)
  wks' <- traverse toWorker (jaWorkers j)
  tks' <- traverse toTask (jaTasks j)
  let assembled =
        Application
          { appName = name'
          , namespace = ns'
          , image = img'
          , env = Map.fromList env'
          , appDatabases = dbs'
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
    Right envelope -> case jkeKind envelope of
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
  { jcrPathPrefix :: !Text
  , jcrEdgeTtlSeconds :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonCdnCacheRule where
  parseJSON = withObject "CdnCacheRule" $ \o ->
    JsonCdnCacheRule <$> o .: "pathPrefix" <*> o .:? "edgeTtlSeconds"

-- | The decoded @"cdn"@ object. @cacheStaticAssets@ defaults to 'True' and
-- @cacheRules@ to @[]@ so a hand-written partial object is forgiving, mirroring
-- how 'JsonVolume'/'JsonHealthCheck' default their optional fields.
data JsonCdn = JsonCdn
  { jcProvider :: !Text
  , jcDefaultTtlSeconds :: !(Maybe Int)
  , jcCacheStaticAssets :: !Bool
  , jcCacheRules :: ![JsonCdnCacheRule]
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
  prov <- case jcProvider j of
    "Cloudflare" -> Right CloudflareCdn
    "GcpCloudCdn" -> Right GcpCloudCdn
    other -> Left (MarshalError "cdn.provider" ("unknown cdn provider: " <> other))
  case jcDefaultTtlSeconds j of
    Just n
      | n < 0 ->
          Left (MarshalError "cdn.defaultTtlSeconds" ("must be >= 0, got: " <> Text.pack (show n)))
    _ -> Right ()
  rules <- traverse toCdnCacheRule (jcCacheRules j)
  Right
    Cdn
      { provider = prov
      , defaultTtlSeconds = jcDefaultTtlSeconds j
      , cacheStaticAssets = jcCacheStaticAssets j
      , cacheRules = rules
      }
  where
    toCdnCacheRule r =
      first (MarshalError "cdn.cacheRules") $
        mkCdnCacheRule (jcrPathPrefix r) (jcrEdgeTtlSeconds r)

-- ---------------------------------------------------------------------------
-- JSON intermediate for static sites (mirrors Nagare.Dsl.Config's emitted shape)

-- | A minimal envelope used to read the top-level @kind@ discriminator before
-- committing to a full decode.
newtype JsonKindEnvelope = JsonKindEnvelope {jkeKind :: Maybe Text}
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonKindEnvelope where
  parseJSON = withObject "kinded" $ \o -> JsonKindEnvelope <$> o .:? "kind"

data JsonStaticBuild = JsonStaticBuild
  { jsbKind :: !Text
  , jsbDirectory :: !(Maybe Text)
  , jsbCommand :: !(Maybe Text)
  , jsbOutputDirectory :: !(Maybe Text)
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
  { jrFrom :: !Text
  , jrTo :: !Text
  , jrStatus :: !Int
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonRedirect where
  parseJSON = withObject "RedirectRule" $ \o ->
    JsonRedirect <$> o .: "from" <*> o .: "to" <*> o .: "status"

data JsonHeader = JsonHeader
  { jhPath :: !Text
  , jhName :: !Text
  , jhValue :: !Text
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonHeader where
  parseJSON = withObject "HeaderRule" $ \o ->
    JsonHeader <$> o .: "path" <*> o .: "name" <*> o .: "value"

data JsonCache = JsonCache
  { jcImmutableAssets :: !Bool
  , jcDefaultMaxAge :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonCache where
  parseJSON = withObject "CachePolicy" $ \o ->
    JsonCache <$> o .: "immutableAssets" <*> o .:? "defaultMaxAge"

data JsonStaticSite = JsonStaticSite
  { jssName :: !Text
  , jssNamespace :: !Text
  , jssImage :: !Text
  , jssBuild :: !JsonStaticBuild
  , jssDomains :: ![Text]
  , jssRedirects :: ![JsonRedirect]
  , jssHeaders :: ![JsonHeader]
  , jssCache :: !JsonCache
  , jssNotFound :: !(Maybe Text)
  , jssCdn :: !(Maybe JsonCdn)
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
  name' <- first (MarshalError "name") $ mkSiteName (jssName j)
  ns' <- first (MarshalError "namespace") $ mkNamespace (jssNamespace j)
  img' <- first (MarshalError "image") $ mkImageRef (jssImage j)
  build' <- toStaticBuild (jssBuild j)
  domains' <- traverse (first (MarshalError "domain") . mkDomain) (jssDomains j)
  redirects' <- traverse toRedirect (jssRedirects j)
  headers' <- traverse toHeader (jssHeaders j)
  cache' <-
    first (MarshalError "cache") $
      mkCachePolicy (jcImmutableAssets cacheJ) (jcDefaultMaxAge cacheJ)
  notFound' <- traverse (first (MarshalError "notFound") . mkFilePathText) (jssNotFound j)
  cdn' <- traverse toCdn (jssCdn j)
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
    cacheJ = jssCache j

toStaticBuild :: JsonStaticBuild -> Either LoadError StaticBuild
toStaticBuild jb = case jsbKind jb of
  "NoBuild" -> case jsbDirectory jb of
    Nothing -> Left (MarshalError "build" "NoBuild entry missing 'directory' field")
    Just d -> fmap NoBuild . first (MarshalError "build.directory") $ mkFilePathText d
  "BuildCommand" -> do
    cmd <-
      maybe (Left (MarshalError "build" "BuildCommand entry missing 'command' field")) Right $
        jsbCommand jb
    outD <-
      maybe (Left (MarshalError "build" "BuildCommand entry missing 'outputDirectory' field")) Right $
        jsbOutputDirectory jb
    outD' <- first (MarshalError "build.outputDirectory") $ mkFilePathText outD
    Right (BuildCommand {command = cmd, outputDirectory = outD'})
  other -> Left (MarshalError "build.kind" ("unknown build kind: " <> other))

toRedirect :: JsonRedirect -> Either LoadError RedirectRule
toRedirect jr =
  first (MarshalError "redirect") $ mkRedirectRule (jrFrom jr) (jrTo jr) (jrStatus jr)

toHeader :: JsonHeader -> Either LoadError HeaderRule
toHeader jh =
  first (MarshalError "header") $ mkHeaderRule (jhPath jh) (jhName jh) (jhValue jh)

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
    Right envelope -> case jkeKind envelope of
      Just "StaticSite" -> case eitherDecodeStrict bs of
        Left perr ->
          Left (MarshalError "json" ("could not decode static site: " <> Text.pack perr))
        Right jss -> toStaticSite jss
      Just other -> Left (UnexpectedKind "StaticSite" other)
      Nothing -> Left (UnexpectedKind "StaticSite" "<none>")

-- | Compile-and-run a config-as-program source file with @runghc@ and capture
-- the JSON it prints on stdout, mapping every failure mode to a 'LoadError'.
--
-- The file is run with @runghc@ (the house @GHC2024@ edition, the local
-- @nagare-dsl@ package exposed, and the config's directory on the include path).
-- The config must print its JSON via one of the @Nagare.Dsl.Config.emit*@
-- helpers; empty output means it never called one ('MissingBinding'). The
-- decoder that reads the captured bytes is chosen by the caller
-- ('decodeDeployment' or 'decodeStaticSite').
runConfig :: FilePath -> IO (Either LoadError ByteString)
runConfig path = do
  exists <- doesFileExist path
  if not exists
    then pure (Left (FileNotFound path))
    else do
      let configDir = takeDirectory path
      result <-
        try @IOException $
          readProcessWithExitCode
            "runghc"
            ["--ghc-arg=-XGHC2024", "--ghc-arg=-package", "--ghc-arg=nagare-dsl", "-i" <> configDir, path]
            ""
      pure $ case result of
        Left ioErr -> Left (CompileError path (Text.pack (show ioErr)))
        Right (ExitFailure _, _out, err) -> Left (CompileError path (Text.pack err))
        Right (ExitSuccess, out, _err)
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
loadStaticSite path = fmap (>>= decodeStaticSite) (runConfig path)

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
    Right envelope -> case jkeKind envelope of
      Just "StaticSite" -> SiteStatic <$> decodeStaticSite bs
      Just "ServerSite" -> SiteServer <$> decodeServerSite bs
      Just other -> Left (UnexpectedKind "StaticSite or ServerSite" other)
      Nothing -> Left (UnexpectedKind "StaticSite or ServerSite" "<none>")

-- ---------------------------------------------------------------------------
-- JSON intermediate for server sites (mirrors Nagare.Dsl.Config's emitted shape)

data JsonServerBuild = JsonServerBuild
  { srvCommand :: !Text
  , srvOutputDirs :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonServerBuild where
  parseJSON = withObject "ServerBuild" $ \o ->
    JsonServerBuild <$> o .: "command" <*> o .: "outputDirs"

data JsonServerRuntime = JsonServerRuntime
  { jsrBaseImage :: !Text
  , jsrStartCommand :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonServerRuntime where
  parseJSON = withObject "ServerRuntime" $ \o ->
    JsonServerRuntime <$> o .: "baseImage" <*> o .: "startCommand"

data JsonServerSite = JsonServerSite
  { jsvName :: !Text
  , jsvNamespace :: !Text
  , jsvImage :: !Text
  , jsvBuild :: !JsonServerBuild
  , jsvRuntime :: !JsonServerRuntime
  , jsvPort :: !Int
  , jsvEnv :: ![JsonEnvEntry]
  , jsvCpuRequest :: !(Maybe Text)
  , jsvMemoryRequest :: !(Maybe Text)
  , jsvScaleMin :: !(Maybe Int)
  , jsvScaleMax :: !(Maybe Int)
  , jsvDomains :: ![Text]
  , jsvVolumes :: ![JsonVolume]
  , jsvCdn :: !(Maybe JsonCdn)
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
  name' <- first (MarshalError "name") $ mkSiteName (jsvName j)
  ns' <- first (MarshalError "namespace") $ mkNamespace (jsvNamespace j)
  img' <- first (MarshalError "image") $ mkImageRef (jsvImage j)
  build' <- toServerBuild (jsvBuild j)
  runtime' <- toServerRuntime (jsvRuntime j)
  port' <- first (MarshalError "port") $ mkPort (jsvPort j)
  env' <- mapM toEnvEntry (jsvEnv j)
  res' <- toServerResources (jsvCpuRequest j) (jsvMemoryRequest j)
  scale' <- case (jsvScaleMin j, jsvScaleMax j) of
    (Nothing, Nothing) -> Right Nothing
    (Just mn, Just mx) -> fmap Just . first (MarshalError "scale") $ mkScale mn mx
    _ -> Left (MarshalError "scale" "scaleMin and scaleMax must both be present or both absent")
  domains' <- traverse (first (MarshalError "domain") . mkDomain) (jsvDomains j)
  vols' <- toVolumes (jsvVolumes j)
  cdn' <- traverse toCdn (jsvCdn j)
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
  dirs <- traverse (first (MarshalError "build.outputDirs") . mkFilePathText) (srvOutputDirs jb)
  neDirs <- maybe (Left (MarshalError "build.outputDirs" "outputDirs must be non-empty")) Right (NE.nonEmpty dirs)
  Right (ServerBuild {command = srvCommand jb, outputDirs = neDirs})

toServerRuntime :: JsonServerRuntime -> Either LoadError ServerRuntime
toServerRuntime jr = do
  base <- first (MarshalError "runtime.baseImage") $ mkRuntimeImage (jsrBaseImage jr)
  neCmd <- maybe (Left (MarshalError "runtime.startCommand" "startCommand must be non-empty")) Right (NE.nonEmpty (jsrStartCommand jr))
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
    Right envelope -> case jkeKind envelope of
      Just "ServerSite" -> case eitherDecodeStrict bs of
        Left perr ->
          Left (MarshalError "json" ("could not decode server site: " <> Text.pack perr))
        Right jss -> toServerSite jss
      Just other -> Left (UnexpectedKind "ServerSite" other)
      Nothing -> Left (UnexpectedKind "ServerSite" "<none>")
