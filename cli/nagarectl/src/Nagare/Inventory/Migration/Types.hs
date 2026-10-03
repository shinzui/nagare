-- | Shared typed migration evidence used by proposal validation and planning.
module Nagare.Inventory.Migration.Types
  ( MigrationContract (..)
  , ValidatedMigration (..)
  , migrationStageDigest
  , migrationPoliciesCompatible
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store (ScopeRevision)
import Nagare.Resource.Canonical (canonicalValue)
import Nagare.Resource.Inventory (Declaration (..), ManagedResource)
import Nagare.Resource.Policy (DataPolicy (..), RecoveryIntent (..), mkSecretRef, secretRefParts)
import Nagare.Resource.Types
import Nagare.Resource.Wire ()

-- | These identifiers name evidence the provider must verify. Their presence
-- in a proposal never by itself proves backup, compatibility, or recovery.
data MigrationContract
  = StatelessMigration
  | DurableMigration
      { migrationBackupEvidence :: !ContentDigest
      , migrationCompatibilityEvidence :: !ContentDigest
      , migrationFenceEvidence :: !ContentDigest
      , migrationRecoveryEvidence :: !ContentDigest
      }
  deriving stock (Eq, Show)

data ValidatedMigration = ValidatedMigration
  { validatedSource :: !(ScopeRevision, ManagedResource)
  , validatedDestination :: !ManagedResource
  , validatedSourcePhysical :: !PhysicalIdentity
  , validatedDestinationAbsence :: !ContentDigest
  , validatedContract :: !MigrationContract
  }
  deriving stock (Eq, Show)

-- | Every stage of one reviewed migration chain carries this input digest. A
-- provider adapter recomputes it to bind its private native bundle to the
-- reviewed source incarnation, destination absence and contract.
migrationStageDigest :: ResourceId -> ValidatedMigration -> Either Text ContentDigest
migrationStageDigest resourceId migration =
  contentDigest
    <$> canonicalValue
      ( object
          [ "resource" .= resourceId
          , "sourceRevision" .= sourceRevision
          , "source" .= Managed sourceResource
          , "sourcePhysical" .= validatedSourcePhysical migration
          , "destination" .= Managed (validatedDestination migration)
          , "destinationAbsence" .= validatedDestinationAbsence migration
          , "contract" .= validatedContract migration
          ]
      )
  where
    (sourceRevision, sourceResource) = validatedSource migration

-- | A durable policy names its recovery credentials by Secret name. When the
-- same proposal migrates such a Secret to a new name in the source's
-- namespace, the destination policy names the destination Secret. Every other
-- part of the policy must be identical.
migrationPoliciesCompatible :: [(ManagedResource, ManagedResource)] -> ManagedResource -> ManagedResource -> Bool
migrationPoliciesCompatible migrated source destination =
  renamed (source ^. #dataPolicy) == destination ^. #dataPolicy
  where
    renamed Stateless = Stateless
    renamed (Durable (RecoveryIntent backup references)) =
      Durable (RecoveryIntent backup (fmap rename references))
    rename reference =
      let (key, version) = secretRefParts reference
       in mkSecretRef (Map.findWithDefault key key renames) version
    renames =
      Map.fromList
        [ (sourceSecret, destinationSecret)
        | Kubernetes cluster "" _ (Just namespace) _ <- [source ^. #address]
        , (old, new) <- migrated
        , Kubernetes oldCluster "" oldKind (Just oldNamespace) sourceSecret <- [old ^. #address]
        , Kubernetes newCluster "" newKind (Just newNamespace) destinationSecret <- [new ^. #address]
        , nameText oldKind == "secret" && oldKind == newKind
        , oldCluster == cluster && newCluster == cluster
        , oldNamespace == namespace && newNamespace == namespace
        ]

instance ToJSON MigrationContract where
  toJSON StatelessMigration = object ["mode" .= ("stateless" :: Text)]
  toJSON (DurableMigration backup compatibility fence recovery) =
    object
      [ "mode" .= ("durable" :: Text)
      , "backupEvidence" .= backup
      , "compatibilityEvidence" .= compatibility
      , "fenceEvidence" .= fence
      , "recoveryEvidence" .= recovery
      ]

instance FromJSON MigrationContract where
  parseJSON = withObject "MigrationContract" $ \o -> do
    mode <- o .: "mode" :: Parser Text
    case mode of
      "stateless" -> do
        unless (all (`elem` ["mode"]) (KM.keys o)) (fail "stateless migration contract has an unknown field")
        pure StatelessMigration
      "durable" -> do
        unless
          (all (`elem` ["mode", "backupEvidence", "compatibilityEvidence", "fenceEvidence", "recoveryEvidence"]) (KM.keys o))
          (fail "durable migration contract has an unknown field")
        DurableMigration
          <$> o .: "backupEvidence"
          <*> o .: "compatibilityEvidence"
          <*> o .: "fenceEvidence"
          <*> o .: "recoveryEvidence"
      _ -> fail "unsupported migration contract mode"
