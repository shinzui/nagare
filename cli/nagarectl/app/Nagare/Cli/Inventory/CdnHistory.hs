-- | Recover exact historical DNS declarations for retention and collection.
-- These declarations were validated when accepted; their former route need not
-- remain desired merely to inspect or collect the retained record.
module Nagare.Cli.Inventory.CdnHistory
  ( retainedCdnResources
  , historicalDnsBindings
  , historicalCloudflareBindings
  , reviewedHistoricalCdn
  )
where

import Control.Monad (forM)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.Cdn (DnsBinding (..))
import Nagare.Inventory.Adapters.Cloudflare (CloudflareBinding (..))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Resource.Wire (decodeScope)

retainedCdnResources :: InventoryHistory -> Map ResourceId ManagedResource
retainedCdnResources = Map.filter ((== CdnExecutor) . (^. #executor)) . Map.map snd . historyRetained

historicalDnsBindings :: Map ResourceId ManagedResource -> Map ResourceId DnsBinding
historicalDnsBindings =
  Map.mapMaybe
    ( \resource -> case resource ^. #address of
        DnsRecord {} -> Just (DnsBinding resource)
        _ -> Nothing
    )

historicalCloudflareBindings :: Map ResourceId ManagedResource -> Map ResourceId CloudflareBinding
historicalCloudflareBindings =
  Map.mapMaybe
    ( \resource -> case resource ^. #address of
        CloudflareDnsRecord {} -> Just (CloudflareBinding resource)
        _ -> Nothing
    )

reviewedHistoricalCdn :: InventoryStore -> ReviewBundle -> IO (Map ResourceId ManagedResource)
reviewedHistoricalCdn store bundle = fmap (Map.filter ((== CdnExecutor) . (^. #executor)) . Map.fromList) $ forM selected $ \(resourceId, proof) -> do
  let digest = revisionDigest (retentionRevision proof)
  bytes <-
    readObject store (scopeKey digest)
      >>= either (dieT . T.pack . show) pure
      >>= maybe (dieT "historical CDN owner scope is missing") pure
  unless (contentDigest bytes == digest) (dieT "historical CDN owner scope digest differs")
  scope <- either (dieT . T.pack . show) pure (decodeScope bytes)
  unless (scopeId scope == retentionOwner proof) (dieT "historical CDN owner differs from the review")
  resource <- case [ member
                   | item <- scopeBundles scope
                   , Managed member <- item ^. #declarations
                   , member ^. #identity == resourceId
                   , member ^. #owner == scopeId scope
                   ] of
    [member] -> pure member
    _ -> dieT "historical CDN resource is absent or ambiguous"
  pure (resourceId, resource)
  where
    document = reviewBundleDocument bundle
    -- Retirement can have no operations, so select original proof authority.
    -- Platform cloud proofs are reconstructed by CloudHistory, never as CDN.
    selected =
      Map.toAscList
        ( Map.filter
            ( \proof ->
                let owner = retentionOwner proof
                 in not (scopeKind owner == Platform && nameText (scopeName owner) == "cloud")
            )
            (Map.union (reviewRetentions document) (reviewCollections document))
        )
