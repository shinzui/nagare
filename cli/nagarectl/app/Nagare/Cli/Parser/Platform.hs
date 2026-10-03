-- | Parser / Platform. Executable-private CLI boundary.
module Nagare.Cli.Parser.Platform
  ( clusterCmd
  , hostCmd
  , infraCmd
  , kubeconfigCmd
  , platformCmd
  , releaseCmd
  , versionCmd
  )
where

import Nagare.Cli.Options
  ( ClusterCommand (..)
  , ClusterGuardOpts (..)
  , Command (..)
  , HostCommand (..)
  , HostInitOpts (..)
  , HostPlaceAgeKeyOpts (..)
  , InfraApplyOpts (..)
  , InfraCommand (..)
  , InfraPreviewOpts (..)
  , KubeconfigCommand (..)
  , KubeconfigFetchOpts (..)
  , UpgradeOpts (..)
  , VersionOpts (..)
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
  , showDefault
  , strArgument
  , strOption
  , subparser
  , switch
  , value
  , (<**>)
  )

versionCmd :: ParserInfo Command
versionCmd =
  info
    ( Version
        <$> ( VersionOpts
                <$> switch (long "json" <> help "Print machine-readable version metadata")
                <*> switch (long "tools" <> help "Report the executable paths selected from PATH")
            )
          <**> helper
    )
    (progDesc "Print the nagarectl version")

releaseCmd :: ParserInfo Command
releaseCmd =
  info
    ( subparser
        ( command
            "publish"
            ( info
                ( ReleasePublish
                    <$> strOption (long "repo" <> metavar "OWNER/REPO")
                    <*> strOption (long "version" <> metavar "VERSION")
                    <*> strOption (long "assets" <> metavar "DIRECTORY")
                    <*> switch (long "yes" <> help "Publish the exact reviewed release candidate")
                      <**> helper
                )
                (progDesc "Review and recover publication of exact release attachments")
            )
            <> command
              "cleanup-starter"
              ( info
                  ( ReleaseCleanupStarter
                      <$> strOption (long "repo" <> metavar "OWNER/REPO")
                      <*> strOption (long "version" <> metavar "VERSION")
                      <*> strOption (long "assets" <> metavar "DIRECTORY")
                      <*> option auto (long "release-id" <> metavar "ID")
                      <*> option auto (long "asset-id" <> metavar "ID")
                      <*> strOption (long "asset-name" <> metavar "NAME")
                      <*> switch (long "yes" <> help "Delete only the reviewed failed draft asset ID")
                        <**> helper
                  )
                  (progDesc "Review exact cleanup of a failed upload placeholder")
              )
        )
    )
    (progDesc "Global immutable release publication")

platformCmd :: ParserInfo Command
platformCmd =
  info
    ( subparser
        ( command
            "root"
            ( info
                (PlatformRoot <$> switch (long "json" <> help "Print machine-readable platform path metadata") <**> helper)
                (progDesc "Resolve, validate, and materialize the active platform payload")
            )
            <> command
              "status"
              ( info
                  (PlatformStatusCmd <$> switch (long "json" <> help "Print machine-readable release identities") <**> helper)
                  (progDesc "Compare CLI, payload, context, host, and cluster release identities")
              )
            <> command
              "guard"
              (info (pure PlatformGuard <**> helper) (progDesc "Refuse unsafe platform mutation when release versions are incompatible"))
            <> command
              "stamp"
              (info (pure PlatformStamp <**> helper) (progDesc "Retired: use a reviewed platform bootstrap apply to record the payload identity"))
            <> command
              "bootstrap"
              (info (bootstrapCommandParser <**> helper) (progDesc "Plan or apply reviewed cluster bootstrap resources"))
            <> command
              "adopt"
              ( info
                  (PlatformAdopt <$> strOption (long "version" <> metavar "VERSION" <> help "Release identity to assign to a legacy context") <*> switch (long "yes" <> help "Confirm the displayed observations") <*> switch (long "json" <> help "Print machine-readable observations and result") <**> helper)
                  (progDesc "Explicitly adopt the observed payload release for a legacy context")
              )
            <> command
              "repin"
              ( info
                  (PlatformRepin <$> strOption (long "version" <> metavar "VERSION" <> help "Current payload release to assign before first deployment") <*> switch (long "yes" <> help "Confirm the displayed absence evidence") <**> helper)
                  (progDesc "Re-pin a versioned context whose GCE host has never been deployed")
              )
            <> command
              "upgrade"
              (info (upgradeCommandParser <**> helper) (progDesc "Plan, apply, resume, or inspect a per-context platform upgrade"))
        )
        <**> helper
    )
    (fullDesc <> progDesc "Inspect packaged platform resources")

