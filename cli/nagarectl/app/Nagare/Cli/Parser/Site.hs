-- | Parser / Site. Executable-private CLI boundary.
module Nagare.Cli.Parser.Site
  ( siteCmd
  )
where

import Nagare.Cli.Options
  ( Command (..)
  , SiteCommonOpts (..)
  , SiteDeployOpts (..)
  , SiteListOpts (..)
  , SitePackageOpts (..)
  , SitePreviewDeleteOpts (..)
  , SitePublishOpts (..)
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

siteProjectDirOpt :: Parser FilePath
siteProjectDirOpt =
  strOption
    ( long "project-dir"
        <> short 'C'
        <> metavar "DIR"
        <> value "."
        <> showDefault
        <> help "Project root: where the build runs and the output directory is resolved"
    )

sitePackageOptsParser :: FilePath -> Parser SitePackageOpts
sitePackageOptsParser defaultFile =
  SitePackageOpts
    <$> fileOpt defaultFile
    <*> siteProjectDirOpt
    <*> ghcEnvOpt
    <*> optional (strOption (long "output-dir" <> metavar "DIR" <> help "Package this directory instead of the configured output (relative to --project-dir)"))
    <*> switch (long "build" <> help "Run the configured frontend build command first; by default the existing output is packaged as-is")
    <*> optional (strOption (long "context-out" <> metavar "DIR" <> help "Write the Docker build context (Dockerfile, nginx.conf, site/) to this new directory"))
    <*> optional (strOption (long "archive" <> metavar "FILE" <> help "Build a Docker archive at this new path, for image-plan or app image publication"))
    <*> tagOpt
    <*> optional (strOption (long "platform" <> metavar "PLATFORM" <> help "Archive platform: linux/amd64 or linux/arm64 (default: the active context's platform)"))

sitePublishOptsParser :: FilePath -> Parser SitePublishOpts
sitePublishOptsParser defaultFile =
  SitePublishOpts
    <$> fileOpt defaultFile
    <*> siteProjectDirOpt
    <*> ghcEnvOpt
    <*> baseDomainOpt
    <*> optional (strOption (long "output-dir" <> metavar "DIR" <> help "Publish this directory instead of the configured output (relative to --project-dir)"))
    <*> switch (long "build" <> help "Run the configured frontend build command first; by default the existing output is published as-is")
    <*> tagOpt
    <*> optional (strOption (long "platform" <> metavar "PLATFORM" <> help "Image platform: linux/amd64 or linux/arm64 (default: the active context's platform)"))
    <*> optional (strOption (long "release-dir" <> metavar "DIR" <> help "Directory that keeps this release's archive, receipt and build log (default: under the context's state directory); with --resume, the release to resume"))
    <*> switch (long "new-release" <> help "Publish a new release even when the files and configuration match the serving release")
    <*> switch (long "verbose" <> help "Stream Docker output to the terminal instead of build.log")
    <*> switch (long "resume" <> help "Continue the newest unfinished release of this site in this context (or the one named by --release-dir)")
    <*> optional (strOption (long "cdn-backend-resource" <> metavar "RESOURCE-ID" <> help "Accepted platform Pulumi BackendService for reviewed Google CDN DNS"))
    <*> many (strOption (long "tls-secret-resource" <> metavar "RESOURCE-ID" <> help "Accepted supplied-TLS Secret dependency for reviewed site domains"))

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
        <> command "package" sitePackageCmd
        <> command "publish" sitePublishCmd
        <> command "releases" siteReleasesCmd
        <> command "list" siteListCmd
        <> command "rollback" siteRollbackCmd
        <> command "preview" sitePreviewCmd
    )

siteDeployCmd :: ParserInfo Command
siteDeployCmd =
  info
    (SiteDeploy <$> siteDeployOptsParser defaultConfigFile <**> helper)
    (fullDesc <> progDesc "Deploy or inspect a reviewed static or server site using an accepted image")

sitePackageCmd :: ParserInfo Command
sitePackageCmd =
  info
    (SitePackage <$> sitePackageOptsParser defaultConfigFile <**> helper)
    (fullDesc <> progDesc "Package a static site's output as a local build context or Docker archive; reads local files only")

sitePublishCmd :: ParserInfo Command
sitePublishCmd =
  info
    (SitePublish <$> sitePublishOptsParser defaultConfigFile <**> helper)
    (fullDesc <> progDesc "Package, publish the image and deploy a static site in one command; an unchanged site reports the serving release and builds nothing")

siteReleasesCmd :: ParserInfo Command
siteReleasesCmd =
  info
    (SiteReleases <$> siteCommonOptsParser defaultConfigFile <**> helper)
    (fullDesc <> progDesc "List recorded releases for the site")

siteListCmd :: ParserInfo Command
siteListCmd =
  info
    ( SiteList
        <$> ( SiteListOpts
                <$> optional (strOption (long "namespace" <> short 'n' <> metavar "NS" <> help "Only sites whose origin Service is in this namespace; all namespaces by default"))
                <*> switch (long "include-previews" <> help "Include site previews")
                <*> switch (long "json" <> help "Print the versioned site-list document")
                <*> optional (option auto (long "contract" <> metavar "VERSION" <> help "Print the site-list document of this contract version (1)"))
            )
          <**> helper
    )
    (fullDesc <> progDesc "List the recorded sites of the active context from its inventory store; no workload, DNS or certificate is inspected")

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
