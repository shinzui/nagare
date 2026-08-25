{-# LANGUAGE OverloadedStrings #-}

-- | The single resolution point for the GCP "target profile" (MasterPlan 12,
-- EP-62; the variable contract is fixed by EP-60). Every value that used to be a
-- compile-time literal (the project, region, zone, Artifact Registry host/id, the
-- image/backup bucket names, the base domain, the VM instance name) is resolved
-- here, once, from the process environment with the EP-60 fallback defaults, so an
-- operator who sets @nagare.target.env@ (which EP-60's @.envrc@ exports) retargets
-- the whole CLI without editing Haskell. With nothing set, the defaults reproduce
-- the original tan-nb-exp / us-west1 / us-west1-a setup, so existing behavior is
-- unchanged. EP-63's @nagarectl init@ reuses this record.
module Nagare.Target
  ( ActiveTarget (..)
  , TargetProfile (..)
  , Mode (..)
  , PulumiEnv (..)
  , PulumiBackendKind (..)
  , ContextName
  , mkContextName
  , contextNameText
  , nagareConfigDir
  , nagareStateDir
  , contextsDir
  , contextFilePath
  , currentContextPath
  , contextStateDirName
  , listContexts
  , contextExists
  , readContextProfile
  , setCurrentContext
  , clearCurrentContext
  , deleteContext
  , writeContextPlatformVersion
  , parseMode
  , parseContextEnv
  , readContextMap
  , readCurrentContext
  , profileFromContextMap
  , pulumiEnvFor
  , parsePulumiBackendKind
  , pulumiBackendToken
  , defaultGcsPulumiBackendUrl
  , effectivePulumiBackend
  , resolveActiveContext
  , resolveActiveTarget
  , resolveTargetProfile
  , registryPrefix
  , minioCredentialsSecret
  , storeBackendFor
  )
where

import Control.Exception (IOException, try)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, toLower)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cluster.GcsJob
  ( MinioRef (..)
  , StoreBackend (..)
  , parseLocalObjectStore
  )
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, removeFile, renameFile)
import System.Environment (lookupEnv)
import System.FilePath (dropExtension, takeExtension, (<.>), (</>))

-- | The deploy target's mode (MasterPlan 16, EP-83; this is Integration Point 2's
-- public type — EP-84 and EP-85 import it and must not re-derive the mode from the
-- environment themselves). 'Cloud' is the original GCP target; 'Local' selects the
-- local k3d cluster + local registry from EP-82. Resolved from @NAGARE_MODE@ in
-- 'resolveTargetProfile'; with the variable unset the mode is 'Cloud', so existing
-- behavior is unchanged.
data Mode = Cloud | Local
  deriving stock (Eq, Show)

-- | Parse the @NAGARE_MODE@ value. The string @"local"@ (case-insensitive) selects
-- 'Local'; anything else — including 'Nothing' (unset), @"cloud"@, and any
-- unrecognized value — is 'Cloud'. Defaulting unknown values to 'Cloud' keeps the
-- fail-safe direction: a typo never silently points a cloud operator at a
-- nonexistent local cluster.
parseMode :: Maybe String -> Mode
parseMode m = case fmap (map toLower) m of
  Just "local" -> Local
  _ -> Cloud

-- | Which backend Pulumi stores stack state in for a context (EP-93). 'PulumiBackendLocal'
-- is EP-90's per-context @file://@ backend and is the default and the only local-mode
-- option; 'PulumiBackendGcs' is an opt-in remote Google Cloud Storage backend for
-- @mode=cloud@ contexts. Resolved from @NAGARE_PULUMI_BACKEND@; unset is 'PulumiBackendLocal',
-- so existing contexts keep their local file state.
data PulumiBackendKind = PulumiBackendLocal | PulumiBackendGcs
  deriving stock (Eq, Show)

