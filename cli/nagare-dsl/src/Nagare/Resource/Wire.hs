{-# LANGUAGE GADTs #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Versioned untrusted declarations. There is intentionally no inventory decoder.
module Nagare.Resource.Wire
  ( encodeCanonicalScope
  , decodeScope
  , canonicalValue
  , scopeValue
  , CandidateInput (..)
  , decodeCandidateInput
  , candidateInputValue
  , bindingValue
  , errorValue
  )
where

import Control.Monad (forM)
import Data.Aeson
import Data.Aeson.Decoding.ByteString (bsToTokens)
import Data.Aeson.Decoding.Tokens qualified as Tokens
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Resource.Canonical (canonicalValue)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference
import Nagare.Resource.Types

strictObject :: String -> [Key] -> (Object -> Parser a) -> Value -> Parser a
strictObject label allowed f = withObject label $ \o -> do
  unless (all (`elem` allowed) (KM.keys o)) (fail (label <> ": unknown field"))
  f o

checkedText :: (Text -> Either Text a) -> Value -> Parser a
checkedText f = withText "validated identifier" (either (fail . T.unpack) pure . f)

parseChecked :: Either (NonEmpty InventoryError) a -> Parser a
parseChecked = either (fail . show) pure

options :: Options
options = defaultOptions {rejectUnknownFields = True}

instance ToJSON Name where toJSON = toJSON . nameText

instance FromJSON Name where parseJSON = checkedText mkName

instance ToJSON ContextId where toJSON = toJSON . contextIdText

instance FromJSON ContextId where parseJSON = checkedText mkContextId

instance ToJSON ResourceId where toJSON = toJSON . resourceIdText

instance FromJSON ResourceId where parseJSON = checkedText mkResourceId

instance ToJSON LogicalKey where toJSON = toJSON . logicalKeyText

instance FromJSON LogicalKey where parseJSON = checkedText mkLogicalKey

instance ToJSON ContentDigest where toJSON = toJSON . digestText

instance FromJSON ContentDigest where parseJSON = checkedText mkContentDigest

instance ToJSON PhysicalIdentity where toJSON = toJSON . physicalIdentityText

instance FromJSON PhysicalIdentity where parseJSON = checkedText mkPhysicalIdentity

instance ToJSON ScopeGeneration where toJSON = toJSON . generationNumber

instance FromJSON ScopeGeneration where parseJSON v = parseJSON v >>= either (fail . T.unpack) pure . mkScopeGeneration

instance ToJSON ScopeId where toJSON s = object ["kind" .= scopeKind s, "name" .= scopeName s]

instance FromJSON ScopeId where
  parseJSON = strictObject "scope identity" ["kind", "name"] $ \o -> do
    k <- o .: "kind"
    n <- o .: "name"
    either (fail . T.unpack) pure (mkScopeId k n)

instance ToJSON SecretRef where toJSON r = let (k, v) = secretRefParts r in object ["key" .= k, "version" .= v]

instance FromJSON SecretRef where parseJSON = strictObject "secret reference" ["key", "version"] $ \o -> mkSecretRef <$> o .: "key" <*> o .: "version"

instance ToJSON SomeRef where
  toJSON (SomeRef r) = object ["producer" .= refProducer r, "key" .= refKey r, "capability" .= witnessCapability (refWitness r), "constraints" .= refConstraints r, "sensitivity" .= refSensitivity r]

instance FromJSON SomeRef where
  parseJSON = strictObject "output reference" ["producer", "key", "capability", "constraints", "sensitivity"] $ \o -> do
    p <- o .: "producer"
    k <- o .: "key"
    c <- o .: "capability"
    cs <- o .: "constraints"
    s <- o .: "sensitivity"
    pure $ case witness c of SomeWitness w -> SomeRef (outputRef w p k cs s)

instance ToJSON SomeExport where toJSON (SomeExport r) = toJSON (SomeRef r)

instance FromJSON SomeExport where parseJSON v = do SomeRef r <- parseJSON v; pure (SomeExport r)

witness :: Capability -> SomeWitness
witness DatabaseConnection = SomeWitness DatabaseConnectionW
witness OciImage = SomeWitness OciImageW
witness StorageLocation = SomeWitness StorageLocationW
witness ReadinessCondition = SomeWitness ReadinessConditionW
witness TlsReady = SomeWitness TlsReadyW
witness NixCachePublicKey = SomeWitness NixCachePublicKeyW

scopeValue :: ScopeDeclaration -> Value
scopeValue s = object ["version" .= (1 :: Integer), "scope" .= scopeId s, "bundles" .= normalizeBundles (scopeBundles s)]

-- Bundles and all set-valued fields have no execution order. Canonicalize them.
normalizeBundles :: [ResourceBundle] -> [ResourceBundle]
normalizeBundles =
  sortOn (canonicalValue . toJSON)
    . map
      ( \b ->
          b
            & #declarations
            %~ sortOn declarationId
            . map normalizeDeclaration
            & #exports
            %~ sortOn exportSignature
            & #conditions
            %~ sortOn refSignature
            & #contributions
            %~ sortOn show
            & #operations
            %~ sortOn show
            & #grants
            %~ sortOn show
      )
  where
    normalizeDeclaration (Managed r) = Managed (r & #aliases %~ sortOn show & #dependencies %~ sortOn show & #delegations %~ sortOn show)
    normalizeDeclaration (External r a ds s) = External r a (sortOn show ds) s
    normalizeDeclaration d = d

parseScope :: Value -> Parser ScopeDeclaration
parseScope = strictObject "scope" ["version", "scope", "bundles"] $ \o -> do
  version <- o .: "version" :: Parser Integer
  unless (version == 1) (fail "unsupported inventory schema version")
  s <- o .: "scope"
  bs <- o .: "bundles"
  parseChecked (mkScopeDeclaration s bs)

encodeCanonicalScope :: ScopeDeclaration -> ByteString
encodeCanonicalScope = either (error . T.unpack) id . canonicalValue . scopeValue

decodeScope :: ByteString -> Either (NonEmpty InventoryError) ScopeDeclaration
decodeScope = decodeWith parseScope

decodeWith :: (Value -> Parser a) -> ByteString -> Either (NonEmpty InventoryError) a
decodeWith parser bytes = first (\e -> inventoryError "wire" (T.pack e) :| []) $ do
  _ <- checkTokens (bsToTokens bytes)
  eitherDecodeStrict bytes >>= parseEither parser

-- Aeson intentionally collapses duplicate object keys; inventory intent must
-- refuse that ambiguity before conversion to a KeyMap loses the evidence.
checkTokens :: Tokens.Tokens k String -> Either String k
checkTokens = \case
  Tokens.TkLit _ k -> Right k
  Tokens.TkText _ k -> Right k
  Tokens.TkNumber (Tokens.NumInteger _) k -> Right k
  Tokens.TkNumber _ _ -> Left "resource JSON permits integer tokens only"
  Tokens.TkArrayOpen xs -> checkArray xs
  Tokens.TkRecordOpen fields -> checkRecord Set.empty fields
  Tokens.TkErr e -> Left e
  where
    checkArray (Tokens.TkItem xs) = checkTokens xs >>= checkArray
    checkArray (Tokens.TkArrayEnd k) = Right k
    checkArray (Tokens.TkArrayErr e) = Left e
    checkRecord seen (Tokens.TkPair key xs)
      | Set.member key seen = Left ("duplicate JSON field: " <> show key)
      | otherwise = checkTokens xs >>= checkRecord (Set.insert key seen)
    checkRecord _ (Tokens.TkRecordEnd k) = Right k
    checkRecord _ (Tokens.TkRecordErr e) = Left e

data CandidateInput = CandidateInput !ScopeSnapshot !(NonEmpty ScopeChange) deriving stock (Eq, Show)

bindingValue :: ContextBinding -> Value
bindingValue = toJSON

errorValue :: InventoryError -> Value
errorValue e = object ["code" .= (e ^. #code), "message" .= (e ^. #message), "scopes" .= (e ^. #scopes), "resources" .= (e ^. #resources), "claims" .= map claimParts (e ^. #claims), "sources" .= (e ^. #sources)]

candidateInputValue :: CandidateInput -> Value
candidateInputValue (CandidateInput snapshot changes) =
  object
    [ "version" .= (1 :: Integer)
    , "context" .= snapshotBinding snapshot
    , "base" .= [object ["scope" .= s, "generation" .= g] | (s, (g, _)) <- Map.toAscList (snapshotScopes snapshot)]
    , "snapshot" .= [object ["generation" .= g, "declaration" .= scopeValue s] | (_, (g, s)) <- Map.toAscList (snapshotScopes snapshot)]
    , "reservations" .= [object ["claim" .= claimParts c, "holder" .= h] | (c, h) <- Map.toAscList (snapshotReservations snapshot)]
    , "changes" .= map changeValue (NE.toList (NE.sort changes))
    ]
  where
    changeValue (ReplaceScope s) = object ["replace" .= scopeValue s]
    changeValue (RetireScope s intent) = object ["retire" .= s, "intent" .= intent]
    changeValue (CollectRetained resource) = object ["collect" .= resource]

decodeCandidateInput :: ByteString -> Either (NonEmpty InventoryError) CandidateInput
decodeCandidateInput = decodeWith $ strictObject "candidate" ["version", "context", "base", "snapshot", "reservations", "changes"] $ \o -> do
  version <- o .: "version" :: Parser Integer
  unless (version == 1) (fail "unsupported inventory schema version")
  binding <- o .: "context"
  baseValues <- o .: "base"
  base <- traverse (strictObject "base member" ["scope", "generation"] (\v -> (,) <$> v .: "scope" <*> v .: "generation")) baseValues
  scopeValues <- o .: "snapshot"
  scopes <- forM scopeValues $ strictObject "snapshot member" ["generation", "declaration"] $ \v -> do
    g <- v .: "generation"
    s <- v .: "declaration" >>= parseScope
    pure (scopeId s, (g, s))
  unless (length base == Map.size (Map.fromList base) && length scopes == Map.size (Map.fromList scopes)) (fail "duplicate snapshot or base scope")
  unless (Map.fromList base == fmap fst (Map.fromList scopes)) (fail "snapshot is missing a known scope or disagrees with base generation")
  reservationValues <- o .: "reservations"
  reservations <- forM reservationValues $ strictObject "reservation" ["claim", "holder"] $ \v -> do
    parts <- v .: "claim"
    c <- parseClaim parts
    h <- v .: "holder"
    pure (c, h)
  unless (length reservations == Map.size (Map.fromList reservations)) (fail "duplicate reserved claim")
  snapshot <- parseChecked (mkScopeSnapshot binding (Map.fromList scopes) (Map.fromList reservations))
  changesValues <- o .: "changes"
  changes <- forM changesValues $ \v -> case v of
    Object kv | KM.member "replace" kv -> strictObject "replace" ["replace"] (\r -> ReplaceScope <$> (r .: "replace" >>= parseScope)) v
    Object kv | KM.member "collect" kv -> strictObject "collect" ["collect"] (\r -> CollectRetained <$> r .: "collect") v
    _ -> strictObject "retire" ["retire", "intent"] (\r -> RetireScope <$> r .: "retire" <*> r .: "intent") v
  case changes of [] -> fail "candidate requires at least one explicit scope change"; c : cs -> pure (CandidateInput snapshot (c :| cs))

parseClaim :: [Text] -> Parser CanonicalClaim
parseClaim parts = fmap canonicalClaim $ case parts of
  ["kubernetes", c, g, k, ns, n] -> Kubernetes <$> resource c <*> pure g <*> name k <*> (if ns == "" then pure Nothing else Just <$> name ns) <*> name n
  ["bucket", n] -> GlobalBucket <$> name n
  ["instance", p, z, n] -> CloudInstance <$> name p <*> name z <*> name n
  ["pulumi", n] -> pure (PulumiUrn n)
  ["host", c, n] -> Host <$> resource c <*> name n
  ["artifact", n, d] -> Artifact <$> name n <*> check (mkContentDigest d)
  ["hostname", n] -> Hostname <$> name n
  ["database", r, n] -> DatabaseName <$> resource r <*> name n
  ["route", r, n] -> BackendRoute <$> resource r <*> name n
  ["attic-cache", r, n] -> AtticCache <$> resource r <*> name n
  ["helm", r, namespace, n] -> Helm <$> resource r <*> name namespace <*> name n
  _ -> fail "unsupported canonical claim"
  where
    name = check . mkName
    resource = check . mkResourceId
    check = either (fail . T.unpack) pure

instance ToJSON ScopeKind where toJSON = genericToJSON options

instance FromJSON ScopeKind where parseJSON = genericParseJSON options

instance ToJSON ContextBinding where toJSON = genericToJSON options

instance FromJSON ContextBinding where parseJSON = genericParseJSON options

instance ToJSON ProviderAddress where toJSON = genericToJSON options

instance FromJSON ProviderAddress where
  parseJSON (Object fields) | KM.lookup "tag" fields == Just (String "Kubernetes") = do
    unless (KM.size fields == 2) (fail "Kubernetes address has unknown fields")
    contents <- fields .: "contents" >>= withArray "Kubernetes address" (pure . toList)
    case contents of
      [target, group, kind, namespace, name] -> do
        parsedName <- withText "Kubernetes name" (either (fail . T.unpack) pure . mkKubernetesName) name
        address <-
          Kubernetes
            <$> parseJSON target
            <*> parseJSON group
            <*> parseJSON kind
            <*> parseJSON namespace
            <*> pure parsedName
        either (fail . T.unpack) pure (mkProviderAddress address)
      _ -> fail "Kubernetes address must have five fields"
  parseJSON value = genericParseJSON options value >>= either (fail . T.unpack) pure . mkProviderAddress

instance ToJSON SourceLocation where toJSON = genericToJSON options

instance FromJSON SourceLocation where parseJSON = genericParseJSON options

instance ToJSON Sensitivity where toJSON = genericToJSON options

instance FromJSON Sensitivity where parseJSON = genericParseJSON options

instance ToJSON RecoveryIntent where toJSON (RecoveryIntent method secrets) = toJSON (method, NE.sort secrets)

instance FromJSON RecoveryIntent where parseJSON = genericParseJSON options

instance ToJSON DataPolicy where toJSON = genericToJSON options

instance FromJSON DataPolicy where parseJSON = genericParseJSON options

instance ToJSON LifecyclePolicy where toJSON = genericToJSON options

instance FromJSON LifecyclePolicy where parseJSON = genericParseJSON options

instance ToJSON RetirementIntent where toJSON = genericToJSON options

instance FromJSON RetirementIntent where parseJSON = genericParseJSON options

instance ToJSON DelegatedOperation where toJSON = genericToJSON options

instance FromJSON DelegatedOperation where parseJSON = genericParseJSON options

instance ToJSON Delegation where toJSON = genericToJSON options . (\d -> d & #fields %~ NE.sort & #operations %~ NE.sort)

instance FromJSON Delegation where parseJSON = genericParseJSON options

instance ToJSON RecoveryClass where toJSON = genericToJSON options

instance FromJSON RecoveryClass where parseJSON = genericParseJSON options

instance ToJSON Capability where toJSON = genericToJSON options

instance FromJSON Capability where parseJSON = genericParseJSON options

instance ToJSON OutputConstraint where toJSON = genericToJSON options

instance FromJSON OutputConstraint where parseJSON = genericParseJSON options

instance ToJSON Dependency where toJSON = genericToJSON options

instance FromJSON Dependency where parseJSON = genericParseJSON options

instance ToJSON Executor where toJSON = genericToJSON options

instance FromJSON Executor where parseJSON = genericParseJSON options

instance ToJSON DesiredSpec where
  toJSON =
    genericToJSON options . \case
      StatefulSet count templates digest -> StatefulSet count (sortOn nameText templates) digest
      HelmRelease objects digest -> HelmRelease (NE.sort objects) digest
      BackendMapSpec entries -> BackendMapSpec (sortOn (nameText . first3) entries)
      other -> other
    where first3 (name, _, _) = name

instance FromJSON DesiredSpec where parseJSON = genericParseJSON options

instance ToJSON ManagedResource where toJSON = genericToJSON options

instance FromJSON ManagedResource where parseJSON = genericParseJSON options

instance ToJSON Declaration where toJSON = genericToJSON options

instance FromJSON Declaration where parseJSON = genericParseJSON options

instance ToJSON OperationInput where toJSON = genericToJSON options

instance FromJSON OperationInput where parseJSON = genericParseJSON options

instance ToJSON OperationKind where toJSON = genericToJSON options

instance FromJSON OperationKind where parseJSON = genericParseJSON options

instance ToJSON DeclaredOperation where toJSON = genericToJSON options . (\operation -> operation & #affects %~ NE.sort & #inputs %~ sortOn show)

instance FromJSON DeclaredOperation where parseJSON = genericParseJSON options

instance ToJSON BackendRole where
  toJSON ProtectedBackend = String "protected"
  toJSON PortalBackend = String "portal"

instance FromJSON BackendRole where
  parseJSON = withText "backend role" $ \case
    "protected" -> pure ProtectedBackend
    "portal" -> pure PortalBackend
    _ -> fail "unknown backend role"

-- Preserve the v1 namespace contribution representation in accepted scopes.
instance ToJSON Contribution where
  toJSON (RegisterNamespace owner cluster namespace key) = object
    ["owner" .= owner, "cluster" .= cluster, "namespace" .= namespace, "key" .= key]
  toJSON (RegisterBackend owner cluster host upstream role key) = object
    ["tag" .= ("RegisterBackend" :: Text), "owner" .= owner, "cluster" .= cluster
    , "host" .= host, "upstream" .= upstream, "role" .= role, "key" .= key]

instance FromJSON Contribution where
  parseJSON = withObject "contribution" $ \value -> case KM.lookup "tag" value of
    Nothing -> do
      unless (all (`elem` ["owner", "cluster", "namespace", "key"]) (KM.keys value))
        (fail "namespace contribution has unknown field")
      RegisterNamespace <$> value .: "owner" <*> value .: "cluster"
        <*> value .: "namespace" <*> value .: "key"
    Just (String "RegisterBackend") -> do
      unless (all (`elem` ["tag", "owner", "cluster", "host", "upstream", "role", "key"]) (KM.keys value))
        (fail "backend contribution has unknown field")
      RegisterBackend <$> value .: "owner" <*> value .: "cluster" <*> value .: "host"
        <*> value .: "upstream" <*> value .: "role" <*> value .: "key"
    _ -> fail "unknown contribution kind"

instance ToJSON ContributionGrant where
  toJSON (NamespaceGrant scope cluster) = toJSON (scope, cluster)
  toJSON (BackendMapGrant cluster) = object
    ["tag" .= ("BackendMapGrant" :: Text), "cluster" .= cluster]
  toJSON (ShomeiSettingsGrant cluster baseDomain) = object
    ["tag" .= ("ShomeiSettingsGrant" :: Text), "cluster" .= cluster, "baseDomain" .= baseDomain]

instance FromJSON ContributionGrant where
  parseJSON value@(Array _) = do
    (scope, cluster) <- parseJSON value
    pure (NamespaceGrant scope cluster)
  parseJSON value = withObject "contribution grant" (\fields -> do
    tag <- fields .: "tag"
    case (tag :: Text) of
      "BackendMapGrant" -> do
        unless (all (`elem` ["tag", "cluster"]) (KM.keys fields)) (fail "backend grant has unknown field")
        BackendMapGrant <$> fields .: "cluster"
      "ShomeiSettingsGrant" -> do
        unless (all (`elem` ["tag", "cluster", "baseDomain"]) (KM.keys fields)) (fail "Shomei grant has unknown field")
        ShomeiSettingsGrant <$> fields .: "cluster" <*> fields .: "baseDomain"
      _ -> fail "unknown contribution grant") value

instance ToJSON ResourceBundle where toJSON = genericToJSON options

instance FromJSON ResourceBundle where parseJSON = genericParseJSON options

instance ToJSON ReservationReason where toJSON = genericToJSON options

instance FromJSON ReservationReason where parseJSON = genericParseJSON options

instance ToJSON ClaimHolder where toJSON = genericToJSON options

instance FromJSON ClaimHolder where parseJSON = genericParseJSON options
