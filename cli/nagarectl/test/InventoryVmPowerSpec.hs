module InventoryVmPowerSpec (inventoryVmPowerTests) where

import Data.Aeson (toJSON)
import Data.ByteString (ByteString)
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Command (executionBlockedAdapterFor)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (mkOperationId)
import Nagare.Inventory.VmPower
import Nagare.Resource.Inventory hiding (address, owner)
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Test.Tasty
import Test.Tasty.HUnit

inventoryVmPowerTests :: TestTree
inventoryVmPowerTests =
  testGroup
    "reviewed VM power"
    [ testCase "lost acknowledgement recovers same instance without another request" $ do
        (adapter, current, writes) <- fixture True
        native <- adapterPrepare adapter operation >>= right
        adapterExecute adapter operation native >>= \case
          AdapterEffectAmbiguous _ -> pure ()
          value -> assertFailure (show value)
        readIORef current >>= (@?= VmPowerObservation "98765" "TERMINATED")
        adapterRecover adapter operation native >>= \case
          RecoveryProvedComplete _ -> pure ()
          value -> assertFailure (show value)
        adapterExecute adapter operation native >>= (@?= AdapterEffectCompleted)
        readIORef writes >>= (@?= 1)
    , testCase "already stopped verifies without power request" $ do
        (adapter, current, writes) <- fixture False
        writeIORef current (VmPowerObservation "98765" "TERMINATED")
        native <- adapterPrepare adapter operation >>= right
        adapterExecute adapter operation native >>= (@?= AdapterEffectCompleted)
        void (adapterVerify adapter operation native >>= right)
        readIORef writes >>= (@?= 0)
    , testCase "foreign instance refuses before effect and during recovery" $ do
        (adapter, current, writes) <- fixture False
        native <- adapterPrepare adapter operation >>= right
        writeIORef current (VmPowerObservation "11111" "RUNNING")
        adapterExecute adapter operation native >>= \case
          AdapterEffectFailed _ -> pure ()
          value -> assertFailure (show value)
        writeIORef current (VmPowerObservation "11111" "TERMINATED")
        adapterRecover adapter operation native >>= \case
          RecoveryUnresolved _ -> pure ()
          value -> assertFailure (show value)
        readIORef writes >>= (@?= 0)
    , testCase "incomplete power outcome never authorizes automatic retry" $ do
        (adapter, current, writes) <- fixture False
        native <- adapterPrepare adapter operation >>= right
        adapterRecover adapter operation native >>= \case
          RecoveryUnresolved _ -> pure ()
          value -> assertFailure (show value)
        writeIORef current (VmPowerObservation "98765" "STOPPING")
        adapterRecover adapter operation native >>= \case
          RecoveryUnresolved _ -> pure ()
          value -> assertFailure (show value)
        -- E's U2: close cannot prove it, so the attested close is the exit.
        settleOperationWith adapter operation native >>= \case
          SettledUnknown _ resolvesBy -> assertBool "names the attested close" ("--attest" `T.isInfixOf` resolvesBy)
          value -> assertFailure (show value)
        readIORef writes >>= (@?= 0)
    , testCase "retained completion survives opposite transition and fresh planning" $ do
        (adapter, current, writes, _, _) <- receiptFixture False
        native <- adapterPrepare adapter operation >>= right
        adapterExecute adapter operation native >>= (@?= AdapterEffectCompleted)
        proof <- adapterVerify adapter operation native >>= right
        writeIORef current (VmPowerObservation "98765" "RUNNING")
        fresh <- adapterPrepare adapter operation >>= right
        preparedNativeBytes fresh @?= preparedNativeBytes native
        adapterPreflight adapter operation fresh >>= (@?= Right ())
        adapterExecute adapter operation fresh >>= (@?= AdapterEffectCompleted)
        adapterRecover adapter operation fresh >>= (@?= RecoveryProvedComplete proof)
        readIORef current >>= (@?= VmPowerObservation "98765" "RUNNING")
        readIORef writes >>= (@?= 1)
    , testCase "lost receipt acknowledgement recovers without repeating provider effect" $ do
        (adapter, current, writes, _, loseReceiptAck) <- receiptFixture False
        native <- adapterPrepare adapter operation >>= right
        adapterExecute adapter operation native >>= (@?= AdapterEffectCompleted)
        writeIORef loseReceiptAck True
        adapterVerify adapter operation native >>= assertBool "lost receipt acknowledgement" . isLeft
        writeIORef current (VmPowerObservation "98765" "RUNNING")
        adapterRecover adapter operation native >>= \case
          RecoveryProvedComplete _ -> pure ()
          value -> assertFailure (show value)
        readIORef writes >>= (@?= 1)
    , testCase "malformed receipt refuses planning and execution" $ do
        (adapter, _, writes, receipt, _) <- receiptFixture False
        native <- adapterPrepare adapter operation >>= right
        writeIORef receipt (Just "invalid")
        adapterPrepare adapter operation >>= assertBool "malformed receipt" . isLeft
        adapterExecute adapter operation native >>= \case
          AdapterEffectFailed _ -> pure ()
          value -> assertFailure (show value)
        readIORef writes >>= (@?= 0)
    , testCase "operation ID is immutable and unrelated scope declarations survive" $ do
        let snapshot scope =
              ok
                ( mkScopeSnapshot
                    (ContextBinding (ok (mkContextId "fixture")) (name "project"))
                    (Map.singleton owner (ok (mkScopeGeneration 1), scope))
                    Map.empty
                )
        declared <- right (compileVmPower (snapshot scope) address "stop-one" False)
        map declarations (scopeBundles declared) @?= map declarations (scopeBundles scope)
        compileVmPower (snapshot declared) address "stop-one" False @?= Right declared
        assertBool "ID cannot change meaning" (isLeft (compileVmPower (snapshot declared) address "stop-one" True))
        bindings <- right (vmPowerBindings address [declared])
        Map.size bindings @?= 2
        let stripped = ok (mkScopeDeclaration owner [bundle {operations = []} | bundle <- scopeBundles declared])
        retainVmPowerIntents declared stripped @?= Right declared
        vmPowerOnly [scope] [operation] @?= True
        vmPowerOnly [scope] [operation {plannedAction = CreateResource}] @?= False
        vmPowerOnly [scope] [operation {plannedExecutor = HostExecutor}] @?= False
    ]