-- | Parse @NAGARE_PULUMI_BACKEND@. Only @"gcs"@ (case-insensitive) selects GCS; anything
-- else — including 'Nothing' (unset), @"local"@, and any typo — is 'PulumiBackendLocal'.
-- Defaulting the unknown case to local keeps the fail-safe direction: a misspelling never
-- silently points state at a remote bucket.
parsePulumiBackendKind :: Maybe String -> PulumiBackendKind
parsePulumiBackendKind m = case fmap (map toLower) m of
  Just "gcs" -> PulumiBackendGcs
  _ -> PulumiBackendLocal

-- | The @NAGARE_PULUMI_BACKEND@ token for a backend kind (the inverse of
-- 'parsePulumiBackendKind'), used by the context-file renderer.
pulumiBackendToken :: PulumiBackendKind -> Text
pulumiBackendToken PulumiBackendLocal = "local"
pulumiBackendToken PulumiBackendGcs = "gcs"

-- | The name of a stored context. It is used verbatim as a filename
-- (@<name>.env@) and as the value of the @current-context@ pointer, so it is
-- restricted to a single safe path segment: non-empty, and composed only of
-- ASCII letters, digits, '-', '_', and '.', with no '/', no leading '.', and
-- not "." or "..". 'mkContextName' is the only way to build one.
newtype ContextName = ContextName Text
  deriving stock (Eq, Ord, Show)

contextNameText :: ContextName -> Text
contextNameText (ContextName t) = t

defaultContextName :: ContextName
defaultContextName = ContextName "default"

mkContextName :: Text -> Either Text ContextName
mkContextName raw
  | T.null raw = Left "context name must not be empty"
  | T.any (== '/') raw = Left "context name must not contain '/'"
  | raw == "." || raw == ".." = Left "context name must not be '.' or '..'"
  | T.isPrefixOf "." raw = Left "context name must not start with '.'"
  | T.all isSafe raw = Right (ContextName raw)
  | otherwise = Left "context name may use only letters, digits, '-', '_', '.'"
  where
    isSafe c = isAsciiLower c || isAsciiUpper c || isDigit c || c `elem` ['-', '_', '.']

-- | The nagare user-level config root: @${XDG_CONFIG_HOME:-$HOME/.config}/nagare@.
-- An unset OR empty XDG_CONFIG_HOME falls back to @$HOME/.config@, matching shell
-- @${VAR:-default}@. With HOME also unset, the root is relative @.config/nagare@;
-- callers that touch the store should set HOME or XDG_CONFIG_HOME.
nagareConfigDir :: IO FilePath
nagareConfigDir = do
  xdg <- lookupEnv "XDG_CONFIG_HOME"
  home <- lookupEnv "HOME"
  let base = case xdg of
        Just p | not (null p) -> p
        _ -> maybe ".config" (</> ".config") home
  pure (base </> "nagare")

-- | The nagare user-level state root: @${XDG_STATE_HOME:-$HOME/.local/state}/nagare@.
-- EP-90 uses this for per-context Pulumi backend and home directories.
nagareStateDir :: IO FilePath
nagareStateDir = do
  xdg <- lookupEnv "XDG_STATE_HOME"
  home <- lookupEnv "HOME"
  let base = case xdg of
        Just p | not (null p) -> p
        _ -> maybe ".local/state" (</> ".local" </> "state") home
  pure (base </> "nagare")

contextsDir :: IO FilePath
contextsDir = (</> "contexts") <$> nagareConfigDir

contextFilePath :: ContextName -> IO FilePath
contextFilePath name = do
  dir <- contextsDir
  pure (dir </> T.unpack (contextNameText name) <.> "env")

currentContextPath :: IO FilePath
currentContextPath = (</> "current-context") <$> nagareConfigDir

-- | The per-context Pulumi-state directory name. EP-87 reserves this hook; EP-90
-- owns the absolute backend path, stack naming, and config projection.
contextStateDirName :: ContextName -> Text
contextStateDirName = contextNameText

