-- | Parser / Operations. Executable-private CLI boundary.
module Nagare.Cli.Parser.Operations
  ( cdnCmd
  , cleanupCmd
  , doctorCmd
  , domainsCmd
  , serverCmd
  )
where

import Data.Text qualified as T
import Nagare.Cli.Options
  ( CdnCommand (..)
  , CdnDisableOpts (..)
  , CdnListOpts (..)
  , CdnPurgeOpts (..)
  , CdnStatusOpts (..)
  , Command (..)
  , DoctorOpts (..)
  , DomainsCommand (..)
  , DomainsListOpts (..)
  , ServerStatusOpts (..)
  )
import Nagare.Cli.Parser.Common
  ( baseDomainOpt
  , dryRunOpt
  , namespaceOpt
  )
import Nagare.Dsl.Prelude
import Nagare.Ops.Cleanup
  ( CleanupOpts (CleanupOpts)
  , defaultKeepReleases
  , defaultPreviewTtlDays
  )
import Options.Applicative
  ( Alternative (many)
  , Parser
  , ParserInfo
  , auto
  , command
  , fullDesc
  , help
  , helper
  , info
  , long
  , metavar
  , option
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

serverStatusOptsParser :: Parser ServerStatusOpts
serverStatusOptsParser =
  ServerStatusOpts
    <$> switch (long "skip-vm" <> help "Skip the IAP-SSH disk probe (no SSH setup needed)")

doctorOptsParser :: Parser DoctorOpts
doctorOptsParser =
  DoctorOpts
    <$> switch (long "skip-vm" <> help "Skip the IAP-SSH disk probe (no SSH setup needed)")

domainsListOptsParser :: Parser DomainsListOpts
domainsListOptsParser =
  DomainsListOpts
    <$> namespaceOpt
    <*> switch (long "all-namespaces" <> help "List domains across all namespaces")
    <*> baseDomainOpt
    <*> switch (long "json" <> help "Emit versioned JSON instead of the human table")

cdnHostArg :: Parser String
cdnHostArg = strArgument (metavar "HOST" <> help "CDN-fronted hostname (e.g. blog.example.com)")

cdnListOptsParser :: Parser CdnListOpts
cdnListOptsParser =
  CdnListOpts
    <$> namespaceOpt
    <*> switch (long "all-namespaces" <> help "List CDN-fronted hostnames across all namespaces")
    <*> baseDomainOpt

cdnStatusOptsParser :: Parser CdnStatusOpts
cdnStatusOptsParser =
  CdnStatusOpts <$> cdnHostArg <*> namespaceOpt <*> baseDomainOpt

cdnPurgeOptsParser :: Parser CdnPurgeOpts
cdnPurgeOptsParser =
  CdnPurgeOpts
    <$> cdnHostArg
    <*> many
      ( strOption
          (long "path" <> metavar "PATH" <> help "Purge only this path (repeatable; default: selected hostname only)")
      )
    <*> namespaceOpt
    <*> dryRunOpt
    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save a reviewed host-bounded purge"))
    <*> optional (strOption (long "purge-id" <> metavar "ID" <> help "Immutable purge request ID, required with --save-plan"))
    <*> switch (long "whole-zone" <> help "Review ALL cached content in the platform-owned zone; requires --save-plan and no --path")

cdnDisableOptsParser :: Parser CdnDisableOpts
cdnDisableOptsParser =
  CdnDisableOpts
    <$> cdnHostArg
    <*> namespaceOpt
    <*> dryRunOpt
    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save an exact reviewed DNS disable; apply with inventory apply"))

-- | Options for @cleanup@ (MasterPlan 8, EP-41). @--confirm@ defaults 'False', so
-- a plain run is the dry run; when none of @--images/--previews/--releases@ is
-- given, all three categories are acted on.
cleanupOptsParser :: Parser CleanupOpts
cleanupOptsParser =
  CleanupOpts
    <$> switch (long "images" <> help "Limit cleanup to the containerd image store")
    <*> switch (long "previews" <> help "Limit cleanup to stale static-site previews")
    <*> switch (long "releases" <> help "Limit cleanup to old release-history entries")
    <*> switch (long "confirm" <> help "REQUIRED to delete; without it cleanup is a dry run")
    <*> option
      auto
      (long "preview-ttl-days" <> value defaultPreviewTtlDays <> showDefault <> metavar "N" <> help "Previews older than N days are stale")
    <*> option
      auto
      (long "keep-releases" <> value defaultKeepReleases <> showDefault <> metavar "N" <> help "Keep the most recent N releases per log (current always kept)")
    <*> optional (T.pack <$> strOption (long "namespace" <> short 'n' <> metavar "NS" <> help "Namespace to scan for previews/releases"))
    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save exact accepted image, preview, or release-history cleanup for inventory apply"))
    <*> optional (T.pack <$> strOption (long "id" <> metavar "REQUEST_ID" <> help "Stable one-shot image cleanup request ID; reuse never prunes a later re-pull"))

doctorCmd :: ParserInfo Command
doctorCmd =
  info
    (Doctor <$> doctorOptsParser <**> helper)
    (fullDesc <> progDesc "Health-check the platform and print remediation hints (exit 1 on any FAIL)")

domainsCmd :: ParserInfo Command
domainsCmd =
  info
    (domainsSubparser <**> helper)
    (fullDesc <> progDesc "Inspect platform domains, DNS expectation, and certificate readiness")

domainsSubparser :: Parser Command
domainsSubparser =
  subparser
    ( command
        "list"
        ( info
            (Domains . DomainsList <$> domainsListOptsParser <**> helper)
            (progDesc "List the base domain and per-app DomainMappings with DNS and cert state")
        )
        <> command
          "check"
          ( info
              (Domains . DomainsCheck <$> domainsListOptsParser <**> helper)
              (progDesc "Check public DNS, route ownership/readiness, and certificate state")
          )
    )

cdnCmd :: ParserInfo Command
cdnCmd =
  info
    (cdnSubparser <**> helper)
    (fullDesc <> progDesc "Inspect and manage CDN-fronted hostnames (list, status, purge, disable)")

cdnSubparser :: Parser Command
cdnSubparser =
  subparser
    ( command
        "list"
        ( info
            (CdnCmd . CdnList <$> cdnListOptsParser <**> helper)
            (progDesc "List CDN-fronted sites/apps, provider, and edge status")
        )
        <> command
          "status"
          ( info
              (CdnCmd . CdnStatus <$> cdnStatusOptsParser <**> helper)
              (progDesc "Show one hostname's provider, DNS target, cache config, and readiness")
          )
        <> command
          "purge"
          ( info
              (CdnCmd . CdnPurge <$> cdnPurgeOptsParser <**> helper)
              (progDesc "Purge the edge cache for a hostname (optionally specific --path values)")
          )
        <> command
          "disable"
          ( info
              (CdnCmd . CdnDisable <$> cdnDisableOptsParser <**> helper)
              (progDesc "Revert a hostname's DNS back to the VM (un-proxy / delete the A record)")
          )
    )

cleanupCmd :: ParserInfo Command
cleanupCmd =
  info
    (Cleanup <$> cleanupOptsParser <**> helper)
    (fullDesc <> progDesc "Reclaim disk: prune unused images, stale previews, old releases (dry-run by default)")

serverCmd :: ParserInfo Command
serverCmd =
  info
    (serverSubparser <**> helper)
    (fullDesc <> progDesc "Server and platform inventory")

serverSubparser :: Parser Command
serverSubparser =
  subparser
    ( command
        "status"
        ( info
            (ServerStatus <$> serverStatusOptsParser <**> helper)
            (progDesc "One-screen platform health report")
        )
    )
