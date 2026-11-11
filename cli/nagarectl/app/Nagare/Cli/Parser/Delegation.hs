-- | Parser / Delegation (EP-247). Executable-private CLI boundary.
module Nagare.Cli.Parser.Delegation
  ( delegationCmd
  , withReviewSource
  )
where

import Data.Text qualified as T
import Nagare.Cli.Options (Command (..))
import Nagare.Cli.Options.Delegation (DelegationCommand (..), DelegationCreateOpts (..))
import Nagare.Cli.Parser.Common (contractOpt)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Actor (ReviewSource (..))
import Options.Applicative
  ( Parser
  , ParserInfo
  , auto
  , command
  , help
  , helper
  , info
  , long
  , many
  , metavar
  , option
  , optional
  , progDesc
  , some
  , strArgument
  , strOption
  , subparser
  , (<**>)
  )

delegationCmd :: ParserInfo Command
delegationCmd =
  info
    ( Delegation
        <$> subparser
          ( command
              "create"
              ( info
                  (DelegationCreate <$> createOpts <**> helper)
                  (progDesc "Save a review of a bounded delegation of namespaces, hostnames and an image repository to a named deployer")
              )
              <> command
                "revoke"
                ( info
                    (DelegationRevoke <$> nameArg <*> savePlan <**> helper)
                    (progDesc "Save a review revoking a delegation; its namespaces and what runs in them are kept")
                )
              <> command
                "show"
                ( info
                    (DelegationShow <$> nameArg <*> contractOpt <**> helper)
                    (progDesc "Show one accepted delegation from the inventory without contacting providers")
                )
          )
          <**> helper
    )
    (progDesc "Delegate a bounded part of the context to a CI deployer (EP-247)")
  where
    nameArg = strArgument (metavar "DEPLOYER")
    savePlan = strOption (long "save-plan" <> metavar "DIRECTORY")
    createOpts =
      DelegationCreateOpts
        <$> nameArg
        <*> some (strOption (long "namespace" <> metavar "NS" <> help "A namespace the delegation creates and owns (repeatable)"))
        <*> many (strOption (long "host-suffix" <> metavar "LABEL" <> help "One-label hostnames ending in LABEL under the base domain (repeatable)"))
        <*> some (strOption (long "kinds" <> metavar "KIND" <> help "web-app, worker, task, static-site or server-site (repeatable)"))
        <*> strOption (long "image-repository" <> metavar "PATH" <> help "The registry path every published image must sit under")
        <*> strOption (long "team" <> metavar "TEAM" <> help "The default team for the delegation's sites")
        <*> optional (strOption (long "build-namespace" <> metavar "NS" <> help "A namespace for credential-free build Jobs"))
        <*> optional (strOption (long "quota-cpu" <> metavar "CPU"))
        <*> optional (strOption (long "quota-memory" <> metavar "MEMORY"))
        <*> optional (option auto (long "quota-pods" <> metavar "N"))
        <*> savePlan

-- | Wrap a command that prepares a review with its source options. The
-- revision comes from the command's own @--source@ when it has one.
withReviewSource :: Bool -> Parser Command -> Parser Command
withReviewSource ownRevision parser = WithReviewSource <$> source <*> parser
  where
    text = fmap T.pack
    source =
      ReviewSource
        <$> optional (text (strOption (long "source-repository" <> metavar "URL" <> help "The repository this change came from, recorded in the review")))
        <*> (if ownRevision then pure Nothing else optional (text (strOption (long "source-revision" <> metavar "REF" <> help "The commit this change came from"))))
        <*> optional (text (strOption (long "source-run" <> metavar "URL" <> help "The CI run that produced this change")))
