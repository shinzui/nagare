-- | Runtime / Context. Executable-private CLI boundary.
module Nagare.Cli.Runtime.Context
  ( contextEnvPairs
  , exportProfileEnv
  , formatContextList
  , guardExistingContextMutation
  , parseContextNameOrDie
  , resolveField
  , writeContextProfile
  , writeNamedContext
  )
where

import Data.Generics.Labels ()
import Data.Maybe (catMaybes)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Options (ContextCreateOpts (..))
import Nagare.Cli.Runtime.ContextReview (guardRemovedContext)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Guards (guardLegacyMutationInventory)
import Nagare.Dsl.Prelude
import Nagare.Init (renderTargetEnv)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Target
  ( ActiveTarget (ActiveTarget)
  , ContextName
  , Mode (Cloud, Local)
  , TargetProfile
  , contextExists
  , contextFilePath
  , contextNameText
  , contextsDir
  , effectiveInventoryStore
  , effectivePulumiBackend
  , inventoryStoreToken
  , mkContextName
  , pulumiBackendToken
  , readContextProfile
  , registryPrefix
  )
import System.Directory (createDirectoryIfMissing)
import System.Environment (setEnv, unsetEnv)
import System.IO (hFlush, hIsTerminalDevice, stdin, stdout)

-- | Export the named profile for child scripts. Empty values are removed so a
-- stale ambient value cannot outrank the new context. Pulumi's own variables are
-- still installed by 'ensurePulumiInWorkspace'.
exportProfileEnv :: ContextName -> TargetProfile -> IO ()
exportProfileEnv name tp = mapM_ (uncurry setOrUnset) fields
  where
    context = contextNameText name
    fields =
      [ ("NAGARE_CONTEXT", context)
      , ("CLOUDSDK_CORE_PROJECT", tp ^. #project)
      , ("CLOUDSDK_COMPUTE_REGION", tp ^. #region)
      , ("CLOUDSDK_COMPUTE_ZONE", tp ^. #zone)
      , ("NAGARE_REGISTRY_HOST", tp ^. #registryHost)
      , ("NAGARE_ARTIFACT_REGISTRY_ID", tp ^. #artifactRegistryId)
      , ("NAGARE_IMAGE_BUCKET", tp ^. #imageBucket)
      , ("NAGARE_BACKUP_BUCKET", tp ^. #backupBucket)
      , ("NAGARE_BASE_DOMAIN", tp ^. #baseDomain)
      , ("NAGARE_ACME_EMAIL", tp ^. #acmeEmail)
      , ("NAGARE_ACME_DIRECTORY", tp ^. #acmeDirectory)
      , ("NAGARE_INSTANCE_NAME", tp ^. #instanceName)
      , ("NAGARE_SERVICE_ACCOUNT_ID", tp ^. #serviceAccountId)
      , ("NAGARE_MACHINE_TYPE", tp ^. #machineType)
      , ("NAGARE_BOOT_DISK_TYPE", tp ^. #bootDiskType)
      , ("NAGARE_BOOT_DISK_SIZE_GB", tp ^. #bootDiskSizeGb)
      , ("NAGARE_DATA_DISK_SIZE_GB", tp ^. #dataDiskSizeGb)
      , ("NAGARE_TARGET_PLATFORM", tp ^. #targetPlatform)
      , ("NAGARE_MODE", modeToken (tp ^. #mode))
      , ("NAGARE_LOCAL_OBJECT_STORE", tp ^. #localObjectStore)
      , ("NAGARE_PULUMI_BACKEND", pulumiBackendToken (effectivePulumiBackend tp))
      , ("NAGARE_PULUMI_BACKEND_URL", tp ^. #pulumiBackendUrl)
      , ("NAGARE_INVENTORY_STORE", inventoryStoreToken (effectiveInventoryStore tp))
      , ("NAGARE_INVENTORY_STORE_URL", tp ^. #inventoryStoreUrl)
      , ("NAGARE_REGISTRY_PREFIX", registryPrefix tp)
      , ("NAGARE_PULUMI_STACK", context)
      ]
        <> maybe [] (\version -> [("NAGARE_PLATFORM_VERSION", version)]) (tp ^. #platformVersion)
    setOrUnset key fieldValue
      | T.null fieldValue = unsetEnv key
      | otherwise = setEnv key (T.unpack fieldValue)
    modeToken Cloud = "cloud"
    modeToken Local = "local"

-- | Resolve one @init@ target field: a flag value wins; otherwise prompt on a TTY
-- with the default; otherwise (non-TTY, no flag) use the default unless the field
-- is @required@ (only the project), in which case error clearly naming the flag.
resolveField :: Bool -> String -> String -> Maybe String -> Text -> IO Text
resolveField _ _ _ (Just v) _ = pure (T.pack v)
resolveField required label flag Nothing def = do
  tty <- hIsTerminalDevice stdin
  if tty
    then do
      putStr (label <> " [" <> T.unpack def <> "]: ")
      hFlush stdout
      line <- getLine
      pure (if null line then def else T.pack line)
    else
      if required
        then dieT (T.pack ("nagarectl init: --" <> flag <> " is required in non-interactive mode"))
        else pure def

-- Existing context profiles select the inventory store and bind its project.
-- Replacing or deleting one outside a reviewed store migration can strand the
-- accepted history or point subsequent provider work at the wrong project.
guardExistingContextMutation :: Text -> ContextName -> IO ()
guardExistingContextMutation operation name = do
  guardRemovedContext name
  exists <- contextExists name
  when exists $ do
    profile <- readContextProfile name >>= either dieT pure
    selected <- Inventory.selectFoundationStore (ActiveTarget name profile) >>= either (dieT . T.pack . show) pure
    guardLegacyMutationInventory operation selected

parseContextNameOrDie :: String -> IO ContextName
parseContextNameOrDie raw =
  either (dieT . ("invalid context name: " <>)) pure (mkContextName (T.pack raw))

writeContextProfile :: ContextName -> TargetProfile -> IO ()
writeContextProfile name tp = do
  guardRemovedContext name
  dir <- contextsDir
  createDirectoryIfMissing True dir
  path <- contextFilePath name
  TIO.writeFile path (renderTargetEnv tp)

writeNamedContext :: Bool -> Bool -> ContextName -> TargetProfile -> IO ()
writeNamedContext force dryRun name tp = do
  exists <- contextExists name
  when (exists && not force) $
    dieT ("context '" <> contextNameText name <> "' already exists; pass --force to overwrite it.")
  if dryRun
    then TIO.putStr (renderTargetEnv tp)
    else writeContextProfile name tp

contextEnvPairs :: ContextCreateOpts -> [(String, Text)]
contextEnvPairs o =
  catMaybes
    [ pair "CLOUDSDK_CORE_PROJECT" (o ^. #project)
    , pair "CLOUDSDK_COMPUTE_REGION" (o ^. #region)
    , pair "CLOUDSDK_COMPUTE_ZONE" (o ^. #zone)
    , pair "NAGARE_BASE_DOMAIN" (o ^. #baseDomain)
    , pair "NAGARE_EXTERNAL_DOMAIN_TLS_ENABLED" (o ^. #externalDomainTlsEnabled)
    , pair "NAGARE_MACHINE_TYPE" (o ^. #machineType)
    , pair "NAGARE_BOOT_DISK_TYPE" (o ^. #bootDiskType)
    , pair "NAGARE_BOOT_DISK_SIZE_GB" (o ^. #bootDiskSizeGb)
    , pair "NAGARE_DATA_DISK_SIZE_GB" (o ^. #dataDiskSizeGb)
    , pair "NAGARE_REGISTRY_HOST" (o ^. #registryHost)
    , pair "NAGARE_ARTIFACT_REGISTRY_ID" (o ^. #artifactRegistryId)
    , pair "NAGARE_IMAGE_BUCKET" (o ^. #imageBucket)
    , pair "NAGARE_BACKUP_BUCKET" (o ^. #backupBucket)
    , pair "NAGARE_NIX_CACHE_ENABLED" (o ^. #nixCacheEnabled)
    , pair "NAGARE_NIX_CACHE_BUCKET" (o ^. #nixCacheBucket)
    , pair "NAGARE_INSTANCE_NAME" (o ^. #instanceName)
    , pair "NAGARE_SERVICE_ACCOUNT_ID" (o ^. #serviceAccountId)
    , pair "NAGARE_TARGET_PLATFORM" (o ^. #targetPlatform)
    , pair "NAGARE_MODE" (o ^. #mode)
    , pair "NAGARE_LOCAL_OBJECT_STORE" (o ^. #localObjectStore)
    , pair "NAGARE_PULUMI_BACKEND" (o ^. #pulumiBackend)
    , pair "NAGARE_PULUMI_BACKEND_URL" (o ^. #pulumiBackendUrl)
    , pair "NAGARE_PULUMI_BACKEND_MEMBER" (o ^. #pulumiBackendMember)
    , pair "NAGARE_INVENTORY_STORE" (o ^. #inventoryStore)
    , pair "NAGARE_INVENTORY_STORE_URL" (o ^. #inventoryStoreUrl)
    , pair "NAGARE_ACME_EMAIL" (o ^. #acmeEmail)
    , pair "NAGARE_ACME_DIRECTORY" (o ^. #acmeDirectory)
    ]
  where
    pair k mv = fmap (\v -> (k, T.pack v)) mv

formatContextList :: Maybe ContextName -> [(ContextName, Text, Text)] -> Text
formatContextList cur rows =
  T.unlines (hdr : map row rows)
  where
    hdr = T.concat [pad 9 "CURRENT", pad 18 "NAME", pad 24 "PROJECT", "BASE DOMAIN"]
    row (name, project, baseDomain) =
      T.concat
        [ pad 9 (if cur == Just name then "*" else "")
        , pad 18 (contextNameText name)
        , pad 24 project
        , baseDomain
        ]
    pad n t =
      let t' = T.take n t
       in t' <> T.replicate (max 1 (n - T.length t')) " "
