-- | Options / Bucket (EP-283). Executable-private CLI boundary.
module Nagare.Cli.Options.Bucket
  ( BucketCommand (..)
  , BucketPlanOpts (..)
  )
where

import Nagare.Dsl.Prelude

data BucketCommand
  = BucketPlan BucketPlanOpts
  | -- | One bucket by name, or every accepted bucket.
    BucketStatus (Maybe String)
  | -- | The bucket's name and the directory to save the review in.
    BucketRetire String FilePath
  deriving stock (Generic, Show)

data BucketPlanOpts = BucketPlanOpts
  { file :: !FilePath
  , savePlan :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)
