-- | Cookie headers owned by the access enforcer.
module Nagare.Access.Cookie
  ( CookieSettings (..)
  , clearSessionCookieHeader
  , clearRefreshCookieHeader
  , csrfCookieHeader
  , decodeRefreshCookieValue
  , defaultCookieSettings
  , refreshCookieHeader
  , sessionCookieHeader
  , signedCookieSettings
  )
where

import Crypto.Hash (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac, hmacGetDigest)
import Data.ByteArray (convert)
import Data.ByteArray qualified as BA
import Data.ByteArray.Encoding (Base (Base64URLUnpadded), convertFromBase, convertToBase)
import Data.ByteString qualified as BS
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
  , cookieKey :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

defaultCookieSettings :: Text -> CookieSettings
defaultCookieSettings domain =
  CookieSettings
    { cookieDomain = domain
    , cookieSecure = True
    , cookieKey = Nothing
    }

signedCookieSettings :: Text -> Text -> CookieSettings
signedCookieSettings domain key =
  CookieSettings
    { cookieDomain = domain
    , cookieSecure = True
    , cookieKey = Just key
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

refreshCookieHeader :: CookieSettings -> Text -> Int -> Either Text Header
refreshCookieHeader settings refreshToken maxAgeSeconds = do
  domain <- safeCookiePart "cookie domain" (cookieDomain settings)
  key <- maybe (Left "NAGARE_ACCESS_COOKIE_KEY is required for refresh cookies") Right (cookieKey settings)
  value <- encodeRefreshCookieValue key refreshToken
  pure
    ( "Set-Cookie"
    , LBS.toStrict . Builder.toLazyByteString $
        Builder.byteString "nagare_refresh="
          <> Builder.byteString value
          <> Builder.byteString "; Domain="
          <> Builder.byteString domain
          <> Builder.byteString "; Path=/; Max-Age="
          <> Builder.intDec maxAgeSeconds
          <> Builder.byteString "; HttpOnly"
          <> securePart settings
          <> Builder.byteString "; SameSite=Lax"
    )

clearRefreshCookieHeader :: CookieSettings -> Either Text Header
clearRefreshCookieHeader settings = do
  domain <- safeCookiePart "cookie domain" (cookieDomain settings)
  pure
    ( "Set-Cookie"
    , "nagare_refresh=; Domain="
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

encodeRefreshCookieValue :: Text -> Text -> Either Text BC.ByteString
encodeRefreshCookieValue key refreshToken = do
  keyBytes <- safeCookiePart "cookie key" key
  tokenBytes <- safeCookiePart "refresh token" refreshToken
  let tokenPart = b64 tokenBytes
      signedPart = "v1." <> tokenPart
      macPart = b64 (macBytes keyBytes signedPart)
  pure (signedPart <> "." <> macPart)

decodeRefreshCookieValue :: Text -> Text -> Maybe Text
decodeRefreshCookieValue key value = do
  [version, tokenPartText, macPartText] <- pure (Text.splitOn "." value)
  if version == "v1" then Just () else Nothing
  let keyBytes = TE.encodeUtf8 key
      tokenPart = TE.encodeUtf8 tokenPartText
      macPart = TE.encodeUtf8 macPartText
      signedPart = "v1." <> tokenPart
  tokenBytes <- either (const Nothing) Just (convertFromBase Base64URLUnpadded tokenPart :: Either String BS.ByteString)
  providedMacBytes <- either (const Nothing) Just (convertFromBase Base64URLUnpadded macPart :: Either String BS.ByteString)
  -- Compare the raw MAC bytes with an explicitly constant-time primitive, the
  -- same way 'Nagare.Static.Webhook.verifySignature' does. Comparing HMAC
  -- values with (==) happens to be constant-time in crypton today, but that is
  -- a property of an instance chosen by resolution rather than something a
  -- reader of this function can see. 'BA.constEq' also returns False on a
  -- length mismatch without an early exit, which subsumes the length check the
  -- old digestFromByteString round-trip performed.
  let expectedMacBytes = macBytes keyBytes signedPart
  if BA.constEq providedMacBytes expectedMacBytes
    then either (const Nothing) Just (TE.decodeUtf8' tokenBytes)
    else Nothing

macBytes :: BC.ByteString -> BC.ByteString -> BC.ByteString
macBytes key message =
  convert (hmacGetDigest (hmac key message :: HMAC SHA256))

b64 :: BS.ByteString -> BS.ByteString
b64 =
  convertToBase Base64URLUnpadded
