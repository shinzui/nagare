-- | An app database's on-demand backup (EP-205): one reviewed Job whose spec
-- is its accepted schedule's @jobTemplate.spec@, byte for byte. The template
-- reads its run identity from the Job's controller UID and signs its receipt
-- with the accepted schedule revision, which does not cover @suspend@, so the
-- run lands in the schedule's key space and is ingested, restored and pruned
-- exactly as a scheduled run is, quiesced or not.
module Nagare.Inventory.AppDatabaseBackup
  ( AppDatabaseBackupRequest (..)
  , compileAppDatabaseOnDemandBackupScope
  , onDemandBackupJobName
  , validOnDemandBackupId
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Char (isAsciiLower, isDigit)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Identity (checkedPhysical, requireAccepted)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced), Sensitivity (Private))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- | The accepted app-database scope, the backup's ID, and the server
-- incarnations observed now, which must be the recorded ones (ADR 27).
data AppDatabaseBackupRequest = AppDatabaseBackupRequest
  { appScope :: !ScopeDeclaration
  , namespace :: !Text
  , appDatabase :: !Text
  , backupId :: !Text
  , statefulSet :: !ResourceId
  , persistentVolume :: !ResourceId
  , statefulUid :: !PhysicalIdentity
  , pvcUid :: !PhysicalIdentity
  , incarnations :: !(Map ResourceId PhysicalIdentity)
  , source :: !SourceLocation
  }
  deriving stock (Generic, Eq, Show)

-- | At most 12 lowercase letters or digits: the Job name is the schedule's
-- (at most 49 characters), a hyphen and the ID, within the 63 characters of
-- the @batch.kubernetes.io/job-name@ label.
validOnDemandBackupId :: Text -> Bool
validOnDemandBackupId backup = not (T.null backup) && T.length backup <= 12 && T.all (\c -> isAsciiLower c || isDigit c) backup

onDemandBackupJobName :: Text -> Text -> Text
onDemandBackupJobName schedule backup = schedule <> "-" <> backup

compileAppDatabaseOnDemandBackupScope ::
  AppDatabaseBackupRequest ->
  Map ResourceId (ManagedResource, ByteString) ->
  Either (NonEmpty InventoryError) (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileAppDatabaseOnDemandBackupScope request native = do
  let scope = request ^. #appScope
      members = [member | bundle <- scopeBundles scope, Managed member <- declarations bundle]
      invalid code message = (inventoryError code message & #scopes .~ [scopeId scope] & #sources .~ [request ^. #source]) :| []
      refuse = invalid "invalid-app-database-backup"
      migrationLogin = [login | member <- members, DatabaseUserSpec _ "migration" login _ _ <- [member ^. #spec]]
  -- The Job dumps with the migration credential (ADR 30).
  case migrationLogin of
    [LoginOpen] -> pure ()
    [LoginQuiesced] -> Left (invalid "app-database-quiesced" "the migration user is quiesced, and the backup dumps with its credential; resume it or quiesce only the runtime user")
    [LoginClosed] -> Left (refuse "a retired app database is not backed up on demand")
    _ -> Left (refuse "the app database has no unique migration user")
  unless (validOnDemandBackupId (request ^. #backupId)) (Left (refuse "the backup ID is 1 to 12 lowercase letters or digits"))
  _ <- first refuse (requireAccepted "the app-database server StatefulSet" (checkedPhysical (request ^. #incarnations) (request ^. #statefulSet) (request ^. #statefulUid)))
  _ <- first refuse (requireAccepted "the app-database server volume" (checkedPhysical (request ^. #incarnations) (request ^. #persistentVolume) (request ^. #pvcUid)))
  (cron, cronBytes) <- case [(member, bytes) | member <- members, Kubernetes _ "batch" kind' _ _ <- [member ^. #address], nameText kind' == "cronjob", Just (accepted, bytes) <- [Map.lookup (member ^. #identity) native], accepted == member] of
    [single] -> Right single
    _ -> Left (refuse "the app database has no accepted backup schedule with native bytes")
  (cluster, schedule) <- case cron ^. #address of
    Kubernetes clusterId _ _ (Just ns) name | nameText ns == request ^. #namespace -> Right (clusterId, nameText name)
    _ -> Left (refuse "the backup schedule is not in the app database's namespace")
  template <- case Yaml.decodeEither' cronBytes :: Either Yaml.ParseException Value of
    Right (Object root)
      | Just (Object spec) <- KM.lookup "spec" root
      , Just (Object jobTemplate) <- KM.lookup "jobTemplate" spec
      , Just jobSpec <- KM.lookup "spec" jobTemplate ->
          Right jobSpec
    _ -> Left (refuse "the backup schedule has no jobTemplate.spec")
  let jobName = onDemandBackupJobName schedule (request ^. #backupId)
      job =
        object
          [ "apiVersion" .= ("batch/v1" :: Text)
          , "kind" .= ("Job" :: Text)
          , "metadata"
              .= object
                [ "name" .= jobName
                , "namespace" .= (request ^. #namespace)
                , "labels" .= object ["nagare.dev/app-database" .= (request ^. #appDatabase), "nagare.dev/app-database-backup" .= ("on-demand" :: Text)]
                ]
          , "spec" .= template
          ]
  owner <- first refuse (mkScopeId Standalone ("appdb-backup-" <> request ^. #namespace <> "-" <> request ^. #appDatabase <> "-" <> request ^. #backupId))
  key <- first refuse (mkLogicalKey (request ^. #backupId))
  role <- first refuse (mkName "job")
  canonical <- first refuse (canonicalValue job)
  let jobId = mintResourceId owner key role
  (bound, bytes) <-
    first
      (:| [])
      ( bindKubernetesObject
          KubernetesInput
            { resourceId = jobId
            , ownerScope = owner
            , clusterId = cluster
            , inputObject = job
            , objectDigest = contentDigest canonical
            , lifecyclePolicy = DeleteWhenUnreferenced
            , inputDataPolicy = Stateless
            , inputSensitivity = Private
            , sourceLocation = request ^. #source
            }
      )
  -- The Job reads the server and the schedule's credential and signing Secrets.
  let secrets = [secret ^. #identity | secret <- members, Kubernetes _ "" kind' _ _ <- [secret ^. #address], nameText kind' == "secret"]
      member = bound {dependencies = map OrderedAfter ([request ^. #statefulSet, request ^. #persistentVolume, cron ^. #identity] <> secrets)}
      overrides =
        Map.fromList
          [ ("backup.id", request ^. #backupId)
          , ("backup.job", jobName)
          , ("backup.source.scope", scopeIdText (scopeId scope))
          , ("backup.source.statefulset.uid", physicalIdentityText (request ^. #statefulUid))
          , ("backup.source.pvc.uid", physicalIdentityText (request ^. #pvcUid))
          ]
  declared <- mkScopeDeclaration owner [ResourceBundle [Managed member] [] [] [] [] []]
  pure (withScopeOverrides overrides declared, Map.singleton jobId (member, bytes))
