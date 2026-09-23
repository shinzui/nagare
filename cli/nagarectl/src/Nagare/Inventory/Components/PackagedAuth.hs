-- | Supply the complete, context-specific auth inputs to the reviewed compiler.
module Nagare.Inventory.Components.PackagedAuth
  ( compilePackagedAuth
  , packagedAuthInputs
  ) where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Cluster.GcsJob (StoreBackend)
import Nagare.Dsl.Database (Database (..), Engine (Postgres), defaultEngineVersion, mkDatabaseName)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Components.Auth
import Nagare.Inventory.Components.Foundation (FoundationInput (..), foundationNamespaceId)
import Nagare.Resource.Database (DatabaseDirectInput (..), databaseResourceId)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (RecoveryIntent (..), mkSecretRef)
import Nagare.Resource.Types

compilePackagedAuth
  :: FilePath -> FoundationInput -> AuthMode -> Text -> Map Text Text -> StoreBackend
  -> IO (Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString)))
compilePackagedAuth root foundation mode domain images backend =
  case packagedAuthInputs root foundation mode domain images backend of
    Left failure -> pure (Left failure)
    Right (auth, inputs) -> compileAuthComponent auth inputs

packagedAuthInputs
  :: FilePath -> FoundationInput -> AuthMode -> Text -> Map Text Text -> StoreBackend
  -> Either (NonEmpty InventoryError) (AuthInput, [(Text, DatabaseDirectInput, StoreBackend)])
packagedAuthInputs root foundation mode domain images backend =
  case traverse databaseInput ["shomei", "en"] of
    Left failure -> Left (failure :| [])
    Right inputs ->
      let auth = AuthInput owner (foundationCluster foundation) namespaceId root images domain
            (Map.fromList [(service, databaseId) | (service, _, databaseId) <- inputs]) [] mode
       in Right (auth, [(service, direct, backend) | (service, direct, _) <- inputs])
  where
    owner = known (mkScopeId Platform "auth")
    namespaceId = foundationNamespaceId foundation (known (mkName "nagare-system"))
    known = either (error . T.unpack) id
    databaseInput service = do
      name <- first invalid (mkDatabaseName (service <> "-db"))
      namespace <- first invalid (Dsl.mkNamespace "nagare-system")
      size <- first invalid (Dsl.mkQuantity "5Gi")
      let database = Database name Nothing Postgres (defaultEngineVersion Postgres)
            namespace size Nothing Dsl.Retain
          recovery = RecoveryIntent (known (mkName "postgres-backup"))
            (mkSecretRef (known (mkName ("nagare-db-" <> service <> "-db")))
              (known (mkName "v1")) :| [])
          direct = DatabaseDirectInput database owner (foundationCluster foundation)
            (Just namespaceId) recovery (SourceLocation "packaged:auth-database" service)
      databaseId <- first invalid (databaseResourceId owner (known (mkName "statefulset")) database)
      pure (service, direct, databaseId)
    invalid failure = inventoryError "invalid-packaged-auth" (T.pack (show failure))
