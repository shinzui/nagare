-- | Host to upstream mapping for protected sites and the authentication portal.
module Nagare.Access.BackendMap
  ( BackendMap
  , BackendRole (..)
  , BackendTarget (..)
  , Portal (..)
  , PublicHost
  , backendMapFromList
  , backendMapFromTargets
  , decodeBackendMap
  , emptyBackendMap
  , findPortal
  , isRoutedHost
  , lookupBackend
  , lookupBackendWithHost
  , mkPublicHost
  , publicHostText
  )
where

import Nagare.Access.Prelude
import Data.Generics.Labels ()

import Data.Aeson (FromJSON (parseJSON), Value (Object, String), eitherDecodeStrict, withObject, (.:))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types qualified as Aeson
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text

-- | A public host after lower-casing and removing a port and trailing dot.
newtype PublicHost = PublicHost Text
  deriving stock (Generic, Eq, Ord, Show)

publicHostText :: PublicHost -> Text
publicHostText (PublicHost host) = host

data BackendRole
  = ProtectedBackend
  | PortalBackend
  deriving stock (Generic, Eq, Show)

data BackendTarget = BackendTarget
  { upstreamUrl :: !Text
  , role :: !BackendRole
  }
  deriving stock (Generic, Eq, Show)

data Portal = Portal
  { host :: !PublicHost
  , target :: !BackendTarget
  }
  deriving stock (Generic, Eq, Show)

newtype BackendMap = BackendMap (Map PublicHost BackendTarget)
  deriving stock (Generic, Eq, Show)

instance FromJSON BackendTarget where
  parseJSON (String upstream) =
    either (fail . Text.unpack) pure (validateTarget ProtectedBackend upstream)
  parseJSON value@(Object _) =
    withObject "backend target" parseTarget value
    where
      parseTarget obj = do
        upstream <- obj .: "upstream"
        roleText <- obj .: "role"
        role <- case (roleText :: Text) of
          "protected" -> pure ProtectedBackend
          "portal" -> pure PortalBackend
          other -> fail ("unknown backend role: " <> Text.unpack other)
        either (fail . Text.unpack) pure (validateTarget role upstream)
  parseJSON _ = fail "backend target must be a string URL or an object with upstream and role"

emptyBackendMap :: BackendMap
emptyBackendMap = BackendMap Map.empty

backendMapFromList :: [(Text, Text)] -> Either Text BackendMap
backendMapFromList entries =
  backendMapFromTargets
    [ (host, BackendTarget upstream ProtectedBackend)
    | (host, upstream) <- entries
    ]

backendMapFromTargets :: [(Text, BackendTarget)] -> Either Text BackendMap
backendMapFromTargets entries = do
  parsed <- traverse parseEntry entries
  rejectMultiplePortals parsed
  pure (BackendMap (Map.fromList parsed))
  where
    parseEntry (host, target) = do
      publicHost <- mkPublicHost host
      validated <- validateTarget (target ^. #role) (target ^. #upstreamUrl)
      pure (publicHost, validated)

decodeBackendMap :: ByteString -> Either Text BackendMap
decodeBackendMap bs =
  case eitherDecodeStrict bs of
    Left e -> Left ("could not decode backend map JSON: " <> Text.pack e)
    Right (Object obj) -> do
      entries <- traverse parseEntry (KeyMap.toList obj)
      rejectMultiplePortals entries
      pure (BackendMap (Map.fromList entries))
    Right _ ->
      Left "backend map must be a JSON object mapping host names to backend targets"
  where
    parseEntry (key, value) = do
      let hostText = Key.toText key
      host <- mapLeft (\err -> "backend map host " <> hostText <> ": " <> err) (mkPublicHost hostText)
      target <- mapLeft (\err -> "backend map value for " <> hostText <> ": " <> Text.pack err) (Aeson.parseEither parseJSON value)
      pure (host, target)

lookupBackend :: Text -> BackendMap -> Maybe BackendTarget
lookupBackend rawHost backendMap = do
  host <- either (const Nothing) Just (mkPublicHost rawHost)
  lookupBackendByHost host backendMap

lookupBackendWithHost :: Text -> BackendMap -> Maybe (PublicHost, BackendTarget)
lookupBackendWithHost rawHost backendMap = do
  host <- either (const Nothing) Just (mkPublicHost rawHost)
  (host,) <$> lookupBackendByHost host backendMap

findPortal :: BackendMap -> Maybe Portal
findPortal (BackendMap entries) =
  case [(host, target) | (host, target) <- Map.toList entries, target ^. #role == PortalBackend] of
    (host, target) : _ -> Just Portal {host = host, target = target}
    [] -> Nothing

isRoutedHost :: PublicHost -> BackendMap -> Bool
isRoutedHost host (BackendMap entries) = Map.member host entries

lookupBackendByHost :: PublicHost -> BackendMap -> Maybe BackendTarget
lookupBackendByHost host (BackendMap entries) = Map.lookup host entries

mkPublicHost :: Text -> Either Text PublicHost
mkPublicHost raw =
  let stripped = Text.toLower . Text.dropWhileEnd (== '.') . stripPort . Text.strip $ raw
   in if Text.null stripped || Text.any isBadHostChar stripped
        then Left "host must be a non-empty DNS name without whitespace"
        else Right (PublicHost stripped)

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

validateTarget :: BackendRole -> Text -> Either Text BackendTarget
validateTarget role raw =
  let upstream = Text.strip raw
   in if hasHttpScheme upstream && hasHostPart upstream && not (Text.any badTargetChar upstream)
        then Right (BackendTarget upstream role)
        else Left ("invalid backend upstream URL: " <> raw)

rejectMultiplePortals :: [(PublicHost, BackendTarget)] -> Either Text ()
rejectMultiplePortals entries =
  case [publicHostText host | (host, target) <- entries, target ^. #role == PortalBackend] of
    _ : second : _ -> Left ("backend map contains more than one portal; offending host: " <> second)
    _ -> Right ()

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
badTargetChar c = c <= ' '

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f = either (Left . f) Right
