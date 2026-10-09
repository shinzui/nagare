module InventoryHostSpec (inventoryHostTests) where

import ContextReviewSpec (contextReviewTests)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified
import Data.Text.Encoding qualified as TE
import InventoryImagePruneSpec (inventoryImagePruneTests)
import InventoryStuckPodSpec (acceptedScopes)
import InventoryTransactionSpec (fixtureBinding)
import InventoryVmPowerSpec (inventoryVmPowerTests)
import Nagare.Dsl.Prelude hiding (contains, (.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Host
import Nagare.Inventory.Adapters.HostRuntime
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute
import Nagare.Inventory.Host
import Nagare.Inventory.HostLock (hostLockRepin)
import Nagare.Inventory.Journal
import Nagare.Inventory.Plan
import Nagare.Inventory.RegistryCredentials
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import System.Environment (getExecutablePath)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import Test.Tasty
import Test.Tasty.HUnit

inventoryHostTests :: TestTree
inventoryHostTests =
  testGroup
    "host inventory adapter"
    [ contextReviewTests
    , inventoryImagePruneTests
    , inventoryVmPowerTests
    , hostLockRepinTests
    , testCase "legacy host plan bytes omit replacement authority" $ do
        case Aeson.toJSON activationPlan of
          Aeson.Object fields -> KeyMap.lookup "previousAgeKeyDigest" fields @?= Nothing
          _ -> assertFailure "host plan is not an object"
        Aeson.eitherDecode (Aeson.encode activationPlan) @?= Right activationPlan
    , testCase "the host transport runs this nagarectl, never another one earlier on PATH (F90)" $
        withSystemTempDirectory "host-transport-self" $ \temporary -> do
          let executable = temporary </> "transport"
              decoy = temporary </> "decoy"
              seen = temporary </> "seen"
              runtime =
                HostRuntimeConfig
                  executable
                  [("PATH", decoy)]
                  (ok (mkContextId "dev"))
                  (name "dev-nagare")
                  "example-project"
                  "us-west1-a"
                  "dev-nagare"
                  "deploy@dev-nagare"
                  (contentDigest "configuration")
                  (contentDigest "lock")
                  Nothing
                  True
              response = "{\"tag\":\"HostTransportPrepared\",\"contents\":[\"gce://example-project/us-west1-a/dev-nagare\",\"/fixture/old\",\"/fixture/new\"]}"
          writeFile executable ("#!/bin/sh\ncat >/dev/null\nprintf '%s\\n%s\\n' \"$NAGARECTL\" \"${PATH%%:*}\" > " <> seen <> "\nprintf '%s\\n' '" <> response <> "'\n")
          setFileMode executable 0o700
          _ <- hostPreparePlan (mkHostRuntimeOps runtime) operation >>= expectRight
          self <- getExecutablePath
          lines <$> readFile seen >>= (@?= [self, takeDirectory self])
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
          let requiredRuntime = runtime {runtimeHostEnvironment = [("NAGARE_HOST_REVIEW_CREDENTIAL", "1")]}
          prepared <- hostPreparePlan (mkHostRuntimeOps requiredRuntime) operation >>= expectRight
          -- A legacy payload cannot silently downgrade an explicit credential
          -- review even if its transport ignores the request version.
          writeFile executable "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{\"tag\":\"HostTransportPrepared\",\"contents\":[\"gce://legacy\",\"/old\",\"/new\"]}'\n"
          hostPreparePlan (mkHostRuntimeOps requiredRuntime) operation >>= \case
            Left reason -> assertBool "credential capability refusal" ("lacks reviewed credential" `Data.Text.isInfixOf` reason)
            Right _ -> assertFailure "legacy transport downgraded credential authority"
          -- Actual old payloads reject protocol version three before providers.
          -- Both inspection and execution must use that newer protocol.
          writeFile executable "#!/bin/sh\nrequest=$(cat)\nif printf '%s' \"$request\" | jq -e '.version == 3' >/dev/null; then echo unsupported-host-transport-version >&2; exit 2; fi\necho legacy-protocol-was-used >&2\nexit 3\n"
          hostPreparePlan (mkHostRuntimeOps requiredRuntime) operation >>= \case
            Left reason -> assertBool "prepare protocol three" ("unsupported-host-transport-version" `Data.Text.isInfixOf` reason)
            Right _ -> assertFailure "legacy transport prepared credential plan"
          hostInspectActivation (mkHostRuntimeOps runtime) prepared >>= \case
            HostUnreachable reason -> assertBool "inspect protocol three" ("unsupported-host-transport-version" `Data.Text.isInfixOf` reason)
            _ -> assertFailure "legacy transport inspected credential plan"
          hostRunActivation (mkHostRuntimeOps runtime) prepared >>= \case
            AdapterEffectAmbiguous reason -> assertBool "activate protocol three" ("unsupported-host-transport-version" `Data.Text.isInfixOf` reason)
            _ -> assertFailure "legacy transport activated credential plan"
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
    , testCase "settle: the reviewed host on its old closure with no timer armed is no effect; anything else is unproved (Section 3)" $ do
        let settleIn hostState = do
              state <- newIORef hostState
              let adapter = mkHostAdapter (ops state)
              prepared <- adapterPrepare adapter operation >>= expectRight
              settleOperationWith adapter operation prepared
            unproved settled = case settled of
              SettledUnknown {} -> pure ()
              other -> assertFailure ("expected an unproved settlement, got " <> show other)
            replacement = ok (mkPhysicalIdentity "gce://replacement")
        settleIn (HostBeforeActivation instanceIdentity "/nix/store/old") >>= \case
          SettledNoEffect _ -> pure ()
          other -> assertFailure ("a reverted host did not settle no effect: " <> show other)
        settleIn (HostReverted instanceIdentity "/nix/store/old") >>= \case
          SettledNoEffect _ -> pure ()
          other -> assertFailure ("a reverted host did not settle no effect: " <> show other)
        settleIn (HostTimerArmed instanceIdentity "/nix/store/new") >>= unproved
        settleIn (HostCommitted instanceIdentity "/nix/store/new" acknowledgement) >>= unproved
        settleIn (HostReverted instanceIdentity "/nix/store/third") >>= unproved
        settleIn (HostBeforeActivation replacement "/nix/store/old") >>= unproved
        settleIn (HostUnreachable "no route") >>= unproved
    , testCase "close: an activation killed after ACTIVATE closes only once the timer has reverted the host, accepting nothing (Section 3)" $ do
        let upgraded = hostBundle {hostLockDigest = contentDigest "re-pinned lock"}
        (store, candidate, history) <- acceptedScopes (ok (compileHostScope hostBundle)) (ok (compileHostScope upgraded))
        state <- newIORef (HostBeforeActivation instanceIdentity "/nix/store/old")
        let killed =
              (ops state)
                { hostPreparePlan = \planned -> pure (Right activationPlan {hostPlanOperation = plannedOperationId planned, hostPlanInputDigest = plannedInputDigest planned})
                , -- The apply process dies after ACTIVATE: the host runs the
                  -- new closure under an armed rollback timer, and no commit
                  -- receipt ever returns.
                  hostRunActivation = \_ -> writeIORef state (HostTimerArmed instanceIdentity "/nix/store/new") >> pure (AdapterEffectAmbiguous "the apply process ended before COMMIT")
                }
            registry = ok (mkAdapterRegistry [mkHostAdapter killed])
        observations <- observeWithRegistry registry (requirementsByExecutor (observationRequirements candidate history)) >>= expectRight
        snapshot <- readStoreSnapshot store >>= expectRight
        bundle <- prepareReview registry snapshot (ok (planChanges candidate noLifecycleDecisions history observations)) >>= expectRight
        _ <- publishReview store bundle >>= expectRight
        published <- readStoreSnapshot store >>= expectRight
        reviewed <- expectRight (verifyReview published bundle)
        acceptedBefore <- readHead store >>= expectRight
        applied <- applyReviewed store registry reviewed >>= expectRight
        transaction <- case applied of
          StoppedAmbiguous tx _ -> pure tx
          other -> assertFailure ("the killed activation did not stop ambiguous: " <> show other) >> pure (error "unreachable")
        let closeIt = closeTransaction store registry (CloseInput transaction (contentDigest (encodeReviewDocument (reviewedDocument reviewed))) False Nothing)
        -- Inside the window the host may still commit or revert: close refuses.
        armed <- closeIt
        assertBool "close accepted a host whose rollback timer is armed" (isLeft armed)
        -- The timer reactivates the old closure; the activation had no effect.
        writeIORef state (HostBeforeActivation instanceIdentity "/nix/store/old")
        record <- closeIt >>= expectRight
        Map.elems (closedClasses record) @?= [ClassNoEffect "the reviewed host runs its old closure /nix/store/old with no rollback timer armed"]
        after <- readHead store >>= expectRight
        fmap headActiveTransaction after @?= Just Nothing
        fmap (Map.lookup scope . headAccepted) after @?= fmap (Map.lookup scope . headAccepted) acceptedBefore
    , testCase "a reverted activation is not retried by resume (ADR 11); a committed closure has durable proof" $ do
        state <- newIORef (HostReverted instanceIdentity "/nix/store/old")
        let adapter = mkHostAdapter (ops state)
        prepared <- adapterPrepare adapter operation >>= expectRight
        adapterRecover adapter operation prepared >>= \case
          RecoveryUnresolved reason | "close the transaction" `contains` reason -> pure ()
          other -> assertFailure ("a reverted activation was not left to close: " <> show other)
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

-- Checklist section 3: a node upgrade re-pins NixOS and k3s (the Nagare input's
-- transitive nixpkgs) while the platform payload stays the accepted store path.
hostLockRepinTests :: TestTree
hostLockRepinTests =
  testGroup
    "host lock re-pin"
    [ testCase "a lock that moves only nixpkgs and keeps the flake's Nagare store path is a NixOS re-pin" $
        hostLockRepin hostFlake (repinLock [("nagare", "nagare")] (pathNode payload payload)) @?= Right ()
    , testCase "a lock whose Nagare node names another store path is a payload change and refuses" $
        assertRefused (hostLockRepin hostFlake (repinLock [("nagare", "nagare")] (pathNode otherPayload otherPayload)))
    , testCase "a lock that keeps the Nagare original but locks another store path refuses" $
        assertRefused (hostLockRepin hostFlake (repinLock [("nagare", "nagare")] (pathNode otherPayload payload)))
    , testCase "a lock whose Nagare original differs from its locked path refuses" $
        assertRefused (hostLockRepin hostFlake (repinLock [("nagare", "nagare")] (pathNode payload otherPayload)))
    , testCase "a lock with a root input besides Nagare refuses" $
        assertRefused (hostLockRepin hostFlake (repinLock [("nagare", "nagare"), ("nixpkgs", "nixpkgs")] (pathNode payload payload)))
    , testCase "a lock whose Nagare node is not a path input refuses" $
        assertRefused
          ( hostLockRepin
              hostFlake
              (repinLock [("nagare", "nagare")] (Aeson.object ["locked" Aeson..= Aeson.object ["type" Aeson..= ("github" :: Text), "path" Aeson..= payload], "original" Aeson..= Aeson.object ["type" Aeson..= ("path" :: Text), "path" Aeson..= payload]]))
          )
    , testCase "a flake whose Nagare input is not a store path refuses" $
        assertRefused (hostLockRepin (flakeFor "/home/operator/nagare/nixos") (repinLock [("nagare", "nagare")] (pathNode "/home/operator/nagare/nixos" "/home/operator/nagare/nixos")))
    , testCase "a flake with two Nagare input assignments refuses" $
        assertRefused (hostLockRepin (hostFlake <> flakeFor payload) (repinLock [("nagare", "nagare")] (pathNode payload payload)))
    ]
  where
    payload = "/nix/store/jr0jwgd506n6x1qm8l0l2rk30k8ng3ca-nagare-platform-0.4.0/share/nagare/nixos" :: Text
    otherPayload = "/nix/store/0xi2vwhd3n7cibkhyzmc9lqsg1gw41rn-nagare-platform-0.5.0/share/nagare/nixos" :: Text
    hostFlake = flakeFor payload
    flakeFor path = TE.encodeUtf8 ("{\n  inputs.nagare.url = \"path:" <> path <> "\";\n  outputs = { self, nagare }: { };\n}\n")
    pathNode :: Text -> Text -> Aeson.Value
    pathNode locked original =
      Aeson.object
        [ "inputs" Aeson..= Aeson.object ["nixpkgs" Aeson..= ("nixpkgs" :: Text)]
        , "locked" Aeson..= Aeson.object ["narHash" Aeson..= ("sha256-yJN6t+eXKQLi5i5C9gBRZNKjohRgwGsxBy8u04l2AYg=" :: Text), "path" Aeson..= locked, "type" Aeson..= ("path" :: Text)]
        , "original" Aeson..= Aeson.object ["path" Aeson..= original, "type" Aeson..= ("path" :: Text)]
        ]
    repinLock :: [(Text, Text)] -> Aeson.Value -> BC.ByteString
    repinLock rootInputs nagareNode =
      LBS.toStrict
        ( Aeson.encode
            ( Aeson.object
                [ "nodes"
                    Aeson..= Aeson.object
                      [ "nagare" Aeson..= nagareNode
                      , "nixpkgs"
                          Aeson..= Aeson.object
                            [ "locked" Aeson..= Aeson.object ["owner" Aeson..= ("NixOS" :: Text), "repo" Aeson..= ("nixpkgs" :: Text), "rev" Aeson..= ("0000000000000000000000000000000000000001" :: Text), "type" Aeson..= ("github" :: Text)]
                            , "original" Aeson..= Aeson.object ["owner" Aeson..= ("NixOS" :: Text), "ref" Aeson..= ("nixos-unstable" :: Text), "repo" Aeson..= ("nixpkgs" :: Text), "type" Aeson..= ("github" :: Text)]
                            ]
                      , "root" Aeson..= Aeson.object ["inputs" Aeson..= Aeson.object [Key.fromText key Aeson..= value | (key, value) <- rootInputs]]
                      ]
                , "root" Aeson..= ("root" :: Text)
                , "version" Aeson..= (7 :: Int)
                ]
            )
        )
    assertRefused result = case result of
      Left _ -> pure ()
      Right () -> assertFailure "expected the re-pin to refuse"
