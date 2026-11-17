-- | Options / Events. Option records for the @events@ commands; parsing-only.
module Nagare.Cli.Options.Events
  ( EventsListOpts (..)
  , EventsCollectBackupsOpts (..)
  , EventsWebhookCommand (..)
  , WebhookCreateOpts (..)
  , WebhookUpdateOpts (..)
  , EventsDeliveryCommand (..)
  , EventsSubscriptionCommand (..)
  )
where

import Nagare.Dsl.Prelude

-- | @events list@: one page of the active context's published lifecycle
-- events, oldest first (EP-231).
data EventsListOpts = EventsListOpts
  { first :: !(Maybe Int)
  , after :: !(Maybe String)
  , refresh :: !Bool
  , types :: ![String]
  , scope :: !(Maybe String)
  , member :: !(Maybe String)
  , json :: !Bool
  , contract :: !(Maybe Int)
  }
  deriving stock (Generic, Show)

-- | @events collect-backups --once@: one bounded backup collection cycle
-- for disposable fixtures and diagnostics (EP-233).
data EventsCollectBackupsOpts = EventsCollectBackupsOpts
  { once :: !Bool
  , activate :: !Bool
  , bucket :: !(Maybe String)
  }
  deriving stock (Generic, Show)

-- | @events webhook@: reviewed webhook subscriptions (EP-234). Each saves an
-- inventory review that @inventory apply@ applies.
data EventsWebhookCommand
  = WebhookCreate !WebhookCreateOpts
  | WebhookUpdate !WebhookUpdateOpts
  | WebhookDisable !String !FilePath
  | WebhookDelete !String !FilePath
  deriving stock (Generic, Show)

data WebhookCreateOpts = WebhookCreateOpts
  { name :: !String
  , url :: !String
  , types :: ![String]
  , scope :: !(Maybe String)
  , member :: !(Maybe String)
  , allowHosts :: ![String]
  , signingSecret :: !String
  , signingKey :: !String
  , keyId :: !String
  , savePlan :: !FilePath
  }
  deriving stock (Generic, Show)

-- | A given field replaces the accepted one; @--rotate-key@ adds a new
-- current key and keeps the old one as retiring, @--retire-key@ drops one.
data WebhookUpdateOpts = WebhookUpdateOpts
  { name :: !String
  , url :: !(Maybe String)
  , types :: ![String]
  , allowHosts :: ![String]
  , rotateKey :: !(Maybe String)
  , retireKey :: !(Maybe String)
  , enable :: !Bool
  , savePlan :: !FilePath
  }
  deriving stock (Generic, Show)

-- | @events delivery@: transport-neutral delivery inspection and replay.
data EventsDeliveryCommand
  = DeliveryReplay !String !String !FilePath
  | DeliveryList !String !(Maybe Integer) !(Maybe Int) !(Maybe Int)
  | DeliveryInspect !String !(Maybe Int)
  deriving stock (Generic, Show)

-- | @events subscription@: transport-neutral subscription inspection.
data EventsSubscriptionCommand
  = SubscriptionList !(Maybe Int)
  | SubscriptionInspect !String !(Maybe Int)
  deriving stock (Generic, Show)
