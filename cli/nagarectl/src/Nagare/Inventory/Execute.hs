{-# LANGUAGE RankNTypes #-}

-- | Lock-scoped admission, execution, and recovery of reviewed plans.
module Nagare.Inventory.Execute
  ( AdmissionError (..)
  , ExecutablePlan
  , TransactionResult (..)
  , withProcessLock
  , admit
  , execute
  , applyReviewed
  , resumeTransaction
  , resumeTransactionWithTakeover
  , OperatorRecoveryInput (..)
  , RecoveryAction (..)
  , decodeOperatorRecoveryInput
  , recordOperatorRecovery
  , prepareBootstrapRegistryRecovery
  )
where

import Nagare.Dsl.Prelude
import Nagare.Inventory.Execute.Admission (admit)
import Nagare.Inventory.Execute.Recovery
  ( prepareBootstrapRegistryRecovery
  , recordOperatorRecovery
  )
import Nagare.Inventory.Execute.Transaction
  ( applyReviewed
  , execute
  , resumeTransaction
  , resumeTransactionWithTakeover
  )
import Nagare.Inventory.Execute.Types
  ( AdmissionError (..)
  , ExecutablePlan (..)
  , OperatorRecoveryInput (..)
  , RecoveryAction (..)
  , TransactionResult (..)
  , decodeOperatorRecoveryInput
  )
import Nagare.Inventory.Store (withProcessLock)
