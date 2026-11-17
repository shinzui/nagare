-- | The @events@ command group (EP-231).
module Nagare.Cli.Parser.Events
  ( eventsCmd
  )
where

import Nagare.Cli.Options
import Nagare.Cli.Options.Events
import Nagare.Dsl.Prelude
import Options.Applicative

eventsCmd :: ParserInfo Command
eventsCmd =
  info
    ( hsubparser
        ( command "list" eventsListCmd
            <> command "collect-backups" eventsCollectBackupsCmd
            <> command "webhook" webhookCmd
            <> command "subscription" subscriptionCmd
            <> command "delivery" deliveryCmd
        )
        <**> helper
    )
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

savePlanOpt :: Parser FilePath
savePlanOpt = strOption (long "save-plan" <> metavar "DIR" <> help "Save the inventory review here; inventory apply DIR applies it")

contractOpt :: Parser (Maybe Int)
contractOpt = optional (option auto (long "contract" <> metavar "VERSION" <> help "Print the document of this contract version (1)"))

webhookCmd :: ParserInfo Command
webhookCmd =
  info
    ( EventsWebhook
        <$> hsubparser
          ( command "create" (info (WebhookCreate <$> createOpts <**> helper) (progDesc "Review a new webhook subscription; it receives events published after this review"))
              <> command "update" (info (WebhookUpdate <$> updateOpts <**> helper) (progDesc "Review a change of a webhook subscription; a new URL or filter cancels its unsent deliveries, a key rotation does not"))
              <> command "disable" (info (WebhookDisable <$> nameArg <*> savePlanOpt <**> helper) (progDesc "Review pausing a subscription; its pending deliveries are kept"))
              <> command "delete" (info (WebhookDelete <$> nameArg <*> savePlanOpt <**> helper) (progDesc "Review deleting a subscription; its delivery history is kept"))
          )
          <**> helper
    )
    (fullDesc <> progDesc "Reviewed webhook subscriptions to the context's lifecycle events")
  where
    nameArg = strArgument (metavar "NAME" <> help "The subscription")
    createOpts =
      WebhookCreateOpts
        <$> nameArg
        <*> strOption (long "url" <> metavar "URL" <> help "The receiver, https:// (http:// only for an --allow-host host)")
        <*> some (strOption (long "type" <> metavar "TYPE" <> help "An event type to send (app.deployed, database.backup.completed, database.backup.accepted); repeatable"))
        <*> optional (strOption (long "scope" <> metavar "KIND:NAME" <> help "Only events about this scope"))
        <*> optional (strOption (long "member" <> metavar "RESOURCE" <> help "With --scope, only events about this member"))
        <*> many (strOption (long "allow-host" <> metavar "HOST" <> help "A cluster-private receiver host whose private addresses (and plain http) are allowed; repeatable"))
        <*> strOption (long "signing-secret" <> metavar "NAMESPACE/NAME" <> help "The Secret holding the signing key")
        <*> strOption (long "signing-key" <> metavar "FIELD" <> help "The Secret's field holding the key")
        <*> strOption (long "key-id" <> metavar "ID" <> value "current" <> help "The key ID receivers see (default current)")
        <*> savePlanOpt
    updateOpts =
      WebhookUpdateOpts
        <$> nameArg
        <*> optional (strOption (long "url" <> metavar "URL" <> help "A new receiver URL"))
        <*> many (strOption (long "type" <> metavar "TYPE" <> help "The event types, replacing the accepted ones; repeatable"))
        <*> many (strOption (long "allow-host" <> metavar "HOST" <> help "The allowed cluster-private hosts, replacing the accepted ones; repeatable"))
        <*> optional (strOption (long "rotate-key" <> metavar "NAMESPACE/NAME:FIELD:ID" <> help "Sign with this new current key, and with the current one as retiring"))
        <*> optional (strOption (long "retire-key" <> metavar "ID" <> help "Stop signing with this key"))
        <*> switch (long "enable" <> help "Reactivate a disabled subscription")
        <*> savePlanOpt

subscriptionCmd :: ParserInfo Command
subscriptionCmd =
  info
    ( EventsSubscription
        <$> hsubparser
          ( command "list" (info (SubscriptionList <$> contractOpt <**> helper) (progDesc "List the context's accepted subscriptions and their delivery state"))
              <> command "inspect" (info (SubscriptionInspect <$> strArgument (metavar "NAME") <*> contractOpt <**> helper) (progDesc "Show one subscription's record and delivery state"))
          )
          <**> helper
    )
    (fullDesc <> progDesc "Inspect lifecycle event subscriptions, whatever their transport")

deliveryCmd :: ParserInfo Command
deliveryCmd =
  info
    ( EventsDelivery
        <$> hsubparser
          ( command "list" (info (DeliveryList <$> strArgument (metavar "SUBSCRIPTION") <*> optional (strOption (long "after" <> metavar "CURSOR" <> help "Continue after this cursor, the previous page's endCursor")) <*> optional (option auto (long "first" <> metavar "N" <> help "Deliveries per page, 1 to 100 (default 50)")) <*> contractOpt <**> helper) (progDesc "List a subscription's deliveries, oldest first"))
              <> command "inspect" (info (DeliveryInspect <$> strArgument (metavar "DELIVERY_ID") <*> contractOpt <**> helper) (progDesc "Show one delivery and its attempts"))
              <> command "replay" (info (DeliveryReplay <$> strArgument (metavar "SUBSCRIPTION") <*> strOption (long "event" <> metavar "EVENT_ID" <> help "The retained event to send again") <*> savePlanOpt <**> helper) (progDesc "Review a new delivery cycle of one event under the subscription's current revision"))
          )
          <**> helper
    )
    (fullDesc <> progDesc "Inspect and replay lifecycle event deliveries, whatever their transport")
