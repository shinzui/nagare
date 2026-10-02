-- | Bootstrap / Image. Executable-private CLI boundary.
module Nagare.Cli.Bootstrap.Image
  ( buildImageBuildStageCandidate
  , buildImagePublicationStageCandidate
  )
where

import Control.Exception (IOException, try)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as AesonMap
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Dsl.Prelude
import Nagare.Host.Config (hostConfigDir)
import Nagare.Inventory.Artifact
  ( ArtifactDeclarationBundle (ArtifactDeclarationBundle)
  , ArtifactResourceSpec
    ( ArtifactResourceSpec
    , artifactConsumers
    , artifactContentDigest
    , artifactDataPolicy
    , artifactDependencies
    , artifactDestination
    , artifactKind
    , artifactLifecycle
    , artifactLogicalKey
    , artifactName
    , artifactOwnership
    , artifactPublishOperation
    , artifactRole
    , artifactSensitivity
    , artifactSource
    , artifactSpecDigest
    )
  )
import Nagare.Inventory.Artifact qualified as InventoryArtifact
import Nagare.Inventory.Digest qualified as InventoryDigest
import Nagare.Platform.Workspace (PlatformWorkspace)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Policy qualified as ResourcePolicy
import Nagare.Resource.Reference qualified as ResourceReference
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (ActiveTarget, Mode (Cloud), contextNameText)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.Process
  ( CreateProcess (cwd, env)
  , proc
  , readCreateProcessWithExitCode
  )

-- The image output path is derivation-addressed and can be evaluated before a
-- build. Its build is a separate reviewed artifact effect. A subsequent review
-- can bind the resulting tarball digest to GCE image publication.
buildImageBuildStageCandidate ::
  ActiveTarget ->
  PlatformWorkspace ->
  ResourceInventory.ScopeSnapshot ->
  IO (Maybe ResourceInventory.CompositionCandidate)
buildImageBuildStageCandidate active workspace snapshot
  | active ^. #profile . #mode /= Cloud = pure Nothing
  | otherwise = do
      hostRoot <- hostConfigDir (active ^. #contextName)
      evaluated <-
        try
          ( readCreateProcessWithExitCode
              ( (proc "nix" ["eval", "--raw", ".#packages.x86_64-linux.nagare-image"])
                  { cwd = Just hostRoot
                  }
              )
              ""
          )
          >>= \case
            Left (err :: IOException) -> dieT ("could not evaluate reviewed host image: " <> T.pack (show err))
            Right (ExitFailure code, _, err) ->
              dieT
                ("host image evaluation failed (exit " <> T.pack (show code) <> "): " <> T.pack err)
            Right (ExitSuccess, out, _) -> pure (T.strip (T.pack out))
      unless
        (T.isPrefixOf "/" evaluated && not (T.any (`elem` ['\n', '\r', '\t']) evaluated))
        (dieT "host image evaluation did not return one absolute output path")
      let pathDigest = InventoryDigest.contentDigest (TE.encodeUtf8 evaluated)
      owner <- either dieT pure (Resource.mkScopeId Resource.Platform "host-image-build")
      key <- either dieT pure (Resource.mkLogicalKey "host-image")
      role <- either dieT pure (Resource.mkName "host-image-build")
      cloudOwner <- either dieT pure (Resource.mkScopeId Resource.Platform "cloud")
      bucketKey <- either dieT pure (Resource.mkLogicalKey "nagare-images")
      bucketName <- either dieT pure (Resource.mkName "nagare-images")
      let bucketId = Resource.mintResourceId cloudOwner bucketKey bucketName
          buildSpec =
            ArtifactResourceSpec
              { artifactLogicalKey = key
              , artifactRole = role
              , artifactName = role
              , artifactDestination = evaluated
              , artifactContentDigest = pathDigest
              , artifactSpecDigest = pathDigest
              , artifactKind = InventoryArtifact.BuildJobArtifact
              , artifactOwnership = InventoryArtifact.OwnedArtifact
              , artifactLifecycle = ResourcePolicy.Retain
              , artifactDataPolicy = ResourcePolicy.Stateless
              , artifactSensitivity = ResourcePolicy.Private
              , artifactDependencies = [ResourceReference.OrderedAfter bucketId]
              , artifactConsumers = InventoryArtifact.ConsumerCompletenessUnknown
              , artifactPublishOperation = False
              , artifactSource = Resource.SourceLocation (T.pack hostRoot) "nix-image-output"
              }
      scope <-
        either
          (dieT . T.pack . show)
          pure
          ( InventoryArtifact.compileArtifactScope
              (ArtifactDeclarationBundle 1 owner (buildSpec NE.:| []))
          )
      case Map.lookup owner (ResourceInventory.snapshotScopes snapshot) of
        Just (_, prior)
          | prior /= scope ->
              dieT "accepted host image build differs from this immutable output path"
        _ -> pure ()
      let accepted = Map.member owner (ResourceInventory.snapshotScopes snapshot)
      present <-
        if not accepted
          then pure False
          else do
            result <- runHostImageProbe active workspace hostRoot "--inspect-build"
            case T.splitOn "\t" result of
              ["nagare-build", status, observedPath, observedDigest]
                | observedPath == evaluated
                , observedDigest == Resource.digestText pathDigest
                , status `elem` ["present", "missing"] ->
                    pure (status == "present")
              _ -> dieT "host image build inspection differs from the reviewed output"
      if present
        then pure Nothing
        else
          Just
            <$> either
              (dieT . T.pack . show)
              pure
              (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))

