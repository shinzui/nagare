-- | Recorded sites: the accepted Knative Services and their hostnames, with
-- the earlier converged revision of a pending update.
module Nagare.Api.Sites.Handler
  ( sitesServer
  )
where

import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.Text qualified as Text
import Nagare.Api.Response (Paged (..))
import Nagare.Api.Server.Pagination (PageArgs (..), pageOf, pager)
import Nagare.Api.Server.Problems (storeProblem)
import Nagare.Api.Server.Serve
import Nagare.Api.Sites.Routes (SitesRoutes (..))
import Nagare.Contract.Prelude
import Nagare.Contract.Problem (problemFor, storeInvalid)
import Nagare.Contract.Project (siteSummary)
import Nagare.Contract.V1 (SiteKind (..))
import Nagare.Inventory.Recorded (Selection (..), loadRecordedStateAt)
import Nagare.Inventory.Site.Recorded (recordedSites)
import Servant.Server (Handler)
import Servant.Server.Generic (AsServerT)

sitesServer :: Env -> Text -> SitesRoutes (AsServerT Handler)
sitesServer env context =
  SitesRoutes
    { sites = \namespace includePreviews firstArg afterArg lastArg beforeArg match ->
        serveState env match $ \checked -> do
          let args = PageArgs firstArg afterArg lastArg beforeArg
              previews = fromMaybe False includePreviews
              filters = "namespace=" <> fromMaybe "" namespace <> "|previews=" <> Text.pack (show previews)
          page <- pager (context <> "|sites|" <> filters) args
          pure
            Plan
              { key = "sites|" <> filters <> "|" <> Text.pack (show args) <> "|" <> acceptedVector checked
              , construct = do
                  loaded <- loadRecordedStateAt (reader env) checked WithConvergedSites
                  pure $ do
                    recorded <- first storeProblem loaded
                    rows <- first (problemFor storeInvalid) (recordedSites recorded)
                    let selected =
                          sortOn
                            (^. #resourceId)
                            [ summary
                            | summary <- map siteSummary rows
                            , maybe True (== summary ^. #namespace) namespace
                            , previews || summary ^. #kind /= SiteKindPreview
                            ]
                    pure (Paged (pageOf page (^. #resourceId) selected))
              }
    }
