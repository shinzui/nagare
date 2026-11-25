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
  )
where

import Data.Text qualified as Text
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (domainText, mkDomain)

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