bootstrapCommandParser :: Parser Command
bootstrapCommandParser =
  subparser
    ( command
        "plan"
        ( info
            (PlatformBootstrapPlan <$> strOption (long "out" <> metavar "DIRECTORY") <**> helper)
            (progDesc "Compile and publish a reviewed bootstrap plan")
        )
        <> command
          "apply"
          ( info
              ( PlatformBootstrapApply
                  <$> strArgument (metavar "REVIEW_DIRECTORY")
                  <*> switch (long "yes") <**> helper
              )
              (progDesc "Apply a published bootstrap review")
          )
    )

upgradeCommandParser :: Parser Command
upgradeCommandParser =
  subparser
    ( command
        "status"
        ( info
            (PlatformUpgradeStatus <$> optional (strArgument (metavar "TRANSACTION_ID")) <*> switch (long "json" <> help "Print transaction JSON") <**> helper)
            (progDesc "Show the selected or latest upgrade transaction")
        )
        <> command
          "rollback"
          ( info
              (PlatformUpgradeRollback <$> strArgument (metavar "TRANSACTION_ID") <*> switch (long "yes" <> help "Confirm the supported release rollback") <*> switch (long "json" <> help "Print transaction JSON") <**> helper)
              (progDesc "Create and apply a reverse transaction when release metadata explicitly permits it")
          )
        <> command
          "recover-pulumi"
          ( info
              (PlatformUpgradeRecoverPulumi <$> strArgument (metavar "TRANSACTION_ID") <*> strOption (long "outcome" <> metavar "applied|retry" <> help "Record the inspected Pulumi outcome") <*> switch (long "yes" <> help "Confirm the audited recovery decision") <**> helper)
              (progDesc "Resolve an ambiguous or pre-receipt Pulumi apply outcome")
          )
    )
    <|> (PlatformUpgrade <$> upgradeOptsParser)

upgradeOptsParser :: Parser UpgradeOpts
upgradeOptsParser =
  UpgradeOpts
    <$> optional (strOption (long "to" <> metavar "VERSION" <> help "Target semantic platform version"))
    <*> optional (strOption (long "payload-root" <> metavar "PATH" <> help "Use this already-resolved payload (tests/offline recovery)"))
    <*> switch (long "apply" <> help "Apply a previously successful plan; requires --resume and --yes")
    <*> optional (strOption (long "resume" <> metavar "TRANSACTION_ID" <> help "Resume this persisted transaction"))
    <*> switch (long "dry-run" <> help "Plan only (the default; accepted for explicit automation)")
    <*> switch (long "yes" <> help "Confirm application of the planned infrastructure and cluster changes")
    <*> switch (long "json" <> help "Print the transaction as JSON")

hostCmd :: ParserInfo Command
hostCmd =
  info
    (Host <$> hostSubparser <**> helper)
    (fullDesc <> progDesc "Manage context-owned NixOS host configuration")

