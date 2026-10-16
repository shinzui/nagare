-- | Pure projections from Nagare's internal values to the public document
-- contract (@nagare-contract@). The CLI and the admin API both project
-- through these functions, so a read document has one shape everywhere.
--
-- The contract types are only encoded here: per ADR 22, decoding JSON never
-- grants authority, so nothing in nagarectl reads a contract document back.
module Nagare.Contract.Project
  ( versionInfo
  , contextRef
  , scopeStates
  , scopeState
  , acceptedPublications
  , publicationList
  , siteSummary
  , siteList
  )
where

import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Contract.Schema (ContractVersion (..), DocumentName (..), nullable)
import Nagare.Contract.V1
  ( ContextRef (..)
  , Publication (..)
  , PublicationList (..)
  , RecordState (..)
  , Revision (..)
  , ScopeState (..)
  , SiteKind (..)
  , SiteList (..)
  , SiteService (..)
  , SiteSummary (..)
  , VersionInfo (..)
  , contractVersions
  )
import Nagare.Dsl.Prelude
import Nagare.Inventory.Site.Recorded qualified as Recorded
import Nagare.Inventory.Store (HeadManifest (..), ScopeRevision (..))
import Nagare.Inventory.Store qualified as Store
import Nagare.Resource.Inventory
  ( Declaration (..)
  , DesiredSpec (..)
  , Executor (..)
  , ScopeDeclaration
  , declarations
  , scopeBundles
  , scopeOverrides
  )
import Nagare.Resource.Types hiding (ScopeKind (..))
import Nagare.Resource.Types qualified as Types
import Nagare.Version (BuildVersion (..))

-- | The discovery document for this build. With tools, each name maps to
-- the executable found on @PATH@, or @null@.
versionInfo :: BuildVersion -> Maybe [(Text, Maybe FilePath)] -> VersionInfo
versionInfo (BuildVersion buildVersion buildRevision) resolvedTools =
  VersionInfo
    { version = buildVersion
    , platformVersion = buildVersion
    , revision = buildRevision
    , tools = Map.fromList . map (fmap (nullable . fmap T.pack)) <$> resolvedTools
    , contracts = contractVersions
    }

contextRef :: ContextBinding -> ContextRef
contextRef binding =
  ContextRef
    { identity = contextIdText (binding ^. #identity)
    , project = nameText (binding ^. #project)
    }

-- | Every accepted scope of a head, sorted by scope ID, with its last
-- converged revision. This reads only the head, never a scope object.
scopeStates :: HeadManifest -> [ScopeState]
scopeStates headValue =
  sortOn (^. #scope) [project scope revision | (scope, revision) <- Map.toList (headAccepted headValue)]
  where
    project scope accepted = scopeStateOf scope accepted (Map.lookup scope (headConverged headValue))

-- | One accepted scope of a head, if it is accepted.
scopeState :: HeadManifest -> ScopeId -> Maybe ScopeState
scopeState headValue scope =
  scopeStateOf scope <$> Map.lookup scope (headAccepted headValue) <*> pure (Map.lookup scope (headConverged headValue))

scopeStateOf :: ScopeId -> ScopeRevision -> Maybe ScopeRevision -> ScopeState
scopeStateOf scope accepted lastConverged =
  ScopeState
    { scope = scopeIdText scope
    , generation = generationNumber (revisionGeneration accepted)
    , digest = digestText (revisionDigest accepted)
    , converged = lastConverged == Just accepted
    , convergedRevision = nullable (revisionOf <$> lastConverged)
    }

revisionOf :: ScopeRevision -> Revision
revisionOf revisionValue =
  Revision
    { generation = generationNumber (revisionGeneration revisionValue)
    , digest = digestText (revisionDigest revisionValue)
    }

-- | Every artifact publication in an accepted publication scope, sorted by
-- resource ID. @usedBy@ lists the accepted scopes whose @imageResource@
-- override names it. A publication declaration without its typed
-- publication specification is an error, never an omitted row.
acceptedPublications :: Map ScopeId (ScopeGeneration, ScopeDeclaration) -> Either Text [Publication]
acceptedPublications accepted =
  sortOn (^. #resourceId)
    <$> sequence
      [ publicationOf scope generationValue resource
      | (scope, (generationValue, declaration)) <- Map.toList accepted
      , scopeKind scope == Types.Publication
      , bundle <- scopeBundles declaration
      , Managed resource <- declarations bundle
      , resource ^. #executor == ArtifactExecutor
      ]
  where
    consumers =
      Map.fromListWith
        (<>)
        [ (image, [scopeIdText scope])
        | (scope, (_, declaration)) <- Map.toList accepted
        , Just image <- [Map.lookup "imageResource" (scopeOverrides declaration)]
        ]
    publicationOf scope generationValue resource =
      case (resource ^. #address, resource ^. #spec) of
        (Artifact _ manifest, ArtifactPublication kindName destinationText archive _) -> do
          let identityText = resourceIdText (resource ^. #identity)
          logicalKey <- case T.splitOn "/" identityText of
            [_, keyText, _] -> Right keyText
            _ -> Left ("publication resource ID has no logical key: " <> identityText)
          pure
            Publication
              { resourceId = identityText
              , scope = scopeIdText scope
              , key = logicalKey
              , kind = nameText kindName
              , destination = destinationText
              , manifestDigest = digestText manifest
              , archiveDigest = digestText archive
              , generation = generationNumber generationValue
              , usedBy = sortOn id (Map.findWithDefault [] identityText consumers)
              }
        _ -> Left ("artifact declaration lacks its typed publication specification: " <> resourceIdText (resource ^. #identity))

publicationList :: Map ScopeId (ScopeGeneration, ScopeDeclaration) -> Either Text PublicationList
publicationList accepted = do
  items <- acceptedPublications accepted
  pure
    PublicationList
      { contractVersion = ContractVersion1
      , document = DocumentName
      , publications = items
      }

siteSummary :: Recorded.RecordedSite -> SiteSummary
siteSummary site =
  SiteSummary
    { scope = scopeIdText (site ^. #scope)
    , resourceId = resourceIdText (site ^. #service)
    , kind = case site ^. #kind of
        Recorded.SiteKindSite -> SiteKindSite
        Recorded.SiteKindService -> SiteKindService
        Recorded.SiteKindPreview -> SiteKindPreview
    , state = case site ^. #state of
        Recorded.RecordConverged -> RecordConverged
        Recorded.RecordPending -> RecordPending
        Recorded.RecordNeverConverged -> RecordNeverConverged
    , name = site ^. #acceptedService . #name
    , namespace = site ^. #acceptedService . #namespace
    , hostnames = site ^. #acceptedService . #hostnames
    , acceptedRevision = revisionOf (site ^. #acceptedRevision)
    , convergedRevision = nullable (revisionOf <$> site ^. #convergedRevision)
    , lastConverged = nullable (service <$> site ^. #lastConverged)
    }
  where
    service summary =
      SiteService
        { name = summary ^. #name
        , namespace = summary ^. #namespace
        , hostnames = summary ^. #hostnames
        }

-- | The @site-list@ document of a head's recorded sites, in the given order.
siteList :: HeadManifest -> [Recorded.RecordedSite] -> SiteList
siteList headValue sites =
  SiteList
    { contractVersion = ContractVersion1
    , document = DocumentName
    , context = contextRef (headBinding headValue)
    , headGeneration = Store.headGeneration headValue
    , activeTransaction = nullable (headActiveTransaction headValue)
    , liveObserved = False
    , sites = map siteSummary sites
    }
