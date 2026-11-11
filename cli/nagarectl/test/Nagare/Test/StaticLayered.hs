-- | EP-252: a static site archive without a Docker daemon. The archive is a
-- pure function of the pinned base and the context; a base that is not the
-- pin is refused before anything is written; and the default builder is the
-- daemon only when one answers.
module Nagare.Test.StaticLayered
  ( staticLayeredTests
  )
where

import Codec.Archive.Tar qualified as Tar
import Codec.Archive.Tar.Entry qualified as Tar
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef
import Data.Text qualified as T
import Nagare.Dsl.Path (mkFilePathText)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Static.Types (StaticBuild (NoBuild))
import Nagare.Static.Build (PreparedStaticOutput (..))
import Nagare.Static.Image (BasePin (..))
import Nagare.Static.Layered
import Nagare.Static.Package (ArchiveBuilder (..), PackageError (..), PackageTarget (..), packageStaticSiteWith)
import Nagare.Test.Support.Site (baseSite)
import System.Directory (createDirectoryIfMissing)
import System.Environment (setEnv, unsetEnv)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

staticLayeredTests :: TestTree
staticLayeredTests =
  testGroup
    "layered builder"
    [ testCase "the same base and context give the same archive bytes, with fixed metadata" $ do
        base <- either (assertFailure . T.unpack) pure (readBaseArchive pin baseArchive)
        let files = [ContextFile "usr/share/nginx/html/index.html" "<h1>one</h1>", ContextFile "etc/nginx/conf.d/default.conf" "server {}", ContextFile "usr/share/nginx/html/docs/a b/page.html" "nested"]
        first' <- either (assertFailure . T.unpack) pure (layeredArchive "registry.example/notes:v1" base files)
        second' <- either (assertFailure . T.unpack) pure (layeredArchive "registry.example/notes:v1" base (reverse files))
        first' @?= second'
        let outer = entries first'
            names = map Tar.entryPath outer
        assertBool "the base layer comes first" (take 1 names == ["base/layer.tar"])
        assertBool "a manifest" ("manifest.json" `elem` names)
        layer <- case [content | entry <- outer, "/layer.tar" `T.isSuffixOf` T.pack (Tar.entryPath entry), Tar.entryPath entry /= "base/layer.tar", Tar.NormalFile content _ <- [Tar.entryContent entry]] of
          [one] -> pure one
          other -> assertFailure ("expected one new layer, found " <> show (length other))
        let inner = entries layer
        map Tar.entryPath inner
          @?= ["etc/", "etc/nginx/", "etc/nginx/conf.d/", "usr/", "usr/share/", "usr/share/nginx/", "usr/share/nginx/html/", "usr/share/nginx/html/docs/", "usr/share/nginx/html/docs/a b/", "etc/nginx/conf.d/default.conf", "usr/share/nginx/html/docs/a b/page.html", "usr/share/nginx/html/index.html"]
        forM_' inner $ \entry -> do
          Tar.entryTime entry @?= 0
          Tar.ownerId (Tar.entryOwnership entry) @?= 0
          Tar.groupId (Tar.entryOwnership entry) @?= 0
        let config = [content | entry <- outer, ".json" `T.isSuffixOf` T.pack (Tar.entryPath entry), Tar.entryPath entry /= "manifest.json", Tar.NormalFile content _ <- [Tar.entryContent entry]]
        case config of
          [bytes] -> do
            assertBool "port 8080" ("8080/tcp" `BS.isInfixOf` LBS.toStrict bytes)
            assertBool "a fixed creation time" ("1970-01-01T00:00:00Z" `BS.isInfixOf` LBS.toStrict bytes)
            assertBool "the base entrypoint stays" ("/docker-entrypoint.sh" `BS.isInfixOf` LBS.toStrict bytes)
          other -> assertFailure ("expected one image config, found " <> show (length other))
    , testCase "a base that is not the pinned config is refused" $
        assertBool "mismatch" (isLeft (readBaseArchive (pin & #configDigest .~ "sha256:0000") baseArchive))
    , testCase "a cache entry whose bytes no longer match the pin is refused before use" $
        withSystemTempDirectory "ep252-cache" $ \cache -> do
          setEnv "XDG_CACHE_HOME" cache
          path <- baseCachePath pin
          createDirectoryIfMissing True (takeDirectory path)
          LBS.writeFile path (LBS.take 512 baseArchive)
          refused <- acquireBase pin "docker.io/library/nginx:1.27-alpine@sha256:x" Nothing
          unsetEnv "XDG_CACHE_HOME"
          assertBool "a truncated cache entry" (isLeft refused)
          LBS.writeFile path baseArchive
          setEnv "XDG_CACHE_HOME" cache
          accepted <- acquireBase pin "docker.io/library/nginx:1.27-alpine@sha256:x" Nothing
          unsetEnv "XDG_CACHE_HOME"
          assertBool "the matching cache entry" (not (isLeft accepted))
    , testCase "without --builder, a daemon that answers builds with Docker, and no daemon selects the layered builder" $
        withSystemTempDirectory "ep252-auto" $ \root -> do
          createDirectoryIfMissing True (root </> "public")
          BS.writeFile (root </> "public" </> "index.html") "<h1>one</h1>"
          LBS.writeFile (root </> "base.tar") baseArchive
          let target name = ArchiveOut (root </> name) "registry.example/notes:v1" "v1" "linux/arm64" (AutoBuilder (Just (root </> "base.tar")))
              site = baseSite (NoBuild (either (error . T.unpack) id (mkFilePathText "public")))
              prepared = PreparedStaticOutput (root </> "public")
          calls <- newIORef []
          let daemon answers args = do
                modifyIORef calls (args :)
                case args of
                  ["info", _, _] -> pure answers
                  ["image", "save", "--output", out, _] -> BS.writeFile out "fake-archive" >> pure True
                  _ -> pure True
          withDaemon <- packageStaticSiteWith (daemon True) site prepared (target "docker.tar")
          assertBool "Docker built it" (either (const False) (const True) withDaemon)
          readIORef calls >>= \seen -> assertBool "docker build ran" (any (\call -> take 1 call == ["build"] || take 2 call == ["buildx", "build"]) seen)
          writeIORef calls []
          withoutDaemon <- packageStaticSiteWith (daemon False) site prepared (target "layered.tar")
          case withoutDaemon of
            Left (PackageBuildFailed reason) -> assertBool (T.unpack reason) ("pinned" `T.isInfixOf` reason)
            other -> assertFailure ("the layered builder was not selected: " <> show other)
          readIORef calls >>= \seen -> assertBool "no docker build ran" (all (\call -> take 1 call == ["info"]) seen)
    , testCase "an explicit base archive is read and verified, never fetched" $
        withSystemTempDirectory "ep252-base" $ \directory -> do
          let file = directory </> "base.tar"
          LBS.writeFile file baseArchive
          acquireBase pin "unused" (Just file) >>= assertBool "accepted" . not . isLeft
          acquireBase (pin & #configDigest .~ "sha256:00") "unused" (Just file) >>= assertBool "refused" . isLeft
    ]
  where
    forM_' xs f = mapM_ f xs
    entries bytes = Tar.foldEntries (:) [] (error . show) (Tar.read bytes)
    pin = BasePin "linux/arm64" "sha256:manifest" ("sha256:" <> T.pack (show (hash baseConfig :: Digest SHA256)))

-- | A one-layer base shaped like the pinned Nginx image's archive.
baseConfig :: BS.ByteString
baseConfig =
  LBS.toStrict
    ( encode
        ( object
            [ "architecture" .= ("arm64" :: Text)
            , "os" .= ("linux" :: Text)
            , "config" .= object ["Entrypoint" .= ["/docker-entrypoint.sh" :: Text], "Cmd" .= ["nginx", "-g", "daemon off;" :: Text], "ExposedPorts" .= object ["80/tcp" .= object []]]
            , "rootfs" .= object ["type" .= ("layers" :: Text), "diff_ids" .= ["sha256:base" :: Text]]
            , "history" .= [object ["created_by" .= ("base" :: Text)]]
            ]
        )
    )

baseArchive :: LBS.ByteString
baseArchive =
  Tar.write
    [ file "base/layer.tar" (Tar.write [file "etc/nginx/nginx.conf" "events {}"])
    , file "config.json" (LBS.fromStrict baseConfig)
    , file "manifest.json" (encode [object ["Config" .= ("config.json" :: Text), "RepoTags" .= ([] :: [Text]), "Layers" .= ["base/layer.tar" :: Text]]])
    ]
  where
    file name content = either error (`Tar.fileEntry` content) (Tar.toTarPath False name)
