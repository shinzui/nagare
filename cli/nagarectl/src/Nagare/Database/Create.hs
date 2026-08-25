-- | @nagarectl db create ENGINE NAME@ (MasterPlan 9, EP-45): generate a strong
-- password, write the managed credential Secret (IP3), then provision the
-- PVC/StatefulSet/Service (and, for ClickHouse, the memory ConfigMap) EP-44's
-- renderer produces, in apply order, and wait for the StatefulSet to be Ready.
--
-- The desired 'Database' is built in memory from argv plus flags through EP-44's
-- smart constructors (full validation, no config file needed); a @--config@ path
-- loads a typed 'Database' instead. The password is generated once and reused on
-- re-create (idempotent): the create path never issues @kubectl delete@, so it
-- can never wipe data. @--dry-run@ prints the Secret (with an illustrative
-- password) and the manifests and applies nothing.
module Nagare.Database.Create
  ( DbCreateParams (..)
  , runDbCreate
  , buildDatabase
  , passwordKey
  )
where

import Cradle
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Database.Backup (renderDbBackupCronJob)
import Nagare.Database.Secret
import Nagare.Deploy (applyManifests, requireWait, waitForRollout)
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
import Nagare.Dsl.Database.Render (renderDatabase, statefulSetName)
import Nagare.Dsl.Load (loadDatabase, renderLoadError)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types
  ( Resources (..)
  , RetentionPolicy (..)
  , databaseNameText
  , mkNamespace
  , mkQuantity
  , namespaceText
  , quantityText
  )
import Nagare.Env.Store (extractSecretData)
import Nagare.Target (TargetProfile (..), storeBackendFor)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (stderr)

-- | The create inputs, unpacked from @Main@'s @DbCreateOpts@ so the library does
-- not depend on the executable's option types.
data DbCreateParams = DbCreateParams
  { dcpNamespace :: !Text
  , dcpVersion :: !(Maybe Text)
  , dcpSize :: !(Maybe Text)
  , dcpCpu :: !(Maybe Text)
  , dcpMemory :: !(Maybe Text)
  , dcpConfig :: !(Maybe FilePath)
  , dcpDryRun :: !Bool
  , dcpTargetProfile :: !TargetProfile
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
  ver' <- case dcpVersion params of
    Nothing -> Right (defaultEngineVersion eng)
    Just v -> mkEngineVersion eng v
  ns' <- mkNamespace (dcpNamespace params)
  size' <- mkQuantity (fromMaybe (defaultSize eng) (dcpSize params))
  res' <- buildResources (dcpCpu params) (dcpMemory params)
  Right
    Database
      { dbName = name'
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
runDbCreate eng nameT params = do
  db <- case dcpConfig params of
    Just path -> do
      eDb <- loadDatabase path
      case eDb of
        Left err -> dieT (renderLoadError err)
        Right d -> pure d
    Nothing -> orDie (buildDatabase eng nameT params)
  let name = databaseNameText (db ^. #dbName)
      ns = namespaceText (db ^. #namespace)
      engine' = db ^. #engine
      host = dbHost name ns
      mkParts pw =
        ConnectionParts
          { cpUser = defaultDbUser
          , cpPassword = pw
          , cpHost = host
          , cpDb = sanitizeDbName name
          }
      manifests = renderDatabase db
      -- EP-47: a managed database is backup-included by default — a daily,
      -- self-pruning CronJob — unless retention = Delete (treated as throwaway).
      backsUp = (db ^. #retention) /= Delete
  let tp = dcpTargetProfile params
      bucket = tpBackupBucket tp
  backend <- either dieT pure (storeBackendFor tp bucket)
  let cronJob = renderDbBackupCronJob ns name engine' (engineVersionText (db ^. #version)) backend 7
  if dcpDryRun params
    then do
      pw <- generatePassword
      let kvs = secretKeysFor engine' (mkParts pw)
          secret = renderDbSecret (DbSecretInputs name ns engine' kvs)
      TIO.putStrLn "--- Secret manifest ---"
      TIO.putStr (TE.decodeUtf8 secret)
      TIO.putStrLn ""
      mapM_ printManifest manifests
      when backsUp $ do
        TIO.putStrLn "--- Backup CronJob manifest ---"
        TIO.putStr (TE.decodeUtf8 cronJob)
        TIO.putStrLn ""
      TIO.putStrLn
        ("Would create database " <> name <> " (" <> engineToken engine' <> ") at " <> host)
    else do
      pw <- readOrGeneratePassword ns name engine'
      let kvs = secretKeysFor engine' (mkParts pw)
          secret = renderDbSecret (DbSecretInputs name ns engine' kvs)
      applyManifests [secret]
      applyManifests manifests
      stampMetadata ns name db
      when backsUp (applyManifests [cronJob])
      waitForRollout ns (statefulSetName name)
        >>= requireWait ("database '" <> name <> "'")
      TIO.putStrLn
        ("Created database " <> name <> " (" <> engineToken engine' <> ") at " <> host)

-- | Read the existing password from the managed Secret (idempotent re-create) or
-- generate a fresh one when the Secret is absent.
readOrGeneratePassword :: Text -> Text -> Engine -> IO Text
readOrGeneratePassword ns name eng = do
  (code, StdoutRaw out) <-
    run $
      cmd "kubectl"
        & addArgs ["get", "secret", T.unpack (dbSecretName name), "-n", T.unpack ns, "-o", "json"]
        & silenceStderr
  case code of
    ExitFailure _ -> generatePassword
    ExitSuccess -> case extractSecretData out of
      Right kvs | Just pw <- Map.lookup (passwordKey eng) kvs, not (T.null pw) -> pure pw
      _ -> generatePassword

-- | Generate a strong URL-safe password via @openssl rand -hex 24@ (192 bits).
generatePassword :: IO Text
generatePassword = do
  (code, StdoutRaw out) <-
    run $ cmd "openssl" & addArgs (["rand", "-hex", "24"] :: [String]) & silenceStderr
  case code of
    ExitSuccess -> pure (T.strip (TE.decodeUtf8 out))
    ExitFailure _ -> dieT "could not generate a password: 'openssl rand' failed"

-- | Stamp version/size/retention as annotations on the StatefulSet so
-- @db list@/@get@/@delete@ can read state back (EP-44's renderer stamps only the
-- managed-by/database/engine labels). Idempotent (@--overwrite@); best-effort.
stampMetadata :: Text -> Text -> Database -> IO ()
stampMetadata ns name db =
  run_ $
    cmd "kubectl"
      & addArgs
        [ "annotate"
        , "statefulset/" <> T.unpack name
        , "-n"
        , T.unpack ns
        , "--overwrite"
        , "nagare.dev/version=" <> T.unpack (engineVersionText (db ^. #version))
        , "nagare.dev/size=" <> T.unpack (quantityText (db ^. #size))
        , "nagare.dev/retention=" <> retentionToken (db ^. #retention)
        ]
  where
    retentionToken Retain = "Retain"
    retentionToken Delete = "Delete"

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
