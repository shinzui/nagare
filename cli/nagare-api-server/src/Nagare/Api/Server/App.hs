-- | The admin API as a WAI application.
--
-- Every error Nagare produces before a response is committed is an RFC 9457
-- problem, even without an Accept header: handler alternatives, Servant's
-- own rejections through 'ErrorFormatters', and the 405 and 406 Servant
-- raises outside them, rewritten by 'problemResponses' (which keeps
-- @Allow@). Error responses are never stored. Admission bounds concurrent
-- @/v1@ requests and answers excess at once with 503 @server_busy@ and
-- @Retry-After@.
module Nagare.Api.Server.App
  ( AppConfig (..)
  , adminApplication
  , adminServer
  )
where

import Control.Exception (SomeAsyncException, SomeException, bracket_, evaluate, fromException, throwIO, try)
import Data.Aeson (encode)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (getCurrentTime)
import Nagare.Api.Access.Handler (accessServer)
import Nagare.Api.Inventory.Handler (inventoryServer)
import Nagare.Api.OpenApi (renderAdminOpenApi)
import Nagare.Api.Platform.Routes (PlatformRoutes (..))
import Nagare.Api.Routes (AdminApi (..), adminApi)
import Nagare.Api.Server.RequestLog (requestLog)
import Nagare.Api.Server.Serve
import Nagare.Api.Server.Validators (errorCacheControl)
import Nagare.Api.Sites.Handler (sitesServer)
import Nagare.Contract.Prelude
import Nagare.Contract.Problem
  ( ProblemDetails
  , badRequest
  , internalError
  , methodNotAllowed
  , notAcceptable
  , notFound
  , problemFor
  , serverBusy
  )
import Nagare.Contract.V1 (VersionInfo)
import Nagare.Inventory.Recorded (readRecordedHead)
import Network.HTTP.Types (ResponseHeaders, Status, hCacheControl, hContentType, status405, status406, status500, status503, statusCode)
import Network.Wai (Application, Middleware, Response, mapResponseHeaders, pathInfo, responseHeaders, responseLBS, responseStatus)
import Servant.Health (ProbeVerdict (..), healthServer)
import Servant.Server
  ( ErrorFormatters (..)
  , Handler
  , ServerError (..)
  , defaultErrorFormatters
  , err400
  , err404
  , serveWithContext
  )
import Servant.Server qualified as Servant
import Servant.Server.Generic (AsServerT)
import System.Timeout (timeout)

data AppConfig = AppConfig
  { context :: !Text
  , version :: !VersionInfo
  , admission :: !Int
  , logSink :: !(ByteString -> IO ())
  -- ^ Where each access line goes: stdout in the server.
  }
  deriving stock (Generic)

adminApplication :: AppConfig -> Env -> IO Application
adminApplication config env = do
  -- Build the served documents once, before any request: concurrent first
  -- forcing of one large top-level thunk was observed spinning on its
  -- blackhole (GHC 9.12, many capabilities).
  _ <- evaluate (LBS.length renderAdminOpenApi + LBS.length (encode (config ^. #version)))
  inFlight <- newIORef 0
  let application = serveWithContext adminApi (formatters Servant.:. Servant.EmptyContext) (adminServer config env)
  pure (requestLog env (config ^. #logSink) (problemResponses (admitted (config ^. #admission) inFlight application)))

adminServer :: AppConfig -> Env -> AdminApi (AsServerT Handler)
adminServer config env =
  AdminApi
    { platform = PlatformRoutes {version = serveBuild (build env) versionBytes}
    , inventory = inventoryServer env (config ^. #context)
    , sites = sitesServer env (config ^. #context)
    , access = accessServer env (config ^. #context)
    , openapi = serveBuild (build env) renderAdminOpenApi
    , health = healthServer (pure Healthy) ready
    }
  where
    versionBytes = encode (config ^. #version)
    -- Readiness checks a fresh bound head within one second and loads no
    -- scope; a probe failure is a status report, not an application error.
    ready = do
      checked <- timeout 1000000 (readRecordedHead (reader env))
      case checked of
        Just (Right _) -> pure Healthy
        _ -> Unhealthy "inventory-store" <$> getCurrentTime

formatters :: ErrorFormatters
formatters =
  defaultErrorFormatters
    { bodyParserErrorFormatter = \_ _ message -> problemError err400 (problemFor badRequest (Text.pack message))
    , urlParseErrorFormatter = \_ _ message -> problemError err400 (problemFor badRequest (Text.pack message))
    , headerParseErrorFormatter = \_ _ message -> problemError err400 (problemFor badRequest (Text.pack message))
    , notFoundErrorFormatter = \_ -> problemError err404 (problemFor notFound "no such route")
    }

problemError :: ServerError -> ProblemDetails -> ServerError
problemError base problem =
  base
    { errBody = encode problem
    , errHeaders = [(hContentType, "application/problem+json"), (hCacheControl, TE.encodeUtf8 errorCacheControl)]
    }

-- | Rewrite Servant's bodyless 405 and 406 as problems, mark every error
-- response @no-store@, and answer a synchronous failure that escaped a
-- handler with a sanitized 500 if nothing was sent yet.
problemResponses :: Middleware
problemResponses application request respond = do
  sent <- newIORef False
  outcome <- try (application request (\response -> writeIORef sent True >> respond (rewrite response)))
  case outcome of
    Right received -> pure received
    Left (failure :: SomeException)
      | Just (_ :: SomeAsyncException) <- fromException failure -> throwIO failure
      | otherwise -> do
          already <- readIORef sent
          if already then throwIO failure else respond (problemResponse status500 [] (problemFor internalError "the request failed unexpectedly"))
  where
    rewrite response
      | code == 405 && not (isProblem response) =
          problemResponse status405 (filter ((== "Allow") . fst) (responseHeaders response)) (problemFor methodNotAllowed "only GET and HEAD are served")
      | code == 406 && not (isProblem response) =
          problemResponse status406 [] (problemFor notAcceptable "the representation is application/json")
      | code >= 400 = mapResponseHeaders noStore response
      | otherwise = response
      where
        code = statusCode (responseStatus response)
    isProblem response = lookup hContentType (responseHeaders response) == Just "application/problem+json"
    noStore headers = (hCacheControl, TE.encodeUtf8 errorCacheControl) : filter ((/= hCacheControl) . fst) headers

problemResponse :: Status -> ResponseHeaders -> ProblemDetails -> Response
problemResponse status extra problem =
  responseLBS status ([(hContentType, "application/problem+json"), (hCacheControl, TE.encodeUtf8 errorCacheControl)] <> extra) (encode problem)

-- | At most @limit@ concurrent @/v1@ requests; the excess is refused at
-- once rather than queued. Probes are never refused.
admitted :: Int -> IORef Int -> Middleware
admitted limit inFlight application request respond
  | take 1 (pathInfo request) /= ["v1"] = application request respond
  | otherwise = do
      admittedNow <- atomicModifyIORef' inFlight (\count -> if count < limit then (count + 1, True) else (count, False))
      if admittedNow
        then bracket_ (pure ()) (atomicModifyIORef' inFlight (\count -> (count - 1, ()))) (application request respond)
        else respond (problemResponse status503 [("Retry-After", "1")] (problemFor serverBusy "the admin API is at its admission limit; retry shortly"))
