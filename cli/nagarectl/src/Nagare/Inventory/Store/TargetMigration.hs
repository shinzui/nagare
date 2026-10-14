-- | Move a context's inventory history between its local and GCS stores.
module Nagare.Inventory.Store.TargetMigration (migrateTargetStore) where

import Data.Aeson (toJSON)
import Data.Generics.Labels ()
import Data.Maybe (isJust)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store
import Nagare.Inventory.Store.Migrate (migrateStore)
import Nagare.Inventory.Store.Remote (remoteObjectOps)
import Nagare.Inventory.Store.Target (openRemoteStore, remoteInventoryUrl)
import Nagare.Ops.PulumiBackend (gcsBucketOfUrl)
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Target
import System.Environment (lookupEnv)
import System.FilePath ((</>))

migrateTargetStore :: ActiveTarget -> InventoryStoreKind -> Bool -> IO (Either StoreError T.Text)
migrateTargetStore target destinationKind dryRun = do
  stateRoot <- nagareStateDir
  let contextText = contextNameText (target ^. #contextName)
      path = stateRoot </> T.unpack contextText </> "inventory"
      sourceKind = effectiveInventoryStore (target ^. #profile)
      sourceLabel = case sourceKind of
        InventoryStoreLocal -> "local"
        InventoryStoreGcs -> remoteInventoryUrl target
      destinationLabel = case destinationKind of
        InventoryStoreLocal -> "local"
        InventoryStoreGcs -> remoteInventoryUrl target
      destinationMatches sourceHead destinationHead =
        let canonicalDigest value = contentDigest <$> canonicalValue (toJSON value)
            sourceDigest = case headMigration sourceHead of
              Just marker
                | migrationDestination marker == destinationLabel ->
                    Right (migrationHeadDigest marker)
              _ -> canonicalDigest sourceHead
         in destinationHead == sourceHead || case sourceDigest of
              Left _ -> False
              Right expected -> case headMigration destinationHead of
                Just marker ->
                  migrationDestination marker == sourceLabel
                    && migrationHeadDigest marker == expected
                Nothing ->
                  isJust (headMigration sourceHead)
                    && canonicalDigest destinationHead == Right expected
  if sourceKind == destinationKind
    then pure (Left (StoreConditionFailed "source and destination inventory stores are the same"))
    else do
      source <- case sourceKind of
        InventoryStoreLocal -> openFilesystemStoreReadOnly path
        InventoryStoreGcs -> openRemoteStore False target stateRoot
      case source of
        Left err -> pure (Left err)
        Right sourceStore -> do
          sourceHead <- readHead sourceStore
          case sourceHead of
            Left err -> pure (Left err)
            Right Nothing -> pure (Left (StoreConditionFailed "source inventory store is not initialized"))
            Right (Just headValue)
              | isJust (headActiveTransaction headValue) || isJust (headExecutorClaim headValue) ->
                  pure (Left (StoreConditionFailed "inventory migration requires no active transaction or executor claim"))
              | dryRun -> case destinationKind of
                  InventoryStoreLocal -> do
                    existing <- openFilesystemStoreReadOnly path
                    case existing of
                      Left (StoreConditionFailed _) -> pure (Right destinationLabel)
                      Left err -> pure (Left err)
                      Right localStore -> do
                        previous <- readHead localStore
                        pure $ case previous of
                          Left err -> Left err
                          Right Nothing -> Right destinationLabel
                          Right (Just old) | destinationMatches headValue old -> Right destinationLabel
                          Right (Just _) -> Left (StoreConditionFailed "local destination history differs")
                  InventoryStoreGcs -> do
                    let project = target ^. #profile . #project
                    ambient <- lookupEnv "CLOUDSDK_CORE_PROJECT"
                    case gcsBucketOfUrl destinationLabel of
                      Nothing -> pure (Left (StoreConditionFailed "inventory store URL has no GCS bucket"))
                      Just _
                        | maybe False ((/= project) . T.pack) ambient ->
                            pure (Left (StoreConditionFailed "ambient gcloud project disagrees with the inventory context"))
                      Just _ -> do
                        selected <- remoteObjectOps project destinationLabel
                        case selected of
                          Left reason -> pure (Left (StoreConditionFailed reason))
                          Right ops -> do
                            existing <- openObjectStoreReadOnly ops (headBinding headValue) "dry-run" Nothing
                            case existing of
                              Left (StoreConditionFailed reason)
                                | reason == "inventory object prefix is not initialized" -> pure (Right destinationLabel)
                              Left err -> pure (Left err)
                              Right remoteStore -> do
                                previous <- readHead remoteStore
                                pure $ case previous of
                                  Left err -> Left err
                                  Right Nothing -> Right destinationLabel
                                  Right (Just old) | destinationMatches headValue old -> Right destinationLabel
                                  Right (Just _) -> Left (StoreConditionFailed "remote destination history differs")
              | otherwise -> do
                  destination <- case destinationKind of
                    InventoryStoreLocal -> openFilesystemStore path
                    InventoryStoreGcs -> openRemoteStore True target stateRoot
                  case destination of
                    Left err -> pure (Left err)
                    Right destStore -> fmap (destinationLabel <$) (migrateStore sourceStore destStore sourceLabel destinationLabel)
