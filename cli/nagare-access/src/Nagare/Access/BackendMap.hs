-- | Host to upstream mapping for protected sites.
module Nagare.Access.BackendMap
  ( BackendMap
  , BackendTarget (..)
  , backendMapFromList
  , decodeBackendMap
  , emptyBackendMap
  , lookupBackend
  , lookupBackendWithHost
  )
where

import Data.Aeson (Value (Object, String), eitherDecodeStrict)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text

newtype BackendMap = BackendMap (Map Text BackendTarget)
  deriving stock (Eq, Show)

newtype BackendTarget = BackendTarget
  { upstreamUrl :: Text
  }
  deriving stock (Eq, Show)

emptyBackendMap :: BackendMap
emptyBackendMap = BackendMap Map.empty

backendMapFromList :: [(Text, Text)] -> Either Text BackendMap
backendMapFromList entries =
  BackendMap . Map.fromList <$> traverse parseEntry entries
  where
    parseEntry (host, upstream) =
      (,) <$> canonicalHost host <*> validateTarget upstream

decodeBackendMap :: ByteString -> Either Text BackendMap
decodeBackendMap bs =
  case eitherDecodeStrict bs of
    Left e -> Left ("could not decode backend map JSON: " <> Text.pack e)
    Right (Object obj) ->
      backendMapFromList [(Key.toText host, upstream) | (host, String upstream) <- KeyMap.toList obj]
        >>= rejectNonStringValues obj
    Right _ ->
      Left "backend map must be a JSON object mapping host names to upstream URLs"

lookupBackend :: Text -> BackendMap -> Maybe BackendTarget
lookupBackend rawHost (BackendMap entries) =
  case canonicalHost rawHost of
    Left _ -> Nothing
    Right host -> Map.lookup host entries

lookupBackendWithHost :: Text -> BackendMap -> Maybe (Text, BackendTarget)
lookupBackendWithHost rawHost (BackendMap entries) =
  case canonicalHost rawHost of
    Left _ -> Nothing
    Right host -> (host,) <$> Map.lookup host entries

rejectNonStringValues :: KeyMap.KeyMap Value -> BackendMap -> Either Text BackendMap
rejectNonStringValues obj parsed =
  case [Key.toText k | (k, v) <- KeyMap.toList obj, not (isString v)] of
    [] -> Right parsed
    bad : _ -> Left ("backend map value for " <> bad <> " must be a string URL")
  where
    isString (String _) = True
    isString _ = False

canonicalHost :: Text -> Either Text Text
canonicalHost raw =
  let stripped = Text.toLower . Text.dropWhileEnd (== '.') . stripPort . Text.strip $ raw
   in if Text.null stripped || Text.any isBadHostChar stripped
        then Left "host must be a non-empty DNS name without whitespace"
        else Right stripped

stripPort :: Text -> Text
stripPort host =
  case Text.breakOn ":" host of
    (name, port)
      | Text.null port -> name
      | Text.all isDigitText (Text.drop 1 port) -> name
    _ -> host

isBadHostChar :: Char -> Bool
isBadHostChar c =
  c <= ' ' || c == '/' || c == '\\'

isDigitText :: Char -> Bool
isDigitText c = c >= '0' && c <= '9'

validateTarget :: Text -> Either Text BackendTarget
validateTarget raw =
  let upstream = Text.strip raw
   in if hasHttpScheme upstream && hasHostPart upstream && not (Text.any badTargetChar upstream)
        then Right (BackendTarget upstream)
        else Left ("invalid backend upstream URL: " <> raw)

hasHttpScheme :: Text -> Bool
hasHttpScheme upstream =
  "http://" `Text.isPrefixOf` upstream || "https://" `Text.isPrefixOf` upstream

hasHostPart :: Text -> Bool
hasHostPart upstream =
  not (Text.null hostPart)
  where
    withoutScheme =
      case Text.stripPrefix "http://" upstream of
        Just rest -> rest
        Nothing -> maybe upstream id (Text.stripPrefix "https://" upstream)
    hostPart = fst (Text.breakOn "/" withoutScheme)

badTargetChar :: Char -> Bool
badTargetChar c =
  c <= ' '
