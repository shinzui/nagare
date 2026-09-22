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
  )
where

import Control.Exception (bracket)
import Control.Monad (foldM, forM)
import Data.Either (isRight)
import Data.List (find, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Types
import System.Environment (lookupEnv, setEnv, unsetEnv)

data AdmissionError = AdmissionError
  { admissionErrorCode :: !Text
  , admissionErrorMessage :: !Text
  }
  deriving stock (Eq, Show, Generic)

data ExecutablePlan s = ExecutablePlan
  { executableTransaction :: !TransactionId
  , executableReviewed :: !ReviewedPlan
  }

data TransactionResult
  = Converged !TransactionId
  | PausedAtBarrier !TransactionId !(NonEmpty ReviewBarrier)
  | StoppedFailed !TransactionId !OperationId !FailureClass
  | StoppedAmbiguous !TransactionId !OperationId
  deriving stock (Eq, Show, Generic)

admit :: LockedStore s -> AdapterRegistry -> ReviewedPlan -> IO (Either (NonEmpty AdmissionError) (ExecutablePlan s))
admit locked registry reviewed = do
  let store = lockedStore locked
      document = reviewedDocument reviewed
      transaction = transactionFor document
  headResult <- readHead store
  case headResult of
    Left err -> pure (failure "store" (showText err))
    Right Nothing -> pure (failure "store" "inventory store is not initialized")
    Right (Just headValue) -> do
      preflightErrors <- preflightOperations registry reviewed Map.empty
      let errors =
            [AdmissionError "context-binding" "review belongs to a different context or provider target" | reviewContextBinding document /= headBinding headValue]
              <> [AdmissionError "stale-head" "review was issued against a different head generation or journal sequence" | reviewHeadGeneration document /= headGeneration headValue || reviewHeadSequence document /= headSequence headValue]
              <> [AdmissionError "stale-base" "review base revisions differ from accepted desired state" | reviewBaseRevisions document /= headAccepted headValue]
              <> [AdmissionError "active-transaction" "another transaction is unresolved" | isJust (headActiveTransaction headValue)]
              <> preflightErrors
      case errors of
        firstError : rest -> pure (Left (firstError :| rest))
        [] -> do
          now <- timestamp
          let claim = ExecutorClaim (transactionIdText transaction) (headClientIdentity headValue) 1 now
              activated =
                headValue
                  { headGeneration = headGeneration headValue + 1
                  , headAccepted = reviewDesiredRevisions document
                  , headActiveTransaction = Just (transactionIdText transaction)
                  , headExecutorClaim = Just claim
                  }
          activation <- replaceHeadIfGenerationMatches store (Just (headGeneration headValue)) activated
          case activation of
            Left err -> pure (failure "head-condition" (showText err))
            Right () -> do
              event <- appendEvent locked transaction Nothing Pending ("admitted review " <> digestText (reviewDocumentDigest document))
              pure $ case event of
                Left err -> failure "journal" (showText err)
                Right _ -> Right (ExecutablePlan transaction reviewed)

execute :: LockedStore s -> AdapterRegistry -> ExecutablePlan s -> IO TransactionResult
execute locked registry executable = do
  let transaction = executableTransaction executable
      reviewed = executableReviewed executable
      document = reviewedDocument reviewed
  if not (null (reviewBarriers document))
    then do
      let barriers = NE.fromList (reviewBarriers document)
      _ <- appendEvent locked transaction Nothing Pending "paused at review barrier"
      _ <- releaseClaim locked transaction False
      pure (PausedAtBarrier transaction barriers)
    else do
      eventsResult <- readJournal locked
      case eventsResult of
        Left _ -> ambiguousFallback transaction document
        Right events -> do
          outcome <- runOperations locked registry transaction reviewed events (reviewOperations document)
          case outcome of
            Just result -> releaseClaim locked transaction False >> pure result
            Nothing -> do
              completed <- appendEvent locked transaction Nothing (Completed (reviewDocumentDigest document)) "transaction converged"
              case completed of
                Left _ -> ambiguousFallback transaction document
                Right _ -> do
                  converged <- releaseClaim locked transaction True
                  pure $ if converged then Converged transaction else fallbackResult transaction document

applyReviewed :: InventoryStore -> AdapterRegistry -> ReviewedPlan -> IO (Either (NonEmpty AdmissionError) TransactionResult)
applyReviewed store registry reviewed = do
  locked <- withProcessLock store $ \lock -> do
    admitted <- admit lock registry reviewed
    case admitted of
      Left errors -> pure (Left errors)
      Right executable -> Right <$> execute lock registry executable
  pure $ case locked of
    Left err -> failure "process-lock" (showText err)
    Right result -> result

resumeTransaction :: InventoryStore -> AdapterRegistry -> TransactionId -> IO (Either (NonEmpty AdmissionError) TransactionResult)
resumeTransaction store registry transaction = do
  locked <- withProcessLock store $ \lock -> resumeLocked lock
  pure $ case locked of
    Left err -> failure "process-lock" (showText err)
    Right result -> result
  where
    resumeLocked :: forall s. LockedStore s -> IO (Either (NonEmpty AdmissionError) TransactionResult)
    resumeLocked lock = do
      let digestToken = T.drop 3 (transactionIdText transaction)
      case mkContentDigest digestToken of
        Left err -> pure (failure "transaction-id" err)
        Right digest -> do
          headResult <- readHead store
          eventsResult <- readJournal lock
          case (headResult, eventsResult) of
            (Left err, _) -> pure (failure "store" (showText err))
            (_, Left err) -> pure (failure "journal" (showText err))
            (Right Nothing, _) -> pure (failure "store" "inventory store is not initialized")
            (Right (Just headValue), Right events)
              | headActiveTransaction headValue /= Just (transactionIdText transaction) ->
                  if transactionConverged transaction events
                    then pure (Right (Converged transaction))
                    else pure (failure "inactive-transaction" "transaction is not active in the store head")
              | otherwise -> do
                  claimed <- acquireResumeClaim store transaction headValue
                  case claimed of
                    Left err -> pure (Left err)
                    Right () -> do
                      bundleResult <- loadPublishedReview store digest
                      snapshotResult <- readStoreSnapshot store
                      case (bundleResult, snapshotResult) of
                        (Left err, _) -> pure (failure "review" (showText err))
                        (_, Left err) -> pure (failure "store" (showText err))
                        (Right bundle, Right snapshot) -> case verifyActiveReview snapshot (transactionIdText transaction) bundle of
                          Left errors -> pure (Left (fmap reviewAdmission errors))
                          Right reviewed -> do
                            preflightErrors <- preflightOperations registry reviewed (completedOperations transaction events)
                            case preflightErrors of
                              firstError : rest -> releaseClaim lock transaction False >> pure (Left (firstError :| rest))
                              [] -> Right <$> execute lock registry (ExecutablePlan transaction reviewed)

runOperations :: LockedStore s -> AdapterRegistry -> TransactionId -> ReviewedPlan -> [JournalEvent] -> [ReviewOperation] -> IO (Maybe TransactionResult)
runOperations locked registry transaction reviewed initialEvents operations = go initialEvents ordered
  where
    ordered = topological operations
    go _ [] = pure Nothing
    go events (reviewOperation : rest) = do
      let operation = reviewPlannedOperation reviewOperation
          operationId = plannedOperationId operation
          states = operationStates transaction events
      case Map.lookup operationId states of
        Just (Completed _) -> go events rest
        Just Ambiguous -> recoverOrStop events reviewOperation rest
        Just (Failed (PartialOrUnknown _)) -> recoverOrStop events reviewOperation rest
        Just IntentRecorded -> recoverOrStop events reviewOperation rest
        _ -> executeOne events reviewOperation rest
    recoverOrStop events reviewOperation rest =
      case preparedFor reviewed reviewOperation of
        Left _ -> pure (Just (StoppedAmbiguous transaction (plannedOperationId (reviewPlannedOperation reviewOperation))))
        Right prepared -> case lookupAdapter registry (plannedExecutor (reviewPlannedOperation reviewOperation)) of
          Left _ -> pure (Just (StoppedAmbiguous transaction (plannedOperationId (reviewPlannedOperation reviewOperation))))
          Right adapter -> do
            decision <- withTransactionEnv transaction (adapterRecover adapter (reviewPlannedOperation reviewOperation) prepared)
            case decision of
              RecoveryProvedComplete proof -> do
                appended <- appendEvent locked transaction (Just (plannedOperationId (reviewPlannedOperation reviewOperation))) (Completed proof) "adapter recovery proved completion"
                case appended of Left _ -> pure (Just (StoppedAmbiguous transaction (plannedOperationId (reviewPlannedOperation reviewOperation)))); Right event -> go (events <> [event]) rest
              RecoverySafeToRetry -> executeOne events reviewOperation rest
              RecoveryUnresolved _ -> pure (Just (StoppedAmbiguous transaction (plannedOperationId (reviewPlannedOperation reviewOperation))))
    executeOne events reviewOperation rest = do
      let operation = reviewPlannedOperation reviewOperation
          operationId = plannedOperationId operation
      case (lookupAdapter registry (plannedExecutor operation), preparedFor reviewed reviewOperation) of
        (Left _, _) -> pure (Just (StoppedAmbiguous transaction operationId))
        (_, Left _) -> pure (Just (StoppedAmbiguous transaction operationId))
        (Right adapter, Right prepared) -> do
          preflight <- adapterPreflight adapter operation prepared
          case preflight of
            Left _ -> pure (Just (StoppedFailed transaction operationId (KnownNoEffect "adapter preflight refused")))
            Right () -> do
              intent <- appendEvent locked transaction (Just operationId) IntentRecorded "operation intent recorded"
              case intent of
                Left _ -> pure (Just (StoppedAmbiguous transaction operationId))
                Right intentEvent -> do
                  result <- withTransactionEnv transaction (adapterExecute adapter operation prepared)
                  case result of
                    AdapterEffectFailed failureClass -> do
                      let state = case failureClass of KnownNoEffect _ -> Failed failureClass; PartialOrUnknown _ -> Ambiguous
                      appended <- appendEvent locked transaction (Just operationId) state "adapter execution stopped"
                      pure $ Just $ case (failureClass, appended) of
                        (KnownNoEffect _, Right _) -> StoppedFailed transaction operationId failureClass
                        _ -> StoppedAmbiguous transaction operationId
                    AdapterEffectAmbiguous _ -> do
                      _ <- appendEvent locked transaction (Just operationId) Ambiguous "adapter result was ambiguous"
                      pure (Just (StoppedAmbiguous transaction operationId))
                    AdapterEffectCompleted -> do
                      verification <- withTransactionEnv transaction (adapterVerify adapter operation)
                      case verification of
                        Left _ -> do
                          _ <- appendEvent locked transaction (Just operationId) Ambiguous "adapter completion could not be verified"
                          pure (Just (StoppedAmbiguous transaction operationId))
                        Right proof -> do
                          appended <- appendEvent locked transaction (Just operationId) (Completed proof) "operation completion verified"
                          case appended of
                            Left _ -> pure (Just (StoppedAmbiguous transaction operationId))
                            Right completedEvent -> go (events <> [intentEvent, completedEvent]) rest

preflightOperations :: AdapterRegistry -> ReviewedPlan -> Map OperationId OperationState -> IO [AdmissionError]
preflightOperations registry reviewed completed = fmap concat $ forM (reviewOperations (reviewedDocument reviewed)) $ \reviewOperation -> do
  let operation = reviewPlannedOperation reviewOperation
  if Map.member (plannedOperationId operation) completed || isNothing (reviewNativeDigest reviewOperation)
    then pure []
    else case (lookupAdapter registry (plannedExecutor operation), preparedFor reviewed reviewOperation) of
      (Left err, _) -> pure [AdmissionError "adapter" err]
      (_, Left err) -> pure [AdmissionError "native-bundle" err]
      (Right adapter, Right prepared)
        | adapterIdentity adapter /= reviewAdapterIdentity reviewOperation || adapterVersion adapter /= reviewAdapterVersion reviewOperation ->
            pure [AdmissionError "adapter-version" "review adapter identity or version differs from the active registry"]
        | otherwise -> do
            result <- adapterPreflight adapter operation prepared
            pure [AdmissionError "preflight" err | Left err <- [result]]

preparedFor :: ReviewedPlan -> ReviewOperation -> Either Text PreparedNative
preparedFor reviewed reviewOperation = do
  digest <- maybe (Left "operation is stopped at a review barrier") Right (reviewNativeDigest reviewOperation)
  bytes <- maybe (Left "native bundle is absent") Right (Map.lookup digest (reviewedNativeBundles reviewed))
  unless (contentDigest bytes == digest) (Left "native bundle digest changed")
  pure (PreparedNative bytes (reviewPublicSummary reviewOperation))

appendEvent :: LockedStore s -> TransactionId -> Maybe OperationId -> OperationState -> Text -> IO (Either StoreError JournalEvent)
appendEvent locked transaction operation state detail = do
  let store = lockedStore locked
  headResult <- readHead store
  case headResult of
    Left err -> pure (Left err)
    Right Nothing -> pure (Left (StoreConditionFailed "inventory store is not initialized"))
    Right (Just headValue) -> do
      previous <- previousDigest store (headSequence headValue)
      case previous of
        Left err -> pure (Left err)
        Right prior -> do
          now <- timestamp
          let event = JournalEvent 1 (headSequence headValue) prior transaction operation state now detail
              key = journalKey (headSequence headValue)
          existing <- readObject store key
          case existing of
            Left err -> pure (Left err)
            Right (Just bytes) -> case decodeJournalEvent bytes of
              Left err -> pure (Left (StoreInvalidObject key err))
              Right old
                | sameEventMeaning old event -> advance headValue old
                | otherwise -> pure (Left (StoreObjectConflict key))
            Right Nothing -> do
              published <- appendAtSequence store (headSequence headValue) (encodeJournalEvent event)
              case published of Left err -> pure (Left err); Right _ -> advance headValue event
  where
    advance headValue event = do
      let replacement = headValue {headGeneration = headGeneration headValue + 1, headSequence = headSequence headValue + 1}
      replaced <- replaceHeadIfGenerationMatches (lockedStore locked) (Just (headGeneration headValue)) replacement
      pure (event <$ replaced)
    sameEventMeaning left right =
      eventSequence left == eventSequence right
        && eventPreviousDigest left == eventPreviousDigest right
        && eventTransaction left == eventTransaction right
        && eventOperation left == eventOperation right
        && eventState left == eventState right

previousDigest :: InventoryStore -> Integer -> IO (Either StoreError (Maybe ContentDigest))
previousDigest _ 0 = pure (Right Nothing)
previousDigest store sequenceNumber = do
  loaded <- readObject store (journalKey (sequenceNumber - 1))
  pure $ do
    bytes <- loaded >>= maybe (Left (StoreInvalidObject (journalKey (sequenceNumber - 1)) "previous journal event is missing")) Right
    event <- first (StoreInvalidObject (journalKey (sequenceNumber - 1))) (decodeJournalEvent bytes)
    pure (Just (journalEventDigest event))

readJournal :: LockedStore s -> IO (Either StoreError [JournalEvent])
readJournal locked = do
  let store = lockedStore locked
  headResult <- readHead store
  case headResult of
    Left err -> pure (Left err)
    Right Nothing -> pure (Left (StoreConditionFailed "inventory store is not initialized"))
    Right (Just headValue) -> do
      loaded <- traverse (readObject store . journalKey) [0 .. headSequence headValue - 1]
      pure $ do
        values <- sequence loaded
        bytes <- traverse (maybe (Left (StoreInvalidObject "journal" "committed journal event is missing")) Right) values
        events <- traverse (first (StoreInvalidObject "journal") . decodeJournalEvent) bytes
        first (StoreInvalidObject "journal") (validateJournal events)

operationStates :: TransactionId -> [JournalEvent] -> Map OperationId OperationState
operationStates transaction =
  foldl
    (\states event -> case eventOperation event of Just operation | eventTransaction event == transaction -> Map.insert operation (eventState event) states; _ -> states)
    Map.empty

completedOperations :: TransactionId -> [JournalEvent] -> Map OperationId OperationState
completedOperations transaction = Map.filter isCompleted . operationStates transaction
  where
    isCompleted Completed {} = True
    isCompleted _ = False

transactionConverged :: TransactionId -> [JournalEvent] -> Bool
transactionConverged transaction = any (\event -> eventTransaction event == transaction && isNothing (eventOperation event) && "converged" `T.isInfixOf` eventDetail event)

acquireResumeClaim :: InventoryStore -> TransactionId -> HeadManifest -> IO (Either (NonEmpty AdmissionError) ())
acquireResumeClaim store transaction headValue = do
  now <- timestamp
  case headExecutorClaim headValue of
    Just claim | claimClientIdentity claim /= headClientIdentity headValue -> pure (failure "executor-claim" "transaction is claimed by a different store client; explicit takeover is required")
    claim -> do
      let epoch = maybe 1 ((+ 1) . claimEpoch) claim
          replacement = headValue {headGeneration = headGeneration headValue + 1, headExecutorClaim = Just (ExecutorClaim (transactionIdText transaction) (headClientIdentity headValue) epoch now)}
      result <- replaceHeadIfGenerationMatches store (Just (headGeneration headValue)) replacement
      pure $ case result of Left err -> failure "head-condition" (showText err); Right () -> Right ()

releaseClaim :: LockedStore s -> TransactionId -> Bool -> IO Bool
releaseClaim locked transaction converged = do
  let store = lockedStore locked
  headResult <- readHead store
  case headResult of
    Right (Just headValue) | headActiveTransaction headValue == Just (transactionIdText transaction) -> do
      let replacement =
            headValue
              { headGeneration = headGeneration headValue + 1
              , headExecutorClaim = Nothing
              , headActiveTransaction = if converged then Nothing else headActiveTransaction headValue
              , headConverged = if converged then headAccepted headValue else headConverged headValue
              }
      isRight <$> replaceHeadIfGenerationMatches store (Just (headGeneration headValue)) replacement
    _ -> pure False

transactionFor :: ReviewDocument -> TransactionId
transactionFor document =
  either (error . T.unpack) id (mkTransactionId ("tx-" <> digestText (reviewDocumentDigest document)))

reviewDocumentDigest :: ReviewDocument -> ContentDigest
reviewDocumentDigest = contentDigest . encodeReviewDocument

topological :: [ReviewOperation] -> [ReviewOperation]
topological operations = go [] operations
  where
    go done [] = done
    go done remaining =
      let completed = map (plannedOperationId . reviewPlannedOperation) done
          (ready, blocked) = spanReady completed remaining
       in if null ready then done <> remaining else go (done <> sortOn (operationIdText . plannedOperationId . reviewPlannedOperation) ready) blocked
    spanReady completed values =
      ( [value | value <- values, all (`elem` completed) (plannedDependencies (reviewPlannedOperation value))]
      , [value | value <- values, not (all (`elem` completed) (plannedDependencies (reviewPlannedOperation value)))]
      )

withTransactionEnv :: TransactionId -> IO a -> IO a
withTransactionEnv transaction action = do
  previous <- lookupEnv variable
  bracket (setEnv variable (T.unpack (transactionIdText transaction))) (const (restore previous)) (const action)
  where
    variable = "NAGARE_INVENTORY_TRANSACTION"
    restore Nothing = unsetEnv variable
    restore (Just value) = setEnv variable value

timestamp :: IO Text
timestamp = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" <$> getCurrentTime

failure :: Text -> Text -> Either (NonEmpty AdmissionError) a
failure code message = Left (AdmissionError code message :| [])

reviewAdmission :: ReviewError -> AdmissionError
reviewAdmission errorValue = AdmissionError (reviewErrorCode errorValue) (reviewErrorMessage errorValue)

showText :: (Show a) => a -> Text
showText = T.pack . show

ambiguousFallback :: TransactionId -> ReviewDocument -> IO TransactionResult
ambiguousFallback transaction document = pure (fallbackResult transaction document)

fallbackResult :: TransactionId -> ReviewDocument -> TransactionResult
fallbackResult transaction document =
  case reviewOperations document of
    operation : _ -> StoppedAmbiguous transaction (plannedOperationId (reviewPlannedOperation operation))
    [] -> StoppedAmbiguous transaction fallbackOperation
  where
    fallbackOperation = either (error . T.unpack) id (mkOperationId "op-store")
