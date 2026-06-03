-- | Tiny driver executed by Prototype 1 via @runghc@.
--
-- It imports the app-author's @Config@ module and the shared 'renderService',
-- then writes the rendered Knative YAML to stdout. Prototype 1's harness shells
-- out to @runghc@ on this file and captures the bytes.
module Main (main) where

import Config (deployment)
import Data.ByteString qualified as BS
import Spike.Render (renderService)

main :: IO ()
main = BS.putStr (renderService deployment "20260602-120000")
