-- | EP-173 M2: the reviewed PostgreSQL rename under the recovery model's
-- adversary. The migration adapter reaches Kubernetes only through `kubectl`,
-- so the rename runs in its own modelled API server
-- ('InventoryPostgresRenameSpec'), with one fault at each write it issues. For
-- every schedule, status never reports a renamed member as replaced (I3), the
-- stopped transaction has a supported exit (I1), the data survives, and the
-- transfer copy runs once (I4).
module InventoryRenameRecoveryModelSpec (inventoryRenameRecoveryModelTests) where

import Control.Exception (SomeException, displayException, throwIO, try)
import Control.Monad (forM)
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text qualified as T
import InventoryPostgresRenameSpec
  ( RenameWorld
  , databaseOwner
  , destinationCopies
  , newScope
  , plannedRenameThrough
  , recordOldIncarnations
  , renameVolumes
  , replacedMembers
  , transferJobs
  , verifyRenamedWorld
  )
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (AdapterRegistry)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute
import Nagare.Inventory.Journal
import Nagare.Inventory.KubernetesTransport (KubectlRequest, KubectlResult)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Wire (encodeCanonicalScope)
import Nagare.Test.World.Adversary (Interrupted (..))
import System.Exit (ExitCode (..))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

inventoryRenameRecoveryModelTests :: TestTree
inventoryRenameRecoveryModelTests =
  testGroup
    "rename recovery model"
    [ testCase "every single fault at every rename write has an exit and keeps the data (F52)" $ do
        clean <- runRename Nothing
        writes <- either (assertFailure . T.unpack . ("the fault-free rename violates the model: " <>)) pure clean
        assertBool "the rename issues writes" (writes > 0)
        violations <-
          fmap concat . forM [(boundary, fault) | boundary <- [1 .. writes], fault <- [minBound .. maxBound]] $ \schedule ->
            either (: []) (const []) <$> runRename (Just schedule)
        case violations of
          [] -> pure ()
          _ -> assertFailure (T.unpack (T.intercalate "\n\n" (take 5 violations)) <> "\n\n" <> show (length violations) <> " violation(s)")
    ]

-- | A fault at one write (`create`, `patch` or `delete`) of the rename.
data RenameFault
  = -- | The API server refuses the write before any effect.
    RefusedWrite
  | -- | The write lands and its acknowledgement is lost.
    LostAcknowledgement
  | -- | The executor dies right after the write lands.
    InterruptedAfterWrite
  deriving stock (Eq, Show, Enum, Bounded)

