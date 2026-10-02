-- | Support.Release responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Support.Release
  ( t1
  , t2
  , t3
  , release
  , tAt
  )
where

import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Static.Release (StaticRelease (..))

release :: Text -> UTCTime -> StaticRelease
release rid created =
  StaticRelease
    { releaseId = rid
    , siteName = "notes"
    , namespace = "personal"
    , image = "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes"
    , imageTag = rid
    , url = "https://notes.personal.apps.example.com"
    , source = Just "main"
    , createdAt = created
    }

t1, t2, t3 :: UTCTime
t1 = tAt 1
t2 = tAt 2
t3 = tAt 3

tAt :: Int -> UTCTime
tAt n = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime (fromIntegral n))
