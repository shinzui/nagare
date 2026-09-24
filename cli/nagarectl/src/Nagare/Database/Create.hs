-- | @nagarectl db create ENGINE NAME@ (MasterPlan 9, EP-45): generate a strong
-- password, write the managed credential Secret (IP3), then provision the
-- PVC/StatefulSet/Service (and, for ClickHouse, the memory ConfigMap) EP-44's
-- renderer produces, in apply order, and wait for the StatefulSet to be Ready.
--
-- The desired 'Database' is built in memory from argv plus flags through EP-44's
-- smart constructors (full validation, no config file needed); a @--config@ path
-- loads a typed 'Database' instead. The password is generated once and reused on
-- re-create (idempotent): the create path never issues @kubectl delete@, so it
-- can never wipe data. @--dry-run@ names the credential Secret without
-- generating or printing a password, then prints non-secret manifests.
module Nagare.Database.Create
  ( DbCreateParams (..)
  , runDbCreate
  , buildDatabase
  , resolveDatabase
  , passwordKey
  , classifyPasswordObservation
  , ensureCredential
  )
where

import Cradle
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Cluster.Namespace (NamespacePurpose (..), ensureNamespace, renderNamespace)
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
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (stderr)
import System.IO (hClose)
import System.IO.Temp (withSystemTempFile)

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
runDbCreate eng nameT params = do
  transaction <- lookupEnv "NAGARE_INVENTORY_TRANSACTION"
  when (isJust transaction) $
    dieT "db create cannot run inside a reviewed inventory transaction"
  db <- resolveDatabase eng nameT params
  let name = databaseNameText (db ^. #name)
      ns = namespaceText (db ^. #namespace)
      engine' = db ^. #engine
      purpose = params ^. #namespacePurpose
      host = dbHost name ns
      mkParts pw =
        ConnectionParts
          { user = defaultDbUser
          , password = pw
          , host = host
          , database = sanitizeDbName name
          }
      manifests = renderDatabase db
      -- EP-47: a managed database is backup-included by default — a daily,
      -- self-pruning CronJob — unless retention = Delete (treated as throwaway).
      backsUp = (db ^. #retention) /= Delete
  let tp = params ^. #targetProfile
      bucket = tp ^. #backupBucket
  backend <- either dieT pure (storeBackendFor tp bucket)
  let cronJob = renderDbBackupCronJob ns name engine' (engineVersionText (db ^. #version)) backend 7
  if params ^. #dryRun
    then do
      namespaceManifest <- orDie (renderNamespace purpose ns)
      TIO.putStrLn "--- Namespace manifest ---"
      TIO.putStr (TE.decodeUtf8 namespaceManifest)
      TIO.putStrLn ""
      TIO.putStrLn ("--- Credential Secret " <> dbSecretName name <> " (data generated at apply; omitted from dry run) ---")
      mapM_ printManifest manifests
      when backsUp $ do
        TIO.putStrLn "--- Backup CronJob manifest ---"
        TIO.putStr (TE.decodeUtf8 cronJob)
        TIO.putStrLn ""
      TIO.putStrLn
        ("Would create database " <> name <> " (" <> engineToken engine' <> ") at " <> host)
    else do
      ensureNamespace purpose ns >>= orDie
      _ <- ensureDatabaseSecret ns name engine' mkParts
      applyManifests manifests
      stampMetadata ns name db
      when backsUp (applyManifests [cronJob])
      waitForRollout ns (statefulSetName name)
        >>= requireWait ("database '" <> name <> "'")
      TIO.putStrLn
        ("Created database " <> name <> " (" <> engineToken engine' <> ") at " <> host)

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

-- | Read the existing credential or create it with the API server's create-only
-- operation. A concurrent creator wins; its value is reread rather than
-- overwritten. No failure to read may authorize a new credential.
ensureDatabaseSecret :: Text -> Text -> Engine -> (Text -> ConnectionParts) -> IO Text
ensureDatabaseSecret ns name eng makeConnection =
  ensureCredential (readPasswordObservation ns name eng) generatePassword createOnly >>= either dieT pure
  where
    createOnly password = do
      let secret = renderDbSecret (DbSecretInputs name ns eng (secretKeysFor eng (makeConnection password)))
      created <- withSystemTempFile "nagare-db-secret.json" $ \path handle -> do
        BS.hPut handle secret
        hClose handle
        run $ cmd "kubectl" & addArgs ["create", "-f", path] & silenceStderr
      pure (created == ExitSuccess)

-- | Creation is conditional at the API server. On a race, use the winner's
-- credential only after a second confirmed read; never overwrite it.
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

readPasswordObservation :: Text -> Text -> Engine -> IO (Either Text (Maybe Text))
readPasswordObservation ns name eng = do
  (code, StdoutRaw out) <-
    run $
      cmd "kubectl"
        & addArgs ["get", "secret", T.unpack (dbSecretName name), "-n", T.unpack ns, "-o", "json", "--ignore-not-found"]
        & silenceStderr
  pure (classifyPasswordObservation eng code out)

-- | Only a successful, empty --ignore-not-found response proves absence.
-- Failed or malformed reads never authorize a replacement credential.
classifyPasswordObservation :: Engine -> ExitCode -> ByteString -> Either Text (Maybe Text)
classifyPasswordObservation eng code out = case code of
  ExitFailure _ -> Left "could not read database Secret; refusing to create a new password from an unknown observation"
  ExitSuccess | BS.null out -> Right Nothing
  ExitSuccess -> case extractSecretData out of
    Right kvs | Just pw <- Map.lookup (passwordKey eng) kvs, not (T.null pw) -> Right (Just pw)
    _ -> Left "database Secret is malformed or lacks its password; refusing to rotate it"

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
