module InventoryMaintenanceSpec (inventoryMaintenanceTests) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.DataFence.GuardAuthority
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
      let pod labels = object ["items" .= [object
            [ "metadata" .= object
                [ "name" .= ("database-0" :: Text)
                , "namespace" .= ("personal" :: Text)
                , "uid" .= ("11111111-1111-1111-1111-111111111111" :: Text)
                , "labels" .= labels ]
            , "status" .= object ["phase" .= ("Running" :: Text)]
            , "spec" .= object ["hostNetwork" .= False] ]]]
          selectedLabels = object
            [ "statefulset.kubernetes.io/pod-name" .= ("database-0" :: Text)
            , "nagare.dev/database" .= ("database" :: Text) ]
      maintenancePodSelected pin (pod selectedLabels) @?= Right ()
      case maintenancePodSelected pin (pod (object [])) of
        Left _ -> pure ()
        Right () -> assertFailure "non-selected database Pod passed ingress proof"
      let hostNetworkPod = case pod selectedLabels of
            Object root | Just (Array items) <- KM.lookup "items" root ->
              Object (KM.insert "items" (Array (fmap (\case
                Object selected -> Object (KM.insert "spec"
                  (object ["hostNetwork" .= True]) selected)
                other -> other) items)) root)
            _ -> error "maintenance Pod fixture is malformed"
      case maintenancePodSelected pin hostNetworkPod of
        Left _ -> pure ()
        Right () -> assertFailure "host-network Pod passed ingress proof"
      current <- newIORef Nothing
      competing <- newIORef []
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
            , listMaintenancePolicies = \_ -> do
                selected <- readIORef current
                others <- readIORef competing
                pure (Right (object ["items" .= (maybe [] pure selected <> others)]))
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
      let normalized = case withIdentity (maintenancePolicyObject pin) of
            Object root | Just (Object spec) <- KM.lookup "spec" root ->
              Object (KM.insert "spec" (Object (KM.delete "ingress" spec)) root)
            _ -> error "maintenance policy is malformed"
      writeIORef current (Just normalized)
      observeMaintenancePolicy transport pin >>= (@?= Right (Just (uid, version)))
      queries <- newIORef ([] :: [GuardAccessQuery])
      let principal = "system:serviceaccount:personal:application"
          access allow = GuardAccessTransport $ \query -> do
            modifyIORef' queries (query :)
            pure (Right (allow query))
      observeMaintenancePolicyAuthority (access (const False)) transport
        [principal] [("apps", "statefulsets", "database")] pin
        >>= (@?= Right True)
      inspected <- readIORef queries
      assertBool "maintenance did not check additive policy creation"
        (GuardAccessQuery principal "networking.k8s.io" (Just "personal")
          "create" "networkpolicies" Nothing "" `elem` inspected)
      assertBool "maintenance did not check a second local exec client"
        (GuardAccessQuery principal "" (Just "personal") "create"
          "pods" (Just "exec") "database-0" `elem` inspected)
      assertBool "maintenance did not check the reviewed controller template"
        (GuardAccessQuery principal "apps" (Just "personal") "patch"
          "statefulsets" Nothing "database" `elem` inspected)
      let execQuery = GuardAccessQuery principal "" (Just "personal")
            "create" "pods" (Just "exec") "database-0"
      case guardAccessReview execQuery of
        Right (Object sar) | Just (Object spec) <- KM.lookup "spec" sar
          , Just (Object attributes) <- KM.lookup "resourceAttributes" spec -> do
              KM.lookup "resource" attributes @?= Just (String "pods")
              KM.lookup "subresource" attributes @?= Just (String "exec")
              KM.lookup "namespace" attributes @?= Just (String "personal")
        _ -> assertFailure "maintenance exec SubjectAccessReview is malformed"
      observeMaintenancePolicyAuthority (access (\query ->
          accessGroup query == "networking.k8s.io"
            && accessVerb query == "create")) transport [principal] [] pin
        >>= \case
          Left reason -> assertBool "allowed edit was not identified"
            ("networkpolicies" `T.isInfixOf` reason)
          Right _ -> assertFailure "allowed policy edit was accepted"
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
      writeIORef competing [object
        [ "metadata" .= object
            [ "name" .= ("other-ingress" :: Text)
            , "namespace" .= ("personal" :: Text) ]
        , "spec" .= object ["policyTypes" .= (["Ingress"] :: [Text])] ]]
      observeMaintenancePolicy transport pin >>= \case
        Left _ -> pure ()
        Right _ -> assertFailure "another ingress policy was ignored"
      writeIORef competing []
      removeMaintenancePolicy transport pin >>= (@?= Right ())
      readIORef deletions >>= (@?= 1)
  ]
