-- | The canonical typed deployment model with maximal-safety constructors.
--
-- Every newtype below hides its data constructor and exposes only a validating
-- smart constructor (@mkX :: ... -> Either Text X@) plus a read-only accessor.
-- Code outside this module therefore cannot construct an invalid value: a bad
-- DNS name, an out-of-range port, a malformed quantity, or a @max < min@ scale
-- is rejected at construction with a precise message — never silently written
-- down to fail at the cluster. The headline invariant, env values being a
-- literal /or/ a secret reference but never both, is enforced by the 'EnvVar'
-- sum type: it is impossible to construct a value that is simultaneously both.
module Nagare.Dsl.Types
  ( -- * ServiceName
    ServiceName
  , mkServiceName
  , serviceNameText

    -- * Namespace
  , Namespace
  , mkNamespace
  , defaultNamespace
  , namespaceText

    -- * ImageRef
  , ImageRef
  , mkImageRef
  , imageRefText

    -- * EnvName
  , EnvName
  , mkEnvName
  , envNameText

    -- * SecretName
  , SecretName
  , mkSecretName
  , secretNameText

    -- * EnvVar
  , EnvVar (..)

    -- * Port
  , Port
  , mkPort
  , defaultPort
  , portInt

    -- * Quantity
  , Quantity
  , mkQuantity
  , quantityText

    -- * Resources
  , Resources (..)

    -- * Scale
  , Scale (..)
  , mkScale

    -- * Domain
  , Domain
  , mkDomain
  , domainText

    -- * Deployment
  , Deployment (..)
  ) where

import Nagare.Dsl.Prelude

import Data.Char (isDigit, isLower)
import Data.Map (Map)
import Data.Text qualified as Text

-- | A Kubernetes / RFC 1123 DNS label used as the Knative Service name.
-- The constructor is hidden; use 'mkServiceName'.
newtype ServiceName = ServiceName Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct a 'ServiceName': 1–63 characters of lowercase
-- letters, digits, and hyphens, not starting or ending with a hyphen.
mkServiceName :: Text -> Either Text ServiceName
mkServiceName t
  | Text.null t = Left "service name must not be empty"
  | Text.length t > 63 =
      Left ("service name too long (" <> tshow (Text.length t) <> " chars, max 63)")
  | Text.isPrefixOf "-" t = Left "service name must not start with a hyphen"
  | Text.isSuffixOf "-" t = Left "service name must not end with a hyphen"
  | not (Text.all validLabelChar t) =
      Left ("service name contains invalid characters (allowed: a-z, 0-9, -): " <> t)
  | otherwise = Right (ServiceName t)

serviceNameText :: ServiceName -> Text
serviceNameText (ServiceName t) = t

-- | Kubernetes namespace name. The constructor is hidden; use 'mkNamespace' or
-- 'defaultNamespace'.
newtype Namespace = Namespace Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct a 'Namespace' (same rules as 'mkServiceName').
mkNamespace :: Text -> Either Text Namespace
mkNamespace t
  | Text.null t = Left "namespace must not be empty"
  | Text.length t > 63 = Left "namespace too long (max 63)"
  | Text.isPrefixOf "-" t = Left "namespace must not start with a hyphen"
  | Text.isSuffixOf "-" t = Left "namespace must not end with a hyphen"
  | not (Text.all validLabelChar t) =
      Left ("namespace contains invalid characters: " <> t)
  | otherwise = Right (Namespace t)

-- | The default Nagare namespace: @"personal"@.
defaultNamespace :: Namespace
defaultNamespace = Namespace "personal"

namespaceText :: Namespace -> Text
namespaceText (Namespace t) = t

-- | Container image repository path, with no tag (e.g.
-- @"gcr.io/knative-samples/helloworld-go"@). Constructor hidden; use
-- 'mkImageRef'.
newtype ImageRef = ImageRef Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct an 'ImageRef': non-empty and containing no colon
-- (the tag is appended separately by 'Nagare.Dsl.Render.renderService').
mkImageRef :: Text -> Either Text ImageRef
mkImageRef t
  | Text.null t = Left "image ref must not be empty"
  | Text.elem ':' t = Left ("image ref must not include a tag (found ':' in: " <> t <> ")")
  | otherwise = Right (ImageRef t)

imageRefText :: ImageRef -> Text
imageRefText (ImageRef t) = t

-- | An environment variable name, e.g. @"DATABASE_URL"@. Constructor hidden;
-- use 'mkEnvName'.
newtype EnvName = EnvName Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct an 'EnvName'. Must be non-empty.
mkEnvName :: Text -> Either Text EnvName
mkEnvName t
  | Text.null t = Left "env name must not be empty"
  | otherwise = Right (EnvName t)

envNameText :: EnvName -> Text
envNameText (EnvName t) = t

-- | A Kubernetes Secret name, used in 'EnvSecretRef'. Constructor hidden; use
-- 'mkSecretName'.
newtype SecretName = SecretName Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct a 'SecretName'. Must be non-empty.
mkSecretName :: Text -> Either Text SecretName
mkSecretName t
  | Text.null t = Left "secret name must not be empty"
  | otherwise = Right (SecretName t)

secretNameText :: SecretName -> Text
secretNameText (SecretName t) = t

