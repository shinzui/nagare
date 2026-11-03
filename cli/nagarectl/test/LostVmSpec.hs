module LostVmSpec (lostVmTests) where

import Data.ByteString (ByteString)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Ops.LostVm
import System.Exit (ExitCode (ExitFailure))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

urn :: Text
urn = "urn:pulumi:ep::nagare::nagare:compute:NagareInstance$gcp:compute/instance:Instance::vm-01"

disk :: Text
disk = "urn:pulumi:ep::nagare::gcp:compute/disk:Disk::data"

exported :: ByteString
exported = TE.encodeUtf8 ("{\"deployment\":{\"resources\":[{\"type\":\"gcp:compute/instance:Instance\",\"urn\":\"" <> urn <> "\"},{\"type\":\"gcp:compute/disk:Disk\",\"urn\":\"" <> disk <> "\"}]}}")

refreshSteps :: [(Text, Text)] -> ByteString
refreshSteps steps = TE.encodeUtf8 ("{\"steps\":[" <> T.intercalate "," ["{\"op\":\"" <> op <> "\",\"urn\":\"" <> target <> "\"}" | (op, target) <- steps] <> "]}")

run :: Either Text VmPresence -> ByteString -> IO (Either Text Text, Int)
run presence previewed = do
  refreshed <- newIORef (0 :: Int)
  result <-
    forgetLostVm
      LostVmOps
        { lostVmPresence = pure presence
        , lostVmStackExport = pure (Right exported)
        , lostVmRefreshPreview = \_ -> pure (Right previewed)
        , lostVmRefresh = \_ -> Right () <$ modifyIORef' refreshed (+ 1)
        }
      "vm-01"
  (result,) <$> readIORef refreshed

lostVmTests :: TestTree
lostVmTests =
  testGroup
    "F142: forgetting a lost VM"
    [ testCase "a confirmed absence drops exactly the VM's record" $ do
        (result, refreshed) <- run (Right VmConfirmedAbsent) (refreshSteps [("refresh", disk), ("delete", urn)])
        assertBool "forgotten" (either (const False) (const True) result)
        refreshed @?= 1
    , testCase "a VM that still exists is refused" $ do
        (result, refreshed) <- run (Right VmPresent) (refreshSteps [("delete", urn)])
        assertBool "refused" (either (T.isInfixOf "still exists") (const False) result)
        refreshed @?= 0
    , testCase "a failed read of the VM is not a loss" $ do
        vmPresenceFromGcloud (ExitFailure 1) "PERMISSION_DENIED" @?= Left "could not read the VM: PERMISSION_DENIED"
        vmPresenceFromGcloud (ExitFailure 1) "The resource 'x' was not found" @?= Right VmConfirmedAbsent
        (_, refreshed) <- run (Left "denied") (refreshSteps [("delete", urn)])
        refreshed @?= 0
    , testCase "a refresh that would drop the data disk too is refused" $ do
        (result, refreshed) <- run (Right VmConfirmedAbsent) (refreshSteps [("delete", urn), ("delete", disk)])
        assertBool "refused" (either (T.isInfixOf "more than the lost VM") (const False) result)
        refreshed @?= 0
    , testCase "a refresh that changes nothing is refused" $ do
        (_, refreshed) <- run (Right VmConfirmedAbsent) (refreshSteps [("refresh", urn)])
        refreshed @?= 0
    , testCase "the instance is found by its exact name" $ do
        instanceUrn "vm-01" exported @?= Right (Just urn)
        instanceUrn "vm-0" exported @?= Right Nothing
    ]
