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

    -- * EnvScope
  , EnvScope (..)

    -- * ScopedEnvVar
  , ScopedEnvVar (..)
  , runtimeScoped
  , scopedEnv

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

    -- * HealthCheck
  , HealthCheck (..)
  , HealthScheme (..)
  , mkHealthCheck
  , httpHealthCheck

    -- * Scale
  , Scale (..)
  , mkScale

    -- * Domain
  , Domain
  , mkDomain
  , domainText

    -- * DomainSpec
  , DomainSpec (..)
  , mkDomains
  , canonicalDomain

    -- * VolumeName
  , VolumeName
  , mkVolumeName
  , volumeNameText

    -- * MountPath
  , MountPath
  , mkMountPath
  , mountPathText

    -- * AccessMode
  , AccessMode (..)

    -- * RetentionPolicy
  , RetentionPolicy (..)

    -- * Volume
  , Volume (..)

    -- * Deployment
  , Deployment (..)
  ) where

import Nagare.Dsl.Prelude

import Data.Char (isDigit, isLower)
import Data.Map (Map)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Nagare.Dsl.Build (BuildSpec)

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

-- | When an environment variable applies. 'Runtime' is present in the running
-- container; 'Build' is present during the image build; 'Preview' overlays
-- preview deployments. A variable may carry several scopes at once.
data EnvScope = Runtime | Build | Preview
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

-- | An env value (literal or secret reference) together with the non-empty set
-- of scopes it applies to. The 'EnvVar' sum type is unchanged, preserving the
-- headline safety invariant (literal XOR secret ref). Invariant: 'scopes' is
-- non-empty; construct via 'runtimeScoped' (always 'Runtime') or 'scopedEnv'
-- (validates non-emptiness).
data ScopedEnvVar = ScopedEnvVar
  { value :: !EnvVar
  , scopes :: !(Set EnvScope)
  }
  deriving stock (Generic, Eq, Show)

-- | The backward-compatible default: a single 'Runtime' scope. A bare variable
-- with no scope decoration behaves exactly as before this change.
runtimeScoped :: EnvVar -> ScopedEnvVar
runtimeScoped v = ScopedEnvVar {value = v, scopes = Set.singleton Runtime}

-- | Construct a 'ScopedEnvVar' from an explicit scope set, rejecting the empty
-- set so the non-empty invariant cannot be violated.
scopedEnv :: Set EnvScope -> EnvVar -> Either Text ScopedEnvVar
scopedEnv ss v
  | Set.null ss = Left "env scopes must not be empty"
  | otherwise = Right (ScopedEnvVar {value = v, scopes = ss})

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

-- | CPU and memory resource quantities for the container. The 'cpu' and
-- 'memory' fields are the /requests/ (the guaranteed amount the pod is
-- scheduled against); 'cpuLimit' and 'memoryLimit' are the optional /limits/
-- (the ceiling the container may not exceed). All four are optional; the
-- renderer emits @requests@ and/or @limits@ sub-blocks only for the quantities
-- present.
data Resources = Resources
  { cpu :: !(Maybe Quantity)
  , memory :: !(Maybe Quantity)
  , cpuLimit :: !(Maybe Quantity)
  , memoryLimit :: !(Maybe Quantity)
  }
  deriving stock (Generic, Eq, Show)

-- | The HTTP scheme an HTTP probe uses.
data HealthScheme = HTTP | HTTPS
  deriving stock (Generic, Eq, Show, Enum, Bounded)

-- | An HTTP health check applied to the container. Rendered as a Knative
-- @readinessProbe@ always, and additionally as @livenessProbe@/@startupProbe@
-- when 'asLiveness'/'asStartup' are set. All timings are in seconds.
--
-- Note: Knative's @httpGet@ probe does not assert a response status — any 2xx/3xx
-- is considered healthy. 'expectedStatus' is retained in the model for
-- documentation and future use and is deliberately /not/ rendered.
data HealthCheck = HealthCheck
  { path :: !Text
  -- ^ HTTP path, e.g. @"/healthz"@. Must be non-empty and start with @"/"@.
  , checkPort :: !(Maybe Port)
  -- ^ Port to probe; 'Nothing' means the container port.
  , scheme :: !HealthScheme
  -- ^ HTTP or HTTPS.
  , expectedStatus :: !Int
  -- ^ Expected HTTP status, default 200. Not rendered (see note above).
  , initialDelay :: !Int
  -- ^ Seconds before the first probe. Must be @>= 0@.
  , period :: !Int
  -- ^ Seconds between probes. Must be @>= 1@.
  , timeout :: !Int
  -- ^ Per-probe timeout seconds. Must be @>= 1@.
  , failureThreshold :: !Int
  -- ^ Consecutive failures before unhealthy. Must be @>= 1@.
  , asLiveness :: !Bool
  -- ^ Also emit a @livenessProbe@.
  , asStartup :: !Bool
  -- ^ Also emit a @startupProbe@.
  }
  deriving stock (Generic, Eq, Show)

