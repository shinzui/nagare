-- | Parser / Application. Executable-private CLI boundary.
module Nagare.Cli.Parser.Application
  ( appCmd
  , deployCmd
  , deploymentsCmd
  , taskCmd
  , workerCmd
  )
where

import Nagare.Cli.Options
  ( AppCheckOpts (..)
  , AppDeleteOpts (..)
  , AppDeployOpts (..)
  , AppGetOpts (..)
  , AppImagePlanOpts (..)
  , AppListOpts (..)
  , AppLogsOpts (..)
  , AppNameOpts (..)
  , Command (..)
  , DepListOpts (..)
  , DepLogsOpts (..)
  , DeployOpts (..)
  , TaskCommand (..)
  , TaskDeleteOpts (..)
  , TaskListOpts (..)
  , TaskLogsOpts (..)
  , TaskRunOpts (..)
  , WorkerCommand (..)
  , WorkerDeleteOpts (..)
  , WorkerDeployOpts (..)
  )
import Nagare.Cli.Parser.Common
  ( appNameArg
  , baseDomainOpt
  , defaultConfigFile
  , dryRunOpt
  , fileOpt
  , ghcEnvOpt
  , namespaceOpt
  , tagOpt
  , taskAppArg
  , taskNameArg
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
  , strArgument
  , strOption
  , subparser
  , switch
  , (<**>)
  )

deployOptsParser :: FilePath -> Parser DeployOpts
deployOptsParser defaultFile =
  DeployOpts
    <$> fileOpt defaultFile
    <*> tagOpt
    <*> baseDomainOpt
    <*> optional
      ( strOption
          ( long "build-context"
              <> short 'c'
              <> metavar "DIR"
              <> help "Override the build context directory from the config (build modes only)"
          )
      )
    <*> optional
      ( strOption
          ( long "dockerfile"
              <> metavar "FILE"
              <> help "Override the Dockerfile path from the config (Dockerfile build only)"
          )
      )
    <*> ghcEnvOpt
    <*> dryRunOpt
    <*> optional
      ( strOption
          ( long "source"
              <> metavar "REF"
              <> help "Provenance to record with the deployment (e.g. a git SHA or branch)"
          )
      )
    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save a reviewed single-Service inventory plan"))
    <*> optional (strOption (long "image-resource" <> metavar "RESOURCE-ID" <> help "Accepted OCI image for reviewed preview, saved plan, or live deploy"))
    <*> many (strOption (long "service-volume-recovery" <> metavar "VOLUME=BACKUP:KEY:VERSION" <> help "Retained Service PVC recovery for reviewed deploy"))
    <*> many (strOption (long "tls-secret-resource" <> metavar "RESOURCE-ID" <> help "Accepted supplied-TLS Secret for reviewed deploy"))
    <*> many (strOption (long "env-secret-resource" <> metavar "RESOURCE-ID" <> help "Accepted runtime Secret for reviewed deploy"))
    <*> optional (strOption (long "legacy-release-import" <> metavar "FILE" <> help "Legacy release ConfigMap JSON to preserve during exact reviewed adoption"))
    <*> optional (strOption (long "release-adoption-input" <> metavar "FILE" <> help "Versioned exact-incarnation adoption proposal for --legacy-release-import"))

appImagePlanOptsParser :: Parser AppImagePlanOpts
appImagePlanOptsParser =
  AppImagePlanOpts
    <$> strOption (long "archive" <> metavar "FILE" <> help "Docker archive to bind by SHA-256")
    <*> strOption (long "destination" <> metavar "IMAGE:TAG" <> help "Exact registry tag to publish")
    <*> strOption (long "key" <> metavar "KEY" <> help "Stable publication key")
    <*> many (strOption (long "build-input-resource" <> metavar "RESOURCE-ID" <> help "Exact accepted Build environment or Secret channel used to prepare this archive"))
    <*> optional (strOption (long "build-dockerfile" <> metavar "FILE" <> help "Build the archive locally with this Dockerfile and accepted Build inputs"))
    <*> optional (strOption (long "build-context" <> metavar "DIR" <> help "Docker context for --build-dockerfile"))
    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save a reviewed image publication for separate apply"))