-- | List stored contexts by filename, sorted for stable CLI output. Invalid
-- filenames are ignored so a stray file in the config directory cannot crash
-- @nagarectl context list@.
listContexts :: IO [ContextName]
listContexts = do
  dir <- contextsDir
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else do
      entries <- listDirectory dir
      pure $
        sort
          [ name
          | entry <- entries
          , takeExtension entry == ".env"
          , Right name <- [mkContextName (T.pack (dropExtension entry))]
          ]

contextExists :: ContextName -> IO Bool
contextExists name = contextFilePath name >>= doesFileExist

readContextProfile :: ContextName -> IO (Either Text TargetProfile)
readContextProfile name = do
  path <- contextFilePath name
  m <- readContextMap path
  pure $ case m of
    Just ctx -> Right (profileFromContextMap ctx)
    Nothing -> Left ("context \"" <> contextNameText name <> "\" not found (expected " <> T.pack path <> ")")

setCurrentContext :: ContextName -> IO ()
setCurrentContext name = do
  dir <- nagareConfigDir
  createDirectoryIfMissing True dir
  path <- currentContextPath
  TIO.writeFile path (contextNameText name <> "\n")

clearCurrentContext :: IO ()
clearCurrentContext = do
  path <- currentContextPath
  exists <- doesFileExist path
  if exists then removeFile path else pure ()

deleteContext :: ContextName -> IO ()
deleteContext name = do
  path <- contextFilePath name
  exists <- doesFileExist path
  if exists then removeFile path else pure ()

-- | Atomically set the context's release intent while preserving every other
-- line in the flat environment file. This is the final commit point of an
-- upgrade transaction and is also reused by explicit legacy adoption.
writeContextPlatformVersion :: ContextName -> Text -> IO (Either Text ())
writeContextPlatformVersion name version = do
  path <- contextFilePath name
  exists <- doesFileExist path
  if not exists
    then pure (Left ("context '" <> contextNameText name <> "' does not exist"))
    else do
      result <- try $ do
        contents <- TIO.readFile path
        let retained = filter (not . isVersionLine) (T.lines contents)
            rendered = T.unlines (retained <> ["export NAGARE_PLATFORM_VERSION=" <> version])
            temporary = path <> ".upgrade"
        TIO.writeFile temporary rendered
        renameFile temporary path
      pure $ case result of
        Left (err :: IOException) -> Left ("could not update platform version in " <> T.pack path <> ": " <> T.pack (show err))
        Right () -> Right ()
  where
    isVersionLine line =
      let stripped = T.stripStart line
       in "export NAGARE_PLATFORM_VERSION=" `T.isPrefixOf` stripped
            || "NAGARE_PLATFORM_VERSION=" `T.isPrefixOf` stripped

