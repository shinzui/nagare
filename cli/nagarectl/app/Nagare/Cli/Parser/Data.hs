-- | Parser / Data. Executable-private CLI boundary.
module Nagare.Cli.Parser.Data
  ( brokerCmd
  , dbCmd
  , inventoryResourceOption
  , storageCmd
  )
where

import Nagare.Cli.Options
  ( BrokerCommand (..)
  , BrokerCreateOpts (..)
  , BrokerListOpts (..)
  , BrokerNameOpts (..)
  , Command (..)
  , DbBackupOpts (..)
  , DbBackupReceiptsOpts (..)
  , DbCommand (..)
  , DbCreateOpts (..)
  , DbEscrowSigningKeyOpts (..)
  , DbListOpts (..)
  , DbNameOpts (..)
  , DbPruneBackupOpts (..)
  , DbPruneScheduledBackupsOpts (..)
  , DbRecoverScheduledPruneOpts (..)
  , DbRestoreOpts (..)
  , DbRestoreRebuiltOpts (..)
  , DbVerifyEscrowedBackupOpts (..)
  , StandaloneRetireOpts (..)
  , StorageCommand (..)
  )
import Nagare.Cli.Parser.Common (dryRunOpt, namespaceOpt)
import Nagare.Cli.Parser.Environment (storeCommonOptsParser)
import Nagare.Dsl.Broker (BrokerProvider (Redpanda))
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Prelude
import Options.Applicative
  ( Alternative (many)
  , Parser
  , ParserInfo
  , ReadM
  , argument
  , auto
  , command
  , eitherReader
  , fullDesc
  , help
  , helper
  , info
  , internal
  , long
  , metavar
  , option
  , optional
  , progDesc
  , strArgument
  , strOption
  , subparser
  , switch
  , (<**>)
  )

-- Managed-database option fragments (MasterPlan 9, EP-45).

-- | Parse the positional ENGINE argument into the typed 'Engine'.
engineReader :: ReadM Engine
engineReader = eitherReader $ \case
  "postgres" -> Right Postgres
  "redis" -> Right Redis
  "clickhouse" -> Right ClickHouse
  other -> Left ("unknown engine '" <> other <> "' (expected postgres | redis | clickhouse)")

dbNameArg :: Parser String
dbNameArg = strArgument (metavar "NAME" <> help "Managed database name (DNS label)")

brokerProviderReader :: ReadM BrokerProvider
brokerProviderReader = eitherReader $ \case
  "redpanda" -> Right Redpanda
  "tansu" -> Left "Tansu is reserved but not implemented yet; use redpanda"
  other -> Left ("unknown broker provider '" <> other <> "' (expected redpanda)")

brokerNameArg :: Parser String
brokerNameArg = strArgument (metavar "NAME" <> help "Broker name (DNS label)")

dbListOptsParser :: Parser DbListOpts
dbListOptsParser = DbListOpts <$> namespaceOpt

dbNameOptsParser :: Parser DbNameOpts
dbNameOptsParser = DbNameOpts <$> dbNameArg <*> namespaceOpt

dbCreateOptsParser :: Parser DbCreateOpts
dbCreateOptsParser =
  DbCreateOpts
    <$> namespaceOpt
    <*> switch (long "system-namespace" <> internal)
    <*> optional (strOption (long "version" <> metavar "TAG" <> help "Pinned engine image tag (per-engine default if absent)"))
    <*> optional (strOption (long "size" <> metavar "QTY" <> help "Data volume size (default 10Gi, redis 2Gi)"))
    <*> optional (strOption (long "cpu" <> metavar "QTY" <> help "CPU limit (e.g. 500m)"))
    <*> optional (strOption (long "memory" <> metavar "QTY" <> help "Memory limit (e.g. 1Gi)"))
    <*> optional (strOption (long "config" <> metavar "FILE" <> help "Load a typed Database from a Config.hs instead of building from flags"))
    <*> dryRunOpt
    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save a reviewed standalone database plan for inventory apply"))
    <*> optional (strOption (long "recovery-backup" <> metavar "NAME" <> help "Recovery backup policy for reviewed database creation"))
    <*> optional (strOption (long "recovery-key-version" <> metavar "VERSION" <> help "Credential recovery key version for reviewed database creation"))

