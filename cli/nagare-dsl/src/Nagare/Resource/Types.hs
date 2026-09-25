-- | Stable identities and provider collision domains. No opaque type has Generic.
module Nagare.Resource.Types
  ( ContextId
  , mkContextId
  , contextIdText
  , ScopeKind (..)
  , ScopeId
  , mkScopeId
  , scopeKind
  , scopeName
  , scopeIdText
  , LogicalKey
  , mkLogicalKey
  , logicalKeyText
  , ResourceId
  , mintResourceId
  , mkResourceId
  , resourceIdText
  , ScopeGeneration
  , mkScopeGeneration
  , generationNumber
  , nextGeneration
  , ContentDigest
  , mkContentDigest
  , digestText
  , PhysicalIdentity
  , mkPhysicalIdentity
  , physicalIdentityText
  , Name
  , mkName
  , mkKubernetesName
  , nameText
  , ContextBinding (..)
  , ProviderAddress (..)
  , mkProviderAddress
  , kubernetesAddress
  , CanonicalClaim
  , canonicalClaim
  , claimParts
  , SourceLocation (..)
  , InventoryError (..)
  , inventoryError
  )
where

import Data.Char (isAsciiLower, isDigit)
import Data.Text qualified as T
import Nagare.Dsl.Prelude

newtype Name = Name Text deriving stock (Eq, Ord, Show)

mkName :: Text -> Either Text Name
mkName t
  | T.null t || T.length t > 253 = Left "name must contain 1..253 characters"
  | T.any (\c -> not (isAsciiLower c || isDigit c || c `elem` ("-._" :: String))) t = Left "name must be lowercase ASCII without separators"
  | otherwise = Right (Name t)

-- Kubernetes RBAC object names may contain colons (for example a ClusterRole
-- for a named API permission). Keep that syntax out of scope/logical IDs.
mkKubernetesName :: Text -> Either Text Name
mkKubernetesName t
  | T.null t || T.length t > 253 = Left "Kubernetes name must contain 1..253 characters"
  | T.any (\c -> not (isAsciiLower c || isDigit c || c `elem` ("-._:" :: String))) t =
      Left "Kubernetes name contains an unsupported character"
  | otherwise = Right (Name t)

nameText :: Name -> Text
nameText (Name t) = t

newtype ContextId = ContextId Name deriving stock (Eq, Ord, Show)

mkContextId :: Text -> Either Text ContextId
mkContextId = fmap ContextId . mkName

contextIdText :: ContextId -> Text
contextIdText (ContextId n) = nameText n

data ScopeKind = Platform | Application | Standalone | Publication deriving stock (Eq, Ord, Show, Generic)

data ScopeId = ScopeId ScopeKind Name deriving stock (Eq, Ord, Show)

mkScopeId :: ScopeKind -> Text -> Either Text ScopeId
mkScopeId k = fmap (ScopeId k) . mkName

scopeKind :: ScopeId -> ScopeKind
scopeKind (ScopeId k _) = k

scopeName :: ScopeId -> Name
scopeName (ScopeId _ n) = n

scopeIdText :: ScopeId -> Text
scopeIdText (ScopeId k n) = T.toLower (T.pack (show k)) <> ":" <> nameText n

newtype LogicalKey = LogicalKey Name deriving stock (Eq, Ord, Show)

mkLogicalKey :: Text -> Either Text LogicalKey
mkLogicalKey = fmap LogicalKey . mkName

logicalKeyText :: LogicalKey -> Text
logicalKeyText (LogicalKey n) = nameText n

newtype ResourceId = ResourceId Text deriving stock (Eq, Ord, Show)

-- | Length-independent separators cannot occur in the smart-constructed parts.
mintResourceId :: ScopeId -> LogicalKey -> Name -> ResourceId
mintResourceId s k r = ResourceId (scopeIdText s <> "/" <> logicalKeyText k <> "/" <> nameText r)

mkResourceId :: Text -> Either Text ResourceId
mkResourceId t = case T.splitOn "/" t of
  [s, k, r] -> case T.splitOn ":" s of
    [kind, n] -> do
      sk <- case kind of
        "platform" -> Right Platform
        "application" -> Right Application
        "standalone" -> Right Standalone
        "publication" -> Right Publication
        _ -> Left "unknown minting scope kind"
      mintResourceId <$> mkScopeId sk n <*> mkLogicalKey k <*> mkName r
    _ -> Left "invalid resource minting scope"
  _ -> Left "resource identity needs minting scope, stable key, and role"

resourceIdText :: ResourceId -> Text
resourceIdText (ResourceId t) = t

newtype ScopeGeneration = ScopeGeneration Integer deriving stock (Eq, Ord, Show)

mkScopeGeneration :: Integer -> Either Text ScopeGeneration
mkScopeGeneration n
  | n > 0 = Right (ScopeGeneration n)
  | otherwise = Left "generation must be positive"

generationNumber :: ScopeGeneration -> Integer
generationNumber (ScopeGeneration n) = n

