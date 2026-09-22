module InventorySpec (inventoryTests) where

import Control.Exception (try)
import Control.Monad (forM_)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.Either (isLeft, isRight)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.List (reverse)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Command
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Resource.Wire
import System.Directory
import System.Exit (ExitCode)
import System.FilePath ((</>))
import System.IO.Temp
import Test.Tasty
import Test.Tasty.HUnit

fixture :: String -> IO BS.ByteString
fixture file = BS.readFile ("test/fixtures/inventory" </> file)

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

inventoryTests :: TestTree
inventoryTests =
  testGroup
    "inventory compiler"
    [ testCase "compile and load immutable bundle; same output may be reused" $ withSystemTempDirectory "inventory-test" $ \dir -> do
        let output = dir </> "compiled"
        compileInventory "test/fixtures/inventory/valid.json" output False
        loaded <- loadCandidate output
        assertBool (show loaded) (isRight loaded)
        compileInventory "test/fixtures/inventory/valid.json" output False
        memberNames <- listDirectory (output </> "scopes")
        length memberNames @?= 2
        BS.writeFile (output </> "scopes" </> head memberNames) "{}"
        bad <- loadCandidate output
        assertBool "tampered member rejected" (isLeft bad)
        refused <- try (compileInventory "test/fixtures/inventory/valid.json" output False) :: IO (Either ExitCode ())
        assertBool "refuses overwrite" (isLeft refused)
    , testCase "invalid input creates no output" $ withSystemTempDirectory "inventory-test" $ \dir -> do
        let output = dir </> "invalid"
        refused <- try (compileInventory "test/fixtures/inventory/collision-service.json" output True) :: IO (Either ExitCode ())
        assertBool "invalid rejected" (isLeft refused)
        doesPathExist output >>= (@?= False)
    , testCase "Kubernetes declaration binds the exact canonical native object" $ do
        let owner = ok (mkScopeId Platform "foundation")
            rid key = mintResourceId owner (ok (mkLogicalKey key)) (ok (mkName "resource"))
            objectName name = object
              [ "apiVersion" .= ("v1" :: Text)
              , "kind" .= ("Service" :: Text)
              , "metadata" .= object ["name" .= name, "namespace" .= ("personal" :: Text)]
              ]
            original = objectName ("cache" :: Text)
            bytes = ok (canonicalValue original)
            input value = KubernetesInput (rid "service") owner (rid "cluster") value (contentDigest bytes) Retain Stateless Public (SourceLocation "fixture.yaml" "document[0]")
        (_, boundBytes) <- either (assertFailure . show) pure (bindKubernetesObject (input original))
        boundBytes @?= bytes
        case bindKubernetesObject (input (objectName ("different" :: Text))) of
          Left err -> err ^. #code @?= "invalid-kubernetes-object"
          Right _ -> assertFailure "changed native object retained stale review digest"
    , testCase "all negative fixtures fail for the intended diagnostic"
        $ forM_
          [("collision-service.json", "claim-conflict"), ("collision-knative-database.json", "claim-conflict"), ("collision-bucket.json", "claim-conflict"), ("collision-version-alias.json", "claim-conflict"), ("duplicate-id.json", "wire"), ("missing-snapshot.json", "wire"), ("retained-claim.json", "reserved-claim")]
        $ \(file, code) -> do
          result <- compileInput <$> fixture file
          case result of Left es -> assertBool (show es) (code `elem` map (^. #code) (NE.toList es)); Right _ -> assertFailure file
    , testCase "typed unresolved output compiles" $ do
        result <- compileInput <$> fixture "unresolved-output.json"
        assertBool (show result) (isRight result)
    , testCase "shared namespace contributions compile to one owner declaration" $ do
        result <- compileInput <$> fixture "shared-namespace-contributions.json"
        assertBool (show result) (isRight result)
    , testCase "shuffled scope selection produces identical member bytes and digest" $ do
        bytes <- fixture "valid.json"
        let CandidateInput snapshot changes = ok (decodeCandidateInput bytes)
            snapshotChanges = map (ReplaceScope . snd) (Map.elems (snapshotScopes snapshot))
            selected = NE.toList changes <> snapshotChanges
            firstInput = CandidateInput snapshot (NE.fromList selected)
            secondInput = CandidateInput snapshot (NE.fromList (reverse selected))
        compileInput (ok (canonicalValue (candidateInputValue firstInput))) @?= compileInput (ok (canonicalValue (candidateInputValue secondInput)))
    , testCase "version-one candidate golden digest" $ do
        bytes <- fixture "valid.json"
        lookup "candidate.sha256" (ok (compileInput bytes)) @?= Just "d29d70896d10117d2cd550b5a17804d1da9a45a0a0706192dd3b03fd54e13632\n"
    , testCase "desired digest excludes base generation but candidate digest binds it" $ do
        bytes <- fixture "valid.json"
        let input = ok (eitherDecodeStrict bytes :: Either String Value)
            changed = replaceGeneration input
            originalFiles = ok (compileInput bytes)
            changedFiles = ok (compileInput (ok (canonicalValue changed)))
            manifest files = ok (eitherDecodeStrict (fromMaybe "" (lookup "candidate.json" files))) :: Value
            desired (Object o) = KM.lookup "desiredDigest" o
            desired _ = Nothing
        desired (manifest originalFiles) @?= desired (manifest changedFiles)
        assertBool "different candidate" (lookup "candidate.sha256" originalFiles /= lookup "candidate.sha256" changedFiles)
    , testCase "missing compiled member is an error, never an empty scope" $ withSystemTempDirectory "inventory-test" $ \dir -> do
        let output = dir </> "compiled"
        compileInventory "test/fixtures/inventory/valid.json" output False
        members <- listDirectory (output </> "scopes")
        renameFile (output </> "scopes" </> head members) (dir </> "removed-member")
        result <- loadCandidate output
        assertBool "missing refuses" (isLeft result)
    ]
  where
    replaceGeneration (Object o) = Object (KM.mapWithKey (\k v -> if k == "generation" then Number 8 else replaceGeneration v) o)
    replaceGeneration (Array xs) = Array (fmap replaceGeneration xs)
    replaceGeneration v = v
