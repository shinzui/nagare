module Main where

import Prelude
import Control.Exception (IOException, try)
import Control.Monad
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import InventoryTransactionSpec (preparedFixtureWith, recordingRegistryWith)
import Nagare.Inventory.Adapter
import Nagare.Inventory.Command qualified as Command
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute
import Nagare.Inventory.Journal
import Nagare.Inventory.Store qualified as Store
import Nagare.Resource.Types
import Nagare.Target

ok :: Show e => Either e a -> a
ok = either (error . show) id

main = do
  let target = ActiveTarget (ok (mkContextName "context-1"))
        (profileFromContextMap (Map.fromList [("CLOUDSDK_CORE_PROJECT", "project"), ("NAGARE_MODE", "local")]))
  store <- Command.openTargetStore target
  effects <- newIORef (0 :: Int)
  recoveries <- newIORef (0 :: Int)
  preflights <- newIORef (0 :: Int)
  let effect _ _ = modifyIORef' effects (+1) >> pure (AdapterEffectAmbiguous "acknowledgement lost after effect")
      recover operation _ = do
        modifyIORef' recoveries (+1)
        pure (RecoveryProvedComplete (contentDigest (TE.encodeUtf8 (operationIdText (plannedOperationId operation)))))
      preflight _ _ = do
        modifyIORef' preflights (+1)
        occurred <- (> 0) <$> readIORef effects
        pure (if occurred then Left "pre-effect condition is now false" else Right ())
  (reviewed, _) <- preparedFixtureWith store effect recover
  let registry = recordingRegistryWith preflight effect recover
  stopped <- ok <$> applyReviewed store registry reviewed
  tx <- case stopped of
    StoppedAmbiguous value _ -> pure value
    other -> error (show other)
  initial <- Store.readHead store
  writeIORef preflights 0
  let factoryWithOldCondition _ = do
        occurred <- (> 0) <$> readIORef effects
        when occurred (ioError (userError "factory requires pre-effect condition"))
        pure registry
  blocked <- try (Command.resumeInventoryWithFactory factoryWithOldCondition target (transactionIdText tx) True)
    :: IO (Either IOException ())
  afterBlocked <- Store.readHead store
  print ("factory-check", either (const "blocked") (const "unexpected success") blocked, initial == afterBlocked)
  (,,) <$> readIORef effects <*> readIORef recoveries <*> readIORef preflights >>= print
  Command.resumeInventoryWithFactory (const (pure registry)) target (transactionIdText tx) True
  print ("adapter-check", "same transaction converged")
  (,,) <$> readIORef effects <*> readIORef recoveries <*> readIORef preflights >>= print
  Command.resumeInventoryWithFactory (\_ -> error "converged resume constructed a registry") target (transactionIdText tx) True
  print ("converged-command", "registry bypassed")
