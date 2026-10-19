-- | App-database responsibilities; internal implementation behind Nagare.Dsl.Load.
module Nagare.Dsl.Load.AppDatabase
  ( JsonAppDatabase (..)
  , decodeAppDatabases
  , toAppDatabase
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
import Data.List.NonEmpty (nonEmpty)
import Data.Text qualified as Text
import Nagare.Dsl.AppDatabase
  ( AppDatabase (..)
  , appDatabaseNameText
  , mkAppDatabaseName
  , mkLogicalDatabaseName
  , validateAppDatabase
  )
import Nagare.Dsl.Database (mkDatabaseName, parseEngine)
import Nagare.Dsl.Load.Error (LoadError (..))
import Nagare.Dsl.Load.Fields (JsonKindEnvelope (..), firstDuplicate)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (mkNamespace)
import Nagare.Resource.Types (mkLogicalKey)

-- | The JSON 'Nagare.Dsl.Config.emitAppDatabases' writes for one entry.
data JsonAppDatabase = JsonAppDatabase
  { name :: !Text
  , logicalKey :: !(Maybe Text)
  , server :: !Text
  , engine :: !Text
  , namespace :: !Text
  , logicalDatabases :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonAppDatabase where
  parseJSON = withObject "AppDatabase" $ \o ->
    JsonAppDatabase
      <$> o .: "name"
      <*> o .:? "logicalKey"
      <*> o .: "server"
      <*> o .: "engine"
      <*> o .: "namespace"
      <*> o .: "logicalDatabases"

newtype JsonAppDatabases = JsonAppDatabases [JsonAppDatabase]

instance FromJSON JsonAppDatabases where
  parseJSON = withObject "AppDatabases" $ \o -> JsonAppDatabases <$> o .: "appDatabases"

toAppDatabase :: JsonAppDatabase -> Either LoadError AppDatabase
toAppDatabase j = do
  name' <- first (MarshalError "name") $ mkAppDatabaseName (j ^. #name)
  key' <- traverse (first (MarshalError "logicalKey") . mkLogicalKey) (j ^. #logicalKey)
  server' <- first (MarshalError "server") $ mkDatabaseName (j ^. #server)
  eng' <- case parseEngine (j ^. #engine) of
    Just e -> Right e
    Nothing -> Left (MarshalError "engine" ("unknown engine: " <> j ^. #engine))
  ns' <- first (MarshalError "namespace") $ mkNamespace (j ^. #namespace)
  names <- traverse (first (MarshalError "logicalDatabases") . mkLogicalDatabaseName) (j ^. #logicalDatabases)
  logical <- maybe (Left (MarshalError "logicalDatabases" "app database declares no logical database")) Right (nonEmpty names)
  first (MarshalError (j ^. #name)) $
    validateAppDatabase
      AppDatabase
        { name = name'
        , logicalKey = key'
        , server = server'
        , engine = eng'
        , namespace = ns'
        , logicalDatabases = logical
        }

-- | Decode the JSON an app-database config emits (via
-- 'Nagare.Dsl.Config.emitAppDatabases'): every entry is validated, and two
-- entries may not share a name.
decodeAppDatabases :: ByteString -> Either LoadError [AppDatabase]
decodeAppDatabases bs =
  case eitherDecodeStrict bs of
    Left perr ->
      Left (MarshalError "json" ("could not decode config output: " <> Text.pack perr))
    Right (JsonKindEnvelope envelopeKind) -> case envelopeKind of
      Just "AppDatabases" -> case eitherDecodeStrict bs of
        Left perr ->
          Left (MarshalError "json" ("could not decode app databases: " <> Text.pack perr))
        Right (JsonAppDatabases entries) -> do
          when (null entries) (Left (MarshalError "appDatabases" "config declares no app database"))
          databases <- traverse toAppDatabase entries
          case firstDuplicate (map (appDatabaseNameText . (^. #name)) databases) of
            Just duplicate -> Left (MarshalError "appDatabases" ("app database declared twice: " <> duplicate))
            Nothing -> Right databases
      Just other -> Left (UnexpectedKind "AppDatabases" other)
      Nothing -> Left (UnexpectedKind "AppDatabases" "<none>")
