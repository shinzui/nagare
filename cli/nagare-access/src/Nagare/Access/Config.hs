-- | Environment parsing helpers for the nagare-access service.
module Nagare.Access.Config
  ( AuthPlaneConfig (..)
  , Listen (..)
  , RuntimeConfig (..)
  , defaultDecisionTtlSeconds
  , defaultListen
  , parseListen
  , parseRuntimeConfig
  , listenPort
  )
where

import Data.Text (Text)
import Data.Text qualified as Text

data Listen = Listen
  { host :: !(Maybe Text)
  , port :: !Int
  }
  deriving stock (Eq, Show)

data AuthPlaneConfig = AuthPlaneConfig
  { shomeiUrl :: !Text
  , shomeiIssuer :: !Text
  , shomeiAudience :: !Text
  , enUrl :: !Text
  , cookieDomain :: !Text
  , cookieKey :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data RuntimeConfig = RuntimeConfig
  { runtimeListen :: !Listen
  , backendMapPath :: !(Maybe FilePath)
  , authPlaneConfig :: !(Maybe AuthPlaneConfig)
  , decisionTtlSeconds :: !Int
  }
  deriving stock (Eq, Show)

defaultListen :: Listen
defaultListen = Listen {host = Nothing, port = 8080}

defaultDecisionTtlSeconds :: Int
defaultDecisionTtlSeconds = 30

-- | Parse @NAGARE_ACCESS_LISTEN@. The initial supported forms are @:8080@,
-- @8080@, and @127.0.0.1:8080@. Warp binding is currently port-only; the host is
-- retained so a later hardening pass can switch to host-aware settings without
-- changing the config contract.
parseListen :: Text -> Either Text Listen
parseListen raw
  | Text.null trimmed = Right defaultListen
  | ":" `Text.isPrefixOf` trimmed =
      Listen Nothing <$> parsePort (Text.drop 1 trimmed)
  | Just (h, p) <- splitHostPort trimmed =
      Listen (Just h) <$> parsePort p
  | otherwise =
      Listen Nothing <$> parsePort trimmed
  where
    trimmed = Text.strip raw

listenPort :: Listen -> Int
listenPort = port

parseRuntimeConfig :: [(String, String)] -> Either Text RuntimeConfig
parseRuntimeConfig env = do
  runtimeListen <- parseListen (envText "NAGARE_ACCESS_LISTEN")
  decisionTtlSeconds <- parseDecisionTtl (envText "NAGARE_ACCESS_DECISION_TTL")
  authPlaneConfig <- parseAuthPlane env
  pure
    RuntimeConfig
      { runtimeListen
      , backendMapPath = envFilePath "NAGARE_ACCESS_BACKENDS"
      , authPlaneConfig
      , decisionTtlSeconds
      }
  where
    envText name = maybe "" Text.pack (lookup name env)
    envFilePath name = nonEmptyString =<< lookup name env

splitHostPort :: Text -> Maybe (Text, Text)
splitHostPort t =
  case Text.breakOnEnd ":" t of
    ("", _) -> Nothing
    (prefix, p) ->
      let h = Text.dropEnd 1 prefix
       in if Text.null h || Text.null p then Nothing else Just (h, p)

parsePort :: Text -> Either Text Int
parsePort t =
  case reads (Text.unpack t) of
    [(n, "")]
      | n >= 1 && n <= 65535 -> Right n
      | otherwise -> Left ("listen port must be between 1 and 65535: " <> t)
    _ -> Left ("listen port must be an integer: " <> t)

parseDecisionTtl :: Text -> Either Text Int
parseDecisionTtl raw
  | Text.null trimmed = Right defaultDecisionTtlSeconds
  | otherwise =
      case reads (Text.unpack trimmed) of
        [(n, "")]
          | n >= 0 -> Right n
          | otherwise -> Left "NAGARE_ACCESS_DECISION_TTL must be zero or a positive integer"
        _ -> Left "NAGARE_ACCESS_DECISION_TTL must be an integer number of seconds"
  where
    trimmed = Text.strip raw

parseAuthPlane :: [(String, String)] -> Either Text (Maybe AuthPlaneConfig)
parseAuthPlane env =
  if null present && cookieKeyRaw == Nothing
    then Right Nothing
    else Just <$> parseCompleteAuthPlane
  where
    raw name = lookupText env name
    requiredNames =
      [ "NAGARE_ACCESS_SHOMEI_URL"
      , "NAGARE_ACCESS_SHOMEI_ISSUER"
      , "NAGARE_ACCESS_SHOMEI_AUDIENCE"
      , "NAGARE_ACCESS_EN_URL"
      , "NAGARE_ACCESS_COOKIE_DOMAIN"
      ]
    present = [name | name <- requiredNames, raw name /= Nothing]
    cookieKeyRaw = raw "NAGARE_ACCESS_COOKIE_KEY"
    parseCompleteAuthPlane =
      AuthPlaneConfig
        <$> (requireAuthEnv "NAGARE_ACCESS_SHOMEI_URL" >>= parseHttpUrl "NAGARE_ACCESS_SHOMEI_URL")
        <*> requireAuthEnv "NAGARE_ACCESS_SHOMEI_ISSUER"
        <*> requireAuthEnv "NAGARE_ACCESS_SHOMEI_AUDIENCE"
        <*> (requireAuthEnv "NAGARE_ACCESS_EN_URL" >>= parseHttpUrl "NAGARE_ACCESS_EN_URL")
        <*> (requireAuthEnv "NAGARE_ACCESS_COOKIE_DOMAIN" >>= parseCookiePart "NAGARE_ACCESS_COOKIE_DOMAIN")
        <*> traverse (parseCookiePart "NAGARE_ACCESS_COOKIE_KEY") cookieKeyRaw
    requireAuthEnv name =
      case raw name of
        Just value -> Right value
        Nothing -> Left ("auth-plane config is incomplete; missing " <> Text.pack name)

lookupText :: [(String, String)] -> String -> Maybe Text
lookupText env name =
  nonEmptyText . Text.pack =<< lookup name env

parseHttpUrl :: String -> Text -> Either Text Text
parseHttpUrl name raw =
  let url = Text.strip raw
   in if hasHttpScheme url && hasHostPart url && not (Text.any badUrlChar url)
        then Right url
        else Left (Text.pack name <> " must be an http(s) URL with a host")

parseCookiePart :: String -> Text -> Either Text Text
parseCookiePart name raw =
  let value = Text.strip raw
   in if Text.null value || Text.any badCookieChar value
        then Left (Text.pack name <> " contains a character that is not valid in Set-Cookie")
        else Right value

hasHttpScheme :: Text -> Bool
hasHttpScheme url =
  "http://" `Text.isPrefixOf` url || "https://" `Text.isPrefixOf` url

hasHostPart :: Text -> Bool
hasHostPart url =
  not (Text.null hostPart)
  where
    withoutScheme =
      case Text.stripPrefix "http://" url of
        Just rest -> rest
        Nothing -> maybe url id (Text.stripPrefix "https://" url)
    hostPart = fst (Text.breakOn "/" withoutScheme)

badUrlChar :: Char -> Bool
badUrlChar c =
  c <= ' '

badCookieChar :: Char -> Bool
badCookieChar c =
  c <= ' ' || c == ';' || c == ',' || c == '\DEL'

nonEmptyString :: String -> Maybe FilePath
nonEmptyString value =
  case Text.unpack (Text.strip (Text.pack value)) of
    "" -> Nothing
    trimmed -> Just trimmed

nonEmptyText :: Text -> Maybe Text
nonEmptyText value =
  let trimmed = Text.strip value
   in if Text.null trimmed then Nothing else Just trimmed
