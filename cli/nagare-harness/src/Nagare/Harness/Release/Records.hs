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
  , decodeDocument
  , readDocument
  , lockedRevision
  , exactOn
  , everyAcceptedConverged
  , rehearsalMatches
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
newtype StoreStatus = StoreStatus {activeTransaction :: Maybe Value}
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

-- | No open transaction, and every accepted scope revision has converged.
everyAcceptedConverged :: InventoryStatus -> Bool
everyAcceptedConverged status =
  isNothing (status ^. #activeTransaction) && all (`elem` fromMaybe [] (status ^. #converged)) (fromMaybe [] (status ^. #accepted))

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
