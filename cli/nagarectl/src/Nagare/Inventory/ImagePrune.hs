-- | One-shot pruning of exact cached CRI images on an accepted platform VM.
-- Published registry/image artifacts are outside this derived-cache operation.
module Nagare.Inventory.ImagePrune
  ( CachedImage (..)
  , ImageCacheSnapshot (..)
  , ImagePruneBinding (..)
  , ImagePrunePlan (..)
  , ImagePruneOps (..)
  , compileImagePrune
  , imagePruneRequestTargets
  , imagePruneBindings
  , imagePruneReceiptKey
  , validateImageCache
  , unusedCacheImages
  )
where

import Data.Aeson
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Cloud (NativeRegistration (..), registrationsFromDeclarations)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (OperationId)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (RecoveryClass (OperatorRecovery))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data CachedImage = CachedImage
  { imageId :: !Text
  , imageAliases :: ![Text]
  , imagePinned :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ImageCacheSnapshot = ImageCacheSnapshot
  { cacheInstanceId :: !Text
  , cacheImages :: ![CachedImage]
  , cacheUsedIds :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ImagePruneBinding = ImagePruneBinding !ResourceId !ProviderAddress !Text
  deriving stock (Eq, Show)

data ImagePrunePlan = ImagePrunePlan
  { pruneVersion :: !Int
  , pruneOperation :: !OperationId
  , pruneInputDigest :: !ContentDigest
  , pruneInstanceId :: !Text
  , pruneImageId :: !Text
  , pruneAliases :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ImagePruneOps = ImagePruneOps
  { imagePruneObserve :: !(ProviderAddress -> IO (Either Text ImageCacheSnapshot))
  , imagePruneRemove :: !(ProviderAddress -> ImagePrunePlan -> IO (Either Text ()))
  , imagePruneReadReceipt :: !(ContentDigest -> IO (Either Text (Maybe ByteString)))
  , imagePruneWriteReceipt :: !(ContentDigest -> ByteString -> IO (Either Text ()))
  }

imagePruneReceiptKey :: ContentDigest -> FilePath
imagePruneReceiptKey digest = "image-prune/" <> T.unpack (digestText digest) <> ".json"

validateImageCache :: ImageCacheSnapshot -> Either Text ()
validateImageCache snapshot = do
  unless
    (not (T.null (cacheInstanceId snapshot)) && T.all (`elem` ("0123456789" :: String)) (cacheInstanceId snapshot))
    (Left "image cache requires an exact numeric Compute instance ID")
  let ids = map imageId (cacheImages snapshot)
  unless
    (length ids == Set.size (Set.fromList ids) && all validImageId (ids <> cacheUsedIds snapshot))
    (Left "image cache contains duplicate or invalid full image IDs")
  unless
    (all (\image -> imageAliases image == Set.toAscList (Set.fromList (imageAliases image)) && all (not . T.null) (imageAliases image)) (cacheImages snapshot))
    (Left "image cache aliases must be nonempty, sorted and distinct")
  let aliases = concatMap imageAliases (cacheImages snapshot)
  unless
    (length aliases == Set.size (Set.fromList aliases))
    (Left "image cache aliases ambiguously identify multiple image IDs")

unusedCacheImages :: ImageCacheSnapshot -> Either Text [Text]
unusedCacheImages snapshot = do
  validateImageCache snapshot
  let protected image = imagePinned image || imageId image `elem` cacheUsedIds snapshot
      protectedAliases = Set.fromList [alias | image <- cacheImages snapshot, protected image, alias <- imageAliases image]
  pure
    [ imageId image
    | image <- cacheImages snapshot
    , not (protected image)
    , Set.null (Set.intersection protectedAliases (Set.fromList (imageAliases image)))
    ]

validImageId :: Text -> Bool
validImageId value = case T.stripPrefix "sha256:" value of
  Just digest -> T.length digest == 64 && T.all (`elem` ("0123456789abcdef" :: String)) digest
  Nothing -> False

acceptedVm :: ScopeSnapshot -> ProviderAddress -> Either Text (ScopeDeclaration, ManagedResource)
acceptedVm snapshot address = case [ (scope, resource)
                                   | (_, scope) <- Map.elems (snapshotScopes snapshot)
                                   , scopeKind (scopeId scope) == Platform
                                   , bundle <- scopeBundles scope
                                   , Managed resource <- declarations bundle
                                   , matchesVm address resource
                                   ] of
  [one] -> Right one
  _ -> Left "image pruning requires one accepted platform-owned Compute instance"

matchesVm :: ProviderAddress -> ManagedResource -> Bool
matchesVm target resource = case (target, registrationsFromDeclarations [Managed resource]) of
  (CloudInstance _ _ name, Right [registration]) ->
    resource ^. #executor == PulumiExecutor
      && registrationPulumiType registration == "gcp:compute/instance:Instance"
      && registrationPulumiName registration == name
  _ -> False

imagePruneRequestTargets :: ScopeSnapshot -> ProviderAddress -> Text -> Either Text (Maybe [Text])
imagePruneRequestTargets snapshot address requestId = do
  _ <- mkName requestId
  (scope, _) <- acceptedVm snapshot address
  bindings <- imagePruneBindings address [scope]
  let prefix = scopeIdText (scopeId scope) <> "/image-prune-" <> requestId <> "/"
      intents =
        [ intent
        | bundle <- scopeBundles scope
        , intent <- operations bundle
        , prefix `T.isPrefixOf` resourceIdText (intent ^. #identity)
        ]
  targets <-
    traverse
      ( \intent -> do
          digest <- contentDigest <$> canonicalValue (toJSON intent)
          case Map.lookup digest bindings of
            Just (ImagePruneBinding _ _ image) -> Right image
            Nothing -> Left "image cleanup request ID is occupied by another operation"
      )
      intents
  pure (if null targets then Nothing else Just (Set.toAscList (Set.fromList targets)))

compileImagePrune :: ScopeSnapshot -> ProviderAddress -> Text -> [Text] -> Either Text ScopeDeclaration
compileImagePrune snapshot address requestId images = do
  _ <- mkName requestId
  unless
    (not (null images) && all validImageId images && length images == Set.size (Set.fromList images))
    (Left "image cleanup requires distinct full sha256 image IDs")
  (scope, resource) <- acceptedVm snapshot address
  prior <- imagePruneRequestTargets snapshot address requestId
  case prior of
    Just selected | selected /= Set.toAscList (Set.fromList images) -> Left "image cleanup request ID already binds a different image set"
    Just _ -> Right scope
    Nothing -> do
      key <- mkLogicalKey ("image-prune-" <> requestId)
      target <- contentDigest <$> canonicalValue (toJSON address)
      intents <-
        traverse
          ( \image -> do
              role <- mkName (T.drop 7 image)
              pure
                ( DeclaredOperation
                    (mintResourceId (scopeId scope) key role)
                    ((resource ^. #identity) NE.:| [])
                    [ContentInput target, HostImageInput image]
                    OperatorRecovery
                    PruneHostImage
                )
          )
          images
      case scopeBundles scope of
        firstBundle : rest -> do
          revised <-
            first
              (T.pack . show)
              ( mkScopeDeclaration
                  (scopeId scope)
                  (firstBundle {operations = operations firstBundle <> intents} : rest)
              )
          pure (withScopeOverrides (scopeOverrides scope) (maybe revised (`withScopeConfigDigest` revised) (scopeConfigDigest scope)))
        [] -> Left "accepted VM scope is empty"

imagePruneBindings :: ProviderAddress -> [ScopeDeclaration] -> Either Text (Map.Map ContentDigest ImagePruneBinding)
imagePruneBindings address scopes = Map.fromList <$> traverse bind intents
  where
    members = Map.fromList [(resource ^. #identity, resource) | scope <- scopes, bundle <- scopeBundles scope, Managed resource <- declarations bundle]
    intents = [(scopeId scope, intent) | scope <- scopes, bundle <- scopeBundles scope, intent <- operations bundle, operationKind intent == PruneHostImage]
    bind (owner, intent) = do
      resourceId <- case NE.toList (intent ^. #affects) of
        [single] -> Right single
        _ -> Left "image prune must affect exactly one accepted VM"
      resource <- maybe (Left "image prune VM is absent") Right (Map.lookup resourceId members)
      expected <- contentDigest <$> canonicalValue (toJSON address)
      image <- case intent ^. #inputs of
        [ContentInput target, HostImageInput image] | target == expected && validImageId image -> Right image
        _ -> Left "image prune inputs differ from the exact VM and image ID"
      unless
        (resource ^. #owner == owner && scopeKind owner == Platform && matchesVm address resource && intent ^. #recovery == OperatorRecovery)
        (Left "image prune ownership or recovery differs")
      digest <- contentDigest <$> canonicalValue (toJSON intent)
      pure (digest, ImagePruneBinding resourceId address image)
