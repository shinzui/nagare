-- | Database responsibilities; internal implementation behind Nagare.Inventory.Application.
module Nagare.Inventory.Application.Database
  ( compileApplicationDatabases
  )
where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Nagare.Cluster.GcsJob (StoreBackend)
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (DatabaseName, databaseNameText)
import Nagare.Inventory.Database (DatabaseBackupTarget, compileDatabaseForBackend)
import Nagare.Resource.Application (applicationScopeId)
import Nagare.Resource.Database
  ( DatabaseDirectInput (DatabaseDirectInput)
  )
import Nagare.Resource.Inventory
  ( ManagedResource
  , ResourceBundle
  , mkScopeDeclaration
  )
import Nagare.Resource.Policy (RecoveryIntent)
import Nagare.Resource.Types
  ( InventoryError
  , ResourceId
  , SourceLocation (path)
  , inventoryError
  )

compileApplicationDatabases ::
  Application ->
  ResourceId ->
  Maybe ResourceId ->
  Map DatabaseName RecoveryIntent ->
  DatabaseBackupTarget ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    ([ResourceBundle], Map ResourceId (ManagedResource, ByteString))
compileApplicationDatabases app cluster namespaceId recoveryByDatabase backend source = do
  _ <- first invalidApp (mkApplication app)
  owner <- first invalidApp (applicationScopeId app)
  compiled <- traverse (compileOne owner) (app ^. #databases)
  let bundles = map fst compiled
      native = Map.unions (map snd compiled)
  -- Validate the combined member set, including duplicate logical keys that
  -- individual database builders cannot see across separate databases.
  _ <- mkScopeDeclaration owner bundles
  unless
    (Map.size native == sum (map (Map.size . snd) compiled))
    ( Left
        ( single
            ( inventoryError "duplicate-app-database" "database native members share an identity"
                & #scopes
                .~ [owner]
                & #sources
                .~ [source]
            )
        )
    )
  pure (bundles, native)
  where
    invalidApp message =
      single
        ( inventoryError "invalid-application" message
            & #sources
            .~ [source]
        )
    single errorValue = errorValue :| []
    compileOne owner database = do
      recovery <-
        maybe
          ( Left
              ( single
                  ( inventoryError "missing-database-recovery" "application database has no recovery intent"
                      & #scopes
                      .~ [owner]
                      & #sources
                      .~ [source]
                  )
              )
          )
          Right
          (Map.lookup (database ^. #name) recoveryByDatabase)
      let databaseSource =
            source
              { path = path source <> "/database/" <> databaseNameText (database ^. #name)
              }
          input = DatabaseDirectInput database owner cluster namespaceId recovery databaseSource
      compileDatabaseForBackend input backend
