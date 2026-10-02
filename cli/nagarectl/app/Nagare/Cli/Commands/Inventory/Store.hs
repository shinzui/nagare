-- | Commands / Inventory / Store. Executable-private CLI boundary.
module Nagare.Cli.Commands.Inventory.Store
  ( runInventoryMaterializeNative
  , runInventoryStoreMigrate
  , runInventoryStoreStatus
  )
where

import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LBC
import Data.Generics.Labels ()
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Inventory.PublicEvidence (publicDataFence)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target (activeTarget)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Digest qualified as InventoryDigest
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Store qualified as InventoryStore
import Nagare.Resource.Types qualified as Resource
import Nagare.Target
  ( InventoryStoreKind (InventoryStoreGcs, InventoryStoreLocal)
  , Mode (Local)
  , contextNameText
  , defaultGcsInventoryStoreUrl
  , effectiveInventoryStore
  , inventoryStoreToken
  , writeContextInventoryStore
  )
import System.IO (stderr)

-- Explicit compatibility extraction: one bounded batch, immutable writes only,
-- visible per-review progress, and a stable captured head. No implicit scans in
-- status/explain and no materialization prerequisite for admitted recovery.
runInventoryMaterializeNative :: Maybe String -> Maybe String -> Int -> IO ()
runInventoryMaterializeNative mctx afterRaw limit = do
  unless (limit > 0 && limit <= 100) (dieT "--limit must be between 1 and 100 reviews")
  after <- traverse (either dieT pure . Resource.mkContentDigest . T.pack) afterRaw
  active <- activeTarget mctx
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  result <- InventoryStore.withProcessLock store $ \_ -> do
    snapshot <- InventoryStore.readStoreSnapshot store >>= either (dieT . T.pack . show) pure
    context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
    project <- either dieT pure (Resource.mkName (active ^. #profile . #project))
    unless
      ( InventoryStore.headBinding (InventoryStore.storeSnapshotHead snapshot)
          == Resource.ContextBinding context project
      )
      (dieT "inventory belongs to a different context or project")
    let headValue = InventoryStore.storeSnapshotHead snapshot
        available =
          filter
            (\digest -> maybe True (< digest) after)
            (Set.toAscList (InventoryStore.storeSnapshotReviewDigests snapshot))
        batch = take limit available
    forM_ batch $ \digest -> do
      bundle <- InventoryPlan.loadPublishedReview store digest >>= either (dieT . T.pack . show) pure
      unless
        ( InventoryPlan.reviewContextBinding (InventoryPlan.reviewBundleDocument bundle)
            == InventoryStore.headBinding headValue
        )
        (dieT "historical review context differs from captured head")
      InventoryPlan.publishObservationMembers store bundle >>= either (dieT . T.pack . show) pure
      TIO.hPutStrLn stderr ("Materialized review " <> Resource.digestText digest)
    final <- InventoryStore.readHead store >>= either (dieT . T.pack . show) pure
    unless (final == Just headValue) (dieT "inventory head changed during materialization; rerun the batch")
    LBC.putStrLn
      ( Aeson.encode
          ( Aeson.object
              [ "headGeneration" Aeson..= InventoryStore.headGeneration headValue
              , "processed" Aeson..= length batch
              , "remaining" Aeson..= (length available - length batch)
              , "after" Aeson..= case reverse batch of [] -> after; digest : _ -> Just digest
              ]
          )
      )
  either (dieT . T.pack . show) pure result

runInventoryStoreStatus :: Maybe String -> Bool -> IO ()
runInventoryStoreStatus mctx json = do
  active <- activeTarget mctx
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  rawHead <-
    InventoryStore.readObject store "head.json"
      >>= either (dieT . T.pack . show) pure
      >>= maybe (dieT "inventory history is not initialized") pure
  schema <- either (dieT . T.pack . show) pure (InventoryStore.inspectHeadSchema rawHead)
  repeated <- InventoryStore.readObject store "head.json" >>= either (dieT . T.pack . show) pure
  unless (repeated == Just rawHead) (dieT "inventory history changed during status")
  let profile = active ^. #profile
      kind = effectiveInventoryStore profile
      context = contextNameText (active ^. #contextName)
      url = case kind of
        InventoryStoreLocal -> "local"
        InventoryStoreGcs ->
          if T.null (profile ^. #inventoryStoreUrl)
            then defaultGcsInventoryStoreUrl context profile
            else profile ^. #inventoryStoreUrl
  if schema > 1
    then do
      let report =
            Aeson.object
              [ "kind" Aeson..= inventoryStoreToken kind
              , "url" Aeson..= url
              , "headDigest" Aeson..= InventoryDigest.contentDigest rawHead
              , "schemaVersion" Aeson..= schema
              , "state" Aeson..= ("unsupported-schema" :: Text)
              ]
      if json
        then LBC.putStrLn (Aeson.encode report)
        else
          TIO.putStrLn
            ( "Inventory store "
                <> inventoryStoreToken kind
                <> " at "
                <> url
                <> " uses unsupported head schema "
                <> T.pack (show schema)
                <> "; use a newer operator payload"
            )
    else do
      headValue <-
        InventoryStore.readHead store
          >>= either (dieT . T.pack . show) pure
          >>= maybe (dieT "inventory history head disappeared") pure
      let report =
            Aeson.object
              [ "kind" Aeson..= inventoryStoreToken kind
              , "url" Aeson..= url
              , "binding" Aeson..= InventoryStore.headBinding headValue
              , "headDigest" Aeson..= InventoryDigest.contentDigest rawHead
              , "generation" Aeson..= InventoryStore.headGeneration headValue
              , "activeTransaction" Aeson..= InventoryStore.headActiveTransaction headValue
              , "dataFence" Aeson..= fmap publicDataFence (InventoryStore.headDataFence headValue)
              , "executorClaim" Aeson..= InventoryStore.headExecutorClaim headValue
              , "migration" Aeson..= InventoryStore.headMigration headValue
              ]
      if json
        then LBC.putStrLn (Aeson.encode report)
        else
          TIO.putStrLn
            ( "Inventory store "
                <> inventoryStoreToken kind
                <> " at "
                <> url
                <> ", generation "
                <> T.pack (show (InventoryStore.headGeneration headValue))
                <> ", data fence: "
                <> maybe
                  "none"
                  (T.pack . show . InventoryStore.fencePhase)
                  (InventoryStore.headDataFence headValue)
            )

runInventoryStoreMigrate :: Maybe String -> String -> Bool -> Bool -> IO ()
runInventoryStoreMigrate mctx destination dryRun yes = do
  kind <- case destination of
    "gcs" -> pure InventoryStoreGcs
    "local" -> pure InventoryStoreLocal
    _ -> dieT "--to must be gcs or local"
  unless (dryRun || yes) (dieT "inventory store migration requires --yes or --dry-run")
  active <- activeTarget mctx
  when
    ( kind == InventoryStoreGcs
        && effectiveInventoryStore (active ^. #profile) == InventoryStoreLocal
        && active ^. #profile . #mode == Local
    )
    (dieT "local-mode contexts cannot use a GCS inventory store")
  label <- Inventory.migrateTargetStore active kind dryRun >>= either (dieT . T.pack . show) pure
  if dryRun
    then TIO.putStrLn ("Inventory migration is ready for " <> label)
    else do
      let url = case kind of
            InventoryStoreLocal -> ""
            InventoryStoreGcs -> label
      writeContextInventoryStore (active ^. #contextName) kind url >>= either dieT pure
      TIO.putStrLn ("Inventory history migrated to " <> label <> "; reload the context shell")