hostSubparser :: Parser HostCommand
hostSubparser =
  subparser
    ( command "init" (info (HostInit <$> hostInitOptsParser <**> helper) (progDesc "Generate and validate a context-owned host flake"))
        <> command "image" (info (HostImagePlan <$> strOption (long "save-plan" <> metavar "DIR" <> help "Review the next image build/publication stage; apply with inventory apply") <**> helper) (progDesc "Review immutable host image build and publication"))
        <> command "start" (info (HostStart <$> powerId <*> powerReview <**> helper) (progDesc "Review starting the accepted VM without changing its disks"))
        <> command "stop" (info (HostStop <$> powerId <*> powerReview <**> helper) (progDesc "Review stopping the accepted VM while retaining its disks"))
        <> command "show" (info (HostShow <$> optional hostContextOption <**> helper) (progDesc "Print the generated operator module"))
        <> command "path" (info (HostPath <$> optional hostContextOption <**> helper) (progDesc "Print the generated host-flake path"))
        <> command
          "name"
          ( info
              (HostName <$> optional hostContextOption <*> switch (long "json" <> help "Print machine-readable host identity") <**> helper)
              (progDesc "Print the validated generated NixOS and tailnet host name")
          )
        <> command
          "place-age-key"
          ( info
              (HostPlaceAgeKey <$> hostPlaceAgeKeyOptsParser <**> helper)
              (progDesc "Stream an age private key to the selected host over project-confined IAP")
          )
        <> command
          "apply"
          ( info
              ( HostApply
                  <$> strArgument (metavar "DIR")
                  <*> switch (long "yes" <> help "Apply the exact saved host review") <**> helper
              )
              (progDesc "Apply a saved host transition through the inventory executor")
          )
        <> command
          "plan"
          ( info
              ( HostPlan
                  <$> strOption (long "save-plan" <> metavar "DIR" <> help "Save a reviewed same-payload host transition")
                  <*> optional (strOption (long "age-key-file" <> metavar "PATH" <> help "Bind an operator-held age key to this review"))
                  <*> switch (long "replace-age-key" <> help "Review replacement of the exact observed installed key")
                    <**> helper
              )
              (progDesc "Review host configuration and credential reconciliation")
          )
    )
  where
    powerId = strOption (long "operation-id" <> metavar "ID" <> help "Unique immutable ID for this power transition")
    powerReview = strOption (long "save-plan" <> metavar "DIR" <> help "Save the power review; apply it with inventory apply")

hostContextOption :: Parser String
hostContextOption = strOption (long "context" <> metavar "NAME" <> help "Host context (defaults to the global or active context)")

hostInitOptsParser :: Parser HostInitOpts
hostInitOptsParser =
  HostInitOpts
    <$> optional hostContextOption
    <*> many (strOption (long "ssh-public-key-file" <> metavar "PATH" <> help "Operator SSH public-key file; repeat for multiple keys"))
    <*> optional (strOption (long "sops-file" <> metavar "PATH" <> help "Existing sops-encrypted host secrets YAML; required for a new host"))
    <*> strOption (long "age-key-file" <> metavar "HOST_PATH" <> value "/var/lib/sops-nix/age-key.txt" <> showDefault <> help "Private age-key path on the host (the key is never read or copied)")
    <*> optional (strOption (long "host-name" <> metavar "NAME" <> help "NixOS and tailnet hostname (defaults to <context>-nagare)"))
    <*> optional (strOption (long "instance-name" <> metavar "NAME" <> help "Cloud instance identity (defaults to the context instance name)"))
    <*> optional (strOption (long "registry-host" <> metavar "HOST" <> help "Artifact Registry host (defaults to the context registry)"))
    <*> strOption (long "deploy-user" <> metavar "USER" <> value "deploy" <> showDefault <> help "Operator account created on the host")
    <*> switch (long "force" <> help "Atomically replace changed generated scaffolding")
    <*> switch (long "dry-run" <> help "Validate inputs and print generated configuration without writing")

hostPlaceAgeKeyOptsParser :: Parser HostPlaceAgeKeyOpts
hostPlaceAgeKeyOptsParser =
  HostPlaceAgeKeyOpts
    <$> optional hostContextOption
    <*> strOption (long "key-file" <> metavar "PATH" <> help "Operator-held age private-key file to stream over SSH stdin")
    <*> switch (long "force" <> help "Replace a different installed key (interruption-sensitive; preserve both keys first)")
    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save a reviewed host credential transition; required after inventory admission"))

