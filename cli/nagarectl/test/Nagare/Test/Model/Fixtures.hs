-- | EP-173/EP-177: the recovery model's scopes. One application scope (a
-- Knative Service, its release history and, by shape, a durable volume, a
-- worker or a kind-table member) and one standalone PostgreSQL database.
module Nagare.Test.Model.Fixtures
  ( Shape (..)
  , plainShape
  , volumeShape
  , workerShape
  , volumeBackupShape
  , appScope
  , appCluster
  , serviceId
  , historyId
  , volumeId
  , workerId
  , extraId
  , serviceValue
  , historyValue
  , volumeValue
  , workerValue
  , volumePolicy
  , bindMember
  , bindMemberWith
  , boundMembers
  , boundDigests
  , workerDigest
  , serviceDigest
  , scopeFor
  , databaseScopeId
  , databaseBackend
  , databaseScope
  , databaseNative
  , resizedDatabase
  , databaseMember
  , statefulId
  , pvcId
  , cronId
  , signingId
  , ok
  )
where

import Data.Aeson (Value, object, (.=))
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Dsl.Database (Database (Database), Engine (Postgres), defaultEngineVersion, mkDatabaseName)
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Render (pvcName)
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Application (compileVolumeBackups)
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective (DailyRecoveryPoint, HourlyRecoveryPoint))
import Nagare.Inventory.DataService (compileStandaloneDatabase)
import Nagare.Inventory.Database (DatabaseBackupTarget (DatabaseBackupTarget))
import Nagare.Inventory.Digest
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Database (DatabaseDirectInput (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (..))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.World.Kinds (KindRow, kindFixture)

-- | The application's members besides its Service and release history.
data Shape = Shape
  { shapeVolume :: !Bool
  , shapeWorker :: !Bool
  -- ^ A worker Deployment whose image follows the release; in a worker
  -- scenario only the worker's revision of an unready image fails readiness.
  , shapeExtra :: !(Maybe KindRow)
  -- ^ A generated scenario's member of the kind under test.
  , shapeVolumeBackup :: !Bool
  -- ^ EP-183 M3: the durable volume is backup-included, so the scope also
  -- holds its namespace and the five members of its scheduled producer, as
  -- 'compileVolumeBackups' compiles them. The "v2" release moves the
  -- objective to daily, so its review updates the CronJob.
  }
  deriving stock (Eq, Show)

plainShape, volumeShape, workerShape, volumeBackupShape :: Shape
plainShape = Shape False False Nothing False
volumeShape = Shape True False Nothing False
workerShape = Shape False True Nothing False
volumeBackupShape = Shape True False Nothing True

-- * The application scope

appScope :: ScopeId
appScope = ok (mkScopeId Application "model-web")

appCluster :: ResourceId
appCluster = mintResourceId appScope (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))

serviceId, historyId :: ResourceId
serviceId = mintResourceId appScope (ok (mkLogicalKey "service")) (ok (mkName "resource"))
historyId = mintResourceId appScope (ok (mkLogicalKey "history")) (ok (mkName "resource"))

serviceValue :: Text -> Value
serviceValue image =
  object
    [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
    , "kind" .= ("Service" :: Text)
    , "metadata" .= object ["name" .= ("web" :: Text), "namespace" .= ("personal" :: Text)]
    , "spec" .= object ["template" .= object ["spec" .= object ["containers" .= [object ["image" .= ("registry.example/web:" <> image)]]]]]
    ]

historyValue :: Text -> Value
historyValue image =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("ConfigMap" :: Text)
    , "metadata" .= object ["name" .= ("web-history" :: Text), "namespace" .= ("personal" :: Text)]
    , "data" .= object ["current" .= image]
    ]

bindMember :: ResourceId -> Value -> (ManagedResource, ByteString)
bindMember = bindMemberWith Stateless

bindMemberWith :: DataPolicy -> ResourceId -> Value -> (ManagedResource, ByteString)
bindMemberWith policy resource value =
  let bytes = ok (canonicalValue value)
   in ok (bindKubernetesObject (KubernetesInput resource appScope appCluster value (contentDigest bytes) Retain policy Private (SourceLocation "model" (resourceIdText resource))))

volumePolicy :: DataPolicy
volumePolicy = Durable (RecoveryIntent (ok (mkName "uploads")) (mkSecretRef (ok (mkName "uploads-key")) (ok (mkName "v1")) :| []))

volumeId :: ResourceId
volumeId = mintResourceId appScope (ok (mkLogicalKey "uploads")) (ok (mkName "pvc"))

volumeValue :: Value
volumeValue =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("PersistentVolumeClaim" :: Text)
    , "metadata" .= object ["name" .= ("web-uploads" :: Text), "namespace" .= ("personal" :: Text)]
    , "spec" .= object ["accessModes" .= ["ReadWriteOnce" :: Text], "resources" .= object ["requests" .= object ["storage" .= ("1Gi" :: Text)]]]
    ]

boundMembers :: Shape -> Text -> Text -> Map.Map ResourceId (ManagedResource, ByteString)
boundMembers volume image historyImage =
  Map.fromList
    ( [ (serviceId, bindMember serviceId (serviceValue image))
      , (historyId, first (\history -> history {dependencies = [OrderedAfter serviceId]}) (bindMember historyId (historyValue historyImage)))
      ]
        <> [(volumeId, bindMemberWith volumePolicy volumeId volumeValue) | shapeVolume volume, not (shapeVolumeBackup volume)]
        <> [(workerId, bindMember workerId (workerValue image)) | shapeWorker volume]
        <> [(extraId, bindMember extraId (fixture image)) | Just row <- [shapeExtra volume], Just fixture <- [kindFixture row]]
    )
    <> if shapeVolumeBackup volume then backedUpVolume image else Map.empty