standaloneRetireOptsParser :: Parser String -> Parser StandaloneRetireOpts
standaloneRetireOptsParser nameParser =
  StandaloneRetireOpts
    <$> nameParser
    <*> namespaceOpt
    <*> optional (strOption (long "scope-key" <> metavar "KEY" <> help "Pinned standalone scope key used at creation"))
    <*> strOption (long "save-plan" <> metavar "DIR" <> help "Save a review that retires the scope and retains all provider resources")

inventoryResourceOption :: Parser String
inventoryResourceOption =
  strOption
    (long "resource" <> metavar "RESOURCE_ID" <> help "Retained resource to collect; repeat for multiple resources")

brokerListOptsParser :: Parser BrokerListOpts
brokerListOptsParser = BrokerListOpts <$> namespaceOpt

brokerNameOptsParser :: Parser BrokerNameOpts
brokerNameOptsParser = BrokerNameOpts <$> brokerNameArg <*> namespaceOpt

brokerCreateOptsParser :: Parser BrokerCreateOpts
brokerCreateOptsParser =
  BrokerCreateOpts
    <$> namespaceOpt
    <*> optional (strOption (long "version" <> metavar "TAG" <> help "Pinned provider image tag (provider default if absent)"))
    <*> optional (strOption (long "size" <> metavar "QTY" <> help "Data volume size (default 5Gi)"))
    <*> optional (strOption (long "cpu" <> metavar "QTY" <> help "CPU limit (e.g. 1)"))
    <*> optional (strOption (long "memory" <> metavar "QTY" <> help "Memory limit (e.g. 1536Mi)"))
    <*> optional (strOption (long "config" <> metavar "FILE" <> help "Load a typed Broker from a Config.hs instead of building from flags"))
    <*> dryRunOpt
    <*> optional (option auto (long "redpanda-smp" <> metavar "N" <> help "Redpanda core count / --smp"))
    <*> optional (strOption (long "redpanda-memory" <> metavar "QTY" <> help "Redpanda process memory (e.g. 1G)"))
    <*> many (strOption (long "topic" <> metavar "TOPIC" <> help "Topic to create; repeat for multiple topics"))
    <*> optional (option auto (long "topic-partitions" <> metavar "N" <> help "Partitions for topics declared with --topic"))
    <*> optional (option auto (long "topic-retention-ms" <> metavar "MS" <> help "retention.ms for topics declared with --topic"))
    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save a reviewed standalone broker plan for inventory apply"))
    <*> optional (strOption (long "recovery-backup" <> metavar "NAME" <> help "Recovery backup policy for a reviewed broker"))
    <*> optional (strOption (long "recovery-key" <> metavar "NAME" <> help "Recovery key name for a reviewed broker"))
    <*> optional (strOption (long "recovery-key-version" <> metavar "VERSION" <> help "Recovery key version for a reviewed broker"))

dbBackupBucketOpt :: Parser (Maybe String)
dbBackupBucketOpt =
  optional
    ( strOption
        ( long "bucket"
            <> metavar "BUCKET"
            <> help "GCS backup bucket (overrides the target profile NAGARE_BACKUP_BUCKET / <project>-nagare-backups)"
        )
    )

dbBackupOptsParser :: Parser DbBackupOpts
dbBackupOptsParser =
  DbBackupOpts
    <$> dbNameArg
    <*> namespaceOpt
    <*> dbBackupBucketOpt
    <*> optional (option auto (long "keep" <> metavar "N" <> help "Legacy direct backup count to retain"))
    <*> dryRunOpt
    <*> optional (strOption (long "backup-id" <> metavar "ID" <> help "Stable ID for a reviewed manual backup"))
    <*> optional (strOption (long "expires-at" <> metavar "UTC" <> help "Reviewed backup expiry, YYYY-MM-DDTHH:MM:SSZ (default: retain)"))
    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save a reviewed manual backup plan for separate apply"))

dbRestoreOptsParser :: Parser DbRestoreOpts
dbRestoreOptsParser =
  DbRestoreOpts
    <$> dbNameArg
    <*> strArgument (metavar "BACKUP_ID" <> help "Backup timestamp (or full gs:// URL) to restore")
    <*> namespaceOpt
    <*> dbBackupBucketOpt
    <*> switch (long "into-live" <> help "Deferred: live database overwrite is unavailable; use an isolated target")
    <*> dryRunOpt
    <*> optional (strOption (long "restore-id" <> metavar "ID" <> help "Stable ID for a reviewed database restore"))
    <*> optional (strOption (long "recovery-backup" <> metavar "ID" <> help "Distinct accepted pre-change manual backup for a reviewed live restore"))
    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save a reviewed database restore plan for separate apply"))

