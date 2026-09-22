-- | Stable inventory identity and direct Kubernetes declarations for a database.
-- Credential creation and backup operations are deliberately separate: their
-- private inputs cannot be represented by the public rendered object set.
module Nagare.Resource.Database
  ( databaseResourceId
  , DatabaseDirectInput (..)
  , compileDatabaseDirect
  ) where

import Data.Aeson (Value)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Nagare.Dsl.Database (Database (..), engineMemoryConfig)
import Nagare.Dsl.Database.Render (databaseObjects)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (databaseNameText)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes
import Nagare.Resource.Policy
import Nagare.Resource.Types

databaseResourceId :: ScopeId -> Name -> Database -> Either Text ResourceId
databaseResourceId owner role database =
  mintResourceId owner <$> key <*> pure role
  where
    key = maybe (mkLogicalKey (databaseNameText (database ^. #name))) Right (database ^. #logicalKey)

-- | The digest callback is supplied by nagarectl, which owns content hashing.
-- The resulting values must be bound to canonical bytes by its native adapter.
data DatabaseDirectInput = DatabaseDirectInput
  { directDatabase :: !Database
  , directOwnerScope :: !ScopeId
  , directClusterId :: !ResourceId
  , directRecoveryIntent :: !RecoveryIntent
  , directSourceLocation :: !SourceLocation
  }

-- | Compile every direct object emitted by the database renderer, preserving
-- its full typed resources and the same stable logical key for each role.
-- The returned objects are the native members corresponding to the bundle.
compileDatabaseDirect
  :: (Value -> Either Text ContentDigest)
  -> DatabaseDirectInput
  -> Either (NonEmpty InventoryError) (ResourceBundle, [(ResourceId, Value)])
compileDatabaseDirect digestOf input = do
  members <- traverse compileOne (zip roles (databaseObjects (directDatabase input)))
  pure
    ( ResourceBundle (map (Managed . fst) members) [] [] [] [] []
    , [(resource ^. #identity, value) | (resource, value) <- members]
    )
  where
    roles = ["pvc"]
      <> maybe [] (const ["configmap"]) (engineMemoryConfig (directDatabase input ^. #engine))
      <> ["service", "statefulset"]
    compileOne (roleText, value) = do
      role <- first invalid (mkName roleText)
      resource <- first invalid (databaseResourceId (directOwnerScope input) role (directDatabase input))
      digest <- first invalid (digestOf value)
      declaration <- first single $ compileKubernetesObject
        KubernetesInput
          { resourceId = resource
          , ownerScope = directOwnerScope input
          , clusterId = directClusterId input
          , inputObject = value
          , objectDigest = digest
          , lifecyclePolicy = Retain
          , inputDataPolicy = if roleText == "pvc" then Durable (directRecoveryIntent input) else Stateless
          , inputSensitivity = Private
          , sourceLocation = directSourceLocation input
          }
      pure (declaration, value)
    invalid message = inventoryError "invalid-database-declaration" message
      & #scopes .~ [directOwnerScope input]
      & #sources .~ [directSourceLocation input]
      & single
    single err = err :| []