-- | The fully-resolved GCP target. Every field is the final value a consumer
-- should use; no further env lookups or literal fallbacks happen downstream.
data TargetProfile = TargetProfile
  { tpProject :: !Text
  -- ^ CLOUDSDK_CORE_PROJECT, e.g. @"tan-nb-exp"@
  , tpRegion :: !Text
  -- ^ CLOUDSDK_COMPUTE_REGION, e.g. @"us-west1"@
  , tpZone :: !Text
  -- ^ CLOUDSDK_COMPUTE_ZONE, e.g. @"us-west1-a"@
  , tpRegistryHost :: !Text
  -- ^ NAGARE_REGISTRY_HOST, default @"\<region>-docker.pkg.dev"@
  , tpArtifactRegistryId :: !Text
  -- ^ NAGARE_ARTIFACT_REGISTRY_ID, default @"nagare"@
  , tpImageBucket :: !Text
  -- ^ NAGARE_IMAGE_BUCKET, default @"\<project>-nagare-images"@
  , tpBackupBucket :: !Text
  -- ^ NAGARE_BACKUP_BUCKET, default @"\<project>-nagare-backups"@
  , tpBaseDomain :: !Text
  -- ^ NAGARE_BASE_DOMAIN, default @"apps.example.com"@
  , tpInstanceName :: !Text
  -- ^ NAGARE_INSTANCE_NAME, default @"nagare-01"@
  , tpTargetPlatform :: !Text
  -- ^ NAGARE_TARGET_PLATFORM, the Docker platform string the cluster node runs,
  -- default @"linux/amd64"@. Passed verbatim to @docker build --platform@ and
  -- @nixpacks build --platform@ (EP-3). The node is amd64; an operator whose
  -- node differs overrides this in @nagare.target.env@.
  , tpMode :: !Mode
  -- ^ NAGARE_MODE; 'Local' selects the EP-82 local cluster, default 'Cloud'
  -- (unset or any non-@local@ value). Drives conditional Docker auth in
  -- 'Nagare.Image.configureDockerAuth' (EP-83).
  , tpLocalObjectStore :: !Text
  -- ^ NAGARE_LOCAL_OBJECT_STORE, the in-cluster S3 endpoint + bucket used for
  -- backups/snapshots in local mode (form @"\<endpoint-url>/\<bucket>"@, e.g.
  -- @"http://minio.nagare-system.svc.cluster.local:9000/nagare-backups"@).
  -- Default @""@ (unset); only read in local mode, where EP-82's profile sets
  -- it. Consumed by EP-84's @StoreBackend@ in 'Nagare.Cluster.GcsJob'.
  , tpPulumiBackend :: !PulumiBackendKind
  -- ^ NAGARE_PULUMI_BACKEND (EP-93); 'PulumiBackendGcs' opts a cloud context into
  -- remote GCS Pulumi state, default 'PulumiBackendLocal' (EP-90's per-context
  -- @file://@ backend). Downgraded to local in local mode by 'effectivePulumiBackend'.
  , tpPulumiBackendUrl :: !Text
  -- ^ NAGARE_PULUMI_BACKEND_URL (EP-93), an explicit @gs://\<bucket>/\<path>@ backend
  -- URL. Default @""@; when empty and the backend is GCS, the URL is derived by
  -- 'defaultGcsPulumiBackendUrl'.
  , tpPlatformVersion :: !(Maybe Text)
  -- ^ Optional NAGARE_PLATFORM_VERSION. 'Nothing' identifies a legacy
  -- source-managed context whose release has not been explicitly adopted.
  }
  deriving stock (Eq, Show)

-- | The active context identity plus its resolved target bundle. The synthetic
-- context name @"default"@ represents the legacy in-repo/default profile path.
data ActiveTarget = ActiveTarget
  { atContextName :: !ContextName
  , atProfile :: !TargetProfile
  }
  deriving stock (Eq, Show)

-- | The Pulumi process environment derived for a context (EP-90, extended by
-- EP-93). The stack name is the context name. 'peHome' is always the per-context
-- __local__ Pulumi home (Pulumi keeps its workspace and credentials cache there even
-- for a remote backend); only 'peBackendUrl' changes between backends.
data PulumiEnv = PulumiEnv
  { peHome :: !FilePath
  , peBackendUrl :: !Text
  , peStack :: !Text
  , peKind :: !PulumiBackendKind
  }
  deriving stock (Eq, Show)

-- | The backend a context actually uses. A @mode=local@ context can never use GCS:
-- local mode points every primitive at loopback substitutes and the GCP guardrail
-- steps aside, so there is no project to protect and no credentials to assume. A
-- @gcs@ setting on a local context is therefore downgraded to 'PulumiBackendLocal'
-- (the shell resolver and 'Nagare.Init' surface a warning when this happens).
effectivePulumiBackend :: TargetProfile -> PulumiBackendKind
effectivePulumiBackend tp = case tpMode tp of
  Local -> PulumiBackendLocal
  Cloud -> tpPulumiBackend tp

-- | The default GCS Pulumi backend URL for a context when @NAGARE_PULUMI_BACKEND=gcs@
-- is set without an explicit URL: @gs://\<project>-nagare-pulumi-state/nagare/\<context>@.
-- The state bucket is kept distinct from the application backup bucket so IAM,
-- lifecycle, and deletion boundaries stay clear (EP-93 Decision Log).
defaultGcsPulumiBackendUrl :: Text -> TargetProfile -> Text
defaultGcsPulumiBackendUrl ctx tp =
  "gs://" <> tpProject tp <> "-nagare-pulumi-state/nagare/" <> ctx

-- | Derive the Pulumi environment for a context from the nagare state root, the
-- context name, and its profile. Local backends get EP-90's @file://\<root>/state@
-- URL; GCS backends get the explicit 'tpPulumiBackendUrl' or, when empty, the
-- 'defaultGcsPulumiBackendUrl'. 'peHome' is the local @\<root>/home@ in both cases.
pulumiEnvFor :: FilePath -> Text -> TargetProfile -> PulumiEnv
pulumiEnvFor stateRoot ctx tp =
  let root = stateRoot </> T.unpack ctx
      kind = effectivePulumiBackend tp
      url = case kind of
        PulumiBackendLocal -> "file://" <> T.pack (root </> "state")
        PulumiBackendGcs
          | T.null (tpPulumiBackendUrl tp) -> defaultGcsPulumiBackendUrl ctx tp
          | otherwise -> tpPulumiBackendUrl tp
   in PulumiEnv
        { peHome = root </> "home"
        , peBackendUrl = url
        , peStack = ctx
        , peKind = kind
        }

-- | The Artifact Registry image-name prefix: @"\<host>/\<project>/\<repo-id>"@. An
-- app's short image name is appended to this to form a full image ref (EP-62 M3,
-- MasterPlan 12 Integration Point 4).
registryPrefix :: TargetProfile -> Text
registryPrefix tp =
  tpRegistryHost tp <> "/" <> tpProject tp <> "/" <> tpArtifactRegistryId tp

