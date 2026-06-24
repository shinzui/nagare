-- | Identity-aware access policy for web-facing Nagare services.
--
-- The common case is 'requireLogin': the service is still deployed as a normal
-- Knative Service, but deploy-time wiring will route public traffic through the
-- shared nagare-access enforcer. The renderer deliberately emits no Kubernetes
-- YAML for this value; nagarectl resolves it later against the live cluster.
module Nagare.Dsl.Access
  ( AccessPolicy (..)
  , Audience
  , mkAudience
  , audienceText
  , AccessPermission
  , mkAccessPermission
  , accessPermissionText
  , requireLogin
  )
where

import Data.Char (isDigit, isLower)
import Data.Text qualified as Text
import Nagare.Dsl.Prelude

-- | A per-site access policy. 'Nothing' audience means the cluster default
-- audience configured on the enforcer; the default permission is @"access"@.
data AccessPolicy = AccessPolicy
  { audience :: !(Maybe Audience)
  , permission :: !AccessPermission
  }
  deriving stock (Generic, Eq, Show)

-- | The one-line opt-in for a private site.
requireLogin :: AccessPolicy
requireLogin =
  AccessPolicy
    { audience = Nothing
    , permission = AccessPermission "access"
    }

newtype Audience = Audience Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate a token audience. Keep it host-ish: non-empty, no whitespace, and
-- no URI scheme. This accepts ordinary shomei audiences such as @nagare@ or a
-- host-like value while rejecting values that cannot be safely shown in config.
mkAudience :: Text -> Either Text Audience
mkAudience t
  | Text.null t = Left "access audience must not be empty"
  | Text.any isSpaceLike t = Left ("access audience must not contain whitespace: " <> t)
  | "://" `Text.isInfixOf` t =
      Left ("access audience must not include a URI scheme (http://, https://): " <> t)
  | otherwise = Right (Audience t)

audienceText :: Audience -> Text
audienceText (Audience t) = t

newtype AccessPermission = AccessPermission Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate an en permission token. The initial contract uses lowercase
-- identifier characters so the default @"access"@ maps cleanly to the en schema.
mkAccessPermission :: Text -> Either Text AccessPermission
mkAccessPermission t
  | Text.null t = Left "access permission must not be empty"
  | not (Text.all validPermissionChar t) =
      Left ("access permission contains invalid characters (allowed: a-z, 0-9, _): " <> t)
  | otherwise = Right (AccessPermission t)

accessPermissionText :: AccessPermission -> Text
accessPermissionText (AccessPermission t) = t

validPermissionChar :: Char -> Bool
validPermissionChar c = isLower c || isDigit c || c == '_'

isSpaceLike :: Char -> Bool
isSpaceLike c = c == ' ' || c == '\t' || c == '\n' || c == '\r'
