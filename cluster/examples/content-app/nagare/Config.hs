{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLabels #-}

-- | The content-app example (MasterPlan 39): an app that stores user files in
-- an app object bucket.
--
--   * one web Service, @content-app@, which reads and writes the bucket
--   * one Worker, @content-gateway@, which only reads it
--
-- The bucket @publications@ is declared in @Buckets.hs@ beside this file. It
-- grants each workload by name, and each workload binds it here. A binding
-- with no accepted grant is refused when the app is planned.
--
-- A bound workload receives @NAGARE_BUCKET_PUBLICATIONS_BACKEND@, @_NAME@,
-- @_ENDPOINT@, @_ACCESS_KEY_ID@ and @_SECRET_ACCESS_KEY@.
--
-- Provision it with:
--   nagarectl bucket plan --file cluster/examples/content-app/nagare/Buckets.hs --save-plan DIR
--   nagarectl inventory apply DIR --yes
--   nagarectl app deploy -f cluster/examples/content-app/nagare/Config.hs
module Main (main) where

import Control.Lens ((&), (.~))
import Data.Bifunctor (first)
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Config (emitApplication)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (BucketBinding (..), mkBucketName, mkImageRef, mkNamespace, mkServiceName)
import Nagare.Dsl.Worker (webWorker)

-- | The one shared image every workload runs.
sharedImage :: Text
sharedImage = "gcr.io/knative-samples/helloworld-go"

applicationConfig :: Either Text Application
applicationConfig = do
  appNm <- mkServiceName "content"
  ns <- mkNamespace "personal"
  img <- mkImageRef sharedImage
  publications <- BucketBinding <$> mkBucketName "publications"
  api <- webService "content-app" sharedImage
  gateway <- first Text.pack (webWorker "content-gateway" sharedImage)
  mkApplication
    Application
      { name = appNm
      , logicalKey = Nothing
      , namespace = ns
      , image = img
      , env = Map.empty
      , databases = []
      , brokers = []
      , access = Nothing
      , service = Just (api & #buckets .~ [publications])
      , workers = [gateway & #buckets .~ [publications]]
      , tasks = []
      }

main :: IO ()
main = either (ioError . userError . Text.unpack) emitApplication applicationConfig
