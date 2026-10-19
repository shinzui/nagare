-- | The accepted backup schedules @server status@ and @doctor@ grade, one
-- recovery-point row and one retention row each: a database's, a volume's
-- (EP-183 M3) and an app database's (EP-202, F132).
module Nagare.Inventory.ScheduledStatus
  ( ScheduledStatusKind (..)
  , ScheduledStatusSource (..)
  , scheduledStatusSources
  )
where

import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory
import Nagare.Resource.Types

data ScheduledStatusKind
  = -- | The database a @nagare-dbbackup-@ schedule dumps.
    DatabaseStatus !Text
  | -- | A volume's schedule, by its name.
    VolumeStatus !Text
  | -- | The app database a @nagare-appdb-@ schedule dumps.
    AppDatabaseStatus !Text
  deriving stock (Eq, Ord, Show)

data ScheduledStatusSource = ScheduledStatusSource
  { kind :: !ScheduledStatusKind
  , namespace :: !Text
  , label :: !Text
  -- ^ @namespace/database@, @namespace/schedule@ or @namespace/appdb@
  , source :: !ScopeId
  , schedule :: !ResourceId
  }
  deriving stock (Generic, Eq, Ord, Show)

scheduledStatusSources :: ScopeSnapshot -> [ScheduledStatusSource]
scheduledStatusSources snapshot =
  Set.toAscList
    ( Set.fromList
        [ ScheduledStatusSource selected (nameText namespace') (nameText namespace' <> "/" <> labelled) (scopeId scope) (member ^. #identity)
        | (_, scope) <- Map.elems (snapshotScopes snapshot)
        , bundle <- scopeBundles scope
        , Managed member <- declarations bundle
        , Kubernetes _ "batch" kind' (Just namespace') name' <- [member ^. #address]
        , nameText kind' == "cronjob"
        , (selected, labelled) <- classify (nameText name')
        ]
    )
  where
    classify name'
      | Just database <- T.stripPrefix "nagare-dbbackup-" name' = [(DatabaseStatus database, database)]
      | "nagare-volbackup-" `T.isPrefixOf` name' = [(VolumeStatus name', name')]
      | Just appDatabase <- T.stripPrefix "nagare-appdb-" name' = [(AppDatabaseStatus appDatabase, appDatabase)]
      | otherwise = []
