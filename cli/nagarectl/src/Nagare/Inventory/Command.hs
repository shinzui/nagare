module Nagare.Inventory.Command (compileInput, compileInventory, loadCandidate) where

import Control.Exception (IOException, try)
import Control.Monad (forM, forM_)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Digest
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Resource.Wire
import System.Directory
import System.Exit (exitFailure)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO (stderr)
import System.IO.Temp (withTempDirectory)
import System.Posix.Files (setFileMode)

-- | No context lookup and no provider process. Validation completes before IO.
compileInput :: ByteString -> Either (NonEmpty InventoryError) [(FilePath, ByteString)]
compileInput bytes = do
  input@(CandidateInput snapshot changes) <- decodeCandidateInput bytes
  candidate <- composeInventory snapshot changes
  let desired = inventoryScopes (candidateInventory candidate)
      allScopes = Map.elems desired <> map snd (Map.elems (snapshotScopes snapshot))
      members = Map.fromList [(memberPath s, encodeCanonicalScope s) | s <- allScopes]
      memberPath s = "scopes/" <> T.unpack (digestText (contentDigest (encodeCanonicalScope s))) <> ".json"
      references s = object ["scope" .= scopeId s, "member" .= memberPath s, "digest" .= contentDigest (encodeCanonicalScope s)]
      desiredValue = object ["context" .= inventoryBinding (candidateInventory candidate), "scopes" .= map references (Map.elems desired)]
  desiredBytes <- canonical desiredValue
  -- Retain the explicit base and changes using digest-bound member references.
  -- Loading verifies the references and composes the declarations again.
  inputBytes <- canonical (referenceScopes (candidateInputValue input))
  manifest <-
    canonical
      ( object
          [ "version" .= (1 :: Integer)
          , "inputDigest" .= contentDigest inputBytes
          , "members" .= [object ["path" .= p, "digest" .= contentDigest b] | (p, b) <- Map.toAscList members]
          , "desiredDigest" .= contentDigest desiredBytes
          , "desired" .= desiredValue
          , "generations" .= [object ["scope" .= s, "generation" .= g] | (s, g) <- Map.toAscList (candidateGenerations candidate)]
          ]
      )
  pure ([("candidate.json", manifest), ("candidate.sha256", BC.pack (T.unpack (digestText (contentDigest manifest))) <> "\n"), ("input.json", inputBytes)] <> Map.toAscList members)
  where
    canonical = first (\e -> inventoryError "canonical" e :| []) . canonicalValue

-- | Verify exact members and recompose. Bytes can never manufacture a proof value.
loadCandidate :: FilePath -> IO (Either Text CompositionCandidate)
loadCandidate dir = do
  result <- try $ do
    inputBytes <- BS.readFile (dir </> "input.json")
    inputValue <- either (ioError . userError) pure (eitherDecodeStrict inputBytes)
    expanded <- expandScopes dir inputValue
    bytes <- either (ioError . userError . T.unpack) pure (canonicalValue expanded)
    case compileInput bytes of
      Left es -> pure (Left (T.pack (show es)))
      Right files -> do
        equal <- verifyFiles dir files
        pure $
          if not equal
            then Left "candidate files differ from their canonical digests or membership"
            else first (T.pack . show) $ do
              CandidateInput snapshot changes <- decodeCandidateInput bytes
              composeInventory snapshot changes
  pure $ case result of Left (e :: IOException) -> Left (T.pack (show e)); Right r -> r

-- Scope members are immutable individual documents, never embedded in manifests.
referenceScopes :: Value -> Value
referenceScopes (Object o)
  | sort (KM.keys o) == ["bundles", "scope", "version"] =
      let bytes = either (error . T.unpack) id (canonicalValue (Object o))
          digest = contentDigest bytes
       in object ["member" .= ("scopes/" <> digestText digest <> ".json"), "digest" .= digest]
  | otherwise = Object (fmap referenceScopes o)
referenceScopes (Array xs) = Array (fmap referenceScopes xs)
referenceScopes value = value

expandScopes :: FilePath -> Value -> IO Value
expandScopes dir (Object o)
  | sort (KM.keys o) == ["digest", "member"] = do
      (member, digest) <- either (ioError . userError) pure (parseEither (\v -> (,) <$> v .: "member" <*> v .: "digest") o)
      let expected = "scopes/" <> T.unpack (digestText digest) <> ".json"
      unless (member == expected) (ioError (userError "invalid scope member path"))
      link <- pathIsSymbolicLink (dir </> member)
      when link (ioError (userError "scope member must not be a symlink"))
      bytes <- BS.readFile (dir </> member)
      unless (contentDigest bytes == digest) (ioError (userError "scope member digest mismatch"))
      declaration <- either (ioError . userError . show) pure (decodeScope bytes)
      unless (encodeCanonicalScope declaration == bytes) (ioError (userError "noncanonical scope member"))
      pure (scopeValue declaration)
  | otherwise = Object <$> traverse (expandScopes dir) o
expandScopes dir (Array xs) = Array <$> traverse (expandScopes dir) xs
expandScopes _ value = pure value

verifyFiles :: FilePath -> [(FilePath, ByteString)] -> IO Bool
verifyFiles dir files = do
  rootNames <- sort <$> listDirectory dir
  scopeNames <- sort <$> listDirectory (dir </> "scopes")
  equal <- forM files $ \(p, b) -> do
    symlink <- pathIsSymbolicLink (dir </> p)
    actual <- BS.readFile (dir </> p)
    pure (not symlink && actual == b)
  scopeLink <- pathIsSymbolicLink (dir </> "scopes")
  pure (not scopeLink && and equal && rootNames == ["candidate.json", "candidate.sha256", "input.json", "scopes"] && scopeNames == sort [takeFileName p | (p, _) <- files, takeDirectory p == "scopes"])

compileInventory :: FilePath -> FilePath -> Bool -> IO ()
compileInventory input output json = do
  result <- try (BS.readFile input)
  case result of
    Left (e :: IOException) -> report [inventoryError "input" (T.pack (show e))]
    Right bytes -> case compileInput bytes of
      Left es -> report (NE.toList es)
      Right files -> do
        published <- try $ do
          exists <- doesPathExist output
          if exists
            then do
              link <- pathIsSymbolicLink output
              matches <- if link then pure False else verifyFiles output files
              unless matches (ioError (userError "output exists with different contents; refusing overwrite"))
            else do
              let parent = takeDirectory output
              createDirectoryIfMissing True parent
              withTempDirectory parent ".inventory-" $ \staging -> do
                setFileMode staging 0o700
                createDirectory (staging </> "scopes")
                setFileMode (staging </> "scopes") 0o700
                forM_ files $ \(p, b) -> do
                  BS.writeFile (staging </> p) b
                  setFileMode (staging </> p) 0o600
                renameDirectory staging output
        case published of
          Left (e :: IOException) -> report [inventoryError "output" (T.pack (show e))]
          Right () -> BC.putStr (fromMaybe "" (lookup "candidate.sha256" files))
  where
    report es = do
      if json
        then BC.hPutStrLn stderr (either (error . T.unpack) id (canonicalValue (toJSON (map errorValue es))))
        else BC.hPutStrLn stderr (BC.pack (show es))
      exitFailure
