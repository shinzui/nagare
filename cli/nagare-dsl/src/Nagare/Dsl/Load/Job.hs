-- | Job responsibilities; internal implementation behind Nagare.Dsl.Load.
module Nagare.Dsl.Load.Job
  ( decodeJob
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
import Nagare.Dsl.Job (Job (..), mkConfigMapName, mkJob)
import Nagare.Dsl.Load.Error (LoadError (..))
import Nagare.Dsl.Load.Fields
  ( JsonBuildSpec (..)
  , JsonEnvEntry (..)
  , JsonKindEnvelope (..)
  , toBuildSpec
  , toEnvEntry
  )
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types
  ( Resources (..)
  , mkImageRef
  , mkNamespace
  , mkQuantity
  , mkServiceName
  )
import Nagare.Dsl.Worker (mkCommand)

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
