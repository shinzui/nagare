{-# LANGUAGE OverloadedStrings #-}

-- | @database.restored@ (EP-276): a reviewed restore of a database backup
-- converged.
--
-- A reviewed restore, of a database or of an app-owned database, into a
-- scratch database or a rebuilt server, compiles to its own scope whose
-- overrides record the restore: @restore.id@, the backup, the source, the
-- namespace and the target. The producer reads only those overrides, so it
-- stays total: a member the scope did not record is null in the event. A
-- later review that leaves the restore's overrides alone announces nothing.
module Nagare.Events.Restore
  ( restoreProducer
  , restoreKey
  )
where

import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Events.Source
import Nagare.Inventory.Journal (TransactionId, transactionIdText)
import Nagare.Resource.Types

restoreProducer :: SourceProducer
restoreProducer = SourceProducer (const False) [restoreIdKey] restores

restoreIdKey :: Text
restoreIdKey = "restore.id"

restoreKey :: TransactionId -> ScopeId -> Either Text SourceKey
restoreKey transaction scope = mkSourceKey ("database.restored:" <> transactionIdText transaction <> ":" <> scopeIdText scope)

restores :: SourceInput -> [SourceItem]
restores input =
  [ PublicCandidate
      EventCandidate
        { key
        , resource = ResourceRef scope Nothing (field "restore.namespace") Nothing
        , occurredAt = Nothing
        , evidence = [Evidence "review" (input ^. #review)]
        , payload =
            DatabaseRestoredPayload
              DatabaseRestore
                { restore
                , backup = field "restore.backup.id"
                , database = field "restore.database"
                , appDatabase = field "restore.app-database"
                , namespace = field "restore.namespace"
                , targetDatabase = field "restore.target.database" <|> field "restore.target.databases"
                , targetKind
                , transaction = input ^. #transaction
                , review = input ^. #review
                , scopeRevision = view ^. #revision
                }
        }
  | (scope, view) <- Map.toAscList (input ^. #scopes)
  , let desired = view ^. #desired
        field name = Map.lookup name desired
  , Just restore <- [field restoreIdKey]
  , ((view ^. #previous) >>= Map.lookup restoreIdKey) /= Just restore
  , Right key <- [restoreKey (input ^. #transaction) scope]
  , let targetKind = case field "restore.target.kind" of
          Just "rebuilt" -> RebuiltTarget
          Just _ -> ScratchTarget
          -- A database rebuild restore records its lineage, not a kind.
          Nothing
            | any ("restore.rebuild." `T.isPrefixOf`) (Map.keys desired) -> RebuiltTarget
            | otherwise -> ScratchTarget
  ]
