-- | The typed static-site model with maximal-safety constructors.
--
-- A 'StaticSite' describes a directory of files served directly over HTTP after
-- an optional build step — the Cloudflare Pages-style static-hosting surface.
-- It is a sibling of 'Nagare.Dsl.Types.Deployment' (a long-running Knative web
-- service), not an extension of it: a static site carries build/output
-- directories, redirect rules, header rules, and a cache policy that a
-- 'Deployment' does not, and it carries none of a 'Deployment''s container
-- @env@/@resources@/@scale@.
--
-- Every leaf newtype below hides its data constructor and exposes only a
-- validating smart constructor (@mkX :: ... -> Either Text X@) plus a read-only
-- accessor, so a bad site name or an unsafe output path is rejected at
-- construction with a precise message rather than silently written down to fail
-- at the cluster. The shared leaf types 'SiteName' and 'FilePathText' (and
-- 'mkFilePathText') are exported so the sibling server-site model in
-- @docs/plans/18-full-stack-server-runtime-hosting-for-static-sites.md@ (EP-18)
-- can reuse them instead of redefining them.
module Nagare.Dsl.Static.Types
  ( -- * StaticSite
    StaticSite (..)

    -- * SiteName
  , SiteName
  , mkSiteName
  , siteNameText

    -- * FilePathText
  , FilePathText
  , mkFilePathText
  , filePathText

    -- * StaticBuild
  , StaticBuild (..)
  , staticOutputDir
  , staticBuildCommand

    -- * RedirectRule
  , RedirectRule (..)
  , mkRedirectRule
  , allowedRedirectStatuses

    -- * HeaderRule
  , HeaderRule (..)
  , mkHeaderRule

    -- * CachePolicy
  , CachePolicy (..)
  , defaultCachePolicy
  , mkCachePolicy
  ) where

import Nagare.Dsl.Prelude

import Data.Char (isControl, isDigit, isLower, isSpace)
import Data.Text qualified as Text
import Nagare.Dsl.Path (FilePathText, filePathText, mkFilePathText)
import Nagare.Dsl.Types (Domain, ImageRef, Namespace)

-- | A Kubernetes / RFC 1123 DNS label used as the static site's Knative Service
-- name. Same rules as 'Nagare.Dsl.Types.ServiceName'. Constructor hidden; use
-- 'mkSiteName'.
newtype SiteName = SiteName Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct a 'SiteName': 1–63 characters of lowercase letters,
-- digits, and hyphens, not starting or ending with a hyphen.
mkSiteName :: Text -> Either Text SiteName
mkSiteName t
  | Text.null t = Left "site name must not be empty"
  | Text.length t > 63 =
      Left ("site name too long (" <> tshow (Text.length t) <> " chars, max 63)")
  | Text.isPrefixOf "-" t = Left "site name must not start with a hyphen"
  | Text.isSuffixOf "-" t = Left "site name must not end with a hyphen"
  | not (Text.all validLabelChar t) =
      Left ("site name contains invalid characters (allowed: a-z, 0-9, -): " <> t)
  | otherwise = Right (SiteName t)

siteNameText :: SiteName -> Text
siteNameText (SiteName t) = t

-- | How the static files are produced. Either the files already exist in a
-- directory (@NoBuild dir@), or a build command produces them into an output
-- directory (@BuildCommand cmd outDir@). In both cases the named directory is
-- what gets packaged into the Nginx image.
data StaticBuild
  = -- | The files are already present; serve them from this directory.
    NoBuild FilePathText
  | -- | Run @command@ (e.g. @"npm run build"@), then serve @outputDirectory@.
    BuildCommand
      { command :: !Text
      , outputDirectory :: !FilePathText
      }
  deriving stock (Generic, Eq, Show)

-- | The directory whose contents are served, regardless of build variant.
staticOutputDir :: StaticBuild -> FilePathText
staticOutputDir (NoBuild d) = d
staticOutputDir (BuildCommand _ d) = d

-- | The build command to run before packaging, or 'Nothing' for 'NoBuild'.
staticBuildCommand :: StaticBuild -> Maybe Text
staticBuildCommand (NoBuild _) = Nothing
staticBuildCommand (BuildCommand c _) = Just c

-- | A redirect from a request path to a target URL or path with an HTTP status.
-- Construct with 'mkRedirectRule'; direct record construction bypasses status
-- validation (the same convention as 'Nagare.Dsl.Types.Scale').
data RedirectRule = RedirectRule
  { from :: !Text
  , to :: !Text
  , status :: !Int
  }
  deriving stock (Generic, Eq, Show)

