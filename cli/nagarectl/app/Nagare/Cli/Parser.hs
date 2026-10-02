-- | Parser. Executable-private CLI boundary.
module Nagare.Cli.Parser
  ( opts
  )
where

import Nagare.Cli.Options (Command (..))
import Nagare.Cli.Parser.Access (accessCmd)
import Nagare.Cli.Parser.Application
  ( appCmd
  , deployCmd
  , deploymentsCmd
  , taskCmd
  , workerCmd
  )
import Nagare.Cli.Parser.Context (contextCmd, initCmd)
import Nagare.Cli.Parser.Data (brokerCmd, dbCmd, storageCmd)
import Nagare.Cli.Parser.Environment (envCmd, secretCmd)
import Nagare.Cli.Parser.Inventory (inventoryCmd)
import Nagare.Cli.Parser.Operations
  ( cdnCmd
  , cleanupCmd
  , doctorCmd
  , domainsCmd
  , serverCmd
  )
import Nagare.Cli.Parser.Platform
  ( clusterCmd
  , hostCmd
  , infraCmd
  , kubeconfigCmd
  , platformCmd
  , releaseCmd
  , versionCmd
  )
import Nagare.Cli.Parser.Site (siteCmd)
import Nagare.Dsl.Prelude
import Options.Applicative
  ( Parser
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
  , strOption
  , subparser
  , (<**>)
  )

globalContextParser :: Parser (Maybe String)
globalContextParser =
  optional
    ( strOption
        ( long "context"
            <> metavar "NAME"
            <> help "Target context to use for this command (overrides NAGARE_CONTEXT and the current-context pointer)"
        )
    )

opts :: ParserInfo (Maybe String, Command)
opts =
  info
    (((,) <$> globalContextParser <*> commandParser) <**> helper)
    ( fullDesc
        <> progDesc "nagarectl — deploy a typed Nagare app or static site to Knative"
    )

commandParser :: Parser Command
commandParser =
  subparser
    ( command "version" versionCmd
        <> command "release" releaseCmd
        <> command "inventory" inventoryCmd
        <> command "platform" platformCmd
        <> command "host" hostCmd
        <> command "kubeconfig" kubeconfigCmd
        <> command "cluster" clusterCmd
        <> command "deploy" deployCmd
        <> command "site" siteCmd
        <> command "env" envCmd
        <> command "secret" secretCmd
        <> command "app" appCmd
        <> command "deployments" deploymentsCmd
        <> command "storage" storageCmd
        <> command "broker" brokerCmd
        <> command "db" dbCmd
        <> command "task" taskCmd
        <> command "worker" workerCmd
        <> command "access" accessCmd
        <> command "server" serverCmd
        <> command "doctor" doctorCmd
        <> command "context" contextCmd
        <> command "init" initCmd
        <> command "infra" infraCmd
        <> command "domains" domainsCmd
        <> command "cdn" cdnCmd
        <> command "cleanup" cleanupCmd
    )
