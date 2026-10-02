-- | Database responsibilities; internal implementation behind Nagare.Dsl.Load.
module Nagare.Dsl.Load.Database
  ( JsonDatabase (..)
  , decodeDatabase
  , toDatabase
  )
where

import Data.Aeson
  ( FromJSON (parseJSON)
  , eitherDecodeStrict
  , withObject
  , (.:)
  , (.:?)
  )
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Nagare.Dsl.Database
  ( Database (..)
  , mkDatabaseName
  , mkEngineVersion
  , parseEngine
  )
import Nagare.Dsl.Load.Error (LoadError (..))
import Nagare.Dsl.Load.Fields (JsonKindEnvelope (..))
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types
  ( Resources (..)
  , RetentionPolicy (Delete, Retain)
  , mkNamespace
  , mkQuantity
  )
import Nagare.Resource.Types (mkLogicalKey)

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
