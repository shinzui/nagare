-- | Parser / Bucket (EP-283). Executable-private CLI boundary.
module Nagare.Cli.Parser.Bucket
  ( bucketCmd
  )
where

import Nagare.Cli.Options (Command (..))
import Nagare.Cli.Options.Bucket (BucketCommand (..), BucketPlanOpts (..))
import Nagare.Dsl.Prelude
import Options.Applicative
  ( Parser
  , ParserInfo
  , command
  , help
  , helper
  , info
  , long
  , metavar
  , optional
  , progDesc
  , short
  , strArgument
  , strOption
  , subparser
  , (<**>)
  )

bucketCmd :: ParserInfo Command
bucketCmd =
  info
    ( Bucket
        <$> subparser
          ( command
              "plan"
              ( info
                  (BucketPlan <$> planOpts <**> helper)
                  (progDesc "Review the app object buckets a config declares: each bucket, its expiry rules and one credential per granted workload")
              )
              <> command
                "status"
                ( info
                    (BucketStatus <$> optional (strArgument (metavar "NAME" <> help "One bucket; every accepted bucket when omitted")) <**> helper)
                    (progDesc "List accepted app object buckets with their backend, store bucket and grants")
                )
              <> command
                "retire"
                ( info
                    (BucketRetire <$> strArgument (metavar "NAME") <*> savePlan <**> helper)
                    (progDesc "Save a review that removes every workload's access to a bucket; the bucket and its objects are kept")
                )
          )
          <**> helper
    )
    (progDesc "App object buckets with per-workload access")
  where
    planOpts :: Parser BucketPlanOpts
    planOpts =
      BucketPlanOpts
        <$> strOption (long "file" <> short 'f' <> metavar "CONFIG" <> help "A config that calls emitObjectBuckets")
        <*> optional savePlan
    savePlan = strOption (long "save-plan" <> metavar "DIRECTORY" <> help "Directory to save the review in")
