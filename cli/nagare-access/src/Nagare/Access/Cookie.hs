-- | Cookie headers owned by the access enforcer.
module Nagare.Access.Cookie
  ( CookieSettings (..)
  , clearSessionCookieHeader
  , csrfCookieHeader
  , defaultCookieSettings
  , sessionCookieHeader
  )
where

import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types.Header (Header)

data CookieSettings = CookieSettings
  { cookieDomain :: !Text
  , cookieSecure :: !Bool
  }
  deriving stock (Eq, Show)

defaultCookieSettings :: Text -> CookieSettings
defaultCookieSettings domain =
  CookieSettings
    { cookieDomain = domain
    , cookieSecure = True
    }

sessionCookieHeader :: CookieSettings -> Text -> Int -> Either Text Header
sessionCookieHeader settings token maxAgeSeconds = do
  domain <- safeCookiePart "cookie domain" (cookieDomain settings)
  value <- safeCookiePart "session cookie value" token
  pure
    ( "Set-Cookie"
    , LBS.toStrict . Builder.toLazyByteString $
        Builder.byteString "nagare_session="
          <> Builder.byteString value
          <> Builder.byteString "; Domain="
          <> Builder.byteString domain
          <> Builder.byteString "; Path=/; Max-Age="
          <> Builder.intDec maxAgeSeconds
          <> Builder.byteString "; HttpOnly"
          <> securePart settings
          <> Builder.byteString "; SameSite=Lax"
    )

clearSessionCookieHeader :: CookieSettings -> Either Text Header
clearSessionCookieHeader settings = do
  domain <- safeCookiePart "cookie domain" (cookieDomain settings)
  pure
    ( "Set-Cookie"
    , "nagare_session=; Domain="
        <> domain
        <> "; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly"
        <> LBS.toStrict (Builder.toLazyByteString (securePart settings))
        <> "; SameSite=Lax"
    )

csrfCookieHeader :: Text -> Int -> Either Text Header
csrfCookieHeader token maxAgeSeconds = do
  value <- safeCookiePart "csrf cookie value" token
  pure
    ( "Set-Cookie"
    , LBS.toStrict . Builder.toLazyByteString $
        Builder.byteString "__Host-nagare_csrf="
          <> Builder.byteString value
          <> Builder.byteString "; Path=/; Max-Age="
          <> Builder.intDec maxAgeSeconds
          <> Builder.byteString "; Secure; SameSite=Lax"
    )

securePart :: CookieSettings -> Builder.Builder
securePart settings =
  if cookieSecure settings
    then Builder.byteString "; Secure"
    else mempty

safeCookiePart :: Text -> Text -> Either Text BC.ByteString
safeCookiePart label value
  | Text.null value = Left (label <> " must not be empty")
  | Text.any badCookieChar value = Left (label <> " contains a character that is not valid in Set-Cookie")
  | otherwise = Right (TE.encodeUtf8 value)

badCookieChar :: Char -> Bool
badCookieChar c =
  c <= ' ' || c == ';' || c == ',' || c == '\DEL'
