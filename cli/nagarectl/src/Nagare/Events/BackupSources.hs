{-# LANGUAGE OverloadedStrings #-}

-- | The accepted backup schedules the collector reads (EP-233), resolved
-- from accepted inventory alone: the snapshot names each managed database's
-- and app database's CronJob, signing Secret, StatefulSet and claim; the
-- head records their incarnations; the native store keeps the accepted
-- CronJob bytes of every converged revision. A receipt must name the
-- recorded source incarnations, so a same-name replacement made outside
-- Nagare is unresolved, never a completion. No cluster is observed.
--
-- A schedule that cannot be resolved is reported with its reason and left
-- out; the others are still collected.
module Nagare.Events.BackupSources
  ( loadBackupSchedules
  , resolveSchedules
  )
where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Cluster.GcsJob (StoreBackend, storeObjectUrl)
import Nagare.Database.AppDatabase.Backup (appDatabaseBackupScheduleName)
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude
import Nagare.Events.Backup
import Nagare.Events.Source (ResourceRef (..))
import Nagare.Inventory.AppDatabase (AppDatabaseScheduleSource (..), appDatabaseScheduleSource)
import Nagare.Inventory.Backup (ScheduledReceiptExpectation (..), scheduledReceiptExpectationFromCronJob)
import Nagare.Inventory.BackupReceipt (scheduledAppDatabaseReceiptExpectationFromCronJob)
import Nagare.Inventory.Journal (JournalEvent, decodeJournalEvent)
import Nagare.Inventory.Plan (InventoryHistory (..), historyReservations, loadInventoryHistoryAt)
import Nagare.Inventory.ScheduleHistory (convergedScheduleRevisionsIn)
import Nagare.Inventory.ScheduledStatus (ScheduledStatusKind (..), ScheduledStatusSource (..), scheduledStatusSources)
import Nagare.Inventory.Status (loadAcceptedNativeSelected)
import Nagare.Inventory.Store (HeadManifest (..), InventoryStore, readHead, readJournalPrefix, revisionGeneration)
import Nagare.Resource.Inventory
import Nagare.Resource.Types

-- | The context's accepted database and app-database schedules, and the
-- ones that could not be resolved with their reasons.
loadBackupSchedules :: InventoryStore -> StoreBackend -> IO (Either Text ([BackupSchedule], [(Text, Text)]))
loadBackupSchedules store backend = do
  loadedHead <- readHead store
  case loadedHead of
    Left err -> pure (Left (T.pack (show err)))
    Right Nothing -> pure (Left "accepted inventory history is absent")
    Right (Just headValue) -> do
      historyResult <- loadInventoryHistoryAt store headValue
      case historyResult of
        Left err -> pure (Left (T.pack (show err)))
        Right history -> case mkScopeSnapshot (headBinding headValue) (Map.map (\(revision, declaration) -> (revisionGeneration revision, declaration)) (historyAccepted history)) (historyReservations history) of
          Left errs -> pure (Left (T.pack (show (NE.toList errs))))
          Right snapshot -> case composeSnapshot snapshot of
            Left errs -> pure (Left (T.pack (show (NE.toList errs))))
            Right validated -> do
              let sources = resolveSchedules snapshot (headIncarnations headValue)
                  crons = Set.fromList [found ^. #cron . #identity | Right found <- map snd sources]
              native <- loadAcceptedNativeSelected crons store history validated
              raw <- readJournalPrefix store (headSequence headValue)
              case (native, first (T.pack . show) raw >>= traverse decodeJournalEvent) of
                (Left err, _) -> pure (Left err)
                (_, Left err) -> pure (Left ("the journal cannot be read for schedule revisions: " <> err))
                (Right (accepted, _), Right events) -> do
                  built <- traverse (build accepted events) sources
                  pure (Right ([schedule | Right schedule <- built], [problem | Left problem <- built]))
  where
    build :: Map ResourceId (ManagedResource, ByteString) -> [JournalEvent] -> (Text, Either Text Resolved) -> IO (Either (Text, Text) BackupSchedule)
    build _ _ (label', Left reason) = pure (Left (label', reason))
    build accepted events (label', Right found) = case Map.lookup (found ^. #cron . #identity) accepted of
      Nothing -> pure (Left (label', "the accepted CronJob has no native bytes"))
      Just (_, cronBytes) -> do
        historical <- convergedScheduleRevisionsIn store events (found ^. #cron)
        let expect = expectationFor found
        pure $ do
          current <- first ((,) label') (expect cronBytes)
          older <- first ((,) label') historical
          let expectations = current : [e | bytes <- older, Right e <- [expect bytes], e /= current]
              objectPrefix = scheduledObjectPrefix current
          keyPrefix <- maybe (Left (label', "the schedule uploads outside the backup bucket")) Right (T.stripPrefix (storeObjectUrl backend "") objectPrefix)
          pure
            BackupSchedule
              { kind = found ^. #kind
              , label = label'
              , owner = found ^. #owner
              , schedule = found ^. #cron . #identity
              , keyPrefix
              , objectPrefix
              , expectations
              , signing = found ^. #signing
              , source = ResourceRef (found ^. #owner) (Just (found ^. #stateful)) Nothing (Just (found ^. #statefulUid))
              }
    expectationFor found = case found ^. #kind of
      DatabaseSchedule -> scheduledReceiptExpectationFromCronJob backend (found ^. #namespace) (found ^. #name) (found ^. #statefulUid) (found ^. #pvcUid)
      AppDatabaseSchedule -> scheduledAppDatabaseReceiptExpectationFromCronJob backend (found ^. #namespace) (found ^. #name) (found ^. #statefulUid) (found ^. #pvcUid)

-- | One schedule's accepted members and recorded incarnations.
data Resolved = Resolved
  { kind :: !ScheduleKind
  , namespace :: !Text
  , name :: !Text
  , owner :: !ScopeId
  , cron :: !ManagedResource
  , stateful :: !ResourceId
  , statefulUid :: !PhysicalIdentity
  , pvcUid :: !PhysicalIdentity
  , signing :: !SigningRef
  }
  deriving stock (Generic)

-- | Every database and app-database schedule of a snapshot, by label,
-- resolved to its accepted members and their recorded incarnations.
resolveSchedules :: ScopeSnapshot -> Map ResourceId PhysicalIdentity -> [(Text, Either Text Resolved)]
resolveSchedules snapshot incarnations =
  [ (status ^. #label, resolve status)
  | status <- scheduledStatusSources snapshot
  , case status ^. #kind of
      VolumeStatus _ -> False
      _ -> True
  ]
  where
    scopes = map snd (Map.elems (snapshotScopes snapshot))
    members scope' address = [member | bundle <- scopeBundles scope', Managed member <- declarations bundle, member ^. #address == address]
    recorded what member = maybe (Left (what <> " has no recorded incarnation")) Right (Map.lookup (member ^. #identity) incarnations)
    signingRef namespace' schedule' member = SigningRef namespace' (schedule' <> "-signing") (member ^. #identity) <$> recorded "the signing Secret" member
    resolve status = do
      let namespace' = status ^. #namespace
      -- The accepted CronJob's own address names the cluster its siblings are in.
      cluster <- case [member ^. #address | scope' <- scopes, scopeId scope' == status ^. #source, bundle <- scopeBundles scope', Managed member <- declarations bundle, member ^. #identity == status ^. #schedule] of
        [Kubernetes cluster' _ _ _ _] -> Right cluster'
        _ -> Left "the schedule's CronJob is not one accepted Kubernetes member"
      let address api kind' name' = kubernetesAddress cluster api kind' (Just namespace') name'
      case status ^. #kind of
        DatabaseStatus database -> do
          let schedule' = "nagare-dbbackup-" <> database
          statefulAddress <- address "apps/v1" "StatefulSet" database
          (owner', stateful') <- case [(scope', member) | scope' <- scopes, member <- members scope' statefulAddress] of
            [single] -> Right single
            _ -> Left "the schedule needs one accepted database StatefulSet"
          let unique what address' = case members owner' address' of
                [single] -> Right single
                _ -> Left ("the schedule needs one accepted " <> what)
          pvc <- address "v1" "PersistentVolumeClaim" (dbPvcName database) >>= unique "database claim"
          cron' <- address "batch/v1" "CronJob" schedule' >>= unique "backup CronJob"
          signing' <- address "v1" "Secret" (schedule' <> "-signing") >>= unique "signing Secret"
          Resolved DatabaseSchedule namespace' database (scopeId owner') cron' (stateful' ^. #identity)
            <$> recorded "the StatefulSet" stateful'
            <*> recorded "the claim" pvc
            <*> signingRef namespace' schedule' signing'
        AppDatabaseStatus appDatabase -> do
          found <- appDatabaseScheduleSource snapshot cluster namespace' appDatabase
          Resolved AppDatabaseSchedule namespace' appDatabase (scopeId (found ^. #scope)) (found ^. #schedule) (found ^. #statefulSet . #identity)
            <$> recorded "the server StatefulSet" (found ^. #statefulSet)
            <*> recorded "the server claim" (found ^. #claim)
            <*> signingRef namespace' (appDatabaseBackupScheduleName appDatabase) (found ^. #signing)
        VolumeStatus _ -> Left "volume schedules are not collected"