dbPruneBackupOptsParser :: Parser DbPruneBackupOpts
dbPruneBackupOptsParser =
  DbPruneBackupOpts
    <$> dbNameArg
    <*> strArgument (metavar "BACKUP_ID" <> help "Accepted manual backup ID to prune after expiry")
    <*> namespaceOpt
    <*> dbBackupBucketOpt
    <*> strOption (long "save-plan" <> metavar "DIR" <> help "Save the exact backup pruning review")

dbPruneScheduledBackupsOptsParser :: Parser DbPruneScheduledBackupsOpts
dbPruneScheduledBackupsOptsParser =
  DbPruneScheduledBackupsOpts
    <$> dbNameArg
    <*> namespaceOpt
    <*> dbBackupBucketOpt
    <*> strOption (long "save-plan" <> metavar "DIR" <> help "Save the exact scheduled retention review")

dbRecoverScheduledPruneOptsParser :: Parser DbRecoverScheduledPruneOpts
dbRecoverScheduledPruneOptsParser =
  DbRecoverScheduledPruneOpts
    <$> dbNameArg
    <*> strArgument (metavar "BACKUP_ID" <> help "Exact scheduled Job UID from the abandoned prune")
    <*> namespaceOpt
    <*> dbBackupBucketOpt
    <*> strOption (long "failed-review" <> metavar "DIR" <> help "Published immutable review of the failed scheduled prune")
    <*> strOption (long "save-plan" <> metavar "DIR" <> help "Save an exact remaining-receipt recovery review")

dbBackupReceiptsOptsParser :: Parser DbBackupReceiptsOpts
dbBackupReceiptsOptsParser =
  DbBackupReceiptsOpts
    <$> dbNameArg
    <*> namespaceOpt
    <*> dbBackupBucketOpt
    <*> optional (strOption (long "backup-id" <> metavar "JOB_UID" <> help "Physical scheduled backup Job UID to ingest"))
    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save an exact scheduled receipt ingestion review"))
    <*> switch (long "check-freshness" <> help "Fail unless the newest verified recovery point is within the warning threshold of the schedule's accepted objective")
    <*> switch (long "all" <> help "With --save-plan: review the ingestion of every verified, not-yet-ingested scheduled run in one transaction")

dbEscrowSigningKeyOptsParser :: Parser DbEscrowSigningKeyOpts
dbEscrowSigningKeyOptsParser =
  DbEscrowSigningKeyOpts
    <$> dbNameArg
    <*> namespaceOpt
    <*> optional (strOption (long "output" <> metavar "FILE" <> help "sops-encrypted escrow path (default: the context's cluster-secrets backup-signing directory)"))

dbRestoreRebuiltOptsParser :: Parser DbRestoreRebuiltOpts
dbRestoreRebuiltOptsParser =
  DbRestoreRebuiltOpts
    <$> dbNameArg
    <*> namespaceOpt
    <*> strOption (long "restore-id" <> metavar "ID" <> help "Fixed ID of this restore review")
    <*> optional (strOption (long "escrow" <> metavar "FILE" <> help "sops-encrypted escrow of the predecessor's signing key (default: the context's cluster-secrets backup-signing directory)"))
    <*> dbBackupBucketOpt
    <*> optional (strOption (long "offline-object-store" <> metavar "URL" <> help "Local mode: read an offline copy of the object store at a loopback http://127.0.0.1:PORT instead of through the cluster"))
    <*> optional (strOption (long "offline-credentials" <> metavar "FILE" <> help "Private file with AWS_ACCESS_KEY_ID= and AWS_SECRET_ACCESS_KEY= lines for --offline-object-store"))
    <*> strOption (long "save-plan" <> metavar "DIR" <> help "Write the reviewed restore")

