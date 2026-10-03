-- | Local profile reviews retain the shared history locator through removal.
module Nagare.Cli.Runtime.ContextReview
  ( saveContextReview
  , runContextReview
  , guardRemovedContext
  )
where

import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Context.Review
import Nagare.Dsl.Prelude
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store (HeadManifest, inventoryStoreRoot, readHead)
import Nagare.Resource.Types (digestText)
import Nagare.Target
  ( ActiveTarget (ActiveTarget)
  , ContextName
  , InventoryStoreKind (InventoryStoreLocal)
  , clearCurrentContext
  , contextFilePath
  , parseContextEnv
  , profileFromContextMap
  , readContextProfile
  , readCurrentContext
  )
import System.Directory (doesPathExist, makeAbsolute)
import System.FilePath ((</>))

saveContextReview :: ContextName -> Maybe Text -> FilePath -> IO ()
saveContextReview name replacement output = do
  guardRemovedContext name
  location <- contextFilePath name >>= makeAbsolute
  original <- TIO.readFile location
  profile <- readContextProfile name >>= either dieT pure
  selected <- Inventory.selectFoundationStore (ActiveTarget name profile) >>= either (dieT . T.pack . show) pure
  (selectedRoot, headValue) <- observe selected >>= either dieT pure
  safeReplacement <- traverse (either dieT pure . renderProfileReplacement . profileFromContextMap . parseContextEnv) replacement
  request <- newProfileRequest
  review <- either dieT pure (prepareProfileReview request name location original safeReplacement selectedRoot headValue)
  saveProfileReview output review >>= either dieT pure
  TIO.putStrLn ("Saved local context review in " <> T.pack output <> "; provider changes require separate inventory reviews")

runContextReview :: Bool -> FilePath -> Bool -> IO ()
runContextReview restoring input yes = do
  unless yes (dieT "local context apply/restore requires --yes")
  bytes <- BS.readFile (input </> "context-review.json")
  expected <- BS.readFile (input </> "context-review.sha256")
  unless (expected == TE.encodeUtf8 (digestText (contentDigest bytes))) (dieT "context review digest differs from saved bytes")
  review <- either dieT pure (decodeProfileReview bytes)
  let name = profileReviewContext review
      authority = ActiveTarget name (profileReviewOriginal review)
      retained = case profileReviewLocalRoot review of
        Just _ -> authority & #profile . #inventoryStore .~ InventoryStoreLocal
        Nothing -> authority
      check _ = do
        selected <- if restoring then pure (Right retained) else first (T.pack . show) <$> Inventory.selectFoundationStore authority
        case selected of
          Left reason -> pure (Left reason)
          Right target -> do
            observed <- observe target
            pure $ do
              (selectedRoot, headValue) <- observed
              unless
                (selectedRoot == profileReviewLocalRoot review)
                (Left "context history authority or local state root changed since review")
              pure headValue
  location <- contextFilePath name >>= makeAbsolute
  (if restoring then restoreProfileReview else applyProfileReview) location check review >>= either dieT pure
  exists <- doesPathExist location
  unless exists $ do
    current <- readCurrentContext
    when (current == Just name) clearCurrentContext
  TIO.putStrLn (if restoring then "Restored the original local context profile" else "Local context review completed; replay preserves its historical result")

guardRemovedContext :: ContextName -> IO ()
guardRemovedContext name = do
  location <- contextFilePath name
  removed <- doesPathExist (profileRemovalMarker location)
  when removed (dieT "context has retained removal authority; use context restore with its original removal review")

observe :: ActiveTarget -> IO (Either Text (Maybe FilePath, HeadManifest))
observe active = do
  opened <- Inventory.openTargetStoreReadOnly active
  case opened of
    Left reason -> pure (Left (T.pack (show reason)))
    Right store -> do
      selectedRoot <- traverse makeAbsolute (inventoryStoreRoot store)
      loaded <- readHead store
      pure $ do
        headValue <- first (T.pack . show) loaded >>= maybe (Left "context review requires initialized history") Right
        pure (selectedRoot, headValue)
