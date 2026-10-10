-- | The enforcer's live backend map. A reviewed application deploy changes
-- only the @nagare-access-backends@ ConfigMap; the kubelet then swaps the
-- mounted file in place. The enforcer must pick that file up without a
-- restart, or every route protected after the platform bootstrap answers
-- "no backend configured" until something rolls the enforcer.
module Nagare.Access.BackendSource
  ( BackendSource
  , newBackendSource
  , currentBackends
  , refreshBackends
  , RefreshResult (..)
  , liveApplication
  )
where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Nagare.Access.BackendMap (BackendMap, decodeBackendMap)
import Nagare.Access.Prelude
import Network.Wai (Application)

data BackendSource = BackendSource
  { readBytes :: !(IO ByteString)
  , loaded :: !(IORef (ByteString, BackendMap))
  }
  deriving stock (Generic)

data RefreshResult
  = Unchanged
  | Reloaded
  | -- | The new bytes do not decode; the previous map stays in force.
    Rejected !Text
  deriving stock (Eq, Show)

-- | Read and decode the map once. A map that does not decode at startup is
-- fatal, as before: the enforcer must not start with no routes.
newBackendSource :: IO ByteString -> IO (Either Text BackendSource)
newBackendSource readBytes = do
  bytes <- readBytes
  case decodeBackendMap bytes of
    Left err -> pure (Left err)
    Right backends -> Right . BackendSource readBytes <$> newIORef (bytes, backends)

currentBackends :: BackendSource -> IO BackendMap
currentBackends source = snd <$> readIORef (source ^. #loaded)

-- | Re-read the file and swap in its map when the bytes changed and decode.
refreshBackends :: BackendSource -> IO RefreshResult
refreshBackends source = do
  (previous, _) <- readIORef (source ^. #loaded)
  bytes <- source ^. #readBytes
  if bytes == previous
    then pure Unchanged
    else case decodeBackendMap bytes of
      Left err -> pure (Rejected err)
      Right backends -> Reloaded <$ writeIORef (source ^. #loaded) (bytes, backends)

-- | Serve each request with the map in force when it arrives.
liveApplication :: BackendSource -> (BackendMap -> Application) -> Application
liveApplication source build req respond = do
  backends <- currentBackends source
  build backends req respond