runHostImageProbe :: ActiveTarget -> PlatformWorkspace -> FilePath -> String -> IO Text
runHostImageProbe active workspace hostRoot option = do
  environment <- getEnvironment
  let selected =
        [ ("NAGARE_CONTEXT", T.unpack (contextNameText (active ^. #contextName)))
        , ("NAGARE_HOST_FLAKE", hostRoot)
        ]
      names = map fst selected
      process :: CreateProcess
      process =
        (proc "bash" [workspace ^. #scriptsDir </> "upload-images.sh", option])
          { env = Just (selected <> filter ((`notElem` names) . fst) environment)
          }
  try (readCreateProcessWithExitCode process "") >>= \case
    Left (err :: IOException) -> dieT ("could not inspect host image: " <> T.pack (show err))
    Right (ExitFailure code, _, err) ->
      dieT
        ("host image inspection failed (exit " <> T.pack (show code) <> "): " <> T.pack err)
    Right (ExitSuccess, out, _) -> pure (T.strip (T.pack out))

buildImagePublicationStageCandidate ::
  ActiveTarget ->
  PlatformWorkspace ->
  ResourceInventory.ScopeSnapshot ->
  IO (Maybe ResourceInventory.CompositionCandidate)
buildImagePublicationStageCandidate active workspace snapshot
  | active ^. #profile . #mode /= Cloud = pure Nothing
  | otherwise = do
      hostRoot <- hostConfigDir (active ^. #contextName)
      description <- runHostImageProbe active workspace hostRoot "--describe-build"
      (storePath, imageName, imageDigest) <- case T.splitOn "\t" description of
        ["nagare-image", path, name, digest]
          | T.isPrefixOf "/" path
          , T.isPrefixOf "nagare-image-" name ->
              (,,) path name <$> either dieT pure (Resource.mkContentDigest digest)
        _ -> dieT "built host image description is invalid"
      buildOwner <- either dieT pure (Resource.mkScopeId Resource.Platform "host-image-build")
      buildKey <- either dieT pure (Resource.mkLogicalKey "host-image")
      buildRole <- either dieT pure (Resource.mkName "host-image-build")
      let buildId = Resource.mintResourceId buildOwner buildKey buildRole
          acceptedBuild =
            [ resource
            | Just (_, scope) <- [Map.lookup buildOwner (ResourceInventory.snapshotScopes snapshot)]
            , bundle <- ResourceInventory.scopeBundles scope
            , ResourceInventory.Managed resource <- ResourceInventory.declarations bundle
            , resource ^. #identity == buildId
            ]
      unless
        ( case acceptedBuild of
            [resource] ->
              resource ^. #address
                == Resource.Artifact
                  buildRole
                  (InventoryDigest.contentDigest (TE.encodeUtf8 storePath))
            _ -> False
        )
        (dieT "host image publication requires the accepted reviewed build output")
      let project = active ^. #profile . #project
          destination = "projects/" <> project <> "/global/images/" <> imageName
          pathDigest = InventoryDigest.contentDigest (TE.encodeUtf8 storePath)
      owner <- either dieT pure (Resource.mkScopeId Resource.Platform "host-image")
      key <- either dieT pure (Resource.mkLogicalKey "gce-image")
      role <- either dieT pure (Resource.mkName imageName)
      cloudOwner <- either dieT pure (Resource.mkScopeId Resource.Platform "cloud")
      bucketKey <- either dieT pure (Resource.mkLogicalKey "nagare-images")
      bucketName <- either dieT pure (Resource.mkName "nagare-images")
      let resourceId = Resource.mintResourceId owner key role
          bucketId = Resource.mintResourceId cloudOwner bucketKey bucketName
          imageSpec =
            ArtifactResourceSpec
              { artifactLogicalKey = key
              , artifactRole = role
              , artifactName = role
              , artifactDestination = destination
              , artifactContentDigest = imageDigest
              , artifactSpecDigest = pathDigest
              , artifactKind = InventoryArtifact.GceImageArtifact
              , artifactOwnership = InventoryArtifact.OwnedArtifact
              , artifactLifecycle = ResourcePolicy.Retain
              , artifactDataPolicy = ResourcePolicy.Stateless
              , artifactSensitivity = ResourcePolicy.Private
              , artifactDependencies = map ResourceReference.OrderedAfter [bucketId, buildId]
              , artifactConsumers = InventoryArtifact.ConsumerCompletenessUnknown
              , artifactPublishOperation = False
              , artifactSource = Resource.SourceLocation (T.pack hostRoot) "gce-image-from-nix"
              }
      scope <-
        either
          (dieT . T.pack . show)
          pure
          ( InventoryArtifact.compileArtifactScope
              (ArtifactDeclarationBundle 1 owner (imageSpec NE.:| []))
          )
      case Map.lookup owner (ResourceInventory.snapshotScopes snapshot) of
        Just (_, prior)
          | prior /= scope ->
              dieT "accepted GCE image differs from this immutable host image build"
        _ -> pure ()
      let accepted = Map.member owner (ResourceInventory.snapshotScopes snapshot)
      present <-
        if not accepted
          then pure False
          else
            observeReviewedGceImage active workspace resourceId destination imageDigest pathDigest
      if present
        then pure Nothing
        else
          Just
            <$> either
              (dieT . T.pack . show)
              pure
              (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))

observeReviewedGceImage ::
  ActiveTarget ->
  PlatformWorkspace ->
  Resource.ResourceId ->
  Text ->
  Resource.ContentDigest ->
  Resource.ContentDigest ->
  IO Bool
observeReviewedGceImage active workspace resourceId destination contentDigest specDigest = do
  environment <- getEnvironment
  hostRoot <- hostConfigDir (active ^. #contextName)
  let selected =
        [ ("NAGARE_CONTEXT", T.unpack (contextNameText (active ^. #contextName)))
        , ("NAGARE_HOST_FLAKE", hostRoot)
        , ("NAGARE_INVENTORY_ADAPTER_CHILD", "artifact")
        ]
      names = map fst selected
      process :: CreateProcess
      process =
        (proc (workspace ^. #scriptsDir </> "inventory-artifact-transport.sh") ["observe"])
          { env = Just (selected <> filter ((`notElem` names) . fst) environment)
          }
      request =
        Aeson.object
          [ "version" Aeson..= (1 :: Int)
          , "resource" Aeson..= resourceId
          , "kind" Aeson..= InventoryArtifact.GceImageArtifact
          , "destination" Aeson..= destination
          , "expectedDigest" Aeson..= contentDigest
          , "specDigest" Aeson..= specDigest
          , "archive" Aeson..= Aeson.Null
          , "plan" Aeson..= Aeson.Null
          ]
  result <-
    try
      ( readCreateProcessWithExitCode
          process
          (T.unpack (TE.decodeUtf8 (LBS.toStrict (Aeson.encode request))))
      )
      >>= \case
        Left (err :: IOException) -> dieT ("could not observe reviewed GCE image: " <> T.pack (show err))
        Right (ExitFailure code, _, err) ->
          dieT
            ("reviewed GCE image observation failed (exit " <> T.pack (show code) <> "): " <> T.pack err)
        Right (ExitSuccess, out, _) ->
          either
            (dieT . T.pack)
            pure
            (Aeson.eitherDecodeStrict' (BC.pack out) :: Either String Aeson.Value)
  case result of
    Aeson.Object fields -> case (AesonMap.lookup "tag" fields, AesonMap.lookup "contents" fields) of
      (Just (Aeson.String "TransportMissing"), _) -> pure False
      (Just (Aeson.String "TransportPresent"), Just contents) ->
        case Aeson.fromJSON contents :: Aeson.Result [Text] of
          Aeson.Success [physical, digest]
            | physical == "gce://" <> destination
            , digest == Resource.digestText contentDigest ->
                pure True
          _ -> dieT "reviewed GCE image has a different physical identity or content digest"
      _ -> dieT "reviewed GCE image observation is unavailable or unowned"
    _ -> dieT "reviewed GCE image observation is invalid"
