-- | Read exact, versioned local scheduled-backup objects without creating a
-- Kubernetes Pod. The operator's guarded context opens a short-lived
-- port-forward; curl receives SigV4 credentials on stdin, never on argv.
module Nagare.Inventory.ScheduledStore
  ( StoredObject (..)
  , ListedObject (..)
  , ObjectReader (..)
  , withLocalObjectStore
  , parseObjectList
  , parseObjectEntries
  , readSecretField
  ) where

import Control.Exception (IOException, bracket, catch, try)
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Char8 qualified as BC
import Data.Char (isAlphaNum)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Nagare.Cluster.GcsJob (MinioRef (..))
import Nagare.Dsl.Prelude
import System.Exit (ExitCode (..))
import System.IO (Handle, hClose, hGetLine)
import System.IO.Temp (withSystemTempDirectory)
import System.Process
  ( CreateProcess (..), ProcessHandle, StdStream (..), createProcess, proc
  , readCreateProcessWithExitCode, readProcessWithExitCode, terminateProcess
  , waitForProcess )
import System.Timeout (timeout)

data StoredObject = StoredObject
  { storedVersion :: !Text
  , storedLength :: !Integer
  }
  deriving stock (Eq, Show)

data ListedObject = ListedObject
  { listedKey :: !Text
  , listedModified :: !UTCTime
  }
  deriving stock (Eq, Show)

data ObjectReader = ObjectReader
  { readObjectToFile :: !(Text -> Maybe Text -> FilePath -> IO (Either Text StoredObject))
  , listObjectKeys :: !(Text -> IO (Either Text [Text]))
  , listObjectEntries :: !(Text -> IO (Either Text [ListedObject]))
  }

-- | The callback must consume files before returning; the port-forward and
-- scratch headers are closed and removed immediately afterwards. The caller
-- supplies an already-guarded kubectl context and an accepted MinIO reference.
withLocalObjectStore
  :: forall a. Text -> MinioRef -> (ObjectReader -> IO a) -> IO (Either Text a)
withLocalObjectStore context ref action = do
  credentials <- readCredentials context ref
  case credentials of
    Left reason -> pure (Left reason)
    Right user -> do
      result <- try (withSystemTempDirectory "nagare-scheduled-store" $ \scratch ->
        bracket (openForward context) closeForward $ \(output, _) -> do
          ready <- timeout (10 * 1000000) (hGetLine output)
          case ready >>= parseForwardPort . T.pack of
            Nothing -> pure (Left "local object-store port-forward did not become ready")
            Just port -> Right <$> action (ObjectReader
              (readViaCurl ref user port scratch)
              (listViaCurl ref user port scratch parseObjectList)
              (listViaCurl ref user port scratch parseObjectEntries)))
        :: IO (Either IOException (Either Text a))
      pure (either (Left . const "local object-store read failed") id result)

readCredentials :: Text -> MinioRef -> IO (Either Text Text)
readCredentials context ref = do
  access <- readSecretField context "nagare-system" (secretName ref) "AWS_ACCESS_KEY_ID"
  secret <- readSecretField context "nagare-system" (secretName ref) "AWS_SECRET_ACCESS_KEY"
  pure ((<>) <$> ((<> ":") <$> access) <*> secret)

-- | Read one operator-authorized Secret field privately. The decoded value is
-- never put in a process argument, review, terminal output, or error message.
readSecretField :: Text -> Text -> Text -> Text -> IO (Either Text Text)
readSecretField context namespaceName secretRefName keyName = do
  outcome <- try (readProcessWithExitCode "kubectl"
    ["--context", T.unpack context, "-n", T.unpack namespaceName, "get", "secret"
    , T.unpack secretRefName, "-o", "json"] "")
    :: IO (Either IOException (ExitCode, String, String))
  case outcome of
    Left _ -> pure (Left "could not read local object-store credentials")
    Right (ExitFailure _, _, _) -> pure (Left "local object-store credentials are unavailable")
    Right (ExitSuccess, body, _) -> case eitherDecodeStrict (BC.pack body) of
      Right (Object root) | Just (Object fields) <- KM.lookup "data" root -> do
        decodeField fields (K.fromText keyName)
      _ -> pure (Left "local object-store credential Secret is malformed")
  where
    decodeField fields key = case KM.lookup key fields of
      Just (String encoded) -> do
        decoded <- try (readProcessWithExitCode "base64" ["-d"] (T.unpack encoded))
          :: IO (Either IOException (ExitCode, String, String))
        pure $ case decoded of
          Right (ExitSuccess, value, _) | not (null value)
            && all (\character -> character >= ' ' && character <= '~') value ->
              Right (T.pack value)
          _ -> Left "local object-store credential field is invalid"
      _ -> pure (Left "local object-store credential field is missing")

