-- | Typed host configuration and activation declarations.
module Nagare.Inventory.Host
  ( HostResourceSpec (..)
  , HostDeclarationBundle (..)
  , compileHostScope
  , hostSystemResourceId
  , hostExecutionInputsFromScopes
  )
where

import Data.Generics.Labels ()

import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference
import Nagare.Resource.Types

data HostResourceSpec = HostResourceSpec
  { hostLogicalKey :: !LogicalKey
  , hostRole :: !Name
  , hostProviderName :: !Name
  , hostSpecDigest :: !ContentDigest
  , hostLifecycle :: !LifecyclePolicy
  , hostDataPolicy :: !DataPolicy
  , hostSensitivity :: !Sensitivity
  , hostDependencies :: ![Dependency]
  , hostSource :: !SourceLocation
  }
  deriving stock (Eq, Ord, Show, Generic)

data HostDeclarationBundle = HostDeclarationBundle
  { hostBundleVersion :: !Int
  , hostScope :: !ScopeId
  , hostPhysicalParent :: !ResourceId
  , hostResources :: !(NonEmpty HostResourceSpec)
  , hostConfigurationDigest :: !ContentDigest
  , hostLockDigest :: !ContentDigest
  }
  deriving stock (Eq, Show, Generic)

hostSystemResourceId :: HostDeclarationBundle -> ResourceId
hostSystemResourceId bundle =
  let resource = NE.head (hostResources bundle)
   in mintResourceId (hostScope bundle) (hostLogicalKey resource) (hostRole resource)

compileHostScope :: HostDeclarationBundle -> Either (NonEmpty InventoryError) ScopeDeclaration
compileHostScope bundle
  | hostBundleVersion bundle /= 1 = Left (inventoryError "host-wire-version" "unsupported host declaration bundle version" :| [])
  | otherwise = mkScopeDeclaration (hostScope bundle) [resourceBundle]
  where
    resources = NE.toList (hostResources bundle)
    resourceIds = map resourceId resources
    systemId = hostSystemResourceId bundle
    activationId = mintResourceId (hostScope bundle) (knownKey "activation") (knownName "apply")
    resourceBundle =
      ResourceBundle
        { declarations = map (Managed . managedResource) resources
        , exports = []
        , conditions = []
        , contributions = []
        , operations =
            [ DeclaredOperation
                { identity = activationId
                , affects = systemId :| filter (/= systemId) resourceIds
                , inputs = [ContentInput (hostConfigurationDigest bundle), ContentInput (hostLockDigest bundle)]
                , recovery = OperatorRecovery
                , operationKind = ActivateHost
                }
            ]
        , grants = []
        }
    resourceId resource = mintResourceId (hostScope bundle) (hostLogicalKey resource) (hostRole resource)
    managedResource resource =
      ManagedResource
        { identity = resourceId resource
        , owner = hostScope bundle
        , executor = HostExecutor
        , address = Host (hostPhysicalParent bundle) (hostProviderName resource)
        , aliases = []
        , spec = NativeObject (hostSpecDigest resource)
        , lifecycle = hostLifecycle resource
        , dataPolicy = hostDataPolicy resource
        , sensitivity = hostSensitivity resource
        , dependencies = hostDependencies resource
        , delegations = []
        , source = hostSource resource
        }

knownName :: Text -> Name
knownName = either (error . show) id . mkName

knownKey :: Text -> LogicalKey
knownKey = either (error . show) id . mkLogicalKey

hostExecutionInputsFromScopes :: [ScopeDeclaration] -> Either Text (Maybe (ContentDigest, ContentDigest))
hostExecutionInputsFromScopes scopes = case activationInputs of
  [] -> Right Nothing
  [[ContentInput configuration, ContentInput lock]] -> Right (Just (configuration, lock))
  [_] -> Left "host activation must retain exactly its configuration and lock digests"
  _ -> Left "inventory contains more than one host activation operation"
  where
    activationInputs =
      [ operation ^. #inputs
      | scope <- scopes
      , bundle <- scopeBundles scope
      , operation <- bundle ^. #operations
      , operation ^. #operationKind == ActivateHost
      ]
