module InventoryHostSpec (inventoryHostTests) where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding (contains, (.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Host
import Nagare.Inventory.Adapters.HostRuntime
import Nagare.Inventory.Digest
import Nagare.Inventory.Host
import Nagare.Inventory.Journal
import Nagare.Inventory.RegistryCredentials
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import Test.Tasty
import Test.Tasty.HUnit

inventoryHostTests :: TestTree
inventoryHostTests =
  testGroup
    "host inventory adapter"
    [ testCase "legacy host plan bytes omit replacement authority" $ do
        case Aeson.toJSON activationPlan of
          Aeson.Object fields -> KeyMap.lookup "previousAgeKeyDigest" fields @?= Nothing
          _ -> assertFailure "host plan is not an object"
        Aeson.eitherDecode (Aeson.encode activationPlan) @?= Right activationPlan
    , testCase "credential preparation pins previous digest for host update and verification" $
        withSystemTempDirectory "host-credential-plan" $ \temporary -> do
          let executable = temporary </> "transport"
              oldKey = contentDigest "previous-key"
              newKey = contentDigest "next-key"
              runtime =
                HostRuntimeConfig
                  executable
                  []
                  (ok (mkContextId "dev"))
                  (name "dev-nagare")
                  "example-project"
                  "us-west1-a"
                  "dev-nagare"
                  "deploy@dev-nagare"
                  (contentDigest "configuration")
                  (contentDigest "lock")
                  (Just newKey)
                  True
              response =
                "{\"tag\":\"HostTransportPreparedCredential\",\"contents\":[\"gce://example-project/us-west1-a/dev-nagare\",\"/fixture/old\",\"/fixture/new\",\""
                  <> Data.Text.unpack (digestText oldKey)
                  <> "\"]}"
          writeFile executable ("#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '" <> response <> "'\n")
          setFileMode executable 0o700
          for_ [UpdateResource, VerifyResource] $ \action -> do
            prepared <- hostPreparePlan (mkHostRuntimeOps runtime) (operation {plannedAction = action}) >>= expectRight
            hostPlanPreviousAgeKeyDigest prepared @?= Just oldKey
            hostPlanCredentialReceiptRequired prepared @?= True
            hostPlanVersion prepared @?= 2
            supportedHostPlanVersion prepared @?= True
            supportedHostPlanVersion (prepared {hostPlanVersion = 1}) @?= False
            hostPlanAgeKeyDigest prepared @?= Just newKey
            Aeson.eitherDecode (Aeson.encode prepared) @?= Right prepared
    , testCase "host declaration includes system, durable mount, and explicit activation" $ do
        declaration <- expectRight (compileHostScope hostBundle)
        case scopeBundles declaration of
          [ResourceBundle declared _ _ _ declaredOperations _] -> do
            length declared @?= 2
            case declaredOperations of
              [activation] -> operationKind activation @?= ActivateHost
              values -> assertFailure ("expected one activation operation, got " <> show (length values))
          values -> assertFailure ("expected one resource bundle, got " <> show (length values))
    , testCase "registry footprint reserves exact Secrets against another scope" $ do
        let first :| rest = hostResources hostBundle
            configured = hostBundle {hostResources = first {hostLogicalKey = logicalKey "nixos-system"} :| rest}
        declared <- expectRight (compileHostScopeWithRegistryCredentials configured registryClusterIdentity)
        footprint <- expectRight (registryCredentialAliases registryClusterIdentity)
        let members = [r | b <- scopeBundles declared, Managed r <- declarations b]
        system <- case [r | r <- members, r ^. #identity == registryHostIdentity] of
          [r] -> pure r
          _ -> assertFailure "typed registry host missing" >> pure (error "unreachable")
        system ^. #aliases @?= footprint
        let otherOwner = ok (mkScopeId Standalone "foreign-secret")
            foreignSecret =
              system
                { identity = ok (mkResourceId "standalone:foreign-secret/pull/secret")
                , owner = otherOwner
                , executor = KubernetesExecutor
                , address = head footprint
                , aliases = []
                , lifecycle = Retain
                }
            other = ok (mkScopeDeclaration otherOwner [ResourceBundle [Managed foreignSecret] [] [] [] [] []])
            binding = ContextBinding (ok (mkContextId "fixture")) (name "project")
            snapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
        case composeInventory snapshot (ReplaceScope declared :| [ReplaceScope other]) of
          Left errors -> assertBool "canonical footprint conflict" (any ((== "claim-conflict") . (^. #code)) errors)
          Right _ -> assertFailure "another scope claimed the host credential Secret"
    , testCase "registry module and snapshot refuse partial grants while preserving legacy hosts" $ do
        registryCredentialModuleEnabled registryClusterIdentity "legacy module" @?= Right False
        fields <- expectRight (registryCredentialModuleFields registryClusterIdentity)
        let rendered =
              TE.encodeUtf8
                ( Data.Text.unlines
                    ["    " <> key <> " = \"" <> value <> "\";" | (key, value) <- fields]
                )
        registryCredentialModuleEnabled registryClusterIdentity rendered @?= Right True
        case registryCredentialModuleEnabled registryClusterIdentity (rendered <> rendered) of
          Left _ -> pure ()
          Right _ -> assertFailure "duplicate generated host grant accepted"
        let partial = TE.encodeUtf8 ("registryCredentialOwner = \"" <> resourceIdText registryHostIdentity <> "\";")
        case registryCredentialModuleEnabled registryClusterIdentity partial of
          Left _ -> pure ()
          Right _ -> assertFailure "partial generated host grant accepted"
        let first :| rest = hostResources hostBundle
            configured = hostBundle {hostResources = first {hostLogicalKey = logicalKey "nixos-system"} :| rest}
            binding = ContextBinding (ok (mkContextId "fixture")) (name "project")
            snapshot scopeValue = ok (mkScopeSnapshot binding (Map.singleton scope (ok (mkScopeGeneration 1), scopeValue)) Map.empty)
        legacy <- expectRight (compileHostScope configured)
        registryCredentialHost (snapshot legacy) registryClusterIdentity @?= Right Nothing
        declared <- expectRight (compileHostScopeWithRegistryCredentials configured registryClusterIdentity)
        registryCredentialHost (snapshot declared) registryClusterIdentity @?= Right (Just registryHostIdentity)
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
        proof <- adapterVerify adapter operation prepared >>= expectRight
        proof @?= hostCompletionProof activationPlan acknowledgement
    , testCase "effect-time drift after preflight cannot run host activation" $ do
        state <- newIORef (HostBeforeActivation instanceIdentity "/nix/store/old")
        effects <- newIORef (0 :: Int)
        let base = ops state
            adapter =
              mkHostAdapter
                base
                  { hostRunActivation = \_ -> modifyIORef' effects (+ 1) >> pure AdapterEffectCompleted
                  }
        prepared <- adapterPrepare adapter operation >>= expectRight
        adapterPreflight adapter operation prepared >>= expectRight
        let replacement = ok (mkPhysicalIdentity "gce://replacement")
        mapM_
          ( \changed -> do
              writeIORef state changed
              result <- adapterExecute adapter operation prepared
              case result of
                AdapterEffectFailed (KnownNoEffect _) -> pure ()
                other -> assertFailure ("effect-time drift was not refused: " <> show other)
          )
          [ HostBeforeActivation replacement "/nix/store/old"
          , HostBeforeActivation instanceIdentity "/nix/store/other"
          , HostCommitted replacement "/nix/store/new" acknowledgement
          ]
        readIORef effects >>= (@?= 0)
    , testCase "local flake evidence cannot substitute for a remote committed closure" $ do
        state <- newIORef (HostBeforeActivation instanceIdentity "/nix/store/old")
        let adapter = mkHostAdapter (ops state)
        prepared <- adapterPrepare adapter operation >>= expectRight
        result <- adapterVerify adapter operation prepared
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
    , testCase "subprocess runtime retains the prepared closure across execution" $
        withSystemTempDirectory "nagare-host-runtime-test" $ \temporary -> do
          let executable = temporary </> "host-transport"
              statePath = temporary </> "committed"
              body =
                unlines
                  [ "#!/bin/sh"
                  , "set -eu"
                  , "request=$(cat)"
                  , "printf '%s' \"$request\" | grep -F 'example-project' >/dev/null"
                  , "case \"$1\" in"
                  , "  observe|prepare) printf '%s\\n' '{\"tag\":\"HostTransportPrepared\",\"contents\":[\"gce://example-project/us-west1-a/dev-nagare\",\"/nix/store/old\",\"/nix/store/new\"]}' ;;"
                  , "  inspect)"
                  , "    if [ -f '" <> statePath <> "' ]; then"
                  , "      printf '%s\\n' '{\"tag\":\"HostTransportCommitted\",\"contents\":[\"gce://example-project/us-west1-a/dev-nagare\",\"/nix/store/new\",\"" <> Data.Text.unpack (digestText acknowledgement) <> "\"]}'"
                  , "    else"
                  , "      printf '%s\\n' '{\"tag\":\"HostTransportBefore\",\"contents\":[\"gce://example-project/us-west1-a/dev-nagare\",\"/nix/store/old\"]}'"
                  , "    fi ;;"
                  , "  activate)"
                  , "    : >'" <> statePath <> "'"
                  , "    printf '%s\\n' '{\"tag\":\"HostTransportCommitted\",\"contents\":[\"gce://example-project/us-west1-a/dev-nagare\",\"/nix/store/new\",\"" <> Data.Text.unpack (digestText acknowledgement) <> "\"]}' ;;"
                  , "esac"
                  ]
              runtime =
                HostRuntimeConfig
                  executable
                  []
                  (ok (mkContextId "dev"))
                  (name "dev-nagare")
                  "example-project"
                  "us-west1-a"
                  "dev-nagare"
                  "deploy@dev-nagare"
                  (contentDigest "configuration")
                  (contentDigest "lock")
                  Nothing
                  False
          writeFile executable body
          setFileMode executable 0o700
          let adapter = mkHostAdapter (mkHostRuntimeOps runtime)
          prepared <- adapterPrepare adapter operation >>= expectRight
          adapterPreflight adapter operation prepared >>= expectRight
          adapterExecute adapter operation prepared >>= (@?= AdapterEffectCompleted)
          _ <- adapterVerify adapter operation prepared >>= expectRight
          pure ()
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
    , hostAgeKeyDigest = Nothing
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
    , hostPlanAgeKeyDigest = Nothing
    , hostPlanPreviousAgeKeyDigest = Nothing
    , hostPlanCredentialReceiptRequired = False
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
