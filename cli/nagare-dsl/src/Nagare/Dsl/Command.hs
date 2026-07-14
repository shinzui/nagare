-- | A validated container entrypoint override shared by bounded Jobs and
-- continuously running Workers.
module Nagare.Dsl.Command
  ( Command (..)
  , mkCommand
  , commandArgvList
  )
where

import Data.Text qualified as Text
import Nagare.Dsl.Prelude

-- | An optional container entrypoint override. @argv[0]@ is the executable.
-- Construct with 'mkCommand' so the list is non-empty and NUL-free.
data Command = Command
  { commandArgv :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

-- | Validate and construct a 'Command'.
mkCommand :: [Text] -> Either Text Command
mkCommand [] = Left "command must not be empty (argv[0] is the executable)"
mkCommand argv
  | any (Text.isInfixOf "\NUL") argv =
      Left "command arguments must not contain NUL characters"
  | otherwise = Right (Command {commandArgv = argv})

-- | Recover the validated argument vector.
commandArgvList :: Command -> [Text]
commandArgvList = commandArgv