openForward :: Text -> IO (Handle, ProcessHandle)
openForward context = do
  (_, output, _, processHandle) <- createProcess
    (proc "kubectl" ["--context", T.unpack context, "-n", "nagare-system"
      , "port-forward", "svc/minio", ":9000", "--address", "127.0.0.1"])
      {std_out = CreatePipe, std_err = Inherit}
  case output of
    Just handle -> pure (handle, processHandle)
    Nothing -> fail "kubectl port-forward has no output pipe"

closeForward :: (Handle, ProcessHandle) -> IO ()
closeForward (output, processHandle) = do
  terminateProcess processHandle `catch` \(_ :: IOException) -> pure ()
  _ <- waitForProcess processHandle
  hClose output `catch` \(_ :: IOException) -> pure ()

parseForwardPort :: Text -> Maybe Text
parseForwardPort line = do
  rest <- T.stripPrefix "Forwarding from 127.0.0.1:" line
  let (port, suffix) = T.breakOn " -> 9000" rest
  if not (T.null port) && T.all (\character -> character >= '0' && character <= '9') port
      && suffix == " -> 9000"
    then Just port else Nothing

readViaCurl
  :: MinioRef -> Text -> Text -> FilePath -> Text -> Maybe Text -> FilePath
  -> IO (Either Text StoredObject)
readViaCurl ref user port scratch address selectedVersion output = do
  let prefix = "s3://" <> bucket ref <> "/"
  case T.stripPrefix prefix address of
    Nothing -> pure (Left "scheduled object is outside the accepted local bucket")
    Just key | T.null key || T.any (\character -> not (isAlphaNum character
        || character `elem` ("/-_." :: String))) key ->
          pure (Left "scheduled object key has unsupported URL characters")
    Just key -> case selectedVersion of
      Just version | T.null version || T.any (\character -> not (isAlphaNum character
          || character == '-')) version ->
            pure (Left "scheduled object version has unsupported URL characters")
      _ -> do
        let url = "http://127.0.0.1:" <> port <> "/" <> bucket ref <> "/" <> key
              <> maybe "" ("?versionId=" <>) selectedVersion
            headerFile = scratch <> "/headers"
            config = "user = \"" <> quoteConfig user <> "\"\n"
            arguments = ["--silent", "--show-error", "--fail", "--aws-sigv4"
              , "aws:amz:us-east-1:s3", "--config", "-", "--dump-header", headerFile
              , "--output", output, T.unpack url]
        outcome <- try (readCreateProcessWithExitCode (proc "curl" arguments)
          (T.unpack config)) :: IO (Either IOException (ExitCode, String, String))
        case outcome of
          Left _ -> pure (Left "could not invoke local object-store reader")
          Right (ExitFailure _, _, _) -> pure (Left "local object-store object is unavailable")
          Right (ExitSuccess, _, _) -> do
            headers <- try (BC.readFile headerFile) :: IO (Either IOException BC.ByteString)
            pure $ case headers of
              Left _ -> Left "local object-store response headers are unavailable"
              Right raw -> do
                version <- oneHeader "x-amz-version-id" raw
                lengthText <- oneHeader "content-length" raw
                lengthValue <- case reads (T.unpack lengthText) of
                  [(number, "")] | number >= (0 :: Integer) -> Right number
                  _ -> Left "local object-store object length is invalid"
                case selectedVersion of
                  Just expected | expected /= version ->
                    Left "local object-store returned another object version"
                  _ -> Right (StoredObject version lengthValue)

oneHeader :: Text -> BC.ByteString -> Either Text Text
oneHeader name raw = case [T.strip value
    | line <- T.lines (TE.decodeUtf8 raw)
    , let (key, rest) = T.breakOn ":" (T.stripEnd line)
    , T.toLower key == name
    , Just value <- [T.stripPrefix ":" rest]] of
  [value] | not (T.null value) -> Right value
  _ -> Left ("local object-store response lacks one " <> name <> " header")

-- | A listing is useful only when it is complete. A truncated or malformed
-- page cannot silently hide an orphan or authorize a later prune decision.
listViaCurl :: MinioRef -> Text -> Text -> FilePath
  -> (Text -> BC.ByteString -> Either Text a) -> Text
  -> IO (Either Text a)