-- | The labelled backup-included claim and its scheduled producer (EP-183
-- M3). In production each producer member is ordered after the foundation's
-- namespace, another scope; the model has no foundation scope, so that one
-- edge is dropped and every other edge is kept as compiled.
backedUpVolume :: Text -> Map.Map ResourceId (ManagedResource, ByteString)
backedUpVolume image =
  Map.insert volumeId claim (Map.map (first withoutNamespace) (Map.unions (map snd producers)))
  where
    claim = bindMemberWith volumePolicy volumeId labelledVolumeValue
    objective = if image == "v2" then DailyRecoveryPoint else HourlyRecoveryPoint
    producers = ok (compileVolumeBackups (DatabaseBackupTarget databaseBackend objective) foundationNamespace (SourceLocation "model" "web") (Map.singleton volumeId claim))
    withoutNamespace member = member {dependencies = filter (/= OrderedAfter foundationNamespace) (member ^. #dependencies)}
    foundationNamespace = mintResourceId appScope (ok (mkLogicalKey "namespace")) (ok (mkName "namespace"))

labelledVolumeValue :: Value
labelledVolumeValue =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("PersistentVolumeClaim" :: Text)
    , "metadata" .= object ["name" .= pvcName "web" "uploads", "namespace" .= ("personal" :: Text), "labels" .= object ["nagare.dev/app" .= ("web" :: Text), "nagare.dev/volume" .= ("uploads" :: Text)]]
    , "spec" .= object ["accessModes" .= ["ReadWriteOnce" :: Text], "resources" .= object ["requests" .= object ["storage" .= ("1Gi" :: Text)]]]
    ]

boundDigests :: Shape -> Text -> Text -> Map.Map ResourceId ContentDigest
boundDigests volume image historyImage = Map.map (contentDigest . snd) (boundMembers volume image historyImage)

extraId :: ResourceId
extraId = mintResourceId appScope (ok (mkLogicalKey "extra")) (ok (mkName "resource"))

workerId :: ResourceId
workerId = mintResourceId appScope (ok (mkLogicalKey "worker")) (ok (mkName "deployment"))

workerValue :: Text -> Value
workerValue image =
  object
    [ "apiVersion" .= ("apps/v1" :: Text)
    , "kind" .= ("Deployment" :: Text)
    , "metadata" .= object ["name" .= ("web-worker" :: Text), "namespace" .= ("personal" :: Text)]
    , "spec" .= object ["replicas" .= (1 :: Int), "template" .= object ["spec" .= object ["containers" .= [object ["image" .= ("registry.example/worker:" <> image)]]]]]
    ]

workerDigest :: Text -> ContentDigest
workerDigest image = contentDigest (snd (bindMember workerId (workerValue image)))

serviceDigest :: Text -> ContentDigest
serviceDigest image = contentDigest (snd (bindMember serviceId (serviceValue image)))

scopeFor :: Shape -> Text -> Text -> ScopeDeclaration
scopeFor volume image historyImage = ok (mkScopeDeclaration appScope [ResourceBundle (map (Managed . fst) (Map.elems (boundMembers volume image historyImage))) [] [] [] [] []])

-- * The standalone database scope

databaseScopeId :: ScopeId
databaseScopeId = ok (mkScopeId Standalone "database-pg")

databaseBackend :: StoreBackend
databaseBackend = GcsBackend "project" "bucket"

databaseScope :: ScopeDeclaration
databaseNative :: Map.Map ResourceId (ManagedResource, ByteString)
(databaseScope, databaseNative) = compiledDatabase Nothing

-- | The same database with CPU requests: only its StatefulSet changes.
resizedDatabase :: (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
resizedDatabase = compiledDatabase (Just (Dsl.Resources (Just (ok (Dsl.mkQuantity "500m"))) Nothing Nothing Nothing))

compiledDatabase :: Maybe Dsl.Resources -> (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
compiledDatabase resources =
  ok
    ( compileStandaloneDatabase
        (DatabaseDirectInput database databaseScopeId appCluster Nothing recovery (SourceLocation "model" "pg"))
        (DatabaseBackupTarget databaseBackend HourlyRecoveryPoint)
    )
  where
    database =
      Database
        (ok (mkDatabaseName "pg"))
        Nothing
        Postgres
        (defaultEngineVersion Postgres)
        (ok (Dsl.mkNamespace "personal"))
        (ok (Dsl.mkQuantity "1Gi"))
        resources
        Dsl.Retain
    recovery = RecoveryIntent (ok (mkName "backup")) (mkSecretRef (ok (mkName "nagare-db-pg")) (ok (mkName "v1")) :| [])

-- | The database member at one Kubernetes kind and name.
databaseMember :: Text -> Text -> ResourceId
databaseMember kind name =
  case [ member ^. #identity
       | (member, _) <- Map.elems databaseNative
       , Kubernetes _ _ nativeKind _ nativeName <- [member ^. #address]
       , nameText nativeKind == kind
       , nameText nativeName == name
       ] of
    [resource] -> resource
    found -> error ("database fixture lacks one " <> T.unpack kind <> " " <> T.unpack name <> ": " <> show found)

statefulId, pvcId, cronId, signingId :: ResourceId
statefulId = databaseMember "statefulset" "pg"
pvcId = databaseMember "persistentvolumeclaim" (dbPvcName "pg")
cronId = databaseMember "cronjob" "nagare-dbbackup-pg"
signingId = databaseMember "secret" "nagare-dbbackup-pg-signing"

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
