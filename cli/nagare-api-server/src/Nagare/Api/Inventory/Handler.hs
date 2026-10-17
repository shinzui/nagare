-- | The recorded inventory routes. The head and scope routes project from
-- the checked head alone; publications hydrate its accepted scopes.
module Nagare.Api.Inventory.Handler
  ( inventoryServer
  )
where

import Data.Generics.Labels ()
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Nagare.Api.Inventory.Routes (InventoryRoutes (..))
import Nagare.Api.Page (PageSize)
import Nagare.Api.Response (Paged (..))
import Nagare.Api.Server.Pagination (PageArgs (..), pageOf, pager)
import Nagare.Api.Server.Problems (storeProblem)
import Nagare.Api.Server.Serve
import Nagare.Contract.Prelude
import Nagare.Contract.Problem (problemFor, storeInvalid, unknownScope)
import Nagare.Contract.Project (acceptedPublications, headSummary, scopeStates)
import Nagare.Inventory.Recorded (RecordedHead, Selection (..), loadRecordedStateAt, recordedAccepted, recordedHeadManifest, recordedHeadRevision)
import Nagare.Inventory.Store (ScopeRevision (..))
import Nagare.Resource.Types (ContextBinding, contextIdText)
import Servant.Server (Handler)
import Servant.Server.Generic (AsServerT)

inventoryServer :: Env -> Text -> InventoryRoutes (AsServerT Handler)
inventoryServer env context =
  InventoryRoutes
    { head = \match ->
        serveState env match $ \checked ->
          Right (Plan ("head|" <> headRevisionText checked) (pure (Right (headSummary (recordedHeadManifest checked) (recordedHeadRevision checked)))))
    , scopes = \firstArg afterArg lastArg beforeArg match ->
        serveState env match $ \checked -> do
          let args = PageArgs firstArg afterArg lastArg beforeArg
          page <- pager (context <> "|inventory/scopes") args
          pure
            Plan
              { key = "scopes|" <> argsKey args <> "|" <> acceptedVector checked
              , construct = pure (Right (Paged (pageOf page (^. #scope) (scopeStates (recordedHeadManifest checked)))))
              }
    , scope = \scopeText match ->
        serveState env match $ \checked ->
          case find ((== scopeText) . (^. #scope)) (scopeStates (recordedHeadManifest checked)) of
            Nothing -> Left (problemFor unknownScope (scopeText <> " is not an accepted scope"))
            Just found -> Right (Plan ("scope|" <> scopeText <> "|" <> acceptedVector checked) (pure (Right found)))
    , publications = \firstArg afterArg lastArg beforeArg match ->
        serveState env match $ \checked -> do
          let args = PageArgs firstArg afterArg lastArg beforeArg
          page <- pager (context <> "|inventory/publications") args
          pure
            Plan
              { key = "publications|" <> argsKey args <> "|" <> acceptedVector checked
              , construct = do
                  loaded <- loadRecordedStateAt (reader env) checked AcceptedOnly
                  pure $ do
                    recorded <- first storeProblem loaded
                    items <-
                      first
                        (problemFor storeInvalid)
                        (acceptedPublications (Map.map (\(revisionValue, declaration) -> (revisionGeneration revisionValue, declaration)) (recordedAccepted recorded)))
                    pure (Paged (pageOf page (^. #resourceId) items))
              }
    }

-- | The page arguments as part of a representation key.
argsKey :: PageArgs -> Text
argsKey = Text.pack . show
