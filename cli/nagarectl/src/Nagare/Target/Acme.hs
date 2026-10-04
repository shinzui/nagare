-- | ACME directory and contact settings of a context (EP-112). "Nagare.Target"
-- re-exports them, so callers keep importing from there.
module Nagare.Target.Acme
  ( AcmeDirectory (..)
  , parseAcmeDirectory
  , acmeDirectoryToken
  , acmeDirectoryUrl
  , validateAcmeEmail
  )
where

import Data.Char (isSpace)
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude

-- | Which ACME service a context's issuer talks to (EP-112). 'AcmeProduction' is
-- Let's Encrypt's real service; 'AcmeStaging' issues certificates that are NOT
-- browser-trusted but has far looser rate limits, for rehearsing issuance on a
-- new domain; 'AcmeCustom' is any other ACME directory URL.
data AcmeDirectory = AcmeProduction | AcmeStaging | AcmeCustom Text
  deriving stock (Eq, Show)

-- | Parse the @NAGARE_ACME_DIRECTORY@ token. Empty (or unset) means
-- 'AcmeProduction'. Unlike 'parseMode' and 'parsePulumiBackendKind', an
-- unrecognized value is an ERROR, not a fallback: silently choosing production
-- burns a real rate limit against a real domain and silently choosing staging
-- installs certificates no browser trusts, so neither is a safe landing place
-- for a typo.
parseAcmeDirectory :: Text -> Either Text AcmeDirectory
parseAcmeDirectory raw
  | T.null token = Right AcmeProduction
  | lowered == "production" = Right AcmeProduction
  | lowered == "staging" = Right AcmeStaging
  | "https://" `T.isPrefixOf` token = Right (AcmeCustom token)
  | otherwise =
      Left
        ( "NAGARE_ACME_DIRECTORY='"
            <> token
            <> "' is not recognized (expected 'production', 'staging', or an absolute https:// ACME directory URL)."
        )
  where
    token = T.strip raw
    lowered = T.toLower token

-- | The @NAGARE_ACME_DIRECTORY@ token for a parsed endpoint (the inverse of
-- 'parseAcmeDirectory'), used by the context-file renderer. Round-tripping
-- through this normalizes case, so @--acme-directory STAGING@ is stored as
-- @staging@.
acmeDirectoryToken :: AcmeDirectory -> Text
acmeDirectoryToken AcmeProduction = "production"
acmeDirectoryToken AcmeStaging = "staging"
acmeDirectoryToken (AcmeCustom url) = url

-- | The directory URL for a parsed endpoint. Keep the two literals in sync with
-- @nagare_acme_directory_url@ in @scripts\/lib\/target.sh@; the
-- @cluster-bootstrap-defaults@ flake check fails the build if they drift.
acmeDirectoryUrl :: AcmeDirectory -> Text
acmeDirectoryUrl AcmeProduction = "https://acme-v02.api.letsencrypt.org/directory"
acmeDirectoryUrl AcmeStaging = "https://acme-staging-v02.api.letsencrypt.org/directory"
acmeDirectoryUrl (AcmeCustom url) = url

-- | Accept a single usable ACME contact address, or explain why not. This is a
-- SANITY CHECK (exactly one \'@\', a dotted domain, no whitespace or comma), not
-- an RFC 5322 validator: its job is to reject empty, placeholder and
-- multi-address values before they reach Let\'s Encrypt, where an account
-- registered under the wrong address cannot be re-pointed.
validateAcmeEmail :: Text -> Either Text Text
validateAcmeEmail raw
  | T.null addr = Left "an ACME contact address is required (there is no default)"
  | T.any (\c -> isSpace c || c == ',') addr = bad
  | otherwise = case T.splitOn "@" addr of
      [localPart, domain]
        | not (T.null localPart)
        , T.isInfixOf "." domain
        , not ("." `T.isPrefixOf` domain)
        , not ("." `T.isSuffixOf` domain) ->
            Right addr
      _ -> bad
  where
    addr = T.strip raw
    bad =
      Left
        ( "NAGARE_ACME_EMAIL='"
            <> addr
            <> "' is not a usable ACME contact address (expected one address of the form you@example.com)."
        )