dbVerifyEscrowedBackupOptsParser :: Parser DbVerifyEscrowedBackupOpts
dbVerifyEscrowedBackupOptsParser =
  DbVerifyEscrowedBackupOpts
    <$> dbNameArg
    <*> namespaceOpt
    <*> strOption (long "backup-id" <> metavar "JOB_UID" <> help "Physical scheduled backup Job UID to verify")
    <*> optional (strOption (long "escrow" <> metavar "FILE" <> help "sops-encrypted escrow path (default: the context's cluster-secrets backup-signing directory)"))
    <*> dbBackupBucketOpt
    <*> optional (strOption (long "offline-object-store" <> metavar "URL" <> help "Local mode: read an offline copy of the object store at a loopback http://127.0.0.1:PORT instead of through the cluster"))
    <*> optional (strOption (long "offline-credentials" <> metavar "FILE" <> help "Private file with AWS_ACCESS_KEY_ID= and AWS_SECRET_ACCESS_KEY= lines for --offline-object-store"))

dbManualReceiptOptsParser :: Parser DbBackupReceiptsOpts
dbManualReceiptOptsParser =
  DbBackupReceiptsOpts
    <$> dbNameArg
    <*> namespaceOpt
    <*> dbBackupBucketOpt
    <*> (Just <$> strOption (long "backup-id" <> metavar "ID" <> help "Accepted manual backup ID"))
    <*> (Just <$> strOption (long "save-plan" <> metavar "DIR" <> help "Save a reviewed manual receipt record"))
    <*> pure False
    <*> pure False

storageCmd :: ParserInfo Command
storageCmd =
  info
    (storageSubparser <**> helper)
    (fullDesc <> progDesc "Inspect an app's persistent volumes")

