-- | StaticSite responsibilities; internal implementation behind Nagare.Dsl.Load.
module Nagare.Dsl.Load.StaticSite
  ( decodeStaticSite
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
import Nagare.Dsl.Load.Cdn (JsonCdn (..), toCdn)
import Nagare.Dsl.Load.Error (LoadError (..))
import Nagare.Dsl.Load.Fields
  ( JsonDomainEntry (..)
  , JsonKindEnvelope (..)
  , toDomainSpecs
  )
import Nagare.Dsl.Prelude
import Nagare.Dsl.Static.Types
  ( HeaderRule
  , RedirectRule
  , StaticBuild (..)
  , StaticSite (..)
  , mkCachePolicy
  , mkFilePathText
  , mkHeaderRule
  , mkRedirectRule
  , mkSiteName
  )
import Nagare.Dsl.Types (mkImageRef, mkNamespace)

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
