module InventoryCdnCollectionSpec (inventoryCdnCollectionTests) where

import Data.Aeson (object, (.=))
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Cdn
import Nagare.Inventory.Adapters.CdnRuntime (dnsChangeBody)
import Nagare.Inventory.Adapters.Cloudflare
import Nagare.Inventory.CollectionPolicy (supportsRetainedCollection)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (mkOperationId)
import Nagare.Resource.Inventory hiding (owner)
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

inventoryCdnCollectionTests :: TestTree
inventoryCdnCollectionTests =
  testGroup
    "retained DNS collection"
    [ testCase "Google deletion is exact old-value conditional and absence recovers lost acknowledgement" $ do
        state <- newIORef (DnsPresent physical "203.0.113.1" 300)
        writes <- newIORef (0 :: Int)
        let ops =
              DnsAdapterOps
                (\_ -> readIORef state)
                (\_ -> fail "unexpected create")
                (\_ -> fail "unexpected replace")
                ( \plan -> do
                    dnsChangeBody plan
                      @?= object
                        [ "additions" .= ([] :: [Text])
                        , "deletions"
                            .= [ object
                                   [ "name" .= ("a.example.test." :: Text)
                                   , "type" .= ("A" :: Text)
                                   , "ttl" .= (300 :: Int)
                                   , "rrdatas" .= ["203.0.113.1" :: Text]
                                   ]
                               ]
                        ]
                    modifyIORef' writes (+ 1)
                    writeIORef state DnsMissing
                    pure (AdapterEffectAmbiguous "acknowledgement lost")
                )
            adapter = mkDnsAdapter (Map.singleton rid google) (Map.singleton rid (DnsBinding google)) ops
        native <- adapterPrepare adapter operation >>= right
        writeIORef state (DnsPresent physical "203.0.113.2" 300)
        refused <- adapterExecute adapter operation native
        assertBool "changed target refuses" (case refused of AdapterEffectFailed _ -> True; _ -> False)
        readIORef writes >>= (@?= 0)
        writeIORef state (DnsPresent physical "203.0.113.1" 300)
        adapterExecute adapter operation native >>= (@?= AdapterEffectAmbiguous "acknowledgement lost")
        proof <- adapterVerify adapter operation native >>= right
        adapterRecover adapter operation native >>= (@?= RecoveryProvedComplete proof)
        readIORef writes >>= (@?= 1)
    , testCase "Cloudflare deletion binds retained ID and version; unknown presence never resends" $ do
        let current = CloudflarePresent physical (Just "v1") target
        state <- newIORef current
        writes <- newIORef (0 :: Int)
        let ops =
              CloudflareAdapterOps
                (\_ -> readIORef state)
                (\_ -> fail "unexpected create")
                (\_ -> fail "unexpected replace")
                ( \plan -> do
                    cloudflarePlanPhysical plan @?= Just physical
                    cloudflarePlanVersion plan @?= Just "v1"
                    modifyIORef' writes (+ 1)
                    pure (AdapterEffectAmbiguous "acknowledgement lost")
                )
            adapter = mkCloudflareAdapter (Map.singleton rid cloudflare) (Map.singleton rid (CloudflareBinding cloudflare)) ops
        native <- adapterPrepare adapter operation >>= right
        writeIORef state (CloudflarePresent physical (Just "v2") target)
        refused <- adapterExecute adapter operation native
        assertBool "changed version refuses" (case refused of AdapterEffectFailed _ -> True; _ -> False)
        readIORef writes >>= (@?= 0)
        writeIORef state current
        adapterExecute adapter operation native >>= (@?= AdapterEffectAmbiguous "acknowledgement lost")
        recovered <- adapterRecover adapter operation native
        assertBool "still present cannot complete or resend" (case recovered of RecoveryUnresolved _ -> True; _ -> False)
        writeIORef state CloudflareMissing
        proof <- adapterVerify adapter operation native >>= right
        adapterRecover adapter operation native >>= (@?= RecoveryProvedComplete proof)
        readIORef writes >>= (@?= 1)
    , testCase "retention and platform shared resources remain ineligible" $ do
        supportsRetainedCollection google @?= True
        supportsRetainedCollection cloudflare @?= True
        supportsRetainedCollection (google & #lifecycle .~ Retain) @?= False
        supportsRetainedCollection (cloudflare & #owner .~ ok (mkScopeId Platform "shared")) @?= False
        supportsRetainedCollection (cloudflare & #address .~ CloudflareRuleset zone) @?= False
    ]
  where
    owner = ok (mkScopeId Application "retained-dns")
    rid = mintResourceId owner (ok (mkLogicalKey "dns")) (ok (mkName "record"))
    zone = ok (mkName "zone")
    host = ok (mkName "a.example.test")
    physical = ok (mkPhysicalIdentity "original-record")
    target = CloudflareDnsTarget host "203.0.113.1" True 1
    google =
      ManagedResource
        rid
        owner
        CdnExecutor
        (DnsRecord (ok (mkName "project")) zone host)
        [Hostname host]
        (DnsARecord "203.0.113.1" 300)
        DeleteWhenUnreferenced
        Stateless
        Private
        []
        []
        (SourceLocation "test" "collection")
    cloudflare = google & #address .~ CloudflareDnsRecord zone host & #spec .~ CloudflareProxiedARecord "203.0.113.1"
    operation =
      PlannedOperation
        (ok (mkOperationId "op-collect"))
        RetireResource
        CdnExecutor
        (rid :| [])
        (contentDigest "collection")
        []
        VerifyBeforeRetry

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
