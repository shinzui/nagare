-- | Cloud resources that must exist before a Pulumi backend can be opened.
-- These declarations have their own executor so a fresh context can review
-- their effects without asking Pulumi or Kubernetes to observe an absent stack.
module Nagare.Inventory.Foundation
  ( FoundationResource (..)
  , FoundationDeclarationBundle (..)
  , compileFoundationScope
  , foundationTargetsFromDeclarations
  , validateFoundationMember
  )
where

import Data.Generics.Labels ()
import Data.Char (isControl, isSpace)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.Foundation (FoundationTarget (..), foundationTargetDigest)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference
import Nagare.Resource.Types

data FoundationResource = FoundationResource
  { foundationLogicalKey :: !LogicalKey
  , foundationRole :: !Name
  , foundationAddress :: !ProviderAddress
  , foundationSpecDigest :: !ContentDigest
  , foundationLifecycle :: !LifecyclePolicy
  , foundationDataPolicy :: !DataPolicy
  , foundationSensitivity :: !Sensitivity
  , foundationDependencies :: ![Dependency]
  , foundationSource :: !SourceLocation
  }
  deriving stock (Eq, Ord, Show, Generic)

data FoundationDeclarationBundle = FoundationDeclarationBundle
  { foundationBundleVersion :: !Int
  , foundationScope :: !ScopeId
  , foundationProject :: !Name
  , foundationResources :: !(NonEmpty FoundationResource)
  }
  deriving stock (Eq, Show, Generic)

compileFoundationScope :: FoundationDeclarationBundle -> Either (NonEmpty InventoryError) ScopeDeclaration
compileFoundationScope bundle
  | foundationBundleVersion bundle /= 1 = Left (inventoryError "foundation-wire-version" "unsupported foundation declaration bundle version" :| [])
  | scopeKind (foundationScope bundle) /= Platform = Left (inventoryError "foundation-scope" "cloud foundation must belong to a platform scope" :| [])
  | any wrongAddress (NE.toList (foundationResources bundle)) = Left (inventoryError "foundation-address" "cloud foundation requires bucket or target-project service addresses" :| [])
  | otherwise = mkScopeDeclaration (foundationScope bundle) [resourceBundle]
  where
    wrongAddress resource = case foundationAddress resource of
      GlobalBucket {} -> False
      CloudService project _ -> project /= foundationProject bundle
      CloudStack project _ -> project /= foundationProject bundle
      _ -> True
    resourceBundle = ResourceBundle
      { declarations = map (Managed . managedResource) (NE.toList (foundationResources bundle))
      , exports = []
      , conditions = []
      , contributions = []
      , operations = []
      , grants = []
      }
    managedResource resource = ManagedResource
      { identity = mintResourceId (foundationScope bundle) (foundationLogicalKey resource) (foundationRole resource)
      , owner = foundationScope bundle
      , executor = CloudFoundationExecutor
      , address = foundationAddress resource
      , aliases = []
      , spec = NativeObject (foundationSpecDigest resource)
      , lifecycle = foundationLifecycle resource
      , dataPolicy = foundationDataPolicy resource
      , sensitivity = foundationSensitivity resource
      , dependencies = foundationDependencies resource
      , delegations = []
      , source = foundationSource resource
      }

-- | Rebuild execution targets from the immutable declarations and the selected
-- context. The digest comparison prevents a changed region or member policy
-- from silently changing a retained review's native effects.
foundationTargetsFromDeclarations
  :: Name -> Name -> Maybe Name -> Maybe Text -> Maybe (ProviderAddress, FoundationTarget) -> [Declaration]
  -> Either Text (Map ResourceId FoundationTarget)
foundationTargetsFromDeclarations project location backendBucket member stackTarget declarations =
  Map.fromList <$> traverse target foundationMembers
  where
    foundationMembers = [resource | Managed resource <- declarations,
      resource ^. #executor == CloudFoundationExecutor]
    target resource = do
      value <- case resource ^. #address of
        GlobalBucket bucket -> Right (FoundationBucket project bucket location
          (if Just bucket == backendBucket then member else Nothing))
        CloudService targetProject service
          | targetProject == project -> Right (FoundationService project service)
          | otherwise -> Left "reviewed foundation service belongs to another project"
        CloudStack declaredProject declaredStack -> case stackTarget of
          Just (CloudStack expectedProject expectedStack,
            value@(FoundationStack targetProject targetStack _ _ _ _ _))
            | declaredProject == project && expectedProject == project
                && targetProject == project && declaredStack == expectedStack
                && declaredStack == targetStack -> Right value
          _ -> Left "reviewed foundation stack differs from the selected context"
        _ -> Left "reviewed foundation address is unsupported"
      unless (resource ^. #spec == NativeObject (foundationTargetDigest value))
        (Left "reviewed foundation target digest differs from the selected context")
      pure (resource ^. #identity, value)

validateFoundationMember :: Maybe Text -> Either Text ()
validateFoundationMember Nothing = Right ()
validateFoundationMember (Just member)
  | T.null member || T.any (\character -> isControl character || isSpace character) member =
      Left "Pulumi backend IAM member must be a nonempty single token"
  | otherwise = Right ()