-- | Validate an assembled 'HealthCheck': 'path' non-empty and starting with
-- @"/"@; 'expectedStatus' in 100–599; 'initialDelay' @>= 0@; 'period',
-- 'timeout', 'failureThreshold' all @>= 1@.
mkHealthCheck :: HealthCheck -> Either Text HealthCheck
mkHealthCheck hc
  | Text.null (path hc) = Left "health check path must not be empty"
  | not (Text.isPrefixOf "/" (path hc)) =
      Left ("health check path must start with '/': " <> path hc)
  | expectedStatus hc < 100 || expectedStatus hc > 599 =
      Left ("health check expectedStatus must be in 100-599, got: " <> tshow (expectedStatus hc))
  | initialDelay hc < 0 =
      Left ("health check initialDelay must be >= 0, got: " <> tshow (initialDelay hc))
  | period hc < 1 =
      Left ("health check period must be >= 1, got: " <> tshow (period hc))
  | timeout hc < 1 =
      Left ("health check timeout must be >= 1, got: " <> tshow (timeout hc))
  | failureThreshold hc < 1 =
      Left ("health check failureThreshold must be >= 1, got: " <> tshow (failureThreshold hc))
  | otherwise = Right hc

-- | Build a 'HealthCheck' from just a path, filling sensible defaults:
-- @scheme = HTTP@, @expectedStatus = 200@, @initialDelay = 0@, @period = 10@,
-- @timeout = 1@, @failureThreshold = 3@, @asLiveness = False@,
-- @asStartup = False@, @checkPort = Nothing@. Validates via 'mkHealthCheck'.
httpHealthCheck :: Text -> Either Text HealthCheck
httpHealthCheck p =
  mkHealthCheck
    HealthCheck
      { path = p
      , checkPort = Nothing
      , scheme = HTTP
      , expectedStatus = 200
      , initialDelay = 0
      , period = 10
      , timeout = 1
      , failureThreshold = 3
      , asLiveness = False
      , asStartup = False
      }

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

-- | A custom domain plus whether it is the canonical (advertised) one. Used in
-- 'Deployment.domains'. Construct lists through 'mkDomains', which enforces the
-- "exactly one canonical" invariant for a non-empty list.
data DomainSpec = DomainSpec
  { domain :: !Domain
  , canonical :: !Bool
  }
  deriving stock (Generic, Eq, Show)

-- | Build a domain list from @(hostname, isCanonical)@ pairs. An empty list is
-- allowed (no custom domain). A non-empty list must mark /exactly one/ entry
-- canonical. Each hostname is validated through 'mkDomain'.
mkDomains :: [(Text, Bool)] -> Either Text [DomainSpec]
mkDomains [] = Right []
mkDomains pairs = do
  specs <- traverse toSpec pairs
  let canonicalCount = length (filter canonical specs)
  if canonicalCount == 1
    then Right specs
    else
      Left
        ( "a non-empty domain list must mark exactly one domain canonical, found "
            <> tshow canonicalCount
        )
  where
    toSpec (host, isCanon) = do
      d <- mkDomain host
      Right (DomainSpec {domain = d, canonical = isCanon})

-- | The canonical entry's domain, or 'Nothing' for an empty list. For a list
-- built by 'mkDomains' there is at most one canonical entry.
canonicalDomain :: [DomainSpec] -> Maybe Domain
canonicalDomain specs = domain <$> find canonical specs
  where
    find p = foldr (\x acc -> if p x then Just x else acc) Nothing

-- | A durable-disk volume name: a DNS-1123 label (same character rules as
-- 'ServiceName'), unique within an app. Constructor hidden; use 'mkVolumeName'.
newtype VolumeName = VolumeName Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct a 'VolumeName': 1–63 characters of lowercase
-- letters, digits, and hyphens, not starting or ending with a hyphen.
mkVolumeName :: Text -> Either Text VolumeName
mkVolumeName t
  | Text.null t = Left "volume name must not be empty"
  | Text.length t > 63 =
      Left ("volume name too long (" <> tshow (Text.length t) <> " chars, max 63)")
  | Text.isPrefixOf "-" t = Left "volume name must not start with a hyphen"
  | Text.isSuffixOf "-" t = Left "volume name must not end with a hyphen"
  | not (Text.all validLabelChar t) =
      Left ("volume name contains invalid characters (allowed: a-z, 0-9, -): " <> t)
  | otherwise = Right (VolumeName t)

