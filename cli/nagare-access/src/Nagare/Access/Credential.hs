-- | Extract raw access credentials from incoming requests.
module Nagare.Access.Credential
  ( Credential (..)
  , credentialToken
  , extractCredential
  )
where

import Control.Applicative ((<|>))
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types.Header (Header, HeaderName)

data Credential
  = SessionCookie Text
  | BearerToken Text
  deriving stock (Eq, Show)

credentialToken :: Credential -> Text
credentialToken (SessionCookie token) = token
credentialToken (BearerToken token) = token

extractCredential :: [Header] -> Maybe Credential
extractCredential headers =
  extractSessionCookie headers <|> extractBearerToken headers

extractSessionCookie :: [Header] -> Maybe Credential
extractSessionCookie headers =
  SessionCookie <$> firstParsed [value | (name, value) <- headers, name == cookieHeaderName]
  where
    firstParsed = foldr ((<|>) . parseSessionCookie) Nothing

parseSessionCookie :: ByteString -> Maybe Text
parseSessionCookie headerValue =
  firstToken
    [ BC.drop 1 value
    | part <- BC.split ';' headerValue
    , let (name, value) = BC.break (== '=') (BC.strip part)
    , name == "nagare_session"
    , not (BC.null value)
    ]

extractBearerToken :: [Header] -> Maybe Credential
extractBearerToken headers =
  BearerToken <$> firstParsed [value | (name, value) <- headers, name == authorizationHeaderName]
  where
    firstParsed = foldr ((<|>) . parseBearerToken) Nothing

parseBearerToken :: ByteString -> Maybe Text
parseBearerToken value =
  case BC.words value of
    [scheme, token]
      | BC.map toLowerAscii scheme == "bearer" ->
          decodeNonEmpty token
    _ -> Nothing

decodeNonEmpty :: ByteString -> Maybe Text
decodeNonEmpty bytes
  | BC.null bytes = Nothing
  | otherwise = either (const Nothing) Just (TE.decodeUtf8' bytes)

firstToken :: [ByteString] -> Maybe Text
firstToken =
  foldr ((<|>) . decodeNonEmpty) Nothing

cookieHeaderName :: HeaderName
cookieHeaderName = "Cookie"

authorizationHeaderName :: HeaderName
authorizationHeaderName = "Authorization"

toLowerAscii :: Char -> Char
toLowerAscii c
  | c >= 'A' && c <= 'Z' = toEnum (fromEnum c + 32)
  | otherwise = c
