-- | Parser / AppDatabase (EP-202). Executable-private CLI boundary.
module Nagare.Cli.Parser.AppDatabase
  ( appDatabaseParser
  )
where

import Nagare.Cli.Options.AppDatabase
import Nagare.Dsl.Prelude
import Options.Applicative
  ( Parser
  , command
  , help
  , helper
  , info
  , long
  , metavar
  , optional
  , progDesc
  , short
  , showDefault
  , strArgument
  , strOption
  , subparser
  , switch
  , value
  , (<**>)
  )

appDatabaseParser :: Parser AppDatabaseCommand
appDatabaseParser =
  subparser
    ( command
        "plan"
        ( info
            (AppDatabasePlan <$> planOpts <**> helper)
            (progDesc "Plan every app database a config declares; without --save-plan, print the operations or \"no operations\"")
        )
        <> command
          "rotate"
          ( info
              ( AppDatabaseRotate
                  <$> nameOpts "Save a review that rotates one user's password"
                  <*> strOption (long "user" <> metavar "runtime|migration" <> help "The user whose password is rotated")
                    <**> helper
              )
              (progDesc "Review a new password for one user: the Secret first, then the user; restart bound workloads afterwards")
          )
        <> command
          "retire"
          ( info
              (AppDatabaseRetire <$> nameOpts "Save a review that turns the app database's access off" <**> helper)
              (progDesc "Review retirement: logins and grants off, databases and Secrets kept")
          )
        <> command
          "quiesce"
          ( info
              ( AppDatabaseQuiesce
                  <$> nameOpts "Save a review that quiesces the app database"
                  <*> strOption (long "users" <> metavar "runtime[,migration]" <> value "runtime" <> showDefault <> help "The users whose logins close; the runtime user always")
                    <**> helper
              )
              (progDesc "Review a maintenance window: logins off, the schedule paused, then a drain proves no session, scheduled run or mutation remains")
          )
        <> command
          "resume"
          ( info
              (AppDatabaseResume <$> nameOpts "Save a review that ends the app database's maintenance window" <**> helper)
              (progDesc "Review the end of a quiesce: the quiesced users log in again and the schedule's accepted bytes come back")
          )
        <> command
          "backup"
          ( info
              ( AppDatabaseBackup
                  <$> nameOpts "Save a review that takes a signed backup now"
                  <*> optional (strOption (long "backup-id" <> metavar "ID" <> help "1 to 12 lowercase letters or digits (default: the UTC time as yyyymmddhhmm)"))
                    <**> helper
              )
              (progDesc "Review an on-demand backup: the schedule's own Job, quiesced or not; ingest its run with backup-receipts --backup-id JOB_UID")
          )
        <> command
          "evidence"
          ( info
              ( AppDatabaseEvidence
                  <$> strArgument (metavar "NAME" <> help "App database name")
                  <*> namespaceOpt
                  <*> switch (long "json" <> help "Print one JSON record")
                    <**> helper
              )
              (progDesc "Print what the last quiesce, backup and resume recorded: server identity, blocked users, drained state, transactions and proofs, and the ingested receipt")
          )
        <> command
          "backup-receipts"
          ( info
              ( AppDatabaseBackupReceipts
                  <$> ( AppDatabaseReceiptsOpts
                          <$> strArgument (metavar "NAME" <> help "App database name")
                          <*> namespaceOpt
                          <*> optional (strOption (long "bucket" <> metavar "BUCKET" <> help "Backup bucket (default: the context's)"))
                          <*> optional (strOption (long "backup-id" <> metavar "JOB_UID" <> help "Scheduled backup Job UID to ingest"))
                          <*> switch (long "all" <> help "Ingest every verified, not-yet-ingested scheduled run")
                          <*> strOption (long "save-plan" <> metavar "DIR" <> help "Save the ingestion review")
                      )
                    <**> helper
              )
              (progDesc "Review the ingestion of an app database's verified scheduled backups, the authority a restore consumes")
          )
        <> command
          "restore"
          ( info
              ( AppDatabaseRestore
                  <$> ( AppDatabaseRestoreOpts
                          <$> strArgument (metavar "NAME" <> help "App database name")
                          <*> namespaceOpt
                          <*> optional (strOption (long "bucket" <> metavar "BUCKET" <> help "Backup bucket (default: the context's)"))
                          <*> strOption (long "backup-id" <> metavar "JOB_UID" <> help "An ingested scheduled backup run")
                          <*> strOption (long "restore-id" <> metavar "ID" <> help "Scratch names are <database>_restore_<ID>")
                          <*> switch (long "rebuilt" <> help "After a server rebuild: load into the re-applied, empty declared databases instead of scratch names")
                          <*> strOption (long "save-plan" <> metavar "DIR" <> help "Save the restore review")
                      )
                    <**> helper
              )
              (progDesc "Review a restore of one app database's backup into scratch databases, leaving every other app untouched")
          )
        <> command
          "prune-scheduled-backups"
          ( info
              ( AppDatabasePruneScheduledBackups
                  <$> ( AppDatabasePruneOpts
                          <$> strArgument (metavar "NAME" <> help "App database name")
                          <*> namespaceOpt
                          <*> bucketOpt
                          <*> strOption (long "save-plan" <> metavar "DIR" <> help "Save the exact scheduled retention review")
                      )
                    <**> helper
              )
              (progDesc "Review an app database's accepted scheduled backups past the retention policy (every point 48 h, the newest per day 30 days)")
          )
        <> command
          "recover-scheduled-prune"
          ( info
              ( AppDatabaseRecoverScheduledPrune
                  <$> ( AppDatabaseRecoverPruneOpts
                          <$> strArgument (metavar "NAME" <> help "App database name")
                          <*> strArgument (metavar "BACKUP_ID" <> help "Exact scheduled Job UID from the abandoned prune")
                          <*> namespaceOpt
                          <*> bucketOpt
                          <*> strOption (long "failed-review" <> metavar "DIR" <> help "Published immutable review of the failed scheduled prune")
                          <*> strOption (long "save-plan" <> metavar "DIR" <> help "Save an exact remaining-receipt recovery review")
                      )
                    <**> helper
              )
              (progDesc "Review deletion of the exact receipt left by an abandoned partial scheduled app-database prune")
          )
        <> command
          "list"
          ( info
              (AppDatabaseList <$> namespaceOpt <**> helper)
              (progDesc "List accepted app databases with their servers")
          )
    )
  where
    planOpts =
      AppDatabasePlanOpts
        <$> strOption (long "config" <> metavar "FILE" <> help "Config-as-program that calls emitAppDatabases")
        <*> optional (strOption (long "recovery-backup" <> metavar "ID" <> help "Recovery backup named in the review (default: each app database's scheduled backup)"))
        <*> optional (strOption (long "recovery-key-version" <> metavar "VERSION" <> help "Recovery key version of the credentials (default v1)"))
        <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save the review instead of printing its operations"))
    nameOpts savePlanHelp =
      AppDatabaseNameOpts
        <$> strArgument (metavar "NAME" <> help "App database name")
        <*> namespaceOpt
        <*> optional (strOption (long "scope-key" <> metavar "KEY" <> help "Pinned logical key used at creation"))
        <*> strOption (long "save-plan" <> metavar "DIR" <> help savePlanHelp)
    namespaceOpt = optional (strOption (long "namespace" <> short 'n' <> metavar "NS" <> help "Namespace (default personal)"))
    bucketOpt = optional (strOption (long "bucket" <> metavar "BUCKET" <> help "Backup bucket (default: the context's)"))
