-- | Direct observability members installed beside the five Helm releases.
module Nagare.Inventory.Components.ObservabilityExtras
  ( compileObservabilityExtras
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (Value, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Components.Foundation (FoundationInput (..), foundationNamespaceId)
import Nagare.Inventory.Components.Upstream
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (kubernetesObjectIdentity)
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import System.FilePath ((</>))

compileObservabilityExtras ::
  FilePath ->
  FoundationInput ->
  ResourceId ->
  IO
    ( Either
        (NonEmpty InventoryError)
        (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
    )
compileObservabilityExtras root foundation metricsRelease = do
  generated <- traverse loadConfigMap generatedFiles
  case sequence generated of
    Left failure -> pure (Left (failure :| []))
    Right objects -> do
      let input =
            UpstreamInput
              { upstreamOwner = owner
              , upstreamCluster = foundationCluster foundation
              , upstreamKey = known (mkLogicalKey "observability-extra")
              , upstreamRoot = root
              , upstreamFiles = [(path, known (mkContentDigest digest)) | (path, digest) <- manifestFiles]
              , upstreamNamespaces =
                  Map.fromList
                    [ (known (mkName "monitoring"), monitoringNamespace)
                    , (known (mkName "nagare-system"), foundationNamespaceId foundation (known (mkName "nagare-system")))
                    ]
              , upstreamTransferred = Set.empty
              , upstreamConfigMapData = Map.empty
              , upstreamClusterIpServices = Set.empty
              , upstreamImageOverrides = Map.empty
              , upstreamGenerated = objects
              , upstreamAfter = Map.empty
              , upstreamExternalAfter =
                  Map.fromList
                    ( (enScrape, [metricsRelease, enScrapeKey])
                        : [(address, [metricsRelease]) | address <- addresses]
                    )
              , upstreamOrderDeployments = False
              , upstreamRegistryDelegations = Map.empty
              }
      result <- compileUpstream input
      pure $ do
        (bundle, native) <- result
        scope <- mkScopeDeclaration owner [bundle]
        pure (scope, native)
  where
    owner = known (mkScopeId Platform "observability-extra")
    known = either (error . T.unpack) id
    monitoringNamespace =
      mintResourceId
        (foundationOwner foundation)
        (known (mkLogicalKey "monitoring"))
        (known (mkName "namespace"))
    manifestFiles =
      [ ("cluster/observability/brokers/vmservicescrape.yaml", "671a9e79b8bb6323700c668d99bf3e8acc762ea9f7051570193cf60cb4559504")
      , ("cluster/observability/cert-manager/vmservicescrape.yaml", "863fb660be31a9de8c41102291b812e34613fd602ec95a03d40a57637e1991ed")
      , ("cluster/observability/vmrules/nagare-alerts.yaml", "0bfb5e50ff46e337e1736ab68783e3d52f5e949e3651c5bf5fa05d6285a65a15")
      , ("cluster/observability/vmrules/nagare-auth-alerts.yaml", "1aaa485e61dcfbe72a63591770bf4beae472b0eec5e20464d0a77fce972663ba")
      , ("cluster/observability/en/vmservicescrape.yaml", "30ec14c0555cecfcbc965bb0ff83bacfeeb8d978ba422ddc84629ae2e18dfc12")
      ]
    generatedFiles =
      [ ("cluster/observability/grafana/dashboards/nagare-brokers.json", "b90c9908f24e1ea0aa486a5591687d75e130ef67f7574529d066c597256ed515", "grafana-dashboard-nagare-brokers", "nagare-brokers.json", "grafana_dashboard")
      , ("cluster/observability/grafana/datasources/victoria-logs.yaml", "94b1f4e998ba43e91e8aa0c77a299c2607482bf0174a35080e16fb92bd02a46f", "grafana-datasource-victoria-logs", "victoria-logs.yaml", "grafana_datasource")
      , ("cluster/observability/grafana/datasources/victoria-traces.yaml", "57bcdaac80de171b7f7b18280f4967c45faa7aa1bcc893246ef644d748e7e546", "grafana-datasource-victoria-traces", "victoria-traces.yaml", "grafana_datasource")
      ]
    addresses =
      [ address "operator.victoriametrics.com/v1beta1" "VMServiceScrape" "nagare-brokers"
      , address "operator.victoriametrics.com/v1beta1" "VMServiceScrape" "cert-manager"
      , address "operator.victoriametrics.com/v1beta1" "VMRule" "nagare-alerts"
      , address "operator.victoriametrics.com/v1beta1" "VMRule" "nagare-auth-alerts"
      ]
        <> [address "v1" "ConfigMap" name | (_, _, name, _, _) <- generatedFiles]
    address = addressIn "monitoring"
    addressIn namespace api kind name =
      known
        ( kubernetesAddress
            (foundationCluster foundation)
            api
            kind
            (Just namespace)
            name
        )
    -- EP-262: En's scrape lives beside its bearer-token Secret, which a
    -- scrape object can only name in its own namespace, and waits for the
    -- auth scope to create that Secret.
    enScrape = addressIn "nagare-system" "operator.victoriametrics.com/v1beta1" "VMServiceScrape" "en"
    enScrapeKey =
      known
        ( kubernetesObjectIdentity
            (known (mkScopeId Platform "auth"))
            (known (mkLogicalKey "auth"))
            (addressIn "nagare-system" "v1" "Secret" "nagare-en-scrape-keys")
        )
    loadConfigMap (path, expected, name, key, label) = do
      readResult <- try (BS.readFile (root </> path)) :: IO (Either IOException ByteString)
      pure $ do
        bytes <- first (invalid . ("cannot read packaged Grafana input: " <>) . T.pack . show) readResult
        unless
          (contentDigest bytes == known (mkContentDigest expected))
          (Left (invalid "packaged Grafana input differs from its pinned digest"))
        contents <- first (invalid . T.pack . show) (TE.decodeUtf8' bytes)
        let value =
              object
                [ "apiVersion" .= ("v1" :: Text)
                , "kind" .= ("ConfigMap" :: Text)
                , "metadata"
                    .= object
                      [ "name" .= (name :: Text)
                      , "namespace" .= ("monitoring" :: Text)
                      , "labels" .= object [Key.fromText label .= ("1" :: Text)]
                      ]
                , "data" .= object [Key.fromText key .= contents]
                ]
        pure (SourceLocation (T.pack path) "grafana", value)
    invalid message = inventoryError "invalid-observability-extra" message
