{-# LANGUAGE OverloadedStrings #-}

module PlatformSpec (platformTests) where

import Control.Exception (bracket, finally)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (traverse_)
import Data.Text qualified as T
import Nagare.Platform.Paths
import Nagare.Platform.Status
import Nagare.Platform.Workspace
import Nagare.Target (mkContextName)
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
    ]

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
    "{\"assetSchemaVersion\":1,\"payloadId\":\"test-payload\",\"platformVersion\":\"0.1.0\",\"sourceRevision\":null}"
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
