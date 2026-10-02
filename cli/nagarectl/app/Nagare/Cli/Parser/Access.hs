-- | Parser / Access. Executable-private CLI boundary.
module Nagare.Cli.Parser.Access
  ( accessCmd
  )
where

import Nagare.Cli.Options
  ( AccessCommand (..)
  , AccessGrantOpts (..)
  , AccessListOpts (..)
  , Command (..)
  , PortalCommand (..)
  )
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

accessGrantOptsParser :: Parser AccessGrantOpts
accessGrantOptsParser =
  AccessGrantOpts
    <$> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save a reviewed access grant or revocation"))
    <*> enUrlOpt
    <*> enApiKeyOpt
    <*> strOption (long "host" <> metavar "HOST" <> help "Protected site hostname, e.g. tools.apps.example.com")
    <*> strOption (long "user" <> metavar "USER" <> help "Shomei user id to grant or revoke")

accessListOptsParser :: Parser AccessListOpts
accessListOptsParser =
  AccessListOpts
    <$> enUrlOpt
    <*> enApiKeyOpt
    <*> strOption (long "host" <> metavar "HOST" <> help "Protected site hostname, e.g. tools.apps.example.com")

enUrlOpt :: Parser (Maybe String)
enUrlOpt =
  optional
    ( strOption
        ( long "en-url"
            <> metavar "URL"
            <> help "en-server URL (default: NAGARE_EN_URL)"
        )
    )

enApiKeyOpt :: Parser (Maybe String)
enApiKeyOpt =
  optional
    ( strOption
        ( long "en-api-key"
            <> metavar "KEY"
            <> help "en-server bearer API key (default: NAGARE_EN_API_KEY)"
        )
    )

accessCmd :: ParserInfo Command
accessCmd =
  info
    (Access <$> accessSubparser <**> helper)
    (fullDesc <> progDesc "Manage identity-aware access grants for protected sites")

accessSubparser :: Parser AccessCommand
accessSubparser =
  subparser
    ( command
        "grant"
        ( info
            (AccessGrant <$> accessGrantOptsParser <**> helper)
            (progDesc "Grant a shomei user access to a protected host")
        )
        <> command
          "revoke"
          ( info
              (AccessRevoke <$> accessGrantOptsParser <**> helper)
              (progDesc "Revoke a shomei user's access to a protected host")
          )
        <> command
          "list"
          ( info
              (AccessList <$> accessListOptsParser <**> helper)
              (progDesc "List users who currently expand to access on a protected host")
          )
        <> command
          "portal"
          ( info
              (AccessPortal <$> portalSubparser <**> helper)
              (progDesc "Inspect or synchronize the authentication portal")
          )
    )

portalSubparser :: Parser PortalCommand
portalSubparser =
  subparser
    ( command
        "show"
        (info (pure PortalShow <**> helper) (progDesc "Show the registered authentication portal"))
        <> command
          "sync"
          (info (PortalSync <$> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save the complete accepted portal configuration review")) <**> helper) (progDesc "Review complete portal settings and roll their startup readers"))
    )
