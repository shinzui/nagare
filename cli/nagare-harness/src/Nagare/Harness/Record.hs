-- | The revision-bound gate records (EP-174). @nagare-harness gate --full@
-- writes a full record and @gate --fast@ on a clean tree writes a fast one;
-- @gate verify@ and @gate landable@ read them. They live under
-- @$XDG_STATE_HOME/nagare/gates/@ because they describe one machine's
-- verification, not source.
module Nagare.Harness.Record
  ( BuilderProbe (..)
  , FastRecord (..)
  , GateRecord (..)
  , SystemRealisation (..)
  , readFastRecord
  , readRecord
  , recentRecordCommits
  , recordPath
  , writeFastRecord
  , writeRecord
  )
where

import Data.Aeson (FromJSON, ToJSON, eitherDecodeFileStrict)
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString.Lazy qualified as BL
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Ord (Down (..))
import Data.Text qualified as T
import Nagare.Harness.Prelude
import Nagare.Harness.Step (StepResult)
import System.Directory (XdgDirectory (XdgState), createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getModificationTime, getXdgDirectory, listDirectory)
import System.FilePath (dropExtension, takeDirectory, takeExtension, (</>))

-- | Every check attribute of one system, and what a dry run says is still
-- missing. @realised@ equals @checks@ only when @remaining@ is empty.
data SystemRealisation = SystemRealisation
  { checks :: !Int
  , realised :: !Int
  , remaining :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A salted derivation built for @system@ right now, so a down builder
-- cannot hide behind cached outputs.
data BuilderProbe = BuilderProbe
  { system :: !Text
  , ok :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data GateRecord = GateRecord
  { version :: !Int
  , commit :: !Text
  , tree :: !Text
  , clean :: !Bool
  , steps :: ![StepResult]
  , systems :: !(Map Text SystemRealisation)
  , builderProbe :: !BuilderProbe
  , tools :: !(Map Text Text)
  , green :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The fast gate's result for a clean commit: the static checks and both
-- suites, built incrementally on this machine. @just land@ accepts it, and the
-- full gate then runs on the landed commit in the background.
data FastRecord = FastRecord
  { version :: !Int
  , commit :: !Text
  , tree :: !Text
  , steps :: ![StepResult]
  , green :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

recordPath :: Text -> IO FilePath
recordPath commitId = do
  base <- getXdgDirectory XdgState "nagare/gates"
  pure (base </> (T.unpack commitId <> ".json"))

writeRecord :: GateRecord -> IO FilePath
writeRecord record = do
  path <- recordPath (record ^. #commit)
  createDirectoryIfMissing True (takeDirectory path)
  BL.writeFile path (encodePretty record <> "\n")
  pure path

-- | @Nothing@ when no record exists for the commit.
readRecord :: Text -> IO (Either Text (Maybe GateRecord))
readRecord commitId = do
  path <- recordPath commitId
  present <- doesFileExist path
  if not present
    then pure (Right Nothing)
    else first (\err -> T.pack (path <> ": " <> err)) . fmap Just <$> eitherDecodeFileStrict path

fastRecordPath :: Text -> IO FilePath
fastRecordPath commitId = do
  base <- getXdgDirectory XdgState "nagare/gates/fast"
  pure (base </> (T.unpack commitId <> ".json"))

writeFastRecord :: FastRecord -> IO FilePath
writeFastRecord record = do
  path <- fastRecordPath (record ^. #commit)
  createDirectoryIfMissing True (takeDirectory path)
  BL.writeFile path (encodePretty record <> "\n")
  pure path

-- | @Nothing@ when no fast record exists for the commit.
readFastRecord :: Text -> IO (Either Text (Maybe FastRecord))
readFastRecord commitId = do
  path <- fastRecordPath commitId
  present <- doesFileExist path
  if not present
    then pure (Right Nothing)
    else first (\err -> T.pack (path <> ": " <> err)) . fmap Just <$> eitherDecodeFileStrict path

-- | The commits of the @limit@ most recently written records, newest first.
recentRecordCommits :: Int -> IO [Text]
recentRecordCommits limit = do
  base <- takeDirectory <$> recordPath "x"
  present <- doesDirectoryExist base
  if not present
    then pure []
    else do
      names <- filter ((== ".json") . takeExtension) <$> listDirectory base
      stamped <- forM names $ \name -> (,name) <$> getModificationTime (base </> name)
      pure [T.pack (dropExtension name) | (_, name) <- take limit (sortOn (Down . fst) stamped)]
