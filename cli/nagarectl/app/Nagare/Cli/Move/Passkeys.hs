-- | @remove-passkeys@ of a move to a new base domain (EP-246 D4). A browser refuses a passkey on another
-- domain and Shomei gates sign-in on any stored passkey, so the move exports every passkey to a
-- sops-encrypted file in the context's secrets directory and only then removes exactly those rows.
-- Undoing the step restores the table to the export. The SQL is the payload's
-- @cluster/bootstrap/shomei/move/@, the same the real-Shomei test runs.
module Nagare.Cli.Move.Passkeys
  ( removePasskeys
  , restorePasskeys
  , passkeyExportFile
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict, encode, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy.Char8 qualified as LBC
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Access.ShomeiMove (bindRows, expectedPasskeyColumns, passkeyIds, runShomeiSql)
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Target (resolvePlatformWorkspace)
import Nagare.Context.Move (StepOutcome (..))
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Components.ObservabilitySecrets (contextSecretsDirectory)
import Nagare.Target (ActiveTarget, contextNameText)
import System.Directory (doesFileExist, renameFile)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Files (ownerReadMode, ownerWriteMode, setFileMode, unionFileModes)
import System.Process (proc, readCreateProcessWithExitCode)

-- | Kept until @context move retire@, which deletes it (D7).
passkeyExportFile :: FilePath
passkeyExportFile = "move-passkeys.sops.yaml"

data PasskeyContext = PasskeyContext
  { root :: !FilePath
  , export :: !FilePath
  , secrets :: !FilePath
  , run :: !(Bool -> String -> IO (Either Text Text))
  }
  deriving stock (Generic)

passkeyContext :: ActiveTarget -> IO PasskeyContext
passkeyContext active = do
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  let context = contextNameText (active ^. #contextName)
  directory <- contextSecretsDirectory (workspace ^. #root) context
  pure
    PasskeyContext
      { root = workspace ^. #root
      , export = directory </> passkeyExportFile
      , secrets = directory
      , run = runShomeiSql context (fmap (const ()) <$> guardKubernetesContext active)
      }

-- | Export once, then remove exactly the exported rows. A rerun after a crash reads the export it
-- already wrote, so the rows removed are always the rows saved.
removePasskeys :: ActiveTarget -> IO StepOutcome
removePasskeys active = do
  context <- passkeyContext active
  saved <- doesFileExist (context ^. #export)
  exported <-
    if saved
      then readExport context
      else do
        columns <- sqlFile context "columns.sql" >>= (context ^. #run) True . T.unpack
        case T.strip <$> columns of
          Left reason -> pure (Left reason)
          Right found
            | found /= expectedPasskeyColumns ->
                pure (Left ("Shomei's passkey table differs from the one this move exports (" <> found <> "); upgrade nagarectl with the platform"))
            | otherwise -> do
                rows <- sqlFile context "export-passkeys.sql" >>= (context ^. #run) True . T.unpack
                traverse (\r -> writeExport context (T.strip r) >> pure (T.strip r)) rows
  case exported of
    Left reason -> pure (StepRefused reason)
    Right rows -> do
      count <- either (pure . Left) (pure . Right . length) (passkeyIds rows)
      removed <- applyRows context "remove-passkeys.sql" rows
      pure $ case (count, removed) of
        (Left reason, _) -> StepRefused reason
        (_, Left reason) -> StepRefused reason
        (Right _, Right ()) -> StepCompleted

-- | Restore the table to the export; with no export, nothing was removed.
restorePasskeys :: ActiveTarget -> IO StepOutcome
restorePasskeys active = do
  context <- passkeyContext active
  saved <- doesFileExist (context ^. #export)
  if not saved
    then pure StepCompleted
    else do
      outcome <- readExport context >>= either (pure . Left) (applyRows context "restore-passkeys.sql")
      pure (either StepRefused (const StepCompleted) outcome)

applyRows :: PasskeyContext -> FilePath -> Text -> IO (Either Text ())
applyRows context name rows = do
  sql <- sqlFile context name
  case bindRows sql rows of
    Left reason -> pure (Left reason)
    Right bound -> fmap (const ()) <$> (context ^. #run) False (T.unpack bound)

sqlFile :: PasskeyContext -> FilePath -> IO Text
sqlFile context name = TIO.readFile (context ^. #root </> "cluster/bootstrap/shomei/move" </> name)

-- | Encrypt with the context's own @.sops.yaml@, the rows reaching sops on stdin only, and replace the
-- file in one step, so a failed run leaves no partial export.
writeExport :: PasskeyContext -> Text -> IO ()
writeExport context rows = do
  let config = context ^. #secrets </> ".sops.yaml"
      path = context ^. #export
      temporary = path <> ".new"
  hasConfig <- doesFileExist config
  unless hasConfig (fail ("no sops recipients for this context's secrets: " <> config))
  (code, encrypted, _) <-
    readCreateProcessWithExitCode
      (proc "sops" ["--config", config, "--encrypt", "--input-type", "json", "--output-type", "yaml", "--filename-override", path, "/dev/stdin"])
      (LBC.unpack (encode (object ["rows" .= rows])))
  -- sops's error text can quote its input, so it is not repeated here.
  unless (code == ExitSuccess && "ENC[" `T.isInfixOf` T.pack encrypted) (fail "sops could not encrypt the passkey export")
  writeFile temporary encrypted
  setFileMode temporary (ownerReadMode `unionFileModes` ownerWriteMode)
  renameFile temporary path
  TIO.putStrLn ("Exported the passkeys to " <> T.pack path <> ". Keep it until `context move retire`; rollback restores from it.")

readExport :: PasskeyContext -> IO (Either Text Text)
readExport context = do
  (code, decrypted, _) <-
    readCreateProcessWithExitCode (proc "sops" ["--decrypt", "--input-type", "yaml", "--output-type", "json", context ^. #export]) ""
  pure $
    if code /= ExitSuccess
      then Left ("sops could not decrypt " <> T.pack (context ^. #export))
      else case eitherDecodeStrict (TE.encodeUtf8 (T.pack decrypted)) of
        Right (Object o) | Just (String rows) <- KM.lookup "rows" o -> Right rows
        _ -> Left ("the passkey export " <> T.pack (context ^. #export) <> " holds no rows")
