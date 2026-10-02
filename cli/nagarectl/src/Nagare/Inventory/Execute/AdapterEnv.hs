{-# LANGUAGE RankNTypes #-}
{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | AdapterEnv responsibilities; internal implementation behind Nagare.Inventory.Execute.
module Nagare.Inventory.Execute.AdapterEnv
  ( withAdapterEnv
  )
where

import Control.Exception (bracket)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
  ( PlannedOperation (plannedExecutor)
  )
import Nagare.Inventory.Journal
  ( TransactionId
  , transactionIdText
  )
import Nagare.Resource.Inventory (Executor (..))
import System.Environment (lookupEnv, setEnv, unsetEnv)

withAdapterEnv :: TransactionId -> PlannedOperation -> IO a -> IO a
withAdapterEnv transaction operation action = do
  previousTransaction <- lookupEnv transactionVariable
  previousChild <- lookupEnv childVariable
  let restore = do
        restoreVariable transactionVariable previousTransaction
        restoreVariable childVariable previousChild
  bracket install (const restore) (const action)
  where
    transactionVariable = "NAGARE_INVENTORY_TRANSACTION"
    childVariable = "NAGARE_INVENTORY_ADAPTER_CHILD"
    install = do
      setEnv transactionVariable (T.unpack (transactionIdText transaction))
      setEnv childVariable (executorChild (plannedExecutor operation))
    restoreVariable variable Nothing = unsetEnv variable
    restoreVariable variable (Just value) = setEnv variable value
    executorChild executor = case executor of
      KubernetesExecutor -> "kubernetes"
      PulumiExecutor -> "pulumi"
      CloudFoundationExecutor -> "cloud-foundation"
      HostExecutor -> "host"
      ArtifactExecutor -> "artifact"
      CacheExecutor -> "cache"
      BrokerExecutor -> "broker"
      HelmExecutor -> "helm"
      CdnExecutor -> "cdn"
      AccessExecutor -> "access"
