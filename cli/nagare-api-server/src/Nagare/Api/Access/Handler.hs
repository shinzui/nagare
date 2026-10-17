-- | Recorded host grants: what the inventory accepted, not an
-- effective-access check.
module Nagare.Api.Access.Handler
  ( accessServer
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as Text
import Nagare.Api.Access.Routes (AccessRoutes (..))
import Nagare.Api.Response (Paged (..))
import Nagare.Api.Server.Pagination (PageArgs (..), pageOf, pager)
import Nagare.Api.Server.Problems (storeProblem)
import Nagare.Api.Server.Serve
import Nagare.Contract.Prelude
import Nagare.Contract.Project (grants)
import Nagare.Inventory.Recorded (Selection (..), loadRecordedStateAt, recordedAccepted, recordedHeadManifest)
import Servant.Server (Handler)
import Servant.Server.Generic (AsServerT)

accessServer :: Env -> Text -> AccessRoutes (AsServerT Handler)
accessServer env context =
  AccessRoutes
    { grants = \firstArg afterArg lastArg beforeArg match ->
        serveState env match $ \checked -> do
          let args = PageArgs firstArg afterArg lastArg beforeArg
          page <- pager (context <> "|access/grants") args
          pure
            Plan
              { key = "grants|" <> Text.pack (show args) <> "|" <> acceptedVector checked
              , construct = do
                  loaded <- loadRecordedStateAt (reader env) checked AcceptedOnly
                  pure $ do
                    recorded <- first storeProblem loaded
                    pure (Paged (pageOf page (^. #resourceId) (Nagare.Contract.Project.grants (recordedHeadManifest checked) (recordedAccepted recorded))))
              }
    }
