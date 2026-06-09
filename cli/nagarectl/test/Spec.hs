-- | Tests for nagarectl's static-site helpers (EP-14).
--
-- The CLI proper (load → render → build → push → apply → wait) is validated
-- behaviourally by @nagarectl site deploy --dry-run@ against
-- @cluster/examples/static-site@; the renderer goldens live in
-- @nagare-dsl-test@ (EP-13). These unit tests cover the pure/helper logic that
-- is awkward to exercise through the dry-run: the generated Dockerfile and the
-- build/output-preparation state machine.
module Main (main) where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Static.Types
import Nagare.Dsl.Types (mkImageRef, mkNamespace)
import Nagare.Static.Build
import Nagare.Static.Image (staticDockerfile)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

main :: IO ()
main =
  defaultMain $
    testGroup
      "nagarectl"
      [ testGroup "Nagare.Static.Image" dockerfileTests
      , testGroup "Nagare.Static.Build" prepareTests
      ]

-- ---------------------------------------------------------------------------
-- Dockerfile

dockerfileTests :: [TestTree]
dockerfileTests =
  [ testCase "staticDockerfile uses the nginx base and 8080 layout" $ do
      let df = staticDockerfile
      assertInfix "FROM nginx:1.27-alpine" df
      assertInfix "COPY nginx.conf /etc/nginx/conf.d/default.conf" df
      assertInfix "COPY site/ /usr/share/nginx/html/" df
      assertInfix "EXPOSE 8080" df
  ]

assertInfix :: ByteString -> ByteString -> Assertion
assertInfix needle hay
  | needle `BC.isInfixOf` hay = pure ()
  | otherwise =
      assertFailure ("expected " <> show needle <> " in:\n" <> BC.unpack hay)

-- ---------------------------------------------------------------------------
-- prepareStaticOutput

prepareTests :: [TestTree]
prepareTests =
  [ testCase "NoBuild + existing dir + skipBuild returns the resolved output dir" $
      withSystemTempDirectory "nagare-prep" $ \root -> do
        createDirectoryIfMissing True (root </> "public")
        result <- prepareStaticOutput True (noBuildSite "public") root
        case result of
          Right (PreparedStaticOutput out) -> assertInfixStr "public" out
          other -> assertFailure ("expected Right, got: " <> show other)
  , testCase "NoBuild + missing dir returns OutputDirectoryMissing" $
      withSystemTempDirectory "nagare-prep" $ \root -> do
        result <- prepareStaticOutput True (noBuildSite "dist") root
        case result of
          Left (OutputDirectoryMissing _) -> pure ()
          other -> assertFailure ("expected OutputDirectoryMissing, got: " <> show other)
  , testCase "missing project root returns ProjectRootMissing" $ do
      result <- prepareStaticOutput True (noBuildSite "public") "/no/such/root"
      case result of
        Left (ProjectRootMissing _) -> pure ()
        other -> assertFailure ("expected ProjectRootMissing, got: " <> show other)
  , testCase "BuildCommand that produces the output dir succeeds" $
      withSystemTempDirectory "nagare-prep" $ \root -> do
        result <- prepareStaticOutput False (buildSite "mkdir -p out" "out") root
        case result of
          Right (PreparedStaticOutput out) -> assertInfixStr "out" out
          other -> assertFailure ("expected Right, got: " <> show other)
  , testCase "BuildCommand that exits non-zero returns BuildCommandFailed" $
      withSystemTempDirectory "nagare-prep" $ \root -> do
        result <- prepareStaticOutput False (buildSite "exit 3" "out") root
        case result of
          Left (BuildCommandFailed _ 3) -> pure ()
          other -> assertFailure ("expected BuildCommandFailed _ 3, got: " <> show other)
  ]

assertInfixStr :: String -> FilePath -> Assertion
assertInfixStr needle hay
  | T.pack needle `T.isInfixOf` T.pack hay = pure ()
  | otherwise = assertFailure ("expected " <> show needle <> " in path: " <> hay)

-- ---------------------------------------------------------------------------
-- Fixtures

noBuildSite :: Text -> StaticSite
noBuildSite dir = baseSite (NoBuild (unsafe (mkFilePathText dir)))

buildSite :: Text -> Text -> StaticSite
buildSite command outDir =
  baseSite
    ( BuildCommand
        { command = command
        , outputDirectory = unsafe (mkFilePathText outDir)
        }
    )

baseSite :: StaticBuild -> StaticSite
baseSite b =
  StaticSite
    { name = unsafe (mkSiteName "demo")
    , namespace = unsafe (mkNamespace "personal")
    , image = unsafe (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/demo")
    , build = b
    , domains = []
    , redirects = []
    , headers = []
    , cache = defaultCachePolicy
    , notFound = Nothing
    }

unsafe :: Either Text a -> a
unsafe (Right a) = a
unsafe (Left e) = error ("test fixture invalid: " <> T.unpack e)
