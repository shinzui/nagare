-- | Parser / Common. Executable-private CLI boundary.
module Nagare.Cli.Parser.Common
  ( appArg
  , appNameArg
  , baseDomainOpt
  , configFileOpt
  , defaultConfigFile
  , dryRunOpt
  , fileOpt
  , ghcEnvOpt
  , namespaceOpt
  , tagOpt
  , taskAppArg
  , taskNameArg
  )
where

import Nagare.Dsl.Prelude
import Options.Applicative
  ( Parser
  , help
  , long
  , metavar
  , optional
  , short
  , showDefault
  , strArgument
  , strOption
  , switch
  , value
  )

-- Reusable option fragments shared across the subcommands.

fileOpt :: FilePath -> Parser FilePath
fileOpt defaultFile =
  strOption
    ( long "file"
        <> short 'f'
        <> metavar "FILE"
        <> value defaultFile
        <> showDefault
        <> help "Path to the typed config file"
    )

tagOpt :: Parser (Maybe String)
tagOpt =
  optional
    ( strOption
        ( long "tag"
            <> short 't'
            <> metavar "TAG"
            <> help "Image tag override (default: UTC timestamp YYYYMMDD-HHMMSS)"
        )
    )

baseDomainOpt :: Parser (Maybe String)
baseDomainOpt =
  optional
    ( strOption
        ( long "base-domain"
            <> metavar "DOMAIN"
            <> help "Apps base domain (overrides NAGARE_BASE_DOMAIN, default apps.example.com)"
        )
    )

ghcEnvOpt :: Parser (Maybe FilePath)
ghcEnvOpt =
  optional
    ( strOption
        ( long "ghc-env"
            <> metavar "FILE"
            <> help "GHC package-environment file for the config loader's runghc (overrides NAGARE_GHC_ENVIRONMENT)"
        )
    )

dryRunOpt :: Parser Bool
dryRunOpt =
  switch
    ( long "dry-run"
        <> help "Print rendered artifacts and URL without building, pushing, or applying"
    )

-- App lifecycle option fragments (EP-30).

-- | @-n/--namespace@ for the @app@ commands; 'Nothing' means @personal@.
namespaceOpt :: Parser (Maybe String)
namespaceOpt =
  optional
    ( strOption
        ( long "namespace"
            <> short 'n'
            <> metavar "NS"
            <> help "Kubernetes namespace (default: personal)"
        )
    )

-- | The positional @NAME@ (Knative Service name) every @app NAME@ command takes.
appNameArg :: Parser String
appNameArg = strArgument (metavar "NAME" <> help "App (Knative Service) name")

-- | The default config filename for the chosen substrate (EP-8).
defaultConfigFile :: FilePath
defaultConfigFile = "nagare/Config.hs"

-- Env / secret option fragments (EP-25).

appArg :: Parser String
appArg = strArgument (metavar "APP" <> help "App whose env/secret store to manage")

-- | The config-file option for @env@/@secret@: @-f/--config@ (not @--file@), so
-- @env sync@'s dotenv argument can use the @--file@ long name.
configFileOpt :: Parser FilePath
configFileOpt =
  strOption
    ( long "config"
        <> short 'f'
        <> metavar "FILE"
        <> value defaultConfigFile
        <> showDefault
        <> help "Typed config file; its name/namespace identify the app"
    )

-- Scheduled-task option fragments (MasterPlan 10, EP-51).

-- | The positional TASK argument every @task ... TASK@ command takes.
taskNameArg :: Parser String
taskNameArg = strArgument (metavar "TASK" <> help "Scheduled task name (DNS label)")

-- | The positional APP argument: scopes by the @nagare.dev/app@ label. @-@ means
-- "tasks with no app association".
taskAppArg :: Parser String
taskAppArg = strArgument (metavar "APP" <> help "Owning app (or - for app-less tasks)")
