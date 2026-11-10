{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The servers behind the browser suite (EP-239): a real Shomei, the enforcer,
-- a control enforcer that behaves as before the rotation redirect, a plain
-- upstream whose responses a test holds open, and a control API for the
-- Playwright tests. Every measured upstream request belongs to one case, so one
-- test attempt can neither see nor release another's work.
module Main (main) where

import Control.Concurrent (forkIO, myThreadId, threadDelay, throwTo)
import Control.Concurrent.STM
import Control.Exception (SomeException, bracket_, catch, finally)
import Control.Monad (forever, void)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Builder qualified as Builder
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.UUID (UUID, toText)
import Data.UUID.V4 (nextRandom)
import GHC.Clock (getMonotonicTime)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as HasqlPool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Nagare.Access.App (appWithRuntime)
import Nagare.Access.Auth
import Nagare.Access.BackendMap
import Nagare.Access.Config (AuthPlaneConfig (..))
import Nagare.Access.Cookie (signedCookieSettings)
import Nagare.Access.DecisionCache (AccessDecision (..), AuthorizationResult (..), disabledDecisionCache)
import Nagare.Access.Jwks (fetchJwksFromShomei, newJwksCache)
import Nagare.Access.Prelude hiding ((.=))
import Nagare.Access.Proxy (newProxyManager, portalForwarder, proxyForwarder)
import Nagare.Access.RefreshCoalescer (RefreshCoalescer, coalesceRefresh, newRefreshCoalescer)
import Nagare.Access.Shomei (verifyShomeiCredentialCached)
import Nagare.Access.ShomeiClient (completeMfaWithShomei, loginWithShomei, logoutWithShomei, refreshWithShomei, shomeiLoginEnvFromAuthPlane)
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types (Status, hContentType, status200, status400, status404, status500)
import Network.Wai
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import RealShomei (withRealShomeiServerAndPool)
import Shomei.Account.Dto qualified as ShomeiAccountDTO
import Shomei.Account.User.Dto (UserResponse (..))
import Shomei.Client qualified as ShomeiClient
import Shomei.Id (UserId, parseId, userIdToUUID)
import System.Environment (lookupEnv)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import System.Timeout (timeout)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  enabled <- lookupEnv "NAGARE_ACCESS_BROWSER_HARNESS"
  if enabled == Just "1"
    then runHarness
    else putStrLn "nagare-access-browser-harness only runs under `just access-browser-test`; exiting."

enforcerPort, legacyEnforcerPort, controlPort, upstreamPort :: Int
enforcerPort = 18780
legacyEnforcerPort = 18782
controlPort = 18781
upstreamPort = 18783

-- | Short, so a test can wait past it.
coalescerWindowSeconds :: Int
coalescerWindowSeconds = 2

-- | Longer than a test's deadline, so only an explicit release ends a hold.
heldUpstreamTimeoutSeconds :: Int
heldUpstreamTimeoutSeconds = 120

caseDeleteMicroseconds :: Int
caseDeleteMicroseconds = 10000000

runHarness :: IO ()
runHarness = do
  cases <- newCases
  main' <- myThreadId
  let serve port application =
        void . forkIO $
          runSettings (setPort port (setHost "127.0.0.1" defaultSettings)) application
            `catch` \(err :: SomeException) -> throwTo main' err
  withRealShomeiServerAndPool
    ( \pool shomeiPort -> do
        manager <- newProxyManager
        let shomeiUrl = "http://127.0.0.1:" <> show shomeiPort
            authPlane =
              AuthPlaneConfig
                { shomeiUrl = Text.pack shomeiUrl
                , shomeiIssuer = "shomei"
                , shomeiAudience = "shomei-clients"
                , enUrl = "http://127.0.0.1:1"
                , enApiKey = Nothing
                , cookieDomain = ".example.test"
                , cookieKey = Just "browser-harness-cookie-secret"
                }
        jwksCache <- newJwksCache 300 currentSeconds (fetchJwksFromShomei manager authPlane)
        shomeiEnv <- shomeiLoginEnvFromAuthPlane authPlane
        signupEnv <- ShomeiClient.shomeiClientEnv shomeiUrl
        coalescer <- newRefreshCoalescer coalescerWindowSeconds currentSeconds
        legacyCoalescer <- newRefreshCoalescer coalescerWindowSeconds currentSeconds
        let services refresh =
              AccessServices
                { verifyCredential = verifyShomeiCredentialCached jwksCache authPlane
                , authorizeUser = \_ _ -> pure (AuthorizationDecision AccessAllowed)
                , forwardAuthorized = proxyForwarder manager
                , loginUser = loginWithShomei shomeiEnv
                , completeMfa = completeMfaWithShomei shomeiEnv
                , refreshUserSession = refresh
                , revokeSession = logoutWithShomei shomeiEnv
                , forwardPortal = portalForwarder manager
                , fetchPortalPage = \_ _ -> pure Nothing
                , newCsrfToken = toText <$> nextRandom
                , decisionCache = disabledDecisionCache
                , cookieSettings = Just (signedCookieSettings ".example.test" "browser-harness-cookie-secret")
                }
            refreshWith :: RefreshCoalescer -> Text -> IO RefreshResult
            refreshWith shared = coalesceRefresh shared (refreshWithShomei shomeiEnv)
            -- Today's behaviour without any production switch: nothing leads.
            refreshLegacy token = (#role .~ RefreshShared) <$> refreshWith legacyCoalescer token
        serve upstreamPort (upstreamApp cases)
        serve enforcerPort (appWithRuntime (routesFor ["app.example.test", "other.example.test"]) (services (refreshWith coalescer)))
        serve legacyEnforcerPort (appWithRuntime (routesFor ["legacy.example.test"]) (services refreshLegacy))
        serve controlPort (controlApp cases pool signupEnv)
        putStrLn "browser harness ready"
        forever (threadDelay 1000000)
    )
    `finally` releaseAll cases

routesFor :: [Text] -> BackendMap
routesFor hosts =
  either (error . Text.unpack) id . backendMapFromTargets $
    [ (host, BackendTarget (Text.pack ("http://127.0.0.1:" <> show upstreamPort)) ProtectedBackend Nothing (Just heldUpstreamTimeoutSeconds))
    | host <- hosts
    ]

currentSeconds :: IO Int
currentSeconds = floor <$> getMonotonicTime

-- Cases: one per test attempt, each with its own counters and barrier.

data Cases = Cases
  { nextId :: !(TVar Int)
  , entries :: !(TVar (Map Text CaseState))
  }
  deriving stock (Generic)

data CaseState = CaseState
  { counts :: !(TVar (Map ByteString Int))
  , released :: !(TVar Bool)
  , activeHandlers :: !(TVar Int)
  }
  deriving stock (Generic)

newCases :: IO Cases
newCases = Cases <$> newTVarIO 0 <*> newTVarIO Map.empty

allocateCase :: Cases -> IO Text
allocateCase cases = atomically $ do
  n <- readTVar (cases ^. #nextId)
  writeTVar (cases ^. #nextId) (n + 1)
  state <- CaseState <$> newTVar Map.empty <*> newTVar False <*> newTVar 0
  let caseId = "case-" <> Text.pack (show n)
  modifyTVar' (cases ^. #entries) (Map.insert caseId state)
  pure caseId

lookupCase :: Cases -> Text -> STM (Maybe CaseState)
lookupCase cases caseId = Map.lookup caseId <$> readTVar (cases ^. #entries)

release :: CaseState -> STM ()
release state = writeTVar (state ^. #released) True

releaseAll :: Cases -> IO ()
releaseAll cases =
  atomically (readTVar (cases ^. #entries) >>= traverse_ release)

awaitRelease :: CaseState -> IO ()
awaitRelease state = atomically (readTVar (state ^. #released) >>= check)

-- | Release the case, wait for its handlers, then forget it. A second delete of
-- the same case finds nothing and is still a success.
deleteCase :: Cases -> Text -> IO Bool
deleteCase cases caseId = do
  found <- atomically $ do
    state <- lookupCase cases caseId
    traverse_ release state
    pure state
  case found of
    Nothing -> pure True
    Just state ->
      maybe False (const True)
        <$> timeout
          caseDeleteMicroseconds
          ( atomically $ do
              active <- readTVar (state ^. #activeHandlers)
              check (active == 0)
              modifyTVar' (cases ^. #entries) (Map.delete caseId)
          )

-- The plain upstream.

upstreamApp :: Cases -> Application
upstreamApp cases req respond =
  case queryText "case" req of
    Nothing -> respond (plainResponse req)
    Just caseId -> do
      claimed <- atomically $ do
        found <- lookupCase cases caseId
        case found of
          Nothing -> pure Nothing
          Just state -> do
            modifyTVar' (state ^. #activeHandlers) (+ 1)
            modifyTVar' (state ^. #counts) (Map.insertWith (+) (rawPathInfo req) 1)
            pure (Just state)
      case claimed of
        Nothing -> respond (responseLBS status404 [] "unknown case\n")
        Just state ->
          -- The decrement is what lets a delete finish, so it must run even
          -- when the peer has already gone.
          finallyDecrement state $
            case pathInfo req of
              ["held"] -> awaitRelease state >> respond (plainResponse req)
              ["sse"] -> respond (sseResponse state)
              _ -> respond (plainResponse req)

finallyDecrement :: CaseState -> IO a -> IO a
finallyDecrement state = bracket_ (pure ()) (atomically (modifyTVar' (state ^. #activeHandlers) (subtract 1)))

plainResponse :: Request -> Response
plainResponse req =
  responseLBS status200 ((hContentType, "text/plain; charset=utf-8") : corsHeaders) "ok\n"
  where
    corsHeaders =
      case lookup "Origin" (requestHeaders req) of
        Just origin -> [("Access-Control-Allow-Origin", origin), ("Access-Control-Allow-Credentials", "true")]
        Nothing -> []

sseResponse :: CaseState -> Response
sseResponse state =
  responseStream status200 [(hContentType, "text/event-stream"), ("Cache-Control", "no-store")] $ \write flush -> do
    write (Builder.byteString "data: ready\n\n")
    flush
    awaitRelease state

-- The control API.

controlApp :: Cases -> HasqlPool.Pool -> ShomeiClient.ClientEnv -> Application
controlApp cases pool signupEnv req respond =
  respond =<< case (requestMethod req, pathInfo req) of
    ("GET", ["healthz"]) -> pure (json status200 (object ["ok" .= True]))
    ("POST", ["users"]) -> createUser signupEnv
    ("POST", ["cases"]) -> do
      caseId <- allocateCase cases
      pure (json status200 (object ["id" .= caseId]))
    ("GET", ["counts"]) -> withCase $ \state -> atomically $ do
      seen <- readTVar (state ^. #counts)
      isReleased <- readTVar (state ^. #released)
      let count = Map.findWithDefault 0 (maybe "" TE.encodeUtf8 (queryText "path" req)) seen
      pure (json status200 (object ["count" .= count, "arrived" .= (count > 0), "released" .= isReleased]))
    ("POST", ["release"]) -> withCase $ \state -> do
      atomically (release state)
      pure (json status200 (object ["released" .= True]))
    ("DELETE", ["cases", caseId]) -> do
      deleted <- deleteCase cases caseId
      pure $
        if deleted
          then json status200 (object ["deleted" .= True])
          else json status500 (object ["error" .= ("handlers did not settle" :: Text)])
    ("GET", ["reuse-alarms"]) -> reuseAlarmsResponse pool (queryText "user" req)
    _ -> pure (json status404 (object ["error" .= ("not found" :: Text)]))
  where
    -- An unknown case is a failure, never a count of zero.
    withCase act =
      case queryText "case" req of
        Nothing -> pure (json status400 (object ["error" .= ("case is required" :: Text)]))
        Just caseId ->
          atomically (lookupCase cases caseId)
            >>= maybe (pure (json status404 (object ["error" .= ("unknown case" :: Text)]))) act

createUser :: ShomeiClient.ClientEnv -> IO Response
createUser env = do
  suffix <- toText <$> nextRandom
  let login = "person-" <> suffix
      password = "A-long-random-password-42"
  result <-
    ShomeiClient.signup
      env
      ShomeiAccountDTO.SignupRequest
        { ShomeiAccountDTO.loginId = login
        , ShomeiAccountDTO.email = Just (login <> "@example.test")
        , ShomeiAccountDTO.password = password
        , ShomeiAccountDTO.displayName = login
        }
  pure $ case result of
    Right (ShomeiClient.ApplicationSuccess response) ->
      json status200 (object ["login" .= login, "password" .= password, "userId" .= (ShomeiClient.cookieBody response).user.userId])
    _ -> json status500 (object ["error" .= ("signup failed" :: Text)])

reuseAlarmsResponse :: HasqlPool.Pool -> Maybe Text -> IO Response
reuseAlarmsResponse pool user =
  case user >>= either (const Nothing) Just . (parseId :: Text -> Either Text UserId) of
    Nothing -> pure (json status400 (object ["error" .= ("a user id is required" :: Text)]))
    Just userId -> do
      result <- HasqlPool.use pool (Session.statement (userIdToUUID userId) reuseAlarmsStatement)
      pure $ case result of
        Right count -> json status200 (object ["count" .= count])
        Left err -> json status500 (object ["error" .= Text.pack (show err)])

-- | Shomei records this event against the session and leaves its @user_id@
-- NULL, so the owner comes from the session.
reuseAlarmsStatement :: Statement UUID Int64
reuseAlarmsStatement =
  preparable
    "SELECT count(*) FROM shomei.shomei_auth_events e JOIN shomei.shomei_sessions s ON s.session_id = e.session_id WHERE e.event_type = 'refresh_token_reuse_detected' AND s.user_id = $1"
    (E.param (E.nonNullable E.uuid))
    (D.singleRow (D.column (D.nonNullable D.int8)))

json :: Status -> Value -> Response
json status body = responseLBS status [(hContentType, "application/json")] (encode body)

queryText :: ByteString -> Request -> Maybe Text
queryText name req =
  lookup name (queryString req) >>= id >>= either (const Nothing) Just . TE.decodeUtf8'
