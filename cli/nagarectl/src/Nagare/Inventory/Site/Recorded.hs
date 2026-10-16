-- | Recorded sites: the user-facing Knative Services of the accepted
-- inventory, with their declared hostnames and whether their scope's
-- accepted revision has converged (EP-193).
--
-- This is a pure projection of a 'RecordedState'. Convergence means Nagare
-- recorded the completion of a scope revision; it never claims the site is
-- reachable or healthy now.
module Nagare.Inventory.Site.Recorded
  ( SiteKind (..)
  , RecordState (..)
  , ServiceSummary (..)
  , RecordedSite (..)
  , recordedSites
  )
where

import Data.Generics.Labels ()
import Data.List (nub, sort, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.PreviewCleanup (previewOwner)
import Nagare.Inventory.Recorded (RecordedState, recordedAccepted, recordedConverged, recordedHeadManifest, recordedStateHead)
import Nagare.Inventory.Store (HeadManifest (..), ScopeRevision)
import Nagare.Resource.Inventory (Declaration (..), ScopeDeclaration, declarations, scopeBundles)
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types

-- | A production static or server site (@standalone:site-<name>@), a site
-- preview, or another application or standalone web service.
data SiteKind = SiteKindSite | SiteKindService | SiteKindPreview
  deriving stock (Eq, Ord, Show, Generic)

-- | The scope record, not workload health: the accepted revision converged,
-- an earlier revision of this Service converged, or none ever did.
data RecordState = RecordConverged | RecordPending | RecordNeverConverged
  deriving stock (Eq, Ord, Show, Generic)

data ServiceSummary = ServiceSummary
  { name :: !Text
  , namespace :: !Text
  , hostnames :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

data RecordedSite = RecordedSite
  { scope :: !ScopeId
  , service :: !ResourceId
  , kind :: !SiteKind
  , state :: !RecordState
  , acceptedRevision :: !ScopeRevision
  , convergedRevision :: !(Maybe ScopeRevision)
  , acceptedService :: !ServiceSummary
  , lastConverged :: !(Maybe ServiceSummary)
  }
  deriving stock (Eq, Show, Generic)

-- | Every accepted Knative Service of an application or standalone scope,
-- sorted by namespace, name and resource ID. A DomainMapping that depends on
-- zero or several Services of its scope is an error, never a guessed row.
recordedSites :: RecordedState -> Either Text [RecordedSite]
recordedSites recorded =
  sortOn (\site -> (site ^. #acceptedService . #namespace, site ^. #acceptedService . #name, resourceIdText (site ^. #service)))
    . concat
    <$> traverse siteRows (Map.toAscList (recordedAccepted recorded))
  where
    headValue = recordedHeadManifest (recordedStateHead recorded)
    siteRows (scope, (accepted, declaration))
      | scopeKind scope `notElem` [Application, Standalone] = Right []
      | otherwise = do
          services <- servicesOf declaration
          let lastRevision = Map.lookup scope (headConverged headValue)
              earlier = case lastRevision of
                Just revision
                  | revision == accepted -> Just (Right declaration)
                  | otherwise -> Right . snd <$> Map.lookup scope (recordedConverged recorded)
                Nothing -> Nothing
          previous <- traverse (>>= servicesOf) earlier
          pure
            [ RecordedSite
                { scope = scope
                , service = identity
                , kind = kindOf scope
                , state = stateOf (lastRevision == Just accepted) earlierSummary
                , acceptedRevision = accepted
                , convergedRevision = lastRevision
                , acceptedService = summary
                , lastConverged = earlierSummary
                }
            | (identity, summary) <- Map.toAscList services
            , let earlierSummary = previous >>= Map.lookup identity
            ]
    stateOf True _ = RecordConverged
    stateOf False (Just _) = RecordPending
    stateOf False Nothing = RecordNeverConverged
    kindOf scope
      | previewOwner scope = SiteKindPreview
      | scopeKind scope == Standalone && "site-" `T.isPrefixOf` nameText (scopeName scope) = SiteKindSite
      | otherwise = SiteKindService

-- | The Knative Services of one scope with the hostnames of the
-- DomainMappings that depend on them.
servicesOf :: ScopeDeclaration -> Either Text (Map ResourceId ServiceSummary)
servicesOf declaration = do
  let managed = [resource | bundle <- scopeBundles declaration, Managed resource <- declarations bundle]
      services =
        Map.fromList
          [ (resource ^. #identity, (nameText serviceName, nameText serviceNamespace))
          | resource <- managed
          , Kubernetes _ "serving.knative.dev" kindName (Just serviceNamespace) serviceName <- [resource ^. #address]
          , nameText kindName == "service"
          ]
      mappings = [resource | resource <- managed, isDomainMapping resource]
  routed <- traverse (mappingRoute (Map.keysSet services)) mappings
  let hostnamesFor identity = sort (nub [host | (target, host) <- routed, target == identity])
  pure
    ( Map.mapWithKey
        (\identity (serviceName, serviceNamespace) -> ServiceSummary serviceName serviceNamespace (hostnamesFor identity))
        services
    )
  where
    isDomainMapping resource = case resource ^. #address of
      Kubernetes _ "serving.knative.dev" kindName _ _ -> nameText kindName == "domainmapping"
      _ -> False
    mappingRoute serviceIds resource = do
      target <- case [dependency | OrderedAfter dependency <- resource ^. #dependencies, Set.member dependency serviceIds] of
        [single] -> Right single
        _ -> Left ("DomainMapping does not depend on exactly one Service of its scope: " <> resourceIdText (resource ^. #identity))
      host <- case [hostName | Hostname hostName <- resource ^. #aliases] of
        [single] -> Right (nameText single)
        _ -> Left ("DomainMapping does not declare exactly one hostname: " <> resourceIdText (resource ^. #identity))
      pure (target, host)
