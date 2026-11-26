-- | Parser / KeySet (EP-286). Executable-private CLI boundary.
module Nagare.Cli.Parser.KeySet
  ( keySetCmd
  )
where

import Nagare.Cli.Options (Command (..))
import Nagare.Cli.Options.KeySet (KeySetCommand (..), KeySetPlanOpts (..))
import Nagare.Dsl.Prelude
import Options.Applicative
  ( Parser
  , ParserInfo
  , command
  , help
  , helper
  , info
  , long
  , metavar
  , optional
  , progDesc
  , short
  , strArgument
  , strOption
  , subparser
  , (<**>)
  )

keySetCmd :: ParserInfo Command
keySetCmd =
  info
    ( KeySet
        <$> subparser
          ( command
              "plan"
              ( info
                  (KeySetPlan <$> planOpts <**> helper)
                  (progDesc "Review the signing key sets a config declares: each key set's objects, its rotator and the first run that generates its keys")
              )
              <> command
                "status"
                ( info
                    (KeySetStatus <$> optional (strArgument (metavar "NAME" <> help "One key set; every accepted key set when omitted")) <**> helper)
                    (progDesc "Show each accepted key set's published keys and recorded rotations, read from its public file")
                )
              <> command
                "retire"
                ( info
                    (KeySetRetire <$> strArgument (metavar "NAME") <*> strOption (long "save-plan" <> metavar "DIRECTORY" <> help "Directory to save the review in") <**> helper)
                    (progDesc "Save a review that retires a key set no workload binds; the inventory collect review it prints then deletes its keys")
                )
          )
          <**> helper
    )
    (progDesc "Ed25519 signing key sets the platform generates and rotates")
  where
    planOpts :: Parser KeySetPlanOpts
    planOpts =
      KeySetPlanOpts
        <$> strOption (long "file" <> short 'f' <> metavar "CONFIG" <> help "A config that calls emitKeySets")
        <*> optional (strOption (long "save-plan" <> metavar "DIRECTORY" <> help "Directory to save the review in"))
