module InventoryMaintenanceSpec (inventoryMaintenanceTests) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.IORef
import Data.Text (Text)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.DataFence.MaintenanceNetwork
import Test.Tasty
import Test.Tasty.HUnit

inventoryMaintenanceTests :: TestTree
inventoryMaintenanceTests = testGroup "maintenance"
  [ testCase "lost ingress-policy create acknowledgement reobserves exact intent" $ do
      pin <- case mkMaintenanceNetworkPin "session-1" "personal" "database"
          "database-0" "11111111-1111-1111-1111-111111111111" of
        Left reason -> assertFailure (show reason) >> error "invalid maintenance pin"
        Right value -> pure value
      current <- newIORef Nothing
      creations <- newIORef (0 :: Int)
      deletions <- newIORef (0 :: Int)
      let uid = "22222222-2222-2222-2222-222222222222" :: Text
          version = "17" :: Text
          withIdentity = \case
            Object root | Just (Object metadata) <- KM.lookup "metadata" root ->
              Object (KM.insert "metadata" (Object
                (KM.insert "resourceVersion" (String version)
                  (KM.insert "uid" (String uid) metadata))) root)
            _ -> error "maintenance policy is malformed"
          transport = MaintenanceNetworkTransport
            { readMaintenancePolicy = \_ _ -> Right <$> readIORef current
            , createMaintenancePolicy = \value -> do
                modifyIORef' creations (+ 1)
                writeIORef current (Just (withIdentity value))
                pure (Left "acknowledgement lost")
            , deleteMaintenancePolicy = \_ _ selectedUid selectedVersion -> do
                selectedUid @?= uid
                selectedVersion @?= version
                modifyIORef' deletions (+ 1)
                writeIORef current Nothing
                pure (Right ())
            }
      installMaintenancePolicy transport pin >>= (@?= Right (uid, version))
      installMaintenancePolicy transport pin >>= (@?= Right (uid, version))
      readIORef creations >>= (@?= 1)
      let allowing = withIdentity (maintenancePolicyObject pin)
            & \case
              Object root -> Object (KM.insert "spec" (object
                [ "podSelector" .= object []
                , "policyTypes" .= (["Ingress"] :: [Text])
                , "ingress" .= [object []] ]) root)
              _ -> error "maintenance policy is malformed"
      writeIORef current (Just allowing)
      observed <- observeMaintenancePolicy transport pin
      assertBool "an ingress-allowing policy was accepted" (case observed of
        Left _ -> True
        Right _ -> False)
      removeMaintenancePolicy transport pin >>= \case
        Left _ -> pure ()
        Right () -> assertFailure "drifted ingress policy was deleted"
      readIORef deletions >>= (@?= 0)
      writeIORef current (Just (withIdentity (maintenancePolicyObject pin)))
      removeMaintenancePolicy transport pin >>= (@?= Right ())
      readIORef deletions >>= (@?= 1)
  ]
