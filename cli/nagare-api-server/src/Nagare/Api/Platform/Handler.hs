-- | @/v1/platform@: the serving build, and the platform-versions document
-- (EP-236).
--
-- The versions document reads one snapshot object under the request
-- deadline and never runs a provider: the snapshot was collected by
-- @nagarectl platform versions refresh@. A missing, unreadable, corrupt,
-- oversized or foreign snapshot is still a 200 with the serving build and
-- the snapshot's reason. The ETag is computed from the exact bytes on every
-- request; the snapshot is mutable, so no representation is cached.
module Nagare.Api.Platform.Handler
  ( platformServer
  )
where

import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Nagare.Api.Platform.Routes (PlatformRoutes (..))
import Nagare.Api.Response
import Nagare.Api.Server.Serve (Env (..), noteDeadline, serveBuild)
import Nagare.Api.Server.Validators (entityTag, noneMatch, stateValidators)
import Nagare.Contract.Prelude
import Nagare.Contract.Versions (PlatformVersions, ServingBuild)
import Nagare.Platform.Versions (platformVersionsDocument, reasonSnapshotUnavailable, servingBuildOf)
import Nagare.Platform.Versions.Store (validateSnapshot)
import Nagare.Resource.Types (contextIdText, nameText)
import Servant.Server (Handler)
import Servant.Server.Generic (AsServerT)
import System.Timeout (timeout)

-- | @image@ is the image reference the server was started with, if any.
platformServer :: Maybe Text -> Env -> PlatformRoutes (AsServerT Handler)
platformServer image env =
  PlatformRoutes
    { version = serveBuild (build env) (encode serving)
    , versions = serveVersions serving env
    }
  where
    serving = servingBuildOf image (startedAt env)

serveVersions :: ServingBuild -> Env -> Maybe Text -> Handler (BuildResult PlatformVersions)
serveVersions serving env match = liftIO $ do
  loaded <- try (timeout (deadlineMicroseconds env) (versionSnapshot env))
  stored <- case loaded of
    Right (Just (Right bytes)) -> pure (validateSnapshot (binding env) bytes)
    Right (Just (Left _)) -> pure (Left reasonSnapshotUnavailable)
    Right Nothing -> Left reasonSnapshotUnavailable <$ noteDeadline env
    Left (failure :: SomeException)
      | Just (_ :: SomeAsyncException) <- fromException failure -> throwIO failure
      | otherwise -> pure (Left reasonSnapshotUnavailable)
  let contextBinding = binding env
      rendered =
        platformVersionsDocument
          (contextIdText (contextBinding ^. #identity))
          (nameText (contextBinding ^. #project))
          (Just serving)
          stored
      -- Strict bytes: the encoding is forced inside this request.
      bytes = LBS.fromStrict (LBS.toStrict (encode rendered))
      tag = entityTag (build env) bytes
  _ <- pure $! LBS.length bytes
  pure $
    if noneMatch match tag
      then BuildNotModified (stateValidators tag)
      else BuildOk (BuildBody (Encoded bytes) (stateValidators tag))
