-- | EP-262 M2: in tenant mode En stays ready while one tenant's database is
-- down (En ADR 10), so apply's verification of the en Deployment, and its
-- recovery, prove every declared tenant available from En's metrics.
module InventoryEnTenantsSpec
  ( inventoryEnTenantsTests
  )
where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Database.Secret (b64encode)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter (Adapter (..), AdapterExecution (..), RecoveryDecision (..))
import Nagare.Inventory.Adapters.EnTenants (TenantVerdict (..), enDeclaredTenants, enMetricsRequest, lastUnavailableReason, proveEnTenants, tenantAvailability)
import Nagare.Inventory.Adapters.Kubernetes (KubernetesState (..), kubernetesObserve, mkKubernetesAdapterWithObservations)
import Nagare.Inventory.Adapters.KubernetesStuckPod (KubernetesPodOps (..), noPodOps)
import Nagare.Inventory.KubernetesTransport (KubernetesRuntimeConfig (..), runKubectlWith, withKubectlInterpreter)
import Nagare.Resource.Types (mkContextId)
import Nagare.Test.Support.Kubernetes qualified as K
import System.Exit (ExitCode (..))
import Test.Tasty
import Test.Tasty.HUnit

inventoryEnTenantsTests :: TestTree
inventoryEnTenantsTests =
  testGroup
    "En tenants (EP-262)"
    [ testCase "the en Deployment's EN_TENANTS names the tenants to prove; any other object needs no proof" $ do
        enDeclaredTenants (enDeployment "en" "nagare-system" "nagare,demo") @?= Just ["nagare", "demo"]
        enDeclaredTenants (enDeployment "shomei" "nagare-system" "nagare") @?= Nothing
        enDeclaredTenants (enDeployment "en" "default" "nagare") @?= Nothing
        enDeclaredTenants K.nativeBytes @?= Nothing
    , testCase "every declared tenant must report available; a missing sample is unavailable" $ do
        tenantAvailability ["nagare", "demo"] (metrics [("nagare", "1"), ("demo", "1")]) @?= TenantsAvailable
        tenantAvailability ["nagare", "demo"] (metrics [("nagare", "1"), ("demo", "0")]) @?= TenantUnavailable "demo"
        tenantAvailability ["nagare", "demo"] (metrics [("nagare", "1")]) @?= TenantUnavailable "demo"
        tenantAvailability ["nagare"] "" @?= TenantUnavailable "nagare"
    , testCase "the reason is En's last UNAVAILABLE line, unless the tenant has logged AVAILABLE since" $ do
        let down = "2026-11-14 [tenant nagare] UNAVAILABLE: Could not reach PostgreSQL\n[tenant demo] AVAILABLE\n"
        lastUnavailableReason "nagare" down @?= Just "Could not reach PostgreSQL"
        lastUnavailableReason "demo" down @?= Nothing
        lastUnavailableReason "nagare" (down <> "[tenant nagare] AVAILABLE\n") @?= Nothing
    , testCase "an unavailable tenant fails the proof with En's reason; the scrape key is sent only as input" $ do
        (config, asked) <- interpreted [("nagare", "0")]
        proveEnTenants config ["nagare"] >>= (@?= Left "en tenant nagare unavailable: Could not reach PostgreSQL through EN_TENANT_NAGARE_DATABASE_URL")
        requests <- readIORef asked
        assertBool "the scrape key appeared in kubectl arguments" (not (any (elem "scrape-secret" . fst) requests))
        assertBool "the metrics read did not carry the scrape key" (all ((== "scrape-secret") . snd) [r | r@(arguments, _) <- requests, arguments == enMetricsRequest])
    , testCase "available tenants pass the proof" $ do
        (config, _) <- interpreted [("nagare", "1"), ("demo", "1")]
        proveEnTenants config ["nagare", "demo"] >>= (@?= Right ())
    , testCase "verification and recovery never pass an en Deployment whose tenant is unavailable" $ do
        let proved verdict = noPodOps {proveWorkload = \_ -> pure verdict}
        unavailable <- created (proved (Left "en tenant nagare unavailable"))
        adapterVerify (fst unavailable) K.createOperation (snd unavailable) >>= \case
          Left reason -> reason @?= "en tenant nagare unavailable"
          Right _ -> assertFailure "an unavailable tenant verified"
        adapterRecover (fst unavailable) K.createOperation (snd unavailable) >>= \case
          RecoveryProvedComplete _ -> assertFailure "recovery proved an unavailable tenant complete"
          _ -> pure ()
        available <- created (proved (Right ()))
        adapterVerify (fst available) K.createOperation (snd available) >>= either (assertFailure . T.unpack) (const (pure ()))
    ]
  where
    created pods = do
      state <- newIORef (KubernetesAbsent K.absence)
      calls <- newIORef 0
      let ops = K.ops state calls
          adapter = mkKubernetesAdapterWithObservations K.specs ops pods (traverse (kubernetesObserve ops)) (\_ _ -> pure (Left "no receipt")) (\_ _ -> pure (Right False)) Nothing
      prepared <- adapterPrepare adapter K.createOperation >>= K.expectRight
      adapterExecute adapter K.createOperation prepared >>= (@?= AdapterEffectCompleted)
      pure (adapter, prepared)

metrics :: [(Text, Text)] -> Text
metrics samples =
  T.unlines
    ( "# TYPE en_tenant_available gauge"
        : ["en_tenant_available{tenant=\"" <> tenant <> "\"} " <> value | (tenant, value) <- samples]
    )

-- | A kubectl interpreter that serves the scrape key, the metrics read and
-- En's log, recording each request's arguments and input.
interpreted :: [(Text, Text)] -> IO (KubernetesRuntimeConfig, IORef [([String], String)])
interpreted samples = do
  asked <- newIORef []
  let answer request = do
        modifyIORef' asked (<> [(request ^. #arguments, request ^. #input)])
        pure $ case request ^. #arguments of
          "get" : "secret" : "nagare-en-scrape-keys" : _ ->
            Right (ExitSuccess, T.unpack (TE.decodeUtf8 (LBS.toStrict (Aeson.encode (object ["data" .= object ["metrics" .= b64encode "scrape-secret"]])))), "")
          arguments
            | arguments == enMetricsRequest -> Right (ExitSuccess, "200\n" <> T.unpack (metrics samples), "")
          "logs" : _ -> Right (ExitSuccess, "[tenant nagare] UNAVAILABLE: Could not reach PostgreSQL through EN_TENANT_NAGARE_DATABASE_URL\n", "")
          other -> Left ("unexpected kubectl request " <> T.pack (show other))
      config = withKubectlInterpreter (runKubectlWith answer) (KubernetesRuntimeConfig (K.ok (mkContextId "test")) "en-tenants" (pure (Right ())))
  pure (config, asked)

enDeployment :: Text -> Text -> Text -> ByteString
enDeployment name namespace tenants =
  LBS.toStrict . Aeson.encode $
    object
      [ "apiVersion" .= ("apps/v1" :: Text)
      , "kind" .= ("Deployment" :: Text)
      , "metadata" .= object ["name" .= name, "namespace" .= namespace]
      , "spec"
          .= object
            [ "template"
                .= object
                  [ "spec"
                      .= object
                        [ "containers"
                            .= [ object
                                   [ "name" .= name
                                   , "env" .= [object ["name" .= ("EN_TENANTS" :: Text), "value" .= tenants]]
                                   ]
                               ]
                        ]
                  ]
            ]
      ]
