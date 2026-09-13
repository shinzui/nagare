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

import Control.Monad (when)
import Cradle (addArgs, cmd, run)
import Data.Function ((&))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Text.IO qualified as TIO
import GHC.Generics (Generic)
import Nagare.Dsl.Prelude
import Nagare.Ops.Probe (captureTool)
import Nagare.Target
  ( Mode (..)
  , TargetProfile (..)
  , VmShape (..)
  , pulumiBackendToken
  , resolveTargetProfile
  )
import System.Directory (doesFileExist)
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
  , machineType :: !(Maybe String)
  , bootDiskType :: !(Maybe String)
  , bootDiskSizeGb :: !(Maybe String)
  , dataDiskSizeGb :: !(Maybe String)
  , pulumiBackend :: !(Maybe String)
  , pulumiBackendUrl :: !(Maybe String)
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
  , "iam.googleapis.com"
  , "servicenetworking.googleapis.com"
  ]

-- | Build the resolved 'TargetProfile' from the chosen project/region/zone/base
-- domain by REUSING 'resolveTargetProfile' with those values placed into the
-- environment, so the derived fields (registry host, buckets) follow EP-60's
-- derivations exactly. The derived overrides are cleared so the derivation, not a
-- stale env value, wins.
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
    ]
      <> maybe [] (\version -> ["export NAGARE_PLATFORM_VERSION=" <> version]) (tp ^. #platformVersion)
  where
    modeToken Cloud = "cloud"
    modeToken Local = "local"

-- | The twelve Pulumi config (key, value) pairs to seed from the profile. Order is
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

-- | The ordered follow-on commands printed after a successful init.
nextStepsText :: Text
nextStepsText =
  T.unlines
    [ ""
    , "Next steps:"
    , "  1.  just infra-up        # create the GCP resources (the VM is omitted until the image exists)"
    , "  2.  just host-image      # build + register the NixOS image and write its self-link to Pulumi config"
    , "  3.  just infra-up        # re-run to create the VM now that nagareImageSelfLink is set"
    , "  4.  just cluster-bootstrap   # install the in-cluster platform (k3s/Knative/cert-manager)"
    , ""
    , "See docs/masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md and the"
    , "EP-2/EP-3/EP-4 plans under docs/plans/ for the details behind each step."
    ]

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
          code <- run $ cmd "pulumi" & addArgs (pulumiConfigSetArgs pulumiDir stack k v)
          case code of
            ExitSuccess -> go rest
            ExitFailure _ -> pure (Left (k, code))

-- | Preflight: confirm gcloud has an active authenticated account and that it
-- holds (or owns) the operator roles on @project@. Returns @Right ()@ on pass, or
-- @Left msg@ with a precise remediation on failure. Read-only: it only queries.
runPreflight :: Text -> IO (Either Text ())
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
            then pure (Right ())
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