storageSubparser :: Parser Command
storageSubparser =
  subparser
    ( command
        "list"
        ( info
            (Storage . StorageList <$> storeCommonOptsParser <**> helper)
            (progDesc "List an app's volumes and their PVC status")
        )
        <> command
          "inspect"
          ( info
              ( Storage
                  <$> ( StorageInspect
                          <$> storeCommonOptsParser
                          <*> strArgument (metavar "VOLUME" <> help "Declared volume name")
                      )
                    <**> helper
              )
              (progDesc "Show full detail of one volume's PVC")
          )
        <> command
          "snapshot"
          ( info
              ( Storage
                  <$> ( StorageSnapshot
                          <$> storeCommonOptsParser
                          <*> strArgument (metavar "VOLUME" <> help "Declared volume name")
                          <*> optional
                            ( strOption
                                ( long "bucket"
                                    <> metavar "BUCKET"
                                    <> help "GCS backup bucket (overrides the target profile NAGARE_BACKUP_BUCKET / <project>-nagare-backups)"
                                )
                            )
                          <*> optional
                            ( strOption
                                ( long "expires-at"
                                    <> metavar "UTC"
                                    <> help "Finite UTC expiry for reviewed snapshot pruning"
                                )
                            )
                          <*> optional
                            ( strOption
                                ( long "snapshot-id"
                                    <> metavar "ID"
                                    <> help "Stable ID for one reviewed volume snapshot"
                                )
                            )
                          <*> optional
                            ( strOption
                                ( long "save-plan"
                                    <> metavar "DIR"
                                    <> help "Save the reviewed snapshot plan"
                                )
                            )
                          <*> switch (long "dry-run" <> help "Print a read-only legacy Job preview")
                      )
                    <**> helper
              )
              (progDesc "Save a reviewed volume snapshot Job; apply the saved plan to run it")
          )
        <> command
          "restore"
          ( info
              ( Storage
                  <$> ( StorageRestore
                          <$> storeCommonOptsParser
                          <*> strArgument (metavar "VOLUME" <> help "Declared volume name")
                          <*> strArgument (metavar "BACKUP_ID" <> help "Accepted volume snapshot ID")
                          <*> optional
                            ( strOption
                                ( long "bucket"
                                    <> metavar "BUCKET"
                                    <> help "GCS backup bucket (overrides the target profile NAGARE_BACKUP_BUCKET / <project>-nagare-backups)"
                                )
                            )
                          <*> switch (long "into-live" <> help "Deferred: live volume overwrite is unavailable; use a scratch PVC")
                          <*> dryRunOpt
                          <*> optional
                            ( strOption
                                ( long "restore-id"
                                    <> metavar "ID"
                                    <> help "Stable ID for one reviewed scratch restore"
                                )
                            )
                          <*> optional
                            ( strOption
                                ( long "save-plan"
                                    <> metavar "DIR"
                                    <> help "Save the reviewed scratch restore plan"
                                )
                            )
                          <*> switch (long "scheduled-run" <> help "BACKUP_ID names an accepted scheduled run (its Job UID) instead of a manual snapshot")
                      )
                    <**> helper
              )
              (progDesc "Save a reviewed scratch restore from an accepted volume snapshot or scheduled run")
          )
        <> command
          "restore-rebuilt"
          ( info
              ( Storage
                  <$> ( StorageRestoreRebuilt
                          <$> strArgument (metavar "APP" <> help "Application that declares the volume")
                          <*> strArgument (metavar "VOLUME" <> help "Declared volume name")
                          <*> namespaceOpt
                          <*> strOption (long "restore-id" <> metavar "ID" <> help "Fixed ID of this restore review")
                          <*> optional (strOption (long "bucket" <> metavar "BUCKET" <> help "GCS backup bucket (overrides the target profile)"))
                          <*> optional (strOption (long "offline-object-store" <> metavar "URL" <> help "Local mode: verify against an offline copy of the object store at a loopback http://127.0.0.1:PORT"))
                          <*> optional (strOption (long "offline-credentials" <> metavar "FILE" <> help "Private file with AWS_ACCESS_KEY_ID= and AWS_SECRET_ACCESS_KEY= lines for --offline-object-store"))
                          <*> strOption (long "save-plan" <> metavar "DIR" <> help "Write the reviewed restore")
                      )
                    <**> helper
              )
              (progDesc "Review restoring a rebuilt volume from the snapshot its rebuild named (EP-183)")
          )
        <> command
          "prune-scheduled-backups"
          ( info
              ( Storage
                  <$> ( StoragePruneScheduledBackups
                          <$> strArgument (metavar "APP" <> help "Application that declares the volume")
                          <*> strArgument (metavar "VOLUME" <> help "Declared backup-included volume name")
                          <*> namespaceOpt
                          <*> optional (strOption (long "bucket" <> metavar "BUCKET" <> help "GCS backup bucket (overrides the target profile)"))
                          <*> strOption (long "save-plan" <> metavar "DIR" <> help "Write the reviewed prune")
                      )
                    <**> helper
              )
              (progDesc "Review the volume's accepted scheduled backups past the retention policy (every point 48 h, the newest per day 30 days)")
          )
        <> command
          "recover-scheduled-prune"
          ( info
              ( Storage
                  <$> ( StorageRecoverScheduledPrune
                          <$> strArgument (metavar "APP" <> help "Application that declares the volume")
                          <*> strArgument (metavar "VOLUME" <> help "Declared backup-included volume name")
                          <*> namespaceOpt
                          <*> strOption (long "backup-id" <> metavar "ID" <> help "Job UID of the run the abandoned prune named")
                          <*> optional (strOption (long "bucket" <> metavar "BUCKET" <> help "GCS backup bucket (overrides the target profile)"))
                          <*> strOption (long "failed-review" <> metavar "DIR" <> help "The abandoned prune's saved review")
                          <*> strOption (long "save-plan" <> metavar "DIR" <> help "Write the reviewed recovery")
                      )
                    <**> helper
              )
              (progDesc "Review deletion of the exact receipt left by an abandoned partial scheduled volume prune")
          )
        <> command
          "backup-receipts"
          ( info
              ( Storage
                  <$> ( StorageBackupReceipts
                          <$> strArgument (metavar "APP" <> help "Application that declares the volume")
                          <*> strArgument (metavar "VOLUME" <> help "Backup-included volume name")
                          <*> namespaceOpt
                          <*> optional (strOption (long "bucket" <> metavar "BUCKET" <> help "GCS backup bucket (overrides the target profile)"))
                          <*> optional (strOption (long "backup-id" <> metavar "ID" <> help "Ingest one scheduled run by its producer Job UID"))
                          <*> switch (long "all" <> help "Ingest every verified, not-yet-ingested run in one review")
                          <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save the reviewed ingestion"))
                      )
                    <**> helper
              )
              (progDesc "List a volume's scheduled backups, or review ingesting verified runs (EP-183)")
          )
        <> command
          "prune-snapshot"
          ( info
              ( Storage
                  <$> ( StoragePrune
                          <$> storeCommonOptsParser
                          <*> strArgument (metavar "VOLUME" <> help "Declared volume name")
                          <*> strArgument (metavar "BACKUP_ID" <> help "Expired accepted snapshot ID")
                          <*> optional
                            ( strOption
                                ( long "bucket"
                                    <> metavar "BUCKET"
                                    <> help "GCS backup bucket override"
                                )
                            )
                          <*> strOption
                            ( long "save-plan"
                                <> metavar "DIR"
                                <> help "Save an exact reviewed pruning plan"
                            )
                      )
                    <**> helper
              )
              (progDesc "Save expiry-gated exact volume snapshot pruning for separate apply")
          )
    )

