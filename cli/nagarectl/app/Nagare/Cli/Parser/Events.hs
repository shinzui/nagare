-- | The @events@ command group (EP-231).
module Nagare.Cli.Parser.Events
  ( eventsCmd
  )
where

import Nagare.Cli.Options
import Nagare.Cli.Options.Events (EventsCollectBackupsOpts (..), EventsListOpts (..))
import Nagare.Dsl.Prelude
import Options.Applicative

eventsCmd :: ParserInfo Command
eventsCmd =
  info
    (hsubparser (command "list" eventsListCmd <> command "collect-backups" eventsCollectBackupsCmd) <**> helper)
    (fullDesc <> progDesc "Read the active context's durable lifecycle event history")

eventsListCmd :: ParserInfo Command
eventsListCmd =
  info
    ( EventsList
        <$> ( EventsListOpts
                <$> optional (option auto (long "first" <> metavar "N" <> help "Events per page, 1 to 100 (default 50)"))
                <*> optional (strOption (long "after" <> metavar "CURSOR" <> help "Continue after this cursor, the previous page's endCursor"))
                <*> switch (long "refresh" <> help "With --after, also read events published since the cursor's traversal began")
                <*> many (strOption (long "type" <> metavar "TYPE" <> help "Only events of this type (app.deployed, database.backup.completed, database.backup.accepted); repeatable"))
                <*> optional (strOption (long "scope" <> metavar "KIND:NAME" <> help "Only events about this scope, for example application:notes"))
                <*> optional (strOption (long "member" <> metavar "RESOURCE" <> help "With --scope, only events about this member"))
                <*> switch (long "json" <> help "Print the versioned event-list document")
                <*> optional (option auto (long "contract" <> metavar "VERSION" <> help "Print the event-list document of this contract version (1)"))
            )
          <**> helper
    )
    (fullDesc <> progDesc "List published lifecycle events, oldest first, from the context's feed; it never publishes or initializes the feed")

eventsCollectBackupsCmd :: ParserInfo Command
eventsCollectBackupsCmd =
  info
    ( EventsCollectBackups
        <$> ( EventsCollectBackupsOpts
                <$> switch (long "once" <> help "Run one bounded collection cycle (required; the lifecycle event service runs it continuously)")
                <*> switch (long "activate" <> help "Enable the feed and collection if they are not yet, pinning the backups present now as already seen")
                <*> optional (strOption (long "bucket" <> metavar "BUCKET" <> help "The backup bucket (default: the context's)"))
            )
          <**> helper
    )
    (fullDesc <> progDesc "Verify new scheduled database backups at their exact versions and publish database.backup.completed events; read-only for inventory and backups, it writes only the context's lifecycle state")
