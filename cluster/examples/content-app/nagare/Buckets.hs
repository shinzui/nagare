{-# LANGUAGE OverloadedStrings #-}

-- | The content-app example's object bucket (MasterPlan 39).
--
-- @publications@ is private. Objects under @staging/@ are deleted after one
-- day. The web Service @content-app@ reads and writes and may sign URLs; the
-- Worker @content-gateway@ only reads. Each gets its own credential.
--
-- Review it with:
--   nagarectl bucket plan --file cluster/examples/content-app/nagare/Buckets.hs --save-plan DIR
module Main (main) where

import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Config (emitObjectBuckets)
import Nagare.Dsl.ObjectBucket
  ( BucketAccess (..)
  , BucketGrant (..)
  , ExpireRule (..)
  , ObjectBucket (..)
  , mkBucketName
  , mkObjectPrefix
  , mkPositiveDays
  , validateObjectBucket
  )
import Nagare.Dsl.Types (mkNamespace, mkServiceName)

publications :: Either Text ObjectBucket
publications = do
  bucket <- mkBucketName "publications"
  ns <- mkNamespace "personal"
  api <- mkServiceName "content-app"
  gateway <- mkServiceName "content-gateway"
  staging <- mkObjectPrefix "staging/"
  oneDay <- mkPositiveDays 1
  validateObjectBucket
    ObjectBucket
      { name = bucket
      , logicalKey = Nothing
      , expire = [ExpireRule {prefix = staging, afterDays = oneDay}]
      , grants =
          [ BucketGrant {namespace = ns, workload = api, access = ReadWrite, signUrls = True}
          , BucketGrant {namespace = ns, workload = gateway, access = ReadOnly, signUrls = False}
          ]
      }

main :: IO ()
main = either (ioError . userError . Text.unpack) (emitObjectBuckets . pure) publications