kubeconfigCmd :: ParserInfo Command
kubeconfigCmd =
  info
    (Kubeconfig <$> kubeconfigSubparser <**> helper)
    (fullDesc <> progDesc "Fetch and manage context-owned Kubernetes credentials")

kubeconfigSubparser :: Parser KubeconfigCommand
kubeconfigSubparser =
  subparser
    ( command
        "fetch"
        ( info
            ( KubeconfigFetch
                <$> ( KubeconfigFetchOpts
                        <$> optional (strOption (long "context" <> metavar "NAME" <> help "Context to fetch (defaults to the global or active context)"))
                        <*> optional (strOption (long "output" <> metavar "FILE" <> help "Destination (default: the context kubeconfig store)"))
                    )
                  <**> helper
            )
            (progDesc "Fetch k3s credentials over project-confined IAP and install them atomically")
        )
        <> command
          "recover"
          ( info
              (pure KubeconfigRecover <**> helper)
              (progDesc "Materialize accepted shared-history credentials in this context root")
          )
    )

clusterCmd :: ParserInfo Command
clusterCmd =
  info
    (Cluster <$> clusterSubparser <**> helper)
    (fullDesc <> progDesc "Inspect and guard the selected Kubernetes cluster")

clusterSubparser :: Parser ClusterCommand
clusterSubparser =
  subparser
    ( command
        "guard"
        ( info
            ( ClusterGuard
                <$> ( ClusterGuardOpts
                        <$> optional (strOption (long "context" <> metavar "NAME" <> help "Nagare context expected to own the active Kubernetes cluster"))
                        <*> switch (long "json" <> help "Emit the expected and observed identities as JSON")
                    )
                  <**> helper
            )
            (progDesc "Refuse unless the active kube context has the selected context's sole server node")
        )
        <> command
          "certificate-policy"
          ( info
              (pure ClusterCertificatePolicy <**> helper)
              (progDesc "Refuse when public ACME certificates contain internal names or unlabeled wildcards")
          )
    )

infraCmd :: ParserInfo Command
infraCmd =
  info
    ( subparser
        ( command
            "guard"
            ( info
                (Infra . InfraGuard <$> switch (long "allow-replacement" <> help "Allow a deliberate GCE instance replacement for this run") <**> helper)
                (progDesc "Preview and refuse a plan that replaces the GCE instance")
            )
            <> command
              "preview"
              ( info
                  ( Infra
                      . InfraPreview
                      <$> ( InfraPreviewOpts
                              <$> strOption (long "save-plan" <> metavar "DIR" <> help "Write one private context-bound reviewed-plan bundle")
                              <*> optional (strOption (long "inventory" <> metavar "COMPILED_DIRECTORY" <> help "Plan the compiled typed inventory through the shared executor"))
                              <*> switch (long "allow-replacement" <> help "Record approval for protected replacements in this review")
                          )
                        <**> helper
                  )
                  (progDesc "Save and classify one context-bound Pulumi preview")
              )
            <> command
              "apply"
              ( info
                  ( Infra
                      . InfraApply
                      <$> ( InfraApplyOpts
                              <$> strOption (long "plan" <> metavar "DIR" <> help "Previously reviewed plan bundle")
                              <*> switch (long "yes" <> help "Apply without an interactive prompt")
                              <*> switch (long "allow-replacement" <> help "Acknowledge an approved protected replacement again at apply time")
                          )
                        <**> helper
                  )
                  (progDesc "Verify and non-interactively apply a reviewed Pulumi plan")
              )
            <> command
              "destroy"
              ( info
                  ((Infra <$> (InfraDestroy <$> switch (long "yes" <> help "Confirm legacy teardown only") <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save the next staged inventory teardown review")))) <**> helper)
                  (progDesc "Review cloud teardown policy, retained retirement, and exact leaf collection")
              )
        )
        <**> helper
    )
    (fullDesc <> progDesc "Preview, apply, and tear down guarded infrastructure")