dbCmd :: ParserInfo Command
dbCmd =
  info
    (dbSubparser <**> helper)
    (fullDesc <> progDesc "Provision and operate managed databases (Postgres, Redis, ClickHouse)")

brokerCmd :: ParserInfo Command
brokerCmd =
  info
    (brokerSubparser <**> helper)
    (fullDesc <> progDesc "Provision and operate in-cluster messaging brokers")

brokerSubparser :: Parser Command
brokerSubparser =
  subparser
    ( command
        "list"
        ( info
            (Broker . BrokerList <$> brokerListOptsParser <**> helper)
            (progDesc "List managed brokers in a namespace")
        )
        <> command
          "create"
          ( info
              ( Broker
                  <$> ( BrokerCreate
                          <$> Options.Applicative.argument brokerProviderReader (metavar "PROVIDER" <> help "redpanda")
                          <*> brokerNameArg
                          <*> brokerCreateOptsParser
                      )
                    <**> helper
              )
              (progDesc "Create an internal Kafka-compatible broker")
          )
        <> command
          "get"
          ( info
              (Broker . BrokerGet <$> brokerNameOptsParser <**> helper)
              (progDesc "Show one broker's detail")
          )
        <> command
          "restart"
          ( info
              ( Broker
                  <$> ( BrokerRestart
                          <$> brokerNameOptsParser
                          <*> dryRunOpt
                          <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save a reviewed restart of an accepted broker"))
                      )
                    <**> helper
              )
              (progDesc "Review an accepted broker restart or preview the legacy command")
          )
        <> command
          "delete"
          ( info
              (Broker . BrokerDelete <$> standaloneRetireOptsParser brokerNameArg <**> helper)
              (progDesc "Save a reviewed broker retirement; provider resources remain retained")
          )
        <> command
          "retire"
          ( info
              (Broker . BrokerRetire <$> standaloneRetireOptsParser brokerNameArg <**> helper)
              (progDesc "Review retirement of an accepted broker scope; retain all provider resources")
          )
    )

