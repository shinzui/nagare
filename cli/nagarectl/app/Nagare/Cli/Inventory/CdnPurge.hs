-- | Private Cloudflare transport and shared receipt storage for reviewed purges.
module Nagare.Cli.Inventory.CdnPurge (cdnPurgeRuntime) where

import Data.Aeson (object, (.=))
import Data.Map.Strict (Map)
import Data.Text qualified as T
import Nagare.Cdn.Cloudflare (buildPurgePayload, cfRequestWithStatus)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter (Adapter)
import Nagare.Inventory.CdnPurge
import Nagare.Inventory.Store (InventoryStore, publishIfAbsent, readObject)
import Nagare.Resource.Inventory (ManagedResource, ScopeDeclaration)
import Nagare.Resource.Types (ResourceId, nameText)
import System.Environment (lookupEnv)

cdnPurgeRuntime :: InventoryStore -> [ScopeDeclaration] -> Map ResourceId ManagedResource -> Adapter -> IO Adapter
cdnPurgeRuntime store scopes accepted base = do
  bindings <- either dieT pure (purgeBindings scopes accepted)
  let ops =
        PurgeOps
          { purgeReadReceipt = \digest -> first (T.pack . show) <$> readObject store (purgeReceiptKey digest)
          , purgeWriteReceipt = \digest bytes ->
              fmap (const ()) . first (T.pack . show)
                <$> publishIfAbsent store (purgeReceiptKey digest) bytes
          , purgeSubmit = \zone host paths -> do
              token <- lookupEnv "CF_API_TOKEN"
              case token of
                Nothing -> pure (Left "CF_API_TOKEN is not set")
                Just value | null value -> pure (Left "CF_API_TOKEN is empty")
                Just value -> do
                  result <-
                    cfRequestWithStatus
                      (T.pack value)
                      "POST"
                      ("/zones/" <> nameText zone <> "/purge_cache")
                      (Just (maybe (object ["purge_everything" .= True]) (\hostname -> buildPurgePayload (nameText hostname) paths) host))
                  pure (first (const "Cloudflare purge outcome is unknown") result >>= parsePurgeAcceptance)
          }
  pure (withCdnPurge bindings ops base)