-- | Parse a flat @export VAR=value@ context file into a variable map. Blank
-- lines and lines whose first non-space character is '#' are ignored. A leading
-- @export @ is stripped; this is a pragmatic reader for machine-generated or
-- example-derived files, not a complete shell parser.
parseContextEnv :: Text -> Map String Text
parseContextEnv = Map.fromList . concatMap lineKV . T.lines
  where
    lineKV raw =
      let s = T.stripStart raw
       in if T.null s || "#" `T.isPrefixOf` s
            then []
            else
              let s' = fromMaybe s (T.stripPrefix "export " s)
               in case T.breakOn "=" s' of
                    (k, v)
                      | T.null v -> []
                      | otherwise -> [(T.unpack (T.strip k), unquote (T.drop 1 v))]
    unquote v =
      let t = T.strip v
       in if T.length t >= 2 && (T.head t == '"' || T.head t == '\'') && T.last t == T.head t
            then T.drop 1 (T.dropEnd 1 t)
            else t

-- | Read a context file into a variable map, or 'Nothing' if the path is absent.
readContextMap :: FilePath -> IO (Maybe (Map String Text))
readContextMap path = do
  exists <- doesFileExist path
  if exists
    then Just . parseContextEnv <$> TIO.readFile path
    else pure Nothing

-- | Read the current-context pointer, validated through 'mkContextName'. A
-- missing file, an empty file, or an invalid name means no default context.
readCurrentContext :: IO (Maybe ContextName)
readCurrentContext = do
  path <- currentContextPath
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      t <- T.strip <$> TIO.readFile path
      pure (either (const Nothing) Just (mkContextName t))

data ContextSelection
  = NoContextSelection
  | NamedContext ContextName
  | SyntheticDefaultContext

