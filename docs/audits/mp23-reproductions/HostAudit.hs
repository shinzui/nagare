module Main where
import Nagare.Dsl.Prelude hiding ((.=), contains)

import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Host
import Nagare.Inventory.Adapters.HostRuntime
import Nagare.Inventory.Digest
import Nagare.Inventory.Host
import Nagare.Inventory.Journal
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)

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
  Left err -> fail (show err)
  Right value -> pure value

ok :: (Show e) => Either e a -> a
ok = either (error . show) id


main :: IO ()
main = do
  mapM_ check [HostBeforeActivation (ok (mkPhysicalIdentity "gce://replacement")) "/nix/store/old", HostBeforeActivation instanceIdentity "/nix/store/unreviewed", HostCommitted (ok (mkPhysicalIdentity "gce://replacement")) "/nix/store/new" acknowledgement]
  where
    check changed = do
      state <- newIORef (HostBeforeActivation instanceIdentity "/nix/store/old")
      effects <- newIORef (0 :: Int)
      let base = ops state
          adapter = mkHostAdapter (base { hostRunActivation = \p -> modifyIORef' effects (+1) >> hostRunActivation base p })
      prepared <- adapterPrepare adapter operation >>= expectRight
      before <- adapterPreflight adapter operation prepared
      writeIORef state changed
      wouldRefuse <- adapterPreflight adapter operation prepared
      result <- adapterExecute adapter operation prepared
      count <- readIORef effects
      print (changed, before, wouldRefuse, result, count)