-- | The redirect status codes a 'RedirectRule' may carry: 301, 302, 303, 307,
-- 308.
allowedRedirectStatuses :: [Int]
allowedRedirectStatuses = [301, 302, 303, 307, 308]

-- | Validate and construct a 'RedirectRule'. @from@ and @to@ must be non-empty
-- and whitespace-free; @status@ must be one of 'allowedRedirectStatuses'.
mkRedirectRule :: Text -> Text -> Int -> Either Text RedirectRule
mkRedirectRule from' to' status'
  | Text.null from' = Left "redirect 'from' must not be empty"
  | Text.any isSpace from' = Left ("redirect 'from' must not contain whitespace: " <> from')
  | Text.null to' = Left "redirect 'to' must not be empty"
  | Text.any isSpace to' = Left ("redirect 'to' must not contain whitespace: " <> to')
  | status' `notElem` allowedRedirectStatuses =
      Left
        ( "redirect status must be one of "
            <> Text.intercalate ", " (map tshow allowedRedirectStatuses)
            <> "; got: "
            <> tshow status'
        )
  | otherwise = Right (RedirectRule {from = from', to = to', status = status'})

-- | A response-header rule: add header @name: value@ to responses whose request
-- path matches @path@. Construct with 'mkHeaderRule'; direct record
-- construction bypasses header-name validation.
data HeaderRule = HeaderRule
  { path :: !Text
  , name :: !Text
  , value :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | Validate and construct a 'HeaderRule'. @path@ must be non-empty and
-- whitespace-free; the header @name@ must be non-empty and contain no
-- whitespace, control characters, or colon.
mkHeaderRule :: Text -> Text -> Text -> Either Text HeaderRule
mkHeaderRule path' name' value'
  | Text.null path' = Left "header rule 'path' must not be empty"
  | Text.any isSpace path' = Left ("header rule 'path' must not contain whitespace: " <> path')
  | Text.null name' = Left "header name must not be empty"
  | Text.any isSpace name' = Left ("header name must not contain whitespace: " <> name')
  | Text.any isControl name' = Left ("header name must not contain control characters: " <> name')
  | Text.elem ':' name' = Left ("header name must not contain a colon: " <> name')
  | otherwise = Right (HeaderRule {path = path', name = name', value = value'})

-- | The cache-control policy for served responses. @immutableAssets@ emits a
-- long-lived immutable @Cache-Control@ for fingerprinted static assets;
-- @defaultMaxAge@ sets a default @max-age@ (in seconds) for everything else.
data CachePolicy = CachePolicy
  { immutableAssets :: !Bool
  , defaultMaxAge :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

-- | The neutral cache policy: no immutable-asset rule and no default max-age.
defaultCachePolicy :: CachePolicy
defaultCachePolicy = CachePolicy {immutableAssets = False, defaultMaxAge = Nothing}

-- | Validate and construct a 'CachePolicy'. A negative @defaultMaxAge@ is
-- rejected.
mkCachePolicy :: Bool -> Maybe Int -> Either Text CachePolicy
mkCachePolicy immutable maxAge
  | Just n <- maxAge, n < 0 = Left ("cache max-age must be >= 0, got: " <> tshow n)
  | otherwise = Right (CachePolicy {immutableAssets = immutable, defaultMaxAge = maxAge})

-- | A static site: a built directory of files served by Nginx through a Knative
-- Service, with optional custom domains, redirects, header rules, a cache
-- policy, and a 404 page. Assemble with a record literal after constructing each
-- field through its smart constructor (the @namespace@, @image@, and @domains@
-- leaves reuse 'Nagare.Dsl.Types').
data StaticSite = StaticSite
  { name :: !SiteName
  , namespace :: !Namespace
  , image :: !ImageRef
  , build :: !StaticBuild
  , domains :: ![Domain]
  , redirects :: ![RedirectRule]
  , headers :: ![HeaderRule]
  , cache :: !CachePolicy
  , notFound :: !(Maybe FilePathText)
  }
  deriving stock (Generic, Eq, Show)

-- Internal: show a value as Text for error messages.
tshow :: (Show a) => a -> Text
tshow = Text.pack . show

-- Internal: a valid RFC 1123 label character (lowercase alnum or hyphen).
validLabelChar :: Char -> Bool
validLabelChar c = isLower c || isDigit c || c == '-'
