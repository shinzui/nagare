{-# LANGUAGE RankNTypes #-}

-- | AdapterEnv responsibilities; internal implementation behind Nagare.Inventory.Execute.
module Nagare.Inventory.Execute.AdapterEnv
  ( withAdapterEnv
  )
where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar)
import Control.Exception (bracket_)
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
import System.IO.Unsafe (unsafePerformIO)

-- | How many adapter calls are inside the variables, and what they replaced.
-- The environment is the process's; EP-228 M2 lets several effects of one
-- transaction and executor run at once, so the first installs the variables
-- and the last restores them.
installed :: MVar (Int, (Maybe String, Maybe String))
installed = unsafePerformIO (newMVar (0, (Nothing, Nothing)))
{-# NOINLINE installed #-}

withAdapterEnv :: TransactionId -> PlannedOperation -> IO a -> IO a
withAdapterEnv transaction operation = bracket_ install restore
  where
    transactionVariable = "NAGARE_INVENTORY_TRANSACTION"
    childVariable = "NAGARE_INVENTORY_ADAPTER_CHILD"
    install = modifyMVar_ installed $ \(count, saved) ->
      if count > 0
        then pure (count + 1, saved)
        else do
          previous <- (,) <$> lookupEnv transactionVariable <*> lookupEnv childVariable
          setEnv transactionVariable (T.unpack (transactionIdText transaction))
          setEnv childVariable (executorChild (plannedExecutor operation))
          pure (1, previous)
    restore = modifyMVar_ installed $ \(count, saved@(previousTransaction, previousChild)) ->
      if count > 1
        then pure (count - 1, saved)
        else do
          restoreVariable transactionVariable previousTransaction
          restoreVariable childVariable previousChild
          pure (0, (Nothing, Nothing))
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
      AppDatabaseExecutor -> "app-database"
