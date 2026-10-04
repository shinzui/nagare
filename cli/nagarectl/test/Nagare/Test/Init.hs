-- | Init responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Init
  ( initTests
  )
where

import Control.Exception (finally)
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Init
  ( InitOpts (..)
  , checkInitOwnership
  , findMissingTools
  , initContextMap
  , nextStepsText
  , operatorRoles
  , pulumiConfigSetArgs
  , renderInitSummary
  , renderTargetEnv
  , requiredInitTools
  , seedKeys
  , seedPulumiConfig
  )
import Nagare.Platform.Paths
  ( PlatformRootSource (InstalledRoot, SourceRoot)
  )
import Nagare.Target
  ( AcmeDirectory (AcmeCustom, AcmeProduction, AcmeStaging)
  , InventoryStoreKind (InventoryStoreGcs, InventoryStoreLocal)
  , Mode (Cloud, Local)
  , PulumiBackendKind (PulumiBackendGcs, PulumiBackendLocal)
  , PulumiEnv (PulumiEnv, backendUrl, home, kind, stack)
  , TargetProfile (inventoryStore, mode)
  , acmeDirectoryUrl
  , defaultGcsInventoryStoreUrl
  , defaultGcsPulumiBackendUrl
  , defaultVmShape
  , effectiveInventoryStore
  , effectivePulumiBackend
  , mkContextName
  , parseAcmeDirectory
  , parseContextEnv
  , parseInventoryStoreKind
  , parsePulumiBackendKind
  , profileFromContextMap
  , pulumiEnvFor
  , renderContextShellEnv
  , validateAcmeEmail
  , validateNixCacheMode
  , validateVmShape
  )
import Nagare.Test.Support.Profiles (initProfile)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (ExitFailure))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcess)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit
  ( assertBool
  , assertFailure
  , testCase
  , (@?=)
  )

