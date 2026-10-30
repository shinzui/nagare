-- | Static responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Static
  ( prepareTests
  , previewTests
  , releaseTests
  , staticImageTests
  )
where

import Data.Aeson (eitherDecodeStrict, encode)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef (modifyIORef, newIORef, readIORef)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Dsl.Static.Render (renderNginxConfig)
import Nagare.Static.Build
  ( PreparedStaticOutput (PreparedStaticOutput)
  , StaticBuildError
    ( BuildCommandFailed
    , OutputDirectoryMissing
    , ProjectRootMissing
    )
  , prepareStaticOutput
  )
import Nagare.Static.ContentDigest (digestContextTree)
import Nagare.Static.Image (staticDockerfile)
import Nagare.Static.Package
  ( PackageError (..)
  , PackageResult (..)
  , PackageTarget (..)
  , packageStaticSiteWith
  , runLogged
  )
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
import Nagare.Test.StaticPublish (publishTests)
import Nagare.Test.Support.Assertions
  ( assertInfix
  , assertInfixStr
  , assertLeftText
  )
import Nagare.Test.Support.Release (release, t1, t2, t3, tAt)
import Nagare.Test.Support.Site (buildSite, noBuildSite)
import System.Directory (createDirectoryIfMissing, doesPathExist, listDirectory)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (createSymbolicLink, setFileMode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit
  ( assertBool
  , assertFailure
  , testCase
  , (@?=)
  )

-- ---------------------------------------------------------------------------
-- Dockerfile

-- | The Dockerfile tests, with the packaging tests as their own named group.
staticImageTests :: TestTree
staticImageTests =
  testGroup
    "Nagare.Static.Image"
    (dockerfileTests <> [testGroup "Nagare.Static.Package" packageTests, testGroup "Nagare.Static.Publish" publishTests])

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
  , testCase "previewServiceName accepts a 63-character Service name" $
      previewServiceName "notes" (T.replicate 54 "a") @?= Right ("notes-pr-" <> T.replicate 54 "a")
  , testCase "previewServiceName refuses a 64-character Service name instead of cutting it" $
      previewServiceName "notes" (T.replicate 55 "a")
        @?= Left ("preview name too long: \"notes-pr-" <> T.replicate 55 "a" <> "\" is 64 characters, max 63 (at most 54 characters for site notes)")
  , testCase "previewServiceName refuses every preview of a 59-character site" $
      assertLeftText (previewServiceName (T.replicate 59 "s") "x")
  , testCase "previewDomain derives <preview>.<site>.preview.<base>" $
      previewDomain "notes" "feature-x" "apps.example.com"
        @?= Right "feature-x.notes.preview.apps.example.com"
  ]

-- ---------------------------------------------------------------------------
-- Packaging

-- | A prepared output with spaces, nesting and a dotfile.
withExample :: (FilePath -> PreparedStaticOutput -> IO a) -> IO a
withExample action = withSystemTempDirectory "nagare-package" $ \root -> do
  let out = root </> "public"
  createDirectoryIfMissing True (out </> "docs" </> "a b")
  BS.writeFile (out </> "index.html") "<h1>one</h1>"
  BS.writeFile (out </> ".well-known") "dot"
  BS.writeFile (out </> "docs" </> "a b" </> "page 2.html") "nested"
  action root (PreparedStaticOutput out)

archiveTarget :: FilePath -> PackageTarget
archiveTarget path = archiveTargetWith path "v1" "linux/arm64"

archiveTargetWith :: FilePath -> Text -> Text -> PackageTarget
archiveTargetWith path t p =
  ArchiveOut
    { archive = path
    , destination = "registry.example/notes:v1"
    , tag = t
    , platform = p
    }

