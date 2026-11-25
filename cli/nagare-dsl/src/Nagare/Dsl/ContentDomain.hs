-- | A content domain (EP-285): a registrable domain, separate from the
-- context's base domain, that one worker serves as @*.D@ and @D@ so each
-- document gets its own browser origin and never receives the application's
-- cookies.
--
-- The context lists its content domains (@NAGARE_CONTENT_DOMAINS@) and owns
-- each one's DNS zone; an application claims one listed domain.
module Nagare.Dsl.ContentDomain
  ( ContentDomain
  , mkContentDomain
  , contentDomainText
  , contentDomainSlug
  , contentDomainRelation
  , DomainRelation (..)

    -- * A worker's route
  , ContentRoute (..)
  , mkContentRoute
  , contentRouteHosts
  , WorkerHttp (..)
  )
where

import Data.Generics.Labels ()
import Data.List (nub)
import Data.Text qualified as Text
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (Domain, Port, domainText, mkDomain)

-- | A plain multi-label DNS name, lower case, with no wildcard; the wildcard
-- is implied. Constructor hidden; use 'mkContentDomain'.
newtype ContentDomain = ContentDomain Text
  deriving stock (Eq, Ord, Show)

-- | Accepts what 'mkDomain' accepts, and refuses a name whose slug would not
-- fit the Cloud DNS zone name @nagare-content-\<slug\>@ (63 characters).
mkContentDomain :: Text -> Either Text ContentDomain
mkContentDomain raw = do
  domain <- first ("content domain: " <>) (mkDomain raw)
  let name = domainText domain
  when
    (Text.length name > 48)
    (Left ("content domain must be at most 48 characters, so its zone name fits Cloud DNS: " <> name))
  pure (ContentDomain name)

contentDomainText :: ContentDomain -> Text
contentDomainText (ContentDomain name) = name

-- | The domain with @.@ as @-@, used in Pulumi and Cloud DNS names.
contentDomainSlug :: ContentDomain -> Text
contentDomainSlug (ContentDomain name) = Text.replace "." "-" name

data DomainRelation
  = SameDomain
  | UnderDomain
  | ContainsDomain
  | Unrelated
  deriving stock (Eq, Show)

-- | How a content domain relates to another host: equal to it, below it, above
-- it, or neither. Only 'Unrelated' keeps the two in separate cookie scopes.
contentDomainRelation :: ContentDomain -> Text -> DomainRelation
contentDomainRelation (ContentDomain name) other
  | name == other = SameDomain
  | ("." <> other) `Text.isSuffixOf` name = UnderDomain
  | ("." <> name) `Text.isSuffixOf` other = ContainsDomain
  | otherwise = Unrelated

-- | The route a worker serves on a content domain: @*.D@ and @D@, which
-- one wildcard certificate covers, and fixed hosts that are named for claims
-- and documentation. Construct with 'mkContentRoute'.
data ContentRoute = ContentRoute
  { domain :: !ContentDomain
  , fixedHosts :: ![Domain]
  -- ^ the domain itself or one label below it
  }
  deriving stock (Generic, Eq, Show)

-- | Refuses a fixed host that the wildcard certificate would not cover: one
-- that is not @D@ or exactly one label below it, and a repeat.
mkContentRoute :: ContentDomain -> [Domain] -> Either Text ContentRoute
mkContentRoute contentDomain hosts = do
  mapM_ covered hosts
  unless (nub hosts == hosts) (Left ("content route names a fixed host twice under " <> contentDomainText contentDomain))
  pure (ContentRoute contentDomain hosts)
  where
    covered host =
      case contentDomainRelation contentDomain (domainText host) of
        SameDomain -> Right ()
        ContainsDomain
          | Just label <- Text.stripSuffix ("." <> contentDomainText contentDomain) (domainText host)
          , not (Text.isInfixOf "." label) ->
              Right ()
        _ ->
          Left
            ( "content route fixed host "
                <> domainText host
                <> " is not "
                <> contentDomainText contentDomain
                <> " or one label below it, so the wildcard certificate does not cover it"
            )

-- | The hosts the route serves, as Kourier and the certificate name them.
contentRouteHosts :: ContentRoute -> [Text]
contentRouteHosts route = ["*." <> contentDomainText (route ^. #domain), contentDomainText (route ^. #domain)]

-- | A worker's HTTP port (EP-285). A worker with one is reachable inside the
-- cluster through a ClusterIP Service named after it; with a content route it
-- also receives every request for the route's hosts with the original @Host@
-- header. Such a worker never scales to zero, and its requests are never
-- authenticated by the platform.
data WorkerHttp = WorkerHttp
  { port :: !Port
  , content :: !(Maybe ContentRoute)
  }
  deriving stock (Generic, Eq, Show)