initTests :: TestTree
initTests =
  testGroup
    "Nagare.Init (EP-63)"
    [ testCase "renderTargetEnv emits the export lines with the right values" $ do
        let out = renderTargetEnv initProfile
        assertBool "project" (T.isInfixOf "export CLOUDSDK_CORE_PROJECT=acme-prod" out)
        assertBool "derived image bucket" (T.isInfixOf "export NAGARE_IMAGE_BUCKET=acme-prod-nagare-images" out)
        assertBool "cache disabled" (T.isInfixOf "export NAGARE_NIX_CACHE_ENABLED=0" out)
        assertBool "derived cache bucket" (T.isInfixOf "export NAGARE_NIX_CACHE_BUCKET=acme-prod-nagare-nix-cache" out)
        assertBool "base domain" (T.isInfixOf "export NAGARE_BASE_DOMAIN=apps.acme.com" out)
        assertBool "machine type" (T.isInfixOf "export NAGARE_MACHINE_TYPE=e2-standard-2" out)
        assertBool "boot disk type" (T.isInfixOf "export NAGARE_BOOT_DISK_TYPE=pd-balanced" out)
        assertBool "target platform (default)" (T.isInfixOf "export NAGARE_TARGET_PLATFORM=linux/amd64" out)
        assertBool "mode (default cloud)" (T.isInfixOf "export NAGARE_MODE=cloud" out)
        assertBool "local object store (empty for cloud)" (T.isInfixOf "export NAGARE_LOCAL_OBJECT_STORE=" out)
        assertBool "platform version" (T.isInfixOf "export NAGARE_PLATFORM_VERSION=0.1.0" out)
    , testCase "renderTargetEnv emits an overridden target platform (EP-3)" $ do
        let out = renderTargetEnv (initProfile & #targetPlatform .~ "linux/arm64")
        assertBool "target platform (override)" (T.isInfixOf "export NAGARE_TARGET_PLATFORM=linux/arm64" out)
    , testCase "renderTargetEnv emits local context fields for round-trip" $ do
        let out =
              renderTargetEnv $
                initProfile
                  & #mode
                  .~ Local
                  & #registryHost
                  .~ "k3d-registry.localhost:5000"
                  & #baseDomain
                  .~ "127-0-0-1.sslip.io"
                  & #localObjectStore
                  .~ "http://minio:9000/nagare-backups"
        assertBool "local mode" (T.isInfixOf "export NAGARE_MODE=local" out)
        assertBool "local registry" (T.isInfixOf "export NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000" out)
        assertBool "local object store" (T.isInfixOf "export NAGARE_LOCAL_OBJECT_STORE=http://minio:9000/nagare-backups" out)
    , testCase "seedKeys covers the Pulumi keys incl. cache opt-in and pinned VM shape" $
        map fst (seedKeys initProfile)
          @?= [ "gcp:project"
              , "gcp:region"
              , "gcp:zone"
              , "nagare:baseDomain"
              , "nagare:imageBucket"
              , "nagare:backupBucket"
              , "nagare:enableNixCache"
              , "nagare:nixCacheBucket"
              , "nagare:artifactRegistryId"
              , "nagare:instanceName"
              , "nagare:serviceAccountId"
              , "nagare:machineType"
              , "nagare:bootDiskType"
              , "nagare:bootDiskSizeGb"
              , "nagare:dataDiskSizeGb"
              , "nagare:manageProjectApis"
              ]
    , testCase "foundation owns API enablement when Pulumi config is seeded" $
        lookup "nagare:manageProjectApis" (seedKeys initProfile) @?= Just "false"
    , testCase "isolated context pins its node service account in the reviewed stack" $ do
        let contextMap =
              initContextMap
                Nothing
                [("NAGARE_SERVICE_ACCOUNT_ID", "nagare-ep150")]
                "0.4.0"
            profile = profileFromContextMap contextMap
        profile ^. #serviceAccountId @?= "nagare-ep150"
        lookup "nagare:serviceAccountId" (seedKeys profile) @?= Just "nagare-ep150"
        assertBool
          "rendered profile includes service account"
          ( T.isInfixOf
              "export NAGARE_SERVICE_ACCOUNT_ID=nagare-ep150"
              (renderTargetEnv profile)
          )
    , testCase "named init retains the reviewed backend IAM member" $ do
        let contextMap =
              initContextMap
                Nothing
                [("NAGARE_PULUMI_BACKEND_MEMBER", "serviceAccount:deployer@example.iam.gserviceaccount.com")]
                "0.4.0"
            profile = profileFromContextMap contextMap
        profile ^. #pulumiBackendMember
          @?= Just "serviceAccount:deployer@example.iam.gserviceaccount.com"
        assertBool
          "rendered profile includes member"
          ( T.isInfixOf
              "export NAGARE_PULUMI_BACKEND_MEMBER='serviceAccount:deployer@example.iam.gserviceaccount.com'"
              (renderTargetEnv profile)
          )
    , testCase "validateVmShape accepts named and custom machine types" $ do
        validateVmShape defaultVmShape @?= Right defaultVmShape
        let custom = defaultVmShape & #machineType .~ "custom-4-8192"
        validateVmShape custom @?= Right custom
    , testCase "validateVmShape reports every rejected field precisely" $ do
        validateVmShape (defaultVmShape & #machineType .~ "")
          @?= Left "NAGARE_MACHINE_TYPE must not be empty"
        validateVmShape (defaultVmShape & #machineType .~ "E2-standard-2")
          @?= Left "NAGARE_MACHINE_TYPE='E2-standard-2' is invalid (expected <family>-<series> using lowercase letters/digits/hyphens, or custom-<cpus>-<mb>)"
        validateVmShape (defaultVmShape & #bootDiskType .~ "pd-extreme")
          @?= Left "NAGARE_BOOT_DISK_TYPE='pd-extreme' is invalid (accepted: pd-standard, pd-balanced, pd-ssd, hyperdisk-balanced)"
        validateVmShape (defaultVmShape & #bootDiskSizeGb .~ "9")
          @?= Left "NAGARE_BOOT_DISK_SIZE_GB must be an integer of at least 10 GB"
        validateVmShape (defaultVmShape & #dataDiskSizeGb .~ "many")
          @?= Left "NAGARE_DATA_DISK_SIZE_GB must be an integer of at least 10 GB"
    , testCase "a new init context derives names without an active-context base" $ do
        let contextMap =
              initContextMap
                Nothing
                [ ("CLOUDSDK_CORE_PROJECT", "p")
                , ("NAGARE_ACME_EMAIL", "ops@example.com")
                ]
                "0.2.2"
            tp = profileFromContextMap contextMap
        tp ^. #imageBucket @?= "p-nagare-images"
        tp ^. #backupBucket @?= "p-nagare-backups"
        tp ^. #nixCacheEnabled @?= False
        tp ^. #nixCacheBucket @?= "p-nagare-nix-cache"
        tp ^. #registryHost @?= "us-west1-docker.pkg.dev"
        tp ^. #instanceName @?= "nagare-01"
        tp ^. #targetPlatform @?= "linux/amd64"
        tp ^. #mode @?= Cloud
        tp ^. #pulumiBackend @?= PulumiBackendLocal
        tp ^. #platformVersion @?= Just "0.2.2"
    , testCase "forced init keeps omitted values from its own stored context" $ do
        let stored =
              Map.fromList
                [ ("CLOUDSDK_CORE_PROJECT", "p")
                , ("NAGARE_IMAGE_BUCKET", "p-custom-images")
                , ("NAGARE_PULUMI_BACKEND", "gcs")
                , ("NAGARE_PLATFORM_VERSION", "0.2.1")
                ]
            contextMap = initContextMap (Just stored) [("NAGARE_ACME_DIRECTORY", "staging")] "0.2.2"
            tp = profileFromContextMap contextMap
        tp ^. #imageBucket @?= "p-custom-images"
        tp ^. #pulumiBackend @?= PulumiBackendGcs
        tp ^. #platformVersion @?= Just "0.2.1"
        tp ^. #acmeDirectory @?= "staging"
    , testCase "init ownership refuses foreign derived buckets and backend URLs" $ do
        let foreignBuckets =
              initProfile
                & #project
                .~ "tan-ng-labs"
                & #imageBucket
                .~ "tan-nb-exp-nagare-images"
                & #backupBucket
                .~ "tan-nb-exp-nagare-backups"
            foreignBackend =
              initProfile
                & #pulumiBackend
                .~ PulumiBackendGcs
                & #pulumiBackendUrl
                .~ "gs://other-nagare-pulumi-state/nagare/labs"
        case checkInitOwnership False "labs" foreignBuckets of
          Left message -> do
            assertBool "image bucket named" (T.isInfixOf "NAGARE_IMAGE_BUCKET" message)
            assertBool "backup bucket named" (T.isInfixOf "NAGARE_BACKUP_BUCKET" message)
          Right () -> assertFailure "foreign buckets were accepted"
        checkInitOwnership False "labs" initProfile @?= Right ()
        assertBool "stored foreign GCS URL refused" (isLeft (checkInitOwnership False "labs" foreignBackend))
        checkInitOwnership True "labs" foreignBackend @?= Right ()
    , testCase "nix cache is cloud-only and round-trips when enabled" $ do
        let enabled = initProfile & #nixCacheEnabled .~ True
        validateNixCacheMode enabled @?= Right ()
        validateNixCacheMode (enabled & #mode .~ Local)
          @?= Left "NAGARE_NIX_CACHE_ENABLED=1 is cloud-only; disable it for local contexts"
        let parsed = profileFromContextMap (parseContextEnv "export CLOUDSDK_CORE_PROJECT=acme-prod\nexport NAGARE_NIX_CACHE_ENABLED=1\n")
        parsed ^. #nixCacheEnabled @?= True
        parsed ^. #nixCacheBucket @?= "acme-prod-nagare-nix-cache"
    , testCase "Google CDN is cloud-only, round-trips, and seeds the apex-preserving keys (F43)" $ do
        let enabled = initProfile & #cdnEnabled .~ True
        validateNixCacheMode enabled @?= Right ()
        validateNixCacheMode (enabled & #mode .~ Local)
          @?= Left "NAGARE_CDN_ENABLED=1 is cloud-only; disable it for local contexts"
        let parsed = profileFromContextMap (parseContextEnv "export CLOUDSDK_CORE_PROJECT=acme-prod\nexport NAGARE_CDN_ENABLED=1\n")
        parsed ^. #cdnEnabled @?= True
        lookup "nagare:enableCdn" (seedKeys enabled) @?= Just "true"
        lookup "nagare:cdnApex" (seedKeys enabled) @?= Just "false"
        lookup "nagare:enableCdn" (seedKeys initProfile) @?= Nothing
        lookup "nagare:cdnApex" (seedKeys initProfile) @?= Nothing
    , testCase "init summary shows both buckets and the effective GCS URL" $ do
        let out = renderInitSummary "labs" (initProfile & #pulumiBackend .~ PulumiBackendGcs)
        assertBool "heading" (T.isInfixOf "Derived names for context 'labs':" out)
        assertBool "image bucket" (T.isInfixOf "acme-prod-nagare-images" out)
        assertBool "backup bucket" (T.isInfixOf "acme-prod-nagare-backups" out)
        assertBool "default GCS URL" (T.isInfixOf "gs://acme-prod-nagare-pulumi-state/nagare/labs" out)
    , testCase "init tool requirements match the enabled phases" $ do
        requiredInitTools defaultInitOpts PulumiBackendLocal @?= ["gcloud", "pulumi", "npm"]
        requiredInitTools
          ( defaultInitOpts
              & #skipPreflight
              .~ True
              & #skipEnable
              .~ True
              & #skipSeed
              .~ True
          )
          PulumiBackendLocal
          @?= []
        requiredInitTools
          (defaultInitOpts & #skipPreflight .~ True & #skipEnable .~ True)
          PulumiBackendGcs
          @?= ["gcloud", "pulumi", "npm"]
    , testCase "missing Pulumi is reported instead of throwing" $ do
        withSystemTempDirectory "nagare-empty-path" $ \emptyPath -> do
          oldPath <- lookupEnv "PATH"
          let restorePath = maybe (unsetEnv "PATH") (setEnv "PATH") oldPath
          result <-
            ( do
                setEnv "PATH" emptyPath
                findMissingTools ["pulumi"] >>= (@?= ["pulumi"])
                seedPulumiConfig "/tmp/unused" False "labs" initProfile
            )
              `finally` restorePath
          result @?= Left ("gcp:project", ExitFailure 127)
    , testCase "pulumiConfigSetArgs targets the active context stack" $
        pulumiConfigSetArgs "/payload/infra/pulumi" "labs" "gcp:project" "acme-prod"
          @?= ["-C", "/payload/infra/pulumi", "config", "set", "--stack", "labs", "gcp:project", "acme-prod"]
    , testCase "pulumiEnvFor derives a per-context LOCAL backend, home, and stack" $
        pulumiEnvFor "/tmp/nagare-state" "labs" initProfile
          @?= PulumiEnv
            { home = "/tmp/nagare-state/labs/home"
            , backendUrl = "file:///tmp/nagare-state/labs/state"
            , stack = "labs"
            , kind = PulumiBackendLocal
            }
    , testCase "renderTargetEnv emits the Pulumi backend fields (default local, EP-93)" $ do
        let out = renderTargetEnv initProfile
        assertBool "backend kind (default local)" (T.isInfixOf "export NAGARE_PULUMI_BACKEND=local" out)
        assertBool "backend url (empty by default)" (T.isInfixOf "export NAGARE_PULUMI_BACKEND_URL=" out)
    , testCase "parsePulumiBackendKind: only 'gcs' selects GCS; unset/typo is local" $ do
        parsePulumiBackendKind (Just "gcs") @?= PulumiBackendGcs
        parsePulumiBackendKind (Just "GCS") @?= PulumiBackendGcs
        parsePulumiBackendKind (Just "local") @?= PulumiBackendLocal
        parsePulumiBackendKind (Just "gcss") @?= PulumiBackendLocal
        parsePulumiBackendKind Nothing @?= PulumiBackendLocal
    , testCase "defaultGcsPulumiBackendUrl uses the state bucket + context path" $
        defaultGcsPulumiBackendUrl "labs" initProfile
          @?= "gs://acme-prod-nagare-pulumi-state/nagare/labs"
    , testCase "pulumiEnvFor derives a GCS backend URL when kind=gcs and no explicit URL" $
        pulumiEnvFor "/tmp/nagare-state" "labs" (initProfile & #pulumiBackend .~ PulumiBackendGcs)
          @?= PulumiEnv
            { home = "/tmp/nagare-state/labs/home"
            , backendUrl = "gs://acme-prod-nagare-pulumi-state/nagare/labs"
            , stack = "labs"
            , kind = PulumiBackendGcs
            }
    , testCase "pulumiEnvFor honors an explicit GCS backend URL" $
        (^. #backendUrl)
          ( pulumiEnvFor
              "/tmp/nagare-state"
              "labs"
              ( initProfile
                  & #pulumiBackend
                  .~ PulumiBackendGcs
                  & #pulumiBackendUrl
                  .~ "gs://custom-bucket/state/labs"
              )
          )
          @?= "gs://custom-bucket/state/labs"
    , testCase "a local-mode context can never use GCS (downgraded to local)" $ do
        let localGcs = initProfile & #mode .~ Local & #pulumiBackend .~ PulumiBackendGcs
        effectivePulumiBackend localGcs @?= PulumiBackendLocal
        pulumiEnvFor "/tmp/nagare-state" "labs" localGcs ^. #kind @?= PulumiBackendLocal
        assertBool
          "local-mode gcs falls back to a file:// backend"
          (T.isPrefixOf "file://" (pulumiEnvFor "/tmp/nagare-state" "labs" localGcs ^. #backendUrl))
    , testCase "profileFromContextMap parses NAGARE_PULUMI_BACKEND + URL (EP-93)" $ do
        let ctx =
              parseContextEnv $
                T.unlines
                  [ "export CLOUDSDK_CORE_PROJECT=acme-prod"
                  , "export NAGARE_MODE=cloud"
                  , "export NAGARE_PULUMI_BACKEND=gcs"
                  , "export NAGARE_PULUMI_BACKEND_URL=gs://acme-prod-nagare-pulumi-state/nagare/prod"
                  ]
            tp = profileFromContextMap ctx
        tp ^. #pulumiBackend @?= PulumiBackendGcs
        tp ^. #pulumiBackendUrl @?= "gs://acme-prod-nagare-pulumi-state/nagare/prod"
    , testCase "inventory store selection is explicit and local mode downgrades GCS" $ do
        parseInventoryStoreKind Nothing @?= InventoryStoreLocal
        parseInventoryStoreKind (Just "gcs") @?= InventoryStoreGcs
        let cloud = (initProfile :: TargetProfile) {inventoryStore = InventoryStoreGcs}
            local = cloud {mode = Local}
        effectiveInventoryStore cloud @?= InventoryStoreGcs
        effectiveInventoryStore local @?= InventoryStoreLocal
        defaultGcsInventoryStoreUrl "labs" cloud
          @?= "gs://acme-prod-nagare-pulumi-state/nagare/labs/inventory"
    , -- EP-113: the launcher has no .envrc, so `nagarectl context env` must emit
      -- the whole contract, Pulumi selection included, safely quoted.
      testCase "renderContextShellEnv emits the local backend's per-context file URL" $ do
        let name = either (error . T.unpack) id (mkContextName "labs")
            penv = pulumiEnvFor "/tmp/nagare-state" "labs" initProfile
            out = renderContextShellEnv name initProfile penv
        assertBool "context" (T.isInfixOf "export NAGARE_CONTEXT='labs'\n" out)
        assertBool "project" (T.isInfixOf "export CLOUDSDK_CORE_PROJECT='acme-prod'\n" out)
        assertBool "cache enabled flag" (T.isInfixOf "export NAGARE_NIX_CACHE_ENABLED='0'\n" out)
        assertBool
          "local backend url"
          (T.isInfixOf "export PULUMI_BACKEND_URL='file:///tmp/nagare-state/labs/state'\n" out)
        assertBool "pulumi home" (T.isInfixOf "export PULUMI_HOME='/tmp/nagare-state/labs/home'\n" out)
        assertBool "stack" (T.isInfixOf "export NAGARE_PULUMI_STACK='labs'\n" out)
        assertBool "no empty passphrase export" (not (T.isInfixOf "export PULUMI_CONFIG_PASSPHRASE=" out))
        assertBool
          "empty passphrase unset"
          (T.isInfixOf "[ -n \"${PULUMI_CONFIG_PASSPHRASE:-}\" ] || unset PULUMI_CONFIG_PASSPHRASE\n" out)
        assertBool
          "passphrase file"
          (T.isInfixOf "export PULUMI_CONFIG_PASSPHRASE_FILE='/tmp/nagare-state/labs/home/passphrase'\n" out)
    , testCase "renderContextShellEnv emits the gcs backend's remote URL" $ do
        let name = either (error . T.unpack) id (mkContextName "labs")
            gcsProfile = initProfile & #pulumiBackend .~ PulumiBackendGcs
            penv = pulumiEnvFor "/tmp/nagare-state" "labs" gcsProfile
            out = renderContextShellEnv name gcsProfile penv
        assertBool
          "gcs backend url"
          (T.isInfixOf "export PULUMI_BACKEND_URL='gs://acme-prod-nagare-pulumi-state/nagare/labs'\n" out)
        -- PULUMI_HOME stays the per-context LOCAL home even for a remote backend.
        assertBool "pulumi home" (T.isInfixOf "export PULUMI_HOME='/tmp/nagare-state/labs/home'\n" out)
    , testCase "renderContextShellEnv round-trips a value containing a single quote" $ do
        let name = either (error . T.unpack) id (mkContextName "labs")
            odd' = initProfile & #baseDomain .~ "it's.example.com"
            penv = pulumiEnvFor "/tmp/nagare-state" "labs" odd'
            out = renderContextShellEnv name odd' penv
        got <-
          readProcess
            "bash"
            ["-c", T.unpack out <> "\nprintf '%s' \"$NAGARE_BASE_DOMAIN\""]
            ""
        got @?= "it's.example.com"
    , testCase "renderTargetEnv emits the ACME identity fields (EP-112)" $ do
        let out = renderTargetEnv initProfile
        assertBool "acme contact" (T.isInfixOf "export NAGARE_ACME_EMAIL=ops@acme.example" out)
        assertBool "acme directory (default production)" (T.isInfixOf "export NAGARE_ACME_DIRECTORY=production" out)
    , testCase "renderTargetEnv emits an EMPTY ACME contact rather than inventing one" $ do
        -- The absence of a contact must round-trip as an empty value: a context
        -- written without one has no contact, and the renderer refuses. No
        -- default may appear here.
        let out = renderTargetEnv (initProfile & #acmeEmail .~ "")
        assertBool "empty contact line" (T.isInfixOf "export NAGARE_ACME_EMAIL=\n" out)
    , testCase "profileFromContextMap reads the ACME fields from a context (EP-112)" $ do
        let ctx =
              parseContextEnv
                (T.unlines ["export NAGARE_ACME_EMAIL=ops@acme.example", "export NAGARE_ACME_DIRECTORY=staging"])
            tp = profileFromContextMap ctx
        tp ^. #acmeEmail @?= "ops@acme.example"
        tp ^. #acmeDirectory @?= "staging"
    , testCase "profileFromContextMap defaults the endpoint to production and the contact to empty" $ do
        let tp = profileFromContextMap (parseContextEnv "export CLOUDSDK_CORE_PROJECT=acme-prod\n")
        tp ^. #acmeEmail @?= ""
        tp ^. #acmeDirectory @?= "production"
    , testCase "cloud TLS preference persists in the context profile" $ do
        let disabled = profileFromContextMap (parseContextEnv "export CLOUDSDK_CORE_PROJECT=acme-prod\n")
            enabled =
              profileFromContextMap
                ( parseContextEnv
                    "export CLOUDSDK_CORE_PROJECT=acme-prod\nexport NAGARE_EXTERNAL_DOMAIN_TLS_ENABLED=1\n"
                )
        disabled ^. #externalDomainTlsEnabled @?= False
        enabled ^. #externalDomainTlsEnabled @?= True
        assertBool
          "enabled preference missing from persisted profile"
          (T.isInfixOf "export NAGARE_EXTERNAL_DOMAIN_TLS_ENABLED=1\n" (renderTargetEnv enabled))
    , testCase "parseAcmeDirectory: an unrecognized token is an ERROR, not a fallback" $ do
        parseAcmeDirectory "" @?= Right AcmeProduction
        parseAcmeDirectory "production" @?= Right AcmeProduction
        parseAcmeDirectory "staging" @?= Right AcmeStaging
        parseAcmeDirectory "STAGING" @?= Right AcmeStaging
        parseAcmeDirectory "https://acme.example/directory" @?= Right (AcmeCustom "https://acme.example/directory")
        assertBool "typo rejected" (isLeft (parseAcmeDirectory "stagingg"))
        -- Plain http is not an ACME directory URL: the account key would travel
        -- in the clear.
        assertBool "bare http rejected" (isLeft (parseAcmeDirectory "http://acme.example/directory"))
    , testCase "acmeDirectoryUrl produces the two Let's Encrypt endpoints verbatim" $ do
        acmeDirectoryUrl AcmeProduction @?= "https://acme-v02.api.letsencrypt.org/directory"
        acmeDirectoryUrl AcmeStaging @?= "https://acme-staging-v02.api.letsencrypt.org/directory"
        acmeDirectoryUrl (AcmeCustom "https://acme.example/d") @?= "https://acme.example/d"
    , testCase "validateAcmeEmail accepts one usable address and rejects the rest" $ do
        validateAcmeEmail "ops@acme.example" @?= Right "ops@acme.example"
        assertBool "empty rejected" (isLeft (validateAcmeEmail ""))
        assertBool "no domain rejected" (isLeft (validateAcmeEmail "ops"))
        assertBool "undotted domain rejected" (isLeft (validateAcmeEmail "ops@acme"))
        assertBool "multi-address rejected" (isLeft (validateAcmeEmail "a@b.c,d@e.f"))
        assertBool "embedded space rejected" (isLeft (validateAcmeEmail "ops @acme.example"))
        assertBool "two at-signs rejected" (isLeft (validateAcmeEmail "a@b@c.example"))
    , testCase "operatorRoles includes serviceUsageAdmin for the enable step" $
        assertBool "serviceUsageAdmin" ("roles/serviceusage.serviceUsageAdmin" `elem` operatorRoles)
    , testCase "nextStepsText matches source and installed payloads" $ do
        let source = nextStepsText SourceRoot
            installed = nextStepsText InstalledRoot
        assertBool "source infra-up" (T.isInfixOf "just infra-up" source)
        assertBool "source host-image" (T.isInfixOf "just host-image" source)
        assertBool "installed infra-up" (T.isInfixOf "nagare infra-up" installed)
        assertBool "installed host-image" (T.isInfixOf "nagare host-image" installed)
        assertBool "installed has no just command" (not (T.isInfixOf "just " installed))
        assertBool "installed has no masterplan pointer" (not (T.isInfixOf "masterplans" installed))
    ]

defaultInitOpts :: InitOpts
defaultInitOpts =
  InitOpts
    { contextName = Just "labs"
    , project = Nothing
    , region = Nothing
    , zone = Nothing
    , baseDomain = Nothing
    , externalDomainTlsEnabled = Nothing
    , machineType = Nothing
    , bootDiskType = Nothing
    , bootDiskSizeGb = Nothing
    , dataDiskSizeGb = Nothing
    , nixCacheEnabled = Nothing
    , cdnEnabled = Nothing
    , nixCacheBucket = Nothing
    , pulumiBackend = Nothing
    , pulumiBackendUrl = Nothing
    , inventoryStore = Nothing
    , inventoryStoreUrl = Nothing
    , pulumiBackendMember = Nothing
    , acmeEmail = Nothing
    , acmeDirectory = Nothing
    , force = False
    , skipPreflight = False
    , skipEnable = False
    , skipSeed = False
    , dryRun = False
    }
