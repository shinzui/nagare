-- | The documents the release runner reads from nagarectl and git, and the
-- records it writes (EP-229): @candidate.json@, @intranet.json@ and the
-- transition-rehearsal record a release binds. Reads are typed projections of
-- the fields a decision needs; records keep the scripts' shape and key order.
module Nagare.Harness.Release.Records
  ( ReleaseIdentity (..)
  , Identities (..)
  , PlatformStatus (..)
  , StoreStatus (..)
  , InventoryStatus (..)
  , PlatformRoot (..)
  , ReleaseMetadata (..)
  , CandidateRecord (..)
  , RehearsalCheck (..)
  , IntranetCheck (..)
  , decodeDocument
  , readDocument
  , lockedRevision
  , exactOn
  , unconvergedScopes
  , platformConverged
  , rehearsalMatches
  , intranetOn
  , writeSorted
  , writeSortedAtomically
  , encodeSorted
  )
where

import Control.Monad ((>=>))
import Data.Aeson (FromJSON (..), ToJSON, Value (..), eitherDecodeFileStrict, eitherDecodeStrict, withObject, (.:))
import Data.Aeson.Encode.Pretty (Config (..), Indent (Spaces), defConfig, encodePretty')
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Generics.Labels ()
import Data.List (partition)
import Data.Text qualified as T
import Nagare.Harness.Prelude
import System.Directory (renameFile)

-- | A release identity as @version --json@ and @platform status --json@
-- print it; either half may be null.
data ReleaseIdentity = ReleaseIdentity
  { version :: !(Maybe Text)
  , revision :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

data Identities = Identities
  { cli :: !ReleaseIdentity
  , payload :: !ReleaseIdentity
  , host :: !ReleaseIdentity
  , cluster :: !ReleaseIdentity
  , context :: !ReleaseIdentity
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

data PlatformStatus = PlatformStatus
  { compatibility :: !Text
  , identities :: !Identities
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

-- | @inventory store status --json@: only the head's open transaction.
newtype StoreStatus = StoreStatus {activeTransaction :: Maybe Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

data InventoryStatus = InventoryStatus
  { activeTransaction :: !(Maybe Value)
  , accepted :: !(Maybe [Value])
  , converged :: !(Maybe [Value])
  , transactionStatus :: !(Maybe Value)
  , observationComplete :: !(Maybe Value)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

newtype PlatformRoot = PlatformRoot {platformVersion :: Maybe Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

-- | @release.json@ at the candidate revision.
data ReleaseMetadata = ReleaseMetadata
  { platformVersion :: !Text
  , supportedSystems :: ![Text]
  , transitionsFrom :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

-- | @<run>/candidate.json@, which the intranet and publish steps read.
data CandidateRecord = CandidateRecord
  { previous :: !Text
  , revision :: !Text
  , version :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | What @release-rehearse@ checks of a rehearsal record before keeping it.
data RehearsalCheck = RehearsalCheck
  { candidateRevision :: !(Maybe Text)
  , sourceVersion :: !(Maybe Text)
  , seeded :: !(Maybe Value)
  , readBack :: !(Maybe Value)
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON RehearsalCheck where
  parseJSON = withObject "transition rehearsal record" $ \record -> do
    candidate <- record .: "candidate"
    source <- record .: "source"
    sentinel <- record .: "sentinel"
    RehearsalCheck
      <$> withObject "candidate" (.: "revision") candidate
      <*> withObject "source" (.: "version") source
      <*> withObject "sentinel" (.: "seeded") sentinel
      <*> withObject "sentinel" (.: "readBack") sentinel

-- | What publication and a rerun read of @<run>/intranet.json@.
data IntranetCheck = IntranetCheck
  { version :: !Text
  , revision :: !Text
  , compatibility :: !Text
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON IntranetCheck where
  parseJSON = withObject "intranet record" $ \record ->
    IntranetCheck
      <$> record .: "version"
      <*> record .: "revision"
      <*> (record .: "status" >>= withObject "status" (.: "compatibility"))

-- | The intranet record shows the context exact on this candidate.
intranetOn :: Text -> Text -> IntranetCheck -> Bool
intranetOn version' revision' check =
  check ^. #version == version' && check ^. #revision == revision' && check ^. #compatibility == "exact"

decodeDocument :: (FromJSON a) => Text -> ByteString -> Either Text a
decodeDocument label bytes = first (\reason -> label <> ": " <> T.pack reason) (eitherDecodeStrict bytes)

readDocument :: (FromJSON a) => FilePath -> IO (Either Text a)
readDocument path = first (\reason -> T.pack (path <> ": " <> reason)) <$> eitherDecodeFileStrict path

type ByteString = BS.ByteString

-- | @.nodes.nagare.locked.rev@ of a flake lock.
lockedRevision :: Value -> Maybe Text
lockedRevision = either (const Nothing) Just . parseEither (withObject "lock" ((.: "nodes") >=> withObject "nodes" (.: "nagare") >=> withObject "node" (.: "locked") >=> withObject "locked" (.: "rev")))

-- | Platform status is exact: compatibility @exact@, every component at the
-- version and revision, and the context pinned to the version.
exactOn :: Text -> Text -> PlatformStatus -> Bool
exactOn version' revision' status =
  status ^. #compatibility == "exact"
    && all matches [ids ^. #cli, ids ^. #payload, ids ^. #host, ids ^. #cluster]
    && ids ^. #context . #version == Just version'
  where
    ids = status ^. #identities
    matches identity = identity ^. #version == Just version' && identity ^. #revision == Just revision'

-- | The accepted scope revisions that have not converged, by name: those the
-- release answers for, and those of an application or its deploy hook
-- (@Standalone/app-hook-…@), which are that application's to fix.
unconvergedScopes :: InventoryStatus -> ([Text], [Text])
unconvergedScopes status = (map scopeLabel platform, map scopeLabel applications)
  where
    (applications, platform) = partition ofApplication (filter (`notElem` fromMaybe [] (status ^. #converged)) (fromMaybe [] (status ^. #accepted)))
    ofApplication entry = scopeField "kind" entry == Just "Application" || (scopeField "kind" entry == Just "Standalone" && maybe False ("app-hook-" `T.isPrefixOf`) (scopeField "name" entry))
    scopeField key entry = either (const Nothing) Just (parseEither (withObject "scope revision" ((.: "scope") >=> withObject "scope" (.: key))) entry) :: Maybe Text
    scopeLabel entry = fromMaybe "?" (scopeField "kind" entry) <> "/" <> fromMaybe "?" (scopeField "name" entry)

-- | No open transaction, and every accepted scope revision has converged
-- except an application's own. Those are reported, not a refusal.
platformConverged :: InventoryStatus -> Bool
platformConverged status = isNothing (status ^. #activeTransaction) && null (fst (unconvergedScopes status))

rehearsalMatches :: Text -> Text -> RehearsalCheck -> Bool
rehearsalMatches revision' previous' check =
  check ^. #candidateRevision == Just revision'
    && check ^. #sourceVersion == Just previous'
    && check ^. #seeded == check ^. #readBack

-- | Two-space indented JSON with every object's keys sorted, as @jq -S@ and
-- Python's @sort_keys@ print it.
encodeSorted :: Value -> BL.ByteString
encodeSorted = encodePretty' defConfig {confIndent = Spaces 2, confCompare = compare}

-- | Write a sorted document; @newline@ ends it with one, as @jq@ does.
writeSorted :: Bool -> FilePath -> Value -> IO ()
writeSorted newline path document = BL.writeFile path (encodeSorted document <> (if newline then "\n" else ""))

-- | 'writeSorted' through a temporary file and a rename.
writeSortedAtomically :: FilePath -> Value -> IO ()
writeSortedAtomically path document = writeSorted True (path <> ".tmp") document >> renameFile (path <> ".tmp") path
