-- | Static responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Static
  ( dockerfileTests
  , prepareTests
  , previewTests
  , releaseTests
  )
where

import Data.Aeson (eitherDecodeStrict, encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Static.Build
  ( PreparedStaticOutput (PreparedStaticOutput)
  , StaticBuildError
    ( BuildCommandFailed
    , OutputDirectoryMissing
    , ProjectRootMissing
    )
  , prepareStaticOutput
  )
import Nagare.Static.Image (staticDockerfile)
import Nagare.Static.Preview
  ( normalizePreviewName
  , previewDomain
  , previewServiceName
  )
import Nagare.Static.Release
  ( addRelease
  , configMapName
  , decodeReleaseLogRead
  , emptyReleaseLog
  , extractReleaseLog
  , findRelease
  , historyCap
  , renderReleaseConfigMap
  )
import Nagare.Test.Support.Assertions
  ( assertInfix
  , assertInfixStr
  , assertLeftText
  )
import Nagare.Test.Support.Release (release, t1, t2, t3, tAt)
import Nagare.Test.Support.Site (buildSite, noBuildSite)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit
  ( assertBool
  , assertFailure
  , testCase
  , (@?=)
  )

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

-- ---------------------------------------------------------------------------
-- Release log

releaseTests :: [TestTree]
releaseTests =
  [ testCase "StaticReleaseLog JSON round-trips" $ do
      let logv = addRelease (release "20260101-000000" t1) emptyReleaseLog
          encoded = LBS.toStrict (encode logv)
      case eitherDecodeStrict encoded of
        Right back -> back @?= logv
        Left e -> assertFailure ("decode failed: " <> e)
  , testCase "addRelease puts newest first and marks it current" $ do
      let logv =
            addRelease (release "b" t2) $
              addRelease (release "a" t1) emptyReleaseLog
      logv ^. #current @?= Just "b"
      map (^. #releaseId) (logv ^. #releases) @?= ["b", "a"]
  , testCase "addRelease dedupes a re-deployed id (no duplicate, becomes current)" $ do
      let logv =
            addRelease (release "a" t3) $
              addRelease (release "b" t2) $
                addRelease (release "a" t1) emptyReleaseLog
      map (^. #releaseId) (logv ^. #releases) @?= ["a", "b"]
      logv ^. #current @?= Just "a"
  , testCase "addRelease caps history at historyCap" $ do
      let many' = foldr (\i l -> addRelease (release (T.pack (show i)) (tAt i)) l) emptyReleaseLog [1 .. historyCap + 10 :: Int]
      length (many' ^. #releases) @?= historyCap
  , testCase "findRelease finds a recorded release" $ do
      let logv = addRelease (release "a" t1) emptyReleaseLog
      fmap (^. #releaseId) (findRelease "a" logv) @?= Just "a"
      findRelease "missing" logv @?= Nothing
  , testCase "extractReleaseLog reads the ConfigMap data key" $ do
      let logv = addRelease (release "a" t1) emptyReleaseLog
          cm = renderReleaseConfigMap "notes" "personal" logv
      case extractReleaseLog cm of
        Right back -> back @?= logv
        Left e -> assertFailure ("extract failed: " <> T.unpack e)
  , testCase "extractReleaseLog refuses an existing ConfigMap with no data" $
      case extractReleaseLog "{\"apiVersion\":\"v1\",\"kind\":\"ConfigMap\",\"metadata\":{}}" of
        Right _ -> assertFailure "malformed ConfigMap replaced the history with an empty log"
        Left _ -> pure ()
  , testCase "extractReleaseLog refuses an incomplete existing history" $
      case extractReleaseLog "{\"data\":{\"releases.json\":\"{}\"}}" of
        Right _ -> assertFailure "missing history fields were treated as an empty log"
        Left _ -> pure ()
  , testCase "release history read distinguishes absence from provider failure" $ do
      decodeReleaseLogRead ExitSuccess "" @?= Right emptyReleaseLog
      let existing =
            renderReleaseConfigMap
              "notes"
              "personal"
              (addRelease (release "a" t1) emptyReleaseLog)
      case decodeReleaseLogRead (ExitFailure 1) existing of
        Left _ -> pure ()
        Right _ -> assertFailure "failed ConfigMap read replaced the history with an empty log"
      case decodeReleaseLogRead ExitSuccess existing of
        Right logv -> logv ^. #current @?= Just "a"
        Left err -> assertFailure (T.unpack err)
  , testCase "configMapName is prefixed per site" $
      configMapName "notes" @?= "nagare-static-releases-notes"
  ]

-- ---------------------------------------------------------------------------
-- Preview naming

previewTests :: [TestTree]
previewTests =
  [ testCase "normalizePreviewName lowercases and hyphenates" $
      normalizePreviewName "Feature/PR #12" @?= Right "feature-pr-12"
  , testCase "normalizePreviewName trims and collapses hyphens" $
      normalizePreviewName "--a__b--" @?= Right "a-b"
  , testCase "normalizePreviewName rejects all-punctuation" $
      assertLeftText (normalizePreviewName "@@@")
  , testCase "previewServiceName derives <site>-pr-<name>" $
      previewServiceName "notes" "feature-x" @?= Right "notes-pr-feature-x"
  , testCase "previewServiceName clips to 63 chars without trailing hyphen" $
      case previewServiceName "notes" (T.replicate 80 "a") of
        Right n -> do
          assertBool "<= 63 chars" (T.length n <= 63)
          assertBool "no trailing hyphen" (T.last n /= '-')
        Left e -> assertFailure ("expected Right, got: " <> T.unpack e)
  , testCase "previewDomain derives <preview>.<site>.preview.<base>" $
      previewDomain "notes" "feature-x" "apps.example.com"
        @?= Right "feature-x.notes.preview.apps.example.com"
  ]