appDeployOptsParser :: FilePath -> Parser AppDeployOpts
appDeployOptsParser defaultFile =
  AppDeployOpts
    <$> fileOpt defaultFile
    <*> tagOpt
    <*> baseDomainOpt
    <*> optional
      ( strOption
          ( long "build-context"
              <> short 'c'
              <> metavar "DIR"
              <> help "Override the build context directory from the config (build modes only)"
          )
      )
    <*> optional
      ( strOption
          ( long "dockerfile"
              <> metavar "FILE"
              <> help "Override the Dockerfile path from the config (Dockerfile build only)"
          )
      )
    <*> ghcEnvOpt
    <*> dryRunOpt
    <*> switch
      ( long "json"
          <> help "With --dry-run, emit the compiled scope as one public JSON document"
      )
    <*> optional
      ( strOption
          ( long "source"
              <> metavar "REF"
              <> help "Provenance to record with the deployment (e.g. a git SHA or branch)"
          )
      )
    <*> optional
      (strOption (long "save-plan" <> metavar "FILE" <> help "Save a reviewed inventory plan for a prepublished-image application"))
    <*> optional
      (strOption (long "image-resource" <> metavar "RESOURCE-ID" <> help "Accepted OCI image resource for reviewed preview, saved plan, or live deploy"))
    <*> optional
      (strOption (long "cdn-backend-resource" <> metavar "RESOURCE-ID" <> help "Accepted platform Pulumi BackendService for reviewed Google CDN DNS"))
    <*> many
      (strOption (long "database-recovery" <> metavar "NAME=BACKUP:KEY_VERSION" <> help "Recovery binding for each reviewed application database"))
    <*> many
      (strOption (long "tls-secret-resource" <> metavar "RESOURCE-ID" <> help "Accepted Secret for a reviewed supplied-TLS domain"))
    <*> many
      (strOption (long "env-secret-resource" <> metavar "RESOURCE-ID" <> help "Accepted Secret for a reviewed runtime environment reference"))
    <*> many
      (strOption (long "service-volume-recovery" <> metavar "VOLUME=BACKUP:KEY:VERSION" <> help "Recovery binding for a reviewed retained Service PVC"))
    <*> many
      (strOption (long "worker-volume-recovery" <> metavar "WORKER/VOLUME=BACKUP:KEY:VERSION" <> help "Recovery binding for a reviewed retained worker PVC"))
    <*> many
      (strOption (long "hook-affects" <> metavar "TASK=database:NAME|RESOURCE-ID" <> help "Data resource changed by a pre-deploy hook; repeat for multiple effects"))
    <*> many
      (strOption (long "hook-no-data-effects" <> metavar "TASK" <> help "Assert that a pre-deploy hook changes no managed data resource"))
    <*> switch
      (long "request-namespace" <> help "Request a new namespace through the platform foundation's explicit grant in review")
    <*> optional
      (strOption (long "legacy-release-import" <> metavar "FILE" <> help "Legacy release ConfigMap JSON to preserve during exact reviewed adoption"))
    <*> optional
      (strOption (long "release-adoption-input" <> metavar "FILE" <> help "Versioned exact-incarnation adoption proposal for --legacy-release-import"))

workerDeployOptsParser :: FilePath -> Parser WorkerDeployOpts
workerDeployOptsParser defaultFile =
  WorkerDeployOpts
    <$> fileOpt defaultFile
    <*> tagOpt
    <*> optional
      ( strOption
          ( long "build-context"
              <> short 'c'
              <> metavar "DIR"
              <> help "Override the build context directory from the config (build modes only)"
          )
      )
    <*> optional
      ( strOption
          ( long "dockerfile"
              <> metavar "FILE"
              <> help "Override the Dockerfile path from the config (Dockerfile build only)"
          )
      )
    <*> ghcEnvOpt
    <*> dryRunOpt
    <*> optional (strOption (long "save-plan" <> metavar "FILE" <> help "Save reviewed standalone worker inventory plan"))
    <*> optional (strOption (long "image-resource" <> metavar "RESOURCE-ID" <> help "Accepted OCI image publication for reviewed preview, saved plan, or live deploy"))
    <*> many (strOption (long "volume-recovery" <> metavar "VOLUME=BACKUP:KEY:VERSION" <> help "Recovery for a retained worker PVC; repeat for reviewed deploy"))
    <*> many (strOption (long "env-secret-resource" <> metavar "RESOURCE-ID" <> help "Accepted runtime Secret; repeat for reviewed deploy"))

