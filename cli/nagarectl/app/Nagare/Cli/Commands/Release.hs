-- | Commands / Release. Executable-private CLI boundary.
module Nagare.Cli.Commands.Release
  ( runReleasePublish
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM, forM_)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as AesonMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (sortOn)
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Cli.Runtime.Error (dieT, renderVersionError)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.GitHubRelease qualified as GitHubRelease
import Nagare.Inventory.Adapters.GitHubReleaseRuntime
  ( githubReleaseOps
  )
import Nagare.Inventory.Artifact
  ( ArtifactExecutionSpec (ArtifactExecutionSpec)
  , ArtifactKind (ReleasePayloadArtifact)
  )
import Nagare.Inventory.Digest qualified as InventoryDigest
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire qualified as ResourceWire
import Nagare.Version (parsePlatformVersion)
import System.Directory
  ( doesFileExist
  , doesPathExist
  , pathIsSymbolicLink
  , renameFile
  )
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withTempDirectory)
import System.Process (readProcessWithExitCode)

runReleasePublish :: Text -> Text -> FilePath -> Bool -> Maybe (Integer, Integer, Text) -> IO ()
runReleasePublish repository version directory yes cleanup = do
  _ <- either (dieT . renderVersionError) pure (parsePlatformVersion version)
  let evidenceName = "nagare-inventory-evidence-v" <> T.unpack version <> ".json"
  evidenceExists <- doesFileExist (directory </> evidenceName)
  when evidenceExists $ do
    linked <- pathIsSymbolicLink (directory </> evidenceName)
    when linked (dieT "inventory evidence attachment may not be a symbolic link")
  let tag = "v" <> version
      manifestName = "nagare-release-" <> T.unpack version <> ".json"
      notesName = "nagare-" <> T.unpack tag <> ".md"
      productNames =
        [ manifestName
        , notesName
        , "nix-output-x86_64-linux.json"
        , "nix-output-aarch64-darwin.json"
        , "clone-free-x86_64-linux.json"
        , "clone-free-aarch64-darwin.json"
        , "SHA256SUMS"
        ]
          <> [evidenceName | evidenceExists]
  tagType <- exactGitObjectType ("refs/tags/" <> T.unpack tag)
  unless (tagType == "tag") (dieT "release requires an annotated Git tag")
  tagObject <- exactGitRevision ("refs/tags/" <> T.unpack tag)
  commit <- exactGitRevision ("refs/tags/" <> T.unpack tag <> "^{commit}")
  headCommit <- exactGitRevision "HEAD"
  unless (headCommit == commit) (dieT "release tag does not identify the checked-out commit")
  assets <- forM productNames $ \name -> do
    attempted <- try (BS.readFile (directory </> name))
    bytes <-
      either
        (dieT . ("could not read assembled release asset: " <>) . T.pack . show)
        pure
        (attempted :: Either IOException ByteString)
    let digest = InventoryDigest.contentDigest bytes
        spec =
          ArtifactExecutionSpec
            ReleasePayloadArtifact
            ("github-release://" <> repository <> "/" <> tag <> "/" <> T.pack name)
            digest
            digest
            False
            Nothing
    pure (GitHubRelease.ProductAsset (T.pack name) spec bytes)
  let byName = Map.fromList [(T.unpack (GitHubRelease.productName item), GitHubRelease.productBytes item) | item <- assets]
      manifestBytes = fromMaybe BS.empty (Map.lookup manifestName byName)
      notesBytes = fromMaybe BS.empty (Map.lookup notesName byName)
      sumsBytes = fromMaybe BS.empty (Map.lookup "SHA256SUMS" byName)
  manifest <-
    either
      (dieT . T.pack)
      pure
      (Aeson.eitherDecodeStrict' manifestBytes :: Either String Aeson.Value)
  case manifest of
    Aeson.Object fields -> do
      unless
        ( AesonMap.lookup "version" fields == Just (Aeson.String version)
            && AesonMap.lookup "tag" fields == Just (Aeson.String tag)
            && AesonMap.lookup "revision" fields == Just (Aeson.String commit)
            && AesonMap.lookup "consistent" fields == Just (Aeson.Bool True)
        )
        (dieT "assembled release manifest does not bind this version, tag, and commit")
    _ -> dieT "assembled release manifest is not an object"
  forM_ (Map.lookup evidenceName byName) $ \evidenceBytes -> do
    evidence <-
      either
        (dieT . ("invalid inventory evidence: " <>) . T.pack)
        pure
        (Aeson.eitherDecodeStrict' evidenceBytes :: Either String Aeson.Value)
    let field key (Aeson.Object fields) = AesonMap.lookup key fields
        field _ _ = Nothing
        payload = field "payload" evidence
        fromPayload key = payload >>= field key
        system = case fromPayload "system" of
          Just (Aeson.String systemName) -> Just systemName
          _ -> Nothing
        expectedDigest = do
          Aeson.Object manifestFields <- pure manifest
          Aeson.Object digests <- AesonMap.lookup "payloadDigests" manifestFields
          selected <- system
          AesonMap.lookup (AesonKey.fromText selected) digests
        validRun = case field "run" evidence >>= field "id" of
          Just (Aeson.String runToken) -> T.length runToken == 64
          _ -> False
        hasReceipts = case field "componentReceipts" evidence of
          Just (Aeson.Array values) -> not (null values)
          _ -> False
        validEvidence =
          field "schemaVersion" evidence == Just (Aeson.Number 1)
            && fromPayload "version" == Just (Aeson.String version)
            && fromPayload "sourceRevision" == Just (Aeson.String commit)
            && isJust expectedDigest
            && fromPayload "digest" == expectedDigest
            && validRun
            && hasReceipts
            && (field "coverage" evidence >>= field "complete") == Just (Aeson.Bool True)
            && (field "finalObservation" evidence >>= field "complete") == Just (Aeson.Bool True)
    unless validEvidence (dieT "inventory evidence does not bind the complete release candidate")
  sumsText <- either (dieT . T.pack . show) pure (TE.decodeUtf8' sumsBytes)
  listed <- forM (T.lines sumsText) $ \line -> do
    let (digest, suffix) = T.breakOn "  " line
        name = T.drop 2 suffix
    unless
      (T.length digest == 64 && not (T.null name))
      (dieT "SHA256SUMS contains an invalid entry")
    pure (T.unpack name, digest)
  let expectedSums =
        Map.fromList
          [ (name, Resource.digestText (InventoryDigest.contentDigest bytes))
          | (name, bytes) <- Map.toList byName
          , name /= "SHA256SUMS"
          ]
  unless
    (length listed == Map.size expectedSums && Map.fromList listed == expectedSums)
    (dieT "SHA256SUMS does not exactly cover the assembled product bytes")
  notes <- either (dieT . T.pack . show) pure (TE.decodeUtf8' notesBytes)
  let payload = Resource.digestText (InventoryDigest.contentDigest manifestBytes)
  review <-
    either
      dieT
      pure
      (GitHubRelease.compilePublicationReview repository tag tagObject commit payload notes assets)
  TIO.putStrLn ("Release candidate: " <> repository <> "/" <> tag)
  TIO.putStrLn ("Tag object: " <> tagObject <> "; commit: " <> commit)
  TIO.putStrLn ("Publication review: " <> GitHubRelease.publicationDigest review)
  forM_ assets $ \item ->
    TIO.putStrLn
      ( "  "
          <> GitHubRelease.productName item
          <> "  "
          <> Resource.digestText (InventoryDigest.contentDigest (GitHubRelease.productBytes item))
      )
  case cleanup of
    Nothing ->
      if not yes
        then TIO.putStrLn "Review only; pass --yes to publish these exact bytes."
        else do
          published <-
            GitHubRelease.publishReviewedRelease (githubReleaseOps review) review
              >>= either dieT pure
          let observation =
                Aeson.object
                  [ "schemaVersion" Aeson..= (1 :: Int)
                  , "repository" Aeson..= repository
                  , "tag" Aeson..= tag
                  , "tagObject" Aeson..= tagObject
                  , "commit" Aeson..= commit
                  , "payloadId" Aeson..= payload
                  , "reviewDigest" Aeson..= GitHubRelease.publicationDigest review
                  , "releaseId" Aeson..= GitHubRelease.providerReleaseId published
                  , "published" Aeson..= True
                  , "assets"
                      Aeson..= [ Aeson.object
                                   [ "id" Aeson..= GitHubRelease.providerAssetId asset
                                   , "name" Aeson..= GitHubRelease.providerAssetName asset
                                   , "size" Aeson..= GitHubRelease.providerAssetSize asset
                                   , "digest" Aeson..= GitHubRelease.providerAssetDigest asset
                                   ]
                               | asset <- sortOn GitHubRelease.providerAssetName (GitHubRelease.providerReleaseAssets published)
                               ]
                  ]
              observationPath = directory </> "nagare-publication-observation-v" <> T.unpack version <> ".json"
          observationBytes <- either dieT pure (ResourceWire.canonicalValue observation)
          existing <- doesPathExist observationPath
          if existing
            then do
              recorded <- BS.readFile observationPath
              unless
                (recorded == observationBytes)
                (dieT "local release completion observation has different bytes")
            else withTempDirectory directory ".nagare-publication-observation-" $ \staging -> do
              let temporary = staging </> "observation.json"
              BS.writeFile temporary observationBytes
              renameFile temporary observationPath
          TIO.putStrLn
            ( "Release "
                <> tag
                <> " verified at GitHub release ID "
                <> T.pack (show (GitHubRelease.providerReleaseId published))
                <> "; completion observation: "
                <> T.pack observationPath
            )
    Just (releaseId, assetId, assetName) -> do
      TIO.putStrLn
        ( "Failed-upload cleanup review: release "
            <> T.pack (show releaseId)
            <> ", asset "
            <> T.pack (show assetId)
            <> " ("
            <> assetName
            <> ")"
        )
      if not yes
        then TIO.putStrLn "Review only; pass --yes to delete this exact draft placeholder."
        else do
          GitHubRelease.cleanupReviewedStarter
            (githubReleaseOps review)
            review
            releaseId
            assetId
            assetName
            >>= either dieT pure
          TIO.putStrLn ("Deleted failed draft asset ID " <> T.pack (show assetId))

exactGitRevision :: String -> IO Text
exactGitRevision revision = do
  (code, output, err) <- readProcessWithExitCode "git" ["rev-parse", "--verify", revision] ""
  case code of
    ExitSuccess -> pure (T.strip (T.pack output))
    _ -> dieT ("could not resolve exact Git revision " <> T.pack revision <> ": " <> T.pack err)

exactGitObjectType :: String -> IO Text
exactGitObjectType revision = do
  (code, output, err) <- readProcessWithExitCode "git" ["cat-file", "-t", revision] ""
  case code of
    ExitSuccess -> pure (T.strip (T.pack output))
    _ -> dieT ("could not inspect Git object " <> T.pack revision <> ": " <> T.pack err)
