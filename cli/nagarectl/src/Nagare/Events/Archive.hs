{-# LANGUAGE OverloadedStrings #-}

-- | Lifecycle state in a context export (EP-235 M2): the feed, the backup
-- collector's chain and the delivery records, copied object by object
-- beside an inventory export and restored beside a restored inventory.
-- Restore writes create-only into an empty location, immutable objects
-- first and heads last, so an interrupted restore leaves no head naming an
-- object that is missing. Restoring older state can resend an event a
-- receiver already has, always under its original event ID; it never runs
-- a deployment or a backup.
module Nagare.Events.Archive
  ( exportLifecycle
  , restoreLifecycle
  )
where

import Data.Generics.Labels ()
import Data.List (partition, sortOn)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Store.ObjectOps

-- | Copy every lifecycle object from @source@ into the empty @destination@,
-- returning how many were copied.
exportLifecycle :: ObjectOps -> ObjectOps -> IO (Either Text Int)
exportLifecycle = copyAll "export"

restoreLifecycle :: ObjectOps -> ObjectOps -> IO (Either Text Int)
restoreLifecycle = copyAll "restore"

copyAll :: Text -> ObjectOps -> ObjectOps -> IO (Either Text Int)
copyAll what source destination = do
  existing <- listObjects destination (ObjectName "")
  listed <- listObjects source (ObjectName "")
  case (existing, listed) of
    (Left reason, _) -> pure (Left ("the lifecycle " <> what <> " destination cannot be listed: " <> reason))
    (_, Left reason) -> pure (Left ("the lifecycle state cannot be listed: " <> reason))
    (Right (_ : _), _) -> pure (Left ("the lifecycle " <> what <> " destination is not empty"))
    (Right [], Right names) -> do
      let (heads, immutable) = partition mutable names
      go 0 (sortOn objectText immutable <> sortOn objectText heads)
  where
    go count [] = pure (Right count)
    go count (name : rest) = do
      read' <- getObject source name
      case read' of
        ObjectFound _ bytes -> do
          written <- putObject destination IfAbsent name bytes
          case written of
            PutWritten _ -> go (count + 1) rest
            _ -> pure (Left ("the lifecycle object " <> objectText name <> " could not be written"))
        ObjectAbsent -> go count rest
        GetUnknown reason -> pure (Left ("the lifecycle object " <> objectText name <> " cannot be read: " <> reason))
    -- Heads and delivery records change in place; everything else is
    -- content-addressed or create-only.
    mutable name = any (`T.isSuffixOf` objectText name) ["head.json", "sender.json"] || "/deliveries/" `T.isInfixOf` objectText name

objectText :: ObjectName -> Text
objectText (ObjectName name) = name
