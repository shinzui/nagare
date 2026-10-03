-- | Exact original cloud declarations survive scope retirement and collection.
module Nagare.Cli.Inventory.CloudHistory
  ( CloudHistory (..)
  , requireCloudCollectionProtocol
  , loadCloudHistory
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Cloud (registrationPulumiUrn, registrationsFromDeclarations)
import Nagare.Inventory.CloudCollection (cloudCollectionTypes)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store
import Nagare.Platform.Workspace (PlatformWorkspace)
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Resource.Wire (decodeScope, encodeCanonicalScope)
import System.FilePath ((</>))

data CloudHistory = CloudHistory
  { cloudHistoricalScopes :: ![ScopeDeclaration]
  , cloudHistoricalMembers :: !(Map ResourceId ManagedResource)
  , cloudOmittedUrns :: ![Text]
  , cloudCollectingPhysical :: !(Map Text PhysicalIdentity)
  -- ^ Retained physical identity of each URN being collected, from history.
  }

-- References come from the admitted original review or retained/tombstoned
-- history. Each member is checked against its own original immutable revision.
loadCloudHistory ::
  InventoryStore ->
  HeadManifest ->
  [ScopeDeclaration] ->
  Map ResourceId (ScopeId, ScopeRevision) ->
  Set.Set ResourceId ->
  IO CloudHistory
loadCloudHistory store headValue cached requested collecting = do
  let cloudOwner owner = scopeKind owner == Platform && nameText (scopeName owner) == "cloud"
      retained = Map.map (\value -> (retainedOwner value, retainedRevision value)) (headRetained headValue)
      collected = Map.map (\value -> (tombstoneOwner value, tombstoneRevision value)) (headCollected headValue)
      references = Map.filter (cloudOwner . fst) (Map.unions [requested, retained, collected])
      revisions = Set.toAscList (Set.fromList (Map.elems references))
  original <- forM revisions $ \key@(owner, revision) -> do
    let digest = revisionDigest revision
        matches =
          [ scope
          | scope <- cached
          , scopeId scope == owner
          , let bytes = encodeCanonicalScope scope
          , contentDigest bytes == digest
          ]
    scope <- case matches of
      value : _ -> pure value
      [] -> do
        bytes <-
          readObject store (scopeKey digest)
            >>= either (dieT . T.pack . show) pure
            >>= maybe (dieT "historical cloud scope bytes are missing") pure
        unless (contentDigest bytes == digest) (dieT "historical cloud scope digest mismatch")
        either (dieT . T.pack . show) pure (decodeScope bytes)
    unless (scopeId scope == owner) (dieT "historical cloud owner mismatch")
    pure (key, scope)
  let scopes = Map.fromList original
  members <- forM (Map.toAscList references) $ \(resourceId, key) -> do
    scope <- maybe (dieT "historical cloud revision missing") pure (Map.lookup key scopes)
    member <- case [ member
                   | bundle <- scopeBundles scope
                   , Managed member <- declarations bundle
                   , member ^. #identity == resourceId
                   , member ^. #owner == scopeId scope
                   , member ^. #executor == PulumiExecutor
                   ] of
      [one] -> pure one
      _ -> dieT "historical cloud member is absent, ambiguous or belongs to another executor"
    pure (resourceId, member)
  let byResource = Map.fromList members
      omitted = Set.union collecting (Map.keysSet (Map.filter (cloudOwner . fst) collected))
      urnFor resource = do
        member <- maybe (dieT "collected cloud member lacks original declaration") pure (Map.lookup resource byResource)
        case registrationsFromDeclarations [Managed member] of
          Right [registration] -> pure (registrationPulumiUrn registration)
          _ -> dieT "collected cloud member lacks exact native registration"
  urns <- forM (Set.toAscList omitted) urnFor
  physical <- forM (Set.toAscList collecting) $ \resource -> do
    urn <- urnFor resource
    identity <- case (Map.lookup resource (headRetained headValue), Map.lookup resource (headCollected headValue)) of
      (Just retainedValue, _) -> pure (retainedPhysical retainedValue)
      (Nothing, Just tombstone) -> pure (tombstonePhysical tombstone)
      (Nothing, Nothing) -> dieT "collected cloud member lacks its retained physical identity"
    pure (urn, identity)
  pure (CloudHistory (Map.elems scopes) byResource urns (Map.fromList physical))

requireCloudCollectionProtocol :: PlatformWorkspace -> IO ()
requireCloudCollectionProtocol workspace = do
  captured <- try (BS.readFile (workspace ^. #pulumiDir </> "resource-collection-protocol.json"))
  bytes <- case captured of
    Left (_ :: IOException) -> dieT "selected immutable payload does not support reviewed cloud collection"
    Right value -> pure value
  let parsed = do
        value <- eitherDecodeStrict' bytes
        parseEither
          ( withObject
              "cloud collection protocol"
              ( \fields ->
                  (,,)
                    <$> fields .: "version"
                    <*> fields .: "declarationVersion"
                    <*> fields .: "types"
              )
          )
          value
  (version, declarationVersion, kinds) <- either (dieT . T.pack) pure parsed
  unless
    ( version == (1 :: Int)
        && declarationVersion == (2 :: Int)
        && Set.fromList (kinds :: [Text]) == Set.fromList cloudCollectionTypes
    )
    (dieT "selected payload cloud collection protocol differs from the operator")