dbSubparser :: Parser Command
dbSubparser =
  subparser
    ( command
        "list"
        ( info
            (Db . DbList <$> dbListOptsParser <**> helper)
            (progDesc "List managed databases in a namespace")
        )
        <> command
          "create"
          ( info
              ( Db
                  <$> ( DbCreate
                          <$> Options.Applicative.argument engineReader (metavar "ENGINE" <> help "postgres | redis | clickhouse")
                          <*> strArgument (metavar "NAME" <> help "Database name (DNS label)")
                          <*> dbCreateOptsParser
                      )
                    <**> helper
              )
              (progDesc "Create a managed database: generate credentials and provision it")
          )
        <> command
          "rename"
          ( info
              ( Db
                  <$> ( DbRename
                          <$> Options.Applicative.argument engineReader (metavar "ENGINE" <> help "postgres")
                          <*> strArgument (metavar "OLD" <> help "Accepted database name")
                          <*> strArgument (metavar "NEW" <> help "New database name (DNS label)")
                          <*> optional (strOption (long "scope-key" <> metavar "KEY" <> help "Pinned standalone scope key (default: the old name)"))
                          <*> dbCreateOptsParser
                      )
                    <**> helper
              )
              (progDesc "Review a bounded rename of a retained PostgreSQL database; the old incarnation stays retained")
          )
        <> command
          "get"
          ( info
              (Db . DbGet <$> dbNameOptsParser <**> helper)
              (progDesc "Show one database's detail and its Secret key names")
          )
        <> command
          "shell"
          ( info
              ( Db
                  <$> ( DbShell
                          <$> dbNameOptsParser
                          <*> optional
                            ( strOption
                                ( long "session-id"
                                    <> metavar "ID"
                                    <> help "Unique reviewed maintenance session ID"
                                )
                            )
                          <*> optional
                            ( strOption
                                ( long "recovery-backup"
                                    <> metavar "ID"
                                    <> help "Accepted recovery backup ID"
                                )
                            )
                          <*> optional
                            ( strOption
                                ( long "save-plan"
                                    <> metavar "DIR"
                                    <> help "Save a reviewed maintenance session"
                                )
                            )
                      )
                    <**> helper
              )
              (progDesc "Deferred: new interactive database maintenance sessions are unavailable")
          )
        <> command
          "restart"
          ( info
              ( Db
                  <$> ( DbRestart
                          <$> dbNameOptsParser
                          <*> dryRunOpt
                          <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save a reviewed restart of an accepted database"))
                      )
                    <**> helper
              )
              (progDesc "Review an accepted database restart or preview the legacy command")
          )
        <> command
          "delete"
          ( info
              (Db . DbDelete <$> standaloneRetireOptsParser dbNameArg <**> helper)
              (progDesc "Save a reviewed database retirement; provider resources remain retained")
          )
        <> command
          "retire"
          ( info
              (Db . DbRetire <$> standaloneRetireOptsParser dbNameArg <**> helper)
              (progDesc "Review retirement of an accepted database scope; retain all provider resources")
          )
        <> command
          "backup"
          ( info
              (Db . DbBackup <$> dbBackupOptsParser <**> helper)
              (progDesc "Save a reviewed manual backup with --backup-id and --save-plan; --dry-run previews legacy Job rendering")
          )
        <> command
          "prune-backup"
          ( info
              (Db . DbPruneBackup <$> dbPruneBackupOptsParser <**> helper)
              (progDesc "Review deletion of one expired manual backup and its exact receipt")
          )
        <> command
          "prune-scheduled-backups"
          ( info
              (Db . DbPruneScheduledBackups <$> dbPruneScheduledBackupsOptsParser <**> helper)
              (progDesc "Review accepted scheduled backups past the retention policy (every point 48 h, the newest per day 30 days)")
          )
        <> command
          "recover-scheduled-prune"
          ( info
              (Db . DbRecoverScheduledPrune <$> dbRecoverScheduledPruneOptsParser <**> helper)
              (progDesc "Review deletion of the exact receipt left by an abandoned partial scheduled prune")
          )
        <> command
          "backup-receipts"
          ( info
              (Db . DbBackupReceipts <$> dbBackupReceiptsOptsParser <**> helper)
              (progDesc "List accepted scheduled receipts or save one exact ingestion review")
          )
        <> command
          "escrow-signing-key"
          ( info
              (Db . DbEscrowSigningKey <$> dbEscrowSigningKeyOptsParser <**> helper)
              (progDesc "Escrow the scheduled-backup signing key in sops-encrypted operator material")
          )
        <> command
          "verify-escrowed-backup"
          ( info
              (Db . DbVerifyEscrowedBackup <$> dbVerifyEscrowedBackupOptsParser <**> helper)
              (progDesc "Verify one scheduled backup with only the escrowed key and the object store")
          )
        <> command
          "restore-rebuilt"
          ( info
              (Db . DbRestoreRebuilt <$> dbRestoreRebuiltOptsParser <**> helper)
              (progDesc "Review loading a rebuilt database from the recovery point its rebuild named (EP-183)")
          )
        <> command
          "backup-receipt"
          ( info
              (Db . DbManualReceipt <$> dbManualReceiptOptsParser <**> helper)
              (progDesc "Save a reviewed durable manual receipt after verifying the completed Job and stored bytes")
          )
        <> command
          "disable-backup-prune"
          ( info
              ( Db
                  <$> ( DbDisableBackupPrune
                          <$> dbNameOptsParser
                          <*> strOption (long "save-plan" <> metavar "DIR" <> help "Save a review that removes legacy inline backup pruning")
                      )
                    <**> helper
              )
              (progDesc "Review removal of inline pruning from an accepted database backup schedule")
          )
        <> command
          "restore"
          ( info
              (Db . DbRestore <$> dbRestoreOptsParser <**> helper)
              (progDesc "Save a reviewed scratch or fenced PostgreSQL live restore; --dry-run previews legacy Job rendering")
          )
    )
