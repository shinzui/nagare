-- | Store failures as sanitized problems. The detail never carries provider
-- error text, tokens or private object contents.
module Nagare.Api.Server.Problems
  ( storeProblem
  )
where

import Data.Text qualified as Text
import Nagare.Contract.Prelude
import Nagare.Contract.Problem (ProblemDetails, internalError, problemFor, storeCredentialsUnavailable, storeInvalid, storeUnavailable)
import Nagare.Inventory.Store (StoreError (..))

-- | An unreadable store may answer later; a store whose objects fail their
-- checks, or that belongs to another context, will not.
storeProblem :: StoreError -> ProblemDetails
storeProblem = \case
  StoreIoError _ -> problemFor storeUnavailable "the inventory store could not be read"
  StoreBusy -> problemFor storeUnavailable "the inventory store is busy"
  StoreInvalidObject key reason -> problemFor storeInvalid ("inventory object " <> Text.pack key <> " is invalid: " <> reason)
  StoreInvalidPath key -> problemFor storeInvalid ("inventory object path " <> Text.pack key <> " is invalid")
  StoreConditionFailed reason -> problemFor storeInvalid reason
  StoreObjectConflict _ -> problemFor internalError "the inventory store reported a write conflict to a reader"
  StoreReentry -> problemFor internalError "the inventory store was re-entered"
  StoreCredentialsUnavailable _ -> problemFor storeCredentialsUnavailable "the admin API's store credential is unavailable"
