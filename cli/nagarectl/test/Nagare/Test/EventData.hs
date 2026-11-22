-- | EP-276: every lifecycle event type's @data@ decodes, unchanged, through
-- the contract schema the OpenAPI document names for it, and validates
-- against that schema. A payload member the contract does not describe, or a
-- type with no schema, fails here.
module Nagare.Test.EventData
  ( eventDataTests
  , eventTypesSample
  )
where

import Data.Aeson (FromJSON, Result (..), ToJSON, Value, fromJSON, toJSON)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.OpenApi (ToSchema (declareNamedSchema))
import Data.OpenApi qualified as OpenApi
import Data.OpenApi.Declare (undeclare)
import Data.OpenApi.Schema.Validation (validateToJSON)
import Data.Proxy (Proxy (..))
import Nagare.Contract.EventData qualified as Contract
import Nagare.Contract.Events qualified as Events
import Nagare.Contract.Schema (ContractVersion (..), DocumentName (..), Nullable (..))
import Nagare.Dsl.Prelude
import Nagare.Events.Envelope (envelopeFor)
import Nagare.Events.Query (lifecycleEvent)
import Nagare.Events.Source
import Nagare.Inventory.Actor (Actor (..))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (mkTransactionId)
import Nagare.Inventory.Store (ScopeRevision (..))
import Nagare.Resource.Types
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase, (@?=))

eventDataTests :: TestTree
eventDataTests =
  testGroup
    "event data"
    [ testCase (show (eventKindText kind) <> " data matches its schema") $ do
        let payload = samplePayload kind
        payloadKind payload @?= kind
        conforms (eventKindText kind) payload
    | kind <- [minBound .. maxBound]
    ]

conforms :: Text -> EventPayload -> Assertion
conforms eventType = \case
  AppDeployedPayload value -> through (Proxy @Contract.AppDeployedData) (toJSON value)
  BackupCompletedPayload value -> through (Proxy @Contract.BackupCompletedData) (toJSON value)
  BackupAcceptedPayload value -> through (Proxy @Contract.BackupAcceptedData) (toJSON value)
  ChangeAppliedPayload value -> through (Proxy @Contract.ChangeAppliedData) (toJSON value)
  where
    through :: forall a. (Eq a, Show a, FromJSON a, ToJSON a, ToSchema a) => Proxy a -> Value -> Assertion
    through proxy value = do
      Contract.eventDataSchemaName eventType @?= undeclare (declareNamedSchema proxy) ^. OpenApi.name
      case fromJSON value :: Result a of
        Error reason -> assertFailure reason
        Success decoded -> do
          toJSON decoded @?= value
          validateToJSON decoded @?= []

-- | One sample payload of every type, with its nullable members filled.
samplePayload :: EventKind -> EventPayload
samplePayload = \case
  AppDeployed ->
    AppDeployedPayload
      AppDeployment
        { subject = ApplicationSubject
        , action = DeployAction
        , release = "notes-20261122-1"
        , previousRelease = Just "notes-20261117-1"
        , scopeRevision = revisionAt 5 "notes revisionAt 5"
        , transaction
        , review
        , readiness = contentDigest "notes readiness"
        }
  DatabaseBackupCompleted ->
    BackupCompletedPayload
      BackupCompletion
        { backup = "bk-0123456789abcdef0123456789abcdef"
        , origin = ScheduledBackup
        , run = "3f0c9a52-6d1e-4b8a-9b0e-5c2d1f7e8a90"
        , archive = StoredVersion "s3://backups/personal/notes/run.dump" "1"
        , receipt = StoredVersion "s3://backups/personal/notes/run.dump.receipt.json" "2"
        , sha256 = digestText (contentDigest "archive")
        , archiveBytes = 4096
        , scheduleRevision = Just (contentDigest "schedule")
        , recoveryPoint = Just "2026-11-22T04:00:00Z"
        , completedAt = Just "2026-11-22T04:00:07Z"
        }
  DatabaseBackupAccepted ->
    BackupAcceptedPayload
      BackupAcceptance
        { backup = "bk-0123456789abcdef0123456789abcdef"
        , completion = "ev-0123456789abcdef0123456789abcdef"
        , receiptScope = scopeOf Platform "receipt-notes"
        , receiptRevision = revisionAt 1 "receipt"
        , transaction
        , review
        , recoveryPoint = Just "2026-11-22T04:00:00Z"
        }
  ChangeApplied ->
    ChangeAppliedPayload
      ChangeApplication
        { transaction
        , review
        , actor = DeployerActor "ci"
        , source = ChangeSource (Just "github.com/example/notes") (Just "0123abc") (Just "run-7")
        , scopes =
            [ ScopeChange (scopeOf Application "notes") ScopeUpdated (Just (revisionAt 4 "notes revisionAt 4")) (Just (revisionAt 5 "notes revisionAt 5"))
            , ScopeChange (scopeOf Publication "notes-image") ScopeCreated Nothing (Just (revisionAt 1 "image"))
            , ScopeChange (scopeOf Standalone "old") ScopeRetired (Just (revisionAt 2 "old")) Nothing
            ]
        , operations = [ActionCount "create" 1, ActionCount "retire" 1, ActionCount "update" 2]
        }
  where
    transaction = either (error . show) id (mkTransactionId ("tx-" <> digestText review))
    review = contentDigest "review"

revisionAt :: Integer -> ByteString -> ScopeRevision
revisionAt generation seed = ScopeRevision (either (error . show) id (mkScopeGeneration generation)) (contentDigest seed)

scopeOf :: ScopeKind -> Text -> ScopeId
scopeOf kind value = either (error . show) id (mkScopeId kind value)

-- | @nagarectl events list --contract 1@ with one event of every type.
eventTypesSample :: Events.EventList
eventTypesSample =
  Events.EventList
    ContractVersion1
    DocumentName
    "context-1"
    "4b7a5f0c0d9d4f3f8a2f61e5c9d1c2b3a4f5e6d7c8b9a0f1e2d3c4b5a6978899"
    [ Events.LifecycleFeedEntry position (lifecycleEvent (envelopeFor context "2026-11-22T04:00:05Z" "2026-11-22T04:00:07Z" (candidate kind)))
    | (position, kind) <- zip [0 ..] [minBound .. maxBound]
    ]
    (Events.EventPageInfo False (Nullable (Just "eyJ2IjoxfQ")))
  where
    context = either (error . show) id (mkContextId "context-1")
    candidate kind =
      EventCandidate
        { key = either (error . show) id (mkSourceKey ("sample:" <> eventKindText kind))
        , resource = ResourceRef (scopeOf Application "notes") Nothing (Just "personal") Nothing
        , occurredAt = Nothing
        , evidence = [Evidence "review" (contentDigest "review")]
        , payload = samplePayload kind
        }