fixture :: Bool -> IO (Adapter, IORef VmPowerObservation, IORef Int)
fixture lost = do
  (adapter, current, writes, _, _) <- receiptFixture lost
  pure (adapter, current, writes)

receiptFixture :: Bool -> IO (Adapter, IORef VmPowerObservation, IORef Int, IORef (Maybe ByteString), IORef Bool)
receiptFixture lost = do
  receipt <- newIORef Nothing
  loseReceiptAck <- newIORef False
  current <- newIORef (VmPowerObservation "98765" "RUNNING")
  writes <- newIORef 0
  let ops =
        VmPowerOps
          (\selected -> (selected @?= address) >> (Right <$> readIORef current))
          ( \selected start -> do
              selected @?= address
              start @?= False
              modifyIORef' writes (+ 1)
              writeIORef current (VmPowerObservation "98765" "TERMINATED")
              pure (if lost then Left "acknowledgement lost" else Right ())
          )
          (\_ -> Right <$> readIORef receipt)
          ( \_ bytes -> do
              previous <- readIORef receipt
              case previous of
                Just prior | prior /= bytes -> pure (Left "immutable receipt differs")
                _ -> do
                  writeIORef receipt (Just bytes)
                  lostAck <- atomicModifyIORef' loseReceiptAck (\lost -> (False, lost))
                  pure (if lostAck then Left "receipt acknowledgement lost" else Right ())
          )
      adapter = withVmPower (ok (vmPowerBindings address [scope])) ops (executionBlockedAdapterFor PulumiExecutor)
  pure (adapter, current, writes, receipt, loseReceiptAck)

owner :: ScopeId
owner = ok (mkScopeId Platform "cloud")

resource :: ResourceId
resource = mintResourceId owner (ok (mkLogicalKey "vm")) (name "instance")

address :: ProviderAddress
address = CloudInstance (name "project") (name "us-west1-a") (name "fixture-vm")

scope :: ScopeDeclaration
scope =
  ok
    ( mkScopeDeclaration
        owner
        [ ResourceBundle
            [ Managed
                ( ManagedResource
                    resource
                    owner
                    PulumiExecutor
                    (PulumiUrn "urn:pulumi:fixture::nagare::gcp:compute/instance:Instance::fixture-vm")
                    []
                    (NativeObject (contentDigest "vm"))
                    Protect
                    Stateless
                    Private
                    []
                    []
                    (SourceLocation "fixture" "vm")
                )
            ]
            []
            []
            []
            [intent]
            []
        ]
    )

intent :: DeclaredOperation
intent =
  DeclaredOperation
    (mintResourceId owner (ok (mkLogicalKey "vm-power")) (name "stop-zero"))
    (resource :| [])
    [ContentInput (contentDigest (ok (canonicalValue (toJSON address))))]
    OperatorRecovery
    StopVm

operation :: PlannedOperation
operation =
  PlannedOperation
    (ok (mkOperationId "op-power"))
    RunDeclaredOperation
    PulumiExecutor
    (resource :| [])
    (contentDigest (ok (canonicalValue (toJSON intent))))
    []
    OperatorRecovery

name :: Text -> Name
name = ok . mkName

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> error "unreachable") pure
