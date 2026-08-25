{-# LANGUAGE OverloadedStrings #-}

module PlatformSpec (platformTests) where

import Control.Exception (bracket, finally)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (traverse_)
import Data.IORef
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Platform.Paths
import Nagare.Platform.Status
import Nagare.Platform.Upgrade
import Nagare.Platform.Workspace
import Nagare.Target (contextFilePath, mkContextName, readContextProfile, tpPlatformVersion, writeContextPlatformVersion)
import Nagare.Version (BuildVersion (..), Compatibility (..))
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , getCurrentDirectory
  , setCurrentDirectory
  )
import System.FilePath (takeDirectory, (</>))
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

platformTests :: TestTree
platformTests =
  testGroup
    "Nagare.Platform (EP-106)"
    [ testCase "an explicit valid root resolves every absolute platform path" $
        withFixture $ \root -> do
          result <- resolvePlatformPaths (Just root)
          paths <- either (assertFailure . show) pure result
          ppRootSource paths @?= ExplicitRoot
          ppPulumiDir paths @?= root </> "infra" </> "pulumi"
          ppJustfile paths @?= root </> "justfile"
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
          ppRootSource paths @?= SourceRoot
          ppRoot paths @?= root
    , testCase "workspace preparation is idempotent and content-addressed" $
        withFixture $ \root -> withSystemTempDirectory "nagare-platform-state" $ \stateRoot -> do
          paths <- validatePlatformRoot ExplicitRoot root >>= either (assertFailure . show) pure
          context <- either (assertFailure . T.unpack) pure (mkContextName "prod")
          first <- preparePlatformWorkspace stateRoot context paths >>= either (assertFailure . show) pure
          second <- preparePlatformWorkspace stateRoot context paths >>= either (assertFailure . show) pure
          pwRoot second @?= pwRoot first
          pwDigest second @?= pwDigest first
          leaked <- doesFileExist (pwPulumiDir first </> "Pulumi.prod.yaml")
          assertBool "generated source stack config is excluded" (not leaked)
          BS.appendFile (root </> "justfile") "\n# changed\n"
          changed <- preparePlatformWorkspace stateRoot context paths >>= either (assertFailure . show) pure
          assertBool "changed payload gets a distinct workspace" (pwRoot changed /= pwRoot first)
    , testCase "two contexts never share a mutable workspace" $
        withFixture $ \root -> withSystemTempDirectory "nagare-platform-state" $ \stateRoot -> do
          paths <- validatePlatformRoot ExplicitRoot root >>= either (assertFailure . show) pure
          prod <- either (assertFailure . T.unpack) pure (mkContextName "prod")
          staging <- either (assertFailure . T.unpack) pure (mkContextName "staging")
          prodWorkspace <- preparePlatformWorkspace stateRoot prod paths >>= either (assertFailure . show) pure
          stagingWorkspace <- preparePlatformWorkspace stateRoot staging paths >>= either (assertFailure . show) pure
          assertBool "context workspace roots differ" (pwRoot prodWorkspace /= pwRoot stagingWorkspace)
    , testCase "platform status compares all five identities and fails closed on major skew" $ do
        let cli = identityFromBuild (BuildVersion "1.2.3" (Just "cli-rev"))
            payload = ReleaseIdentity (Just "1.2.3") (Just "payload-rev") (Just 1)
            context = ReleaseIdentity (Just "1.2.3") Nothing Nothing
            host = parseHostIdentity "# Nagare platform version: 1.2.3\n# Nagare source revision: payload-rev\n"
            clusterBytes = LBS.toStrict (Aeson.encode (clusterMarkerValue payload "2026-08-25T19:00:00Z"))
            cluster = maybe (error "cluster marker did not parse") id (parseClusterIdentity clusterBytes)
            exact = assessPlatformStatus cli payload context host cluster
            incompatible = assessPlatformStatus cli payload context host (ReleaseIdentity (Just "2.0.0") Nothing (Just 1))
        statusCompatibility exact @?= Exact
        guardPlatformMutation exact @?= Right ()
        statusCompatibility incompatible @?= MajorIncompatible
        assertBool "major skew blocks mutation" (either (const True) (const False) (guardPlatformMutation incompatible))
    , testCase "missing host and cluster identities remain a non-blocking legacy warning" $ do
        let release = ReleaseIdentity (Just "1.2.3") Nothing (Just 1)
            unknown = ReleaseIdentity Nothing Nothing Nothing
            status = assessPlatformStatus release release release unknown unknown
        statusCompatibility status @?= LegacyUnknown
        guardPlatformMutation status @?= Right ()
    , testCase "status and legacy adoption distinguish exact, patch, major, and absent observations" $ do
        let exactIdentity = ReleaseIdentity (Just "1.2.3") Nothing (Just 1)
            legacyIdentity = ReleaseIdentity Nothing Nothing Nothing
            exact = assessPlatformStatus exactIdentity exactIdentity exactIdentity exactIdentity exactIdentity
            patch = assessPlatformStatus exactIdentity exactIdentity (ReleaseIdentity (Just "1.2.4") Nothing Nothing) exactIdentity exactIdentity
            major = assessPlatformStatus exactIdentity exactIdentity exactIdentity exactIdentity (ReleaseIdentity (Just "2.0.0") Nothing Nothing)
            absent = assessPlatformStatus exactIdentity exactIdentity legacyIdentity exactIdentity legacyIdentity
        statusCompatibility exact @?= Exact
        statusCompatibility patch @?= PatchSkew
        statusCompatibility major @?= MajorIncompatible
        statusCompatibility absent @?= LegacyUnknown
        validatePlatformAdoption "1.2.3" absent @?= Right ()
        assertBool "known patch skew cannot be hidden by adoption" (either (const True) (const False) (validatePlatformAdoption "1.2.3" (absent {statusCli = ReleaseIdentity (Just "1.2.4") Nothing Nothing})))
        assertBool "an already versioned context must upgrade" (either (const True) (const False) (validatePlatformAdoption "1.2.3" exact))
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
            tpPlatformVersion prodProfile @?= Just "1.1.0"
            tpPlatformVersion labsProfile @?= Just "1.2.0"
    , testCase "upgrade planning and apply persist every phase in order" $ do
        events <- newIORef []
        saved <- newIORef Nothing
        let tx = newUpgradeTransaction "tx-1" "labs" (Just "0.1.0") "0.2.0" "payload" "digest" "/workspace" "/host" False "2026-08-25T19:00:00Z"
            ops = fixtureUpgradeOps events saved (const (pure (Right "ok"))) (const (pure False))
        planned <- planUpgrade ops tx >>= either (assertFailure . T.unpack) pure
        transactionState planned @?= Planned
        applied <- applyUpgrade False ops planned >>= either (assertFailure . T.unpack) pure
        transactionState applied @?= Completed
        observed <- readIORef events
        observed @?= previewPhases <> applyPhases
        assertBool "context commit is final" (last (transactionPhases applied) == PhaseRecord ContextCommit Succeeded (Just "ok") (Just fixtureNow))
        (Aeson.eitherDecode (Aeson.encode applied) :: Either String UpgradeTransaction) @?= Right applied
        reapplied <- applyUpgrade True ops applied >>= either (assertFailure . T.unpack) pure
        reapplied @?= applied
        readIORef events >>= (@?= observed)
    , testCase "failed apply preserves the old commit point and resume rechecks succeeded phases" $ do
        events <- newIORef []
        saved <- newIORef Nothing
        failHost <- newIORef True
        let run phase = do
              shouldFail <- readIORef failHost
              pure (if shouldFail && phase == HostApply then Left "host unavailable" else Right "ok")
            satisfied phase = pure (phase == PulumiApply)
            tx = newUpgradeTransaction "tx-2" "labs" (Just "0.1.0") "0.2.0" "payload" "digest" "/workspace" "/host" False fixtureNow
            ops = fixtureUpgradeOps events saved run satisfied
        planned <- planUpgrade ops tx >>= either (assertFailure . T.unpack) pure
        failed <- applyUpgrade False ops planned
        assertBool "first apply fails" (either (const True) (const False) failed)
        Just persisted <- readIORef saved
        transactionState persisted @?= TransactionFailed
        observedAfterFailure <- readIORef events
        assertBool "context commit did not run" (ContextCommit `notElem` observedAfterFailure)
        writeIORef failHost False
        resumed <- applyUpgrade True ops persisted >>= either (assertFailure . T.unpack) pure
        transactionState resumed @?= Completed
        assertBool "context commit ran after recovery" (phaseState (last (transactionPhases resumed)) == Succeeded)
    , testCase "failure at every apply phase leaves a resumable old-context commit point" $
        traverse_ checkFailure applyPhases
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
          ops = fixtureUpgradeOps events saved run (const (pure False))
      planned <- planUpgrade ops tx >>= either (assertFailure . T.unpack) pure
      applyUpgrade False ops planned >>= assertBool ("expected failure at " <> show failingPhase) . either (const True) (const False)
      Just persisted <- readIORef saved
      transactionState persisted @?= TransactionFailed
      let contextRecord = last (transactionPhases persisted)
      whenBeforeContext failingPhase $ phaseState contextRecord @?= Pending
      writeIORef failing False
      resumed <- applyUpgrade True ops persisted >>= either (assertFailure . T.unpack) pure
      transactionState resumed @?= Completed
      phaseState (last (transactionPhases resumed)) @?= Succeeded
    whenBeforeContext phase assertion = if phase == ContextCommit then pure () else assertion

fixtureNow :: T.Text
fixtureNow = "2026-08-25T19:00:00Z"

fixtureUpgradeOps :: IORef [UpgradePhase] -> IORef (Maybe UpgradeTransaction) -> (UpgradePhase -> IO (Either T.Text T.Text)) -> (UpgradePhase -> IO Bool) -> UpgradeOps
fixtureUpgradeOps events saved run satisfied =
  UpgradeOps
    { runUpgradePhase = \phase -> modifyIORef' events (<> [phase]) >> run phase
    , upgradePhaseSatisfied = satisfied
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
    "{\"assetSchemaVersion\":1,\"payloadId\":\"test-payload\",\"platformVersion\":\"0.1.0\",\"sourceRevision\":null,\"rollbackSupportedFrom\":[]}"
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
