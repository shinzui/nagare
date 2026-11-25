-- | EP-285: the content domains a context lists in @NAGARE_CONTENT_DOMAINS@, a
-- comma-separated list. Each is a registrable domain the context owns a DNS
-- zone for and one application's worker may serve as @*.D@ and @D@.
--
-- A content domain exists to keep untrusted documents out of the login
-- cookie's scope, which is @.@ plus the base domain, so a domain that equals,
-- is under or contains the base domain is refused, as is a repeat.
module Nagare.Target.ContentDomains
  ( contentDomainsVariable
  , parseContentDomains
  , renderContentDomains
  , contentDomainZoneName
  , contentDelegationProblem
  )
where

import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Context.MoveChecks (sameNameServers)
import Nagare.Dsl.ContentDomain
import Nagare.Dsl.Prelude

contentDomainsVariable :: Text
contentDomainsVariable = "NAGARE_CONTENT_DOMAINS"

-- | The listed domains, in the order written; empty when the variable is unset
-- or blank.
parseContentDomains :: Text -> Map String Text -> Either Text [ContentDomain]
parseContentDomains baseDomain ctx = do
  domains <- traverse refuseDomain entries
  mapM_ separateFromBase domains
  let names = map contentDomainText domains
      slugs = map contentDomainSlug domains
  unless (nub names == names) (Left (variable <> " lists a domain twice"))
  unless (nub slugs == slugs) (Left (variable <> " lists two domains whose zone names collide (they differ only in . and -)"))
  pure domains
  where
    variable = contentDomainsVariable
    entries = filter (not . T.null) (map T.strip (T.splitOn "," (Map.findWithDefault "" (T.unpack variable) ctx)))
    refuseDomain raw = first (\reason -> variable <> ": " <> reason) (mkContentDomain raw)
    separateFromBase domain = case contentDomainRelation domain baseDomain of
      Unrelated -> Right ()
      relation ->
        Left
          ( variable
              <> ": "
              <> contentDomainText domain
              <> " "
              <> describe relation
              <> " the base domain "
              <> baseDomain
              <> "; a content domain must be a separate registrable domain so the login cookie never reaches it"
          )
    describe SameDomain = "equals"
    describe UnderDomain = "is under"
    describe ContainsDomain = "contains"
    describe Unrelated = "is unrelated to"

renderContentDomains :: [ContentDomain] -> Text
renderContentDomains = T.intercalate "," . map contentDomainText

-- | The Cloud DNS managed zone the Pulumi program creates for a content
-- domain (@infra/pulumi/src/components/NagareContentDomain.ts@).
contentDomainZoneName :: ContentDomain -> Text
contentDomainZoneName domain = "nagare-content-" <> contentDomainSlug domain

-- | Why public DNS does not yet send a content domain to its zone: the zone's
-- name servers could not be read, no resolver answers, or a resolver answers
-- with other servers. 'Nothing' when every answering resolver agrees with the
-- zone. Delegating is the operator's act at the registrar.
contentDelegationProblem :: Either Text [Text] -> [[Text]] -> Maybe Text
contentDelegationProblem zone resolvers = case zone of
  Left detail -> Just detail
  Right servers
    | null answered -> Just ("no public resolver answers NS; delegate the domain at its registrar to " <> T.intercalate ", " servers)
    | all (sameNameServers servers) answered -> Nothing
    | otherwise -> Just ("public resolvers answer NS " <> T.intercalate ", " (concat answered) <> ", not the zone's " <> T.intercalate ", " servers)
  where
    answered = filter (not . null) resolvers
