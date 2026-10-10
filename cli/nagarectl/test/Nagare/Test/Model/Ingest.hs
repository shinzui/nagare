-- | I3 through receipt ingestion: plan ingestion of a scheduled receipt as
-- `db backup-receipts` does, from the live source of the model's database.
module Nagare.Test.Model.Ingest
  ( ingestReceipt
  )
where

import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import InventoryTransactionSpec (fixtureBinding)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Backup (ScheduledBackupReceipt (..), ScheduledReceiptExpectation (..), scheduledReceiptExpectationFromCronJob)
import Nagare.Inventory.Digest
import Nagare.Inventory.Plan
import Nagare.Inventory.ScheduledIngest (ScheduledIngestRequest (..), compileScheduledIngestScope)
import Nagare.Inventory.ScheduledReceipt (ScheduledReceiptEvidence (..))
import Nagare.Inventory.Status qualified as Status
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Test.Model.Fixtures
import Nagare.Test.Model.Run
import Nagare.Test.World.Kubernetes

-- | I3: plan ingestion of a scheduled receipt from the live source, as `db
-- backup-receipts` plans it. A receipt whose source StatefulSet or PVC was
-- created outside review never compiles for ingestion. In a fault-free run the
-- receipt must compile, so the clause is never vacuous. A failed store read is
-- re-run, as an operator re-runs the command.
ingestReceipt :: Run -> Bool -> IO (Either Text ())
ingestReceipt run clean = do
  loaded <- asOperator run $ \store -> do
    history <- loadInventoryHistory store >>= orTrouble "load history"
    case Map.lookup databaseScopeId (historyAccepted history) of
      Nothing -> pure (Right Nothing)
      Just (revision, accepted) -> do
        let acceptedInventory = ok (composeSnapshot (ok (mkScopeSnapshot fixtureBinding (Map.map (\(revision', declared) -> (revisionGeneration revision', declared)) (historyAccepted history)) (historyReservations history))))
        -- As the command does: the accepted members' native bytes come from
        -- the store's review evidence, not from the compiler.
        native <- Status.loadAcceptedNativeSelected (Set.fromList [statefulId, pvcId, cronId, signingId]) store history acceptedInventory >>= orTrouble "load accepted native"
        pure (Right (Just (history, revision, accepted, fst native)))
  case loaded of
    Left refusal -> pure (refusedWhen refusal)
    Right Nothing -> pure (refusedWhen "the database is not accepted")
    Right (Just (history, revision, accepted, native)) -> do
      registry <- registryFor run plainShape "v1" "v1"
      observed <- observeWithRegistry registry (Map.singleton KubernetesExecutor [statefulId, pvcId, cronId, signingId])
      world <- readIORef (runWorld run)
      let live resource = case Map.lookup resource . observationMap =<< either (const Nothing) Just observed of
            Just (ObservedPresent physical) -> Just physical
            _ -> Nothing
      pure $ case traverse live [statefulId, pvcId, cronId, signingId] of
        Just [statefulUid, pvcUid, cronUid, signingUid] ->
          let request expectation =
                ScheduledIngestRequest
                  { ingestDatabase = "pg"
                  , ingestNamespace = "personal"
                  , ingestBackupId = "job-1"
                  , ingestSourceRevision = revision
                  , ingestStatefulUid = statefulUid
                  , ingestPvcUid = pvcUid
                  , ingestScheduleUid = cronUid
                  , ingestSigningUid = signingUid
                  , ingestEvidence =
                      ScheduledReceiptEvidence
                        { scheduledReceipt =
                            ScheduledBackupReceipt
                              (ok (mkPhysicalIdentity "job-1"))
                              (scheduledObjectPrefix expectation <> "job-1." <> scheduledFormat expectation)
                              (T.replicate 64 "0")
                              (scheduledPolicyRevision expectation)
                              Nothing
                        , scheduledObjectVersion = "1"
                        , scheduledReceiptVersion = "1"
                        , scheduledObjectLength = 1
                        , scheduledReceiptLength = 1
                        , scheduledReceiptDigest = contentDigest "receipt"
                        }
                  , ingestBackend = databaseBackend
                  , ingestSource = SourceLocation "model" "ingest"
                  , ingestAcceptedIncarnations = recorded
                  }
              recorded = headIncarnations (historyHead history)
              -- ADR 27 (F60): the record is the identity the provider returned
              -- for Nagare's own write, so every replacement must refuse.
              replaced = [physical | physical <- [statefulUid, pvcUid], Set.member physical (replacedUids world)]
              compiled =
                maybe (Left "the accepted CronJob lacks native evidence") Right (Map.lookup cronId native)
                  >>= \(_, cronBytes) ->
                    first (T.pack . show) (scheduledReceiptExpectationFromCronJob databaseBackend "personal" "pg" statefulUid pvcUid cronBytes)
                      >>= \expectation -> first (T.pack . show) (compileScheduledIngestScope (request expectation) accepted native)
           in case compiled of
                Right _
                  | not (null replaced) ->
                      Left ("I3: a scheduled receipt from " <> T.intercalate ", " (map physicalIdentityText replaced) <> ", created outside review, compiled for ingestion")
                Left refusal | clean -> Left ("I3: the fault-free scheduled receipt was refused: " <> refusal)
                _ -> Right ()
        _ -> refusedWhen "the receipt source is not observed present"
  where
    refusedWhen why
      | clean = Left ("I3: fault-free ingestion could not be planned: " <> why)
      | otherwise = Right ()
