module Main (main) where

import Data.ByteString qualified as BS
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Nagare.Access.App (appWithBackends, appWithRuntime)
import Nagare.Access.Auth (AccessServices (..))
import Nagare.Access.BackendMap (BackendMap, decodeBackendMap, emptyBackendMap)
import Nagare.Access.Config (AuthPlaneConfig (..), RuntimeConfig (..), listenPort, parseRuntimeConfig)
import Nagare.Access.Cookie (defaultCookieSettings)
import Nagare.Access.DecisionCache (newDecisionCache)
import Nagare.Access.En (authorizeWithEn, enClientEnvFromAuthPlane)
import Nagare.Access.Jwks (fetchJwksFromShomei, newJwksCache)
import Nagare.Access.Proxy (newProxyManager, proxyForwarder)
import Nagare.Access.Shomei (verifyShomeiCredentialCached)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (run)
import System.Environment (getEnvironment)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

defaultJwksTtlSeconds :: Int
defaultJwksTtlSeconds = 300

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  runtime <- either (fail . Text.unpack) pure . parseRuntimeConfig =<< getEnvironment
  backends <- loadBackends (backendMapPath runtime)
  waiApp <- appForRuntime runtime backends
  let port = listenPort (runtimeListen runtime)
  putStrLn ("nagare-access listening on :" <> show port)
  run port waiApp

appForRuntime :: RuntimeConfig -> BackendMap -> IO Application
appForRuntime runtime backends =
  case authPlaneConfig runtime of
    Nothing ->
      pure (appWithBackends backends)
    Just cfg ->
      appWithRuntime backends <$> buildAccessServices runtime cfg

buildAccessServices :: RuntimeConfig -> AuthPlaneConfig -> IO AccessServices
buildAccessServices runtime cfg = do
  manager <- newProxyManager
  jwksCache <-
    newJwksCache
      defaultJwksTtlSeconds
      currentSeconds
      (fetchJwksFromShomei manager cfg)
  enEnv <- either (fail . Text.unpack) pure =<< enClientEnvFromAuthPlane manager cfg
  decisionCache <- newDecisionCache (decisionTtlSeconds runtime) currentSeconds
  pure
    AccessServices
      { verifyCredential = verifyShomeiCredentialCached jwksCache cfg
      , authorizeUser = authorizeWithEn enEnv
      , forwardAuthorized = proxyForwarder manager
      , decisionCache
      , cookieSettings = Just (defaultCookieSettings (cookieDomain cfg))
      }

loadBackends :: Maybe FilePath -> IO BackendMap
loadBackends Nothing = pure emptyBackendMap
loadBackends (Just "") = pure emptyBackendMap
loadBackends (Just path) = do
  bytes <- BS.readFile path
  either (fail . Text.unpack) pure (decodeBackendMap bytes)

currentSeconds :: IO Int
currentSeconds =
  floor <$> getPOSIXTime
