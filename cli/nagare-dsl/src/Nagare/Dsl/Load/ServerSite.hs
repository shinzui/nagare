-- | ServerSite responsibilities; internal implementation behind Nagare.Dsl.Load.
module Nagare.Dsl.Load.ServerSite
  ( decodeServerSite
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
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Nagare.Dsl.Load.Cdn (JsonCdn (..), toCdn)
import Nagare.Dsl.Load.Error (LoadError (..))
import Nagare.Dsl.Load.Fields
  ( JsonDomainEntry (..)
  , JsonEnvEntry (..)
  , JsonKindEnvelope (..)
  , JsonVolume (..)
  , toDomainSpecs
  , toEnvEntry
  , toVolumes
  )
import Nagare.Dsl.Prelude
import Nagare.Dsl.Server.Types
  ( ServerBuild (..)
  , ServerRuntime (..)
  , ServerSite (..)
  , mkRuntimeImage
  )
import Nagare.Dsl.Static.Types (mkFilePathText, mkSiteName)
import Nagare.Dsl.Types
  ( Resources (..)
  , mkImageRef
  , mkNamespace
  , mkPort
  , mkQuantity
  , mkScale
  )

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
