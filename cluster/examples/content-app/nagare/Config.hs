{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLabels #-}

-- | The content-app example (MasterPlan 39): an app that stores user files in
-- an app object bucket.
--
--   * one web Service, @content-app@, which reads and writes the bucket
--   * one Worker, @content-gateway@, which only reads it and serves every
--     host of the context's first content domain, @*.D@ and @D@, with the
--     request's own @Host@ header (EP-285)
--
-- The bucket @publications@ is declared in @Buckets.hs@ beside this file. It
-- grants each workload by name, and each workload binds it here. A binding
-- with no accepted grant is refused when the app is planned.
--
-- A bound workload receives @NAGARE_BUCKET_PUBLICATIONS_BACKEND@, @_NAME@,
-- @_ENDPOINT@, @_ACCESS_KEY_ID@ and @_SECRET_ACCESS_KEY@.
--
-- The key set @view-grants@ is declared in @KeySets.hs@ beside this file. The
-- web Service signs with it and the Worker verifies with it: each reads
-- @NAGARE_KEYSET_VIEW_GRANTS_DIR@, where the Service finds @public.json@ and
-- @private.json@ and the Worker only @public.json@.
--
-- The content domain is the first one the context lists in
-- @NAGARE_CONTENT_DOMAINS@, or @content.test@ when it lists none; deploying
-- the route needs the context to list it. @share.D@ is a fixed host of the
-- route. A content route is public: the gateway must authorise each request.
--
-- Provision it with:
--   nagarectl bucket plan --file cluster/examples/content-app/nagare/Buckets.hs --save-plan DIR
--   nagarectl inventory apply DIR --yes
--   nagarectl keyset plan --file cluster/examples/content-app/nagare/KeySets.hs --save-plan DIR
--   nagarectl inventory apply DIR --yes
--   nagarectl app deploy -f cluster/examples/content-app/nagare/Config.hs
module Main (main) where

import Control.Lens ((&), (.~), (?~))
import Data.Bifunctor (first)
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Config (emitApplication)
import Nagare.Dsl.KeySet (KeySetBinding (..), KeySetUse (..), mkKeySetName)
import Nagare.Dsl.ContentDomain (WorkerHttp (..), contentDomainText, mkContentDomain, mkContentRoute)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (BucketBinding (..), HealthScheme (HTTP), mkBucketName, mkDomain, mkImageRef, mkNamespace, mkPort, mkServiceName)
import Nagare.Dsl.Worker (defaultProbeTiming, mkHttpProbe, webWorker)
import System.Environment (lookupEnv)

-- | The one shared image every workload runs.
sharedImage :: Text
sharedImage = "gcr.io/knative-samples/helloworld-go"

applicationConfig :: Text -> Either Text Application
applicationConfig contentDomainName = do
  appNm <- mkServiceName "content"
  ns <- mkNamespace "personal"
  img <- mkImageRef sharedImage
  publications <- BucketBinding <$> mkBucketName "publications"
  viewGrants <- mkKeySetName "view-grants"
  api <- webService "content-app" sharedImage
  gateway <- first Text.pack (webWorker "content-gateway" sharedImage)
  port <- mkPort 8080
  domain <- mkContentDomain contentDomainName
  share <- mkDomain ("share." <> contentDomainText domain)
  route <- mkContentRoute domain [share]
  ready <- mkHttpProbe "/" (Just port) HTTP defaultProbeTiming
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
      , service = Just (api & #buckets .~ [publications] & #keySets .~ [KeySetBinding viewGrants Sign])
      , workers =
          [ gateway
              & #buckets .~ [publications]
              & #keySets .~ [KeySetBinding viewGrants Verify]
              & #http ?~ WorkerHttp {port = port, content = Just route}
              & #readiness ?~ ready
          ]
      , tasks = []
      }

main :: IO ()
main = do
  listed <- maybe [] (Text.splitOn "," . Text.pack) <$> lookupEnv "NAGARE_CONTENT_DOMAINS"
  let domain = case filter (not . Text.null) (map Text.strip listed) of
        first' : _ -> first'
        [] -> "content.test"
  either (ioError . userError . Text.unpack) emitApplication (applicationConfig domain)
