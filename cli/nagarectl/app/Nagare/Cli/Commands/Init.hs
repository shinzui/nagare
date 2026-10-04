-- | Commands / Init. Executable-private CLI boundary.
module Nagare.Cli.Commands.Init
  ( runInit
  )
where

import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Runtime.Context
  ( exportProfileEnv
  , guardExistingContextMutation
  , parseContextNameOrDie
  , resolveField
  , writeNamedContext
  )
import Nagare.Cli.Runtime.Error (dieT, printPreflightWarnings)
import Nagare.Cli.Runtime.Guards (guardLegacyMutationInventory)
import Nagare.Cli.Runtime.Pulumi
  ( bootstrapGcsIfNeeded
  , ensurePulumiInWorkspace
  )
import Nagare.Cli.Runtime.Target
  ( activeProfile
  , activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Dsl.Prelude
import Nagare.Init
  ( InitOpts
  , WriteResult (DryRunWouldWrite, RefusedExists, Wrote)
  , checkInitOwnership
  , enableApis
  , findMissingTools
  , initContextMap
  , initFlagPairs
  , nextStepsText
  , profileFromOpts
  , renderInitSummary
  , renderTargetEnv
  , requiredApis
  , requiredInitTools
  , resolveInitBase
  , runPreflight
  , seedPulumiConfig
  , writeTargetEnv
  )
import Nagare.Ops.PulumiBackend (bootstrapPulumiStateBucket)
import Nagare.Platform.Paths
  ( renderPlatformPathError
  , resolvePlatformPaths
  )
import Nagare.Platform.Workspace
  ( readPayloadManifest
  , renderWorkspaceError
  )
import Nagare.Target
  ( ContextName
  , Mode (Cloud)
  , PulumiBackendKind
  , VmShape
    ( VmShape
    , bootDiskSizeGb
    , bootDiskType
    , dataDiskSizeGb
    , machineType
    )
  , acmeDirectoryToken
  , contextNameText
  , effectivePulumiBackend
  , parseAcmeDirectory
  , parseInventoryStoreKind
  , parsePulumiBackendKind
  , profileFromContextMap
  , setCurrentContext
  , validateAcmeEmail
  , validateNixCacheMode
  , validateVmShape
  , vmShapeOf
  )
import Nagare.Version (currentBuildVersion)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath ((</>))
import System.IO (stderr)

-- | @nagarectl init@: the guided onboarding flow (EP-63). Order: resolve target
-- (flags or prompts) -> preflight (gcloud auth + operator IAM) -> write the profile
-- -> enable APIs -> seed Pulumi config -> print next steps. Each side-effecting
-- stage is skippable. The ONLY command that drives Pulumi/gcloud (MasterPlan 12
-- Decision Log).
runInit :: Maybe String -> InitOpts -> IO ()
runInit mctx o = case o ^. #contextName of
  Just rawName -> parseContextNameOrDie rawName >>= runNamedInit o
  Nothing -> runLegacyInit mctx o

-- | Initialize a named context from flags, built-in defaults, and only that
-- context's stored values under @--force@. No active-context resolver appears in
-- this path, which prevents ambient or foreign context values from becoming part
-- of a newly created context.
runNamedInit :: InitOpts -> ContextName -> IO ()
runNamedInit o contextName = do
  guardExistingContextMutation "init NAME" contextName
  base <- either dieT pure =<< resolveInitBase contextName (o ^. #force)
  let preliminaryProfile = profileFromContextMap (initContextMap base (initFlagPairs o) "")
  preflightInitTools o (effectivePulumiBackend preliminaryProfile)
  pathsResult <- resolvePlatformPaths Nothing
  payloadPaths <- either (dieT . renderPlatformPathError) pure pathsResult
  manifest <- either (dieT . renderWorkspaceError) pure =<< readPayloadManifest payloadPaths
  let storedDefaults = profileFromContextMap (initContextMap base [] (manifest ^. #platformVersion))
      projectDefault = fromMaybe "" (base >>= Map.lookup "CLOUDSDK_CORE_PROJECT")
      acmeEmailDefault = fromMaybe "" (base >>= Map.lookup "NAGARE_ACME_EMAIL")

  project <- resolveField (T.null projectDefault) "GCP project id" "project" (o ^. #project) projectDefault
  region <- resolveField False "Compute region" "region" (o ^. #region) (storedDefaults ^. #region)
  zone <- resolveField False "Compute zone" "zone" (o ^. #zone) (storedDefaults ^. #zone)
  baseDomain <- resolveField False "Apps base domain" "base-domain" (o ^. #baseDomain) (storedDefaults ^. #baseDomain)
  machineType <- resolveField False "GCE machine type" "machine-type" (o ^. #machineType) (storedDefaults ^. #machineType)
  bootDiskType <- resolveField False "Boot disk type" "boot-disk-type" (o ^. #bootDiskType) (storedDefaults ^. #bootDiskType)
  bootDiskSizeGb <- resolveField False "Boot disk size (GB)" "boot-disk-size-gb" (o ^. #bootDiskSizeGb) (storedDefaults ^. #bootDiskSizeGb)
  dataDiskSizeGb <- resolveField False "Data disk size (GB)" "data-disk-size-gb" (o ^. #dataDiskSizeGb) (storedDefaults ^. #dataDiskSizeGb)
  shape <-
    either dieT pure $
      validateVmShape
        VmShape
          { machineType = machineType
          , bootDiskType = bootDiskType
          , bootDiskSizeGb = bootDiskSizeGb
          , dataDiskSizeGb = dataDiskSizeGb
          }
  acmeEmailRaw <- resolveField (T.null acmeEmailDefault) "Let's Encrypt contact address" "acme-email" (o ^. #acmeEmail) acmeEmailDefault
  acmeEmail <- either dieT pure (validateAcmeEmail acmeEmailRaw)
  let acmeDirectoryRaw = maybe (storedDefaults ^. #acmeDirectory) T.pack (o ^. #acmeDirectory)
  acmeDirectory <- either dieT (pure . acmeDirectoryToken) (parseAcmeDirectory acmeDirectoryRaw)

  let resolvedOpts =
        o
          & #project
          .~ Just (T.unpack project)
          & #region
          .~ Just (T.unpack region)
          & #zone
          .~ Just (T.unpack zone)
          & #baseDomain
          .~ Just (T.unpack baseDomain)
          & #machineType
          .~ Just (T.unpack (shape ^. #machineType))
          & #bootDiskType
          .~ Just (T.unpack (shape ^. #bootDiskType))
          & #bootDiskSizeGb
          .~ Just (T.unpack (shape ^. #bootDiskSizeGb))
          & #dataDiskSizeGb
          .~ Just (T.unpack (shape ^. #dataDiskSizeGb))
          & #acmeEmail
          .~ Just (T.unpack acmeEmail)
          & #acmeDirectory
          .~ Just (T.unpack acmeDirectory)
      tp =
        profileFromContextMap
          (initContextMap base (initFlagPairs resolvedOpts) (manifest ^. #platformVersion))
      context = contextNameText contextName

  void (either dieT pure (validateVmShape (vmShapeOf tp)))
  either dieT pure (validateNixCacheMode tp)
  TIO.putStr (renderInitSummary context tp)
  either dieT pure (checkInitOwnership (isJust (o ^. #pulumiBackendUrl)) context tp)
  (paths, workspace) <- resolvePlatformWorkspace contextName

  unless (o ^. #skipPreflight) $ do
    putStrLn ("Checking gcloud authentication and operator IAM on " <> T.unpack project <> "...")
    result <- runPreflight project
    case result of
      Left message -> TIO.hPutStr stderr message >> exitFailure
      Right warnings -> do
        printPreflightWarnings warnings
        putStrLn "  preflight OK"

  exportProfileEnv contextName tp
  writeNamedContext (o ^. #force) (o ^. #dryRun) contextName tp
  unless (o ^. #dryRun) (setCurrentContext contextName)
  if o ^. #dryRun
    then TIO.putStrLn ("DRY RUN — would write context '" <> context <> "' and set it current.")
    else TIO.putStrLn ("Wrote context '" <> context <> "' and set it current.")

  -- Named contexts never enable cloud APIs here: a cloud context's reviewed
  -- foundation scope owns them, and a local context must not call gcloud at
  -- all, because the project guardrail steps aside in local mode.
  unless (o ^. #skipSeed || tp ^. #mode == Cloud) $ do
    putStrLn "Seeding Pulumi stack config from the profile..."
    bootstrapResult <- bootstrapPulumiStateBucket (o ^. #dryRun) context tp (T.pack <$> o ^. #pulumiBackendMember)
    either
      ( \message ->
          dieT
            ( "GCS state-bucket bootstrap failed: "
                <> message
                <> " The context '"
                <> context
                <> "' is written and current. Fix the cause and run `nagarectl context use "
                <> context
                <> "` to finish seeding."
            )
      )
      pure
      bootstrapResult
    unless (o ^. #dryRun) (ensurePulumiInWorkspace contextName tp workspace)
    result <- seedPulumiConfig (workspace ^. #pulumiDir) (o ^. #dryRun) context tp
    case result of
      Right () -> pure ()
      Left (key, code) -> dieT (namedSeedFailure context key code)

  when (tp ^. #mode == Cloud) $
    TIO.putStrLn "Cloud APIs and state buckets await `nagarectl platform bootstrap plan --out REVIEW`."
  TIO.putStr (nextStepsText (paths ^. #rootSource))

-- | Legacy no-name initialization retains its active-context-compatible
-- resolver and writes @./nagare.target.env@.
runLegacyInit :: Maybe String -> InitOpts -> IO ()
runLegacyInit mctx o = do
  active <- activeTarget mctx
  guardLegacyMutationInventory "init without NAME" active
  preflightInitTools o (parsePulumiBackendKind (o ^. #pulumiBackend))
  -- Defaults for prompts come from the current resolved profile, so re-running
  -- shows the operator their existing values.
  defs <- activeProfile mctx

  -- Resolve the core target values from flags or interactive prompts. Only
  -- the project is mandatory in non-interactive mode (there is no safe default for
  -- "your project"); region/zone/base-domain fall back to their EP-60 defaults.
  project <- resolveField True "GCP project id" "project" (o ^. #project) (defs ^. #project)
  region <- resolveField False "Compute region" "region" (o ^. #region) (defs ^. #region)
  zone <- resolveField False "Compute zone" "zone" (o ^. #zone) (defs ^. #zone)
  baseDomain <- resolveField False "Apps base domain" "base-domain" (o ^. #baseDomain) (defs ^. #baseDomain)
  machineType <- resolveField False "GCE machine type" "machine-type" (o ^. #machineType) (defs ^. #machineType)
  bootDiskType <- resolveField False "Boot disk type" "boot-disk-type" (o ^. #bootDiskType) (defs ^. #bootDiskType)
  bootDiskSizeGb <- resolveField False "Boot disk size (GB)" "boot-disk-size-gb" (o ^. #bootDiskSizeGb) (defs ^. #bootDiskSizeGb)
  dataDiskSizeGb <- resolveField False "Data disk size (GB)" "data-disk-size-gb" (o ^. #dataDiskSizeGb) (defs ^. #dataDiskSizeGb)
  shape <-
    either dieT pure $
      validateVmShape
        VmShape
          { machineType = machineType
          , bootDiskType = bootDiskType
          , bootDiskSizeGb = bootDiskSizeGb
          , dataDiskSizeGb = dataDiskSizeGb
          }

  -- EP-112: the ACME contact is mandatory, exactly like the project. There is no
  -- safe default for "your mailbox", and a Let's Encrypt account registered under
  -- the wrong address cannot be re-pointed without deleting its account key — so
  -- the cheapest possible failure is here, before a context file exists.
  acmeEmailRaw <- resolveField True "Let's Encrypt contact address" "acme-email" (o ^. #acmeEmail) (defs ^. #acmeEmail)
  acmeEmail <- either dieT pure (validateAcmeEmail acmeEmailRaw)
  let acmeDirectoryRaw = maybe (defs ^. #acmeDirectory) T.pack (o ^. #acmeDirectory)
  acmeDirectory <- either dieT (pure . acmeDirectoryToken) (parseAcmeDirectory acmeDirectoryRaw)

  -- Preflight (unless skipped). Runs AFTER we know the project but BEFORE any
  -- write/enable/seed, so a failure leaves nothing changed.
  unless (o ^. #skipPreflight) $ do
    putStrLn ("Checking gcloud authentication and operator IAM on " <> T.unpack project <> "...")
    r <- runPreflight project
    case r of
      Left msg -> TIO.hPutStr stderr msg >> exitFailure
      Right warnings -> do
        printPreflightWarnings warnings
        putStrLn "  preflight OK"

  -- Build the fully-derived profile (registry host, buckets) via the EP-62 resolver,
  -- then apply the EP-93 Pulumi backend choice (default local; gcs is cloud-only and
  -- downgraded in local mode by effectivePulumiBackend).
  tpBase <- profileFromOpts project region zone baseDomain shape acmeEmail acmeDirectory
  let baseProfile =
        tpBase
          & #pulumiBackend
          .~ parsePulumiBackendKind (o ^. #pulumiBackend)
          & #pulumiBackendUrl
          .~ maybe "" T.pack (o ^. #pulumiBackendUrl)
          & #inventoryStore
          .~ parseInventoryStoreKind (o ^. #inventoryStore)
          & #inventoryStoreUrl
          .~ maybe "" T.pack (o ^. #inventoryStoreUrl)
          & #nixCacheEnabled
          .~ maybe (defs ^. #nixCacheEnabled) (== "1") (o ^. #nixCacheEnabled)
          & #cdnEnabled
          .~ maybe (defs ^. #cdnEnabled) (== "1") (o ^. #cdnEnabled)
          & #nixCacheBucket
          .~ maybe (project <> "-nagare-nix-cache") T.pack (o ^. #nixCacheBucket)
  contextName <- case o ^. #contextName of
    Just rawName -> parseContextNameOrDie rawName
    Nothing -> parseContextNameOrDie "default"
  (paths, workspace) <- resolvePlatformWorkspace contextName
  let tp = case o ^. #contextName of
        Just _ -> baseProfile & #platformVersion .~ Just (workspace ^. #platformVersion)
        Nothing -> baseProfile

  either dieT pure (validateNixCacheMode tp)

  case o ^. #contextName of
    Just _ -> do
      writeNamedContext (o ^. #force) (o ^. #dryRun) contextName tp
      unless (o ^. #dryRun) $ setCurrentContext contextName
      if o ^. #dryRun
        then TIO.putStrLn ("DRY RUN — would write context '" <> contextNameText contextName <> "' and set it current.")
        else TIO.putStrLn ("Wrote context '" <> contextNameText contextName <> "' and set it current.")
    Nothing -> do
      -- Write the profile idempotently.
      wr <- writeTargetEnv (o ^. #force) (o ^. #dryRun) tp
      case wr of
        Wrote -> putStrLn "Wrote nagare.target.env"
        DryRunWouldWrite -> do
          putStrLn "DRY RUN — would write nagare.target.env:"
          TIO.putStr (renderTargetEnv tp)
        RefusedExists ->
          dieT "nagare.target.env already exists; re-run with --force to overwrite it."

  -- Enable the GCP APIs (unless skipped).
  unless (o ^. #skipEnable) $ do
    putStrLn "Enabling GCP service APIs..."
    code <- enableApis (workspace ^. #scriptsDir </> "enable-apis.sh") (o ^. #dryRun)
    case code of
      ExitSuccess -> pure ()
      ExitFailure _ -> dieT "enable-apis failed; see the gcloud output above. Re-run `nagarectl init --skip-preflight` after fixing it."

  -- Seed the Pulumi stack config (unless skipped).
  unless (o ^. #skipSeed) $ do
    putStrLn "Seeding Pulumi stack config from the profile..."
    bootstrapGcsIfNeeded (o ^. #dryRun) (contextNameText contextName) tp (T.pack <$> o ^. #pulumiBackendMember)
    unless (o ^. #dryRun) (ensurePulumiInWorkspace contextName tp workspace)
    s <- seedPulumiConfig (workspace ^. #pulumiDir) (o ^. #dryRun) (contextNameText contextName) tp
    case s of
      Right () -> pure ()
      Left (k, ExitFailure 127) -> dieT ("pulumi could not be started while setting key " <> k <> "; install the nagare operator package and re-run `nagarectl init --skip-preflight --skip-enable`.")
      Left (k, _) -> dieT ("pulumi config set failed at key " <> k <> "; fix Pulumi state and re-run `nagarectl init --skip-preflight --skip-enable`.")

  -- Next steps.
  TIO.putStr (nextStepsText (paths ^. #rootSource))

preflightInitTools :: InitOpts -> PulumiBackendKind -> IO ()
preflightInitTools o backend = do
  missing <- findMissingTools (requiredInitTools o backend)
  unless (null missing) $
    dieT
      ( T.unlines
          ( ["init: required tools are not on PATH: " <> T.intercalate ", " (map T.pack missing)]
              <> [ "  pulumi ships with the nagare package (nix profile install github:shinzui/nagare/v"
                     <> currentBuildVersion ^. #version
                     <> "#nagare);"
                 | "pulumi" `elem` missing
                 ]
              <> ["  npm comes from Node.js, which must be installed separately." | "npm" `elem` missing]
              <> ["  Google Cloud SDK must be installed separately." | "gcloud" `elem` missing]
              <> ["  Nothing was changed."]
          )
      )

namedSeedFailure :: Text -> Text -> ExitCode -> Text
namedSeedFailure context key code =
  prefix
    <> " at key "
    <> key
    <> "; the context '"
    <> context
    <> "' is written and current. Fix the cause and run `nagarectl context use "
    <> context
    <> "` to finish seeding."
  where
    prefix = case code of
      ExitFailure 127 -> "pulumi could not be started"
      _ -> "pulumi config set failed"
