-- | Support.Volumes responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Support.Volumes
  ( mkVol
  , mkVolWith
  )
where

import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Dsl.Types
  ( AccessMode (ReadWriteOnce)
  , RetentionPolicy (Retain)
  , Volume (..)
  , mkMountPath
  , mkQuantity
  , mkVolumeName
  )

-- | A 'Volume' with an explicit 'RetentionPolicy' for the backup-policy tests.
mkVolWith :: RetentionPolicy -> Text -> Text -> Volume
mkVolWith ret n mp =
  Volume
    { name = orError (mkVolumeName n)
    , logicalKey = Nothing
    , size = orError (mkQuantity "1Gi")
    , mountPath = orError (mkMountPath mp)
    , accessMode = ReadWriteOnce
    , readOnly = False
    , retention = ret
    }
  where
    orError = either (error . T.unpack) id

-- ---------------------------------------------------------------------------
-- Nagare.Storage.Discover (EP-35)

-- | Build a known-valid 'Volume' for the storage tests.
mkVol :: Text -> Text -> Text -> Volume
mkVol n sz mp =
  Volume
    { name = orError (mkVolumeName n)
    , logicalKey = Nothing
    , size = orError (mkQuantity sz)
    , mountPath = orError (mkMountPath mp)
    , accessMode = ReadWriteOnce
    , readOnly = False
    , retention = Retain
    }
  where
    orError = either (error . T.unpack) id
