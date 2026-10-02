-- | Parser / Site. Executable-private CLI boundary.
module Nagare.Cli.Parser.Site
  ( siteCmd
  )
where

import Nagare.Cli.Options
  ( Command (..)
  , SiteCommonOpts (..)
  , SiteDeployOpts (..)
  , SitePreviewDeleteOpts (..)
  , SiteRollbackOpts (..)
  )
import Nagare.Cli.Parser.Common
  ( baseDomainOpt
  , defaultConfigFile
  , dryRunOpt
  , fileOpt
  , ghcEnvOpt
  , tagOpt
  )
import Nagare.Dsl.Prelude
import Options.Applicative
  ( Alternative (many)
  , Parser
  , ParserInfo
  , command
  , fullDesc
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

siteDeployOptsParser :: FilePath -> Parser SiteDeployOpts
siteDeployOptsParser defaultFile =
  SiteDeployOpts
    <$> fileOpt defaultFile
    <*> tagOpt
    <*> baseDomainOpt
    <*> strOption
      ( long "project-dir"
          <> short 'C'
          <> metavar "DIR"
          <> value "."
          <> showDefault
          <> help "Project root: where the build runs and the output directory is resolved"
      )
    <*> ghcEnvOpt
    <*> dryRunOpt
    <*> switch
      ( long "skip-build"
          <> help "Do not run the build command; package the existing output directory as-is"
      )
    <*> optional
      ( strOption
          ( long "source"
              <> metavar "REF"
              <> help "Provenance to record with the release (e.g. a git SHA or branch)"
          )
      )
    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save reviewed site deployment"))
    <*> optional (strOption (long "image-resource" <> metavar "RESOURCE-ID" <> help "Accepted prepublished OCI image for reviewed site deploy or preview"))
    <*> optional (strOption (long "cdn-backend-resource" <> metavar "RESOURCE-ID" <> help "Accepted platform Pulumi BackendService for reviewed Google CDN DNS"))
    <*> many (strOption (long "volume-recovery" <> metavar "VOLUME=BACKUP:KEY:VERSION" <> help "Retained server-site PVC recovery for reviewed deploy or preview"))
    <*> many (strOption (long "env-secret-resource" <> metavar "RESOURCE-ID" <> help "Accepted runtime Secret dependency for reviewed server sites"))
    <*> many (strOption (long "tls-secret-resource" <> metavar "RESOURCE-ID" <> help "Accepted supplied-TLS Secret dependency for reviewed site domains"))
    <*> many (strOption (long "preview-env-resource" <> metavar "RESOURCE-ID" <> help "Accepted Runtime/Preview environment store for reviewed static preview"))
    <*> optional (strOption (long "preview-adoption-input" <> metavar "FILE" <> help "Exact-incarnation adoption proposal for an existing direct preview"))
    <*> optional (strOption (long "legacy-release-import" <> metavar "FILE" <> help "Legacy site release ConfigMap JSON for exact adoption"))
    <*> optional (strOption (long "release-adoption-input" <> metavar "FILE" <> help "Versioned exact-incarnation adoption proposal"))

siteCommonOptsParser :: FilePath -> Parser SiteCommonOpts
siteCommonOptsParser defaultFile =
  SiteCommonOpts <$> fileOpt defaultFile <*> baseDomainOpt <*> ghcEnvOpt

siteRollbackOptsParser :: FilePath -> Parser SiteRollbackOpts
siteRollbackOptsParser defaultFile =
  SiteRollbackOpts
    <$> siteCommonOptsParser defaultFile
    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Required saved review for site rollback"))
    <*> optional (strOption (long "image-resource" <> metavar "RESOURCE-ID" <> help "Accepted OCI image for the selected release"))
    <*> optional (strOption (long "cdn-backend-resource" <> metavar "RESOURCE-ID" <> help "Accepted platform Pulumi BackendService for reviewed Google CDN DNS"))
    <*> many (strOption (long "volume-recovery" <> metavar "VOLUME=BACKUP:KEY:VERSION" <> help "Retained server-site PVC recovery"))
    <*> many (strOption (long "env-secret-resource" <> metavar "RESOURCE-ID" <> help "Accepted runtime Secret dependency"))
    <*> many (strOption (long "tls-secret-resource" <> metavar "RESOURCE-ID" <> help "Accepted supplied-TLS Secret dependency"))

sitePreviewDeleteOptsParser :: FilePath -> Parser SitePreviewDeleteOpts
sitePreviewDeleteOptsParser defaultFile =
  SitePreviewDeleteOpts
    <$> siteCommonOptsParser defaultFile
    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Required saved review for preview retirement; collect retained members separately"))

previewNameOpt :: Parser String
previewNameOpt =
  strOption
    ( long "name"
        <> short 'n'
        <> metavar "NAME"
        <> help "Preview name (branch or PR identifier)"
    )

siteCmd :: ParserInfo Command
siteCmd =
  info
    (siteSubparser <**> helper)
    (fullDesc <> progDesc "Static and full-stack site hosting")

siteSubparser :: Parser Command
siteSubparser =
  subparser
    ( command "deploy" siteDeployCmd
        <> command "releases" siteReleasesCmd
        <> command "rollback" siteRollbackCmd
        <> command "preview" sitePreviewCmd
    )

siteDeployCmd :: ParserInfo Command
siteDeployCmd =
  info
    (SiteDeploy <$> siteDeployOptsParser defaultConfigFile <**> helper)
    (fullDesc <> progDesc "Deploy or inspect a reviewed static or server site using an accepted image")

siteReleasesCmd :: ParserInfo Command
siteReleasesCmd =
  info
    (SiteReleases <$> siteCommonOptsParser defaultConfigFile <**> helper)
    (fullDesc <> progDesc "List recorded releases for the site")

siteRollbackCmd :: ParserInfo Command
siteRollbackCmd =
  info
    ( SiteRollback
        <$> siteRollbackOptsParser defaultConfigFile
        <*> strArgument (metavar "RELEASE_ID" <> help "Release id to roll back to")
          <**> helper
    )
    (fullDesc <> progDesc "Roll production back to a prior release")

sitePreviewCmd :: ParserInfo Command
sitePreviewCmd =
  info
    (previewSubparser <**> helper)
    (fullDesc <> progDesc "Branch / pull-request preview deployments")

previewSubparser :: Parser Command
previewSubparser =
  subparser
    ( command "deploy" previewDeployCmd
        <> command "list" previewListCmd
        <> command "delete" previewDeleteCmd
    )

previewDeployCmd :: ParserInfo Command
previewDeployCmd =
  info
    (SitePreviewDeploy <$> siteDeployOptsParser defaultConfigFile <*> previewNameOpt <**> helper)
    (fullDesc <> progDesc "Deploy a preview of the site under a derived name and domain")

previewListCmd :: ParserInfo Command
previewListCmd =
  info
    (SitePreviewList <$> siteCommonOptsParser defaultConfigFile <**> helper)
    (fullDesc <> progDesc "List the site's preview deployments")

previewDeleteCmd :: ParserInfo Command
previewDeleteCmd =
  info
    ( SitePreviewDelete
        <$> sitePreviewDeleteOptsParser defaultConfigFile
        <*> strArgument (metavar "NAME" <> help "Preview name to delete")
          <**> helper
    )
    (fullDesc <> progDesc "Delete a preview deployment")
