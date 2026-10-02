-- | Parser / Context. Executable-private CLI boundary.
module Nagare.Cli.Parser.Context
  ( contextCmd
  , initCmd
  )
where

import Nagare.Cli.Options
  ( Command (..)
  , ContextCommand (..)
  , ContextCreateOpts (..)
  )
import Nagare.Dsl.Prelude
import Nagare.Init (InitOpts (InitOpts))
import Options.Applicative
  ( Parser
  , ParserInfo
  , command
  , flag'
  , fullDesc
  , help
  , helper
  , info
  , long
  , metavar
  , optional
  , progDesc
  , strArgument
  , strOption
  , subparser
  , switch
  , (<**>)
  )

-- | Options for @init@ (MasterPlan 12, EP-63). Target flags are optional
-- so an absent flag prompts on a TTY (or errors non-interactively); the skip/force
-- flags exist for CI and partial recovery.
initOptsParser :: Parser InitOpts
initOptsParser =
  InitOpts
    <$> optional (strArgument (metavar "NAME" <> help "Context name to create and make current (omit to write ./nagare.target.env)"))
    <*> optional (strOption (long "project" <> metavar "PROJECT_ID" <> help "GCP project id (prompted if absent on a TTY)"))
    <*> optional (strOption (long "region" <> metavar "REGION" <> help "Compute region (default us-west1)"))
    <*> optional (strOption (long "zone" <> metavar "ZONE" <> help "Compute zone (default us-west1-a)"))
    <*> optional (strOption (long "base-domain" <> metavar "DOMAIN" <> help "Apps base domain (default apps.example.com)"))
    <*> optional (flag' "1" (long "enable-external-tls" <> help "Enable reviewed cloud-domain TLS after DNS delegation") <|> flag' "0" (long "disable-external-tls" <> help "Disable cloud-domain TLS in the desired context profile"))
    <*> optional (strOption (long "machine-type" <> metavar "TYPE" <> help "GCE machine type (default e2-standard-2)"))
    <*> optional (strOption (long "boot-disk-type" <> metavar "TYPE" <> help "Boot disk type (default pd-balanced; changing a live VM replaces it)"))
    <*> optional (strOption (long "boot-disk-size-gb" <> metavar "GB" <> help "Boot disk size in GB (default 100; changing a live VM replaces it)"))
    <*> optional (strOption (long "data-disk-size-gb" <> metavar "GB" <> help "Data disk size in GB (default 100)"))
    <*> optional (flag' "1" (long "enable-nix-cache" <> help "Enable the cloud-only Attic binary cache") <|> flag' "0" (long "disable-nix-cache" <> help "Disable Attic without deleting retained resources"))
    <*> optional (strOption (long "nix-cache-bucket" <> metavar "BUCKET" <> help "Attic GCS bucket (default <project>-nagare-nix-cache)"))
    <*> optional (strOption (long "pulumi-backend" <> metavar "BACKEND" <> help "local | gcs Pulumi state backend (default local; gcs is cloud-only)"))
    <*> optional (strOption (long "pulumi-backend-url" <> metavar "GS_URL" <> help "Explicit gs://bucket/path backend URL (default gs://<project>-nagare-pulumi-state/nagare/<context>)"))
    <*> optional (strOption (long "inventory-store" <> metavar "STORE" <> help "local | gcs resource inventory history store (default local)"))
    <*> optional (strOption (long "inventory-store-url" <> metavar "GS_URL" <> help "Explicit gs://bucket/prefix inventory history URL"))
    <*> optional (strOption (long "pulumi-backend-member" <> metavar "PRINCIPAL" <> help "Grant this principal objectAdmin on the state bucket during bootstrap (not persisted)"))
    <*> optional (strOption (long "acme-email" <> metavar "ADDRESS" <> help "Let's Encrypt contact address for this context (REQUIRED; prompted if absent on a TTY)"))
    <*> optional (strOption (long "acme-directory" <> metavar "ENDPOINT" <> help "production | staging | https:// ACME directory URL (default production)"))
    <*> switch (long "force" <> help "Overwrite an existing nagare.target.env")
    <*> switch (long "skip-preflight" <> help "Skip the gcloud auth + operator-IAM checks")
    <*> switch (long "skip-enable" <> help "Skip running scripts/enable-apis.sh")
    <*> switch (long "skip-seed" <> help "Skip seeding the Pulumi stack config")
    <*> switch (long "dry-run" <> help "Show what would be written/enabled/seeded without doing it")

contextNameArg :: Parser String
contextNameArg = strArgument (metavar "NAME" <> help "Context name")