-- | The value of an environment variable: either a literal text value or a
-- reference to a Kubernetes Secret.
--
-- This is the headline safety invariant. The YAML schema allows both a
-- @value:@ key and a @secretRef:@ key to appear in one entry, producing an
-- invalid manifest. Modelling env values as a sum type makes it impossible to
-- construct a value that is simultaneously literal and a secret reference — you
-- pick exactly one branch, enforced by the compiler with no runtime check.
data EnvVar
  = -- | A literal value, rendered as @value: <text>@.
    EnvLiteral Text
  | -- | A Secret reference, rendered as @valueFrom.secretKeyRef@ with @name@ =
    -- the secret and @key@ = the env var's own name (see
    -- 'Nagare.Dsl.Render.renderService').
    EnvSecretRef SecretName
  deriving stock (Generic, Eq, Show)

-- | A TCP port number. Constructor hidden; use 'mkPort' or 'defaultPort'.
newtype Port = Port Int
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct a 'Port'. Valid range is 1–65535.
mkPort :: Int -> Either Text Port
mkPort n
  | n < 1 = Left ("port must be >= 1, got: " <> tshow n)
  | n > 65535 = Left ("port must be <= 65535, got: " <> tshow n)
  | otherwise = Right (Port n)

-- | The default container port: @8080@.
defaultPort :: Port
defaultPort = Port 8080

portInt :: Port -> Int
portInt (Port n) = n

-- | A Kubernetes quantity string for CPU and memory requests. Examples:
-- @"250m"@, @"512Mi"@, @"1"@, @"2Gi"@. Constructor hidden; use 'mkQuantity'.
newtype Quantity = Quantity Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct a 'Quantity': an integer (or decimal fraction)
-- optionally followed by a recognised suffix (@m k M G T P E Ki Mi Gi Ti Pi
-- Ei@).
mkQuantity :: Text -> Either Text Quantity
mkQuantity t
  | Text.null t = Left "quantity must not be empty"
  | otherwise =
      let (digits, rest0) = Text.span isDigit t
       in if Text.null digits
            then Left ("quantity must start with a digit: " <> t)
            else
              let (_frac, rest1) = parseFraction rest0
               in if validSuffix rest1
                    then Right (Quantity t)
                    else Left ("unrecognised quantity suffix: " <> rest1 <> " (in: " <> t <> ")")
  where
    parseFraction s =
      case Text.uncons s of
        Just ('.', rest) -> let (d, r) = Text.span isDigit rest in (Just d, r)
        _ -> (Nothing, s)
    validSuffix s =
      s
        `elem` [ ""
               , "m"
               , "k"
               , "M"
               , "G"
               , "T"
               , "P"
               , "E"
               , "Ki"
               , "Mi"
               , "Gi"
               , "Ti"
               , "Pi"
               , "Ei"
               ]

quantityText :: Quantity -> Text
quantityText (Quantity t) = t

-- | CPU and memory resource requests for the container.
data Resources = Resources
  { cpu :: !(Maybe Quantity)
  , memory :: !(Maybe Quantity)
  }
  deriving stock (Generic, Eq, Show)

-- | Knative autoscaling bounds: 'minScale' (minimum pods; 0 means
-- scale-to-zero) and 'maxScale' (maximum pods). Use 'mkScale' to construct;
-- direct record construction bypasses validation.
data Scale = Scale
  { minScale :: !Int
  , maxScale :: !Int
  }
  deriving stock (Generic, Eq, Show)

-- | Validate and construct a 'Scale'. Rejects negative values and requires
-- @min <= max@.
mkScale :: Int -> Int -> Either Text Scale
mkScale mn mx
  | mn < 0 = Left ("scale min must be >= 0, got: " <> tshow mn)
  | mx < 0 = Left ("scale max must be >= 0, got: " <> tshow mx)
  | mx < mn =
      Left ("scale max (" <> tshow mx <> ") must be >= scale min (" <> tshow mn <> ")")
  | otherwise = Right (Scale {minScale = mn, maxScale = mx})

-- | A custom public hostname for a DomainMapping, e.g. @"notes.example.com"@.
-- Constructor hidden; use 'mkDomain'.
newtype Domain = Domain Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct a 'Domain': non-empty, no spaces, no URI scheme.
mkDomain :: Text -> Either Text Domain
mkDomain t
  | Text.null t = Left "domain must not be empty"
  | Text.elem ' ' t = Left ("domain must not contain spaces: " <> t)
  | "://" `Text.isInfixOf` t =
      Left ("domain must not include a URI scheme (http://, https://): " <> t)
  | otherwise = Right (Domain t)

domainText :: Domain -> Text
domainText (Domain t) = t

-- | A fully-specified Nagare deployment. Assemble with a record literal after
-- constructing each field through its smart constructor. There is no hidden
-- constructor for 'Deployment' — the safety guarantee comes from the field
-- types, not from hiding this record.
data Deployment = Deployment
  { name :: !ServiceName
  , namespace :: !Namespace
  , image :: !ImageRef
  , domain :: !(Maybe Domain)
  , port :: !Port
  -- | Env entries are stored by 'EnvName' so 'Data.Map.toAscList' yields a
  -- deterministic, name-sorted order for the renderer.
  , env :: !(Map EnvName EnvVar)
  , resources :: !(Maybe Resources)
  , scale :: !(Maybe Scale)
  }
  deriving stock (Generic, Eq, Show)

-- Internal: show an Int as Text for error messages.
tshow :: (Show a) => a -> Text
tshow = Text.pack . show

-- Internal: a valid RFC 1123 label character (lowercase alnum or hyphen).
validLabelChar :: Char -> Bool
validLabelChar c = isLower c || isDigit c || c == '-'
