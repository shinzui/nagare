-- | Typed cloud declarations and the Haskell/TypeScript registration contract.
--
-- Provider constructors remain in TypeScript.  This module owns the common
-- resource identities and checks the native registrations reported by that
-- program before a Pulumi plan can become reviewable.
module Nagare.Inventory.Cloud
  ( CloudAddress (..)
  , CloudResource (..)
  , CloudDeclarationBundle (..)
  , NativeRegistration (..)
  , RegistrationClass (..)
  , RegistrationParityError (..)
  , compileCloudScope
  , expectedRegistrations
  , registrationsFromDeclarations
  , encodeRegistrationBundle
  , validateNativeRegistrationParity
  , encodeCloudDeclarationBundle
  , decodeCloudDeclarationBundle
  )
where

import Data.Generics.Labels ()

import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.Foldable (asum, traverse_)
import Data.List (nub, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference
import Nagare.Resource.Types
import Nagare.Resource.Wire

data CloudAddress
  = BucketAddress !Name
  | InstanceAddress !Name !Name !Name
  | PulumiAddress !Text
  deriving stock (Eq, Ord, Show, Generic)

data RegistrationClass
  = ManagedRegistration
  | NativeBookkeeping !Text
  deriving stock (Eq, Ord, Show, Generic)

data NativeRegistration = NativeRegistration
  { registrationResource :: !ResourceId
  , registrationPulumiType :: !Text
  , registrationPulumiName :: !Name
  , registrationPulumiUrn :: !Text
  , registrationSpecDigest :: !ContentDigest
  , registrationClass :: !RegistrationClass
  }
  deriving stock (Eq, Ord, Show, Generic)

data CloudResource = CloudResource
  { cloudLogicalKey :: !LogicalKey
  , cloudRole :: !Name
  , cloudAddress :: !CloudAddress
  , cloudAliases :: ![ProviderAddress]
  , cloudSpecDigest :: !ContentDigest
  , cloudLifecycle :: !LifecyclePolicy
  , cloudDataPolicy :: !DataPolicy
  , cloudSensitivity :: !Sensitivity
  , cloudDependencies :: ![Dependency]
  , cloudSource :: !SourceLocation
  , cloudNativeType :: !Text
  , cloudNativeName :: !Name
  , cloudNativeUrn :: !Text
  , cloudRegistrationClass :: !RegistrationClass
  }
  deriving stock (Eq, Ord, Show, Generic)

data CloudDeclarationBundle = CloudDeclarationBundle
  { cloudBundleVersion :: !Int
  , cloudContext :: !ContextId
  , cloudProject :: !Name
  , cloudStack :: !Name
  , cloudScope :: !ScopeId
  , cloudResources :: ![CloudResource]
  }
  deriving stock (Eq, Show, Generic)

data RegistrationParityError
  = DuplicateDeclaredRegistration !ResourceId
  | DuplicateNativeRegistration !ResourceId
  | MissingNativeRegistration !NativeRegistration
  | UnexpectedNativeRegistration !NativeRegistration
  | NativeRegistrationMismatch !NativeRegistration !NativeRegistration
  deriving stock (Eq, Show, Generic)

compileCloudScope :: CloudDeclarationBundle -> Either (NonEmpty InventoryError) ScopeDeclaration
compileCloudScope bundle
  | cloudBundleVersion bundle /= 1 = Left (inventoryError "cloud-wire-version" "unsupported cloud declaration bundle version" :| [])
  | otherwise = mkScopeDeclaration (cloudScope bundle) [resourceBundle]
  where
    resourceBundle =
      ResourceBundle
        { declarations = map (Managed . managedResource) (cloudResources bundle)
        , exports = []
        , conditions = []
        , contributions = []
        , operations = []
        , grants = []
        }
    managedResource resource =
      ManagedResource
        { identity = resourceIdentity resource
        , owner = cloudScope bundle
        , executor = PulumiExecutor
        , address = providerAddress (cloudAddress resource)
        , aliases = nativeAlias resource : cloudAliases resource
        , spec = NativeObject (cloudSpecDigest resource)
        , lifecycle = cloudLifecycle resource
        , dataPolicy = cloudDataPolicy resource
        , sensitivity = cloudSensitivity resource
        , dependencies = cloudDependencies resource
        , delegations = []
        , source = cloudSource resource
        }
    resourceIdentity resource = mintResourceId (cloudScope bundle) (cloudLogicalKey resource) (cloudRole resource)
    nativeAlias = PulumiUrn . cloudNativeUrn

providerAddress :: CloudAddress -> ProviderAddress
providerAddress (BucketAddress name) = GlobalBucket name
providerAddress (InstanceAddress project zone name) = CloudInstance project zone name
providerAddress (PulumiAddress urn) = PulumiUrn urn

expectedRegistrations :: CloudDeclarationBundle -> [NativeRegistration]
expectedRegistrations bundle =
  sortOn
    registrationResource
    [ NativeRegistration
        { registrationResource = mintResourceId (cloudScope bundle) (cloudLogicalKey resource) (cloudRole resource)
        , registrationPulumiType = cloudNativeType resource
        , registrationPulumiName = cloudNativeName resource
        , registrationPulumiUrn = cloudNativeUrn resource
        , registrationSpecDigest = cloudSpecDigest resource
        , registrationClass = cloudRegistrationClass resource
        }
    | resource <- cloudResources bundle
    ]

-- | Recover the TypeScript registration mapping from compiled Pulumi-managed
-- declarations. The common scope remains authoritative for identity/policy;
-- the Pulumi URN alias supplies only the provider type and logical name.
registrationsFromDeclarations :: [Declaration] -> Either Text [NativeRegistration]
registrationsFromDeclarations declarations =
  sortOn registrationResource <$> traverse registration pulumiResources
  where
    pulumiResources = [resource | Managed resource <- declarations, resource ^. #executor == PulumiExecutor]
    registration resource = do
      urn <- case nub [value | PulumiUrn value <- resource ^. #address : resource ^. #aliases] of
        [value] -> Right value
        [] -> Left (resourceError resource "has no Pulumi URN address or alias")
        _ -> Left (resourceError resource "has more than one Pulumi URN address or alias")
      (nativeType, nativeName) <- parseUrn resource urn
      specDigest <- case resource ^. #spec of
        NativeObject digest -> Right digest
        _ -> Left (resourceError resource "does not use a native-object specification")
      pure
        NativeRegistration
          { registrationResource = resource ^. #identity
          , registrationPulumiType = nativeType
          , registrationPulumiName = nativeName
          , registrationPulumiUrn = urn
          , registrationSpecDigest = specDigest
          , registrationClass = ManagedRegistration
          }
    parseUrn resource urn = case reverse (T.splitOn "::" urn) of
      nameToken : qualifiedTypeToken : _ | "urn:pulumi:" `T.isPrefixOf` urn -> do
        nativeName <- first (const (resourceError resource "has an invalid Pulumi logical name")) (mkName nameToken)
        let typeToken = last (T.splitOn "$" qualifiedTypeToken)
        unless (not (T.null typeToken) && not (T.any (< ' ') typeToken)) (Left (resourceError resource "has an invalid Pulumi type token"))
        pure (typeToken, nativeName)
      _ -> Left (resourceError resource "has an invalid Pulumi URN")
    resourceError resource message = resourceIdText (resource ^. #identity) <> " " <> message

-- | Runtime wire document consumed by the Pulumi stack transformation. The
-- resource declarations have already been validated by composition; this
-- projection contains only the native mapping needed during registration.
encodeRegistrationBundle :: ContextId -> Name -> Name -> [ScopeId] -> [NativeRegistration] -> ByteString
encodeRegistrationBundle context project stack scopes registrations =
  either (error . T.unpack) id $
    canonicalValue $
      object
        [ "version" .= (1 :: Int)
        , "context" .= context
        , "project" .= project
        , "stack" .= stack
        , "scope" .= scopes
        , "resources" .= ([] :: [Value])
        , "registrations" .= registrations
        , "bundleDigest" .= contentDigest (either (error . T.unpack) id (canonicalValue (toJSON registrations)))
        ]

validateNativeRegistrationParity :: [NativeRegistration] -> [NativeRegistration] -> Either (NonEmpty RegistrationParityError) ()
validateNativeRegistrationParity declared native =
  case duplicateErrors <> comparisonErrors of
    [] -> Right ()
    err : rest -> Left (err :| rest)
  where
    declaredMap = Map.fromList [(registrationResource registration, registration) | registration <- declared]
    nativeMap = Map.fromList [(registrationResource registration, registration) | registration <- native]
    duplicateErrors =
      map DuplicateDeclaredRegistration (duplicates (map registrationResource declared))
        <> map DuplicateNativeRegistration (duplicates (map registrationResource native))
    comparisonErrors = concatMap compareOne (Map.keys (declaredMap <> nativeMap))
    compareOne resource = case (Map.lookup resource declaredMap, Map.lookup resource nativeMap) of
      (Just expected, Nothing) -> [MissingNativeRegistration expected]
      (Nothing, Just actual) -> [UnexpectedNativeRegistration actual]
      (Just expected, Just actual) | expected /= actual -> [NativeRegistrationMismatch expected actual]
      _ -> []

duplicates :: (Ord a) => [a] -> [a]
duplicates values = Map.keys (Map.filter (> (1 :: Int)) (Map.fromListWith (+) [(value, 1) | value <- values]))

encodeCloudDeclarationBundle :: CloudDeclarationBundle -> ByteString
encodeCloudDeclarationBundle = either (error . T.unpack) id . canonicalValue . toJSON

decodeCloudDeclarationBundle :: ByteString -> Either Text CloudDeclarationBundle
decodeCloudDeclarationBundle bytes = do
  bundle <- first T.pack (eitherDecodeStrict bytes)
  unless (cloudBundleVersion bundle == 1) (Left "unsupported cloud declaration bundle version")
  _ <- first (T.pack . show) (compileCloudScope bundle)
  first (T.pack . show) (validateNativeRegistrationParity (expectedRegistrations bundle) (expectedRegistrations bundle))
  pure bundle

instance ToJSON RegistrationClass where
  toJSON ManagedRegistration = String "managed"
  toJSON (NativeBookkeeping reason) = object ["bookkeeping" .= reason]

instance FromJSON RegistrationClass where
  parseJSON (String "managed") = pure ManagedRegistration
  parseJSON value = withObject "registration class" (\o -> NativeBookkeeping <$> o .: "bookkeeping") value

instance ToJSON NativeRegistration where
  toJSON registration =
    object
      [ "resourceId" .= registrationResource registration
      , "pulumiType" .= registrationPulumiType registration
      , "pulumiName" .= registrationPulumiName registration
      , "pulumiUrn" .= registrationPulumiUrn registration
      , "specDigest" .= registrationSpecDigest registration
      , "class" .= registrationClass registration
      ]

instance FromJSON NativeRegistration where
  parseJSON = withObject "native registration" $ \o ->
    NativeRegistration
      <$> o .: "resourceId"
      <*> o .: "pulumiType"
      <*> o .: "pulumiName"
      <*> o .: "pulumiUrn"
      <*> o .: "specDigest"
      <*> o .: "class"

instance ToJSON CloudAddress where
  toJSON (BucketAddress name) = object ["bucket" .= name]
  toJSON (InstanceAddress project zone name) = object ["instance" .= object ["project" .= project, "zone" .= zone, "name" .= name]]
  toJSON (PulumiAddress urn) = object ["pulumiUrn" .= urn]

instance FromJSON CloudAddress where
  parseJSON = withObject "cloud address" $ \o ->
    asum
      [ BucketAddress <$> o .: "bucket"
      , o .: "instance" >>= withObject "cloud instance" (\i -> InstanceAddress <$> i .: "project" <*> i .: "zone" <*> i .: "name")
      , PulumiAddress <$> o .: "pulumiUrn"
      ]

instance ToJSON CloudResource where
  toJSON resource =
    object
      [ "logicalKey" .= cloudLogicalKey resource
      , "role" .= cloudRole resource
      , "address" .= cloudAddress resource
      , "aliases" .= cloudAliases resource
      , "specDigest" .= cloudSpecDigest resource
      , "lifecycle" .= cloudLifecycle resource
      , "dataPolicy" .= cloudDataPolicy resource
      , "sensitivity" .= cloudSensitivity resource
      , "dependencies" .= cloudDependencies resource
      , "source" .= cloudSource resource
      , "pulumiType" .= cloudNativeType resource
      , "pulumiName" .= cloudNativeName resource
      , "pulumiUrn" .= cloudNativeUrn resource
      , "class" .= cloudRegistrationClass resource
      ]

instance FromJSON CloudResource where
  parseJSON = withObject "cloud resource" $ \o ->
    CloudResource
      <$> o .: "logicalKey"
      <*> o .: "role"
      <*> o .: "address"
      <*> o .:? "aliases" .!= []
      <*> o .: "specDigest"
      <*> o .: "lifecycle"
      <*> o .: "dataPolicy"
      <*> o .: "sensitivity"
      <*> o .:? "dependencies" .!= []
      <*> o .: "source"
      <*> o .: "pulumiType"
      <*> o .: "pulumiName"
      <*> o .: "pulumiUrn"
      <*> o .: "class"

instance ToJSON CloudDeclarationBundle where
  toJSON bundle =
    object
      [ "version" .= cloudBundleVersion bundle
      , "context" .= cloudContext bundle
      , "project" .= cloudProject bundle
      , "stack" .= cloudStack bundle
      , "scope" .= cloudScope bundle
      , "resources" .= cloudResources bundle
      , "registrations" .= expectedRegistrations bundle
      , "bundleDigest" .= contentDigest (either (error . T.unpack) id (canonicalValue (toJSON (expectedRegistrations bundle))))
      ]

instance FromJSON CloudDeclarationBundle where
  parseJSON = withObject "cloud declaration bundle" $ \o -> do
    version <- o .: "version"
    context <- o .: "context"
    project <- o .: "project"
    stack <- o .: "stack"
    scope <- o .: "scope"
    resources <- o .: "resources"
    supplied <- o .: "registrations"
    suppliedDigest <- o .: "bundleDigest"
    let bundle = CloudDeclarationBundle version context project stack scope resources
        expected = expectedRegistrations bundle
        expectedDigest = contentDigest (either (error . T.unpack) id (canonicalValue (toJSON expected)))
    unless (supplied == expected) (fail "native registrations disagree with cloud resources")
    unless (suppliedDigest == expectedDigest) (fail "native registration digest mismatch")
    validateUrns expected
    pure bundle

validateUrns :: [NativeRegistration] -> Parser ()
validateUrns = traverse_ $ \registration -> do
  let urn = registrationPulumiUrn registration
      expectedType = registrationPulumiType registration
      expectedName = nameText (registrationPulumiName registration)
  unless ("urn:pulumi:" `T.isPrefixOf` urn) (fail "native registration has an invalid Pulumi URN")
  case reverse (T.splitOn "::" urn) of
    actualName : actualType : _
      | actualName == expectedName && actualType == expectedType -> pure ()
      | otherwise -> fail "native registration type/name disagrees with its Pulumi URN"
    _ -> fail "native registration has an invalid Pulumi URN"
