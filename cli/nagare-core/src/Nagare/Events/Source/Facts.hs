{-# LANGUAGE OverloadedStrings #-}

-- | Lifecycle source facts (EP-231): the typed candidates a converged
-- transaction commits, and the immutable facts object that carries them.
-- Implementation behind "Nagare.Events.Source".
module Nagare.Events.Source.Facts
  ( SourceKey
  , mkSourceKey
  , sourceKeyText
  , EventKind (..)
  , eventKindText
  , parseEventKind
  , ResourceRef (..)
  , Evidence (..)
  , DeploymentSubject (..)
  , DeploymentAction (..)
  , AppDeployment (..)
  , BackupOrigin (..)
  , StoredVersion (..)
  , BackupCompletion (..)
  , BackupAcceptance (..)
  , ChangeSource (..)
  , changeSource
  , ScopeChangeKind (..)
  , ScopeChange (..)
  , ActionCount (..)
  , ChangeApplication (..)
  , contextScope
  , EventPayload (..)
  , payloadKind
  , payloadData
  , parsePayload
  , EventCandidate (..)
  , ControlChannel
  , mkControlChannel
  , controlChannelText
  , ControlFact (..)
  , SourceItem (..)
  , SourceInput (..)
  , OperationView (..)
  , SourceProducer (..)
  , sourceProducer
  , MemberView (..)
  , ScopeView (..)
  , SourceFacts (..)
  , factsSchemaVersion
  , assembleFacts
  , encodeSourceFacts
  , decodeSourceFacts
  , factsDigest
  , factsKey
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Actor (Actor, ReviewSource)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (JournalEvent, OperationId, TransactionId)
import Nagare.Inventory.Store (ScopeRevision, objectKeyFor)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- | The stable, versioned identity of one source fact. A public event's ID
-- derives from it and the context identity, never from a retry's time.
newtype SourceKey = SourceKey Text deriving stock (Eq, Ord, Show)

-- | Lowercase ASCII letters, digits and @-._:/@, starting with a letter, at
-- most 256 characters.
mkSourceKey :: Text -> Either Text SourceKey
mkSourceKey value
  | T.null value || T.length value > 256 = Left "a source key has 1 to 256 characters"
  | not (T.head value >= 'a' && T.head value <= 'z') = Left "a source key starts with a lowercase letter"
  | T.all allowed value = Right (SourceKey value)
  | otherwise = Left "a source key contains only lowercase ASCII, digits and -._:/"
  where
    allowed c = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c `elem` ("-._:/" :: String)

sourceKeyText :: SourceKey -> Text
sourceKeyText (SourceKey value) = value

-- | The public event types. A new type is added at the end and never
-- renamed; a worker that does not know a type refuses it and stops.
data EventKind
  = AppDeployed
  | DatabaseBackupCompleted
  | DatabaseBackupAccepted
  | ChangeApplied
  deriving stock (Eq, Ord, Show, Bounded, Enum, Generic)

eventKindText :: EventKind -> Text
eventKindText = \case
  AppDeployed -> "app.deployed"
  DatabaseBackupCompleted -> "database.backup.completed"
  DatabaseBackupAccepted -> "database.backup.accepted"
  ChangeApplied -> "change.applied"

parseEventKind :: Text -> Maybe EventKind
parseEventKind value = lookup value [(eventKindText kind, kind) | kind <- [minBound .. maxBound]]

-- | The resource an event is about: its scope, logical member, namespace and
-- the incarnation recorded for it. A display name is never the only identity.
data ResourceRef = ResourceRef
  { scope :: !ScopeId
  , member :: !(Maybe ResourceId)
  , namespace :: !(Maybe Text)
  , incarnation :: !(Maybe PhysicalIdentity)
  }
  deriving stock (Eq, Show, Generic)

-- | A named, digest-bound reference to the evidence an event rests on.
data Evidence = Evidence
  { name :: !Text
  , digest :: !ContentDigest
  }
  deriving stock (Eq, Show, Generic)

data DeploymentSubject = ApplicationSubject | ServiceSubject | SiteSubject
  deriving stock (Eq, Show, Bounded, Enum, Generic)

data DeploymentAction = DeployAction | RollbackAction
  deriving stock (Eq, Show, Bounded, Enum, Generic)

-- | @app.deployed@: a changed production release passed its reviewed
-- readiness and its transaction converged (EP-232 produces it).
data AppDeployment = AppDeployment
  { subject :: !DeploymentSubject
  , action :: !DeploymentAction
  , release :: !Text
  , previousRelease :: !(Maybe Text)
  , scopeRevision :: !ScopeRevision
  , transaction :: !TransactionId
  , review :: !ContentDigest
  , readiness :: !ContentDigest
  }
  deriving stock (Eq, Show, Generic)

data BackupOrigin = ScheduledBackup | ManualBackup
  deriving stock (Eq, Show, Bounded, Enum, Generic)

-- | An exact stored object version.
data StoredVersion = StoredVersion
  { name :: !Text
  , version :: !Text
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | @database.backup.completed@: an archive and its authenticated receipt
-- were verified at exact versions (EP-233 produces it). @backup@ is the
-- normalized backup ID completion and acceptance share; @recoveryPoint@ is
-- the signed dump time, when the receipt carries one, and @completedAt@ the
-- provider's time for the receipt version, when known. Neither is the other.
data BackupCompletion = BackupCompletion
  { backup :: !Text
  , origin :: !BackupOrigin
  , run :: !Text
  , archive :: !StoredVersion
  , receipt :: !StoredVersion
  , sha256 :: !Text
  , archiveBytes :: !Integer
  , scheduleRevision :: !(Maybe ContentDigest)
  , recoveryPoint :: !(Maybe Text)
  , completedAt :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

-- | @database.backup.accepted@: a reviewed transaction admitted the backup as
-- a recovery point (EP-233 produces it). It grants no restore authority.
-- @completion@ is the ID of the backup's completion event in this context.
data BackupAcceptance = BackupAcceptance
  { backup :: !Text
  , completion :: !Text
  , receiptScope :: !ScopeId
  , receiptRevision :: !ScopeRevision
  , transaction :: !TransactionId
  , review :: !ContentDigest
  , recoveryPoint :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

-- | Where a reviewed change came from, as its review recorded it. Each
-- part is null when the review named none.
data ChangeSource = ChangeSource
  { repository :: !(Maybe Text)
  , revision :: !(Maybe Text)
  , run :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

-- | The source a review recorded, with every part null when it named none.
changeSource :: Maybe ReviewSource -> ChangeSource
changeSource = \case
  Nothing -> ChangeSource Nothing Nothing Nothing
  Just recorded -> ChangeSource (recorded ^. #repository) (recorded ^. #revision) (recorded ^. #run)

data ScopeChangeKind = ScopeCreated | ScopeUpdated | ScopeRetired
  deriving stock (Eq, Show, Bounded, Enum, Generic)

-- | One scope a converged transaction changed: created (it had no converged
-- revision before), updated, or retired (its review removed it). @from@ is
-- the revision converged before, or the accepted one for a retired scope
-- that never converged; @to@ is the converged revision, null when retired.
data ScopeChange = ScopeChange
  { scope :: !ScopeId
  , change :: !ScopeChangeKind
  , from :: !(Maybe ScopeRevision)
  , to :: !(Maybe ScopeRevision)
  }
  deriving stock (Eq, Show, Generic)

-- | How many of a transaction's operations had this action.
data ActionCount = ActionCount
  { action :: !Text
  , count :: !Int
  }
  deriving stock (Eq, Show, Generic)

-- | @change.applied@ (EP-276): a reviewed inventory transaction converged:
-- every operation it journaled completed and the head that records its
-- convergence was committed. It is published once per transaction, whatever
-- the change was, so a deploy has one beside its @app.deployed@ and an env,
-- secret, access, storage, schedule or CDN change has only this one. Its
-- resource is the single scope it changed, the single release subject when
-- it changed several, and otherwise @platform:context@. @scopes@ lists every
-- scope it changed and is empty for a review that only verified. @actor@
-- and @source@ are what the review asserted, not proved (ADR 35).
data ChangeApplication = ChangeApplication
  { transaction :: !TransactionId
  , review :: !ContentDigest
  , actor :: !Actor
  , source :: !ChangeSource
  , scopes :: ![ScopeChange]
  , operations :: ![ActionCount]
  }
  deriving stock (Eq, Show, Generic)

-- | The resource scope of an event about the context as a whole. No
-- inventory scope has this name.
contextScope :: ScopeId
contextScope = either (error . T.unpack) id (mkScopeId Platform "context")

data EventPayload
  = AppDeployedPayload !AppDeployment
  | BackupCompletedPayload !BackupCompletion
  | BackupAcceptedPayload !BackupAcceptance
  | ChangeAppliedPayload !ChangeApplication
  deriving stock (Eq, Show, Generic)

payloadKind :: EventPayload -> EventKind
payloadKind = \case
  AppDeployedPayload _ -> AppDeployed
  BackupCompletedPayload _ -> DatabaseBackupCompleted
  BackupAcceptedPayload _ -> DatabaseBackupAccepted
  ChangeAppliedPayload _ -> ChangeApplied

-- | A payload's @data@ member.
payloadData :: EventPayload -> Value
payloadData = \case
  AppDeployedPayload value -> toJSON value
  BackupCompletedPayload value -> toJSON value
  BackupAcceptedPayload value -> toJSON value
  ChangeAppliedPayload value -> toJSON value

-- | The payload of a @data@ member of this type.
parsePayload :: EventKind -> Value -> Parser EventPayload
parsePayload kind dataValue = case kind of
  AppDeployed -> AppDeployedPayload <$> parseJSON dataValue
  DatabaseBackupCompleted -> BackupCompletedPayload <$> parseJSON dataValue
  DatabaseBackupAccepted -> BackupAcceptedPayload <$> parseJSON dataValue
  ChangeApplied -> ChangeAppliedPayload <$> parseJSON dataValue

-- | One public event a source fact can become.
data EventCandidate = EventCandidate
  { key :: !SourceKey
  , resource :: !ResourceRef
  , occurredAt :: !(Maybe Text)
  -- ^ When it happened, if the source knows better than its convergence;
  -- a journal source leaves it out and takes its convergence time.
  , evidence :: ![Evidence]
  , payload :: !EventPayload
  }
  deriving stock (Eq, Show, Generic)

-- | The consumer an internal control fact is addressed to.
newtype ControlChannel = ControlChannel Text deriving stock (Eq, Ord, Show)

mkControlChannel :: Text -> Either Text ControlChannel
mkControlChannel value
  | not (T.null value) && T.length value <= 64 && T.all (\c -> (c >= 'a' && c <= 'z') || c == '-') value = Right (ControlChannel value)
  | otherwise = Left "a control channel has 1 to 64 lowercase letters or hyphens"

controlChannelText :: ControlChannel -> Text
controlChannelText (ControlChannel value) = value

-- | An internal instruction for one consumer, such as a subscription
-- revision or a replay authorization (EP-234 owns the payloads). It never
-- becomes a public event; its consumer refuses a version it does not read.
data ControlFact = ControlFact
  { key :: !SourceKey
  , channel :: !ControlChannel
  , version :: !Int
  , body :: !Value
  }
  deriving stock (Eq, Show, Generic)

data SourceItem = PublicCandidate !EventCandidate | Control !ControlFact
  deriving stock (Eq, Show, Generic)

-- | What a producer sees of a converging transaction.
data SourceInput = SourceInput
  { context :: !ContextId
  , transaction :: !TransactionId
  , review :: !ContentDigest
  , payloadIdentity :: !Text
  , baseRevisions :: !(Map ScopeId ScopeRevision)
  , desiredRevisions :: !(Map ScopeId ScopeRevision)
  , convergedBefore :: !(Map ScopeId ScopeRevision)
  -- ^ The scopes' converged revisions in the head this release replaces.
  , operations :: !(Map OperationId (NonEmpty ResourceId))
  , steps :: ![OperationView]
  -- ^ The review's operations, in review order (EP-276).
  , actor :: !Actor
  , source :: !(Maybe ReviewSource)
  , retained :: !(Map ResourceId ScopeId)
  -- ^ The members the review retained, by the scope that owned them.
  , collected :: !(Map ResourceId ScopeId)
  -- ^ The members the review collected, by the scope that owned them.
  , journal :: ![JournalEvent]
  , members :: !(Map ResourceId MemberView)
  -- ^ The members some producer wants that this transaction operated.
  , scopes :: !(Map ScopeId ScopeView)
  -- ^ The scopes this transaction changed whose desired overrides hold a
  -- key some producer names (EP-233).
  }
  deriving stock (Generic)

-- | One reviewed operation as a producer sees it: its action's wire name
-- (@create@, @update@, @verify@, @retire@, @migrate@ and the others), the
-- adapter that runs it, its public summary and its resources.
data OperationView = OperationView
  { operation :: !OperationId
  , action :: !Text
  , adapter :: !Text
  , summary :: !Text
  , resources :: !(NonEmpty ResourceId)
  }
  deriving stock (Eq, Show, Generic)

-- | One changed scope's overrides at its desired revision, and at the
-- revision converged before this release, if it had one.
data ScopeView = ScopeView
  { revision :: !ScopeRevision
  , desired :: !(Map Text Text)
  , previous :: !(Maybe (Map Text Text))
  }
  deriving stock (Eq, Show, Generic)

-- | One operated member a producer asked for: its native object bytes at
-- the desired scope revision, and at the scope's revision converged before
-- this release, if it had one there (EP-232).
data MemberView = MemberView
  { owner :: !ScopeId
  , operation :: !OperationId
  , desired :: !(Maybe ByteString)
  , previous :: !(Maybe ByteString)
  }
  deriving stock (Eq, Show, Generic)

-- | A pure producer of a converging transaction's source items, the
-- operated members whose native bytes it reads, and the override keys that
-- make a changed scope one it reads.
data SourceProducer = SourceProducer
  { wants :: !(ResourceId -> Bool)
  , scopeKeys :: ![Text]
  , produce :: !(SourceInput -> [SourceItem])
  }
  deriving stock (Generic)

-- | A producer that reads no member bytes and no scope.
sourceProducer :: (SourceInput -> [SourceItem]) -> SourceProducer
sourceProducer = SourceProducer (const False) []

-- | Everything a converged transaction committed for lifecycle consumers.
-- It holds no time of its own: a release that is retried writes the same
-- bytes, and its events take their times from the committed convergence.
data SourceFacts = SourceFacts
  { schemaVersion :: !Int
  , transaction :: !TransactionId
  , review :: !ContentDigest
  , events :: ![EventCandidate]
  , controls :: ![ControlFact]
  }
  deriving stock (Eq, Show, Generic)

factsSchemaVersion :: Int
factsSchemaVersion = 1

-- | Collect the producers' items into one facts object, or nothing when there
-- is none. Public candidates are kept in key order and controls in producer
-- order; a key repeated with the same item is kept once, and a key repeated
-- with a different item is refused.
assembleFacts :: SourceInput -> [SourceProducer] -> Either Text (Maybe SourceFacts)
assembleFacts input producers = do
  let items = concat [(producer ^. #produce) input | producer <- producers]
      candidates = [candidate | PublicCandidate candidate <- items]
      controlFacts = [control | Control control <- items]
  publicEvents <- unique (\candidate -> candidate ^. #key) candidates
  controlOrder <- unique (\control -> control ^. #key) controlFacts
  pure $
    if null publicEvents && null controlOrder
      then Nothing
      else Just (SourceFacts factsSchemaVersion (input ^. #transaction) (input ^. #review) (sortOn (^. #key) publicEvents) controlOrder)
  where
    unique :: (Eq a) => (a -> SourceKey) -> [a] -> Either Text [a]
    unique keyOf = go Map.empty []
      where
        go _ kept [] = Right (reverse kept)
        go seen kept (item : rest) = case Map.lookup (keyOf item) seen of
          Nothing -> go (Map.insert (keyOf item) item seen) (item : kept) rest
          Just earlier
            | earlier == item -> go seen kept rest
            | otherwise -> Left ("source key " <> sourceKeyText (keyOf item) <> " names two different facts")

encodeSourceFacts :: SourceFacts -> ByteString
encodeSourceFacts = either (error . T.unpack) id . canonicalValue . toJSON

decodeSourceFacts :: ByteString -> Either Text SourceFacts
decodeSourceFacts bytes = do
  facts <- first T.pack (eitherDecodeStrict' bytes)
  canonical <- canonicalValue (toJSON facts)
  unless (canonical == bytes) (Left "source facts are not canonical")
  pure facts

-- | A facts object is addressed by the digest of its canonical bytes.
factsDigest :: SourceFacts -> ContentDigest
factsDigest = contentDigest . encodeSourceFacts

-- | The content-addressed inventory member holding a facts object.
factsKey :: ContentDigest -> FilePath
factsKey = objectKeyFor "facts"

instance ToJSON SourceKey where toJSON = String . sourceKeyText

instance FromJSON SourceKey where parseJSON = withText "source key" (either (fail . T.unpack) pure . mkSourceKey)

instance ToJSON ControlChannel where toJSON = String . controlChannelText

instance FromJSON ControlChannel where parseJSON = withText "control channel" (either (fail . T.unpack) pure . mkControlChannel)

instance ToJSON EventKind where toJSON = String . eventKindText

instance FromJSON EventKind where parseJSON = withText "event kind" (\value -> maybe (fail "unknown event kind") pure (parseEventKind value))

enumeration :: (Bounded a, Enum a) => String -> (a -> Text) -> Value -> Parser a
enumeration label render = withText label (\value -> maybe (fail ("unknown " <> label)) pure (lookup value [(render item, item) | item <- [minBound .. maxBound]]))

subjectText :: DeploymentSubject -> Text
subjectText = \case
  ApplicationSubject -> "application"
  ServiceSubject -> "service"
  SiteSubject -> "site"

instance ToJSON DeploymentSubject where toJSON = String . subjectText

instance FromJSON DeploymentSubject where parseJSON = enumeration "deployment subject" subjectText

actionText :: DeploymentAction -> Text
actionText = \case
  DeployAction -> "deploy"
  RollbackAction -> "rollback"

instance ToJSON DeploymentAction where toJSON = String . actionText

instance FromJSON DeploymentAction where parseJSON = enumeration "deployment action" actionText

originText :: BackupOrigin -> Text
originText = \case
  ScheduledBackup -> "scheduled"
  ManualBackup -> "manual"

instance ToJSON BackupOrigin where toJSON = String . originText

instance FromJSON BackupOrigin where parseJSON = enumeration "backup origin" originText

strictOptions :: Options
strictOptions = defaultOptions {rejectUnknownFields = True}

instance ToJSON ResourceRef where toJSON = genericToJSON strictOptions

instance FromJSON ResourceRef where parseJSON = genericParseJSON strictOptions

instance ToJSON Evidence where toJSON = genericToJSON strictOptions

instance FromJSON Evidence where parseJSON = genericParseJSON strictOptions

instance ToJSON AppDeployment where toJSON = genericToJSON strictOptions

instance FromJSON AppDeployment where parseJSON = genericParseJSON strictOptions

instance ToJSON StoredVersion where toJSON = genericToJSON strictOptions

instance FromJSON StoredVersion where parseJSON = genericParseJSON strictOptions

instance ToJSON BackupCompletion where toJSON = genericToJSON strictOptions

instance FromJSON BackupCompletion where parseJSON = genericParseJSON strictOptions

instance ToJSON BackupAcceptance where toJSON = genericToJSON strictOptions

instance FromJSON BackupAcceptance where parseJSON = genericParseJSON strictOptions

instance ToJSON ChangeSource where toJSON = genericToJSON strictOptions

instance FromJSON ChangeSource where parseJSON = genericParseJSON strictOptions

scopeChangeText :: ScopeChangeKind -> Text
scopeChangeText = \case
  ScopeCreated -> "created"
  ScopeUpdated -> "updated"
  ScopeRetired -> "retired"

instance ToJSON ScopeChangeKind where toJSON = String . scopeChangeText

instance FromJSON ScopeChangeKind where parseJSON = enumeration "scope change" scopeChangeText

instance ToJSON ScopeChange where toJSON = genericToJSON strictOptions

instance FromJSON ScopeChange where parseJSON = genericParseJSON strictOptions

instance ToJSON ActionCount where toJSON = genericToJSON strictOptions

instance FromJSON ActionCount where parseJSON = genericParseJSON strictOptions

instance ToJSON ChangeApplication where toJSON = genericToJSON strictOptions

instance FromJSON ChangeApplication where parseJSON = genericParseJSON strictOptions

-- | A payload is encoded as its kind and its data, so the kind is explicit.
instance ToJSON EventCandidate where
  toJSON candidate =
    object
      [ "key" .= (candidate ^. #key)
      , "type" .= payloadKind (candidate ^. #payload)
      , "resource" .= (candidate ^. #resource)
      , "occurredAt" .= (candidate ^. #occurredAt)
      , "evidence" .= (candidate ^. #evidence)
      , "data" .= payloadData (candidate ^. #payload)
      ]

instance FromJSON EventCandidate where
  parseJSON = withObject "event candidate" $ \o -> do
    exactKeys "event candidate" ["key", "type", "resource", "occurredAt", "evidence", "data"] o
    kind <- o .: "type"
    dataValue <- o .: "data"
    payloadValue <- parsePayload kind dataValue
    EventCandidate <$> o .: "key" <*> o .: "resource" <*> o .:? "occurredAt" <*> o .: "evidence" <*> pure payloadValue

instance ToJSON ControlFact where
  toJSON control =
    object
      [ "key" .= (control ^. #key)
      , "channel" .= (control ^. #channel)
      , "version" .= (control ^. #version)
      , "body" .= (control ^. #body)
      ]

instance FromJSON ControlFact where
  parseJSON = withObject "control fact" $ \o -> do
    exactKeys "control fact" ["key", "channel", "version", "body"] o
    ControlFact <$> o .: "key" <*> o .: "channel" <*> o .: "version" <*> o .: "body"

instance ToJSON SourceFacts where
  toJSON facts =
    object
      [ "version" .= (facts ^. #schemaVersion)
      , "transaction" .= (facts ^. #transaction)
      , "review" .= (facts ^. #review)
      , "events" .= (facts ^. #events)
      , "controls" .= (facts ^. #controls)
      ]

instance FromJSON SourceFacts where
  parseJSON = withObject "source facts" $ \o -> do
    exactKeys "source facts" ["version", "transaction", "review", "events", "controls"] o
    version <- o .: "version"
    unless (version == factsSchemaVersion) (fail "unsupported source facts version")
    SourceFacts version <$> o .: "transaction" <*> o .: "review" <*> o .: "events" <*> o .: "controls"

exactKeys :: String -> [Key] -> Object -> Parser ()
exactKeys label allowed o = unless (all (`elem` allowed) (KM.keys o)) (fail (label <> " has an unknown field"))
