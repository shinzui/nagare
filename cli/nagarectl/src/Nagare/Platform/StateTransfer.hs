{-# LANGUAGE OverloadedStrings #-}

-- | The cutover-facing portion of a rehearsed state-transfer plan.
--
-- ExecPlan 126 owns inventory and concrete adapters.  This module deliberately
-- contains only the fail-closed contract required by the deadline executor.
module Nagare.Platform.StateTransfer
  ( StateTransferItem (..)
  , StateTransferPlan (..)
  , FinalStateEvidence (..)
  , validateStateTransferPlan
  )
where

import Data.Aeson qualified as Aeson
import Data.Text (Text)
import GHC.Generics (Generic)
import Nagare.Dsl.Prelude
import Numeric.Natural (Natural)

data StateTransferItem = StateTransferItem
  { stateItemId :: !Text
  , stateItemPredictedSeconds :: !Natural
  , stateItemSupported :: !Bool
  , stateItemQuiesceContract :: !Bool
  }
  deriving stock (Eq, Show, Generic)

data StateTransferPlan = StateTransferPlan
  { stateTransferItems :: ![StateTransferItem]
  , stateTransferPredictedSeconds :: !Natural
  , stateTransferDriftToken :: !Text
  }
  deriving stock (Eq, Show, Generic)

data FinalStateEvidence = FinalStateEvidence
  { finalStateCommitTokens :: ![Text]
  , finalStateObservedSeconds :: !Natural
  , finalStateVerified :: !Bool
  }
  deriving stock (Eq, Show, Generic)

validateStateTransferPlan :: StateTransferPlan -> Either Text ()
validateStateTransferPlan plan
  | null (stateTransferItems plan) = Left "state-transfer plan has no complete inventory"
  | any (not . stateItemSupported) (stateTransferItems plan) = Left "state-transfer plan contains an unsupported retained item"
  | any (not . stateItemQuiesceContract) (stateTransferItems plan) = Left "state-transfer plan contains an item without a quiesce contract"
  | stateTransferPredictedSeconds plan /= sum (map stateItemPredictedSeconds (stateTransferItems plan)) = Left "state-transfer aggregate prediction does not match its items"
  | otherwise = Right ()

instance Aeson.ToJSON StateTransferItem where toJSON = Aeson.genericToJSON Aeson.defaultOptions
instance Aeson.FromJSON StateTransferItem where parseJSON = Aeson.genericParseJSON Aeson.defaultOptions
instance Aeson.ToJSON StateTransferPlan where toJSON = Aeson.genericToJSON Aeson.defaultOptions
instance Aeson.FromJSON StateTransferPlan where parseJSON = Aeson.genericParseJSON Aeson.defaultOptions
instance Aeson.ToJSON FinalStateEvidence where toJSON = Aeson.genericToJSON Aeson.defaultOptions
instance Aeson.FromJSON FinalStateEvidence where parseJSON = Aeson.genericParseJSON Aeson.defaultOptions
