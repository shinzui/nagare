module InventoryHostSpec (inventoryHostTests) where

import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Host
import Nagare.Inventory.Digest
import Nagare.Inventory.Host
import Nagare.Inventory.Journal
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Test.Tasty
import Test.Tasty.HUnit

inventoryHostTests :: TestTree
inventoryHostTests =
  testGroup
    "host inventory adapter"
    [ testCase "host declaration includes system, durable mount, and explicit activation" $ do
        declaration <- expectRight (compileHostScope hostBundle)
        case scopeBundles declaration of
          [ResourceBundle declared _ _ _ declaredOperations _] -> do
            length declared @?= 2
            case declaredOperations of
              [activation] -> operationKind activation @?= ActivateHost
              values -> assertFailure ("expected one activation operation, got " <> show (length values))
          values -> assertFailure ("expected one resource bundle, got " <> show (length values))
    , testCase "preflight refuses a timer-armed host without cancelling rollback" $ do
        state <- newIORef (HostTimerArmed instanceIdentity "/nix/store/test-active")
        let adapter = mkHostAdapter (ops state)
        prepared <- adapterPrepare adapter operation >>= expectRight
        result <- adapterPreflight adapter operation prepared
        case result of
          Left message | "timer is armed" `contains` message -> pure ()
          other -> assertFailure ("expected timer refusal, got " <> show other)
        readIORef state >>= (@?= HostTimerArmed instanceIdentity "/nix/store/test-active")
    , testCase "reverted activation is safe to retry; committed closure has durable proof" $ do
        state <- newIORef (HostReverted instanceIdentity "/nix/store/old")
        let adapter = mkHostAdapter (ops state)
        prepared <- adapterPrepare adapter operation >>= expectRight
        adapterRecover adapter operation prepared >>= (@?= RecoverySafeToRetry)
        adapterExecute adapter operation prepared >>= (@?= AdapterEffectCompleted)
        proof <- adapterVerify adapter operation >>= expectRight
        proof @?= hostCompletionProof activationPlan acknowledgement
    , testCase "local flake evidence cannot substitute for a remote committed closure" $ do
        state <- newIORef (HostBeforeActivation instanceIdentity "/nix/store/old")
        let adapter = mkHostAdapter (ops state)
        result <- adapterVerify adapter operation
        case result of
          Left message | "committed-closure" `contains` message -> pure ()
          other -> assertFailure ("expected committed-closure refusal, got " <> show other)
    , testCase "fresh-login host receipt binds the committed closure" $ do
        (closure, proof) <- expectRight (parseHostCommitReceipt (BC.pack "COMMITTED new=/nix/store/new\nnagare-host-activation\tcommitted\t/nix/store/new\tfresh-login\n"))
        closure @?= "/nix/store/new"
        proof @?= contentDigest "nagare-host-activation\tcommitted\t/nix/store/new\tfresh-login"
        case parseHostCommitReceipt "COMMITTED new=/nix/store/new\n" of
          Left _ -> pure ()
          Right _ -> assertFailure "plain success text was accepted as committed-closure evidence"
    ]

ops :: IORef HostActivationState -> HostAdapterOps
ops state =
  HostAdapterOps
    { hostObserveResources = \resources -> pure (observationSet [(resource, ObservedPresent instanceIdentity) | resource <- resources])
    , hostPreparePlan = \_ -> pure (Right activationPlan)
    , hostInspectActivation = \_ -> readIORef state
    , hostRunActivation = \_ -> writeIORef state (HostCommitted instanceIdentity "/nix/store/new" acknowledgement) >> pure AdapterEffectCompleted
    }

hostBundle :: HostDeclarationBundle
hostBundle =
  HostDeclarationBundle
    { hostBundleVersion = 1
    , hostScope = scope
    , hostPhysicalParent = parentResource
    , hostResources = systemResource :| [mountResource]
    , hostConfigurationDigest = contentDigest "configuration"
    , hostLockDigest = contentDigest "lock"
    }
  where
    systemResource =
      HostResourceSpec
        { hostLogicalKey = logicalKey "operator-system"
        , hostRole = name "system"
        , hostProviderName = name "operator"
        , hostSpecDigest = contentDigest "system"
        , hostLifecycle = Protect
        , hostDataPolicy = Stateless
        , hostSensitivity = Private
        , hostDependencies = []
        , hostSource = SourceLocation "nixos/lib/nagare-safe-switch-client.sh" "activation"
        }
    mountResource =
      HostResourceSpec
        { hostLogicalKey = logicalKey "data-mount"
        , hostRole = name "mount"
        , hostProviderName = name "var-lib-nagare"
        , hostSpecDigest = contentDigest "mount"
        , hostLifecycle = Protect
        , hostDataPolicy = Durable (RecoveryIntent (name "disk-snapshot") (mkSecretRef (name "recovery") (name "v1") :| []))
        , hostSensitivity = Private
        , hostDependencies = []
        , hostSource = SourceLocation "nixos/modules/host/storage.nix" "var-lib-nagare"
        }

operation :: PlannedOperation
operation =
  PlannedOperation
    { plannedOperationId = operationId
    , plannedAction = RunDeclaredOperation
    , plannedExecutor = HostExecutor
    , plannedResources = hostSystemResourceId hostBundle :| []
    , plannedInputDigest = contentDigest "activation-input"
    , plannedDependencies = []
    , plannedRecovery = OperatorRecovery
    }

activationPlan :: HostActivationPlan
activationPlan =
  HostActivationPlan
    { hostPlanVersion = 1
    , hostPlanOperation = operationId
    , hostPlanInputDigest = contentDigest "activation-input"
    , hostPlanContext = ok (mkContextId "dev")
    , hostPlanAttribute = name "dev-nagare"
    , hostPlanInstance = instanceIdentity
    , hostPlanDestination = "dev-nagare"
    , hostPlanConfigurationDigest = contentDigest "configuration"
    , hostPlanLockDigest = contentDigest "lock"
    , hostPlanExpectedOldClosure = "/nix/store/old"
    , hostPlanNewClosure = "/nix/store/new"
    , hostPlanActivationId = "activation-01"
    }

scope :: ScopeId
scope = ok (mkScopeId Platform "host")

parentResource :: ResourceId
parentResource = ok (mkResourceId "platform:cloud/instance/vm")

operationId :: OperationId
operationId = ok (mkOperationId "op-host-activate")

instanceIdentity :: PhysicalIdentity
instanceIdentity = ok (mkPhysicalIdentity "gce://example-project/us-west1-a/dev-nagare")

acknowledgement :: ContentDigest
acknowledgement = contentDigest "fresh-login-acknowledgement"

name :: Text -> Name
name = ok . mkName

logicalKey :: Text -> LogicalKey
logicalKey = ok . mkLogicalKey

contains :: Text -> Text -> Bool
contains needle haystack = needle `Data.Text.isInfixOf` haystack

expectRight :: (Show e) => Either e a -> IO a
expectRight result = case result of
  Left err -> assertFailure (show err) >> pure (error "unreachable")
  Right value -> pure value

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
