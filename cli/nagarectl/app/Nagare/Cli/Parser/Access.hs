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
  , TeamCommand (..)
  , TeamListOpts (..)
  , TeamMemberOpts (..)
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
  , switch
  , (<**>)
  )

accessGrantOptsParser :: Parser AccessGrantOpts
accessGrantOptsParser =
  AccessGrantOpts
    <$> savePlanOpt "Save a reviewed access grant or revocation"
    <*> enUrlOpt
    <*> enApiKeyOpt
    <*> hostOpt
    <*> optional userOpt
    <*> optional (strOption (long "team" <> metavar "TEAM" <> help "Team whose members receive access to the host (always reviewed; exactly one of --user and --team)"))

accessListOptsParser :: Parser AccessListOpts
accessListOptsParser =
  AccessListOpts
    <$> enUrlOpt
    <*> enApiKeyOpt
    <*> hostOpt
    <*> jsonOpt "Print the stored relationships as JSON"

teamMemberOptsParser :: Parser TeamMemberOpts
teamMemberOptsParser =
  TeamMemberOpts
    <$> savePlanOpt "Save a reviewed team membership change"
    <*> enApiKeyOpt
    <*> teamOpt
    <*> userOpt

teamListOptsParser :: Parser TeamListOpts
teamListOptsParser =
  TeamListOpts
    <$> enUrlOpt
    <*> enApiKeyOpt
    <*> teamOpt
    <*> jsonOpt "Print the stored memberships as JSON"

savePlanOpt :: String -> Parser (Maybe FilePath)
savePlanOpt description = optional (strOption (long "save-plan" <> metavar "DIR" <> help description))

hostOpt :: Parser String
hostOpt = strOption (long "host" <> metavar "HOST" <> help "Protected site hostname, e.g. tools.apps.example.com")

userOpt :: Parser String
userOpt = strOption (long "user" <> metavar "EMAIL|USER_ID" <> help "The email the person signed up with, or their Shomei user id (user_…)")

teamOpt :: Parser String
teamOpt = strOption (long "team" <> metavar "TEAM" <> help "Team key: lowercase letters, digits, _ and -, starting with a letter")

jsonOpt :: String -> Parser Bool
jsonOpt description = switch (long "json" <> help description)

enUrlOpt :: Parser (Maybe String)
enUrlOpt =
  optional
    ( strOption
        ( long "en-url"
            <> metavar "URL"
            <> help "en-server URL for list and the direct grant and revoke (default: NAGARE_EN_URL); reviewed grants reach en themselves"
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
            (progDesc "Grant a shomei user, or a team's members, access to a protected host")
        )
        <> command
          "revoke"
          ( info
              (AccessRevoke <$> accessGrantOptsParser <**> helper)
              (progDesc "Revoke a shomei user's, or a team's, access to a protected host")
          )
        <> command
          "list"
          ( info
              (AccessList <$> accessListOptsParser <**> helper)
              (progDesc "List the stored grants on a protected host: direct users apart from teams")
          )
        <> command
          "team"
          ( info
              (AccessTeam <$> teamSubparser <**> helper)
              (progDesc "Manage team membership (a team is a named group with flat user membership)")
          )
        <> command
          "portal"
          ( info
              (AccessPortal <$> portalSubparser <**> helper)
              (progDesc "Inspect or synchronize the authentication portal")
          )
    )

teamSubparser :: Parser TeamCommand
teamSubparser =
  subparser
    ( command
        "add-member"
        (info (TeamAddMember <$> teamMemberOptsParser <**> helper) (progDesc "Add a shomei user to a team (reviewed)"))
        <> command
          "remove-member"
          (info (TeamRemoveMember <$> teamMemberOptsParser <**> helper) (progDesc "Remove a shomei user from a team (reviewed)"))
        <> command
          "list-members"
          (info (TeamListMembers <$> teamListOptsParser <**> helper) (progDesc "List a team's stored memberships"))
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
