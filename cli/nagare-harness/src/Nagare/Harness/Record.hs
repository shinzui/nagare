-- | The revision-bound gate record (EP-174). @nagare-harness gate --full@
-- writes it; @gate verify@ and the acceptance harness (EP-168) read it. It
-- lives under @$XDG_STATE_HOME/nagare/gates/<commit>.json@ because it
-- describes one machine's verification, not source.
module Nagare.Harness.Record
  ( BuilderProbe (..)
  , GateRecord (..)
  , SystemRealisation (..)
  , readRecord
  , recordPath
  , writeRecord
  )
where

import Data.Aeson (FromJSON, ToJSON, eitherDecodeFileStrict)
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString.Lazy qualified as BL
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Text qualified as T
import Nagare.Harness.Prelude
import Nagare.Harness.Step (StepResult)
import System.Directory (XdgDirectory (XdgState), createDirectoryIfMissing, doesFileExist, getXdgDirectory)
import System.FilePath (takeDirectory, (</>))

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
