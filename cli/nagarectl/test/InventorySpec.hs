module InventorySpec (inventoryTests) where

import Control.Exception (try)
import Control.Monad (forM_)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.Either (isLeft, isRight)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Command
import Nagare.Resource.Inventory
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
    , testCase "all negative fixtures fail for the intended diagnostic"
        $ forM_
          [("collision-service.json", "claim-conflict"), ("collision-knative-database.json", "claim-conflict"), ("collision-bucket.json", "claim-conflict"), ("duplicate-id.json", "wire"), ("missing-snapshot.json", "wire"), ("retained-claim.json", "reserved-claim")]
        $ \(file, code) -> do
          result <- compileInput <$> fixture file
          case result of Left es -> assertBool (show es) (code `elem` map (^. #code) (NE.toList es)); Right _ -> assertFailure file
    , testCase "typed unresolved output compiles" $ do
        result <- compileInput <$> fixture "unresolved-output.json"
        assertBool (show result) (isRight result)
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
