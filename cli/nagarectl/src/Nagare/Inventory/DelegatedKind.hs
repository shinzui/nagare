-- | The scope kinds a delegated deployer may admit (EP-247). Nothing else is
-- delegable. Kept apart from the delegation record so the deployer's
-- Kubernetes authority ("Nagare.Inventory.DeployerAccess") can be derived
-- from it without importing the record.
module Nagare.Inventory.DelegatedKind
  ( DelegatedKind (..)
  , delegatedKindText
  , parseDelegatedKind
  )
where

import Data.Aeson (FromJSON (parseJSON), ToJSON (toJSON), withText)
import Data.Text qualified as T
import Nagare.Dsl.Prelude

data DelegatedKind = DelegatedWebApp | DelegatedWorker | DelegatedTask | DelegatedStaticSite | DelegatedServerSite
  deriving stock (Eq, Ord, Show, Generic, Enum, Bounded)

delegatedKindText :: DelegatedKind -> Text
delegatedKindText = \case
  DelegatedWebApp -> "web-app"
  DelegatedWorker -> "worker"
  DelegatedTask -> "task"
  DelegatedStaticSite -> "static-site"
  DelegatedServerSite -> "server-site"

parseDelegatedKind :: Text -> Either Text DelegatedKind
parseDelegatedKind raw = case [kind | kind <- [minBound .. maxBound], delegatedKindText kind == raw] of
  [kind] -> Right kind
  _ -> Left ("unknown delegated kind " <> raw <> "; expected one of web-app, worker, task, static-site, server-site")

instance ToJSON DelegatedKind where
  toJSON = toJSON . delegatedKindText

instance FromJSON DelegatedKind where
  parseJSON = withText "DelegatedKind" (either (fail . T.unpack) pure . parseDelegatedKind)