-- | Resolve the explicitly-selected context name, if any. The caller's argument
-- wins over NAGARE_CONTEXT. The literal @"default"@ means the synthetic
-- back-compat context, matching scripts/lib/target.sh.
selectContextSelection :: Maybe Text -> IO (Either Text ContextSelection)
selectContextSelection arg = do
  envName <- lookupEnv "NAGARE_CONTEXT"
  let raw = case arg of
        Just a | not (T.null a) -> Just a
        _ -> case envName of
          Just e | not (null e) -> Just (T.pack e)
          _ -> Nothing
  pure $ case raw of
    Nothing -> Right NoContextSelection
    Just "default" -> Right SyntheticDefaultContext
    Just r -> NamedContext <$> mkContextName r

-- | The active context's name and variable map. Precedence:
-- explicit/NAGARE_CONTEXT named context > current-context pointer > in-repo
-- profile > empty map. A named context whose file is missing is an error.
loadActiveContextMap :: Maybe Text -> IO (Either Text (ContextName, Map String Text))
loadActiveContextMap arg = do
  sel <- selectContextSelection arg
  case sel of
    Left err -> pure (Left ("invalid context name: " <> err))
    Right (NamedContext name) -> requireNamed name
    Right SyntheticDefaultContext -> Right . (\ctx -> (defaultContextName, ctx)) <$> inRepoMap
    Right NoContextSelection -> do
      ptr <- readCurrentContext
      case ptr of
        Just name -> requireNamed name
        Nothing -> Right . (\ctx -> (defaultContextName, ctx)) <$> inRepoMap
  where
    requireNamed name = do
      path <- contextFilePath name
      m <- readContextMap path
      pure $ case m of
        Just kv -> Right (name, kv)
        Nothing ->
          Left ("context \"" <> contextNameText name <> "\" not found (expected " <> T.pack path <> ")")

-- | The in-repo profile as a context map for MasterPlan 12/16 back-compat. Reads
-- ./nagare.target.env, then overlays ./nagare.local.env when local mode applies.
inRepoMap :: IO (Map String Text)
inRepoMap = do
  base <- fromMaybe Map.empty <$> readContextMap "nagare.target.env"
  local <- readContextMap "nagare.local.env"
  envMode <- lookupEnv "NAGARE_MODE"
  let localIsActive = case local of
        Nothing -> False
        Just kv ->
          (fmap (map toLower) envMode == Just "local")
            || (fmap T.toLower (Map.lookup "NAGARE_MODE" kv) == Just "local")
  pure $ case (localIsActive, local) of
    (True, Just kv) -> Map.union kv base
    _ -> base

-- | Resolve one field with precedence: process env > context map > default. An
-- env var or context value set to empty is treated as unset.
ctxOr :: Map String Text -> String -> Text -> IO Text
ctxOr ctx name def = do
  m <- lookupEnv name
  pure $ case m of
    Just v | not (null v) -> T.pack v
    _ -> case Map.lookup name ctx of
      Just v | not (T.null v) -> v
      _ -> def

-- | Raw field lookup with env > context precedence for parsers like 'parseMode'.
ctxRaw :: Map String Text -> String -> IO (Maybe String)
ctxRaw ctx name = do
  m <- lookupEnv name
  pure $ case m of
    Just v | not (null v) -> Just v
    _ -> case Map.lookup name ctx of
      Just v | not (T.null v) -> Just (T.unpack v)
      _ -> Nothing

mapOr :: Map String Text -> String -> Text -> Text
mapOr ctx name def = case Map.lookup name ctx of
  Just v | not (T.null v) -> v
  _ -> def

mapRaw :: Map String Text -> String -> Maybe String
mapRaw ctx name = case Map.lookup name ctx of
  Just v | not (T.null v) -> Just (T.unpack v)
  _ -> Nothing