packageTests :: [TestTree]
packageTests =
  [ testCase "context output matches the generators and the copied tree byte for byte" $
      withExample $ \root prepared -> do
        let site = noBuildSite "public"
            dest = root </> "out" </> "ctx"
        result <- packageStaticSiteWith (\_ -> pure True) site prepared (ContextOut dest)
        digest' <- either (assertFailure . show) (pure . (^. #digest)) result
        BS.readFile (dest </> "Dockerfile") >>= (@?= staticDockerfile)
        BS.readFile (dest </> "nginx.conf") >>= (@?= renderNginxConfig site)
        BS.readFile (dest </> "site" </> "index.html") >>= (@?= "<h1>one</h1>")
        BS.readFile (dest </> "site" </> ".well-known") >>= (@?= "dot")
        BS.readFile (dest </> "site" </> "docs" </> "a b" </> "page 2.html") >>= (@?= "nested")
        digestContextTree dest >>= (@?= digest')
  , testCase "content digest is stable, and one changed byte or mode changes it" $
      withExample $ \root prepared -> do
        let site = noBuildSite "public"
            digestOf name = do
              r <- packageStaticSiteWith (\_ -> pure True) site prepared (ContextOut (root </> name))
              either (assertFailure . show) (pure . (^. #digest)) r
        a <- digestOf "a"
        b <- digestOf "b"
        a @?= b
        BS.writeFile (root </> "public" </> "index.html") "<h1>two</h1>"
        c <- digestOf "c"
        assertBool "changed byte kept the digest" (a /= c)
        setFileMode (root </> "public" </> "index.html") 0o755
        d <- digestOf "d"
        assertBool "changed mode kept the digest" (c /= d)
  , testCase "a symlink is refused naming the path and leaves no destination" $
      withExample $ \root prepared -> do
        createSymbolicLink "index.html" (root </> "public" </> "link.html")
        let dest = root </> "ctx"
        result <- packageStaticSiteWith (\_ -> pure True) (noBuildSite "public") prepared (ContextOut dest)
        case result of
          Left (PackageContext _) -> pure ()
          other -> assertFailure ("expected a refused symlink, got: " <> show other)
        doesPathExist dest >>= (@?= False)
        leftovers <- listDirectory root
        assertBool "staging directory left behind" (all (not . ("." `isPrefixOf'`)) leftovers)
  , testCase "an existing destination and a destination inside the source are refused" $
      withExample $ \root prepared -> do
        createDirectoryIfMissing True (root </> "taken")
        taken <- packageStaticSiteWith (\_ -> pure True) (noBuildSite "public") prepared (ContextOut (root </> "taken"))
        either (const (pure ())) (const (assertFailure "existing destination was replaced")) taken
        inside <- packageStaticSiteWith (\_ -> pure True) (noBuildSite "public") prepared (ContextOut (root </> "public" </> "ctx"))
        either (const (pure ())) (const (assertFailure "destination inside the source was accepted")) inside
  , testCase "archive build uses the layer cache on the requested platform" $
      withExample $ \root prepared -> do
        calls <- newIORef []
        let fake args = do
              modifyIORef calls (args :)
              case args of
                ["image", "save", "--output", out, _] -> BS.writeFile out "fake-archive"
                _ -> pure ()
              pure True
            archivePath = root </> "artifacts" </> "site.tar"
        result <- packageStaticSiteWith fake (noBuildSite "public") prepared (archiveTarget archivePath)
        case result of
          Right r -> do
            r ^. #tag @?= Just "v1"
            r ^. #platform @?= Just "linux/arm64"
          Left e -> assertFailure (show e)
        BS.readFile archivePath >>= (@?= "fake-archive")
        recorded <- reverse <$> readIORef calls
        case recorded of
          (build : _) -> do
            assertBool "static build disabled the layer cache" ("--no-cache" `notElem` build)
            assertBool "platform missing" (["--platform", "linux/arm64"] `isInfixOf'` build)
          [] -> assertFailure "docker was never called"
        leftovers <- listDirectory (root </> "artifacts")
        leftovers @?= ["site.tar"]
  , testCase "invalid tag, unsupported platform and existing archive stop before Docker" $
      withExample $ \root prepared -> do
        calls <- newIORef (0 :: Int)
        let fake _ = modifyIORef calls (+ 1) >> pure True
            go target = packageStaticSiteWith fake (noBuildSite "public") prepared target
        badTag <- go (archiveTargetWith (root </> "a.tar") "-bad" "linux/arm64")
        either (const (pure ())) (const (assertFailure "bad tag accepted")) badTag
        badPlatform <- go (archiveTargetWith (root </> "b.tar") "v1" "linux/riscv64")
        either (const (pure ())) (const (assertFailure "bad platform accepted")) badPlatform
        BS.writeFile (root </> "c.tar") "keep"
        existing <- go (archiveTarget (root </> "c.tar"))
        existing @?= Left (PackageArchiveExists (root </> "c.tar"))
        BS.readFile (root </> "c.tar") >>= (@?= "keep")
        readIORef calls >>= (@?= 0)
  , testCase "one build log serves two consecutive runs (the build and the save)" $
      withSystemTempDirectory "nagare-log" $ \dir -> do
        let logFile = dir </> "build.log"
        ok1 <- runLogged "sh" (Just logFile) ["-c", "echo build; echo build-err >&2"]
        ok2 <- runLogged "sh" (Just logFile) ["-c", "echo save"]
        (ok1, ok2) @?= (True, True)
        written <- BS.readFile logFile
        written @?= "build\nbuild-err\nsave\n"
        failed <- runLogged "sh" (Just logFile) ["-c", "exit 3"]
        failed @?= False
  , testCase "a failed save leaves no partial archive and keeps a pre-existing one" $
      withExample $ \root prepared -> do
        let failingSave args = case args of
              ["image", "save", "--output", out, _] -> BS.writeFile out "half" >> pure False
              _ -> pure True
            archivePath = root </> "site.tar"
        result <- packageStaticSiteWith failingSave (noBuildSite "public") prepared (archiveTarget archivePath)
        either (const (pure ())) (const (assertFailure "failed save reported success")) result
        listDirectory root >>= \names -> assertBool "partial artifact left" (all (`notElem` ["site.tar"]) names && not (any (".partial" `isInfixOf'`) names))
  ]
  where
    isPrefixOf' p s = take (length p) s == p
    isInfixOf' needle hay = any (\i -> take (length needle) (drop i hay) == needle) [0 .. length hay]
