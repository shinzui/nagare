-- | Parser / Inventory. Executable-private CLI boundary.
module Nagare.Cli.Parser.Inventory
  ( inventoryCmd
  )
where

import Data.List.NonEmpty qualified as NE
import Nagare.Cli.Options (Command (..))
import Nagare.Cli.Parser.Data (inventoryResourceOption)
import Nagare.Dsl.Prelude
import Options.Applicative
  ( Alternative (many)
  , ParserInfo
  , auto
  , command
  , flag'
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
  , value
  , (<**>)
  )

inventoryCmd :: ParserInfo Command
inventoryCmd =
  info
    ( subparser
        ( command
            "compile"
            (info (InventoryCompile <$> strOption (long "input" <> metavar "FILE") <*> strOption (long "out" <> metavar "DIRECTORY") <*> switch (long "json") <**> helper) (progDesc "Compile complete resource scopes without contacting providers"))
            <> command
              "plan"
              ( info
                  ( InventoryPlan
                      <$> strOption (long "inventory" <> metavar "DIRECTORY")
                      <*> many
                        ( strOption
                            ( long "retain-resource"
                                <> metavar "RESOURCE_ID"
                                <> help "Retain one removed member without deleting its live provider object; repeat as needed"
                            )
                        )
                      <*> strOption (long "out" <> metavar "DIRECTORY") <**> helper
                  )
                  (progDesc "Prepare and publish a digest-bound inventory review")
              )
            <> command
              "adopt"
              (info (InventoryAdopt <$> strOption (long "input" <> metavar "FILE") <*> strOption (long "out" <> metavar "DIRECTORY") <**> helper) (progDesc "Review exact adoption or known-owner transfer incarnations"))
            <> command
              "migrate"
              (info (InventoryMigrate <$> strOption (long "input" <> metavar "FILE") <*> strOption (long "out" <> metavar "DIRECTORY") <**> helper) (progDesc "Review exact source and destination migration incarnations"))
            <> command
              "retire"
              (info (InventoryRetire <$> ((NE.:|) <$> strOption (long "scope" <> metavar "KIND:NAME" <> help "Scope to retire; repeat to retire mutually dependent scopes together") <*> many (strOption (long "scope" <> metavar "KIND:NAME" <> internal))) <*> strOption (long "out" <> metavar "DIRECTORY") <**> helper) (progDesc "Review retention of accepted scopes without deleting their resources"))
            <> command
              "gc"
              (info (InventoryGc <$> (flag' () (long "plan" <> help "Write a read-only collection assessment") *> strOption (long "out" <> metavar "DIRECTORY")) <**> helper) (progDesc "Screen retained resources for later collection review"))
            <> command
              "collect"
              (info (InventoryCollect <$> ((NE.:|) <$> inventoryResourceOption <*> many (strOption (long "resource" <> metavar "RESOURCE_ID" <> internal))) <*> strOption (long "out" <> metavar "DIRECTORY") <*> switch (long "controller-descendants" <> help "Review Background collection of a Knative Service or DomainMapping and its exclusive controller descendants") <**> helper) (progDesc "Review exact collection of retained stateless Kubernetes or workload DNS resources"))
            <> command
              "apply"
              (info (InventoryApply <$> strArgument (metavar "REVIEW_DIRECTORY") <*> switch (long "yes") <**> helper) (progDesc "Apply an issued inventory review"))
            <> command
              "resume"
              ( info
                  ( InventoryResume
                      <$> strArgument (metavar "TRANSACTION")
                      <*> switch (long "yes")
                      <*> switch (long "take-over") <**> helper
                  )
                  (progDesc "Resume an unresolved inventory transaction")
              )
            <> command
              "registry-recovery-plan"
              ( info
                  ( InventoryRegistryRecoveryPlan
                      <$> strArgument (metavar "TRANSACTION")
                      <*> strOption (long "operation" <> metavar "OPERATION")
                      <*> strOption (long "out" <> metavar "FILE") <**> helper
                  )
                  (progDesc "Save bounded credential recovery for an existing bootstrap Deployment")
              )
            <> command
              "recover"
              ( info
                  ( InventoryRecover
                      <$> strArgument (metavar "TRANSACTION")
                      <*> strOption (long "operation" <> metavar "OPERATION")
                      <*> strOption (long "decision" <> metavar "FILE")
                      <*> switch (long "take-over") <**> helper
                  )
                  (progDesc "Recover one uncertain reviewed operation using adapter and native proof")
              )
            <> command
              "export"
              (info (InventoryExport <$> strOption (long "out" <> metavar "DIRECTORY") <**> helper) (progDesc "Export the complete private inventory store under lock"))
            <> command
              "restore"
              ( info
                  ( InventoryRestore
                      <$> strOption (long "from" <> metavar "DIRECTORY")
                      <*> switch (long "yes") <**> helper
                  )
                  (progDesc "Restore a verified private export into an empty local context store")
              )
            <> command
              "status"
              (info (InventoryStatus <$> switch (long "json") <**> helper) (progDesc "Report accepted resource ownership and observed drift without mutation"))
            <> command
              "guard-legacy"
              ( info
                  (InventoryLegacyGuard <$> strArgument (metavar "OPERATION") <**> helper)
                  (progDesc "Refuse an unreviewed compatibility transport after inventory admission")
              )
            <> command
              "explain"
              (info (InventoryExplain <$> strArgument (metavar "RESOURCE_ID") <*> switch (long "json") <**> helper) (progDesc "Explain one accepted resource and its current observation"))
            <> command
              "store"
              ( info
                  ( subparser
                      ( command
                          "status"
                          ( info
                              (InventoryStoreStatus <$> switch (long "json") <**> helper)
                              (progDesc "Read the selected inventory history store and executor claim")
                          )
                          <> command
                            "materialize-native"
                            ( info
                                ( InventoryStoreMaterializeNative
                                    <$> optional (strOption (long "after" <> metavar "REVIEW_SHA256"))
                                    <*> option auto (long "limit" <> value 20 <> metavar "COUNT") <**> helper
                                )
                                (progDesc "Extract observation bytes from a bounded batch of historical reviews; resume with --after")
                            )
                          <> command
                            "migrate"
                            ( info
                                ( InventoryStoreMigrate
                                    <$> strOption (long "to" <> metavar "gcs|local")
                                    <*> switch (long "dry-run")
                                    <*> switch (long "yes") <**> helper
                                )
                                (progDesc "Copy inventory history and tombstone the source store")
                            )
                      )
                      <**> helper
                  )
                  (progDesc "Inspect the selected inventory history store")
              )
        )
        <**> helper
    )
    (progDesc "Typed resource inventory")
