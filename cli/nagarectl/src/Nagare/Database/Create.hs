-- | Read-only compatibility rendering for @nagarectl db create --dry-run@.
--
-- The desired 'Database' is built in memory from argv plus flags through EP-44's
-- smart constructors (full validation, no config file needed); a @--config@ path
-- loads a typed 'Database' instead. The password is generated once and reused on
-- live create uses the reviewed standalone database scope. @--dry-run@ names
-- the credential Secret without generating or printing a password.
module Nagare.Database.Create
  ( DbCreateParams (..)
  , runDbCreate
  , runDbCreateWithGuard
  , buildDatabase
  , resolveDatabase
  , passwordKey
  , classifyPasswordObservation
  , ensureCredential
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Cluster.Namespace (NamespacePurpose (..), renderNamespace)
import Nagare.Database.Backup (renderDbBackupCronJob)
import Nagare.Database.Secret (dbHost)
import Nagare.Dsl.Database
  ( Database (..)
  , Engine (..)
  , dbSecretName
  , defaultEngineVersion
  , engineToken
  , engineVersionText
  , mkDatabaseName
  , mkEngineVersion
  )
import Nagare.Dsl.Database.Render (renderDatabase)
import Nagare.Dsl.Load (loadDatabase, renderLoadError)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types
  ( Resources (..)
  , RetentionPolicy (..)
  , databaseNameText
  , mkNamespace
  , mkQuantity
  , namespaceText
  )
import Nagare.Env.Store (extractSecretData)
import Nagare.Target (TargetProfile (..), storeBackendFor)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (stderr)

-- | The create inputs, unpacked from @Main@'s @DbCreateOpts@ so the library does
-- not depend on the executable's option types.
data DbCreateParams = DbCreateParams
  { namespace :: !Text
  , namespacePurpose :: !NamespacePurpose
  , version :: !(Maybe Text)
  , size :: !(Maybe Text)
  , cpu :: !(Maybe Text)
  , memory :: !(Maybe Text)
  , config :: !(Maybe FilePath)
  , dryRun :: !Bool
  , targetProfile :: !TargetProfile
  }
  deriving stock (Generic, Show)

-- | The default data-volume size per engine when @--size@ is absent.
defaultSize :: Engine -> Text
defaultSize Redis = "2Gi"
defaultSize _ = "10Gi"

-- | The Secret key holding the generated password, per engine.
passwordKey :: Engine -> Text
passwordKey Postgres = "POSTGRES_PASSWORD"
passwordKey Redis = "REDIS_PASSWORD"
passwordKey ClickHouse = "CLICKHOUSE_PASSWORD"

-- | Build and validate the desired 'Database' from create inputs, through EP-44's
-- smart constructors. Pure and total; returns a precise message on bad input.
buildDatabase :: Engine -> Text -> DbCreateParams -> Either Text Database
buildDatabase eng nameT params = do
  name' <- mkDatabaseName nameT
  ver' <- case params ^. #version of
    Nothing -> Right (defaultEngineVersion eng)
    Just v -> mkEngineVersion eng v
  ns' <- mkNamespace (params ^. #namespace)
  size' <- mkQuantity (fromMaybe (defaultSize eng) (params ^. #size))
  res' <- buildResources (params ^. #cpu) (params ^. #memory)
  Right
    Database
      { name = name'
      , logicalKey = Nothing
      , engine = eng
      , version = ver'
      , namespace = ns'
      , size = size'
      , resources = res'
      , retention = Retain
      }

buildResources :: Maybe Text -> Maybe Text -> Either Text (Maybe Resources)
buildResources Nothing Nothing = Right Nothing
buildResources mc mm = do
  cl <- traverse mkQuantity mc
  ml <- traverse mkQuantity mm
  Right (Just Resources {cpu = Nothing, memory = Nothing, cpuLimit = cl, memoryLimit = ml})

-- | Run @db create@.
runDbCreate :: Engine -> Text -> DbCreateParams -> IO ()
runDbCreate eng nameT params = runDbCreateWithGuard eng nameT params (const (pure ()))

-- | Check the exact loaded database before any provider mutation. In
-- particular, a Config.hs value may name a different object from argv.
runDbCreateWithGuard :: Engine -> Text -> DbCreateParams -> (Database -> IO ()) -> IO ()
runDbCreateWithGuard eng nameT params checkOwnership = do
  unless (params ^. #dryRun) $
    dieT "live db create requires a reviewed standalone database scope"
  db <- resolveDatabase eng nameT params
  checkOwnership db
  let name = databaseNameText (db ^. #name)
      ns = namespaceText (db ^. #namespace)
      engine' = db ^. #engine
      purpose = params ^. #namespacePurpose
      host = dbHost name ns
      manifests = renderDatabase db
      -- EP-47: a managed database is backup-included by default — a daily,
      -- self-pruning CronJob — unless retention = Delete (treated as throwaway).
      backsUp = (db ^. #retention) /= Delete
  let tp = params ^. #targetProfile
      bucket = tp ^. #backupBucket
  backend <- either dieT pure (storeBackendFor tp bucket)
  let cronJob = renderDbBackupCronJob ns name engine' (engineVersionText (db ^. #version)) backend 7
  namespaceManifest <- orDie (renderNamespace purpose ns)
  TIO.putStrLn "--- Namespace manifest ---"
  TIO.putStr (TE.decodeUtf8 namespaceManifest)
  TIO.putStrLn ""
  TIO.putStrLn ("--- Credential Secret " <> dbSecretName name <> " (data generated at reviewed apply; omitted from dry run) ---")
  mapM_ printManifest manifests
  when backsUp $ do
    TIO.putStrLn "--- Backup CronJob manifest ---"
    TIO.putStr (TE.decodeUtf8 cronJob)
    TIO.putStrLn ""
  TIO.putStrLn
    ("Would create database " <> name <> " (" <> engineToken engine' <> ") at " <> host)

-- | Both the direct compatibility path and inventory planning load exactly the
-- same validated typed value.
resolveDatabase :: Engine -> Text -> DbCreateParams -> IO Database
resolveDatabase eng nameT params = case params ^. #config of
    Just path -> do
      eDb <- loadDatabase path
      case eDb of
        Left err -> dieT (renderLoadError err)
        Right d -> pure d
    Nothing -> orDie (buildDatabase eng nameT params)

-- | The pure create-only credential decision helper retained for callers that
-- supply their own reviewed observation and mutation adapter.
ensureCredential
  :: IO (Either Text (Maybe Text))
  -> IO Text
  -> (Text -> IO Bool)
  -> IO (Either Text Text)
ensureCredential observe generate createOnly = do
  firstRead <- observe
  case firstRead of
    Left reason -> pure (Left reason)
    Right (Just password) -> pure (Right password)
    Right Nothing -> do
      password <- generate
      created <- createOnly password
      if created then pure (Right password) else do
        secondRead <- observe
        pure $ case secondRead of
          Right (Just winner) -> Right winner
          Right Nothing -> Left "database Secret create failed and no valid concurrent Secret exists"
          Left reason -> Left reason

-- | Only a successful, empty --ignore-not-found response proves absence.
-- Failed or malformed reads never authorize a replacement credential.
classifyPasswordObservation :: Engine -> ExitCode -> ByteString -> Either Text (Maybe Text)
classifyPasswordObservation eng code out = case code of
  ExitFailure _ -> Left "could not read database Secret; refusing to create a new password from an unknown observation"
  ExitSuccess | BS.null out -> Right Nothing
  ExitSuccess -> case extractSecretData out of
    Right kvs | Just pw <- Map.lookup (passwordKey eng) kvs, not (T.null pw) -> Right (Just pw)
    _ -> Left "database Secret is malformed or lacks its password; refusing to rotate it"

-- | Print one manifest with a @--- <Kind> manifest ---@ header.
printManifest :: ByteString -> IO ()
printManifest m = do
  TIO.putStrLn ("--- " <> manifestKind m <> " manifest ---")
  TIO.putStr (TE.decodeUtf8 m)
  TIO.putStrLn ""

-- | Find the YAML @kind:@ value in a rendered manifest (for the dry-run header).
manifestKind :: ByteString -> Text
manifestKind m =
  case [T.strip (T.drop 5 l) | l <- T.lines (TE.decodeUtf8 m), "kind:" `T.isPrefixOf` l] of
    (k : _) -> k
    [] -> "resource"

dieT :: Text -> IO a
dieT msg = do
  TIO.hPutStrLn stderr ("nagarectl: " <> msg)
  exitFailure

orDie :: Either Text a -> IO a
orDie = either dieT pure
