-- | Fetch and cache Shomei's public JWKS document.
module Nagare.Access.Jwks
  ( JwksCache
  , decodeJwks
  , fetchJwksFromShomei
  , getCachedJwks
  , jwksUrlFor
  , newJwksCache
  )
where

import Control.Exception (try)
import Crypto.JOSE.JWK (JWKSet)
import Data.Aeson (eitherDecodeStrict)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Access.Config (AuthPlaneConfig (..))
import Nagare.Access.Prelude
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types (status200)

data JwksCache = JwksCache
  { ttlSeconds :: !Int
  , nowSeconds :: !(IO Int)
  , fetchJwks :: !(IO (Either Text JWKSet))
  , cacheState :: !(IORef (Maybe (Int, JWKSet)))
  }
  deriving stock (Generic)

newJwksCache :: Int -> IO Int -> IO (Either Text JWKSet) -> IO JwksCache
newJwksCache ttlSeconds nowSeconds fetchJwks = do
  cacheState <- newIORef Nothing
  pure JwksCache {ttlSeconds, nowSeconds, fetchJwks, cacheState}

-- | How long past its TTL a fetched key set keeps verifying while Shomei
-- cannot be reached. Shomei rotates keys only on operator action and keeps
-- retired keys published, so an older set still verifies the tokens it
-- issued. Without this, once the cached set expired during a Shomei outage,
-- every session check failed until Shomei came back (EP-211).
jwksMaxStaleSeconds :: Int
jwksMaxStaleSeconds = 24 * 60 * 60

getCachedJwks :: JwksCache -> IO (Either Text JWKSet)
getCachedJwks cache
  | cache ^. #ttlSeconds <= 0 =
      cache ^. #fetchJwks
  | otherwise = do
      now <- cache ^. #nowSeconds
      cached <- readIORef (cache ^. #cacheState)
      case cached of
        Just (expiresAt, jwks)
          | now < expiresAt -> pure (Right jwks)
        _ -> do
          loaded <- cache ^. #fetchJwks
          case (loaded, cached) of
            (Right jwks, _) -> do
              writeIORef (cache ^. #cacheState) (Just (now + cache ^. #ttlSeconds, jwks))
              pure loaded
            (Left _, Just (expiresAt, jwks))
              | now < expiresAt + jwksMaxStaleSeconds -> pure (Right jwks)
            (Left _, _) ->
              pure loaded

fetchJwksFromShomei :: HC.Manager -> AuthPlaneConfig -> IO (Either Text JWKSet)
fetchJwksFromShomei manager cfg = do
  requestOrError <- try (HC.parseRequest (Text.unpack (jwksUrlFor cfg)))
  case requestOrError of
    Left (err :: HC.HttpException) ->
      pure (Left ("could not build Shomei JWKS request: " <> Text.pack (show err)))
    Right request -> do
      responseOrError <- try (HC.httpLbs request manager)
      pure $ case responseOrError of
        Left (err :: HC.HttpException) ->
          Left ("could not fetch Shomei JWKS: " <> Text.pack (show err))
        Right response
          | HC.responseStatus response == status200 ->
              decodeJwks (LBS.toStrict (HC.responseBody response))
          | otherwise ->
              Left ("Shomei JWKS request returned " <> Text.pack (show (HC.responseStatus response)))

jwksUrlFor :: AuthPlaneConfig -> Text
jwksUrlFor cfg =
  Text.dropWhileEnd (== '/') (cfg ^. #shomeiUrl) <> "/.well-known/jwks.json"

decodeJwks :: ByteString -> Either Text JWKSet
decodeJwks bytes =
  case eitherDecodeStrict bytes of
    Left err -> Left ("could not decode Shomei JWKS: " <> Text.pack err)
    Right jwks -> Right jwks