-- | Build a fully-derived profile from a context file or @context create@ field
-- map alone. Unlike 'resolveProfileFrom', this does not inspect process
-- environment, so creating/showing a stored context is not polluted by ambient
-- @CLOUDSDK_*@ or @NAGARE_*@ variables.
profileFromContextMap :: Map String Text -> TargetProfile
profileFromContextMap ctx =
  let project = mapOr ctx "CLOUDSDK_CORE_PROJECT" "tan-nb-exp"
      region = mapOr ctx "CLOUDSDK_COMPUTE_REGION" "us-west1"
      zone = mapOr ctx "CLOUDSDK_COMPUTE_ZONE" "us-west1-a"
      registryHost = mapOr ctx "NAGARE_REGISTRY_HOST" (region <> "-docker.pkg.dev")
      registryId = mapOr ctx "NAGARE_ARTIFACT_REGISTRY_ID" "nagare"
      imageBucket = mapOr ctx "NAGARE_IMAGE_BUCKET" (project <> "-nagare-images")
      backupBucket = mapOr ctx "NAGARE_BACKUP_BUCKET" (project <> "-nagare-backups")
      baseDomain = mapOr ctx "NAGARE_BASE_DOMAIN" "apps.example.com"
      instanceName = mapOr ctx "NAGARE_INSTANCE_NAME" "nagare-01"
      targetPlatform = mapOr ctx "NAGARE_TARGET_PLATFORM" "linux/amd64"
      mode = parseMode (mapRaw ctx "NAGARE_MODE")
      localObjectStore = mapOr ctx "NAGARE_LOCAL_OBJECT_STORE" ""
      pulumiBackend = parsePulumiBackendKind (mapRaw ctx "NAGARE_PULUMI_BACKEND")
      pulumiBackendUrl = mapOr ctx "NAGARE_PULUMI_BACKEND_URL" ""
      platformVersion = T.pack <$> mapRaw ctx "NAGARE_PLATFORM_VERSION"
   in TargetProfile
        { tpProject = project
        , tpRegion = region
        , tpZone = zone
        , tpRegistryHost = registryHost
        , tpArtifactRegistryId = registryId
        , tpImageBucket = imageBucket
        , tpBackupBucket = backupBucket
        , tpBaseDomain = baseDomain
        , tpInstanceName = instanceName
        , tpTargetPlatform = targetPlatform
        , tpMode = mode
        , tpLocalObjectStore = localObjectStore
        , tpPulumiBackend = pulumiBackend
        , tpPulumiBackendUrl = pulumiBackendUrl
        , tpPlatformVersion = platformVersion
        }

resolveProfileFrom :: Map String Text -> IO TargetProfile
resolveProfileFrom ctx = do
  project <- ctxOr ctx "CLOUDSDK_CORE_PROJECT" "tan-nb-exp"
  region <- ctxOr ctx "CLOUDSDK_COMPUTE_REGION" "us-west1"
  zone <- ctxOr ctx "CLOUDSDK_COMPUTE_ZONE" "us-west1-a"
  registryHost <- ctxOr ctx "NAGARE_REGISTRY_HOST" (region <> "-docker.pkg.dev")
  registryId <- ctxOr ctx "NAGARE_ARTIFACT_REGISTRY_ID" "nagare"
  imageBucket <- ctxOr ctx "NAGARE_IMAGE_BUCKET" (project <> "-nagare-images")
  backupBucket <- ctxOr ctx "NAGARE_BACKUP_BUCKET" (project <> "-nagare-backups")
  baseDomain <- ctxOr ctx "NAGARE_BASE_DOMAIN" "apps.example.com"
  instanceName <- ctxOr ctx "NAGARE_INSTANCE_NAME" "nagare-01"
  targetPlatform <- ctxOr ctx "NAGARE_TARGET_PLATFORM" "linux/amd64"
  mode <- parseMode <$> ctxRaw ctx "NAGARE_MODE"
  localObjectStore <- ctxOr ctx "NAGARE_LOCAL_OBJECT_STORE" ""
  pulumiBackend <- parsePulumiBackendKind <$> ctxRaw ctx "NAGARE_PULUMI_BACKEND"
  pulumiBackendUrl <- ctxOr ctx "NAGARE_PULUMI_BACKEND_URL" ""
  platformVersion <- fmap T.pack <$> ctxRaw ctx "NAGARE_PLATFORM_VERSION"
  pure
    TargetProfile
      { tpProject = project
      , tpRegion = region
      , tpZone = zone
      , tpRegistryHost = registryHost
      , tpArtifactRegistryId = registryId
      , tpImageBucket = imageBucket
      , tpBackupBucket = backupBucket
      , tpBaseDomain = baseDomain
      , tpInstanceName = instanceName
      , tpTargetPlatform = targetPlatform
      , tpMode = mode
      , tpLocalObjectStore = localObjectStore
      , tpPulumiBackend = pulumiBackend
      , tpPulumiBackendUrl = pulumiBackendUrl
      , tpPlatformVersion = platformVersion
      }

