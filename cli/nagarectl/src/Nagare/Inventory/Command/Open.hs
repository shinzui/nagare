-- | Opening the active context's inventory store, once per command (EP-212),
-- and the refusals every inventory command shares.
module Nagare.Inventory.Command.Open
  ( OpenedInventory (..)
  , openTargetStore
  , openTargetStoreAtHead
  , openInventoryForPlanning
  , openedSnapshot
  , selectFoundationStore
  , loadTargetSnapshot
  , loadTargetSnapshotReadOnly
  , clientIdentity
  , dieText
  , dieCoded
  , showText
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM, forM_)
import Crypto.Random (getRandomBytes)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.IORef
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Contract.Problem (ProblemSpec, admissionRefused, reviewChanged, storeUnavailable, unclassified, wrongContext)
import Nagare.Contract.Project (savedReview)
import Nagare.Contract.Sink (contractSinkSet, emitDocument, progressLine, refuseWith, reportTransaction)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute hiding (withProcessLock)
import Nagare.Inventory.Journal
import Nagare.Inventory.Lifecycle
import Nagare.Inventory.Lineage (renderRebuild)
import Nagare.Inventory.ManifestAdapter (manifestAdapterFor, manifestOnlyRegistry)
import Nagare.Inventory.Migration
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Inventory.Store.Discovery
import Nagare.Inventory.Store.Remote qualified as Remote
import Nagare.Inventory.Store.Target (openProfileReviewStoreReadOnly, openRemoteStore, openTargetStoreReadOnly, remoteInventoryUrl)
import Nagare.Inventory.Store.TargetMigration (migrateTargetStore)
import Nagare.Platform.Paths (renderPlatformPathError, resolvePlatformPaths)
import Nagare.Platform.Transition (transitionContinueRefusal)
import Nagare.Platform.Workspace (readPayloadManifest, renderWorkspaceError)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Resource.Wire
import Nagare.Target
import System.Directory
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.FilePath (isAbsolute, takeDirectory, takeFileName, (</>))
import System.IO (hClose, stderr)
import System.IO.Error (isAlreadyExistsError)
import System.IO.Temp (withTempDirectory)
import System.Posix.Files (fileMode, getFileStatus, isDirectory, setFileMode)
import System.Posix.IO (OpenMode (WriteOnly), creat, defaultFileFlags, exclusive, fdToHandle, openFd)
import System.Timeout (timeout)

openTargetStore :: ActiveTarget -> IO InventoryStore
openTargetStore target = fst <$> openTargetStoreObserving False target

-- | 'openTargetStore' and the head it read, read once (EP-212).
openTargetStoreAtHead :: ActiveTarget -> IO (InventoryStore, Maybe HeadManifest)
openTargetStoreAtHead target = do
  (store, observed) <- openTargetStoreObserving True target
  (,) store <$> maybe (readHead store >>= either (dieText . showText) pure) pure observed

