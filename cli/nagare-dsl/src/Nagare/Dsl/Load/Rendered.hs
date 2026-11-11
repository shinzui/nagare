-- | A rendered configuration (EP-249): a config program's exact stdout,
-- produced once where there are no credentials and carried as data. The
-- envelope keeps the stdout as a JSON string, so its UTF-8 bytes after outer
-- decoding are exactly the bytes the program printed; the digest hashes those
-- bytes, never a re-serialized value. Decoding a document runs nothing and
-- reads nothing it names; it is untrusted input.
module Nagare.Dsl.Load.Rendered
  ( RenderedKind (..)
  , renderedKindText
  , renderedDocumentName
  , renderedDocument
  , decodeRendered
  , configDigestText
  )
where

import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Load.Error (LoadError (..))
import Nagare.Dsl.Prelude hiding ((.=))
import Text.Read (readMaybe)

data RenderedKind = RenderedApplication | RenderedWorker | RenderedStaticSite | RenderedServerSite
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

renderedKindText :: RenderedKind -> Text
renderedKindText = \case
  RenderedApplication -> "Application"
  RenderedWorker -> "Worker"
  RenderedStaticSite -> "StaticSite"
  RenderedServerSite -> "ServerSite"

renderedDocumentName :: RenderedKind -> Text
renderedDocumentName = \case
  RenderedApplication -> "rendered-application"
  RenderedWorker -> "rendered-worker"
  RenderedStaticSite -> "rendered-site"
  RenderedServerSite -> "rendered-site"

-- | The lower-case hex SHA-256 of the program's stdout.
configDigestText :: ByteString -> Text
configDigestText bytes = Text.pack (show (hash bytes :: Digest SHA256))

-- | The envelope for a program's stdout, already decoded by its loader as
-- @kind@. Output that is not UTF-8 is refused rather than normalized.
renderedDocument :: Text -> RenderedKind -> ByteString -> Either LoadError ByteString
renderedDocument version kind stdout = do
  config <- first (const (RenderedRefused "the config program's output is not UTF-8")) (TE.decodeUtf8' stdout)
  pure
    ( LBS.toStrict
        ( encode
            ( object
                [ "contractVersion" .= (1 :: Int)
                , "document" .= renderedDocumentName kind
                , "nagareVersion" .= version
                , "kind" .= renderedKindText kind
                , "configDigest" .= configDigestText stdout
                , "config" .= config
                ]
            )
        )
        <> "\n"
    )

-- | Check a document and return the program's exact stdout and its kind. It
-- must be contract version 1, a kind the command accepts, rendered by this
-- Nagare minor version or an earlier one, and its digest must be the digest
-- of the decoded @config@ string's UTF-8 bytes.
decodeRendered :: Text -> [RenderedKind] -> ByteString -> Either LoadError (RenderedKind, ByteString)
decodeRendered deploying accepted bytes = do
  value <- first (const (refuse "the document is not JSON")) (eitherDecodeStrict' bytes)
  fields <- case value of
    Object fields -> Right fields
    _ -> Left (refuse "the document is not a JSON object")
  let allowed = ["contractVersion", "document", "nagareVersion", "kind", "configDigest", "config"]
  unless (all ((`elem` allowed) . Key.toText) (KM.keys fields)) (Left (refuse "the document has an unknown member"))
  let text name = case KM.lookup (Key.fromText name) fields of
        Just (String t) -> Right t
        _ -> Left (refuse ("the document lacks " <> name))
  case KM.lookup "contractVersion" fields of
    Just (Number 1) -> Right ()
    Just (Number _) -> Left (refuse "the document's contractVersion is not 1")
    _ -> Left (refuse "the document lacks contractVersion")
  kindName <- text "kind"
  kind <- case [k | k <- accepted, renderedKindText k == kindName] of
    [k] -> Right k
    _ -> Left (UnexpectedKind (Text.intercalate " or " (map renderedKindText accepted)) kindName)
  document <- text "document"
  unless (document == renderedDocumentName kind) (Left (refuse ("a " <> kindName <> " is not a " <> document <> " document")))
  version <- text "nagareVersion"
  case (minorOf version, minorOf deploying) of
    (Just rendered, Just current)
      | rendered > current -> Left (refuse ("rendered by Nagare " <> version <> ", newer than this " <> deploying))
      | otherwise -> Right ()
    (Nothing, _) -> Left (refuse ("the document's nagareVersion " <> version <> " is not MAJOR.MINOR.PATCH"))
    (_, Nothing) -> Right ()
  config <- text "config"
  digest <- text "configDigest"
  let stdout = TE.encodeUtf8 config
  unless (configDigestText stdout == digest) (Left (refuse "the configDigest does not match the config"))
  pure (kind, stdout)
  where
    refuse = RenderedRefused
    minorOf version = case Text.splitOn "." (Text.takeWhile (/= '-') version) of
      [major, minor, _] -> (,) <$> readMaybe @Int (Text.unpack major) <*> readMaybe @Int (Text.unpack minor)
      _ -> Nothing
