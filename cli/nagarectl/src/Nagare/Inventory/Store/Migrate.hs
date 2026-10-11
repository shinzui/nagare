-- | Move an inventory store between locations: copy every member, install
-- the destination head behind a tombstone, disable the source, then activate.
module Nagare.Inventory.Store.Migrate (migrateStore) where

import Data.ByteString qualified as BS
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store

-- | Copy a quiescent catalogue with an inactive destination head. Disable the
-- source before activating the destination, so interruption cannot leave two
-- writable stores. Re-running completes either side of the handoff.
migrateStore :: InventoryStore -> InventoryStore -> Text -> Text -> IO (Either StoreError ())
migrateStore source destination sourceLabel label = do
  sourceLock <- withProcessLock source $ \_ ->
    withProcessLock destination $ \_ -> migrateLocked
  pure (sourceLock >>= id >>= id)
  where
    migrateLocked = do
      sourceHead <- readHead source
      case sourceHead of
        Left err -> pure (Left err)
        Right Nothing -> pure (Left (StoreConditionFailed "source inventory store is not initialized"))
        Right (Just oldHead)
          | isJust (headActiveTransaction oldHead)
              || isJust (headExecutorClaim oldHead)
              || isJust (headDataFence oldHead) ->
              pure (Left (StoreConditionFailed "source inventory store has an unresolved transaction or executor claim"))
          | otherwise -> do
              keysResult <- listObjectKeys source
              case keysResult of
                Left err -> pure (Left err)
                Right keys -> do
                  let members = filter (/= "format.json") keys
                  loaded <- traverse (\key -> fmap ((key,) <$>) (readObject source key)) members
                  case sequence loaded >>= traverse requireMember of
                    Left err -> pure (Left err)
                    Right values -> do
                      let oldDigest = case headMigration oldHead of
                            Just marker -> migrationHeadDigest marker
                            Nothing -> maybe (contentDigest BS.empty) contentDigest (lookup "head.json" values)
                      case headMigration oldHead of
                        Just marker
                          | migrationDestination marker /= label ->
                              pure (Left (StoreConditionFailed "source inventory store migrated to a different destination"))
                        Just _ -> do
                          activated <- activateMigrationHead destination sourceLabel oldDigest
                          case activated of
                            Left err -> pure (Left err)
                            Right () -> verifyCopy members oldDigest
                        Nothing -> do
                          destinationHead <- readHead destination
                          case destinationHead of
                            Left err -> pure (Left err)
                            Right (Just current)
                              | headMigration current == Nothing ->
                                  pure (Left (StoreConditionFailed "destination inventory head is already active"))
                            Right (Just current)
                              | Just marker <- headMigration current
                              , migrationDestination marker /= sourceLabel ->
                                  pure (Left (StoreConditionFailed "destination tombstone points to another store"))
                            Right _ -> copyAndCommit values members oldDigest oldHead
    copyAndCommit values members oldDigest oldHead = do
      copied <-
        traverse
          ( \(key, bytes) ->
              if key == "head.json"
                then pure (Right ())
                else publishMigrationMember destination key bytes
          )
          values
      case sequence copied of
        Left err -> pure (Left err)
        Right _ -> case lookup "head.json" values of
          Nothing -> pure (Left (StoreConditionFailed "source inventory head disappeared"))
          Just headBytes -> do
            installed <- installMigrationHead destination sourceLabel label headBytes
            case installed of
              Left err -> pure (Left err)
              Right _ -> do
                verified <- verifyStagedCopy members oldDigest
                case verified of
                  Left err -> pure (Left err)
                  Right () -> do
                    disabled <-
                      replaceHeadIfGenerationMatches
                        source
                        (Just (headGeneration oldHead))
                        oldHead
                          { headGeneration = headGeneration oldHead + 1
                          , headMigration = Just (MigrationTombstone label oldDigest)
                          }
                    case disabled of
                      Left err -> pure (Left err)
                      Right () -> do
                        activated <- activateMigrationHead destination sourceLabel oldDigest
                        case activated of
                          Left err -> pure (Left err)
                          Right () -> verifyCopy members oldDigest
    requireMember (_, Nothing) = Left (StoreConditionFailed "store changed while migration was reading it")
    requireMember (key, Just bytes) = do
      case immutableKeyDigest key of
        Just expected
          | contentDigest bytes /= expected ->
              Left (StoreInvalidObject key "immutable member digest mismatch during migration")
        _ -> Right ()
      Right (key, bytes)
    verifyStagedCopy members expectedDigest = verifyMembers members (Just expectedDigest)
    verifyCopy members expectedDigest = verifyMembers members (Just expectedDigest)
    verifyMembers members expectedDigest = do
      sourceKeys <- listObjectKeys source
      destKeys <- listObjectKeys destination
      case (sourceKeys, destKeys) of
        (Right currentSource, Right currentDest)
          | filter (/= "format.json") currentSource == members
          , filter (/= "format.json") currentDest == members -> do
              comparisons <- traverse (compareMember expectedDigest) members
              pure (void (sequence comparisons) >> Right ())
        (Left err, _) -> pure (Left err)
        (_, Left err) -> pure (Left err)
        _ -> pure (Left (StoreConditionFailed "inventory members changed during migration"))
      where
        compareMember expected key = do
          left <- readObject source key
          right <- readObject destination key
          pure $ do
            src <- left >>= maybe (Left (StoreConditionFailed "source member disappeared")) Right
            dst <- right >>= maybe (Left (StoreConditionFailed "destination member disappeared")) Right
            if key == "head.json"
              then do
                destinationHead <- decodeHead dst
                let actualDigest = maybe (contentDigest dst) migrationHeadDigest (headMigration destinationHead)
                unless
                  (Just actualDigest == expected)
                  (Left (StoreConditionFailed "destination inventory head digest differs"))
              else
                unless
                  (src == dst)
                  (Left (StoreConditionFailed "destination inventory member differs"))
