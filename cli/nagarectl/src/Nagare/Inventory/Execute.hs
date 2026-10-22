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
  , applyReviewedWithHistory
  , resumeTransaction
  , resumeTransactionWithTakeover
  , OperatorRecoveryInput (..)
  , RecoveryAction (..)
  , decodeOperatorRecoveryInput
  , recordOperatorRecovery
  , prepareBootstrapRegistryRecovery
  , settleReviewedOperation
  , CloseInput (..)
  , closeTransaction
  , reverifiedScopes
  , AbandonInput (..)
  , MigrationExit (..)
  , abandonMigration
  , Attestation (..)
  , AttestedEvidence (..)
  , CloseRecord (..)
  , OperationClass (..)
  , ScopeDisposition (..)
  , decodeAttestation
  , renderCloseRecord
  )
where

import Nagare.Dsl.Prelude
import Nagare.Inventory.Execute.Abandon (AbandonInput (..), MigrationExit (..), abandonMigration)
import Nagare.Inventory.Execute.Admission (admit)
import Nagare.Inventory.Execute.Claims (reverifiedScopes)
import Nagare.Inventory.Execute.Close (CloseInput (..), closeTransaction)
import Nagare.Inventory.Execute.Recovery
  ( prepareBootstrapRegistryRecovery
  , recordOperatorRecovery
  )
import Nagare.Inventory.Execute.Settle (settleReviewedOperation)
import Nagare.Inventory.Execute.Transaction
  ( applyReviewed
  , applyReviewedWithHistory
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
import Nagare.Inventory.Plan.CloseRecord (Attestation (..), AttestedEvidence (..), CloseRecord (..), OperationClass (..), ScopeDisposition (..), decodeAttestation, renderCloseRecord)
import Nagare.Inventory.Store (withProcessLock)
