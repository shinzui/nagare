-- | A real Shomei server over a migrated test database, for the cases that
-- must see Shomei's own answers: its token signatures, its rotation and its
-- reuse detection.
module RealShomei (withRealShomeiServer, withRealShomeiServerAndPool, withOidcShomeiServer) where

import Control.Exception (bracket)
import Data.ByteString qualified as BS
import Data.IORef (newIORef)
import Hasql.Pool qualified as HasqlPool
import Nagare.Access.Prelude
import Network.HTTP.Client qualified as HC
import Network.Wai.Handler.Warp (testWithApplication)
import Servant.Health (ProbeVerdict (Healthy))
import Shomei.Account.Password.Hash.Postgres (Argon2Params (..), newHashingLimiter)
import Shomei.Authorization.Claims.Domain (Audience (..), Issuer (..))
import Shomei.Config (OAuthConfig (..), ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Mfa.Totp.Postgres (TotpEncryptionKey, totpEncryptionKeyFromBytes)
import Shomei.Migrations.TestSupport (withShomeiMigratedDatabase)
import Shomei.Notify (noNotifierSecrets)
import Shomei.Notify.Queue (newNotifierQueue)
import Shomei.Persistence.Pool.Postgres (acquirePool)
import Shomei.Servant.Api (shomeiThrottledRoutes)
import Shomei.Server.App qualified as ShomeiServer
import Shomei.Server.Boot qualified as ShomeiBoot
import Shomei.Server.Config (defaultDbStatementTimeoutMs)
import Shomei.Server.Keys (bootstrapKeys)
import Shomei.Server.Middleware.RateLimit (newRateLimiterFor, rateLimitMiddleware)
import Shomei.SigningKey.Domain (SigningAlgorithm (ES256))
import Shomei.SigningKey.Protection.Jwt (KeyEncryptionKey, keyEncryptionKeyFromBase64)

withRealShomeiServer :: (Int -> IO a) -> IO a
withRealShomeiServer action = withRealShomeiServerAndPool (const action)

-- | The same server, with the pool for tests that read Shomei's own tables.
withRealShomeiServerAndPool :: (HasqlPool.Pool -> Int -> IO a) -> IO a
withRealShomeiServerAndPool action =
  withShomeiServer (defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")) False (\env -> action (ShomeiServer.envPool env))

-- | EP-264: Shomei as the platform runs it with @NAGARE_AUTH_ISSUER@ set: a
-- URL issuer, the @nagare-access@ audience, OIDC on, the login URL at the
-- portal, and the per-client rate limiter of the standalone server in front.
withOidcShomeiServer :: Text -> (ShomeiServer.Env -> Int -> IO a) -> IO a
withOidcShomeiServer issuer =
  withShomeiServer
    base
      { oauthConfig = (oauthConfig base) {oidcEnabled = True, loginUrl = Just (issuer <> "/login")}
      }
    True
  where
    base = defaultShomeiConfig (Issuer issuer) (Audience "nagare-access")

withShomeiServer :: ShomeiConfig -> Bool -> (ShomeiServer.Env -> Int -> IO a) -> IO a
withShomeiServer shomeiCfg limited action =
  withShomeiMigratedDatabase $ \connStr ->
    bracket (acquirePool 4 10 defaultDbStatementTimeoutMs connStr) HasqlPool.release $ \pool -> do
      keys <- newIORef =<< bootstrapKeys testKek ES256 pool
      manager <- HC.newManager HC.defaultManagerSettings
      limiter <- newHashingLimiter 2
      notifierQueue <- newNotifierQueue 64
      let env =
            ShomeiServer.Env
              { ShomeiServer.envPool = pool
              , ShomeiServer.envConfig = shomeiCfg
              , ShomeiServer.envKeys = keys
              , ShomeiServer.envKek = testKek
              , ShomeiServer.envTotpKey = testTotpKey
              , ShomeiServer.envHttpManager = manager
              , ShomeiServer.envNotifierSecrets = noNotifierSecrets
              , ShomeiServer.envNotifierQueue = notifierQueue
              , ShomeiServer.envArgon2Params = testArgon2Params
              , ShomeiServer.envHashingLimiter = limiter
              }
      limiter' <- newRateLimiterFor shomeiThrottledRoutes (rateLimitConfig shomeiCfg)
      let served = ShomeiBoot.application env (pure Healthy) (pure Healthy)
      testWithApplication (pure (if limited then rateLimitMiddleware limiter' served else served)) (action env)

testKek :: KeyEncryptionKey
testKek = either (error . show) id (keyEncryptionKeyFromBase64 "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")

testTotpKey :: TotpEncryptionKey
testTotpKey = either (error . show) id (totpEncryptionKeyFromBytes (BS.replicate 32 0))

testArgon2Params :: Argon2Params
testArgon2Params = Argon2Params {memoryKiB = 8192, iterations = 1, parallelism = 1}
