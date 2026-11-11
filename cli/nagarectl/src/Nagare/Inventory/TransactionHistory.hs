-- | @inventory history@ and @delegation show@ (EP-247 D6, D7): read-only
-- documents from the store alone. A transaction's id is @tx-@ plus its review
-- digest and the review is kept under @reviews/@, so each journal entry is
-- bound to the actor and source its review records.
module Nagare.Inventory.TransactionHistory
  ( TransactionEntry (..)
  , transactionEntries
  , readTransactionHistory
  , delegationDocument
  , transactionSummary
  )
where

import Control.Monad (forM)
import Data.Aeson (eitherDecodeStrict')
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Text qualified as T
import Nagare.Contract.Delegation
import Nagare.Contract.Schema (ContractVersion (..), DocumentName (..), nullable)
import Nagare.Deploy.Host (HostShape (..))
import Nagare.Dsl.Prelude
import Nagare.Inventory.Actor (Actor, ReviewSource, actorKindText, actorName)
import Nagare.Inventory.DeployerDelegation (DeployerDelegation, delegatedKindText, delegationStateText)
import Nagare.Inventory.Execute.Journal (readJournalAtHead)
import Nagare.Inventory.Journal (JournalEvent (..), OperationState (..), transactionIdText)
import Nagare.Inventory.Plan.Types (ReviewDocument (..))
import Nagare.Inventory.Store (HeadManifest (headActiveTransaction), InventoryStore, readObject, reviewKey)
import Nagare.Resource.Types (ContentDigest, digestText, mkContentDigest, scopeIdText)

data TransactionEntry = TransactionEntry
  { transaction :: !Text
  , state :: !Text
  , admittedAt :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | Transactions newest first: @converged@ when the transaction recorded its
-- convergence, @closed@ when an operator closed it, @active@ while it holds
-- the head, and @stopped@ otherwise.
transactionEntries :: Maybe Text -> [JournalEvent] -> [TransactionEntry]
transactionEntries active events =
  [ TransactionEntry
      { transaction = transactionId
      , state = finalState transactionId (Map.findWithDefault [] transactionId grouped)
      , admittedAt = maybe "" eventTimestamp (listToMaybe' (Map.findWithDefault [] transactionId grouped))
      }
  | (transactionId, _) <- sortOn (Down . snd) (Map.toList firstSequence)
  ]
  where
    grouped = Map.fromListWith (flip (<>)) [(transactionIdText (eventTransaction event), [event]) | event <- events]
    firstSequence = Map.fromListWith min [(transactionIdText (eventTransaction event), eventSequence event) | event <- events]
    listToMaybe' = \case
      first' : _ -> Just first'
      [] -> Nothing
    finalState transactionId transactionEvents
      | any (\event -> isNothing (eventOperation event) && isCompleted (eventState event)) transactionEvents = "converged"
      | any (\event -> isNothing (eventOperation event) && isResolved (eventState event)) transactionEvents = "closed"
      | active == Just transactionId = "active"
      | otherwise = "stopped"
    isCompleted = \case
      Completed _ -> True
      _ -> False
    isResolved = \case
      OperatorResolved _ -> True
      _ -> False

-- | The newest @limit@ transactions with what their reviews record.
readTransactionHistory :: InventoryStore -> HeadManifest -> Int -> IO (Either Text TransactionHistory)
readTransactionHistory store headValue limit = do
  journal <- readJournalAtHead store headValue
  case journal of
    Left err -> pure (Left (T.pack (show err)))
    Right events -> do
      let entries = take limit (transactionEntries (headActiveTransaction headValue) events)
      summaries <- forM entries $ \entry -> do
        loaded <- either (pure . Left) (readReview store) (mkContentDigest (T.drop 3 (entry ^. #transaction)))
        pure (transactionSummary entry <$> loaded)
      pure (TransactionHistory ContractVersion1 DocumentName <$> sequence summaries)

readReview :: InventoryStore -> ContentDigest -> IO (Either Text (ContentDigest, ReviewDocument))
readReview store digest = do
  loaded <- readObject store (reviewKey digest)
  pure $ case loaded of
    Left err -> Left (T.pack (show err))
    Right Nothing -> Left "a transaction's published review is missing"
    Right (Just bytes) -> (digest,) <$> first T.pack (eitherDecodeStrict' bytes)

transactionSummary :: TransactionEntry -> (ContentDigest, ReviewDocument) -> TransactionSummary
transactionSummary entry (digest, document) =
  TransactionSummary
    { transaction = entry ^. #transaction
    , review = digestText digest
    , state = entry ^. #state
    , admittedAt = entry ^. #admittedAt
    , scopes =
        map
          scopeIdText
          ( Map.keys (Map.differenceWith (\desired base -> if desired == base then Nothing else Just desired) (reviewDesiredRevisions document) (reviewBaseRevisions document))
              <> Map.keys (Map.difference (reviewBaseRevisions document) (reviewDesiredRevisions document))
          )
    , actor = actorSummary (reviewActor document)
    , source = nullable (sourceSummary <$> reviewSource document)
    }

actorSummary :: Actor -> ActorSummary
actorSummary actor = ActorSummary {kind = actorKindText actor, name = nullable (actorName actor)}

sourceSummary :: ReviewSource -> SourceSummary
sourceSummary source =
  SourceSummary
    { repository = nullable (source ^. #repository)
    , revision = nullable (source ^. #revision)
    , run = nullable (source ^. #run)
    }

delegationDocument :: Integer -> DeployerDelegation -> DelegationDocument
delegationDocument generation d =
  DelegationDocument
    { contractVersion = ContractVersion1
    , document = DocumentName
    , name = d ^. #name
    , state = delegationStateText (d ^. #state)
    , namespaces = NE.toList (d ^. #namespaces)
    , hostSuffixes = d ^. #hostSuffixes
    , kinds = map delegatedKindText (NE.toList (d ^. #kinds))
    , imageRepository = d ^. #imageRepository
    , team = d ^. #team
    , buildNamespace = nullable (d ^. #buildNamespace)
    , quota = DelegationQuotaSummary {cpu = d ^. #quota . #cpu, memory = d ^. #quota . #memory, pods = d ^. #quota . #pods}
    , baseDomain = d ^. #baseDomain
    , hostShape = case d ^. #hostShape of
        NestedHosts -> "nested"
        FlatHosts -> "flat"
    , acceptedRevision = generation
    }
