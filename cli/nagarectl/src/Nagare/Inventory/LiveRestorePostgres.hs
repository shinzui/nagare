-- | PostgreSQL's live restore and full logical postcondition. The restore
-- runs in one psql transaction over the server Pod's local socket; a lost
-- client acknowledgement remains uncertain until a fresh dump is compared.
module Nagare.Inventory.LiveRestorePostgres
  ( normalizePostgresDump
  , runLivePostgresRestore
  , dumpLivePostgres
  ) where

import Control.Exception (IOException, catch, try)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.KubernetesRuntime (KubernetesRuntimeConfig (..))
import Nagare.Inventory.DataFence.MaintenancePostgres
import Nagare.Inventory.LiveRestore (LiveRestoreProof (..))
import Nagare.Resource.Types (physicalIdentityText)
import System.Exit (ExitCode (..))
import System.IO (BufferMode (NoBuffering), Handle, IOMode (..), hClose,
  hSetBuffering, withBinaryFile)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (..), createProcess, proc,
  waitForProcess)

-- | PostgreSQL 18 randomizes one paired psql guard token per pg_dump. Remove
-- only that exact pair; any other change to the logical dump remains visible.
normalizePostgresDump :: ByteString -> Either Text ByteString
normalizePostgresDump raw = do
  let rows = BC.lines raw
      restrictions = [token | row <- rows,
        Just token <- [BC.stripPrefix "\\restrict " row]]
      unrestrictions = [token | row <- rows,
        Just token <- [BC.stripPrefix "\\unrestrict " row]]
      validToken token = not (BS.null token) && BS.length token <= 128
        && BC.all (\character -> isAsciiLower character
          || isAsciiUpper character || isDigit character) token
  case (restrictions, unrestrictions) of
    ([], []) -> pure raw
    ([selected], [closing])
      | selected == closing && validToken selected -> do
          let kept = filter (\row -> row /= "\\restrict " <> selected
                && row /= "\\unrestrict " <> selected) rows
              suffix = if BS.isSuffixOf "\n" raw then "\n" else ""
          pure (BC.intercalate "\n" kept <> suffix)
    _ -> Left "PostgreSQL dump has unmatched or malformed psql guard tokens"

-- | This mutates only the selected database schema. PostgreSQL rolls both the
-- schema reset and the complete dump back on a known SQL error; a lost exec
-- result still needs the independent full-dump verifier under the fence.
runLivePostgresRestore :: KubernetesRuntimeConfig -> LiveRestoreProof
  -> FilePath -> IO (Either Text ())
runLivePostgresRestore config proof sourcePath = withPinnedPod config proof $ do
  let script = "PGAPPNAME=nagare-maintenance-lr-" <> liveRestoreProofId proof
        <> " PGPASSWORD=\"$POSTGRES_PASSWORD\" exec psql -X -1"
        <> " -v ON_ERROR_STOP=1 -U \"$POSTGRES_USER\""
        <> " -d \"$POSTGRES_DB\" -f -"
      command = kubectlProcess config proof ["exec", "-i",
        T.unpack (liveRestoreProofDatabase proof <> "-0"),
        "--container", "postgres", "--", "sh", "-c", T.unpack script]
      prefix = "DO $nagare$ DECLARE selected_schema text; BEGIN "
        <> "FOR selected_schema IN SELECT nspname FROM pg_namespace "
        <> "WHERE nspname <> 'information_schema' AND nspname NOT LIKE 'pg_%' "
        <> "LOOP EXECUTE format('DROP SCHEMA %I CASCADE', selected_schema); "
        <> "END LOOP; END $nagare$;\n"
        <> "CREATE SCHEMA public; "
        <> "ALTER SCHEMA public OWNER TO pg_database_owner; "
        <> "COMMENT ON SCHEMA public IS 'standard public schema';\n"
  started <- try (createProcess command
    {std_in = CreatePipe, std_out = NoStream, std_err = NoStream})
    :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle,
      ProcessHandle))
  case started of
    Left _ -> pure (Left "could not start PostgreSQL live restore")
    Right (Just input, _, _, process) -> do
      written <- try (do
        hSetBuffering input NoBuffering
        BS.hPut input prefix
        withBinaryFile sourcePath ReadMode (copyTo input))
        :: IO (Either IOException ())
      hClose input `catch` \(_ :: IOException) -> pure ()
      outcome <- waitForProcess process
      pure $ case (written, outcome) of
        (Right (), ExitSuccess) -> Right ()
        _ -> Left "PostgreSQL live restore outcome is unconfirmed"
    Right _ -> pure (Left "PostgreSQL live restore has no input stream")

-- | Dump the exact live database after the effect through the same pinned
-- Pod. The caller compares normalized bytes against the verified source.
dumpLivePostgres :: KubernetesRuntimeConfig -> LiveRestoreProof
  -> FilePath -> IO (Either Text ())
dumpLivePostgres config proof outputPath = withPinnedPod config proof $ do
  let script = "PGAPPNAME=nagare-maintenance-lr-" <> liveRestoreProofId proof
        <> " PGPASSWORD=\"$POSTGRES_PASSWORD\" exec pg_dump"
        <> " --no-owner --no-privileges -U \"$POSTGRES_USER\""
        <> " -d \"$POSTGRES_DB\""
      command = kubectlProcess config proof ["exec",
        T.unpack (liveRestoreProofDatabase proof <> "-0"),
        "--container", "postgres", "--", "sh", "-c", T.unpack script]
  result <- try (withBinaryFile outputPath WriteMode $ \output -> do
      (_, _, _, process) <- createProcess command
        {std_in = NoStream, std_out = UseHandle output, std_err = NoStream}
      waitForProcess process) :: IO (Either IOException ExitCode)
  pure $ case result of
    Right ExitSuccess -> Right ()
    _ -> Left "PostgreSQL live logical dump is unavailable"

withPinnedPod :: KubernetesRuntimeConfig -> LiveRestoreProof
  -> IO (Either Text a) -> IO (Either Text a)
withPinnedPod config proof action = do
  guarded <- runtimeGuard config
  case guarded of
    Left reason -> pure (Left ("cluster guard refused: " <> reason))
    Right () -> do
      let transport = kubectlPostgresMaintenanceTransport config
          namespace = liveRestoreProofNamespace proof
          pod = liveRestoreProofDatabase proof <> "-0"
          uid = physicalIdentityText (liveRestoreProofPodUid proof)
          observe = observePostgresPodUid transport namespace pod
      before <- observe
      case before of
        Right current | current == uid -> do
          result <- action
          after <- observe
          pure $ do
            value <- result
            observed <- after
            unless (observed == uid)
              (Left "PostgreSQL live restore Pod incarnation changed")
            pure value
        Right _ -> pure (Left "PostgreSQL live restore Pod incarnation changed")
        Left reason -> pure (Left reason)

kubectlProcess :: KubernetesRuntimeConfig -> LiveRestoreProof
  -> [String] -> CreateProcess
kubectlProcess config proof arguments = proc "kubectl"
  (["--context", T.unpack (runtimeKubectlContext config),
    "--namespace", T.unpack (liveRestoreProofNamespace proof)] <> arguments)

copyTo :: Handle -> Handle -> IO ()
copyTo target source = do
  chunk <- BS.hGetSome source 65536
  unless (BS.null chunk) (BS.hPut target chunk >> copyTo target source)
