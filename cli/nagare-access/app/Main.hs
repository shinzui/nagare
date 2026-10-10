module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (IOException, try)
import Control.Monad (forever, when)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.UUID (toText)
import Data.UUID.V4 (nextRandom)
import Nagare.Access.App (appWithBackends, appWithRuntime)
import Nagare.Access.Auth (AccessServices (..))
import Nagare.Access.BackendMap (BackendMap, emptyBackendMap)
import Nagare.Access.BackendSource (BackendSource, RefreshResult (..), liveApplication, newBackendSource, refreshBackends)
import Nagare.Access.Config (AuthPlaneConfig (..), RuntimeConfig (..), listenPort, parseRuntimeConfig)
import Nagare.Access.Cookie (CookieSettings, defaultCookieSettings, signedCookieSettings)
import Nagare.Access.DecisionCache (newDecisionCache)
import Nagare.Access.En (authorizeWithEn, enClientEnvFromAuthPlane)
import Nagare.Access.Jwks (fetchJwksFromShomei, newJwksCache)
import Nagare.Access.Prelude
import Nagare.Access.Proxy (newProxyManager, portalForwarder, portalPageFetcher, proxyForwarder)
import Nagare.Access.Shomei (verifyShomeiCredentialCached)
import Nagare.Access.ShomeiClient (completeMfaWithShomei, loginWithShomei, logoutWithShomei, refreshWithShomei, shomeiLoginEnvFromAuthPlane)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (run)
import System.Environment (getEnvironment)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

defaultJwksTtlSeconds :: Int
defaultJwksTtlSeconds = 300

-- | How often the mounted backend map is re-read. The kubelet already delays a
-- ConfigMap change by up to its sync period, so a few seconds more is noise.
backendRefreshMicroseconds :: Int
backendRefreshMicroseconds = 5000000

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  runtime <- either (fail . Text.unpack) pure . parseRuntimeConfig =<< getEnvironment
  build <- appForRuntime runtime
  waiApp <- case runtime ^. #backendMapPath of
    Just path | not (null path) -> do
      source <- either (fail . Text.unpack) pure =<< newBackendSource (BS.readFile path)
      _ <- forkIO (refreshLoop path source)
      pure (liveApplication source build)
    _ -> pure (build emptyBackendMap)
  let port = listenPort (runtime ^. #listen)
  putStrLn ("nagare-access listening on :" <> show port)
  run port waiApp

appForRuntime :: RuntimeConfig -> IO (BackendMap -> Application)
appForRuntime runtime =
  case runtime ^. #authPlaneConfig of
    Nothing ->
      pure appWithBackends
    Just cfg -> do
      services <- buildAccessServices runtime cfg
      pure (`appWithRuntime` services)

-- | Pick up reviewed changes to the mounted backend map. A map that does not
-- decode is logged and the routes already in force keep serving.
refreshLoop :: FilePath -> BackendSource -> IO ()
refreshLoop path source = forever $ do
  threadDelay backendRefreshMicroseconds
  result <- try (refreshBackends source)
  case result of
    Right Unchanged -> pure ()
    Right Reloaded -> putStrLn ("reloaded backend map " <> path)
    Right (Rejected err) -> putStrLn ("kept the previous backend map; " <> path <> " does not decode: " <> Text.unpack err)
    Left (err :: IOException) -> putStrLn ("kept the previous backend map; reading " <> path <> " failed: " <> show err)

buildAccessServices :: RuntimeConfig -> AuthPlaneConfig -> IO AccessServices
buildAccessServices runtime cfg = do
  -- An omitted key is allowed for an intentionally unauthenticated En, but the
  -- safe default remains fail-closed: an authenticated En rejects the call and
  -- nagare-access turns that failure into 503 rather than granting access.
  when (cfg ^. #enApiKey == Nothing) $
    putStrLn "warning: NAGARE_ACCESS_EN_API_KEY is not set; authenticated En requests will fail closed with 503"
  manager <- newProxyManager
  jwksCache <-
    newJwksCache
      defaultJwksTtlSeconds
      currentSeconds
      (fetchJwksFromShomei manager cfg)
  enEnv <- either (fail . Text.unpack) pure =<< enClientEnvFromAuthPlane manager cfg
  shomeiLoginEnv <- shomeiLoginEnvFromAuthPlane cfg
  decisionCache <- newDecisionCache (runtime ^. #decisionTtlSeconds) currentSeconds
  pure
    AccessServices
      { verifyCredential = verifyShomeiCredentialCached jwksCache cfg
      , authorizeUser = authorizeWithEn enEnv
      , forwardAuthorized = proxyForwarder manager
      , loginUser = loginWithShomei shomeiLoginEnv
      , completeMfa = completeMfaWithShomei shomeiLoginEnv
      , refreshUserSession = refreshWithShomei shomeiLoginEnv
      , revokeSession = logoutWithShomei shomeiLoginEnv
      , forwardPortal = portalForwarder manager
      , fetchPortalPage = portalPageFetcher manager
      , newCsrfToken = toText <$> nextRandom
      , decisionCache
      , cookieSettings = Just (cookieSettingsFromAuthPlane cfg)
      }

cookieSettingsFromAuthPlane :: AuthPlaneConfig -> CookieSettings
cookieSettingsFromAuthPlane cfg =
  case cfg ^. #cookieKey of
    Nothing -> defaultCookieSettings (cfg ^. #cookieDomain)
    Just key -> signedCookieSettings (cfg ^. #cookieDomain) key

currentSeconds :: IO Int
currentSeconds =
  floor <$> getPOSIXTime
