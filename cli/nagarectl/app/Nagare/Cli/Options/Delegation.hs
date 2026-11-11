-- | Options / Delegation. Option records for the @delegation@ commands (EP-247); parsing-only.
module Nagare.Cli.Options.Delegation
  ( DelegationCommand (..)
  , DelegationCreateOpts (..)
  )
where

import Nagare.Dsl.Prelude

data DelegationCommand
  = DelegationCreate DelegationCreateOpts
  | DelegationRevoke String FilePath
  | -- | The deployer name and the contract version.
    DelegationShow String (Maybe Int)
  deriving stock (Generic, Show)

data DelegationCreateOpts = DelegationCreateOpts
  { name :: !String
  , namespaces :: ![String]
  , hostSuffixes :: ![String]
  , kinds :: ![String]
  , imageRepository :: !String
  , team :: !String
  , buildNamespace :: !(Maybe String)
  , quotaCpu :: !(Maybe String)
  , quotaMemory :: !(Maybe String)
  , quotaPods :: !(Maybe Int)
  , savePlan :: !FilePath
  }
  deriving stock (Generic, Show)
