-- | EP-173/EP-177: the recovery model's scenarios. Each is a sequence of
-- reviews of one application scope and one standalone database: explicit
-- scenarios, and one per in-line kind and action of the kind table.
module Nagare.Test.Model.Scenarios
  ( Scenario (..)
  , Step (..)
  , stepText
  , scenarios
  , explicitScenarios
  , generatedScenarios
  )
where

import Data.Generics.Labels ()
import Data.Maybe (isJust)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Test.Model.Fixtures
import Nagare.Test.World.Kinds (KindAction (..), KindStatus (InLine), kindFixture, kindTable, kubernetesKind)

-- | A sequence of reviews: deploys of one application scope, each naming the
-- image of its Knative Service and release-history ConfigMap, its retirement,
-- and a standalone database with a scheduled receipt ingestion.
data Scenario = Scenario
  { label :: !Text
  , steps :: ![Step]
  , unready :: ![Text]
  -- ^ Images whose revision never becomes Ready (a bad update).
  , historyFollows :: !Bool
  -- ^ Whether the release-history ConfigMap records each image, as an
  -- application's release history does, or stays as first created.
  , shape :: !Shape
  -- ^ The application's other members: a durable volume, a worker.
  , sampled :: !Bool
  -- ^ Generated from the kind table: the fast tier places each fault once.
  }
  deriving stock (Eq, Show)

scenarios :: [Scenario]
scenarios = explicitScenarios <> generatedScenarios

-- | EP-177 (ADR 25): one scenario per in-line kind and action, each adding a
-- member of that kind to the application scope.
generatedScenarios :: [Scenario]
generatedScenarios =
  [ Scenario ("kind " <> T.pack (show selected) <> ": " <> action) steps' [] True plainShape {shapeExtra = Just row} True
  | row <- kindTable
  , row ^. #status == InLine
  , Just selected <- [kubernetesKind row]
  , isJust (kindFixture row)
  , (action, steps') <-
      [("create", [Deploy "v1"])]
        <> [("update", [Deploy "v1", Deploy "v2"]) | KindUpdate `elem` row ^. #actions]
        <> [("retire", [Deploy "v1", Retire]) | KindRetire `elem` row ^. #actions]
  ]

explicitScenarios :: [Scenario]
explicitScenarios =
  map ($ False) $
    [ Scenario "create" [Deploy "v1"] [] True plainShape
    , Scenario "create then good update" [Deploy "v1", Deploy "v2"] [] True plainShape
    , Scenario "create, bad update, corrected update (history unchanged)" [Deploy "v1", Deploy "bad", Deploy "v3"] ["bad"] False plainShape
    , Scenario "create, bad update, corrected update (history follows the release)" [Deploy "v1", Deploy "bad", Deploy "v3"] ["bad"] True plainShape
    , Scenario "create, bad update, corrected update (with a durable volume)" [Deploy "v1", Deploy "bad", Deploy "v3"] ["bad"] True volumeShape
    , Scenario "create with a durable volume, then retire" [Deploy "v1", Retire] [] True volumeShape
    , Scenario "create with a backup-included volume, then update its schedule (EP-183 M3)" [Deploy "v1", Deploy "v2"] [] True volumeBackupShape
    , Scenario "create a database, then ingest a scheduled receipt" [CreateDatabase, IngestReceipt] [] True plainShape
    , Scenario "create a database, then retire it" [CreateDatabase, RetireDatabase] [] True plainShape
    , Scenario "create a database, update its resources, update it again, then restart it" [CreateDatabase, UpdateDatabase, CreateDatabase, RestartDatabase] [] True plainShape
    , Scenario "create a database, lose the cluster, then rebuild it (EP-183 M4)" [CreateDatabase, LoseCluster, RebuildDatabase] [] True plainShape
    , Scenario "create with a durable volume, lose the cluster, then rebuild the application (EP-183 M4)" [Deploy "v1", LoseCluster, RebuildApplication] [] True volumeShape
    ]

data Step
  = -- | Review and apply the application at this image.
    Deploy !Text
  | -- | Retire the application scope, retaining its members.
    Retire
  | -- | Review and apply the standalone PostgreSQL database.
    CreateDatabase
  | -- | Plan ingestion of a scheduled receipt as `db backup-receipts` does.
    IngestReceipt
  | -- | Retire the database scope, retaining its members.
    RetireDatabase
  | -- | Review and apply the database with new resource requests, which
    -- rewrites its StatefulSet.
    UpdateDatabase
  | -- | Restart the database as `db restart` does (EP-181): a StatefulSet
    -- whose rollout is stuck submits its accepted scope unchanged, and the
    -- plan replaces the stuck pod; otherwise it stamps a restart token.
    RestartDatabase
  | -- | EP-183 M4: the VM is lost and its cluster keeps no object.
    LoseCluster
  | -- | EP-183 M4: rebuild every missing durable member of the database
    -- through reviewed rebuild decisions, and apply.
    RebuildDatabase
  | -- | EP-183 M4: rebuild every missing durable member of the application
    -- (its volume) through reviewed rebuild decisions, and apply.
    RebuildApplication
  deriving stock (Eq, Show)

stepText :: Step -> Text
stepText step = case step of
  Deploy image -> image
  Retire -> "retire"
  CreateDatabase -> "create database"
  IngestReceipt -> "ingest receipt"
  RetireDatabase -> "retire database"
  UpdateDatabase -> "update database"
  RestartDatabase -> "restart database"
  LoseCluster -> "lose the cluster"
  RebuildDatabase -> "rebuild database"
  RebuildApplication -> "rebuild application"