listViaCurl ref user port scratch parseListing prefix
  | T.null prefix || T.any (\character -> not (isAlphaNum character
      || character `elem` ("/-_." :: String))) prefix =
      pure (Left "scheduled object prefix has unsupported URL characters")
  | otherwise = do
      let url = "http://127.0.0.1:" <> port <> "/" <> bucket ref
            <> "/?list-type=2&prefix=" <> prefix
          output = scratch <> "/listing.xml"
          config = "user = \"" <> quoteConfig user <> "\"\n"
          arguments = ["--silent", "--show-error", "--fail", "--aws-sigv4"
            , "aws:amz:us-east-1:s3", "--config", "-", "--output", output
            , T.unpack url]
      outcome <- try (readCreateProcessWithExitCode (proc "curl" arguments)
        (T.unpack config)) :: IO (Either IOException (ExitCode, String, String))
      case outcome of
        Left _ -> pure (Left "could not invoke local object-store listing")
        Right (ExitFailure _, _, _) -> pure (Left "local object-store listing is unavailable")
        Right (ExitSuccess, _, _) -> do
          body <- try (BC.readFile output) :: IO (Either IOException BC.ByteString)
          pure (either (Left . const "local object-store listing cannot be read")
            (parseListing prefix) body)

parseObjectList :: Text -> BC.ByteString -> Either Text [Text]
parseObjectList prefix raw = do
  body <- first (const "local object-store listing is not UTF-8")
    (TE.decodeUtf8' raw)
  unless ("<ListBucketResult" `T.isInfixOf` body
      && "</ListBucketResult>" `T.isInfixOf` body)
    (Left "local object-store listing has no result envelope")
  truncated <- oneElement "IsTruncated" body
  unless (truncated == "false")
    (Left "local object-store listing is incomplete")
  countText <- oneElement "KeyCount" body
  count <- case reads (T.unpack countText) of
    [(number, "")] | number >= (0 :: Int) -> Right number
    _ -> Left "local object-store listing has an invalid key count"
  contents <- xmlElements "Contents" body
  keys <- traverse (oneElement "Key") contents
  unless (length keys == count && Set.size (Set.fromList keys) == count
      && all (\key -> prefix `T.isPrefixOf` key &&
        T.all (\character -> isAlphaNum character
          || character `elem` ("/-_." :: String)) key) keys)
    (Left "local object-store listing has invalid or duplicate keys")
  pure keys

-- | Retention uses the provider's completion order, never the random Job UID
-- or the order in which an operator happened to ingest receipts. A missing or
-- malformed timestamp therefore makes the entire candidate listing unusable.
parseObjectEntries :: Text -> BC.ByteString -> Either Text [ListedObject]
parseObjectEntries prefix raw = do
  keys <- parseObjectList prefix raw
  body <- first (const "local object-store listing is not UTF-8")
    (TE.decodeUtf8' raw)
  contents <- xmlElements "Contents" body
  entries <- traverse one contents
  unless (map listedKey entries == keys)
    (Left "local object-store listing keys changed during timestamp parsing")
  pure entries
  where
    one value = do
      key <- oneElement "Key" value
      modified <- oneElement "LastModified" value
      timestamp <- maybe
        (Left "local object-store listing has an invalid modification time") Right
        (parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ"
          (T.unpack modified) :: Maybe UTCTime)
      pure (ListedObject key timestamp)

oneElement :: Text -> Text -> Either Text Text
oneElement name body = case xmlElements name body of
  Right [value] -> Right value
  _ -> Left ("local object-store listing lacks one " <> name)

xmlElements :: Text -> Text -> Either Text [Text]
xmlElements name body = go body []
  where
    openTag = "<" <> name <> ">"
    closeTag = "</" <> name <> ">"
    go remaining found = case T.breakOn openTag remaining of
      (_, suffix) | T.null suffix -> Right (reverse found)
      (_, suffix) ->
        let afterOpen = T.drop (T.length openTag) suffix
            (value, closing) = T.breakOn closeTag afterOpen
         in if T.null closing
              then Left "local object-store listing has an unterminated element"
              else go (T.drop (T.length closeTag) closing) (value : found)

quoteConfig :: Text -> Text
quoteConfig = T.concatMap $ \case
  '\\' -> "\\\\"
  '"' -> "\\\""
  character -> T.singleton character