-- | Count writes and fire the scheduled fault at its write.
adversary :: IORef [Text] -> Maybe (Int, RenameFault) -> (KubectlRequest -> IO KubectlResult) -> KubectlRequest -> IO KubectlResult
adversary written schedule next request
  | writes (request ^. #arguments) = do
      count <- atomicModifyIORef' written (\seen -> (seen <> [T.pack (unwords (take 3 (request ^. #arguments)))], length seen + 1))
      case schedule of
        Just (boundary, fault)
          | boundary == count -> case fault of
              RefusedWrite -> pure (Right (ExitFailure 1, "", "injected: the API server refused the write"))
              LostAcknowledgement -> next request >> pure (Right (ExitFailure 1, "", "injected: unable to connect to the server: EOF"))
              InterruptedAfterWrite -> next request >> throwIO Interrupted
        _ -> next request
  | otherwise = next request
  where
    writes arguments = case arguments of
      verb : _ -> verb `elem` ["create", "patch", "delete", "apply", "replace", "scale"]
      [] -> False

-- | Run the rename under one schedule. 'Right' carries the number of writes.
runRename :: Maybe (Int, RenameFault) -> IO (Either Text Int)
runRename schedule = withSystemTempDirectory "rename-model" $ \root -> do
  written <- newIORef []
  probe <- newIORef Nothing
  (store, world, reviewed, registry) <- plannedRenameThrough recordOldIncarnations (adversary written schedule) probe root
  applied <- try @SomeException (applyReviewed store registry reviewed)
  seen <- readIORef written
  let faulted = maybe "" (\(boundary, _) -> " at `kubectl " <> fromMaybe "?" (listToMaybe (drop (boundary - 1) seen)) <> "`") schedule
      explain violation = "faults: " <> T.pack (show schedule) <> faulted <> "\nviolation: " <> violation
  outcome <- case applied of
    Right (Right (Converged _)) -> pure (Right ())
    Right (Left errors) -> pure (Left ("admission refused: " <> T.pack (show (NE.toList errors))))
    _ -> recover store world registry reviewed
  case outcome of
    Left violation -> pure (Left (explain violation))
    Right () -> do
      final <- finalChecks store world
      count <- length <$> readIORef written
      pure (either (Left . explain) (const (Right count)) final)

-- | After a stop: I3 at the stop, then the supported exits. Resume first (a
-- transient fault clears); if the transaction is still active, each recovery
-- decision for each open operation, then resume again.
recover :: InventoryStore -> RenameWorld -> AdapterRegistry -> ReviewedPlan -> IO (Either Text ())
recover store world registry reviewed = do
  stale <- replacedMembers store world
  if not (null stale)
    then pure (Left ("I3: status reports renamed members as replaced while stopped: " <> T.pack (show stale)))
    else resumeUpTo (3 :: Int)
  where
    resumeUpTo attempts = do
      active <- activeTransaction store
      case active of
        Nothing -> pure (Right ())
        Just transaction
          | attempts == 0 -> decide transaction
          | otherwise -> do
              _ <- try @SomeException (resumeTransaction store registry transaction)
              stale <- replacedMembers store world
              if null stale
                then resumeUpTo (attempts - 1)
                else pure (Left ("I3: status reports renamed members as replaced after resume: " <> T.pack (show stale)))
    decide transaction = do
      open <- openOperations store transaction
      tried <- forM [(operation, action) | operation <- open, action <- recoveryActions] $ \(operation, action) -> do
        stillActive <- activeTransaction store
        case stillActive of
          Nothing -> pure True
          Just _ -> do
            recorded <-
              try @SomeException
                ( recordOperatorRecovery
                    store
                    registry
                    (OperatorRecoveryInput transaction operation (contentDigest (encodeReviewDocument (reviewedDocument reviewed))) action)
                    False
                )
            case recorded of
              Right (Right _) -> do
                _ <- try @SomeException (resumeTransaction store registry transaction)
                isNothing <$> activeTransaction store
              _ -> pure False
      done <- isNothing <$> activeTransaction store
      pure $
        if or tried || done
          then Right ()
          else Left ("I1: the rename stopped with no supported exit; open operations " <> T.pack (show (map operationIdText open)))

-- | At an idle head: status reports nothing replaced (I3); a renamed database
-- has every reviewed effect and copied its data exactly once (I4); an
-- unrenamed one still holds its data.
finalChecks :: InventoryStore -> RenameWorld -> IO (Either Text ())
finalChecks store world = do
  stale <- replacedMembers store world
  history <- loadInventoryHistory store
  final <- readIORef world
  let renamed = case history of
        Right loaded -> (revisionDigest . fst <$> Map.lookup databaseOwner (historyAccepted loaded)) == Just (contentDigest (encodeCanonicalScope newScope))
        Left _ -> False
  checked <-
    if renamed
      then either (Left . T.pack . displayException) Right <$> try @SomeException (verifyRenamedWorld final)
      else pure (Right ())
  pure (verdict stale checked renamed final)
  where
    verdict stale checked renamed final
      | not (null stale) = Left ("I3: status reports renamed members as replaced at the end: " <> T.pack (show stale))
      | Left reason <- checked = Left ("the renamed database is incomplete: " <> reason)
      | renamed && destinationCopies final /= 1 = Left ("I4: the destination volume was written " <> T.pack (show (destinationCopies final)) <> " times (transfer Jobs " <> T.pack (show (transferJobs final)) <> ")")
      | Map.lookup "nagare-db-pg-old-data" (renameVolumes final) /= Just "pgdata:known-row-1" = Left "the source volume lost its data"
      | otherwise = Right ()

activeTransaction :: InventoryStore -> IO (Maybe TransactionId)
activeTransaction store = do
  current <- readHead store
  pure $ case current of
    Right (Just value) -> headActiveTransaction value >>= either (const Nothing) Just . mkTransactionId
    _ -> Nothing

-- | Operations of the transaction without a completion, from the journal.
openOperations :: InventoryStore -> TransactionId -> IO [OperationId]
openOperations store transaction = do
  current <- readHead store
  raw <- case current of
    Right (Just value) -> either (const []) id <$> readJournalPrefix store (headSequence value)
    _ -> pure []
  let events = [event | Right event <- map decodeJournalEvent raw, eventTransaction event == transaction]
  pure
    [ operation
    | (operation, state) <- Map.toList (operationStates transaction events)
    , case state of
        Completed _ -> False
        _ -> True
    ]

-- | The operator's recovery decisions, as the recovery model tries them.
recoveryActions :: [RecoveryAction]
recoveryActions =
  [ AcceptAdapterProof
  , RetryAfterAdapterProof
  , ContinueFencedOperation
  , VerifyFencedEffect
  , RecoverFencedBackup
  , ForwardFencedRelease
  , AbandonPartialPrune
  , AbandonPartialVolumeRestore
  , AbandonPartialDatabaseRestore
  , StopIncompleteApplication
  , AbandonRefusedOperation
  ]
