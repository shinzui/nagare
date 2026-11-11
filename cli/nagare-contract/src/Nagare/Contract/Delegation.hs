-- | The delegated-deployer read documents (EP-247 D7): one accepted
-- delegation, and the transaction history with its actor and source.
module Nagare.Contract.Delegation
  ( DelegationQuotaSummary (..)
  , DelegationDocument (..)
  , ActorSummary (..)
  , SourceSummary (..)
  , TransactionSummary (..)
  , TransactionHistory (..)
  , DeployerCredentials (..)
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), genericParseJSON, genericToJSON)
import Data.OpenApi (ToSchema (..), description, schema)
import Nagare.Contract.Prelude
import Nagare.Contract.Schema

data DelegationQuotaSummary = DelegationQuotaSummary
  { cpu :: !Text
  , memory :: !Text
  , pods :: !Int
  }
  deriving stock (Eq, Show, Generic)

-- | What a named deployer may do on this context, as the accepted head
-- records it. @acceptedRevision@ is the delegation scope's generation.
data DelegationDocument = DelegationDocument
  { contractVersion :: !ContractVersion
  , document :: !(DocumentName "delegation")
  , name :: !Text
  , state :: !Text
  , namespaces :: ![Text]
  , hostSuffixes :: ![Text]
  , kinds :: ![Text]
  , imageRepository :: !Text
  , team :: !Text
  , buildNamespace :: !(Nullable Text)
  , quota :: !DelegationQuotaSummary
  , baseDomain :: !Text
  , hostShape :: !Text
  , acceptedRevision :: !Integer
  }
  deriving stock (Eq, Show, Generic)

-- | @kind@ is @operator@ or @deployer@; a deployer always has a name.
data ActorSummary = ActorSummary
  { kind :: !Text
  , name :: !(Nullable Text)
  }
  deriving stock (Eq, Show, Generic)

data SourceSummary = SourceSummary
  { repository :: !(Nullable Text)
  , revision :: !(Nullable Text)
  , run :: !(Nullable Text)
  }
  deriving stock (Eq, Show, Generic)

-- | One transaction: its review, final state (@converged@, @closed@,
-- @active@ or @stopped@), the scopes it changed, who applied it and where
-- the change came from.
data TransactionSummary = TransactionSummary
  { transaction :: !Text
  , review :: !Text
  , state :: !Text
  , admittedAt :: !Text
  , scopes :: ![Text]
  , actor :: !ActorSummary
  , source :: !(Nullable SourceSummary)
  }
  deriving stock (Eq, Show, Generic)

data TransactionHistory = TransactionHistory
  { contractVersion :: !ContractVersion
  , document :: !(DocumentName "transaction-history")
  , transactions :: ![TransactionSummary]
  }
  deriving stock (Eq, Show, Generic)

-- | What @deployer credentials@ issued (EP-248 D4): the bundle's files,
-- relative to its home, when the tokens expire and which key ids it holds,
-- and the earlier handles it retired. Never a secret.
data DeployerCredentials = DeployerCredentials
  { contractVersion :: !ContractVersion
  , document :: !(DocumentName "deployer-credentials")
  , deployer :: !Text
  , context :: !Text
  , home :: !Text
  , contextFile :: !Text
  , kubeconfig :: !Text
  , tokenExpiresAt :: !Text
  , builderKubeconfig :: !(Nullable Text)
  , builderTokenExpiresAt :: !(Nullable Text)
  , storeCredentials :: !(Nullable Text)
  , storeKeyId :: !(Nullable Text)
  , retired :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON DeployerCredentials where toJSON = genericToJSON recordOptions

instance FromJSON DeployerCredentials where parseJSON = genericParseJSON recordOptions

instance ToSchema DeployerCredentials where
  declareNamedSchema proxy =
    recordSchema proxy
      <&> schema
      . description
      ?~ "A delegated deployer's credential bundle: its files relative to the bundle home (run with HOME and XDG_CONFIG_HOME there), token expiries, key ids and the earlier credentials it retired. It names no secret."

instance ToJSON DelegationQuotaSummary where toJSON = genericToJSON recordOptions

instance FromJSON DelegationQuotaSummary where parseJSON = genericParseJSON recordOptions

instance ToSchema DelegationQuotaSummary where declareNamedSchema = recordSchema

instance ToJSON DelegationDocument where toJSON = genericToJSON recordOptions

instance FromJSON DelegationDocument where parseJSON = genericParseJSON recordOptions

instance ToSchema DelegationDocument where
  declareNamedSchema proxy =
    recordSchema proxy
      <&> schema
      . description
      ?~ "One accepted delegation: the namespaces, hostnames, kinds and image repository a named deployer may use."

instance ToJSON ActorSummary where toJSON = genericToJSON recordOptions

instance FromJSON ActorSummary where parseJSON = genericParseJSON recordOptions

instance ToSchema ActorSummary where declareNamedSchema = recordSchema

instance ToJSON SourceSummary where toJSON = genericToJSON recordOptions

instance FromJSON SourceSummary where parseJSON = genericParseJSON recordOptions

instance ToSchema SourceSummary where declareNamedSchema = recordSchema

instance ToJSON TransactionSummary where toJSON = genericToJSON recordOptions

instance FromJSON TransactionSummary where parseJSON = genericParseJSON recordOptions

instance ToSchema TransactionSummary where declareNamedSchema = recordSchema

instance ToJSON TransactionHistory where toJSON = genericToJSON recordOptions

instance FromJSON TransactionHistory where parseJSON = genericParseJSON recordOptions

instance ToSchema TransactionHistory where
  declareNamedSchema proxy =
    recordSchema proxy
      <&> schema
      . description
      ?~ "Transactions newest first, each bound to its published review, with the actor and source that review records."
