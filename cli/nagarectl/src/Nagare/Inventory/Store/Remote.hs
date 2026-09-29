-- | One shared transport/ownership boundary for ordinary commands and migration.
module Nagare.Inventory.Store.Remote (remoteObjectOps) where

import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Gogol qualified as G
import Gogol.Env qualified as Env
import Gogol.Storage qualified as S
import Nagare.Dsl.Prelude
import Nagare.Inventory.Store.GcloudAuth
import Nagare.Inventory.Store.Gogol
import Nagare.Inventory.Store.ObjectOps
import Nagare.Ops.PulumiBackend (GcloudOps (..), bucketOwnershipVerdict, bucketProjectNumberArgs, gcsBucketOfUrl, projectNumberArgs, realGcloudOps)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

remoteObjectOps :: T.Text -> T.Text -> IO (Either T.Text ObjectOps)
remoteObjectOps project url = do
  selected <- lookupEnv "NAGARE_INVENTORY_GCS_TRANSPORT"
  case fromMaybe "gogol" selected of
    "gcloud" -> legacy
    "gogol" -> case validateGogolLocation project url of
      Left reason -> pure (Left reason)
      Right () -> do
        session <- newGcloudSession project
        case session of
          Left reason -> pure (Left reason)
          Right auth -> case endpointOverride (sessionStorageEndpoint auth) of
            Left reason -> pure (Left reason)
            Right configureEnv -> do
              owned <- ownership (sessionCapture auth)
              case owned of
                Left reason -> pure (Left reason)
                Right () -> newGogolObjectOpsWithToken (sessionToken auth) configureEnv project url
    _ -> pure (Left "NAGARE_INVENTORY_GCS_TRANSPORT must be gogol or gcloud")
  where
    legacy = do
      owned <- ownership (capture realGcloudOps)
      pure (owned >> gcloudObjectOps url)
    ownership capture = case gcsBucketOfUrl url of
      Nothing -> pure (Left "inventory store URL has no GCS bucket")
      Just bucket -> do
        bucketNumber <- capture (bucketProjectNumberArgs bucket)
        projectNumber <- capture (projectNumberArgs project)
        pure (bucketOwnershipVerdict bucket project bucketNumber projectNumber)

-- The ordinary Google endpoint and explicit loopback emulators are supported.
-- Do not silently ignore a configured custom endpoint or forward tokens to an
-- arbitrary host. Both JSON and upload routes retain their SDK paths.
endpointOverride :: T.Text -> Either T.Text (StorageEnv -> StorageEnv)
endpointOverride value
  | value `elem` ["", "https://storage.googleapis.com/storage/v1/"] = Right id
  | Just suffix <- T.stripPrefix "http://127.0.0.1:" value
  , Just portText <- T.stripSuffix "/storage/v1/" suffix
  , Just port <- readMaybe (T.unpack portText)
  , port > 0 && port <= 65535 =
      Right (Env.override (S.storageService & G.serviceHost .~ TE.encodeUtf8 "127.0.0.1" & G.servicePort .~ port & G.serviceSecure .~ False))
  | otherwise = Left "inventory SDK requires the default Storage endpoint or an explicit loopback emulator; set NAGARE_INVENTORY_GCS_TRANSPORT=gcloud for other endpoints"
