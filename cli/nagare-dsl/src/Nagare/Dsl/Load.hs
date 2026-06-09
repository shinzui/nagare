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
  , loadStaticSite
  , decodeStaticSite
  ) where

import Control.Exception (IOException, try)
import Data.Aeson (FromJSON (..), eitherDecodeStrict, withObject, (.:), (.:?))
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Nagare.Dsl.Prelude
import Nagare.Dsl.Static.Types
import Nagare.Dsl.Types
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory)
import System.Process (readProcessWithExitCode)

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
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonEnvEntry where
  parseJSON = withObject "EnvEntry" $ \o ->
    JsonEnvEntry
      <$> o .: "varName"
      <*> o .: "kind"
      <*> o .:? "value"
      <*> o .:? "secretName"

data JsonDeployment = JsonDeployment
  { jdName :: !Text
  , jdNamespace :: !Text
  , jdImage :: !Text
  , jdDomain :: !(Maybe Text)
  , jdPort :: !Int
  , jdEnv :: ![JsonEnvEntry]
  , jdCpuRequest :: !(Maybe Text)
  , jdMemoryRequest :: !(Maybe Text)
  , jdScaleMin :: !(Maybe Int)
  , jdScaleMax :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonDeployment where
  parseJSON = withObject "Deployment" $ \o ->
    JsonDeployment
      <$> o .: "name"
      <*> o .: "namespace"
      <*> o .: "image"
      <*> o .:? "domain"
      <*> o .: "port"
      <*> o .: "env"
      <*> o .:? "cpuRequest"
      <*> o .:? "memoryRequest"
      <*> o .:? "scaleMin"
      <*> o .:? "scaleMax"

-- ---------------------------------------------------------------------------
-- Marshalling JsonDeployment -> Deployment (re-runs EP-9 smart constructors)

toDeployment :: JsonDeployment -> Either LoadError Deployment
toDeployment jd = do
  name' <- mapLeft (MarshalError "name") $ mkServiceName (jdName jd)
  ns' <- mapLeft (MarshalError "namespace") $ mkNamespace (jdNamespace jd)
  img' <- mapLeft (MarshalError "image") $ mkImageRef (jdImage jd)
  dom' <- case jdDomain jd of
    Nothing -> Right Nothing
    Just t -> fmap Just . mapLeft (MarshalError "domain") $ mkDomain t
  port' <- mapLeft (MarshalError "port") $ mkPort (jdPort jd)
  env' <- mapM toEnvEntry (jdEnv jd)
  res' <- toResources jd
  scale' <- case (jdScaleMin jd, jdScaleMax jd) of
    (Nothing, Nothing) -> Right Nothing
    (Just mn, Just mx) -> fmap Just . mapLeft (MarshalError "scale") $ mkScale mn mx
    _ ->
      Left
        ( MarshalError
            "scale"
            "scaleMin and scaleMax must both be present or both absent"
        )
  Right
    Deployment
      { name = name'
      , namespace = ns'
      , image = img'
      , domain = dom'
      , port = port'
      , env = Map.fromList env'
      , resources = res'
      , scale = scale'
      }

toEnvEntry :: JsonEnvEntry -> Either LoadError (EnvName, EnvVar)
toEnvEntry e = do
  n <- mapLeft (MarshalError "env.varName") $ mkEnvName (jeVarName e)
  v <- case jeKind e of
    "Literal" -> case jeValue e of
      Nothing -> Left (MarshalError ("env." <> jeVarName e) "Literal entry missing 'value' field")
      Just lit -> Right (EnvLiteral lit)
    "SecretRef" -> case jeSecretName e of
      Nothing -> Left (MarshalError ("env." <> jeVarName e) "SecretRef entry missing 'secretName' field")
      Just sec ->
        fmap EnvSecretRef
          . mapLeft (MarshalError ("env." <> jeVarName e <> ".secretRef"))
          $ mkSecretName sec
    other -> Left (MarshalError ("env." <> jeVarName e <> ".kind") ("unknown env kind: " <> other))
  Right (n, v)

toResources :: JsonDeployment -> Either LoadError (Maybe Resources)
toResources jd =
  case (jdCpuRequest jd, jdMemoryRequest jd) of
    (Nothing, Nothing) -> Right Nothing
    (c, m) -> do
      c' <- traverse (mapLeft (MarshalError "cpuRequest") . mkQuantity) c
      m' <- traverse (mapLeft (MarshalError "memoryRequest") . mkQuantity) m
      Right (Just Resources {cpu = c', memory = m'})

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f = either (Left . f) Right

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
    Right jd -> toDeployment jd

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

-- ---------------------------------------------------------------------------
-- Marshalling JsonStaticSite -> StaticSite (re-runs the smart constructors)

toStaticSite :: JsonStaticSite -> Either LoadError StaticSite
toStaticSite j = do
  name' <- mapLeft (MarshalError "name") $ mkSiteName (jssName j)
  ns' <- mapLeft (MarshalError "namespace") $ mkNamespace (jssNamespace j)
  img' <- mapLeft (MarshalError "image") $ mkImageRef (jssImage j)
  build' <- toStaticBuild (jssBuild j)
  domains' <- traverse (mapLeft (MarshalError "domain") . mkDomain) (jssDomains j)
  redirects' <- traverse toRedirect (jssRedirects j)
  headers' <- traverse toHeader (jssHeaders j)
  cache' <-
    mapLeft (MarshalError "cache") $
      mkCachePolicy (jcImmutableAssets cacheJ) (jcDefaultMaxAge cacheJ)
  notFound' <- traverse (mapLeft (MarshalError "notFound") . mkFilePathText) (jssNotFound j)
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
      }
  where
    cacheJ = jssCache j