workerDeleteOptsParser :: Parser WorkerDeleteOpts
workerDeleteOptsParser =
  WorkerDeleteOpts
    <$> strArgument (metavar "NAME" <> help "Worker Deployment name")
    <*> namespaceOpt
    <*> strOption (long "save-plan" <> metavar "DIR" <> help "Save reviewed retirement of the accepted standalone worker")
    <*> optional (strOption (long "scope-key" <> metavar "KEY" <> help "Pin the accepted standalone worker logical key"))

appListOptsParser :: Parser AppListOpts
appListOptsParser =
  AppListOpts
    <$> namespaceOpt
    <*> switch (long "all" <> help "List every Knative Service, not only Nagare-managed apps")

appGetOptsParser :: Parser AppGetOpts
appGetOptsParser =
  AppGetOpts
    <$> appNameArg
    <*> namespaceOpt
    <*> fileOpt defaultConfigFile
    <*> ghcEnvOpt

appLogsOptsParser :: Parser AppLogsOpts
appLogsOptsParser =
  AppLogsOpts
    <$> appNameArg
    <*> namespaceOpt
    <*> switch (long "follow" <> help "Stream logs until interrupted")
    <*> optional
      ( option
          auto
          ( long "tail"
              <> metavar "N"
              <> help "Lines of recent logs to show (default: 200; ignored with --follow)"
          )
      )

appNameOptsParser :: Parser AppNameOpts
appNameOptsParser = AppNameOpts <$> appNameArg <*> namespaceOpt

appDeleteOptsParser :: Parser AppDeleteOpts
appDeleteOptsParser =
  AppDeleteOpts
    <$> appNameArg
    <*> namespaceOpt
    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Required saved review for application or standalone web Service retirement"))
    <*> optional (strOption (long "scope-key" <> metavar "KEY" <> help "Pin the accepted application logical key"))

depListOptsParser :: Parser DepListOpts
depListOptsParser = DepListOpts <$> appNameArg <*> namespaceOpt

depLogsOptsParser :: Parser DepLogsOpts
depLogsOptsParser =
  DepLogsOpts
    <$> appNameArg
    <*> optional (strArgument (metavar "DEPLOYMENT_ID" <> help "A past deployment id (image tag); omit for the live deployment"))
    <*> namespaceOpt
    <*> switch (long "follow" <> help "Stream logs until interrupted")
    <*> optional
      ( option
          auto
          ( long "tail"
              <> metavar "N"
              <> help "Lines of recent logs to show (default: 200; ignored with --follow)"
          )
      )

taskListOptsParser :: Parser TaskListOpts
taskListOptsParser =
  TaskListOpts
    <$> optional (strArgument (metavar "APP" <> help "Owning app to scope to (or - for app-less; omit for all)"))
    <*> namespaceOpt

taskRunOptsParser :: Parser TaskRunOpts
taskRunOptsParser =
  TaskRunOpts
    <$> taskAppArg
    <*> taskNameArg
    <*> namespaceOpt
    <*> dryRunOpt
    <*> optional (strOption (long "run-id" <> metavar "ID" <> help "Stable identity for a reviewed manual Job run"))
    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save a reviewed one-off Job plan"))

taskLogsOptsParser :: Parser TaskLogsOpts
taskLogsOptsParser =
  TaskLogsOpts
    <$> taskAppArg
    <*> taskNameArg
    <*> namespaceOpt
    <*> switch (long "follow" <> help "Stream logs until interrupted")
    <*> optional (option auto (long "tail" <> metavar "N" <> help "Show only the last N lines"))

taskDeleteOptsParser :: Parser TaskDeleteOpts
taskDeleteOptsParser =
  TaskDeleteOpts
    <$> taskAppArg
    <*> taskNameArg
    <*> namespaceOpt
    <*> switch (long "yes" <> help "Legacy flag; live deletion uses --save-plan and inventory apply --yes")
    <*> dryRunOpt
    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save the next reviewed deletion stage for an accepted task"))

deployCmd :: ParserInfo Command
deployCmd =
  info
    (Deploy <$> deployOptsParser defaultConfigFile <**> helper)
    (fullDesc <> progDesc "Build, push, and deploy the app in the current directory")

workerCmd :: ParserInfo Command
workerCmd =
  info
    (workerSubparser <**> helper)
    (fullDesc <> progDesc "Run long-running background workers (apps/v1 Deployments)")