-- | Open the context's store for mutation. The head is returned when opening
-- read it, or when the caller asks for it.
openTargetStoreObserving :: Bool -> ActiveTarget -> IO (InventoryStore, Maybe (Maybe HeadManifest))
openTargetStoreObserving wantHead target = do
  stateRoot <- nagareStateDir
  let path = stateRoot </> T.unpack (contextNameText (target ^. #contextName)) </> "inventory"
  case effectiveInventoryStore (target ^. #profile) of
    InventoryStoreLocal -> do
      store <- openFilesystemStore path >>= either (dieText . showText) pure
      headResult <- readHead store >>= either (dieText . showText) pure
      case headResult >>= headMigration of
        Just marker -> dieText ("inventory history migrated to " <> migrationDestination marker <> "; reload the context shell")
        Nothing -> pure (store, Just headResult)
    InventoryStoreGcs -> do
      local <- openFilesystemStoreReadOnly path
      migrated <- case local of
        Right localStore -> do
          localHead <- readHead localStore
          case localHead of
            Right (Just headValue) -> case headMigration headValue of
              Just marker | migrationDestination marker == remoteInventoryUrl target -> pure True
              Nothing | not (hasSubstantiveHistory headValue) -> pure False
              _ -> dieText "local inventory history exists; migrate it before selecting the GCS store"
            Left err -> dieText (showText err)
            Right Nothing -> pure False
        Left (StoreConditionFailed _) -> pure False
        Left err -> dieText (showText err)
      remote <- openRemoteStore (not migrated) target stateRoot >>= either (dieText . showText) pure
      if migrated || wantHead
        then do
          remoteHead <- readHead remote >>= either (dieText . showText) pure
          when (migrated && isNothing remoteHead) (dieText "migrated remote inventory head is missing; refusing a new history")
          pure (remote, Just remoteHead)
        else pure (remote, Nothing)

-- | Select authority once before bootstrap work. This probe never creates local
-- state, remote format/head, cache, or client identity; migration stays explicit.
selectFoundationStore :: ActiveTarget -> IO (Either StoreError ActiveTarget)
selectFoundationStore target
  | effectiveInventoryStore (target ^. #profile) == InventoryStoreLocal = pure (Right target)
  | otherwise = do
      bounded <- timeout 60000000 discover
      pure (fromMaybe (Left (StoreIoError "inventory discovery exceeded 60 seconds; remote absence is not proved")) bounded)
  where
    localTarget = target & #profile . #inventoryStore .~ InventoryStoreLocal
    contextText = contextNameText (target ^. #contextName)
    project = target ^. #profile . #project
    refused = Left . StoreConditionFailed
    discover = do
      stateRoot <- nagareStateDir
      let path = stateRoot </> T.unpack contextText </> "inventory"
      exists <- doesPathExist path
      local <-
        if not exists
          then pure (Right Nothing)
          else do
            opened <- openFilesystemStoreReadOnly path
            case opened of
              Left err -> pure (Left err)
              Right store ->
                readHead store >>= \case
                  Right Nothing -> pure (refused "local inventory directory has no head; inspect incomplete history before bootstrap")
                  result -> pure result
      stored <- readContextProfile (target ^. #contextName)
      ambient <- lookupEnv "CLOUDSDK_CORE_PROJECT"
      case (mkContextId contextText, mkName project, stored, local) of
        (Right context, Right provider, Right persisted, Right localHead)
          | persisted ^. #project /= project -> pure (refused "active project disagrees with the stored inventory context")
          | remoteInventoryUrl (target & #profile .~ persisted) /= remoteInventoryUrl target ->
              pure (refused "active remote inventory URL disagrees with the stored context")
          | Just actual <- ambient, T.pack actual /= project -> pure (refused "ambient gcloud project disagrees with the inventory context")
          | maybe False ((/= ContextBinding context provider) . headBinding) localHead ->
              pure (refused "local inventory head belongs to another context or provider project")
          | Just marker <- localHead >>= headMigration
          , migrationDestination marker /= remoteInventoryUrl target ->
              pure (refused "local inventory migration destination differs from the selected remote store")
          | otherwise -> do
              remote <- Remote.remoteDiscoveryOps project (remoteInventoryUrl target)
              case remote of
                Left reason -> pure (Left (StoreIoError reason))
                Right (Remote.BucketUnavailable reason, _, _) -> pure (Left (StoreIoError reason))
                Right (Remote.BucketForeign reason, _, _) -> pure (refused reason)
                Right (Remote.BucketAbsent, _, _) -> pure (choose localHead DiscoveredMissingBucket)
                Right (Remote.BucketOwned _, ops, empty) ->
                  discoverInventoryObjects ops empty (ContextBinding context provider) >>= \case
                    DiscoveryUnavailable reason -> pure (Left (StoreIoError reason))
                    DiscoveryForeign reason -> pure (refused reason)
                    DiscoveryIncomplete reason -> pure (refused reason)
                    result -> pure (choose localHead result)
        (_, _, _, Left err) -> pure (Left err)
        (_, _, Left reason, _) -> pure (refused reason)
        (Left reason, _, _, _) -> pure (refused reason)
        (_, Left reason, _, _) -> pure (refused reason)
    choose localHead result = case chooseHistoryAuthority (remoteInventoryUrl target) localHead result of
      Left reason -> refused reason
      Right UseLocalFoundation -> Right localTarget
      Right UseRemoteHistory -> Right target

-- | Use the accepted complete scopes as the base of a freshly compiled
-- component candidate. The planner still checks unresolved transactions.
loadTargetSnapshot :: ActiveTarget -> IO ScopeSnapshot
loadTargetSnapshot target = do
  context <- either dieText pure (mkContextId (contextNameText (target ^. #contextName)))
  project <- either dieText pure (mkName (target ^. #profile . #project))
  let binding = ContextBinding context project
  store <- openTargetStore target
  _ <- initializeStore store binding (clientIdentity target) >>= either (dieText . showText) pure
  history <- loadInventoryHistory store >>= either (dieText . showText) pure
  either
    (dieText . showText . NE.toList)
    pure
    ( mkScopeSnapshot
        binding
        (Map.map (\(revision, declaration) -> (revisionGeneration revision, declaration)) (historyAccepted history))
        (historyReservations history)
    )

-- | Local credential recovery requires accepted history and never initializes
-- a new authority. An unresolved writer or data fence keeps recovery explicit.
loadTargetSnapshotReadOnly :: ActiveTarget -> IO ScopeSnapshot
loadTargetSnapshotReadOnly target = openInventoryForPlanning target >>= openedSnapshot

-- | A store opened once, the head read once and pinned, and the history
-- loaded once from that head (EP-212). Every consumer in the command takes
-- these; a mutation still observes the head again under its writer lock.
data OpenedInventory = OpenedInventory
  { inventoryStore :: !InventoryStore
  , pinnedHead :: !HeadManifest
  , loadedHistory :: !InventoryHistory
  }
  deriving stock (Generic)

-- | Open accepted history for a plan that composes against it. It never
-- initializes a store: the head must exist, belong to this context and be
-- idle, as 'loadTargetSnapshotReadOnly' always required.
openInventoryForPlanning :: ActiveTarget -> IO OpenedInventory
openInventoryForPlanning target = do
  context <- either dieText pure (mkContextId (contextNameText (target ^. #contextName)))
  project <- either dieText pure (mkName (target ^. #profile . #project))
  let binding = ContextBinding context project
  store <- openTargetStoreReadOnly target >>= either (dieText . showText) pure
  headValue <- readHead store >>= either (dieText . showText) pure
  observed <- maybe (dieText "accepted inventory history is absent") pure headValue
  unless (headBinding observed == binding) (dieText "inventory head belongs to another context or project")
  when
    ( isJust (headActiveTransaction observed)
        || isJust (headExecutorClaim observed)
        || isJust (headDataFence observed)
        || isJust (headMigration observed)
    )
    (dieText "accepted inventory has an unresolved transaction, claim, fence or migration; recover it first")
  history <- loadInventoryHistoryAt store observed >>= either (dieText . showText) pure
  pure (OpenedInventory store observed history)

-- | The accepted snapshot a candidate composes against.
openedSnapshot :: OpenedInventory -> IO ScopeSnapshot
openedSnapshot opened =
  either
    (dieText . showText . NE.toList)
    pure
    ( mkScopeSnapshot
        (headBinding (opened ^. #pinnedHead))
        (Map.map (\(revision, declaration) -> (revisionGeneration revision, declaration)) (historyAccepted history))
        (historyReservations history)
    )
  where
    history = opened ^. #loadedHistory

clientIdentity :: ActiveTarget -> Text
clientIdentity target =
  "client-" <> T.take 24 (digestText (contentDigest (TE.encodeUtf8 (contextNameText (target ^. #contextName)))))

-- | A refusal: its line on stderr, or under @--contract 1@ a coded outcome.
dieText :: Text -> IO a
dieText message = refuseWith message unclassified message

dieCoded :: ProblemSpec -> Text -> IO a
dieCoded spec message = refuseWith message spec message

showText :: (Show a) => a -> Text
showText = T.pack . show
