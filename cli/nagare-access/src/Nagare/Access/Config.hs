-- | Environment parsing helpers for the nagare-access service.
module Nagare.Access.Config
  ( Listen (..)
  , defaultListen
  , parseListen
  , listenPort
  )
where

import Data.Text qualified as Text

data Listen = Listen
  { host :: !(Maybe Text.Text)
  , port :: !Int
  }
  deriving stock (Eq, Show)

defaultListen :: Listen
defaultListen = Listen {host = Nothing, port = 8080}

-- | Parse @NAGARE_ACCESS_LISTEN@. The initial supported forms are @:8080@,
-- @8080@, and @127.0.0.1:8080@. Warp binding is currently port-only; the host is
-- retained so a later hardening pass can switch to host-aware settings without
-- changing the config contract.
parseListen :: Text.Text -> Either Text.Text Listen
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

splitHostPort :: Text.Text -> Maybe (Text.Text, Text.Text)
splitHostPort t =
  case Text.breakOnEnd ":" t of
    ("", _) -> Nothing
    (prefix, p) ->
      let h = Text.dropEnd 1 prefix
       in if Text.null h || Text.null p then Nothing else Just (h, p)

parsePort :: Text.Text -> Either Text.Text Int
parsePort t =
  case reads (Text.unpack t) of
    [(n, "")]
      | n >= 1 && n <= 65535 -> Right n
      | otherwise -> Left ("listen port must be between 1 and 65535: " <> t)
    _ -> Left ("listen port must be an integer: " <> t)