-- | Resolve the active context into a context name plus fully-derived
-- 'TargetProfile'. The argument is an explicit context name (fed by the
-- --context flag); 'Nothing' means NAGARE_CONTEXT, then current-context, then
-- in-repo profile, then defaults. Named-but-missing contexts throw to fail
-- closed.
resolveActiveTarget :: Maybe Text -> IO ActiveTarget
resolveActiveTarget arg = do
  e <- loadActiveContextMap arg
  case e of
    Left err -> ioError (userError (T.unpack err))
    Right (name, ctx) -> ActiveTarget name <$> resolveProfileFrom ctx

-- | Back-compat entry point for consumers that only need the target bundle.
resolveActiveContext :: Maybe Text -> IO TargetProfile
resolveActiveContext arg = atProfile <$> resolveActiveTarget arg

-- | Back-compat entry point: resolve with no explicit context selection.
resolveTargetProfile :: IO TargetProfile
resolveTargetProfile = resolveActiveContext Nothing

-- | The Kubernetes Secret (in the data-movement Job's namespace) holding the
-- local MinIO credentials (@AWS_ACCESS_KEY_ID@ / @AWS_SECRET_ACCESS_KEY@). EP-84
-- creates it in @cluster/local/minio/minio.yaml@; the @secretKeyRef@ env in the
-- MinIO data-movement Jobs references it by this name.
minioCredentialsSecret :: Text
minioCredentialsSecret = "nagare-minio-credentials"

-- | The object-store backend for a profile and a resolved backup bucket (EP-84,
-- MasterPlan 16 Integration Point 3). This is the __one place__ the cloud-vs-local
-- backend is chosen, from 'tpMode': 'Cloud' yields a 'GcsBackend' (the cloud path
-- is byte-for-byte unchanged); 'Local' parses 'tpLocalObjectStore' into a MinIO
-- endpoint+bucket and yields a 'MinioBackend'. A 'Local' profile whose
-- @NAGARE_LOCAL_OBJECT_STORE@ is unset/malformed is a 'Left' so the caller can
-- fail loudly rather than silently target GCS from a laptop.
storeBackendFor :: TargetProfile -> Text -> Either Text StoreBackend
storeBackendFor tp bucket = case tpMode tp of
  Cloud -> Right (GcsBackend (tpProject tp) bucket)
  Local -> case parseLocalObjectStore (tpLocalObjectStore tp) of
    Just (endpoint, b) -> Right (MinioBackend (MinioRef endpoint b minioCredentialsSecret))
    Nothing ->
      Left
        ( "local mode (NAGARE_MODE=local) requires NAGARE_LOCAL_OBJECT_STORE to be set to "
            <> "\"<endpoint-url>/<bucket>\" (e.g. "
            <> "http://minio.nagare-system.svc.cluster.local:9000/nagare-backups); "
            <> "it is currently "
            <> (if T.null (tpLocalObjectStore tp) then "unset" else "malformed: " <> tpLocalObjectStore tp)
        )