nextGeneration :: Maybe ScopeGeneration -> ScopeGeneration
nextGeneration = ScopeGeneration . maybe 1 ((+ 1) . generationNumber)

newtype ContentDigest = ContentDigest Text deriving stock (Eq, Ord, Show)

mkContentDigest :: Text -> Either Text ContentDigest
mkContentDigest t
  | T.length t == 64 && T.all (\c -> isDigit c || c `elem` ("abcdef" :: String)) t = Right (ContentDigest t)
  | otherwise = Left "digest must be 64 lowercase hexadecimal SHA-256 characters"

digestText :: ContentDigest -> Text
digestText (ContentDigest t) = t

newtype PhysicalIdentity = PhysicalIdentity Text deriving stock (Eq, Ord, Show)

mkPhysicalIdentity :: Text -> Either Text PhysicalIdentity
mkPhysicalIdentity t
  | T.null (T.strip t) || T.any (< ' ') t = Left "invalid physical identity"
  | otherwise = Right (PhysicalIdentity t)

physicalIdentityText :: PhysicalIdentity -> Text
physicalIdentityText (PhysicalIdentity t) = t

data ContextBinding = ContextBinding {identity :: !ContextId, project :: !Name}
  deriving stock (Eq, Ord, Show, Generic)

-- | API version is intentionally absent: versions do not create new objects.
data ProviderAddress
  = Kubernetes ResourceId Text Name (Maybe Name) Name
  | GlobalBucket Name
  | CloudInstance Name Name Name
  | PulumiUrn Text
  | Host ResourceId Name
  | Artifact Name ContentDigest
  | Hostname Name
  | DatabaseName ResourceId Name
  | BackendRoute ResourceId Name
  | AtticCache ResourceId Name
  | BrokerTopic ResourceId Name
  | Helm ResourceId Name Name
  | DnsRecord Name Name Name
  deriving stock (Eq, Ord, Show, Generic)

newtype CanonicalClaim = CanonicalClaim [Text] deriving stock (Eq, Ord, Show)

mkProviderAddress :: ProviderAddress -> Either Text ProviderAddress
mkProviderAddress address = case address of
  Kubernetes _ group _ _ _ -> do
    unless (T.null group) (void (mkName group))
    pure address
  PulumiUrn urn -> do
    unless ("urn:pulumi:" `T.isPrefixOf` urn && length (T.splitOn "::" urn) == 4 && all (not . T.null) (T.splitOn "::" urn) && not (T.any (< ' ') urn)) (Left "invalid Pulumi URN")
    pure address
  _ -> Right address

-- | Convert native apiVersion/kind presentation to the version-independent key.
kubernetesAddress :: ResourceId -> Text -> Text -> Maybe Text -> Text -> Either Text ProviderAddress
kubernetesAddress target apiVersion kind namespace name = do
  group <- case T.splitOn "/" apiVersion of
    [version] | not (T.null version) -> Right ""
    [g, version] | not (T.null g), not (T.null version) -> Right g
    _ -> Left "invalid Kubernetes apiVersion"
  address <- Kubernetes target group <$> mkName (T.toLower kind) <*> traverse mkName namespace <*> mkKubernetesName name
  mkProviderAddress address

canonicalClaim :: ProviderAddress -> CanonicalClaim
canonicalClaim =
  CanonicalClaim . \case
    Kubernetes cluster group kind namespace n -> ["kubernetes", resourceIdText cluster, T.toLower group, nameText kind, maybe "" nameText namespace, nameText n]
    GlobalBucket n -> ["bucket", nameText n]
    CloudInstance p z n -> ["instance", nameText p, nameText z, nameText n]
    PulumiUrn n -> ["pulumi", n]
    Host cluster n -> ["host", resourceIdText cluster, nameText n]
    Artifact n d -> ["artifact", nameText n, digestText d]
    Hostname n -> ["hostname", nameText n]
    DatabaseName r n -> ["database", resourceIdText r, nameText n]
    BackendRoute r n -> ["route", resourceIdText r, nameText n]
    AtticCache r n -> ["attic-cache", resourceIdText r, nameText n]
    BrokerTopic r n -> ["broker-topic", resourceIdText r, nameText n]
    Helm r namespace n -> ["helm", resourceIdText r, nameText namespace, nameText n]
    DnsRecord account zone host -> ["dns-record", nameText account, nameText zone, nameText host]

claimParts :: CanonicalClaim -> [Text]
claimParts (CanonicalClaim xs) = xs

data SourceLocation = SourceLocation {file :: !Text, path :: !Text}
  deriving stock (Eq, Ord, Show, Generic)

data InventoryError = InventoryError
  { code :: !Text
  , message :: !Text
  , scopes :: ![ScopeId]
  , resources :: ![ResourceId]
  , claims :: ![CanonicalClaim]
  , sources :: ![SourceLocation]
  }
  deriving stock (Eq, Ord, Show, Generic)

inventoryError :: Text -> Text -> InventoryError
inventoryError c m = InventoryError c m [] [] [] []