workerSubparser :: Parser Command
workerSubparser =
  subparser
    ( command
        "deploy"
        ( info
            (Worker . WorkerDeploy <$> workerDeployOptsParser defaultConfigFile <**> helper)
            (progDesc "Deploy or review a long-running worker (apps/v1 Deployment) from the current directory")
        )
        <> command
          "delete"
          ( info
              (Worker . WorkerDelete <$> workerDeleteOptsParser <**> helper)
              (progDesc "Review retirement of an accepted standalone worker")
          )
    )

appCmd :: ParserInfo Command
appCmd =
  info
    (appSubparser <**> helper)
    (fullDesc <> progDesc "Application lifecycle: check, list, get, logs, restart, stop, delete")

appSubparser :: Parser Command
appSubparser =
  subparser
    ( command
        "check"
        ( info
            (AppCheck <$> (AppCheckOpts <$> fileOpt defaultConfigFile <*> ghcEnvOpt) <**> helper)
            (progDesc "Evaluate a typed Application Config.hs without contacting any context or provider")
        )
        <> command
          "list"
          ( info
              (AppList <$> appListOptsParser <**> helper)
              (progDesc "List Nagare-managed apps in a namespace")
          )
        <> command
          "get"
          ( info
              (AppGet <$> appGetOptsParser <**> helper)
              (progDesc "Show one app's image, revision, URL, and readiness")
          )
        <> command
          "logs"
          ( info
              (AppLogs <$> appLogsOptsParser <**> helper)
              (progDesc "Stream an app's container logs")
          )
        <> command
          "restart"
          ( info
              (AppRestart <$> appNameOptsParser <**> helper)
              (progDesc "Roll a fresh revision (also brings a stopped app back online)")
          )
        <> command
          "stop"
          ( info
              (AppStop <$> appNameOptsParser <**> helper)
              (progDesc "Take the app offline, recoverably")
          )
        <> command
          "delete"
          ( info
              (AppDelete <$> appDeleteOptsParser <**> helper)
              (progDesc "Delete a legacy app or review accepted web-Service retirement")
          )
        <> command
          "deploy"
          ( info
              (AppDeploy <$> appDeployOptsParser defaultConfigFile <**> helper)
              (progDesc "Deploy a whole multi-workload Application (service + workers + databases + hooks) in one ordered rollout")
          )
        <> command
          "image-plan"
          ( info
              (AppImagePlan <$> appImagePlanOptsParser <**> helper)
              (progDesc "Publish an application OCI archive through review, or save the review for separate apply")
          )
    )

taskCmd :: ParserInfo Command
taskCmd =
  info
    (taskSubparser <**> helper)
    (fullDesc <> progDesc "List, run, view logs for, and delete scheduled tasks (CronJobs)")

taskSubparser :: Parser Command
taskSubparser =
  subparser
    ( command
        "list"
        ( info
            (Task . TaskList <$> taskListOptsParser <**> helper)
            (progDesc "List scheduled tasks (optionally scoped to one app)")
        )
        <> command
          "run"
          ( info
              (Task . TaskRun <$> taskRunOptsParser <**> helper)
              (progDesc "Run an accepted task through a stable reviewed Job; --run-id is required for live execution")
          )
        <> command
          "logs"
          ( info
              (Task . TaskLogs <$> taskLogsOptsParser <**> helper)
              (progDesc "Show a task's most recent pod logs (--follow to tail); prints a Grafana history hint")
          )
        <> command
          "delete"
          ( info
              (Task . TaskDelete <$> taskDeleteOptsParser <**> helper)
              (progDesc "Save staged CronJob suspension, retirement, and collection reviews with --save-plan")
          )
    )

deploymentsCmd :: ParserInfo Command
deploymentsCmd =
  info
    (deploymentsSubparser <**> helper)
    (fullDesc <> progDesc "Application deployment history and logs")

deploymentsSubparser :: Parser Command
deploymentsSubparser =
  subparser
    ( command
        "list"
        ( info
            (DeploymentsList <$> depListOptsParser <**> helper)
            (progDesc "List recorded deployments for an app, newest first")
        )
        <> command
          "logs"
          ( info
              (DeploymentsLogs <$> depLogsOptsParser <**> helper)
              (progDesc "Stream logs for the live or a specific past deployment")
          )
    )
