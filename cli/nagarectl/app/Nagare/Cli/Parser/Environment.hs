-- | Parser / Environment. Executable-private CLI boundary.
module Nagare.Cli.Parser.Environment
  ( envCmd
  , secretCmd
  , enTenantCmd
  , storeCommonOptsParser
  )
where

import Nagare.Cli.Options
  ( Command (..)
  , EnTenantCommand (..)
  , EnvCommand (..)
  , ScopeSelection (..)
  , SecretCommand (..)
  , StoreCommonOpts (..)
  )
import Nagare.Cli.Parser.Common
  ( appArg
  , configFileOpt
  , dryRunOpt
  , ghcEnvOpt
  )
import Nagare.Dsl.Prelude
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

storeCommonOptsParser :: Parser StoreCommonOpts
storeCommonOptsParser =
  StoreCommonOpts <$> appArg <*> configFileOpt <*> ghcEnvOpt

scopeSelectionParser :: Parser ScopeSelection
scopeSelectionParser =
  ScopeSelection
    <$> switch (long "runtime" <> help "Target the runtime scope (default if no scope flag is given)")
    <*> switch (long "build" <> help "Target the build scope")
    <*> switch (long "preview" <> help "Target the preview scope")

-- | @--reconcile-exact@ => 'True', @--merge@ (or default) => 'False'. The two
-- flags are mutually exclusive.
reconcileExactParser :: Parser Bool
reconcileExactParser =
  flag' True (long "reconcile-exact" <> help "Make the store exactly the file (drop keys not present)")
    <|> flag' False (long "merge" <> help "Keep existing keys not in the file (default)")
    <|> pure False

envCmd :: ParserInfo Command
envCmd =
  info
    (Env <$> envSubparser <**> helper)
    (fullDesc <> progDesc "Manage an app's environment variables (managed ConfigMap store)")

envSubparser :: Parser EnvCommand
envSubparser =
  subparser
    ( command
        "list"
        ( info
            ( EnvList
                <$> storeCommonOptsParser
                <*> switch (long "all" <> help "Show all scopes, grouped")
                  <**> helper
            )
            (progDesc "List env keys/values for an app")
        )
        <> command
          "set"
          ( info
              ( EnvSet
                  <$> storeCommonOptsParser
                  <*> scopeSelectionParser
                  <*> dryRunOpt
                  <*> strArgument (metavar "KEY")
                  <*> strArgument (metavar "VALUE")
                  <*> switch (long "reviewed" <> help "Publish and apply a reviewed single-key change")
                  <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Review one env key update from accepted history"))
                    <**> helper
              )
              (progDesc "Set one env key (single-key merge)")
          )
        <> command
          "delete"
          ( info
              ( EnvDelete
                  <$> storeCommonOptsParser
                  <*> scopeSelectionParser
                  <*> dryRunOpt
                  <*> strArgument (metavar "KEY")
                  <*> switch (long "reviewed" <> help "Publish and apply a reviewed single-key deletion")
                  <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Review one env key deletion from accepted history"))
                    <**> helper
              )
              (progDesc "Delete one env key")
          )
        <> command
          "sync"
          ( info
              ( EnvSync
                  <$> storeCommonOptsParser
                  <*> scopeSelectionParser
                  <*> dryRunOpt
                  <*> reconcileExactParser
                  <*> strOption (long "file" <> metavar "FILE" <> help "dotenv file to import")
                  <*> switch (long "reviewed" <> help "Publish and apply a reviewed merged or exact channel")
                  <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Review a merged or exact Runtime, Build, or Preview env channel"))
                    <**> helper
              )
              (progDesc "Bulk-import a dotenv file into the env store")
          )
    )

secretCmd :: ParserInfo Command
secretCmd =
  info
    (Secret <$> secretSubparser <**> helper)
    (fullDesc <> progDesc "Manage an app's secrets (managed Secret store)")

secretSubparser :: Parser SecretCommand
secretSubparser =
  subparser
    ( command
        "set"
        ( info
            ( SecretSet
                <$> storeCommonOptsParser
                <*> scopeSelectionParser
                <*> dryRunOpt
                <*> strArgument (metavar "KEY")
                <*> optional (strOption (long "version" <> metavar "TOKEN" <> help "Opaque reviewed Secret rotation version"))
                <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Review one Secret key update"))
                  <**> helper
            )
            (progDesc "Set one secret key; the value is read from stdin")
        )
        <> command
          "list"
          ( info
              ( SecretList
                  <$> storeCommonOptsParser
                  <*> switch (long "all" <> help "Show all scopes")
                    <**> helper
              )
              (progDesc "List secret key names (never values)")
          )
        <> command
          "delete"
          ( info
              ( SecretDelete
                  <$> storeCommonOptsParser
                  <*> scopeSelectionParser
                  <*> dryRunOpt
                  <*> strArgument (metavar "KEY")
                  <*> optional (strOption (long "version" <> metavar "TOKEN" <> help "Opaque reviewed Secret rotation version"))
                  <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Review one Secret key deletion"))
                    <**> helper
              )
              (progDesc "Delete one secret key")
          )
        <> command
          "sync"
          ( info
              ( SecretSync
                  <$> storeCommonOptsParser
                  <*> scopeSelectionParser
                  <*> strOption (long "file" <> metavar "FILE" <> help "dotenv file with exact Runtime, Build, or Preview Secret values")
                  <*> strOption (long "version" <> metavar "TOKEN" <> help "Opaque Secret rotation version")
                  <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save a reviewed Runtime, Build, or Preview Secret replacement"))
                    <**> helper
              )
              (progDesc "Apply an exact reviewed Runtime, Build, or Preview Secret replacement, or save its review")
          )
    )

enTenantCmd :: ParserInfo Command
enTenantCmd =
  info
    (EnTenant <$> enTenantSubparser <**> helper)
    (fullDesc <> progDesc "Use an operator-declared En tenant from an app (EP-262)")

enTenantSubparser :: Parser EnTenantCommand
enTenantSubparser =
  subparser
    ( command
        "bind"
        ( info
            ( EnTenantBind
                <$> strArgument (metavar "NAME" <> help "The En tenant, as NAGARE_EN_TENANTS declares it")
                <*> ( StoreCommonOpts
                        <$> strOption (long "app" <> metavar "APP" <> help "The app whose runtime Secret receives the keys")
                        <*> configFileOpt
                        <*> ghcEnvOpt
                    )
                <*> optional (strOption (long "read-write-as" <> metavar "VAR" <> help "Runtime Secret key for the tenant's read-write API key"))
                <*> optional (strOption (long "read-only-as" <> metavar "VAR" <> help "Runtime Secret key for the tenant's read-only API key"))
                <*> optional (strOption (long "version" <> metavar "TOKEN" <> help "Opaque reviewed Secret rotation version"))
                <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Review the runtime Secret change"))
                  <**> helper
            )
            (progDesc "Copy a tenant's API keys into an app's runtime Secret as one reviewed change; no key is printed")
        )
    )
