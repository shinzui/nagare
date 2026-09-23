{-# LANGUAGE OverloadedStrings #-}

-- | @nagarectl init@ (MasterPlan 12, EP-63): the guided onboarding command. It is
-- the ONE place in nagarectl permitted to drive Pulumi (@pulumi config set@) and
-- gcloud (@services enable@) — a deliberate one-time bootstrap. Every other command
-- resolves its target purely from the environment (see "Nagare.Target").
--
-- Flow (in @runInit@, app/Main.hs): preflight (gcloud auth + operator IAM) ->
-- prompt/resolve the target -> write nagare.target.env (idempotent; --force to
-- clobber) -> run scripts/enable-apis.sh -> @pulumi config set@ the twelve keys the
-- infra program reads -> print the ordered next-step commands.
module Nagare.Init
  ( InitOpts (..)
  , WriteResult (..)
  , initFlagPairs
  , initContextMap
  , resolveInitBase
  , checkInitOwnership
  , renderInitSummary
  , requiredInitTools
  , findMissingTools
  , profileFromOpts
  , renderTargetEnv
  , pulumiConfigSetArgs
  , seedKeys
  , nextStepsText
  , operatorRoles
  , requiredApis
  , writeTargetEnv
  , runPreflight
  , enableApis
  , seedPulumiConfig
  )
where

import Control.Exception (IOException, try)
import Control.Monad (filterM, when)
import Cradle (addArgs, cmd, run)
import Data.Function ((&))
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Maybe (catMaybes, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Text.IO qualified as TIO
import GHC.Generics (Generic)
import Nagare.Dsl.Prelude
import Nagare.Gcp.Adc (adcEnvFromProcess, observeAdc, validateAdc)
import Nagare.Ops.Probe (captureTool)
import Nagare.Platform.Paths (PlatformRootSource (..))
import Nagare.Target
  ( ContextName
  , Mode (..)
  , InventoryStoreKind (..)
  , PulumiBackendKind (..)
  , TargetProfile (..)
  , VmShape (..)
  , contextFilePath
  , contextNameText
  , defaultGcsPulumiBackendUrl
  , effectivePulumiBackend
  , inventoryStoreToken
  , parseInventoryStoreKind
  , mergeContextOverrides
  , pulumiBackendToken
  , readContextMap
  , registryPrefix
  , resolveTargetProfile
  )
import System.Directory (doesFileExist, findExecutable)
import System.Environment (setEnv, unsetEnv)
import System.Exit (ExitCode (..))

-- | Options for @nagarectl init@. Target fields are 'Maybe' so an absent
-- flag triggers an interactive prompt (on a TTY) or an error (non-TTY). The skip
-- flags exist for testing/CI and for partial recovery (e.g. re-seed without
-- re-enabling). @--force@ permits overwriting an existing profile.
data InitOpts = InitOpts
  { contextName :: !(Maybe String)
  , project :: !(Maybe String)
  , region :: !(Maybe String)
  , zone :: !(Maybe String)
  , baseDomain :: !(Maybe String)
  , externalDomainTlsEnabled :: !(Maybe String)
  , machineType :: !(Maybe String)
  , bootDiskType :: !(Maybe String)
  , bootDiskSizeGb :: !(Maybe String)
  , dataDiskSizeGb :: !(Maybe String)
  , nixCacheEnabled :: !(Maybe String)
  , nixCacheBucket :: !(Maybe String)
  , pulumiBackend :: !(Maybe String)
  , pulumiBackendUrl :: !(Maybe String)
  , inventoryStore :: !(Maybe String)
  , inventoryStoreUrl :: !(Maybe String)
  , pulumiBackendMember :: !(Maybe String)
  , acmeEmail :: !(Maybe String)
  , acmeDirectory :: !(Maybe String)
  , force :: !Bool
  , skipPreflight :: !Bool
  , skipEnable :: !Bool
  , skipSeed :: !Bool
  , dryRun :: !Bool
  }
  deriving stock (Eq, Show, Generic)

-- | Convert only the target-setting flags supplied to @nagarectl init@ into the
-- stored context keys they override. Callers may first fill the optional fields
-- from prompts, which makes this suitable for both flag-only and interactive
-- named initialization.
initFlagPairs :: InitOpts -> [(String, Text)]
initFlagPairs o =
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
    , pair "NAGARE_NIX_CACHE_ENABLED" (o ^. #nixCacheEnabled)
    , pair "NAGARE_NIX_CACHE_BUCKET" (o ^. #nixCacheBucket)
    , pair "NAGARE_PULUMI_BACKEND" (o ^. #pulumiBackend)
    , pair "NAGARE_PULUMI_BACKEND_URL" (o ^. #pulumiBackendUrl)
    , pair "NAGARE_INVENTORY_STORE" (o ^. #inventoryStore)
    , pair "NAGARE_INVENTORY_STORE_URL" (o ^. #inventoryStoreUrl)
    , pair "NAGARE_ACME_EMAIL" (o ^. #acmeEmail)
    , pair "NAGARE_ACME_DIRECTORY" (o ^. #acmeDirectory)
    ]
  where
    pair key = fmap (\value -> (key, T.pack value))

-- | Build the context map for named initialization. This deliberately delegates
-- to the same merge used by @context create --force@: flags override the named
-- context's own stored values, omitted fields keep those values, and a new
-- context receives the payload version without consulting the active context.
initContextMap :: Maybe (Map String Text) -> [(String, Text)] -> Text -> Map String Text
initContextMap = mergeContextOverrides

-- | Read only the named context that @init NAME@ is about to create or replace.
-- The current-context pointer and process environment are intentionally outside
-- this function's inputs.
resolveInitBase :: ContextName -> Bool -> IO (Either Text (Maybe (Map String Text)))
resolveInitBase name force = do
  path <- contextFilePath name
  stored <- readContextMap path
  pure $ case stored of
    Nothing -> Right Nothing
    Just context
      | force -> Right (Just context)
      | otherwise ->
          Left
            ( "context '"
                <> contextNameText name
                <> "' already exists; pass --force to re-initialize it (omitted flags keep its stored values)"
            )

-- | Refuse names derived for another project before initialization performs any
-- side effect. Explicit GCS backend URLs are operator choices and are therefore
-- shown in the summary but left to the existing bucket ownership guard.
checkInitOwnership :: Bool -> Text -> TargetProfile -> Either Text ()
checkInitOwnership explicitBackendUrl context tp =
  case offenders of
    [] -> Right ()
    names ->
      Left
        ( "init: stored or inherited values belong to a different project: "
            <> T.intercalate ", " names
            <> ". Expected names beginning with '"
            <> projectPrefix
            <> "'. Choose a new context name or run `nagarectl context create "
            <> context
            <> " --force --image-bucket ... --backup-bucket ...`. Nothing was changed."
        )
  where
    projectPrefix = tp ^. #project <> "-"
    wrongPrefix value = not (projectPrefix `T.isPrefixOf` value)
    bucketOffenders =
      [ name
      | (name, value) <-
          [ ("NAGARE_IMAGE_BUCKET", tp ^. #imageBucket)
          , ("NAGARE_BACKUP_BUCKET", tp ^. #backupBucket)
          , ("NAGARE_NIX_CACHE_BUCKET", tp ^. #nixCacheBucket)
          ]
      , wrongPrefix value
      ]
    backendUrl
      | T.null (tp ^. #pulumiBackendUrl) = defaultGcsPulumiBackendUrl context tp
      | otherwise = tp ^. #pulumiBackendUrl
    backendBucket = do
      rest <- T.stripPrefix "gs://" backendUrl
      pure (T.takeWhile (/= '/') rest)
    backendOffenders
      | explicitBackendUrl = []
      | effectivePulumiBackend tp /= PulumiBackendGcs = []
      | maybe True (\bucket -> T.null bucket || wrongPrefix bucket) backendBucket = ["NAGARE_PULUMI_BACKEND_URL"]
      | otherwise = []
    offenders = bucketOffenders <> backendOffenders

-- | Show the project-owned names that named initialization resolved before any
-- preflight or write. A local backend uses a deliberately symbolic state root;
-- the real per-context path is printed later when the workspace is prepared.
renderInitSummary :: Text -> TargetProfile -> Text
renderInitSummary context tp =
  T.unlines
    [ "Derived names for context '" <> context <> "':"
    , "  project: " <> tp ^. #project
    , "  registry prefix: " <> registryPrefix tp
    , "  image bucket: " <> tp ^. #imageBucket
    , "  backup bucket: " <> tp ^. #backupBucket
    , "  Nix cache: " <> if tp ^. #nixCacheEnabled then "enabled" else "disabled"
    , "  Nix cache bucket: " <> tp ^. #nixCacheBucket
    , "  instance name: " <> tp ^. #instanceName
    , "  Pulumi backend: " <> pulumiBackendToken backend
    , "  Pulumi backend URL: " <> backendUrl
    ]
  where
    backend = effectivePulumiBackend tp
    backendUrl = case backend of
      PulumiBackendLocal -> "file://<state>/" <> context <> "/state"
      PulumiBackendGcs
        | T.null (tp ^. #pulumiBackendUrl) -> defaultGcsPulumiBackendUrl context tp
        | otherwise -> tp ^. #pulumiBackendUrl

-- | External programs needed by an init invocation. The list is ordered for
-- deterministic diagnostics. Dry runs use the same preflight as real runs so
-- they cannot promise success when the real command would later fail.
requiredInitTools :: InitOpts -> PulumiBackendKind -> [String]
requiredInitTools o backend =
  (if needsGcloud then ["gcloud"] else [])
    <> (if o ^. #skipSeed then [] else ["pulumi", "npm"])
  where
    needsGcloud =
      not (o ^. #skipPreflight)
        || not (o ^. #skipEnable)
        || (not (o ^. #skipSeed) && (backend == PulumiBackendGcs
            || parseInventoryStoreKind (o ^. #inventoryStore) == InventoryStoreGcs))

-- | Return the requested executable names that cannot be resolved on PATH.
findMissingTools :: [String] -> IO [String]
findMissingTools = filterM (fmap isNothing . findExecutable)

-- | The operator IAM roles the preflight verifies (Decision Log). @roles/owner@
-- short-circuits to pass because it includes all of these.
operatorRoles :: [Text]
operatorRoles =
  [ "roles/compute.admin"
  , "roles/dns.admin"
  , "roles/artifactregistry.admin"
  , "roles/storage.admin"
  , "roles/iam.securityAdmin"
  , "roles/serviceusage.serviceUsageAdmin"
  ]

-- | The service APIs enable-apis.sh turns on; kept here for documentation and the
-- next-steps text. The script is the source of truth for the actual enable.
requiredApis :: [Text]
requiredApis =
  [ "compute.googleapis.com"
  , "dns.googleapis.com"
  , "storage.googleapis.com"
  , "artifactregistry.googleapis.com"
  , "certificatemanager.googleapis.com"
  , "iam.googleapis.com"
  , "servicenetworking.googleapis.com"
  ]

-- | Build the legacy no-name @init@ profile by reusing 'resolveTargetProfile'
-- with the selected values placed into the environment. Named initialization is
-- pure and must use 'initContextMap' with @profileFromContextMap@ instead.
profileFromOpts :: Text -> Text -> Text -> Text -> VmShape -> Text -> Text -> IO TargetProfile
profileFromOpts project region zone baseDomain shape acmeEmail acmeDirectory = do
  setEnv "CLOUDSDK_CORE_PROJECT" (T.unpack project)
  setEnv "CLOUDSDK_COMPUTE_REGION" (T.unpack region)
  setEnv "CLOUDSDK_COMPUTE_ZONE" (T.unpack zone)
  setEnv "NAGARE_BASE_DOMAIN" (T.unpack baseDomain)
  setEnv "NAGARE_MACHINE_TYPE" (T.unpack (shape ^. #machineType))
  setEnv "NAGARE_BOOT_DISK_TYPE" (T.unpack (shape ^. #bootDiskType))
  setEnv "NAGARE_BOOT_DISK_SIZE_GB" (T.unpack (shape ^. #bootDiskSizeGb))
  setEnv "NAGARE_DATA_DISK_SIZE_GB" (T.unpack (shape ^. #dataDiskSizeGb))
  -- EP-112: an EMPTY value means "no explicit choice", which must not leave a
  -- stale ambient value in place for the resolver to pick up. `setEnv` with an
  -- empty string happens to remove the variable on this toolchain, but write the
  -- case split explicitly so the behavior does not depend on that detail.
  setOrUnset "NAGARE_ACME_EMAIL" acmeEmail
  setOrUnset "NAGARE_ACME_DIRECTORY" acmeDirectory
  mapM_
    unsetEnv
    [ "NAGARE_REGISTRY_HOST"
    , "NAGARE_IMAGE_BUCKET"
    , "NAGARE_BACKUP_BUCKET"
    , "NAGARE_ARTIFACT_REGISTRY_ID"
    , "NAGARE_INSTANCE_NAME"
    ]
  resolveTargetProfile
  where
    setOrUnset name value
      | T.null value = unsetEnv name
      | otherwise = setEnv name (T.unpack value)

-- | Render the profile as @export VAR=value@ lines, matching the target/context
-- schema so a profile can round-trip through the context store.
renderTargetEnv :: TargetProfile -> Text
renderTargetEnv tp =
  T.unlines $
    [ "# nagare target profile — generated by `nagarectl init` (EP-63)."
    , "# Edit this file or re-run `nagarectl init --force` to change the target."
    , "export CLOUDSDK_CORE_PROJECT=" <> tp ^. #project
    , "export CLOUDSDK_COMPUTE_REGION=" <> tp ^. #region
    , "export CLOUDSDK_COMPUTE_ZONE=" <> tp ^. #zone
    , "export NAGARE_REGISTRY_HOST=" <> tp ^. #registryHost
    , "export NAGARE_ARTIFACT_REGISTRY_ID=" <> tp ^. #artifactRegistryId
    , "export NAGARE_IMAGE_BUCKET=" <> tp ^. #imageBucket
    , "export NAGARE_BACKUP_BUCKET=" <> tp ^. #backupBucket
    , "export NAGARE_NIX_CACHE_ENABLED=" <> boolToken (tp ^. #nixCacheEnabled)
    , "export NAGARE_EXTERNAL_DOMAIN_TLS_ENABLED=" <> boolToken (tp ^. #externalDomainTlsEnabled)
    , "export NAGARE_NIX_CACHE_BUCKET=" <> tp ^. #nixCacheBucket
    , "export NAGARE_BASE_DOMAIN=" <> tp ^. #baseDomain
    , "export NAGARE_ACME_EMAIL=" <> tp ^. #acmeEmail
    , "export NAGARE_ACME_DIRECTORY=" <> tp ^. #acmeDirectory
    , "export NAGARE_INSTANCE_NAME=" <> tp ^. #instanceName
    , "export NAGARE_MACHINE_TYPE=" <> tp ^. #machineType
    , "export NAGARE_BOOT_DISK_TYPE=" <> tp ^. #bootDiskType
    , "export NAGARE_BOOT_DISK_SIZE_GB=" <> tp ^. #bootDiskSizeGb
    , "export NAGARE_DATA_DISK_SIZE_GB=" <> tp ^. #dataDiskSizeGb
    , "export NAGARE_TARGET_PLATFORM=" <> tp ^. #targetPlatform
    , "export NAGARE_MODE=" <> modeToken (tp ^. #mode)
    , "export NAGARE_LOCAL_OBJECT_STORE=" <> tp ^. #localObjectStore
    , "export NAGARE_PULUMI_BACKEND=" <> pulumiBackendToken (tp ^. #pulumiBackend)
    , "export NAGARE_PULUMI_BACKEND_URL=" <> tp ^. #pulumiBackendUrl
    , "export NAGARE_INVENTORY_STORE=" <> inventoryStoreToken (tp ^. #inventoryStore)
    , "export NAGARE_INVENTORY_STORE_URL=" <> tp ^. #inventoryStoreUrl
    ]
      <> maybe [] (\version -> ["export NAGARE_PLATFORM_VERSION=" <> version]) (tp ^. #platformVersion)
  where
    modeToken Cloud = "cloud"
    modeToken Local = "local"
    boolToken True = "1"
    boolToken False = "0"

-- | The fourteen Pulumi config (key, value) pairs to seed from the profile. Order is
-- stable for deterministic output. @nagare:imageBucket@ is REQUIRED by the program
-- (no default), so it is always present here. The four VM-shape values are pinned
-- so a later change to a program fallback cannot plan an instance replacement
-- against a live VM. NOTE: @NAGARE_TARGET_PLATFORM@ (EP-3)
-- is deliberately NOT seeded — it is a build-time client concern (the architecture
-- nagarectl builds images for), not GCP infrastructure, so Pulumi has no use for it.
seedKeys :: TargetProfile -> [(Text, Text)]
seedKeys tp =
  [ ("gcp:project", tp ^. #project)
  , ("gcp:region", tp ^. #region)
  , ("gcp:zone", tp ^. #zone)
  , ("nagare:baseDomain", tp ^. #baseDomain)
  , ("nagare:imageBucket", tp ^. #imageBucket)
  , ("nagare:backupBucket", tp ^. #backupBucket)
  , ("nagare:enableNixCache", if tp ^. #nixCacheEnabled then "true" else "false")
  , ("nagare:nixCacheBucket", tp ^. #nixCacheBucket)
  , ("nagare:artifactRegistryId", tp ^. #artifactRegistryId)
  , ("nagare:instanceName", tp ^. #instanceName)
  , ("nagare:machineType", tp ^. #machineType)
  , ("nagare:bootDiskType", tp ^. #bootDiskType)
  , ("nagare:bootDiskSizeGb", tp ^. #bootDiskSizeGb)
  , ("nagare:dataDiskSizeGb", tp ^. #dataDiskSizeGb)
  ]

-- | The argv for one @pulumi -C infra/pulumi config set --stack STACK KEY VALUE@.
-- Pure so it is unit-testable without Pulumi.
pulumiConfigSetArgs :: FilePath -> Text -> Text -> Text -> [String]
pulumiConfigSetArgs pulumiDir stack key value =
  ["-C", pulumiDir, "config", "set", "--stack", T.unpack stack, T.unpack key, T.unpack value]

-- | The ordered follow-on commands printed after a successful init. Packaged
-- and explicitly selected payloads use the installed @nagare@ launcher; source
-- checkouts retain their direct @just@ workflow.
nextStepsText :: PlatformRootSource -> Text
nextStepsText rootSource =
  T.unlines
    ( [ ""
      , "Next steps:"
      , "  1.  " <> command "infra-up" <> "        # create the GCP resources (the VM is omitted until the image exists)"
      , "  2.  " <> command "host-image" <> "      # build + register the NixOS image and write its self-link to Pulumi config"
      , "  3.  " <> command "infra-up" <> "        # re-run to create the VM now that nagareImageSelfLink is set"
      , "  4.  " <> command "cluster-bootstrap" <> "   # install the in-cluster platform (k3s/Knative/cert-manager)"
      , ""
      ]
        <> guidance
    )
  where
    command recipe = launcher <> " " <> recipe
    launcher = case rootSource of
      SourceRoot -> "just"
      InstalledRoot -> "nagare"
      ExplicitRoot -> "nagare"
    guidance = case rootSource of
      SourceRoot ->
        [ "See docs/masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md and the"
        , "EP-2/EP-3/EP-4 plans under docs/plans/ for the details behind each step."
        ]
      _ -> ["See the release's installed guide at docs/user/getting-started.md."]

-- | Outcome of attempting to write the profile file.
data WriteResult = Wrote | RefusedExists | DryRunWouldWrite
  deriving stock (Eq, Show)

-- | Write nagare.target.env at the repo root, idempotently. Refuses to clobber an
-- existing file unless @force@ is set. With @dryRun@, writes nothing. Returns what
-- it did so the handler can report it.
writeTargetEnv :: Bool -> Bool -> TargetProfile -> IO WriteResult
writeTargetEnv force dryRun tp = do
  let path = "nagare.target.env"
  exists <- doesFileExist path
  if dryRun
    then pure DryRunWouldWrite
    else
      if exists && not force
        then pure RefusedExists
        else do
          TIO.writeFile path (renderTargetEnv tp)
          pure Wrote

-- | Run scripts/enable-apis.sh (which sources the guardrail and enables the APIs).
-- Returns the exit code so the handler can fail the command on a real error. With
-- @dryRun@, sets NAGARE_ENABLE_APIS_DRY_RUN=1 so the script prints the argv. The
-- script's stdout/stderr stream to the terminal (no capture).
enableApis :: FilePath -> Bool -> IO ExitCode
enableApis script dryRun = do
  when dryRun (setEnv "NAGARE_ENABLE_APIS_DRY_RUN" "1")
  run $ cmd "bash" & addArgs [script]

-- | @pulumi config set@ each seed key from the profile, against the infra/pulumi
-- stack. Stops and returns the first failing key (with its exit code) so the
-- handler can report a precise, recoverable error. @dryRun@ prints the argv.
seedPulumiConfig :: FilePath -> Bool -> Text -> TargetProfile -> IO (Either (Text, ExitCode) ())
seedPulumiConfig pulumiDir dryRun stack tp = go (seedKeys tp)
  where
    go [] = pure (Right ())
    go ((k, v) : rest)
      | dryRun = do
          TIO.putStrLn ("  pulumi " <> T.pack (unwords (pulumiConfigSetArgs pulumiDir stack k v)))
          go rest
      | otherwise = do
          result <-
            try (run $ cmd "pulumi" & addArgs (pulumiConfigSetArgs pulumiDir stack k v)) ::
              IO (Either IOException ExitCode)
          case result of
            Left _ -> pure (Left (k, ExitFailure 127))
            Right ExitSuccess -> go rest
            Right code@(ExitFailure _) -> pure (Left (k, code))

-- | Preflight: confirm gcloud has an active authenticated account and that it
-- holds (or owns) the operator roles on @project@. Returns ADC warnings on pass, or
-- @Left msg@ with a precise remediation on failure. Read-only: it only queries.
runPreflight :: Text -> IO (Either Text [Text])
runPreflight project = do
  mAcct <-
    captureTool
      "gcloud"
      ["auth", "list", "--filter=status:ACTIVE", "--format=value(account)"]
  case fmap (T.strip . decodeUtf8) mAcct of
    Nothing -> pure (Left authRemediation)
    Just acct
      | T.null acct -> pure (Left authRemediation)
      | otherwise -> do
          adcEnv <- adcEnvFromProcess
          adc <- observeAdc adcEnv
          case validateAdc project (Just acct) adc of
            Left refusal -> pure (Left ("nagarectl init preflight FAILED:\n" <> refusal <> "\n"))
            Right warnings -> do
              mPolicy <-
                captureTool
                  "gcloud"
                  [ "projects"
                  , "get-iam-policy"
                  , T.unpack project
                  , "--flatten=bindings[].members"
                  , "--filter=bindings.members:user:" <> T.unpack acct
                  , "--format=value(bindings.role)"
                  ]
              let held = maybe [] (T.lines . T.strip . decodeUtf8) mPolicy
                  isOwner = "roles/owner" `elem` held
                  missing = filter (`notElem` held) operatorRoles
              if isOwner || null missing
                then pure (Right warnings)
                else pure (Left (iamRemediation acct project missing))
  where
    authRemediation =
      T.unlines
        [ "nagarectl init preflight FAILED: no active gcloud account."
        , "  Run: gcloud auth login"
        , "  and: gcloud auth application-default login"
        , "  then re-run `nagarectl init`."
        ]
    iamRemediation acct proj missing =
      T.unlines
        ( [ "nagarectl init preflight FAILED: account "
              <> acct
              <> " is missing required roles on "
              <> proj
              <> ":"
          ]
            <> map ("    " <>) missing
            <> [ "  Grant them (or roles/owner), e.g.:"
               , "    gcloud projects add-iam-policy-binding "
                   <> proj
                   <> " --member=user:"
                   <> acct
                   <> " --role=<role>"
               , "  then re-run `nagarectl init` (or pass --skip-preflight to bypass)."
               ]
        )
