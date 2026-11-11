-- | The commands a deployer context may run (EP-247 D3). The guard reads the
-- command words from the arguments, before the command parses its options or
-- opens a store, so a refused command reads and writes nothing.
module Nagare.Inventory.DeployerCommands
  ( commandWords
  , contextArgument
  , deployerCommandAllowed
  , guardDeployerCommand
  )
where

import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Actor (Actor (..))

-- | The leading command words, after the global @--context NAME@.
commandWords :: [Text] -> [Text]
commandWords = \case
  "--context" : _ : rest -> commandWords rest
  flag : rest | "--context=" `T.isPrefixOf` flag -> commandWords rest
  arguments -> takeWhile (not . ("-" `T.isPrefixOf`)) arguments

-- | The global @--context NAME@, if the arguments give one before the command.
contextArgument :: [Text] -> Maybe Text
contextArgument = \case
  "--context" : name : _ -> Just name
  flag : rest
    | Just name <- T.stripPrefix "--context=" flag -> Just name
    | "-" `T.isPrefixOf` flag -> contextArgument rest
  _ -> Nothing

deployerCommandAllowed :: [Text] -> Bool
deployerCommandAllowed = \case
  [] -> True
  ["version"] -> True
  "version" : _ -> True
  "app" : verb : _ -> verb `elem` ["image-plan", "check", "deploy", "delete"]
  "worker" : "deploy" : _ -> True
  "task" : verb : _ -> verb `elem` ["run", "delete"]
  "site" : "preview" : _ -> True
  "site" : verb : _ -> verb `elem` ["deploy", "rollback"]
  "inventory" : verb : _ -> verb `elem` ["apply", "resume", "status", "publications", "history"]
  "delegation" : "show" : _ -> True
  _ -> False

-- | Refuse, naming the command, when a deployer runs one its delegation does
-- not cover. An operator runs everything.
guardDeployerCommand :: Actor -> [Text] -> Either Text ()
guardDeployerCommand actor arguments = case actor of
  OperatorActor _ -> Right ()
  DeployerActor deployer
    | deployerCommandAllowed command -> Right ()
    | otherwise ->
        Left
          ( "nagarectl "
              <> T.unwords command
              <> " is not available in deployer context "
              <> deployer
              <> "; a delegated deployer may run app image-plan|check|deploy|delete, worker deploy, task run|delete, site deploy|rollback|preview, inventory apply|resume|status|publications|history, delegation show and version"
          )
  where
    command = take 2 (commandWords arguments)