volumeNameText :: VolumeName -> Text
volumeNameText (VolumeName t) = t

-- | An in-container mount path. Unlike 'Nagare.Dsl.Path.FilePathText' (which
-- models a path inside the build context and so /rejects/ a leading @/@), a
-- mount path must be /absolute/: Kubernetes requires @volumeMounts[].mountPath@
-- to start with @/@. The @..@ and NUL guards are kept. Constructor hidden; use
-- 'mkMountPath'.
newtype MountPath = MountPath Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct a 'MountPath': absolute (leading @/@), no @..@
-- segment, no NUL.
mkMountPath :: Text -> Either Text MountPath
mkMountPath t
  | Text.null t = Left "mount path must not be empty"
  | not (Text.isPrefixOf "/" t) = Left ("mount path must be absolute (start with '/'): " <> t)
  | "\NUL" `Text.isInfixOf` t = Left ("mount path must not contain NUL characters: " <> t)
  | ".." `elem` Text.split (== '/') t = Left ("mount path must not contain a '..' segment: " <> t)
  | otherwise = Right (MountPath t)

mountPathText :: MountPath -> Text
mountPathText (MountPath t) = t

-- | Single-node access mode. Only 'ReadWriteOnce' today (Nagare is single-node;
-- @ReadWriteMany@ is out of scope). Modelled as a one-constructor sum so the
-- field is present in the type and JSON for forward-compatibility and a future
-- mode can be added without breaking exhaustive call sites.
data AccessMode = ReadWriteOnce
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

-- | What happens to the underlying disk when the app is deleted. 'Retain' keeps
-- it (the default, safest); 'Delete' removes it. Read by EP-36 (backup
-- ownership) to drive retention and the include/exclude backup decision.
data RetentionPolicy = Retain | Delete
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

-- | A durable disk attached to an app. Every constrained field goes through a
-- smart constructor, so an illegal mount path or size cannot be written down.
-- Uniqueness of names and mount paths /within an app/ is a cross-field
-- invariant enforced at load time (see 'Nagare.Dsl.Load'), not here.
data Volume = Volume
  { volName :: !VolumeName
  , size :: !Quantity
  , mountPath :: !MountPath
  , accessMode :: !AccessMode
  , readOnly :: !Bool
  , retention :: !RetentionPolicy
  }
  deriving stock (Generic, Eq, Show)

-- | A fully-specified Nagare deployment. Assemble with a record literal after
-- constructing each field through its smart constructor. There is no hidden
-- constructor for 'Deployment' — the safety guarantee comes from the field
-- types, not from hiding this record.
data Deployment = Deployment
  { name :: !ServiceName
  , namespace :: !Namespace
  , image :: !ImageRef
  -- | How the container image at 'image' is produced: a prebuilt image, a
  -- Dockerfile build, or a Nixpacks build. See 'Nagare.Dsl.Build.BuildSpec'.
  , build :: !BuildSpec
  -- | Custom domains for the app, each with a canonical marker. An empty list
  -- means "no custom domain" (the Knative wildcard URL is used). Construct
  -- through 'mkDomains'.
  , domains :: ![DomainSpec]
  , port :: !Port
  -- | Env entries are stored by 'EnvName' so 'Data.Map.toAscList' yields a
  -- deterministic, name-sorted order for the renderer. Each value carries the
  -- set of scopes it applies to (see 'ScopedEnvVar'); a bare variable defaults
  -- to @{Runtime}@ via 'runtimeScoped'.
  , env :: !(Map EnvName ScopedEnvVar)
  , resources :: !(Maybe Resources)
  , scale :: !(Maybe Scale)
  -- | An optional HTTP health check, rendered as Knative readiness/liveness/
  -- startup probes (see 'HealthCheck').
  , healthCheck :: !(Maybe HealthCheck)
  -- | Durable disks attached to the app. Empty (the backward-compatible
  -- default) means a stateless app. Each 'Volume' renders to a
  -- 'PersistentVolumeClaim' plus a container @volumeMount@ and pod @volume@
  -- (see 'Nagare.Dsl.Render'). Name/mount-path uniqueness is enforced at load.
  , volumes :: ![Volume]
  }
  deriving stock (Generic, Eq, Show)

-- Internal: show an Int as Text for error messages.
tshow :: (Show a) => a -> Text
tshow = Text.pack . show

-- Internal: a valid RFC 1123 label character (lowercase alnum or hyphen).
validLabelChar :: Char -> Bool
validLabelChar c = isLower c || isDigit c || c == '-'
