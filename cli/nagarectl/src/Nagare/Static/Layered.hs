-- | A static site image without a Docker daemon (EP-252): the digest-pinned
-- Nginx base plus one layer holding the generated server config and the site
-- files. Everything is a pure function of the base archive and the context,
-- with fixed times, owners and modes, so the same inputs give the same bytes.
module Nagare.Static.Layered
  ( BaseImage (..)
  , readBaseArchive
  , ContextFile (..)
  , readContextFiles
  , layeredArchive
  , baseCachePath
  , acquireBase
  )
where

import Codec.Archive.Tar qualified as Tar
import Codec.Archive.Tar.Entry qualified as Tar
import Control.Exception (IOException, try)
import Crypto.Hash (Digest, SHA256, hash, hashlazy)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.List (sort, sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Vector qualified as V
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Static.Image (BasePin (..))
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, renameFile)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (makeRelative, takeDirectory, (</>))
import System.Process (readProcessWithExitCode)

-- | A base image read from a Docker archive: its config bytes and its layers
-- in order, by their archive names.
data BaseImage = BaseImage
  { config :: !ByteString
  , layers :: ![(FilePath, LBS.ByteString)]
  }
  deriving stock (Eq, Show, Generic)

-- | Read a Docker archive of exactly the pinned base: its config must hash to
-- the platform's pinned config digest.
readBaseArchive :: BasePin -> LBS.ByteString -> Either Text BaseImage
readBaseArchive pin bytes = do
  entries <- first (const "the base archive is not a tar archive") (Tar.foldEntries (\entry rest -> (entry :) <$> rest) (Right []) (Left . show) (Tar.read bytes))
  let files = Map.fromList [(Tar.entryPath entry, content) | entry <- entries, Tar.NormalFile content _ <- [Tar.entryContent entry]]
  manifestBytes <- maybe (Left "the base archive has no manifest.json") Right (Map.lookup "manifest.json" files)
  (configName, layerNames) <- case eitherDecodeStrict' (LBS.toStrict manifestBytes) of
    Right (Array images) | [Object image] <- V.toList images -> do
      name <- case KM.lookup "Config" image of
        Just (String c) -> Right (T.unpack c)
        _ -> Left "the base manifest names no config"
      named <- case KM.lookup "Layers" image of
        Just (Array ls) -> traverse (\case String l -> Right (T.unpack l); _ -> Left "a base layer is not named") (V.toList ls)
        _ -> Left "the base manifest names no layers"
      Right (name, named)
    _ -> Left "the base archive must hold exactly one image"
  configBytes <- maybe (Left "the base archive lacks its config") (Right . LBS.toStrict) (Map.lookup configName files)
  unless ("sha256:" <> sha256Hex configBytes == pin ^. #configDigest) (Left ("the base archive is not the pinned " <> pin ^. #platform <> " base " <> pin ^. #configDigest))
  layerBytes <- traverse (\name -> maybe (Left ("the base archive lacks layer " <> T.pack name)) (Right . (name,)) (Map.lookup name files)) layerNames
  pure BaseImage {config = configBytes, layers = layerBytes}

sha256Hex :: ByteString -> Text
sha256Hex bytes = T.pack (show (hash bytes :: Digest SHA256))

-- | One file of the context, by its path inside the image.
data ContextFile = ContextFile
  { path :: !FilePath
  , bytes :: !ByteString
  }
  deriving stock (Eq, Show, Generic)

-- | The image files of a written context: the server config and the site.
readContextFiles :: FilePath -> IO (Either Text [ContextFile])
readContextFiles context = do
  loaded <- try $ do
    nginx <- BS.readFile (context </> "nginx.conf")
    site <- walk (context </> "site")
    pure (ContextFile "etc/nginx/conf.d/default.conf" nginx : [ContextFile ("usr/share/nginx/html" </> makeRelative (context </> "site") file) content | (file, content) <- site])
  pure (first (\(_ :: IOException) -> "the static context could not be read") loaded)
  where
    walk directory = do
      names <- sort <$> listDirectory directory
      fmap concat . forM' names $ \name -> do
        let full = directory </> name
        isDirectory <- doesDirectoryExist full
        if isDirectory then walk full else (\content -> [(full, content)]) <$> BS.readFile full
    forM' xs f = traverse f xs

-- | The image: the base layers, one layer of the context files, and the
-- base config with that layer, port 8080 and a fixed creation time.
layeredArchive :: Text -> BaseImage -> [ContextFile] -> Either Text LBS.ByteString
layeredArchive reference base files = do
  baseConfig <- case eitherDecodeStrict' (base ^. #config) of
    Right (Object root) -> Right root
    _ -> Left "the base config is not a JSON object"
  layerEntries <- traverse id (directoryEntries <> map fileEntry (sortOn (^. #path) files))
  let layer = Tar.write layerEntries
      layerHex = T.unpack (T.pack (show (hashlazy layer :: Digest SHA256)))
      layerName = layerHex </> "layer.tar"
      runtime = case KM.lookup "config" baseConfig of
        Just (Object c) -> c
        _ -> KM.empty
      ports = case KM.lookup "ExposedPorts" runtime of
        Just (Object p) -> p
        _ -> KM.empty
      rootfs = case KM.lookup "rootfs" baseConfig of
        Just (Object r) -> r
        _ -> KM.empty
      diffIds = case KM.lookup "diff_ids" rootfs of
        Just (Array ids) -> V.toList ids
        _ -> []
      history = case KM.lookup "history" baseConfig of
        Just (Array h) -> V.toList h
        _ -> []
      configValue =
        Object
          ( KM.insert "created" (String fixedTime)
              . KM.insert "config" (Object (KM.insert "ExposedPorts" (Object (KM.insert "8080/tcp" (object []) ports)) runtime))
              . KM.insert "rootfs" (Object (KM.insert "type" (String "layers") (KM.insert "diff_ids" (Array (V.fromList (diffIds <> [String ("sha256:" <> T.pack layerHex)]))) rootfs)))
              . KM.insert "history" (Array (V.fromList (history <> [object ["created" .= fixedTime, "created_by" .= ("nagarectl site package --builder layered" :: Text)]])))
              $ baseConfig
          )
      configBytes = LBS.toStrict (encode configValue)
      configName = T.unpack (sha256Hex configBytes) <> ".json"
      manifest =
        encode
          [ object
              [ "Config" .= configName
              , "RepoTags" .= [reference]
              , "Layers" .= (map fst (base ^. #layers) <> [layerName])
              ]
          ]
  outer <-
    traverse
      (\(name, content) -> fileAt name content)
      (base ^. #layers <> [(layerName, layer), (configName, LBS.fromStrict configBytes), ("manifest.json", manifest)])
  pure (Tar.write outer)
  where
    fixedTime = "1970-01-01T00:00:00Z" :: Text
    directories = Set.toAscList (Set.fromList (concatMap (parents . (^. #path)) files))
    parents file =
      let parts = T.splitOn "/" (T.pack file)
       in [T.unpack (T.intercalate "/" (take n parts)) | n <- [1 .. length parts - 1]]
    directoryEntries = [fixed 0o755 . Tar.directoryEntry <$> first T.pack (Tar.toTarPath True directory) | directory <- directories]
    fileEntry file = fixed 0o644 . (`Tar.fileEntry` LBS.fromStrict (file ^. #bytes)) <$> first T.pack (Tar.toTarPath False (file ^. #path))
    fileAt name content = fixed 0o644 . (`Tar.fileEntry` content) <$> first T.pack (Tar.toTarPath False name)
    fixed mode entry = entry {Tar.entryPermissions = mode, Tar.entryOwnership = Tar.Ownership "" "" 0 0, Tar.entryTime = 0}

-- | Where the pinned base of a platform is cached.
baseCachePath :: BasePin -> IO FilePath
baseCachePath pin = do
  cache <- lookupEnv "XDG_CACHE_HOME"
  home <- lookupEnv "HOME"
  let root = fromMaybe (maybe "/tmp" (</> ".cache") home) cache
  pure (root </> "nagare" </> "static-base" </> T.unpack (T.drop 7 (pin ^. #configDigest)) <> ".tar")

-- | The pinned base: from @--base-archive@, or from the cache, fetched once
-- by digest with @skopeo copy@ when absent. Every use verifies the digest.
acquireBase :: BasePin -> Text -> Maybe FilePath -> IO (Either Text BaseImage)
acquireBase pin indexReference given = case given of
  Just file -> readVerified file
  Nothing -> do
    cached <- baseCachePath pin
    present <- doesFileExist cached
    if present
      then readVerified cached
      else do
        createDirectoryIfMissing True (takeDirectory cached)
        let partial = cached <> ".partial"
            repository = T.takeWhile (/= ':') (T.takeWhile (/= '@') indexReference)
        fetched <- try (readProcessWithExitCode "skopeo" ["--insecure-policy", "copy", "--override-os", "linux", "--override-arch", arch, "docker://" <> T.unpack repository <> "@" <> T.unpack (pin ^. #manifestDigest), "docker-archive:" <> partial] "")
        case fetched of
          Right (ExitSuccess, _, _) -> renameFile partial cached >> readVerified cached
          Right (_, _, errors) -> pure (Left ("skopeo could not fetch the pinned base: " <> T.pack (take 300 errors)))
          Left (_ :: IOException) -> pure (Left "skopeo is not available to fetch the pinned base; pass --base-archive")
  where
    arch = T.unpack (T.drop 6 (pin ^. #platform))
    readVerified file = do
      loaded <- try (LBS.readFile file)
      pure $ case loaded of
        Left (_ :: IOException) -> Left ("the base archive " <> T.pack file <> " cannot be read")
        Right bytes -> readBaseArchive pin bytes
