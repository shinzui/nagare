-- | Conditional object operations beneath one context-owned bucket prefix.
-- The transport reports uncertainty explicitly; callers must never interpret a
-- failed read or list as object absence.
module Nagare.Inventory.Store.ObjectOps
  ( ObjectName (..)
  , Generation (..)
  , PutCondition (..)
  , GetOutcome (..)
  , PutOutcome (..)
  , ObjectOps (..)
  , objectUrl
  , putArgs
  , describeArgs
  , downloadArgs
  , listArgs
  , listedObjectNames
  , classifyPutReadback
  , gcloudObjectOps
  ) where

import Control.Exception (IOException, try)
import Data.Aeson ((.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Process (readProcessWithExitCode)
import Text.Read (readMaybe)

newtype ObjectName = ObjectName Text deriving stock (Eq, Ord, Show)
newtype Generation = Generation Integer deriving stock (Eq, Ord, Show)

data PutCondition = IfAbsent | IfGenerationMatches !Generation
  deriving stock (Eq, Show)

data GetOutcome
  = ObjectFound !Generation !ByteString
  | ObjectAbsent
  | GetUnknown !Text
  deriving stock (Eq, Show)

data PutOutcome
  = PutWritten !Generation
  | PutPreconditionFailed
  | PutNoEffect !Text
  | PutUnknown !Text
  deriving stock (Eq, Show)

data ObjectOps = ObjectOps
  { getObject :: !(ObjectName -> IO GetOutcome)
  , putObject :: !(PutCondition -> ObjectName -> ByteString -> IO PutOutcome)
  , listObjects :: !(ObjectName -> IO (Either Text [ObjectName]))
  }

-- | Construct a URL only from an already validated prefix and an inventory
-- relative name. Store keys are fixed by the inventory store, not user input.
objectUrl :: Text -> ObjectName -> Text
objectUrl prefix (ObjectName name) = T.dropWhileEnd (== '/') prefix <> "/" <> name

putArgs :: FilePath -> Text -> ObjectName -> PutCondition -> [String]
putArgs source prefix name condition =
  ["storage", "cp", source, T.unpack (objectUrl prefix name),
   "--if-generation-match=" <> show generation, "--print-created-message", "--quiet"]
  where
    generation = case condition of
      IfAbsent -> 0
      IfGenerationMatches (Generation value) -> value

describeArgs :: Text -> ObjectName -> [String]
describeArgs prefix name =
  ["storage", "objects", "describe", T.unpack (objectUrl prefix name),
   "--format=value(generation)", "--quiet"]

downloadArgs :: Text -> ObjectName -> FilePath -> [String]
downloadArgs prefix name destination =
  ["storage", "cp", T.unpack (objectUrl prefix name), destination, "--quiet"]

listArgs :: Text -> [String]
listArgs prefix =
  ["storage", "objects", "list", T.unpack (T.dropWhileEnd (== '/') prefix <> "/**"),
   "--format=json(name)", "--quiet"]

listedObjectNames :: Text -> ByteString -> Either Text [ObjectName]
listedObjectNames path bytes = do
  values <- firstText (Aeson.eitherDecodeStrict' bytes :: Either String [Aeson.Value])
  names <- traverse (firstText . parseEither (Aeson.withObject "object" (.: "name"))) values
  pure $ Set.toAscList $ Set.fromList
    [ObjectName relative | full <- names,
      Just relative <- [T.stripPrefix (path <> "/") full]]
  where
    firstText = either (Left . T.pack) Right

-- | Resolve even an ambiguous process exit from authoritative read-back.
-- An equal value is idempotent success. A changed generation or competing
-- value is a conflict. Unknown read-back always stops the caller.
classifyPutReadback :: PutCondition -> ByteString -> GetOutcome -> PutOutcome
classifyPutReadback condition expected outcome = case outcome of
  GetUnknown reason -> PutUnknown reason
  ObjectFound generation actual
    | actual == expected -> PutWritten generation
    | otherwise -> case condition of
        IfAbsent -> PutPreconditionFailed
        IfGenerationMatches previous
          | generation == previous -> PutNoEffect "object is unchanged after failed put"
          | otherwise -> PutPreconditionFailed
  ObjectAbsent -> case condition of
    IfAbsent -> PutNoEffect "object remains absent after failed put"
    IfGenerationMatches _ -> PutPreconditionFailed

-- | The CLI transport never parses error text as proof. A failed describe is
-- followed by a successful listing before it can report absence; uploads are
-- always classified by reading their destination back.
gcloudObjectOps :: Text -> Either Text ObjectOps
gcloudObjectOps prefix = do
  (_, path) <- parsePrefix prefix
  let run args = do
        result <- try (readProcessWithExitCode "gcloud" args "")
        pure $ case result of
          Left (err :: IOException) -> Left (T.pack (show err))
          Right (code, output, _) -> Right (code, output)
      listNames = do
        result <- run (listArgs prefix)
        pure $ case result of
          Left reason -> Left reason
          Right (ExitFailure _, _) -> Left "object listing failed"
          Right (ExitSuccess, output) -> listedObjectNames path (BC.pack output)
      describe name = do
        result <- run (describeArgs prefix name)
        pure $ case result of
          Left reason -> Left reason
          Right (ExitFailure _, _) -> Right Nothing
          Right (ExitSuccess, output) ->
            maybe (Left "object describe returned an invalid generation")
              (Right . Just . Generation) (readMaybe (T.unpack (T.strip (T.pack output))))
      get name = check (2 :: Int)
        where
          check remaining = do
            described <- describe name
            case described of
              Left reason -> pure (GetUnknown reason)
              Right Nothing -> do
                listed <- listNames
                pure $ case listed of
                  Left reason -> GetUnknown reason
                  Right names | name `elem` names -> GetUnknown "object exists but describe failed"
                  Right _ -> ObjectAbsent
              Right (Just before) -> withSystemTempDirectory "nagare-inventory-get" $ \directory -> do
                let destination = directory </> "object"
                downloaded <- run (downloadArgs prefix name destination)
                case downloaded of
                  Right (ExitSuccess, _) -> do
                    bytesResult <- try (BS.readFile destination) :: IO (Either IOException ByteString)
                    after <- describe name
                    case (bytesResult, after) of
                      (Right bytes, Right (Just current)) | current == before ->
                        pure (ObjectFound current bytes)
                      (_, Right (Just _)) | remaining > 0 -> check (remaining - 1)
                      _ -> pure (GetUnknown "object changed or could not be read during download")
                  _ -> pure (GetUnknown "object download failed")
      put condition name bytes = withSystemTempDirectory "nagare-inventory-put" $ \directory -> do
        let source = directory </> "object"
        BS.writeFile source bytes
        setFileMode source 0o600
        _ <- run (putArgs source prefix name condition)
        classifyPutReadback condition bytes <$> get name
  pure ObjectOps
    { getObject = get
    , putObject = put
    , listObjects = \(ObjectName requested) -> do
        result <- listNames
        pure (fmap (filter (\(ObjectName name) -> requested `T.isPrefixOf` name)) result)
    }
  where
    parsePrefix url = case T.stripPrefix "gs://" (T.dropWhileEnd (== '/') url) of
      Nothing -> Left "inventory object store URL must start with gs://"
      Just suffix -> case T.breakOn "/" suffix of
        (bucket, rawPath)
          | not (T.null bucket), not (T.null rawPath),
            let path = T.drop 1 rawPath,
            not (T.null path),
            all validPart (T.splitOn "/" path) -> Right (bucket, path)
        _ -> Left "inventory object store URL must name a bucket and private prefix"
    validPart part = not (T.null part) && part /= "." && part /= ".."
