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
  , strArgument
  , strOption
  , subparser
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
