{-# LANGUAGE OverloadedStrings #-}

module PlatformSpec (platformTests) where

import Control.Exception (bracket, finally)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Dsl.Prelude
import Nagare.Infra.Plan (SavedPlanMetadata (..))
import Nagare.Init (resolveInitBase)
import Nagare.Platform.Deployment
import Nagare.Platform.Paths
import Nagare.Platform.PulumiReceipt
import Nagare.Platform.StackConfig
import Nagare.Platform.Status
import Nagare.Platform.Upgrade
import Nagare.Platform.Workspace
import Nagare.Target (contextFilePath, mergeContextOverrides, mkContextName, profileFromContextMap, readContextProfile, resolveActiveTarget, setCurrentContext, writeContextPlatformVersion)
import Nagare.Version (BuildVersion (..), Compatibility (..))
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , getCurrentDirectory
  , getSymbolicLinkTarget
  , pathIsSymbolicLink
  , removeFile
  , setCurrentDirectory
  )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

platformTests :: TestTree
platformTests =
  testGroup
    "Nagare.Platform (EP-106)"
    [ stackConfigTests
    , testCase "named init base ignores the active context and ambient target variables" $
        withSystemTempDirectory "nagare-init-base" $ \root ->
          withTemporaryEnv "XDG_CONFIG_HOME" (root </> "config") $
            withTemporaryEnv "NAGARE_CONTEXT" "other" $
              withTemporaryEnv "NAGARE_IMAGE_BUCKET" "env-nagare-images" $ do
                other <- either (assertFailure . T.unpack) pure (mkContextName "other")
                fresh <- either (assertFailure . T.unpack) pure (mkContextName "fresh")
                path <- contextFilePath other
                createDirectoryIfMissing True (takeDirectory path)
                let stored = Map.fromList [("CLOUDSDK_CORE_PROJECT", "other"), ("NAGARE_IMAGE_BUCKET", "other-nagare-images")]
                TIO.writeFile path "export CLOUDSDK_CORE_PROJECT=other\nexport NAGARE_IMAGE_BUCKET=other-nagare-images\n"
                setCurrentContext other
                resolveInitBase fresh False >>= (@?= Right Nothing)
                result <- resolveInitBase other False
                assertBool "existing context refused without --force" (either (T.isInfixOf "already exists") (const False) result)
                resolveInitBase other True >>= (@?= Right (Just stored))
    , testCase "EP-121: a forced context create changes only the fields it was given" $ do
        let stored =
              Map.fromList
                [ ("CLOUDSDK_CORE_PROJECT", "labs-project")
                , ("NAGARE_BASE_DOMAIN", "labs.example.org")
                , ("NAGARE_BOOT_DISK_TYPE", "pd-standard")
                , ("NAGARE_DATA_DISK_SIZE_GB", "110")
                , ("NAGARE_ACME_DIRECTORY", "production")
                , ("NAGARE_PLATFORM_VERSION", "0.2.0")
                ]
            merged = mergeContextOverrides (Just stored) [("NAGARE_ACME_DIRECTORY", "staging")] "0.2.1"
            tp = profileFromContextMap merged
        merged @?= Map.insert "NAGARE_ACME_DIRECTORY" "staging" stored
        tp ^. #baseDomain @?= "labs.example.org"
        tp ^. #project @?= "labs-project"
        tp ^. #bootDiskType @?= "pd-standard"
        tp ^. #platformVersion @?= Just "0.2.0"
    , testCase "EP-121: a new context is stamped with the payload version" $
        Map.lookup "NAGARE_PLATFORM_VERSION" (mergeContextOverrides Nothing [("CLOUDSDK_CORE_PROJECT", "p")] "0.2.1") @?= Just "0.2.1"
    , testCase "platform status can read persisted release intent without ambient version overrides" $
        withSystemTempDirectory "nagare-platform-context-version" $ \root ->
          withTemporaryEnv "XDG_CONFIG_HOME" (root </> "config") $
            withTemporaryEnv "NAGARE_PLATFORM_VERSION" "0.3.0" $ do
              labs <- either (assertFailure . T.unpack) pure (mkContextName "labs")
              path <- contextFilePath labs
              createDirectoryIfMissing True (takeDirectory path)
              TIO.writeFile path "export CLOUDSDK_CORE_PROJECT=labs\nexport NAGARE_PLATFORM_VERSION=0.4.0\n"
              active <- resolveActiveTarget (Just "labs")
              active ^. #profile . #platformVersion @?= Just "0.4.0"
    , testCase "EP-121: host identity is read from the indented comments a generated flake carries" $ do
        let flake =
              T.unlines
                [ "{"
                , "  description = \"Nagare host tan-nb-exp\";"
                , ""
                , "  # Generated by nagarectl 0.1.0; EP-108 updates only this input."
                , "  # Nagare platform version: 0.1.0"
                , "  # Nagare source revision: 2ffd98a1c6f35ab07fb9e04f0ea4cf131656aabb"
                , "  inputs.nagare.url = \"path:/nix/store/example/share/nagare/nixos\";"
                , "}"
                ]
            identity = parseHostIdentity flake
        identity ^. #version @?= Just "0.1.0"
        identity ^. #revision @?= Just "2ffd98a1c6f35ab07fb9e04f0ea4cf131656aabb"
    , testCase "an explicit valid root resolves every absolute platform path" $
        withFixture $ \root -> do
          result <- resolvePlatformPaths (Just root)
          paths <- either (assertFailure . show) pure result
          paths ^. #rootSource @?= ExplicitRoot
          paths ^. #pulumiDir @?= root </> "infra" </> "pulumi"
          paths ^. #justfile @?= root </> "justfile"
    , testCase "an explicit lookalike root fails and names missing assets" $
        withSystemTempDirectory "nagare-platform-lookalike" $ \root -> do
          BS.writeFile (root </> "justfile") ""
          result <- resolvePlatformPaths (Just root)
          case result of
            Left (InvalidPlatformRoot ExplicitRoot _ missing) ->
              assertBool "release manifest is reported" ("release.json" `elem` missing)
            other -> assertFailure ("expected invalid explicit root, got " <> show other)
    , testCase "source fallback walks to a validated ancestor, not a lookalike cwd" $
        withFixture $ \root -> do
          let nested = root </> "tmp" </> "deep"
          createDirectoryIfMissing True nested
          original <- getCurrentDirectory
          result <- withClearedEnv "NAGARE_PLATFORM_ROOT" ((setCurrentDirectory nested >> resolvePlatformPaths Nothing) `finally` setCurrentDirectory original)
          paths <- either (assertFailure . show) pure result
          paths ^. #rootSource @?= SourceRoot
          paths ^. #root @?= root
    , testCase "workspace preparation is idempotent and content-addressed" $
        withFixture $ \root -> withSystemTempDirectory "nagare-platform-state" $ \stateRoot -> do
          paths <- validatePlatformRoot ExplicitRoot root >>= either (assertFailure . show) pure
          context <- either (assertFailure . T.unpack) pure (mkContextName "prod")
          first <- preparePlatformWorkspace stateRoot context paths >>= either (assertFailure . show) pure
          second <- preparePlatformWorkspace stateRoot context paths >>= either (assertFailure . show) pure
          second ^. #root @?= first ^. #root
          second ^. #digest @?= first ^. #digest
          dslPackage <- doesFileExist (first ^. #root </> "cli" </> "nagare-dsl" </> "nagare-dsl.cabal")
          accessPackage <- doesFileExist (first ^. #root </> "cli" </> "nagare-access" </> "nagare-access.cabal")
          assertBool "the writable workspace contains the typed-config package" dslPackage
          assertBool "the writable workspace contains the access service package" accessPackage
          leaked <- doesFileExist (first ^. #pulumiDir </> "Pulumi.prod.yaml")
          assertBool "generated source stack config is excluded" (not leaked)
          BS.appendFile (root </> "justfile") "\n# changed\n"
          changed <- preparePlatformWorkspace stateRoot context paths >>= either (assertFailure . show) pure
          assertBool "changed payload gets a distinct workspace" (changed ^. #root /= first ^. #root)
    , testCase "two contexts never share a mutable workspace" $
        withFixture $ \root -> withSystemTempDirectory "nagare-platform-state" $ \stateRoot -> do
          paths <- validatePlatformRoot ExplicitRoot root >>= either (assertFailure . show) pure
          prod <- either (assertFailure . T.unpack) pure (mkContextName "prod")
          staging <- either (assertFailure . T.unpack) pure (mkContextName "staging")
          prodWorkspace <- preparePlatformWorkspace stateRoot prod paths >>= either (assertFailure . show) pure
          stagingWorkspace <- preparePlatformWorkspace stateRoot staging paths >>= either (assertFailure . show) pure
          assertBool "context workspace roots differ" (prodWorkspace ^. #root /= stagingWorkspace ^. #root)
    , testCase "platform status compares all five identities and fails closed on major skew" $ do
        let cli = identityFromBuild (BuildVersion "1.2.3" (Just "cli-rev"))
            payload = ReleaseIdentity (Just "1.2.3") (Just "payload-rev") (Just 1)
            context = ReleaseIdentity (Just "1.2.3") Nothing Nothing
            host = parseHostIdentity "# Nagare platform version: 1.2.3\n# Nagare source revision: payload-rev\n"
            clusterBytes = LBS.toStrict (Aeson.encode (clusterMarkerValue payload "2026-08-25T19:00:00Z"))
            cluster = fromMaybe (error "cluster marker did not parse") (parseClusterIdentity clusterBytes)
            exact = assessPlatformStatus cli payload context host Deployed cluster Deployed
            incompatible = assessPlatformStatus cli payload context host Deployed (ReleaseIdentity (Just "2.0.0") Nothing (Just 1)) Deployed
        exact ^. #compatibility @?= Exact
        guardPlatformMutation exact @?= Right ()
        incompatible ^. #compatibility @?= MajorIncompatible
        assertBool "major skew blocks mutation" (either (const True) (const False) (guardPlatformMutation incompatible))
    , testCase "missing host and cluster identities remain a non-blocking legacy warning" $ do
        let release = ReleaseIdentity (Just "1.2.3") Nothing (Just 1)
            unknown = ReleaseIdentity Nothing Nothing Nothing
            status = assessPlatformStatus release release release unknown (DeploymentUnknown "host identity unavailable") unknown (DeploymentUnknown "cluster identity unavailable")
        status ^. #compatibility @?= LegacyUnknown
        guardPlatformMutation status @?= Right ()
    , testCase "status and legacy adoption distinguish exact, patch, major, and absent observations" $ do
        let exactIdentity = ReleaseIdentity (Just "1.2.3") Nothing (Just 1)
            legacyIdentity = ReleaseIdentity Nothing Nothing Nothing
            exact = assessPlatformStatus exactIdentity exactIdentity exactIdentity exactIdentity Deployed exactIdentity Deployed
            patch = assessPlatformStatus exactIdentity exactIdentity (ReleaseIdentity (Just "1.2.4") Nothing Nothing) exactIdentity Deployed exactIdentity Deployed
            major = assessPlatformStatus exactIdentity exactIdentity exactIdentity exactIdentity Deployed (ReleaseIdentity (Just "2.0.0") Nothing Nothing) Deployed
            absent = assessPlatformStatus exactIdentity exactIdentity legacyIdentity exactIdentity Deployed legacyIdentity (DeploymentUnknown "unreachable")
        exact ^. #compatibility @?= Exact
        patch ^. #compatibility @?= PatchSkew
        major ^. #compatibility @?= MajorIncompatible
        absent ^. #compatibility @?= LegacyUnknown
        validatePlatformAdoption "1.2.3" absent @?= Right ()
        assertBool
          "known patch skew cannot be hidden by adoption"
          (either (const True) (const False) (validatePlatformAdoption "1.2.3" (absent & #cli .~ ReleaseIdentity (Just "1.2.4") Nothing Nothing)))
        assertBool "an already versioned context must upgrade" (either (const True) (const False) (validatePlatformAdoption "1.2.3" exact))
    , testCase "confirmed-absent resources do not hide a patch-behind context" $ do
        let current = ReleaseIdentity (Just "1.2.3") Nothing (Just 1)
            pinned = ReleaseIdentity (Just "1.2.2") Nothing Nothing
            unknown = ReleaseIdentity Nothing Nothing Nothing
            status = assessPlatformStatus current current pinned unknown NotDeployed unknown NotDeployed
        status ^. #compatibility @?= PatchSkew
        validatePlatformRepin "1.2.3" status @?= Right ()
        assertBool
          "deployed host refuses re-pin"
          (either (const True) (const False) (validatePlatformRepin "1.2.3" (status & #hostDeployment .~ Deployed)))
        assertBool
          "unknown host refuses re-pin"
          (either (const True) (const False) (validatePlatformRepin "1.2.3" (status & #hostDeployment .~ DeploymentUnknown "permission denied")))
        assertBool "human host state" ("Host:       not deployed" `T.isInfixOf` renderPlatformStatus "labs" status)
        assertBool "human cluster state" ("Cluster:    not deployed" `T.isInfixOf` renderPlatformStatus "labs" status)
        case platformStatusValue status of
          Aeson.Object root -> case KeyMap.lookup "deployment" root of
            Just (Aeson.Object deployment) -> do
              deploymentState "host" deployment @?= Just (Aeson.String "not-deployed")
              deploymentState "cluster" deployment @?= Just (Aeson.String "not-deployed")
            other -> assertFailure ("missing deployment evidence: " <> show other)
          other -> assertFailure ("expected status object, got " <> show other)
    , testCase "existing unversioned and uncertain resources remain legacy unknown" $ do
        let current = ReleaseIdentity (Just "1.2.3") Nothing (Just 1)
            unknown = ReleaseIdentity Nothing Nothing Nothing
            existing = assessPlatformStatus current current current unknown Deployed unknown (DeploymentUnknown "unreachable")
            uncertain = assessPlatformStatus current current current unknown (DeploymentUnknown "permission denied") unknown (DeploymentUnknown "unreachable")
        existing ^. #compatibility @?= LegacyUnknown
        uncertain ^. #compatibility @?= LegacyUnknown
    , testCase "GCE describe classifies only an explicit not-found diagnostic as absence" $ do
        classifyHostDescribe ExitSuccess "{}" "" @?= Deployed
        classifyHostDescribe (ExitFailure 1) "" "ERROR: The resource was not found" @?= NotDeployed
        classifyHostDescribe ExitSuccess "not-json" "" @?= DeploymentUnknown "gcloud compute instances describe returned invalid JSON"
        case classifyHostDescribe (ExitFailure 1) "" "ERROR: permission denied" of
          DeploymentUnknown err -> assertBool "diagnostic retained" ("permission denied" `T.isInfixOf` err)
          other -> assertFailure ("lookup failure was misclassified: " <> show other)
        let unavailable = DeploymentOps (\_ _ _ -> pure (Left "gcloud unavailable"))
            cloudProfile = profileFromContextMap (Map.fromList [("CLOUDSDK_CORE_PROJECT", "acme-prod")])
        observed <- observeHostDeployment unavailable cloudProfile
        observed @?= DeploymentUnknown "gcloud unavailable"
    , testCase "adopting one of two contexts preserves the other context release" $
        withSystemTempDirectory "nagare-platform-contexts" $ \xdg ->
          withTemporaryEnv "XDG_CONFIG_HOME" xdg $ do
            prod <- either (assertFailure . T.unpack) pure (mkContextName "prod")
            labs <- either (assertFailure . T.unpack) pure (mkContextName "labs")
            prodPath <- contextFilePath prod
            labsPath <- contextFilePath labs
            createDirectoryIfMissing True (takeDirectory prodPath)
            TIO.writeFile prodPath "export CLOUDSDK_CORE_PROJECT=prod\nexport NAGARE_PLATFORM_VERSION=1.1.0\n"
            TIO.writeFile labsPath "export CLOUDSDK_CORE_PROJECT=labs\n"
            writeContextPlatformVersion labs "1.2.0" >>= either (assertFailure . T.unpack) pure
            prodProfile <- readContextProfile prod >>= either (assertFailure . T.unpack) pure
            labsProfile <- readContextProfile labs >>= either (assertFailure . T.unpack) pure
            prodProfile ^. #platformVersion @?= Just "1.1.0"
            labsProfile ^. #platformVersion @?= Just "1.2.0"
    , testCase "upgrade planning and apply persist every phase in order" $ do
        events <- newIORef []
        saved <- newIORef Nothing
        let tx = newUpgradeTransaction "tx-1" "labs" (Just "0.1.0") "0.2.0" "payload" "digest" "/workspace" "/host" False "2026-08-25T19:00:00Z"
            ops = fixtureUpgradeOps events saved (const (pure (Right "ok"))) (\_ _ -> pure RunPhase)
        planned <- planUpgrade ops tx >>= either (assertFailure . T.unpack) pure
        planned ^. #state @?= Planned
        applied <- applyUpgrade False ops planned >>= either (assertFailure . T.unpack) pure
        applied ^. #state @?= Completed
        observed <- readIORef events
        observed @?= previewPhases <> applyPhases
        assertBool "context commit is final" (last (applied ^. #phases) == PhaseRecord ContextCommit Succeeded (Just "ok") (Just fixtureNow))
        (Aeson.eitherDecode (Aeson.encode applied) :: Either String UpgradeTransaction) @?= Right applied
        reapplied <- applyUpgrade True ops applied >>= either (assertFailure . T.unpack) pure
        reapplied @?= applied
        readIORef events >>= (@?= observed)
    , testCase "resume can repair a pending phase from durable evidence without invoking it" $ do
        events <- newIORef []
        saved <- newIORef Nothing
        let tx = newUpgradeTransaction "tx-repair" "labs" (Just "0.1.0") "0.2.0" "payload" "digest" "/workspace" "/host" False fixtureNow
            decision PulumiApply Pending = pure (SkipPhase "verified success receipt")
            decision _ _ = pure RunPhase
            ops = fixtureUpgradeOps events saved (const (pure (Right "ok"))) decision
        planned <- planUpgrade ops tx >>= either (assertFailure . T.unpack) pure
        completed <- applyUpgrade True ops planned >>= either (assertFailure . T.unpack) pure
        completed ^. #state @?= Completed
        readIORef events >>= assertBool "Pulumi was not invoked" . (PulumiApply `notElem`)
        let repaired = filter ((== PulumiApply) . (^. #name)) (completed ^. #phases)
        repaired @?= [PhaseRecord PulumiApply Succeeded (Just "verified success receipt") (Just fixtureNow)]
    , testCase "resume refusal preserves a failed transaction without invoking the phase" $ do
        events <- newIORef []
        saved <- newIORef Nothing
        let tx = newUpgradeTransaction "tx-refuse" "labs" (Just "0.1.0") "0.2.0" "payload" "digest" "/workspace" "/host" False fixtureNow
            decision PulumiApply Pending = pure (RefusePhase "ambiguous provider outcome")
            decision _ _ = pure RunPhase
            ops = fixtureUpgradeOps events saved (const (pure (Right "ok"))) decision
        planned <- planUpgrade ops tx >>= either (assertFailure . T.unpack) pure
        refused <- applyUpgrade True ops planned
        assertBool "resume refused" (either (T.isInfixOf "ambiguous provider outcome") (const False) refused)
        Just persisted <- readIORef saved
        persisted ^. #state @?= TransactionFailed
        readIORef events >>= assertBool "Pulumi was not invoked" . (PulumiApply `notElem`)
    , testCase "Pulumi receipts round-trip, bind the plan, and enforce state transitions" $
        withSystemTempDirectory "nagare-pulumi-receipt" $ \root -> do
          let tx = newUpgradeTransaction "tx-receipt" "labs" (Just "0.1.0") "0.2.0" "payload" "payload-digest" "/workspace" "/host" False fixtureNow
              path = pulumiReceiptPath (root </> "tx-receipt.json") tx
          started <- writeStartedReceipt path tx fixturePlanMetadata fixtureNow >>= either (assertFailure . T.unpack) pure
          receiptState started @?= ReceiptStarted
          writeStartedReceipt path tx fixturePlanMetadata fixtureNow >>= assertBool "a second start is ambiguous" . either (const True) (const False)
          succeeded <- writeResultReceipt path tx fixturePlanMetadata ReceiptSucceeded fixtureNow >>= either (assertFailure . T.unpack) pure
          readVerifiedPulumiReceipt path tx fixturePlanMetadata >>= (@?= Right (Just succeeded))
          let staleMetadata = fixturePlanMetadata {planDigest = "other-plan"}
          readVerifiedPulumiReceipt path tx staleMetadata >>= assertBool "stale plan binding refused" . either (T.isInfixOf "planDigest") (const False)
          let foreignTransaction = tx & #id .~ "tx-foreign"
          readVerifiedPulumiReceipt path foreignTransaction fixturePlanMetadata >>= assertBool "foreign transaction binding refused" . either (T.isInfixOf "transactionId") (const False)
          writeRecoveryReceipt path tx fixturePlanMetadata RecoveryApplied fixtureNow >>= assertBool "automatic success cannot be overwritten" . either (const True) (const False)
    , testCase "Pulumi recovery is idempotent but conflicting outcomes and public modes refuse" $
        withSystemTempDirectory "nagare-pulumi-recovery" $ \root -> do
          let tx = newUpgradeTransaction "tx-recovery" "labs" (Just "0.1.0") "0.2.0" "payload" "payload-digest" "/workspace" "/host" False fixtureNow
              path = pulumiReceiptPath (root </> "tx-recovery.json") tx
          _ <- writeStartedReceipt path tx fixturePlanMetadata fixtureNow >>= either (assertFailure . T.unpack) pure
          recovered <- writeRecoveryReceipt path tx fixturePlanMetadata RecoveryApplied fixtureNow >>= either (assertFailure . T.unpack) pure
          writeRecoveryReceipt path tx fixturePlanMetadata RecoveryApplied fixtureNow >>= (@?= Right recovered)
          writeRecoveryReceipt path tx fixturePlanMetadata RecoveryRetry fixtureNow >>= assertBool "conflicting recovery refused" . either (const True) (const False)
          setFileMode path 0o644
          readPulumiReceipt path >>= assertBool "public receipt refused" . either (T.isInfixOf "group or other") (const False)
    , testCase "failed apply preserves the old commit point and resume rechecks succeeded phases" $ do
        events <- newIORef []
        saved <- newIORef Nothing
        failHost <- newIORef True
        let run phase = do
              shouldFail <- readIORef failHost
              pure (if shouldFail && phase == HostApply then Left "host unavailable" else Right "ok")
            satisfied phase _ = pure (if phase == PulumiApply then SkipPhase "verified receipt" else RunPhase)
            tx = newUpgradeTransaction "tx-2" "labs" (Just "0.1.0") "0.2.0" "payload" "digest" "/workspace" "/host" False fixtureNow
            ops = fixtureUpgradeOps events saved run satisfied
        planned <- planUpgrade ops tx >>= either (assertFailure . T.unpack) pure
        failed <- applyUpgrade False ops planned
        assertBool "first apply fails" (either (const True) (const False) failed)
        Just persisted <- readIORef saved
        persisted ^. #state @?= TransactionFailed
        observedAfterFailure <- readIORef events
        assertBool "context commit did not run" (ContextCommit `notElem` observedAfterFailure)
        writeIORef failHost False
        resumed <- applyUpgrade True ops persisted >>= either (assertFailure . T.unpack) pure
        resumed ^. #state @?= Completed
        assertBool "context commit ran after recovery" (last (resumed ^. #phases) ^. #state == Succeeded)
    , testCase "failure after Pulumi leaves a provider-free resumable old-context commit point" $
        traverse_ checkFailure [HostApply, KubernetesApply, ClusterStamp, ContextCommit]
    ]
  where
    checkFailure failingPhase = do
      events <- newIORef []
      saved <- newIORef Nothing
      failing <- newIORef True
      let run phase = do
            shouldFail <- readIORef failing
            pure (if shouldFail && phase == failingPhase then Left ("injected failure at " <> T.pack (show phase)) else Right "ok")
          tx = newUpgradeTransaction ("tx-" <> T.pack (show failingPhase)) "labs" (Just "0.1.0") "0.2.0" "payload" "digest" "/workspace" "/host" False fixtureNow
          decision PulumiApply Succeeded = pure (SkipPhase "verified success receipt")
          decision _ _ = pure RunPhase
          ops = fixtureUpgradeOps events saved run decision
      planned <- planUpgrade ops tx >>= either (assertFailure . T.unpack) pure
      applyUpgrade False ops planned >>= assertBool ("expected failure at " <> show failingPhase) . either (const True) (const False)
      Just persisted <- readIORef saved
      persisted ^. #state @?= TransactionFailed
      let contextRecord = last (persisted ^. #phases)
      whenBeforeContext failingPhase $ contextRecord ^. #state @?= Pending
      writeIORef failing False
      resumed <- applyUpgrade True ops persisted >>= either (assertFailure . T.unpack) pure
      resumed ^. #state @?= Completed
      last (resumed ^. #phases) ^. #state @?= Succeeded
      observed <- readIORef events
      length (filter (== PulumiApply) observed) @?= 1
    whenBeforeContext phase assertion = if phase == ContextCommit then pure () else assertion

fixtureNow :: T.Text
fixtureNow = "2026-08-25T19:00:00Z"

fixturePlanMetadata :: SavedPlanMetadata
fixturePlanMetadata =
  SavedPlanMetadata
    { metadataSchemaVersion = 1
    , context = "labs"
    , project = "labs-project"
    , stack = "labs"
    , backend = "file:///state"
    , payloadId = "payload"
    , payloadDigest = "payload-digest"
    , programDigest = "program-digest"
    , configDigest = "config-digest"
    , pulumiVersion = "v3.255.0"
    , createdAt = fixtureNow
    , planDigest = "plan-digest"
    , reviewDigest = "review-digest"
    }

deploymentState :: Key -> KeyMap.KeyMap Aeson.Value -> Maybe Aeson.Value
deploymentState key deployment = case KeyMap.lookup key deployment of
  Just (Aeson.Object evidence) -> KeyMap.lookup "state" evidence
  _ -> Nothing

fixtureUpgradeOps :: IORef [UpgradePhase] -> IORef (Maybe UpgradeTransaction) -> (UpgradePhase -> IO (Either T.Text T.Text)) -> (UpgradePhase -> PhaseState -> IO ResumeDecision) -> UpgradeOps
fixtureUpgradeOps events saved run decision =
  UpgradeOps
    { runUpgradePhase = \phase -> modifyIORef' events (<> [phase]) >> run phase
    , upgradeResumeDecision = decision
    , saveUpgradeTransaction = writeIORef saved . Just
    , upgradeNow = pure fixtureNow
    }

withFixture :: (FilePath -> IO a) -> IO a
withFixture action = withSystemTempDirectory "nagare-platform-fixture" $ \root -> do
  traverse_ (writeAsset root) requiredPlatformAssets
  traverse_
    (writeAsset root)
    [ "cluster/observability/kustomization.yaml"
    , "cluster/local/kustomization.yaml"
    , "scripts/enable-apis.sh"
    , "docs/user/extra.md"
    ]
  BS.writeFile
    (root </> "release.json")
    "{\"assetSchemaVersion\":1,\"payloadId\":\"test-payload\",\"platformVersion\":\"0.4.0\",\"sourceRevision\":null,\"rollbackSupportedFrom\":[]}"
  BS.writeFile (root </> "infra" </> "pulumi" </> "Pulumi.prod.yaml") "config:\n  secret: local-only\n"
  action root

writeAsset :: FilePath -> FilePath -> IO ()
writeAsset root relative = do
  createDirectoryIfMissing True (takeDirectory (root </> relative))
  BS.writeFile (root </> relative) (BS.pack [10])

withClearedEnv :: String -> IO a -> IO a
withClearedEnv name = bracket (lookupEnv name <* unsetEnv name) restore . const
  where
    restore Nothing = unsetEnv name
    restore (Just value) = setEnv name value

withTemporaryEnv :: String -> String -> IO a -> IO a
withTemporaryEnv name value = bracket (lookupEnv name <* setEnv name value) restore . const
  where
    restore Nothing = unsetEnv name
    restore (Just oldValue) = setEnv name oldValue

-- EP-121: the context-owned Pulumi stack config and the link every Pulumi
-- working directory makes to it.
stackConfigTests :: TestTree
stackConfigTests =
  testGroup
    "Nagare.Platform.StackConfig (EP-121)"
    [ testCase "an entry already reading the canonical file is left alone" $
        plan (CanonicalPresent "a") (EntryLinksTo canonical True) @?= AlreadyLinked
    , testCase "a missing entry is linked to an existing canonical file" $
        plan (CanonicalPresent "a") EntryAbsent @?= LinkOnly
    , testCase "an identical regular copy is replaced by the link" $
        plan (CanonicalPresent "a") (EntryRegular "a") @?= ReplaceWithLink
    , testCase "a pre-0.2.1 workspace copy is adopted when no canonical file exists" $
        plan CanonicalAbsent (EntryRegular "a") @?= AdoptThenLink
    , testCase "a fresh context gets an empty canonical file" $ do
        plan CanonicalAbsent EntryAbsent @?= CreateEmptyThenLink
        plan CanonicalAbsent (EntryLinksTo canonical True) @?= CreateEmptyThenLink
    , testCase "a differing regular copy is refused, naming both paths" $
        case plan (CanonicalPresent "a") (EntryRegular "b") of
          RefuseStackLink message -> do
            assertBool "entry named" (T.isInfixOf (T.pack entry) message)
            assertBool "canonical named" (T.isInfixOf (T.pack canonical) message)
          other -> assertFailure ("expected a refusal, got " <> show other)
    , testCase "a link to another file is refused" $ do
        assertBool "canonical present" (isRefusal (plan (CanonicalPresent "a") (EntryLinksTo "/elsewhere.yaml" False)))
        assertBool "canonical absent" (isRefusal (plan CanonicalAbsent (EntryLinksTo "/elsewhere.yaml" False)))
    , testCase "a dangling canonical link is refused instead of read as empty config" $
        case plan (CanonicalDangling "/ops/missing.yaml") EntryAbsent of
          RefuseStackLink message -> assertBool "target named" (T.isInfixOf "/ops/missing.yaml" message)
          other -> assertFailure ("expected a refusal, got " <> show other)
    , testCase "linking adopts a workspace copy, then keeps it linked and refuses a conflict" $
        withSystemTempDirectory "nagare-stack-config" $ \root ->
          withTemporaryEnv "XDG_CONFIG_HOME" (root </> "config") $ do
            name <- either (assertFailure . T.unpack) pure (mkContextName "labs")
            let pulumiDir = root </> "workspace" </> "infra" </> "pulumi"
                workspaceEntry = stackConfigEntryPath name pulumiDir
            createDirectoryIfMissing True pulumiDir
            BS.writeFile workspaceEntry "config:\n  nagare:nagareImageSelfLink: kept\n"
            linked <- linkContextStackConfig name pulumiDir
            stackPath <- contextStackConfigPath name
            linked @?= Right stackPath
            pathIsSymbolicLink workspaceEntry >>= assertBool "entry is a link"
            getSymbolicLinkTarget workspaceEntry >>= (@?= stackPath)
            BS.readFile stackPath >>= (@?= "config:\n  nagare:nagareImageSelfLink: kept\n")
            linkContextStackConfig name pulumiDir >>= (@?= Right stackPath)
            removeFile workspaceEntry
            BS.writeFile workspaceEntry "config: {}\n"
            conflict <- linkContextStackConfig name pulumiDir
            assertBool "conflict refused" (either (T.isInfixOf "differs") (const False) conflict)
            BS.readFile stackPath >>= (@?= "config:\n  nagare:nagareImageSelfLink: kept\n")
    ]
  where
    canonical = "/config/nagare/pulumi/Pulumi.labs.yaml"
    entry = "/workspace/infra/pulumi/Pulumi.labs.yaml"
    plan = planStackLink canonical entry
    isRefusal (RefuseStackLink _) = True
    isRefusal _ = False
