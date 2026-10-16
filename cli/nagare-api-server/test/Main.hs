-- | The admin API's suite: its published document and its wire behavior.
module Main (main) where

import Nagare.Api.Server.Test.Client (clientTests)
import Nagare.Api.Server.Test.Document (documentTests)
import Nagare.Contract.Prelude
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = defaultMain (testGroup "nagare-api-server" [documentTests, clientTests])