contextCreateOptsParser :: Parser ContextCreateOpts
contextCreateOptsParser =
  ContextCreateOpts
    <$> optional (strOption (long "project" <> metavar "PROJECT_ID" <> help "GCP project id"))
    <*> optional (strOption (long "region" <> metavar "REGION" <> help "Compute region (default us-west1)"))
    <*> optional (strOption (long "zone" <> metavar "ZONE" <> help "Compute zone (default us-west1-a)"))
    <*> optional (strOption (long "base-domain" <> metavar "DOMAIN" <> help "Apps base domain (default apps.example.com)"))
    <*> optional (flag' "1" (long "enable-external-tls" <> help "Enable reviewed cloud-domain TLS after DNS delegation") <|> flag' "0" (long "disable-external-tls" <> help "Disable cloud-domain TLS in the desired context profile"))
    <*> optional (strOption (long "machine-type" <> metavar "TYPE" <> help "GCE machine type (default e2-standard-2)"))
    <*> optional (strOption (long "boot-disk-type" <> metavar "TYPE" <> help "Boot disk type (default pd-balanced; changing a live VM replaces it)"))
    <*> optional (strOption (long "boot-disk-size-gb" <> metavar "GB" <> help "Boot disk size in GB (default 100; changing a live VM replaces it)"))
    <*> optional (strOption (long "data-disk-size-gb" <> metavar "GB" <> help "Data disk size in GB (default 100)"))
    <*> optional (strOption (long "registry-host" <> metavar "HOST" <> help "Artifact Registry host (default <region>-docker.pkg.dev)"))
    <*> optional (strOption (long "artifact-registry-id" <> metavar "ID" <> help "Artifact Registry repo id (default nagare)"))
    <*> optional (strOption (long "image-bucket" <> metavar "BUCKET" <> help "Image bucket (default <project>-nagare-images)"))
    <*> optional (strOption (long "backup-bucket" <> metavar "BUCKET" <> help "Backup bucket (default <project>-nagare-backups)"))
    <*> optional (flag' "1" (long "enable-nix-cache" <> help "Enable the cloud-only Attic binary cache") <|> flag' "0" (long "disable-nix-cache" <> help "Disable Attic without deleting retained resources"))
    <*> optional (strOption (long "nix-cache-bucket" <> metavar "BUCKET" <> help "Attic GCS bucket (default <project>-nagare-nix-cache)"))
    <*> optional (strOption (long "instance-name" <> metavar "NAME" <> help "VM instance name (default nagare-01)"))
    <*> optional (strOption (long "service-account-id" <> metavar "ID" <> help "Node service account id (default nagare-node)"))
    <*> optional (strOption (long "target-platform" <> metavar "PLATFORM" <> help "Docker build platform (default linux/amd64)"))
    <*> optional (strOption (long "mode" <> metavar "MODE" <> help "cloud | local (default cloud)"))
    <*> optional (strOption (long "local-object-store" <> metavar "URL" <> help "Local S3 endpoint/bucket (local mode only)"))
    <*> optional (strOption (long "pulumi-backend" <> metavar "BACKEND" <> help "local | gcs Pulumi state backend (default local; gcs is cloud-only)"))
    <*> optional (strOption (long "pulumi-backend-url" <> metavar "GS_URL" <> help "Explicit gs://bucket/path backend URL (default gs://<project>-nagare-pulumi-state/nagare/<context>)"))
    <*> optional (strOption (long "inventory-store" <> metavar "STORE" <> help "local | gcs resource inventory history store (default local)"))
    <*> optional (strOption (long "inventory-store-url" <> metavar "GS_URL" <> help "Explicit gs://bucket/prefix inventory history URL"))
    <*> optional (strOption (long "pulumi-backend-member" <> metavar "PRINCIPAL" <> help "Grant this principal objectAdmin on the state bucket during --use bootstrap (not persisted)"))
    <*> optional (strOption (long "acme-email" <> metavar "ADDRESS" <> help "Let's Encrypt contact address (no default; required to render the cluster issuer)"))
    <*> optional (strOption (long "acme-directory" <> metavar "ENDPOINT" <> help "production | staging | https:// ACME directory URL (default production)"))
    <*> switch (long "force" <> help "Update an existing context: passed flags change, every other stored field is kept")
    <*> switch (long "use" <> help "Also set this context as the current context")

contextCmd :: ParserInfo Command
contextCmd =
  info
    (ContextCmdGroup <$> contextSubparser <**> helper)
    (fullDesc <> progDesc "Manage named target contexts")

contextSubparser :: Parser ContextCommand
contextSubparser =
  subparser
    ( command "list" (info (pure ContextList <**> helper) (progDesc "List all contexts; mark the current one"))
        <> command "current" (info (pure ContextCurrent <**> helper) (progDesc "Print the current context name"))
        <> command "use" (info (ContextUse <$> contextNameArg <**> helper) (progDesc "Set the current context"))
        <> command "show" (info (ContextShow <$> optional contextNameArg <**> helper) (progDesc "Print a context bundle (default: active context)"))
        <> command "create" (info (ContextCreate <$> contextNameArg <*> contextCreateOptsParser <**> helper) (progDesc "Write a new context into the store"))
        <> command "delete" (info (ContextDelete <$> contextNameArg <*> switch (long "yes" <> help "Confirm deletion") <**> helper) (progDesc "Delete a context from the store"))
        <> command "guard" (info (ContextGuard <$> switch (long "json" <> help "Emit the compared values as JSON") <**> helper) (progDesc "Refuse unless the Pulumi stack, the environment and gcloud all agree with the active context's project"))
        <> command "env" (info (pure ContextEnv <**> helper) (progDesc "Print the active context's shell environment as export lines, safe to eval"))
    )

initCmd :: ParserInfo Command
initCmd =
  info
    (Init <$> initOptsParser <**> helper)
    (fullDesc <> progDesc "Onboard a fresh GCP project: preflight, write the target profile, enable APIs, seed Pulumi config")
