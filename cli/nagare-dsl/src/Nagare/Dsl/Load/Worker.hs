-- | Worker responsibilities; internal implementation behind Nagare.Dsl.Load.
module Nagare.Dsl.Load.Worker
  ( JsonWorker (..)
  , decodeWorker
  , toWorker
  )
where

import Data.Aeson
  ( FromJSON (..)
  , eitherDecodeStrict
  , withObject
  , (.!=)
  , (.:)
  , (.:?)
  )
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Nagare.Dsl.Build (defaultBuild)
import Nagare.Dsl.Database (mkDatabaseName)
import Nagare.Dsl.Load.Broker
  ( JsonBrokerBinding (..)
  , toBrokerBinding
  )
import Nagare.Dsl.Load.Error (LoadError (..))
import Nagare.Dsl.Load.Fields
  ( JsonAppDatabaseReaderRef
  , JsonBuildSpec (..)
  , JsonEnvEntry (..)
  , JsonKindEnvelope (..)
  , JsonVolume (..)
  , toAppDatabaseReaderRef
  , toBuildSpec
  , toEnvEntry
  , toVolumes
  )
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types
  ( HealthScheme (HTTP, HTTPS)
  , Resources (..)
  , mkAppDatabaseName
  , mkImageRef
  , mkNamespace
  , mkPort
  , mkQuantity
  , mkServiceAccountName
  , mkServiceName
  )
import Nagare.Dsl.Worker
  ( ProbeTiming (..)
  , Worker (..)
  , WorkerProbe
  , mkCommand
  , mkExecProbe
  , mkHttpProbe
  , mkProbeTiming
  , mkReplicas
  , mkShutdownSeconds
  , mkTcpProbe
  )
import Nagare.Resource.Types (mkLogicalKey)

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
  , appDatabases :: ![Text]
  , appDatabaseReaders :: ![JsonAppDatabaseReaderRef]
  , brokers :: ![JsonBrokerBinding]
  , liveness :: !(Maybe JsonWorkerProbe)
  , readiness :: !(Maybe JsonWorkerProbe)
  , shutdownSeconds :: !(Maybe Int)
  , serviceAccount :: !(Maybe Text)
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
      <*> o .:? "appDatabases" .!= []
      <*> o .:? "appDatabaseReaders" .!= []
      <*> o .:? "brokers" .!= []
      <*> o .:? "liveness"
      <*> o .:? "readiness"
      <*> o .:? "shutdownSeconds"
      <*> o .:? "serviceAccount"

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

-- | Re-validate a decoded probe, dispatching on the @kind@ and re-running the
-- relevant smart constructor (and 'mkProbeTiming' / 'mkPort'). The first argument
-- names the probe, so a missing per-kind field or unknown kind/scheme is a
-- precise 'MarshalError' under that name.
toWorkerProbe :: Text -> JsonWorkerProbe -> Either LoadError WorkerProbe
toWorkerProbe field j =
  case j ^. #kind of
    "Exec" -> do
      argv <-
        maybe (Left (MarshalError field "Exec probe missing 'command' field")) Right (j ^. #command)
      first (MarshalError field) (mkExecProbe argv timing)
    "Tcp" -> do
      p <- maybe (Left (MarshalError field "Tcp probe missing 'port' field")) Right (j ^. #port)
      port <- first (MarshalError (field <> ".port")) (mkPort p)
      t <- first (MarshalError field) (mkProbeTiming timing)
      Right (mkTcpProbe port t)
    "Http" -> do
      path <-
        maybe (Left (MarshalError field "Http probe missing 'path' field")) Right (j ^. #path)
      mport <- traverse (first (MarshalError (field <> ".checkPort")) . mkPort) (j ^. #checkPort)
      scheme <- case fromMaybe "HTTP" (j ^. #scheme) of
        "HTTP" -> Right HTTP
        "HTTPS" -> Right HTTPS
        other -> Left (MarshalError (field <> ".scheme") ("unknown scheme: " <> other))
      first (MarshalError field) (mkHttpProbe path mport scheme timing)
    other -> Left (MarshalError (field <> ".kind") ("unknown probe kind: " <> other))
  where
    timing =
      ProbeTiming
        { initialDelay = j ^. #initialDelay
        , period = j ^. #period
        , timeout = j ^. #timeout
        , failureThreshold = j ^. #failureThreshold
        , asStartup = j ^. #asStartup
        }

-- | A readiness probe has no startup form: 'asStartup' repeats a liveness check.
toReadinessProbe :: JsonWorkerProbe -> Either LoadError WorkerProbe
toReadinessProbe j
  | j ^. #asStartup =
      Left (MarshalError "readiness.asStartup" "asStartup applies only to a liveness probe")
  | otherwise = toWorkerProbe "readiness" j

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
  appDbRefs' <- traverse (first (MarshalError "appDatabases") . mkAppDatabaseName) (j ^. #appDatabases)
  readerRefs' <- traverse toAppDatabaseReaderRef (j ^. #appDatabaseReaders)
  brokerRefs' <- traverse (toBrokerBinding "brokers") (j ^. #brokers)
  liveness' <- traverse (toWorkerProbe "liveness") (j ^. #liveness)
  readiness' <- traverse toReadinessProbe (j ^. #readiness)
  shutdown' <- traverse (first (MarshalError "shutdownSeconds") . mkShutdownSeconds) (j ^. #shutdownSeconds)
  serviceAccount' <- traverse (first (MarshalError "serviceAccount") . mkServiceAccountName) (j ^. #serviceAccount)
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
      , appDatabases = appDbRefs'
      , appDatabaseReaders = readerRefs'
      , brokers = brokerRefs'
      , liveness = liveness'
      , readiness = readiness'
      , shutdown = shutdown'
      , serviceAccount = serviceAccount'
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
