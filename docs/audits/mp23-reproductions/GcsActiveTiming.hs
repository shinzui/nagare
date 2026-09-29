{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

-- Complete production transaction driver; Kubernetes observations are synthetic.
-- The public CLI is covered separately by test-inventory-active-command-cost.py.
module Main (main) where

import Control.Lens ((^.))
import Control.Monad (unless)
import Data.Aeson (Value, eitherDecodeStrict', encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as LBS
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import GHC.Clock (getMonotonicTimeNSec)
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute qualified as E
import Nagare.Inventory.Journal
import Nagare.Inventory.Plan
import Nagare.Inventory.Status
import Nagare.Inventory.Store
import Nagare.Inventory.Store.ObjectOps
import Nagare.Inventory.Store.Remote (remoteObjectOps)
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import System.Environment (getArgs)

must :: (Show e) => IO (Either e a) -> IO a
must action = action >>= either (fail . show) pure

main :: IO ()
main = do
  [fixture, url, cache, traceFile] <- getArgs
  -- Bind the synthetic observer from the checked local fixture before measuring.
  local <- must (openFilesystemStoreReadOnly fixture)
  history <- must (loadInventoryHistory local)
  let headValue = historyHead history
      binding = headBinding headValue
      tx = either (error . show) id (mkTransactionId (maybe (error "inactive fixture") id (headActiveTransaction headValue)))
      inventory = either (error . show) id $ do
        snapshot <-
          mkScopeSnapshot
            binding
            (Map.map (\(r, s) -> (revisionGeneration r, s)) (historyAccepted history))
            (historyReservations history)
        composeSnapshot snapshot
  (native, _) <- must (loadAcceptedNative local history inventory)
  observations <- newIORef (0 :: Int)
  let registry =
        either (error . show) id $
          mkAdapterRegistry
            [ mkKubernetesAdapter
                native
                KubernetesAdapterOps
                  { kubernetesContext = binding ^. #identity
                  , kubernetesObserve = \r -> do
                      modifyIORef' observations (+ 1)
                      let (_, bytes) = native Map.! r
                          uid = either (error . show) id (mkPhysicalIdentity "ingestion-uid")
                      pure (KubernetesPresent uid "7" (Just r) (contentDigest bytes))
                  , kubernetesMutateConditional = \_ -> fail "native effects forbidden in cost probe"
                  }
            ]
  started <- getMonotonicTimeNSec
  raw <- must (remoteObjectOps (nameText (binding ^. #project)) (T.pack url))
  ready <- getMonotonicTimeNSec
  calls <- newIORef []
  let seconds a b = fromIntegral (b - a) / 1e9 :: Double
      timed method (ObjectName key) extra action = do
        start <- getMonotonicTimeNSec
        value <- action
        end <- getMonotonicTimeNSec
        let row =
              object
                ( [ "method" .= (method :: T.Text)
                  , "key" .= key
                  , "seconds" .= seconds start end
                  ]
                    <> extra value
                )
        LBS.appendFile traceFile (encode row <> "\n")
        modifyIORef' calls (row :)
        pure value
      ops =
        raw
          { getObject = \key -> timed "get" key (const []) (getObject raw key)
          , getObjects = \key -> timed "batch" key (const []) (getObjects raw key)
          , listObjects = \key -> timed "list" key (const []) (listObjects raw key)
          , putObject = \condition key@(ObjectName name) bytes -> do
              unless
                (name == "head.json" || "journal/" `T.isPrefixOf` name)
                (fail "unexpected publication target")
              timed
                "put"
                key
                ( \outcome ->
                    [ "condition" .= show condition
                    , "outcome" .= show outcome
                    , "publication" .= (either (error . show) id (eitherDecodeStrict' bytes) :: Value)
                    ]
                )
                (putObject raw condition key bytes)
          }
  store <- must (openObjectStoreReadOnly ops binding "prune-spike" (Just cache))
  opened <- getMonotonicTimeNSec
  result <- must (E.resumeTransaction store registry tx)
  done <- getMonotonicTimeNSec
  unless (result == E.Converged tx) (fail (show result))
  final <- must (readHead store) >>= maybe (fail "missing final head") pure
  unless
    ( headActiveTransaction final == Nothing
        && headExecutorClaim final == Nothing
        && headAccepted final == headConverged final
        && headSequence final > headSequence headValue
    )
    (fail "finalization invariant failed")
  rows <- reverse <$> readIORef calls
  count <- readIORef observations
  LBS.putStrLn $
    encode $
      object
        [ "setupSeconds" .= seconds started ready
        , "openSeconds" .= seconds ready opened
        , "driverSeconds" .= seconds opened done
        , "totalSeconds" .= seconds started done
        , "result" .= show result
        , "syntheticProviderObservations" .= count
        , "finalHead" .= final
        , "calls" .= rows
        ]
