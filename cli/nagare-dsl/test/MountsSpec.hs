-- | EP-283 M1: platform mounts on each workload kind. The inputs are the
-- renderers' own goldens, so a mount is tested on what the renderers emit.
module MountsSpec (mountsTests) where

import Data.ByteString qualified as BS
import Data.ByteString.Lazy (fromStrict)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Nagare.Dsl.Mounts
import Nagare.Dsl.Prelude
import Test.Tasty
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit

mountsTests :: TestTree
mountsTests =
  testGroup
    "platform mounts"
    ( [ goldenVsString ("all three sources on a " <> kind) ("test/golden/" <> output) $ do
          rendered <- BS.readFile ("test/golden/" <> input)
          either (assertFailure . show) (pure . fromStrict) (applyPlatformMounts [identity, keys] rendered)
      | (kind, input, output) <- workloads
      ]
        <> [ testCase ("no mount leaves a " <> kind <> " byte-identical") $ do
               rendered <- BS.readFile ("test/golden/" <> input)
               applyPlatformMounts [] rendered @?= Right rendered
           | (kind, input, _) <- workloads
           ]
        <> [ testCase "a volume the workload already declares is refused" $ do
               rendered <- BS.readFile "test/golden/hello-volume.service.yaml"
               mounted <- either (assertFailure . show) pure (applyPlatformMounts [identity] rendered)
               applyPlatformMounts [identity] mounted @?= Left "platform volume nagare-identity is already used by the workload"
           , testCase "two mounts at one path are refused" $ do
               rendered <- BS.readFile "test/golden/hello.service.yaml"
               applyPlatformMounts [identity, keys & #mountPath .~ "/var/run/nagare/identity"] rendered
                 @?= Left "platform mount path /var/run/nagare/identity is already used by the workload"
           , testCase "another kind is refused" $ do
               rendered <- BS.readFile "test/golden/db-postgres.statefulset.yaml"
               applyPlatformMounts [identity] rendered @?= Left "platform mounts are not supported on kind StatefulSet"
           ]
    )
  where
    workloads =
      [ ("Knative Service", "hello.service.yaml", "hello.mounted.service.yaml")
      , ("Deployment", "worker-minimal.deployment.yaml", "worker-minimal.mounted.deployment.yaml")
      , ("CronJob", "task-standalone.cronjob.yaml", "task-standalone.mounted.cronjob.yaml")
      ]
    identity =
      PlatformMount
        { volume = "nagare-identity"
        , mountPath = "/var/run/nagare/identity"
        , sources = ServiceAccountTokenSource "nagare-workload-identity" 3600 :| [ConfigMapSource "nagare-identity-content-app"]
        }
    keys =
      PlatformMount
        { volume = "nagare-keys"
        , mountPath = "/var/run/nagare/keys"
        , sources = SecretSource "nagare-keyset-grants" :| []
        }
