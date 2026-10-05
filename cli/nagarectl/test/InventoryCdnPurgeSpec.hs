module InventoryCdnPurgeSpec (inventoryCdnPurgeTests) where

import Data.Aeson (object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.CdnPurge
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (mkOperationId)
import Nagare.Resource.Inventory hiding (owner)
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

inventoryCdnPurgeTests :: TestTree
inventoryCdnPurgeTests =
  testGroup
    "reviewed CDN purge"
    [ testCase "provider acceptance persists and fresh adapter recovery never resends" $ do
        (adapter, fresh, writes, _, _) <- fixture False False
        native <- adapterPrepare adapter operation >>= right
        adapterExecute adapter operation native >>= (@?= AdapterEffectCompleted)
        proof <- adapterVerify adapter operation native >>= right
        adapterRecover fresh operation native >>= (@?= RecoveryProvedComplete proof)
        adapterExecute fresh operation native >>= (@?= AdapterEffectCompleted)
        readIORef writes >>= (@?= 1)
    , testCase "lost provider acknowledgement remains unresolved without replay" $ do
        (adapter, fresh, writes, _, _) <- fixture True False
        native <- adapterPrepare adapter operation >>= right
        result <- adapterExecute adapter operation native
        assertBool "ambiguous write" (case result of AdapterEffectAmbiguous _ -> True; _ -> False)
        recovered <- adapterRecover fresh operation native
        assertBool "unknown request cannot be reissued" (case recovered of RecoveryUnresolved _ -> True; _ -> False)
        readIORef writes >>= (@?= 1)
    , testCase "persisted receipt recovers lost storage acknowledgement" $ do
        (adapter, fresh, writes, _, _) <- fixture False True
        native <- adapterPrepare adapter operation >>= right
        result <- adapterExecute adapter operation native
        assertBool "storage acknowledgement ambiguous" (case result of AdapterEffectAmbiguous _ -> True; _ -> False)
        recovered <- adapterRecover fresh operation native
        assertBool "persisted acceptance proves completion" (case recovered of RecoveryProvedComplete _ -> True; _ -> False)
        readIORef writes >>= (@?= 1)
    , testCase "changed DNS incarnation refuses before request; altered receipt refuses recovery" $ do
        (adapter, _, writes, receipt, current) <- fixture False False
        native <- adapterPrepare adapter operation >>= right
        writeIORef current "foreign-uid"
        result <- adapterExecute adapter operation native
        assertBool "changed DNS must refuse" (case result of AdapterEffectFailed _ -> True; _ -> False)
        readIORef writes >>= (@?= 0)
        writeIORef current "original-uid"
        adapterExecute adapter operation native >>= (@?= AdapterEffectCompleted)
        writeIORef receipt (Just "{}")
        recovered <- adapterRecover adapter operation native
        assertBool "malformed receipt must not complete" (case recovered of RecoveryUnresolved _ -> True; _ -> False)
    , testCase "acceptance parser requires successful provider request identity" $ do
        let response =
              ok
                ( canonicalValue
                    ( object
                        [ "success" .= True
                        , "errors" .= ([] :: [Text])
                        , "result" .= object ["id" .= ("request123" :: Text)]
                        ]
                    )
                )
        parsePurgeAcceptance (200, response) @?= Right "request123"
        assertBool "non-200 refuses" (either (const True) (const False) (parsePurgeAcceptance (503, response)))
        assertBool "missing ID refuses" (either (const True) (const False) (parsePurgeAcceptance (200, "{\"success\":true,\"errors\":[],\"result\":{}}")))
    ]

fixture :: Bool -> Bool -> IO (Adapter, Adapter, IORef Int, IORef (Maybe ByteString), IORef ByteString)
fixture loseProvider loseStorage = do
  writes <- newIORef 0
  receipt <- newIORef Nothing
  current <- newIORef "original-uid"
  let bindings = ok (purgeBindings [scope] (Map.singleton resource member))
      ops =
        PurgeOps
          { purgeReadReceipt = \_ -> Right <$> readIORef receipt
          , purgeWriteReceipt = \_ bytes -> do
              writeIORef receipt (Just bytes)
              pure (if loseStorage then Left "storage response lost" else Right ())
          , purgeSubmit = \zone host paths -> do
              zone @?= ok (mkName "zone")
              host @?= Just (ok (mkName "a.example.test"))
              paths @?= ["/selected"]
              modifyIORef' writes (+ 1)
              pure (if loseProvider then Left "provider response lost" else Right "request123")
          }
      base =
        Adapter
          CdnExecutor
          "fixture-cloudflare"
          "1"
          (\_ -> pure (observationSet []))
          ( \op -> do
              plannedAction op @?= VerifyResource
              bytes <- readIORef current
              pure (Right (PreparedNative bytes "verify original DNS"))
          )
          ( \op native -> do
              plannedAction op @?= VerifyResource
              bytes <- readIORef current
              pure (if preparedNativeBytes native == bytes then Right () else Left "DNS UID changed")
          )
          (\_ _ -> assertFailure "purge must use dedicated transport" >> pure AdapterEffectCompleted)
          (\_ _ -> pure (Right (contentDigest "dns")))
          (\_ _ -> pure (RecoveryUnresolved "DNS"))
          Nothing
  pure (withCdnPurge bindings ops base, withCdnPurge bindings ops base, writes, receipt, current)

owner :: ScopeId
owner = ok (mkScopeId Application "purge-fixture")

resource :: ResourceId
resource = mintResourceId owner (ok (mkLogicalKey "dns")) (ok (mkName "record"))

member :: ManagedResource
member =
  ManagedResource
    resource
    owner
    CdnExecutor
    (CloudflareDnsRecord (ok (mkName "zone")) (ok (mkName "a.example.test")))
    []
    (CloudflareProxiedARecord "203.0.113.1")
    Retain
    Stateless
    Private
    []
    []
    (SourceLocation "fixture" "purge")

intent :: DeclaredOperation
intent =
  DeclaredOperation
    (mintResourceId owner (ok (mkLogicalKey "request")) (ok (mkName "purge")))
    (resource :| [])
    [CdnPathsInput ["/selected"]]
    OperatorRecovery
    PurgeCdnCache

scope :: ScopeDeclaration
scope = ok (mkScopeDeclaration owner [ResourceBundle [Managed member] [] [] [] [intent] []])

operation :: PlannedOperation
operation =
  PlannedOperation
    (ok (mkOperationId "op-purge"))
    RunDeclaredOperation
    CdnExecutor
    (resource :| [])
    (contentDigest (ok (canonicalValue (toJSON intent))))
    []
    OperatorRecovery

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
