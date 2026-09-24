-- | Shared typed migration evidence used by proposal validation and planning.
module Nagare.Inventory.Migration.Types
  ( MigrationContract (..)
  , ValidatedMigration (..)
  ) where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Store (ScopeRevision)
import Nagare.Resource.Inventory (ManagedResource)
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

instance ToJSON MigrationContract where
  toJSON StatelessMigration = object ["mode" .= ("stateless" :: Text)]
  toJSON (DurableMigration backup compatibility fence recovery) = object
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
        unless (all (`elem` ["mode", "backupEvidence", "compatibilityEvidence", "fenceEvidence", "recoveryEvidence"]) (KM.keys o))
          (fail "durable migration contract has an unknown field")
        DurableMigration <$> o .: "backupEvidence" <*> o .: "compatibilityEvidence"
          <*> o .: "fenceEvidence" <*> o .: "recoveryEvidence"
      _ -> fail "unsupported migration contract mode"