toStaticBuild :: JsonStaticBuild -> Either LoadError StaticBuild
toStaticBuild jb = case jsbKind jb of
  "NoBuild" -> case jsbDirectory jb of
    Nothing -> Left (MarshalError "build" "NoBuild entry missing 'directory' field")
    Just d -> fmap NoBuild . mapLeft (MarshalError "build.directory") $ mkFilePathText d
  "BuildCommand" -> do
    cmd <-
      maybe (Left (MarshalError "build" "BuildCommand entry missing 'command' field")) Right $
        jsbCommand jb
    outD <-
      maybe (Left (MarshalError "build" "BuildCommand entry missing 'outputDirectory' field")) Right $
        jsbOutputDirectory jb
    outD' <- mapLeft (MarshalError "build.outputDirectory") $ mkFilePathText outD
    Right (BuildCommand {command = cmd, outputDirectory = outD'})
  other -> Left (MarshalError "build.kind" ("unknown build kind: " <> other))

toRedirect :: JsonRedirect -> Either LoadError RedirectRule
toRedirect jr =
  mapLeft (MarshalError "redirect") $ mkRedirectRule (jrFrom jr) (jrTo jr) (jrStatus jr)

toHeader :: JsonHeader -> Either LoadError HeaderRule
toHeader jh =
  mapLeft (MarshalError "header") $ mkHeaderRule (jhPath jh) (jhName jh) (jhValue jh)

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
-- The file is run with @runghc@ (the house @GHC2024@ edition and the config's
-- directory on the include path). @runghc@ resolves the @nagare-dsl@ package
-- through the project's @.ghc.environment.*@ file
-- (@write-ghc-environment-files: always@ in @cabal.project@). The config must
-- print its JSON via one of the @Nagare.Dsl.Config.emit*@ helpers; empty output
-- means it never called one ('MissingBinding'). The decoder that reads the
-- captured bytes is chosen by the caller ('decodeDeployment' or
-- 'decodeStaticSite').
runConfig :: FilePath -> IO (Either LoadError ByteString)
runConfig path = do
  exists <- doesFileExist path
  if not exists
    then pure (Left (FileNotFound path))
    else do
      let configDir = takeDirectory path
      result <-
        try @IOException $
          readProcessWithExitCode "runghc" ["-XGHC2024", "-i" <> configDir, path] ""
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

-- | Load a 'StaticSite' from a Haskell config-as-program source file. The config
-- must print its JSON via 'Nagare.Dsl.Config.emitStaticSite'. A config that
-- instead emits a 'Deployment' (or a future @ServerSite@) is reported as
-- 'UnexpectedKind', not silently misread.
loadStaticSite :: FilePath -> IO (Either LoadError StaticSite)
loadStaticSite path = fmap (>>= decodeStaticSite) (runConfig path)
