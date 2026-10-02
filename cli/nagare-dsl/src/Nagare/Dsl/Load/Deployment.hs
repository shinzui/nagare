-- | Deployment responsibilities; internal implementation behind Nagare.Dsl.Load.
module Nagare.Dsl.Load.Deployment
  ( JsonDeployment (..)
  , decodeDeployment
  , toDeployment
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
import Nagare.Dsl.Load.Cdn (JsonCdn (..), toCdn)
import Nagare.Dsl.Load.Error (LoadError (..))
import Nagare.Dsl.Load.Fields
  ( JsonAccessPolicy (..)
  , JsonBuildSpec (..)
  , JsonDomainEntry (..)
  , JsonEnvEntry (..)
  , JsonHealthCheck (..)
  , JsonKindEnvelope (..)
  , JsonVolume (..)
  , checkTaskApp
  , firstDuplicate
  , toAccessPolicy
  , toBuildSpec
  , toDomainSpecs
  , toEnvEntry
  , toHealthCheck
  , toVolumes
  )
import Nagare.Dsl.Load.Task (JsonTask (..), toTask)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types
  ( Deployment (..)
  , Resources (..)
  , mkImageRef
  , mkNamespace
  , mkPort
  , mkQuantity
  , mkScale
  , mkServiceName
  , serviceNameText
  )
import Nagare.Resource.Types (mkLogicalKey)

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
